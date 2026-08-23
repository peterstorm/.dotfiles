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
WORKFLOW_BUILDER="$ROOT/scripts/comfyui/build-krea2-composed-workflows.py"
CONTEST_BUILDER="$ROOT/scripts/comfyui/build-contest-production-workflows.py"
CONTEST_BUILDER_TEST="$ROOT/tests/test_contest_workflow_builder.py"
H3_DOWNLOAD="$ROOT/scripts/comfyui/download-minimax-h3-models.sh"
H3_PHASE="$ROOT/scripts/comfyui/h3-model-phase.sh"
ACTIVATE="$ROOT/scripts/comfyui/activate-creative-stack.sh"
RUNBOOK="$ROOT/docs/runbooks/comfyui-krea2-minimax-h3-muse-runbook.md"
H3_RUNBOOK="$ROOT/docs/runbooks/local-ai-video-script-runbook.md"
TRANSITION_TEST="$ROOT/tests/creative-stack-transitions-contract.sh"
DOWNLOAD_TEST="$ROOT/tests/model-download-verification-contract.sh"
H3_PHASE_TEST="$ROOT/tests/h3-model-phase-contract.sh"

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

for file in "$MODULE" "$DESKTOP" "$NODE" "$NODE_TEST" "$DOWNLOAD" "$KLEIN_DOWNLOAD" "$WORKFLOW_BUILDER" "$CONTEST_BUILDER" "$CONTEST_BUILDER_TEST" "$H3_DOWNLOAD" "$H3_PHASE" "$ACTIVATE" "$RUNBOOK" "$H3_RUNBOOK" "$TRANSITION_TEST" "$DOWNLOAD_TEST" "$H3_PHASE_TEST"; do
  [[ -f "$file" ]] || fail "missing $file"
done
for file in "$NODE_TEST" "$DOWNLOAD" "$KLEIN_DOWNLOAD" "$WORKFLOW_BUILDER" "$CONTEST_BUILDER" "$CONTEST_BUILDER_TEST" "$H3_DOWNLOAD" "$H3_PHASE" "$ACTIVATE" "$TRANSITION_TEST" "$DOWNLOAD_TEST" "$H3_PHASE_TEST"; do
  [[ -x "$file" ]] || fail "$file is not executable"
