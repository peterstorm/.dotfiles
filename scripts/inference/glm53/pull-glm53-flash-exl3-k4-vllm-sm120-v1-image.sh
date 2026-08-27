#!/usr/bin/env bash
# Pull and prove the dedicated GLM-5.3 EXL3 K4 TP2/SM120 vLLM artifact.
set -euo pipefail

IMAGE="verdictai/glm53-flash-exl3-k4@sha256:a6962d4a45474e9b50e26d888d739076c5fbe51e5e531c2d11ead3d74285f484"
EXPECTED_ID="sha256:19a51d921523dd0c21afbf99bb49a00fc2d3feb6f565b1d3474ed0120372d847"
IDENTITY_FILE="${IDENTITY_FILE:-$HOME/.local/state/glm53/exl3-k4-vllm-sm120-v1-image.identity}"

[ "$(uname -s)" = Linux ] && [ "$(uname -m)" = x86_64 ] || {
  echo "error: this image is prepared only for linux/amd64 SM120 hosts" >&2
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
  (.RootFS.Layers | length) == 100 and
  .Config.Labels["org.opencontainers.image.title"] == "GLM-5.3-Flash EXL3 K4 SM120 TP2" and
  .Config.Labels["org.opencontainers.image.source"] == "https://github.com/local-inference-lab/blackwell-llm-docker" and
  .Config.Labels["org.opencontainers.image.revision"] == "54a4e2da5e976230864573c0d79bb0eb777dd382" and
  .Config.Labels["local-inference.glm53.vllm-base"] == "eb290e8162692b8dc5f4af7e5360f5794f983add" and
  .Config.Labels["local-inference.glm53.vllm-overlay"] == "df684ff47dcbf088b41311494fd20347a702e56a" and
  .Config.Labels["local-inference.glm53.b12x-base"] == "30aafad96b7a78064651c4a5ac177791e7bdee30" and
  .Config.Labels["local-inference.glm53.exl3-scope"] == "glm53_routed_experts_only" and
  .Config.Labels["local-inference.glm53.flashinfer-nope-adapter"] == "zero-padded-physical-rope" and
  .Config.Labels["local-inference.vllm.package-version"] == "0.26.1rc0+infernal.invocation.cu133.r19.vllm174c789.b12x12c4263" and
  .Config.Labels["local-inference.exllamav3.commit"] == "704aefd743b390af4bd0fb429d1906f9b964c7d8" and
  .Config.Labels["local-inference.cuda.version"] == "13.3" and
  .Config.Labels["local-inference.torch.version"] == "2.13.0"
' <<<"$inspect" >/dev/null || {
  echo "error: image provenance/capability labels differ" >&2
  exit 1
}

docker run --rm -i --entrypoint /opt/venv/bin/python "$IMAGE" - <<'PY'
from types import SimpleNamespace as S
from vllm.model_executor.layers.quantization.exl3 import Exl3Config
from vllm.model_executor.models.registry import ModelRegistry
from vllm.v1.attention.backends.mla.b12x_mla_sparse import B12xMLASparseBackend
from vllm.v1.attention.backends.mla.flashinfer_mla_sparse import FlashInferMLASparseSM120Backend

quant = {
    "quant_method": "exl3",
    "scope": "glm53_routed_experts_only",
    "bits": 4,
    "codebook": "mcg",
    "non_routed_dtype_policy": "official_source_native",
}
config = Exl3Config.from_config(quant)
text = S(
    model_type="glm5_next_text",
    num_hidden_layers=45,
    first_k_dense_replace=3,
    n_routed_experts=288,
    hidden_size=4096,
    moe_intermediate_size=2048,
    mla_use_nope=True,
    qk_nope_head_dim=256,
    qk_rope_head_dim=0,
    v_head_dim=256,
    index_n_heads=32,
    index_head_dim=128,
    index_topk=2048,
    index_kpool=4,
    index_kpool_compress=True,
    index_kpool_always_select_tail=True,
    linear_attn_config={
        "num_heads": 64,
        "head_dim": 128,
        "short_conv_kernel_size": 4,
        "full_attn_layers": [3, 7, 11, 15, 19, 23, 27, 31, 35, 39, 43],
    },
)
config.maybe_update_config("/model", S(text_config=text))
assert config.rank_sliced_metadata["tp"] == 2
assert config.rank_sliced_layer_bitrates("model.layers.3.mlp.experts") == (4,) * 288
assert B12xMLASparseBackend.get_kv_cache_shape(1, 64, 1, 512, "nvfp4_ds_mla")[-1] in (288, 304)
assert FlashInferMLASparseSM120Backend.get_kv_cache_shape(1, 64, 1, 512, "fp8_ds_mla")[-1] == 656
assert "Glm5NextForConditionalGeneration" in ModelRegistry.get_supported_archs()
print("GLM-5.3 EXL3 K4 TP2 vLLM capability probe: PASS")
PY

install -d -m 700 "$(dirname "$IDENTITY_FILE")"
umask 077
cat >"$IDENTITY_FILE" <<EOF_IDENTITY
image=$IMAGE
image_id=$EXPECTED_ID
platform=linux/amd64
vllm_base=eb290e8162692b8dc5f4af7e5360f5794f983add
vllm_overlay=df684ff47dcbf088b41311494fd20347a702e56a
b12x_base=30aafad96b7a78064651c4a5ac177791e7bdee30
exllamav3=704aefd743b390af4bd0fb429d1906f9b964c7d8
EOF_IDENTITY
chmod 600 "$IDENTITY_FILE"
printf 'Verified %s; identity: %s\n' "$IMAGE" "$IDENTITY_FILE"
printf '%s\n' 'WARNING: source labels are pinned but the GLM overlay commits are not publicly reconstructible; runtime qualification remains mandatory.'
