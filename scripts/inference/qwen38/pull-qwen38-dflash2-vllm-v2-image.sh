#!/usr/bin/env bash
# Pull the first fixed official vLLM DFlash2 nightly by immutable registry digest.
# No custom build is needed: vLLM #52816 is merged and nightly a9a17e7 includes
# the #53435 decoder-layer regression fix required to load DFlash2 checkpoints.
set -euo pipefail

IMAGE="vllm/vllm-openai:nightly-a9a17e7095a66ef6c6685a1c7ddd657781a78d3c"
IMAGE_DIGEST="sha256:3578c1fa6a9676e1de068b9d75c777cc865d251fadfbe6175ae82278739c6674"
IMAGE_SOURCE_SHA="a9a17e7095a66ef6c6685a1c7ddd657781a78d3c"
IMAGE_REF="$IMAGE@$IMAGE_DIGEST"

command -v docker >/dev/null 2>&1 || { echo "error: docker is required" >&2; exit 1; }

echo "Pulling fixed official vLLM DFlash2 image:"
echo "  $IMAGE_REF"
docker pull "$IMAGE_REF"

actual_source_sha="$(docker image inspect --format '{{index .Config.Labels "ai.vllm.build.commit"}}' "$IMAGE_REF")"
if [ "$actual_source_sha" != "$IMAGE_SOURCE_SHA" ]; then
  echo "error: pulled image source label is $actual_source_sha, expected $IMAGE_SOURCE_SHA" >&2
  exit 1
fi

docker image inspect --format='id={{.Id}} repo_digests={{json .RepoDigests}} source={{index .Config.Labels "ai.vllm.build.commit"}}' "$IMAGE_REF"
echo "VLLM_DFLASH2_OFFICIAL_V2_PULL_COMPLETE"
