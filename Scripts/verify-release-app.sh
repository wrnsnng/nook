#!/bin/zsh
set -euo pipefail

if (( $# != 1 )); then
  echo "Usage: ./Scripts/verify-release-app.sh path/to/Nook.app" >&2
  exit 64
fi

APP_PATH="$1"
INFO_PLIST="$APP_PATH/Contents/Info.plist"
SPARKLE_FRAMEWORK="$APP_PATH/Contents/Frameworks/Sparkle.framework"
SPARKLE_VERSION_DIR="$SPARKLE_FRAMEWORK/Versions/B"
SPARKLE_INFO_PLIST="$SPARKLE_VERSION_DIR/Resources/Info.plist"
NOTICES_PATH="$APP_PATH/Contents/Resources/THIRD_PARTY_NOTICES.md"
SPARKLE_LICENSE_PATH="$APP_PATH/Contents/Resources/Sparkle-LICENSE.txt"
PROJECT_LICENSE_PATH="$APP_PATH/Contents/Resources/LICENSE"
PROJECT_NOTICE_PATH="$APP_PATH/Contents/Resources/NOTICE"
TRADEMARK_POLICY_PATH="$APP_PATH/Contents/Resources/TRADEMARKS.md"
EXPECTED_BUNDLE_IDENTIFIER="com.localfirst.nook"
EXPECTED_FEED_URL="https://github.com/wrnsnng/nook-releases/releases/download/updates/appcast.xml"
EXPECTED_PUBLIC_KEY="apOw6+icVsAh8Emfd1cwAkndoeAV71+anDE/w6rkZM8="
EXPECTED_SPARKLE_VERSION="2.9.5"
EXPECTED_SPARKLE_LICENSE_SHA256="389a4e4e9a32f059775b13a06e25a591445ba229d2838d26dd3e7c0c45127cfe"
EXPECTED_PROJECT_LICENSE_SHA256="cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30"

fail() {
  echo "Release verification failed: $1" >&2
  exit 78
}

read_plist_value() {
  /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null
}

signature_field() {
  /usr/bin/codesign --display --verbose=4 "$1" 2>&1 \
    | /usr/bin/sed -n "s/^$2=//p" \
    | /usr/bin/head -n 1
}

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
    fail "$1 must not have the $2 entitlement (found $value)."
  fi
}

[[ -d "$APP_PATH" ]] || fail "app bundle not found at $APP_PATH."
[[ -f "$INFO_PLIST" ]] || fail "Nook Info.plist is missing."
[[ -d "$SPARKLE_VERSION_DIR" ]] || fail "Sparkle Versions/B is missing."

/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_PATH" \
  || fail "the app's code signature is invalid."

BUNDLE_IDENTIFIER=$(read_plist_value "$INFO_PLIST" CFBundleIdentifier)
[[ "$BUNDLE_IDENTIFIER" == "$EXPECTED_BUNDLE_IDENTIFIER" ]] \
  || fail "bundle identifier is $BUNDLE_IDENTIFIER, expected $EXPECTED_BUNDLE_IDENTIFIER."

OFFICIAL_BUILD=$(read_plist_value "$INFO_PLIST" NookOfficialBuild)
[[ "${OFFICIAL_BUILD:l}" == "yes" || "${OFFICIAL_BUILD:l}" == "true" || "$OFFICIAL_BUILD" == "1" ]] \
  || fail "NookOfficialBuild is not enabled."

FEED_URL=$(read_plist_value "$INFO_PLIST" SUFeedURL)
[[ "$FEED_URL" == "$EXPECTED_FEED_URL" ]] \
  || fail "the Sparkle feed URL does not match the official feed."

PUBLIC_KEY=$(read_plist_value "$INFO_PLIST" SUPublicEDKey)
[[ "$PUBLIC_KEY" == "$EXPECTED_PUBLIC_KEY" ]] \
  || fail "the embedded Sparkle public key is not the official key."

for key in SUEnableAutomaticChecks SURequireSignedFeed SUVerifyUpdateBeforeExtraction; do
  value=$(read_plist_value "$INFO_PLIST" "$key")
  [[ "${value:l}" == "true" || "${value:l}" == "yes" || "$value" == "1" ]] \
    || fail "$key must be enabled."
done

SPARKLE_VERSION=$(read_plist_value "$SPARKLE_INFO_PLIST" CFBundleShortVersionString)
[[ "$SPARKLE_VERSION" == "$EXPECTED_SPARKLE_VERSION" ]] \
  || fail "Sparkle is $SPARKLE_VERSION, expected $EXPECTED_SPARKLE_VERSION."

[[ -f "$NOTICES_PATH" ]] || fail "THIRD_PARTY_NOTICES.md is not bundled."
[[ -f "$SPARKLE_LICENSE_PATH" ]] || fail "Sparkle-LICENSE.txt is not bundled."
[[ -f "$PROJECT_LICENSE_PATH" ]] || fail "the Apache 2.0 LICENSE is not bundled."
[[ -f "$PROJECT_NOTICE_PATH" ]] || fail "the project NOTICE is not bundled."
[[ -f "$TRADEMARK_POLICY_PATH" ]] || fail "TRADEMARKS.md is not bundled."
/usr/bin/grep -Fq "Sparkle $EXPECTED_SPARKLE_VERSION" "$NOTICES_PATH" \
  || fail "the bundled notices do not identify Sparkle $EXPECTED_SPARKLE_VERSION."
SPARKLE_LICENSE_SHA256=$(
  /usr/bin/shasum -a 256 "$SPARKLE_LICENSE_PATH" | /usr/bin/awk '{print $1}'
)
[[ "$SPARKLE_LICENSE_SHA256" == "$EXPECTED_SPARKLE_LICENSE_SHA256" ]] \
  || fail "the bundled Sparkle license differs from the upstream license."
PROJECT_LICENSE_SHA256=$(
  /usr/bin/shasum -a 256 "$PROJECT_LICENSE_PATH" | /usr/bin/awk '{print $1}'
)
[[ "$PROJECT_LICENSE_SHA256" == "$EXPECTED_PROJECT_LICENSE_SHA256" ]] \
  || fail "the bundled project license differs from the official Apache 2.0 text."
/usr/bin/grep -Fq "Copyright 2026 Common Tools Co." "$PROJECT_NOTICE_PATH" \
  || fail "the bundled NOTICE is missing the project attribution."
/usr/bin/grep -Fq "Nook/Resources/Brand/" "$TRADEMARK_POLICY_PATH" \
  || fail "the bundled trademark policy does not identify the reserved brand assets."

MAIN_AUTHORITY=$(signature_field "$APP_PATH" Authority)
[[ "$MAIN_AUTHORITY" == "Developer ID Application:"* ]] \
  || fail "Nook is not signed with a Developer ID Application identity."
MAIN_TEAM=$(signature_field "$APP_PATH" TeamIdentifier)
[[ -n "$MAIN_TEAM" && "$MAIN_TEAM" != "not set" ]] \
  || fail "Nook's signing team identifier is missing."

MAIN_MICROPHONE=$(
  entitlement_value "$APP_PATH" com.apple.security.device.audio-input \
    || true
)
[[ "$MAIN_MICROPHONE" == "true" || "$MAIN_MICROPHONE" == "1" ]] \
  || fail "Nook is missing its microphone entitlement."

MAIN_CALENDARS=$(
  entitlement_value "$APP_PATH" com.apple.security.personal-information.calendars \
    || true
)
[[ "$MAIN_CALENDARS" == "true" || "$MAIN_CALENDARS" == "1" ]] \
  || fail "Nook is missing its calendars entitlement."

MAIN_REMINDERS=$(
  entitlement_value "$APP_PATH" com.apple.security.personal-information.reminders \
    || true
)
[[ "$MAIN_REMINDERS" == "true" || "$MAIN_REMINDERS" == "1" ]] \
  || fail "Nook is missing its reminders entitlement."

assert_no_entitlement "$APP_PATH" com.apple.security.get-task-allow

CALENDARS_USAGE_DESCRIPTION=$(
  read_plist_value "$INFO_PLIST" NSCalendarsFullAccessUsageDescription
)
[[ -n "$CALENDARS_USAGE_DESCRIPTION" ]] \
  || fail "Info.plist is missing NSCalendarsFullAccessUsageDescription."

REMINDERS_USAGE_DESCRIPTION=$(
  read_plist_value "$INFO_PLIST" NSRemindersFullAccessUsageDescription
)
[[ -n "$REMINDERS_USAGE_DESCRIPTION" ]] \
  || fail "Info.plist is missing NSRemindersFullAccessUsageDescription."

NESTED_CODE=(
  "$SPARKLE_VERSION_DIR/XPCServices/Installer.xpc"
  "$SPARKLE_VERSION_DIR/XPCServices/Downloader.xpc"
  "$SPARKLE_VERSION_DIR/Autoupdate"
  "$SPARKLE_VERSION_DIR/Updater.app"
  "$SPARKLE_FRAMEWORK"
)

for code_path in "${NESTED_CODE[@]}"; do
  [[ -e "$code_path" ]] || fail "expected nested code is missing: $code_path."
  /usr/bin/codesign --verify --strict --verbose=2 "$code_path" \
    || fail "nested signature is invalid: $code_path."

  NESTED_TEAM=$(signature_field "$code_path" TeamIdentifier)
  [[ "$NESTED_TEAM" == "$MAIN_TEAM" ]] \
    || fail "$code_path is not signed by Nook's signing team."
  assert_no_entitlement "$code_path" com.apple.security.device.audio-input
  assert_no_entitlement "$code_path" com.apple.security.get-task-allow
done

echo "Verified official release identity, Sparkle $SPARKLE_VERSION, bundled licenses and notices, and least-privilege entitlements."
