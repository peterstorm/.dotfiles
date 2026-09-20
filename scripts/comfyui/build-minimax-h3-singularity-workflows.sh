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

singularity_model='minimax_h3_singularity_ref2va_v1.3_int8.safetensors'
official_model='minimax_h3_ref2va_bf16.safetensors'
text_encoder='qwen3vl_32b_minimax_h3_bf16.safetensors'
ref2v_8step='minimax_h3_ref2v_turbo_8step_v1.0_768p_comfyui_bf16.safetensors'
ref2v_4step='minimax_h3_ref2v_turbo_4step_v0.1_comfyui_bf16.safetensors'
fixed_seed=20260919

prompt='subject_definitions:
<Subject 1> is the complete main character in <Picture 1>; preserve the supplied full-body proportions, clothing, silhouette, and visible materials.
<Subject 2> is the face-detail reference in <Picture 2>; transfer only facial identity and hair detail to <Subject 1>, not its crop or background.
<Subject 3> is the hand-and-grip detail in <Picture 3>; transfer only hand anatomy, glove details, and grip geometry to <Subject 1>.
<Subject 4> is the hero prop in <Picture 4>; preserve its exact shape, scale, material, and markings whenever it is visible.

summary:
[reference generation] One continuous action shot contains one causal physical beat involving <Subject 1> and <Subject 4>. The role-separated references preserve identity and high-risk details without acting as keyframes.

retention_analysis:
<Subject 1> (appears in [Shot 1]): fully_preserved - preserve the complete approved look from <Picture 1>.
<Subject 2> (appears in [Shot 1]): attribute_transfer - transfer face and hair identity only.
<Subject 3> (appears in [Shot 1]): attribute_transfer - transfer hand, glove, and grip detail only.
<Subject 4> (appears in [Shot 1]): fully_preserved - preserve the supplied prop design.

detailed_description:
[Shot 1] Replace this paragraph with one continuous 5–10 second action beat. State the opening geometry and planted support, then the trigger, acceleration, body and prop path, one contact or near-contact event, visible receiver and environmental response, recovery, and final state in chronological order. Specify one camera movement by type, direction, speed, amplitude, and followed subject. Tie sparks, dust, cloth, hair, reflections, debris, and lighting changes to their physical causes. Do not request internal cuts or a second exchange.

overall_soundscape:
Describe only synchronized ambience, movement, prop, contact, and recovery sounds.

non_diegetic_music:
N/A'

common_note='## MiniMax H3 Singularity v1.3 — private local Development candidate

Source conclusion: the fixed-seed video comparison found Singularity sharper, better at distant faces, stronger in fast combat, and more natural than the official INT8 checkpoint; the author replaced the old model. That is useful evidence, not workstation qualification. This graph adopts the reusable parts: role-separated full-look, face, hand/grip, and prop references; one causal action beat; fixed-seed A/B; and explicit 4-step versus 8-step profiles. Preserve prompt, inputs, seed, runtime, output, and model hashes. Inspect identity, anatomy, prop topology, contact, motion smear, lighting, and audio before accepting a clip.'

