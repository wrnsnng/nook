# Contributing to Nook

Thank you for helping make Nook more reliable, private, and accessible.

## Before opening an issue

- Search existing issues for the same behavior.
- Use [SECURITY.md](SECURITY.md) for vulnerabilities or accidental disclosure of
  meeting content, credentials, signing material, or personal data.
- Use [SUPPORT.md](SUPPORT.md) for installation and usage questions.
- For detection reports, include the meeting provider, native app or browser,
  macOS version, and whether the problem was a false positive or missed meeting.
  Redact meeting names, participant names, and company information.

## Development setup

Contributor builds require no release credentials and use the development
bundle identity with automatic updates disabled.

1. Use macOS 26 and stable Xcode 26.
2. Install XcodeGen 2.45.4.
3. Regenerate the committed project and verify it is unchanged:

   ```sh
   xcodegen generate
   git diff --exit-code -- Nook.xcodeproj
   ```

4. Run the tests:

   ```sh
   xcodebuild test -quiet \
     -project Nook.xcodeproj \
     -scheme Nook \
     -destination 'platform=macOS' \
     -derivedDataPath .build/DerivedData \
     CODE_SIGNING_ALLOWED=NO
   ```

Open `Nook.xcodeproj` and run the `Nook` scheme for interactive work. Local
capture testing requires granting macOS permissions to that local build.

## Making a change

- Keep each pull request focused on one coherent problem.
- Add or update tests for behavior changes.
- Update `project.yml` first when changing targets, settings, packages, or source
  membership, then regenerate and commit `Nook.xcodeproj` in the same change.
- Do not add release credentials, notarization data, private keys, provisioning
  profiles, recordings, transcripts, or real meeting fixtures.
- Use synthetic meeting content in tests and screenshots.
- Preserve local-first behavior. New network communication requires an explicit
  product, privacy, and security rationale.
- Treat permission copy, recording indicators, deletion behavior, update
  verification, and signing configuration as security-sensitive.

## User-interface changes

Verify relevant changes in light and dark appearances and with:

- VoiceOver;
- keyboard-only navigation;
- Reduce Motion;
- Reduce Transparency;
- Increased Contrast; and
- a notched MacBook and non-notched external display when panel geometry changes.

See [docs/ACCESSIBILITY.md](docs/ACCESSIBILITY.md) for the acceptance checklist.

## Pull requests

Pull requests should explain the user-visible outcome, test evidence, privacy or
security impact, and any manual verification still needed. Maintainers may ask
for a smaller change or additional evidence when platform behavior is difficult
to reproduce.

CI runs without signing or publishing credentials. Passing CI does not replace
manual permission, capture, audio-quality, display-geometry, or update testing.

By participating, you agree to follow the [Code of Conduct](CODE_OF_CONDUCT.md).
Unless you explicitly state otherwise, code and documentation intentionally
submitted for inclusion in Nook are provided under the
[Apache License 2.0](LICENSE), as described in section 5 of that license. Do not
submit third-party or generated material unless you have the rights necessary
to license it on those terms. Brand and logo contributions are not accepted
through ordinary pull requests and require a separate written agreement with a
maintainer. Maintainers cannot accept contributions that are marked as not
being contributions or that carry terms incompatible with Apache-2.0.
