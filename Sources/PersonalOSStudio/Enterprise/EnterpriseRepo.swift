import Foundation

/// One document in the enterprise repo, at some curation stage.
struct EnterpriseItem: Identifiable, Equatable {
    enum Stage: String, CaseIterable {
        case suggested, catalog, disallowed

        var title: String {
            switch self {
            case .suggested: return "Suggested (pending review)"
            case .catalog: return "Catalog (allowed)"
            case .disallowed: return "Disallowed"
            }
        }
    }

    let stage: Stage
    let layer: Layer
    let filename: String
    let url: URL
    let title: String
    let name: String
    let designation: Designation
    let contributedBy: String
    let contributedOn: String
    let moderationNote: String
    let contents: String

    var id: String { "\(stage.rawValue)/\(layer.rawValue)/\(filename)" }

    static func == (a: EnterpriseItem, b: EnterpriseItem) -> Bool { a.id == b.id }
}

/// The shared Enterprise Agent OS repo: three curation stages as directories
/// (`suggested/` → `catalog/` or `disallowed/`), layer subdirectories inside each.
/// Studio reads and writes the LOCAL clone only — remote sync is a deliberate human
/// git action, same posture as F10.
struct EnterpriseRepo {

    static let pathKey = "enterprise.repoPath"
    static let skippedKey = "enterprise.skipped"
    /// Layers that may hold shared content (identity is always PII; memory is personal).
    static let sharedLayers: [Layer] = [.skills, .connections, .context, .agents]

    let root: URL

    // MARK: Configuration

    static var configured: EnterpriseRepo? {
        guard let path = UserDefaults.standard.string(forKey: pathKey) else { return nil }
        let repo = EnterpriseRepo(root: URL(fileURLWithPath: path))
        return repo.isValid ? repo : nil
    }

    var isValid: Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: root.appendingPathComponent("suggested").path)
            && fm.fileExists(atPath: root.appendingPathComponent("catalog").path)
    }

    /// Create the stage/layer skeleton (+ README when absent). Idempotent.
    static func initialize(at root: URL) throws {
        let fm = FileManager.default
        for stage in EnterpriseItem.Stage.allCases {
            for layer in sharedLayers {
                try fm.createDirectory(
                    at: root.appendingPathComponent("\(stage.rawValue)/\(layer.rawValue)"),
                    withIntermediateDirectories: true)
            }
        }
        let readme = root.appendingPathComponent("README.md")
        if !fm.fileExists(atPath: readme.path) {
            try """
            # Enterprise Agent OS

            Shared library of Enterprise-designated Agent OS content. Stages:
            `suggested/` (pending review) → `catalog/` (allowed, pullable) or
            `disallowed/` (rejected, kept for audit with a moderation_note).
            Managed by Personal OS Studio; remote sync is a deliberate git action.
            """.write(to: readme, atomically: true, encoding: .utf8)
        }
    }

    // MARK: Listing

    func items(in stage: EnterpriseItem.Stage) -> [EnterpriseItem] {
        let fm = FileManager.default
        var out: [EnterpriseItem] = []
        for layer in Self.sharedLayers {
            let dir = root.appendingPathComponent("\(stage.rawValue)/\(layer.rawValue)")
            guard let entries = try? fm.contentsOfDirectory(atPath: dir.path) else { continue }
            for file in entries.sorted() where file.hasSuffix(".md") {
                let url = dir.appendingPathComponent(file)
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                let fields = Frontmatter.split(text).0
                out.append(EnterpriseItem(
                    stage: stage, layer: layer, filename: file, url: url,
                    title: fields["title"] ?? file,
                    name: fields["name"] ?? (file as NSString).deletingPathExtension,
                    designation: Designation(rawValue: fields["designation"] ?? "") ?? .unknown,
                    contributedBy: fields["contributed_by"] ?? "",
                    contributedOn: fields["contributed_on"] ?? "",
                    moderationNote: fields["moderation_note"] ?? "",
                    contents: text))
            }
        }
        return out
    }

    /// Which stage (if any) already holds a document with this frontmatter name.
    func stage(ofName name: String, layer: Layer) -> EnterpriseItem.Stage? {
        for stage in EnterpriseItem.Stage.allCases {
            if items(in: stage).contains(where: { $0.name == name && $0.layer == layer }) {
                return stage
            }
        }
        return nil
    }

    // MARK: Contribute (client → suggested/)

    /// Write a canonical document into `suggested/`, stamped with contribution
    /// provenance. The caller has already vetted designation + content.
    @discardableResult
    func contribute(contents: String, layer: Layer, filename: String,
                    contributedBy: String, today: String) throws -> URL {
        let stamped = Self.injectFrontmatter(
            ["contributed_by": contributedBy, "contributed_on": today], into: contents)
        let dest = root.appendingPathComponent("suggested/\(layer.rawValue)/\(filename)")
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try stamped.write(to: dest, atomically: true, encoding: .utf8)
        return dest
    }

    // MARK: Admin (suggested/ → catalog/ | disallowed/)

    @discardableResult
    func allow(_ item: EnterpriseItem) throws -> URL {
        try move(item, to: .catalog, rewriting: item.contents)
    }

    @discardableResult
    func disallow(_ item: EnterpriseItem, note: String) throws -> URL {
        let noted = Self.injectFrontmatter(["moderation_note": note], into: item.contents)
        return try move(item, to: .disallowed, rewriting: noted)
    }

    private func move(_ item: EnterpriseItem, to stage: EnterpriseItem.Stage,
                      rewriting contents: String) throws -> URL {
        let dest = root.appendingPathComponent("\(stage.rawValue)/\(item.layer.rawValue)/\(item.filename)")
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try contents.write(to: dest, atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: item.url)
        return dest
    }

    // MARK: Skip memory (client-side)

    static func skippedHashes() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: skippedKey) ?? [])
    }

    static func recordSkip(hash: String) {
        var skipped = UserDefaults.standard.stringArray(forKey: skippedKey) ?? []
        skipped.append(hash)
        UserDefaults.standard.set(Array(skipped.suffix(1000)), forKey: skippedKey)
    }

    // MARK: Bits

    /// Insert (or replace) frontmatter keys just before the closing `---`.
    static func injectFrontmatter(_ fields: [String: String], into text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let end = lines.dropFirst().firstIndex(where: {
                  $0.trimmingCharacters(in: .whitespaces) == "---"
              })
        else { return text }
        var insertAt = end
        for (key, value) in fields.sorted(by: { $0.key < $1.key }) {
            if let existing = lines[1..<insertAt].firstIndex(where: {
                $0.trimmingCharacters(in: .whitespaces).hasPrefix("\(key):")
            }) {
                lines[existing] = "\(key): \(value)"
            } else {
                lines.insert("\(key): \(value)", at: insertAt)
                insertAt += 1
            }
        }
        return lines.joined(separator: "\n")
    }
}
