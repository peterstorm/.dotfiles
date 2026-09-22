#!/usr/bin/env bash
# Download the DeepSeek-V4-Flash-Vision-Exp checkpoint pinned by the
# Karmic Kraken beta ds4-vision profile.
#
# ~168 GB / 156.3 GiB (48 shards + configs), pinned to the exact revision the upstream
# Karmic Kraken benchmark ran (benchmarks/karmic-kraken-serving.md samples
# JSON, kk.checkpoint.revision) and the pinned image's profile derives. Writes
# the native Hugging Face hub cache layout into
# /models/hf-cache/ds4-flash-vision-karmic-kraken-v1 (a dedicated ZFS dataset,
# no compression), which the serving container mounts at
# /root/.cache/huggingface — the same mount the upstream doc's named volume
# would hold, but host-resident and verifiable. Runs in a throwaway container
# based on the pinned image because it already ships huggingface_hub + hf_xet;
# the host has no python/hf CLI on purpose. Idempotent + resumable: re-run to
# continue. On success writes .download-complete ($REPO $REV) into the cache
# root and a receipt after verifying all 84 pinned files (including the four
# checkpoint metadata hashes the benchmark evidence records); the run script
# refuses to launch without the marker.
#
# --hydrate-from <flat-dir>: when a content-identical copy of the checkpoint
# already exists on the host (the r21-era local download at
# ~/models/DeepSeek-V4-Flash-Vision-Exp), build the hub-cache snapshot layout
# from it instead of re-downloading ~168 GB. The pinned revision
# (6821d6ad...) changes README.md and adds two .eval_results files relative
# to the r21 revision (86f746b3...); all 48 weight shards are byte-identical
# (HF LFS oids == Karmic Kraken evidence kk.checkpoint.shards blobs,
# cross-checked 2026-09-21). The 81 reusable files are size- and sha256-
# verified before any symlink is created; after the three changed/added files
# are fetched from the pinned revision (or reused only when content matches),
# all 84 snapshot files are verified before readiness is committed. Snapshot
# symlinks point at the flat copy, so serving must mount that source
# at the same absolute path; deleting it invalidates the cache.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

REPO="deepseek-ai/DeepSeek-V4-Flash-Vision-Exp"
REV="6821d6ad3681a4b137b066b76094fa82ebd0a380"
IMAGE_CONFIG="sha256:83f00757ff18f3c3c12de291319b1a3a5496056a3873834d0994160828a3c6ee"
CACHE_HOST="${CACHE_HOST:-/models/hf-cache/ds4-flash-vision-karmic-kraken-v1}"
NAME="ds4-flash-vision-karmic-kraken-v1-dl"
STATE_DIR="$HOME/.local/state/ds4-vision"
RECEIPT="${RECEIPT:-$STATE_DIR/karmic-kraken-v1-checkpoint.txt}"
DL_SCRIPT="$STATE_DIR/karmic-kraken-v1-download-entrypoint.sh"
MODE="${1:---detach}"
FLAT_DIR="${2:-}"
MANIFEST="$SCRIPT_DIR/ds4-vision-karmic-kraken-v1.manifest"
HYDRATE_SOURCE_FILE="$CACHE_HOST/.hydrate-source"
# Files changed or added between the r21 revision (86f746b3) and the pinned
# revision (6821d6ad): HF tree API git blob oids, 2026-09-21.
PINNED_ONLY_FILES=("README.md" ".eval_results/deep-swe.yaml" ".eval_results/terminal-bench-2.1.yaml")

# Checkpoint metadata sha256s recorded in the Karmic Kraken benchmark evidence
# (karmic-kraken-serving-samples.json, kk.checkpoint.metadata_sha256). The
# download is only accepted when the pinned snapshot reproduces all four.
METADATA_SHA256=(
  "config.json:6cd841bdd6702f5e2ac34671bc78047ed80817102465525ae2a41c502abbcd75"
  "generation_config.json:5fccff80f55a4d455bbe516bdd552edf3e9623df95e99fbf2a3c3389fdf91af0"
  "tokenizer_config.json:6ac8c8dc065ed118161d02dd532749ae3f52c243deac27872134fae2f50d8547"
  "model.safetensors.index.json:507977e3d3818865264e68c0fdab139aa7f3929d0d0cf693dacc47428da56395"
)