done
bash -n "$DOWNLOAD"
bash -n "$KLEIN_DOWNLOAD"
bash -n "$H3_DOWNLOAD"
bash -n "$H3_PHASE"
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
contains "$MODULE" 'rev = "a01434a0d7a77eba1899116ce2b52ffab5584e91";'
contains "$MODULE" 'hash = "sha256-UuDjX2neQkFcGvL9V6nXSSTYfyiu9VhgmuX9/EySo5M=";'
contains "$MODULE" 'module.krea2t_enhancer_wrapper('
contains "$MODULE" 'assert received_args == args'
contains "$MODULE" 'assert received_kwargs == {"marker": marker}'
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
contains "$MODULE" 'minimax-h3-production-bf16-workflows'
contains "$MODULE" '01 MiniMax H3 BF16 FL2VA - First Frame Production.json'
contains "$MODULE" '02 MiniMax H3 BF16 REF2VA - Character References Production.json'
contains "$MODULE" 'h3-model-phase prepare fl2va'
contains "$MODULE" 'h3-model-phase prepare ref2va'
contains "$MODULE" 'forbidden Krea, practical H3, Turbo, mutable link, or Manager dependency'
contains "$MODULE" 'h3ModelPhase'
contains "$MODULE" 'krea2-single-view-character-bf16-workflow'
contains "$MODULE" 'build-krea2-composed-workflows.py'
contains "$MODULE" 'Krea 2 Single-View Character + Optional Realism and FLUX.2 Klein 9B BF16.json'
contains "$MODULE" 'Krea 2 Three-Panel Character Sheet BF16.json'
contains "$MODULE" 'krea2-max-quality-bf16-workflows'
contains "$MODULE" '01 Krea 2 RAW BF16 - Maximum Quality Text to Image.json'
contains "$MODULE" '02 Krea 2 RAW BF16 - Maximum Quality Single-View Identity.json'
contains "$MODULE" '03 Krea 2 RAW BF16 - Maximum Quality Three-Panel Identity.json'
contains "$MODULE" '04 Krea 2 RAW BF16 to FLUX.2 Klein 9B BF16 - Maximum Quality.json'
contains "$MODULE" 'contest-production-bf16-workflows'
contains "$MODULE" 'build-contest-production-workflows.py'
contains "$CONTEST_BUILDER" '21 H3 REF2VA Character and World References - BF16 Production.json'
contains "$MODULE" 'contest_dir="$user_workflows/contest-production-bf16"'
contains "$MODULE" 'contest_staging="$user_workflows/.contest-production-bf16.new"'
contains "$MODULE" 'for source in ${contestProductionWorkflows}/workflows/*.json; do'
contains "$MODULE" 'test "$(find "$out/workflows" -type f -name '\''*.json'\'' | wc -l)" -eq 21'
contains "$MODULE" '--single-view "$identity"'
contains "$MODULE" '--three-panel "$identity"'
contains "$MODULE" '--quality-tier raw'
contains "$MODULE" '"krea2_raw_bf16.safetensors"'
contains "$MODULE" '.widgets_values[2]) = 52'
contains "$MODULE" '.widgets_values[3]) = 3.5'
contains "$MODULE" 'krea_max_dir="$user_workflows/krea2-max-quality-bf16"'
contains "$MODULE" 'krea_max_staging="$user_workflows/.krea2-max-quality-bf16.new"'
contains "$MODULE" 'for source in ${kreaMaxQualityWorkflows}/workflows/*.json; do'
contains "$MODULE" 'test "$(find "$out/workflows" -type f -name '\''*.json'\'' | wc -l)" -eq 2'
contains "$MODULE" 'krea2/krea2_identity_edit_v1_2.safetensors'
contains "$MODULE" 'OPTIONAL realism — both LoRAs bypassed by default'
contains "$MODULE" 'Identity QA — reject drift before approving'
contains "$MODULE" 'forbidden lower-precision selector, credential, mutable link, or inactive dependency'
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
contains "$MODULE" '3d. Krea 2 Text to Image + Prompt Enhancer + FLUX.2 Klein Realism - Abliterated BF16.json'
contains "$MODULE" '--prompt-enhancer "$prompt_enhancer"'
contains "$MODULE" 'huihui_qwen3vl_4b_abliterated_bf16.safetensors'
contains "$MODULE" 'fp8|int8|rgthree|resolve/main|tree/main|uncensored|unrestricted|krea2RealVae'
contains "$MODULE" 'test "$(${pkgs.findutils}/bin/find "$out/workflows" -type f -name '\''*.json'\'' | wc -l)" -eq 12'
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
contains "$MODULE" 'character_dir="$user_workflows/krea2-character-sheet-bf16"'
contains "$MODULE" 'h3_production_dir="$user_workflows/minimax-h3-production-bf16"'
contains "$MODULE" 'elite_dir="$user_workflows/creative-suite"'
contains "$MODULE" 'ep24_staging="$user_workflows/.pixaroma-ep24-krea2-bf16.new"'
contains "$MODULE" 'ep29_staging="$user_workflows/.pixaroma-ep29-h3-bf16.new"'
contains "$MODULE" 'ep30_staging="$user_workflows/.pixaroma-ep30.new"'
contains "$MODULE" 'klein_staging="$user_workflows/.krea2-flux2-klein9b-bf16.new"'
contains "$MODULE" 'character_staging="$user_workflows/.krea2-character-sheet-bf16.new"'
contains "$MODULE" 'h3_production_staging="$user_workflows/.minimax-h3-production-bf16.new"'
contains "$MODULE" 'elite_staging="$user_workflows/.creative-suite.new"'
contains "$MODULE" '"$ep24_dir" "$ep29_dir" "$ep30_dir" "$klein_dir" "$character_dir"'
contains "$MODULE" '"$h3_production_dir" "$elite_dir"'
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
contains "$DOWNLOAD" 'krea2_raw_bf16.safetensors'
contains "$DOWNLOAD" 'f99bb0ff8e362b77342bc4994e0c50906fe7ef7074864b181b7d48d2fa6d03d7 26283332608'
contains "$DOWNLOAD" 'krea2_turbo_bf16.safetensors'
contains "$DOWNLOAD" 'krea2_turbo_int8_convrot.safetensors'
contains "$DOWNLOAD" 'qwen3vl_4b_bf16.safetensors'
contains "$DOWNLOAD" 'qwen3vl_4b_fp8_scaled.safetensors'
contains "$DOWNLOAD" 'krea2_style_reference.safetensors'
contains "$DOWNLOAD" 'krea2_identity_edit_v1_2.safetensors'
contains "$DOWNLOAD" 'krea_outfittransfer.safetensors'
contains "$DOWNLOAD" 'qwen3-vl-8b-heretic-1.3.0_fp8_e4m3fn.safetensors'
contains "$DOWNLOAD" '1fb1c78533a944ceb7a48c55b16b7a7290ed671ee666f8bd42e01c2da5ffbff5 17534334584'
contains "$DOWNLOAD" 'text_encoders/qwen3-vl-8b-heretic-1.3.0_bf16.safetensors'
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
contains "$DOWNLOAD" 'HF_TOKEN_PATH="$token_file"'
contains "$DOWNLOAD" 'Hugging Face token file must not be group/world-accessible'

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

