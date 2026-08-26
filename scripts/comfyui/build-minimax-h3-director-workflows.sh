#!/usr/bin/env bash
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

full="$output_dir/01 MiniMax H3 Director REF2VA - BF16 Full Quality Development.json"
turbo="$output_dir/02 MiniMax H3 Director REF2VA - Qualified Turbo 4-Step Development.json"
note_full=$'## AFTERSIGNAL Director — full-quality Development\n\nPinned local BF16 Ref2VA and BF16 Qwen3-VL encoder. Native 1344×768, 243 frames, 50-step res_multistep/beta. Use the timeline UI for shot planning, but preserve the queued request and history externally. H3 native audio is never character-dialogue authority; remux approved PCM after visual finishing. The integrated prompt enhancer defaults to local Qwen3.8 at 127.0.0.1:8000 and never stores API keys in workflow state.'

jq --arg note "$note_full" '
  (.nodes[] | select(.id == 1)) |= (
    .widgets_values[0] = "minimax_h3_ref2va_bf16.safetensors"
    | .title = "Pinned BF16 Ref2VA — full quality"
    | del(.properties.models)
  )
  | (.nodes[] | select(.id == 2)) |= (
      .widgets_values[0] = "qwen3vl_32b_minimax_h3_bf16.safetensors"
      | del(.properties.models)
    )
  | (.nodes[] | select(.id == 5)) |= (
      .title = "MiniMax H3 Director — BF16 Full Quality Development"
      | .widgets_values[1] = ""
      | .widgets_values[5] = "fixed"
      | .widgets_values[7] = 1344
      | .widgets_values[8] = 768
      | .widgets_values[9] = 1344
      | .widgets_values[10] = 243
      | .widgets_values[11] |= (
          fromjson
          | .totalFrames = 243
          | .frameRate = 24
          | .width = 1344
          | .height = 768
          | .refMaxSize = 1344
          | .output.width = 1344
          | .output.height = 768
          | .output.longEdge = 1344
          | .output.refImageSize = "match"
          | .output.audioMode = "generate"
          | .output.continuityEnabled = false
          | .global.prompt = ""
          | .global.refs = []
          | .segments = [{
              id: "s0", start: 0, length: 243, frameCount: 243,
              durationSec: 10, prompt: "", taskType: "", refs: [],
              referenceVideo: {}, genImage: {imageFile: ""}, negativePrompt: ""
            }]
          | .gen.defaultFrameCount = 243
          | tojson
        )
      | .widgets_values[13] = 50
      | .widgets_values[14] = "res_multistep"
      | .widgets_values[15] = "beta"
      | .widgets_values[16] = 12
      | .widgets_values[17] = 3
    )
  | (.nodes[] | select(.id == 7) | .widgets_values[0]) =
      "video/AFTERSIGNAL_H3_Director_REF2VA_BF16_Development"
  | (.nodes[] | select(.id == 11) | .widgets_values[0]) = $note
' "$source_workflow" >"$full"