case "$MODE" in
  --detach | --wait | --verify) ;;
  --hydrate-from)
    [ -n "$FLAT_DIR" ] || { echo "usage: ${0##*/} --hydrate-from <flat-checkpoint-dir>" >&2; exit 2; } ;;
  *) echo "usage: ${0##*/} [--detach|--wait|--verify|--hydrate-from <flat-checkpoint-dir>]" >&2; exit 2 ;;
esac

verify_manifest_directory() {
  local directory="$1" label="$2" skip_pinned="${3:-0}" expected records
  records="$(awk '
    /^#/ || NF == 0 { next }
    NF != 3 || length($1) != 64 || $1 !~ /^[0-9a-f]+$/ ||
      $2 !~ /^[1-9][0-9]*$/ || $3 ~ /^\// || $3 == ".." ||
      $3 ~ /^\.\.\// || $3 ~ /\/\.\.\// || $3 ~ /\/\.\.$/ { exit 2 }
    { count++ }
    END { if (count != 84) exit 3; print count }
  ' "$MANIFEST")" || {
    echo "error: invalid checkpoint manifest: $MANIFEST (expected 84 safe sha256 records)" >&2
    return 1
  }
  expected=84
  [ "$skip_pinned" = 0 ] || expected=81
  awk -v skip="$skip_pinned" '
      /^#/ || NF == 0 { next }
      skip == 1 && ($3 == "README.md" || $3 == ".eval_results/deep-swe.yaml" ||
        $3 == ".eval_results/terminal-bench-2.1.yaml") { next }
      { print }
    ' "$MANIFEST" \
    | xargs -r -P 8 -n 3 bash -c '
        root="$1"; label="$2"; sha="$3"; size="$4"; path="$5"
        file="$root/$path"
        [ -f "$file" ] || { echo "error: $label file is missing: $path" >&2; exit 1; }
        actual_size="$(stat -Lc %s "$file")"
        [ "$actual_size" = "$size" ] || {
          echo "error: $label size mismatch: $path ($actual_size != $size)" >&2
          exit 1
        }
        actual_sha="$(sha256sum "$file")"; actual_sha="${actual_sha%% *}"
        [ "$actual_sha" = "$sha" ] || {
          echo "error: $label sha256 mismatch: $path" >&2
          exit 1
        }
      ' _ "$directory" "$label"
  printf 'PASS: %s manifest (%s/%s selected files sha256-verified)\n' \
    "$label" "$expected" "$records"
}

verify_snapshot() {
  local snapshot_dir="$1" file digest actual
  [ -f "$snapshot_dir/config.json" ] || {
    echo "error: pinned snapshot is incomplete at $snapshot_dir" >&2
    return 1
  }
  verify_manifest_directory "$snapshot_dir" "checkpoint snapshot"
  for record in "${METADATA_SHA256[@]}"; do
    file="${record%%:*}"
    digest="${record#*:}"
    actual="$(sha256sum "$snapshot_dir/$file")"; actual="${actual%% *}"
    [ "$actual" = "$digest" ] || {
      echo "error: $file sha256 is $actual, benchmark evidence pins $digest" >&2
      return 1
    }
  done
}

write_receipt() {
  local snapshot_dir="$1" files bytes receipt_tmp
  files="$(awk '!/^#/ && NF {count++} END {print count}' "$MANIFEST")"
  bytes="$(awk '!/^#/ && NF {sum += $2} END {printf "%.0f\n", sum}' "$MANIFEST")"
  install -d -m 700 "$(dirname "$RECEIPT")"
  receipt_tmp="$(mktemp "$(dirname "$RECEIPT")/.ds4v-kk-v1-checkpoint.XXXXXX")"
  {
    printf 'repo=%s\nrevision=%s\nsnapshot=%s\nfiles=%s\nbytes=%s\nmanifest_sha256_verified=84\n' \
      "$REPO" "$REV" "$snapshot_dir" "$files" "$bytes"
    printf 'metadata_sha256_verified=%s\n' "$(printf '%s\n' "${METADATA_SHA256[@]}" | cut -d: -f1 | tr '\n' ',' | sed 's/,$//')"
  } >"$receipt_tmp"
  chmod 600 "$receipt_tmp"
  mv -f "$receipt_tmp" "$RECEIPT"
  if [ -r "$CACHE_HOST/.hydrate-provenance" ]; then
    cat "$CACHE_HOST/.hydrate-provenance" >>"$RECEIPT"
  fi
  printf 'CHECKPOINT OK: %s@%s (84 files sha256-verified; %s bytes) — receipt %s\n' \
    "$REPO" "$REV" "$bytes" "$RECEIPT"
}

