# Nook build and release operations

## Repositories

- Private source: `wrnsnng/nook`
- Public binaries and update feed: `wrnsnng/nook-releases`
- Stable feed:
  `https://github.com/wrnsnng/nook-releases/releases/download/updates/appcast.xml`

The source repository must remain private. The release repository must remain
public so Sparkle can download archives without authentication.

## Local build

Regenerate after editing `project.yml`:

```sh
xcodegen generate
```

Run the full tests:

```sh
xcodebuild test -quiet \
  -project Nook.xcodeproj \
  -scheme Nook \
  -destination 'platform=macOS' \
  -derivedDataPath .build/DerivedData \
  CODE_SIGNING_ALLOWED=NO
```

Build a universal local app:

```sh
./Scripts/build-app.sh
```

The script builds arm64 and x86_64, copies the result to `build/Nook.app`, and
uses an installed Apple code-signing identity when available. A stable
Developer ID identity is essential for reusable privacy grants.

## Release prerequisites

- Xcode 27 and command-line tools.
- `xcodegen`.
- Authenticated GitHub CLI with access to both repositories.
- `Developer ID Application: Marc Obieglo (V2KY59725J)` in the login keychain.
- `NookNotary` notarytool keychain profile.
- Sparkle Ed25519 private key in Keychain account `ed25519`.
- The public Sparkle key in the app bundle must match the Keychain private key.

No Apple or Sparkle private credential belongs in the repository.

## Versioning

Update both values in `project.yml`:

```yaml
MARKETING_VERSION: "1.6.1"
CURRENT_PROJECT_VERSION: "9"
```

- Marketing version is user-facing and becomes the GitHub release tag.
- Build version must increase monotonically for Sparkle.
- Run `xcodegen generate` and commit the resulting
  `Nook.xcodeproj/project.pbxproj` change with `project.yml`.

## Full OTA release

Write Markdown release notes, then run:

```sh
./Scripts/release-update.sh \
  --notes path/to/release-notes.md \
  --publish
```

The script:

1. Builds the universal Release app.
2. Signs it with Developer ID and Hardened Runtime.
3. Submits a zip to Apple notarization and waits.
4. Staples and validates the notarization ticket.
5. Verifies the deep code signature and Gatekeeper assessment.
6. Packages the notarized app for Sparkle.
7. Generates signed deltas from retained releases.
8. Generates and signs `appcast.xml`.
9. Publishes only the current versioned archive and stable `Nook.zip` alias
   under the new version tag.
10. Publishes the complete historical feed snapshot and signed appcast under
    the stable `updates` tag.

Human-facing version releases contain only:

- `Nook-<version>.zip`, the versioned notarized archive.
- `Nook.zip`, a stable alias for
  `https://github.com/wrnsnng/nook-releases/releases/latest/download/Nook.zip`.

Historical archives, deltas, and the signed appcast live on the dedicated
`updates` release. This keeps the latest release unambiguous without breaking
Sparkle update paths.

## Release verification

After publication, verify:

```sh
spctl --assess --type execute --verbose=4 build/Nook.app
xcrun stapler validate build/Nook.app
codesign --verify --deep --strict --verbose=2 build/Nook.app

gh release view "v<version>" \
  --repo wrnsnng/nook-releases

curl -fsSL \
  https://github.com/wrnsnng/nook-releases/releases/download/updates/appcast.xml
```

The newest appcast item must contain:

- the expected `<sparkle:version>` build number
- the expected `<sparkle:shortVersionString>`
- the current archive URL
- `sparkle:edSignature` on the archive
- a final `sparkle-signatures` block
- a delta from the immediately previous build when generation succeeds

Compare the local archive SHA-256 with the GitHub release asset digest.

## Current release

As of 5 August 2026:

- Version: **1.6.4**
- Build: **12**
- Release:
  `https://github.com/wrnsnng/nook-releases/releases/tag/v1.6.4`
- Notarization submission:
  `888970ec-e072-4f96-bec4-2993a8e1daf5`
- Status: stable macOS 26.5 SDK build; accepted, stapled, Gatekeeper accepted
- Sparkle delta from build 11: published
- Test suite: 49 passing tests

## Building a release without local stable Xcode

`release-update.sh` refuses any app whose runtime version is 27.x, so a machine
that only has Xcode 27 installed cannot produce a releasable build directly.

Push the release commit to `agent/release-nook-1-6`, let the
`Stable macOS build` workflow produce the universal `Nook-stable-unsigned`
artifact on a `macos-26` runner, then sign, notarize, and publish it locally:

```sh
gh run download <run-id> --repo wrnsnng/nook --name Nook-stable-unsigned --dir /tmp/stable
ditto -x -k /tmp/stable/Nook-stable-unsigned.zip /tmp/stable

NOOK_PREBUILT_APP=/tmp/stable/Nook.app ./Scripts/release-update.sh \
  --notes Releases/Nook-<version>.md \
  --publish
```

Confirm the artifact before signing it:

```sh
vtool -show-build /tmp/stable/Nook.app/Contents/MacOS/Nook   # sdk must not be 27
lipo -archs /tmp/stable/Nook.app/Contents/MacOS/Nook          # arm64 and x86_64
```

Verify the shipped binary still contains toolchain-sensitive code paths. Nook
1.6.2 and 1.6.3 lost live transcription because a `#if compiler(>=6.4)` fence
compiled the audio converter out of every stable-toolchain build while local
Xcode 27 builds kept it:

```sh
nm -a /tmp/stable/Nook.app/Contents/MacOS/Nook | grep -c Resampling
```

## Privacy-permission QA

Test distributed builds from `/Applications/Nook.app`. Remove duplicate app
copies first so Launch Services cannot open the wrong path.

If an older or incorrectly signed build left stale TCC decisions, reset once:

```sh
tccutil reset Microphone com.localfirst.nook
tccutil reset SpeechRecognition com.localfirst.nook
tccutil reset ScreenCapture com.localfirst.nook
```

Then launch the notarized app from `/Applications`, accept each requested
permission, and allow the required relaunch after Screen & System Audio
Recording is granted.

Do not make TCC reset a normal update step. A correctly signed build with the
stable designated requirement should preserve grants.

## Release rollback

If a bad feed is published:

1. Do not delete meeting data or alter the source repository history.
2. Restore the previous known-good `appcast.xml` asset on the `updates` release.
3. Mark the bad version release as a prerelease or remove only its public
   release assets if necessary.
4. Fix forward with a higher build number; never reuse a Sparkle build number.

GitHub release deletion is externally destructive and should be deliberate.
