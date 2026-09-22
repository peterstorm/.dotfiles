#!/usr/bin/env bash
# Build workstation-native adaptations of The AI Brief's HJteqahyEKM
# Singularity Dual Sampling graph. The video-visible topology is preserved:
# full primary pass -> split AV -> BF16 latent upscale -> video-only high-sigma
# detail pass -> rejoin authoritative audio -> low-sigma final AV pass.
# rgthree's loader stack and Fearworks' resolution helper are replaced by core
# ComfyUI nodes, leaving only the already-pinned H3 latent-upscaler node pack.
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

bf16_model='minimax_h3_ref2va_bf16.safetensors'
singularity_model='minimax_h3_singularity_ref2va_v1.3_int8.safetensors'
text_encoder='qwen3vl_32b_minimax_h3_bf16.safetensors'
turbo_lora='minimax_h3_ref2v_turbo_4step_v0.1_comfyui_bf16.safetensors'
lms_lora='minimax_h3_lms_v1.0_r64.safetensors'
realism_lora='h3-realism-people-t2v-i2v-r2v.safetensors'
upscaler='minimax_h3_latent_upscaler_3d_conv_v1_bf16.safetensors'

prompt='subject_definitions:
<Subject 1> is the person whose face, hair, skin tone, and stable identity come from <Picture 1>.
<Subject 2> is the complete wardrobe and full-body character design from <Picture 2>; preserve its materials, silhouette, and proportions without copying the reference background.

summary:
[reference generation] Create one continuous 15-second photoreal cinematic close-up performance of <Subject 1> wearing <Subject 2>. Preserve natural human skin with pores, vellus hair, fine lines, asymmetry, and physically plausible subsurface response; avoid waxy, glossy, airbrushed, mannequin-like skin.

detailed_description:
The shot begins as a stable chest-up portrait in soft motivated window light. <Subject 1> breathes naturally, shifts focus toward camera, and delivers a restrained emotional reaction with subtle brow, eyelid, cheek, lip, and jaw motion. The camera performs one slow, low-amplitude push-in while maintaining realistic lens depth, facial proportions, and temporal continuity. Hair and fabric respond only to body movement and a faint room draft. Keep pores and micro-contrast stable in motion without crawling texture, oversharpened edges, or beauty-filter smoothing.

overall_soundscape:
Quiet room tone, natural breathing, subtle fabric movement, and any user-supplied dialogue synchronized to the face.

non_diegetic_music:
N/A

quality_trigger:
r34l1sm. Enhance this video with sharp, crisp details while preserving a natural photorealistic appearance.'

