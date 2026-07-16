import Foundation

/// Creates a fresh canonical Agent OS repo skeleton: layer directories, authoring
/// templates, a PII-hygiene .gitignore, and an adapters/ marker (what
/// `CanonicalStore.isValidRoot` checks). Templates are copied from an existing valid
/// repo when one is available; otherwise compact embedded versions are written (same
/// canonical H2 sets, trimmed guidance).
enum Scaffold {

    static let layerDirs = ["identity", "context", "skills", "memory", "connections", "agents"]

    /// Create a canonical repo at `root` (must not be a non-empty directory).
    /// `templateSource` = an existing valid repo to copy templates/validation from.
    /// Returns log lines. Does NOT git-init (call `gitInit` separately — async).
    @discardableResult
    static func create(at root: URL, copyingTemplatesFrom templateSource: URL?) throws -> [String] {
        let fm = FileManager.default
        var log: [String] = []

        if fm.fileExists(atPath: root.path) {
            let contents = (try? fm.contentsOfDirectory(atPath: root.path)) ?? []
            guard contents.filter({ !$0.hasPrefix(".") }).isEmpty else {
                throw NSError(domain: "Scaffold", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "Directory is not empty — refusing to scaffold over existing content."])
            }
        }

        for dir in layerDirs + ["adapters", "validation"] {
            try fm.createDirectory(at: root.appendingPathComponent(dir), withIntermediateDirectories: true)
        }
        log.append("✓ created layer directories")

        // PII hygiene from day one.
        let gitignore = """
        # Personal OS canonical repo — content files are PII by default.
        # Keep this repo private; never push filled content to shared remotes.
        .DS_Store
        *.bak-studio
        """
        try gitignore.write(to: root.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        log.append("✓ wrote .gitignore")

        let readme = """
        # Agent OS (canonical)

        Created by Personal OS Studio. Layers: identity, context, skills, memory,
        connections, agents. Author content from templates via Studio's Interview.
        """
        try readme.write(to: root.appendingPathComponent("adapters/README.md"), atomically: true, encoding: .utf8)
        log.append("✓ wrote adapters/README.md")

        if let source = templateSource {
            var copied = 0
            for dir in layerDirs + ["validation"] {
                let srcDir = source.appendingPathComponent(dir)
                guard let entries = try? fm.contentsOfDirectory(atPath: srcDir.path) else { continue }
                for entry in entries where entry.hasSuffix(".md") && (dir == "validation" || entry.contains("template")) {
                    let dst = root.appendingPathComponent(dir).appendingPathComponent(entry)
                    try? fm.copyItem(at: srcDir.appendingPathComponent(entry), to: dst)
                    copied += 1
                }
            }
            log.append("✓ copied \(copied) template/validation file(s) from \(source.lastPathComponent)")
        } else {
            for (path, contents) in embeddedTemplates {
                try contents.write(to: root.appendingPathComponent(path), atomically: true, encoding: .utf8)
            }
            log.append("✓ wrote \(embeddedTemplates.count) embedded templates")
        }
        return log
    }

    /// Initialize git in the scaffolded repo (skips silently when git is unavailable).
    static func gitInit(at root: URL) async -> String {
        let result = await OpenClawService.run("/usr/bin/git", ["-C", root.path, "init", "-q"])
        return result.exitCode == 0 ? "✓ git repository initialized" : "· git init skipped (\(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)))"
    }

    // MARK: Embedded templates (compact; canonical H2 sets preserved)

    private static func fm(_ title: String, layer: String, extra: String = "") -> String {
        """
        ---
        title: <Your name>'s \(title)
        designation: PII
        layer: \(layer)
        \(extra.isEmpty ? "" : extra + "\n")owner: <your-email-or-handle>
        review_cadence: quarterly
        last_reviewed: <YYYY-MM-DD>
        version: 0.1.0
        status: draft
        target_tools: [openclaw]
        ---

        > **Classification: PII** — once filled in, do not commit to shared repositories.

        """
    }

