#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
DERIVED_DATA_DIR="$PROJECT_DIR/DerivedData"
OUTPUT_DIR="$PROJECT_DIR/build"
SOURCE_APP="$DERIVED_DATA_DIR/Build/Products/Release/Nook.app"
OUTPUT_APP="$OUTPUT_DIR/Nook.app"
ENTITLEMENTS_FILE="$PROJECT_DIR/Nook/Nook.entitlements"

cd "$PROJECT_DIR"

if command -v xcodegen >/dev/null 2>&1; then
  xcodegen generate
fi

xcodebuild \
  -project Nook.xcodeproj \
  -scheme Nook \
  -configuration Release \
  -derivedDataPath "$DERIVED_DATA_DIR" \
  CODE_SIGNING_ALLOWED=NO \
  build

mkdir -p "$OUTPUT_DIR"
if [[ -e "$OUTPUT_APP" ]]; then
  /bin/rm -rf "$OUTPUT_APP"
fi
/usr/bin/ditto "$SOURCE_APP" "$OUTPUT_APP"

# Privacy & Security grants are attached to an app's designated requirement.
# Ad-hoc signing makes that requirement depend on the binary hash, so every
# rebuild silently invalidates Screen Recording access. Prefer an installed
# Apple signing identity to keep the requirement stable across local builds.
SIGNING_IDENTITY="${NOOK_SIGNING_IDENTITY:-}"
if [[ -z "$SIGNING_IDENTITY" ]]; then
  SIGNING_IDENTITY="$(
    /usr/bin/security find-identity -v -p codesigning \
      | /usr/bin/sed -n 's/.*"\([^"]*\)".*/\1/p' \
      | /usr/bin/head -n 1 \
      || true
  )"
fi

if [[ -n "$SIGNING_IDENTITY" ]]; then
  TIMESTAMP_ARGUMENT="--timestamp=none"
  if [[ "$SIGNING_IDENTITY" == "Developer ID Application:"* ]]; then
    TIMESTAMP_ARGUMENT="--timestamp"
  fi

  /usr/bin/codesign \
    --force \
    --deep \
    --options runtime \
    "$TIMESTAMP_ARGUMENT" \
    --entitlements "$ENTITLEMENTS_FILE" \
    --sign "$SIGNING_IDENTITY" \
    "$OUTPUT_APP"
  echo "Signed with $SIGNING_IDENTITY"
else
  echo "Warning: no Apple code-signing identity found; privacy grants will reset after rebuilds."
  /usr/bin/codesign \
    --force \
    --deep \
    --entitlements "$ENTITLEMENTS_FILE" \
    --sign - \
    "$OUTPUT_APP"
fi

echo "Built $OUTPUT_APP"
