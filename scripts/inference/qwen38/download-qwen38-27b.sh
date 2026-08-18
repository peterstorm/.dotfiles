#!/usr/bin/env bash
# Download the Qwen3.8-27B BF16 checkpoint used by the local vLLM server.
#
# ~52 GiB of weights, pinned to the exact revision documented in the runbook.
# Writes to /models/Qwen3.8-27B. Runs in a throwaway Python container because
# the host intentionally has no Python/Hugging Face CLI. Idempotent and resumable.
#
# See docs/new-desktop-install.md — "Running Qwen3.8-27B BF16 on vLLM".
set -euo pipefail

REPO="Qwen/Qwen3.8-27B"
REV="1d4bf0f2ff6012fd82039f2fa52739d0dd7c60c0"
DEST="/models/Qwen3.8-27B"

sudo mkdir -p "$DEST"
sudo chown "$USER:users" "$DEST"

cat > /tmp/qwen38-dl.sh <<EOF
set -e
pip install -q huggingface_hub
# hf-xet 1.6.0 was observed hanging indefinitely at 0% on this machine while
# direct Hub HTTPS remained healthy. Force the standard resumable HTTP backend.
export HF_HUB_DISABLE_XET=1
hf download "$REPO" --revision "$REV" --local-dir "$DEST"
echo DOWNLOAD_COMPLETE
EOF

docker rm -f qwen38-model-dl 2>/dev/null || true
docker run -d --name qwen38-model-dl --network host \
  -v /models:/models -v /tmp/qwen38-dl.sh:/dl.sh:ro \
  python:3.11-slim bash /dl.sh

echo "Downloading in container 'qwen38-model-dl'. Follow with: docker logs -f qwen38-model-dl"
