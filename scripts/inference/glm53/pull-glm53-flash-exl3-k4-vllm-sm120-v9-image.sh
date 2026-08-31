#!/usr/bin/env bash
# Build and prove the GLM-5.3 v9 state-safe, graph-ready, fast exact-top-k image.
set -euo pipefail

BASE_INDEX="sha256:0f1cdcc8891f1cc3a444121eb61d366289a1cbba285f0892dcbb24bc94961692"
BASE_IMAGE="verdictai/glm53-flash-exl3-k4@sha256:184cfdb86fb08902898999ce5d7101f5711e3138f82b4738ba823145c17f8140"
BASE_ID="sha256:f28ba4b2192d8306f2ab93be9ea868459f76e2fd5893d4eef9f7cc48f9180578"
DERIVED_TAG="peterstorm/vllm:glm53-v9-fast-safe"
DERIVED_ID="sha256:82ea6cb3874e4869d43993146bf52b2522f010c1206c7a5f7bd3ec04bc2bcdf2"
STATE_BOUNDS_PATCH_SHA256="a8e288ec067fed7e2e38762ca71e6034982dc4d40dc02ceec5caa1dc319ace85"
STATE_GRAPH_PATCH_SHA256="4ecec3de89f52125fc5884e4924ed5fb326bb1d9e6a97fc04a005147e22ea528"
FAST_TOPK_PATCH_SHA256="8baae7bea9cb85cf72dfc86702187b0227ff585fcb81dbdc8b30747195c24395"
COMPILED_EXTENSION_SHA256="b144bf4e1f0d2455e016191de4bca50bc72cdf517593b374940f9cb2fc68e415"
SOURCE_DATE_EPOCH=1788134400
IDENTITY_FILE="${IDENTITY_FILE:-$HOME/.local/state/glm53/exl3-k4-vllm-sm120-v9-image.identity}"
PUBLICATION_REV="bd5321c1cfd4b8d352ef380e3158c64886039d03"
MODEL_REV="5ab363a8dcf6405955fd5f99671e01a1c9fb124b"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OVERLAY_DIR="$SCRIPT_DIR/glm53-v9-fast-safe"
STATE_BOUNDS_PATCH="$SCRIPT_DIR/glm53-mtp-prefix-safety/glm53-mtp-prefix-state-safety.patch"
STATE_GRAPH_PATCH="$OVERLAY_DIR/glm53-v9-state-graph-safety.patch"
FAST_TOPK_PATCH="$OVERLAY_DIR/glm53-v9-fast-persistent-topk.patch"
VERIFY="$OVERLAY_DIR/verify.py"

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
for record in \
  "$STATE_BOUNDS_PATCH_SHA256:$STATE_BOUNDS_PATCH" \
  "$STATE_GRAPH_PATCH_SHA256:$STATE_GRAPH_PATCH" \
  "$FAST_TOPK_PATCH_SHA256:$FAST_TOPK_PATCH"; do
  expected="${record%%:*}"
  file="${record#*:}"
  actual="$(sha256sum "$file" | cut -d' ' -f1)"
  [ "$actual" = "$expected" ] || {
    echo "error: vendored patch identity differs: $file" >&2
    exit 1
  }
done

# The mutable source tag is never trusted; the manifest and config identities are.
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
  .Config.Labels["local-inference.vllm.commit"] == "6dc2f516688fe6f84c6994dcd20fddf296853a6c" and
  .Config.Labels["local-inference.glm53.vision"] == "validated-runtime-path" and
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
    --progress=plain \
    --provenance=false \
    --build-arg "SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH" \
    --output "type=docker,name=$DERIVED_TAG,rewrite-timestamp=true" \
    -f "$OVERLAY_DIR/Dockerfile" \
    "$SCRIPT_DIR"
