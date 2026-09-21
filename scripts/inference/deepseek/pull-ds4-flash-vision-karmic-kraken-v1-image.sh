#!/usr/bin/env bash
# Pull and prove the DeepSeek V4 Flash Vision Karmic Kraken v1 image: the
# upstream *versioned* Karmic Kraken beta release
# (ghcr.io/local-inference-lab/vllm:karmic-kraken-beta-20260920-443d9f815c57d23b)
# with the ds4-vision deployment profile (PROFILE=ds4-vision).
#
# Upstream qualification sources:
#   - models/deepseek-v4-flash-vision.md  (deployment contract, ds4-vision profile)
#   - benchmarks/karmic-kraken-serving.md (six-mode table; Vision arm = DSpark K3,
#     TP2, batch 4096, 4 slots, 1,048,576 context, top-p 1 override)
# The six-mode throughput table was measured on a local source-composition image
# that is NOT published; this release set pins the published image instead, whose
# digest the benchmark doc records (sha256:55e477ad...) and whose equivalence is
# documented there (481/481 B12X Python files identical; vLLM ASTs equal except
# version metadata + one reviewed MoE docstring).
#
# What this script owns (mirrors the v14 pull pattern):
#   - digest pinning: the versioned tag must resolve to the doc-recorded
#     registry digest and to the recorded image id; a mismatch fails closed
#     (with a by-digest fallback that additionally requires the tag id and
#     digest id to be the same image);
#   - a CPU-only `--print-config` base proof (no GPU, no model load, no cache
#     services) that the pinned image's stock ds4-vision profile IS the contract:
#     DeepSeek-V4-Flash-Vision-Exp, TP2/DCP1, DSpark K3, four slots, 4096-token
#     budget, gpu-memory-utilization 0.975, fp8 KV, block 256, instanttensor
#     load, revision 6821d6ad... (profile-derived), GPU-only cache;
#   - a second --print-config pass carrying the exact Karmic Kraken benchmark
#     arm environment + native sampling override, proving every repository
#     override lands (launcher precedence: native arg > environment > preset);
#   - an identity receipt recording image id, repo digest, pull ref, proof
#     digests and the upstream doc URLs.
set -euo pipefail

TAG="ghcr.io/local-inference-lab/vllm:karmic-kraken-beta-20260920-443d9f815c57d23b"
DOC_DIGEST="sha256:55e477ad62ae15a77c9b869e8fb8e2d958f6edcc4d95e306adfa89dee9ed19df"
# The content identity this release set was written against; the registry
# digest assertion already implies it, and both are recorded.
EXPECTED_IMAGE_ID="sha256:83f00757ff18f3c3c12de291319b1a3a5496056a3873834d0994160828a3c6ee"
PROFILE="ds4-vision"
HARDWARE_PROFILE="rtx-pro-6000-pcie"
CHECKPOINT="deepseek-ai/DeepSeek-V4-Flash-Vision-Exp"
MODEL_REVISION="6821d6ad3681a4b137b066b76094fa82ebd0a380"
SERVED_MODEL_PRESET="DeepSeek-V4-Flash-Vision-Exp"
SERVED_MODEL_REPO="deepseek-v4-flash-vision"
UPSTREAM_MODEL_DOC="https://github.com/local-inference-lab/rtx6kpro/blob/master/models/deepseek-v4-flash-vision.md"
UPSTREAM_BENCH_DOC="https://github.com/local-inference-lab/rtx6kpro/blob/master/benchmarks/karmic-kraken-serving.md"
IDENTITY_FILE="${IDENTITY_FILE:-$HOME/.local/state/ds4-vision/karmic-kraken-v1-image.identity}"
WORKDIR="${TMPDIR:-/tmp}/ds4v-karmic-kraken-v1-pull.$$"

[ "$(uname -s)" = Linux ] && [ "$(uname -m)" = x86_64 ] || {
  echo "error: this image is prepared only for linux/amd64 SM120 hosts" >&2
  exit 1
}
for command in docker jq; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "error: $command is required to pull and prove the image" >&2
    exit 1
  }
