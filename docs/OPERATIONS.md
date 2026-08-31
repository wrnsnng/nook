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

The artifact is not an official release. Dispatch the workflow at the reviewed
candidate ref, after committing all intended source files, the generated
project, version and release notes. A local test of uncommitted changes does not
validate an artifact built from an earlier commit.

Before signing, record and verify the source repository and full commit SHA,
workflow path, successful run ID and its `headSha`, artifact ID and digest, and
the checksum of the inner `Nook-stable-unsigned.zip`. The GitHub artifact
container and the ZIP inside it are different files with different digests.
Retain the downloaded artifact and checksum in an ignored, candidate-specific
directory before its one-day retention expires. Check the app's exact version
and build, both `arm64` and `x86_64` slices, stable SDK, official bundle identity
and official-build marker independently of the workflow's checks.

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

## Preparing a signed candidate

A credentialed maintainer may sign and notarize a candidate for physical QA.
Preparation is not publication. All automated and manual release acceptance
must pass on the candidate before publishing the version release or promoting
the update feed. Follow [HANDOFF.md](HANDOFF.md#manual-release-acceptance) and
the release-specific acceptance record; signing does not close those gates.

Use the verified stable-workflow artifact rather than rebuilding it on a local
beta toolchain. Prefer a clean checkout or worktree of its exact source commit
for preparation, so the signing script, entitlements and release notes match
the artifact. Preserve the original unsigned artifact outside that checkout's
`build/Nook.app`: the release script deletes that destination before copying
`NOOK_PREBUILT_APP`, so the input must not be that same path or an alias of it.

Complete these checks **before** starting the release script:

1. Verify the source/run/artifact provenance above and the candidate's exact
   `CFBundleShortVersionString` and `CFBundleVersion`. Confirm the version/tag
   is unused and its Sparkle build is higher than every published build. Keep
   `project.yml` and the generated project in agreement. Neither the release
   script nor `verify-release-app.sh` enforces the intended version, build or
   monotonicity.
2. Explicitly select the known Developer ID Application identity using
   `NOOK_SIGNING_IDENTITY`. Compare its team with the previous supported
   official app. After signing, compare the candidate's team and designated
   requirement with that app as well. The verifier accepts any nonempty
   Developer ID team with matching nested code; it does not pin the expected
   team. A new signature hash is expected, but an unexplained identity or
   designated-requirement change is a blocker for preserving macOS grants.
3. Confirm an authenticated check using the configured `NOOK_NOTARY_PROFILE`
   succeeds and that the existing Sparkle key is accessible to the release tools.
   Inspect only its public key
   with `generate_keys --account <account> -p` and compare it with the candidate's
   `SUPublicEDKey` and the official key in `verify-release-app.sh`. Do not create
   a replacement key, export a private key, or treat a timed-out credential
   prompt as success. Keep notarization and credential diagnostics private.
4. Set `NOOK_SPARKLE_TOOL_ROOT` to an absolute path to the pinned Sparkle tools;
   verify `generate_keys`, `generate_appcast` and `sign_update` exist and are
   executable. For the usual local dependency checkout the path is
   `.build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin`, not the
   release script's default `DerivedData/...`. Resolve the absolute path before
   entering a separate preparation worktree. Check key access before expensive
   preparation: the script currently reaches these checks only after
   notarization and versioned archive creation.
5. Confirm the preparation directory contains no outputs for this candidate
   version. Review any retained historical update archives and deltas that the
   appcast generator will include. Use exactly the public repository
   `wrnsnng/nook-releases`, with `NOOK_RELEASE_REPOSITORY` set explicitly. The
   script checks only repository visibility, not this exact repository name.

Replace the placeholders with the verified values and run this **once, without
`--publish`**, from the matching source checkout:

```sh
NOOK_PREBUILT_APP=/absolute/path/to/verified-unsigned/Nook.app \
NOOK_SIGNING_IDENTITY='Developer ID Application: <verified identity>' \
NOOK_NOTARY_PROFILE='<configured profile>' \
NOOK_SPARKLE_KEY_ACCOUNT='<existing matching account>' \
NOOK_SPARKLE_TOOL_ROOT=/absolute/path/to/nook/.build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin \
NOOK_RELEASE_REPOSITORY=wrnsnng/nook-releases \
  ./Scripts/release-update.sh --notes 'Releases/Nook-<version>.md'
```

This applies component-specific Developer ID signatures and Hardened Runtime,
notarizes and staples the app, checks Gatekeeper, packages the update, and signs
the archive and appcast. Without `--publish` it exits before GitHub writes.
It still contacts Apple's signing/notarization services and accesses local
release credentials; it is an explicit maintainer action.

The script is **one-shot, not resumable**. Its final suggestion to rerun with
`--publish` is unsafe: the rerun replaces/re-signs `build/Nook.app` and then
refuses the existing versioned archives. Do not rerun it to publish, and never
delete, rebuild or re-sign verified outputs to get past the guard. Preserve
partial results on failure, inspect the failed stage, and resume only the
necessary verified packaging or upload step. Use the publication sequence
below for completed candidates. Do not put Apple or Sparkle private keys in
GitHub Actions.

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
/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
  build/Nook.app/Contents/Info.plist
/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' \
  build/Nook.app/Contents/Info.plist
lipo -archs build/Nook.app/Contents/MacOS/Nook
vtool -show-build build/Nook.app/Contents/MacOS/Nook
codesign -d -r- --verbose=4 build/Nook.app
```

Also inspect the main app and every embedded Sparkle executable with
`codesign -d --entitlements :-`. The main app should have only its intended
entitlements; updater helpers must retain their component-specific entitlements.
Using `codesign --deep` for verification is acceptable, but it must not be used
as a blanket signing operation.

Verify the exact version/build, expected signing team and designated requirement,
both architectures, and stable SDK again on the signed app. Confirm all candidate
acceptance records refer to this source and artifact; an earlier development
build is not the release candidate.

Parse the prepared appcast and verify the candidate item's version/build,
minimum system version, exact HTTPS download URL under
`wrnsnng/nook-releases/releases/download/updates/`, archive byte length and
EdDSA signature. Inspect every referenced archive and delta, not just the first
matching signature. Verify the signed feed and each artifact cryptographically;
the script's `grep` checks prove only that signature fields are present.
The pinned `sign_update` supports `--verify <archive> <signature>` and
`--verify <appcast.xml>`, with `--account <existing matching account>`. Its
verification mode still accesses the configured Keychain key. Do not edit XML
or release notes after signing.

Record SHA-256 and byte length for the prepared appcast, update archive, all
deltas, and `build/distribution/Nook.zip`. The stable alias, versioned update
ZIP and `Nook-<version>-notarized.zip` must contain the same finalized archive
bytes. Generate `Nook.zip.sha256` from that exact alias; the nonpublishing script
does not create this checksum file. Never upload the notary submission archive
or private signing/notarization records.

## Publishing previously verified artifacts

The human-facing `v<version>` GitHub release and the Sparkle `updates` release
are separate publication steps. The former controls the download page and
`releases/latest/download/Nook.zip`; replacing `updates/appcast.xml` promotes
the version to installed apps. Do not use `release-update.sh --publish` for
either step after candidate preparation.

1. Recheck that the destination is exactly **PUBLIC
   `wrnsnng/nook-releases`**, the version has never been published, the Sparkle
   build is still unused and increasing, and all acceptance gates are complete.
   Retain a private copy and SHA-256 of the current public signed appcast for
   rollback. Verify that old feed before relying on it. Keep the source commit
   and workflow/artifact provenance with the candidate record, and link the
   source commit in the release notes. A tag in the separate binary repository
   does not identify the source commit by itself.
2. A maintainer may prepare a **draft** `v<version>` release for review before
   acceptance is complete, using `--draft --latest=false`. Upload only the
   verified `Nook-<version>.zip`, `Nook.zip` and `Nook.zip.sha256`, without
   `--clobber`. A draft is not a published release and must not be advertised as
   latest or used as a public update URL. If the draft already belongs to this
   candidate, resume by comparing asset digests and uploading only missing
   files. Any existing asset with different bytes is a blocker, not permission
   to replace it. Never replace historical version assets or move their tags.
3. After acceptance, upload the **new** update archive and any new deltas to
   the existing `updates` release, without `--clobber`. Use an explicit reviewed
   file list, not a wildcard that also includes the feed or historical files.
   For example, this uploads only the new archive:

   ```sh
   gh release upload updates 'build/update-feed/Nook-<version>.zip' \
     --repo wrnsnng/nook-releases
   ```

   Compare each asset's GitHub SHA-256 digest and size with the recorded local
   values, then download its intended public HTTPS URL to a separate directory
   and verify the bytes and archive/delta signature. Existing referenced assets
   must also match their expected bytes. Do not promote a feed with missing,
   inaccessible or mismatched targets. A safe upload retry skips an existing
   byte-identical asset; it never overwrites it.
4. Verify the version release's assets the same way. If it was a draft, publish
   that verified draft only after acceptance; deliberately marking it latest is
   a separate decision. If no draft was prepared, create the new version release
   with the already verified assets at this point. Re-download the public
   version URLs and, when promoted to latest, `Nook.zip` and its checksum through
   the latest-download URLs. Verify them against the candidate manifest. Do not
   publish the `updates` release as the latest human-facing version.
5. **Replace the appcast last**, only after acceptance and after every target
   URL has passed the checks above. Recheck the local feed's digest and signature
   and confirm the current public feed still matches the saved rollback copy.
   If another release changed it, stop and reconcile that publication rather
   than overwrite it. Then perform this narrowly scoped operation:

   ```sh
   gh release upload updates build/update-feed/appcast.xml \
     --repo wrnsnng/nook-releases --clobber
   ```

   This is the sole intended replacement: never include archives, deltas or
   wildcards with this flag. GitHub CLI deletes the old asset before uploading
   its replacement, so a failure can leave the feed temporarily absent. Keep
   the verified old feed available privately and use the reviewed rollback
   procedure if needed; do not rebuild or re-sign the candidate as a retry.
6. Download the public appcast again, compare its exact digest with the prepared
   feed, verify its signature, and recheck its version/build, URLs and lengths.
   Download and verify the referenced candidate archive and any promoted deltas
   again. Record the public release/asset IDs, digests and verified URLs. Only
   after these checks may the release be described as published and verified.

GitHub upload success alone is not verification, and publishing the version
release does not imply that the update feed has been promoted. Keep both states
explicit in the release record. Do not force-push release tags or replace an
old signed installer to repair a failed promotion.

## Privacy-permission QA

Test official builds from `/Applications/Nook.app` and remove duplicate copies
first. Confirm fresh grant, denial, revocation, and relaunch behavior for
Microphone, Speech Recognition, Screen & System Audio Recording, and the
separate direct-access/private-window-picker consent. Confirm both screen-access
layers are completed in onboarding before starting a real recording.

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
