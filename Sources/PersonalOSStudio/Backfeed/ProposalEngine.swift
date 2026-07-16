import Foundation

/// A reviewed-before-write suggestion to update the canonical repo from harness drift.
struct Proposal: Identifiable {
    let id = UUID()
    let sourceHarness: String
    let sourceFile: String
    /// Dismissal key — the drift item's content hash.
    let driftHash: String
    let targetRelativePath: String
    let proposedContents: String
    let rationale: String
    let isNewFile: Bool
}

/// Turns one drift item into a canonical proposal. The LLM only ever *drafts*;
/// everything before it (detection) and after it (guardrails, validation, review) is
/// deterministic. A weak model can produce a bad draft — it cannot produce a
/// non-compliant canonical file or an unreviewed write.
/// MainActor: shares InterviewEngine's guardrail statics and is only driven from UI /
/// the MainActor test harness.
@MainActor
enum ProposalEngine {

    // MARK: Reverse heading mapping

    /// Undo the shared adapter identity renames (canonical → harness) on a proposed
    /// IDENTITY document, so harness dialect ("## Principles") never lands canonically.
    /// Applied only to identity targets: other layers legitimately use headings like
    /// "## User" (MEMORY index) that must not be rewritten.
    static func reverseIdentityHeadings(_ text: String) -> String {
        var out: [String] = []
        for line in text.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("## ") {
                let heading = String(t.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                if let match = AdapterHelpers.identityRenames.first(where: {
                    $0.to.compare(heading, options: .caseInsensitive) == .orderedSame
                }) {
                    out.append("## \(match.from)")
                    continue
                }
            }
            out.append(line)
        }
        return out.joined(separator: "\n")
    }

    // MARK: Prompt

    /// System + user prompt for one drift item. Bounded: the drift text is truncated
    /// like `boundedDocBlock`; only the likely-relevant canonical doc and (for new
    /// entries) the memory template ride along — never whole trees.
    static func prompt(item: DriftItem, harnessName: String, store: CanonicalStore,
                       ownerEmail: String, today: String) -> (system: String, user: String) {
        let renames = AdapterHelpers.identityRenames
            .filter { $0.from != $0.to }
            .map { "\"\($0.to)\" was rendered from canonical \"\($0.from)\"" }
            .joined(separator: "; ")

        let memoryTemplate = store.files(.memory)
            .first { $0.isTemplate && $0.filename.hasPrefix("persistent.entry.") }
            .map { store.read($0) } ?? ""

        let system = """
        You maintain a canonical "Agent OS" repository of Markdown documents organized in \
        layers: identity/, context/, skills/, memory/, connections/, agents/. A deployed \
        AI harness ("\(harnessName)") has drifted from what was compiled out of that \
        repository — usually because the agent learned something at runtime. Your job is \
        to fold ONE drift item back into the canonical repository as a single document.

        Rules:
        - Prefer creating or updating a MEMORY entry (memory/<kebab-name>.md) unless the \
          drift clearly belongs in another layer (e.g. a changed identity preference).
        - Harness files rename canonical headings: \(renames). Always emit CANONICAL \
          headings.
        - Frontmatter must be complete: title, designation (PII / Enterprise / Public), \
          layer, name (kebab-case, for instance documents), owner: \(ownerEmail), \
          review_cadence, last_reviewed: \(today), version, status, target_tools. \
          Include the blockquote classification banner right after the frontmatter.
        - Never include credentials or secrets.
        - Output EXACTLY this format, nothing else:

        TARGET: <canonical relative path, e.g. memory/some-fact.md>
        RATIONALE: <one line: why this update>
        ---
        <the complete proposed file contents>
        """

        let bounded = item.currentText.count > 6_000
            ? String(item.currentText.prefix(6_000)) + "\n…(truncated)…"
            : item.currentText

        var user = """
        Drift item (\(item.kind.rawValue)) from \(harnessName), file `\(item.relativePath)`:

        ```markdown
        \(bounded)
        ```
        """
        if item.kind == .added, !memoryTemplate.isEmpty {
            user += """


            Template for a new memory entry (keep its H2 headings verbatim):

            \(memoryTemplate)
            """
        }
        return (system, user)
    }

    // MARK: Parse + finalize

