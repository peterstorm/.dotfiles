#!/usr/bin/env bash
# Build the workstation BF16 adaptations of the two Muse Character Sheet
# workflows from Machine Delusions' 2CQwma8ZKNQ video (Muse Character Sheet
# Klein + Muse Character Sheet Krea2).
#
# What the jq pass does:
#   * Forces both Muse Model Loader instances to Maximum Quality rather than
#     trusting a hardware probe, replaces their upstream quantized selectors
#     with the workstation checksum-verified BF16 set, and collapses every
#     lower profile to (disabled) - in both the positional widgets and the
#     named-widget mirror, so stale UI metadata cannot resurrect a selector.
#   * Repoints the pinned-memory pool control to "Default (40% of RAM)": the
#     control only ever LOWERS ComfyUI's ceiling, so Andy's 10 GB value would
#     stay stuck for the heavy H3 Director stack in the same ComfyUI session.
#     Default never claims anything and never interferes across workflows.
#   * Pins both sheet nodes' own manual widgets to the same BF16 set, and sets
#     the Klein node's kv_cache to "off": connecting the Muse Model Loader's
#     model_override socket makes "auto" fall back to always-on KV cache, and
#     FluxKVCache is built specifically for the 9B-KV checkpoint (fp8-only
#     upstream) - the plain 9B BF16 checkpoint has no KV-cache support.
#   * Rewrites the Krea2 node's Windows-style LoRA paths to POSIX subfolder
#     paths and the fp32 filter-bypass filename to the downloaded file name.
#   * Resets both nodes' serialized session state (stale creator previews,
#     test edit instructions, and statuses) while keeping the shipped prompts.
#   * Replaces each creator Model Links section with the workstation pinned
#     profile and the custom-node sections with the workstation own.
set -euo pipefail

usage() {
  printf 'Usage: %s --klein-source FILE --director-source FILE --output-dir DIR\n' "$0" >&2
  exit 64
}

