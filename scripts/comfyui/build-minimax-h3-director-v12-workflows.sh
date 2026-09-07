#!/usr/bin/env bash
# Build the workstation BF16 V1.5 adaptation of the upstream Muse Minimax
# Director V1.4 workflow (the Muse Director + Refine V2 bug-fix bundle the
# video pins).
#
# What the jq pass does:
#   * Rewrites the four third-party helper types the upstream graph wires
#     (easy showAnything, iToolsPreviewText, SaveTextWithPath,
#     LayerUtility: PurgeVRAM) onto the locally pinned muse_helper_nodes pack
#     - 1:1 call-contract mirrors, so every sink and passthrough link stays
#     valid and the graph topology is preserved exactly.
#   * Pins every model selector to the workstation checksum-verified BF16
#     set: the unified loader Low VRAM and Balanced profiles collapse to
#     (disabled) (the workstation policy is BF16-only, so no GGUF or int8
#     route exists here), Maximum Quality pins to the unpruned BF16 families,
#     and the plain subgraph loaders match. The one load-bearing LoRA is the
#     workstation turbo 8-step file; optional creator style LoRAs are stripped
#     from both active and bypassed selectors, so slots 2/3 stay (disabled) and
#     stacked style drift is unrepresentable.
#   * Repoints the Director Analyze Backend from the creator Ollama default
#     to the local OpenAI-compatible prompt-author LLM (the bundle custom
#     provider posts to {base_url}/v1/chat/completions, so the base URL
#     carries no /v1 suffix).
#   * Replaces the creator Model Links section with the workstation pinned
#     profile, fixes the creator Windows-style prompt save path to a POSIX
#     subfolder, and renames the model subgraph.
set -euo pipefail

usage() {
  printf 'Usage: %s --source-workflow FILE --output-dir DIR\n' "$0" >&2
  exit 64
}