write_hydrate_state() {
  local source="$1" fetched="$2" source_tmp provenance_tmp
  source_tmp="$(mktemp "$CACHE_HOST/.hydrate-source.XXXXXX")"
  printf '%s\n' "$source" >"$source_tmp"
  mv -f "$source_tmp" "$HYDRATE_SOURCE_FILE"
  provenance_tmp="$(mktemp "$CACHE_HOST/.hydrate-provenance.XXXXXX")"
  printf 'hydrate_source=%s\nhydrate_manifest_sha256_verified=84\nhydrate_fetched_real=%s\nhydrate_dependency=%s (deleting it invalidates the cache)\n' \
    "$source" "$fetched" "$source" >"$provenance_tmp"
  mv -f "$provenance_tmp" "$CACHE_HOST/.hydrate-provenance"
}

verify_checkpoint() {
  local marker snapshot_dir
  if [ ! -r "$CACHE_HOST/.download-complete" ]; then
    echo "error: $CACHE_HOST/.download-complete is missing; the download has not completed" >&2
    return 1
  fi
  marker="$(<"$CACHE_HOST/.download-complete")"
  [ "$marker" = "$REPO $REV" ] || {
    echo "error: marker is '$marker', expected '$REPO $REV'" >&2
    return 1
  }
  snapshot_dir="$CACHE_HOST/hub/models--${REPO%%/*}--${REPO##*/}/snapshots/$REV"
  verify_snapshot "$snapshot_dir"
  write_receipt "$snapshot_dir"
}

if [ "$MODE" = --verify ]; then
  verify_checkpoint
  exit $?
fi
if ! actual_image_id="$(docker image inspect "$IMAGE_CONFIG" --format '{{.Id}}' 2>/dev/null)"; then
  echo "error: pinned DS4 Vision KK image is absent; run scripts/inference/deepseek/pull-ds4-flash-vision-karmic-kraken-v1-image.sh" >&2
  exit 1
fi
[ "$actual_image_id" = "$IMAGE_CONFIG" ] || {
  echo "error: local DS4 Vision KK image id is $actual_image_id, expected $IMAGE_CONFIG" >&2
  exit 1
}

