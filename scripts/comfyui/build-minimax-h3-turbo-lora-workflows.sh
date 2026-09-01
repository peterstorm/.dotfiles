#!/usr/bin/env bash
set -euo pipefail

usage() {
  printf 'Usage: %s --i2v-source FILE --ref2v-source FILE --pdd-source FILE --output-dir DIR\n' "$0" >&2
  exit 64
}

i2v_source=
ref2v_source=
pdd_source=
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
    --pdd-source)
      [[ $# -ge 2 ]] || usage
      pdd_source=$2
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

[[ -f "$i2v_source" && -f "$ref2v_source" && -f "$pdd_source" && -n "$output_dir" ]] || usage
expected_pdd_source_sha=9ef2d4914e3256fb3d025be80b00f28047ea48d41c2d61b10558354b5c23ac69
[[ $(sha256sum "$pdd_source" | cut -d' ' -f1) == "$expected_pdd_source_sha" ]] || {
  echo "unexpected PDD workflow source checksum" >&2
  exit 1
}
mkdir -p "$output_dir"

t2v8="$output_dir/00 MiniMax H3 BF16 FL2VA Turbo 8-Step - Prompt Only Mechanics Test.json"
fl4="$output_dir/01 MiniMax H3 BF16 FL2VA Turbo 4-Step 768p - First Last Test.json"
fl8="$output_dir/02 MiniMax H3 BF16 FL2VA Turbo 8-Step - First Last Test.json"
ref4="$output_dir/03 MiniMax H3 BF16 REF2VA Turbo 4-Step - Reference Test.json"
pdd_fl8="$output_dir/04 MiniMax H3 BF16 FL2VA PDD Acc 8-Step - Prompt Test.json"
pdd_ref8="$output_dir/05 MiniMax H3 BF16 REF2VA PDD Acc 8-Step - Reference Test.json"

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

pdd_fl_prompt='summary:
[reference generation] One continuous prompt-only mechanics qualification shot with one anonymous subject pair, one causal physical beat, and no internal cuts.

detailed_description:
[Shot 1] Describe opening geometry, planted support, action initiation, exact path, one contact or near-contact event, receiver reaction, and short settle in chronological order. Use a static medium-close camera. Do not add identity references, a second exchange, or a scene transition.

overall_soundscape:
Describe only synchronized ambience, movement, contact, and recovery sounds.

non_diegetic_music:
N/A'
pdd_ref_prompt='subject_definitions:
<Subject 1> is the appearance reference in <Picture 1>. Preserve only its supplied visible identity, proportions, and materials.

summary:
[reference generation] One continuous reference-driven mechanics qualification shot with one causal physical beat and no internal cuts.

retention_analysis:
<Subject 1> (appears in [Shot 1]): fully_preserved - preserve the supplied visible appearance throughout.

detailed_description:
[Shot 1] Describe opening geometry, planted support, action initiation, exact path, one contact or near-contact event, receiver reaction, and short settle in chronological order. Use one restrained camera move. Do not add a second exchange or scene transition.

overall_soundscape:
Describe only synchronized ambience, movement, contact, and recovery sounds.

non_diegetic_music:
N/A'
pdd_note='PDD distills do not stack with Turbo or other acceleration LoRAs. This is not an ordinary LoRA graph: MiniMaxH3PDDAccApply loads the rank-64 trunk adapter, parallel-decoding head bank, and trained sigma boundaries together. Use Euler, CFG 1, shifts 12/3, NFE 8, LoRA/head strengths 1.0, and on_off_grid=error. Keep task families exact. Private local Development qualification only; preserve graph, request, history, inputs, seed, runtime, and output before judging quality.'

build_pdd() {
  local destination=$1 family=$2 pdd_file=$3 prompt=$4 prefix=$5 with_reference=$6
  jq \
    --arg family "$family" \
    --arg pdd_file "$pdd_file" \
    --arg prompt "$prompt" \
    --arg prefix "$prefix" \
    --arg note "$pdd_note" \
    --argjson with_reference "$with_reference" '
      .last_node_id = (if $with_reference then 100 else .last_node_id end)
      | .last_link_id = (if $with_reference then 100 else .last_link_id end)
      | (.nodes[] | select(.id == 1)) |= (
          .title = "ON-DEMAND — unpruned BF16 \($family)"
          | .widgets_values = ["minimax_h3_\($family)_bf16.safetensors", "default"]
          | del(.properties.models)
        )
      | (.nodes[] | select(.id == 2)) |= (
          .title = "ON-DEMAND — BF16 Qwen3-VL-32B"
          | .widgets_values = ["qwen3vl_32b_minimax_h3_bf16.safetensors", "minimax", "default"]
          | del(.properties.models)
        )
      | (.nodes[] | select(.id == 5)) |= (
          .title = "PDD training grid — shifts 12/3 exactly"
          | .widgets_values = [12, 3]
        )
      | (.nodes[] | select(.id == 6)) |= (
          .title = "Dedicated PDD loader — trunk + head bank + trained sigmas"
          | .widgets_values = [$pdd_file, "8", 1.0, 1.0, "error"]
        )
      | (.nodes[] | select(.id == 7)) |= (
          .title = (if $with_reference then "PDD Ref2VA — Picture 1 appearance reference" else "PDD FL2VA-family — prompt-only mechanics" end)
          | .widgets_values = [$prompt, 960, 544, 124, "match"]
        )
      | (.nodes[] | select(.id == 9)) |= (
          .title = "PDD requires Euler"
          | .widgets_values = ["euler"]
        )
      | (.nodes[] | select(.id == 10)) |= (
          .title = "Fixed paired-comparison seed"
          | .widgets_values = [872605, "fixed"]
        )
      | (.nodes[] | select(.id == 15) | .widgets_values[0]) = $prefix
      | (.nodes[] | select(.id == 17)) |= (
          .title = "AFTERSIGNAL PDD qualification contract"
          | .widgets_values = [$note]
        )
      | (.nodes[] | select(.id == 18)) |= (
          .title = "Required PDD recipe — never wire BasicScheduler sigmas"
          | .widgets_values = ["MiniMaxH3PDDAccApply sigmas → SamplerCustomAdvanced. Euler only; CFG 1; shifts 12/3; NFE 8; strengths 1/1; off-grid error. No Turbo, cache, or second distill adapter."]
        )
      | if $with_reference then
          (.nodes[] | select(.id == 7) | .inputs[] | select(.name == "ref_images.ref_image_0") | .link) = 100
          | .nodes += [{
              "id": 100,
              "type": "LoadImage",
              "pos": [-520, 120],
              "size": [320, 314],
              "flags": {},
              "order": 4,
              "mode": 0,
              "inputs": [
                {"name":"image","type":"COMBO","widget":{"name":"image"},"link":null},
                {"name":"upload","type":"IMAGEUPLOAD","widget":{"name":"upload"},"link":null}
              ],
              "outputs": [
                {"name":"IMAGE","type":"IMAGE","links":[100]},
                {"name":"MASK","type":"MASK","links":null}
              ],
              "properties": {"cnr_id":"comfy-core","ver":"0.33.3","Node name for S&R":"LoadImage"},
              "title": "Picture 1 — appearance reference",
              "widgets_values": ["pdd-qualification/subject_1.png", "image"],
              "widgets_values_named": {"image":"pdd-qualification/subject_1.png","upload":"image"}
            }]
          | .links += [[100, 100, 0, 7, 3, "IMAGE"]]
        else . end
      | walk(if type == "object" then del(.models) else . end)
    ' "$pdd_source" >"$destination"
}

build_pdd "$pdd_fl8" fl2va MiniMax-H3-FL2VA-Acc-8Step.safetensors \
  "$pdd_fl_prompt" video/AFTERSIGNAL_H3_FL2VA_PDD8_Prompt_Development false
build_pdd "$pdd_ref8" ref2va MiniMax-H3-Ref2VA-Acc-8Step.safetensors \
  "$pdd_ref_prompt" video/AFTERSIGNAL_H3_REF2VA_PDD8_Reference_Development true

jq -s -e '
  length == 2
  and all(.[]; . as $workflow
    | ([.nodes[].id] | length == (unique | length))
    and all(.links[]; . as $edge
      | any($workflow.nodes[]; .id == $edge[1])
      and any($workflow.nodes[]; .id == $edge[3]))
    and ([.nodes[] | select(.type == "MiniMaxH3PDDAccApply") | .widgets_values[1:5]]
      == [["8", 1, 1, "error"]])
    and ([.nodes[] | select(.type == "MiniMaxH3SigmaShift") | .widgets_values] == [[12, 3]])
    and ([.nodes[] | select(.type == "KSamplerSelect") | .widgets_values] == [["euler"]])
    and ([.nodes[] | select(.type == "BasicScheduler" or .type == "LoraLoaderModelOnly")] | length) == 0
    and ([.nodes[] | select(.type == "MiniMaxH3ReferenceToVideo") | .widgets_values[1:5]]
      == [[960, 544, 124, "match"]]))
  and ([.[0].nodes[] | select(.type == "UNETLoader") | .widgets_values[0]]
    == ["minimax_h3_fl2va_bf16.safetensors"])
  and ([.[0].nodes[] | select(.type == "MiniMaxH3PDDAccApply") | .widgets_values[0]]
    == ["MiniMax-H3-FL2VA-Acc-8Step.safetensors"])
  and ([.[0].nodes[] | select(.type == "LoadImage")] | length) == 0
  and ([.[1].nodes[] | select(.type == "UNETLoader") | .widgets_values[0]]
    == ["minimax_h3_ref2va_bf16.safetensors"])
  and ([.[1].nodes[] | select(.type == "MiniMaxH3PDDAccApply") | .widgets_values[0]]
    == ["MiniMax-H3-Ref2VA-Acc-8Step.safetensors"])
  and ([.[1].nodes[] | select(.type == "LoadImage") | .widgets_values[0]]
    == ["pdd-qualification/subject_1.png"])
' "$pdd_fl8" "$pdd_ref8" >/dev/null

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
[[ $(find "$output_dir" -type f -name '*.json' | wc -l) -eq 6 ]]
