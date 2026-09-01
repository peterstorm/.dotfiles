#!/usr/bin/env bash
set -euo pipefail

usage() {
  printf 'Usage: %s --source-dir DIR --two-guide-source FILE --four-guide-source FILE --output-dir DIR\n' "$0" >&2
  exit 64
}

source_dir=
two_guide_source=
four_guide_source=
output_dir=
while (($#)); do
  case "$1" in
    --source-dir)
      [[ $# -ge 2 ]] || usage
      source_dir=$2
      shift 2
      ;;
    --two-guide-source)
      [[ $# -ge 2 ]] || usage
      two_guide_source=$2
      shift 2
      ;;
    --four-guide-source)
      [[ $# -ge 2 ]] || usage
      four_guide_source=$2
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

[[ -d "$source_dir" && -f "$two_guide_source" && -f "$four_guide_source" && -n "$output_dir" ]] || usage

keyframe_source="$source_dir/example_workflows/UTILITY - Custom Keyframes.json"
av_extension_source="$source_dir/example_workflows/NEW - AV Extension.json"
[[ -f "$keyframe_source" && -f "$av_extension_source" ]] || usage

expected_keyframe_sha=85502305f691ece7f64c0c9db6ed5703f95bc79da6f8024014c80fb37112dbdd
expected_av_extension_sha=b51189eea08339d054ad92945700408b9edd85580fa6f08f24fc29cda14d9187
expected_two_guide_sha=167b811d90e83197da3e583e88d73dcc723f8a375f4f7692c1e851a1d448a235
expected_four_guide_sha=9e7e89727eda1cd810426d56a17af47fe3c4999ac7855d98ad4a2929390d5d30
[[ $(sha256sum "$keyframe_source" | cut -d' ' -f1) == "$expected_keyframe_sha" ]] || {
  printf 'unexpected Custom Keyframes source checksum\n' >&2
  exit 1
}
[[ $(sha256sum "$av_extension_source" | cut -d' ' -f1) == "$expected_av_extension_sha" ]] || {
  printf 'unexpected AV Extension source checksum\n' >&2
  exit 1
}
[[ $(sha256sum "$two_guide_source" | cut -d' ' -f1) == "$expected_two_guide_sha" ]] || {
  printf 'unexpected two-guide source checksum\n' >&2
  exit 1
}
[[ $(sha256sum "$four_guide_source" | cut -d' ' -f1) == "$expected_four_guide_sha" ]] || {
  printf 'unexpected four-guide source checksum\n' >&2
  exit 1
}

mkdir -p "$output_dir"
base_keyframes="$output_dir/01 MiniMax H3 Custom Keyframes - BF16 Base Development.json"
turbo_keyframes="$output_dir/02 MiniMax H3 Custom Keyframes - BF16 FL2VA Turbo 4-Step Development.json"
turbo_extension="$output_dir/03 MiniMax H3 AV Extension - BF16 REF2VA Turbo 4-Step Development.json"
two_guide_base="$output_dir/04 MiniMax H3 Two Guides - Maximum Quality BF16 Development.json"
two_guide_turbo="$output_dir/05 MiniMax H3 Two Guides - BF16 FL2VA Turbo 4-Step Development.json"
four_guide_base="$output_dir/06 MiniMax H3 Four Guides - Maximum Quality BF16 Development.json"
four_guide_turbo="$output_dir/07 MiniMax H3 Four Guides - BF16 FL2VA Turbo 4-Step Development.json"

keyframe_prompt='integrated_multimodal_description:
[Shot 1] One continuous Development shot with no internal cuts. Begin exactly from Keyframe 1. Describe one readable action path through Keyframe 2 and settle exactly into Keyframe 3. For a fight beat, assign each image one state only: setup, contact or evasion, then recoil or consequence. Preserve screen direction, support contacts, identities, materials, lighting, and environment between anchors. The keyframes constrain visible states but do not prove correct force transfer between them.

overall_soundscape:
Describe synchronized ambience, movement, one impact or near-contact cue, and the consequence.

non_diegetic_music:
N/A'

jq --arg prompt "$keyframe_prompt" '
  (.nodes[] | select(.type == "UNETLoader")) |= (
    .widgets_values = ["minimax_h3_fl2va_bf16.safetensors", "default"]
    | .widgets_values_named.unet_name = "minimax_h3_fl2va_bf16.safetensors"
    | del(.properties.models)
  )
  | (.nodes[] | select(.type == "CLIPLoader")) |= (
      .widgets_values = ["qwen3vl_32b_minimax_h3_bf16.safetensors", "minimax", "default"]
      | .widgets_values_named.clip_name = "qwen3vl_32b_minimax_h3_bf16.safetensors"
      | del(.properties.models)
    )
  | (.nodes[] | select(.type == "VAELoader" and (.widgets_values[0] | contains("video")))) |= (
      .widgets_values = ["minimax_h3_video_vae_fp16.safetensors"]
      | .widgets_values_named.vae_name = "minimax_h3_video_vae_fp16.safetensors"
      | del(.properties.models)
    )
  | (.nodes[] | select(.type == "VAELoader" and (.widgets_values[0] | contains("audio")))) |= (
      .widgets_values = ["minimax_h3_audio_vae_fp32.safetensors"]
      | .widgets_values_named.vae_name = "minimax_h3_audio_vae_fp32.safetensors"
      | del(.properties.models)
    )
  | (.nodes[] | select(.type == "MiniMaxH3ImageToVideo") | .widgets_values) = [$prompt, 960, 544, 124]
  | (.nodes[] | select(.type == "BasicScheduler") | .widgets_values) = ["simple", 20, 1]
  | (.nodes[] | select(.type == "KSamplerSelect") | .widgets_values) = ["res_multistep"]
  | (.nodes[] | select(.type == "MiniMaxH3SigmaShift") | .widgets_values) = [12, 3]
  | (.nodes[] | select(.type == "MiniMaxH3CustomKeyframes")) |= (
      .title = "Three exact-frame anchors — setup / event / consequence"
      | .widgets_values = ["{\"count\":3,\"positions\":[1,62,124]}", "1-based", "center"]
    )
  | (.nodes[] | select(.type == "LoadImage") | .widgets_values[0]) = (
      if .id == 5 then "h3-motion-context/KEYFRAME_1_SETUP.png"
      elif .id == 6 then "h3-motion-context/KEYFRAME_2_EVENT.png"
      else "h3-motion-context/KEYFRAME_3_CONSEQUENCE.png"
      end
    )
  | (.nodes[] | select(.type == "SaveVideo") | .widgets_values[0]) = "video/AFTERSIGNAL_H3_CustomKeyframes_Base_Development"
  | walk(if type == "object" then del(.models) else . end)
' "$keyframe_source" >"$base_keyframes"

jq '
  .last_node_id = ([.last_node_id, 1000] | max)
  | .last_link_id = ([.last_link_id, 1000] | max)
  | (.links[] | select(.[0] == 10)) = [10, 1, 0, 1000, 0, "MODEL"]
  | .links += [[1000, 1000, 0, 10, 0, "MODEL"]]
  | (.nodes[] | select(.type == "UNETLoader") | .outputs[] | select(.name == "MODEL") | .links) = [10]
  | (.nodes[] | select(.type == "MiniMaxH3SigmaShift") | .inputs[] | select(.name == "model") | .link) = 1000
  | .nodes += [{
      "id": 1000,
      "type": "LoraLoaderModelOnly",
      "pos": [-800, -260],
      "size": [420, 82],
      "flags": {},
      "order": 5,
      "mode": 0,
      "inputs": [{"name":"model","type":"MODEL","link":10}],
      "outputs": [{"name":"MODEL","type":"MODEL","links":[1000]}],
      "properties": {"cnr_id":"comfy-core","ver":"0.33.3","Node name for S&R":"LoraLoaderModelOnly"},
      "widgets_values": ["minimax_h3_fl2v_turbo_4step_v1.0_768p_comfyui_bf16.safetensors", 1.0]
    }]
  | (.nodes[] | select(.type == "MiniMaxH3ImageToVideo") | .widgets_values[1:4]) = [1344, 768, 124]
  | (.nodes[] | select(.type == "BasicScheduler") | .widgets_values) = ["simple", 4, 1]
  | (.nodes[] | select(.type == "KSamplerSelect") | .widgets_values) = ["euler"]
  | (.nodes[] | select(.type == "MiniMaxH3SigmaShift") | .widgets_values) = [6, 3]
  | (.nodes[] | select(.type == "SaveVideo") | .widgets_values[0]) = "video/AFTERSIGNAL_H3_CustomKeyframes_FL2VA_Turbo4_Development"
' "$base_keyframes" >"$turbo_keyframes"

extension_note='AFTERSIGNAL — PRIVATE LOCAL DEVELOPMENT\n\nCurrent direct-latent AV Extension topology from the pinned Motion Context MultiRef repository. This local port uses the task-matched BF16 Ref2VA model and official Ref2V Turbo four-step LoRA at strength 1.0. Global sampler: Euler/simple, four steps, shifts 12/3. Start with one extension and replace every placeholder before queueing. For fights, each generated clip owns one primary beat; inspect every seam, contact, identity, topology, lighting, and audio transition manually. Long-form continuity is Creative Montage evidence and cannot prove mechanics.'

jq --arg note "$extension_note" '
  (.nodes[] | select(.type == "UNETLoader")) |= (
    .widgets_values = ["minimax_h3_ref2va_bf16.safetensors", "default"]
    | .widgets_values_named.unet_name = "minimax_h3_ref2va_bf16.safetensors"
    | del(.properties.models)
  )
  | (.nodes[] | select(.type == "CLIPLoader")) |= (
      .widgets_values = ["qwen3vl_32b_minimax_h3_bf16.safetensors", "minimax", "default"]
      | .widgets_values_named.clip_name = "qwen3vl_32b_minimax_h3_bf16.safetensors"
      | del(.properties.models)
    )
  | (.nodes[] | select(.type == "VAELoader" and (.widgets_values[0] | contains("video")))) |= (
      .widgets_values = ["minimax_h3_video_vae_fp16.safetensors"]
      | .widgets_values_named.vae_name = "minimax_h3_video_vae_fp16.safetensors"
      | del(.properties.models)
    )
  | (.nodes[] | select(.type == "VAELoader" and (.widgets_values[0] | contains("audio")))) |= (
      .widgets_values = ["minimax_h3_audio_vae_fp32.safetensors"]
      | .widgets_values_named.vae_name = "minimax_h3_audio_vae_fp32.safetensors"
      | del(.properties.models)
    )
  | (.nodes[] | select(.type == "LoraLoaderModelOnly")) |= (
      .widgets_values = ["minimax_h3_ref2v_turbo_4step_v0.1_comfyui_bf16.safetensors", 1.0]
      | .widgets_values_named.lora_name = "minimax_h3_ref2v_turbo_4step_v0.1_comfyui_bf16.safetensors"
      | .widgets_values_named.strength_model = 1.0
      | del(.properties.models)
    )
  | (.nodes[] | select(.type == "MiniMaxH3SigmaShift") | .widgets_values) = [12, 3]
  | (.nodes[] | select(.type == "KSamplerSelect" and .id == 937) | .widgets_values) = ["euler"]
  | (.nodes[] | select(.type == "PrimitiveInt" and .id == 936) | .widgets_values) = [4, "fixed"]
  | (.nodes[] | select(.type == "BasicScheduler" and .id == 976) | .widgets_values) = ["simple", 4, 1]
  | (.nodes[] | select(.type == "ResolutionSelector" and .id == 1024) | .widgets_values) = ["16:9 (Widescreen)", 0.5, 32]
  | (.nodes[] | select(.type == "VHS_LoadVideo" and .id == 99) | .widgets_values.video) = "h3-motion-context/SOURCE_VIDEO_WITH_AUDIO.mp4"
  | (.nodes[] | select(.type == "LoadImage" and .id == 970) | .widgets_values[0]) = "h3-motion-context/KEYFRAME_1_SETUP.png"
  | (.nodes[] | select(.type == "LoadImage" and .id == 1020) | .widgets_values[0]) = "h3-motion-context/REFERENCE_1_SUBJECT.png"
  | (.nodes[] | select(.type == "LoadImage" and .id == 1021) | .widgets_values[0]) = "h3-motion-context/REFERENCE_2_WORLD.png"
  | (.nodes[] | select(.type == "MiniMaxH3AVExtensionController") | .widgets_values) = ["Existing Video", 1, 8, "All Active"]
  | (.nodes[] | select(.id == 900) | .widgets_values) = [$note]
  | (.nodes[] | select(.type == "VHS_VideoCombine") | .widgets_values.filename_prefix) |= sub("^h3_preview/"; "AFTERSIGNAL_H3_MotionContext_Turbo4/")
  | walk(if type == "object" then del(.models) else . end)
' "$av_extension_source" >"$turbo_extension"

two_guide_frames='[124, 243]'
four_guide_frames='[73, 160, 234, 324]'

build_guide_workflow() {
  local source=$1 output=$2 profile=$3 guide_count=$4
  local sampler steps shift_video lora_name output_prefix frames prompt note

  if [[ "$profile" == base ]]; then
    sampler=res_multistep
    steps=50
    shift_video=12
    lora_name=
    output_prefix="video/AFTERSIGNAL_H3_${guide_count}Guides_MaxQuality_BF16_Development"
  elif [[ "$profile" == turbo ]]; then
    sampler=euler
    steps=4
    shift_video=6
    lora_name=minimax_h3_fl2v_turbo_4step_v1.0_768p_comfyui_bf16.safetensors
    output_prefix="video/AFTERSIGNAL_H3_${guide_count}Guides_FL2VA_Turbo4_Development"
  else
    printf 'unsupported guide profile: %s\n' "$profile" >&2
    exit 1
  fi

  if [[ "$guide_count" == 2 ]]; then
    frames=$two_guide_frames
    prompt='integrated_multimodal_description:
[Shot 1] One continuous 15-second Development shot. Preserve the identities, materials, lighting, environment, camera axis, and screen direction shared by <Picture 1> and <Picture 2>. At frame 124, land on the exact visible state and composition in <Picture 1>. Describe one physically achievable transition. At frame 243, land on the exact visible state and composition in <Picture 2>. Continue to one stable consequence without an internal cut. Treat both pictures as visual references and exact-frame guides.

overall_soundscape:
Describe synchronized ambience, movement, contact or near-contact, and persistent consequence across the full shot.

non_diegetic_music:
N/A'
  elif [[ "$guide_count" == 4 ]]; then
    frames=$four_guide_frames
    prompt='integrated_multimodal_description:
[Shot 1] One continuous 15-second Development shot. Preserve the identities, materials, lighting, environment, camera axis, and screen direction shared by <Picture 1>, <Picture 2>, <Picture 3>, and <Picture 4>. Land on their exact visible states and compositions at frames 73, 160, 234, and 324 respectively. Describe one physically achievable path through all four moments with no internal cut, teleportation, duplicate subject, or reset. Treat every picture as both a visual reference and an exact-frame guide, then settle into one stable consequence.

overall_soundscape:
Describe synchronized ambience, movement, contact or near-contact, and persistent consequence across the full shot.

non_diegetic_music:
N/A'
  else
    printf 'unsupported guide count: %s\n' "$guide_count" >&2
    exit 1
  fi

  note="AFTERSIGNAL — PRIVATE LOCAL DEVELOPMENT\n\nEvery guide image is intentionally wired both as an exact-frame guide and as a visual reference. Prompt frame numbers must match the guide widgets. This workflow is constrained to the documented 15-second H3 limit and 362-frame latent cadence. Keyframes are a strong steer, not compositing or Mechanics-Proof. Profile: $profile."

  jq \
    --arg profile "$profile" \
    --arg sampler "$sampler" \
    --argjson steps "$steps" \
    --argjson shift_video "$shift_video" \
    --arg lora_name "$lora_name" \
    --arg output_prefix "$output_prefix" \
    --argjson frames "$frames" \
    --arg prompt "$prompt" \
    --arg note "$note" \
    --argjson guide_count "$guide_count" '
      .last_node_id = (if $profile == "turbo" then 1001 else 1000 end)
      | .last_link_id = 1001
      | .nodes |= map(select(.id != 37))
      | .links |= map(select(.[1] != 37 and .[3] != 37))
      | .links += [[37, 36, 0, 32, 0, "VIDEO"]]
      | (.nodes[] | select(.id == 36) | .outputs[] | select(.name == "VIDEO") | .links) = [37]
      | (.nodes[] | select(.id == 32) | .inputs[] | select(.name == "video") | .link) = 37
      | (.nodes[] | select(.type == "UNETLoader")) |= (
          .title = "ON-DEMAND — unpruned BF16 FL2VA"
          | .widgets_values = ["minimax_h3_fl2va_bf16.safetensors", "default"]
          | .widgets_values_named.unet_name = "minimax_h3_fl2va_bf16.safetensors"
          | .outputs[0].links = [12]
          | del(.properties.models)
        )
      | (.nodes[] | select(.type == "CLIPLoader")) |= (
          .title = "ON-DEMAND — BF16 Qwen3-VL-32B"
          | .widgets_values = ["qwen3vl_32b_minimax_h3_bf16.safetensors", "minimax", "default"]
          | .widgets_values_named.clip_name = "qwen3vl_32b_minimax_h3_bf16.safetensors"
          | del(.properties.models)
        )
      | (.nodes[] | select(.type == "VAELoader" and (.widgets_values[0] | contains("video")))) |= (
          .widgets_values = ["minimax_h3_video_vae_fp16.safetensors"]
          | .widgets_values_named.vae_name = "minimax_h3_video_vae_fp16.safetensors"
          | del(.properties.models)
        )
      | (.nodes[] | select(.type == "VAELoader" and (.widgets_values[0] | contains("audio")))) |= (
          .widgets_values = ["minimax_h3_audio_vae_fp32.safetensors"]
          | .widgets_values_named.vae_name = "minimax_h3_audio_vae_fp32.safetensors"
          | del(.properties.models)
        )
      | (.links[] | select(.[0] == 91)) = [91, 16, 0, 1000, 0, "MODEL"]
      | (.links[] | select(.[0] == 18)) = [18, 1000, 0, 19, 0, "MODEL"]
      | .links += [[1000, 1000, 0, 13, 0, "MODEL"]]
      | (.nodes[] | select(.id == 16) | .outputs[0].links) = [91]
      | (.nodes[] | select(.id == 19) | .inputs[] | select(.name == "model") | .link) = 18
      | (.nodes[] | select(.id == 13) | .inputs[] | select(.name == "model") | .link) = 1000
      | .nodes += [{
          "id": 1000,
          "type": "MiniMaxH3SigmaShift",
          "pos": [-360, -250],
          "size": [360, 110],
          "flags": {},
          "order": 9,
          "mode": 0,
          "inputs": [{"name":"model","type":"MODEL","link":91}],
          "outputs": [{"name":"MODEL","type":"MODEL","links":[18,1000]}],
          "properties": {"cnr_id":"comfy-core","ver":"0.33.3","Node name for S&R":"MiniMaxH3SigmaShift"},
          "widgets_values": [$shift_video, 3],
          "widgets_values_named": {"shift_video":$shift_video,"shift_audio":3}
        }]
      | if $profile == "turbo" then
          (.links[] | select(.[0] == 12)) = [12, 27, 0, 1001, 0, "MODEL"]
          | .links += [[1001, 1001, 0, 16, 0, "MODEL"]]
          | (.nodes[] | select(.id == 16) | .inputs[] | select(.name == "model") | .link) = 1001
          | .nodes += [{
              "id": 1001,
              "type": "LoraLoaderModelOnly",
              "pos": [-1230, -250],
              "size": [476, 82],
              "flags": {},
              "order": 6,
              "mode": 0,
              "inputs": [{"name":"model","type":"MODEL","link":12}],
              "outputs": [{"name":"MODEL","type":"MODEL","links":[1001]}],
              "properties": {"cnr_id":"comfy-core","ver":"0.33.3","Node name for S&R":"LoraLoaderModelOnly"},
              "widgets_values": [$lora_name, 1.0],
              "widgets_values_named": {"lora_name":$lora_name,"strength_model":1.0}
            }]
        else . end
      | (.nodes[] | select(.type == "BasicScheduler")) |= (
          .title = (if $profile == "turbo" then "Qualified FL2VA Turbo — four steps" else "Maximum quality — 50 steps" end)
          | .widgets_values = ["simple", $steps, 1]
          | .widgets_values_named.scheduler = "simple"
          | .widgets_values_named.steps = $steps
          | .widgets_values_named.denoise = 1
        )
      | (.nodes[] | select(.type == "KSamplerSelect")) |= (
          .widgets_values = [$sampler]
          | .widgets_values_named.sampler_name = $sampler
        )
      | (.nodes[] | select(.type == "ResolutionSelector")) |= (
          .title = "Native 768p short edge — 1344×768"
          | .widgets_values = ["16:9 (Widescreen)", 0.98, 32]
          | .widgets_values_named.aspect_ratio = "16:9 (Widescreen)"
          | .widgets_values_named.megapixels = 0.98
          | .widgets_values_named.multiple = 32
        )
      | (.nodes[] | select(.id == 45)) |= (
          .title = "Documented H3 maximum — 15 seconds / 362 frames"
          | .widgets_values = [15]
          | .widgets_values_named.value = 15
        )
      | (.nodes[] | select(.type == "MiniMaxH3ReferenceToVideo")) |= (
          .title = "Guide images also enter as visual references"
          | .widgets_values = [$prompt, 1344, 768, 362, "match"]
          | .widgets_values_named.prompt = $prompt
          | .widgets_values_named.width = 1344
          | .widgets_values_named.height = 768
          | .widgets_values_named.length = 362
          | .widgets_values_named.ref_image_size = "match"
        )
      | (.nodes[] | select(.id == 28)) |= (
          .title = "Prompt frame numbers must match every guide"
          | .widgets_values = [$prompt]
          | .widgets_values_named.value = $prompt
        )
      | (.nodes[] | select(.type == "MiniMaxH3AddGuide")) |= (
          .title = "Exact-frame guide — also connected as a reference"
          | if .id == 38 then .widgets_values = [$frames[0]] | .widgets_values_named.frame_idx = $frames[0]
            elif .id == 53 then .widgets_values = [$frames[1]] | .widgets_values_named.frame_idx = $frames[1]
            elif .id == 42 and $guide_count == 2 then .widgets_values = [$frames[1]] | .widgets_values_named.frame_idx = $frames[1]
            elif .id == 42 then .widgets_values = [$frames[2]] | .widgets_values_named.frame_idx = $frames[2]
            elif .id == 55 then .widgets_values = [$frames[3]] | .widgets_values_named.frame_idx = $frames[3]
            else . end
        )
      | (.nodes[] | select(.type == "LoadImage")) |= (
          if .id == 43 then
            .title = "Guide 1 — frame \($frames[0]) and Picture 1"
            | .widgets_values[0] = "h3-guides/GUIDE_1.png"
            | .widgets_values_named.image = "h3-guides/GUIDE_1.png"
          elif .id == 54 then
            .title = "Guide 2 — frame \($frames[1]) and Picture 2"
            | .widgets_values[0] = "h3-guides/GUIDE_2.png"
            | .widgets_values_named.image = "h3-guides/GUIDE_2.png"
          elif .id == 44 and $guide_count == 2 then
            .title = "Guide 2 — frame \($frames[1]) and Picture 2"
            | .widgets_values[0] = "h3-guides/GUIDE_2.png"
            | .widgets_values_named.image = "h3-guides/GUIDE_2.png"
          elif .id == 44 then
            .title = "Guide 3 — frame \($frames[2]) and Picture 3"
            | .widgets_values[0] = "h3-guides/GUIDE_3.png"
            | .widgets_values_named.image = "h3-guides/GUIDE_3.png"
          elif .id == 56 then
            .title = "Guide 4 — frame \($frames[3]) and Picture 4"
            | .widgets_values[0] = "h3-guides/GUIDE_4.png"
            | .widgets_values_named.image = "h3-guides/GUIDE_4.png"
          else . end
        )
      | (.nodes[] | select(.type == "MarkdownNote" and .id == 1)) |= (
          .title = "Dual-role guide recipe — Development only"
          | .widgets_values = [$note]
        )
      | (.nodes[] | select(.type == "SaveVideo")) |= (
          .widgets_values[0] = $output_prefix
          | .widgets_values_named.filename_prefix = $output_prefix
        )
      | walk(if type == "object" then del(.models) else . end)
    ' "$source" >"$output"
}

build_guide_workflow "$two_guide_source" "$two_guide_base" base 2
build_guide_workflow "$two_guide_source" "$two_guide_turbo" turbo 2
build_guide_workflow "$four_guide_source" "$four_guide_base" base 4
build_guide_workflow "$four_guide_source" "$four_guide_turbo" turbo 4

jq -s -e '
  length == 3
  and all(.[]; . as $workflow
    | ([.nodes[].id] | length) == ([.nodes[].id] | unique | length)
    and all(.links[]; . as $edge
      | any($workflow.nodes[]; .id == $edge[1])
      and any($workflow.nodes[]; .id == $edge[3])))
  and ([.[0].nodes[] | select(.type == "MiniMaxH3CustomKeyframes")] | length) == 1
  and ([.[0].nodes[] | select(.type == "LoraLoaderModelOnly")] | length) == 0
  and ([.[0].nodes[] | select(.type == "BasicScheduler") | .widgets_values] == [["simple", 20, 1]])
  and ([.[1].nodes[] | select(.type == "MiniMaxH3CustomKeyframes")] | length) == 1
  and ([.[1].nodes[] | select(.type == "LoraLoaderModelOnly") | .widgets_values]
    == [["minimax_h3_fl2v_turbo_4step_v1.0_768p_comfyui_bf16.safetensors", 1]])
  and ([.[1].nodes[] | select(.type == "BasicScheduler") | .widgets_values] == [["simple", 4, 1]])
  and ([.[1].nodes[] | select(.type == "MiniMaxH3SigmaShift") | .widgets_values] == [[6, 3]])
  and ([.[1].nodes[] | select(.type == "KSamplerSelect") | .widgets_values] == [["euler"]])
  and ([.[2].nodes[] | select(.type == "MiniMaxH3AVExtensionController")] | length) == 1
  and ([.[2].nodes[] | select(.type == "LoraLoaderModelOnly") | .widgets_values]
    == [["minimax_h3_ref2v_turbo_4step_v0.1_comfyui_bf16.safetensors", 1]])
  and ([.[2].nodes[] | select(.type == "PrimitiveInt" and .id == 936) | .widgets_values] == [[4, "fixed"]])
  and ([.[2].nodes[] | select(.type == "BasicScheduler" and .id == 976) | .widgets_values] == [["simple", 4, 1]])
  and ([.[2].nodes[] | select(.type == "MiniMaxH3SigmaShift") | .widgets_values] == [[12, 3]])
  and ([.[2].nodes[] | select(.type == "KSamplerSelect" and .id == 937) | .widgets_values] == [["euler"]])
  and all(.[0:2][];
    ([.nodes[] | select(.type == "UNETLoader") | .widgets_values[0]] == ["minimax_h3_fl2va_bf16.safetensors"])
    and ([.nodes[] | select(.type == "CLIPLoader") | .widgets_values[0]] == ["qwen3vl_32b_minimax_h3_bf16.safetensors"]))
  and ([.[2].nodes[] | select(.type == "UNETLoader") | .widgets_values[0]] == ["minimax_h3_ref2va_bf16.safetensors"])
  and ([.[2].nodes[] | select(.type == "CLIPLoader") | .widgets_values[0]] == ["qwen3vl_32b_minimax_h3_bf16.safetensors"])
' "$base_keyframes" "$turbo_keyframes" "$turbo_extension" >/dev/null

jq -s -e '
  length == 4
  and all(.[]; . as $workflow
    | ([.nodes[].id] | length) == ([.nodes[].id] | unique | length)
    and all(.links[]; . as $edge
      | any($workflow.nodes[]; .id == $edge[1])
      and any($workflow.nodes[]; .id == $edge[3]))
    and ([.nodes[] | select(.type == "easy cleanGpuUsed")] | length) == 0
    and ([.nodes[] | select(.type == "UNETLoader") | .widgets_values[0]]
      == ["minimax_h3_fl2va_bf16.safetensors"])
    and ([.nodes[] | select(.type == "CLIPLoader") | .widgets_values[0]]
      == ["qwen3vl_32b_minimax_h3_bf16.safetensors"])
    and ([.nodes[] | select(.type == "MiniMaxH3ReferenceToVideo") | .widgets_values[1:5]]
      == [[1344, 768, 362, "match"]])
    and ([.nodes[] | select(.type == "ResolutionSelector") | .widgets_values]
      == [["16:9 (Widescreen)", 0.98, 32]])
    and ([.nodes[] | select(.type == "MiniMaxH3SigmaShift")] | length) == 1
    and all(.nodes[] | select(.type == "LoadImage");
      (.outputs[0].links | length) == 2
      and .widgets_values_named.image == .widgets_values[0]))
  and ([.[0].nodes[] | select(.type == "MiniMaxH3AddGuide") | .widgets_values] | sort
    == [[124], [243]])
  and ([.[1].nodes[] | select(.type == "MiniMaxH3AddGuide") | .widgets_values] | sort
    == [[124], [243]])
  and ([.[2].nodes[] | select(.type == "MiniMaxH3AddGuide") | .widgets_values] | sort
    == [[73], [160], [234], [324]])
  and ([.[3].nodes[] | select(.type == "MiniMaxH3AddGuide") | .widgets_values] | sort
    == [[73], [160], [234], [324]])
  and all([.[0], .[2]][];
    ([.nodes[] | select(.type == "LoraLoaderModelOnly")] | length) == 0
    and ([.nodes[] | select(.type == "BasicScheduler") | .widgets_values] == [["simple", 50, 1]])
    and ([.nodes[] | select(.type == "KSamplerSelect") | .widgets_values] == [["res_multistep"]])
    and ([.nodes[] | select(.type == "MiniMaxH3SigmaShift") | .widgets_values] == [[12, 3]]))
  and all([.[1], .[3]][];
    ([.nodes[] | select(.type == "LoraLoaderModelOnly") | .widgets_values]
      == [["minimax_h3_fl2v_turbo_4step_v1.0_768p_comfyui_bf16.safetensors", 1]])
    and ([.nodes[] | select(.type == "BasicScheduler") | .widgets_values] == [["simple", 4, 1]])
    and ([.nodes[] | select(.type == "KSamplerSelect") | .widgets_values] == [["euler"]])
    and ([.nodes[] | select(.type == "MiniMaxH3SigmaShift") | .widgets_values] == [[6, 3]]))
' "$two_guide_base" "$two_guide_turbo" "$four_guide_base" "$four_guide_turbo" >/dev/null

if grep -RqiE 'Gemini_Generated|pruned_int8|int8_convrot|nvfp4|fl2v_turbo_8step|resolve/main|tree/main|ComfyUI-Manager|api[_-]?key|token' "$output_dir"; then
  printf 'Motion Context workflows retain a lower-quality selector, wrong Turbo family, mutable link, Manager dependency, or credential field\n' >&2
  exit 1
fi

[[ $(find "$output_dir" -type f -name '*.json' | wc -l) -eq 7 ]]
