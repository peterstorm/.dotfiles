#!/usr/bin/env bash
# Build and prove GLM v84 plus state-safety and exact sparse-top-k overlays.
set -euo pipefail

BASE_INDEX="sha256:0f1cdcc8891f1cc3a444121eb61d366289a1cbba285f0892dcbb24bc94961692"
BASE_IMAGE="verdictai/glm53-flash-exl3-k4@sha256:184cfdb86fb08902898999ce5d7101f5711e3138f82b4738ba823145c17f8140"
BASE_ID="sha256:f28ba4b2192d8306f2ab93be9ea868459f76e2fd5893d4eef9f7cc48f9180578"
DERIVED_TAG="peterstorm/vllm:glm53-state-safety-exact-topk-ties-51782-pr50021"
DERIVED_ID="sha256:ab8bf15ab9bd35c01dd1dac3d1a7474e3922f507bb3159695059ac9bbc1eed8d"
UPSTREAM_PR_HEAD="9a198c0f8452d0eb251509f02753853903d9f17f"
PATCH_SHA256="a8e288ec067fed7e2e38762ca71e6034982dc4d40dc02ceec5caa1dc319ace85"
EXACT_TOPK_PATCH_SHA256="00254654846b80fc0ff44019ca0641586023b46993bac4af3e579cf8522a3041"
SOURCE_DATE_EPOCH=1788048000
IDENTITY_FILE="${IDENTITY_FILE:-$HOME/.local/state/glm53/exl3-k4-vllm-sm120-v8-image.identity}"
PUBLICATION_REV="bd5321c1cfd4b8d352ef380e3158c64886039d03"
MODEL_REV="5ab363a8dcf6405955fd5f99671e01a1c9fb124b"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OVERLAY_DIR="$SCRIPT_DIR/glm53-mtp-prefix-safety"

[ "$(uname -s)" = Linux ] && [ "$(uname -m)" = x86_64 ] || {
  echo "error: this image is prepared only for linux/amd64 SM120 hosts" >&2
  exit 1
}
for command in docker jq sha256sum; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "error: $command is required to build and prove the image" >&2
    exit 1
  }
done
[ "$(sha256sum "$OVERLAY_DIR/glm53-mtp-prefix-state-safety.patch" | cut -d' ' -f1)" = "$PATCH_SHA256" ] || {
  echo "error: vendored GLM MTP/prefix-state patch identity differs" >&2
  exit 1
}
[ "$(sha256sum "$OVERLAY_DIR/glm53-exact-sparse-topk.patch" | cut -d' ' -f1)" = "$EXACT_TOPK_PATCH_SHA256" ] || {
  echo "error: vendored GLM exact sparse-top-k patch identity differs" >&2
  exit 1
}

docker pull "$BASE_IMAGE"
actual_base_id="$(docker image inspect "$BASE_IMAGE" --format '{{.Id}}')"
[ "$actual_base_id" = "$BASE_ID" ] || {
  echo "error: v84 base image config differs: expected $BASE_ID, found $actual_base_id" >&2
  exit 1
}
base_inspect="$(docker image inspect "$BASE_IMAGE")"
jq -e '.[0] |
  .Architecture == "amd64" and
  .Os == "linux" and
  (.RootFS.Layers | length) == 113 and
  .Config.Entrypoint == ["/opt/venv/bin/vllm"] and
  .Config.Labels["org.opencontainers.image.title"] == "GLM-5.3-Flash EXL3 K4 SM120 DFlash2" and
  .Config.Labels["org.opencontainers.image.revision"] == "dflash2-triton-swa-vision-20260828" and
  .Config.Labels["local-inference.glm53.vision"] == "validated-runtime-path" and
  .Config.Labels["local-inference.vllm.commit"] == "6dc2f516688fe6f84c6994dcd20fddf296853a6c" and
  .Config.Labels["local-inference.cuda.version"] == "13.3" and
  .Config.Labels["local-inference.torch.version"] == "2.13.0"
