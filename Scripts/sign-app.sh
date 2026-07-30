#!/bin/zsh
set -euo pipefail

if (( $# != 1 )); then
  echo "Usage: ./Scripts/sign-app.sh path/to/Nook.app" >&2
  exit 64
fi

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
APP_PATH="$1"
ENTITLEMENTS_FILE="$PROJECT_DIR/Nook/Nook.entitlements"

if [[ ! -d "$APP_PATH" ]]; then
  echo "App bundle not found: $APP_PATH" >&2
  exit 66
fi

SIGNING_IDENTITY="${NOOK_SIGNING_IDENTITY:-}"
if [[ -z "$SIGNING_IDENTITY" ]]; then
  SIGNING_IDENTITY="$(
    /usr/bin/security find-identity -v -p codesigning \
      | /usr/bin/sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' \
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
    "$APP_PATH"
  echo "Signed with $SIGNING_IDENTITY"
else
  echo "Warning: no Apple code-signing identity found; using an ad-hoc signature." >&2
  /usr/bin/codesign \
    --force \
    --deep \
    --entitlements "$ENTITLEMENTS_FILE" \
    --sign - \
    "$APP_PATH"
fi
