#!/usr/bin/env bash
# Pull and prove the GLM-5.3 v14 image: the upstream Karmic Kraken beta channel
# image (ghcr.io/local-inference-lab/vllm:karmic-kraken-beta) with the
# GLM Spark TP2 deployment preset (PRESET=glm53-spark-tp2).
#
# v14 is the first repository-managed profile that is not a custom-derived
# image: the served tree is exactly the upstream integration image, and the
# deployment contract comes from the upstream preset. What this script still
# owns:
#   - digest pinning: the tag is resolved to one content-addressed image id
#     that run-glm53-flash-spark-tp2-v14.sh refuses to replace;
#   - a CPU-only `--print-config` proof (no GPU, no model load, no cache
#     services) that the pinned image's stock spark preset IS the contract:
#     GLM Spark checkpoint, TP2/DCP2, MTP3, four slots, 3072-token prefill,
#     3996 MiB/GPU KV (4190109696 bytes), gpu-memory-utilization 0.985,
#     max-model-len -1 (memory-resolved), safetensors load, rtx-pro-6000-pcie;
#   - a second --print-config pass with SERVED_MODEL_NAME set, proving the
#     repository's per-profile model id wins over the preset's GLM-5.3-Flash
#     (launcher precedence: native arg > environment alias > preset default);
#   - an identity receipt recording the image id, the pull ref, the proof
#     output digest and the upstream deployment facts.
set -euo pipefail

PULL_REF="ghcr.io/local-inference-lab/vllm:karmic-kraken-beta"
PRESET="glm53-spark-tp2"
UPSTREAM_DOC="https://github.com/local-inference-lab/rtx6kpro/blob/master/models/glm-5.3-flash-spark-tp2.md"
# The upstream preset's pinned values; the proof fails closed on every one.
SERVED_MODEL_PRESET="GLM-5.3-Flash"
SERVED_MODEL_REPO="glm-5.3-flash-spark-tp2-v14"
CHECKPOINT="local-inference-lab/GLM-5.3-Flash-NVFP4-Spark"
KV_CACHE_BYTES="4190109696"   # 3996 MiB per GPU
IDENTITY_FILE="${IDENTITY_FILE:-$HOME/.local/state/glm53/flash-spark-tp2-v14-image.identity}"
WORKDIR="${TMPDIR:-/tmp}/glm53-spark-tp2-v14-pull.$$"

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

docker pull "$PULL_REF" >/dev/null
derived_id="$(docker image inspect "$PULL_REF" --format '{{.Id}}')"
[[ "$derived_id" =~ ^sha256:[0-9a-f]{64}$ ]] || {
  echo "error: pulled image id is not a content address: $derived_id" >&2
  exit 1
}

# Base preset proof: the pinned image's stock PRESET=glm53-spark-tp2 launch
# plan must be byte-stable on the documented deployment contract.
mkdir -p "$WORKDIR"
base_proof="$WORKDIR/base-proof.json"
docker run --rm --runtime runc --network none \
  -e PRESET="$PRESET" "$PULL_REF" --print-config >"$base_proof" 2>"$WORKDIR/base-proof.err" || {
  echo "error: --print-config failed for the stock spark preset" >&2
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
    echo "error: stock preset proof failed: $description" >&2
    rm -rf "$WORKDIR"
    exit 1
  fi
  printf 'PASS: %s\n' "$description"
}
proof_assert 'profile is glm53-flash' '.profile == "glm53-flash"'
proof_assert 'hardware profile is rtx-pro-6000-pcie' '.hardware == "rtx-pro-6000-pcie"'
proof_assert "checkpoint is $CHECKPOINT" '.settings.model.value == "local-inference-lab/GLM-5.3-Flash-NVFP4-Spark"'
proof_assert "preset served model name is $SERVED_MODEL_PRESET" \
  '.settings["served-model-name"].value == "GLM-5.3-Flash" and .settings["served-model-name"].source == "preset:glm53-spark-tp2"'
proof_assert 'tensor parallel is 2' '.settings["tensor-parallel-size"].value == 2'
proof_assert 'decode context parallel is 2' '.settings["decode-context-parallel-size"].value == 2'
proof_assert 'speculation mode is mtp' '.settings.mode.value == "mtp"'
proof_assert 'mtp draft depth is 3' '.settings["draft-tokens"].value == 3'
proof_assert 'request slots are 4' '.settings["max-num-seqs"].value == 4'
proof_assert 'prefill budget is 3072' '.settings["max-num-batched-tokens"].value == 3072 and .settings["cache-object-tokens"].value == 3072'
proof_assert "fixed KV allocation is $KV_CACHE_BYTES bytes (3996 MiB/GPU)" \
  '.settings["kv-cache-memory-bytes"].value == 4190109696'
