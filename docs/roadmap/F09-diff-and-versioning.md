# F09 · Diff preview & version management

**Theme:** Document quality & safety · **Priority:** P2 · **Depends on:** — (F06 refine flow consumes the version helper if both land)

## Context

Personal OS Studio overwrites files at two seams, both currently sight-unseen:

1. **Interview save** — `InterviewView.save()` writes the generated draft via
   `CanonicalStore.createFile(relativePath:contents:)`; the save sheet shows a one-line
   "will be overwritten" warning when `store.fileExists(relativePath:)`, but never *what*
   changes.
2. **Workspace push** — `OpenClawService.push(_:to:backup:)` writes `BuildArtifact`s over
   existing workspace files (`.bak-studio` backups optional). The user can preview an
   artifact's full text (`ArtifactPreviewSheet` in `Views/BuildPushPanel.swift`) but not
   how it differs from what's deployed — so "what will this push actually change?" is
   unanswerable, which matters because pushes reconfigure a live agent.

Versioning is likewise manual: canonical frontmatter carries semver `version` +
`last_reviewed`, and templates end with `## Change Log`, but nothing in the app bumps or
checks them on hand-edits (`EditorPane.save` writes exactly what's in the text view).

Plumbing available: `Frontmatter.split` (fields/body), `MarkdownSections.parse`,
`CanonicalStore.read/write`, `BuildResult`/`BuildArtifact`, the sheet patterns in
`BuildPushPanel`/`InterviewView`.

## Goal

Every overwrite becomes inspectable: a unified line-diff preview at both seams before
writing, plus a version helper that (a) offers a bump + Change Log entry when hand-editing
a canonical doc, and (b) flags pushes whose canonical sources changed without a version
bump.

## Requirements

1. `Diff/LineDiff.swift`: a small LCS-based line differ producing hunks
   (`equal/insert/delete` runs with line numbers) — pure Swift, no dependency; fine to
   keep O(n·m) given file sizes (< a few thousand lines).
2. `DiffView` (SwiftUI): unified diff rendering — context collapsed to ±3 lines around
   changes, insertions green-tinted, deletions red-tinted, monospaced (match
   `ArtifactPreviewSheet` styling); a "no changes" state.
3. **Interview save seam:** when the target path exists, the save sheet gains a
   "Review changes" disclosure showing `DiffView(old: store contents, new: draft)` before
   Save is confirmed.
4. **Push seam:** in `BuildPushPanel`, each artifact row whose destination file exists in
   the selected workspace gets a diff affordance (button or the preview sheet gains a
   Diff tab): `DiffView(old: workspace file, new: artifact.contents)`. The push
   confirmation dialog summarizes: "3 files change (+42 −7), 2 new, 1 unchanged" —
   unchanged artifacts may be skipped on push (log "unchanged, skipped").
5. **Version helper (`Versioning.swift`):** parse/bump/compare semver;
   `suggestBump(old:new:) -> patch|minor` (heuristic: any H2 section added/removed/
   retitled → minor, else patch). In `EditorPane.save`, if the buffer's *body* changed but
   frontmatter `version` didn't, offer a non-blocking prompt: "Bump to X.Y.Z and add a
   Change Log entry?" — accepting rewrites frontmatter `version`, `last_reviewed` (today),
   and appends `- <today> · v<new> — <user-entered one-liner>` to `## Change Log` (create
   the section only if the layer's template has it).
6. **Push staleness flag:** when building, if a canonical source file's `version` equals
   the version recorded in the deployed artifact's provenance comment
   (`provenanceComment` embeds `version:`) *but* content differs, add a
   `BuildResult.warnings` note ("identity.md changed without a version bump").
7. All prompts skippable — never hard-block a save or push.

## Files

Create:
- `Sources/PersonalOSStudio/Diff/LineDiff.swift`
- `Sources/PersonalOSStudio/Diff/DiffView.swift`
- `Sources/PersonalOSStudio/Diff/Versioning.swift`

Modify:
- `Sources/PersonalOSStudio/Views/InterviewView.swift` (save-sheet diff disclosure)
- `Sources/PersonalOSStudio/Views/BuildPushPanel.swift` (artifact diff, push summary,
  skip-unchanged)
- `Sources/PersonalOSStudio/OpenClawService.swift` (skip-unchanged support in push)
- `Sources/PersonalOSStudio/Views/EditorPane.swift` (bump prompt on save)
- `Sources/PersonalOSStudio/OpenClawAdapter.swift` (staleness warning — read deployed
  provenance)

## Architecture constraints

- The differ and version helpers are pure value types with no UI/IO — separately testable
  via a headless flag or assertions in `SelfTest`.
- Read deployed files for diffing at render time (workspace may be on an external drive —
  handle missing/unmounted gracefully: "deployed copy unavailable").
- Reuse `Frontmatter` for version reads/writes — rewrite frontmatter by targeted line
  replacement to preserve field order/comments, not by re-serializing.
- `rtk` prefix; no new dependencies; sheets follow the existing `@State`-driven pattern.

## Acceptance criteria

- [ ] Interview re-save over an existing doc shows an accurate unified diff before writing.
- [ ] Push over a populated workspace shows per-artifact diffs and the correct
      changed/new/unchanged summary; unchanged files skipped and logged.
- [ ] Hand-edit + save without bumping → prompt appears; accepting yields correct semver
      bump, today's `last_reviewed`, appended Change Log line; declining saves untouched.
- [ ] Canonical change without a bump surfaces the staleness warning at build time.
- [ ] Differ correctness spot-checks: empty→text, text→empty, identical, single-line edit,
      section reorder (all verified headlessly).
- [ ] `--selftest` / `--interviewtest` unchanged.

## Verification

1. `swift build` clean; headless differ assertions exit 0.
2. Live drive: interview-save over an existing identity (view diff), push to a scratch
   workspace twice (second push reports all-unchanged), hand-edit a doc and accept the
   bump prompt, then `rtk git diff` the canonical repo to confirm frontmatter + Change Log
   edits are surgical.
