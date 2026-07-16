# F13 · PII vault — encrypted snapshots for the untracked layers

**Theme:** Operations & lifecycle · **Priority:** P1 · **Depends on:** F10 (content-tracking detection), F11 (migration hook)

## Context

The canonical repo's PII posture (`../agent_os/.gitignore`) deliberately keeps every
filled-in personal file out of git: `identity/*`, `context/*`, `memory/*`,
`connections/*`, `agents/*` are ignored, re-allowing only `*.template.md` and
`examples/` (skills are tracked as Enterprise since 2026-07-06). That posture is
correct — PII never lands in a pushable repo — but it leaves the most valuable files
in the system with **zero version history and zero backup**:

- F10's git integration explicitly detects this and shows *"Canonical files are
  gitignored — nothing to snapshot"* (`GitService.contentFilesIgnored`,
  `SnapshotBadge` in `Views/RootView.swift`). The explainer is honest, but the gap
  is real: git snapshots/history cover tracked files only.
- The editor (`Views/EditorPane.swift`) writes canonical files in place. A bad save,
  a botched refine, or an editor mistake has no undo beyond what's in the buffer.
- F11's migration (`Migrator.swift`) can **move** PII documents between repos —
  copy-verify-then-delete is careful, but there is still no independent recovery
  point before originals are removed.
- Disk failure or accidental `rm` loses the personal OS outright. Users can't rely on
  Time Machine semantics they don't control, and telling them to hand-manage copies
  of PII files defeats the tool.

What exists to build on: `GitService.contentFilesIgnored` + `Migrator.contentFiles(in:)`
already enumerate exactly the files at risk (content docs, not templates/examples);
`OpenClawService.run` is the process runner; UserDefaults persistence patterns are
established; the app is unsandboxed with ad-hoc signing (`build-app.sh`); API keys
already live in the macOS Keychain (`LLMSettings`), so the Keychain pattern is proven
in-code. CryptoKit (AES-GCM, HKDF) is available on macOS 14; PBKDF2 via CommonCrypto.

## Goal

PII documents are continuously protected without ever weakening the posture: encrypted,
versioned snapshots of all canonical content files, written automatically at the moments
that matter, restorable from inside the app — with the encryption key in the macOS
Keychain (never on disk) and a passphrase export path for machine migration/disaster
recovery. The vault directory holds only ciphertext, so it is safe to place on a synced
or external volume.

## Requirements

1. **Vault format & crypto** (`Vault/PIIVault.swift`):
   - A snapshot = manifest of `{layer-relative path → file bytes}` for every content
     document (reuse `Migrator.contentFiles(in:)` semantics: no templates, no examples),
     serialized, then sealed as **one blob per snapshot** with CryptoKit **AES-GCM**.
   - Blob filename = UTC timestamp (sortable); a small **plaintext index sidecar is
     forbidden** — listing snapshots decrypts headers only (store `{date, fileCount,
     totalBytes}` in a sealed header block, or accept decrypt-to-list).
   - Vault directory `chmod 700`, blobs `600` (mirror `HermesAdapter.tightenPermissions`
     approach). Default location `~/Library/Application Support/PersonalOSStudio/vault/`;
     user-relocatable via the vault sheet (persisted in UserDefaults like
     `canonical.root`).
2. **Key management** (`Vault/VaultKey.swift`):
   - 256-bit symmetric key generated on first use, stored as a Keychain generic password
     (service `com.dretech.PersonalOSStudio.vault`); never written to disk, never logged.
   - **Export**: user sets a passphrase → key wrapped via PBKDF2-derived KEK
     (CommonCrypto, ≥ 600k iterations, random salt) → single `.vaultkey` file the user
     stores wherever they trust. **Import** on a new machine restores the Keychain entry.
     Both flows live in the vault sheet with explicit wording that losing key + passphrase
     file means the vault is unrecoverable.
3. **Snapshot triggers** (all funnel through one `AppState.vaultSnapshot(reason:)`):
   - Manual: button in the vault sheet and on the sidebar vault badge.
   - Auto on canonical **save** (editor save, interview/bootstrap save, refine save) —
     debounced so a burst of saves yields one snapshot.
   - Auto **before a migration move** (F11 `runMigration(move: true)`) — the snapshot is
     the recovery point for the deleted originals.
   - Retention: keep the most recent N (default 30, user-configurable); prune oldest
     after each snapshot.
4. **Restore UI** (`Views/VaultSheet.swift`):
   - List snapshots (date, file count, size). Selecting one lists its documents.
   - Restore a single document or the whole snapshot into the current canonical repo;
     any overwrite shows the F09 `DiffView` (vault version vs current) and confirms
     before writing. `store.reload()` + `revalidate()` after restore.
