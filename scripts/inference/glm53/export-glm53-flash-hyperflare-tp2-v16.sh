#!/usr/bin/env bash
# Export the GLM-5.3 v16 Hyperflare TP2 package (2 GPUs, 8 slots, images).
#
# Runs the recipe's own export-glm-tp2.sh (vendored byte-for-byte in
# glm53-v16-hyperflare/, git blob f2bcc006…) inside the locally built
# Hyperflare image, from the fork checkout at /opt/flare, against the
# downloaded FP4-Local checkpoint. The checkpoint is mounted read-only at
# /ckpt/glm53-fp4-local so its directory name — which Hyperflare uses as the
# model name — stays glm53-fp4-local.
#
# Persistent state lives under /models/glm53-hyperflare (rpool/models, not
# /home): flare-home/ is the container's $HOME, so the package store
# (~/.cache/flare/cores), the shared kernel-tuning cache
# (~/.cache/flare/kernels), FlashInfer/Triton JIT caches and the local
# package-signing key (~/.config/flare) survive between export and serve;
# brrr-ext/ keeps the torch extension builds.
#
# Requires both GPUs idle (stop the serving profile first; this script never
# stops anything). Export at the power limit you serve with: kernel tuning
# measures the cards as they run (recipe EXPORT.md). On success it writes the
# package receipt the v16 run script serves from.
#
# See docs/runbooks/glm53-flash-hyperflare-tp2-v16-runbook-2026-11-13.md.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE="peterstorm/glm53-hyperflare:ac9136b-cu131"
HYPERFLARE_COMMIT="ac9136b02c7c523f12d6e628e9d94f41006312ea"
RECIPE_EXPORT="$SCRIPT_DIR/glm53-v16-hyperflare/export-glm-tp2.sh"
RECIPE_EXPORT_BLOB="f2bcc006e3b63c0add107396bfe8f85f4832e502"
ROOT_HOST="${ROOT_HOST:-/models/glm53-hyperflare}"
CKPT_HOST="$ROOT_HOST/glm53-fp4-local"
FLARE_HOME="$ROOT_HOST/flare-home"
BRRR_EXT="$ROOT_HOST/brrr-ext"
NAME="glm53-flash-hyperflare-tp2-v16-export"
PACKAGE_RECEIPT="$ROOT_HOST/package-v16.txt"
LOG="$ROOT_HOST/export-v16-$(date +%Y%m%d%H%M%S).log"
# VISION=1 (recipe default) keeps image input; VISION=0 exports text-only
# (+7.2% KV at TP2). CONC=8 is the recipe's TP2 slot count.
VISION="${VISION:-1}"
CONC="${CONC:-8}"

die() { echo "error: $*" >&2; exit 1; }

# The image's uid-1000 user has home /flare-home so the Rust flare CLI
# (getpwuid) and the Python exporter ($HOME) share one store; see Dockerfile.
[ "$(id -u)" = 1000 ] || die "run as uid 1000 (the image maps only uid 1000's home to /flare-home)"

[ "$(git hash-object "$RECIPE_EXPORT")" = "$RECIPE_EXPORT_BLOB" ] \
  || die "vendored recipe export script drifted from blob $RECIPE_EXPORT_BLOB"
"$SCRIPT_DIR/download-glm53-flash-hyperflare-tp2-v16-checkpoint.sh" --verify

label="$(docker image inspect "$IMAGE" \
  --format '{{index .Config.Labels "ai.peterstorm.inference.hyperflare-commit"}}' 2>/dev/null)" \
  || die "image $IMAGE is absent; run build-glm53-flash-hyperflare-tp2-v16-image.sh"
[ "$label" = "$HYPERFLARE_COMMIT" ] || die "image $IMAGE was built from $label, expected $HYPERFLARE_COMMIT"

mapfile -t used < <(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits)
[ "${#used[@]}" -eq 2 ] || die "expected two GPUs, found ${#used[@]}"
for mib in "${used[@]}"; do
  ((${mib// /} <= 1024)) || die "a GPU has ${mib// /} MiB in use; stop every GPU workload before exporting"
done

mkdir -p "$FLARE_HOME" "$BRRR_EXT"
docker rm -f "$NAME" >/dev/null 2>&1 || true
echo "Exporting (VISION=$VISION CONC=$CONC) — log: $LOG"
docker run --rm --name "$NAME" \
  --gpus all --ipc host --shm-size 32g \
  --ulimit memlock=-1 --ulimit stack=67108864:67108864 \
  --security-opt seccomp=unconfined \
  --user "$(id -u):$(id -g)" \
  -e HOME=/flare-home -e CUDA_HOME=/usr/local/cuda \
  -e CKPT=/ckpt/glm53-fp4-local -e VISION="$VISION" -e CONC="$CONC" \
  -v "$CKPT_HOST:/ckpt/glm53-fp4-local:ro" \
  -v "$FLARE_HOME:/flare-home" \
  -v "$BRRR_EXT:/opt/flare/.brrr-ext" \
  -v "$RECIPE_EXPORT:/recipe/export-glm-tp2.sh:ro" \
  -w /opt/flare \
  --entrypoint bash "$IMAGE" /recipe/export-glm-tp2.sh 2>&1 | tee "$LOG"
status="${PIPESTATUS[0]}"
[ "$status" -eq 0 ] || die "export exited $status; see $LOG"

entry="$(sed -nE 's/^Exported cache entry: .*\/(glm53-fp4-local\/gb202-tp2-[0-9]+)$/\1/p' "$LOG" | tail -1)"
[ -n "$entry" ] || die "export log has no 'Exported cache entry: .../glm53-fp4-local/gb202-tp2-<ts>' line"
package="${entry%%/*}@${entry##*/}"
plan_line="$(grep -E 'Plan cache\.|Graph catalog' "$LOG" | tail -2 | tr '\n' ' ')"
tmp="$(mktemp "$ROOT_HOST/.package-v16.XXXXXX")"
printf 'package=%s\nhyperflare_commit=%s\nvision=%s\nconc=%s\nexported_at=%s\nlog=%s\nplan=%s\n' \
  "$package" "$HYPERFLARE_COMMIT" "$VISION" "$CONC" "$(date -Is)" "$LOG" "$plan_line" >"$tmp"
mv -f "$tmp" "$PACKAGE_RECEIPT"
echo "PACKAGE OK: $package — receipt $PACKAGE_RECEIPT"
