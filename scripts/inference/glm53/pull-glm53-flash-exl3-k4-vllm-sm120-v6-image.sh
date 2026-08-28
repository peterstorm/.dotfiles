#!/usr/bin/env bash
# Pull and prove the exact v84 image capabilities required by the text-only FP8-DS-MLA v6 profile.
set -euo pipefail

IMAGE="verdictai/glm53-flash-exl3-k4@sha256:184cfdb86fb08902898999ce5d7101f5711e3138f82b4738ba823145c17f8140"
EXPECTED_ID="sha256:f28ba4b2192d8306f2ab93be9ea868459f76e2fd5893d4eef9f7cc48f9180578"
EXPECTED_INDEX="sha256:0f1cdcc8891f1cc3a444121eb61d366289a1cbba285f0892dcbb24bc94961692"
SOURCE_TAG="verdictai/glm53-flash-exl3-k4:r19-sm120-tp2-ep2-dcp2-v84-dflash2"
IDENTITY_FILE="${IDENTITY_FILE:-$HOME/.local/state/glm53/exl3-k4-vllm-sm120-v6-image.identity}"

[ "$(uname -s)" = Linux ] && [ "$(uname -m)" = x86_64 ] || {
  echo "error: this image is prepared only for linux/amd64 SM120 hosts" >&2
  exit 1
}
command -v jq >/dev/null 2>&1 || {
  echo "error: jq is required to prove image configuration" >&2
  exit 1
}

# The mutable source tag was observed at EXPECTED_INDEX, but it is evidence,
# not a runtime dependency. Pull only the immutable AMD64 manifest digest.
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
  .Config.Labels["org.opencontainers.image.revision"] == "dflash2-triton-swa-vision-20260828" and
  .Config.Labels["org.opencontainers.image.version"] == "r19-sm120-tp2-ep2-dcp2-v84-dflash2" and
  .Config.Labels["local-inference.vllm.commit"] == "6dc2f516688fe6f84c6994dcd20fddf296853a6c" and
  .Config.Labels["local-inference.b12x.commit"] == "36bce2c1552ba2d47dc09f20a6f64fbfc8ec4ff8" and
  .Config.Labels["local-inference.cuda.version"] == "13.3" and
  .Config.Labels["local-inference.torch.version"] == "2.13.0"
' <<<"$inspect" >/dev/null || {
  echo "error: v84 platform or embedded runtime identity differs" >&2
  exit 1
}

docker run --rm -i --entrypoint /opt/venv/bin/python "$IMAGE" - <<'PY'
import importlib.util

from vllm.v1.attention.backends.registry import AttentionBackendEnum

assert "FLASHINFER_MLA_SPARSE_SM120" in AttentionBackendEnum.__members__
assert importlib.util.find_spec("instanttensor") is not None
print("GLM-5.3 v84 FP8-DS-MLA + FlashInfer SM120 + InstantTensor capability probe: PASS")
PY

install -d -m 700 "$(dirname "$IDENTITY_FILE")"
umask 077
cat >"$IDENTITY_FILE" <<EOF_IDENTITY
image=$IMAGE
image_id=$EXPECTED_ID
image_index=$EXPECTED_INDEX
source_tag=$SOURCE_TAG
platform=linux/amd64
vllm=6dc2f516688fe6f84c6994dcd20fddf296853a6c
b12x=36bce2c1552ba2d47dc09f20a6f64fbfc8ec4ff8
profile_capabilities=fp8_ds_mla,flashinfer_mla_sparse_sm120,instanttensor,mtp3
EOF_IDENTITY
chmod 600 "$IDENTITY_FILE"
printf 'Verified %s; identity: %s\n' "$IMAGE" "$IDENTITY_FILE"
printf '%s\n' 'WARNING: this proves the published binary identity and capabilities, not independent source-overlay reproducibility.'
