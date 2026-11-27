#!/usr/bin/env bash
# Export a GLM-5.3 v17 Hyperflare TP2 core (2 GPUs, 8 slots, MTP 5) with
# upstream ignition from the locally built v17 image, from v16's checkpoint
# (nvidia/GLM-5.3-Flash-FP4-Local, the directory glm53-fp4-local).
#
# PREFILL picks the core (glm53-v17-hyperflare/pins.sh):
#   rowshard  (default) PR #55's row-sharded prefill and attention, 8192-token chunks
#   baseline  upstream's head-sharded prefill, 4096-token chunks: the A/B control
# Each mode writes its own receipt, so both cores can sit in the store and the
# run script serves either without another export.
#
# State lives under V17_ROOT (default /models/glm53-hyperflare-v17): flare-home/
# is the container's $HOME (core store ~/.cache/flare/cores, kernel-tuning and
# JIT caches, ~/.config/flare), plus the receipts and logs. It is separate from
# v16's /models/glm53-hyperflare/flare-home: a different exporter builds
# different cores and tuning selections, and v16 must stay servable. Point
# V17_ROOT at another disk to export there.
#
# The checkpoint is read from CKPT_ROOT/glm53-fp4-local (default v16's
# /models/glm53-hyperflare), mounted read-only under its own directory name,
# which ignition uses as the model name; v16's downloader --verify is its gate
# (re-download its shards with ROOT_HOST=CKPT_ROOT first if they were archived).
#
# Signing: a new state root gets a copy of v16's local development signing key
# (SIGNING_KEY_SOURCE), so the core is signed by the key the run script pins;
# an existing key that is not that one fails closed before the export.
#
# Requires both GPUs idle (this script never stops anything) and the export at
# the power limit you serve with: kernel tuning measures the cards as they run.
# Disk: refuses unless V17_ROOT has the checkpoint's size plus 10% free, the
# worst case for a core that shares no payload with an existing one.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/inference/glm53/glm53-v17-hyperflare/pins.sh
source "$SCRIPT_DIR/glm53-v17-hyperflare/pins.sh"

PREFILL="$(v17_resolve_prefill "${PREFILL:-rowshard}")" || exit 2
CHUNK="$(v17_prefill_chunk "$PREFILL")"
mapfile -t PREFILL_FLAGS < <(v17_prefill_flags "$PREFILL")
V17_ROOT="${V17_ROOT:-$V17_DEFAULT_ROOT}"
CKPT_ROOT="${CKPT_ROOT:-/models/glm53-hyperflare}"
CKPT_HOST="$CKPT_ROOT/$V17_MODEL"
SIGNING_KEY_SOURCE="${SIGNING_KEY_SOURCE:-/models/glm53-hyperflare/flare-home/.config/flare}"
FLARE_HOME="$V17_ROOT/flare-home"
NAME="$V17_CONTAINER-export"
CORE_RECEIPT="$V17_ROOT/core-$PREFILL.txt"
LOG="$V17_ROOT/export-$PREFILL-$(date +%Y%m%d%H%M%S).log"
# VISION=1 keeps image input like v16 (vision tower replicated on both GPUs);
# VISION=0 exports text-only (--language-model-only), more KV.
VISION="${VISION:-1}"
CONC="${CONC:-8}"
DISK_MARGIN_PERCENT="${DISK_MARGIN_PERCENT:-10}"

die() { echo "error: $*" >&2; exit 1; }

case "$VISION" in
  1) MODALITY=(--image-concurrency 2) ;;
  0) MODALITY=(--language-model-only) ;;
  *) echo "error: VISION must be 1 or 0" >&2; exit 2 ;;
esac
[[ "$CONC" =~ ^[1-9][0-9]*$ ]] || { echo "error: CONC must be a positive integer" >&2; exit 2; }
# The image's uid-1000 user has home /flare-home so the Rust flare CLI
# (getpwuid) and the Python exporter ($HOME) share one store; see the Dockerfile.
[ "$(id -u)" = 1000 ] || die "run as uid 1000 (the image maps only uid 1000's home to /flare-home)"

ROOT_HOST="$CKPT_ROOT" "$SCRIPT_DIR/download-glm53-flash-hyperflare-tp2-v16-checkpoint.sh" --verify

labels="$(docker image inspect "$V17_IMAGE" --format "$(v17_image_labels_format)" 2>/dev/null)" \
  || die "image $V17_IMAGE is absent; run build-glm53-flash-hyperflare-tp2-v17-image.sh"
mismatch="$(v17_image_matches_pins "$labels")" || die "image $V17_IMAGE: $mismatch"

