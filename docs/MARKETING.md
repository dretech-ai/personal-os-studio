# Personal OS Studio

**Define your AI agent once. Train every harness you use.**

Personal OS Studio is a native macOS app that turns a written specification of your AI
agent — its identity, context, skills, memory, and connections — into the live
configuration of every AI tool you run. Author the definition in guided interviews,
validate it against schemas, version it, protect it, and compile it into OpenClaw,
Hermes, OpenAI Codex, or Claude Cowork with one click.

> **Specifications, not prompts.** An agent should be defined once, in a tool-neutral
> specification, and compiled into whatever runtime executes it. Behavior is trained,
> not hand-tuned.

---

## The problem

Everyone who works seriously with AI assistants ends up maintaining the same knowledge
five times, badly:

- **Every tool wants its own instruction format.** OpenClaw reads `SOUL.md` and
  workspace files. Hermes has its own home-directory layout. Codex reads one repo-scoped
  `AGENTS.md`. Claude Cowork wants paste blocks. Same you, same agent — four dialects.
- **The instructions drift.** You fix a preference in one tool and forget the other
  three. There is no single source of truth, no diff, no version history, no way to know
  which tool has which vintage of you.
- **It's all personal data, handled casually.** Your working hours, reporting lines,
  communication preferences, and project context are PII — routinely pasted into config
  files, synced folders, and repos with no data classification and no backup story.
- **Authoring is a blank-page problem.** Writing a good agent definition from scratch is
  hard. Most people never do it, and their assistants stay generic.

## The idea

Personal OS Studio implements a simple architecture:

```
   canonical Agent OS  ──compile──▶  live harnesses ──behavior──▶  evals
   (tool-neutral Markdown)     (OpenClaw · Hermes · Codex · Cowork)  │
        ▲    ▲                              │                        │
        │    └── reviewed proposals ◀── drift                        │
        └─────────── refine ◀──────── failing cases ◀────────────────┘
```

One **canonical repository** of plain Markdown defines the agent across six layers —
Identity, Context, Skills, Memory, Connections, Agents — each with a schema, a
validation checklist, and a data designation (**PII / Enterprise / Public**). Studio is
the compiler and the authoring environment: pluggable adapters translate the canonical
files into exactly what each tool reads, and guided interviews keep the canonical files
themselves current.

Plain Markdown means no lock-in — the source of truth is readable, diffable, and yours.

---

## What it does

### Compile: one definition, four harnesses

A pluggable adapter framework maps the canonical layers to each tool's real format:

| Harness | What Studio produces | Delivery |
|---|---|---|
| **OpenClaw** | `SOUL.md`, `AGENTS.md`, `skills/`, `MEMORY.md` per workspace | Push to workspace + gateway restart + health check |
| **Hermes** | `SOUL.md`, `AGENTS.md`, `memories/`, `skills/<name>/SKILL.md` | Push to `~/.hermes` with permission tightening (700/600) |
| **OpenAI Codex** | Repo-scoped `AGENTS.md` + `~/.codex/skills` | Push with automatic commit-exclusion (`.git/info/exclude`) |
| **Claude Cowork** | Global-instructions and project paste blocks | Copy-ready clipboard blocks, length-pressure trimming |

Every artifact carries provenance (owner, version, review date, designation) and every
push previews before it writes, backs up what it overwrites, and applies
destination-appropriate guardrails — chmod tightening for Hermes, commit-exclusion for
Codex, PII warnings everywhere they apply.

### Author: interviews, not blank pages

- **Agent interview** — pick a document, and an LLM interviewer asks one focused
  question at a time, then generates the complete, schema-correct file. Responses stream
  live; cancel and retry are first-class.
- **Bootstrap wizard** — build an entire personal OS in one sitting: identity → role →
  domain → team → memory, with facts carried forward so nothing is asked twice.
- **Refine by interview** — point the interviewer at an existing document; it reads the
  current content, asks only delta questions, fixes anything the validator flagged, and
  regenerates with a version bump and change-log entry. Deterministic guardrails ensure
  version math, frontmatter structure, and required sections are right even when a small
  local model isn't.
- **Bring your own model** — local Ollama for fully-offline authoring, or Anthropic,
  OpenAI, or Perplexity by API key (keys live in the macOS Keychain, never on disk).

### Trust: validation, diffs, versions

