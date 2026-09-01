#!/usr/bin/env bash
# Prove the local immutable DS4 Vision r21 image and checkpoint.
set -euo pipefail

IMAGE="sha256:f5b3c70a39613bd2459bc186068e8e67720cf69b407a7c91b12a0585bf0ed183"
TAG="peterstorm/vllm:ds4-flash-vision-r21-v1"
MODEL_HOST="${MODEL_HOST:-$HOME/models/DeepSeek-V4-Flash-Vision-Exp}"
MODEL_REV="86f746b36186f0e567729a5c06a8c918caba82a9"

actual="$(docker image inspect "$TAG" --format '{{.Id}}' 2>/dev/null)" || {
  echo "error: $TAG is absent; run build-ds4-flash-vision-r21-image.sh" >&2
  exit 1
}
[[ "$actual" == "$IMAGE" ]] || {
  echo "error: $TAG resolves to $actual, expected $IMAGE" >&2
  exit 1
}
docker image inspect "$IMAGE" --format '{{json .Config.Labels}}' | jq -e \
  --arg revision "$MODEL_REV" '
    .["local-inference.base.digest"] == "sha256:ed525dec1a4ac5cf7f19c7cf2fb29661389d71a29ff8de91aade8e6785e10291" and
    .["local-inference.vllm.tree"] == "d6cf36ae0dc30d48fd656a3c34a353ec62074922" and
    .["local-inference.ds4.vision.model-revision"] == $revision and
    .["org.opencontainers.image.revision"] == "800f7ad21304e8be633428ad0db4ef49839b75bff84071b84ef9f44c78042469"
  ' >/dev/null

docker run --rm -v "$MODEL_HOST:/model:ro" --entrypoint python3 "$IMAGE" \
  /opt/ds4-vision-r21/verify.py --static --checkpoint /model

state_dir="$HOME/.local/state/ds4-vision"
mkdir -p "$state_dir"
identity="$state_dir/r21-v1-image.identity"
temporary="$identity.tmp.$$"
{
  printf 'image_id=%s\n' "$IMAGE"
  printf 'tag=%s\n' "$TAG"
  printf 'base_digest=%s\n' 'sha256:ed525dec1a4ac5cf7f19c7cf2fb29661389d71a29ff8de91aade8e6785e10291'
  printf 'vllm_tree=%s\n' 'd6cf36ae0dc30d48fd656a3c34a353ec62074922'
  printf 'patch_sha256=%s\n' '800f7ad21304e8be633428ad0db4ef49839b75bff84071b84ef9f44c78042469'
  printf 'model_revision=%s\n' "$MODEL_REV"
} >"$temporary"
chmod 600 "$temporary"
mv "$temporary" "$identity"
printf 'Verified immutable DS4 Vision image %s; identity: %s\n' "$IMAGE" "$identity"