5. **Sidebar surface** (`Views/RootView.swift`): extend the F10 empty-state note — when
   content files are gitignored AND the vault is enabled, the badge reads
   *"PII protected by vault · last snapshot <relative time>"* and opens the vault sheet;
   when the vault has never run, an amber nudge *"PII files have no backup — enable the
   vault"* replaces the passive explainer.
6. **Headless** (`--vaulttest`, registered in `PersonalOSStudioApp.swift`): deterministic
   — inject a fixed test key (no Keychain access in CI paths): seal/unseal roundtrip;
   snapshot → mutate → restore roundtrip byte-identical; prune-to-N; passphrase
   export/import roundtrip recovers the key; wrong passphrase fails cleanly; vault dir
   and blob permissions are 700/600. Keychain-touching code is isolated behind a
   protocol so the test never prompts.

## Files

Create:
- `Sources/PersonalOSStudio/Vault/PIIVault.swift` (snapshot/list/restore/prune, sealing)
- `Sources/PersonalOSStudio/Vault/VaultKey.swift` (Keychain CRUD, passphrase wrap/unwrap)
- `Sources/PersonalOSStudio/Views/VaultSheet.swift` (status, snapshots, restore, key
  export/import, location + retention settings)

Modify:
- `Sources/PersonalOSStudio/PersonalOSStudioApp.swift` (AppState wiring,
  `vaultSnapshot(reason:)`, save-path hooks, `--vaulttest`)
- `Sources/PersonalOSStudio/Views/RootView.swift` (vault badge states)
- `Sources/PersonalOSStudio/Views/EditorPane.swift`, `Views/InterviewView.swift`,
  `Views/BootstrapWizardView.swift` (snapshot-on-save hooks — one call each)
- `Sources/PersonalOSStudio/Views/OnboardingView.swift` (pre-move snapshot in
  `runMigration`)
- `Sources/PersonalOSStudio/SelfTest.swift` (`vaultTest`)

## Architecture constraints

- **The posture does not change**: PII files stay gitignored; the vault complements git,
  never feeds it. Studio never pushes, syncs, or transmits vault contents anywhere.
- Ciphertext-only at rest: nothing in the vault directory (filenames included) may leak
  document names or content. Blob names are timestamps, not paths.
- CryptoKit AES-GCM for sealing; PBKDF2 (CommonCrypto) only for the passphrase KEK.
  No third-party dependencies.
- Key lives exclusively in the Keychain at runtime; the exported `.vaultkey` is the
  user's responsibility and is itself passphrase-encrypted.
- Snapshot must be atomic: write to a temp file in the vault dir, then rename; a crashed
  snapshot never leaves a partial blob that lists as restorable.
- Restore is the only vault→repo write path, always mediated by the confirm/diff UI
  (headless restore only in `--vaulttest` against scratch dirs).
- Pure-logic layers (sealing, manifest, prune) take injected keys/clocks — fully
  testable without Keychain or UI. `rtk` prefix in docs/verification; in-app process
  calls invoke binaries directly.

## Acceptance criteria

- [ ] With the vault enabled, every editor/interview/refine save and every migration
      move produces (at most, given debounce) one new snapshot; sidebar badge shows the
      last-snapshot time.
- [ ] Deleting a PII file from the canonical repo, then restoring it from the newest
      snapshot, yields byte-identical content.
- [ ] A migration **move** can be fully reversed from the pre-move snapshot after the
      originals are gone.
- [ ] The vault directory contains only opaque blobs (700/600 perms); no plaintext PII
      or document paths are recoverable without the key (`strings` spot-check).
- [ ] Key export → `defaults`/Keychain wipe → key import on the same machine restores
      access to all prior snapshots; a wrong passphrase fails without corrupting state.
- [ ] Retention prunes to the configured N; pruning never removes the newest snapshot.
- [ ] `--vaulttest` exits 0 with no Keychain prompt; full regression battery stays green
      (`--selftest` byte-identical; all suites).

## Verification

1. `rtk swift build` clean; `--vaulttest` exit 0; full battery green.
2. GUI: enable vault → edit + save `identity/identity.md` → badge updates; delete the
   file in Finder → restore from vault → file back byte-identical (editor + validation
   agree).
3. Migration drill: move content to a scratch repo (F11), confirm pre-move snapshot
   exists, restore originals from it into the source repo.
4. Security drill: `ls -l` vault dir (700/600); `strings` on a blob shows no PII;
   export key with passphrase, delete Keychain entry (`security delete-generic-password`),
   relaunch → vault locked; import `.vaultkey` → snapshots readable again.