done

docker pull "$TAG" >/dev/null
derived_id="$(docker image inspect "$TAG" --format '{{.Id}}')"
[[ "$derived_id" =~ ^sha256:[0-9a-f]{64}$ ]] || {
  echo "error: pulled image id is not a content address: $derived_id" >&2
  exit 1
}
if [[ "$derived_id" != "$EXPECTED_IMAGE_ID" ]]; then
  echo "error: $TAG resolved to $derived_id, not the recorded $EXPECTED_IMAGE_ID;" >&2
  echo "       upstream republished the versioned tag - re-qualify before serving" >&2
  exit 1
fi
repo_digests="$(docker image inspect "$TAG" --format '{{json .RepoDigests}}')"
if ! jq -e --arg digest "$DOC_DIGEST" 'map(select(. == $digest)) | length == 1' <<<"$repo_digests" >/dev/null; then
  echo "error: tag repo digests $repo_digests do not contain the documented $DOC_DIGEST" >&2
  echo "       falling back to a by-digest pull and requiring identical image ids" >&2
  docker pull "ghcr.io/local-inference-lab/vllm@$DOC_DIGEST" >/dev/null
  digest_id="$(docker image inspect "ghcr.io/local-inference-lab/vllm@$DOC_DIGEST" --format '{{.Id}}')"
  [[ "$digest_id" == "$derived_id" ]] || {
    echo "error: digest $DOC_DIGEST resolves to $digest_id, tag resolves to $derived_id" >&2
    exit 1
  }
fi

# Base profile proof: the pinned image's stock PROFILE=ds4-vision launch plan
# must be byte-stable on the documented deployment contract.
mkdir -p "$WORKDIR"
base_proof="$WORKDIR/base-proof.json"
docker run --rm --runtime runc --network none \
  -e PROFILE="$PROFILE" -e HARDWARE_PROFILE="$HARDWARE_PROFILE" \
  "$derived_id" --print-config >"$base_proof" 2>"$WORKDIR/base-proof.err" || {
  echo "error: --print-config failed for the stock ds4-vision profile" >&2
  cat "$WORKDIR/base-proof.err" >&2 || true
  rm -rf "$WORKDIR"
  exit 1
}
jq -e . "$base_proof" >/dev/null || {
  echo "error: --print-config output is not valid JSON" >&2
  rm -rf "$WORKDIR"
  exit 1
}
proof_assert() {
  local description="$1" filter="$2"
  if ! jq -e "$filter" "$base_proof" >/dev/null 2>&1; then
    echo "error: stock profile proof failed: $description" >&2
    rm -rf "$WORKDIR"
    exit 1
  fi
  printf 'PASS: %s\n' "$description"
}
proof_assert 'profile is ds4-vision' '.profile == "ds4-vision"'
proof_assert 'hardware profile is rtx-pro-6000-pcie' '.hardware == "rtx-pro-6000-pcie"'
proof_assert "checkpoint is $CHECKPOINT" '.settings.model.value == "deepseek-ai/DeepSeek-V4-Flash-Vision-Exp"'
proof_assert "profile served model name is $SERVED_MODEL_PRESET" \
  '.settings["served-model-name"].value == "DeepSeek-V4-Flash-Vision-Exp" and .settings["served-model-name"].source == "model:ds4-vision"'
proof_assert "checkpoint revision is pinned to $MODEL_REVISION" \
  --arg rev "$MODEL_REVISION" \
  '.settings.revision.value == $rev and .settings["code-revision"].value == $rev'
proof_assert 'speculative draft follows the pinned revision' \
  --arg rev "$MODEL_REVISION" \
  '.settings["speculative-config"].value.revision == $rev and .settings["speculative-config"].value.method == "dspark"'
