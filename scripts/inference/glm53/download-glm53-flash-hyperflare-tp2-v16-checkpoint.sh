#!/usr/bin/env bash
# Download the NVIDIA GLM-5.3-Flash FP4-Local checkpoint the v16 Hyperflare
# profile exports from.
#
# ~178 GB (166 GiB, 40 shards), pinned to the revision the upstream recipe
# (AzallazA/RTX-PRO-6000-TP3-Inference-Recipes, "GLM-5.3-Flash
# Hyperflare-tp3-20261112") measured. Unlike the vLLM profiles this is a plain
# --local-dir checkout, not a hub cache: Hyperflare names the exported model
# after the checkpoint DIRECTORY, so the directory must be called
# glm53-fp4-local for the package to be glm53-fp4-local@gb202-tp2-<ts>.
#
# Runs in a throwaway digest-pinned python container with a pinned
# huggingface_hub/hf_xet; the host has no python/hf CLI on purpose.
# Idempotent + resumable: re-run to continue. On success writes
# .download-complete ($REPO $REV) next to the checkpoint and a receipt; the
# export script refuses to run without that marker.
#
# See docs/runbooks/glm53-flash-hyperflare-tp2-v16-runbook-2026-11-13.md.
set -euo pipefail

REPO="nvidia/GLM-5.3-Flash-FP4-Local"
REV="76348ddb2be2e35e39ecfc00e75dc07703f4f3d5"
IMAGE="python@sha256:90744cff8f32887f075c47d747a173ff333e9e98801667af93c357fa9f5e28ff"
HF_HUB_PIN="huggingface_hub[hf_xet]==1.31.0"
ROOT_HOST="${ROOT_HOST:-/models/glm53-hyperflare}"
CKPT_HOST="$ROOT_HOST/glm53-fp4-local"
NAME="glm53-flash-hyperflare-tp2-v16-dl"
RECEIPT="${RECEIPT:-$HOME/.local/state/glm53/flash-hyperflare-tp2-v16-checkpoint.txt}"
EXPECTED_SHARDS=40
# The download shares a 96 GB host with whatever serves on the GPUs (ds41
# holds ~85 GiB of it). hf_xet reassembles shards in RAM (4+ GiB RSS and
# climbing on the first attempt, 2026-11-13), so xet is disabled — plain
# HTTPS streams each shard to disk at constant memory and the Wi-Fi link is
# the bottleneck either way — and the container is hard-capped so a
# misbehaving downloader OOM-kills itself (then resumes), never the engine.
MEMORY_CAP="${MEMORY_CAP:-3g}"
MODE="${1:---detach}"

case "$MODE" in
  --detach | --wait | --verify) ;;
  *) echo "usage: ${0##*/} [--detach|--wait|--verify]" >&2; exit 2 ;;
esac

verify_checkpoint() {
  local marker shards bytes receipt_tmp
  [ -r "$CKPT_HOST/.download-complete" ] || {
    echo "error: $CKPT_HOST/.download-complete is missing; the download has not completed" >&2
    return 1
  }
  marker="$(<"$CKPT_HOST/.download-complete")"
  [ "$marker" = "$REPO $REV" ] || {
    echo "error: marker is '$marker', expected '$REPO $REV'" >&2
    return 1
  }
  [ -f "$CKPT_HOST/config.json" ] && [ -f "$CKPT_HOST/model.safetensors.index.json" ] || {
    echo "error: config.json or model.safetensors.index.json missing in $CKPT_HOST" >&2
    return 1
  }
  shards="$(find "$CKPT_HOST" -maxdepth 1 -name '*.safetensors' | wc -l)"
  [ "$shards" -eq "$EXPECTED_SHARDS" ] || {
    echo "error: $shards safetensors shards in $CKPT_HOST, expected $EXPECTED_SHARDS" >&2
    return 1
  }
  bytes="$(du -sb "$CKPT_HOST" | cut -f1)"
  install -d -m 700 "$(dirname "$RECEIPT")"
  receipt_tmp="$(mktemp "$(dirname "$RECEIPT")/.v16-checkpoint.XXXXXX")"
  printf 'repo=%s\nrevision=%s\npath=%s\nshards=%s\nbytes=%s\n' \
    "$REPO" "$REV" "$CKPT_HOST" "$shards" "$bytes" >"$receipt_tmp"
  chmod 600 "$receipt_tmp"
  mv -f "$receipt_tmp" "$RECEIPT"
  printf 'CHECKPOINT OK: %s@%s (%s shards, %s bytes) - receipt %s\n' \
    "$REPO" "$REV" "$shards" "$bytes" "$RECEIPT"
}