build_profile() {
  local destination=$1 model=$2 lora=$3 steps=$4 megapixels=$5 width=$6 height=$7 title=$8 prefix=$9 profile_note=${10}
  jq \
    --arg model "$model" \
    --arg lora "$lora" \
    --arg encoder "$text_encoder" \
    --arg prompt "$prompt" \
    --arg title "$title" \
    --arg prefix "$prefix" \
    --arg note "$common_note\n\n$profile_note" \
    --argjson steps "$steps" \
    --argjson seed "$fixed_seed" \
    --argjson megapixels "$megapixels" \
    --argjson width "$width" \
    --argjson height "$height" '
      (.nodes[] | select(.id == 141)) as $reference_template
      | .last_node_id = ([.last_node_id, 200] | max)
      | .last_link_id = ([.last_link_id, 500] | max)
      | (.nodes[] | select(.id == 127)) |= (
          .title = $title
          | .widgets_values = [$model, "default"]
          | del(.properties.models)
        )
      | (.nodes[] | select(.id == 128)) |= (
          .title = "BF16 Qwen3-VL-32B — shared A/B encoder"
          | .widgets_values = [$encoder, "minimax", "default"]
          | del(.properties.models)
        )
      | (.nodes[] | select(.id == 143)) |= (
          .title = "Task-matched Ref2V acceleration — strength 1.0"
          | .widgets_values = [$lora, 1]
          | del(.properties.models)
        )
      | (.nodes[] | select(.id == 124)) |= (
          .title = "Pinned Euler/simple profile — \($steps) steps"
          | .widgets_values = ["simple", $steps, 1]
        )
      | (.nodes[] | select(.id == 123) | .widgets_values) = ["euler"]
      | (.nodes[] | select(.id == 142)) |= (
          .title = "Pinned MiniMax H3 shifts"
          | .widgets_values = [12, 3]
        )
      | (.nodes[] | select(.id == 129)) |= (
          .title = "Fixed seed — change only after A/B"
          | .widgets_values = [$seed, "fixed"]
        )
      | (.nodes[] | select(.id == 115)) |= (
          .title = "Pinned \($width)×\($height) action profile"
          | .widgets_values = ["16:9 (Widescreen)", $megapixels, 32]
        )
      | (.nodes[] | select(.id == 132)) |= (
          .title = "10-second action qualification"
          | .widgets_values = [10]
        )
      | (.nodes[] | select(.id == 136)) |= (
          .title = "Four role-separated references — never automatic keyframes"
          | (.inputs[] | select(.name == "ref_images.ref_image_3") | .link) = 500
          | .widgets_values = ["", $width, $height, 243, "match"]
        )
      | (.nodes[] | select(.id == 137)) |= (
          .title = "Picture 1 — approved complete full-look"
          | .widgets_values[0] = "singularity-action/full_look.png"
        )
      | (.nodes[] | select(.id == 139)) |= (
          .title = "Picture 2 — face and hair detail only"
          | .widgets_values[0] = "singularity-action/face_detail.png"
        )
      | (.nodes[] | select(.id == 141)) |= (
          .title = "Picture 3 — hand and grip detail only"
          | .widgets_values[0] = "singularity-action/hand_grip_detail.png"
        )
      | .nodes += [($reference_template
          | .id = 200
          | .pos[0] += 360
          | .order += 1
          | .title = "Picture 4 — hero prop only"
          | .widgets_values[0] = "singularity-action/hero_prop.png"
          | .outputs[0].links = [500]
        )]
      | (.nodes[] | select(.id == 138)) |= (
          .title = "One causal action beat — role-aware H3 prompt"
          | .widgets_values = [$prompt]
        )
      | (.nodes[] | select(.id == 92) | .widgets_values[0]) = $prefix
      | (.nodes[] | select(.id == 116)) |= (
          .title = "Singularity evidence and qualification contract"
          | .widgets_values = [$note]
        )
      | (.nodes[] | select(.id == 117)) |= (
          .title = "Pinned artifacts — no runtime downloads"
          | .widgets_values = ["Singularity model and Ref2V 8-step LoRA are revision-, size-, and SHA-256-pinned by download-minimax-h3-singularity-models. The 4-step LoRA, BF16 encoder, and VAEs come from the separately verified base H3 profile."]
        )
      | .links += [[500, 200, 0, 136, 6, "IMAGE"]]
      | walk(if type == "object" then del(.models) else . end)
    ' "$source_workflow" >"$destination"
}

singularity_8="$output_dir/00 MiniMax H3 Singularity v1.3 REF2VA 8-Step - Action Quality.json"
singularity_4="$output_dir/01 MiniMax H3 Singularity v1.3 REF2VA 4-Step - Fast Iterate.json"
official_8="$output_dir/02 MiniMax H3 Official BF16 REF2VA 8-Step - Fixed-Seed A-B Control.json"

build_profile "$singularity_8" "$singularity_model" "$ref2v_8step" 8 0.98 1344 768 \
  'Singularity v1.3 full 34 GB INT8 — 8-step action candidate' \
  'video/AFTERSIGNAL_H3_Singularity_v1_3_Ref2VA_8Step_Development' \
  'Primary quality candidate from the video conclusion. Use this before the 4-step profile for difficult combat, distant faces, or fast prop motion.'
