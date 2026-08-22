#!/usr/bin/env bash
# Download the canonical Inco AI DFlash2 draft used by SGLang's official
# Qwen3.8-27B cookbook. The weight/config bytes match the earlier z-lab mirror,
# so an existing complete Desktop tree is verified and reused without replacement.
set -euo pipefail

REPO="incoai/Qwen3.8-27B-DFlash2"
REV="dedf8df68adfb1afeaf7b7480c0a0243108177b4"
MODEL_SIZE="3848817896"
MODEL_SHA256="67fc76d68dc5a9415511a4f394ef744d67510cd20e93b37cc2cc7d28e4bab65c"
CONFIG_SHA256="873e3556509b0da06e29654ba00d4944888d4b5e8a33afde25f7eb27d321e980"

if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != root ]]; then
  TARGET_USER="$SUDO_USER"
else
  TARGET_USER="$USER"
fi
DESKTOP_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
TARGET_UID="$(getent passwd "$TARGET_USER" | cut -d: -f3)"
TARGET_GID="$(getent group users | cut -d: -f3)"
DEST="${DFLASH2_DEST:-$DESKTOP_HOME/Desktop/Qwen3.8-27B-DFlash2}"
[[ -n "$DESKTOP_HOME" && -n "$TARGET_UID" && -n "$TARGET_GID" ]] || {
  echo "error: could not resolve user $TARGET_USER" >&2
  exit 2
}

TOKEN_FILE="$DESKTOP_HOME/.config/hf/token"
EXTRA_VOLS=()
if [[ -f "$TOKEN_FILE" ]]; then
  EXTRA_VOLS+=(-v "$TOKEN_FILE:/root/.cache/huggingface/token:ro")
else
  echo "note: no HF token at $TOKEN_FILE; downloading unauthenticated" >&2
fi

mkdir -p "$DEST"
chown "$TARGET_USER:users" "$DEST"
case "$DEST" in
  "$DESKTOP_HOME"/*) CONTAINER_DEST="/home/dl${DEST#"$DESKTOP_HOME"}" ;;
  /models/*) CONTAINER_DEST="$DEST" ;;
  *) echo "error: DFLASH2_DEST must be under $DESKTOP_HOME or /models (got: $DEST)" >&2; exit 2 ;;
esac

cat > /tmp/qwen38-dflash2-v2-dl.sh <<EOF
set -euo pipefail
pip install -q huggingface_hub
export HF_HUB_DISABLE_XET=1
hf download "$REPO" --revision "$REV" --local-dir "$CONTAINER_DEST"
config_sha="\$(sha256sum "$CONTAINER_DEST/config.json" | cut -d' ' -f1)"
model_sha="\$(sha256sum "$CONTAINER_DEST/model.safetensors" | cut -d' ' -f1)"
model_size="\$(stat -c %s "$CONTAINER_DEST/model.safetensors")"
[ "\$config_sha" = "$CONFIG_SHA256" ] || { echo "error: config.json checksum mismatch" >&2; exit 1; }
[ "\$model_sha" = "$MODEL_SHA256" ] || { echo "error: model.safetensors checksum mismatch" >&2; exit 1; }
[ "\$model_size" = "$MODEL_SIZE" ] || { echo "error: model.safetensors size mismatch" >&2; exit 1; }
printf '%s\n' "$REPO@$REV" > "$CONTAINER_DEST/.download-complete"
chown -R "$TARGET_UID:$TARGET_GID" "$CONTAINER_DEST"
echo DOWNLOAD_COMPLETE
EOF

docker rm -f qwen38-dflash2-model-dl-v2 2>/dev/null || true
docker run -d --name qwen38-dflash2-model-dl-v2 --network host \
  -v "$DESKTOP_HOME:/home/dl" \
  -v /models:/models \
  -v /tmp/qwen38-dflash2-v2-dl.sh:/dl.sh:ro \
  ${EXTRA_VOLS[@]+"${EXTRA_VOLS[@]}"} \
  python:3.11-slim bash /dl.sh

echo "Downloading/verifying in 'qwen38-dflash2-model-dl-v2'."
echo "Follow: docker logs -f qwen38-dflash2-model-dl-v2"
echo "Destination: $DEST"
