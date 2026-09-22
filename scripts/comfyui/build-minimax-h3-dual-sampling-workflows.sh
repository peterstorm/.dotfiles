#!/usr/bin/env bash
# Build pinned workstation adaptations of The AI Brief's downloaded
# MiniMax H3 Singularity Dual-Sampling workflow. The source JSON is preserved
# byte-for-byte in comfyui/workflows; this adapter only changes compatibility,
# local artifact selectors, and the requested maximum-quality model profile.
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

readonly SOURCE_SHA256='69b3373cf4b9784d50886c0ae65a516e34f0b9cf65dc29d9d216bd286dab4778'
readonly SOURCE_NODES=87
readonly SOURCE_LINKS=88
actual_source_sha=$(sha256sum "$source_workflow")
actual_source_sha=${actual_source_sha%% *}
[[ "$actual_source_sha" == "$SOURCE_SHA256" ]] || {
  printf 'Source workflow digest mismatch: expected %s, got %s\n' \
    "$SOURCE_SHA256" "$actual_source_sha" >&2
  exit 1
}
jq -e --argjson nodes "$SOURCE_NODES" --argjson links "$SOURCE_LINKS" '
  .extra.workflow_author == "The AI Brief"
  and .extra.workflow_title == "MiniMax H3 Singularity Dual-Sampling Workflow"
  and (.nodes | length) == $nodes
  and (.links | length) == $links
  and any(.nodes[]; .type == "ExtendIntermediateSigmas")
  and any(.nodes[]; .type == "Lora Loader Stack (rgthree)")
  and any(.nodes[]; .type == "BlockSparseAttention")
' "$source_workflow" >/dev/null

mkdir -p "$output_dir"

readonly BF16_MODEL='minimax_h3_ref2va_bf16.safetensors'
readonly SINGULARITY_MODEL='minimax_h3_singularity_ref2va_v1.3_int8.safetensors'
readonly TEXT_ENCODER='qwen3vl_32b_minimax_h3_bf16.safetensors'
readonly VIDEO_VAE='minimax_h3_video_vae_fp16.safetensors'
readonly AUDIO_VAE='minimax_h3_audio_vae_fp32.safetensors'
readonly TURBO_LORA='minimax_h3_ref2v_turbo_4step_v0.1_comfyui_bf16.safetensors'
readonly LMS_LORA='minimax_h3_lms_v1.0_r64.safetensors'
readonly REALISM_LORA='h3-realism-people-t2v-i2v-r2v.safetensors'
readonly UPSCALER='minimax_h3_latent_upscaler_3d_conv_v1_bf16.safetensors'

