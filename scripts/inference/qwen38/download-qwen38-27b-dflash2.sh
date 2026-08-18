#!/usr/bin/env bash
# 2026-08-19: download the DFlash 2 draft checkpoint for Qwen3.8-27B from
# z-lab/Qwen3.8-27B-DFlash2 (mirror of incoai/Qwen3.8-27B-DFlash2), pinned to
# upstream revision ac04198556d7e8867853cbc356807b969f311b05 (repo last
# modified 2026-08-18T20:19:51Z). Single model.safetensors, 1.92B params BF16
# (~3.6 GiB), Apache-2.0. It is a draft model only — it runs inside a
# speculative-decoding server next to the Qwen3.8-27B target (downloaded
# separately by download-qwen38-27b.sh), never standalone.
#
# Default destination is the desktop user's Desktop folder:
#   $HOME/Desktop/Qwen3.8-27B-DFlash2
# (deliberate deviation from the /models convention for all other
# checkpoints; override with DFLASH2_DEST, e.g.
#   DFLASH2_DEST=/models/Qwen3.8-27B-DFlash2 bash $0). The SGLang launcher
# reads the same default, so the two scripts agree out of the box.
#
# Runs the download in a throwaway Python container (docker + network host).
# Idempotent and resumable: re-run after an interruption to continue.
#
# See docs/runbooks/qwen38-27b-dflash2-runbook-2026-08-19.md.
set -euo pipefail

REPO="z-lab/Qwen3.8-27B-DFlash2"
REV="ac04198556d7e8867853cbc356807b969f311b05"

# Resolve the desktop user's home even when invoked under sudo, so the
# default destination lands in the human's Desktop, not /root.
if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != root ]]; then
  DESKTOP_HOME="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
else
  DESKTOP_HOME="$HOME"
fi
DEST="${DFLASH2_DEST:-$DESKTOP_HOME/Desktop/Qwen3.8-27B-DFlash2}"

# Optional HF auth: if a token exists at the standard hf CLI location, mount
# it into the container at huggingface_hub's default token path so the
# download authenticates (higher rate limits, no unauthenticated warning).
# Get a read token at https://huggingface.co/settings/tokens and save it:
#   mkdir -p ~/.config/hf && echo "hf_..." > ~/.config/hf/token && chmod 600 ~/.config/hf/token
TOKEN_FILE="$DESKTOP_HOME/.config/hf/token"
EXTRA_VOLS=()
if [[ -f "$TOKEN_FILE" ]]; then
  EXTRA_VOLS+=(-v "$TOKEN_FILE:/root/.cache/huggingface/token:ro")
else
  echo "note: no HF token at $TOKEN_FILE - downloading unauthenticated (lower rate limits)" >&2
fi

mkdir -p "$DEST"
# The container runs as root; hand the directory back to the desktop user so
# a later unprivileged re-run (or the SGLang launcher's cp -a) can operate on it.
chown "$USER:users" "$DEST"

# Map the host destination into the container's namespace: only the desktop
# home (mounted at /home/dl) and /models (mounted 1:1) are reachable. Anything
# else is refused rather than silently written into the container layer.
case "$DEST" in
  "$DESKTOP_HOME"/*) CONTAINER_DEST="/home/dl${DEST#"$DESKTOP_HOME"}" ;;
  /models/*)         CONTAINER_DEST="$DEST" ;;
  *) echo "error: DFLASH2_DEST must be under $DESKTOP_HOME or /models (got: $DEST)" >&2; exit 2 ;;
esac

cat > /tmp/qwen38-dflash2-dl.sh <<EOF
set -e
pip install -q huggingface_hub
# hf-xet 1.6.0 was observed hanging indefinitely at 0% on this machine while
# direct Hub HTTPS remained healthy. Force the standard resumable HTTP backend.
export HF_HUB_DISABLE_XET=1
hf download "$REPO" --revision "$REV" --local-dir "$CONTAINER_DEST"
echo DOWNLOAD_COMPLETE
EOF

docker rm -f qwen38-dflash2-model-dl 2>/dev/null || true
docker run -d --name qwen38-dflash2-model-dl --network host \
  -v "$DESKTOP_HOME:/home/dl" -v /models:/models -v /tmp/qwen38-dflash2-dl.sh:/dl.sh:ro \
  ${EXTRA_VOLS[@]+"${EXTRA_VOLS[@]}"} \
  python:3.11-slim bash /dl.sh

echo "Downloading in container 'qwen38-dflash2-model-dl'. Follow with: docker logs -f qwen38-dflash2-model-dl"
echo "Destination: $DEST (container path: $CONTAINER_DEST)"
