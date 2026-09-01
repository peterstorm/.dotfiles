#!/usr/bin/env bash
# Download the exact DeepSeek-V4-Flash-Vision-Exp runtime payload.
set -euo pipefail

REPO="deepseek-ai/DeepSeek-V4-Flash-Vision-Exp"
REV="86f746b36186f0e567729a5c06a8c918caba82a9"
DEST="${DEST:-$HOME/models/DeepSeek-V4-Flash-Vision-Exp}"
TOKEN_FILE="$HOME/.config/hf/token"
CONTAINER="ds4-vision-model-dl"

volumes=(-v "$HOME/models:$HOME/models")
if [[ -f "$TOKEN_FILE" ]]; then
  volumes+=(-v "$TOKEN_FILE:/root/.cache/huggingface/token:ro")
else
  echo "note: no Hugging Face token at $TOKEN_FILE" >&2
fi

mkdir -p "$DEST"
cat > /tmp/ds4-vision-dl.sh <<EOF
set -euo pipefail
python3 -m pip install -q 'huggingface_hub[hf_xet]'
export HF_XET_HIGH_PERFORMANCE=1
hf download "$REPO" --revision "$REV" --local-dir "$DEST"
printf '%s\n' "$REV" > "$DEST/.deepseek-v4-flash-vision-exp.revision.tmp"
mv "$DEST/.deepseek-v4-flash-vision-exp.revision.tmp" \
  "$DEST/.deepseek-v4-flash-vision-exp.revision"
echo DOWNLOAD_COMPLETE
EOF

docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
docker run -d --name "$CONTAINER" --network host \
  -v /tmp/ds4-vision-dl.sh:/dl.sh:ro \
  "${volumes[@]}" \
  python:3.11-slim bash /dl.sh >/dev/null

printf "Downloading %s@%s in '%s'.\n" "$REPO" "$REV" "$CONTAINER"
printf "Follow: docker logs -f %s\n" "$CONTAINER"