build_profile() {
  local destination=$1 model=$2 title=$3 prefix=$4 profile_note=$5

  jq \
    --arg model "$model" \
    --arg title "$title" \
    --arg prefix "$prefix" \
    --arg encoder "$TEXT_ENCODER" \
    --arg video_vae "$VIDEO_VAE" \
    --arg audio_vae "$AUDIO_VAE" \
    --arg turbo "$TURBO_LORA" \
    --arg lms "$LMS_LORA" \
    --arg realism "$REALISM_LORA" \
    --arg upscaler "$UPSCALER" \
    --arg source_sha "$SOURCE_SHA256" \
    --arg profile_note "$profile_note" '
      # Set/Get are virtual wires. Direct links preserve their semantics while
      # removing the unavailable rgthree runtime dependency.
      .nodes |= map(select(
        (.id | IN(
          121, 150,151,152,153,154,156,157,158,160,163,164,165,166,167,168,
          182,183,184,185,186,187,188,189,190,191,192,193,194,195,196,198
        )) | not
      ))
      | .links |= map(select(
          (.[0] == 188
           or .[0] == 194
           or (.[0] >= 262 and .[0] <= 276)
           or .[0] == 298) | not
        )
        | if .[0] == 189 then [189,64,0,56,0,"CLIP"]
          elif .[0] == 259 then [259,119,0,142,0,"MODEL"]
          elif .[0] == 279 then [279,170,0,56,3,"IMAGE"]
          elif .[0] == 280 then [280,172,0,56,4,"IMAGE"]
          elif .[0] == 281 then [281,173,0,56,5,"IMAGE"]
          elif .[0] == 283 then [283,148,0,56,7,"IMAGE"]
          elif .[0] == 284 then [284,149,0,56,8,"IMAGE"]
          elif .[0] == 285 then [285,169,0,56,6,"IMAGE"]
          elif .[0] == 286 then [286,161,0,56,9,"IMAGE"]
          elif .[0] == 287 then [287,162,0,56,24,"IMAGE"]
          elif .[0] == 288 then [288,171,0,56,25,"IMAGE"]
          elif .[0] == 289 then [289,178,0,56,10,"IMAGE"]
          elif .[0] == 290 then [290,159,0,56,11,"IMAGE"]
          elif .[0] == 291 then [291,155,0,56,12,"IMAGE"]
          elif .[0] == 292 then [292,175,0,56,16,"AUDIO"]
          elif .[0] == 293 then [293,176,0,56,17,"AUDIO"]
          elif .[0] == 294 then [294,177,0,56,18,"AUDIO"]
          else . end
        )
      | (.nodes[] | select(.id == 64)) |= (
          .title = "Maximum-quality BF16 Qwen3-VL-32B encoder"
          | .widgets_values = [$encoder,"minimax","default"]
          | .outputs[0].links = [189]
        )
      | (.nodes[] | select(.id == 69)) |= (
          .title = $title
          | .widgets_values = [$model,"default"]
        )
      | (.nodes[] | select(.id == 65)) |= (
          .title = "MiniMax H3 video VAE — FP16"
          | .widgets_values = [$video_vae]
        )
      | (.nodes[] | select(.id == 66)) |= (
          .title = "MiniMax H3 audio VAE — FP32"
          | .widgets_values = [$audio_vae]
        )
      | (.nodes[] | select(.id == 118)) |= (
          .type = "LoraLoaderModelOnly"
          | .title = "Primary Ref2V Turbo — BF16 strength 1.0 / core loader"
          | .inputs = [
              {"label":"model","localized_name":"model","name":"model","type":"MODEL","link":260},
              {"label":"lora_name","localized_name":"lora_name","name":"lora_name","type":"COMBO","widget":{"name":"lora_name"},"link":null},
              {"label":"strength_model","localized_name":"strength_model","name":"strength_model","type":"FLOAT","widget":{"name":"strength_model"},"link":null}
            ]
          | .outputs = [
              {"label":"MODEL","localized_name":"MODEL","name":"MODEL","type":"MODEL","links":[218,254,255]}
            ]
          | .widgets_values = [$turbo,1]
          | .properties["Node name for S&R"] = "LoraLoaderModelOnly"
        )
      | (.nodes[] | select(.id == 127)) |= (
          .title = "Final-pass LMS detail — strength 0.5"
          | .widgets_values = [$lms,0.5]
        )
      | (.nodes[] | select(.id == 199)) |= (
          .title = "Final-pass Realism People — strength 1.0 / trigger r34l1sm"
          | .widgets_values = [$realism,1]
        )
      | (.nodes[] | select(.id == 119)) |= (
          .title = "Exact-quality Comfy Kitchen attention backend"
          | .outputs[0].links = [259]
        )
      | (.nodes[] | select(.id == 142)).title = "Optional low-VRAM attention — bypassed"
      | (.nodes[] | select(.id == 143)).title = "Chunked feed-forward — source setting"
      | (.nodes[] | select(.id == 71)) |= (
          .title = "Source schedule — simple 6 steps"
          | .widgets_values = ["simple",6,1]
        )
      | (.nodes[] | select(.id == 94)) |= (
          .title = "Source schedule — extend 2 intermediate sigmas"
          | .widgets_values = [2,1,0,"linear"]
        )
      | (.nodes[] | select(.id == 99)).title = "Dual-sampling split at step 2"
      | (.nodes[] | select(.id == 100)).title = "Optional middle sampler split at step 0 (no-op by design)"
      | (.nodes[] | select(.id == 108)).title = "Primary high-sigma sampler"
      | (.nodes[] | select(.id == 128)).title = "Optional middle sampler — zero intervals at source split 0"
      | (.nodes[] | select(.id == 106)).title = "Final low-sigma AV sampler — LMS + Realism"
      | (.nodes[] | select(.id == 124)) |= (
          .title = "Latent video upscaler — current BF16 3D-conv / 1.25x"
          | (.inputs[] | select(.name == "mode.scale") | .link) = null
          | .widgets_values = [$upscaler,"scale by multiplier",1.25,32,true,true,"cuda","bf16"]
          | .widgets_values_named = {
              "model_name":$upscaler,
              "mode":"scale by multiplier",
              "mode.scale":1.25,
              "align":32,
              "enable_temporal_chunking":true,
              "force_unload":true,
              "device":"cuda",
              "precision":"bf16"
            }
        )
      | (.nodes[] | select(.id == 170)) |= (
          .title = "Picture 1 — face / identity reference"
          | .widgets_values[0] = "dual-sampling/picture_1.png"
          | .outputs[0].links = [279]
        )
      | (.nodes[] | select(.id == 172)) |= (
          .title = "Picture 2 — character / wardrobe reference"
          | .widgets_values[0] = "dual-sampling/picture_2.png"
          | .outputs[0].links = [280]
        )
      | (.nodes[] | select(.id == 169)) |= (
          .title = "Picture 4 — optional continuity reference"
          | .widgets_values[0] = "dual-sampling/picture_4.png"
          | .outputs[0].links = [285]
        )
      | (.nodes[] | select(.id == 148) | .outputs[0].links) = [283]
      | (.nodes[] | select(.id == 149) | .outputs[0].links) = [284]
      | (.nodes[] | select(.id == 155) | .outputs[0].links) = [291]
      | (.nodes[] | select(.id == 159) | .outputs[0].links) = [290]
      | (.nodes[] | select(.id == 161) | .outputs[0].links) = [286]
      | (.nodes[] | select(.id == 162) | .outputs[0].links) = [287]
      | (.nodes[] | select(.id == 171) | .outputs[0].links) = [288]
      | (.nodes[] | select(.id == 173) | .outputs[0].links) = [281]
      | (.nodes[] | select(.id == 175) | .outputs[0].links) = [292]
      | (.nodes[] | select(.id == 176) | .outputs[0].links) = [293]
      | (.nodes[] | select(.id == 177) | .outputs[0].links) = [294]
      | (.nodes[] | select(.id == 178) | .outputs[0].links) = [289]
      | (.nodes[] | select(.id == 84)) |= (
          .title = "The AI Brief anti-plastic-skin prompt — trigger r34l1sm"
          | if (.widgets_values[0] | startswith("r34l1sm")) then .
            else .widgets_values[0] = ("r34l1sm\n\n" + .widgets_values[0]) end
        )
      | (.nodes[] | select(.id == 56)) |= (
          .title = "MiniMax H3 multi-reference I2V — source topology"
          | .widgets_values[0] = ""
        )
      | (.nodes[] | select(.id == 72)) |= (
          .title = "Resolution reference"
          | .widgets_values[0] |= gsub("ReAttention Backendution";"Resolution")
        )
      | (.nodes[] | select(.id == 174)) |= (
          .title = "The AI Brief — source provenance and workstation adaptation"
          | .widgets_values = [
              "# MiniMax H3 — The AI Brief Dual-Sampling Workflow\n\n"
              + "Downloaded source SHA-256: `" + $source_sha + "`\n\n"
              + $profile_note + "\n\n"
              + "Preserved source semantics: six-step simple schedule; two inserted intermediate sigmas; high/low split at step 2; source split-0 optional middle sampler; video-only 1.25x latent upscale; preserved primary audio; final no-fresh-noise AV pass with LMS 0.5 + Realism People 1.0.\n\n"
              + "Compatibility adaptations: direct reference links replace virtual Set/Get nodes; a core LoRA loader replaces the loader stack; stale cloud previews are removed; current BF16 3D-conv upscaler schema is used; unsupported BlockSparseAttention is omitted because this pinned Comfy version lacks it and upstream reports H3 Turbo artifact risk. The exact downloaded JSON remains in the repository.\n\n"
              + "Source credit: The AI Brief — https://www.youtube.com/@TheAIBriefYT20"
            ]
        )
      | (.nodes[] | select(.id == 135)) |= (
          .title = "Primary-pass preview"
          | .widgets_values.filename_prefix = ($prefix + "_primary_preview")
          | .widgets_values.save_output = false
        )
      | (.nodes[] | select(.id == 141)) |= (
          .title = "Final source-exact dual-sampled output"
          | .widgets_values.filename_prefix = $prefix
          | .widgets_values.save_output = true
        )
      | .extra.workflow_title = "MiniMax H3 Dual Sampling — source-exact workstation adaptation"
      | .extra.source_sha256 = $source_sha
      | .extra.profile = $title
      | .extra |= del(.anomalous_hashes,.comfyui_mcp)
      | walk(if type == "object" then del(.models,.videopreview) else . end)
    ' "$source_workflow" >"$destination"
}

