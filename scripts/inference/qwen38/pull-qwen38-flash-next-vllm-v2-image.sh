#!/usr/bin/env bash
# Build if absent, then prove and retag the immutable Qwen3.8 Flash-Next v2 image.
set -euo pipefail

IMAGE_TAG="peterstorm/vllm:qwen38-flash-next-v2-safe"
IMAGE_ID="sha256:931c3c595e48f63c1900ee559966cad845673e37bdc2bd73ce5f49390a8154e1"
SOURCE_COMMIT="e126687a9a828d513c01a07cd69f025f27d63280"
SOURCE_OVERLAY_COMMIT="c0ac28980016af357df50359d301648352eebbf2"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD="$SCRIPT_DIR/build-qwen38-flash-next-vllm-v2-image.sh"
IDENTITY_FILE="${IDENTITY_FILE:-$HOME/.local/state/qwen38/flash-next-vllm-v2-image.identity}"

for command in docker jq sha256sum; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "error: $command is required" >&2
    exit 1
  }
done

if ! docker image inspect "$IMAGE_ID" >/dev/null 2>&1; then
  "$BUILD"
fi
actual_id="$(docker image inspect "$IMAGE_ID" --format '{{.Id}}')"
[ "$actual_id" = "$IMAGE_ID" ] || {
  echo "error: image config is $actual_id, expected $IMAGE_ID" >&2
  exit 1
}
docker tag "$IMAGE_ID" "$IMAGE_TAG"

inspect="$(docker image inspect "$IMAGE_ID")"
jq -e --arg image "$IMAGE_TAG" --arg source "$SOURCE_COMMIT" \
  --arg overlay "$SOURCE_OVERLAY_COMMIT" '.[0] |
  .Architecture == "amd64" and
  .Os == "linux" and
  .Config.Entrypoint == ["vllm", "serve"] and
  .Config.Labels["ai.peterstorm.inference.overlay"] == "qwen38-flash-next-v2-safe" and
  .Config.Labels["ai.peterstorm.inference.source-commit"] == $source and
  .Config.Labels["ai.peterstorm.inference.source-overlay-commit"] == $overlay and
  .Config.Labels["ai.peterstorm.inference.repaired-source-overlay-commit"] == $overlay and
  .Config.Labels["ai.peterstorm.inference.large-topk-ties"] == "deterministic-global-token-index" and
  .Config.Labels["ai.peterstorm.inference.ple-state-bounds"] == "accepted-count-and-state-row-fail-closed" and
  .Config.Labels["ai.peterstorm.inference.qsa-order"] == "ascending-compressed-block-index" and
  .Config.Labels["ai.peterstorm.inference.prefix-cache"] == "disabled-until-equivalence-qualified" and
  any(.Config.Env[]; . == "VLLM_PLE_CPU_OFFLOAD=1") and
  any(.Config.Env[]; . == ("VLLM_BUILD_COMMIT=" + $overlay)) and
  any(.Config.Env[]; . == "CUDA_VERSION=13.0.3")
' <<<"$inspect" >/dev/null || {
  echo "error: Qwen3.8 Flash-Next v2 image provenance or runtime invariants differ" >&2
  exit 1
}

docker run --rm -i --entrypoint python3 "$IMAGE_ID" - <<'PY'
import hashlib
import inspect
import os
from importlib.metadata import version
from pathlib import Path

import vllm
from vllm import envs
from vllm.model_executor.models.registry import ModelRegistry
from vllm.models.qwen4_exp.nvidia import ple_layer
from vllm.models.qwen4_exp.nvidia.ops import qsa

expected = {
    inspect.getfile(qsa): "5baec281455281510c0929e939f978e72ba39d77eaf4f97417c218052debeabf",
    inspect.getfile(ple_layer): "79ccc700f665d7b0a86f8c4b6de5837e5183ec699aa318da014755eacd47acc3",
}
for path, digest in expected.items():
    with open(path, "rb") as source:
        assert hashlib.sha256(source.read()).hexdigest() == digest
extension = next(Path(vllm.__file__).parent.glob("_C_stable_libtorch*.so"))
assert hashlib.sha256(extension.read_bytes()).hexdigest() == "c7d4513f12740b58f01b6903128227d02bda7f6c1d1491a50f4e38955824ea95"
assert envs.VLLM_PLE_CPU_OFFLOAD is True
assert os.environ["VLLM_BUILD_COMMIT"] == "c0ac28980016af357df50359d301648352eebbf2"
assert "Qwen4ExpForConditionalGeneration" in ModelRegistry.get_supported_archs()
assert hasattr(ple_layer, "Qwen4ExpPinnedHostEmbedding")
assert hasattr(qsa, "qsa_select_paged_tokens")
print(f"Qwen3.8 Flash-Next v2 static capability probe: PASS (vllm={version('vllm')})")
PY

install -d -m 700 "$(dirname "$IDENTITY_FILE")"
umask 077
cat >"$IDENTITY_FILE" <<EOF
source_commit=$SOURCE_COMMIT
source_overlay_commit=$SOURCE_OVERLAY_COMMIT
final_image=$IMAGE_TAG
final_image_id=$IMAGE_ID
ple_cpu_offload=uva-pinned-host
persistent_topk=exact-lower-index-ties
qsa_order=ascending-compressed-block-index
accepted_state_bounds=fail-closed
large_topk_ties=deterministic-global-token-index
stable_extension_sha256=c7d4513f12740b58f01b6903128227d02bda7f6c1d1491a50f4e38955824ea95
prefix_caching=disabled
EOF
chmod 600 "$IDENTITY_FILE"
printf 'Verified immutable Flash-Next v2 image %s; identity: %s\n' "$IMAGE_ID" "$IDENTITY_FILE"