' <<<"$base_inspect" >/dev/null || {
  echo "error: v84 base platform, runtime, vision, or provenance differs" >&2
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
actual_derived_id="$(docker image inspect "$DERIVED_TAG" --format '{{.Id}}')"
[ "$actual_derived_id" = "$DERIVED_ID" ] || {
  echo "error: GLM safety overlay differs: expected $DERIVED_ID, found $actual_derived_id" >&2
  echo "Rebuild deliberately, qualify it, then update every image pin together." >&2
  exit 1
}
derived_inspect="$(docker image inspect "$DERIVED_ID")"
jq -e --arg base "$BASE_IMAGE" --arg patch "$PATCH_SHA256" --arg exact "$EXACT_TOPK_PATCH_SHA256" --arg pr "vllm-project/vllm#50021@$UPSTREAM_PR_HEAD" '.[0] |
  .Architecture == "amd64" and
  .Os == "linux" and
  (.RootFS.Layers | length) == 115 and
  .Config.Entrypoint == ["/opt/venv/bin/vllm"] and
  .Config.Labels["ai.peterstorm.inference.base-image"] == $base and
  .Config.Labels["ai.peterstorm.inference.overlay"] == "glm53-mtp-prefix-state-safety" and
  .Config.Labels["ai.peterstorm.inference.overlay-upstream-pr"] == $pr and
  .Config.Labels["ai.peterstorm.inference.overlay-patch-sha256"] == $patch and
  .Config.Labels["ai.peterstorm.inference.exact-topk-issue"] == "vllm-project/vllm#51782" and
  .Config.Labels["ai.peterstorm.inference.exact-topk-patch-sha256"] == $exact and
  .Config.Labels["ai.peterstorm.inference.gdn-mixed-partition"] == "cpu-proven-complete-in-range"
' <<<"$derived_inspect" >/dev/null || {
  echo "error: GLM safety overlay platform, labels, or layer count differs" >&2
  exit 1
}
mapfile -t base_layers < <(jq -r '.[0].RootFS.Layers[]' <<<"$base_inspect")
mapfile -t derived_layers < <(jq -r '.[0].RootFS.Layers[]' <<<"$derived_inspect")
for index in "${!base_layers[@]}"; do
  [ "${derived_layers[$index]}" = "${base_layers[$index]}" ] || {
    echo "error: GLM safety overlay does not retain the exact base rootfs prefix at layer $index" >&2
    exit 1
  }
done

docker run --rm -i --gpus all --entrypoint /opt/venv/bin/python "$DERIVED_ID" - <<'PY'
import hashlib
import json
from pathlib import Path

import torch
from vllm.model_executor.layers.rotary_embedding.common import ApplyRotaryEmb
from vllm.model_executor.layers.sparse_attn_indexer import _exact_sparse_attn_topk
from vllm.model_executor.models.registry import ModelRegistry
from vllm.v1.attention.backends.gdn_attn import _build_mixed_token_indices_cpu
from vllm.v1.attention.backends.registry import AttentionBackendEnum

root = Path("/opt/infernal-invocation/vllm/vllm")
expected = {
    "model_executor/layers/sparse_attn_indexer.py": "cc73aebd80723718331b40782623e799e7ba61f143d1ab2f8bfd3f4877c5ce34",
    "model_executor/layers/sparse_attn_indexer_kpool.py": "a5345e5703232d61d285a988ca67757d19828ef5b0bcc10e161c17c6a5c2f5d2",
    "third_party/flash_linear_attention/ops/fused_recurrent.py": "f98f8a5a5cdc3a746637656350d7f72349c5a03b2272657c082086ab86a15135",
    "v1/attention/backends/gdn_attn.py": "04b1733d7d65ddcaefab59143bc59dbe61f8bc0404c1fcc5cddcd82a1718f697",
    "v1/worker/mamba_utils.py": "10306573a3b19d816f9066ff7b14679aa07e9eefe347f68952fe5c04f923753d",
}
for relative, digest in expected.items():
    assert hashlib.sha256((root / relative).read_bytes()).hexdigest() == digest
for relative in (
    "model_executor/layers/sparse_attn_indexer.py",
    "model_executor/layers/sparse_attn_indexer_kpool.py",
):
    assert "torch.ops._C.persistent_topk(" not in (root / relative).read_text()
