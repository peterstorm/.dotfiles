#!/usr/bin/env bash
# Pull and prove the exact v84 multimodal FP8-DS-MLA/FlashInfer image capabilities required by v8.
set -euo pipefail

IMAGE="verdictai/glm53-flash-exl3-k4@sha256:184cfdb86fb08902898999ce5d7101f5711e3138f82b4738ba823145c17f8140"
EXPECTED_ID="sha256:f28ba4b2192d8306f2ab93be9ea868459f76e2fd5893d4eef9f7cc48f9180578"
IDENTITY_FILE="${IDENTITY_FILE:-$HOME/.local/state/glm53/exl3-k4-vllm-sm120-v8-image.identity}"
PUBLICATION_REV="bd5321c1cfd4b8d352ef380e3158c64886039d03"
MODEL_REV="5ab363a8dcf6405955fd5f99671e01a1c9fb124b"

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
  echo "error: v84 image config differs: expected $EXPECTED_ID, found $actual_id" >&2
  exit 1
}
inspect="$(docker image inspect "$IMAGE")"
jq -e '.[0] |
  .Architecture == "amd64" and
  .Os == "linux" and
  (.RootFS.Layers | length) == 113 and
  .Config.Entrypoint == ["/opt/venv/bin/vllm"] and
  .Config.Labels["org.opencontainers.image.title"] == "GLM-5.3-Flash EXL3 K4 SM120 DFlash2" and
  .Config.Labels["org.opencontainers.image.source"] == "https://github.com/brandonmmusic-max/glm-5.3-flash-exl3-4bpw" and
  .Config.Labels["org.opencontainers.image.revision"] == "dflash2-triton-swa-vision-20260828" and
  .Config.Labels["org.opencontainers.image.version"] == "r19-sm120-tp2-ep2-dcp2-v84-dflash2" and
  .Config.Labels["local-inference.glm53.runtime-profile"] == "tp2-ep2-dcp2-exl3-k4-nvfp4-mla-kv-dflash2-7-vision" and
  .Config.Labels["local-inference.glm53.vision"] == "validated-runtime-path" and
  .Config.Labels["local-inference.glm53.vision-rope-packaging-fix"] == "native-pytorch-fallback-when-vllm-flash-attn-layers-absent" and
  .Config.Labels["local-inference.glm53.dflash2-checkpoint"] == "incoai/GLM-5.3-Flash-DFlash2@7d74cdd881ed7e32c31175984a67823127b66cfe" and
  .Config.Labels["local-inference.glm53.dflash2-triton-swa"] == "noncausal-full-draft-block-backward-window" and
  .Config.Labels["local-inference.glm53.dflash2-acceptance"] == "gsm8k-first16-max-mean-5.738763" and
  .Config.Labels["local-inference.vllm.commit"] == "6dc2f516688fe6f84c6994dcd20fddf296853a6c" and
  .Config.Labels["local-inference.b12x.commit"] == "36bce2c1552ba2d47dc09f20a6f64fbfc8ec4ff8" and
  .Config.Labels["io.github.brandonmmusic-max.glm53.provenance-fingerprint"] == "sha256:cf4b00958987cc50f94641592b1a8d74874adb4d671861ce12dd5e8f2907d907" and
  .Config.Labels["local-inference.cuda.version"] == "13.3" and
  .Config.Labels["local-inference.torch.version"] == "2.13.0"
' <<<"$inspect" >/dev/null || {
  echo "error: v84 platform, runtime, vision, DFlash2, or provenance labels differ" >&2
  exit 1
}

docker run --rm -i --entrypoint /opt/venv/bin/python "$IMAGE" - <<'PY'
import hashlib
import json
from pathlib import Path

import torch
from vllm.model_executor.layers.rotary_embedding.common import ApplyRotaryEmb
from vllm.model_executor.models.registry import ModelRegistry
from vllm.v1.attention.backends.registry import AttentionBackendEnum

