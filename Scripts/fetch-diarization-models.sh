#!/bin/zsh
set -euo pipefail

# Fetches the Core ML models Nook's speaker separation runs on, at build time.
#
# Nook never downloads a model at runtime (AGENTS.md rule 5). The app bundles
# these files instead, and a build without them fails in the Nook target's
# pre-build check, so no release can silently ship without speaker labels
# (AGENTS.md rule 2).
#
# Only the offline pipeline's Community-1 artifacts are fetched, from one
# immutable Hugging Face revision, and every file must match the SHA-256 pinned
# below. The same revision is the one FluidAudio 0.17.4 pins for this
# repository. The hashes equal those Fluid Inference publishes in the
# repository's provenance.json at that revision.
#
# Usage:
#   Scripts/fetch-diarization-models.sh            fetch if missing or changed
#   Scripts/fetch-diarization-models.sh --check    verify only, never download
#   Scripts/fetch-diarization-models.sh --check DIR
#                                                  verify another copy, such as
#                                                  the one inside a built app

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
DESTINATION="$PROJECT_DIR/ThirdParty/SpeakerDiarizationModels"

REPOSITORY="FluidInference/speaker-diarization-coreml"
REVISION="df2625ac79a7ac6b65ad868fee6d80f320da4232"
BASE_URL="https://huggingface.co/$REPOSITORY/resolve/$REVISION"

# sha256, size in bytes, path relative to the repository root. The analytics
# files are part of a compiled model's layout; Core ML reads them.
MANIFEST=(
  "8d6706436639b53830b4dbe8aaf9c9a843f7f582d63e16f3cb8bb7c6ccd58682 243 Embedding.mlmodelc/analytics/coremldata.bin"
  "4a705bac27d151d9642f37609296042a15602a42253039e0921dc9e75da7e004 704 Embedding.mlmodelc/coremldata.bin"
  "1854371eb6b438fb8aeac96afb45c999af7902581c06afdfcd7ff3cb1ce66be5 2818 Embedding.mlmodelc/metadata.json"
  "22fa958aef72a561c21f874a07cbdcd30fdf40ee961c0bc2fb67c119273b46d3 78432 Embedding.mlmodelc/model.mil"
  "99356b2985b8d43880a657024d941d450b38820451ccff903f76ed4e52d1868b 13412288 Embedding.mlmodelc/weights/weight.bin"
  "0e8bd3a8b82ac123580989f490e4d9245127c535857630b543311268accc3f0a 243 FBank.mlmodelc/analytics/coremldata.bin"
  "57ac436bb0671cbb5527a339134d695f752eb77f7a18966b93c6835335595759 853 FBank.mlmodelc/coremldata.bin"
  "2623785f5d186893b82d01e84aa33a7704ef763c3309e02055f22dc9d871ce9a 3409 FBank.mlmodelc/metadata.json"
  "27aaeb21569e81bdbe2eef87789f50a37cfea800039bd134448a9417de2f30ed 15667 FBank.mlmodelc/model.mil"
  "9e83fdd3ea78064b078069e4d9141603c61c47a27fd19e7e3142ff7476f8db36 1776896 FBank.mlmodelc/weights/weight.bin"
  "8940ea6044dbcbefa22da8cc41e0b485e1fb5ed89aecaf37c6e0c483a97ddcd7 243 PldaRho.mlmodelc/analytics/coremldata.bin"
  "4d9741477f721c79b09fcdfe455110c4b7d4272e2de3496bf1729d966d3ee418 763 PldaRho.mlmodelc/coremldata.bin"
  "b314cf25a93e46b4076883a6f5a2f8848b73c3851bd9d36074d067f35a1c7945 2749 PldaRho.mlmodelc/metadata.json"
  "83aee2e5310d19b5f202aea97d07a0e12102556d1b32ef3ed08b36f7f9725041 7613 PldaRho.mlmodelc/model.mil"
  "80f7d229202636d372428c90596f11a91545f07da77259f07153aaf225914a36 200192 PldaRho.mlmodelc/weights/weight.bin"
  "64265f8e7ad41a5f68d630c15288c2499cca5892ad49e20096819cdeac004cdb 243 Segmentation.mlmodelc/analytics/coremldata.bin"
  "ea51481b8bd3e496ad3cf16f066ddaa37f20e8772eaac76b3393c28de20e06bc 812 Segmentation.mlmodelc/coremldata.bin"
  "88dbf0b07208fe142e1729c2b4c974ad3599fcb2ae5d5f18fce782b225384124 3410 Segmentation.mlmodelc/metadata.json"
  "d37e4ce30b406a6b34f765f769b9baed3178cc0c2b2e299c641daa43a052dd3f 43063 Segmentation.mlmodelc/model.mil"
  "c3189a64946c75bc24fcb98afe89ad78c52bdbadfdf65e857fb1b81e2cc9fbb2 5959360 Segmentation.mlmodelc/weights/weight.bin"
  "38ee28d4269c076cef254ee760bbd811f0738a92e0f01f9699ad372828c5de8f 89416 plda-parameters.json"
)