if [ "$MODE" = --verify ]; then
  verify_checkpoint
  exit $?
fi

TOKEN_FILE="$HOME/.config/hf/token"
EXTRA_VOLS=()
if [ -f "$TOKEN_FILE" ]; then
  EXTRA_VOLS+=(-v "$TOKEN_FILE:/run/hf-token:ro")
else
  echo "note: no HF token at $TOKEN_FILE - downloading unauthenticated (public repo)" >&2
fi

if ! mkdir -p "$CKPT_HOST" 2>/dev/null || [ ! -w "$CKPT_HOST" ]; then
  sudo mkdir -p "$CKPT_HOST"
  sudo chown -R "$USER:users" "$ROOT_HOST"
fi

# The download body lives beside the checkpoint (not in /tmp) so the
# --restart on-failure policy can re-read it after this script exits. It runs
# as the invoking user so the checkout is owned by it; --local-dir keeps hf's
# resumable metadata in $CKPT_HOST/.cache/huggingface.
DL_SCRIPT="$ROOT_HOST/.download-v16.sh"
cat >"$DL_SCRIPT" <<EOF
set -euo pipefail
export HOME=/tmp/home HF_HOME=/tmp/home/.cache/huggingface
mkdir -p "\$HF_HOME"
if [ -r /run/hf-token ]; then cp /run/hf-token "\$HF_HOME/token"; fi
python -m pip install --quiet --no-cache-dir --user '$HF_HUB_PIN'
export PATH="\$HOME/.local/bin:\$PATH" HF_HUB_DISABLE_XET=1 HF_HUB_DISABLE_PROGRESS_BARS=1
hf download "$REPO" --revision "$REV" --local-dir /ckpt
python - <<'PY'
import json, pathlib
root = pathlib.Path("/ckpt")
index = json.loads((root / "model.safetensors.index.json").read_text())
missing = sorted({f for f in index["weight_map"].values() if not (root / f).is_file()})
if missing:
    raise SystemExit(f"index names {len(missing)} missing shards: {missing[:3]}")
print("INDEX-OK:", len(set(index["weight_map"].values())), "shards")
PY
printf '%s %s\n' "$REPO" "$REV" > /ckpt/.download-complete
echo DOWNLOAD_COMPLETE
EOF
chmod 644 "$DL_SCRIPT"

if running="$(docker inspect --format '{{.State.Running}}' "$NAME" 2>/dev/null)" \
  && [ "$running" = true ]; then
  echo "Download container '$NAME' is already running; attaching to it."
else
  docker rm -f "$NAME" 2>/dev/null || true
  docker run -d --name "$NAME" --network host --init --restart on-failure:5 \
    --memory "$MEMORY_CAP" --memory-swap "$MEMORY_CAP" \
    --user "$(id -u):$(id -g)" \
    -v "$CKPT_HOST:/ckpt" \
    -v "$DL_SCRIPT:/dl.sh:ro" \
    ${EXTRA_VOLS[@]+"${EXTRA_VOLS[@]}"} \
    --entrypoint bash "$IMAGE" /dl.sh
  echo "Downloading in container '$NAME' into $CKPT_HOST"
fi
echo "Follow with:  docker logs -f $NAME"

if [ "$MODE" = --wait ]; then
  exit_code="$(docker wait "$NAME")"
  if [ "$exit_code" = 0 ]; then
    verify_checkpoint
  else
    echo "error: download container exited $exit_code; inspect: docker logs $NAME" >&2
    exit 1
  fi
fi