build_profile() {
  local destination=$1 model=$2 title=$3 prefix=$4 profile_note=$5
  jq \
    --arg model "$model" \
    --arg title "$title" \
    --arg prefix "$prefix" \
    --arg encoder "$text_encoder" \
    --arg turbo "$turbo_lora" \
    --arg lms "$lms_lora" \
    --arg realism "$realism_lora" \
    --arg upscaler "$upscaler" \
    --arg prompt "$prompt" \
    --arg note "## MiniMax H3 Dual Sampling — HJteqahyEKM workstation adaptation\n\n$profile_note\n\nPipeline: full four-step primary pass at 0.5 MP; split AV; upscale only the video latent 1.25x with the pinned BF16 3D-conv upscaler; run the high-sigma refinement segment with LMS 0.5 + Realism People 1.0; rejoin the untouched primary audio latent; run the low-sigma final AV segment; decode once. The graph uses only core LoRA loaders and fixed core ResolutionSelector values instead of third-party convenience nodes. This is a reconstruction from the public video/transcript, not the gated Gumroad JSON byte-for-byte. Development-only: the latent-upscaler code/model repository declares no license." '
      (.nodes[] | select(.id == 143)) as $lora_template
      | (.nodes[] | select(.id == 126)) as $guider_template
      | (.nodes[] | select(.id == 125)) as $sampler_template
      | .last_node_id = 157
      | .last_link_id = 309
      | .nodes |= map(select(.id != 141))
      | .links |= map(select(.[0] != 256 and .[0] != 280 and .[0] != 281 and .[0] != 283))
      | (.nodes[] | select(.id == 127)) |= (
          .title = $title
          | .widgets_values = [$model, "default"]
          | .outputs[0].links = [252, 285]
          | del(.properties.models)
        )
      | (.nodes[] | select(.id == 128)) |= (
          .title = "Maximum-quality BF16 Qwen3-VL-32B encoder"
          | .widgets_values = [$encoder, "minimax", "default"]
          | del(.properties.models)
        )
      | (.nodes[] | select(.id == 143)) |= (
          .title = "Primary four-step Ref2V Turbo — BF16 strength 1.0"
          | .widgets_values = [$turbo, 1]
          | .outputs[0].links = [284]
          | del(.properties.models)
        )
      | (.nodes[] | select(.id == 142) | .outputs[0].links) = [286, 287]
      | (.nodes[] | select(.id == 124)) |= (
          .title = "Shared four-step simple schedule"
          | .widgets_values = ["simple", 4, 1]
          | .outputs[0].links = [291, 293]
        )
      | (.nodes[] | select(.id == 123)) |= (
          .title = "Shared Euler sampler"
          | .widgets_values = ["euler"]
          | .outputs[0].links = [255, 299, 306]
        )
      | (.nodes[] | select(.id == 125)) |= (
          .title = "Primary full sampling pass — 0.5 MP foundation"
          | (.inputs[] | select(.name == "sigmas") | .link) = 292
          | .outputs[0].links = [294]
          | .outputs[1].links = null
        )
      | (.nodes[] | select(.id == 136)) |= (
          .title = "Two-reference MiniMax H3 REF2VA — 15 seconds"
          | (.inputs[] | select(.name == "ref_images.ref_image_2") | .link) = null
          | .widgets_values = ["", 544, 960, 362, "match"]
          | .outputs[0].links = [270, 290]
        )
      | (.nodes[] | select(.id == 115)) |= (
          .title = "Video setting — 9:16, 0.5 MP, multiple 32"
          | .widgets_values = ["9:16 (Portrait Widescreen)", 0.5, 32]
        )
      | (.nodes[] | select(.id == 132)) |= (
          .title = "Video duration — 15 seconds"
          | .widgets_values = [15]
        )
      | (.nodes[] | select(.id == 137)) |= (
          .title = "Picture 1 — face and identity reference"
          | .widgets_values[0] = "dual-sampling/face_identity.png"
        )
      | (.nodes[] | select(.id == 139)) |= (
          .title = "Picture 2 — complete wardrobe / character sheet"
          | .widgets_values[0] = "dual-sampling/character_sheet.png"
        )
      | (.nodes[] | select(.id == 138)) |= (
          .title = "Photoreal skin + LMS trigger prompt"
          | .widgets_values = [$prompt]
        )
      | (.nodes[] | select(.id == 121) | .inputs[0].link) = 309
      | (.nodes[] | select(.id == 122) | .inputs[0].link) = 308
      | (.nodes[] | select(.id == 92)) |= (
          .title = "Final dual-sampled AV output"
          | .widgets_values[0] = $prefix
        )
      | (.nodes[] | select(.id == 116)) |= (
          .title = "Dual Sampling evidence and operating contract"
          | .widgets_values = [$note]
        )
      | (.nodes[] | select(.id == 117)) |= (
          .title = "Pinned local artifacts — no runtime downloads"
          | .widgets_values = ["Diffusion, BF16 encoder, VAEs, Turbo, LMS, Realism People, and BF16 3D latent upscaler are immutable local selectors installed by checksum-gated downloaders. Never replace them with pruned, W4A8, FP8, NVFP4, or mutable main-branch selectors."]
        )
      | .nodes += [
          ($lora_template
            | .id = 144 | .pos = [980, -250] | .order = 19
            | .title = "Second-pass LMS detail — strength 0.5"
            | .inputs[0].link = 287
            | .outputs[0].links = [288]
            | .widgets_values = [$lms, 0.5]
            | del(.properties.models)),
          ($lora_template
            | .id = 145 | .pos = [1320, -250] | .order = 20
            | .title = "Second-pass Realism People — strength 1.0 / trigger r34l1sm"
            | .inputs[0].link = 288
            | .outputs[0].links = [289]
            | .widgets_values = [$realism, 1]
            | del(.properties.models)),
          ($guider_template
            | .id = 146 | .pos = [1660, -220] | .order = 24
            | .title = "LMS + Realism refinement guider"
            | (.inputs[] | select(.name == "model") | .link) = 289
            | (.inputs[] | select(.name == "conditioning") | .link) = 290
            | .outputs[0].links = [298, 305]),
          {
            "id":147,"type":"SplitSigmas","pos":[620,520],"size":[250,82],
            "flags":{},"order":22,"mode":0,
            "inputs":[{"name":"sigmas","type":"SIGMAS","link":291}],
            "outputs":[
              {"name":"high_sigmas","type":"SIGMAS","links":null},
              {"name":"low_sigmas","type":"SIGMAS","links":[292]}],
            "properties":{"Node name for S&R":"SplitSigmas","cnr_id":"comfy-core","ver":"0.34.0"},
            "widgets_values":[0],"widgets_values_named":{"step":0},
            "title":"Primary pass — full schedule from step 0"
          },
          {
            "id":148,"type":"SplitSigmas","pos":[940,520],"size":[250,82],
            "flags":{},"order":23,"mode":0,
            "inputs":[{"name":"sigmas","type":"SIGMAS","link":293}],
            "outputs":[
              {"name":"high_sigmas","type":"SIGMAS","links":[296]},
              {"name":"low_sigmas","type":"SIGMAS","links":[301]}],
            "properties":{"Node name for S&R":"SplitSigmas","cnr_id":"comfy-core","ver":"0.34.0"},
            "widgets_values":[2],"widgets_values_named":{"step":2},
            "title":"Dual pass split — high video detail / low final AV"
          },
          {
            "id":149,"type":"LTXVSeparateAVLatent","pos":[2380,20],"size":[280,50],
            "flags":{},"order":29,"mode":0,
            "inputs":[{"name":"av_latent","type":"LATENT","link":294}],
            "outputs":[
              {"name":"video_latent","type":"LATENT","links":[295]},
              {"name":"audio_latent","type":"LATENT","links":[303]}],
            "properties":{"Node name for S&R":"LTXVSeparateAVLatent","cnr_id":"comfy-core","ver":"0.34.0"},
            "title":"Preserve primary audio; upscale video only"
          },
          {
            "id":150,"type":"MinimaxH3LatentUpscaler3D","pos":[2700,-40],"size":[310,230],
            "flags":{},"order":30,"mode":0,
            "inputs":[
              {"name":"latent","type":"*","link":295},
              {"name":"model_name","type":"COMBO","widget":{"name":"model_name"},"link":null},
              {"name":"mode","type":"COMFY_DYNAMICCOMBO_V3","widget":{"name":"mode"},"link":null},
              {"name":"mode.scale","type":"FLOAT","widget":{"name":"mode.scale"},"link":null},
              {"name":"align","type":"INT","widget":{"name":"align"},"link":null},
              {"name":"enable_temporal_chunking","type":"BOOLEAN","widget":{"name":"enable_temporal_chunking"},"link":null},
              {"name":"force_unload","type":"BOOLEAN","widget":{"name":"force_unload"},"link":null},
              {"name":"device","type":"COMBO","widget":{"name":"device"},"link":null},
              {"name":"precision","type":"COMBO","widget":{"name":"precision"},"link":null}],
            "outputs":[{"name":"latent","type":"*","links":[300]}],
            "properties":{"Node name for S&R":"MinimaxH3LatentUpscaler3D","aux_id":"LBH-123-AI/Comfyui_Minimax_h3_latent_Upscaler","ver":"d7c01b9011f2e8439493f6c02c29995a27df276f"},
            "widgets_values":[$upscaler,"scale by multiplier",1.25,32,true,true,"cuda","bf16"],
            "widgets_values_named":{"model_name":$upscaler,"mode":"scale by multiplier","mode.scale":1.25,"align":32,"enable_temporal_chunking":true,"force_unload":true,"device":"cuda","precision":"bf16"},
            "title":"Optional latent upscaler — BF16, 1.25x, temporal chunks"
          },
          {
            "id":153,"type":"DisableNoise","pos":[3020,260],"size":[210,50],
            "flags":{},"order":31,"mode":0,"inputs":[],
            "outputs":[{"name":"NOISE","type":"NOISE","links":[297,304]}],
            "properties":{"Node name for S&R":"DisableNoise","cnr_id":"comfy-core","ver":"0.34.0"},
            "title":"No fresh noise — preserve primary motion and identity"
          },
          ($sampler_template
            | .id = 154 | .pos = [3280,-40] | .order = 32
            | .title = "Second sampling pass — upscaled video / high sigmas"
            | (.inputs[] | select(.name == "noise") | .link) = 297
            | (.inputs[] | select(.name == "guider") | .link) = 298
            | (.inputs[] | select(.name == "sampler") | .link) = 299
            | (.inputs[] | select(.name == "sigmas") | .link) = 296
            | (.inputs[] | select(.name == "latent_image") | .link) = 300
            | .outputs[0].links = null
            | .outputs[1].links = [302]),
          {
            "id":155,"type":"LTXVConcatAVLatent","pos":[3640,180],"size":[280,50],
            "flags":{},"order":33,"mode":0,
            "inputs":[
              {"name":"video_latent","type":"LATENT","link":302},
              {"name":"audio_latent","type":"LATENT","link":303}],
            "outputs":[{"name":"latent","type":"LATENT","links":[307]}],
            "properties":{"Node name for S&R":"LTXVConcatAVLatent","cnr_id":"comfy-core","ver":"0.34.0"},
            "title":"Rejoin untouched primary audio latent"
          },
          ($sampler_template
            | .id = 156 | .pos = [3980,-40] | .order = 34
            | .title = "Final AV sampler — low sigmas after rejoin"
            | (.inputs[] | select(.name == "noise") | .link) = 304
            | (.inputs[] | select(.name == "guider") | .link) = 305
            | (.inputs[] | select(.name == "sampler") | .link) = 306
            | (.inputs[] | select(.name == "sigmas") | .link) = 301
            | (.inputs[] | select(.name == "latent_image") | .link) = 307
            | .outputs[0].links = [308,309]
            | .outputs[1].links = null),
          {
            "id":157,"type":"MarkdownNote","pos":[2380,360],"size":[1580,300],
            "flags":{},"order":35,"mode":0,"inputs":[],"outputs":[],
            "properties":{"Node name for S&R":"MarkdownNote","cnr_id":"comfy-core","ver":"0.34.0"},
            "widgets_values":[$note],"title":"Read before queueing — provenance, quality, and limits"
          }
        ]
      | .links += [
          [287,142,0,144,0,"MODEL"],
          [288,144,0,145,0,"MODEL"],
          [289,145,0,146,0,"MODEL"],
          [290,136,0,146,1,"CONDITIONING"],
          [291,124,0,147,0,"SIGMAS"],
          [292,147,1,125,3,"SIGMAS"],
          [293,124,0,148,0,"SIGMAS"],
          [294,125,0,149,0,"LATENT"],
          [295,149,0,150,0,"LATENT"],
          [296,148,0,154,3,"SIGMAS"],
          [297,153,0,154,0,"NOISE"],
          [298,146,0,154,1,"GUIDER"],
          [299,123,0,154,2,"SAMPLER"],
          [300,150,0,154,4,"LATENT"],
          [301,148,1,156,3,"SIGMAS"],
          [302,154,1,155,0,"LATENT"],
          [303,149,1,155,1,"LATENT"],
          [304,153,0,156,0,"NOISE"],
          [305,146,0,156,1,"GUIDER"],
          [306,123,0,156,2,"SAMPLER"],
          [307,155,0,156,4,"LATENT"],
          [308,156,0,122,0,"LATENT"],
          [309,156,0,121,0,"LATENT"]
        ]
      | walk(if type == "object" then del(.models) else . end)
    ' "$source_workflow" >"$destination"
}