source_workflow=
output_dir=
while (($#)); do
  case "$1" in
    --source-workflow)
      [[ $# -ge 2 ]] || usage
      source_workflow=$2
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

[[ -f "$source_workflow" && -n "$output_dir" ]] || usage
mkdir -p "$output_dir"

full="$output_dir/01 MiniMax H3 Muse Director V1.5 - BF16 Local Development.json"

model_note=$'## Workstation Model Links (pinned local profile)\n\nThis adapted graph pins every selector to the workstation checksum-verified BF16 set. Model installation is owned by the local downloaders; nothing here downloads at runtime.\n\n- `diffusion_models/minimax_h3_ref2va_bf16.safetensors` - Reference model (unpruned BF16)\n- `diffusion_models/minimax_h3_fl2va_bf16.safetensors` - First/Last-frame model (unpruned BF16)\n- `text_encoders/qwen3vl_32b_minimax_h3_bf16.safetensors` - BF16 Qwen3-VL-32B encoder\n- `vae/minimax_h3_video_vae_fp16.safetensors` + `vae/minimax_h3_audio_vae_fp32.safetensors` - full VAEs\n- `latent_upscale_models/minimax_h3_latent_upscaler_3d_fp16.safetensors` - Stage-2 upscale model (Two-Stage Sampling is on by default)\n- `loras/minimax_h3_fl2v_turbo_8step_v1.0_comfyui_bf16.safetensors` - the one load-bearing LoRA, strength 1.0, both models\n- `vae_approx/taeh3.safetensors` - H3 sampling preview for the Model Preview Override tiny_vae box\n- `vae/taeltx2_3.safetensors` - lightweight LTX2.3 preview VAE for the Model Preview Override vae input\n\nThe unified loader Low VRAM and Balanced profiles are pinned to (disabled): the workstation policy is BF16-only, so no lower-precision route exists here. Optional creator style LoRAs are intentionally absent; slots 2/3 stay (disabled) so stacked style drift is unrepresentable.\n\nThe Director Analyze Backend points at the local prompt-author LLM (OpenAI Compatible, http://127.0.0.1:8000, qwen3.8-27b).'

status_note=$'Maximum Quality was automatically selected. Detected VRAM: 94.14 GB. LoRAs: minimax_h3_fl2v_turbo_8step_v1.0_comfyui_bf16.safetensors. Patches: SageAttention, Low-VRAM attention, chunked feed-forward. First/Last-frame branch uses the maximum-quality model: minimax_h3_fl2va_bf16.safetensors.'

custom_nodes_note=$'# Download These First - Custom Nodes\n\nThe ComfyUI "Install Missing Custom Nodes" scanner will not catch the internal dependencies below: they are called by other nodes own code at runtime, not wired in as visible boxes, so nothing flags them as missing. All three are pinned and deployed declaratively by the workstation configuration; nothing to install by hand.\n\n## Required\n\n1. **ComfyUI-H3-Multishot** - Two-Stage Sampling (on by default) and every Muse Unified Loader model/clip load.\n2. **ComfyUI-H3-Motion-Context-MultiRef** - VAE Re-encode Carry and Raw Latent Carry (both on by default). This is the seitanism fork, not the original it forked from.\n3. **ComfyUI-KJNodes** - SageAttention support in the Muse Unified Loader (on by default), plus the Model Preview Override H3 patch.\n\n## Optional\n\n4. **ComfyUI-GGUF** - only if the Low VRAM or Balanced quality profile is ever enabled. Both profiles are pinned to (disabled) on this workstation, so no GGUF route exists here.'

jq \
  --arg model_note "$model_note" \
  --arg status_note "$status_note" \
  --arg custom_nodes_note "$custom_nodes_note" '
  # Helper type rewrites - 1:1 call-contract mirrors, so every sink and
  # passthrough link stays valid and the graph topology is preserved exactly.
  (.nodes[] | select(.type == "easy showAnything")) |= (
    .type = "MuseHelper: Show Anything"
    | .outputs[0].type = "STRING"
    | .properties = {"Node name for S&R": "MuseHelper: Show Anything"}
    | del(.ue_properties)
  )
  | (.nodes[] | select(.type == "iToolsPreviewText")) |= (
    .type = "MuseHelper: Preview Text"
    | .properties = {"Node name for S&R": "MuseHelper: Preview Text"}
    | del(.ue_properties)
  )
  | (.nodes[] | select(.type == "SaveTextWithPath")) |= (
    .type = "MuseHelper: Save Text With Path"
    | .properties = {"Node name for S&R": "MuseHelper: Save Text With Path"}
  )
  | (.nodes[] | select(.type == "LayerUtility: PurgeVRAM")) |= (
    .type = "MuseHelper: Purge VRAM"
    | .properties = {"Node name for S&R": "MuseHelper: Purge VRAM"}
    | del(.ue_properties)
  )

  # Workstation display text on the three status sinks (the runtime output
  # refreshes them on the first run; the stale creator text never shows).
  | (.nodes[] | select(.id == 348) | .widgets_values[0]) = "Maximum Quality"
  | (.nodes[] | select(.id == 349) | .widgets_values[0]) = "94.14"
  | (.nodes[] | select(.id == 350) | .widgets_values[0]) = $status_note
  | (.nodes[] | select(.id == 350) | .widgets_values_named.text) = $status_note

  # The creator Windows-style prompt save path becomes a POSIX subfolder
  # under the ComfyUI output directory.
  | (.nodes[] | select(.id == 391) | .widgets_values[0]) =
      "Muse Collective/MiniMax H3 Prompt"

  # Unified Loader: the Low VRAM and Balanced profiles collapse to (disabled);
  # the workstation policy is BF16-only, so no GGUF or int8 route exists here.
  # Maximum Quality pins to the unpruned BF16 families and the BF16 encoder.
  | (.nodes[] | select(.id == 430) | .widgets_values[3]) = "(disabled)"
  | (.nodes[] | select(.id == 430) | .widgets_values[4]) = "(disabled)"
  | (.nodes[] | select(.id == 430) | .widgets_values[5]) =
      "minimax_h3_ref2va_bf16.safetensors"
  | (.nodes[] | select(.id == 430) | .widgets_values[7]) = "(disabled)"
  | (.nodes[] | select(.id == 430) | .widgets_values[8]) = "(disabled)"
  | (.nodes[] | select(.id == 430) | .widgets_values[9]) =
      "minimax_h3_fl2va_bf16.safetensors"
  | (.nodes[] | select(.id == 430) | .widgets_values[11]) = "(disabled)"
  | (.nodes[] | select(.id == 430) | .widgets_values[12]) = "(disabled)"
  | (.nodes[] | select(.id == 430) | .widgets_values[13]) = "(disabled)"
  | (.nodes[] | select(.id == 430) | .widgets_values[15]) =
      "qwen3vl_32b_minimax_h3_bf16.safetensors"
  # One load-bearing LoRA; the CivitAI style LoRAs are intentionally absent so
  # stacked style drift is unrepresentable.
  | (.nodes[] | select(.id == 430) | .widgets_values[21]) =
      "minimax_h3_fl2v_turbo_8step_v1.0_comfyui_bf16.safetensors"
  | (.nodes[] | select(.id == 430) | .widgets_values[24]) = "(disabled)"
  | (.nodes[] | select(.id == 430) | .widgets_values[27]) = "(disabled)"

  # Strip lower-precision and optional creator selectors from the loader
  # named-widget mirror. The positional widgets above remain the execution
  # source of truth; these values prevent stale UI metadata from resurrecting
  # selectors the workstation profile makes illegal.
  | (.nodes[] | select(.id == 430) | .widgets_values_named) |= (
      .low_vram_model = "(disabled)"
      | .balanced_model = "(disabled)"
      | .maximum_quality_model = "minimax_h3_ref2va_bf16.safetensors"
      | .low_vram_fl2va = "(disabled)"
      | .balanced_fl2va = "(disabled)"
      | .maximum_quality_fl2va = "minimax_h3_fl2va_bf16.safetensors"
      | .low_vram_clip = "(disabled)"
      | .balanced_clip = "(disabled)"
      | .maximum_quality_clip = "qwen3vl_32b_minimax_h3_bf16.safetensors"
      | .lora_1 = "minimax_h3_fl2v_turbo_8step_v1.0_comfyui_bf16.safetensors"
      | .lora_2 = "(disabled)"
      | .lora_3 = "(disabled)"
      | del(.low_vram_mmproj, .balanced_mmproj, .maximum_quality_mmproj)
    )

  # The upstream model picker is bypassed, but its serialized widget mirrors
  # still carried creator paths. Strip them too so re-enabling it cannot
  # restore an undeclared model state.
  | (.nodes[] | select(.id == 423)) |= (
      .widgets_values[6:12] = [
        "minimax_h3_fl2v_turbo_8step_v1.0_comfyui_bf16.safetensors",
        "(disabled)",
        "(disabled)",
        "minimax_h3_fl2v_turbo_8step_v1.0_comfyui_bf16.safetensors",
        "(disabled)",
        "(disabled)"
      ]
      | .widgets_values_named.lora_name =
          "minimax_h3_fl2v_turbo_8step_v1.0_comfyui_bf16.safetensors"
      | .widgets_values_named.lora_name_1 = "(disabled)"
      | .widgets_values_named.lora_name_2 = "(disabled)"
      | .widgets_values_named.lora_name_3 =
          "minimax_h3_fl2v_turbo_8step_v1.0_comfyui_bf16.safetensors"
      | .widgets_values_named.lora_name_4 = "(disabled)"
      | .widgets_values_named.lora_name_5 = "(disabled)"
    )

  # Strip the same serialized LoRA selectors inside the bypassed subgraph.
  | (.definitions.subgraphs[].nodes[]
      | select(.id == 415 or .id == 424)) |= (
        .widgets_values[0] =
          "minimax_h3_fl2v_turbo_8step_v1.0_comfyui_bf16.safetensors"
        | .widgets_values_named.lora_name =
          "minimax_h3_fl2v_turbo_8step_v1.0_comfyui_bf16.safetensors"
      )
  | (.definitions.subgraphs[].nodes[]
      | select(.id == 420 or .id == 421 or .id == 425 or .id == 426)) |= (
        .widgets_values[0] = "(disabled)"
        | .widgets_values_named.lora_name = "(disabled)"
      )

  # The plain subgraph loaders: same BF16 set, so whichever path is active
  # (the unified loader or the hand-wired fallback) selects the pinned models.
  | (.definitions.subgraphs[].nodes[] | select(.id == 411)
      | .widgets_values[0]) = "minimax_h3_ref2va_bf16.safetensors"
  | (.definitions.subgraphs[].nodes[] | select(.id == 422)
      | .widgets_values[0]) = "minimax_h3_fl2va_bf16.safetensors"
  | (.definitions.subgraphs[].nodes[] | select(.id == 412)
      | .widgets_values[0]) = "qwen3vl_32b_minimax_h3_bf16.safetensors"

  # The Director Analyze Backend: the creator Ollama default becomes the
  # local OpenAI-compatible prompt-author LLM. The bundle custom provider
  # posts to {base_url}/v1/chat/completions, so the base URL carries no /v1.
  | (.nodes[] | select(.id == 388) | .widgets_values[26]) |= (
      fromjson
      | .prompt_gen_provider = "custom"
      | .prompt_gen_base_url = "http://127.0.0.1:8000"
      | .prompt_gen_model = "qwen3.8-27b"
      | tojson
    )

  # The creator Model Links note: keep its description and required-node
  # documentation, replace the model-links section with the workstation
  # pinned profile. The custom-nodes note becomes the workstation own.
  | walk(
      if type == "string" then
        if contains("## Model Links") then
          (split("## Model Links")[0] + "## Model Links (pinned local profile)\n\n" + $model_note)
        elif contains("## Optional - only if you turn on the feature that needs them") then
          $custom_nodes_note
        else
          gsub("minimax_h3_fastvideo_vsa_datafree_1300step_4step_int8_convrot\\.safetensors";
              "minimax_h3_ref2va_bf16.safetensors")
          | gsub("minimax_h3_fl2va_pruned_int8_convrot\\.safetensors";
              "minimax_h3_fl2va_bf16.safetensors")
          | gsub("minimax_h3_ref2va_pruned_int8_convrot\\.safetensors";
              "minimax_h3_ref2va_bf16.safetensors")
          | gsub("qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors";
              "qwen3vl_32b_minimax_h3_bf16.safetensors")
          | gsub("https://huggingface.co/Comfy-Org/MiniMax-H3/resolve/main/";
              "https://huggingface.co/Comfy-Org/MiniMax-H3/resolve/dc559027db79c174125df4d827db55cd11178860/")
        end
      else . end
    )

  # The model subgraph: name it for what it is on this workstation.
  | (.definitions.subgraphs[] | select(.name == "New Subgraph") | .name) =
      "Pinned BF16 model set - workstation profile"
' "$source_workflow" >"$full"

jq -e --arg status_note "$status_note" '
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
  and ([.nodes[] | select(.type == "MuseHelper: Show Anything")] | length == 3)
  and ([.nodes[] | select(.type == "MuseHelper: Preview Text")] | length == 1)
  and ([.nodes[] | select(.type == "MuseHelper: Save Text With Path")] | length == 1)
  and ([.nodes[] | select(.type == "MuseHelper: Purge VRAM")] | length == 4)
  and ([.nodes[] | select(.type == "easy showAnything"
      or .type == "iToolsPreviewText"
      or .type == "SaveTextWithPath"
      or .type == "LayerUtility: PurgeVRAM")] | length == 0)
  and ([.nodes[] | select(.type == "MuseHelper: Show Anything")
      | .outputs[0].type] | unique == ["STRING"])
  and ([.nodes[] | select(.type == "MuseHelper: Preview Text")
      | .outputs[0].type] | unique == ["STRING"])
  and ([.nodes[] | select(.type == "MuseHelper: Save Text With Path")
      | .widgets_values[0]] == ["Muse Collective/MiniMax H3 Prompt"])
  and ([.nodes[] | select(.type == "MuseHelper: Save Text With Path")
      | .widgets_values[4:6]] == [[false, ".txt"]])
  and ([.nodes[] | select(.id == 430) | .widgets_values[3:6]]
    == [["(disabled)", "(disabled)", "minimax_h3_ref2va_bf16.safetensors"]])
  and ([.nodes[] | select(.id == 430) | .widgets_values[7:10]]
    == [["(disabled)", "(disabled)", "minimax_h3_fl2va_bf16.safetensors"]])
  and ([.nodes[] | select(.id == 430) | .widgets_values[11:16]]
    == [["(disabled)", "(disabled)", "(disabled)", "(auto)",
         "qwen3vl_32b_minimax_h3_bf16.safetensors"]])
  and ([.nodes[] | select(.id == 430) | .widgets_values[18:20]]
    == [["minimax_h3_video_vae_fp16.safetensors",
         "minimax_h3_audio_vae_fp32.safetensors"]])
  and ([.nodes[] | select(.id == 430) | .widgets_values[21:22]]
    == [["minimax_h3_fl2v_turbo_8step_v1.0_comfyui_bf16.safetensors"]])
  and ([.nodes[] | select(.id == 430) | .widgets_values[24:25]]
    == [["(disabled)"]])
  and ([.nodes[] | select(.id == 430) | .widgets_values[27:28]]
    == [["(disabled)"]])
  and ([.nodes[] | select(.id == 430) | .widgets_values_named
      | [.low_vram_model, .balanced_model, .maximum_quality_model,
         .low_vram_fl2va, .balanced_fl2va, .maximum_quality_fl2va,
         .low_vram_clip, .balanced_clip, .maximum_quality_clip,
         .lora_1, .lora_2, .lora_3]]
    == [["(disabled)", "(disabled)", "minimax_h3_ref2va_bf16.safetensors",
         "(disabled)", "(disabled)", "minimax_h3_fl2va_bf16.safetensors",
         "(disabled)", "(disabled)", "qwen3vl_32b_minimax_h3_bf16.safetensors",
         "minimax_h3_fl2v_turbo_8step_v1.0_comfyui_bf16.safetensors",
         "(disabled)", "(disabled)"]])
  and all(.nodes[] | select(.id == 430) | .widgets_values_named;
    (has("low_vram_mmproj") or has("balanced_mmproj")
      or has("maximum_quality_mmproj")) | not)
  and ([.nodes[] | select(.id == 423)
      | [.mode, .widgets_values[6:12]]]
    == [[4, ["minimax_h3_fl2v_turbo_8step_v1.0_comfyui_bf16.safetensors",
             "(disabled)", "(disabled)",
             "minimax_h3_fl2v_turbo_8step_v1.0_comfyui_bf16.safetensors",
             "(disabled)", "(disabled)"]]])
  and ([.nodes[] | select(.id == 350)
      | .widgets_values_named.text] == [$status_note])
  and ([.nodes[] | select(.id == 430) | .widgets_values[31]] == [true])
  and ([.nodes[] | select(.id == 430) | .widgets_values[33]] == [true])
  and ([.nodes[] | select(.id == 430) | .widgets_values[34]] == [true])
  and ([.definitions.subgraphs[].nodes[] | select(.id == 411)
      | .widgets_values[0]] == ["minimax_h3_ref2va_bf16.safetensors"])
  and ([.definitions.subgraphs[].nodes[] | select(.id == 422)
      | .widgets_values[0]] == ["minimax_h3_fl2va_bf16.safetensors"])
  and ([.definitions.subgraphs[].nodes[] | select(.id == 412)
      | .widgets_values[0]] == ["qwen3vl_32b_minimax_h3_bf16.safetensors"])
  and ([.definitions.subgraphs[].nodes[]
      | select(.id == 415 or .id == 424) | .widgets_values[0]]
    == ["minimax_h3_fl2v_turbo_8step_v1.0_comfyui_bf16.safetensors",
        "minimax_h3_fl2v_turbo_8step_v1.0_comfyui_bf16.safetensors"])
  and ([.definitions.subgraphs[].nodes[]
      | select(.id == 420 or .id == 421 or .id == 425 or .id == 426)
      | .widgets_values[0]] | unique == ["(disabled)"])
  and ([.definitions.subgraphs[].nodes[] | select(.id == 416)
      | .widgets_values[0]] == ["taeltx2_3.safetensors"])
  and ([.nodes[] | select(.type == "MuseMinimaxDirectorV1_4")
      | .widgets_values[21]] == ["minimax_h3_latent_upscaler_3d_fp16.safetensors"])
  and ([.nodes[] | select(.type == "MuseMinimaxRefineV2")
      | .widgets_values[9]] == ["minimax_h3_latent_upscaler_3d_fp16.safetensors"])
  and ([.nodes[] | select(.type == "ModelPreviewOverrideKJ")
      | .widgets_values[5]] | unique == ["taeh3.safetensors"])
  and ([.nodes[] | select(.id == 388) | .widgets_values[26] | fromjson
      | .prompt_gen_provider] == ["custom"])
  and ([.nodes[] | select(.id == 388) | .widgets_values[26] | fromjson
      | .prompt_gen_base_url] == ["http://127.0.0.1:8000"])
  and ([.nodes[] | select(.id == 388) | .widgets_values[26] | fromjson
      | .prompt_gen_model] == ["qwen3.8-27b"])
  and ([.nodes[] | select(.type == "MuseHelper: Show Anything")
      | .widgets_values[0]] | unique | sort
    == (["94.14", "Maximum Quality", $status_note] | sort))
  and ([.definitions.subgraphs[].name]
    == ["Pinned BF16 model set - workstation profile"])
' "$full" >/dev/null

if grep -RqiE \
  'easy showAnything|iToolsPreviewText|"SaveTextWithPath"|LayerUtility: PurgeVRAM|int8|nvfp4|curve-Q4|curve-Q5|Q4_K_M|mmproj|resolve/main|tree/main|joeygambino|lightx2v|H3\\\\|MysticXXX|GalaxyAce' \
  "$output_dir"; then
  echo "forbidden third-party helper, lower-precision selector, mutable link, or CivitAI style LoRA in the Muse Director workflow" >&2
  exit 1
fi
test "$(find "$output_dir" -type f -name '*.json' | wc -l)" -eq 1
