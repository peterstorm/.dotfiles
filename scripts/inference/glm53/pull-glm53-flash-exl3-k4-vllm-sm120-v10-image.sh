#!/usr/bin/env bash
# Build and prove the GLM-5.3 v10 DCP2 recurrent-geometry overlay.
set -euo pipefail

BASE_IMAGE="peterstorm/vllm:glm53-v9-fast-safe"
BASE_ID="sha256:82ea6cb3874e4869d43993146bf52b2522f010c1206c7a5f7bd3ec04bc2bcdf2"
DERIVED_TAG="peterstorm/vllm:glm53-v10-dcp2-safe"
DERIVED_ID="sha256:ef5f2fcb25d16abdcd800ff70b158e077780f2cb550a0ebf5bd1fe12e9f44553"
DCP_GEOMETRY_PATCH_SHA256="7ebef333c9ef4f363136fb0f78a622edbf886e0b62bd2e87fba11b17164c705a"
MTP_POSITION_ZERO_PATCH_SHA256="0e723d2978ac6d42ce7963727638a80c984a6111cfbe304d507444005362d253"
B12X_ADAPTER_PATCH_SHA256="60bf08b17169dfe65105460790b371035b0109098dce69107edc868b3e70b4e4"
GLM_NEXT_FP8_SPEC_PATCH_SHA256="c2f4e4724da7c3f3306030a3ac1406a8d3e304301de92a753df4d56d574f3fbc"
HYBRID_PAGE_PADDING_PATCH_SHA256="c6098ffef5b662dd91820f14485642e8cb94662544e2f18a877ebfc5d6d0eec5"
B12X_PADDED_PAGE_PATCH_SHA256="fc6ae25924cca96c652044abd52166970e9f8057264daa6625e0ff1aa8ab84b8"
B12X_SOURCE_SHA256="4a9eafc91967d6e88169522c0db6e234025cc372e205ffa0f354d74e210dba57"
COMPILED_EXTENSION_SHA256="b144bf4e1f0d2455e016191de4bca50bc72cdf517593b374940f9cb2fc68e415"
SOURCE_DATE_EPOCH=1788134400
IDENTITY_FILE="${IDENTITY_FILE:-$HOME/.local/state/glm53/exl3-k4-vllm-sm120-v10-image.identity}"
PUBLICATION_REV="bd5321c1cfd4b8d352ef380e3158c64886039d03"
MODEL_REV="5ab363a8dcf6405955fd5f99671e01a1c9fb124b"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OVERLAY_DIR="$SCRIPT_DIR/glm53-v10-dcp2-safe"
DCP_GEOMETRY_PATCH="$OVERLAY_DIR/glm53-v10-dcp2-mamba-geometry.patch"
MTP_POSITION_ZERO_PATCH="$OVERLAY_DIR/glm53-v10-mtp-position-zero.patch"
B12X_ADAPTER_PATCH="$OVERLAY_DIR/glm53-v10-b12x-glm-next-fp8.patch"
GLM_NEXT_FP8_SPEC_PATCH="$OVERLAY_DIR/glm53-v10-glm-next-fp8-spec.patch"
HYBRID_PAGE_PADDING_PATCH="$OVERLAY_DIR/glm53-v10-hybrid-page-padding.patch"
B12X_PADDED_PAGE_PATCH="$OVERLAY_DIR/glm53-v10-b12x-padded-page.patch"
B12X_SOURCE="$OVERLAY_DIR/b12x-903667d36aee19320776019a31dd06d1e9255b6a.tar.gz"
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
  "$DCP_GEOMETRY_PATCH_SHA256:$DCP_GEOMETRY_PATCH" \
  "$MTP_POSITION_ZERO_PATCH_SHA256:$MTP_POSITION_ZERO_PATCH" \
  "$B12X_ADAPTER_PATCH_SHA256:$B12X_ADAPTER_PATCH" \
  "$GLM_NEXT_FP8_SPEC_PATCH_SHA256:$GLM_NEXT_FP8_SPEC_PATCH" \
  "$HYBRID_PAGE_PADDING_PATCH_SHA256:$HYBRID_PAGE_PADDING_PATCH" \
  "$B12X_PADDED_PAGE_PATCH_SHA256:$B12X_PADDED_PAGE_PATCH" \
  "$B12X_SOURCE_SHA256:$B12X_SOURCE"; do
  expected="${record%%:*}"
  file="${record#*:}"
  actual="$(sha256sum "$file" | cut -d' ' -f1)"
  [ "$actual" = "$expected" ] || {
    echo "error: vendored patch identity differs: $file" >&2
    exit 1
  }
