#!/usr/bin/env bash
# Pull and prove the GLM-5.3 v15 image: the upstream Karmic Kraken beta build
# 20261015.2 (ghcr.io/local-inference-lab/vllm, digest-pinned) launched
# through lil-serve with the glm53-tp2 preset on the qad2 checkpoint
# (local-inference-lab/GLM-5.3-Flash-NVFP4-MXFP8-CSF-QAD).
#
# Like v14, v15 is a stock upstream deployment — no overlay, no derived image.
# Unlike v14 the pull is by digest, not by the moving karmic-kraken-beta tag:
# beta tags move, the digest cannot. What this script owns:
#   - the digest pull and the content-addressed image id that
#     run-glm53-flash-qad2-tp2-v15.sh refuses to replace;
#   - a CPU-only `--print-config` proof (no GPU, no model load, no cache
#     services) that the pinned image resolves the documented recipe with the
#     exact launcher argv the run script uses: qad2 checkpoint at revision
#     0a041763…, TP2/DCP2, MTP3, eight slots, 4096-token prefill, 7296 MiB/GPU
#     FP8 KV (7650410496 bytes), memory-resolved context, nvfp4_csf load, A4
#     expert prefill, glm47 tool parser, server-default effort high;
#   - a second pass proving the repository's per-profile model id overrides
#     the preset's served name (launcher precedence: cli > environment >
#     preset);
#   - an identity receipt recording the image id, the digest ref, the proof
#     output digest and the recipe facts.
set -euo pipefail

PULL_REF="ghcr.io/local-inference-lab/vllm:karmic-kraken-beta-20261015.2"
PULL_DIGEST="sha256:a7dc6c5f23310c0949e72fc1977fdcdaa5d8a4e1a9e7ee8f2482e6163b296178"
PRESET="glm53-tp2"
RECIPE="https://claude.ai/code/artifact/a7cd0b46-db88-4891-b132-99b39cb313c9"
SERVED_MODEL_REPO="glm-5.3-flash-qad2-tp2-v15"
CHECKPOINT="local-inference-lab/GLM-5.3-Flash-NVFP4-MXFP8-CSF-QAD"
MODEL_REVISION="0a0417631b4065d16e9639f327f44a0a4237a537"
KV_CACHE_BYTES="7650410496" # 7296 MiB per GPU
CHAT_TEMPLATE_KWARGS='{"reasoning_effort":"high","clear_thinking":false}'
IDENTITY_FILE="${IDENTITY_FILE:-$HOME/.local/state/glm53/flash-qad2-tp2-v15-image.identity}"
WORKDIR="${TMPDIR:-/tmp}/glm53-qad2-tp2-v15-pull.$$"

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

IMAGE_REF="$PULL_REF@$PULL_DIGEST"
docker pull "$IMAGE_REF" >/dev/null
derived_id="$(docker image inspect "$IMAGE_REF" --format '{{.Id}}')"
[[ "$derived_id" =~ ^sha256:[0-9a-f]{64}$ ]] || {
  echo "error: pulled image id is not a content address: $derived_id" >&2
  exit 1
}

mkdir -p "$WORKDIR"
trap 'rm -rf "$WORKDIR"' EXIT

# print_config <output> [extra docker args...]
# Runs the recipe's exact launcher argv with --print-config, CPU-only.
print_config() {
  local output="$1"
  shift
  docker run --rm --runtime runc --network none \
    -e PRESET="$PRESET" -e CACHE_MODE=vram \
    -e DEFAULT_CHAT_TEMPLATE_KWARGS="$CHAT_TEMPLATE_KWARGS" \
    "$@" \
    --entrypoint /usr/local/bin/lil-serve "$IMAGE_REF" \
    --profile glm53-flash --hardware rtx-pro-6000-pcie --preset "$PRESET" \
    --print-config -- --cache-mode vram \
    >"$output" 2>"$output.err" || {
    echo "error: --print-config failed" >&2
    cat "$output.err" >&2 || true
    exit 1
  }
  jq -e . "$output" >/dev/null || {
    echo "error: --print-config output is not valid JSON" >&2
    exit 1
  }
}

