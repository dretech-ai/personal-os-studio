# Personal OS Studio — Feature Roadmap

This roadmap was produced by evaluating the application end-to-end after the v1 delivery
(PR #1). Each feature has a **self-sufficient implementation prompt** in this directory —
written so a future Claude Code session can implement the feature from the prompt alone —
and a matching GitHub Issue for tracking.

## Where the app stands (evaluation summary)

**Delivered in v1:**

| Capability | Where |
|---|---|
| Browse & edit canonical Agent OS Markdown by layer | `CanonicalStore`, `Views/OpenClawView.swift`, `Views/EditorPane.swift` |
| Train the OpenClaw harness (Identity→SOUL.md, Context→AGENTS.md, Skills, Memory) | `OpenClawAdapter.swift` implementing `agent_os/adapters/openclaw.md` |
| Preview artifacts, push to workspace with backups, restart gateway, health check | `Views/BuildPushPanel.swift`, `OpenClawService.swift` |
| LLM provider selection — local Ollama or OpenAI / Perplexity / Anthropic by API key (Keychain) | `LLM/` |
| Agent interview — guided authoring of the trainable canonical docs, name auto-capture | `Interview/`, `Views/InterviewView.swift` |
| Fresh-install hygiene (no sample data, no template duplicates), headless self-tests | `CanonicalStore`, `SelfTest.swift` |

**Structural gaps this roadmap addresses:**

1. Three harnesses are advertised as "Coming soon" (`Harness.all` in `Models.swift`) with
   written adapter specs already in `agent_os/adapters/` — but only OpenClaw is implemented,
   and its pipeline is hard-wired to one harness.
2. The interview authors one doc at a time, can't refine an existing doc, and blocks on
   full responses (no streaming).
3. Nothing validates canonical docs, previews a diff before overwriting, or manages
   versions/change logs — despite `agent_os/validation/*-checklist.md` defining the rules.
4. Operations gaps: hardcoded paths in `AppState.init`, no first-run onboarding, no git
   awareness for the canonical repo, and connections remain a "configure manually" warning.

## The feature set

| ID | Feature | Theme | Priority | Depends on | Issue |
|----|---------|-------|----------|------------|-------|
| [F01](F01-adapter-framework.md) | Adapter framework — pluggable harness pipeline | Harness | P1 | — | #2 |
| [F02](F02-hermes-adapter.md) | Hermes harness adapter | Harness | P2 | F01 | #3 |
| [F03](F03-claude-cowork-adapter.md) | Claude Cowork harness adapter (paste-based) | Harness | P3 | F01 | #4 |
| [F04](F04-codex-adapter.md) | OpenAI Codex harness adapter | Harness | P2 | F01 | #5 |
| [F05](F05-bootstrap-wizard.md) | Personal-OS bootstrap wizard (multi-doc interview) | Interview | P2 | — | #6 |
| [F06](F06-refine-by-interview.md) | Refine existing docs by interview | Interview | P3 | — | #7 |
| [F07](F07-streaming-llm.md) | Streaming LLM responses + provider polish | Interview | P3 | — | #8 |
| [F08](F08-validation-engine.md) | Validation engine (checklists as code) | Quality | P1 | — | #9 |
| [F09](F09-diff-and-versioning.md) | Diff preview & version management | Quality | P2 | — | #10 |
| [F10](F10-git-integration.md) | Canonical repo git integration | Ops | P3 | — | #11 |
| [F11](F11-onboarding-repo-picker.md) | Onboarding & repo picker | Ops | P1 | — | #12 |
| [F12](F12-connections-manager.md) | Connections manager (openclaw.json) | Ops | P3 | — | #13 |
| [F13](F13-pii-vault.md) | PII vault — encrypted snapshots for the untracked layers | Ops | P1 | F10, F11 | #18 |
| [F14](F14-multi-document-layers.md) | Multi-document layers — instance-aware authoring | Interview | P2 | F08, F09 | #19 |
| [F15](F15-context-backfeed.md) | Context backfeed — harness drift becomes reviewed canonical proposals | Feedback loop | P1 | F01, F08, F09, F13 + LLM | #20 |
| [F16](F16-evals-layer.md) | Evals layer — measure the compiled spec, feed the signal back | Feedback loop | P1 | F07, F08, F15 + LLM | #23 |

Tracking milestone: Feature Roadmap v1.

_Issue numbers (#N) reference the project's original tracker where these features were built and reviewed._

**Suggested build order:** F01 → F08 → F11 (foundations) · F02/F04 + F09 + F05 (core value)
· F03 + F06 + F07 + F10 + F12 (completeness) · F13 (data protection, after F10/F11 land)
· F14 (multi-document authoring) · F15 (the loop's return arc — backfeed, shipped)
· F16 (evals — the loop becomes measurable).

## How to use a prompt

Open the feature's `FNN-*.md`, paste its full contents into a fresh Claude Code session
started in this repo, and say "implement this". Each prompt carries its own context,
requirements, file map, architecture constraints, acceptance criteria, and verification
steps — no other context needed. Standing conventions the prompts assume:

- Prefix shell commands with `rtk` (see `CLAUDE.md`).
- The canonical Agent OS repo is a sibling checkout at `../agent_os` (adapter specs in
  `agent_os/adapters/`, validation checklists in `agent_os/validation/`).
- Build with `swift build`; assemble the app with `./build-app.sh`; headless checks run
  from inside the canonical repo (`--selftest`, `--interviewtest`).
- Deliver on a feature branch via PR into `main`.