# The character-sheet workflow is a pure merge of immutable sources with exact defaults.
contains "$WORKFLOW_BUILDER" 'IDENTITY_REMOVE_NODES = {163, 223}'
contains "$WORKFLOW_BUILDER" 'krea2_turbo_bf16.safetensors'
contains "$WORKFLOW_BUILDER" 'qwen3vl_4b_bf16.safetensors'
contains "$WORKFLOW_BUILDER" 'krea2/krea2_identity_edit_v1_2.safetensors'
contains "$WORKFLOW_BUILDER" 'ultra_real_krea2_v2_bf16.safetensors", 0.6'
contains "$WORKFLOW_BUILDER" 'famegrid_standard_krea2_bf16.safetensors", 0.65'
contains "$WORKFLOW_BUILDER" 'flux-2-klein-9b-bf16.safetensors'
contains "$WORKFLOW_BUILDER" 'qwen_3_8b_bf16.safetensors'
contains "$WORKFLOW_BUILDER" 'QualityTier = Literal["turbo", "raw"]'
contains "$WORKFLOW_BUILDER" '"krea2_raw_bf16.safetensors"'
contains "$WORKFLOW_BUILDER" 'steps = 20 if quality_tier == "raw" else 10'
contains "$WORKFLOW_BUILDER" 'cfg = 3 if quality_tier == "raw" else 1'
contains "$WORKFLOW_BUILDER" 'sampler_name = "euler" if quality_tier == "raw" else "er_sde"'
contains "$WORKFLOW_BUILDER" 'removed_nodes.add(207)  # Krea2T enhancer is Turbo-specific.'
contains "$WORKFLOW_BUILDER" 'detail[141]["widgets_values"] = ["simple", steps, 1]'
contains "$WORKFLOW_BUILDER" 'detail[139]["widgets_values"] = [True, 530887432637999, "randomize", cfg]'
contains "$WORKFLOW_BUILDER" 'SINGLE_VIEW_PROMPT = ('
contains "$WORKFLOW_BUILDER" 'front view, three-quarter view, additional subjects, duplicate views, panels'
contains "$WORKFLOW_BUILDER" 'STYLE_PRESERVING_REFINEMENT_PROMPT = ('
contains "$WORKFLOW_BUILDER" 'Do not photorealize, stylize, redesign, beautify, duplicate'
contains "$WORKFLOW_BUILDER" 'identity_nodes[232]["widgets_values"][0] = 1'
contains "$WORKFLOW_BUILDER" 'slider_state["sliders"][0]["value"] = 1'
contains "$WORKFLOW_BUILDER" 'source_state = json.loads(identity_nodes[226]["properties"]["loadImagePixState"])'
contains "$WORKFLOW_BUILDER" '"ratio_preset": "1:1"'
contains "$WORKFLOW_BUILDER" '"ratio": "1:1", "w": 1024, "h": 1024'
contains "$WORKFLOW_BUILDER" 'identity_nodes[232], "target_latent", "LATENT"'
contains "$WORKFLOW_BUILDER" 'flux[46]["mode"] = 2'
contains "$WORKFLOW_BUILDER" 'flux[96]["mode"] = 2'
contains "$WORKFLOW_BUILDER" 'add_link(graph, 65, 0, 96, 0, "IMAGE")'
contains "$WORKFLOW_BUILDER" 'def rebuild_port_links(graph: Graph) -> None:'
contains "$WORKFLOW_BUILDER" 'def build_single_view_character_workflow('
contains "$WORKFLOW_BUILDER" 'def validate_single_view_character_graph('
contains "$WORKFLOW_BUILDER" 'def build_three_panel_character_sheet_workflow('
contains "$WORKFLOW_BUILDER" 'def validate_three_panel_character_sheet_graph('
contains "$WORKFLOW_BUILDER" 'THREE_PANEL_SHEET_PROMPT = ('
contains "$WORKFLOW_BUILDER" 'FULL-BODY REAR: complete direct back view turned 180'
contains "$WORKFLOW_BUILDER" 'MAGNIFIED FACE CLOSE-UP ONLY: a dramatically tighter and'
contains "$WORKFLOW_BUILDER" 'index[224]["widgets_values"][1] = 1024'
contains "$WORKFLOW_BUILDER" 'index[228]["widgets_values"][1] = 1024'
contains "$WORKFLOW_BUILDER" 'index[232]["widgets_values"][0] = 1'
contains "$WORKFLOW_BUILDER" 'VAE-encode approved identity reference'
contains "$WORKFLOW_BUILDER" 'The approved image must feed both trained identity channels'
contains "$WORKFLOW_BUILDER" '(226, 0, 233, 0)'
contains "$WORKFLOW_BUILDER" '(233, 0, 232, 1)'
contains "$WORKFLOW_BUILDER" '(226, 0, 232, 5)'
contains "$WORKFLOW_BUILDER" '(162, 0, 139, 5)'
contains "$WORKFLOW_BUILDER" 'the reference must provide tokens, never sampler initialization'
contains "$WORKFLOW_BUILDER" 'source.add_argument("--single-view", type=Path)'
contains "$WORKFLOW_BUILDER" 'source.add_argument("--three-panel", type=Path)'
contains "$WORKFLOW_BUILDER" 'def build_prompt_enhancer_refinement_workflow('
contains "$WORKFLOW_BUILDER" 'source.add_argument("--prompt-enhancer", type=Path)'
contains "$WORKFLOW_BUILDER" 'PROMPT_AUTHOR_ENCODER = "qwen3-vl-8b-heretic-1.3.0_bf16.safetensors"'
contains "$WORKFLOW_BUILDER" 'Prompt author only — BF16 Qwen3-VL-8B Heretic'
contains "$WORKFLOW_BUILDER" 'link[1:5] == [218, 0, 213, 0]'
contains "$WORKFLOW_BUILDER" '8B Heretic encoder must never feed Krea conditioning'
contains "$WORKFLOW_BUILDER" 'Do not add, remove, redesign, or beautify anything.'
contains "$WORKFLOW_BUILDER" 'link[1:5] == [164, 0, 56, 0]'
contains "$WORKFLOW_BUILDER" 'FLUX refinement output is not connected to its save node'
contains "$WORKFLOW_BUILDER" 'raise ValueError("duplicate node id")'
contains "$WORKFLOW_BUILDER" 'raise ValueError("duplicate link id")'

