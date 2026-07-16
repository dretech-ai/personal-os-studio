# F10 · Canonical repo git integration

**Theme:** Operations & lifecycle · **Priority:** P3 · **Depends on:** — (F09's diff view is reused if present)

## Context

Personal OS Studio edits the canonical Agent OS repo (`../agent_os`) — which **is a git
repository** — through `CanonicalStore.write/createFile`, but the app is git-blind: no
indication that a doc has uncommitted changes, no way to commit an authoring session, no
history view. Users must drop to a terminal to snapshot their personal OS, so in practice
edits accumulate uncommitted.

Sensitivities: canonical content is largely **PII** (identity/context/memory files carry
`designation: PII` and their banners say "do not commit to shared repositories"). Local
version control is exactly what you want (snapshots, rollback); *pushing to a remote* is
where leakage risk lives. The canonical repo may or may not have a remote; Studio must
never initiate network git operations.

Plumbing available: `OpenClawService.run(_:_:) async -> ProcResult` — a generic process
runner (launchPath + args → exitCode/stdout/stderr) that F01 may have moved to a shared
location; `CanonicalStore.rootURL`; the sidebar badge pattern (`LLMProviderBadge`,
`GatewayStatusBadge` in `Views/RootView.swift`); `EditorPane` header chips; per the repo
convention all *user-facing docs* say to prefix shell with `rtk`, but **in-app process
calls invoke `/usr/bin/git` directly** (rtk is a CLI-session concern, not an app runtime
concern).

## Goal

Local git awareness and snapshotting inside Studio: see per-file dirty state, stage-and-
commit from the app with a suggested message, browse a file's history and view old
versions — with remotes strictly hands-off (no push/pull/fetch ever).

## Requirements

1. `Git/GitService.swift` (`@MainActor ObservableObject`): wraps `/usr/bin/git -C
   <canonicalRoot>` via the process runner. Detect "is a repo" (`rev-parse
   --is-inside-work-tree`); expose:
   - `status()` → parsed `git status --porcelain=v1` (per-path state: modified/untracked/
     staged),
   - `commit(paths:[String], message:String)` → `git add -- <paths>` + `git commit -m`,
   - `history(path:) → [Commit]` via `git log --follow --format=%H%x09%ct%x09%s -- <path>`,
   - `show(commit:path:) → String` via `git show <hash>:<path>`,
   - graceful no-repo mode (all UI hidden).
2. **Browser dirty markers:** a subtle dot on `FileRow` for files with uncommitted changes
   (map porcelain paths → `CanonicalFile.url` relative paths); refresh on
   `CanonicalStore.reload()` and after saves.
3. **Commit UI:** a "Snapshot changes" sheet (entry: sidebar badge showing "N uncommitted
   change(s)", styled like `GatewayStatusBadge`): checklist of changed canonical files
   (default all checked), message field pre-filled with a generated summary ("Update
   identity.md, role.md"), Commit button. Commits run with the repo's own author config;
   if `user.name`/`user.email` are unset, surface git's error verbatim.
4. **History UI:** in `EditorPane`'s header, a History button → sheet listing the file's
   commits (relative date + subject); selecting one shows the old version read-only
   (monospaced, like `ArtifactPreviewSheet`) — and if F09 landed, a diff against the
   current buffer via `DiffView`.
5. **Remote guardrails:** never invoke push/pull/fetch/remote subcommands. If `git
   remote -v` is non-empty AND any PII-designated file is tracked, show a one-time
   advisory in the snapshot sheet ("This repo has a remote; canonical PII should not be
   pushed to shared remotes") — informational, not blocking.
6. All git calls async off the main thread (the runner already is); UI updates on main.
   Errors land in the sheet, never crash. Everything degrades cleanly when git is absent
   (env without CLT) or the root isn't a repo.

## Files

Create:
- `Sources/PersonalOSStudio/Git/GitService.swift`
- `Sources/PersonalOSStudio/Views/SnapshotSheet.swift`
- `Sources/PersonalOSStudio/Views/FileHistorySheet.swift`

Modify:
- `Sources/PersonalOSStudio/PersonalOSStudioApp.swift` (`AppState.git`, root wiring)
- `Sources/PersonalOSStudio/Views/RootView.swift` (snapshot badge)
- `Sources/PersonalOSStudio/Views/OpenClawView.swift` (dirty markers on `FileRow`)
- `Sources/PersonalOSStudio/Views/EditorPane.swift` (History button)

## Architecture constraints

- Porcelain parsing must handle renames (`R `), quoted paths with spaces, and untracked
  dirs; parse strictly, ignore what you don't recognize.
- No libgit2 or SPM dependencies — shell out to system git only.
- Observe `GitService` directly with `@ObservedObject` in sheets (established pattern).
- Never mutate git config; never create the repo (no `git init` — that's F11's scaffold
  concern if any).

## Acceptance criteria

- [ ] Editing a doc marks it dirty in the browser within one reload; snapshot sheet lists
      it; committing clears the marker and `git log` in a terminal shows the commit.
- [ ] Partial commit works (uncheck one file → it stays dirty).
- [ ] History on `identity/identity.md` lists real commits; viewing an old version renders
      its content (and diff, if F09 present).
- [ ] Non-repo canonical root: all git UI hidden, zero errors.
- [ ] No network git subprocess is ever spawned (audit `GitService` call sites).
- [ ] `--selftest` / `--interviewtest` unchanged.

## Verification

1. `swift build` clean.
2. Live: edit + save a doc → dirty dot; snapshot with default message; verify via
   `rtk git -C ../agent_os log --oneline -2` and clean status. Make two more edits,
   commit one, confirm split state.
3. History sheet vs `rtk git -C ../agent_os log --follow --oneline identity/identity.md`.
4. Point Studio at a non-git scratch canonical dir → git UI absent, app fully functional.