root = Path("/opt/infernal-invocation/vllm/vllm")
paths = {
    "rotary_embedding_common.py": root / "model_executor/layers/rotary_embedding/common.py",
    "multimodal_chat_template.jinja": Path("/opt/glm53/chat_template.multimodal.jinja"),
}
provenance_path = Path("/opt/glm53/PROVENANCE.json")
assert hashlib.sha256(provenance_path.read_bytes()).hexdigest() == "cf4b00958987cc50f94641592b1a8d74874adb4d671861ce12dd5e8f2907d907"
provenance = json.loads(provenance_path.read_text())
assert provenance["schema"] == "brandonmusic.glm53.runtime-provenance.v1"
assert provenance["release"] == "r19-sm120-tp2-ep2-dcp2-v84-dflash2"
for name, path in paths.items():
    assert hashlib.sha256(path.read_bytes()).hexdigest() == provenance["source_sha256"][name]
assert provenance["source_sha256"]["multimodal_chat_template.jinja"] == "34d5ee66b12fa6446cdae131c352b8f68cd85369e0e6fda115583805fada3891"
template = paths["multimodal_chat_template.jinja"].read_text()
assert "<|begin_of_image|><|image|><|end_of_image|>" in template
assert "<|begin_of_video|><|video|><|end_of_video|>" in template
supported = ModelRegistry.get_supported_archs()
assert "Glm5NextForConditionalGeneration" in supported
assert "TORCH_SDPA" in AttentionBackendEnum.__members__
assert "FLASHINFER_MLA_SPARSE_SM120" in AttentionBackendEnum.__members__
rotary = ApplyRotaryEmb.__new__(ApplyRotaryEmb)
object.__setattr__(rotary, "is_neox_style", True)
object.__setattr__(rotary, "enable_fp32_compute", False)
object.__setattr__(rotary, "apply_rotary_emb_vllm_flash_attn", None)
x = torch.randn(2, 5, 3, 8)
cos = torch.randn(5, 4)
sin = torch.randn(5, 4)
torch.testing.assert_close(rotary.forward_cuda(x, cos, sin), rotary.forward_native(x, cos, sin))
print("GLM-5.3 v84 multimodal + FP8 DS MLA + FlashInfer SM120 + MTP3 capability probe: PASS")
PY

install -d -m 700 "$(dirname "$IDENTITY_FILE")"
umask 077
cat >"$IDENTITY_FILE" <<EOF_IDENTITY
image=$IMAGE
image_id=$EXPECTED_ID
image_index=sha256:0f1cdcc8891f1cc3a444121eb61d366289a1cbba285f0892dcbb24bc94961692
platform=linux/amd64
publication_revision=$PUBLICATION_REV
model_revision=$MODEL_REV
dflash2_revision=7d74cdd881ed7e32c31175984a67823127b66cfe
multimodal_template_sha256=34d5ee66b12fa6446cdae131c352b8f68cd85369e0e6fda115583805fada3891
runtime_provenance_sha256=cf4b00958987cc50f94641592b1a8d74874adb4d671861ce12dd5e8f2907d907
vllm=6dc2f516688fe6f84c6994dcd20fddf296853a6c
b12x=36bce2c1552ba2d47dc09f20a6f64fbfc8ec4ff8
source_tag=verdictai/glm53-flash-exl3-k4:r19-sm120-tp2-ep2-dcp2-v84-language-only
profile_capabilities=multimodal,fp8_ds_mla,flashinfer_mla_sparse_sm120,prefix_cache,mtp3
EOF_IDENTITY
chmod 600 "$IDENTITY_FILE"
printf 'Verified %s; identity: %s\n' "$IMAGE" "$IDENTITY_FILE"
printf '%s\n' 'WARNING: exact source hashes are embedded, but the complete custom overlay remains unavailable as a reconstructible public build.'