    static let embeddedTemplates: [String: String] = [
        "identity/identity.template.md": fm("Identity", layer: "identity") + """
        ## Classification

        Identity captures personal preferences and rules tied to a specific user — always PII.

        ## Agent Identity

        - **Name:** <agent name>
        - **Archetype:** <e.g. Chief of Staff>
        - **Purpose:** <one sentence>
        - **Scope:** <covers / does not cover>

        ## User Profile

        - **Preferred name / address:** <how to refer to you>
        - **Timezone & working hours:** <tz, hours>
        - **Communication preferences:** <style>
        - **Formats you reach for:** <formats>

        ## Operating Principles

        1. <Durable rule.>
        2. <Another.>
        3. <3–7 total.>

        ## Boundaries

        - <Thing the agent should not do.>

        ## Style & Tone

        - **Voice:** <voice>
        - **Verbosity:** <verbosity>
        - **Formatting:** <formatting>

        ## Output Expectations

        - <What good output looks like.>

        ## Escalation & Confirmation

        - <When to ask before acting.>

        ## Change Log

        - <YYYY-MM-DD> · v0.1.0 — created
        """,

        "context/role.template.md": fm("Role Context", layer: "context", extra: "context_type: role") + """
        ## Classification

        Ties a role and mandate to a person — PII by default.

        ## Role

        - **Title:** <title>
        - **Seniority / scope:** <reporting line, remit>
        - **Scope of authority:** <can act on without escalation>

        ## Mandate

        <One sentence: the role's purpose.>

        ## Time Horizon

        - **Primary horizon:** <quarter / year>
        - **Planning rhythm:** <cadence>

        ## Decisions Owned

        - <Decision made unilaterally.>

        ## Signals & KPIs

        - <Metric the role is judged on.>

        ## Change Log

        - <YYYY-MM-DD> · v0.1.0 — created
        """,

        "context/domain.template.md": fm("Domain Context", layer: "context", extra: "context_type: domain") + """
        ## Classification

        Describes the work domain — PII when tied to a person's priorities.

        ## Domain

        <The field or business area.>

        ## Mission

        <What the domain exists to achieve.>

        ## Stakeholders

        - <Who cares about outcomes.>

        ## Vocabulary

        - **<Term>:** <meaning>

        ## Constraints

        - <Hard constraint.>

        ## Current Priorities

        - <Priority.>

        ## Change Log

        - <YYYY-MM-DD> · v0.1.0 — created
        """,

        "context/team.template.md": fm("Team Context", layer: "context", extra: "context_type: team") + """
        ## Classification

        Names reporting lines and people — PII.

        ## Reporting Line Up

        - <Manager and above.>

        ## Peers

        - <Peer and what they own.>

        ## Direct Reports

        - <Report and what they own.>

        ## Cadence

        - <Meeting rhythm.>

        ## Key Stakeholders

        - <Stakeholder and stake.>

        ## Escalation Paths

        - <When to go to whom.>

        ## Change Log

        - <YYYY-MM-DD> · v0.1.0 — created
        """,

        "skills/skill.template.md": """
        ---
        title: <Skill title>
        designation: PII
        layer: skills
        name: <kebab-case-name>
        scope: personal
        owner: <your-email-or-handle>
        review_cadence: quarterly
        last_reviewed: <YYYY-MM-DD>
        version: 0.1.0
        status: draft
        target_tools: [openclaw]
        ---

        > **Classification: PII** — once filled in, do not commit to shared repositories.

        ## Classification

        Skills encode personal procedure — PII by default.

        ## Trigger

        <One sentence: when to invoke this skill.>

        ## Inputs

        - <Input.>

        ## Procedure

        1. <Step.>

        ## Output

        <Shape and destination of the output.>

        ## Examples

        <Worked example.>

        ## Test Plan

        - <How to verify the skill works.>

        ## Evolution Notes

        - <What to watch as this matures.>

        ## Change Log

        - <YYYY-MM-DD> · v0.1.0 — created
        """,

        "memory/MEMORY.template.md": """
        ---
        title: Memory Index Template
        designation: PII
        layer: memory
        owner: <your-email-or-handle>
        review_cadence: monthly
        last_reviewed: <YYYY-MM-DD>
        version: 0.1.0
        status: draft
        target_tools: [openclaw]
        ---

        > Template note: the FILLED index itself carries no frontmatter — it's an index,
        > not a memory. One line per entry; keep under 200 lines.

        ## User

        - [<title>](<file.md>) — <one-line hook>

        ## Feedback

        - [<title>](<file.md>) — <one-line hook>

        ## Project

        - [<title>](<file.md>) — <one-line hook>

        ## Reference

        - [<title>](<file.md>) — <one-line hook>
        """,

        "memory/persistent.entry.template.md": """
        ---
        title: <Entry title>
        designation: PII
        layer: memory
        entry_type: <user|feedback|project|reference>
        name: <kebab-case-name>
        description: <one line — this is the recall hook>
        owner: <your-email-or-handle>
        review_cadence: monthly
        last_reviewed: <YYYY-MM-DD>
        version: 0.1.0
        status: draft
        target_tools: [openclaw]
        ---

        > **Classification: PII** — once filled in, do not commit to shared repositories.

        ## Classification

        Memory entries are about the user — PII.

        ## Entry

        <The fact. For feedback/project entries include **Why:** and **How to apply:** lines.>

        ## Source

        <Where this came from and when.>

        ## Change Log

        - <YYYY-MM-DD> · v0.1.0 — created
        """,
    ]
}
