#!/usr/bin/env bash
# Pull the special Flash-Next base, build the deterministic QSA overlay, and prove both identities.
set -euo pipefail

BASE_INDEX="sha256:fc120ece0a388cc0aa1caad4a9f1cd92113484ab7ec2fd0efadd62585be05bf8"
BASE_IMAGE="vllm/vllm-openai@sha256:0aea30240f3e3d9ffae8526643950e170eb5fa07fc427016a9dd90892afa2aa3"
BASE_ID="sha256:bd995759b5b8ac51062e04c9e4d7c91c382d1ba377bb787e24dca2ccb39925e9"
DERIVED_TAG="peterstorm/vllm:qwen38-flash-next-fp8-topk3-docai-522430a"
DERIVED_ID="sha256:32a26fee4a4225b565017c36ce4f6589d716d608b59bbaa93c712a31a8433a32"
PATCH_SHA256="b2d642b9a54c504d8ad109888767cbbf2eda760f8c4edda6b12732ac22c174e4"
PATCHED_QSA_SHA256="79d13ab4a3805bd568e3b930cd0cc193fbf5997403f9d4e809838193c14204dc"
SOURCE_DATE_EPOCH=1787875200
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OVERLAY_DIR="$SCRIPT_DIR/flash-next-topk3"
IDENTITY_FILE="${IDENTITY_FILE:-$HOME/.local/state/qwen38/flash-next-vllm-v1-image.identity}"

[ "$(uname -s)" = Linux ] && [ "$(uname -m)" = x86_64 ] || {
  echo "error: this image is prepared only for linux/amd64 hosts" >&2
  exit 1
}
for command in docker jq sha256sum; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "error: $command is required to build and prove the image" >&2
    exit 1
  }
done
[ "$(sha256sum "$OVERLAY_DIR/qsa-exact-topk.patch" | cut -d" " -f1)" = "$PATCH_SHA256" ] || {
  echo "error: vendored deterministic QSA patch identity differs" >&2
  exit 1
}

docker pull "$BASE_IMAGE"
actual_base_id="$(docker image inspect "$BASE_IMAGE" --format "{{.Id}}")"
[ "$actual_base_id" = "$BASE_ID" ] || {
  echo "error: base image config differs: expected $BASE_ID, found $actual_base_id" >&2
  exit 1
}
base_inspect="$(docker image inspect "$BASE_IMAGE")"
jq -e '.[0] |
  .Architecture == "amd64" and
  .Os == "linux" and
  (.RootFS.Layers | length) == 32 and
  .Config.Entrypoint == ["vllm", "serve"] and
  .Config.Labels["org.opencontainers.image.source"] == "https://github.com/vllm-project/vllm" and
  .Config.Labels["org.opencontainers.image.revision"] == "unknown" and
  .Config.Labels["ai.vllm.build.commit"] == "unknown" and
  .Config.Labels["ai.vllm.build.pipeline"] == "local" and
  .Config.Labels["ai.vllm.image.tag"] == "local/vllm-openai:dev" and
  any(.Config.Env[]; . == "CUDA_VERSION=13.0.1") and
  any(.Config.Env[]; . == "TORCH_CUDA_ARCH_LIST=7.5 8.0 8.6 8.9 9.0 10.0 12.0")
' <<<"$base_inspect" >/dev/null || {
  echo "error: base image platform, entrypoint, CUDA, or provenance labels differ" >&2
  exit 1
}

if docker image inspect "$DERIVED_ID" >/dev/null 2>&1; then
  docker tag "$DERIVED_ID" "$DERIVED_TAG"
else
  SOURCE_DATE_EPOCH="$SOURCE_DATE_EPOCH" docker buildx build \
    --provenance=false \
    --build-arg "SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH" \
    --output "type=docker,name=$DERIVED_TAG,rewrite-timestamp=true" \
    "$OVERLAY_DIR"
fi
actual_derived_id="$(docker image inspect "$DERIVED_TAG" --format "{{.Id}}")"
[ "$actual_derived_id" = "$DERIVED_ID" ] || {
  echo "error: deterministic QSA image config differs: expected $DERIVED_ID, found $actual_derived_id" >&2
  echo "Rebuild deliberately, validate it, then update the launcher and contract pin together." >&2
  exit 1
}

