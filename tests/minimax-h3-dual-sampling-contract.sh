#!/usr/bin/env bash
# Contract for the exact downloaded HJteqahyEKM MiniMax H3 Dual Sampling source
# and its deterministic workstation adaptations.
# shellcheck disable=SC2016 # Assertions intentionally match literal source text.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
MODULE="$ROOT/machines/desktop/comfyui.nix"
BUILDER="$ROOT/scripts/comfyui/build-minimax-h3-dual-sampling-workflows.sh"
DOWNLOADER="$ROOT/scripts/comfyui/download-minimax-h3-dual-sampling-models.sh"
SOURCE="$ROOT/comfyui/workflows/minimax-h3-singularity-dual-sampling-i2v.json"
RUNBOOK="$ROOT/docs/runbooks/minimax-h3-dual-sampling.md"
SOURCE_SHA256=69b3373cf4b9784d50886c0ae65a516e34f0b9cf65dc29d9d216bd286dab4778

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

contains() {
  local file=$1 needle=$2
  grep -Fq -- "$needle" "$file" || fail "$file does not contain: $needle"
}

for file in "$MODULE" "$BUILDER" "$DOWNLOADER" "$SOURCE" "$RUNBOOK"; do
  [[ -f "$file" ]] || fail "missing $file"
done
[[ -x "$BUILDER" ]] || fail "builder is not executable"
[[ -x "$DOWNLOADER" ]] || fail "downloader is not executable"
bash -n "$BUILDER"
bash -n "$DOWNLOADER"
nix-instantiate --parse "$MODULE" >/dev/null

actual_source_sha=$(sha256sum "$SOURCE")
actual_source_sha=${actual_source_sha%% *}
[[ "$actual_source_sha" == "$SOURCE_SHA256" ]] || fail "downloaded source digest drifted"
jq -e '
  .extra.workflow_author == "The AI Brief"
  and (.nodes | length) == 87
  and (.links | length) == 88
  and ([.nodes[] | select(.type == "SamplerCustomAdvanced")] | length) == 3
  and any(.nodes[]; .type == "ExtendIntermediateSigmas" and .widgets_values == [2,1.0000000000000002,0,"linear"])
  and any(.nodes[]; .type == "BlockSparseAttention")
  and any(.nodes[]; .type == "Lora Loader Stack (rgthree)")
' "$SOURCE" >/dev/null

# Nix builds from the immutable downloaded source and installs a new version
# before retiring the earlier public-video reconstruction.
contains "$MODULE" '${../../comfyui/workflows/minimax-h3-singularity-dual-sampling-i2v.json}'
contains "$MODULE" 'h3_dual_dir="$user_workflows/minimax-h3-dual-sampling-v1.1-source-exact"'
contains "$MODULE" 'verify_versioned_workflow_install "$h3_dual_staging" "$h3_dual_dir"'
contains "$MODULE" 'install_versioned_workflow_dir "$h3_dual_staging" "$h3_dual_dir"'
contains "$MODULE" 'rm -rf "$h3_dual_legacy_dir"'
contains "$MODULE" 'downloadMinimaxH3DualSamplingModels = pkgs.writeShellApplication'

# Build both profiles from the real source and validate their complete graph.
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
"$BUILDER" --source-workflow "$SOURCE" --output-dir "$tmp"
bf16="$tmp/00 MiniMax H3 BF16 Dual Sampling - Source Exact Topology.json"
singularity="$tmp/01 MiniMax H3 Singularity v1.3 Dual Sampling - Source Exact Topology.json"
[[ -f "$bf16" && -f "$singularity" ]] || fail "builder did not emit both profiles"

jq -s -e --arg sha "$SOURCE_SHA256" '
  length == 2
  and all(.[]; . as $workflow
    | (.nodes | length) == 55
    and (.links | length) == 70
    and .extra.source_sha256 == $sha
    and all(.links[]; . as $edge
      | any($workflow.nodes[];
          .id == $edge[1]
          and ((.outputs[$edge[2]].links // []) | index($edge[0])) != null)
      and any($workflow.nodes[];
          .id == $edge[3]
          and .inputs[$edge[4]].link == $edge[0]))
    and any(.nodes[]; .id == 71 and .widgets_values == ["simple",6,1])
    and any(.nodes[]; .id == 94 and .widgets_values == [2,1,0,"linear"])
    and any(.nodes[]; .id == 99 and .widgets_values == [2])
    and any(.nodes[]; .id == 100 and .widgets_values == [0])
    and any(.nodes[]; .id == 118 and .type == "LoraLoaderModelOnly"
      and .widgets_values == ["minimax_h3_ref2v_turbo_4step_v0.1_comfyui_bf16.safetensors",1])
    and any(.nodes[]; .id == 127 and .widgets_values == ["minimax_h3_lms_v1.0_r64.safetensors",0.5])
    and any(.nodes[]; .id == 199 and .widgets_values == ["h3-realism-people-t2v-i2v-r2v.safetensors",1])
    and any(.nodes[]; .type == "MinimaxH3LatentUpscaler3D"
      and .widgets_values == ["minimax_h3_latent_upscaler_3d_conv_v1_bf16.safetensors","scale by multiplier",1.25,32,true,true,"cuda","bf16"])
    and ([.nodes[] | select(.type == "BlockSparseAttention"
        or .type == "Lora Loader Stack (rgthree)"
        or .type == "SetNode"
        or .type == "GetNode"
        or .type == "easy float")] | length) == 0
    and ([.. | objects | select(has("models") or has("videopreview"))] | length) == 0)
  and ([.[0].nodes[] | select(.type == "UNETLoader") | .widgets_values[0]] == ["minimax_h3_ref2va_bf16.safetensors"])
  and ([.[1].nodes[] | select(.type == "UNETLoader") | .widgets_values[0]] == ["minimax_h3_singularity_ref2va_v1.3_int8.safetensors"])
  and all(.[]; [.nodes[] | select(.type == "CLIPLoader") | .widgets_values[0]] == ["qwen3vl_32b_minimax_h3_bf16.safetensors"])
' "$bf16" "$singularity" >/dev/null

# LMS artifact identity and transactional install remain immutable.
contains "$DOWNLOADER" 'REV="0ff489e781c274d17b2e3a30cd6f9a8d40ca49ff"'
contains "$DOWNLOADER" 'SHA256="16f3195bc6bffa431c0598dc2031e520ba058b4fcbc9f104db9e3fdfdeacf60c"'
contains "$DOWNLOADER" 'SIZE="1239664536"'
contains "$DOWNLOADER" 'mv -f "$DESTINATION.new" "$DESTINATION"'
contains "$DOWNLOADER" 'MINIMAX_H3_DUAL_SAMPLING_LMS_READY'

contains "$RUNBOOK" "$SOURCE_SHA256"
contains "$RUNBOOK" 'official unpruned BF16 Ref2VA checkpoint'
contains "$RUNBOOK" 'no BF16 checkpoint'
contains "$RUNBOOK" 'container is not stopped or restarted.'

printf 'minimax-h3 dual-sampling source-exact contract: OK\n'
