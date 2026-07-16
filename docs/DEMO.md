# Personal OS Studio — Guided Demo (Demo Mode)

A ~20-minute live walkthrough hitting every major capability — run almost entirely in
**🎭 Demo mode**, so nothing on screen is your real PII, no harness can be touched, and
the whole thing resets with two clicks. The story: **define once → author by interview
→ trust it → compile it everywhere → measure the loop.**

Steps marked 🎬 are the live actions; **Say:** lines are the talking points.
Steps marked ⚠️ are demo-risk notes (mostly LLM latency).

---

## 0 · Pre-flight (2 minutes — demo mode kills most of the old checklist)

- [ ] Launch `dist/Personal OS Studio.app` (built from `main`).
- [ ] Provider: pick **Anthropic** for snappy streaming (Provider button, toolbar).
      Ollama works fully offline but streams slower. ⚠️
- [ ] Click the 🎭 **Demo** button in the toolbar once, confirm the orange banner and
      the Nova Reyes files, click around freely — then **Exit demo**. (Any mess you
      make rehearsing is discarded; every entry rebuilds the content fresh.)
- [ ] Optional live finale only: confirm the OpenClaw gateway is up and plant the
      backfeed prop (see Act 9).

**Reset button, mid-demo:** Exit demo → Demo. Fresh content, deterministic.

---

## 1 · The idea (2 min)

**Say:** "Everyone here maintains AI tool instructions — and everyone maintains them
several times, badly. OpenClaw wants SOUL.md, Codex wants AGENTS.md in a repo, Claude
wants paste blocks. Same person, same context, four dialects, all drifting. The idea:
**define the agent once, in tool-neutral Markdown, and compile it** — like source code
for who your AI is."

🎬 Click 🎭 **Demo** in the toolbar. The banner appears.

**Say:** "This is demo mode — a complete personal OS for a fictional user so I don't
have to show you mine. Meet **Nova Reyes** and his Chief-of-Staff agent, **Beacon**.
Everything you'll see is publicly known lore — and note the app has physically disabled
every button that could touch a real AI tool while we're in here."

🎬 Sidebar tour: six layers (Identity, Context, Skills, Memory, Connections, Agents),
each file tagged **PII / Enterprise / Public**.

## 2 · What the content looks like (4 min — this is the heart of the demo)

