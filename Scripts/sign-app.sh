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
SPARKLE_FRAMEWORK="$APP_PATH/Contents/Frameworks/Sparkle.framework"
SPARKLE_VERSION_DIR="$SPARKLE_FRAMEWORK/Versions/B"

if [[ ! -d "$APP_PATH" ]]; then
  echo "App bundle not found: $APP_PATH" >&2
  exit 66
fi

if [[ ! -d "$SPARKLE_VERSION_DIR" ]]; then
  echo "Sparkle.framework is missing its expected Versions/B directory." >&2
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

if [[ -z "$SIGNING_IDENTITY" ]]; then
  echo "Warning: no Apple code-signing identity found; using an ad-hoc signature." >&2
  SIGNING_IDENTITY="-"
fi

TIMESTAMP_ARGUMENT=(--timestamp=none)
if [[ "$SIGNING_IDENTITY" == "Developer ID Application:"* ]]; then
  TIMESTAMP_ARGUMENT=(--timestamp)
fi

sign_nested_code() {
  local code_path="$1"
  shift
  if [[ ! -e "$code_path" ]]; then
    echo "Expected nested code is missing: $code_path" >&2
    exit 66
  fi

  /usr/bin/codesign \
    --force \
    --options runtime \
    "${TIMESTAMP_ARGUMENT[@]}" \
    "$@" \
    --sign "$SIGNING_IDENTITY" \
    "$code_path"
}

# Sparkle ships helpers with different entitlement requirements. Sign them
# inside-out as documented by Sparkle instead of using --deep, which would
# incorrectly copy Nook's microphone entitlement onto every nested process.
sign_nested_code \
  "$SPARKLE_VERSION_DIR/XPCServices/Installer.xpc"
sign_nested_code \
  "$SPARKLE_VERSION_DIR/XPCServices/Downloader.xpc" \
  --preserve-metadata=entitlements
sign_nested_code "$SPARKLE_VERSION_DIR/Autoupdate"
sign_nested_code "$SPARKLE_VERSION_DIR/Updater.app"
sign_nested_code "$SPARKLE_FRAMEWORK"

# Nook is the only executable that receives Nook's privacy entitlement.
/usr/bin/codesign \
  --force \
  --options runtime \
  "${TIMESTAMP_ARGUMENT[@]}" \
  --entitlements "$ENTITLEMENTS_FILE" \
  --sign "$SIGNING_IDENTITY" \
  "$APP_PATH"

entitlement_value() {
  local entitlements
  local key_path="${2//./\\.}"
  entitlements=$(
    /usr/bin/codesign --display --entitlements :- "$1" 2>/dev/null
  )
  [[ -n "$entitlements" ]] || return 1
  print -rn -- "$entitlements" \
    | /usr/bin/plutil -extract "$key_path" raw -o - - 2>/dev/null
}

assert_no_entitlement() {
  local value
  if value=$(entitlement_value "$1" "$2"); then
    echo "Refusing over-entitled nested code: $1 has $2=$value" >&2
    exit 78
  fi
}

for nested_code in \
  "$SPARKLE_VERSION_DIR/XPCServices/Installer.xpc" \
  "$SPARKLE_VERSION_DIR/XPCServices/Downloader.xpc" \
  "$SPARKLE_VERSION_DIR/Autoupdate" \
  "$SPARKLE_VERSION_DIR/Updater.app" \
  "$SPARKLE_FRAMEWORK"; do
  assert_no_entitlement \
    "$nested_code" \
    com.apple.security.device.audio-input
  assert_no_entitlement \
    "$nested_code" \
    com.apple.security.get-task-allow
done

/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_PATH"

if [[ "$SIGNING_IDENTITY" == "-" ]]; then
  echo "Signed with an ad-hoc identity."
else
  echo "Signed with $SIGNING_IDENTITY"
fi