# The contest pack maps prompt skills onto audited local BF16 graphs without
# importing the untrusted skills or pretending unsupported cloud tools are local.
contains "$CONTEST_BUILDER" 'class IdentityVariant:'
contains "$CONTEST_BUILDER" 'def build_t2i_variant('
contains "$CONTEST_BUILDER" 'def build_identity_variant('
contains "$CONTEST_BUILDER" 'def build_sheet_variant('
contains "$CONTEST_BUILDER" 'def build_character_world_variant('
contains "$CONTEST_BUILDER" 'def build_outfit_transfer_variant('
contains "$CONTEST_BUILDER" 'krea2/krea_outfittransfer.safetensors'
contains "$CONTEST_BUILDER" 'def build_klein_finish_variant('
contains "$CONTEST_BUILDER" 'def build_h3_t2v_variant('
contains "$CONTEST_BUILDER" 'def build_h3_fl2va_variant('
contains "$CONTEST_BUILDER" 'def build_h3_ref_variant('
contains "$CONTEST_BUILDER" 'if len(workflows) != 21:'
contains "$CONTEST_BUILDER" 'pipeline["widgets_values"][1] = False'
contains "$CONTEST_BUILDER" 'pipeline["widgets_values"][7] = False'
contains "$CONTEST_BUILDER" 'index[232]["widgets_values"][0] = 1'
contains "$CONTEST_BUILDER" 'index[224]["widgets_values"][1] = 1024'
contains "$CONTEST_BUILDER" 'index[228]["widgets_values"][1] = 1024'
contains "$CONTEST_BUILDER" 'H3_FL2VA_LAST_PROMPT'
contains "$CONTEST_BUILDER" 'add_link(graph, 500, 0, 105, 1, "IMAGE")'
contains "$CONTEST_BUILDER" 'strip_model_metadata(graph)'
contains "$CONTEST_BUILDER" 'forbidden selectors or dependencies'
"$CONTEST_BUILDER_TEST"

