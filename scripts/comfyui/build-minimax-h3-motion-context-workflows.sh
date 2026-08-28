#!/usr/bin/env bash
set -euo pipefail

usage() {
  printf 'Usage: %s --source-dir DIR --output-dir DIR\n' "$0" >&2
  exit 64
}

source_dir=
output_dir=
while (($#)); do
  case "$1" in
    --source-dir)
      [[ $# -ge 2 ]] || usage
      source_dir=$2
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

[[ -d "$source_dir" && -n "$output_dir" ]] || usage

keyframe_source="$source_dir/example_workflows/UTILITY - Custom Keyframes.json"
av_extension_source="$source_dir/example_workflows/NEW - AV Extension.json"
[[ -f "$keyframe_source" && -f "$av_extension_source" ]] || usage

expected_keyframe_sha=85502305f691ece7f64c0c9db6ed5703f95bc79da6f8024014c80fb37112dbdd
expected_av_extension_sha=b51189eea08339d054ad92945700408b9edd85580fa6f08f24fc29cda14d9187
[[ $(sha256sum "$keyframe_source" | cut -d' ' -f1) == "$expected_keyframe_sha" ]] || {
  printf 'unexpected Custom Keyframes source checksum\n' >&2
  exit 1
}
[[ $(sha256sum "$av_extension_source" | cut -d' ' -f1) == "$expected_av_extension_sha" ]] || {
  printf 'unexpected AV Extension source checksum\n' >&2
  exit 1
}

mkdir -p "$output_dir"
base_keyframes="$output_dir/01 MiniMax H3 Custom Keyframes - BF16 Base Development.json"
turbo_keyframes="$output_dir/02 MiniMax H3 Custom Keyframes - BF16 FL2VA Turbo 4-Step Development.json"
turbo_extension="$output_dir/03 MiniMax H3 AV Extension - BF16 REF2VA Turbo 4-Step Development.json"

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

if grep -RqiE 'pruned_int8|int8_convrot|nvfp4|fl2v_turbo_8step|resolve/main|tree/main|ComfyUI-Manager|api[_-]?key|token' "$output_dir"; then
  printf 'Motion Context workflows retain a lower-quality selector, wrong Turbo family, mutable link, Manager dependency, or credential field\n' >&2
  exit 1
fi

[[ $(find "$output_dir" -type f -name '*.json' | wc -l) -eq 3 ]]
