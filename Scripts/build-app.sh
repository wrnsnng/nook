#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
DERIVED_DATA_DIR="$PROJECT_DIR/DerivedData"
OUTPUT_DIR="$PROJECT_DIR/build"
SOURCE_APP="$DERIVED_DATA_DIR/Build/Products/Release/Nook.app"
OUTPUT_APP="$OUTPUT_DIR/Nook.app"
OFFICIAL_BUILD="${NOOK_OFFICIAL_BUILD:-NO}"
PRODUCT_BUNDLE_IDENTIFIER="${NOOK_PRODUCT_BUNDLE_IDENTIFIER:-com.localfirst.nook.dev}"

case "$OFFICIAL_BUILD" in
  YES|NO) ;;
  *)
    echo "NOOK_OFFICIAL_BUILD must be YES or NO." >&2
    exit 64
    ;;
esac

if [[ "$OFFICIAL_BUILD" == YES && "$PRODUCT_BUNDLE_IDENTIFIER" != com.localfirst.nook ]]; then
  echo "Official builds must use the com.localfirst.nook bundle identifier." >&2
  exit 78
fi

if [[ "$OFFICIAL_BUILD" == NO && "$PRODUCT_BUNDLE_IDENTIFIER" == com.localfirst.nook ]]; then
  echo "Community builds may not use Nook's official bundle identifier." >&2
  exit 78
fi

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
  NOOK_OFFICIAL_BUILD="$OFFICIAL_BUILD" \
  PRODUCT_BUNDLE_IDENTIFIER="$PRODUCT_BUNDLE_IDENTIFIER" \
  build

mkdir -p "$OUTPUT_DIR"
if [[ -e "$OUTPUT_APP" ]]; then
  /bin/rm -rf "$OUTPUT_APP"
fi
/usr/bin/ditto "$SOURCE_APP" "$OUTPUT_APP"

# Privacy & Security grants are attached to an app's designated requirement.
# Contributor builds default to com.localfirst.nook.dev. The release pipeline
# opts into com.localfirst.nook so an official upgrade retains the designated
# requirement associated with users' existing grants.
"$SCRIPT_DIR/sign-app.sh" "$OUTPUT_APP"

echo "Built $OUTPUT_APP"
