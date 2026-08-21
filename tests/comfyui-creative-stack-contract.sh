#!/usr/bin/env bash
# Static and pure-function contract for the Nix-managed creative stack.
# shellcheck disable=SC2016 # Assertions intentionally match literal source.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODULE="$ROOT/machines/desktop/comfyui.nix"
DESKTOP="$ROOT/machines/desktop/default.nix"
NODE="$ROOT/comfyui/custom_nodes/muse_glimmer_prompt/__init__.py"
NODE_TEST="$ROOT/tests/test_muse_glimmer_prompt.py"
DOWNLOAD="$ROOT/scripts/comfyui/download-krea2-models.sh"
H3_DOWNLOAD="$ROOT/scripts/comfyui/download-minimax-h3-models.sh"
ACTIVATE="$ROOT/scripts/comfyui/activate-creative-stack.sh"
RUNBOOK="$ROOT/docs/runbooks/comfyui-krea2-minimax-h3-muse-runbook.md"
H3_RUNBOOK="$ROOT/docs/runbooks/local-ai-video-script-runbook.md"
TRANSITION_TEST="$ROOT/tests/creative-stack-transitions-contract.sh"
DOWNLOAD_TEST="$ROOT/tests/model-download-verification-contract.sh"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

contains() {
  local file="$1" text="$2"
  grep -Fq -- "$text" "$file" || fail "$file does not contain: $text"
}

absent() {
  local file="$1" text="$2"
  if grep -Fq -- "$text" "$file"; then
    fail "$file must not contain: $text"
  fi
}

for file in "$MODULE" "$DESKTOP" "$NODE" "$NODE_TEST" "$DOWNLOAD" "$H3_DOWNLOAD" "$ACTIVATE" "$RUNBOOK" "$H3_RUNBOOK" "$TRANSITION_TEST" "$DOWNLOAD_TEST"; do
  [[ -f "$file" ]] || fail "missing $file"
done
for file in "$NODE_TEST" "$DOWNLOAD" "$H3_DOWNLOAD" "$ACTIVATE" "$TRANSITION_TEST" "$DOWNLOAD_TEST"; do
  [[ -x "$file" ]] || fail "$file is not executable"
done
bash -n "$DOWNLOAD"
bash -n "$H3_DOWNLOAD"
bash -n "$ACTIVATE"
nix-instantiate --parse "$MODULE" >/dev/null

# Nix owns a binary-CUDA ComfyUI runtime and an immutable custom-node path.
contains "$DESKTOP" './comfyui.nix'
contains "$MODULE" 'cuda-bindings = prev.cuda-bindings.override {'
contains "$MODULE" '(prev.torch-bin.override {'
contains "$MODULE" 'pythonRelaxDeps = (old.pythonRelaxDeps or [ ]) ++ [ "setuptools" ];'
contains "$MODULE" 'triton = prev.triton-bin.override {'
contains "$MODULE" 'torchvision = prev.torchvision-bin.override {'
contains "$MODULE" '(prev.torchaudio-bin.override {'
contains "$MODULE" 'torchaudio-2.11.0%2Bcu130-cp314-cp314-manylinux_2_28_x86_64.whl'
contains "$MODULE" 'sha256-N4tJZxtYERSi0l1Ako8SoVCHL+rfEWaaY/Vz6Bx4AZo='
contains "$MODULE" 'binaryCudaPackages = pkgs.cudaPackages_13.overrideScope ('
contains "$MODULE" 'cudaPackages = binaryCudaPackages;'
contains "$MODULE" '(pkgs.lib.cmakeBool "NVSHMEM_BUILD_TESTS" false)'
contains "$MODULE" '(pkgs.lib.cmakeBool "NVSHMEM_BUILD_EXAMPLES" false)'
contains "$MODULE" 'pkgs.comfyui.override'
contains "$MODULE" 'CUDA_VISIBLE_DEVICES = "1";'
contains "$MODULE" '--listen 127.0.0.1'
contains "$MODULE" '--port 8188'
contains "$MODULE" '"${pkgs.coreutils}/bin/install -d -m 0700 /var/lib/comfyui/user"'
contains "$MODULE" 'installCreativeWorkflows'
contains "$MODULE" '--database-url sqlite:////var/lib/comfyui/user/comfyui.db'
contains "$MODULE" '--reserve-vram 8'
contains "$MODULE" 'custom_nodes: ${declarativeNodes}'
contains "$MODULE" 'rev = "bdfa8b267fdb13730868d435b277dcfe696ec083";'
contains "$MODULE" 'rev = "cf8895005540680306cd46e1faaf75f8902db794";'
contains "$MODULE" 'rev = "c1aaee4f6a41a69563eab50e51cd1ef7347f22e9";'
contains "$MODULE" 'Ep30%20Workflows.zip'
contains "$MODULE" 'sha256-Rvy8DmMPWk7gKL3YQdBPJsqXylOMPDPSkjFZ2bH1l5k='
contains "$MODULE" 'test "$(find "$out/workflows" -type f -name '\''*.json'\'' | wc -l)" -eq 7'
contains "$MODULE" 'test "$(find "$out/media" -type f | wc -l)" -eq 6'
contains "$MODULE" 'grep -RohF '\''krea2\\krea2_turbo_int8_convrot.safetensors'\'''
contains "$MODULE" 'grep -RohF '\''qwen3-vl-4b-heretic_int8.safetensors'\'''
contains "$MODULE" 'pythonPackages.hf-xet'
contains "$MODULE" 'modelSubdirectories = ['
contains "$MODULE" '++ map (directory: "d /models/comfyui/${directory} 0750 peterstorm users - -") modelSubdirectories;'
contains "$MODULE" 'binaryTorchPython.pkgs.comfyui-workflow-templates-json'
contains "$MODULE" 'test "$(${pkgs.findutils}/bin/find "$out" -type f -name '\''*.json'\'' | wc -l)" -eq 51'
contains "$MODULE" 'ep30_dir="$user_workflows/pixaroma-ep30"'
contains "$MODULE" 'elite_dir="$user_workflows/creative-suite"'
contains "$MODULE" 'ep30_staging="$user_workflows/.pixaroma-ep30.new"'
contains "$MODULE" 'elite_staging="$user_workflows/.creative-suite.new"'
contains "$MODULE" 'rm -rf "$ep30_dir" "$elite_dir"'
contains "$MODULE" 'ReadOnlyPaths = [ "/models/comfyui" ];'
contains "$MODULE" 'ProtectSystem = "strict";'
absent "$MODULE" 'wantedBy = [ "multi-user.target" ];'
absent "$MODULE" 'comfyui-manager'
# The only mention is the explanatory comment spelling ComfyUI-Manager.
if grep -Eq 'allowedTCPPorts.*8188|8188.*allowedTCPPorts' "$DESKTOP"; then
  fail "desktop firewall exposes unauthenticated ComfyUI port 8188"
