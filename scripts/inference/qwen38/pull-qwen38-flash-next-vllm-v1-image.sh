#!/usr/bin/env bash
# Pull and prove the special Qwen3.8 Flash-Next vLLM image with PLE CPU offload.
set -euo pipefail

IMAGE="vllm/vllm-openai@sha256:0aea30240f3e3d9ffae8526643950e170eb5fa07fc427016a9dd90892afa2aa3"
EXPECTED_ID="sha256:bd995759b5b8ac51062e04c9e4d7c91c382d1ba377bb787e24dca2ccb39925e9"
IDENTITY_FILE="${IDENTITY_FILE:-$HOME/.local/state/qwen38/flash-next-vllm-v1-image.identity}"

[ "$(uname -s)" = Linux ] && [ "$(uname -m)" = x86_64 ] || {
  echo "error: this image is prepared only for linux/amd64 hosts" >&2
  exit 1
}
command -v jq >/dev/null 2>&1 || {
  echo "error: jq is required to prove image configuration" >&2
  exit 1
}

docker pull "$IMAGE"
actual_id="$(docker image inspect "$IMAGE" --format '{{.Id}}')"
[ "$actual_id" = "$EXPECTED_ID" ] || {
  echo "error: image config identity differs: expected $EXPECTED_ID, found $actual_id" >&2
  exit 1
}
inspect="$(docker image inspect "$IMAGE")"
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
' <<<"$inspect" >/dev/null || {
  echo "error: image platform, entrypoint, CUDA, or provenance labels differ" >&2
  exit 1
}

docker run --rm -i \
  -e VLLM_PLE_CPU_OFFLOAD=1 \
  --entrypoint python3 \
  "$IMAGE" - <<'PY'
from importlib.metadata import version

from vllm import envs
from vllm.model_executor.layers.ple_offload_layer import PleOffloadLayer
from vllm.model_executor.models.registry import ModelRegistry
from vllm.models.qwen3_8_flash_next.nvidia.ple_layer import (
    Qwen3_8FlashNextNGramEmbedding,
)

package_version = version("vllm")
assert package_version == "0.1.dev20073+g8e685d198"
assert envs.VLLM_PLE_CPU_OFFLOAD is True
assert issubclass(Qwen3_8FlashNextNGramEmbedding, PleOffloadLayer)
supported = ModelRegistry.get_supported_archs()
assert "Qwen3_8FlashNextForConditionalGeneration" in supported
assert "Qwen4ExpForConditionalGeneration" in supported
print(f"Qwen3.8 Flash-Next PLE CPU-offload capability probe: PASS ({package_version})")
PY

install -d -m 700 "$(dirname "$IDENTITY_FILE")"
umask 077
cat >"$IDENTITY_FILE" <<EOF_IDENTITY
image=$IMAGE
image_id=$EXPECTED_ID
image_index=sha256:fc120ece0a388cc0aa1caad4a9f1cd92113484ab7ec2fd0efadd62585be05bf8
platform=linux/amd64
cuda=13.0.1
vllm_package=0.1.dev20073+g8e685d198
vllm_build_commit=unknown
vllm_build_pipeline=local
source_pr_model=https://github.com/vllm-project/vllm/pull/53896
source_pr_ple_offload=https://github.com/vllm-project/vllm/pull/53899
EOF_IDENTITY
chmod 600 "$IDENTITY_FILE"
printf 'Verified %s; identity: %s\n' "$IMAGE" "$IDENTITY_FILE"
printf '%s\n' 'WARNING: the exact image is pinned, but its embedded build commit is unknown; runtime qualification and eventual replacement remain mandatory.'