[[ "$(grep -Ec '^[0-9a-f]{64} [0-9]+ (diffusion_models|text_encoders|vae|loras)/' "$DOWNLOAD")" -eq 16 ]] \
  || fail "Krea base manifest must contain exactly 16 pinned artifacts"
[[ "$(grep -Ec '^[0-9a-f]{64} [0-9]+ \$[A-Z0-9_]+_REPO \$[A-Z0-9_]+_REV ' "$DOWNLOAD")" -eq 5 ]] \
  || fail "Episode 24/30 auxiliary manifest must contain exactly 5 pinned artifacts"

# H3 phase control is loopback-only, queue-aware, native, and behaviorally verified.
contains "$H3_PHASE" 'http://127.0.0.1:8188'
contains "$H3_PHASE" 'COMFYUI_URL must use loopback HTTP'
contains "$H3_PHASE" 'refusing model release while ComfyUI is busy'
contains "$H3_PHASE" '--data '\''{"unload_models":true,"free_memory":true}'\'''
contains "$H3_PHASE" 'H3_PHASE_READY family=%s; queue only the matching BF16 workflow'
contains "$H3_PHASE" 'H3_PHASE_RELEASED family=none'
absent "$H3_PHASE" '/interrupt'
"$H3_PHASE_TEST"

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
contains "$RUNBOOK" '**110 user workflows:**'
contains "$RUNBOOK" 'krea2-max-quality-bf16'
contains "$RUNBOOK" 'contest-production-bf16'
contains "$RUNBOOK" '21 purpose-built contest workflows'
contains "$RUNBOOK" 'Picture 1 = character'
contains "$RUNBOOK" 'Picture 1 = opening'
contains "$RUNBOOK" 'prompt expansion and style LoRA disabled'
contains "$RUNBOOK" 'video upscaler; the curated SeedVR2 INT8 utilities'
contains "$RUNBOOK" 'eligibility, submission dates, duration, licensing, disclosure'
contains "$RUNBOOK" 'krea2_raw_bf16.safetensors'
contains "$RUNBOOK" '52 steps and CFG 3.5'
contains "$RUNBOOK" '3d. Krea 2 Text to Image + Prompt Enhancer + FLUX.2 Klein Realism - Abliterated BF16'
contains "$RUNBOOK" 'full-BF16 Qwen3-VL-8B Heretic feeds only `TextGenerate`'
contains "$RUNBOOK" 'Krea requires twelve 2560-wide hidden-layer outputs'
contains "$RUNBOOK" 'krea2-flux2-klein9b-bf16'
contains "$RUNBOOK" 'krea2-character-sheet-bf16'
contains "$RUNBOOK" 'Krea 2 Single-View Character + Optional Realism and FLUX.2 Klein 9B BF16'
contains "$RUNBOOK" 'Krea 2 Three-Panel Character Sheet BF16'
contains "$RUNBOOK" 'one native RAW Krea pass'
contains "$RUNBOOK" 'both realism LoRAs bypassed'
contains "$RUNBOOK" '`ref_boost=1`'
contains "$RUNBOOK" 'source-panel outpainting'
contains "$RUNBOOK" 'minimax-h3-production-bf16'
contains "$RUNBOOK" 'h3-model-phase prepare fl2va'
contains "$RUNBOOK" 'h3-model-phase prepare ref2va'
contains "$RUNBOOK" 'There is intentionally no in-graph unload node'
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
contains "$RUNBOOK" 'Blackfrost-AI/Muse-Glimmer-30B-Abliterated-BF16'
contains "$RUNBOOK" '1b489c23b583d609b6c17b00e1a877d1faac1ee2'
contains "$RUNBOOK" 'full BF16'
contains "$RUNBOOK" 'ComfyUI-Manager'
contains "$RUNBOOK" 'manual human review'
contains "$H3_RUNBOOK" 'comfyui-krea2-minimax-h3-muse-runbook.md'

"$TRANSITION_TEST"
"$DOWNLOAD_TEST"

printf 'PASS: Nix-managed ComfyUI + Krea 2 + MiniMax H3 + Muse contract is internally consistent\n'