proof_assert 'tensor parallel is 2' '.settings["tensor-parallel-size"].value == 2'
proof_assert 'decode context parallel is 1' '.settings["decode-context-parallel-size"].value == 1'
proof_assert 'speculation mode is dspark' '.settings.mode.value == "dspark"'
proof_assert 'DSpark draft depth is 3' '.settings["draft-tokens"].value == 3'
proof_assert 'request slots are 4' '.settings["max-num-seqs"].value == 4'
proof_assert 'prefill budget is 4096' '.settings["max-num-batched-tokens"].value == 4096 and .settings["cache-object-tokens"].value == 4096'
proof_assert 'gpu memory utilization is 0.975' '.settings["gpu-memory-utilization"].value == 0.975'
proof_assert 'max model len is memory-resolved (-1)' '.settings["max-model-len"].value == -1'
proof_assert 'kv cache dtype is fp8' '.settings["kv-cache-dtype"].value == "fp8"'
proof_assert 'kv block size is 256' '.settings["block-size"].value == 256'
proof_assert 'load format is instanttensor' '.settings["load-format"].value == "instanttensor"'
proof_assert 'attention backend is B12X' '.settings["attention-backend"].value == "B12X"'
proof_assert 'moe backend is b12x' '.settings["moe-backend"].value == "b12x"'
proof_assert 'prefix caching is enabled' '.settings["enable-prefix-caching"].value == true'
proof_assert 'sampling default is temperature 1 / top-p 0.95' \
  '.settings["override-generation-config"].value.temperature == 1.0 and .settings["override-generation-config"].value.top_p == 0.95'
proof_assert 'thinking default is enabled at reasoning high' \
  '.settings["default-chat-template-kwargs"].value.thinking == true and .settings["default-chat-template-kwargs"].value.reasoning_effort == "high"'
proof_assert 'no cache service in the stock plan (GPU-only)' '.cache_service == null'

# Karmic Kraken benchmark-arm proof: the exact environment the upstream Vision
# arm set (benchmarks/karmic-kraken-serving.md samples JSON, kk.docker_argv)
# plus the native sampling override must resolve through the launcher with the
# expected precedence (native arg > environment alias > profile preset).
override_proof="$WORKDIR/override-proof.json"
docker run --rm --runtime runc --network none \
  -e PROFILE="$PROFILE" -e HARDWARE_PROFILE="$HARDWARE_PROFILE" \
  -e TP=2 -e DCP=1 -e PORT=8000 -e SERVED_MODEL_NAME="$SERVED_MODEL_REPO" \
  -e MODEL_REVISION="$MODEL_REVISION" \
  -e MAX_MODEL_LEN=1048576 -e MAX_NUM_SEQS=4 -e MAX_NUM_BATCHED_TOKENS=4096 \
  -e GPU_MEMORY_UTILIZATION=0.975 -e OMP_NUM_THREADS=2 \
  -e VLLM_USE_BREAKABLE_CUDAGRAPH=0 -e NCCL_SOCKET_IFNAME=lo -e GLOO_SOCKET_IFNAME=lo \
  -e CACHE_MODE=vram \
  "$derived_id" --print-config \
  --override-generation-config '{"temperature":1.0,"top_p":1.0}' \
  >"$override_proof" 2>"$WORKDIR/override-proof.err" || {
  echo "error: --print-config failed for the benchmark-arm override pass" >&2
  cat "$WORKDIR/override-proof.err" >&2 || true
  rm -rf "$WORKDIR"
  exit 1
}
override_assert() {
  local description="$1" filter="$2"
  shift 2
  if ! jq -e "$filter" "$@" "$override_proof" >/dev/null 2>&1; then
    echo "error: benchmark-arm override proof failed: $description" >&2
    rm -rf "$WORKDIR"
    exit 1
  fi
  printf 'PASS: %s\n' "$description"
}
override_assert 'served model id comes from the environment' \
  '.settings["served-model-name"].value == $model and .settings["served-model-name"].source == "environment:SERVED_MODEL_NAME"' \
  --arg model "$SERVED_MODEL_REPO"
override_assert 'revision comes from MODEL_REVISION (offline pin)' \
  '.settings.revision.value == $rev and .settings.revision.source == "environment:MODEL_REVISION"' \
  --arg rev "$MODEL_REVISION"
