# F15 · Context backfeed — harness drift becomes reviewed canonical proposals

**Theme:** Feedback loop · **Priority:** P1 · **Depends on:** F01 (adapter/delivery framework), F08 (validation), F09 (diff), F13 (vault, pre-apply snapshot) · **Requires:** a configured LLM provider

## Context

The loop is currently one-directional. Studio compiles canonical → harness
(`HarnessAdapter.build` + `DirectoryPusher`), but everything the agent learns *at
runtime* stays stranded in the harness: OpenClaw appends to its workspace `MEMORY.md`
and drops files into `memories/`; Hermes does the same under `~/.hermes`; a user (or the
agent) may hand-edit a deployed `SOUL.md`/`AGENTS.md` in place. None of it flows back,
so the canonical repo — the supposed source of truth — quietly falls behind the
runtimes it feeds, and the next push **overwrites** runtime knowledge with stale
canonical content. Today the only mitigation is the `.bak-studio` backup.

Decisions (2026-07-07):
- **Sources: instruction-file drift only.** Compare what Studio pushed against what's in
  the harness target now. No session-transcript mining — bounded, deterministic
  detection, and the raw material never includes conversation logs.
- **Targets: any canonical layer, memory-first.** Most proposals become new/updated
  `memory/<name>.md` entries; the LLM may propose identity/context/skill edits when the
  drift clearly belongs there. Every proposal is a human-reviewed diff — Studio is the
  man in the middle, never an auto-writer.
- **LLM-gated.** Classification/distillation requires a model. With no provider
  configured, the feature surfaces as disabled with guidance, never as broken.

What exists to build on: push paths are centralized (`DirectoryPusher.push`,
`OpenClawService.push`) and every artifact carries a provenance comment
(owner/version/reviewed/designation); adapters define the forward heading mappings that
backfeed must reverse (e.g. OpenClaw renames Identity's "Operating Principles" →
"Principles"); `settings.makeProvider()` + streaming and the deterministic draft
guardrails (`normalizeFrontmatter`, `enforceRefineGuardrail`, `ensureInstanceName`) are
proven; `DiffView` (F09) and the validator (F08) gate what may land; the vault (F13)
provides the pre-apply snapshot; `Migrator.contentFiles` shows the content-enumeration
pattern.

## Goal

Every directory-delivered harness becomes a two-way surface: Studio detects what changed
in the harness since the last push (deterministically), an LLM distills each drift item
into a schema-correct proposal against the canonical repo (memory-first, any layer),
and the user reviews each proposal as a diff — accept writes canonical (validated,
version-bumped, vault-snapshotted), reject is remembered so the same drift is never
re-proposed. The canonical repo stops falling behind its runtimes.

## Requirements

1. **Push ledger** (`Backfeed/PushLedger.swift`): every push records a per-target
   manifest — relative path → SHA-256 of pushed bytes + source provenance — persisted
   under Application Support (keyed by harness id + target path). Both push paths
   (`DirectoryPusher` callers: generic panel, OpenClaw push) update it. The ledger is
   metadata only (hashes, never content) and survives relaunches.
2. **Harvest scan** (`Backfeed/HarvestScanner.swift`): for a target with a ledger,
   classify deterministically — **modified** (pushed file whose current hash differs),
   **added** (file in scanned artifact roots not in the ledger, e.g. agent-written
   `memories/*.md`), **unchanged** (skipped). No LLM in this stage. Scan is strictly
   read-only on the harness; `.bak-studio`, hidden files, and non-Markdown are ignored.
   Clipboard harnesses (Cowork) are out of scope — no filesystem to scan.
3. **Proposal engine** (`Backfeed/ProposalEngine.swift`, LLM-gated): each drift item +
   the bounded relevant canonical doc(s) go to the provider with the adapter's REVERSE
   heading map, producing a `Proposal`: target canonical path (existing file, or a new
   `memory/<name>.md`), full proposed contents, one-line rationale, and source
   attribution (harness / target / file). Deterministic guardrails then apply — the
   same battle-tested chain as authoring: frontmatter normalization; instance naming
   for new entries; version bump + `last_reviewed` + Change Log entry for updates; and
   the proposal is DROPPED (logged) if the result still fails validation with errors.
   The model proposes; the guardrails and the user dispose.
4. **Review UI** (`Views/BackfeedPanel.swift`): a queue of pending proposals. Each row:
   source attribution, rationale, designation tag, and a `DiffView` (current canonical →
   proposed; "new file" rendering for additions). Actions per proposal: **Accept**
   (vault auto-snapshot, write canonical, `store.reload()` + `revalidate()`),
   **Reject** (remembered), **Skip** (stays pending). Batch "Accept all" is
   deliberately absent — review is the point.