if [ "$MODE" = --hydrate-from ]; then
  [ -d "$FLAT_DIR" ] || { echo "error: flat checkpoint dir not found: $FLAT_DIR" >&2; exit 1; }
  FLAT_DIR="$(realpath -e -- "$FLAT_DIR")"
  case "$FLAT_DIR" in
    /*) ;;
    *) echo "error: hydrate source did not resolve to an absolute path: $FLAT_DIR" >&2; exit 1 ;;
  esac
  case "$FLAT_DIR" in
    *:*) echo "error: hydrate source cannot contain ':' (required for the read-only Docker bind): $FLAT_DIR" >&2; exit 1 ;;
  esac
  [ -f "$FLAT_DIR/config.json" ] || { echo "error: no config.json in $FLAT_DIR" >&2; exit 1; }
  [ -r "$MANIFEST" ] || { echo "error: manifest missing: $MANIFEST" >&2; exit 1; }
  if [ -r "$CACHE_HOST/.download-complete" ] \
    && [ "$(<"$CACHE_HOST/.download-complete")" = "$REPO $REV" ]; then
    echo "Marker already present; verifying existing snapshot."
    if verify_checkpoint; then
      SNAPSHOT_DIR="$CACHE_HOST/hub/models--${REPO%%/*}--${REPO##*/}/snapshots/$REV"
      existing_real=()
      for path in "${PINNED_ONLY_FILES[@]}"; do
        [ -L "$SNAPSHOT_DIR/$path" ] || existing_real+=("$path")
      done
      write_hydrate_state "$FLAT_DIR" "${existing_real[*]:-none}"
      write_receipt "$SNAPSHOT_DIR"
      exit 0
    fi
    echo "Existing snapshot failed verification; rebuilding it from the verified source." >&2
  fi
  rm -f "$CACHE_HOST/.download-complete" "$HYDRATE_SOURCE_FILE" 2>/dev/null \
    || sudo rm -f "$CACHE_HOST/.download-complete" "$HYDRATE_SOURCE_FILE"

  # 1. Content-verify every reusable flat-copy file. The three revision-only
  #    paths are fetched below; parallel sha256 covers the other 81 files,
  #    including all 48 shards, tokenizer and executable code assets.
  echo "Hydrate: verifying 81 reusable files (parallel sha256)..."
  verify_manifest_directory "$FLAT_DIR" "hydrate source" 1

  # 2. Build the snapshot layout. Symlinks point at the flat copy; the
  #    pinned-only files are fetched from the pinned revision and installed
  #    as real files (or symlinked when the flat copy is already identical).
  SNAPSHOT_DIR="$CACHE_HOST/hub/models--${REPO%%/*}--${REPO##*/}/snapshots/$REV"
  rm -rf "$SNAPSHOT_DIR" 2>/dev/null || sudo rm -rf "$SNAPSHOT_DIR"
  # The download container may leave root-owned hub parents. Reclaim only the
  # new, empty snapshot directory—not the whole hub tree or symlink targets.
  mkdir -p "$SNAPSHOT_DIR" 2>/dev/null || {
    sudo mkdir -p "$SNAPSHOT_DIR"
    sudo chown "$USER:$(id -gn)" "$SNAPSHOT_DIR"
  }
  fetched_real=()
  for path in "${PINNED_ONLY_FILES[@]}"; do
    tmp="$(mktemp "/tmp/.ds4v-hydrate-${path##*/}.XXXXXX")"
    if ! curl -fsSL "https://huggingface.co/$REPO/resolve/$REV/$path" -o "$tmp"; then
      echo "error: could not fetch pinned-revision file: $path" >&2
      rm -f "$tmp"
      exit 1
    fi
    mkdir -p "$SNAPSHOT_DIR/$(dirname "$path")"
    flat="$FLAT_DIR/$path"
    if [ -f "$flat" ] \
      && [ "$(sha256sum "$flat" | cut -d' ' -f1)" = "$(sha256sum "$tmp" | cut -d' ' -f1)" ]; then
      ln -sfn "$flat" "$SNAPSHOT_DIR/$path"
      rm -f "$tmp"
    else
      mv "$tmp" "$SNAPSHOT_DIR/$path"
      chmod 644 "$SNAPSHOT_DIR/$path"
      fetched_real+=("$path")
    fi
  done
  awk '!/^#/ {print $3}' "$MANIFEST" \
    | while read -r path; do
        case " ${PINNED_ONLY_FILES[*]} " in *" $path "*) continue ;; esac
        mkdir -p "$SNAPSHOT_DIR/$(dirname "$path")"
        ln -sfn "$FLAT_DIR/$path" "$SNAPSHOT_DIR/$path"
      done

  # 3. Verify the completed snapshot before committing readiness markers.
  #    .hydrate-source is machine-readable launch state; provenance is the
  #    human receipt. Both are written only after all 84 paths verify.
  verify_snapshot "$SNAPSHOT_DIR"
  write_hydrate_state "$FLAT_DIR" "${fetched_real[*]:-none}"
  marker_tmp="$(mktemp "$CACHE_HOST/.download-complete.XXXXXX")"
  printf '%s %s\n' "$REPO" "$REV" >"$marker_tmp"
  mv -f "$marker_tmp" "$CACHE_HOST/.download-complete"
  write_receipt "$SNAPSHOT_DIR"
  echo "Hydrate complete: snapshot at $SNAPSHOT_DIR (84/84 files sha256-verified)."
  exit 0
fi