- **Validation engine** — the schema checklists are executable. Every document is linted
  live: frontmatter completeness, classification banners, required sections in order,
  kebab-case naming, stale review dates, cross-file name collisions. Errors surface in
  the editor, roll up into training warnings, and run headlessly (`--validate`, CI-ready).
- **Diff before anything overwrites** — refine drafts, editor saves, and harness pushes
  all show line diffs against what exists before a byte is written.
- **Version management** — semver + change-log discipline enforced by tooling: hand-edit
  a file without bumping and Studio offers the bump with a one-line summary; artifacts
  that drift from their deployed version get staleness warnings.

### Protect: the PII posture, with teeth

- **Data designations everywhere** — every document declares PII / Enterprise / Public,
  every generated artifact inherits the strongest designation of its sources, and the UI
  tags both.
- **Git-aware, never git-careless** — local snapshot commits and per-file history for the
  canonical repo, with a hard rule: Studio never pushes, pulls, or touches a remote. The
  recommended posture keeps filled-in PII files gitignored entirely — and Studio
  explains that state instead of hiding it.
- **Encrypted PII vault** — the files git deliberately never sees still get history:
  AES-GCM-encrypted snapshots of every content document, taken automatically on each
  save and before any destructive migration. The key lives only in the macOS Keychain,
  with passphrase-protected export for machine migration. Blobs are ciphertext-only —
  filenames included — safe to keep on a synced or external volume. Restore any file,
  from any snapshot, with a diff review first.

### Operate: a real application lifecycle

- **First-run onboarding** — choose an existing canonical repo or scaffold a fresh one
  (layer directories, authoring templates, PII-safe `.gitignore`, git init) in a click.
- **Repo migration** — switch canonical repos and bring your documents along: copy, or
  verified move with an automatic pre-move vault snapshot as the recovery point.
- **Multi-document layers** — skills, memory entries, connections, and agent definitions
  are one-file-per-instance with name-derived filenames, "+ new" affordances per layer,
  and duplicate-name detection before adapter outputs can collide.
- **Connections manager** — canonical connection documents map to gateway MCP config:
  registered-vs-unregistered diagnosis against the live `openclaw.json`, previewed and
  backed-up writes where the config format is recognized, copy-ready entries where it
  isn't — and a hard refusal to ever write an inline secret.

### Learn: the return arc

Your agent doesn't stop learning after you push — it writes new memories, and deployed
instructions drift. The **context backfeed** closes that gap without ever writing behind
your back:

- **Every push records a hash ledger** of exactly what Studio wrote, so what changed
  since is a deterministic fact — no model involved, no harness file ever touched.
- **One click harvests the drift**: memories the agent wrote itself, instruction files
  edited in place. Your LLM distills each item into a schema-correct canonical
  proposal — harness dialect translated back, versions bumped, change logs appended —
  and anything that fails validation is dropped, never shown.
- **You are the merge authority.** Every proposal is a diff with source attribution and
  a one-line rationale. Accept writes canonical behind an automatic vault snapshot;
  reject is remembered forever (never re-proposed). There is deliberately no
  "Accept all."

The knowledge your agent earns at runtime stops being stranded in one tool — it flows
back into the specification every tool is trained from.

### Measure: the loop becomes provable

A specification you can't test is a hope. The **evals layer** makes yours measurable:

- **Your spec already says what to test** — every skill carries a Test Plan, every
  identity rule is a behavioral claim, every memory is a recall promise. One click
  turns them into eval cases: portable Markdown in your canonical repo, reviewed
  before saving, versioned like everything else.
- **One click runs the suite** against a harness's compiled artifacts — the same cases
  measure your OpenClaw, Hermes, Codex, and Cowork renders, fully offline with a local
  model. Hard assertions are checked in code and are final; an LLM judge grades only
  the prose expectations, and it can never overrule a deterministic failure.
- **Regressions are caught, not felt.** Every run is recorded with the exact spec
  versions it measured — change your identity and the history strip shows what broke.
  And every failure has a "Refine…" button that opens the interview seeded with
  exactly what measured wrong.

Spec → compile → measure → refine. The loop isn't a diagram anymore — it's a button.

### Share: the enterprise library

A great skill shouldn't die in one person's repo. The **enterprise library** gives
Enterprise-designated content a governed path to the whole team — with an AI gate and
a human gate between "mine" and "everyone's":