5. **Dismissal memory**: rejecting a proposal records the drift item's content hash;
   identical drift is never re-proposed. Re-pushing canonical to the harness clears the
   relevant ledger entries naturally (new baseline). Dismissals persist locally.
6. **Entry points**: the OpenClaw panel and the generic directory panel gain a
   "Check for harness updates…" affordance showing the drift count after a scan
   (e.g. "3 changes since last push"); opening it runs/refreshes the harvest and
   presents the queue. With no LLM configured, the affordance is visible but disabled
   with one-line guidance ("Configure a provider to distill harness changes into
   proposals").
7. **Privacy posture**: harvest reads local harness directories only. Drift excerpts are
   sent to the *user-configured* LLM provider and nowhere else — the panel states this
   plainly when the provider is a cloud key (local Ollama: fully offline). Proposals and
   dismissals are stored locally; the vault snapshot precedes every accepted write.
8. **Headless** (`--backfeedtest`, registered in `PersonalOSStudioApp.swift`):
   deterministic, scripted fake provider, no network — ledger write/read roundtrip;
   scan classifies added/modified/unchanged correctly against a scratch target;
   reverse heading mapping restores canonical H2s; guardrail chain produces a
   validation-clean proposal (version bumped, Change Log appended, kebab name for new
   entries); a proposal failing validation is dropped not surfaced; dismissal memory
   suppresses an identical re-harvest; re-push resets the baseline.

## Files

Create:
- `Sources/PersonalOSStudio/Backfeed/PushLedger.swift`
- `Sources/PersonalOSStudio/Backfeed/HarvestScanner.swift`
- `Sources/PersonalOSStudio/Backfeed/ProposalEngine.swift`
- `Sources/PersonalOSStudio/Views/BackfeedPanel.swift`

Modify:
- `Sources/PersonalOSStudio/DirectoryPusher.swift` / `OpenClawService.swift` (ledger
  recording on push)
- `Sources/PersonalOSStudio/Adapters/*.swift` (expose reverse heading maps alongside the
  forward ones — single source for both directions)
- `Sources/PersonalOSStudio/Views/BuildPushPanel.swift`,
  `Views/GenericDirectoryPanel.swift` (entry points + drift count)
- `Sources/PersonalOSStudio/PersonalOSStudioApp.swift` (wiring, `--backfeedtest`)
- `Sources/PersonalOSStudio/SelfTest.swift` (`backfeedTest`)

## Architecture constraints

- **Nothing auto-applies.** Every canonical write goes through an explicit per-proposal
  Accept with a diff. No batch-accept, no background application.
- **Harvest is read-only** on harness directories — backfeed never mutates a runtime.
- The LLM is quarantined to the proposal stage: detection (hashes) and disposal
  (guardrails + validation + user) are deterministic. A garbage model can produce
  garbage proposals, but never a non-compliant canonical file or an unreviewed write.
- Ledger and dismissals are hashes + paths, never document content; stored per-user
  under Application Support, not in any repo.
- Bounded prompts: drift excerpts use the `boundedDocBlock`-style truncation; whole
  harness trees are never shipped to a provider.
- `rtk` prefix in docs/verification; in-app process calls invoke binaries directly.

## Acceptance criteria

- [ ] Push to a scratch target, append a new `memories/*.md` and edit `MEMORY.md` in the
      target, harvest → exactly two drift items (one added, one modified); unchanged
      files produce none.
- [ ] With the scripted provider, the added memory becomes a proposal for a new
      `memory/<kebab-name>.md` that passes validation (banner, frontmatter, sections)
      without manual fixes; the modified file becomes an update proposal whose diff
      shows a version bump + Change Log entry.
- [ ] Accepting writes the canonical file, triggers a vault snapshot first, and the
      browser/validation reflect it immediately; rejecting an item and re-harvesting
      does not re-propose it; re-pushing canonical clears the drift.
- [ ] With no LLM provider configured, the affordance is disabled with guidance; the
      scan itself (drift count) still works.
- [ ] A proposal that fails validation with errors is dropped and logged, never queued.
- [ ] `--backfeedtest` exits 0 with no network; full regression battery stays green
      (`--selftest` byte-identical; all suites).

## Verification

1. `rtk swift build` clean; `--backfeedtest` exit 0; full battery green.
2. GUI drill (OpenClaw scratch workspace): train + push → hand-add a memory file and
   edit `MEMORY.md` in the workspace → "Check for harness updates…" shows 2 → review
   queue shows both proposals with diffs → accept the new memory (vault snapshot logged,
   file appears in browser, validation clean) → reject the other → re-harvest shows 0.
3. Hermes drill: same flow against `~/.hermes` with a scratch home.
4. Gating drill: remove the provider key → affordance disabled with guidance; restore →
   proposals flow again.
