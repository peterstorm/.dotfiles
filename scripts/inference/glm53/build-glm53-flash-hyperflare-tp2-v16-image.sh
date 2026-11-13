#!/usr/bin/env bash
# Build the GLM-5.3 v16 Hyperflare image on the serving host.
#
# There is no published image: the recipe ships source, not binaries. The
# Dockerfile in glm53-v16-hyperflare/ pins every input (base images by digest,
# the fork by full commit, uv.lock/Cargo.lock --locked, rustc by version), so
# this is a reproducible local build rather than a floating one. The image is
# tagged by fork commit and CUDA version and labelled with the commit; the
# export and run scripts refuse an image whose label differs.
#
# ~20-40 min on a cold Docker cache (torch cu132 + FlashInfer + the flare
# binary); no GPU needed, safe to run while another profile serves.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE="peterstorm/glm53-hyperflare:ac9136b-cu131"
HYPERFLARE_COMMIT="ac9136b02c7c523f12d6e628e9d94f41006312ea"

docker build --progress=plain -t "$IMAGE" "$SCRIPT_DIR/glm53-v16-hyperflare"
label="$(docker image inspect "$IMAGE" --format '{{index .Config.Labels "ai.peterstorm.inference.hyperflare-commit"}}')"
[ "$label" = "$HYPERFLARE_COMMIT" ] || { echo "error: built image label is $label" >&2; exit 1; }
docker run --rm --entrypoint /opt/flare/flare-cli/target/release/flare "$IMAGE" --version
echo "IMAGE OK: $IMAGE ($(docker image inspect "$IMAGE" --format '{{.Id}}'))"
