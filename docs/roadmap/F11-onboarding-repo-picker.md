# F11 · Onboarding & repo picker

**Theme:** Operations & lifecycle · **Priority:** P1 · **Depends on:** —

> **Partially delivered:** the OpenClaw half (user-configured state dir / gateway URL /
> container name via `OpenClawSettings` + `OpenClawSettingsView`, detect-and-suggest,
> honest unconfigured states) shipped separately. Remaining scope here is the
> **canonical repo** onboarding: first-run picker, scaffold-new-repo, and removing the
> canonical-path fallback in `AppState.init`.

## Context

Personal OS Studio hardcodes its two anchor paths in `AppState.init`
(`Sources/PersonalOSStudio/PersonalOSStudioApp.swift`):

- **Canonical repo:** tries the current working directory, then the literal
  `~/code/agent_os`, validated by
  `CanonicalStore.isValidRoot` (an `adapters/` dir exists). When launched from Finder
  (CWD = `/`), only the hardcoded fallback works — on any other machine or checkout
  location the app opens invalid with no recovery path in the UI.
- **OpenClaw state dir:** literal `an external-volume path`
  (`OpenClawService(stateDir:)` discovers `workspace*/` under it). If the external drive
  isn't mounted, the build panel shows "No OpenClaw workspaces found" with no way to
  repoint.

There is no first-run experience: a new user (or a fresh machine) gets an app pointed at
paths that don't exist, and no way to create a canonical repo from scratch even though the
app knows every template. The sidebar "Source repo" row (`Views/RootView.swift`) displays
`store.rootURL` but is inert.

Plumbing available: `CanonicalStore.setRoot(_:)` already re-roots and reloads;
`OpenClawService` takes `stateDir` at init and has `discoverWorkspaces()`;
`Harness`/`RootView` render per-harness; UserDefaults persistence patterns exist
(`LLMSettings`, `personName`); templates for scaffolding live in the canonical repo
itself — but for *creating* a repo from nothing, the skeleton (layer dirs +
`adapters/`, `validation/`, template files) must come from a bundled resource or a
minimal built-in set (decide during implementation; bundling a snapshot of the template
files via `build-app.sh` into `Contents/Resources/` is acceptable).

## Goal

First-run onboarding plus always-available repointing: pick (or scaffold) the canonical
repo and set the OpenClaw state dir through the UI, with choices persisted and validated —
no hardcoded user-specific paths left in the code.

## Requirements

1. **Path resolution order** (replacing the hardcoded logic): UserDefaults-persisted
   choice → CWD if `isValidRoot` → no fallback. Same for the state dir (persisted →
   `an external-volume path` if it exists → unset). Remove the   hardcoded home-directory literal entirely.
2. **First-run/invalid-state onboarding sheet** (blocking until resolved or skipped):
   shown when no valid canonical root resolves. Steps:
   - Welcome + one-paragraph explanation of canonical repo vs harness workspaces.
   - Canonical repo: "Choose existing…" (`NSOpenPanel`, directories) with live
     `isValidRoot` validation feedback, or "Create new…" → pick a parent folder + name,
     scaffold the skeleton (layer dirs, bundled templates, `adapters/` +
     `validation/` docs if bundled; plus a `.gitignore` seeded for PII hygiene), then
     `git init` it (via the process runner; skip silently if git absent).
   - OpenClaw state dir (optional step, skippable): choose the dir; show discovered
     workspace count live.
3. **Settings surface afterwards:** the sidebar "Source repo" row becomes a button
   (hover affordance) opening the same picker; add a small "state dir" affordance near
   the gateway badge or in the build panel's empty state ("No workspaces — change
   location…"). Both persist and take effect immediately (`store.setRoot`, recreate/
   re-point `OpenClawService`).
4. `OpenClawService` must support re-pointing at runtime (either a `setStateDir` that
   re-discovers, or `AppState` swaps the instance and re-publishes — pick one; views
   observe through `AppState` today via direct reads, so re-creation needs `@Published`
   propagation to hold).
5. Launch-time flags (`--selftest`, `--interviewtest`, and F08's `--validate` if present)
   keep using CWD and must not trigger onboarding UI (they run before any window).
6. Handle mid-session invalidation: external drive unmount just degrades (existing
   behavior); canonical root deletion → next reload shows the onboarding sheet.

## Files

Modify:
- `Sources/PersonalOSStudio/PersonalOSStudioApp.swift` (resolution order, persistence,
  onboarding presentation state)
- `Sources/PersonalOSStudio/CanonicalStore.swift` (only if `setRoot` needs hardening)
- `Sources/PersonalOSStudio/OpenClawService.swift` (runtime re-point)
- `Sources/PersonalOSStudio/Views/RootView.swift` (source-repo row → button; state-dir
  affordance)
- `Sources/PersonalOSStudio/Views/BuildPushPanel.swift` (empty-state "change location…")
- `build-app.sh` (bundle template skeleton into Resources, if that route is chosen)

Create:
- `Sources/PersonalOSStudio/Views/OnboardingView.swift`
- `Sources/PersonalOSStudio/Scaffold.swift` (skeleton creation: dirs + templates +
  .gitignore + optional git init)

## Architecture constraints

- Persist paths as security-scope-free absolute paths in UserDefaults (the app is not
  sandboxed — `build-app.sh` does ad-hoc signing, no entitlements; do not introduce
  sandboxing).
- `NSOpenPanel` usage stays in the view layer. Scaffolding is pure FileManager work in
  `Scaffold.swift`, testable headlessly.
- Never overwrite an existing non-empty directory when scaffolding; validate emptiness
  first.
- Keep fresh-install semantics from v1: scaffolded repos start with templates only, no
  sample/example content.
- `rtk` prefix in docs/verification; in-app process calls invoke binaries directly.

## Acceptance criteria

- [ ] Zero hardcoded user-specific paths remain (`grep -rn "dretech" Sources/` returns
      nothing path-like outside comments).
- [ ] Launch from Finder with no persisted choice on a machine layout without the old
      paths → onboarding appears; choosing `../agent_os` lands a working app; choice
      survives relaunch.
- [ ] "Create new…" scaffolds a repo that `isValidRoot` accepts, the browser shows empty
      layers with templates available to the interview, and (git present) `git log`
      shows an init commit or clean init state.
- [ ] Repointing the state dir live updates workspace discovery without relaunch.
- [ ] `--selftest`/`--interviewtest` from `../agent_os` unchanged (exit 0, no UI).
- [ ] Existing users (valid persisted/CWD path) never see onboarding.

## Verification

1. `swift build` clean; headless flags exit 0.
2. `defaults delete com.dretech.PersonalOSStudio` (scratch the persisted state), launch
   from Finder → onboarding; walk both paths (choose-existing and create-new into
   `/tmp/fresh_os`); relaunch to confirm persistence.
3. Run the interview against the scaffolded repo → identity generates and saves.
4. Unmount-simulation: point state dir at a nonexistent path → build panel guidance +
   "change location…" works.