key_dir="$FLARE_HOME/.config/flare"
mkdir -p "$key_dir"
need="$(du -s --apparent-size -B1 "$CKPT_HOST" | cut -f1)"
avail="$(df --output=avail -B1 "$V17_ROOT" | tail -1 | tr -d ' ')"
((avail >= need + need * DISK_MARGIN_PERCENT / 100)) \
  || die "$V17_ROOT has $((avail >> 30)) GiB free; a core needs ~$((need >> 30)) GiB + ${DISK_MARGIN_PERCENT}%"

# Seed the signing key once; never overwrite a key that is already there.
for file in development-signing-key.pem development-publisher.json; do
  if [ ! -e "$key_dir/$file" ]; then
    [ -r "$SIGNING_KEY_SOURCE/$file" ] || die "no $file in $SIGNING_KEY_SOURCE to seed $key_dir"
    install -m 600 "$SIGNING_KEY_SOURCE/$file" "$key_dir/$file"
  fi
done
cmp -s "$key_dir/development-signing-key.pem" "$SIGNING_KEY_SOURCE/development-signing-key.pem" \
  || die "$key_dir holds a signing key other than $SIGNING_KEY_SOURCE's; the run script pins $V17_SIGNING_KEY_FINGERPRINT"

mapfile -t used < <(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits)
[ "${#used[@]}" -eq 2 ] || die "expected two GPUs, found ${#used[@]}"
for mib in "${used[@]}"; do
  ((${mib// /} <= 1024)) || die "a GPU has ${mib// /} MiB in use; stop every GPU workload before exporting"
done

docker rm -f "$NAME" >/dev/null 2>&1 || true
echo "Exporting $V17_MODEL as v17 $PREFILL (chunk $CHUNK, VISION=$VISION CONC=$CONC) — log: $LOG"
# HF_HUB_OFFLINE: the checkpoint and its chat template are local; a cache miss
# must fail, not download into a full disk.
# shellcheck disable=SC2054 # "0,1" is ignition's single --gpus value
docker run --rm --name "$NAME" \
  --gpus all --ipc host --shm-size 32g \
  --ulimit memlock=-1 --ulimit stack=67108864:67108864 \
  --security-opt seccomp=unconfined \
  --user "$(id -u):$(id -g)" \
  -e HOME=/flare-home -e HF_HUB_OFFLINE=1 \
  -v "$CKPT_HOST:/ckpt/$V17_MODEL:ro" \
  -v "$FLARE_HOME:/flare-home" \
  -w /opt/hyperflare-recipes \
  --entrypoint /opt/hyperflare-recipes/.venv/bin/ignition "$V17_IMAGE" \
  export "/ckpt/$V17_MODEL" --gpus 0,1 --max-concurrency "$CONC" \
  --prefill-chunk-size "$CHUNK" --mtp-draft-tokens 5 --mtp-only \
  "${MODALITY[@]}" ${PREFILL_FLAGS[@]+"${PREFILL_FLAGS[@]}"} --verbose 2>&1 | tee "$LOG"
status="${PIPESTATUS[0]}"
[ "$status" -eq 0 ] || die "export exited $status; see $LOG"

entry="$(v17_entry_from_export_log "$V17_MODEL" <"$LOG")" \
  || die "export log has no 'Exported cache entry: .../$V17_MODEL/<version>' line"
[[ "$entry" == /flare-home/* ]] || die "the export published $entry, outside the mounted store /flare-home"
[ -d "$FLARE_HOME${entry#/flare-home}" ] || die "the published entry is not at $FLARE_HOME${entry#/flare-home}"
core="$(v17_core_of_entry "$entry")"
plan_line="$(grep -E 'Plan cache\.|Graph catalog' "$LOG" | tail -2 | tr '\n' ' ')"
tmp="$(mktemp "$V17_ROOT/.core-$PREFILL.XXXXXX")"
printf 'model=%s\ncore=%s\nentry=%s\nprefill=%s\nchunk=%s\nimage=%s\nhyperflare_inference=%s\nrecipes=%s\nflashinfer=%s\nvision=%s\nconc=%s\nexported_at=%s\nlog=%s\nplan=%s\n' \
  "$V17_MODEL" "$core" "$entry" "$PREFILL" "$CHUNK" "$V17_IMAGE" "$V17_HYPERFLARE_INFERENCE_COMMIT" \
  "$V17_RECIPES_COMMIT" "$V17_FLASHINFER_COMMIT" "$VISION" "$CONC" "$(date -Is)" "$LOG" "$plan_line" >"$tmp"
mv -f "$tmp" "$CORE_RECEIPT"
echo "CORE OK: $core ($PREFILL) — receipt $CORE_RECEIPT"
