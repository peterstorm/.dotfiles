#!/usr/bin/env bash
# Download dealignai's uncensored GLM-5.3-Flash NVFP4 release, the source the
# `uncensored` Hyperflare variant is converted from (glm53-uncensored-convert.py).
#
# ~181 GiB (120 numbered shards + model-input-scales), pinned to one revision
# (MIT). It lands in $ROOT_HOST/sources/, NOT beside the Hyperflare checkpoints:
# Hyperflare names an export after its checkpoint directory and refuses this
# layout as-is (modelopt NVFP4 without a per-layer quantized_layers table), so
# the raw download must never look like a model directory. The converter
# reflinks it into /models/glm53-hyperflare/glm53-uncensored.
#
# Same discipline as download-glm53-flash-hyperflare-tp2-v16-checkpoint.sh:
# digest-pinned python container, pinned huggingface_hub, xet disabled (it
# reassembles shards in RAM), container memory-capped so a misbehaving
# downloader kills itself and resumes, never the serving engine. Idempotent and
# resumable; on success writes .download-complete ($REPO $REV) and a receipt.
set -euo pipefail

REPO="dealignai/GLM-5.3-Flash-UNCENSORED-NVFP4"
REV="745aac2ff0f10acf961f396df3f9418598aa7327"
IMAGE="python@sha256:90744cff8f32887f075c47d747a173ff333e9e98801667af93c357fa9f5e28ff"
HF_HUB_PIN="huggingface_hub[hf_xet]==1.31.0"
ROOT_HOST="${ROOT_HOST:-/models/glm53-hyperflare}"
SOURCE_HOST="$ROOT_HOST/sources/dealign-uncensored-nvfp4"
NAME="glm53-uncensored-source-dl"
RECEIPT="${RECEIPT:-$HOME/.local/state/glm53/uncensored-source.txt}"
EXPECTED_SHARDS=120
MEMORY_CAP="${MEMORY_CAP:-3g}"
MODE="${1:---detach}"

case "$MODE" in
  --detach | --wait | --verify) ;;
  *) echo "usage: ${0##*/} [--detach|--wait|--verify]" >&2; exit 2 ;;
esac

verify_source() {
  local marker shards missing bytes receipt_tmp
  [ -r "$SOURCE_HOST/.download-complete" ] || {
    echo "error: $SOURCE_HOST/.download-complete is missing; the download has not completed" >&2
    return 1
  }
  marker="$(<"$SOURCE_HOST/.download-complete")"
  [ "$marker" = "$REPO $REV" ] || { echo "error: marker is '$marker', expected '$REPO $REV'" >&2; return 1; }
  [ -f "$SOURCE_HOST/config.json" ] && [ -f "$SOURCE_HOST/model.safetensors.index.json" ] \
    && [ -f "$SOURCE_HOST/model-input-scales.safetensors" ] || {
    echo "error: config.json, the index or model-input-scales.safetensors is missing in $SOURCE_HOST" >&2
    return 1
  }
  shards="$(find "$SOURCE_HOST" -maxdepth 1 -name "model-*-of-00$EXPECTED_SHARDS.safetensors" | wc -l)"
  [ "$shards" -eq "$EXPECTED_SHARDS" ] || {
    echo "error: $shards numbered shards in $SOURCE_HOST, expected $EXPECTED_SHARDS" >&2
    return 1
  }
  missing="$(jq -r '.weight_map | [.[]] | unique | .[]' "$SOURCE_HOST/model.safetensors.index.json" \
    | while read -r file; do [ -f "$SOURCE_HOST/$file" ] || printf '%s\n' "$file"; done)"
  [ -z "$missing" ] || {
    echo "error: index names files missing from $SOURCE_HOST: $(head -3 <<<"$missing" | tr '\n' ' ')" >&2
    return 1
  }
  bytes="$(du -sb --exclude=.cache "$SOURCE_HOST" | cut -f1)"
  install -d -m 700 "$(dirname "$RECEIPT")"
  receipt_tmp="$(mktemp "$(dirname "$RECEIPT")/.uncensored-source.XXXXXX")"
  printf 'repo=%s\nrevision=%s\npath=%s\nshards=%s\nbytes=%s\n' \
    "$REPO" "$REV" "$SOURCE_HOST" "$shards" "$bytes" >"$receipt_tmp"
  chmod 600 "$receipt_tmp"
  mv -f "$receipt_tmp" "$RECEIPT"
  printf 'SOURCE OK: %s@%s (%s shards, %s bytes) - receipt %s\n' "$REPO" "$REV" "$shards" "$bytes" "$RECEIPT"
}

if [ "$MODE" = --verify ]; then
  verify_source
  exit $?
fi

TOKEN_FILE="$HOME/.config/hf/token"
EXTRA_VOLS=()
if [ -f "$TOKEN_FILE" ]; then
  EXTRA_VOLS+=(-v "$TOKEN_FILE:/run/hf-token:ro")
else
  echo "note: no HF token at $TOKEN_FILE - downloading unauthenticated (public repo)" >&2
fi
mkdir -p "$SOURCE_HOST"

# The body lives beside the download so --restart on-failure can re-read it.
DL_SCRIPT="$ROOT_HOST/sources/.download-uncensored.sh"
cat >"$DL_SCRIPT" <<EOF
set -euo pipefail
export HOME=/tmp/home HF_HOME=/tmp/home/.cache/huggingface
mkdir -p "\$HF_HOME"
if [ -r /run/hf-token ]; then cp /run/hf-token "\$HF_HOME/token"; fi
python -m pip install --quiet --no-cache-dir --user '$HF_HUB_PIN'
export PATH="\$HOME/.local/bin:\$PATH" HF_HUB_DISABLE_XET=1 HF_HUB_DISABLE_PROGRESS_BARS=1
hf download "$REPO" --revision "$REV" --local-dir /src
python - <<'PY'
import json, pathlib
root = pathlib.Path("/src")
index = json.loads((root / "model.safetensors.index.json").read_text())
missing = sorted({f for f in index["weight_map"].values() if not (root / f).is_file()})
if missing:
    raise SystemExit(f"index names {len(missing)} missing shards: {missing[:3]}")
print("INDEX-OK:", len(set(index["weight_map"].values())), "shards")
PY
printf '%s %s\n' "$REPO" "$REV" > /src/.download-complete
echo DOWNLOAD_COMPLETE
EOF
chmod 644 "$DL_SCRIPT"

if running="$(docker inspect --format '{{.State.Running}}' "$NAME" 2>/dev/null)" && [ "$running" = true ]; then
  echo "Download container '$NAME' is already running; attaching to it."
else
  docker rm -f "$NAME" 2>/dev/null || true
  docker run -d --name "$NAME" --network host --init --restart on-failure:5 \
    --memory "$MEMORY_CAP" --memory-swap "$MEMORY_CAP" \
    --user "$(id -u):$(id -g)" \
    -v "$SOURCE_HOST:/src" -v "$DL_SCRIPT:/dl.sh:ro" \
    ${EXTRA_VOLS[@]+"${EXTRA_VOLS[@]}"} \
    --entrypoint bash "$IMAGE" /dl.sh
  echo "Downloading in container '$NAME' into $SOURCE_HOST"
fi
echo "Follow with:  docker logs -f $NAME"

if [ "$MODE" = --wait ]; then
  exit_code="$(docker wait "$NAME")"
  if [ "$exit_code" = 0 ]; then
    verify_source
  else
    echo "error: download container exited $exit_code; inspect: docker logs $NAME" >&2
    exit 1
  fi
fi
