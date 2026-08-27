#!/usr/bin/env bash
# Pull and prove the immutable vLLM SM120 overlay used by the GLM-5.3 v2 profile.
set -euo pipefail

BASE_IMAGE="vllm/vllm-openai:glm53-flash@sha256:2c6da6c6f16ed15c91e412d896dba13701f25fe1861eaec9ddaa4db34d1d21c4"
BASE_CONFIG="sha256:75870ba0b54f80886bd8f9eb3db6497875a82c0a511a83f81382ce9a82af7de8"
IMAGE="cstechdev/vllm:glm53-flash-nope-sm120-cu130-20260826-r1@sha256:0bd709e80b8ff13ae5de8f7d7f708a499fade3a26970d56afb1be2ff3860fde5"
IMAGE_CONFIG="sha256:136b60b807401679fb529b5fc99ce86c8ec291b38ef01c75801c76696e995be3"
OVERLAY_SOURCE="https://github.com/chriswritescode-dev/glm-5.3-flash-sm120"
OVERLAY_COMMIT="dc6b4fdd68005ab6ee0b1decfa4ebb8384393d37"
OVERLAY_TREE="b376906774010561e22fa8e234937764f83fd221"

[ "$(uname -m)" = x86_64 ] || {
  echo "error: this profile is prepared only for linux/amd64 SM120 hosts" >&2
  exit 1
}

docker pull "$BASE_IMAGE"
docker pull "$IMAGE"
[ "$(docker image inspect "$BASE_IMAGE" --format '{{.Id}}')" = "$BASE_CONFIG" ] || {
  echo "error: official base image config does not match $BASE_CONFIG" >&2
  exit 1
}
[ "$(docker image inspect "$IMAGE" --format '{{.Id}}')" = "$IMAGE_CONFIG" ] || {
  echo "error: SM120 overlay image config does not match $IMAGE_CONFIG" >&2
  exit 1
}
repo_digests="$(docker image inspect "$IMAGE" --format '{{join .RepoDigests "\n"}}')"
grep -Fxq 'cstechdev/vllm@sha256:0bd709e80b8ff13ae5de8f7d7f708a499fade3a26970d56afb1be2ff3860fde5' \
  <<<"$repo_digests" || {
  echo "error: overlay image does not expose its pinned repository digest" >&2
  exit 1
}

# Supply-chain shape: the published overlay must be the exact official base rootfs
# plus two layers, never a replacement filesystem.
mapfile -t base_layers < <(docker image inspect "$BASE_IMAGE" --format '{{range .RootFS.Layers}}{{println .}}{{end}}')
mapfile -t overlay_layers < <(docker image inspect "$IMAGE" --format '{{range .RootFS.Layers}}{{println .}}{{end}}')
[ "${#overlay_layers[@]}" -eq "$((${#base_layers[@]} + 2))" ] || {
  echo "error: SM120 artifact is not the expected two-layer overlay" >&2
  exit 1
}
for index in "${!base_layers[@]}"; do
  [ "${overlay_layers[$index]}" = "${base_layers[$index]}" ] || {
    echo "error: SM120 artifact does not extend the pinned official base at layer $index" >&2
    exit 1
  }
done

# Static capability/provenance probe; no GPU or model is started.
docker run --rm -i --entrypoint python3 "$IMAGE" - <<'PY'
import inspect
from pathlib import Path

from vllm.model_executor.layers.quantization import get_quantization_config
from vllm.model_executor.models.registry import ModelRegistry
from vllm.v1.attention.backends.mla.flashinfer_mla_sparse_sm120 import (
    FlashInferMLASparseSM120Impl,
)

supported = ModelRegistry.get_supported_archs()
assert "Glm5NextForConditionalGeneration" in supported
assert "Glm5NextMTPModel" in supported
assert get_quantization_config("modelopt_mixed").get_name() == "modelopt_mixed"
assert FlashInferMLASparseSM120Impl.supports_dense_mha_prefill is False
assert "do_kv_cache_update" in FlashInferMLASparseSM120Impl.__dict__
init_source = inspect.getsource(FlashInferMLASparseSM120Impl.__init__)
forward_source = inspect.getsource(FlashInferMLASparseSM120Impl.forward_mqa)
assert "self.rope_pad = 64" in init_source
assert "return_valid_counts=True" in forward_source
assert "sparse_mla_top_k=sparse_topk_capacity" in forward_source
assert "seq_lens=topk_lengths" in forward_source
assert "attn_metadata.topk_tokens" not in forward_source

site = Path(__import__("vllm").__file__).parent
for relative in ("models/glm5next/nvidia/model.py", "models/glm5next/nvidia/mtp.py"):
    source = (site / relative).read_text()
    assert "buffer_width = topk_tokens\n" in source
    assert "kpool - 1 if kpool > 1" not in source
indexer = (site / "model_executor/layers/sparse_attn_indexer_kpool.py").read_text()
assert indexer.count("pool_ids[:, : select_k - 1]") == 2
cuda_platform = (site / "platforms/cuda.py").read_text()
assert "page_sizes = tuple(p for p in page_sizes if p == 64)" in cuda_platform
print("GLM-5.3 SM120 NoPE/2176/page-alignment capability probe: PASS")
PY

printf 'Verified %s\n' "$IMAGE"
printf 'official base: %s\noverlay source: %s @ %s (tree %s)\n' \
  "$BASE_IMAGE" "$OVERLAY_SOURCE" "$OVERLAY_COMMIT" "$OVERLAY_TREE"
printf '%s\n' 'Artifact provenance and static capability pass; TP2 runtime qualification remains mandatory.'
