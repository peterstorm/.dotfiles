#!/usr/bin/env bash
# Download the DeepSeek-V4-Flash-0731 checkpoint used by the r33 server.
#
# ~155 GiB, pinned to the exact revision the runbook validates. Writes to
# /models/DeepSeek-V4-Flash-0731 (a dedicated ZFS dataset, 1M records, no
# compression). Runs in a throwaway python container because the host has no
# python/hf CLI on purpose. Idempotent + resumable: re-run to continue.
#
# See docs/new-desktop-install.md — "Running DeepSeek-V4-Flash (Gilded Gnosis r33, K5)".
set -euo pipefail

REPO="deepseek-ai/DeepSeek-V4-Flash-0731"
REV="9e165c30e2704aec5d9d593cce3eebd58bbef1cb"
DEST="/models/DeepSeek-V4-Flash-0731"

sudo mkdir -p "$DEST"
sudo chown "$USER:users" "$DEST"

# `hf` (huggingface_hub >= 0.34) with Xet high-performance transport. The old
# `huggingface-cli` + HF_HUB_ENABLE_HF_TRANSFER path is deprecated and no longer works.
cat > /tmp/ds4-dl.sh <<EOF
set -e
pip install -q 'huggingface_hub[hf_xet]'
export HF_XET_HIGH_PERFORMANCE=1
hf download "$REPO" --revision "$REV" --local-dir "$DEST"
echo DOWNLOAD_COMPLETE
EOF

docker rm -f ds4-model-dl 2>/dev/null || true
docker run -d --name ds4-model-dl --network host \
  -v /models:/models -v /tmp/ds4-dl.sh:/dl.sh:ro \
  python:3.11-slim bash /dl.sh

echo "Downloading in container 'ds4-model-dl'. Follow with:  docker logs -f ds4-model-dl"
