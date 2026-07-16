# F08 · Validation engine — checklists as code

**Theme:** Document quality & safety · **Priority:** P1 · **Depends on:** —

## Context

The canonical Agent OS repo ships six per-layer validation checklists at
`../agent_os/validation/{identity,context,skills,memory,connections,agents}-checklist.md`.
They are explicitly manual gates today — the identity checklist says *"It is the manual
gate; automated linting arrives in a later milestone."* **This feature is that milestone.**

Checklist rules are concrete and machine-checkable (read all six before implementing; the
identity checklist is representative):

- **Frontmatter:** `designation` ∈ {PII, Enterprise, Public}; layer-specific designation
  rules (identity is always PII); `layer` matches; `owner` non-empty; `review_cadence`
  set; `last_reviewed` within the cadence window (quarterly → < 90 days); `version` valid
  semver; `status` ∈ {draft, active, archived}; `target_tools` non-empty from the known set.
- **Banner:** a blockquote classification banner within the first 10 body lines restating
  the frontmatter designation.
- **Sections:** all canonical H2s present in order (per layer's template); no invented
  sections; layer-specific counts (identity: Operating Principles has 3–7 rules); Change
  Log non-empty and reflecting the current version.
- **Sample hygiene:** `sample: true` files carry the FICTIONAL banner; real-looking
  emails/names flagged.
- **Leakage:** PII indicators ("I prefer", "my manager", "reports to", email addresses,
  real names) appearing in files declared Enterprise/Public.

Studio context: `CanonicalStore` loads files per layer with parsed frontmatter
(`CanonicalFile.frontmatter`, `.designation`, `.status`, `.version`); `Frontmatter.split`
and `MarkdownSections.parse` give body/banner/H2 access; the browser (`Views/
OpenClawView.swift`) renders rows with `DesignationTag` badges; the train panel
(`Views/BuildPushPanel.swift`) already surfaces `BuildResult.warnings`; templates define
each layer's canonical H2 set (`InterviewTarget` extracts headings the same way).

## Goal

A validation engine that lints every canonical content file against its layer's checklist,
surfaces results as per-file badges in the browser and a detail list in the editor,
warns in the train panel when included files have findings, and runs headlessly via a
`--validate` flag suitable for CI on the canonical repo.

## Requirements

1. `Validation/Validator.swift`: `struct Finding { severity: error|warning; rule: String;
   message: String; file: CanonicalFile }` and
   `func validate(_ file: CanonicalFile, store: CanonicalStore) -> [Finding]`, plus
   `validateAll(store:)`. Rules implemented per layer:
   - shared frontmatter rules (designation enum, owner, semver, status enum, cadence
     window math, target_tools set),
   - banner-presence + designation-match rule,
   - section presence/order rule driven by the layer's template headings (reuse the
     template-heading extraction from `InterviewTarget.from` — extract it into a shared
     helper rather than duplicating),
   - identity extras (always-PII, Principles 3–7 items),
   - Change Log rule (non-empty; contains the current version string),
   - leakage heuristics (regex indicators + designation cross-check) as **warnings**,
   - sample-hygiene rules for example files (when examples are loaded).
2. Severity policy: structural/frontmatter violations = error; heuristics (leakage,
   stale review) = warning. Templates are skipped entirely; examples only when loaded.
3. Browser badges: a small status dot/icon per file row (green = clean, amber = warnings,
   red = errors) with a count; clicking the file shows findings in a collapsible strip
   above the editor (rule name + message per finding). Re-validate on save (hook
   `EditorPane.save` and interview saves via `store.reload()` — simplest: validate lazily
   per render from a cache invalidated on reload).
4. Train-panel gate: when building, list findings for included files in
   `BuildResult.warnings` ("identity.md: 2 validation errors — …"). Errors don't block the
   build (the user may be mid-authoring) but are prominent.
5. Headless `--validate`: run from the canonical repo (like `--selftest`), print findings
   grouped by file with severities, exit 0 if no errors (warnings allowed), 1 otherwise.
   Wire into `PersonalOSStudioApp.init` beside the existing flags.
6. Performance: whole-repo validation must be trivially fast (< 100 ms for tens of files);
   pure string work, no LLM calls.

## Files

Create:
- `Sources/PersonalOSStudio/Validation/Validator.swift` (rules + engine)
- `Sources/PersonalOSStudio/Validation/ValidationCache.swift` (per-file results,
  invalidated on `CanonicalStore.reload`) — or fold into the store if cleaner

Modify:
- `Sources/PersonalOSStudio/Views/OpenClawView.swift` (row badges)
- `Sources/PersonalOSStudio/Views/EditorPane.swift` (findings strip; revalidate on save)
- `Sources/PersonalOSStudio/Views/BuildPushPanel.swift` / `OpenClawAdapter.swift`
  (include findings in build warnings)
- `Sources/PersonalOSStudio/SelfTest.swift` + `PersonalOSStudioApp.swift` (`--validate`)
- `Sources/PersonalOSStudio/Interview/InterviewTarget.swift` (share heading extraction)

## Architecture constraints

- Rules must read their ground truth from the repo where possible (template headings for
  section rules) — hardcode only what the checklists hardcode (enums, counts, cadence
  windows: quarterly=90d, monthly=31d, yearly=366d).
- Reuse `Frontmatter`/`MarkdownSections`; no regex re-parse of structure (regex is fine
  inside leakage heuristics).
- No LLM involvement — deterministic linting only. `@MainActor` only where UI-bound; the
  validator itself should be a pure value-type API. `rtk` prefix; no new dependencies.

## Acceptance criteria

- [ ] A deliberately broken identity file (bad designation, missing banner, 9 principles,
      stale `last_reviewed`, version absent from Change Log) yields exactly the expected
      findings, each naming its rule.
- [ ] Clean example files (loaded via a store with examples enabled) validate clean apart
      from expected sample rules.
- [ ] Browser shows correct badges; editor strip lists findings; fixing + saving clears
      them without app restart.
- [ ] Train panel surfaces findings for included files.
- [ ] `--validate` exits 0 on the pristine canonical repo (or lists true positives), 1
      when the broken fixture is present.
- [ ] `--selftest` / `--interviewtest` unchanged.

## Verification

1. `swift build` clean.
2. Fixture drive: copy `../agent_os` to a scratch dir, break `identity/identity.md` per
   the acceptance list, run `--validate` (exit 1, findings printed), fix, re-run (exit 0).
3. In-app: open the broken file → strip shows findings; fix in editor → save → badge
   green.
4. `cd ../agent_os && … --validate` on the real repo; triage anything it reports.
