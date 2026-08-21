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
ACTIVATE="$ROOT/scripts/comfyui/activate-creative-stack.sh"
RUNBOOK="$ROOT/docs/runbooks/comfyui-krea2-minimax-h3-muse-runbook.md"
H3_RUNBOOK="$ROOT/docs/runbooks/local-ai-video-script-runbook.md"

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

for file in "$MODULE" "$DESKTOP" "$NODE" "$NODE_TEST" "$DOWNLOAD" "$ACTIVATE" "$RUNBOOK" "$H3_RUNBOOK"; do
  [[ -f "$file" ]] || fail "missing $file"
done
for file in "$NODE_TEST" "$DOWNLOAD" "$ACTIVATE"; do
  [[ -x "$file" ]] || fail "$file is not executable"
done
bash -n "$DOWNLOAD"
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
contains "$MODULE" 'ExecStartPre = "${pkgs.coreutils}/bin/install -d -m 0700 /var/lib/comfyui/user";'
contains "$MODULE" '--database-url sqlite:////var/lib/comfyui/user/comfyui.db'
contains "$MODULE" '--reserve-vram 8'
contains "$MODULE" 'custom_nodes: ${musePromptNode}'
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
absent "$NODE" 'sk-'
"$NODE_TEST"

# Krea artifacts are license-gated, revision-pinned, and checksum-verified.
contains "$DOWNLOAD" 'KREA2_ACCEPT_LICENSE'
contains "$DOWNLOAD" 'REV="e5ea8b4dd7f38f348b138eb0fe29f92c0e367e96"'
contains "$DOWNLOAD" 'krea2_turbo_bf16.safetensors'
contains "$DOWNLOAD" 'krea2_turbo_int8_convrot.safetensors'
contains "$DOWNLOAD" 'qwen3vl_4b_bf16.safetensors'
contains "$DOWNLOAD" 'qwen3vl_4b_fp8_scaled.safetensors'
contains "$DOWNLOAD" 'krea2_style_reference.safetensors'
contains "$DOWNLOAD" 'sha256sum "$file"'
contains "$DOWNLOAD" 'stat -c %s "$file"'
contains "$DOWNLOAD" 'mv -f "$destination.new" "$destination"'
[[ "$(grep -Ec '^[0-9a-f]{64} [0-9]+ (diffusion_models|text_encoders|vae|loras)/' "$DOWNLOAD")" -eq 15 ]] \
  || fail "Krea manifest must contain exactly 15 pinned artifacts"

# Activation is explicit and rollback-aware; Comfy stays on GPU1, Muse on GPU0.
contains "$ACTIVATE" "mapfile -t prior_running"
contains "$ACTIVATE" 'comfy_was_active=0'
contains "$ACTIVATE" 'trap rollback ERR INT TERM'
contains "$ACTIVATE" 'sudo systemctl stop comfyui.service'
contains "$ACTIVATE" 'if [ "$comfy_was_active" -eq 1 ]; then'
contains "$ACTIVATE" 'CUDA_VISIBLE_DEVICES=1'
contains "$ACTIVATE" 'GPU_DEVICE=0 PORT=8001 bash "$MUSE_LAUNCHER"'
contains "$ACTIVATE" 'ssh -N -L 8188:127.0.0.1:8188 desktop'

# The runbook distinguishes globally available API use from blocked EU weights.
contains "$RUNBOOK" 'local H3 weights must not be downloaded'
contains "$RUNBOOK" 'MiniMax H3 API is'
contains "$RUNBOOK" 'Krea2ImageNode'
contains "$RUNBOOK" 'Krea2StyleReferenceNode'
contains "$RUNBOOK" 'MinimaxHailuo03ContextIRNode'
contains "$RUNBOOK" 'MinimaxHailuo03RegenerateNode'
contains "$RUNBOOK" 'MiniMaxH3ReferenceToVideo'
contains "$RUNBOOK" 'Muse Glimmer Creative Prompt'
contains "$RUNBOOK" 'ComfyUI-Manager'
contains "$RUNBOOK" 'manual human review'
contains "$H3_RUNBOOK" 'comfyui-krea2-minimax-h3-muse-runbook.md'

printf 'PASS: Nix-managed ComfyUI + Krea 2 + MiniMax H3 + Muse contract is internally consistent\n'
