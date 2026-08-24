# Security

## Reporting

Email piarrettegauthier@gmail.com or open a GitHub Security Advisory on this repo.
Please don't file public issues for exploitable problems.

## Threat model, honestly

Highball runs Windows binaries on your Mac. That is the product, and it defines the risks.

**What Highball guarantees:**

- **Every engine component is pinned.** Wine, DXMT, runtime dylibs and D3DMetal are downloaded
  over HTTPS from their upstream releases and verified against SHA-256 hashes committed in the
  manifest *before* anything is extracted or quarantine-stripped. A mismatch aborts the install.
- **Updates are signed twice.** Releases are Developer ID-signed, hardened-runtime, notarized and
  stapled; Sparkle updates additionally verify an EdDSA signature against the public key baked
  into the app. A compromised download mirror cannot ship you a modified Highball.
- **No telemetry, no accounts, no servers.** Highball has no backend. Compatibility reports are
  user-initiated and go through GitHub in your own browser, visibly.
- **Credentials are never handled.** You log into Steam/Epic inside *their* windows. Highball
  never sees, stores, or transmits passwords.

**What Highball cannot guarantee — by design, shared with every Wine product:**

- **The app is not sandboxed.** Wine cannot run inside the macOS App Sandbox. Highball and the
  Windows programs it runs execute with your user's privileges.
- **Windows programs can reach your files.** Wine maps `Z:` to `/`, so a Windows binary you run
  in a bottle can read and write anything your user can — exactly as if you ran it on a PC.
  Only install software you trust, from vendors you trust. (An opt-in isolated-bottle mode that
  removes the `Z:` mapping is tracked in the issues.)
- **Game and launcher installers are fetched from vendor CDNs** (Steam, Epic, GOG, …) over HTTPS
  but cannot be hash-pinned, because vendors rotate them. You extend the same trust to those
  vendors as any of their users does.
- **Wine is a compatibility layer, not a security boundary.** Do not use bottles to run malware
  "safely."

## Operational notes

- Quarantine attributes are removed only from engine files whose checksums verified.
- The Sparkle private key lives in the maintainer's keychain, never in the repository.
- Database ingestion (`highball-db`) only merges community reports after maintainer review
  (label-gated GitHub Action); site rendering HTML-escapes all third-party strings.
