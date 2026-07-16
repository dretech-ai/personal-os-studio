# Security Policy

## Reporting a vulnerability

Please **do not** open a public issue for security vulnerabilities. Instead, report
privately to **security@dretech.ai** (or via GitHub's private vulnerability reporting on
this repo). We'll acknowledge within a few business days and keep you updated on the fix.

## Scope worth noting

Personal OS Studio handles personal data (PII) and cryptographic material by design:

- The **PII vault** uses AES-GCM with a 256-bit key stored only in the macOS Keychain;
  vault blobs are ciphertext-only.
- **API keys** and the vault key are never written to disk or committed — Keychain only.
- The app is **local-first**: the only outbound network calls are the user-configured
  LLM provider and localhost health probes.

Reports touching key handling, the vault's crypto, commit-exclusion of PII, or any path
that could leak personal data are especially appreciated.