note_turbo=$'## AFTERSIGNAL Director — qualified Ref2VA Turbo Development\n\nThis is the already reviewed visual blocking profile: `minimax_h3_ref2v_turbo_4step_v0.1_comfyui_bf16.safetensors`, strength 1.0, four Euler/simple steps, shifts 12/3, 960×544, 243 frames, reference resize `match`. The RHEA Hush visual result was user-affirmed as great; its dialogue performance was separately rejected as robotic. Turbo qualification does not authorize its native audio or cross-family LoRA substitution.'
jq --arg note "$note_turbo" '
  .last_node_id = 12
  | .last_link_id = 12
  | (.nodes[] | select(.id != 1) | .order) += 1
  | (.nodes[] | select(.id == 1) | .outputs[0].links) = [1]
  | (.nodes[] | select(.id == 5) | .inputs[0].link) = 12
  | (.links[] | select(.[0] == 1)) = [1,1,0,12,0,"MODEL"]
  | .nodes += [{
      id: 12,
      type: "LoraLoaderModelOnly",
      pos: [-500, 190],
      size: [360, 82],
      flags: {},
      order: 1,
      mode: 0,
      inputs: [
        {name: "model", type: "MODEL", link: 1},
        {name: "lora_name", type: "COMBO", widget: {name: "lora_name"}, link: null},
        {name: "strength_model", type: "FLOAT", widget: {name: "strength_model"}, link: null}
      ],
      outputs: [{name: "MODEL", type: "MODEL", links: [12]}],
      title: "Qualified Ref2VA Turbo 4-Step — strength 1.0",
      properties: {"Node name for S&R": "LoraLoaderModelOnly"},
      widgets_values: ["minimax_h3_ref2v_turbo_4step_v0.1_comfyui_bf16.safetensors", 1.0]
    }]
  | .links += [[12,12,0,5,0,"MODEL"]]
  | (.nodes[] | select(.id == 5)) |= (
      .title = "MiniMax H3 Director — Qualified Ref2VA Turbo Development"
      | .widgets_values[7] = 960
      | .widgets_values[8] = 544
      | .widgets_values[9] = 960
      | .widgets_values[10] = 243
      | .widgets_values[11] |= (
          fromjson
          | .width = 960
          | .height = 544
          | .refMaxSize = 960
          | .output.width = 960
          | .output.height = 544
          | .output.longEdge = 960
          | .output.refImageSize = "match"
          | tojson
        )
      | .widgets_values[13] = 4
      | .widgets_values[14] = "euler"
      | .widgets_values[15] = "simple"
    )
  | (.nodes[] | select(.id == 7) | .widgets_values[0]) =
      "video/AFTERSIGNAL_H3_Director_REF2VA_Turbo4_Development"
  | (.nodes[] | select(.id == 11) | .widgets_values[0]) = $note
' "$full" >"$turbo"

jq -s -e '
  length == 2
  and all(.[]; . as $graph
    | ([.nodes[].id] | length == (unique | length))
    and ([.links[][0]] | length == (unique | length))
    and all($graph.links[]; . as $edge
      | any($graph.nodes[]; .id == $edge[1])
        and any($graph.nodes[]; .id == $edge[3])))
  and all(.[];
    ([.nodes[] | select(.type == "UNETLoader") | .widgets_values[0]]
      == ["minimax_h3_ref2va_bf16.safetensors"])
    and ([.nodes[] | select(.type == "CLIPLoader") | .widgets_values[0]]
      == ["qwen3vl_32b_minimax_h3_bf16.safetensors"])
    and ([.nodes[] | select(.type == "MiniMaxH3Director")
      | .widgets_values[16:18]] == [[12,3]]))
  and ([.[0].nodes[] | select(.type == "MiniMaxH3Director")
    | .widgets_values[7:11]] == [[1344,768,1344,243]])
  and ([.[0].nodes[] | select(.type == "MiniMaxH3Director")
    | .widgets_values[13:18]] == [[50,"res_multistep","beta",12,3]])
  and ([.[0].nodes[] | select(.type == "LoraLoaderModelOnly")] | length == 0)
  and ([.[1].nodes[] | select(.type == "MiniMaxH3Director")
    | .widgets_values[7:11]] == [[960,544,960,243]])
  and ([.[1].nodes[] | select(.type == "MiniMaxH3Director")
    | .widgets_values[13:18]] == [[4,"euler","simple",12,3]])
  and ([.[1].nodes[] | select(.type == "LoraLoaderModelOnly")
    | .widgets_values] == [[
      "minimax_h3_ref2v_turbo_4step_v0.1_comfyui_bf16.safetensors",1
    ]])
  and all(.[];
    (.nodes[] | select(.type == "MiniMaxH3Director")
      | .widgets_values[11] | fromjson) as $timeline
    | $timeline.totalFrames == 243
      and $timeline.output.refImageSize == "match"
      and $timeline.global.refs == [])
' "$full" "$turbo" >/dev/null

if grep -RqiE 'pruned_int8|nvfp4|resolve/main|tree/main|ComfyUI-Manager|api_token|mie_llm_keys' "$output_dir"; then
  printf 'Director workflows retain a lower-quality selector, mutable model URL, Manager, or embedded credential\n' >&2
  exit 1
fi
[[ $(find "$output_dir" -type f -name '*.json' | wc -l) -eq 2 ]]
