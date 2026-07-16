# F16 · Evals layer — measure the compiled spec, feed the signal back

**Theme:** Feedback loop · **Priority:** P1 · **Depends on:** F07 (providers/streaming), F08 (validation), F15 (backfeed seam) · **Requires:** a configured LLM provider

## Context

The loop now runs in both directions — canonical compiles into harnesses (F01–F04),
runtime learning flows back as reviewed proposals (F15) — but nothing **measures**
whether a trained harness actually behaves the way the specification says it should.
The vision this app implements ("definitions feed a live harness, an evals layer
measures the result, and that signal refines the spec") has shipped everything except
the measuring.

The raw material already exists in the canonical schema:

- **Skills carry `## Test Plan` sections** — the skills checklist explicitly requires a
  test plan that "describes how to verify on real input" (reject 'looks reasonable').
  Today those plans are prose nobody executes.
- **Identity carries testable behavior**: Operating Principles, Boundaries, Style &
  Tone, Output Expectations, Escalation & Confirmation — each is a behavioral claim an
  eval can probe ("does the trained agent actually refuse X / confirm before Y / answer
  tersely?").
- **Memory entries are recall claims** — a trained harness should surface the pool
  routine or the cat's name when relevant, without being handed the file.

Plumbing available: adapters produce each harness's exact artifact set
(`HarnessAdapter.build`) — a harness-primed context is one system-prompt assembly away;
`LLMProvider.complete/stream` and the scripted fake providers (F07) give execution and
deterministic tests; provenance comments tie every artifact to source doc + version, so
results can be pinned to spec versions; `configureRefine(findings:)` (F08) is the
existing seam for feeding problems into a refine interview; the roadmap's storage
patterns (Application Support for machine-local state, canonical repo for portable
definitions) are established.

Scope decision for v1: evals execute against a **simulated harness** — the configured
LLM primed with the exact compiled artifacts for the chosen harness (works for all four,
offline with Ollama, no tool-specific automation). Driving the *live* tools
(OpenClaw gateway API, `codex exec`, Hermes CLI) is deliberately out of scope; the
runner is a protocol so live targets can arrive as F16.x without reshaping anything.

## Goal

Every part of the personal OS becomes measurable: eval cases live as portable Markdown
in the canonical repo (generated from the spec, hand-editable), one click runs a suite
against a harness's compiled artifacts, an LLM judge scores each case against its
rubric, results persist locally with per-version history — and failures flow back into
the loop as refine-interview seeds, closing spec → compile → measure → refine.

## Requirements

1. **Eval case format** (portable, in the canonical repo under `evals/*.md` — a
   root-level directory like `validation/`, not a seventh layer): frontmatter
   (`title`, `designation`, `name` kebab-case, `source` = layer-relative doc path,
   `source_version`, `owner`, `last_reviewed`, `version`, `status`) plus H2s:
   `## Prompt` (what is said to the agent), `## Expectation` (what good behavior looks
   like, prose rubric for the judge), optional `## Must Contain` / `## Must Not Contain`
   (deterministic line-item assertions checked in code before any judge call),
   `## Change Log`. Validator gains an `evals` ruleset (frontmatter completeness,
   required sections, `source` resolves to an existing canonical doc).
2. **Suite generation** (`Evals/EvalGenerator.swift`, LLM-gated): "Generate eval
   cases…" builds cases from the spec — deterministically seeded where the spec already
   says how (each skill `## Test Plan` step becomes a case skeleton; each memory entry
   becomes a recall probe), LLM-drafted for behavioral identity claims (principles,
   boundaries, escalation). Generated cases are **proposals into `evals/`** via the
   existing save-with-diff flow — the user reviews and owns them; regeneration never
   silently overwrites hand-edits.
3. **Runner** (`Evals/EvalRunner.swift`): `EvalTarget` protocol —
   `primedContext(for harness:) -> String` v1 implementation assembles the harness's
   compiled artifacts (SOUL/AGENTS/memory, exactly what `build(from:)` produced) into a
   system prompt; each case runs `## Prompt` through the provider against that context.
   Concurrency-bounded, per-case streaming progress, cancellable.
4. **Judge** (`Evals/EvalJudge.swift`): deterministic assertions first (`Must Contain` /
   `Must Not Contain` — a failure here needs no model and can't be argued with); then an
   LLM judge scores the transcript against `## Expectation` → verdict `pass` / `fail` /
   `partial` + one-line reason. The judge prompt is fixed and versioned in code; judge
   and subject may use the same provider but never share a conversation.
5. **Results & history** (`Evals/EvalStore.swift`): machine-local (Application Support,
   700) — per run: date, harness, case id + verdict + reason, and the **source doc
   versions** from artifact provenance. The panel shows the latest run per harness and
   deltas vs the previous run ("passed 12/14 — 2 regressions since identity v0.3.0").
   Results never enter the canonical repo.
6. **Feed the signal back**: a failing case surfaces "Refine <source doc>…" — opens the
   refine interview seeded with the failure (case prompt, expectation, verdict reason)
   through the same channel as validator findings, so the interviewer targets exactly
   what measured wrong. This is the loop's last unbuilt edge.
7. **UI** (`Views/EvalsPanel.swift`): per-harness entry point ("Evaluate…") beside
   train/push — suite list (from `evals/`, filtered to cases whose `source` is included
   in the build), run button with live progress, verdict rows (case, verdict badge,
   reason, source doc + version), history strip, per-failure "Refine…" action.
   LLM-gated with guidance when unconfigured.
8. **Headless**: `--eval` runs the suite from the cwd canonical repo against a named
   harness's artifacts and exits non-zero on any `fail` (CI-ready; provider from env or
   local Ollama). `--evaltest` is deterministic with scripted providers: case parsing +
   validation, Test-Plan → skeleton generation, deterministic assertions short-circuit
   the judge, judge verdict parsing, store roundtrip + regression delta, refine-seed
   handoff. No network.

## Files

Create:
- `Sources/PersonalOSStudio/Evals/EvalCase.swift` (parse/serialize `evals/*.md`)
- `Sources/PersonalOSStudio/Evals/EvalGenerator.swift`
- `Sources/PersonalOSStudio/Evals/EvalRunner.swift`
- `Sources/PersonalOSStudio/Evals/EvalJudge.swift`
- `Sources/PersonalOSStudio/Evals/EvalStore.swift`
- `Sources/PersonalOSStudio/Views/EvalsPanel.swift`

Modify:
- `Sources/PersonalOSStudio/Validation/Validator.swift` (evals ruleset)
- `Sources/PersonalOSStudio/Views/BuildPushPanel.swift`,
  `Views/GenericDirectoryPanel.swift`, `Views/ClipboardDeliveryPanel.swift`
  ("Evaluate…" entry point)
- `Sources/PersonalOSStudio/Views/InterviewView.swift` / `InterviewEngine.swift`
  (refine seeding accepts eval failures alongside validator findings)
- `Sources/PersonalOSStudio/PersonalOSStudioApp.swift` (`--eval`, `--evaltest`, wiring)
- `Sources/PersonalOSStudio/SelfTest.swift` (`evalTest`)

## Architecture constraints

- **Definitions portable, measurements local**: eval cases are canonical repo content
  (designation-aware, validated, versioned, vault-covered like any content doc);
  results/history live only in Application Support.
- **Deterministic before model**: assertions run before the judge; the judge never
  overrides a deterministic failure. A garbage judge can mis-grade prose expectations
  but cannot pass a case that violates a Must-Not-Contain.
- The subject transcript is generated fresh per run — no caching of subject responses
  across runs (that would measure the cache, not the spec).
- Bounded prompts: primed context reuses the artifacts as-built (they are already
  length-managed by the adapters); one case = one subject call + at most one judge call.
- Nothing auto-refines: failures *offer* the refine interview; the user drives it.
- Generation never overwrites existing `evals/*.md` without the standard
  exists-overwrite diff confirmation.
- `rtk` prefix in docs/verification; in-app process calls invoke binaries directly.

## Acceptance criteria

- [ ] "Generate eval cases…" on a repo with 1 skill (with Test Plan), identity, and ≥1
      memory entry proposes ≥4 reviewable cases into `evals/`; a hand-edited case
      survives regeneration untouched (or shows the overwrite diff).
- [ ] Running the suite against OpenClaw's artifacts yields a verdict per case with
      reasons; a case with `Must Not Contain` violated fails without a judge call.
- [ ] A deliberately-wrong memory recall case fails; clicking "Refine…" opens the
      refine interview seeded with that failure; fixing the doc + re-running flips the
      case to pass and the history strip shows the delta.
- [ ] Same suite runs against Hermes/Codex/Cowork artifact sets (simulated target).
- [ ] `--eval` exits 0 on all-pass, non-zero on any fail; `--evaltest` exits 0 with no
      network; full regression battery stays green (`--selftest` byte-identical).
- [ ] Validator flags a malformed eval case (missing Expectation, dangling `source`).

## Verification

1. `rtk swift build` clean; `--evaltest` exit 0; full battery green.
2. GUI drill (OpenClaw): generate cases → review/save → Evaluate → all verdicts
   rendered; sabotage `identity.md` tone rules → re-run → regression shown → Refine…
   from the failure → regenerate doc → re-run → pass restored.
3. Headless drill: `rtk` + `--eval openclaw` in CI mode against the canonical repo.
4. Cross-harness: run the same suite against Hermes artifacts; verify verdicts and
   history are tracked per harness.
