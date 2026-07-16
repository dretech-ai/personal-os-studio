# F04 · OpenAI Codex harness adapter

**Theme:** Harness expansion · **Priority:** P2 · **Depends on:** F01 (adapter framework)

## Context

Personal OS Studio (macOS SwiftUI, `Sources/PersonalOSStudio/`, canonical repo at
`../agent_os`) plugs harnesses in via `HarnessAdapter` (F01). `Harness.all`
(`Models.swift`) lists OpenAI Codex ("Codex CLI · AGENTS.md") as `.comingSoon`.

The transform is specified in **`../agent_os/adapters/codex.md`** (v1.1.0, pinned to Codex
CLI 0.133.0). Read it first — v1.1.0 contains an important empirical correction. Key facts:

- **Single instruction file, repo-scoped by design.** Codex reads `AGENTS.md` files from
  CWD upward, stopping at the **git repo root**. There is no user-level always-on file
  (`~/.codex/AGENTS.md` is NOT read — that was the 1.0.0 error). The adapter therefore
  concatenates Identity + Context (+ optional active agent job) into **one `AGENTS.md`**
  pushed to a user-chosen git repo root.
- AGENTS.md layout (spec's "Load order" block): provenance comment, classification banner,
  preamble "*Identity rules below take precedence over Context and any nested AGENTS.md.*",
  renamed Identity H2s (Agent/User/Principles/Boundaries/Style/Output/Escalation), `---`,
  then `# Role context` etc.
- High-signal persistent memory inlines into AGENTS.md (user → Identity section area,
  feedback → Principles area or `## Feedback`, project → project-specific AGENTS.md);
  working memory skipped. There is no MEMORY.md surface — Codex state is SQLite-backed.
- **Skills are first-class:** `scope: personal` → `~/.codex/skills/<name>/SKILL.md` with
  frontmatter `name`, `description` (first sentence of `## Trigger`), and
  `metadata.short-description`; body = banner + Inputs/Procedure/Output; authoring
  sections dropped.
- PII: rendered AGENTS.md is PII — after writing, offer to add `/AGENTS.md` to the repo's
  `.git/info/exclude` (per-clone, not the shared `.gitignore`; the spec explains why).
- Detection: `codex` binary on PATH (`/opt/homebrew/bin/codex` or npm prefix);
  `~/.codex/` home. `codex --version` for a health/presence string.

## Goal

Implement `CodexAdapter`: train once, preview the concatenated AGENTS.md and the SKILL.md
set, then push — AGENTS.md into a user-picked git repo root (with the exclude-file
safeguard) and skills into `~/.codex/skills/` — activating the Codex harness row.

## Requirements

1. `CodexAdapter: HarnessAdapter` building: one `AGENTS.md` artifact per the spec's layout
   (Identity + Context ordered role→domain→team + optional agent job + inlined
   user/feedback persistent entries), and one `skills/<name>/SKILL.md` artifact per
   included personal-scope skill with the Codex frontmatter shape.
2. Delivery: `.directory` with **two targets** — F01's delivery model must support a
   split push:
   - AGENTS.md → a git repo root chosen via folder picker (validate `.git` exists at the
     chosen path; persist the last choice in UserDefaults).
   - Skills → `~/.codex/skills/` (create subdirs; back up existing SKILL.md with
     `.bak-studio` like the OpenClaw pusher).
   If F01's `DirectoryDelivery` only supports one root, extend it minimally (e.g. artifacts
   carry a target key) — keep OpenClaw/Hermes unaffected.
3. Post-push: append `/AGENTS.md` to `<repo>/.git/info/exclude` if not already present
   (idempotent); log it. Never touch the repo's tracked `.gitignore`.
4. Detection/health: PATH lookup for `codex` + `~/.codex/` existence; run
   `codex --version` via the process-runner for the badge text. Missing binary → guidance
   (brew/npm install lines from the spec), not a crash.
5. Contract compliance (`adapters/README.md`): banners, provenance comment, truncation
   order, aim < 3,000 words for AGENTS.md (warn in `BuildResult.warnings` if over).
6. Register the adapter; row activates. Headless assertion (extend `--selftest` or add a
   flag): AGENTS.md contains the preamble line, renamed sections, and role-before-domain
   ordering with the example set.

## Files

Create:
- `Sources/PersonalOSStudio/Adapters/CodexAdapter.swift`

Modify:
- `Sources/PersonalOSStudio/Adapters/HarnessAdapter.swift` /
  `Sources/PersonalOSStudio/Adapters/DirectoryPusher.swift` (only if split-target push
  needs a minimal extension)
- `Sources/PersonalOSStudio/PersonalOSStudioApp.swift` (register)
- `Sources/PersonalOSStudio/SelfTest.swift` (assertion)

## Architecture constraints

- Reuse `AdapterHelpers` (renames, banner, provenance, firstSentence, ordering) and the
  generic pusher; `Frontmatter`/`MarkdownSections` for parsing.
- Folder picker: `NSOpenPanel` (directories only) — first use in this codebase, keep it in
  the view layer, not the adapter.
- Never write into `~/.codex/` beyond `skills/`; never edit `config.toml`/`auth.json`
  (MCP/plugin config is out of scope — F12 territory and Codex-owned).
- `rtk` shell prefix; no new dependencies.

## Acceptance criteria

- [ ] Codex row active; train → preview shows one AGENTS.md + N SKILL.md artifacts.
- [ ] Push writes AGENTS.md to the chosen repo root, appends the exclude entry once, and
      writes skills under `~/.codex/skills/` with backups; push log covers all three.
- [ ] Choosing a non-git folder is rejected with clear guidance.
- [ ] AGENTS.md matches the spec layout (preamble precedence line, section order,
      < 3,000-word warning path works).
- [ ] OpenClaw/Hermes unchanged; `--selftest` exits 0.

## Verification

1. `swift build` clean; headless assertion exits 0 from `../agent_os`.
2. Scratch test: `git init /tmp/codex-repo`, push there, verify `/tmp/codex-repo/AGENTS.md`,
   `cat /tmp/codex-repo/.git/info/exclude` contains `/AGENTS.md`, re-push doesn't duplicate
   the exclude line.
3. If Codex is installed: `cd /tmp/codex-repo && codex exec "who am I to you?"` — the
   response should reflect the pushed identity (preferred name, principles).
