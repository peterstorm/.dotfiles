#!/usr/bin/env bash
# Static and pure-function contract for the Muse Character Sheet workflows.
# shellcheck disable=SC2016 # Assertions intentionally match literal source text.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
MODULE="$ROOT/machines/desktop/comfyui.nix"
BUILDER="$ROOT/scripts/comfyui/build-muse-character-sheet-workflows.sh"
DOWNLOADER="$ROOT/scripts/comfyui/download-muse-character-sheet-models.sh"
RUNBOOK="$ROOT/docs/runbooks/muse-character-sheet-workflows.md"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

contains() {
  local file=$1 needle=$2
  grep -Fq -- "$needle" "$file" || fail "$file does not contain: $needle"
}

absent() {
  local file=$1 needle=$2
  if grep -Fq -- "$needle" "$file"; then
    fail "$file must not contain: $needle"
  fi
}

for file in "$MODULE" "$BUILDER" "$DOWNLOADER" "$RUNBOOK"; do
  [[ -f "$file" ]] || fail "missing $file"
done
[[ -x "$BUILDER" ]] || fail "builder is not executable"
[[ -x "$DOWNLOADER" ]] || fail "downloader is not executable"
bash -n "$BUILDER"
bash -n "$DOWNLOADER"
nix-instantiate --parse "$MODULE" >/dev/null

# --- Nix module wiring ---
contains "$MODULE" 'museCharacterSheetWorkflows ='
contains "$MODULE" 'muse_sheet_klein_dir="$user_workflows/muse-character-sheet-klein-bf16"'
contains "$MODULE" 'muse_sheet_krea2_dir="$user_workflows/muse-character-sheet-krea2-bf16"'
contains "$MODULE" 'muse_sheet_klein_staging="$user_workflows/.muse-character-sheet-klein-bf16.new"'
contains "$MODULE" 'muse_sheet_krea2_staging="$user_workflows/.muse-character-sheet-krea2-bf16.new"'
contains "$MODULE" 'for source in ${museCharacterSheetWorkflows}/workflows/01*.json'
contains "$MODULE" 'for source in ${museCharacterSheetWorkflows}/workflows/02*.json'
contains "$MODULE" 'install -m 0600 "$source" "$muse_sheet_klein_staging/$(basename "$source")"'
contains "$MODULE" 'install -m 0600 "$source" "$muse_sheet_krea2_staging/$(basename "$source")"'
contains "$MODULE" 'verify_versioned_workflow_install "$muse_sheet_klein_staging" "$muse_sheet_klein_dir"'
contains "$MODULE" 'verify_versioned_workflow_install "$muse_sheet_krea2_staging" "$muse_sheet_krea2_dir"'
contains "$MODULE" 'install_versioned_workflow_dir "$muse_sheet_klein_staging" "$muse_sheet_klein_dir"'
contains "$MODULE" 'install_versioned_workflow_dir "$muse_sheet_krea2_staging" "$muse_sheet_krea2_dir"'
absent "$MODULE" 'mv "$muse_sheet_klein_staging" "$muse_sheet_klein_dir"'
absent "$MODULE" 'mv "$muse_sheet_krea2_staging" "$muse_sheet_krea2_dir"'
contains "$MODULE" 'downloadMuseCharacterSheetModels = pkgs.writeShellApplication'
contains "$MODULE" 'name = "download-muse-character-sheet-models"'
contains "$MODULE" 'text = builtins.readFile ../../scripts/comfyui/download-muse-character-sheet-models.sh;'

# Node pins (all seven custom nodes plus deps)
contains "$MODULE" 'ln -s ${museCharacterSheetKleinNode}'
contains "$MODULE" 'ln -s ${museCharacterSheetNode}'
contains "$MODULE" 'ln -s ${museModelLoaderNode}'
contains "$MODULE" 'ln -s ${rmbgNode}'
contains "$MODULE" 'ln -s ${krea2NagNode}'
contains "$MODULE" 'ln -s ${memoryCleanupNode}'
contains "$MODULE" 'ln -s ${impactPackNode}'
contains "$MODULE" 'ln -s ${impactSubpackNode}'
contains "$MODULE" '"ultralytics"'

# The downloader owns model installation; nothing in the module downloads at runtime.
absent "$MODULE" 'download-muse-character-sheet-models.sh && curl'

# --- Builder: BF16 substitutions and immutable workflow filenames ---
contains "$BUILDER" 'klein_full="$output_dir/01 Muse Character Sheet Klein - Maximum Quality BF16.json"'
contains "$BUILDER" 'krea2_full="$output_dir/02 Muse Character Sheet Krea2 - Maximum Quality BF16.json"'
contains "$BUILDER" '"flux-2-klein-9b-bf16.safetensors"'
contains "$BUILDER" '"qwen_3_8b_bf16.safetensors"'
contains "$BUILDER" '"krea2_turbo_bf16.safetensors"'
contains "$BUILDER" '"qwen3vl_4b_bf16.safetensors"'
contains "$BUILDER" 'krea2_identity_edit_v1_2.safetensors'
contains "$BUILDER" 'Maximum Quality'
contains "$BUILDER" 'kv_cache'
# The video's low-quant selectors must not survive the adaptation: the builder
# self-checks the built output and refuses any forbidden selector or path.
contains "$BUILDER" 'forbidden lower-precision selector, Windows LoRA path, or mutable link in the Muse Character Sheet workflows'

# --- Downloader: checksum-verified atomic profile ---
contains "$DOWNLOADER" 'PROFILE_REV="muse-character-sheet-models-v1"'
contains "$DOWNLOADER" 'RMBG/RMBG-2.0/model.safetensors'
contains "$DOWNLOADER" 'loras/Krea2/Detailer-KREA2.safetensors'
contains "$DOWNLOADER" 'loras/Krea2/krea2filterbypass3.safetensors'
contains "$DOWNLOADER" 'ultralytics/bbox/face_yolov8m.pt'
contains "$DOWNLOADER" 'ultralytics/bbox/hand_yolov8s.pt'
contains "$DOWNLOADER" 'ultralytics/segm/person_yolov8m-seg.pt'
contains "$DOWNLOADER" 'MUSE_SHEET_ACCEPT_RMBG_LICENSE'
contains "$DOWNLOADER" 'MUSE_CHARACTER_SHEET_MODELS_READY'

# --- Runbook documents the installed state ---
contains "$RUNBOOK" 'muse-character-sheet-klein-bf16'
contains "$RUNBOOK" 'muse-character-sheet-krea2-bf16'
contains "$RUNBOOK" 'MUSE_SHEET_ACCEPT_RMBG_LICENSE=yes download-muse-character-sheet-models'

printf 'muse-character-sheet-workflows contract: OK\n'
