#!/usr/bin/env bash
# shellcheck disable=SC2016 # Assertions intentionally match literal Nix source.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
MODULE="$ROOT/machines/desktop/comfyui.nix"
BUILDER="$ROOT/scripts/comfyui/build-minimax-h3-vdn-workflows.sh"
DOWNLOADER="$ROOT/scripts/comfyui/download-minimax-h3-vdn-stage.sh"
RUNBOOK="$ROOT/docs/runbooks/minimax-h3-vdn-h3.md"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

contains() {
  local needle=$1
  grep -Fq -- "$needle" "$MODULE" || fail "missing module contract: $needle"
}

builder_contains() {
  local needle=$1
  grep -Fq -- "$needle" "$BUILDER" || fail "missing builder contract: $needle"
}

# Immutable node-pack pins: the VDN port, the Sol comparison nodes, and the
# Switch node the example's comparison topology routes through.
contains 'repo = "ComfyUI-VDN-H3";'
contains 'rev = "183f33d8a7b3c6322d83be95ae369251a63b3198";'
contains 'hash = "sha256-D7hR0XpYOIXV27g43Q0sH+X9SP8QGe47mDhW2DBpLJQ=";'
contains 'repo = "ComfyUI-sol-attn";'
contains 'rev = "930a4d6e432ff8b8ed5e30ff2f72519b92d69bdf";'
contains 'hash = "sha256-bdAEEzx6Ab2EHcrjsnhrwPOwlQHFfntMExj14mqumfA=";'
contains 'repo = "Rebalance-Pack";'
contains 'rev = "4553b145043b3ed6818651e5e39a01614fc11fb6";'
contains 'hash = "sha256-VgrNS/EfmJ94MFQCHDtke7JUr2jCtUgbHPYccKCh2mI=";'
contains '${comfyPythonEnv}/bin/python run_vdn_test.py'
contains 'VDN_TEST_PATH="$out/tests/test_vdn_math.py"'
contains 'VDN_TEST_PATH="$out/tests/test_window_dispatch.py"'
contains '${comfyPythonEnv}/bin/python tests/test_optimizations.py ArchitectureDispatchTests'
contains 'ln -s ${vdnH3Node} "$out/ComfyUI-VDN-H3"'
contains 'ln -s ${solAttnNode} "$out/ComfyUI-sol-attn"'
contains 'ln -s ${rebalancePackNode} "$out/Rebalance-Pack"'
contains '"vdn"'
contains '${../../scripts/comfyui/build-minimax-h3-vdn-workflows.sh}'
contains '${vdnH3Source}/example_workflows/vdn_h3_t2v_8step.json'
contains '${minimaxH3TurboWorkflowSource}/example_workflows/video_minimax_h3_ref2v_lightx2v_turbo.json'
contains 'h3_vdn_dir="$user_workflows/minimax-h3-vdn-h3"'

builder_contains 'VDN-H3-VS-fastvideoH3_t2v.json'
builder_contains 'Minimax-H3VDN-R2V.json'
builder_contains '"stage-dmd-step-250", true, 1, "merge", "cache_gpu", true, "grouped"'
builder_contains 'minimax_h3_fl2va_bf16.safetensors'
builder_contains 'minimax_h3_ref2va_bf16.safetensors'
builder_contains 'qwen3vl_32b_minimax_h3_bf16.safetensors'
builder_contains 'minimax_h3_fl2v_turbo_8step_v1.0_comfyui_bf16.safetensors'
builder_contains 'minimax_h3_ref2v_turbo_4step_v0.1_comfyui_bf16.safetensors'
builder_contains 'minimax_h3_video_vae_fp16.safetensors'
builder_contains 'minimax_h3_audio_vae_fp32.safetensors'
builder_contains 'No Turbo LoRA on the VDN branch'
builder_contains 'the released 8-step turbo adapter replaces community Turbo LoRAs'
builder_contains 'Do not stack the Scheduled Sol Attention patch or any Turbo LoRA into the VDN branch'
builder_contains '"beta", 8, 1'
builder_contains '["simple", 4, 1]'
builder_contains '["er_sde"]'
builder_contains '["euler"]'
builder_contains '[[12, 3]]'
builder_contains 'reference resize match'
builder_contains 'video/VDN-H3_R2V_VDN'
builder_contains 'video/VDN-H3_R2V_Turbo4_Control'
builder_contains 'video/VDN-H3_VS_fastvideoH3_t2v'
builder_contains '[[ $(find "$output_dir" -type f -name '\''*.json'\'' | wc -l) -eq 2 ]]'
grep -Fq "expected_vdn_t2v_source_sha=5abad5ea329d1b4cebc6dc8aa4bdb66a2f5440a5a77d27070ed065ada9667e5c" "$BUILDER" || fail 'VDN example source is not checksum-gated'
grep -Fq "expected_ref2v_source_sha=b906a154f9a45047714c43c038d345a6c645fda44e53f3b6f6aef23d3e179028" "$BUILDER" || fail 'REF2VA Turbo source is not checksum-gated'