bf16="$output_dir/00 MiniMax H3 BF16 Dual Sampling - Source Exact Topology.json"
singularity="$output_dir/01 MiniMax H3 Singularity v1.3 Dual Sampling - Source Exact Topology.json"

build_profile "$bf16" "$BF16_MODEL" \
  'DEFAULT — official unpruned BF16 Ref2VA / maximum precision' \
  'video/MiniMax_H3_BF16_TheAIBrief_DualSampling' \
  'Default quality profile: official unpruned BF16 Ref2VA, BF16 Qwen3-VL-32B, FP16 video VAE, FP32 audio VAE, and BF16 refinement artifacts.'
build_profile "$singularity" "$SINGULARITY_MODEL" \
  'VIDEO MODEL — Singularity v1.3 unpruned INT8 / best published Singularity quant' \
  'video/MiniMax_H3_Singularity_v1_3_TheAIBrief_DualSampling' \
  'Video-model profile: Singularity v1.3 has no BF16 publication. Its 34 GB unpruned INT8 checkpoint is paired with the BF16 encoder and BF16 refinement artifacts; pruned INT8 and W4A8 variants remain excluded.'

jq -s -e \
  --arg bf16 "$BF16_MODEL" \
  --arg singularity "$SINGULARITY_MODEL" \
  --arg encoder "$TEXT_ENCODER" \
  --arg turbo "$TURBO_LORA" \
  --arg lms "$LMS_LORA" \
  --arg realism "$REALISM_LORA" \
  --arg upscaler "$UPSCALER" \
  --arg source_sha "$SOURCE_SHA256" '
    length == 2
    and all(.[]; . as $workflow
      | (.nodes | length) == 55
      and (.links | length) == 70
      and ([.nodes[].id] | length == (unique | length))
      and ([.links[][0]] | length == (unique | length))
      and all(.links[]; . as $edge
        | any($workflow.nodes[];
            .id == $edge[1]
            and ((.outputs[$edge[2]].links // []) | index($edge[0])) != null)
        and any($workflow.nodes[];
            .id == $edge[3]
            and .inputs[$edge[4]].link == $edge[0]))
      and .extra.source_sha256 == $source_sha
      and ([.nodes[] | select(.type == "CLIPLoader") | .widgets_values[0]] == [$encoder])
      and ([.nodes[] | select(.id == 118) | .type,.widgets_values] == [
        "LoraLoaderModelOnly",[$turbo,1]
      ])
      and ([.nodes[] | select(.id == 127) | .type,.widgets_values] == [
        "LoraLoaderModelOnly",[$lms,0.5]
      ])
      and ([.nodes[] | select(.id == 199) | .type,.widgets_values] == [
        "LoraLoaderModelOnly",[$realism,1]
      ])
      and ([.nodes[] | select(.type == "BasicScheduler") | .widgets_values] == [["simple",6,1]])
      and ([.nodes[] | select(.type == "ExtendIntermediateSigmas") | .widgets_values] == [[2,1,0,"linear"]])
      and ([.nodes[] | select(.id == 99) | .type,.widgets_values] == ["SplitSigmas",[2]])
      and ([.nodes[] | select(.id == 100) | .type,.widgets_values] == ["SplitSigmas",[0]])
      and ([.nodes[] | select(.type == "SamplerCustomAdvanced")] | length) == 3
      and ([.nodes[] | select(.type == "DisableNoise")] | length) == 1
      and ([.nodes[] | select(.type == "LTXVSeparateAVLatent")] | length) == 2
      and ([.nodes[] | select(.type == "LTXVConcatAVLatent")] | length) == 1
      and ([.nodes[] | select(.type == "MinimaxH3LatentUpscaler3D") | .widgets_values] == [[
        $upscaler,"scale by multiplier",1.25,32,true,true,"cuda","bf16"
      ]])
      and ([.nodes[] | select(.type == "ResolutionSelector") | .widgets_values] == [[
        "9:16 (Portrait Widescreen)",0.5,32
      ]])
      and ([.nodes[] | select(.type == "PrimitiveFloat") | .widgets_values] == [[15]])
      and ([.links[] | select(.[0] == 148)] == [[148,99,0,108,3,"SIGMAS"]])
      and ([.links[] | select(.[0] == 144)] == [[144,99,1,106,3,"SIGMAS"]])
      and ([.links[] | select(.[0] == 223)] == [[223,100,0,128,3,"SIGMAS"]])
      and ([.nodes[] | select(.type == "BlockSparseAttention"
          or .type == "Lora Loader Stack (rgthree)"
          or .type == "SetNode"
          or .type == "GetNode"
          or .type == "easy float")] | length) == 0
      and ([.. | objects | select(has("videopreview"))] | length) == 0
      and ([.. | objects | select(has("models"))] | length) == 0)
    and ([.[0].nodes[] | select(.type == "UNETLoader") | .widgets_values[0]] == [$bf16])
    and ([.[1].nodes[] | select(.type == "UNETLoader") | .widgets_values[0]] == [$singularity])
  ' "$bf16" "$singularity" >/dev/null

if grep -RqiE 'resolve/main|tree/main|ComfyUI-Manager|rgthree|cos_url|objectKey|[A-Z]:\\\\ComfyUI' "$output_dir"; then
  echo 'Adapted workflow retains a mutable URL, Manager dependency, virtual-node pack, or stale preview path' >&2
  exit 1
fi
[[ $(find "$output_dir" -type f -name '*.json' | wc -l) -eq 2 ]]
