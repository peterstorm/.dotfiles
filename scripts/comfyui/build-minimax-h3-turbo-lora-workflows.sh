#!/usr/bin/env bash
set -euo pipefail

usage() {
  printf 'Usage: %s --i2v-source FILE --ref2v-source FILE --output-dir DIR\n' "$0" >&2
  exit 64
}

i2v_source=
ref2v_source=
output_dir=
while (($#)); do
  case "$1" in
    --i2v-source)
      [[ $# -ge 2 ]] || usage
      i2v_source=$2
      shift 2
      ;;
    --ref2v-source)
      [[ $# -ge 2 ]] || usage
      ref2v_source=$2
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

[[ -f "$i2v_source" && -f "$ref2v_source" && -n "$output_dir" ]] || usage
mkdir -p "$output_dir"

t2v8="$output_dir/00 MiniMax H3 BF16 FL2VA Turbo 8-Step - Prompt Only Mechanics Test.json"
fl4="$output_dir/01 MiniMax H3 BF16 FL2VA Turbo 4-Step 768p - First Last Test.json"
fl8="$output_dir/02 MiniMax H3 BF16 FL2VA Turbo 8-Step - First Last Test.json"
ref4="$output_dir/03 MiniMax H3 BF16 REF2VA Turbo 4-Step - Reference Test.json"

fl_prompt='How the reference pictures align with the target video — Picture 1 (from Shot 1) aligns with the 0.00-second mark of the target video; Picture 2 (from Shot 1) aligns with the final frame.\n\nintegrated_multimodal_description: [Shot 1] Paste one prompt-only qualification shot here. Begin exactly from Picture 1 and end exactly on Picture 2. Describe one subject pair, one causal physical beat, one camera move, and one contact or near-contact event in chronological order. Use concrete verbs and visible reactions. Do not request internal cuts.\n\noverall_soundscape: Describe only synchronized ambience, movement, and impact sounds.\n\nnon_diegetic_music: N/A'
fl4_note='## AFTERSIGNAL — FL2VA Turbo 4-step 768p Development test\n\nTask-matched BF16 FL2VA base plus `minimax_h3_fl2v_turbo_4step_v1.0_768p_comfyui_bf16.safetensors` at strength 1.0. Exact source profile: Euler/simple, 4 steps, video/audio shifts 6/3, native 1344×768. Supply independent first and last frames. This profile is unqualified: preserve request, history, seed, inputs, output, and runtime before judging it. Do not use it as Production authority.'
fl8_note='## AFTERSIGNAL — FL2VA Turbo 8-step Development test\n\nTask-matched BF16 FL2VA base plus `minimax_h3_fl2v_turbo_8step_v1.0_comfyui_bf16.safetensors` at strength 1.0. Exact source profile: Euler/simple, 8 steps, video/audio shifts 12/3, 864×480. Supply independent first and last frames. Compare against the four-step graph with the same prompt, frames, and seed. This profile is unqualified and cannot be promoted by technical QA.'

build_fl2va() {
  local destination=$1 lora=$2 steps=$3 shift_video=$4 megapixels=$5 width=$6 height=$7 prefix=$8 note=$9
  jq \
    --arg lora "$lora" \
    --arg prompt "$fl_prompt" \
    --arg prefix "$prefix" \
    --arg note "$note" \
    --argjson steps "$steps" \
    --argjson shift_video "$shift_video" \
    --argjson megapixels "$megapixels" \
    --argjson width "$width" \
    --argjson height "$height" '
      (.nodes[] | select(.id == 114)) as $first
      | .last_node_id = ([.last_node_id, 500] | max)
      | .last_link_id = ([.last_link_id, 500] | max)
      | (.nodes[] | select(.id == 114)) |= (
          .title = "Picture 1 — exact first frame"
          | .widgets_values[0] = "first_frame.png"
        )
      | .nodes += [($first
          | .id = 500
          | .pos[1] += 720
          | .order += 1
          | .title = "Picture 2 — exact last frame"
          | .widgets_values[0] = "last_frame.png"
          | .outputs[0].links = [500]
        )]
      | (.nodes[] | select(.id == 105)) |= (
          .title = "BF16 FL2VA Turbo prompt-only qualification"
          | (.inputs[] | select(.name == "last_frame") | .link) = 500
          | .widgets_values[0] = $prompt
          | .widgets_values[1] = $width
          | .widgets_values[2] = $height
          | .widgets_values[5] = "minimax_h3_fl2va_bf16.safetensors"
          | .widgets_values[6] = "qwen3vl_32b_minimax_h3_bf16.safetensors"
          | .widgets_values[9] = $lora
          | .widgets_values[10] = $shift_video
          | .widgets_values[11] = 3
          | .widgets_values[12] = $steps
          | .widgets_values[13] = "euler"
        )
      | (.nodes[] | select(.id == 115)) |= (
          .title = "Pinned qualification resolution"
          | .widgets_values = ["16:9 (Widescreen)", $megapixels, 32]
        )
      | (.nodes[] | select(.id == 92) | .widgets_values[0]) = $prefix
      | (.nodes[] | select(.id == 116 or .id == 117)) |= (
          .title = "AFTERSIGNAL qualification contract"
          | .widgets_values = [$note]
        )
      | .links += [[500, 500, 0, 105, 1, "IMAGE"]]
      | (.definitions.subgraphs[].nodes[] | select(.type == "UNETLoader")) |= (
          .widgets_values = ["minimax_h3_fl2va_bf16.safetensors", "default"]
          | del(.properties.models)
        )
      | (.definitions.subgraphs[].nodes[] | select(.type == "CLIPLoader")) |= (
          .widgets_values = ["qwen3vl_32b_minimax_h3_bf16.safetensors", "minimax", "default"]
          | del(.properties.models)
        )
      | (.definitions.subgraphs[].nodes[] | select(.type == "LoraLoaderModelOnly")) |= (
          .widgets_values = [$lora, 1]
          | del(.properties.models)
        )
      | (.definitions.subgraphs[].nodes[] | select(.type == "MiniMaxH3SigmaShift") | .widgets_values) = [$shift_video, 3]
      | (.definitions.subgraphs[].nodes[] | select(.type == "BasicScheduler") | .widgets_values) = ["simple", $steps, 1]
      | (.definitions.subgraphs[].nodes[] | select(.type == "KSamplerSelect") | .widgets_values) = ["euler"]
      | walk(if type == "object" then del(.models) else . end)
    ' "$i2v_source" >"$destination"
}

build_fl2va "$fl4" \
  minimax_h3_fl2v_turbo_4step_v1.0_768p_comfyui_bf16.safetensors \
  4 6 0.98 1344 768 video/AFTERSIGNAL_H3_FL2VA_Turbo4_768p_Development "$fl4_note"
build_fl2va "$fl8" \
  minimax_h3_fl2v_turbo_8step_v1.0_comfyui_bf16.safetensors \
  8 12 0.4 864 480 video/AFTERSIGNAL_H3_FL2VA_Turbo8_Development "$fl8_note"

t2v_prompt='integrated_multimodal_description: [Shot 1] Live-action physical-action mechanics test. Paste one anonymous-subject test here. Use one continuous 3–5 second shot, one physical beat, and a static medium-close camera. Describe initial geometry, load, limb or object path, exact contact time and surfaces, receiver response, and short settle in chronological order. Do not identify AEGIS, request cuts, or add a second exchange.\n\noverall_soundscape: Describe only synchronized room tone, movement, contact, and recovery sounds.\n\nnon_diegetic_music: N/A'
t2v_note='## AFTERSIGNAL — prompt-only mechanics isolation\n\nThis zero-reference graph intentionally uses the task-compatible BF16 FL2VA family as T2VA with the eight-step FL2VA Turbo adapter. It is not zero-reference Ref2VA and is not a dedicated T2VA checkpoint. Euler/simple, 8 steps, shifts 12/3, 864×480. Use anonymous subjects and one contact beat to test whether H3 can execute the mechanics before adding AEGIS identity, references, camera movement, or cuts.'
jq --arg prompt "$t2v_prompt" --arg note "$t2v_note" '
  .nodes |= map(select(.id != 114 and .id != 500))
  | .links |= map(select(.[0] != 218 and .[0] != 500))
  | (.nodes[] | select(.id == 105)) |= (
      .title = "BF16 FL2VA-family Turbo — zero-reference prompt mechanics"
      | (.inputs[] | select(.name == "first_frame" or .name == "last_frame") | .link) = null
      | .widgets_values[0] = $prompt
    )
  | (.nodes[] | select(.id == 92) | .widgets_values[0]) = "video/AFTERSIGNAL_H3_PromptMechanics_Turbo8_Development"
  | (.nodes[] | select(.id == 116 or .id == 117)) |= (
      .title = "AFTERSIGNAL prompt-only qualification contract"
      | .widgets_values = [$note]
    )
' "$fl8" >"$t2v8"

ref_prompt='subject_definitions:\n<Subject 1> is the appearance reference in <Picture 1>. Use it only for the first subject’s visible identity and materials.\n<Subject 2> is the appearance reference in <Picture 2>. Use it only for the second subject’s visible identity and materials.\n<Subject 3> is the environment reference in <Picture 3>. Use it only for setting, scale cues, and lighting.\n\nsummary:\n[reference generation] Paste one prompt-only qualification shot here. One continuous shot contains one causal physical beat and one primary camera move.\n\nretention_analysis:\n<Subject 1> (appears in [Shot 1]): fully_preserved - preserve only its supplied visible appearance.\n<Subject 2> (appears in [Shot 1]): fully_preserved - preserve only its supplied visible appearance.\n<Subject 3> (appears in [Shot 1]): fully_preserved - preserve the supplied environment and lighting.\n\ndetailed_description:\n[Shot 1] Describe the opening positions, planted support, action initiation, exact path, one contact or near-contact event, receiver reaction, and short recovery in chronological order. Name one camera move with type, amplitude, and speed. Do not request internal cuts or a sequence of exchanges.\n\noverall_soundscape:\nDescribe only synchronized ambience, movement, and impact sounds.\n\nnon_diegetic_music:\nN/A'
ref_note='## AFTERSIGNAL — Ref2VA Turbo 4-step Development control\n\nTask-matched BF16 Ref2VA base plus `minimax_h3_ref2v_turbo_4step_v0.1_comfyui_bf16.safetensors` at strength 1.0. Exact source profile: Euler/simple, 4 steps, shifts 12/3, 960×544, reference resize `match`. This is the previously qualified speed profile, included as a control beside the two unqualified FL2VA candidates. Reference images provide appearance; the prompt describes one temporal action. No technical result promotes an asset.'

jq \
  --arg prompt "$ref_prompt" \
  --arg note "$ref_note" '
    (.nodes[] | select(.id == 127)) |= (
        .widgets_values = ["minimax_h3_ref2va_bf16.safetensors", "default"]
        | del(.properties.models)
      )
    | (.nodes[] | select(.id == 128)) |= (
        .widgets_values = ["qwen3vl_32b_minimax_h3_bf16.safetensors", "minimax", "default"]
        | del(.properties.models)
      )
    | (.nodes[] | select(.id == 115)) |= (
        .title = "Pinned 960×544 Ref2VA Turbo control"
        | .widgets_values = ["16:9 (Widescreen)", 0.5, 32]
      )
    | (.nodes[] | select(.id == 123) | .widgets_values) = ["euler"]
    | (.nodes[] | select(.id == 124) | .widgets_values) = ["simple", 4, 1]
    | (.nodes[] | select(.id == 136)) |= (
        .title = "BF16 Ref2VA Turbo prompt-only qualification"
        | .widgets_values = ["", 960, 544, 124, "match"]
      )
    | (.nodes[] | select(.id == 138) | .widgets_values) = [$prompt]
    | (.nodes[] | select(.id == 142) | .widgets_values) = [12, 3]
    | (.nodes[] | select(.id == 143)) |= (
        .widgets_values = ["minimax_h3_ref2v_turbo_4step_v0.1_comfyui_bf16.safetensors", 1]
        | del(.properties.models)
      )
    | (.nodes[] | select(.id == 137)) |= (.title = "Picture 1 — subject 1 appearance" | .widgets_values[0] = "subject_1.png")
    | (.nodes[] | select(.id == 139)) |= (.title = "Picture 2 — subject 2 appearance" | .widgets_values[0] = "subject_2.png")
    | (.nodes[] | select(.id == 141)) |= (.title = "Picture 3 — environment only" | .widgets_values[0] = "environment.png")
    | (.nodes[] | select(.id == 92) | .widgets_values[0]) = "video/AFTERSIGNAL_H3_REF2VA_Turbo4_Control_Development"
    | (.nodes[] | select(.id == 116 or .id == 117)) |= (
        .title = "AFTERSIGNAL qualification contract"
        | .widgets_values = [$note]
      )
    | walk(if type == "object" then del(.models) else . end)
  ' "$ref2v_source" >"$ref4"

jq -s -e '
  length == 4
  and all(.[]; . as $workflow
    | ([.nodes[].id] | length == (unique | length))
    and all(.links[]; . as $edge
      | any($workflow.nodes[]; .id == $edge[1])
      and any($workflow.nodes[]; .id == $edge[3])))
  and ([.[0].nodes[] | select(.id == 105) | [.inputs[0].link, .inputs[1].link]] == [[null, null]])
  and ([.[0].definitions.subgraphs[].nodes[] | select(.type == "LoraLoaderModelOnly") | .widgets_values]
    == [["minimax_h3_fl2v_turbo_8step_v1.0_comfyui_bf16.safetensors", 1]])
  and ([.[1].definitions.subgraphs[].nodes[] | select(.type == "LoraLoaderModelOnly") | .widgets_values]
    == [["minimax_h3_fl2v_turbo_4step_v1.0_768p_comfyui_bf16.safetensors", 1]])
  and ([.[1].definitions.subgraphs[].nodes[] | select(.type == "BasicScheduler") | .widgets_values]
    == [["simple", 4, 1]])
  and ([.[1].definitions.subgraphs[].nodes[] | select(.type == "MiniMaxH3SigmaShift") | .widgets_values]
    == [[6, 3]])
  and ([.[2].definitions.subgraphs[].nodes[] | select(.type == "LoraLoaderModelOnly") | .widgets_values]
    == [["minimax_h3_fl2v_turbo_8step_v1.0_comfyui_bf16.safetensors", 1]])
  and ([.[2].definitions.subgraphs[].nodes[] | select(.type == "BasicScheduler") | .widgets_values]
    == [["simple", 8, 1]])
  and ([.[2].definitions.subgraphs[].nodes[] | select(.type == "MiniMaxH3SigmaShift") | .widgets_values]
    == [[12, 3]])
  and ([.[3].nodes[] | select(.type == "LoraLoaderModelOnly") | .widgets_values]
    == [["minimax_h3_ref2v_turbo_4step_v0.1_comfyui_bf16.safetensors", 1]])
  and ([.[3].nodes[] | select(.type == "BasicScheduler") | .widgets_values]
    == [["simple", 4, 1]])
  and ([.[3].nodes[] | select(.type == "MiniMaxH3SigmaShift") | .widgets_values]
    == [[12, 3]])
  and all(.[];
    ([.. | objects | select(.type? == "UNETLoader") | .widgets_values[0]]
      | all(test("^minimax_h3_(fl2va|ref2va)_bf16\\.safetensors$")))
    and ([.. | objects | select(.type? == "CLIPLoader") | .widgets_values[0]]
      == ["qwen3vl_32b_minimax_h3_bf16.safetensors"]))
' "$t2v8" "$fl4" "$fl8" "$ref4" >/dev/null

if grep -RqiE 'pruned_int8|nvfp4|resolve/main|tree/main|ComfyUI-Manager|api[_-]?key|token' "$output_dir"; then
  echo "Turbo qualification workflows retain a lower-quality selector, mutable model URL, Manager, or credential field" >&2
  exit 1
fi
[[ $(find "$output_dir" -type f -name '*.json' | wc -l) -eq 4 ]]
