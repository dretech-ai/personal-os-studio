# Contributing to Personal OS Studio

Thanks for your interest! This project is a native macOS app (Swift/SwiftUI) that
compiles a tool-neutral Agent OS into live AI-harness configurations. Contributions of
all kinds are welcome — bug reports, adapters for new harnesses, docs, tests.

## Ground rules

- **Discuss big changes first.** Open an issue before a large PR so we can align on
  approach — the roadmap (`docs/roadmap/`) shows how features are scoped here.
- **Every change ships with tests.** The project has a headless self-test battery
  (`--selftest`, `--validate`, and the per-feature `--*test` flags). Add or extend a
  suite for anything you change; a PR that touches product code with no test is
  incomplete.
- **The golden master must stay green.** `--selftest` produces a byte-stable transform
  of a canonical repo. If your change alters output intentionally, say so in the PR and
  explain why.
- **Match the surrounding code.** Comment density, naming, and idiom should look like
  the file you're editing.

## Development

```sh
swift build                         # compile
./build-app.sh                      # assemble dist/Personal OS Studio.app
# Run the headless battery from inside a canonical Agent OS repo checkout:
( cd ../agent_os && /path/to/PersonalOSStudio --validate )
```

The self-contained suites (they scaffold their own scratch repos and need no external
checkout) run anywhere: `--demotest --vaulttest --evaltest --enterprisetest
--multidoctest --migratetest --gittest --scaffoldtest --backfeedtest --difftest`.

## Posture (please preserve)

- **No unreviewed writes.** Anything that touches disk or a harness previews, confirms,
  and backs up first. Model output is always human-gated.
- **Data designations are load-bearing.** PII / Enterprise / Public are enforced end to
  end; PII never enters git, and secrets live only in the Keychain — never in source,
  never in SQLite, never committed.

## Licensing

By contributing, you agree that your contributions are licensed under the project's
[Apache License 2.0](LICENSE).