🎬 Open `identity/identity.md`: agent identity (Beacon), user profile ("never
'Ms. Reyes'"), **Operating Principles** ("The playtest is the source of truth"), **Boundaries**
("never announce an unannounced title", "never schedule before 11am"), **Escalation** ("ask
Priya before changing the schedule; build/pipeline issues go to Marcus").

**Say:** "This is the shape of it: durable rules, not prompts. Note the file explains
its own classification — identity is *always* PII by schema rule, even for a fictional persona."

🎬 Quick flips: `context/team.md` (Priya owns ops, Marcus is 'brilliant,
temperamental, keep tasks short', Biscuit is morale officer) → a skill,
`skills/plan-a-playtest.md` — point at **Trigger → Procedure → Test Plan** ("the
Test Plan gets *executed* later, hold that thought") → `memory/MEMORY.md` index +
`biscuit-favorite-toy.md` (a typed memory entry with a recall hook).

**Say:** "Six layers, one schema each, versioned with change logs, all plain Markdown
in a git repo — readable, diffable, yours. No lock-in."

## 3 · Author by interview (3 min)

🎬 Hover the **Skills** header → click **+** ("New skill") → answer 2–3 questions for
something studio-flavored (e.g. a "unblock-marcus" skill). Point out **streaming**
and the agent asking for a kebab-case name. ⚠️ Keep answers short.
🎬 **Generate file** → **Save** — the filename came from the interview
(`skills/unblock-marcus.md`), and the browser now shows three skills.

**Say:** "Nobody writes these from a blank page. An interviewer asks, schemas shape
the answers, and deterministic guardrails fix whatever the model gets wrong. And
because we're in demo mode, this edit is disposable — exit and re-enter, and Nova's
OS is factory-fresh."

## 4 · Trust: validation + versioning (2 min)

🎬 Open `identity/identity.md`, delete the `> **Classification: PII**` banner line,
**Save** → the red **error strip** appears (banner.presence).
🎬 Re-add the line, **Save** → the **"Version bump?"** sheet appears; accept with a
one-line summary.

**Say:** "The schema checklists are executable — every doc is linted live, every save
is version-disciplined. And on the real OS, every save also lands in an encrypted
vault: AES-GCM snapshots, key in the macOS Keychain, history for exactly the PII files
that deliberately never enter git." *(Point at the vault badge in the sidebar — don't
open snapshot details in front of a room; those are your real snapshot timestamps.)*

## 5 · Compile: one spec, four harnesses (4 min)

🎬 Train → **OpenClaw** → **Train from canonical** → preview `SOUL.md`: Beacon'
principles rendered in OpenClaw's dialect, provenance comment on top.
🎬 Point at the push section: **disabled**, with the demo-mode note.

**Say:** "In demo mode the app physically won't deliver — on my real OS this button
writes the workspace and restarts the gateway container. What matters: same canonical
source, four completely different render targets."

🎬 Flip through: **Hermes** (same spec, different file layout), **Codex** (single
repo-scoped AGENTS.md; mention PII is auto-excluded from git at the destination),
**Claude Cowork** (paste blocks — copy disabled here too, uniformly).

## 6 · Measure: the evals layer (4 min)

**Say:** "A spec you can't test is a hope. Remember that skill Test Plan? Watch."

🎬 Train → OpenClaw → **Evaluate against spec…** — two pre-made cases are already
there: *Recall: Biscuit's favorite toy* and *Skill: plan a playtest ends with the demo
reel*. Show a case file if asked: Prompt, Expectation, `Must Contain` assertions.
🎬 **Run** both. ⚠️ Two LLM calls per case. Expect green passes with judge reasons.
🎬 The money shot: open `memory/biscuit-favorite-toy.md`, change the toy from the carrot
to the **tennis ball**, save → re-**Train** → re-**Run** → the recall case **fails
deterministically** (the transcript now names the banned tennis ball) + regression flag
→ click **Refine…** → the interview opens *already talking about the failed
expectation*. Cancel out.

**Say:** "Spec → compile → measure → refine. Assertions are checked in code and can't
be argued with; an LLM judge only grades the prose expectations. Failures feed the
refine interview. That loop is the whole product."

🎬 **Exit demo → Demo** — everything resets. "And that's the demo reset: two clicks."

## 7 · Headless finale (1 min)

🎬 In a terminal (the demo repo is a real repo on disk):
```bash
cd ~/Library/Application\ Support/PersonalOSStudio/demo-agent-os
/path/to/PersonalOSStudio --validate        # 0 errors — the linter, CI-ready
/path/to/PersonalOSStudio --eval openclaw   # the eval suite — same, CI-ready
```

**Say:** "Everything you just saw has a headless twin — a 20-suite regression battery
plus these CI hooks. The app is tested against itself the same way your agent is
tested against its spec."

## 8 · Optional live segment: the enterprise library (4 min, uses the real OS)

The team story — how a good skill escapes one person's repo. Enterprise is disabled in
demo mode (fictional content must never enter the shared repo), so this act runs on the
real OS; the shared repo is local and the content is Enterprise-designated, so nothing
personal appears on screen.

- 🎬 **Exit demo** → toolbar **Enterprise** → point at the repo bar ("admins switch
  between org repos here — two clicks") → Client mode: point at the candidates
  (Enterprise-designated content only — "PII physically cannot appear here") → **AI
  vet** one → point at the verdict line → **Push to suggested…**
- 🎬 Flip the picker to **Admin** — "a different job, a different look": review the
  pending suggestions (including seeded ones from fictional colleagues), **Allow** one,
  **Disallow…** another and show that the moderation note is required and kept forever.
- 🎬 Back to **Client** → the catalog → **Pull** a colleague's skill (e.g.
  weekly-status-rollup "by casey.rivera") into the local OS — validation-gated, vault
  snapshot first, provenance attached.

**Say:** "Contribute with an AI gate, curate with a human gate and an audit trail, pull
with a validation gate. Skills stop being tribal prompt lore and become reviewed,
versioned capability definitions."

## 9 · Optional live segment: the backfeed (3 min, uses the real OS)

Only if the room wants to see the return arc live — this is the one act demo mode
deliberately can't do, because it reads a real harness.

- Pre-plant (before the session) — write a fake "learned" memory into a real harness
  workspace you control (adjust the path to your OpenClaw workspace):
  ```bash
  cat > "<your-openclaw>/workspace-<name>/memory/demo-learned.md" <<'EOF'
  # Playtest note
  Learned in conversation — the team prefers Friday playtests over Mondays.
  EOF
  ```
- 🎬 **Exit demo** → Train → OpenClaw → **Check for harness updates…** → the planted
  memory appears as drift → **Generate proposals** → review the diff → **Accept**
  (vault snapshot first). **Say:** "What the agent learns at runtime flows back into
  the spec — as a reviewed proposal, never an auto-write."
- Cleanup after: delete the accepted memory + the workspace prop, re-push to reset the
  ledger. (Or skip this act entirely and just describe it over Act 5.)

## 10 · Close (30 sec)

**Say:** "Eighteen features, one loop — and now a team story on top. Define once in
Markdown you own. Compile to every tool. Validate, version, and encrypt the personal
parts. Harvest what the agents learn. Measure everything. Share the enterprise-grade
parts with an AI gate and a human gate. And demo it all without showing you a single
real fact about me — except that I clearly like building loops. Questions?"

---

## If things go wrong live

- **LLM slow/down** → switch provider (sidebar badge) to Ollama; Acts 1–2, 4–5 and 7
  need no model at all.
- **Keychain prompt appears** → Always Allow; explain keys never live on disk.
- **Demo content in a weird state** → Exit demo → Demo. Always fixes it.
- **Accidentally exited demo with the room watching** → the sidebar shows your real
  repo name; click 🎭 Demo again before opening any file.
