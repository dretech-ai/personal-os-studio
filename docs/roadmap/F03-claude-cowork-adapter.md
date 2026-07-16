# F03 · Claude Cowork harness adapter (paste-based)

**Theme:** Harness expansion · **Priority:** P3 · **Depends on:** F01 (adapter framework)

## Context

Personal OS Studio (macOS SwiftUI, `Sources/PersonalOSStudio/`, canonical repo at
`../agent_os`) plugs harnesses in via `HarnessAdapter` (F01). `Harness.all`
(`Models.swift`) lists Claude Cowork ("Agentic mode in Claude Desktop") as `.comingSoon`.

The transform is specified in **`../agent_os/adapters/claude-cowork.md`** (v1.0.0, pinned
to Claude Desktop 1.8555.x with Cowork GA). Read it first. Cowork is structurally unlike
every other harness:

- **No file-based instruction discovery.** Cowork does not read SOUL.md/AGENTS.md/CLAUDE.md
  from disk. Its two instruction surfaces are UI fields in Claude Desktop:
  **Global instructions** (`Settings > Cowork > Global instructions`, applies everywhere)
  and **Folder instructions** (per Cowork Space).
- Identity → a paste-ready **Global instructions block** (same section renames as
  OpenClaw/Hermes; Change Log dropped; classification banner + provenance HTML comment on
  top — comments survive paste and Cowork ignores them at render time).
- Context (+ optional active agent job) → a paste-ready **Folder instructions block**
  (`# Role context` / `# Domain context` / `# Team context` sub-bullets per canonical H2).
- Skills: no native skills primitive — only inline a skill's `## Procedure` into a block
  when the user explicitly includes it (default off; the spec warns against bloating).
- Memory: `entry_type: user`/`feedback` entries may append to the Global block under
  `## Persistent facts`; `project` entries to the Folder block; working memory skipped.
- Enablement detection (read-only): Claude Desktop at `/Applications/Claude.app` and the
  marker `~/Library/Application Support/Claude/cowork-enabled-cli-ops.json`.
  **Never write** into `~/Library/Application Support/Claude/` — config paths are
  read-only for the adapter.
- Length: if a block is over-long, drop sections in the spec's order (Change Log → Style &
  Tone → Output Expectations → Escalation), never Classification/Agent Identity/
  Principles/Boundaries.

## Goal

Implement `CoworkAdapter` using F01's `.clipboard` delivery: training produces named
paste blocks ("Global instructions", "Folder instructions — <space>") with per-block copy
buttons and step-by-step paste guidance, activating the Claude Cowork harness row.

## Requirements

1. `CoworkAdapter: HarnessAdapter` building two artifacts (Global block from Identity
   [+ opted-in user/feedback memory], Folder block from Context [+ optional agent job,
   + opted-in project memory]) per the spec's mapping tables.
2. Delivery: `.clipboard` with `PasteTarget`s carrying: display name, the block contents,
   and ordered paste instructions (from the spec's "Configuration walkthrough": where to
   click in Claude Desktop, Save, no restart needed).
3. Detection: show an enablement badge — green when `/Applications/Claude.app` exists and
   the `cowork-enabled-cli-ops.json` marker is present; otherwise amber with "Cowork not
   detected" plus what to check. Pure filesystem reads.
4. Copy button per block (NSPasteboard, mirroring `ArtifactPreviewSheet`'s Copy). Mark the
   panel clearly: pushing means pasting — Studio cannot write Cowork's config.
5. A "sections dropped for length" note if the truncation order was applied (only apply it
   when a block exceeds a conservative threshold, e.g. 8,000 chars; the real limit is
   undocumented).
6. PII notice: pasted blocks are PII in Anthropic's app state — reuse the designation-tag
   styling for a warning row, and never include Connection secrets in blocks.
7. Register the adapter; the row activates via F01's data-driven status.

## Files

Create:
- `Sources/PersonalOSStudio/Adapters/CoworkAdapter.swift`

Modify:
- `Sources/PersonalOSStudio/PersonalOSStudioApp.swift` (register)
- `Sources/PersonalOSStudio/Views/BuildPushPanel.swift` (only if F01's clipboard rendering
  needs the per-block instructions UI added)

## Architecture constraints

- Reuse `AdapterHelpers` renames/banner/provenance; `Frontmatter`/`MarkdownSections` for
  parsing; `BuildArtifact` for blocks (relativePath doubles as the block name).
- Strictly read-only against `~/Library/Application Support/Claude/`.
- `@MainActor ObservableObject` state patterns; `rtk` shell prefix; no new dependencies.

## Acceptance criteria

- [ ] Cowork row active; training renders two named blocks with working Copy buttons and
      numbered paste instructions.
- [ ] Blocks match the spec (banner first, provenance comment, renamed H2s, dropped
      authoring sections; Folder block ordered role→domain→team→agent).
- [ ] Enablement badge reflects real filesystem state on this machine.
- [ ] Length-pressure path drops sections in spec order and says so.
- [ ] OpenClaw and any other registered harnesses unchanged; `--selftest` exits 0.

## Verification

1. `swift build` clean; launch, select Claude Cowork, train with the example set (enable
   examples in a scratch canonical checkout if no personal content), inspect both blocks.
2. Copy each block; paste into TextEdit to confirm clipboard integrity (banner + comment
   intact).
3. If Claude Desktop with Cowork is available: paste Block 1 into Global instructions,
   Block 2 into a test Space's Folder instructions, start a Cowork session, and confirm
   the persona/context land (first reply reflects principles + role).