for file in "$BUILDER" "$DOWNLOADER"; do
  [[ -x "$file" ]] || fail "missing executable: $file"
  bash -n "$file"
done

# Downloader: the bf16 stage-dmd-step-250 release pinned byte-exact, both
# license gates in force, staging/marker integrity intact.
grep -Fq 'REPO="OpenVDN/vdn-minimax-h3"' "$DOWNLOADER" || fail 'VDN downloader repository is not pinned'
grep -Fq 'REV="18be6bcc4ee72585eee322ba28b5ccac2cf85ef0"' "$DOWNLOADER" || fail 'VDN downloader revision is not pinned'
grep -Fq '58558fef506f88bb41649242de9b9b3a365da806b51b2e96afbbe1625222058a 334026912 stage-dmd-step-250/adapters/default/adapter_model.safetensors' "$DOWNLOADER" || fail 'default adapter artifact is not exact'
grep -Fq '24fc93c82fe84dc45d0627f4e72c637bc387d282ba18f60ed3b7f8c81089392c 851452696 stage-dmd-step-250/adapters/turbo/adapter_model.safetensors' "$DOWNLOADER" || fail 'turbo adapter artifact is not exact'
grep -Fq 'dec6981c7874f5b3bc92d1a02e256b673a3b3499dc1a124714bb3b19da602855 4279428112 stage-dmd-step-250/linear_branch/model.safetensors' "$DOWNLOADER" || fail 'linear branch artifact is not exact'
grep -Fq 'MINIMAX_H3_ACCEPT_LICENSE' "$DOWNLOADER" || fail 'VDN downloader lacks the base-license gate'
grep -Fq 'MINIMAX_H3_AUTHORIZED' "$DOWNLOADER" || fail 'VDN downloader lacks the authorization gate'
grep -Fq 'int8 ConvRot quantization' "$DOWNLOADER" || fail 'VDN downloader does not attest the bf16 stage choice'
if ! MINIMAX_H3_ACCEPT_LICENSE=no COMFYUI_MODELS_ROOT=/tmp/vdn-gate-check \
  "$DOWNLOADER" >/dev/null 2>&1; then
  :
else
  fail 'VDN downloader runs without the license gate'
fi
if ! MINIMAX_H3_ACCEPT_LICENSE=yes MINIMAX_H3_AUTHORIZED=no COMFYUI_MODELS_ROOT=/tmp/vdn-gate-check \
  "$DOWNLOADER" >/dev/null 2>&1; then
  :
else
  fail 'VDN downloader runs without the territorial authorization gate'
fi

# Runbook: what VDN is, how it installs, and the video's tips kept binding.
grep -Fq 'no Turbo LoRA' "$RUNBOOK" || fail 'runbook omits the VDN-no-LoRA rule'
grep -Fq 'lora_mode' "$RUNBOOK" || fail 'runbook omits the merge requirement'
grep -Fq 'Do not stack' "$RUNBOOK" || fail 'runbook omits the SOL stacking warning'
grep -Fq '8 steps' "$RUNBOOK" || fail 'runbook omits the 8-step recipe'

nix-instantiate --parse "$MODULE" >/dev/null
printf 'PASS: VDN-H3 pins the node port, Sol comparison nodes, bf16 stage, both license gates, and the Switch comparison topology\n'
