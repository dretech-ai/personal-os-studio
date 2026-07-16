# F01 · Adapter framework — pluggable harness pipeline

**Theme:** Harness expansion · **Priority:** P1 · **Depends on:** — (unblocks F02, F03, F04)

## Context

Personal OS Studio is a native macOS SwiftUI app (Swift Package, `Sources/PersonalOSStudio/`,
macOS 14+, no Xcode project — build with `swift build`, bundle with `./build-app.sh`). It
transforms canonical Agent OS Markdown from a sibling repo (`../agent_os`) into the files an
AI harness reads at session start, then pushes them to that harness.

Today the pipeline is hard-wired to one harness:

- `OpenClawAdapter.swift` — the only adapter; a struct with `build() -> BuildResult` that
  reads included files from `CanonicalStore` and emits `BuildArtifact` values (relativePath,
  contents, sourceDescription, designation).
- `OpenClawService.swift` — workspace discovery under `an external-volume path`, gateway
  health via `curl http://127.0.0.1:18789/healthz`, `push(_:to:backup:)` writing artifacts
  with `.bak-studio` backups, and a docker-container restart.
- `Views/BuildPushPanel.swift` — the right-hand pane: target picker → "Train from
  canonical" → artifact list/preview → push → restart.
- `Models.swift` — `Harness.all` lists OpenClaw (`.active`) plus Hermes, Claude Cowork, and
  OpenAI Codex flagged `.comingSoon`; `RootView` shows `ComingSoonView` for those.
- `AppState.rebuild()` calls `OpenClawAdapter(store:).build()` directly.

The canonical repo documents each harness's transform in `agent_os/adapters/*.md` with a
shared contract (`agent_os/adapters/README.md`): preserve classification banners, map H2
sections by exact name, strip frontmatter into a provenance HTML comment, fixed layer load
order, truncation rules. The OpenClaw adapter implements `openclaw.md`; F02–F04 will
implement `hermes.md`, `claude-cowork.md`, `codex.md`. **Crucially, harnesses differ in push
mechanics:** OpenClaw/Hermes write files into a directory; Codex writes into a chosen git
repo root + `~/.codex/skills/`; Claude Cowork has *no file surface at all* — its artifacts
are paste-ready blocks for UI fields.

## Goal

Extract a harness-agnostic adapter framework so each harness plugs in one type: a
`HarnessAdapter` implementation describing what it builds and how it delivers. The
build/preview/push UI becomes generic, `OpenClawAdapter` becomes the first plug-in with
zero behavior change, and activating a new harness = adding one adapter file.

## Requirements

1. A `HarnessAdapter` protocol in a new `Sources/PersonalOSStudio/Adapters/` directory,
   roughly:
   - `var harnessID: String` (matches `Harness.id`),
   - `func build(from store: CanonicalStore) -> BuildResult`,
   - `var delivery: DeliveryKind` where `DeliveryKind` is an enum:
     `.directory(DirectoryDelivery)` (target discovery + write + optional post-push action
     + optional health check) or `.clipboard([PasteTarget])` (named paste blocks, e.g.
     "Global instructions", "Folder instructions").
2. Move the generic pieces of `OpenClawService` (artifact writing with backups, process
   runner, push log) into a reusable `DirectoryPusher`; keep OpenClaw-specific pieces
   (workspace discovery, `healthz`, docker restart) in an OpenClaw adapter/delivery type.
3. Refactor `OpenClawAdapter` to conform to `HarnessAdapter` with **byte-identical
   artifacts** for the same inputs (assert via `--selftest` output comparison).
4. `AppState` holds `adapters: [String: HarnessAdapter]` keyed by harness id; `rebuild()`
   dispatches on `selectedHarness`. `BuildPushPanel` renders from the selected adapter's
   `delivery` (directory targets + push button vs. copy-block list).
5. A shared `AdapterHelpers` (or similar) exposing the transform utilities currently
   private to `OpenClawAdapter` — `bannerOrDefault`, `firstBlockquoteLine`,
   `provenanceComment`, `firstSentence`, section-rename tables — so F02–F04 don't
   re-implement them. Layer ordering rules (role→domain→team, skills alphabetical, memory
   user→feedback→project→reference) live here too.
6. `Harness.status` stays data-driven: a harness with a registered adapter renders the
   full train/push UI; unregistered ones keep `ComingSoonView`. Don't flip Hermes/Cowork/
   Codex to active in this feature.
7. `SelfTest.run()` keeps working unchanged (it exercises the OpenClaw path).

## Files

Modify:
- `Sources/PersonalOSStudio/OpenClawAdapter.swift` (conform; extract shared helpers)
- `Sources/PersonalOSStudio/OpenClawService.swift` (split generic vs OpenClaw-specific)
- `Sources/PersonalOSStudio/Views/BuildPushPanel.swift` (render from adapter description)
- `Sources/PersonalOSStudio/PersonalOSStudioApp.swift` (`AppState.adapters`, dispatch)
- `Sources/PersonalOSStudio/Models.swift` (derive active status from registration)

Create:
- `Sources/PersonalOSStudio/Adapters/HarnessAdapter.swift` (protocol + DeliveryKind)
- `Sources/PersonalOSStudio/Adapters/AdapterHelpers.swift` (shared transforms)
- `Sources/PersonalOSStudio/Adapters/DirectoryPusher.swift` (generic write/backup/log)

## Architecture constraints

- Reuse `Frontmatter.split` / `MarkdownSections.parse` (`Frontmatter.swift`) — never
  re-parse Markdown ad hoc.
- Keep `BuildArtifact` / `BuildResult` (`Models.swift`) as the universal artifact currency;
  extend rather than replace.
- UI state stays in `@MainActor ObservableObject`s observed directly (the codebase pattern:
  pass `@ObservedObject` into sheets, don't rely on nested-object republishing).
- No new dependencies; Foundation + SwiftUI only. Prefix all shell commands with `rtk`.

## Acceptance criteria

- [ ] `swift build` clean; no behavior change for OpenClaw: same artifacts, same push flow.
- [ ] `--selftest` (run from `../agent_os`) output identical before/after (diff the
      artifact sections).
- [ ] Adding a stub adapter (test-only) with `delivery: .clipboard` renders a copy-block
      panel without touching `BuildPushPanel` internals.
- [ ] `OpenClawAdapter` contains only OpenClaw-specific mapping; shared transform helpers
      live in `Adapters/AdapterHelpers.swift`.

## Verification

1. `swift build` → clean.
2. `cd ../agent_os && /path/to/.build/debug/PersonalOSStudio --selftest` → exit 0, artifact
   bytes identical to pre-refactor run (capture both to files and `diff`).
3. Launch the app: OpenClaw harness trains, previews, and pushes exactly as before
   (including backups and gateway restart).
4. Hermes/Cowork/Codex rows still show "Coming soon".