    static func parse(_ raw: String) -> (target: String, rationale: String, contents: String)? {
        let text = InterviewEngine.stripCodeFence(raw)
        guard let targetLine = text.components(separatedBy: "\n")
                .first(where: { $0.hasPrefix("TARGET:") }),
              let sepRange = text.range(of: "\n---\n")
        else { return nil }
        let head = String(text[..<sepRange.lowerBound])
        let rationale = head.components(separatedBy: "\n")
            .first { $0.hasPrefix("RATIONALE:") }
            .map { String($0.dropFirst("RATIONALE:".count)).trimmingCharacters(in: .whitespaces) }
            ?? "harness update"
        let target = String(targetLine.dropFirst("TARGET:".count))
            .trimmingCharacters(in: .whitespaces)
        let contents = String(text[sepRange.upperBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty, !contents.isEmpty else { return nil }
        return (target, rationale, contents)
    }

    /// Deterministic disposal of a raw model response: sanitize the target path, apply
    /// the authoring guardrail chain, and gate on validation — returns nil (dropped)
    /// for anything that would land a non-compliant file.
    static func finalize(item: DriftItem, harness: String, rawResponse: String,
                         canonicalRoot: URL, today: String) -> Proposal? {
        guard var (target, rationale, contents) = parse(rawResponse) else { return nil }

        // Target must be layer-relative, no traversal.
        let parts = target.components(separatedBy: "/")
        guard parts.count >= 2, !target.contains(".."),
              let layer = Layer(rawValue: parts[0]),
              target.hasSuffix(".md")
        else { return nil }

        contents = InterviewEngine.normalizeFrontmatter(contents)
        if layer == .identity {
            contents = reverseIdentityHeadings(contents)
        }

        let store = CanonicalStore(rootURL: canonicalRoot)
        let existingURL = canonicalRoot.appendingPathComponent(target)
        let exists = FileManager.default.fileExists(atPath: existingURL.path)

        if exists {
            // Update: never trust the model with version math.
            let original = (try? String(contentsOf: existingURL, encoding: .utf8)) ?? ""
            let originalVersion = Frontmatter.split(original).0["version"] ?? "0.1.0"
            contents = InterviewEngine.enforceRefineGuardrail(
                draft: contents, originalVersion: originalVersion, today: today)
        } else if layer.cardinality == .multi {
            // New instance: guarantee a kebab name and derive the filename from it.
            contents = InterviewEngine.ensureInstanceName(contents)
            if let name = Frontmatter.split(contents).0["name"],
               InterviewEngine.isValidInstanceName(name) {
                target = "\(layer.rawValue)/\(name).md"
            }
        }

        // Validation gate in a scratch repo (canonical templates + the proposal).
        guard validationErrors(contents: contents, target: target, store: store).isEmpty
        else { return nil }

        return Proposal(sourceHarness: harness, sourceFile: item.relativePath,
                        driftHash: item.contentHash, targetRelativePath: target,
                        proposedContents: contents, rationale: rationale,
                        isNewFile: !exists)
    }

    /// Error-severity findings for a proposed file, computed without touching the real
    /// repo: templates are copied into a scratch root, the proposal written beside
    /// them, and the standard Validator runs.
    static func validationErrors(contents: String, target: String,
                                 store: CanonicalStore) -> [Finding] {
        let fm = FileManager.default
        // Resolve the temp root's symlinks (/var → /private/var) so the store's
        // exact-path lookups match the URLs it enumerates.
        let scratch = fm.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("backfeed-validate-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: scratch) }
        do {
            for layer in Layer.allCases {
                let dir = scratch.appendingPathComponent(layer.rawValue)
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                for template in store.files(layer) where template.isTemplate {
                    try? fm.copyItem(at: template.url,
                                     to: dir.appendingPathComponent(template.filename))
                }
            }
            let dest = scratch.appendingPathComponent(target)
            try fm.createDirectory(at: dest.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            try contents.write(to: dest, atomically: true, encoding: .utf8)
        } catch { return [Finding(severity: .error, rule: "backfeed.scratch",
                                  message: error.localizedDescription)] }

        let scratchStore = CanonicalStore(rootURL: scratch)
        // Symlink-insensitive lookup: Foundation normalizes /private/var vs /var
        // inconsistently between enumerated URLs and constructed ones — resolve both.
        let wanted = scratch.appendingPathComponent(target).resolvingSymlinksInPath().path
        let file = Layer.allCases.lazy
            .flatMap { scratchStore.files($0) }
            .first { $0.url.resolvingSymlinksInPath().path == wanted }
        guard let file else {
            return [Finding(severity: .error, rule: "backfeed.scratch",
                            message: "proposed file not loadable")]
        }
        return Validator(store: scratchStore).validate(file)
            .filter { $0.severity == .error }
    }
}