# Disk gate: ~156.3 GiB payload plus xet staging on /models; fail closed before downloading
# rather than filling the dataset mid-flight. Never deletes anything itself.
if ! mkdir -p "$CACHE_HOST" 2>/dev/null || [ ! -w "$CACHE_HOST" ]; then
  sudo mkdir -p "$CACHE_HOST"
  sudo chown "$USER:users" "$CACHE_HOST"
fi
models_df="$(df -Pk "$CACHE_HOST" 2>/dev/null || true)"
available_kb="$(awk 'NR==2 {print $4}' <<<"$models_df")"
if [ -z "$available_kb" ]; then
  models_df="$(df -Pk /models 2>/dev/null || true)"
  available_kb="$(awk 'NR==2 {print $4}' <<<"$models_df")"
fi
[ -n "$available_kb" ] || {
  echo "error: could not determine free space on the checkpoint filesystem" >&2
  exit 1
}
if [ "$available_kb" -lt $((180 * 1024 * 1024)) ]; then
  echo "error: only $((available_kb / 1024 / 1024)) GiB free on the checkpoint filesystem; the pinned" >&2
  echo "       download needs ~156.3 GiB payload plus transient xet staging. Free space first" >&2
  echo "       (candidates: /models/vllm-cache/ds4-vision-infernal-invocation-cu133-r21*)" >&2
  exit 1
fi

# Optional HF auth: if a token exists at the standard hf CLI location, mount
# it into the container at huggingface_hub's default token path so the
# download authenticates. The checkpoint repo is public, so this only buys
# rate limit headroom.
TOKEN_FILE="$HOME/.config/hf/token"
EXTRA_VOLS=()
if [[ -f "$TOKEN_FILE" ]]; then
  EXTRA_VOLS+=(-v "$TOKEN_FILE:/run/secrets/hf-token:ro" -e HF_TOKEN_PATH=/run/secrets/hf-token)
else
  echo "note: no HF token at $TOKEN_FILE - downloading unauthenticated (public repo)" >&2
fi

# hf download (huggingface_hub 1.31 with hf_xet high-performance transport)
# into the container's default hub cache, which is the host mount. After the
# download, snapshot_download(local_files_only=True) proves the pinned
# revision resolves from the cache alone; all 84 manifest hashes are verified
# by this script's verify_checkpoint (host-side) before the receipt is written.
install -d -m 700 "$STATE_DIR"
dl_tmp="$(mktemp "$STATE_DIR/.karmic-kraken-v1-download-entrypoint.XXXXXX")"
cat >"$dl_tmp" <<EOF
set -euo pipefail
export HF_XET_HIGH_PERFORMANCE=1
export HF_HUB_DISABLE_PROGRESS_BARS=1
hf download "$REPO" --revision "$REV"
/opt/venv/bin/python - <<'PY'
from huggingface_hub import snapshot_download

path = snapshot_download(
    repo_id="$REPO",
    revision="$REV",
    local_files_only=True,
)
print("OFFLINE-OK:", path)
PY
printf '%s %s\n' "$REPO" "$REV" > /root/.cache/huggingface/.download-complete
echo DOWNLOAD_COMPLETE
EOF
chmod 600 "$dl_tmp"
mv -f "$dl_tmp" "$DL_SCRIPT"

if running="$(docker inspect --format '{{.State.Running}}' "$NAME" 2>/dev/null)" \
  && [ "$running" = true ]; then
  echo "Download container '$NAME' is already running; attaching to it."
else
  docker rm -f "$NAME" 2>/dev/null || true
  docker run -d --name "$NAME" --network host \
    --init --restart on-failure:5 \
    -v "$CACHE_HOST:/root/.cache/huggingface" \
    -v "$DL_SCRIPT:/dl.sh:ro" \
    ${EXTRA_VOLS[@]+"${EXTRA_VOLS[@]}"} \
    --entrypoint bash "$IMAGE_CONFIG" /dl.sh
  echo "Downloading in container '$NAME' into $CACHE_HOST"
fi
echo "Follow with:  docker logs -f $NAME"
echo "On completion the marker .download-complete is written; --wait verifies and writes the receipt."

if [ "$MODE" = --wait ]; then
  if docker wait "$NAME"; then
    verify_checkpoint
  else
    echo "error: download container exited non-zero; inspect: docker logs $NAME" >&2
    exit 1
  fi
fi