fi
actual_derived_id="$(docker image inspect "$DERIVED_TAG" --format '{{.Id}}')"
[ "$actual_derived_id" = "$DERIVED_ID" ] || {
  echo "error: GLM v9 image differs: expected $DERIVED_ID, found $actual_derived_id" >&2
  echo "Rebuild deliberately, qualify it, then update every image pin together." >&2
  exit 1
}
derived_inspect="$(docker image inspect "$DERIVED_ID")"
jq -e --arg base "$BASE_IMAGE" '.[0] |
  .Architecture == "amd64" and
  .Os == "linux" and
  (.RootFS.Layers | length) == 115 and
  .Config.Entrypoint == ["/opt/venv/bin/vllm"] and
  .Config.Labels["ai.peterstorm.inference.base-image"] == $base and
  .Config.Labels["ai.peterstorm.inference.overlay"] == "glm53-v9-fast-safe" and
  .Config.Labels["ai.peterstorm.inference.state-bounds"] == "vllm-project/vllm#50021@9a198c0f8452d0eb251509f02753853903d9f17f" and
  .Config.Labels["ai.peterstorm.inference.mamba-overlap"] == "vllm-project/vllm#50729@a02cfccbc6187344325e364f09f6d8c33c4b253b" and
  .Config.Labels["ai.peterstorm.inference.slot-bounds"] == "vllm-project/vllm#54296@191f82d710493c9a02077d976d8cf0403ab8c96a" and
  .Config.Labels["ai.peterstorm.inference.persistent-topk"] == "vllm-project/vllm#52149@b8f88c1a29f54dcc42f1b163db523bf362e845e3" and
  .Config.Labels["ai.peterstorm.inference.topk-ties"] == "exact-score-lower-token-index" and
  .Config.Labels["ai.peterstorm.inference.kpool-tail"] == "persistent-circular-slot-buffer"
' <<<"$derived_inspect" >/dev/null || {
  echo "error: GLM v9 platform, labels, or layer count differs" >&2
  exit 1
}
mapfile -t base_layers < <(jq -r '.[0].RootFS.Layers[]' <<<"$base_inspect")
mapfile -t derived_layers < <(jq -r '.[0].RootFS.Layers[]' <<<"$derived_inspect")
for index in "${!base_layers[@]}"; do
  [ "${derived_layers[$index]}" = "${base_layers[$index]}" ] || {
    echo "error: GLM v9 does not retain the exact base rootfs prefix at layer $index" >&2
    exit 1
  }
done

# The probe exercises the rebuilt operator, overflow paths, deterministic ties,
# overlap-safe Mamba copies, both narrow-row slot semantics, and KPool address stability.
docker run --rm -i --gpus all --ipc=host --shm-size 16g \
  --entrypoint /opt/venv/bin/python "$DERIVED_ID" /dev/stdin <"$VERIFY"

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
state_bounds_pr=vllm-project/vllm#50021@9a198c0f8452d0eb251509f02753853903d9f17f
mamba_overlap_merge=vllm-project/vllm#50729@a02cfccbc6187344325e364f09f6d8c33c4b253b
slot_bounds_pr=vllm-project/vllm#54296@191f82d710493c9a02077d976d8cf0403ab8c96a
persistent_topk_pr=vllm-project/vllm#52149@b8f88c1a29f54dcc42f1b163db523bf362e845e3
state_bounds_patch_sha256=$STATE_BOUNDS_PATCH_SHA256
state_graph_patch_sha256=$STATE_GRAPH_PATCH_SHA256
fast_topk_patch_sha256=$FAST_TOPK_PATCH_SHA256
compiled_extension_sha256=$COMPILED_EXTENSION_SHA256
profile_capabilities=multimodal,fp8_ds_mla,flashinfer_mla_sparse_sm120,prefix_cache,mtp3,state_bounds,mamba_memmove,slot_bounds,persistent_kpool_mapping,overflow_exact_sparse_topk,deterministic_boundary_ties,cudagraph_candidate
EOF_IDENTITY
chmod 600 "$IDENTITY_FILE"
printf 'Verified GLM v9 %s; identity: %s\n' "$DERIVED_ID" "$IDENTITY_FILE"
