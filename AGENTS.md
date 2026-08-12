# Working on Nook with an AI agent

Instructions for any coding agent working in this repository. This file is the
canonical one; tool-specific files point here rather than repeating it.

Nook is a local-first meeting notebook and dictation tool for macOS, written in
Swift 6 with SwiftUI and AppKit. It is not sandboxed, targets macOS 26, and is
distributed as a signed, notarized app with Sparkle updates.

Read [CONTRIBUTING.md](CONTRIBUTING.md) for the human process. This file covers
what an agent gets wrong.

## Commands

```sh
# Regenerate the Xcode project. Required after adding, moving or deleting ANY
# file, including test files.
xcodegen generate

# Build
xcodebuild build -quiet -project Nook.xcodeproj -scheme Nook \
  -destination 'platform=macOS' -derivedDataPath .build/DerivedData \
  CODE_SIGNING_ALLOWED=NO

# Test
xcodebuild test -quiet -project Nook.xcodeproj -scheme Nook \
  -destination 'platform=macOS' -derivedDataPath .build/DerivedData \
  CODE_SIGNING_ALLOWED=NO
```

Tests use swift-testing, not XCTest. The XCTest summary line reports
`Executed 0 tests`; the real result is the `Test run with N tests` line.

## Rules that are not negotiable

### 1. `project.yml` is the source of truth

Sources are listed explicitly in the generated project. A new file that is not
regenerated **is silently not compiled**, and a new test file that is not
regenerated **silently does not run**. A green test run therefore proves nothing
until you have confirmed the file is in the project.

```sh
xcodegen generate
git diff --exit-code -- Nook.xcodeproj   # must be committed together
```

### 2. Never make behaviour depend on the building toolchain

Versions 1.6.2 and 1.6.3 shipped a `#if compiler(>=6.4)` fence around live audio
conversion. Local builds kept the feature, every release build silently lost it,
and meetings produced no transcript for weeks.

Do not introduce `#if compiler(...)`, `#if canImport(...)`, or availability
forks that change shipped behaviour. If an API exists only in a newer SDK, use
an alternative that exists everywhere. Behaviour that differs by Xcode or SDK is
a release blocker, not a tradeoff.

### 3. Swift 6 strict concurrency, including at runtime

`SWIFT_STRICT_CONCURRENCY: complete`. Beyond what the compiler catches:

A closure written inside a `@MainActor` type **inherits main-actor isolation**,
even when handed to an SDK callback that fires on another queue. The SDK types
are often not annotated, so this compiles cleanly and then traps at runtime with
`dispatch_assert_queue`. It has already happened once here, in the
`AVAudioEngine` tap.

Give such closures an explicit `@Sendable` type, and mark everything they call
`nonisolated`:

```swift
let tap: @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void = { buffer, _ in ... }
input.installTap(onBus: 0, bufferSize: 4_096, format: format, block: tap)
```

Also: unstructured `Task {}` gives no ordering guarantee. Do not spawn one per
item for anything order-sensitive; use a single `AsyncStream` with one consumer.
And a task group awaits every child, so it cannot implement a timeout race. Use
`withDeadline(seconds:)` in `LiveTranscriptionService.swift`.

### 4. No em-dashes in user-facing copy

A hard rule for every string a user can read: buttons, help text, alerts,
settings footers, placeholders, onboarding. Use a comma, a colon, or two
sentences. Comments and documentation are exempt.

`InterfaceCopyTests` enforces this and will fail the build with a file and line.
Its allowlist exists only for strings that match text produced by other software
(browser window titles), not for copy.

### 5. Local-first is the product, not a preference

Audio, transcripts, summaries and notes stay on the Mac. There is exactly one
exception: note actions can be routed to a locally installed Claude Code or
Codex CLI, and that path requires explicit per-provider consent, shows a
persistent warning while active, and is off by default.

Any new network call needs a product, privacy and security rationale, an
explicit opt-in, and a `docs/PRIVACY.md` update in the same change. Do not add
telemetry, analytics, crash reporting, or a remote model.

Nook never handles anyone's credentials. The CLI bridge runs the user's own
signed-in tool over stdin with no shell, so there is no token to store or leak.
Do not replace this with reading an OAuth token from the keychain: that
credential belongs to another application, and reusing it puts the user's
account at risk.

### 6. Model output is never trusted

Dictated speech and spoken notes routinely read as instructions, and a language
model will act on them. Every model result is checked against the input before
it reaches a document, and the user's own words are used when it drifts. See
`DictationOutputGuard`. Keep this property when adding model-backed features.

### 7. Credentials and identity

Never commit keys, notarization records, provisioning profiles, recordings,
transcripts, or real meeting content. Use synthetic content in tests.

Contributor builds use `com.localfirst.nook.dev` with `NOOK_OFFICIAL_BUILD=NO`
and no updater. Only the release tooling opts into the official identity. Do not
change these defaults in `project.yml`; release paths override the bundle
identifier explicitly and would not override a new setting you add.

## House style

- Comments explain **why**, especially where the obvious approach is wrong.
  Several files document a specific bug the current shape prevents. Do not
  delete that context.
- Match the surrounding code: naming, comment density, and structure.
- Tests are named as behaviour, not as methods, and assert user-visible
  outcomes. Add one for any behaviour change.
- Prefer deterministic code over a model call where both are possible. Clean-up
  in `DisfluencyFilter` is a fixed word list precisely so it cannot invent text.

## Things that look like bugs and are not

- The 2x2 pixel video stream in `CaptureService` is a ScreenCaptureKit
  requirement for capturing system audio. It is discarded.
- `MeetingDetector` and `SummaryService` contain em-dashes in string matches.
  They match other applications' window titles and older note titles.
- Carbon's `RegisterEventHotKey` is used deliberately for the dictation
  shortcut. It reports key release and needs no Accessibility permission, which
  no modern API does together.

## Local development notes

Running tests with `CODE_SIGNING_ALLOWED=NO` into the same derived data path as
a signed build re-signs the app ad hoc. Since an ad-hoc signature's designated
requirement is a bare cdhash, macOS then treats every rebuild as a different
application and drops its Accessibility and microphone grants. Use a separate
derived data path for tests when you are also running a signed local build.

`tccutil reset` is acceptable for the development bundle identity when
diagnosing this. It must never become a normal step for releases, which are
expected to preserve permission grants across updates.

## Documentation map

| File | Contents |
| --- | --- |
| [docs/PRODUCT.md](docs/PRODUCT.md) | Product promise, principles, UX contract |
| [docs/TECHNICAL.md](docs/TECHNICAL.md) | Architecture |
| [docs/PRIVACY.md](docs/PRIVACY.md) | What is captured, stored, sent, deleted |
| [docs/OPERATIONS.md](docs/OPERATIONS.md) | Build, signing, release |
| [docs/ACCESSIBILITY.md](docs/ACCESSIBILITY.md) | Accessibility acceptance |
| [docs/HANDOFF.md](docs/HANDOFF.md) | Current state, durable constraints, manual acceptance |

Propose major product or architecture changes in a public issue before
implementing them.

## What CI cannot verify

Automated tests cannot exercise macOS privacy prompts, real microphones, system
audio, physical displays, or an installed update. Passing CI is not evidence
that a capture, permission, dictation or update change works. Say plainly what
you verified and what still needs a human at a Mac.