done

if ! actual_base_id="$(docker image inspect "$BASE_IMAGE" --format '{{.Id}}' 2>/dev/null)"; then
  echo "error: pinned v9 parent image is absent; build and prove v9 first" >&2
  exit 1
fi
[ "$actual_base_id" = "$BASE_ID" ] || {
  echo "error: v9 parent config differs: expected $BASE_ID, found $actual_base_id" >&2
  exit 1
}
base_inspect="$(docker image inspect "$BASE_ID")"
jq -e '.[0] |
  .Architecture == "amd64" and
  .Os == "linux" and
  (.RootFS.Layers | length) == 115 and
  .Config.Entrypoint == ["/opt/venv/bin/vllm"] and
  .Config.Labels["ai.peterstorm.inference.overlay"] == "glm53-v9-fast-safe" and
  .Config.Labels["ai.peterstorm.inference.persistent-topk"] == "vllm-project/vllm#52149@b8f88c1a29f54dcc42f1b163db523bf362e845e3" and
  .Config.Labels["ai.peterstorm.inference.mamba-overlap"] == "vllm-project/vllm#50729@a02cfccbc6187344325e364f09f6d8c33c4b253b"
' <<<"$base_inspect" >/dev/null || {
  echo "error: v9 parent platform, provenance, or layer count differs" >&2
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
  echo "error: GLM v10 image differs: expected $DERIVED_ID, found $actual_derived_id" >&2
  echo "Rebuild deliberately, qualify it, then update every image pin together." >&2
  exit 1
}
derived_inspect="$(docker image inspect "$DERIVED_ID")"
jq -e --arg base "$BASE_ID" '.[0] |
  .Architecture == "amd64" and
  .Os == "linux" and
  (.RootFS.Layers | length) == 117 and
  .Config.Entrypoint == ["/opt/venv/bin/vllm"] and
  .Config.Labels["ai.peterstorm.inference.base-image"] == $base and
  .Config.Labels["ai.peterstorm.inference.overlay"] == "glm53-v10-dcp2-safe" and
  .Config.Labels["ai.peterstorm.inference.dcp"] == "tp2-ep2-dcp2" and
  .Config.Labels["ai.peterstorm.inference.dcp-attention"] == "b12x-mla-sparse" and
  .Config.Labels["ai.peterstorm.inference.dcp-transport"] == "ag-rs" and
  .Config.Labels["ai.peterstorm.inference.mamba-dcp-layout"] == "replicated-full-position-table" and
  .Config.Labels["ai.peterstorm.inference.block-table-overflow"] == "fail-closed" and
  .Config.Labels["ai.peterstorm.inference.mtp-position-zero"] == "local-inference-lab/vllm#539@4c1f7b2c37b75d4e8fefed337e82c3771dc5f8a7-adapted" and
  .Config.Labels["ai.peterstorm.inference.b12x-attention-commit"] == "903667d36aee19320776019a31dd06d1e9255b6a" and
  .Config.Labels["ai.peterstorm.inference.b12x-moe-lineage"] == "v9-byte-exact-36bce2c1552ba2d47dc09f20a6f64fbfc8ec4ff8" and
  .Config.Labels["ai.peterstorm.inference.glm-next-fp8-abi"] == "explicit-model-type-528-byte-record" and
  .Config.Labels["ai.peterstorm.inference.glm-next-fp8-spec"] == "logical-528-physical-656-hybrid-page" and
  .Config.Labels["ai.peterstorm.inference.hybrid-page-padding"] == "validated-widening" and
  .Config.Labels["ai.peterstorm.inference.b12x-padded-page"] == "packed-stride-writer-precompile" and
  .Config.Labels["ai.peterstorm.inference.graph-shapes"] == "mtp3-c1-c4-dense"