bf16="$output_dir/00 MiniMax H3 BF16 Dual Sampling - Maximum Precision.json"
singularity="$output_dir/01 MiniMax H3 Singularity v1.3 Dual Sampling - Best Published Quant.json"

build_profile "$bf16" "$bf16_model" \
  'DEFAULT — official unpruned BF16 Ref2VA / maximum precision' \
  'video/MiniMax_H3_BF16_DualSampling_MaximumPrecision' \
  'Default quality profile: official unpruned BF16 Ref2VA. This is the highest-precision published diffusion checkpoint and is preferred whenever fidelity matters more than the Singularity fine-tune.'
build_profile "$singularity" "$singularity_model" \
  'VIDEO MODEL — Singularity v1.3 unpruned INT8 / best published Singularity quant' \
  'video/MiniMax_H3_Singularity_v1_3_DualSampling' \
  'Video-faithful profile: Singularity v1.3 has no BF16 publication. Its 34 GB unpruned INT8 checkpoint is the best available Singularity artifact; the pruned INT8 and W4A8 variants are deliberately excluded.'

jq -s -e \
  --arg bf16 "$bf16_model" \
  --arg singularity "$singularity_model" \
  --arg encoder "$text_encoder" \
  --arg turbo "$turbo_lora" \
  --arg lms "$lms_lora" \
  --arg realism "$realism_lora" \
  --arg upscaler "$upscaler" '
    length == 2
    and all(.[]; . as $workflow
      | ([.nodes[].id] | length == (unique | length))
      and ([.links[][0]] | length == (unique | length))
      and all(.links[]; . as $edge
        | any($workflow.nodes[];
            .id == $edge[1]
            and ((.outputs[$edge[2]].links // []) | index($edge[0])) != null)
        and any($workflow.nodes[];
            .id == $edge[3]
            and .inputs[$edge[4]].link == $edge[0]))
      and ([.nodes[] | select(.type == "CLIPLoader") | .widgets_values[0]] == [$encoder])
      and ([.nodes[] | select(.type == "LoraLoaderModelOnly") | .widgets_values] == [
        [$turbo,1], [$lms,0.5], [$realism,1]
      ])
      and ([.nodes[] | select(.type == "BasicScheduler") | .widgets_values] == [["simple",4,1]])
      and ([.nodes[] | select(.type == "SplitSigmas") | .widgets_values] == [[0],[2]])
      and ([.nodes[] | select(.type == "SamplerCustomAdvanced")] | length) == 3
      and ([.nodes[] | select(.type == "DisableNoise")] | length) == 1
      and ([.nodes[] | select(.type == "LTXVSeparateAVLatent")] | length) == 1
      and ([.nodes[] | select(.type == "LTXVConcatAVLatent")] | length) == 1
      and ([.nodes[] | select(.type == "MinimaxH3LatentUpscaler3D") | .widgets_values] == [[
        $upscaler,"scale by multiplier",1.25,32,true,true,"cuda","bf16"
      ]])
      and ([.nodes[] | select(.type == "ResolutionSelector") | .widgets_values] == [[
        "9:16 (Portrait Widescreen)",0.5,32
      ]])
      and ([.nodes[] | select(.type == "PrimitiveFloat") | .widgets_values] == [[15]])
      and ([.nodes[] | select(.type == "LoadImage") | .widgets_values[0]] == [
        "dual-sampling/face_identity.png", "dual-sampling/character_sheet.png"
      ]))
    and ([.[0].nodes[] | select(.type == "UNETLoader") | .widgets_values[0]] == [$bf16])
    and ([.[1].nodes[] | select(.type == "UNETLoader") | .widgets_values[0]] == [$singularity])
  ' "$bf16" "$singularity" >/dev/null

if grep -RqiE 'resolve/main|tree/main|ComfyUI-Manager|rgthree|fearworks' "$output_dir"; then
  echo 'Dual Sampling profiles retain a mutable URL, Manager, or convenience-node dependency' >&2
  exit 1
fi
[[ $(find "$output_dir" -type f -name '*.json' | wc -l) -eq 2 ]]
