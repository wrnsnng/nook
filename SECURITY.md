# Security policy

## Supported versions

Security fixes are made for the current release line. Upgrade to the latest
signed and notarized Nook release before reporting a problem that may already be
fixed.

| Version | Supported |
| --- | --- |
| 1.6.x | Yes |
| Earlier releases | No |

## Reporting a vulnerability

Do not open a public issue for a suspected vulnerability. Use GitHub's private
[security advisory form](https://github.com/wrnsnng/nook/security/advisories/new).

Include:

- affected Nook and macOS versions;
- prerequisites and a minimal reproduction;
- expected and observed impact;
- whether meeting content, local files, permissions, signing keys, or the update
  chain are involved; and
- suggested remediation, if known.

Use synthetic data. Do not attach real recordings, transcripts, credentials,
private keys, notarization credentials, or personally identifiable meeting
information.

Maintainers aim to acknowledge a complete report within seven days. Validation,
fix, and disclosure timing depend on severity and platform coordination. Please
allow a reasonable remediation period before public disclosure.

## Security boundaries

High-impact areas include:

- ScreenCaptureKit and microphone permission handling;
- temporary recording and transcript retention;
- meeting-window and process metadata inspection;
- Markdown parsing and storage-path handling;
- Developer ID, notarization, Sparkle signing, and update verification; and
- changes that introduce any network destination or telemetry.

The Sparkle public key, bundle identifier, release URLs, and public code-signing
identity are not secrets. Private signing keys, Apple credentials, Keychain
profiles, and temporary meeting content must never enter the repository.

## Safe harbor

Good-faith research that avoids privacy violations, service disruption, data
destruction, social engineering, and accessing data that is not yours is
welcome. Stop and report immediately if you encounter another person's meeting
content or credentials.
