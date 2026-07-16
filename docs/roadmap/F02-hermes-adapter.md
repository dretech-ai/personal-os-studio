# F02 · Hermes harness adapter

**Theme:** Harness expansion · **Priority:** P2 · **Depends on:** F01 (adapter framework)

## Context

Personal OS Studio (macOS SwiftUI, `Sources/PersonalOSStudio/`, sibling canonical repo at
`../agent_os`) trains AI harnesses from canonical Agent OS Markdown. After F01, harnesses
plug in via the `HarnessAdapter` protocol (`Sources/PersonalOSStudio/Adapters/`), with
shared transform helpers in `AdapterHelpers.swift` and a generic `DirectoryPusher`.
`Harness.all` (`Models.swift`) already lists Hermes ("Markdown workspace agent") as
`.comingSoon`.

The transform is fully specified in **`../agent_os/adapters/hermes.md`** (v1.0.0, pinned to
Hermes Agent 2026.5.x, Nous Research). Read it first — it is the source of truth. Key facts:

- Hermes reads instruction files **directly from `~/.hermes/`** (not a `workspace/`
  subdir): `SOUL.md`, `AGENTS.md`, `MEMORY.md`, `USER.md`. Skills at
  `~/.hermes/skills/<name>/SKILL.md`; persistent memory entries at
  `~/.hermes/memories/<name>.md`.
- Identity→SOUL.md section renames are identical to OpenClaw's (Agent Identity→Agent,
  User Profile→User, Operating Principles→Principles, …; Change Log dropped) — reuse the
  rename table from `AdapterHelpers`.
- Context→AGENTS.md: same consolidation as OpenClaw (role→domain→team, per-file banner,
  "SOUL.md rules take precedence" preamble). Canonical *working memory* (if present)
  appends to AGENTS.md under `# Working memory` — never write into `~/.hermes/sessions/`.
- Memory: `memory/MEMORY.md` → `~/.hermes/MEMORY.md` (keep under 200 lines); persistent
  entries → `~/.hermes/memories/<name>.md` with the `description` field preserved (it's the
  recall hook).
- Frontmatter: strip; preserve designation/owner/version/last_reviewed as one HTML comment.
- PII: the whole `~/.hermes/` tree is PII. After push, tighten permissions:
  `chmod 700 ~/.hermes`, `chmod 600` on SOUL.md/AGENTS.md (and .env if present).
- Health signal: the Hermes dashboard binds loopback `http://127.0.0.1:9119/` when running;
  treat reachable = healthy, else "not running" (Hermes has no launchd auto-start).

## Goal

Implement `HermesAdapter` so the Hermes harness row becomes active: select canonical files,
train, preview the exact `~/.hermes/*` artifacts, and push into `~/.hermes/` with backups
and permission tightening — mirroring the OpenClaw experience.

## Requirements

1. `HermesAdapter: HarnessAdapter` producing artifacts with relative paths `SOUL.md`,
   `AGENTS.md`, `MEMORY.md`, `memories/<name>.md`, `skills/<name>/SKILL.md`, per the spec's
   mapping tables (including the skill frontmatter: `name` + `description` from the first
   sentence of `## Trigger`).
2. Delivery: `.directory` targeting `~/.hermes/` (expand tilde; validate the directory
   exists — if missing, surface "Hermes not installed" guidance with the install reference
   from the spec rather than creating the tree).
3. Post-push action: run `chmod 700 ~/.hermes` and `chmod 600` on the written instruction
   files (use the existing process-runner helper). Report in the push log.
4. Health check: GET `http://127.0.0.1:9119/` with a short timeout → healthy/down badge in
   the panel (label it "Hermes dashboard").
5. Respect the shared contract (`adapters/README.md`): banners preserved, load order,
   Change Log/Examples/Test Plan/Evolution Notes dropped, provenance comment at top.
6. Flip Hermes to active by registering the adapter in `AppState.adapters` — no changes to
   `RootView`/`BuildPushPanel` should be needed if F01 landed correctly.
7. Extend `SelfTest` with a Hermes assertion: with examples enabled, the build produces a
   SOUL.md whose sections match the rename table, and MEMORY.md ≤ 200 lines (add to
   `--selftest` or a `--hermestest` flag; either is fine, document the choice).

## Files

Create:
- `Sources/PersonalOSStudio/Adapters/HermesAdapter.swift`

Modify:
- `Sources/PersonalOSStudio/PersonalOSStudioApp.swift` (register adapter)
- `Sources/PersonalOSStudio/Models.swift` (only if status derivation needs the new id)
- `Sources/PersonalOSStudio/SelfTest.swift` (headless assertion)

## Architecture constraints

- Reuse `AdapterHelpers` (rename tables, banner/provenance/firstSentence) and
  `DirectoryPusher` from F01 — do not duplicate transform code from `OpenClawAdapter`.
- Reuse `Frontmatter.split` / `MarkdownSections.parse`; `BuildArtifact`/`BuildResult` as-is.
- Never write outside `~/.hermes/`; never touch `~/.hermes/sessions/` or `config.yaml`
  (config is user-owned; the spec's model/auth notes are docs-only for this feature).
- `rtk` prefix for shell; no new dependencies.

## Acceptance criteria

- [ ] Hermes row is active; full train→preview→push flow works against a real or scratch
      `~/.hermes/` directory.
- [ ] Artifacts match the spec's mapping tables (spot-check SOUL.md section names, skill
      frontmatter shape, provenance comments).
- [ ] Push creates `.bak-studio` backups for existing files and tightens permissions;
      push log records both.
- [ ] Missing `~/.hermes/` produces guidance, not a crash or empty push.
- [ ] OpenClaw flow unchanged; `--selftest` still exits 0.

## Verification

1. `swift build` clean; headless Hermes assertion exits 0 from `../agent_os`.
2. Create a scratch home: `mkdir -p /tmp/hermes-test && HOME=/tmp/hermes-test` variant or
   point the target picker at a scratch dir if the adapter exposes one for testing; push;
   inspect files + `stat -f "%Lp"` permissions (700/600).
3. If Hermes is installed: start `hermes dashboard --port 9119 --host 127.0.0.1 --tui
   --no-open`, confirm the health badge goes green; push real artifacts; start a session
   and confirm the agent reflects SOUL.md identity.