fi

# Muse credentials stay out of workflows and request bodies.
contains "$NODE" 'MUSE_GLIMMER_API_KEY_FILE'
contains "$NODE" 'mode & 0o077'
contains "$NODE" 'chat_template_kwargs": {"reasoning_strength": reasoning_strength}'
contains "$NODE" 'temperature": 1.0'
contains "$NODE" 'top_p": 0.95'
contains "$NODE" 'top_k": 64'
contains "$NODE" 'NODE_CLASS_MAPPINGS = {"MuseGlimmerPrompt": MuseGlimmerPrompt}'
if grep -Eq '"sk-[[:alnum:]]{8,}' "$NODE"; then
  fail "$NODE contains a literal API-key-shaped value"
fi
"$NODE_TEST"

# Krea artifacts are license-gated, revision-pinned, and checksum-verified.
contains "$DOWNLOAD" 'KREA2_ACCEPT_LICENSE'
contains "$DOWNLOAD" 'REV="e5ea8b4dd7f38f348b138eb0fe29f92c0e367e96"'
contains "$DOWNLOAD" 'krea2_turbo_bf16.safetensors'
contains "$DOWNLOAD" 'krea2_turbo_int8_convrot.safetensors'
contains "$DOWNLOAD" 'qwen3vl_4b_bf16.safetensors'
contains "$DOWNLOAD" 'qwen3vl_4b_fp8_scaled.safetensors'
contains "$DOWNLOAD" 'krea2_style_reference.safetensors'
contains "$DOWNLOAD" 'krea2_identity_edit_v1_2.safetensors'
contains "$DOWNLOAD" 'krea_outfittransfer.safetensors'
contains "$DOWNLOAD" 'qwen3-vl-8b-heretic-1.3.0_fp8_e4m3fn.safetensors'
contains "$DOWNLOAD" 'IDENTITY_REV="89e9e7a09ee2e5c9331e952063d79b1b8a703280"'
contains "$DOWNLOAD" 'OUTFIT_REV="827dab8588b6cb261cf9ae580c417bc068740b7f"'
contains "$DOWNLOAD" 'H3_PROMPT_REV="28dc0129b4c7c16304bc2ed3697c9437ae8ac2f3"'
contains "$DOWNLOAD" 'sha256sum "$file"'
contains "$DOWNLOAD" 'stat -c %s "$file"'
contains "$DOWNLOAD" 'mv -f "$destination.new" "$destination"'
[[ "$(grep -Ec '^[0-9a-f]{64} [0-9]+ (diffusion_models|text_encoders|vae|loras)/' "$DOWNLOAD")" -eq 15 ]] \
  || fail "Krea base manifest must contain exactly 15 pinned artifacts"
