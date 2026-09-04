#!/usr/bin/env bash
# shellcheck disable=SC2016 # Assertions intentionally match literal Nix source.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
MODULE="$ROOT/machines/desktop/comfyui.nix"
WORKFLOW="$ROOT/comfyui/workflows/minimax-h3-balanced-supercc-v1.0-t2v.json"
RUNBOOK="$ROOT/docs/runbooks/minimax-h3-balanced-supercc-workflows.md"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

contains() {
  local needle=$1
  grep -Fq -- "$needle" "$MODULE" || fail "missing module contract: $needle"
}

runbook_contains() {
  local needle=$1
  grep -Fq -- "$needle" "$RUNBOOK" || fail "missing runbook contract: $needle"
}

# --- SuperNodes pin (sampler, scheduling, and tool nodes the workflow requires) ---
contains 'superNodesSource = pkgs.fetchFromGitHub {'
contains 'owner = "sonnybox";'
contains 'repo = "ComfyUI-SuperNodes";'
contains 'rev = "6a271834567f26576c046259493f0934c6c57d84";'
contains 'hash = "sha256-cBI28zo7MxtbRk8PcATbJN/1N87PJ9wC3dL2V1qmqv4=";'

# --- NVIDIA RTX nodes pin (RTXVideoSuperResolution is load-bearing) ---
contains 'nvidiaRtxNodesSource = pkgs.fetchFromGitHub {'
contains 'owner = "Comfy-Org";'
contains 'repo = "Nvidia_RTX_Nodes_ComfyUI";'
contains 'rev = "892515e3eb9a4920a131a502a047e47adca9eb0d";'
contains 'hash = "sha256-cuoFJAy2IQYomJlcclbM7WAdjk1AckQ4TRn3mCivyKc=";'

# --- nvidia-vfx proprietary wheel pin (wheel-stub cannot run hermetically) ---
contains 'nvidiaVfxWheel = pkgs.fetchurl {'
contains 'url = "https://pypi.nvidia.com/nvidia-vfx/nvidia_vfx-0.1.0.1-cp312-abi3-manylinux_2_27_x86_64.manylinux_2_28_x86_64.whl";'
contains 'hash = "sha256-e51d9e6faa68466e45b83be7928321af4b0c561c7c5536a8cb2b7e6aba25f905";'
contains 'nvidia-vfx = prev.buildPythonPackage {'
contains 'format = "wheel";'
contains 'nativeBuildInputs = [ pkgs.autoPatchelfHook ];'
contains 'autoPatchelfIgnoreMissingDeps = [ "libcuda.so.1" ];'
contains 'addAutoPatchelfSearchPath $out/${final.python.sitePackages}/nvvfx/libs'
contains 'Development evaluation under the bundled NVIDIA license terms, not a'
grep -Fq '      nvidia-vfx' "$MODULE" || fail "nvidia-vfx missing from comfyPythonEnv"

# --- declarative node mounts ---
contains 'ln -s ${superNodesSource} "$out/ComfyUI-SuperNodes"'
contains 'ln -s ${nvidiaRtxNodesSource} "$out/Nvidia_RTX_Nodes_ComfyUI"'

# --- install wiring ---
contains 'balanced_dir="$user_workflows/minimax-h3-balanced-supercc-bf16"'
contains 'balanced_staging="$user_workflows/.minimax-h3-balanced-supercc-bf16.new"'
contains '${../../comfyui/workflows/minimax-h3-balanced-supercc-v1.0-t2v.json}'
contains '"$balanced_staging/MiniMax H3 BF16 Balanced SuperCC v1.0 - Text To Video.json"'
contains 'mv "$balanced_staging" "$balanced_dir"'
test "$(grep -Fc 'balanced_staging/MiniMax H3 BF16 Balanced SuperCC v1.0 - Text To Video.json' "$MODULE")" -eq 1 \
  || fail "balanced workflow installed more than once"
contains 'docs/runbooks/minimax-h3-balanced-supercc-workflows.md'

# --- workflow JSON invariants ---
jq -e . "$WORKFLOW" > /dev/null || fail "adapted workflow is not valid JSON"

jq -e '
  ([.. | objects | select(.type? == "UNETLoader") | .widgets_values]
    == [["minimax_h3_fl2va_bf16.safetensors", "default"]])
  and ([.. | objects | select(.type? == "CLIPLoader") | .widgets_values]
    == [["qwen3vl_32b_minimax_h3_bf16.safetensors", "minimax", "default"]])
  and ([.. | objects | select(.type? == "SuperSelectLoraName") | .widgets_values[0]]
    == ["h3/minimax_h3_fl2v_lightx2v_turbo_8step_merge_0821_bf16.safetensors"])
  and (([.. | objects | select(.type? == "VAELoader") | .widgets_values[0]] | sort)
    == (["minimax_h3_audio_vae_fp32.safetensors", "minimax_h3_video_vae_fp16.safetensors"] | sort))
  and ([.. | objects | select(.type? == "MiniMaxChunkFeedForward" and .mode? == 0)] | length == 0)
  and ([.. | objects | select(.type? == "SetReserveVRAM" and .mode? == 0
    and .widgets_values[0] == 128)] | length == 0)
' "$WORKFLOW" > /dev/null || fail "workflow invariant violation"

grep -Fq '"minimax_h3_fl2va_bf16.safetensors"' "$WORKFLOW" || fail "missing bf16 DiT selector"
if grep -RqiE 'int8_convrot|pruned_int8|nvfp4' "$WORKFLOW"; then
  fail "forbidden lower-precision selector in adapted workflow"
fi

# Bypass modes: main graph ids and the Test Target Megapixels subgraph pair.
for id in 751 650; do
  jq -e --argjson id "$id" '
    ([.nodes[] | select(.id == $id)][0].mode) == 4
    and ([.nodes[] | select(.id == $id)][0].type | IN("MiniMaxChunkFeedForward", "SetReserveVRAM"))
  ' "$WORKFLOW" > /dev/null || fail "main-graph node $id is not a bypassed low-VRAM node"
done
jq -e '
  ([.definitions.subgraphs[] | select(.name? == "Test Target Megapixels")][0].nodes
    | map(select(.type == "MiniMaxChunkFeedForward" or .type == "SetReserveVRAM"))
    | {count: length, all_bypassed: all(.mode == 4)})
  == {count: 2, all_bypassed: true}
' "$WORKFLOW" > /dev/null || fail "Test Target Megapixels subgraph low-VRAM pair is not bypassed"

# Required node types the packs must provide.
for node_type in SetReserveVRAM DualSamplerEulerAncestral DualSamplerCustomAdvanced \
  SigmaAncestry SigmasRescale SuperSelectLoraName ImageSizeCalculator \
  MiniMaxChunkFeedForward RTXVideoSuperResolution ComfyMathExpression \
  EmptyMiniMaxH3LatentAV LTXVConcatAVLatent ModelAttentionBackend; do
  grep -Fq "\"$node_type\"" "$WORKFLOW" || fail "workflow missing required node type: $node_type"
done

# Runbook provenance.
runbook_contains '2f04b9e5329ddc625f2d7694e5e988c1db688e2ff7942ff5016fadeb3bdfe22a'
runbook_contains '15437c28698054a63821f3b9c4a6b729ec5fe6e387a126b942d43c62b0a5930b'
runbook_contains 'https://supercc.ai/files/1/v1.0-16qvluw/H3_T2V_Balanced.json'
runbook_contains 'LicenseRef-NvidiaProprietary'

printf 'OK: minimax-h3-balanced-supercc workflows contract satisfied\n'
