#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
APP_PATH="$PROJECT_DIR/build/Nook.app"
BUILD_DIR="$PROJECT_DIR/build"
FEED_DIR="$BUILD_DIR/update-feed"
DIST_DIR="$BUILD_DIR/distribution"
NOTARY_PROFILE="${NOOK_NOTARY_PROFILE:-NookNotary}"
SPARKLE_KEY_ACCOUNT="${NOOK_SPARKLE_KEY_ACCOUNT:-ed25519}"
RELEASE_REPOSITORY="${NOOK_RELEASE_REPOSITORY:-wrnsnng/nook-releases}"
PUBLISH=false
RELEASE_NOTES_PATH=""

usage() {
  echo "Usage: ./Scripts/release-update.sh [--publish] [--notes path/to/notes.md]"
  echo ""
  echo "Builds, signs, notarizes, Sparkle-signs, and packages the current Nook version."
  echo "--publish uploads the archive and stable appcast to the public release repository."
}

while (( $# > 0 )); do
  case "$1" in
    --publish)
      PUBLISH=true
      shift
      ;;
    --notes)
      [[ $# -ge 2 ]] || { usage; exit 64; }
      RELEASE_NOTES_PATH="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 64
      ;;
  esac
done

cd "$PROJECT_DIR"

if [[ -n "$RELEASE_NOTES_PATH" && ! -f "$RELEASE_NOTES_PATH" ]]; then
  echo "Release notes not found: $RELEASE_NOTES_PATH" >&2
  exit 66
fi

if [[ -n "${NOOK_PREBUILT_APP:-}" ]]; then
  if [[ ! -d "$NOOK_PREBUILT_APP" ]]; then
    echo "NOOK_PREBUILT_APP does not point to an app bundle: $NOOK_PREBUILT_APP" >&2
    exit 66
  fi
  mkdir -p "$BUILD_DIR"
  if [[ -e "$APP_PATH" ]]; then
    /bin/rm -rf "$APP_PATH"
  fi
  /usr/bin/ditto "$NOOK_PREBUILT_APP" "$APP_PATH"
  ./Scripts/sign-app.sh "$APP_PATH"
else
  if ! command -v xcodegen >/dev/null 2>&1; then
    echo "xcodegen is required." >&2
    exit 69
  fi
  NOOK_OFFICIAL_BUILD=YES \
    NOOK_PRODUCT_BUNDLE_IDENTIFIER=com.localfirst.nook \
    ./Scripts/build-app.sh
fi

# Fail before notarization if a contributor build, an outdated Sparkle binary,
# missing notices, or over-entitled updater helper entered the release path.
./Scripts/verify-release-app.sh "$APP_PATH"

RUNTIME_VERSION=$(
  /usr/bin/codesign -dv --verbose=4 "$APP_PATH" 2>&1 \
    | /usr/bin/sed -n 's/^Runtime Version=//p'
)
if [[ "$RUNTIME_VERSION" == 27.* ]]; then
  echo "Refusing to release an app built with the macOS 27 beta SDK." >&2
  echo "Build on stable Xcode 26 and provide it with NOOK_PREBUILT_APP." >&2
  exit 78
fi

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_PATH/Contents/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP_PATH/Contents/Info.plist")
UPDATE_ARCHIVE="$FEED_DIR/Nook-$VERSION.zip"
SUBMISSION_ARCHIVE="$DIST_DIR/Nook-$VERSION-notary-submit.zip"
FINAL_ARCHIVE="$DIST_DIR/Nook-$VERSION-notarized.zip"
STABLE_ARCHIVE="$DIST_DIR/Nook.zip"

mkdir -p "$FEED_DIR" "$DIST_DIR"

if [[ -e "$SUBMISSION_ARCHIVE" || -e "$UPDATE_ARCHIVE" || -e "$FINAL_ARCHIVE" ]]; then
  echo "Release output already exists for Nook $VERSION. Move it aside before retrying." >&2
  exit 73
fi

echo "Submitting Nook $VERSION ($BUILD) to Apple notarization..."
/usr/bin/ditto -c -k --keepParent "$APP_PATH" "$SUBMISSION_ARCHIVE"
xcrun notarytool submit "$SUBMISSION_ARCHIVE" \
  --keychain-profile "$NOTARY_PROFILE" \
  --wait
xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH"

./Scripts/verify-release-app.sh "$APP_PATH"
/usr/sbin/spctl --assess --type execute --verbose=4 "$APP_PATH"

/usr/bin/ditto -c -k --keepParent "$APP_PATH" "$UPDATE_ARCHIVE"
/usr/bin/ditto "$UPDATE_ARCHIVE" "$FINAL_ARCHIVE"
/bin/rm -f "$STABLE_ARCHIVE"
/usr/bin/ditto "$UPDATE_ARCHIVE" "$STABLE_ARCHIVE"

SPARKLE_TOOL_ROOT="${NOOK_SPARKLE_TOOL_ROOT:-$PROJECT_DIR/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin}"
GENERATE_APPCAST="$SPARKLE_TOOL_ROOT/generate_appcast"
GENERATE_KEYS="$SPARKLE_TOOL_ROOT/generate_keys"

if [[ ! -x "$GENERATE_APPCAST" || ! -x "$GENERATE_KEYS" ]]; then
  echo "Sparkle release tools were not resolved under DerivedData." >&2
  exit 69
fi

PUBLIC_KEY=$("$GENERATE_KEYS" --account "$SPARKLE_KEY_ACCOUNT" -p)
BUNDLE_PUBLIC_KEY=$(/usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" "$APP_PATH/Contents/Info.plist")
if [[ "$PUBLIC_KEY" != "$BUNDLE_PUBLIC_KEY" ]]; then
  echo "The Sparkle signing key does not match Nook's embedded public key." >&2
  exit 78
fi

if [[ -n "$RELEASE_NOTES_PATH" ]]; then
  /usr/bin/ditto "$RELEASE_NOTES_PATH" "$FEED_DIR/Nook-$VERSION.md"
fi

DOWNLOAD_PREFIX="https://github.com/$RELEASE_REPOSITORY/releases/download/updates/"
"$GENERATE_APPCAST" \
  --account "$SPARKLE_KEY_ACCOUNT" \
  --download-url-prefix "$DOWNLOAD_PREFIX" \
  --embed-release-notes \
  --maximum-versions 10 \
  --maximum-deltas 5 \
  -o "$FEED_DIR/appcast.xml" \
  "$FEED_DIR"

if ! /usr/bin/grep -q "sparkle:edSignature=" "$FEED_DIR/appcast.xml"; then
  echo "The generated update archive is not signed." >&2
  exit 78
fi
if ! /usr/bin/grep -q "<!-- sparkle-signatures:" "$FEED_DIR/appcast.xml"; then
  echo "The generated appcast feed is not signed." >&2
  exit 78
fi
if ! /usr/bin/grep -q "Nook-$VERSION.zip" "$FEED_DIR/appcast.xml"; then
  echo "The generated appcast does not contain Nook $VERSION." >&2
  exit 78
fi

echo "Prepared signed update:"
echo "  Archive: $UPDATE_ARCHIVE"
echo "  Appcast: $FEED_DIR/appcast.xml"

if [[ "$PUBLISH" != true ]]; then
  echo "Not published. Re-run with --publish after the public release repository is ready."
  exit 0
fi

if ! command -v gh >/dev/null 2>&1; then
  echo "GitHub CLI is required for --publish." >&2
  exit 69
fi

VISIBILITY=$(gh repo view "$RELEASE_REPOSITORY" --json visibility --jq .visibility 2>/dev/null || true)
if [[ "$VISIBILITY" != "PUBLIC" ]]; then
  echo "$RELEASE_REPOSITORY must exist and be public before OTA updates can be published." >&2
  exit 69
fi

VERSION_RELEASE_ASSETS=(
  "$UPDATE_ARCHIVE"
  "$STABLE_ARCHIVE"
)
FEED_RELEASE_ASSETS=(
  "$FEED_DIR"/*.zip(N)
  "$FEED_DIR"/*.delta(N)
  "$FEED_DIR/appcast.xml"
)
if (( ${#FEED_RELEASE_ASSETS[@]} == 0 )); then
  echo "No Sparkle update archives or deltas were generated." >&2
  exit 66
fi

# Keep the human-facing release deliberately simple: the versioned archive and
# a stable Nook.zip alias used by /releases/latest/download/Nook.zip.
if gh release view "v$VERSION" --repo "$RELEASE_REPOSITORY" >/dev/null 2>&1; then
  gh release upload "v$VERSION" "${VERSION_RELEASE_ASSETS[@]}" \
    --repo "$RELEASE_REPOSITORY" \
    --clobber
else
  NOTES_ARGUMENTS=()
  if [[ -n "$RELEASE_NOTES_PATH" ]]; then
    NOTES_ARGUMENTS=(--notes-file "$RELEASE_NOTES_PATH")
  else
    NOTES_ARGUMENTS=(--notes "Nook $VERSION")
  fi
  gh release create "v$VERSION" "${VERSION_RELEASE_ASSETS[@]}" \
    --repo "$RELEASE_REPOSITORY" \
    --title "Nook $VERSION" \
    "${NOTES_ARGUMENTS[@]}"
fi

# Historical archives and deltas live on the dedicated OTA release. The signed
# appcast uses this stable tag, so publishing a new version never exposes old
# installers on the latest human-facing release.
if gh release view updates --repo "$RELEASE_REPOSITORY" >/dev/null 2>&1; then
  gh release upload updates "${FEED_RELEASE_ASSETS[@]}" \
    --repo "$RELEASE_REPOSITORY" \
    --clobber
else
  gh release create updates "${FEED_RELEASE_ASSETS[@]}" \
    --repo "$RELEASE_REPOSITORY" \
    --title "Nook automatic updates" \
    --notes "Stable Sparkle update feed for Nook."
fi

echo "Published Nook $VERSION and updated the OTA feed."