[[ "$(grep -Ec '^[0-9a-f]{64} [0-9]+ \$[A-Z0-9_]+_REPO \$[A-Z0-9_]+_REV ' "$DOWNLOAD")" -eq 3 ]] \
  || fail "Episode 30 auxiliary manifest must contain exactly 3 pinned artifacts"

# MiniMax H3 is separately authorized, revision-pinned, complete, and atomic.
contains "$H3_DOWNLOAD" 'MINIMAX_H3_ACCEPT_LICENSE'
contains "$H3_DOWNLOAD" 'MINIMAX_H3_AUTHORIZED'
contains "$H3_DOWNLOAD" 'REV="dc559027db79c174125df4d827db55cd11178860"'
contains "$H3_DOWNLOAD" 'minimax_h3_fl2va_bf16.safetensors'
contains "$H3_DOWNLOAD" 'minimax_h3_ref2va_bf16.safetensors'
contains "$H3_DOWNLOAD" 'qwen3vl_32b_minimax_h3_bf16.safetensors'
contains "$H3_DOWNLOAD" "python3 -c 'import hf_xet'"
contains "$H3_DOWNLOAD" 'unset HF_HUB_DISABLE_XET'
contains "$H3_DOWNLOAD" 'sha256sum "$file"'
contains "$H3_DOWNLOAD" 'mv -f "$destination.new" "$destination"'
[[ "$(grep -Fc 'rm -rf "$STAGING"' "$H3_DOWNLOAD")" -eq 1 ]] \
  || fail "MiniMax H3 staging may be removed only after successful installation"
[[ "$(grep -Ec '^[0-9a-f]{64} [0-9]+ (diffusion_models|text_encoders|vae|loras)/' "$H3_DOWNLOAD")" -eq 8 ]] \
  || fail "MiniMax H3 BF16 manifest must contain exactly 8 pinned artifacts"

# Activation is explicit and rollback-aware; Comfy stays on GPU1, Muse on GPU0.
contains "$ACTIVATE" "mapfile -t prior_running"
contains "$ACTIVATE" 'comfy_was_active=0'
contains "$ACTIVATE" 'trap rollback ERR INT TERM'
contains "$ACTIVATE" 'sudo systemctl stop comfyui.service'
contains "$ACTIVATE" 'if [ "$comfy_was_active" -eq 1 ]; then'
contains "$ACTIVATE" 'CUDA_VISIBLE_DEVICES=1'
contains "$ACTIVATE" 'MUSE_VARIANT="$MUSE_VARIANT" GPU_DEVICE=0 PORT=8001 bash "$MUSE_LAUNCHER"'
contains "$ACTIVATE" 'muse_resolve_variant "${MUSE_VARIANT:-standard}"'
contains "$ACTIVATE" 'ssh -N -L 8188:127.0.0.1:8188 desktop'

# The runbook distinguishes globally available API use from blocked EU weights.
contains "$RUNBOOK" 'MINIMAX_H3_AUTHORIZED=yes'
contains "$RUNBOOK" 'Disk inventory is not simultaneous VRAM residency'
contains "$RUNBOOK" 'minimax_h3_fl2va_bf16.safetensors'
contains "$RUNBOOK" 'minimax_h3_ref2va_bf16.safetensors'
contains "$RUNBOOK" '61.73 GiB'
contains "$RUNBOOK" 'Do not queue Krea and H3 generation concurrently on GPU1'
contains "$RUNBOOK" 'MiniMax H3 API is'
contains "$RUNBOOK" 'Krea2ImageNode'
contains "$RUNBOOK" 'Krea2StyleReferenceNode'
contains "$RUNBOOK" 'MinimaxHailuo03ContextIRNode'
contains "$RUNBOOK" 'MinimaxHailuo03RegenerateNode'
contains "$RUNBOOK" 'MiniMaxH3ReferenceToVideo'
contains "$RUNBOOK" 'Muse Glimmer Creative Prompt'
contains "$RUNBOOK" '51 curated official workflows'
contains "$RUNBOOK" 'Muse-Glimmer-30B-Abliterated-BF16'
contains "$RUNBOOK" 'daf5fab76a0351a583714a92d88ebdb6eb48af35'
contains "$RUNBOOK" 'full BF16'
contains "$RUNBOOK" 'ComfyUI-Manager'
contains "$RUNBOOK" 'manual human review'
contains "$H3_RUNBOOK" 'comfyui-krea2-minimax-h3-muse-runbook.md'

"$TRANSITION_TEST"
"$DOWNLOAD_TEST"

printf 'PASS: Nix-managed ComfyUI + Krea 2 + MiniMax H3 + Muse contract is internally consistent\n'
