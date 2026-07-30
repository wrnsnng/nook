#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
DERIVED_DATA_DIR="$PROJECT_DIR/DerivedData"
OUTPUT_DIR="$PROJECT_DIR/build"
SOURCE_APP="$DERIVED_DATA_DIR/Build/Products/Release/Nook.app"
OUTPUT_APP="$OUTPUT_DIR/Nook.app"

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
# Keep signing in one script so local and stable CI-built artifacts use the
# same identity, entitlements, hardened runtime, and timestamp policy.
"$SCRIPT_DIR/sign-app.sh" "$OUTPUT_APP"

echo "Built $OUTPUT_APP"