base_proof="$WORKDIR/base-proof.json"
print_config "$base_proof"
proof_assert() {
  local description="$1" filter="$2"
  if ! jq -e "$filter" "$base_proof" >/dev/null 2>&1; then
    echo "error: recipe proof failed: $description" >&2
    exit 1
  fi
  printf 'PASS: %s\n' "$description"
}
proof_assert 'profile is glm53-flash' '.profile == "glm53-flash"'
proof_assert 'hardware profile is rtx-pro-6000-pcie' '.hardware == "rtx-pro-6000-pcie"'
proof_assert "checkpoint is $CHECKPOINT" '.settings.model.value == "local-inference-lab/GLM-5.3-Flash-NVFP4-MXFP8-CSF-QAD"'
proof_assert "checkpoint revision is $MODEL_REVISION" '.settings.revision.value == "0a0417631b4065d16e9639f327f44a0a4237a537"'
proof_assert 'preset owns the served model name' '.settings["served-model-name"].source == "preset:glm53-tp2"'
proof_assert 'tensor parallel is 2' '.settings["tensor-parallel-size"].value == 2'
proof_assert 'decode context parallel is 2' '.settings["decode-context-parallel-size"].value == 2'
proof_assert 'speculation mode is mtp' '.settings.mode.value == "mtp"'
proof_assert 'mtp draft depth is 3' '.settings["draft-tokens"].value == 3'
proof_assert 'request slots are 8' '.settings["max-num-seqs"].value == 8'
proof_assert 'prefill budget is 4096' '.settings["max-num-batched-tokens"].value == 4096'
proof_assert "fixed KV allocation is $KV_CACHE_BYTES bytes (7296 MiB/GPU)" \
  '.settings["kv-cache-memory-bytes"].value == 7650410496'
proof_assert 'KV cache dtype is fp8' '.settings["kv-cache-dtype"].value == "fp8"'
proof_assert 'gpu memory utilization is 0.985' '.settings["gpu-memory-utilization"].value == 0.985'
proof_assert 'max model len is memory-resolved (-1)' '.settings["max-model-len"].value == -1'
proof_assert 'load format is nvfp4_csf' '.settings["load-format"].value == "nvfp4_csf"'
proof_assert 'A4 expert prefill' '.settings["prefill-activations"].value == "a4"'
proof_assert 'tool parser is glm47' '.settings["tool-call-parser"].value == "glm47"'
proof_assert 'cache mode is vram (no host-RAM KV tier)' \
  '.settings["cache-mode"].value == "vram" and .cache_service == null'
proof_assert 'server-default effort is high (not the preset max)' \
  '.settings["default-chat-template-kwargs"].value == {"reasoning_effort":"high","clear_thinking":false}'
proof_assert 'KDA MXFP8 activations on prefill' '.environment.VLLM_GLM53_KDA_MXFP8_ACTIVATION_MODE.value == "prefill"'
proof_assert 'bf16 MTP draft head' '.environment.VLLM_GLM53_MTP_DRAFT_HEAD.value == "bf16"'
proof_assert 'lo-loopback NCCL socket' '.environment.NCCL_SOCKET_IFNAME.value == "lo"'

# Repository model-id proof: the environment alias overrides the preset name.
override_proof="$WORKDIR/override-proof.json"
print_config "$override_proof" -e SERVED_MODEL_NAME="$SERVED_MODEL_REPO"
if ! jq -e --arg model "$SERVED_MODEL_REPO" '
  .settings["served-model-name"].value == $model
  and (.settings["served-model-name"].source | startswith("environment:"))
' "$override_proof" >/dev/null 2>&1; then
  echo "error: SERVED_MODEL_NAME override was not honoured; the served name stays on the preset value" >&2
  exit 1
fi
printf 'PASS: SERVED_MODEL_NAME=%s overrides the preset served name\n' "$SERVED_MODEL_REPO"

proof_sha256="$(sha256sum "$base_proof" | cut -d' ' -f1)"
install -d -m 700 "$(dirname "$IDENTITY_FILE")"
identity_tmp="$(mktemp "$(dirname "$IDENTITY_FILE")/.v15-identity.XXXXXX")"
{
  printf 'pull_ref=%s\n' "$IMAGE_REF"
  printf 'image_id=%s\n' "$derived_id"
  printf 'preset=%s\n' "$PRESET"
  printf 'served_model_repo=%s\n' "$SERVED_MODEL_REPO"
  printf 'checkpoint=%s@%s\n' "$CHECKPOINT" "$MODEL_REVISION"
  printf 'kv_cache_bytes=%s\n' "$KV_CACHE_BYTES"
  printf 'base_proof_sha256=%s\n' "$proof_sha256"
  printf 'recipe=%s\n' "$RECIPE"
} >"$identity_tmp"
chmod 600 "$identity_tmp"
mv -f "$identity_tmp" "$IDENTITY_FILE"

printf 'GLM-5.3 v15 image pinned: %s\n' "$derived_id"
printf 'identity receipt: %s\n' "$IDENTITY_FILE"
printf 'IMAGE_CONFIG in run-glm53-flash-qad2-tp2-v15.sh must equal this id;\n'
printf 'the serve script refuses to launch any other image.\n'
