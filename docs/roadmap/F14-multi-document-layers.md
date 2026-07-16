# F14 · Multi-document layers — instance-aware authoring

**Theme:** Interview · **Priority:** P2 · **Depends on:** F08 (validator), F09 (save-sheet diff)

## Context

The canonical schema intends several layers to hold **many documents**: the examples ship
three skills (`skills/examples/sample.draft-weekly-update.md`,
`sample.monthly-business-review-prep.md`, `sample.prep-exec-staff.md`), three connections,
and multiple persistent memory entries — and every adapter already iterates
`store.files(layer)`, emitting one artifact per document (each skill becomes its own
`skills/<name>/SKILL.md`, each memory entry its own `memories/…` file).

The authoring path contradicts this. `InterviewTarget.from(template:)`
(`Sources/PersonalOSStudio/Interview/InterviewTarget.swift`) derives the save suggestion
from the **template's** filename:

```swift
suggestedRelativePath: "\(file.layer.rawValue)/\(cleanBase)"   // skills/skill.md — always
```

So every new skill suggests `skills/skill.md`, every memory entry
`memory/persistent.entry.md`, every connection `connections/connection.md`, every agent
`agents/agent.md`. The F09 save sheet warns before overwriting, but the design funnels
each layer's Nth document onto the same filename — observed in practice: a real repo
ended up with a single literal `skills/skill.md` and `memory/persistent.entry.md`.
Documents in these layers already carry a validator-enforced kebab-case `name:` field
(`skills.name` rule in `Validation/Validator.swift`) — the natural per-instance filename —
but nothing uses it for the save path, nothing offers "add another", and nothing catches
two documents claiming the same `name:` (which silently collide in adapter output).

Decided cardinality (product decision, 2026-07-06):

| Layer | Cardinality |
|---|---|
| Identity | **Single** (`identity/identity.md`) |
| Context | **Single per type** — one `role.md`, one `domain.md`, one `team.md` (stakeholders/reporting lines are sections *inside* `team.md`) |
| Skills | **Multi** — one file per skill |
| Memory | **Multi** persistent entries + singleton `MEMORY.md` index + singleton working memory |
| Connections | **Multi** — one file per integration |
| Agents | **Multi** — one file per agent definition |

Plumbing available: `Frontmatter.split` reads `name:` from a draft;
`state.store.fileExists(relativePath:)` powers the overwrite warning + `DiffView` (F09);
`InterviewView`'s `saveFilename` is already user-editable; the layer browser
(`Views/OpenClawView.swift`) lists all files per layer, so display needs no change.

## Goal

Layer cardinality is explicit in the model, and authoring respects it: creating a skill /
memory entry / connection / agent always lands a **new, uniquely-named file** derived from
the document's own `name:`, with an obvious "add another" affordance per multi layer —
while single(-per-type) layers keep exactly today's behavior. Duplicate names within a
layer become a validation error instead of a silent adapter-output collision.

## Requirements

1. **Cardinality model** (`Models.swift`): `Layer` (or a parallel table) exposes
   `cardinality` — `.single` (identity), `.singlePerType` (context), `.multi` (skills,
   connections, agents), memory = `.multi` for entries with `MEMORY.md` and the working
   file as explicit singletons. Drives everything below; no behavior hardcoded per view.
2. **Name-derived save suggestion** (`InterviewTarget` / `InterviewView`): for `.multi`
   targets, once a draft exists, the suggested path becomes
   `layer/<kebab-name>.md` — `name:` from the draft's frontmatter, falling back to a
   kebab-cased `title:`. Never suggest the template-base filename for a `.multi` layer.
   If the derived path already exists, keep the F09 overwrite warning + diff (that's a
   legitimate re-generate), but a *different* document with a colliding name must be
   renameable in place (the field stays editable).
3. **Interview asks for the name**: for `.multi` targets the system prompt instructs the
   agent to establish what the document should be called (kebab-case, ≤ 40 chars) early
   in the conversation, and the draft instruction requires `name:` in the frontmatter.
   Deterministic guardrail: if the generated draft lacks a valid `name:`, derive one from
   the title (kebab-case, truncated) before the save sheet opens — never block on the
   model getting it right.
