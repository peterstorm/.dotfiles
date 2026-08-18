#!/usr/bin/env bash
# v2 (2026-08-18): download the DSpark draft checkpoint re-pinned to the
# 08-16 upstream revision 85ef153 — the dflash.py verify-window fix
# (verify_width = block_size + 1; logits slice [:, -block_size:]). Weights are
# byte-identical to the 08-16 pin (same LFS oid 9d26d5e6...); only the
# reference-implementation code changed.
#
# ~2.53 GiB of BF16 draft weights. The BF16 target is downloaded separately by
# scripts/inference/qwen38/download-qwen38-27b.sh. Writes to
# /models/Qwen3.8-27B-DSpark-v2 — a SEPARATE tree from the 08-16 profile's
# /models/Qwen3.8-27B-DSpark, so the old profile keeps its exact revision.
# Runs in a throwaway Python container. Idempotent and resumable.
#
# See docs/runbooks/qwen38-27b-runbook-2026-08-18.md and
# docs/research/2026-08-18-qwen38-upstream-update-research.md.
set -euo pipefail

REPO="RadixArk/Qwen3.8-27B-DSpark"
REV="85ef153be924f17ce4bf62726954eeaa4a73e854"
DEST="/models/Qwen3.8-27B-DSpark-v2"

# Optional HF auth: if a token exists at the standard hf CLI location, mount
# it into the container at huggingface_hub's default token path so the
# download authenticates (higher rate limits, no unauthenticated warning).
# Get a read token at https://huggingface.co/settings/tokens and save it:
#   mkdir -p ~/.config/hf && echo "hf_..." > ~/.config/hf/token && chmod 600 ~/.config/hf/token
TOKEN_FILE="$HOME/.config/hf/token"
EXTRA_VOLS=()
if [[ -f "$TOKEN_FILE" ]]; then
  EXTRA_VOLS+=(-v "$TOKEN_FILE:/root/.cache/huggingface/token:ro")
else
  echo "note: no HF token at $TOKEN_FILE - downloading unauthenticated (lower rate limits)" >&2
fi

sudo mkdir -p "$DEST"
sudo chown "$USER:users" "$DEST"

cat > /tmp/qwen38-dspark-dl-v2.sh <<EOF
set -e
pip install -q huggingface_hub
# hf-xet 1.6.0 was observed hanging indefinitely at 0% on this machine while
# direct Hub HTTPS remained healthy. Force the standard resumable HTTP backend.
export HF_HUB_DISABLE_XET=1
hf download "$REPO" --revision "$REV" --local-dir "$DEST"
echo DOWNLOAD_COMPLETE
EOF

docker rm -f qwen38-dspark-model-dl-v2 2>/dev/null || true
docker run -d --name qwen38-dspark-model-dl-v2 --network host \
  -v /models:/models -v /tmp/qwen38-dspark-dl-v2.sh:/dl.sh:ro \
  ${EXTRA_VOLS[@]+"${EXTRA_VOLS[@]}"} \
  python:3.11-slim bash /dl.sh

echo "Downloading in container 'qwen38-dspark-model-dl-v2'. Follow with: docker logs -f qwen38-dspark-model-dl-v2"