' <<<"$derived_inspect" >/dev/null || {
  echo "error: GLM v10 platform, labels, or layer count differs" >&2
  exit 1
}
mapfile -t base_layers < <(jq -r '.[0].RootFS.Layers[]' <<<"$base_inspect")
mapfile -t derived_layers < <(jq -r '.[0].RootFS.Layers[]' <<<"$derived_inspect")
for index in "${!base_layers[@]}"; do
  [ "${derived_layers[$index]}" = "${base_layers[$index]}" ] || {
    echo "error: GLM v10 does not retain the exact v9 rootfs prefix at layer $index" >&2
    exit 1
  }
done

# Run only after the serving profile is stopped; this probe needs free GPU memory.
docker run --rm -i --gpus all --ipc=host --shm-size 16g \
  --entrypoint /opt/venv/bin/python "$DERIVED_ID" /dev/stdin <"$VERIFY"

install -d -m 700 "$(dirname "$IDENTITY_FILE")"
umask 077
cat >"$IDENTITY_FILE" <<EOF_IDENTITY
base_image=$BASE_IMAGE
base_image_id=$BASE_ID
derived_image=$DERIVED_TAG
derived_image_id=$DERIVED_ID
platform=linux/amd64
publication_revision=$PUBLICATION_REV
model_revision=$MODEL_REV
vllm=6dc2f516688fe6f84c6994dcd20fddf296853a6c
dcp_geometry_pr=vllm-project/vllm#50287@3a91629d06826edb624323694c211831234a64a6
dcp_geometry_adaptation=global-MambaSpec-replication-plus-fail-closed-staged-writes
dcp_geometry_patch_sha256=$DCP_GEOMETRY_PATCH_SHA256
mtp_position_zero_pr=local-inference-lab/vllm#539@4c1f7b2c37b75d4e8fefed337e82c3771dc5f8a7
mtp_position_zero_adaptation=preserve-live-position-zero-embedding-in-fused-glm-eh-norm
mtp_position_zero_patch_sha256=$MTP_POSITION_ZERO_PATCH_SHA256
b12x_attention_commit=903667d36aee19320776019a31dd06d1e9255b6a
b12x_moe_lineage=v9-byte-exact-36bce2c1552ba2d47dc09f20a6f64fbfc8ec4ff8
b12x_source_sha256=$B12X_SOURCE_SHA256
b12x_adapter_patch_sha256=$B12X_ADAPTER_PATCH_SHA256
glm_next_fp8_spec_patch_sha256=$GLM_NEXT_FP8_SPEC_PATCH_SHA256
hybrid_page_padding_patch_sha256=$HYBRID_PAGE_PADDING_PATCH_SHA256
b12x_padded_page_patch_sha256=$B12X_PADDED_PAGE_PATCH_SHA256
glm_next_fp8_abi=logical-528-byte-record-physical-656-byte-hybrid-page
compiled_extension_sha256=$COMPILED_EXTENSION_SHA256
profile_capabilities=multimodal,fp8_ds_mla,b12x_mla_sparse,b12x_glm_next_528,tp2_ep2_dcp2,ag_rs,prefix_cache,mtp3,mtp_position_zero_preserved,dense_mtp3_graph_shapes,replicated_mamba_table,fail_closed_block_writes,state_bounds,mamba_memmove,slot_bounds,persistent_kpool_mapping,overflow_exact_sparse_topk
EOF_IDENTITY
chmod 600 "$IDENTITY_FILE"
printf 'Verified GLM v10 %s; identity: %s\n' "$DERIVED_ID" "$IDENTITY_FILE"