proof_assert 'gpu memory utilization is 0.985' '.settings["gpu-memory-utilization"].value == 0.985'
proof_assert 'max model len is memory-resolved (-1)' '.settings["max-model-len"].value == -1'
proof_assert 'load format is safetensors' '.settings["load-format"].value == "safetensors"'
proof_assert 'lo-loopback NCCL socket' '.environment.NCCL_SOCKET_IFNAME.value == "lo"'
proof_assert 'two-shot all-reduce disabled' '.environment.VLLM_PCIE_TWOSHOT_ALLREDUCE_MAX_SIZE.value == "off"'
proof_assert 'cublas 4 MiB workspace' '.environment.CUBLAS_WORKSPACE_CONFIG.value == ":4096:1"'
proof_assert 'no cache service in the stock plan' '.cache_service == null'

# Repository model-id proof: the environment alias overrides the preset
# served-model-name (launcher precedence: native arg > env alias > preset).
override_proof="$WORKDIR/override-proof.json"
docker run --rm --runtime runc --network none \
  -e PRESET="$PRESET" -e SERVED_MODEL_NAME="$SERVED_MODEL_REPO" \
  "$PULL_REF" --print-config >"$override_proof" 2>"$WORKDIR/override-proof.err" || {
  echo "error: --print-config failed with SERVED_MODEL_NAME set" >&2
  cat "$WORKDIR/override-proof.err" >&2 || true
  rm -rf "$WORKDIR"
  exit 1
}
if ! jq -e --arg model "$SERVED_MODEL_REPO" '
  .settings["served-model-name"].value == $model
  and (.settings["served-model-name"].source | startswith("environment:"))
' "$override_proof" >/dev/null 2>&1; then
  echo "error: SERVED_MODEL_NAME override was not honoured; the served name stays on the preset value" >&2
  rm -rf "$WORKDIR"
  exit 1
fi
printf 'PASS: SERVED_MODEL_NAME=%s overrides the preset served name\n' "$SERVED_MODEL_REPO"

# Also prove the launch-argument override path (native arg wins over the env
# alias) so the operator pass documented in the runbook cannot drift either.
native_proof="$WORKDIR/native-proof.json"
docker run --rm --runtime runc --network none \
  -e PRESET="$PRESET" -e SERVED_MODEL_NAME="$SERVED_MODEL_PRESET" \
  "$PULL_REF" --print-config --served-model-name "$SERVED_MODEL_REPO" \
  >"$native_proof" 2>"$WORKDIR/native-proof.err" || {
  echo "error: --print-config failed with --served-model-name" >&2
  cat "$WORKDIR/native-proof.err" >&2 || true
  rm -rf "$WORKDIR"
  exit 1
}
if ! jq -e --arg model "$SERVED_MODEL_REPO" '
  .settings["served-model-name"].value == $model
  and .settings["served-model-name"].source == "cli"
' "$native_proof" >/dev/null 2>&1; then
  echo "error: --served-model-name override was not honoured" >&2
  rm -rf "$WORKDIR"
  exit 1
fi
printf 'PASS: --served-model-name wins over the environment alias\n'

proof_sha256="$(sha256sum "$base_proof" | cut -d' ' -f1)"
install -d -m 700 "$(dirname "$IDENTITY_FILE")"
identity_tmp="$(mktemp "$(dirname "$IDENTITY_FILE")/.v14-identity.XXXXXX")"
{
  printf 'pull_ref=%s\n' "$PULL_REF"
  printf 'image_id=%s\n' "$derived_id"
  printf 'preset=%s\n' "$PRESET"
  printf 'served_model_preset=%s\n' "$SERVED_MODEL_PRESET"
  printf 'served_model_repo=%s\n' "$SERVED_MODEL_REPO"
  printf 'checkpoint=%s\n' "$CHECKPOINT"
  printf 'kv_cache_bytes=%s\n' "$KV_CACHE_BYTES"
  printf 'base_proof_sha256=%s\n' "$proof_sha256"
  printf 'upstream_doc=%s\n' "$UPSTREAM_DOC"
} >"$identity_tmp"
chmod 600 "$identity_tmp"
mv -f "$identity_tmp" "$IDENTITY_FILE"
rm -rf "$WORKDIR"

printf 'GLM-5.3 v14 image pinned: %s\n' "$derived_id"
printf 'identity receipt: %s\n' "$IDENTITY_FILE"
printf 'Record this image id as IMAGE_CONFIG in run-glm53-flash-spark-tp2-v14.sh before serving;\n'
printf 'the serve script refuses to launch while the id is unrecorded.\n'
