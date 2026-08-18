#!/usr/bin/env bash
# Download the BF16 Muse Glimmer target and its official BF16 DFlash draft.
#
# The two repositories are pinned to the revisions qualified in the workstation
# runbook. Together they occupy about 60.2 GiB. The operation is resumable and
# runs in a throwaway Python container because the host intentionally has no HF
# CLI. Standard Hub HTTPS is forced: hf-xet 1.6.0 hangs on this workstation.
#
# See docs/runbooks/new-desktop-install.md — "Muse Glimmer BF16 + DFlash beside Qwen".
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/inference/shared/inference-api-key.sh
source "$SCRIPT_DIR/../shared/inference-api-key.sh"
inference_resolve_operator

TARGET_REPO="meta-models/Muse-Glimmer-30B"
TARGET_REV="a4e59da52a7bc87ae7251dd5545c0dd437c44b68"
TARGET_DEST="/models/Muse-Glimmer-30B"
DRAFT_REPO="meta-models/Muse-Glimmer-30B-assistant"
DRAFT_REV="e8192f3a8f617f74be2ce220360c89ef4789f39f"
DRAFT_DEST="/models/Muse-Glimmer-30B-assistant"
DOWNLOAD_SCRIPT="/tmp/muse-glimmer-dl.sh"
NAME="muse-glimmer-model-dl"

sudo mkdir -p "$TARGET_DEST" "$DRAFT_DEST"
sudo chown "$INFERENCE_OPERATOR_USER:$INFERENCE_OPERATOR_GROUP" "$TARGET_DEST" "$DRAFT_DEST"

cat >"$DOWNLOAD_SCRIPT" <<EOF
set -euo pipefail
pip install -q huggingface_hub
export HF_HUB_DISABLE_XET=1
hf download "$TARGET_REPO" --revision "$TARGET_REV" --local-dir "$TARGET_DEST"
printf '%s\n' '$TARGET_REPO@$TARGET_REV' > '$TARGET_DEST/.download-complete'
hf download "$DRAFT_REPO" --revision "$DRAFT_REV" --local-dir "$DRAFT_DEST"
printf '%s\n' '$DRAFT_REPO@$DRAFT_REV' > '$DRAFT_DEST/.download-complete'
echo DOWNLOAD_COMPLETE
EOF
chmod 600 "$DOWNLOAD_SCRIPT"

docker rm -f "$NAME" 2>/dev/null || true
docker run -d --name "$NAME" --network host \
  -v "$TARGET_DEST":"$TARGET_DEST" \
  -v "$DRAFT_DEST":"$DRAFT_DEST" \
  -v "$DOWNLOAD_SCRIPT":/dl.sh:ro \
  python:3.11-slim bash /dl.sh

echo "Downloading both Muse checkpoints in container '$NAME'."
echo "Follow: docker logs -f $NAME"
