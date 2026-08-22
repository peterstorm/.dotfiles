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
KLEIN_DOWNLOAD="$ROOT/scripts/comfyui/download-krea2-flux-klein-models.sh"
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

for file in "$MODULE" "$DESKTOP" "$NODE" "$NODE_TEST" "$DOWNLOAD" "$KLEIN_DOWNLOAD" "$H3_DOWNLOAD" "$ACTIVATE" "$RUNBOOK" "$H3_RUNBOOK" "$TRANSITION_TEST" "$DOWNLOAD_TEST"; do
  [[ -f "$file" ]] || fail "missing $file"
done
for file in "$NODE_TEST" "$DOWNLOAD" "$KLEIN_DOWNLOAD" "$H3_DOWNLOAD" "$ACTIVATE" "$TRANSITION_TEST" "$DOWNLOAD_TEST"; do
  [[ -x "$file" ]] || fail "$file is not executable"
done
bash -n "$DOWNLOAD"
bash -n "$KLEIN_DOWNLOAD"
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
contains "$MODULE" 'declarative_nodes.custom_nodes = toString declarativeNodes;'
contains "$MODULE" 'rev = "bdfa8b267fdb13730868d435b277dcfe696ec083";'
contains "$MODULE" 'rev = "cf8895005540680306cd46e1faaf75f8902db794";'
contains "$MODULE" 'rev = "c1aaee4f6a41a69563eab50e51cd1ef7347f22e9";'
contains "$MODULE" 'rev = "3394e44afea04ed0188fb37b21f0d9952469766b";'
contains "$MODULE" 'rev = "3f20054214fec9f9234fd3841ae6f1e4287948f6";'
contains "$MODULE" 'sha256-Krz3Jke8aQyFkmFkS2EwN9/HHNbCdVUZhh1lA89///I='
contains "$MODULE" 'krea2-flux2-klein9b-bf16-workflow'
contains "$MODULE" 'flux-2-klein-9b-bf16.safetensors'
contains "$MODULE" 'qwen_3_8b_bf16.safetensors'
contains "$MODULE" 'famegrid_standard_krea2_bf16.safetensors'
contains "$MODULE" 'ultra_real_krea2_v2_bf16.safetensors'
contains "$MODULE" 'DetailDaemonSamplerNode'
contains "$MODULE" 'Rh-Comfy-Auth'
contains "$MODULE" 'Ep24%20Workflows.zip'
contains "$MODULE" 'sha256-aHuDeJ6dpP3bcTR1FOLyVaV+WYv99f6vT5VhUjBq8nQ='
contains "$MODULE" 'pixaroma-ep24-krea2-bf16-workflows'
contains "$MODULE" '1a. Krea 2 Text to Image - Simple.json'
contains "$MODULE" '2d. Krea 2 Text to Image - 2K.json'
contains "$MODULE" 'test "$(${pkgs.findutils}/bin/find "$source_root" -type f -name '\''*.json'\'' | wc -l)" -eq 11'
contains "$MODULE" 'test "$(${pkgs.findutils}/bin/find "$source_root" -type f -name '\''3u.*.json'\'' | wc -l)" -eq 3'
contains "$MODULE" '"Krea 2 Style LoRA (core)"'
contains "$MODULE" '"LoraLoaderModelOnly"'
contains "$MODULE" '"krea2_kidsdrawing.safetensors", "krea2_vintagetarot.safetensors"'
contains "$MODULE" '3a. Krea 2 Text to Image - 2K - Abliterated BF16.json'
contains "$MODULE" '3b. Krea 2 Text to Image + Extra Pass + Prompt Enhancer - Abliterated BF16.json'
contains "$MODULE" '3c. Krea 2 Text to Image + Prompt Enhancer - Abliterated BF16.json'
contains "$MODULE" 'huihui_qwen3vl_4b_abliterated_bf16.safetensors'
contains "$MODULE" 'fp8|int8|rgthree|resolve/main|tree/main|uncensored|unrestricted|krea2RealVae'
contains "$MODULE" 'test "$(${pkgs.findutils}/bin/find "$out/workflows" -type f -name '\''*.json'\'' | wc -l)" -eq 11'
contains "$MODULE" 'Ep29%20Workflows.zip'
contains "$MODULE" 'sha256-DV0WoYk/S9zdMEKOWaCfj5Uru0YDpzea6XLLTwcZWbM='
contains "$MODULE" 'Ep30%20Workflows.zip'
contains "$MODULE" 'sha256-Rvy8DmMPWk7gKL3YQdBPJsqXylOMPDPSkjFZ2bH1l5k='
contains "$MODULE" 'test "$(find "$out/workflows" -type f -name '\''*.json'\'' | wc -l)" -eq 8'
contains "$MODULE" 'test "$(find "$out/media" -type f | wc -l)" -eq 11'
contains "$MODULE" '"minimax_h3_fl2va_bf16.safetensors"'
contains "$MODULE" '"minimax_h3_ref2va_bf16.safetensors"'
contains "$MODULE" '"qwen3vl_32b_minimax_h3_bf16.safetensors"'
contains "$MODULE" 'select(.type == "KSampler") | .widgets_values[2]) = 50'
contains "$MODULE" '! -path '\''*/Low Vram/*'\'''
contains "$MODULE" '! -path '\''*/4. Generate Image H3 (fl2va)/*'\'''
contains "$MODULE" 'test "$(find "$out/workflows" -type f -name '\''*.json'\'' | wc -l)" -eq 7'
contains "$MODULE" 'test "$(find "$out/media" -type f | wc -l)" -eq 6'
contains "$MODULE" 'grep -RohF '\''krea2\\krea2_turbo_int8_convrot.safetensors'\'''
contains "$MODULE" 'grep -RohF '\''qwen3-vl-4b-heretic_int8.safetensors'\'''
contains "$MODULE" '--replace-warn '\''krea2_turbo_fp8_scaled.safetensors'\'' '\''krea2_turbo_bf16.safetensors'\'''
contains "$MODULE" '--replace-warn '\''qwen3-vl-4b-heretic_int8.safetensors'\'' '\''qwen3vl_4b_bf16.safetensors'\'''
contains "$MODULE" '--replace-warn '\''krea2_turbo_int8_convrot.safetensors'\'' '\''krea2_turbo_bf16.safetensors'\'''
contains "$MODULE" '--replace-warn '\''qwen3-vl-4b-heretic_int8'\'' '\''qwen3vl_4b_bf16'\'''
contains "$MODULE" '--replace-warn '\''>12.2 GB<'\'' '\''>24.5 GB<'\'''
contains "$MODULE" 'resolve/89e9e7a09ee2e5c9331e952063d79b1b8a703280/'
contains "$MODULE" 'resolve/827dab8588b6cb261cf9ae580c417bc068740b7f/'
contains "$MODULE" 'resolve/28dc0129b4c7c16304bc2ed3697c9437ae8ac2f3/'
contains "$MODULE" 'qwen3-vl-8b-heretic-1.3.0-int8convrot|craftingmod|resolve/main|tree/main'
contains "$MODULE" 'pythonPackages.hf-xet'
contains "$MODULE" 'modelSubdirectories = ['
contains "$MODULE" 'modelPathEntries = builtins.listToAttrs ('
contains "$MODULE" '// modelPathEntries;'
contains "$MODULE" '++ map (directory: "d /models/comfyui/${directory} 0750 peterstorm users - -") modelSubdirectories;'
contains "$MODULE" 'binaryTorchPython.pkgs.comfyui-workflow-templates-json'
contains "$MODULE" 'pkgs.gnugrep'
contains "$MODULE" 'forbidden Episode 24 model, node, or mutable link'
contains "$MODULE" 'forbidden Episode 29 practical selector or unsupported node'
contains "$MODULE" 'forbidden Episode 30 lower-precision selector or mutable link'
absent "$MODULE" '! grep -RqiE'
contains "$MODULE" 'video_minimax_h3_t2v.json video_minimax_h3_bf16_t2v.json'
contains "$MODULE" 'video_minimax_h3_i2v.json video_minimax_h3_bf16_i2v.json'
contains "$MODULE" 'video_minimax_h3_r2v.json video_minimax_h3_bf16_r2v.json'
contains "$MODULE" 'image_krea2_turbo_bf16_image_style_reference.json'
contains "$MODULE" '"krea2_turbo_bf16.safetensors"'
contains "$MODULE" '"qwen3vl_4b_bf16.safetensors"'
contains "$MODULE" 'krea2_turbo_(int8|fp8)|qwen3vl_4b_fp8'
contains "$MODULE" '"minimax_h3_fl2va_bf16.safetensors"'
contains "$MODULE" '"minimax_h3_ref2va_bf16.safetensors"'
contains "$MODULE" '"qwen3vl_32b_minimax_h3_bf16.safetensors"'
contains "$MODULE" 'select(.type? == "BasicScheduler") | .widgets_values[1]) = 50'
contains "$MODULE" 'resolve/e5ea8b4dd7f38f348b138eb0fe29f92c0e367e96/'
contains "$MODULE" 'resolve/dc559027db79c174125df4d827db55cd11178860/'
contains "$MODULE" 'test "$(${pkgs.findutils}/bin/find "$out" -type f -name '\''*.json'\'' | wc -l)" -eq 53'
contains "$MODULE" 'ep24_dir="$user_workflows/pixaroma-ep24-krea2-bf16"'
contains "$MODULE" 'ep29_dir="$user_workflows/pixaroma-ep29-h3-bf16"'
contains "$MODULE" 'ep30_dir="$user_workflows/pixaroma-ep30"'
contains "$MODULE" 'klein_dir="$user_workflows/krea2-flux2-klein9b-bf16"'
contains "$MODULE" 'elite_dir="$user_workflows/creative-suite"'
contains "$MODULE" 'ep24_staging="$user_workflows/.pixaroma-ep24-krea2-bf16.new"'
contains "$MODULE" 'ep29_staging="$user_workflows/.pixaroma-ep29-h3-bf16.new"'
contains "$MODULE" 'ep30_staging="$user_workflows/.pixaroma-ep30.new"'
contains "$MODULE" 'klein_staging="$user_workflows/.krea2-flux2-klein9b-bf16.new"'
contains "$MODULE" 'elite_staging="$user_workflows/.creative-suite.new"'
contains "$MODULE" 'rm -rf "$ep24_dir" "$ep29_dir" "$ep30_dir" "$klein_dir" "$elite_dir"'
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
contains "$DOWNLOAD" 'ABLITERATED_ENCODER_REPO="ahmed22xa/Huihui-Qwen3-VL-4B-Instruct-abliterated-comfy"'
contains "$DOWNLOAD" 'ABLITERATED_ENCODER_REV="6d6fc98f9bfa783dfa4f143804525742cb5dad62"'
contains "$DOWNLOAD" '03590b45adf6a071dd5de231d4e2b697355746e36ce2d9368b4c0587ba014cd2 8875719408'
contains "$DOWNLOAD" 'text_encoders/huihui_qwen3vl_4b_abliterated_bf16.safetensors'
contains "$DOWNLOAD" 'stage_verified_existing'
contains "$DOWNLOAD" 'missing_files'
contains "$DOWNLOAD" 'sha256sum "$file"'
contains "$DOWNLOAD" 'stat -c %s "$file"'
contains "$DOWNLOAD" 'mv -f "$destination.new" "$destination"'

# The video-backed Krea/FLUX profile is BF16, license-gated, immutable, and secret-safe.
contains "$KLEIN_DOWNLOAD" 'FLUX2_KLEIN_ACCEPT_NONCOMMERCIAL_LICENSE'
contains "$KLEIN_DOWNLOAD" 'KREA2_FLUX_LORA_ACCEPT_LICENSES'
contains "$KLEIN_DOWNLOAD" 'black-forest-labs/FLUX.2-klein-9B 92196c8e11f7b6cf2b7493e037d8c5345c559216'
contains "$KLEIN_DOWNLOAD" 'Comfy-Org/flux2-klein-9B 3f62d9d8ae1fec33c6e91453d5c712855b096b55'
contains "$KLEIN_DOWNLOAD" '0975d6b77b5f510b99547d6724a208e36527df654e8f6134f59ece3f9f30da58 18157185168'
contains "$KLEIN_DOWNLOAD" 'f0ff9239d56269ca1d05e5f86da6a79fac111af464955681f11c7ab0ec5ef6c1 16381517176'
contains "$KLEIN_DOWNLOAD" '233a8b1df4b3387f9f2bedaa2099d0e14cc946d1105f732de2a8600310b86f07 228588904'
contains "$KLEIN_DOWNLOAD" '40ce4ebd8af41f985ef7ff0b15c4989eacec155b9975c9649dbce00ba31fed46 228587744'
contains "$KLEIN_DOWNLOAD" 'CIVITAI_TOKEN_FILE'
contains "$KLEIN_DOWNLOAD" 'curl --config "$config"'
contains "$KLEIN_DOWNLOAD" 'mv -f "$destination.new" "$destination"'
if grep -Eq 'hf download .*--token|curl .*token' "$KLEIN_DOWNLOAD"; then
  fail "$KLEIN_DOWNLOAD exposes a credential through process arguments"
fi
[[ "$(grep -Ec '^[0-9a-f]{64} [0-9]+ (diffusion_models|text_encoders|vae|loras)/' "$DOWNLOAD")" -eq 15 ]] \
  || fail "Krea base manifest must contain exactly 15 pinned artifacts"
[[ "$(grep -Ec '^[0-9a-f]{64} [0-9]+ \$[A-Z0-9_]+_REPO \$[A-Z0-9_]+_REV ' "$DOWNLOAD")" -eq 4 ]] \
  || fail "Episode 24/30 auxiliary manifest must contain exactly 4 pinned artifacts"

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
contains "$ACTIVATE" 'prior_running=()'
contains "$ACTIVATE" 'inference_container_running "$container"'
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
contains "$RUNBOOK" 'You do not manually unload the encoder, DiT, and VAEs between nodes'
contains "$RUNBOOK" 'Do not queue Krea and H3 simultaneously on GPU1'
contains "$RUNBOOK" '--data '\''{"unload_models":true,"free_memory":true}'\'''
contains "$RUNBOOK" 'video_minimax_h3_bf16_t2v'
contains "$RUNBOOK" 'video_minimax_h3_bf16_i2v'
contains "$RUNBOOK" 'video_minimax_h3_bf16_r2v'
contains "$RUNBOOK" 'qwen3vl_32b_minimax_h3_bf16.safetensors'
contains "$RUNBOOK" 'Candidate topology; must pass the qualification above'
contains "$RUNBOOK" 'Make a character-driven short film, one scene at a time'
contains "$RUNBOOK" 'Definition present:'
contains "$RUNBOOK" 'Krea 2 + Edit Lora - Character and Background'
contains "$RUNBOOK" '687b83789e9da4fddb71347514e2f255a57e598bfdf5feaf4f956152306af274'
contains "$RUNBOOK" 'pixaroma-ep24-krea2-bf16'
contains "$RUNBOOK" 'eight workflows demonstrated by the video'
contains "$RUNBOOK" 'LoraLoaderModelOnly'
contains "$RUNBOOK" 'three later experimental topologies'
contains "$RUNBOOK" 'huihui_qwen3vl_4b_abliterated_bf16.safetensors'
contains "$RUNBOOK" '8,875,719,408 bytes'
contains "$RUNBOOK" '**80 user workflows:**'
contains "$RUNBOOK" 'krea2-flux2-klein9b-bf16'
contains "$RUNBOOK" 'character-bible.md'
contains "$RUNBOOK" 'desktop-muse/muse-glimmer-30b'
contains "$RUNBOOK" 'compile and render exactly one scene'
contains "$RUNBOOK" 'Do not queue the next scene until this scene is accepted'
contains "$RUNBOOK" 'ffmpeg -f concat -safe 0 -i concat.txt -c copy final.mp4'
contains "$RUNBOOK" 'MiniMax H3 API is'
contains "$RUNBOOK" 'Krea2ImageNode'
contains "$RUNBOOK" 'Krea2StyleReferenceNode'
contains "$RUNBOOK" 'MinimaxHailuo03ContextIRNode'
contains "$RUNBOOK" 'MinimaxHailuo03RegenerateNode'
contains "$RUNBOOK" 'MiniMaxH3ReferenceToVideo'
contains "$RUNBOOK" 'Muse Glimmer Creative Prompt'
contains "$RUNBOOK" '53 curated official workflows'
contains "$RUNBOOK" 'image_krea2_turbo_t2i'
contains "$RUNBOOK" 'image_krea2_turbo_bf16_image_style_reference'
contains "$RUNBOOK" 'no curated or Episode 30 workflow selects them'
contains "$RUNBOOK" 'Do not open the similarly named'
contains "$RUNBOOK" 'lower-precision selectors'
contains "$RUNBOOK" 'sharing a text encoder or VAE does not make a different DiT compatible'
contains "$RUNBOOK" 'Muse-Glimmer-30B-Abliterated-BF16'
contains "$RUNBOOK" 'daf5fab76a0351a583714a92d88ebdb6eb48af35'
contains "$RUNBOOK" 'full BF16'
contains "$RUNBOOK" 'ComfyUI-Manager'
contains "$RUNBOOK" 'manual human review'
contains "$H3_RUNBOOK" 'comfyui-krea2-minimax-h3-muse-runbook.md'

"$TRANSITION_TEST"
"$DOWNLOAD_TEST"

printf 'PASS: Nix-managed ComfyUI + Krea 2 + MiniMax H3 + Muse contract is internally consistent\n'
