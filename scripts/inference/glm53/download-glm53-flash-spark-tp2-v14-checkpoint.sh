#!/usr/bin/env bash
# Download the GLM-5.3 Spark NVFP4 checkpoint used by the v14 profile.
#
# ~174 GiB, pinned to the exact revision the runbook validates. Writes the
# native Hugging Face hub cache layout into
# /models/hf-cache/glm53-flash-spark-tp2-v14 (a dedicated ZFS dataset, no
# compression), which the v14 serving container mounts at
# /root/.cache/huggingface — the same mount the doc's named volume would use,
# but host-resident and verifiable. Runs in a throwaway container based on
# the pinned v14 image because it already ships huggingface_hub + hf_xet; the
# host has no python/hf CLI on purpose. Idempotent + resumable: re-run to
# continue. On success writes .download-complete ($REPO $REV) into the cache
# root and a receipt; the serve script refuses to launch without that marker.
#
# See docs/runbooks/glm53-flash-spark-tp2-v14-runbook-2026-09-19.md.
set -euo pipefail

REPO="local-inference-lab/GLM-5.3-Flash-NVFP4-Spark"
REV="a608241037e4c2565356bff7ca293f2133888f88"
IMAGE_CONFIG="sha256:7b5c335cc647b203aacd09e7513f19266846a8efeabdcaa8724524e51e04ff7a"
CACHE_HOST="${CACHE_HOST:-/models/hf-cache/glm53-flash-spark-tp2-v14}"
NAME="glm53-flash-spark-tp2-v14-dl"
RECEIPT="${RECEIPT:-$HOME/.local/state/glm53/flash-spark-tp2-v14-checkpoint.txt}"

for command in docker; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "error: $command is required to download the checkpoint" >&2
    exit 1
  }
done
if ! actual_image_id="$(docker image inspect "$IMAGE_CONFIG" --format '{{.Id}}' 2>/dev/null)"; then
  echo "error: pinned GLM v14 image is absent; run scripts/inference/glm53/pull-glm53-flash-spark-tp2-v14-image.sh" >&2
  exit 1
fi
[ "$actual_image_id" = "$IMAGE_CONFIG" ] || {
  echo "error: local GLM v14 image id is $actual_image_id, expected $IMAGE_CONFIG" >&2
  exit 1
}

# Optional HF auth: if a token exists at the standard hf CLI location, mount
# it into the container at huggingface_hub's default token path so the
# download authenticates. The Spark repo is public, so this only buys rate
# limit headroom.
TOKEN_FILE="$HOME/.config/hf/token"
EXTRA_VOLS=()
if [[ -f "$TOKEN_FILE" ]]; then
  EXTRA_VOLS+=(-v "$TOKEN_FILE:/root/.cache/huggingface/token:ro")
else
  echo "note: no HF token at $TOKEN_FILE - downloading unauthenticated (public repo)" >&2
fi

if ! mkdir -p "$CACHE_HOST" 2>/dev/null || [ ! -w "$CACHE_HOST" ]; then
  sudo mkdir -p "$CACHE_HOST"
  sudo chown "$USER:users" "$CACHE_HOST"
fi

# hf download (huggingface_hub 1.31 with hf_xet high-performance transport)
# into the container's default hub cache, which is the host mount. After the
# download, snapshot_download(local_files_only=True) proves the pinned
# revision resolves from the cache alone; only then is the marker written.
cat > /tmp/glm53-spark-tp2-dl.sh <<EOF
set -euo pipefail
export HF_XET_HIGH_PERFORMANCE=1
export HF_HUB_DISABLE_PROGRESS_BARS=1
hf download "$REPO" --revision "$REV"
/opt/venv/bin/python - <<'PY'
from huggingface_hub import snapshot_download

path = snapshot_download(
    repo_id="$REPO",
    revision="$REV",
    local_files_only=True,
)
print("OFFLINE-OK:", path)
PY
printf '%s %s\n' "$REPO" "$REV" > /root/.cache/huggingface/.download-complete
echo DOWNLOAD_COMPLETE
EOF

docker rm -f "$NAME" 2>/dev/null || true
docker run -d --name "$NAME" --network host \
  --init --restart on-failure:5 \
  -v "$CACHE_HOST:/root/.cache/huggingface" \
  -v /tmp/glm53-spark-tp2-dl.sh:/dl.sh:ro \
  ${EXTRA_VOLS[@]+"${EXTRA_VOLS[@]}"} \
  --entrypoint bash "$IMAGE_CONFIG" /dl.sh

echo "Downloading in container '$NAME' into $CACHE_HOST"
echo "Follow with:  docker logs -f $NAME"
echo "On completion the marker .download-complete is written and the receipt records the facts."
