#!/bin/zsh
set -euo pipefail

if (( $# != 1 )); then
  echo "Usage: ./Scripts/verify-release-archive.sh path/to/Nook.zip" >&2
  exit 64
fi

ARCHIVE_PATH="$1"

fail() {
  echo "Archive verification failed: $1" >&2
  exit 78
}

[[ -f "$ARCHIVE_PATH" ]] || fail "$ARCHIVE_PATH does not exist"

# ditto stores extended attributes as ._* AppleDouble entries unless told not
# to. Archive Utility folds them back into attributes, but unzip and many
# managed-Mac installers write them out as files. Inside Sparkle.framework that
# is unsealed content, so the extracted app fails codesign (-67008) and
# Gatekeeper refuses to launch it with no override offered.
metadata_entries=$(
  /usr/bin/zipinfo -1 "$ARCHIVE_PATH" \
    | /usr/bin/grep -E '(^|/)(\._|__MACOSX/|\.DS_Store$)' \
    || true
)
if [[ -n "$metadata_entries" ]]; then
  print -r -- "$metadata_entries" | /usr/bin/head -n 10 >&2
  fail "the archive contains Finder metadata entries"
fi

WORK_DIR=$(/usr/bin/mktemp -d)
trap '/bin/rm -rf "$WORK_DIR"' EXIT

# Check the app the way a user receives it: extracted by plain unzip, which
# keeps anything the archive holds, and quarantined like a browser download.
/usr/bin/unzip -q "$ARCHIVE_PATH" -d "$WORK_DIR"
APP_PATH="$WORK_DIR/Nook.app"
[[ -d "$APP_PATH" ]] || fail "the archive does not contain Nook.app at its root"

/usr/bin/xattr -w com.apple.quarantine \
  "0081;$(printf %x "$(date +%s)");Safari;" \
  "$APP_PATH"

/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_PATH" \
  || fail "the extracted app does not pass strict code signature verification"
/usr/sbin/spctl --assess --type execute --verbose=4 "$APP_PATH" \
  || fail "Gatekeeper rejects the extracted app"

echo "Archive verified: $ARCHIVE_PATH"
