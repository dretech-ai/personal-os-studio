# F06 · Refine existing docs by interview

**Theme:** Interview & LLM · **Priority:** P3 · **Depends on:** — (pairs well with F09 diff preview)

## Context

Personal OS Studio's interview (`Sources/PersonalOSStudio/Interview/`,
`Views/InterviewView.swift`) only **creates** canonical docs from templates
(`InterviewTarget` wraps a `*.template.md`; `InterviewEngine` quizzes per H2 section and
generates a fresh file). Once a doc exists (e.g. `identity/identity.md` authored via the
interview), the only way to change it is hand-editing in `EditorPane`.

Canonical docs are versioned artifacts: frontmatter carries `version` (semver) and
`last_reviewed`; most templates end with a `## Change Log` section (see
`../agent_os/identity/identity.template.md`), and the validation checklists
(`../agent_os/validation/*.md`) require the Change Log to reflect the current version.
Today the interview's draft instruction pins `version: 0.1.0` — right for creation, wrong
for updates.

Reusable plumbing: `CanonicalStore.read/write/file(atRelativePath:)`,
`Frontmatter.split` (fields + body), `MarkdownSections.parse` (H2 sections),
`InterviewEngine`'s phases + prompt-builder structure, `LLMSettings.makeProvider()`,
`AppState.personName`.

## Goal

A "Refine" flow: pick an existing canonical doc, the agent reads it and asks *delta*
questions ("Your identity says X — still true? What's changed?"), then regenerates the
full doc preserving unchanged content, bumping the version, updating `last_reviewed`, and
appending a Change Log entry describing the delta.

## Requirements

1. Entry points: a "Refine with interview" button in `EditorPane`'s header when the
   selected file is a real content doc (not example; layer in the trainable set), and an
   "existing docs" section on the interview target-picker listing refinable files
   (`CanonicalStore` content files whose layer/template pair exists in
   `InterviewTarget.trainable`).
2. `InterviewEngine` gains a refine mode: `configureRefine(provider:file:store:personName:)`
   which loads the current doc, splits frontmatter/body, and builds a refine system prompt:
   the agent sees the **current content per section** and must (a) briefly confirm/probe
   sections that look stale, one question at a time, (b) never re-ask what the doc already
   answers unless checking staleness, (c) target sections the user says changed.
3. Refine draft instruction: regenerate the complete file — keep unchanged sections
   verbatim; apply user-described changes; bump `version` (minor bump for content changes,
   patch for pure corrections — let the model choose, default minor); set `last_reviewed`
   to today; keep `status` unless the user asks; **append** a Change Log entry
   (`- <today> · v<newVersion> — <one-line summary of the delta>`) preserving prior
   entries; keep every canonical H2.
4. Version handling is verified in code, not just prompted: after generation, parse the
   draft's frontmatter — if `version` didn't increase (semver compare) or Change Log lost
   entries, auto-fix version/append entry programmatically before showing the draft
   (deterministic guardrail around a fallible model).
5. Save overwrites the doc's own path (pre-filled, warning shown — reuse the existing
   save-sheet overwrite warning). After save: `store.reload()`, reselect the file.
6. Works with all providers; keep the current-doc block in the system prompt bounded
   (if the doc exceeds ~6,000 chars, include full section list but truncate long section
   bodies with an ellipsis note).

## Files

Modify:
- `Sources/PersonalOSStudio/Interview/InterviewEngine.swift` (refine mode: configure,
  prompts, post-generation version/changelog guardrail)
- `Sources/PersonalOSStudio/Views/InterviewView.swift` (refinable-docs section; refine flow
  reuses transcript/draft UI)
- `Sources/PersonalOSStudio/Views/EditorPane.swift` (header button → opens interview in
  refine mode for the selected file)

Create (only if the guardrail grows):
- `Sources/PersonalOSStudio/Interview/SemVer.swift` (tiny semver parse/bump/compare)

## Architecture constraints

- Reuse `Frontmatter`/`MarkdownSections`; no ad-hoc Markdown parsing.
- The guardrail (requirement 4) must be pure Swift — never trust the model for version
  math. Keep `stripCodeFence` handling on the draft as today.
- Single-doc create flow and `--interviewtest` unchanged. `@MainActor`, `rtk` prefix,
  no new dependencies.

## Acceptance criteria

- [ ] Refining `identity/identity.md`: agent's first message references actual current
      content (not generic questions); answering one change produces a draft where only
      the relevant section changed, `version` bumped, `last_reviewed` = today, Change Log
      gained exactly one entry and kept old ones.
- [ ] Guardrail: a model draft with an unbumped version still lands bumped in the preview.
- [ ] Save overwrites in place with the warning; browser shows one file, updated.
- [ ] Creation flow + `--interviewtest` unchanged (7 targets, exit 0).

## Verification

1. `swift build` clean; `--interviewtest` exit 0.
2. Live drive with Ollama: create an identity via the normal interview, then refine it
   ("my communication preference changed to detailed briefs"); diff before/after on disk —
   only User Profile/Style sections + frontmatter/changelog change.
3. Force the guardrail: temporarily instruct the model (via an answer like "don't change
   the version") and confirm the saved file still bumped.