4. **"Add another" affordance** (`Views/OpenClawView.swift`): each `.multi` layer's
   section header in the browser gains a small `+` button ("New skill…", "New
   connection…", …) that opens the interview preconfigured with that layer's instance
   template (skills → `skill.template.md`, memory → `persistent.entry.template.md`,
   connections → `connection.template.md`, agents → `agent.template.md`). Single layers
   get no `+`.
5. **Duplicate-name validation** (`Validation/Validator.swift`): within a `.multi` layer,
   two content documents with the same `name:` → `[error] layer.duplicate_name` on both
   files (message names the other file). Adapter builds already warn on artifact-path
   collisions if trivial to surface; the validator rule is the required catch.
6. **Out of scope / unchanged**: bootstrap wizard keeps its fixed 5-doc flow (identity,
   role, domain, team, MEMORY index); refine already operates per-file; context stays
   single-per-type — no `+` button, no multi handling.
7. **Headless** (`--multidoctest`, registered in `PersonalOSStudioApp.swift`):
   deterministic — cardinality table sanity; name-derived suggestion for a fake multi
   draft (`skills/extract-project-architecture.md`, not `skills/skill.md`); fallback
   derivation when `name:` missing; duplicate-name findings fire on a two-file fixture
   and stay quiet on unique names; single layers still suggest their fixed paths.

## Files

Modify:
- `Sources/PersonalOSStudio/Models.swift` (cardinality)
- `Sources/PersonalOSStudio/Interview/InterviewTarget.swift` (multi-aware suggestion)
- `Sources/PersonalOSStudio/Interview/InterviewEngine.swift` (name question in system
  prompt; `name:` requirement + deterministic fallback in the draft path)
- `Sources/PersonalOSStudio/Views/InterviewView.swift` (post-draft suggested-path
  recompute from the draft's `name:`)
- `Sources/PersonalOSStudio/Views/OpenClawView.swift` (per-layer `+` affordance)
- `Sources/PersonalOSStudio/Validation/Validator.swift` (`layer.duplicate_name`)
- `Sources/PersonalOSStudio/PersonalOSStudioApp.swift` (`--multidoctest`)
- `Sources/PersonalOSStudio/SelfTest.swift` (`multiDocTest`)

## Architecture constraints

- Cardinality is data on the layer model, consumed generically — views/validator switch
  on it, never on layer identity strings.
- The save sheet's path field remains fully user-editable; suggestion ≠ enforcement.
  Overwrite of an existing path keeps the F09 warning + diff exactly as today.
- Name derivation is pure string work (kebab-case: lowercase, non-alphanumerics → `-`,
  collapse repeats, trim, ≤ 40 chars) in a static, testable helper — reuse the
  validator's `skills.name` regex as the acceptance check.
- No schema changes to the canonical repo: `name:` already exists in the multi-layer
  templates; templates/examples are untouched.
- `rtk` prefix in docs/verification; in-app process calls invoke binaries directly.

## Acceptance criteria

- [ ] Authoring two skills back-to-back yields two files (e.g.
      `skills/extract-project-architecture.md`, `skills/draft-weekly-update.md`) with no
      overwrite prompt between them.
- [ ] A multi-layer draft whose model output lacks `name:` still gets a valid kebab-case
      suggestion (derived from title) — never `skills/skill.md`.
- [ ] Each multi layer shows the `+` affordance and it lands in the interview with the
      right template; identity/context show none.
- [ ] Two documents sharing a `name:` in one layer produce `layer.duplicate_name` errors
      on both; renaming one clears both.
- [ ] Bootstrap wizard, refine, and single-layer interviews behave exactly as before
      (`--bootstraptest`, `--refinetest`, `--interviewtest` unchanged).
- [ ] `--multidoctest` exits 0; full regression battery green (`--selftest`
      byte-identical; all suites).

## Verification

1. `rtk swift build` clean; `--multidoctest` exit 0; full battery green.
2. GUI: `+` on Skills → interview → generate → save sheet suggests
   `skills/<name-from-interview>.md`; save; repeat with a second skill; browser lists
   both; train → two `skills/<name>/SKILL.md` artifacts.
3. Duplicate drill: hand-edit the second skill's `name:` to match the first → both files
   flag `layer.duplicate_name` in the editor strip; fix → findings clear.
4. Memory: `+` on Memory → entry saves as `memory/<name>.md` (matches the existing
   real-world pattern, e.g. `acme-migration-notes.md`).
