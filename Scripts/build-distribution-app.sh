#!/bin/zsh
# Builds, tests and verifies the unsigned official-configuration app, then
# zips it with a checksum. The distribution workflow and a maintainer's Mac run
# this same script, so a local release candidate is built exactly as CI would.
#
# Requires stable Xcode 27 (the macOS 27 SDK) and the pinned XcodeGen. Output:
#   <output-dir>/Nook-stable-unsigned.zip and .zip.sha256
set -euo pipefail

OUTPUT_DIR=${1:-$PWD}
PROJECT_DIR=${0:A:h:h}
cd "$PROJECT_DIR"

if xcodebuild -version | grep -Eiq '(beta|rc)' || ! xcodebuild -version | grep -Eq '^Xcode 27'; then
  echo "Distribution builds require stable Xcode 27." >&2
  xcodebuild -version >&2
  exit 1
fi

if [[ -n "$(git status --porcelain)" ]]; then
  echo "Refusing to build a candidate from a checkout with uncommitted changes." >&2
  exit 1
fi

xcodegen generate
git diff --exit-code -- Nook.xcodeproj

# Build-time only. The Nook target refuses to build without these pinned,
# checksum-verified models, and the app never downloads them.
./Scripts/fetch-diarization-models.sh

DERIVED=.build/StableDerivedData
xcodebuild test -quiet \
  -project Nook.xcodeproj \
  -scheme Nook \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED" \
  NOOK_OFFICIAL_BUILD=YES \
  PRODUCT_BUNDLE_IDENTIFIER=com.localfirst.nook \
  CODE_SIGNING_ALLOWED=NO

xcodebuild build -quiet \
  -project Nook.xcodeproj \
  -scheme Nook \
  -configuration Release \
  -derivedDataPath "$DERIVED" \
  ARCHS='arm64 x86_64' \
  ONLY_ACTIVE_ARCH=NO \
  NOOK_OFFICIAL_BUILD=YES \
  PRODUCT_BUNDLE_IDENTIFIER=com.localfirst.nook \
  CODE_SIGNING_ALLOWED=NO

app="$DERIVED/Build/Products/Release/Nook.app"
executable="$app/Contents/MacOS/Nook"
info="$app/Contents/Info.plist"
test -d "$app"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info")" = 'com.localfirst.nook'
test "$(/usr/libexec/PlistBuddy -c 'Print :NookOfficialBuild' "$info")" = 'YES'
./Scripts/fetch-diarization-models.sh --check "$app/Contents/Resources/SpeakerDiarizationModels"
lipo -archs "$executable" | grep -q arm64
lipo -archs "$executable" | grep -q x86_64
if ! vtool -show-build "$executable" | grep -q 'sdk 27'; then
  echo "Refusing an app not linked against the macOS 27 SDK." >&2
  exit 1
fi

mkdir -p "$OUTPUT_DIR"
( cd "$app/.." && /usr/bin/ditto -c -k --keepParent Nook.app "$OUTPUT_DIR/Nook-stable-unsigned.zip" )
( cd "$OUTPUT_DIR" && shasum -a 256 Nook-stable-unsigned.zip > Nook-stable-unsigned.zip.sha256 )
echo "Built $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info") ($(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$info")) from $(git rev-parse HEAD)"
cat "$OUTPUT_DIR/Nook-stable-unsigned.zip.sha256"
