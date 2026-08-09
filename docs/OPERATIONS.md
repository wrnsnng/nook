# Build and release operations

This document separates public, credential-free contributor work from official
distribution. Normal pull requests and CI never receive Apple, Sparkle, or
publishing credentials.

## Repositories

- Source and collaboration: `wrnsnng/nook`
- Signed binaries and update feed: `wrnsnng/nook-releases`
- Stable feed:
  `https://github.com/wrnsnng/nook-releases/releases/download/updates/appcast.xml`

The release repository remains public so installed official builds can fetch
updates without a GitHub credential.

## Open-source publication gate

Before making the source repository public, an owner must confirm that:

- Common Tools Co. owns, or has permission to license, every original code,
  documentation, and artwork file covered by Apache-2.0;
- the Nook name and visual identity have received an appropriate trademark
  clearance review in each intended launch market;
- the public Git history contains no secrets, private material, or author
  metadata the contributors do not consent to publish;
- `LICENSE`, `NOTICE`, `TRADEMARKS.md`, `THIRD_PARTY_NOTICES.md`, and all
  referenced third-party license files are present in the source distribution;
  and
- repository visibility, branch protection, security-advisory access, issue
  templates, and the default branch are configured as intended.

A trademark policy documents permitted use of marks the project is entitled to
use; it does not establish ownership, registration, or clearance against prior
rights. Record legal or provenance evidence privately rather than committing
contracts or personal records to the repository.

## Toolchains and identities

Both contributor CI and distribution builds use:

- macOS 26;
- stable Xcode 26, never a beta or release candidate; and
- XcodeGen 2.45.4.

The generated Xcode project is committed. `project.yml` is authoritative; after
changing it, run:

```sh
xcodegen generate
git diff --exit-code -- Nook.xcodeproj
```

Contributor builds use `com.localfirst.nook.dev` and `NOOK_OFFICIAL_BUILD=NO`.
That separates macOS privacy grants from the distributed app and disables the
production updater. Only the maintainer artifact workflow and release tooling
may opt into `com.localfirst.nook` with `NOOK_OFFICIAL_BUILD=YES`.

## Contributor validation

Run tests without code signing:

```sh
xcodebuild test -quiet \
  -project Nook.xcodeproj \
  -scheme Nook \
  -destination 'platform=macOS' \
  -derivedDataPath .build/DerivedData \
  CODE_SIGNING_ALLOWED=NO
```

`.github/workflows/ci.yml` performs the same credential-free validation for pull
requests and `main`, checks that XcodeGen produces no project drift, builds the
development configuration, and verifies the development bundle identity and
disabled-updater marker.

## Unsigned official-configuration artifact

`.github/workflows/stable-macos-build.yml` is manually dispatched by a
maintainer. It has read-only repository permissions and no release secrets. It:

1. selects stable Xcode 26;
2. downloads XcodeGen 2.45.4 and checks the pinned SHA-256;
3. tests with `NOOK_OFFICIAL_BUILD=YES` and
   `PRODUCT_BUNDLE_IDENTIFIER=com.localfirst.nook`;
4. builds an unsigned universal app with the same explicit settings;
5. verifies both architectures, SDK, official bundle identity, and official
   build marker; and
6. uploads the app plus a SHA-256 file for one day.

The artifact is not an official release. Before signing it, a maintainer must
verify the workflow run, source commit, artifact digest, Info.plist values, and
binary architecture.

## Release credentials

Official publication requires maintainer-controlled local access to:

- an Apple Developer ID Application identity;
- a `notarytool` Keychain profile;
- the matching Sparkle Ed25519 private key; and
- an authenticated GitHub CLI session authorized for the releases repository.

Names and paths can be supplied through the `NOOK_*` environment variables
documented by the scripts. Private keys, credentials, exported Keychain items,
provisioning profiles, and notarization records must never be committed, placed
in CI artifacts, pasted into issues, or accepted from a pull request.

## Version and release-note mapping

Update `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `project.yml`, then
regenerate the Xcode project.

- `MARKETING_VERSION` is the user-facing version, release-note filename, and
  `v<version>` GitHub tag.
- `CURRENT_PROJECT_VERSION` is the monotonically increasing Sparkle build number
  and must never be reused.
- Release notes live at `Releases/Nook-<version>.md` and are linked from
  [CHANGELOG.md](../CHANGELOG.md).

Commit the version, generated project, release note, and changelog update
together. Do not include private release logs or notarization submission IDs.

## Preparing an official release

After all automated and manual acceptance checks pass, a credentialed maintainer
can use the local release script with release notes:

```sh
NOOK_PREBUILT_APP=/absolute/path/to/Nook.app \
  ./Scripts/release-update.sh \
  --notes Releases/Nook-<version>.md
```

Review the prepared archive and feed before adding `--publish`. The script is
expected to:

1. require the official build marker and bundle identity;
2. apply component-correct Developer ID signatures and Hardened Runtime;
3. notarize, staple, and validate the app;
4. verify signatures and Gatekeeper assessment;
5. create and EdDSA-sign the update archive;
6. generate a signed appcast; and
7. refuse publication to a non-public or unexpected repository.

Release signing is an explicit local maintainer action. Do not add Apple or
Sparkle private keys to GitHub Actions to automate it.

## Verification before publication

At minimum, verify:

```sh
codesign --verify --deep --strict --verbose=2 build/Nook.app
spctl --assess --type execute --verbose=4 build/Nook.app
xcrun stapler validate build/Nook.app

/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
  build/Nook.app/Contents/Info.plist
/usr/libexec/PlistBuddy -c 'Print :NookOfficialBuild' \
  build/Nook.app/Contents/Info.plist
```

Also inspect the main app and every embedded Sparkle executable with
`codesign -d --entitlements :-`. The main app should have only its intended
entitlements; updater helpers must retain their component-specific entitlements.
Using `codesign --deep` for verification is acceptable, but it must not be used
as a blanket signing operation.

Verify the appcast contains the expected version/build, HTTPS archive URL,
archive EdDSA signature, and signed-feed block. Compare local archive SHA-256
with the uploaded release-asset digest.

## Privacy-permission QA

Test official builds from `/Applications/Nook.app` and remove duplicate copies
first. Confirm fresh grant, denial, revocation, and relaunch behavior for
Microphone, Speech Recognition, and Screen & System Audio Recording.

Do not make `tccutil reset` a normal update step. Correctly signed releases with
the stable bundle identity and designated requirement should preserve grants.

## Rollback

Prefer fixing forward with a higher build number. If a bad feed is published:

1. preserve source and user data;
2. stop promoting the bad release;
3. restore a previously verified signed appcast only when doing so preserves the
   update trust chain; and
4. publish a corrected, higher build as soon as it is verified.

Deleting or replacing public release assets is externally destructive and must
be deliberate, reviewed, and documented without exposing credentials.

## Dependency maintenance

GitHub Actions dependencies are SHA-pinned and monitored by Dependabot. Sparkle
is declared through the generated Xcode project rather than a root
`Package.swift`, so maintainers review its releases and security advisories
manually, update the exact version and resolved revision together, preserve its
complete third-party notices, and run the full update-chain acceptance pass.