klein_source=
director_source=
output_dir=
while (($#)); do
  case "$1" in
    --klein-source)
      [[ $# -ge 2 ]] || usage
      klein_source=$2
      shift 2
      ;;
    --director-source)
      [[ $# -ge 2 ]] || usage
      director_source=$2
      shift 2
      ;;
    --output-dir)
      [[ $# -ge 2 ]] || usage
      output_dir=$2
      shift 2
      ;;
    *) usage ;;
  esac
done

[[ -f "$klein_source" && -f "$director_source" && -n "$output_dir" ]] || usage
mkdir -p "$output_dir"

klein_full="$output_dir/01 Muse Character Sheet Klein - Maximum Quality BF16.json"
krea2_full="$output_dir/02 Muse Character Sheet Krea2 - Maximum Quality BF16.json"

klein_model_note=$'## Workstation Model Links (pinned local profile)\n\nThis adapted graph pins every selector to the workstation checksum-verified BF16 set. Model installation is owned by the local downloaders; nothing here downloads at runtime.\n\n- `diffusion_models/flux-2-klein-9b-bf16.safetensors` - FLUX.2 [klein] plain 9B, full BF16 (the highest-quant checkpoint available; the KV variant only ships fp8)\n- `text_encoders/qwen_3_8b_bf16.safetensors` - full-BF16 Qwen3-8B encoder\n- `vae/flux2-vae.safetensors` - official FLUX.2 VAE\n\nThe Muse Model Loader is forced to Maximum Quality and its pinned-memory control is left at Default, so it never lowers ComfyUI\'s page-locked pool for the heavy H3 Director stack sharing this session. Low VRAM and Balanced stay (disabled), so an automatic hardware probe cannot silently select a lower-quality route.\n\nThe `kv_cache` widget is pinned to `off`. FluxKVCache is a speed optimization built specifically for the 9B-KV checkpoint (fp8-only upstream); the plain 9B has no KV-cache support, and the `auto` detection is filename-based, so a MODEL arriving through the Muse Model Loader\'s model_override socket would fall back to always-on KV. If sheet quality ever differs from the video, the fp8 9B-KV checkpoint can be fetched separately - it is intentionally not part of this maximum-quant profile.\n\nLicensing: FLUX.2 [klein] 9B uses the FLUX Non-Commercial License (https://huggingface.co/black-forest-labs/FLUX.2-klein-9B/blob/main/LICENSE.md) - free for personal research/testing; monetized use needs BFL\'s Commercial Weights License.'

krea2_model_note=$'## Workstation Model Links (pinned local profile)\n\nThis adapted graph pins every selector to the workstation checksum-verified BF16 set. Model installation is owned by the local downloaders; nothing here downloads at runtime.\n\n- `diffusion_models/krea2_turbo_bf16.safetensors` - Krea 2 Turbo (unpruned BF16, replaces the video int8-convrot selector)\n- `text_encoders/qwen3vl_4b_bf16.safetensors` - full-BF16 Qwen3-VL-4B encoder (replaces fp8_scaled)\n- `vae/qwen_image_vae.safetensors` - official Qwen Image VAE\n- `loras/Krea2/krea2_identity_edit_v1_2.safetensors` - official Identity Edit LoRA behind comfyui-krea2edit, strength 1.0\n- `loras/Krea2/krea2filterbypass3.safetensors` - filter-bypass projector patch (the video renames it fp32; the downloaded filename is kept)\n- `loras/Krea2/Detailer-KREA2.safetensors` - the Muse Model Loader lora_3 detailer LoRA, strength 1.0\n\nThe Muse Model Loader is forced to Maximum Quality and its pinned-memory control is left at Default, so it never lowers ComfyUI\'s page-locked pool for the heavy H3 Director stack sharing this session. Low VRAM and Balanced stay (disabled), so an automatic hardware probe cannot silently select a lower-quality route.\n\nThe white-background cleanup runs on RMBG-2.0 (briaai/RMBG-2.0 weights, Apache-2.0 per the pack\'s own model card) and Face Detail uses the Ultralytics COCO-pretrained detector models (AGPL-3.0); both are pinned by the local downloader.'

custom_nodes_note=$'# Download These First - Custom Nodes\n\nThe ComfyUI "Install Missing Custom Nodes" scanner will not catch the internal dependencies below: they are called by the sheet nodes own code at runtime, not wired in as visible boxes, so nothing flags them as missing. All of them are pinned and deployed declaratively by the workstation configuration; nothing to install by hand.\n\n## Required\n\n1. **ComfyUI-RMBG** - the white-background cleanup run on every pose (both sheet nodes). Only the RMBG-2.0 model family is needed; the rest of the pack is trimmed on this workstation.\n2. **ComfyUI-Impact-Pack** + **ComfyUI-Impact-Subpack** - FaceDetailer + UltralyticsDetectorProvider (the Face Detail pass; off in both shipped graphs, works out of the box when enabled).\n3. **comfyui-krea2edit** (Krea2 graph) - image-grounded instruction encoding for Krea 2.\n4. **ComfyUI-Krea2-NAG** (Krea2 graph) - Normalized Attention Guidance for Krea2Edit.\n5. **Muse Model Loader** - the hardware-aware loader feeding both sheet nodes.\n6. **Comfyui-Memory_Cleanup** - the RAM/VRAM cleanup sinks both graphs wire.\n\n## Deliberately omitted\n\nThe rest of ComfyUI-RMBG\'s model families (SAM2/SAM3, Florence2, LaMa, BEN/INSPYRENET) are trimmed from this workstation: only the RMBG-2.0 family the sheet nodes call is deployed. The RMBG-2.0 and detector models are owned by the checksum-verified local downloader.'

# --- Klein workflow ---------------------------------------------------------
jq \
  --arg model_note "$klein_model_note" \
  --arg custom_nodes_note "$custom_nodes_note" '
  .
  # Muse Model Loader: force Maximum Quality rather than trusting a hardware
  # probe, replace that route with the BF16 9B set, and make lower profiles
  # unrepresentable. Both the positional widgets (headers interleaved) and the
  # named-widget mirror are pinned - the mirror prevents stale UI metadata
  # from resurrecting a selector the workstation profile makes illegal.
  | (.nodes[] | select(.type == "MuseModelLoader") | .widgets_values[1]) = "Maximum Quality"
  | (.nodes[] | select(.type == "MuseModelLoader") | .widgets_values[3]) = "Default (40% of RAM)"
  | (.nodes[] | select(.type == "MuseModelLoader") | .widgets_values[5]) = "(disabled)"
  | (.nodes[] | select(.type == "MuseModelLoader") | .widgets_values[6]) = "(disabled)"
  | (.nodes[] | select(.type == "MuseModelLoader") | .widgets_values[7]) =
      "flux-2-klein-9b-bf16.safetensors"
  | (.nodes[] | select(.type == "MuseModelLoader") | .widgets_values[9]) =
      "qwen_3_8b_bf16.safetensors"
  | (.nodes[] | select(.type == "MuseModelLoader") | .widgets_values_named) |= (
      .profile = "Maximum Quality"
      | .pinned_memory_cap = "Default (40% of RAM)"
      | .low_vram_model = "(disabled)"
      | .balanced_model = "(disabled)"
      | .maximum_quality_model = "flux-2-klein-9b-bf16.safetensors"
      | .clip_name = "qwen_3_8b_bf16.safetensors"
    )

  # The sheet node manual widgets: same BF16 set, so whichever path is
  # active (the loader override or the manual widgets) selects the same models.
  # kv_cache is pinned to "off": the loader override socket makes "auto" fall
  # back to always-on KV cache, and the plain 9B BF16 checkpoint has no
  # KV-cache support (the README documents exactly this case for overrides).
  | (.nodes[] | select(.type == "MuseCharacterSheetKlein")
      | .widgets_values[0]) = "flux-2-klein-9b-bf16.safetensors"
  | (.nodes[] | select(.type == "MuseCharacterSheetKlein")
      | .widgets_values[1]) = "qwen_3_8b_bf16.safetensors"
  | (.nodes[] | select(.type == "MuseCharacterSheetKlein")
      | .widgets_values[3]) = "off"
  | (.nodes[] | select(.type == "MuseCharacterSheetKlein")
      | .widgets_values_named) |= (
      .unet_name = "flux-2-klein-9b-bf16.safetensors"
      | .clip_name = "qwen_3_8b_bf16.safetensors"
      | .kv_cache = "off"
    )

  # Reset the creator session state (stale preview files, test edit
  # instructions, statuses) while keeping the shipped seeds/prompts - the JS
  # fills the null previews/editInstructions back in on load, and the node
  # own run() handles every missing key gracefully.
  | (.nodes[] | select(.type == "MuseCharacterSheetKlein")
      | .widgets_values[12]) |= (
      fromjson | del(.previews, .editInstructions, .status)
      | .action = null
      | .seeds = [41001, 41002, 41003, 41004, 41005]
      | tojson
    )
  | (.nodes[] | select(.type == "MuseCharacterSheetKlein")
      | .widgets_values_named.state_json) |= (
      fromjson | del(.previews, .editInstructions, .status)
      | .action = null
      | .seeds = [41001, 41002, 41003, 41004, 41005]
      | tojson
    )

  # The creator Model Links note: keep its description, replace the
  # custom-node section and the model-links section (everything from
  # "## Model Links" to the end, including Model Storage Locations and the
  # kv_cache guidance that moves into the workstation note).
  | walk(
      if type == "string" then
        if contains("## Model Links") then
          (split("## Model Links")[0]
           | split("## ⚠️ Required custom nodes")[0]
           + "## Required custom nodes (workstation)\n\n" + $custom_nodes_note
           + "\n\n## Model Links (workstation pinned profile)\n\n" + $model_note)
        else . end
      else . end
    )
' "$klein_source" >"$klein_full"

# --- Krea2 workflow ---------------------------------------------------------
jq \
  --arg model_note "$krea2_model_note" \
  --arg custom_nodes_note "$custom_nodes_note" '
  .
  # Muse Model Loader: force Maximum Quality, workstation pinned-memory
  # choice, BF16 selectors, POSIX LoRA paths, lower profiles unrepresentable.
  | (.nodes[] | select(.type == "MuseModelLoader") | .widgets_values[1]) = "Maximum Quality"
  | (.nodes[] | select(.type == "MuseModelLoader") | .widgets_values[3]) = "Default (40% of RAM)"
  | (.nodes[] | select(.type == "MuseModelLoader") | .widgets_values[7]) =
      "krea2_turbo_bf16.safetensors"
  | (.nodes[] | select(.type == "MuseModelLoader") | .widgets_values[9]) =
      "qwen3vl_4b_bf16.safetensors"
  | (.nodes[] | select(.type == "MuseModelLoader") | .widgets_values[14]) =
      "Krea2/krea2_identity_edit_v1_2.safetensors"
  | (.nodes[] | select(.type == "MuseModelLoader") | .widgets_values[16]) =
      "Krea2/krea2filterbypass3.safetensors"
  | (.nodes[] | select(.type == "MuseModelLoader") | .widgets_values[18]) =
      "Krea2/Detailer-KREA2.safetensors"
  | (.nodes[] | select(.type == "MuseModelLoader") | .widgets_values_named) |= (
      .profile = "Maximum Quality"
      | .pinned_memory_cap = "Default (40% of RAM)"
      | .maximum_quality_model = "krea2_turbo_bf16.safetensors"
      | .clip_name = "qwen3vl_4b_bf16.safetensors"
      | .lora_1 = "Krea2/krea2_identity_edit_v1_2.safetensors"
      | .lora_2 = "Krea2/krea2filterbypass3.safetensors"
      | .lora_3 = "Krea2/Detailer-KREA2.safetensors"
    )

  # The sheet node manual widgets: same BF16 set and POSIX LoRA paths.
  | (.nodes[] | select(.type == "MuseCharacterSheetDirector")
      | .widgets_values[0]) = "krea2_turbo_bf16.safetensors"
  | (.nodes[] | select(.type == "MuseCharacterSheetDirector")
      | .widgets_values[1]) = "Krea2/krea2_identity_edit_v1_2.safetensors"
  | (.nodes[] | select(.type == "MuseCharacterSheetDirector")
      | .widgets_values[2]) = "Krea2/krea2filterbypass3.safetensors"
  | (.nodes[] | select(.type == "MuseCharacterSheetDirector")
      | .widgets_values[3]) = "qwen3vl_4b_bf16.safetensors"
  | (.nodes[] | select(.type == "MuseCharacterSheetDirector")
      | .widgets_values_named) |= (
      .unet_name = "krea2_turbo_bf16.safetensors"
      | .identity_lora = "Krea2/krea2_identity_edit_v1_2.safetensors"
      | .filter_bypass_lora = "Krea2/krea2filterbypass3.safetensors"
      | .clip_name = "qwen3vl_4b_bf16.safetensors"
    )

  # Reset the creator session state (see the Klein pass for the reasoning).
  | (.nodes[] | select(.type == "MuseCharacterSheetDirector")
      | .widgets_values[15]) |= (
      fromjson | del(.previews, .editInstructions, .status)
      | .action = null
      | .seeds = [41001, 41002, 41003, 41004, 41005]
      | tojson
    )
  | (.nodes[] | select(.type == "MuseCharacterSheetDirector")
      | .widgets_values_named.state_json) |= (
      fromjson | del(.previews, .editInstructions, .status)
      | .action = null
      | .seeds = [41001, 41002, 41003, 41004, 41005]
      | tojson
    )

  # The creator Model Links note: keep its description, replace the
  # custom-node and model-links sections (the Krea2 note has no separate
  # licensing section - its licensing terms travel inside the model note).
  | walk(
      if type == "string" then
        if contains("## Model Links") then
          (split("## Model Links")[0]
           | split("## ⚠️ Required custom nodes")[0]
           + "## Required custom nodes (workstation)\n\n" + $custom_nodes_note
           + "\n\n## Model Links (workstation pinned profile)\n\n" + $model_note)
        else . end
      else . end
    )
' "$director_source" >"$krea2_full"

# --- Topology + selector assertions (fail closed) ---------------------------
jq -e '
  . as $workflow
  | ([.nodes[].id] | length == (unique | length))
  and ([.links[][0]] | length == (unique | length))
  and all(.links[];
    .[1] as $origin_id
    | .[3] as $target_id
    | any($workflow.nodes[]; .id == $origin_id)
      and any($workflow.nodes[]; .id == $target_id))
  and all(.nodes[]; . as $node
    | all($node.inputs[]? | select(.link != null);
        .link as $link_id | any($workflow.links[]; .[0] == $link_id)))
' "$klein_full" "$krea2_full" >/dev/null

jq -e '
  ([.nodes[] | select(.type == "MuseModelLoader")] | length == 1)
  and ([.nodes[] | select(.type == "MuseCharacterSheetKlein")] | length == 1)
  and ([.nodes[] | select(.type == "MuseModelLoader") | .widgets_values[1]]
    == ["Maximum Quality"])
  and ([.nodes[] | select(.type == "MuseModelLoader") | .widgets_values[3]]
    == ["Default (40% of RAM)"])
  and ([.nodes[] | select(.type == "MuseModelLoader") | .widgets_values[5:8]]
    == [["(disabled)", "(disabled)", "flux-2-klein-9b-bf16.safetensors"]])
  and ([.nodes[] | select(.type == "MuseModelLoader") | .widgets_values[9:11]]
    == [["qwen_3_8b_bf16.safetensors", "flux2"]])
  and ([.nodes[] | select(.type == "MuseModelLoader") | .widgets_values_named
      | [.profile, .pinned_memory_cap, .low_vram_model, .balanced_model,
         .maximum_quality_model, .clip_name]]
    == [["Maximum Quality", "Default (40% of RAM)", "(disabled)", "(disabled)",
         "flux-2-klein-9b-bf16.safetensors", "qwen_3_8b_bf16.safetensors"]])
  and ([.nodes[] | select(.type == "MuseCharacterSheetKlein")
      | [.widgets_values[0], .widgets_values[1], .widgets_values[3]]]
    == [["flux-2-klein-9b-bf16.safetensors", "qwen_3_8b_bf16.safetensors", "off"]])
  and ([.nodes[] | select(.type == "MuseCharacterSheetKlein")
      | .widgets_values_named | [.unet_name, .clip_name, .kv_cache]]
    == [["flux-2-klein-9b-bf16.safetensors", "qwen_3_8b_bf16.safetensors", "off"]])
  and ([.nodes[] | select(.type == "MuseCharacterSheetKlein")
      | .widgets_values[12] | fromjson
      | [.seeds, .confirmed, .action]]
    == [[[41001, 41002, 41003, 41004, 41005],
         [false, false, false, false, false],
         null]])
  and ([.nodes[] | select(.type == "MuseCharacterSheetKlein")
      | .widgets_values[12] | fromjson | has("previews")] | all(. == false))
  and ([.nodes[] | select(.type == "MuseCharacterSheetKlein")
      | .widgets_values[12] | fromjson | has("editInstructions")] | all(. == false))
  and ([.nodes[] | select(.type == "MuseModelLoader") | .widgets_values[8:14]]
    == [["CLIP", "qwen_3_8b_bf16.safetensors", "flux2", "VAE",
         "flux2-vae.safetensors", "LoRAs"]])
  and ([.nodes[] | select(.type == "MuseModelLoader") | .widgets_values[14:16]]
    == [["(disabled)", 1]])
' "$klein_full" >/dev/null

jq -e '
  ([.nodes[] | select(.type == "MuseModelLoader")] | length == 1)
  and ([.nodes[] | select(.type == "MuseCharacterSheetDirector")] | length == 1)
  and ([.nodes[] | select(.type == "MuseModelLoader") | .widgets_values[1]]
    == ["Maximum Quality"])
  and ([.nodes[] | select(.type == "MuseModelLoader") | .widgets_values[3]]
    == ["Default (40% of RAM)"])
  and ([.nodes[] | select(.type == "MuseModelLoader") | .widgets_values[5:8]]
    == [["(disabled)", "(disabled)", "krea2_turbo_bf16.safetensors"]])
  and ([.nodes[] | select(.type == "MuseModelLoader") | .widgets_values[9:11]]
    == [["qwen3vl_4b_bf16.safetensors", "krea2"]])
  and ([.nodes[] | select(.type == "MuseModelLoader") | .widgets_values[14:20]]
    == [["Krea2/krea2_identity_edit_v1_2.safetensors", 1,
         "Krea2/krea2filterbypass3.safetensors", 1,
         "Krea2/Detailer-KREA2.safetensors", 1]])
  and ([.nodes[] | select(.type == "MuseModelLoader") | .widgets_values_named
      | [.profile, .pinned_memory_cap, .low_vram_model, .balanced_model,
         .maximum_quality_model, .clip_name,
         .lora_1, .lora_2, .lora_3]]
    == [["Maximum Quality", "Default (40% of RAM)", "(disabled)", "(disabled)",
         "krea2_turbo_bf16.safetensors", "qwen3vl_4b_bf16.safetensors",
         "Krea2/krea2_identity_edit_v1_2.safetensors",
         "Krea2/krea2filterbypass3.safetensors",
         "Krea2/Detailer-KREA2.safetensors"]])
  and ([.nodes[] | select(.type == "MuseCharacterSheetDirector")
      | [.widgets_values[0], .widgets_values[1], .widgets_values[2],
         .widgets_values[3]]]
    == [["krea2_turbo_bf16.safetensors",
         "Krea2/krea2_identity_edit_v1_2.safetensors",
         "Krea2/krea2filterbypass3.safetensors",
         "qwen3vl_4b_bf16.safetensors"]])
  and ([.nodes[] | select(.type == "MuseCharacterSheetDirector")
      | .widgets_values_named | [.unet_name, .identity_lora, .filter_bypass_lora,
                                 .clip_name]]
    == [["krea2_turbo_bf16.safetensors",
         "Krea2/krea2_identity_edit_v1_2.safetensors",
         "Krea2/krea2filterbypass3.safetensors",
         "qwen3vl_4b_bf16.safetensors"]])
  and ([.nodes[] | select(.type == "MuseCharacterSheetDirector")
      | .widgets_values[15] | fromjson
      | [.seeds, .confirmed, .action]]
    == [[[41001, 41002, 41003, 41004, 41005],
         [false, false, false, false, false],
         null]])
  and ([.nodes[] | select(.type == "MuseCharacterSheetDirector")
      | .widgets_values[15] | fromjson | has("previews")] | all(. == false))
  and ([.nodes[] | select(.type == "MuseCharacterSheetDirector")
      | .widgets_values[15] | fromjson | has("editInstructions")] | all(. == false))
' "$krea2_full" >/dev/null

if grep -RqiE \
  'flux-2-klein-9b-kv-fp8|flux-2-klein-4b|qwen_3_8b_fp8mixed|qwen_3_8b_fp4|qwen3vl_4b_fp8_scaled|krea2_turbo_int8_convrot|krea2filterbypass3_fp32|auto-download|Krea2\\\\|ComfyUI-Manager' \
  "$output_dir"; then
  echo "forbidden lower-precision selector, Windows LoRA path, or mutable link in the Muse Character Sheet workflows" >&2
  exit 1
fi
test "$(find "$output_dir" -type f -name '*.json' | wc -l)" -eq 2