usage() {
  echo "Usage: Scripts/fetch-diarization-models.sh [--check [directory]]" >&2
}

# Succeeds only when the directory holds exactly the pinned files. Anything
# extra would be bundled into the app too, so it counts as a mismatch.
verify() {
  local directory="$1"
  local entry expected_hash expected_size relative_path actual_hash actual_size
  local expected_paths actual_paths

  [[ -d "$directory" && ! -L "$directory" ]] || return 1

  expected_paths=$(
    for entry in "${MANIFEST[@]}"; do print -r -- "${entry##* }"; done \
      | LC_ALL=C /usr/bin/sort
  )
  actual_paths=$(
    cd "$directory" && /usr/bin/find . -mindepth 1 ! -type d \
      | /usr/bin/sed 's|^\./||' | LC_ALL=C /usr/bin/sort
  )
  [[ "$actual_paths" == "$expected_paths" ]] || return 1

  for entry in "${MANIFEST[@]}"; do
    expected_hash="${entry%% *}"
    expected_size="${${entry#* }%% *}"
    relative_path="${entry##* }"
    [[ -f "$directory/$relative_path" && ! -L "$directory/$relative_path" ]] || return 1
    actual_size=$(/usr/bin/stat -f %z "$directory/$relative_path")
    [[ "$actual_size" == "$expected_size" ]] || return 1
    actual_hash=$(/usr/bin/shasum -a 256 "$directory/$relative_path" | /usr/bin/awk '{print $1}')
    [[ "$actual_hash" == "$expected_hash" ]] || return 1
  done
}

if (( $# > 0 )) && [[ "$1" == "--check" ]]; then
  (( $# <= 2 )) || { usage; exit 64; }
  target="${2:-$DESTINATION}"
  if verify "$target"; then
    exit 0
  fi
  echo "Speaker diarization models at $target are missing or do not match the pinned checksums." >&2
  echo "Run Scripts/fetch-diarization-models.sh, then build again." >&2
  exit 1
fi

(( $# == 0 )) || { usage; exit 64; }

if verify "$DESTINATION"; then
  echo "Speaker diarization models already present and verified at $DESTINATION."
  exit 0
fi

/bin/mkdir -p "${DESTINATION:h}"
# Stage beside the destination so the final move is a rename on one volume and
# an interrupted fetch never leaves a half-populated model folder behind.
STAGING=$(/usr/bin/mktemp -d "${DESTINATION:h}/.SpeakerDiarizationModels.XXXXXX")
trap '/bin/rm -rf "$STAGING"' EXIT

for entry in "${MANIFEST[@]}"; do
  expected_hash="${entry%% *}"
  relative_path="${entry##* }"
  /bin/mkdir -p "$STAGING/${relative_path:h}"
  echo "Fetching $relative_path"
  /usr/bin/curl --fail --silent --show-error --location \
    --proto '=https' --tlsv1.2 --retry 3 \
    "$BASE_URL/$relative_path" --output "$STAGING/$relative_path"
  actual_hash=$(/usr/bin/shasum -a 256 "$STAGING/$relative_path" | /usr/bin/awk '{print $1}')
  if [[ "$actual_hash" != "$expected_hash" ]]; then
    echo "Checksum mismatch for $relative_path: expected $expected_hash, got $actual_hash." >&2
    exit 1
  fi
done

verify "$STAGING" || {
  echo "The fetched model folder does not match the pinned manifest." >&2
  exit 1
}

/bin/chmod -R u=rwX,go=rX "$STAGING"
/bin/rm -rf "$DESTINATION"
/bin/mv "$STAGING" "$DESTINATION"
trap - EXIT
echo "Speaker diarization models fetched and verified at $DESTINATION."