derived_inspect="$(docker image inspect "$DERIVED_ID")"
jq -e --arg base "$BASE_IMAGE" --arg patch "$PATCH_SHA256" '.[0] |
  .Architecture == "amd64" and
  .Os == "linux" and
  (.RootFS.Layers | length) == 34 and
  .Config.Entrypoint == ["vllm", "serve"] and
  .Config.Labels["ai.peterstorm.inference.base-image"] == $base and
  .Config.Labels["ai.peterstorm.inference.overlay"] == "qwen38-flash-next-qsa-exact-topk3" and
  .Config.Labels["ai.peterstorm.inference.overlay-patch-sha256"] == $patch and
  any(.Config.Env[]; . == "VLLM_QSA_EXACT_TOPK=3")
' <<<"$derived_inspect" >/dev/null || {
  echo "error: derived image layer count, base identity, overlay labels, or mode differs" >&2
  exit 1
}
mapfile -t base_layers < <(jq -r '.[0].RootFS.Layers[]' <<<"$base_inspect")
mapfile -t derived_layers < <(jq -r '.[0].RootFS.Layers[]' <<<"$derived_inspect")
for index in "${!base_layers[@]}"; do
  [ "${derived_layers[$index]}" = "${base_layers[$index]}" ] || {
    echo "error: derived image does not retain the exact base rootfs prefix at layer $index" >&2
    exit 1
  }
done

docker run --rm -i -e VLLM_PLE_CPU_OFFLOAD=1 --entrypoint python3 "$DERIVED_ID" - "$PATCHED_QSA_SHA256" <<'PY'
import hashlib
import inspect
import os
import sys
from importlib.metadata import version

from vllm import envs
from vllm.model_executor.layers.ple_offload_layer import PleOffloadLayer
from vllm.model_executor.models.registry import ModelRegistry
from vllm.models.qwen3_8_flash_next.nvidia.ops import qsa
from vllm.models.qwen3_8_flash_next.nvidia.ple_layer import Qwen3_8FlashNextNGramEmbedding

qsa_path = inspect.getfile(qsa)
assert version("vllm") == "0.1.dev20073+g8e685d198"
assert envs.VLLM_PLE_CPU_OFFLOAD is True
assert os.environ["VLLM_QSA_EXACT_TOPK"] == "3"
assert qsa._QSA_EXACT_TOPK == 3
assert hasattr(qsa, "_fast_topk")
assert hashlib.sha256(open(qsa_path, "rb").read()).hexdigest() == sys.argv[1]
assert issubclass(Qwen3_8FlashNextNGramEmbedding, PleOffloadLayer)
supported = ModelRegistry.get_supported_archs()
assert "Qwen3_8FlashNextForConditionalGeneration" in supported
assert "Qwen4ExpForConditionalGeneration" in supported
print("Qwen3.8 Flash-Next deterministic QSA top-k3 + PLE capability probe: PASS")
PY

install -d -m 700 "$(dirname "$IDENTITY_FILE")"
umask 077
cat >"$IDENTITY_FILE" <<EOF_IDENTITY
base_image_index=$BASE_INDEX
base_image=$BASE_IMAGE
base_image_id=$BASE_ID
derived_image=$DERIVED_TAG
derived_image_id=$DERIVED_ID
platform=linux/amd64
cuda=13.0.1
vllm_package=0.1.dev20073+g8e685d198
qsa_mode=3
qsa_patch_sha256=$PATCH_SHA256
qsa_source_sha256=$PATCHED_QSA_SHA256
qsa_patch_source=https://github.com/k3net/docai-evals/tree/522430ac96a4847583c3b0069757338cf27ab7ff/experiments/2026-08-28-qwen38-flash-next-nvfp4-topk-nondeterminism-gb10
EOF_IDENTITY
chmod 600 "$IDENTITY_FILE"
printf "Verified deterministic Flash-Next image %s; identity: %s\n" "$DERIVED_ID" "$IDENTITY_FILE"