build_profile "$singularity_4" "$singularity_model" "$ref2v_4step" 4 0.5 960 544 \
  'Singularity v1.3 full 34 GB INT8 — 4-step fast candidate' \
  'video/AFTERSIGNAL_H3_Singularity_v1_3_Ref2VA_4Step_Development' \
  'Fast iteration candidate. The transcript reports mild noise at four steps; promote no result without comparison to the 8-step graph.'
build_profile "$official_8" "$official_model" "$ref2v_8step" 8 0.98 1344 768 \
  'Official unpruned BF16 Ref2VA — fixed-seed control' \
  'video/AFTERSIGNAL_H3_Official_BF16_Ref2VA_8Step_AB_Control' \
  'A/B control: same graph, prompt, references, dimensions, seed, LoRA, shifts, sampler, and steps; only the diffusion checkpoint differs.'

jq -s -e --arg singularity "$singularity_model" --arg official "$official_model" --arg lora8 "$ref2v_8step" --arg lora4 "$ref2v_4step" --arg encoder "$text_encoder" '
  length == 3
  and all(.[]; . as $workflow
    | ([.nodes[].id] | length == (unique | length))
    and ([.links[][0]] | length == (unique | length))
    and all(.links[]; . as $edge
      | any($workflow.nodes[]; .id == $edge[1])
      and any($workflow.nodes[]; .id == $edge[3]))
    and ([.nodes[] | select(.type == "LoadImage") | .widgets_values[0]] == [
      "singularity-action/full_look.png",
      "singularity-action/face_detail.png",
      "singularity-action/hand_grip_detail.png",
      "singularity-action/hero_prop.png"
    ])
    and ([.nodes[] | select(.type == "MiniMaxH3ReferenceToVideo")
      | [.inputs[] | select(.name | startswith("ref_images.ref_image_")) | .link]]
      == [[278, 282, 283, 500]])
    and ([.nodes[] | select(.type == "CLIPLoader") | .widgets_values[0]] == [$encoder])
    and ([.nodes[] | select(.type == "MiniMaxH3SigmaShift") | .widgets_values] == [[12, 3]])
    and ([.nodes[] | select(.type == "KSamplerSelect") | .widgets_values] == [["euler"]])
    and ([.nodes[] | select(.type == "RandomNoise") | .widgets_values] == [[20260919, "fixed"]]))
  and ([.[0].nodes[] | select(.type == "ResolutionSelector") | .widgets_values] == [["16:9 (Widescreen)", 0.98, 32]])
  and ([.[0].nodes[] | select(.type == "UNETLoader") | .widgets_values[0]] == [$singularity])
  and ([.[0].nodes[] | select(.type == "LoraLoaderModelOnly") | .widgets_values] == [[$lora8, 1]])
  and ([.[0].nodes[] | select(.type == "BasicScheduler") | .widgets_values] == [["simple", 8, 1]])
  and ([.[1].nodes[] | select(.type == "ResolutionSelector") | .widgets_values] == [["16:9 (Widescreen)", 0.5, 32]])
  and ([.[1].nodes[] | select(.type == "UNETLoader") | .widgets_values[0]] == [$singularity])
  and ([.[1].nodes[] | select(.type == "LoraLoaderModelOnly") | .widgets_values] == [[$lora4, 1]])
  and ([.[1].nodes[] | select(.type == "BasicScheduler") | .widgets_values] == [["simple", 4, 1]])
  and ([.[2].nodes[] | select(.type == "ResolutionSelector") | .widgets_values] == [["16:9 (Widescreen)", 0.98, 32]])
  and ([.[2].nodes[] | select(.type == "UNETLoader") | .widgets_values[0]] == [$official])
  and ([.[2].nodes[] | select(.type == "LoraLoaderModelOnly") | .widgets_values] == [[$lora8, 1]])
  and ([.[2].nodes[] | select(.type == "BasicScheduler") | .widgets_values] == [["simple", 8, 1]])
' "$singularity_8" "$singularity_4" "$official_8" >/dev/null

if grep -RqiE 'resolve/main|tree/main|ComfyUI-Manager|api[_-]?key|token' "$output_dir"; then
  echo 'Singularity workflows retain a mutable link, Manager dependency, or credential field' >&2
  exit 1
fi
[[ $(find "$output_dir" -type f -name '*.json' | wc -l) -eq 3 ]]
