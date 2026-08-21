#!/usr/bin/env bash
# Download a pinned BF16 Muse Glimmer target and the official BF16 DFlash draft.
#
# MUSE_VARIANT=standard selects the qualified upstream target;
# MUSE_VARIANT=abliterated selects mlasli's BF16 refusal-suppressed derivative.
# The linked Abliterated-BF16 repository is full BF16, not a quantization.
# Together target + draft occupy about 60.2 GiB. The operation is resumable and
# runs in a throwaway Python container because the host intentionally has no HF
# CLI. Standard Hub HTTPS is forced: hf-xet 1.6.0 hangs on this workstation.
#
# See docs/runbooks/new-desktop-install.md — "Muse Glimmer BF16 + DFlash beside Qwen".
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/inference/shared/inference-api-key.sh
source "$SCRIPT_DIR/../shared/inference-api-key.sh"
# shellcheck source=scripts/inference/muse/muse-glimmer-variant.sh
source "$SCRIPT_DIR/muse-glimmer-variant.sh"
inference_resolve_operator
muse_resolve_variant "${MUSE_VARIANT:-standard}"

DOWNLOAD_SCRIPT="/tmp/muse-glimmer-$MUSE_VARIANT-dl.sh"

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

sudo mkdir -p "$MUSE_TARGET_HOST" "$MUSE_DRAFT_HOST"
sudo chown "$INFERENCE_OPERATOR_USER:$INFERENCE_OPERATOR_GROUP" "$MUSE_TARGET_HOST" "$MUSE_DRAFT_HOST"

cat >"$DOWNLOAD_SCRIPT" <<EOF
set -euo pipefail
pip install -q huggingface_hub
export HF_HUB_DISABLE_XET=1
hf download "$MUSE_TARGET_REPO" --revision "$MUSE_TARGET_REV" --local-dir "$MUSE_TARGET_HOST"
if [ -n '$MUSE_TARGET_SHA256_MANIFEST' ]; then
  cd '$MUSE_TARGET_HOST'
  printf '%s\n' '$MUSE_TARGET_SHA256_MANIFEST' | sha256sum --check --strict
fi
printf '%s\n' '$MUSE_TARGET_REPO@$MUSE_TARGET_REV' > '$MUSE_TARGET_HOST/.download-complete'
hf download "$MUSE_DRAFT_REPO" --revision "$MUSE_DRAFT_REV" --local-dir "$MUSE_DRAFT_HOST"
printf '%s\n' '$MUSE_DRAFT_REPO@$MUSE_DRAFT_REV' > '$MUSE_DRAFT_HOST/.download-complete'
echo DOWNLOAD_COMPLETE
EOF
chmod 600 "$DOWNLOAD_SCRIPT"

docker rm -f "$MUSE_DOWNLOAD_CONTAINER_NAME" 2>/dev/null || true
docker run -d --name "$MUSE_DOWNLOAD_CONTAINER_NAME" --network host \
  -v "$MUSE_TARGET_HOST":"$MUSE_TARGET_HOST" \
  -v "$MUSE_DRAFT_HOST":"$MUSE_DRAFT_HOST" \
  -v "$DOWNLOAD_SCRIPT":/dl.sh:ro \
  ${EXTRA_VOLS[@]+"${EXTRA_VOLS[@]}"} \
  python:3.11-slim bash /dl.sh

echo "Downloading Muse '$MUSE_VARIANT' BF16 target and DFlash draft in container '$MUSE_DOWNLOAD_CONTAINER_NAME'."
echo "Follow: docker logs -f $MUSE_DOWNLOAD_CONTAINER_NAME"
