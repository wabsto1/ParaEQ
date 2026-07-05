# Contributing to ParaEQ

## Building

```bash
bash build.sh          # release build + signed .app bundle at .build/ParaEQ.app
swift test             # DSP/parser unit tests (no audio hardware required)
```

Requirements: macOS 14.4+, Xcode command-line tools (Swift 5.10+). No external
dependencies.

## Development signing

The System Audio Recording permission (TCC) is keyed to the code signature.
With ad-hoc signing, macOS re-prompts after every rebuild. Create a stable
local identity once and `build.sh` picks it up automatically:

1. Create a self-signed certificate named **ParaEQ Dev Signing** with the
   Code Signing extension (Keychain Access → Certificate Assistant, or openssl
   + `security import` + `security add-trusted-cert -p codeSign`).
2. Rebuild — the grant now survives rebuilds.

## Releases (notarized distribution)

Pushing a `v*` tag triggers `.github/workflows/release.yml`, which builds,
signs (Developer ID + hardened runtime), notarizes, staples, and attaches
`ParaEQ.zip` to the GitHub release. It stays dormant (exits with a notice)
until these repository secrets are configured:

| Secret | Value |
|---|---|
| `MACOS_CERTIFICATE` | base64 of the "Developer ID Application" `.p12` (`base64 -i cert.p12 \| pbcopy`) |
| `MACOS_CERTIFICATE_PASSWORD` | the `.p12` password |
| `MACOS_SIGNING_IDENTITY` | e.g. `Developer ID Application: Your Name (TEAMID)` |
| `APPLE_API_KEY` | base64 of an App Store Connect API `.p8` key |
| `APPLE_API_KEY_ID` | that key's ID |
| `APPLE_API_ISSUER_ID` | the App Store Connect issuer ID |

Local releases: one-time `xcrun notarytool store-credentials paraeq-notary …`,
then `scripts/release.sh "Developer ID Application: Your Name (TEAMID)"`.

## Ground rules

- Read `docs/ARCHITECTURE.md` first — especially the "Hard-won platform
  gotchas" section. Several innocuous-looking changes (listener queues, array
  assignments on the audio thread, aggregate dictionary shape) cause deadlocks
  or silent audio loss.
- The IO callback must stay allocation-free and lock-free.
- Every DSP change needs a test in `Tests/ParaEQTests`. The suite runs offline;
  filter behavior is asserted on synthesized signals.
- Verify live after engine changes: run the app, play audio, and check
  `~/Library/Logs/ParaEQ.log` shows non-zero peaks and no restart loops.