provenance_path = Path("/opt/glm53/PROVENANCE.json")
assert hashlib.sha256(provenance_path.read_bytes()).hexdigest() == "cf4b00958987cc50f94641592b1a8d74874adb4d671861ce12dd5e8f2907d907"
provenance = json.loads(provenance_path.read_text())
assert provenance["release"] == "r19-sm120-tp2-ep2-dcp2-v84-dflash2"
template_path = Path("/opt/glm53/chat_template.multimodal.jinja")
assert hashlib.sha256(template_path.read_bytes()).hexdigest() == "34d5ee66b12fa6446cdae131c352b8f68cd85369e0e6fda115583805fada3891"
template = template_path.read_text()
assert "<|begin_of_image|><|image|><|end_of_image|>" in template
assert "Glm5NextForConditionalGeneration" in ModelRegistry.get_supported_archs()
assert "TORCH_SDPA" in AttentionBackendEnum.__members__
assert "FLASHINFER_MLA_SPARSE_SM120" in AttentionBackendEnum.__members__
columns, visible, topk = 806_736, 4_096, 512
logits = torch.full((1, columns), float("inf"), dtype=torch.float32, device="cuda")
logits[0, :visible] = torch.arange(
    columns, columns - visible, -1, dtype=torch.float32, device="cuda"
)
seq_lens = torch.tensor([visible], dtype=torch.int32, device="cuda")
topk_indices = torch.empty((1, topk), dtype=torch.int32, device="cuda")
expected_indices = torch.arange(topk, dtype=torch.int32, device="cuda")
for _ in range(10):
    _exact_sparse_attn_topk(logits, seq_lens, topk_indices, topk)
    torch.testing.assert_close(topk_indices[0], expected_indices)
tied_logits = torch.tensor([[5.0, 5.0, 5.0, 4.0, 99.0]], device="cuda")
tied_lens = torch.tensor([4], dtype=torch.int32, device="cuda")
tied_indices = torch.empty((1, 5), dtype=torch.int32, device="cuda")
for _ in range(20):
    _exact_sparse_attn_topk(tied_logits, tied_lens, tied_indices, 5)
torch.testing.assert_close(
    tied_indices[0], torch.tensor([0, 1, 2, 3, -1], dtype=torch.int32, device="cuda")
)
for masks, lens in (([True, False], [4, 543]), ([True, False, False], [4, 0, 271])):
    actual = sum(lens)
    expected_non_spec = sum(length for mask, length in zip(masks, lens) if not mask)
    non_spec, spec = _build_mixed_token_indices_cpu(
        torch.tensor(masks), torch.tensor(lens, dtype=torch.int32), actual, expected_non_spec
    )
    torch.testing.assert_close(torch.cat((non_spec, spec)).sort().values, torch.arange(actual))
rotary = ApplyRotaryEmb.__new__(ApplyRotaryEmb)
object.__setattr__(rotary, "is_neox_style", True)
object.__setattr__(rotary, "enable_fp32_compute", False)
object.__setattr__(rotary, "apply_rotary_emb_vllm_flash_attn", None)
x = torch.randn(2, 5, 3, 8)
cos = torch.randn(5, 4)
sin = torch.randn(5, 4)
torch.testing.assert_close(rotary.forward_cuda(x, cos, sin), rotary.forward_native(x, cos, sin))
print("GLM-5.3 state safety + exact sparse top-k + multimodal capability probe: PASS")
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
publication_revision=$PUBLICATION_REV
model_revision=$MODEL_REV
vllm=6dc2f516688fe6f84c6994dcd20fddf296853a6c
upstream_state_bounds_pr=vllm-project/vllm#50021@$UPSTREAM_PR_HEAD
overlay_patch_sha256=$PATCH_SHA256
exact_topk_issue=vllm-project/vllm#51782
exact_topk_patch_sha256=$EXACT_TOPK_PATCH_SHA256
gdn_mixed_partition=cpu-proven-complete-in-range
profile_capabilities=multimodal,fp8_ds_mla,flashinfer_mla_sparse_sm120,prefix_cache,mtp3,state_bounds,exact_sparse_topk
EOF_IDENTITY
chmod 600 "$IDENTITY_FILE"
printf 'Verified GLM safety overlay %s; identity: %s\n' "$DERIVED_ID" "$IDENTITY_FILE"
