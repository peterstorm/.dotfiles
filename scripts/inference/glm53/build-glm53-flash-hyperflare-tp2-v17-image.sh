#!/usr/bin/env bash
# Build the GLM-5.3 v17 Hyperflare image on the serving host.
#
# No image is published for upstream Hyperflare + the two open Local Inference
# Lab PRs, so this is a reproducible local build: every source is a full commit
# from glm53-v17-hyperflare/pins.sh, passed as a required build argument and
# recorded as a label; the export and run scripts refuse an image whose labels
# differ. No GPU needed; safe while another profile serves.
#
# Disk: the build caches (cargo, uv, maturin) live on tmpfs mounts, so the pool
# only has to hold the finished image (~20 GB, most of it torch cu132). It
# refuses when Docker's filesystem has less than MIN_FREE_GIB free: a ZFS pool
# driven to 100% stalls everything on it, the serving profile included.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/inference/glm53/glm53-v17-hyperflare/pins.sh
source "$SCRIPT_DIR/glm53-v17-hyperflare/pins.sh"
MIN_FREE_GIB="${MIN_FREE_GIB:-30}"

docker_root="$(docker info --format '{{.DockerRootDir}}')"
free_gib="$(($(df --output=avail -B1 "$docker_root" | tail -1 | tr -d ' ') / 1024 / 1024 / 1024))"
((free_gib >= MIN_FREE_GIB)) || {
  echo "error: $docker_root has $free_gib GiB free; the build needs at least $MIN_FREE_GIB GiB (MIN_FREE_GIB)" >&2
  exit 1
}

docker build --progress=plain -t "$V17_IMAGE" \
  --build-arg "HYPERFLARE_INFERENCE_COMMIT=$V17_HYPERFLARE_INFERENCE_COMMIT" \
  --build-arg "RECIPES_COMMIT=$V17_RECIPES_COMMIT" \
  --build-arg "FLASHINFER_COMMIT=$V17_FLASHINFER_COMMIT" \
  "$SCRIPT_DIR/glm53-v17-hyperflare"
labels="$(docker image inspect "$V17_IMAGE" --format "$(v17_image_labels_format)")"
mismatch="$(v17_image_matches_pins "$labels")" || { echo "error: built image $mismatch" >&2; exit 1; }
docker run --rm --entrypoint flare "$V17_IMAGE" --version
echo "IMAGE OK: $V17_IMAGE ($(docker image inspect "$V17_IMAGE" --format '{{.Id}}'))"
