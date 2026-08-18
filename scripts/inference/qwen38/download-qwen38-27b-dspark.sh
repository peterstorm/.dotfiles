#!/usr/bin/env bash
# Download the DSpark draft checkpoint for the experimental Qwen3.8-27B SGLang profile.
#
# ~2.53 GiB of BF16 draft weights, pinned to the exact revision documented in
# the runbook. The BF16 target is downloaded separately by
# scripts/inference/qwen38/download-qwen38-27b.sh. Writes to /models/Qwen3.8-27B-DSpark and runs
# in a throwaway Python container. Idempotent and resumable.
#
# See docs/runbooks/new-desktop-install.md — "Experimental Qwen3.8-27B DSpark on SGLang".
set -euo pipefail

REPO="RadixArk/Qwen3.8-27B-DSpark"
REV="923ed3a8572615643f0137e424e4ce4edd7f1cda"
DEST="/models/Qwen3.8-27B-DSpark"

sudo mkdir -p "$DEST"
sudo chown "$USER:users" "$DEST"

cat > /tmp/qwen38-dspark-dl.sh <<EOF
set -e
pip install -q huggingface_hub
# hf-xet 1.6.0 was observed hanging indefinitely at 0% on this machine while
# direct Hub HTTPS remained healthy. Force the standard resumable HTTP backend.
export HF_HUB_DISABLE_XET=1
hf download "$REPO" --revision "$REV" --local-dir "$DEST"
echo DOWNLOAD_COMPLETE
EOF

docker rm -f qwen38-dspark-model-dl 2>/dev/null || true
docker run -d --name qwen38-dspark-model-dl --network host \
  -v /models:/models -v /tmp/qwen38-dspark-dl.sh:/dl.sh:ro \
  python:3.11-slim bash /dl.sh

echo "Downloading in container 'qwen38-dspark-model-dl'. Follow with: docker logs -f qwen38-dspark-model-dl"
