# F05 · Personal-OS bootstrap wizard (multi-doc interview)

**Theme:** Interview & LLM · **Priority:** P2 · **Depends on:** — (F07 streaming improves it but isn't required)

## Context

Personal OS Studio's agent interview (`Sources/PersonalOSStudio/Interview/`,
`Views/InterviewView.swift`) authors **one canonical doc per session**: pick a target
(`InterviewTarget.all(in:)` — curated to the trainable set: Identity, Role/Domain/Team
context, a Skill, Memory index, a Memory entry), answer one question at a time
(`InterviewEngine`, a `@MainActor ObservableObject` with phases
idle/asking/thinking/drafted/error), generate a draft, review, save via
`CanonicalStore.createFile(relativePath:contents:)`.

For a brand-new user the journey is repetitive: they must run four-plus separate
interviews (Identity → Role → Domain → Team → Memory index) and re-establish context each
time — the Role interview doesn't know what Identity said. A fresh install (which now
shows empty layers with "No files yet — use Interview to create one") deserves a single
guided bootstrap.

Existing plumbing to reuse: `LLMSettings.makeProvider()` (Ollama/OpenAI/Perplexity/
Anthropic behind the `LLMProvider` protocol — `complete(system:messages:)`),
`AppState.personName` (auto-filled from `NSFullUserName()`, editable),
`InterviewEngine`'s prompt builders (system prompt from template H2s; draft instruction
filling owner/date/version/name), `InterviewTarget` (template frontmatter + section
headings), `CanonicalStore.reload()`/`file(atRelativePath:)` for post-save selection.

## Goal

A "Bootstrap my OS" wizard: one continuous interview that walks Identity → Role → Domain →
Team → Memory index in sequence, carries forward what it learns between docs (no repeated
questions), shows progress, lets the user skip docs, and finishes with a batch review/save
of all generated files.

## Requirements

1. `BootstrapEngine` (new, `Interview/BootstrapEngine.swift`) orchestrating an ordered
   queue of `InterviewTarget`s: `[identity, role, domain, team, MEMORY]` (resolve from
   `InterviewTarget.all`; tolerate missing templates by skipping with a note).
2. **Context carry-forward:** when doc N+1 starts, its system prompt includes a compact
   summary block of the answers/drafts from docs 1…N ("Already established: name, role
   title, company domain…") so the agent never re-asks known facts. Cap the block (~1,500
   chars) by summarizing older docs harder (frontmatter title + key bullets).
3. Per-doc flow reuses the single-doc loop (ask → answer → generate) — refactor
   `InterviewEngine` so its turn loop is callable per-doc rather than duplicating it.
   Draft generation per doc happens when the agent signals coverage or the user clicks
   "Next doc".
4. Wizard UI in `InterviewView` (new mode, not a separate window): progress header
   ("Doc 2 of 5 · Role context"), per-doc skip button, the existing transcript/input UI,
   and a final **review screen** listing all drafts with per-doc editors (reuse the draft
   `TextEditor` pattern) and one "Save all" that writes every file, reloads the store, and
   reports results per file.
5. Entry point: on the interview target-picker screen, a prominent "Bootstrap my OS"
   button shown when ≥ 2 of the wizard docs don't exist yet
   (`CanonicalStore.fileExists(relativePath:)`).
6. Failure handling: a provider error mid-wizard preserves all completed drafts; retry
   resumes the current doc. Cancelling the wizard offers to save completed drafts.
7. Name handling as today: `personName` passed in, agent told not to ask for it.

## Files

Create:
- `Sources/PersonalOSStudio/Interview/BootstrapEngine.swift`

Modify:
- `Sources/PersonalOSStudio/Interview/InterviewEngine.swift` (extract reusable turn loop +
  prompt builders; keep the single-doc API intact)
- `Sources/PersonalOSStudio/Views/InterviewView.swift` (wizard mode: progress, skip,
  review/save-all screens; entry button)
- `Sources/PersonalOSStudio/Interview/InterviewTarget.swift` (ordered bootstrap set helper)

## Architecture constraints

- One provider round-trip API only: `LLMProvider.complete(system:messages:)` — the wizard
  is provider-agnostic and must work with local Ollama models (keep prompts compact).
- `@MainActor ObservableObject`; views observe engines directly via `@ObservedObject`
  (established pattern — nested-object republishing is not relied on).
- All saves via `CanonicalStore.createFile` + `reload()`; suggested paths from
  `InterviewTarget.suggestedRelativePath`.
- Don't break the single-doc interview or `--interviewtest`. `rtk` shell prefix; no new
  dependencies.

## Acceptance criteria

- [ ] Fresh canonical repo (no content files): Bootstrap button appears; completing the
      wizard produces identity.md, role.md, domain.md, team.md, MEMORY.md — all valid
      (frontmatter filled: owner email, today's date, version 0.1.0, status draft, name
      substituted; template H2s intact).
- [ ] A fact given in the Identity doc (e.g. job title) is **not re-asked** during Role.
- [ ] Skip works (skipped doc not generated, wizard continues); cancel offers partial save.
- [ ] Provider error mid-doc → retry resumes without losing prior drafts.
- [ ] Single-doc interview unchanged; `--interviewtest` still exits 0 with 7 targets.

## Verification

1. `swift build` clean.
2. Point the app at a scratch canonical checkout (copy `../agent_os` minus content files),
   run the full wizard against local Ollama (`llama3.2`), answer 2–3 questions per doc,
   Save all; inspect the five files.
3. Grep the transcripts: the Role doc's questions must not include name/title re-asks.
4. `--interviewtest` from `../agent_os` → exit 0.
