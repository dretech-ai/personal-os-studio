# F12 · Connections manager (openclaw.json)

**Theme:** Operations & lifecycle · **Priority:** P3 · **Depends on:** — (F01 helps if the config surface generalizes per harness later)

## Context

The canonical Connections layer (`../agent_os/connections/*.md`, template
`connection.template.md`) describes integrations an agent can reach — frontmatter
includes `name` and `mechanism` (`builtin` / `cli` / `mcp` / `api`), and the body carries
`## Capabilities`, `## Access Mode`, `## Configuration`, `## Security Notes` H2s. The
OpenClaw adapter spec (`../agent_os/adapters/openclaw.md`) maps `mechanism: mcp`
connections to entries in **`openclaw.json`** — OpenClaw's own config file in its state
dir — and the adapter contract's rules apply (read-only connections must be registered
in a write-preventing way; capabilities list is the source of truth).

Studio currently punts: `OpenClawAdapter.noteConnections` emits a warning — *"Connections
are configured in openclaw.json, not workspace files. N connection file(s) selected —
review and register them manually…"* — and `Views/BuildPushPanel.swift` renders it. Studio
never reads or writes `openclaw.json`. The stated v1 safety rule was "openclaw.json is
never auto-edited" (README), so this feature must keep every write **explicit, previewed,
and backed up** — it upgrades manual guidance to guided registration, not silent
automation.

Plumbing: `OpenClawService.stateDir` (where `openclaw.json` lives — verify the exact
filename/location against the adapter spec and a real install before coding),
`Frontmatter`/`MarkdownSections` for parsing connection docs, `.bak-studio` backup
convention in `push`, the confirmation-dialog + preview-sheet patterns in
`BuildPushPanel`, and (if F09 landed) `DiffView` for config diffs.

## Goal

A Connections panel that parses canonical connection docs, shows what's registered vs
unregistered in the live `openclaw.json`, and performs guided, previewed, backed-up
registration edits for `mechanism: mcp` connections — replacing the "configure manually"
warning with a safe workflow.

## Requirements

1. `Connections/ConnectionDoc.swift`: parse a connections-layer `CanonicalFile` into a
   typed model (name, mechanism, capabilities list, access mode, configuration block,
   designation, status) via `Frontmatter`/`MarkdownSections`. Tolerate missing sections
   with warnings rather than failing.
2. `Connections/OpenClawConfig.swift`: locate + load `openclaw.json` from the state dir
   (via `JSONSerialization`, order-preserving edits — modify the minimal subtree, keep
   unknown keys byte-stable where JSONSerialization allows; if key-order preservation
   proves impossible, do a text-targeted edit of the mcp-servers subtree instead — decide
   during implementation against the real file shape and document the choice in code).
   Expose: registered server names, and `register(connection:) -> proposed new config
   text`.
3. **Panel UI** (a sheet from the build panel's connections warning area, or a dedicated
   section in `BuildPushPanel` when connection files are included): each included
   connection doc shows mechanism badge, registration status
   (registered / unregistered / not-applicable-for-mcp), access mode, and capabilities
   count. Non-mcp mechanisms render guidance text only (from the adapter spec's mapping
   table) — no writes.
4. **Guided registration flow** for `mechanism: mcp`: propose the JSON edit built from the
   doc's `## Configuration` block; show before/after (F09 `DiffView` if present, else
   old/new panes); require explicit confirmation (destructive-style confirm like the push
   dialog); on accept — back up `openclaw.json` to `.bak-studio`, write, verify re-parse,
   log to the push log. Secrets: **never** write literal secrets — if the configuration
   block references env vars/keychain, pass the reference through verbatim; if it embeds
   what looks like a literal secret, refuse with a security note (per the layer's
   Security Notes rules).
5. Read-only connections (`access mode: read-only`): include the spec's write-prevention
   flag/pattern in the proposed entry when representable; otherwise annotate the preview
   with a manual step callout.
6. Post-registration: the existing "restart gateway container" button is surfaced in the
   flow ("restart for changes to take effect").
7. If `openclaw.json` is absent/unparseable: read-only diagnosis ("config not found at
   <path>"), no write path offered.

## Files

Create:
- `Sources/PersonalOSStudio/Connections/ConnectionDoc.swift`
- `Sources/PersonalOSStudio/Connections/OpenClawConfig.swift`
- `Sources/PersonalOSStudio/Views/ConnectionsPanel.swift`

Modify:
- `Sources/PersonalOSStudio/OpenClawAdapter.swift` (`noteConnections` → richer signal the
  panel consumes; keep the textual warning as fallback)
- `Sources/PersonalOSStudio/Views/BuildPushPanel.swift` (entry point + status row)
- `Sources/PersonalOSStudio/OpenClawService.swift` (config path helper, backup reuse)

## Architecture constraints

- Honor the v1 safety posture: no write without an explicit per-connection confirmation +
  automatic backup; all writes locally verifiable (re-parse after write; on failure,
  restore the backup automatically and report).
- Never log or display secret values; redact anything matching common token shapes in
  previews.
- Verify the real `openclaw.json` schema empirically before coding the edit shape (the
  live install is at the state dir on this machine); pin what you implement in a comment
  with the observed version, mirroring how `OpenClawAdapter` pins its spec.
- `@MainActor ObservableObject` UI state; `rtk` prefix in verification; no new deps.

## Acceptance criteria

- [ ] Connection docs render with correct mechanism/status; a doc registered in the live
      config shows "registered".
- [ ] Registering an unregistered mcp connection: preview shows a minimal, correct JSON
      delta; accept → backup exists, config re-parses, entry present; gateway restart
      offered.
- [ ] Literal-secret configuration is refused with the security note; env-var references
      pass through.
- [ ] Failed write (e.g. read-only file) auto-restores the backup and reports.
- [ ] Non-mcp mechanisms show guidance only; absent config → diagnosis only.
- [ ] `--selftest` unchanged (its connections warning path still works).

## Verification

1. `swift build` clean.
2. Scratch drive: copy the real `openclaw.json` to a scratch state dir with a fake
   workspace; register the example calendar-read connection (enable examples in a scratch
   canonical checkout); inspect the delta, the `.bak-studio`, and re-parse.
3. Corrupt the scratch config → panel degrades to diagnosis.
4. Live (optional, with care): register a real connection, restart the gateway, verify
   via the OpenClaw dashboard that the server appears.
