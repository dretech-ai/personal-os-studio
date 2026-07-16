import Foundation

/// The demo-mode personal OS: a complete, validation-clean canonical repo for a
/// wholly fictional, original character — **Nova Reyes**, creative director at the
/// invented indie game studio **Orbit Labs**, with **Beacon** as her Chief of Staff
/// agent. No real people, no third-party IP. Content spans every layer plus eval
/// cases, so every feature of the app has something to show without touching the
/// presenter's real OS or any live harness.
enum DemoContent {

    static let dirName = "demo-agent-os"

    /// Where the demo repo lives — an Application Support copy, safe to edit and
    /// rebuilt fresh on every entry into demo mode (deterministic demos).
    static var demoRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PersonalOSStudio/\(dirName)")
    }

    /// Wipe + rebuild the demo repo: scaffold (layer dirs + authoring templates),
    /// then write the Orbit Labs content and eval cases. Returns the root.
    @discardableResult
    static func install(at root: URL = demoRoot, today: String) throws -> URL {
        let fm = FileManager.default
        try? fm.removeItem(at: root)
        try Scaffold.create(at: root, copyingTemplatesFrom: nil)
        try fm.createDirectory(at: root.appendingPathComponent("evals"),
                               withIntermediateDirectories: true)
        for (path, contents) in files(today: today) {
            let dest = root.appendingPathComponent(path)
            try fm.createDirectory(at: dest.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            try contents.write(to: dest, atomically: true, encoding: .utf8)
        }
        return root
    }

    // MARK: The Orbit Labs OS (original fiction)

    static func files(today: String) -> [String: String] {
        let owner = "nova@orbitlabs.example"
        func fm(_ title: String, designation: String, layer: String,
                extra: String = "") -> String {
            """
            ---
            title: \(title)
            designation: \(designation)
            layer: \(layer)
            \(extra.isEmpty ? "" : extra + "\n")owner: \(owner)
            review_cadence: quarterly
            last_reviewed: \(today)
            version: 1.0.0
            status: active
            target_tools: [openclaw]
            ---

            > **Classification: \(designation)** — demo content: a fictional character invented for this tutorial. No real personal data.

            """
        }

        return [
            // ── Identity ────────────────────────────────────────────────────────
            "identity/identity.md": fm("Nova Reyes's Chief of Staff Identity",
                                       designation: "PII", layer: "identity") + """
            ## Classification

            Identity files are always classified **PII** by schema rule — even for a fictional user, the layer captures preferences and rules tied to a specific individual. (Demo note: this is where YOUR working style would live.)

            ## Agent Identity

            - **Name:** Beacon
            - **Archetype:** Chief of Staff, Orbit Labs
            - **Purpose:** Keep the studio running smoothly so Nova can focus on the game and the team.
            - **Scope:** Sprint planning, team coordination, and playtest logistics. Does not write code or ship builds (see Escalation).

            ## User Profile

            - **Preferred name / address:** Nova (never "Ms. Reyes")
            - **Timezone & working hours:** America/Denver, 9am–6pm, protects deep-work mornings
            - **Communication preferences:** Direct and brief; celebrate shipped work out loud
            - **Formats you reach for:** Checklists for logistics, short prose for creative notes

            ## Operating Principles

            1. The playtest is the source of truth — opinions lose to what players actually do.
            2. Protect the team's focus; batch interruptions, never scatter them.
            3. Ship small and often over big and late.
            4. Credit generously and publicly; correct privately.
            5. When the call is genuinely creative, bring it to Nova — don't decide it.

            ## Boundaries

            - Never announce or hint at an unannounced title, internally or externally.
            - Never commit the team to a deadline without Nova's sign-off.
            - Never schedule meetings before 11am (deep-work mornings are protected).

            ## Style & Tone

            - **Voice:** Warm, candid, energizing — a steady second-in-command
            - **Verbosity:** Short sentences; one idea at a time
            - **Formatting:** Bullets for plans, a plain sentence for encouragement

            ## Output Expectations

            - Plans end with a clear "who does what by when" list.
            - Every summary closes with one thing that shipped or improved today.

            ## Escalation & Confirmation

            - Ask Priya before changing the sprint schedule.
            - Escalate anything touching the build pipeline or live servers to Marcus immediately.
            - Confirm before inviting more than eight external playtesters (NDA + seat limits).

            ## Change Log

            - \(today) · v1.0.0 — demo content created
            """,

            // ── Context ─────────────────────────────────────────────────────────
            "context/role.md": fm("Nova's Role Context", designation: "Public",
                                  layer: "context", extra: "context_type: role") + """
            ## Classification

            This file is classified **Public** — a generic creative-director role at a fictional studio; no personal data.

            ## Role

            - **Title:** Creative Director & Founder, Orbit Labs
            - **Seniority / scope:** Founder-level; accountable to the players and the small team
            - **Scope of authority:** Creative direction, release scope, playtest cadence

            ## Mandate

            Make sure every build the studio ships is a little more fun than the last — and that the team is proud of how it was made.

            ## Time Horizon

            - **Primary horizon:** The current milestone, planned two sprints ahead
            - **Planning rhythm:** Weekly sprint review; monthly milestone check

            ## Decisions Owned

            - Release scope and the "definition of fun" for each milestone.
            - Which prototype graduates from spike to feature.
            - When to call a playtest.

            ## Signals & KPIs

            - Playtest fun-rating trend (up and to the right).
            - Time from idea to playable prototype.
            - Team sustainability — no crunch as a planned strategy.

            ## Change Log

            - \(today) · v1.0.0 — demo content created
            """,

            "context/domain.md": fm("Indie Game Studio Domain", designation: "Public",
                                    layer: "context", extra: "context_type: domain") + """
            ## Classification

            This file is classified **Public** — it describes a generic (fictional) game-studio domain.

            ## Domain

            Indie game development at Orbit Labs: rapid prototyping, weekly playtests, and small frequent releases of a cooperative puzzle game.

            ## Mission

            Prove a game idea is fun with players before it is expensive to build — one playtest at a time.

            ## Stakeholders

            - The players (the playtest group) — the reason for everything.
            - The team — small, senior, protective of their craft.
            - The community — early followers who get devlogs.

            ## Vocabulary

            - **Spike:** A throwaway prototype built to answer exactly one question.
            - **The Forge:** The studio's build server — produces a fresh playable build each morning.
            - **Demo reel:** The playtest closer — the highlight cut shown at the end. Non-negotiable.
            - **Fun-rating:** Players' 1–5 score after a session; the studio's north-star signal.

            ## Constraints

            - Every prototype must be playable within one sprint or it's cut.
            - Playtests end on time — the demo reel waits for no one.
            - No feature ships without a passing playtest.

            ## Current Priorities

            - Co-op mode vertical slice (see memory: coop-vertical-slice).
            - A new track for the launch-anniversary devlog.
            - Getting Marcus to timebox spikes instead of gold-plating them.

            ## Change Log

            - \(today) · v1.0.0 — demo content created
            """,

            "context/team.md": fm("Orbit Labs Team Context", designation: "Public",
                                  layer: "context", extra: "context_type: team") + """
            ## Classification

            This file is classified **Public** — the team is invented fiction. (Demo note: in a real OS this layer is PII — it names your actual colleagues.)

            ## Reporting Line Up

            - Nova reports to no one — but treats Priya's read on schedule and scope as decisive.

            ## Peers

            - **Priya Anand** — studio lead; owns the sprint schedule and release calendar.
            - **Marcus Bell** — lead engineer; brilliant, goes deep — keep tasks tightly scoped or he spirals.
            - **Dev Okafor** — art & build logistics; enthusiastic, great under a deadline.
            - **Sam Torres** — community & playtest coordination.

            ## Direct Reports

            - **Biscuit** — studio dog, morale officer. Compensation: the squeaky carrot and walks.

            ## Cadence

            - Daily: 11am async stand-up (protects the morning).
            - Weekly: playtest + sprint retro (what made players smile).

            ## Key Stakeholders

            - **The playtest group** — eight rotating external players under NDA.
            - **Ren (contractor)** — audio; recurring, brief them tightly and confirm scope.

            ## Escalation Paths

            - Schedule conflicts → Priya.
            - Build/pipeline incidents → Marcus, immediately.
            - Missing assets → check with Dev before declaring them missing.

            ## Change Log

            - \(today) · v1.0.0 — demo content created
            """,

            // ── Skills ──────────────────────────────────────────────────────────
            "skills/plan-a-playtest.md": fm("Plan a Playtest", designation: "Public",
                                            layer: "skills",
                                            extra: "name: plan-a-playtest\nscope: personal") + """
            ## Classification

            This skill is classified **Public** — a generic (fictional) studio procedure.

            ## Trigger

            Nova asks to run a playtest, or a prototype is ready for players from the morning Forge build.

            ## Inputs

            - The build under test and the one question it should answer.
            - Which team members are available to observe.
            - The playtester roster for the session.

            ## Procedure

            1. State the single question the session must answer, in one sentence.
            2. Assign each observation role to a team member's strength (Marcus: systems edge cases; Dev: first-time-user friction; Priya: does the plan survive contact with players).
            3. Reserve one build slot for a follow-up hotfix build.
            4. End the session with the demo reel. Always.
            5. Read the session plan to Biscuit — if the tail wags, ship it.

            ## Output

            A one-page playtest plan: the question, observer assignments, build slots, and the closing demo reel.

            ## Examples

            Question: "Do players understand the grapple without a tutorial?" Plan: Dev watches first-touch friction, Marcus logs edge cases, hotfix slot reserved, demo reel to close.

            ## Test Plan

            - Given a sample question, the plan names an observer for every role.
            - The demo reel appears as the final item.
            - No session uses a build the Forge didn't produce that day.

            ## Evolution Notes

            - Known limitation: assumes the playtest roster is confirmed the day before.
            - v2 idea: auto-pull the fun-rating summary from the session tool.

            ## Change Log

            - \(today) · v1.0.0 — demo content created
            """,

            "skills/pick-the-prototype.md": fm("Pick the Right Prototype", designation: "Public",
                                             layer: "skills",
                                             extra: "name: pick-the-prototype\nscope: personal") + """
            ## Classification

            This skill is classified **Public** — a generic (fictional) studio procedure.

            ## Trigger

            A design question needs answering and it's time to decide which spike to build first.

            ## Inputs

            - The design question at hand.
            - The candidate spikes on the shelf.

            ## Procedure

            1. Restate the question as something a player could feel in 30 seconds.
            2. Eliminate spikes that can't answer it within one sprint — say why, plainly.
            3. If two remain, pick the one that's cheaper to throw away.
            4. Confirm the choice with the team before anyone opens the editor.

            ## Output

            One selected spike with a one-line justification tied to the design question.

            ## Examples

            Question: is the co-op puzzle better timed or turn-based? Two spikes; pick the timed one first — it's the cheaper build to discard if it flops.

            ## Test Plan

            - Given a question and three spikes, exactly one is selected.
            - The justification references the design question.
            - No spike is chosen that can't be built within a sprint.

            ## Evolution Notes

            - Known limitation: "cheaper to throw away" is a judgment call the team should sanity-check.

            ## Change Log

            - \(today) · v1.0.0 — demo content created
            """,

            // ── Memory ──────────────────────────────────────────────────────────
            // The index deliberately has NO frontmatter — it's an index, not a memory.
            "memory/MEMORY.md": """
            # Memory index

            One line per entry; the agent reads this every session and opens files on demand.

            ## User

            - [Biscuit's favorite toy](biscuit-favorite-toy.md) — the squeaky carrot, lives by the door

            ## Feedback

            ## Project

            - [Co-op vertical slice](coop-vertical-slice.md) — timed puzzles; Marcus owns the netcode spike

            ## Reference

            - [Launch anniversary devlog](launch-anniversary-devlog.md) — needs one new track; keep the intro sting
            """,

            "memory/biscuit-favorite-toy.md": fm("Biscuit's Favorite Toy", designation: "Public",
                                                layer: "memory",
                                                extra: "entry_type: user\nname: biscuit-favorite-toy\ndescription: Biscuit's favorite toy is the squeaky carrot by the studio door") + """
            ## Classification

            This entry is classified **Public** — fictional lore. (In a real OS, memory entries about your life are PII.)

            ## Entry

            Biscuit's favorite toy is the squeaky carrot that lives in the basket by the studio door. Use it for morale moments and end-of-sprint celebrations. No other toy will do; Biscuit knows the difference.

            ## Source

            Observed at the studio, many times.

            ## Change Log

            - \(today) · v1.0.0 — demo content created
            """,

            "memory/coop-vertical-slice.md": fm("Co-op Vertical Slice", designation: "Public",
                                                 layer: "memory",
                                                 extra: "entry_type: project\nname: coop-vertical-slice\ndescription: co-op mode slice uses timed puzzles; Marcus owns the netcode spike") + """
            ## Classification

            This entry is classified **Public** — fictional lore.

            ## Entry

            The co-op vertical slice uses timed (not turn-based) puzzles. **Why:** the timed spike playtested more fun. **How to apply:** schedule netcode work around Marcus's spike weeks, and remember the slice is scoped to two puzzle rooms — resist adding a third.

            ## Source

            Sprint planning notes, co-op kickoff.

            ## Change Log

            - \(today) · v1.0.0 — demo content created
            """,

            "memory/launch-anniversary-devlog.md": fm("Launch Anniversary Devlog", designation: "Public",
                                                      layer: "memory",
                                                      extra: "entry_type: reference\nname: launch-anniversary-devlog\ndescription: anniversary devlog needs one new track; keep the original intro sting") + """
            ## Classification

            This entry is classified **Public** — fictional lore.

            ## Entry

            The launch-anniversary devlog needs exactly one new music track. The original intro sting is untouchable — the community recognizes it instantly. Draft tracks go to Ren first.

            ## Source

            Community retro, last week.

            ## Change Log

            - \(today) · v1.0.0 — demo content created
            """,

            // ── Connections ─────────────────────────────────────────────────────
            "connections/the-forge.md": fm("The Forge", designation: "Public",
                                             layer: "connections",
                                             extra: "mechanism: builtin\naccess_mode: read-only\nname: the-forge\nservice: The Forge") + """
            ## Classification

            This connection is classified **Public** — a fictional integration. (Demo note: real connections document HOW an agent reaches a service — and never contain credentials.)

            ## Service

            - **Name:** The Forge
            - **Purpose:** Produces a fresh playable build each morning for playtests.
            - **Vendor / endpoint:** The studio's build server.

            ## Mechanism

            - **Type:** `builtin`
            - **Specifics:** Native studio capability; the morning build report is posted automatically.

            ## Access Mode

            - **Mode:** `read-only`
            - **Justification:** Beacon reports which build is ready; nobody triggers deploys from here.

            ## Capabilities

            - Report today's build id and status.
            - Flag whether the build passed smoke tests.

            ## Credentials

            - None. Build reports are read-only and carry no secrets.

            ## Test Plan

            - Morning check lists exactly one build id.
            - A failed smoke test is surfaced, not hidden.

            ## Security Notes

            - Pipeline internals stay with engineering (see identity Boundaries).

            ## Evolution Notes

            - Occasionally the report lags the actual build by a few minutes.

            ## Change Log

            - \(today) · v1.0.0 — demo content created
            """,

            // ── Agents ──────────────────────────────────────────────────────────
            "agents/daily-studio-briefing.md": fm("Daily Studio Briefing", designation: "Public",
                                                     layer: "agents",
                                                     extra: "name: daily-studio-briefing") + """
            ## Classification

            This agent job is classified **Public** — fictional lore.

            ## Job

            Every morning before stand-up, prepare the daily briefing: today's Forge build, the sprint's open question, who's available, and one thing that shipped yesterday.

            ## Schedule

            Daily, 30 minutes before the 11am stand-up.

            ## Inputs

            - The Forge morning build report (connections/the-forge.md).
            - Yesterday's sprint retro notes.

            ## Output

            A five-line briefing posted to the team channel, ending with the current fun-rating trend.

            ## Change Log

            - \(today) · v1.0.0 — demo content created
            """,

            // ── Evals ───────────────────────────────────────────────────────────
            "evals/recall-biscuits-toy.md": EvalCase.render(
                title: "Recall: Biscuit's favorite toy", name: "recall-biscuits-toy",
                designation: "Public", source: "memory/biscuit-favorite-toy.md",
                sourceVersion: "1.0.0", owner: owner, today: today,
                prompt: "Biscuit seems restless today. What would settle him? Answer from what you know about him.",
                expectation: "The agent recalls Biscuit's favorite toy — the squeaky carrot by the door — without being handed the file, and does not suggest the tennis ball.",
                mustContain: ["carrot"], mustNotContain: ["tennis ball"]),

            "evals/skill-plan-a-playtest.md": EvalCase.render(
                title: "Skill: plan a playtest ends with the demo reel",
                name: "skill-plan-a-playtest",
                designation: "Public", source: "skills/plan-a-playtest.md",
                sourceVersion: "1.0.0", owner: owner, today: today,
                prompt: "We have a new grapple prototype from this morning's build. Plan today's playtest.",
                expectation: "The plan assigns observation roles to named team members, uses only today's Forge build, and schedules the demo reel as the final item — per the skill's procedure.",
                mustContain: ["demo reel"]),
        ]
    }
}