override_assert 'context cap is the benchmark 1,048,576' \
  '.settings["max-model-len"].value == 1048576 and .settings["max-model-len"].source == "environment:MAX_MODEL_LEN"'
override_assert 'slots come from MAX_NUM_SEQS=4' \
  '.settings["max-num-seqs"].value == 4 and .settings["max-num-seqs"].source == "environment:MAX_NUM_SEQS"'
override_assert 'prefill budget comes from MAX_NUM_BATCHED_TOKENS=4096' \
  '.settings["max-num-batched-tokens"].value == 4096 and .settings["max-num-batched-tokens"].source == "environment:MAX_NUM_BATCHED_TOKENS"'
override_assert 'gpu memory utilization comes from the environment' \
  '.settings["gpu-memory-utilization"].value == 0.975 and .settings["gpu-memory-utilization"].source == "environment:GPU_MEMORY_UTILIZATION"'
override_assert 'TP2/DCP1 come from the environment' \
  '.settings["tensor-parallel-size"].value == 2 and .settings["tensor-parallel-size"].source == "environment:TP" and .settings["decode-context-parallel-size"].value == 1 and .settings["decode-context-parallel-size"].source == "environment:DCP"'
override_assert 'native sampling override wins (temperature 1, top-p 1)' \
  '.settings["override-generation-config"].value.temperature == 1.0 and .settings["override-generation-config"].value.top_p == 1.0 and .settings["override-generation-config"].source == "cli"'
override_assert 'draft revision follows the pinned revision' \
  '.settings["speculative-config"].value.revision == $rev' \
  --arg rev "$MODEL_REVISION"
override_assert 'plan status is implemented' '.status == "implemented"'

base_proof_sha256="$(sha256sum "$base_proof" | cut -d' ' -f1)"
override_proof_sha256="$(sha256sum "$override_proof" | cut -d' ' -f1)"
image_size_bytes="$(docker image inspect "$derived_id" --format '{{.Size}}')"
install -d -m 700 "$(dirname "$IDENTITY_FILE")"
identity_tmp="$(mktemp "$(dirname "$IDENTITY_FILE")/.ds4v-kk-v1-identity.XXXXXX")"
{
  printf 'pull_ref=%s\n' "$TAG"
  printf 'doc_digest=%s\n' "$DOC_DIGEST"
  printf 'image_id=%s\n' "$derived_id"
  printf 'image_size_bytes=%s\n' "$image_size_bytes"
  printf 'profile=%s\n' "$PROFILE"
  printf 'hardware_profile=%s\n' "$HARDWARE_PROFILE"
  printf 'checkpoint=%s\n' "$CHECKPOINT"
  printf 'model_revision=%s\n' "$MODEL_REVISION"
  printf 'served_model_preset=%s\n' "$SERVED_MODEL_PRESET"
  printf 'served_model_repo=%s\n' "$SERVED_MODEL_REPO"
  printf 'base_proof_sha256=%s\n' "$base_proof_sha256"
  printf 'override_proof_sha256=%s\n' "$override_proof_sha256"
  printf 'upstream_model_doc=%s\n' "$UPSTREAM_MODEL_DOC"
  printf 'upstream_bench_doc=%s\n' "$UPSTREAM_BENCH_DOC"
} >"$identity_tmp"
chmod 600 "$identity_tmp"
mv -f "$identity_tmp" "$IDENTITY_FILE"
rm -rf "$WORKDIR"

printf 'DS4 Vision Karmic Kraken v1 image pinned: %s\n' "$derived_id"
printf 'repo digest: %s\n' "$DOC_DIGEST"
printf 'identity receipt: %s\n' "$IDENTITY_FILE"
printf 'Record this image id as IMAGE_CONFIG in run-ds4-flash-vision-karmic-kraken-v1.sh\n'
printf 'and download-ds4-flash-vision-karmic-kraken-v1-checkpoint.sh before serving;\n'
printf 'the scripts refuse to launch while the id is unrecorded or different.\n'