- **Contribute, vetted.** Studio finds your shareable content (Enterprise/Public only —
  PII can never be a candidate) and an AI vet screens every candidate for embedded
  personal data before Push is even enabled. Push lands in `suggested/`; Skip is
  remembered.
- **Curate, accountably.** Admin mode is a distinct experience: review suggestions and
  flag them **allowed** (into the catalog) or **disallowed** — with a required
  moderation note that stays in the audit trail forever.
- **Pull, safely.** Anyone browses the allowed catalog and pulls content into their own
  OS — validation-gated, vault-snapshotted, provenance attached ("by casey.rivera").

The library is a plain git repo of Markdown with curation stages as directories — as
portable and lock-in-free as everything else. Run several (per-org, staging vs. live):
the panel shows which repo you're pointed at and switches in two clicks. And when it's time to show any of this to
a room, **demo mode** swaps the whole app onto a fictional, validation-clean personal
OS (Nova Reyes, an invented studio founder) with every delivery path blocked — a full-featured
demo with zero real data on screen.

---

## Built like it means it

- **Native macOS** (SwiftUI, macOS 14+). No Electron, no telemetry, no accounts.
- **Zero third-party dependencies.** The entire app is first-party Swift; crypto is
  Apple CryptoKit + CommonCrypto.
- **Local-first by architecture, not policy.** The only network calls are the LLM
  provider you explicitly configure and the localhost health probes of your own
  gateways. Nothing about you leaves your machine otherwise.
- **Seriously tested.** A 20-suite headless regression battery covers every adapter
  mapping, the interview/refine/streaming flows, validation rules, diffing, git,
  scaffolding, migration, connections, the vault's crypto and recovery drills,
  multi-document naming, the backfeed's harvest/disposal chain, the eval machinery,
  the demo content, and the enterprise sharing loop — plus a byte-identical golden-master test of the full transform and a
  CI-ready `--eval` hook. All runnable from the CLI.
- **Honest UI.** Status dots never claim a tool is installed when it isn't; empty states
  say why they're empty; destructive actions preview, confirm, and back up.

## Who it's for

- **Practitioners running multiple AI harnesses** who are done maintaining four
  divergent copies of their own context.
- **Privacy-conscious professionals** who want a personal AI that genuinely knows them —
  with the personal data encrypted, versioned, classified, and provably out of git.
- **Teams standardizing agent behavior** — the enterprise library ships exactly this:
  AI-vetted contribution, admin curation with an audit trail, and validation-gated
  pulls. Skills become reviewable, versioned capability definitions rather than tribal
  prompt lore.
- **Builders of the agentic enterprise** who buy the thesis: agency is architectural,
  context is infrastructure, and specifications beat prompts.

## What's next

The loop is complete: definitions compile out, runtime learning flows back as reviewed
proposals, and the evals layer scores compiled behavior against the specification —
a written spec tuned into measured, reliable behavior. Ahead: live-harness eval
targets (driving the real tools, not just their compiled context), richer generated
coverage, and whatever running the loop every day teaches us.

---

## At a glance

| | |
|---|---|
| Platform | macOS 14+ (native SwiftUI) |
| Source of truth | Your canonical Agent OS repo — plain, portable Markdown |
| Layers | Identity · Context · Skills · Memory · Connections · Agents |
| Harnesses | OpenClaw · Hermes · OpenAI Codex · Claude Cowork |
| Authoring | Streaming LLM interviews (Ollama local, or Anthropic / OpenAI / Perplexity) |
| Feedback | Context backfeed — harness drift harvested into reviewed canonical proposals |
| Evals | Spec-derived cases · deterministic-before-judge scoring · regression history · CI hook |
| Enterprise | Shared library — AI-vetted contribute · admin curation · validation-gated pull |
| Demo | One-click fictional OS (all features, zero real data, delivery blocked) |
| Data designations | PII / Enterprise / Public, enforced end to end |
| Protection | Encrypted vault (AES-GCM, Keychain key, passphrase recovery) + local-only git |
| Quality | Executable schema validation · diffs before every write · semver + change logs |
| Network posture | Local-first; no telemetry, no accounts, no remote git operations |
| Dependencies | None — 100% first-party Swift |

*Personal OS Studio is built by [DreTech.ai](https://dretech.ai) — Architecting the
Agentic Enterprise.*
