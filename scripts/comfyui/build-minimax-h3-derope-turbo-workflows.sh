#!/usr/bin/env bash
# Build the maintained MiniMax H3 Motion Lab Turbo recipes against the
# workstation's full-BF16 base models and task-matched Turbo adapters.
set -euo pipefail

usage() {
  printf 'Usage: %s --ref2va-source FILE --fast-source FILE --upscale-source FILE --output-dir DIR\n' "$0" >&2
  exit 64
}

ref2va_source=
fast_source=
upscale_source=
output_dir=
while (($#)); do
  case "$1" in
    --ref2va-source)
      [[ $# -ge 2 ]] || usage
      ref2va_source=$2
      shift 2
      ;;
    --fast-source)
      [[ $# -ge 2 ]] || usage
      fast_source=$2
      shift 2
      ;;
    --upscale-source)
      [[ $# -ge 2 ]] || usage
      upscale_source=$2
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

[[ -f "$ref2va_source" && -f "$fast_source" && -f "$upscale_source" && -n "$output_dir" ]] || usage

require_sha256() {
  local file=$1 expected=$2 label=$3 actual
  actual=$(sha256sum "$file" | cut -d' ' -f1)
  [[ "$actual" == "$expected" ]] || {
    printf 'unexpected %s source checksum: %s\n' "$label" "$actual" >&2
    exit 1
  }
}

require_sha256 "$ref2va_source" c1f8613eedab77d275e6ed48e00792a1ceb751a27d3dbe0d3c8a05197bd162c5 'REF2VA balanced Turbo workflow'
require_sha256 "$fast_source" ed2970f5bea60d1de402a5d821f7cb2a615655d68906952073bb76e1560531a5 'FL2VA fast-iterate Turbo workflow'
require_sha256 "$upscale_source" 5a49a4a8c04925629e1385a4649562b5d5bc6c1819fcf5971f15d1660f3bc858 'FL2VA upscale Turbo workflow'

mkdir -p "$output_dir"
ref2va="$output_dir/01 MiniMax H3 De-RoPE Turbo v1.1 - REF2VA Balanced Audio Development.json"
fast="$output_dir/02 MiniMax H3 De-RoPE Turbo v1.1 - FL2VA Fast Iterate Development.json"
upscale="$output_dir/03 MiniMax H3 De-RoPE Turbo v1.1 - FL2VA Upscale Development.json"

common_note=$'## MiniMax H3 De-RoPE Turbo v1.1 — Development qualification\n\nThese are MatlowAI MAINodes v1.1.3 maintained August 19 recipes, not the older 25-step graph with a Turbo LoRA dropped into it. Pass 1 stays on the task-matched full-BF16 base for 12 linear-quadratic steps and decides choreography. Only pass 2 receives the task-matched 4-step Turbo adapter; its beta schedule has six total steps and the faithful-detail 0.50 injection executes three.\n\nThe exact chunked-feed-forward patch is retained. Both SageAttention patches are removed because the pinned runtime intentionally has no SageAttention module; ComfyUI uses its supported PyTorch attention path instead. Compare baseline, oracle heatmap, dilated preview, and recovered output. Turbo can lose detail on the exact clip being repaired, so this immutable package remains Development evidence beside the slower v1.0 full-BF16 control.'

build_workflow() {
  local source=$1 destination=$2 model=$3 lora=$4 title=$5 baseline_prefix=$6 recovered_prefix=$7 profile_note=$8
  jq \
    --arg model "$model" \
    --arg lora "$lora" \
    --arg title "$title" \
    --arg note "$common_note" \
    --arg profile_note "$profile_note" \
    --arg baseline_prefix "$baseline_prefix" \
    --arg recovered_prefix "$recovered_prefix" '
      (.nodes[] | select(.type == "UNETLoader")) |= (
        .widgets_values = [$model, "default"]
        | del(.properties.models)
      )
      | (.nodes[] | select(.type == "CLIPLoader")) |= (
          .widgets_values = ["qwen3vl_32b_minimax_h3_bf16.safetensors", "minimax", "default"]
          | del(.properties.models)
        )
      | (.nodes[] | select(.type == "VAELoader" and (.widgets_values[0] | contains("video_vae"))) | .widgets_values[0]) =
          "minimax_h3_video_vae_fp16.safetensors"
      | (.nodes[] | select(.type == "VAELoader" and (.widgets_values[0] | contains("audio_vae"))) | .widgets_values[0]) =
          "minimax_h3_audio_vae_fp32.safetensors"
      | (.nodes[] | select(.type == "LoraLoaderModelOnly")) |= (
          .widgets_values = [$lora, 1]
          | del(.properties.models)
        )
      | (.nodes[] | select(.type == "BasicScheduler") | .widgets_values) = ["linear_quadratic", 12, 1]
      | (.nodes[] | select(.type == "KSamplerSelect") | .widgets_values) = ["gradient_estimation"]
      | (.nodes[] | select(.type == "H3InjectSchedule") | .widgets_values) =
          ["beta", 6, 0.5, "faithful detail 0.50 (metric best)"]
      | .nodes |= map(select(.id != 300 and .id != 301))
      | .links |= map(select(
          (.[1] != 300 and .[3] != 300)
          and (.[1] != 301 and .[3] != 301)))
      | (.nodes[] | select(.id == 127) | .outputs[0].links) = [9201]
      | (.nodes[] | select(.id == 302) | .inputs[0].link) = 9201
      | .links += [[9201, 127, 0, 302, 0, "MODEL"]]
      | .last_link_id = ([.last_link_id, 9201] | max)
      | (.nodes[] | select(.id == 92) | .widgets_values[0]) = $baseline_prefix
      | (.nodes[] | select(.id == 215) | .widgets_values[0]) = $recovered_prefix
      | .last_node_id = ([.last_node_id, 9200] | max)
      | .nodes += [{
          "id": 9200,
          "type": "MarkdownNote",
          "pos": [-720, -920],
          "size": [680, 620],
          "flags": {},
          "order": 50,
          "mode": 0,
          "inputs": [],
          "outputs": [],
          "properties": {},
          "title": $title,
          "widgets_values": [$note + "\n\n" + $profile_note]
        }]
      | walk(if type == "object" then del(.models) else . end)
    ' "$source" >"$destination"
}

build_workflow \
  "$ref2va_source" "$ref2va" \
  minimax_h3_ref2va_bf16.safetensors \
  minimax_h3_ref2v_turbo_4step_v0.1_comfyui_bf16.safetensors \
  'De-RoPE Turbo v1.1 — recommended REF2VA balanced/audio profile' \
  video/DeRoPE_Turbo_v1_1/REF2VA_Balanced_Baseline \
  video/DeRoPE_Turbo_v1_1/REF2VA_Balanced_Recovered \
  'Recommended first trial: replace example.png with one appearance reference. Native 1344×768, 124 frames. The primary recovered output keeps pass-1 audio; the seeded-foley output is an explicit alternate.'

# Preserve the explicit alternate foley output in the audio-initialized graph.
jq '(.nodes[] | select(.id == 9105) | .widgets_values[0]) =
      "video/DeRoPE_Turbo_v1_1/REF2VA_Balanced_Recovered_Seeded_Foley"' \
  "$ref2va" >"$ref2va.tmp"
mv "$ref2va.tmp" "$ref2va"

build_workflow \
  "$fast_source" "$fast" \
  minimax_h3_fl2va_bf16.safetensors \
  minimax_h3_fl2v_turbo_4step_v1.0_768p_comfyui_bf16.safetensors \
  'De-RoPE Turbo v1.1 — FL2VA fast-iterate scouting profile' \
  video/DeRoPE_Turbo_v1_1/FL2VA_FastIterate_Baseline \
  video/DeRoPE_Turbo_v1_1/FL2VA_FastIterate_Recovered \
  'Scouting only: 0.2 MP pass 1 and 0.4 MP De-RoPE pass. Use it to find a prompt, seed, and motion pattern quickly; do not use its image quality to judge a keeper.'

build_workflow \
  "$upscale_source" "$upscale" \
  minimax_h3_fl2va_bf16.safetensors \
  minimax_h3_fl2v_turbo_4step_v1.0_768p_comfyui_bf16.safetensors \
  'De-RoPE Turbo v1.1 — FL2VA integrated-upscale profile' \
  video/DeRoPE_Turbo_v1_1/FL2VA_Upscale_Baseline \
  video/DeRoPE_Turbo_v1_1/FL2VA_Upscale_Recovered \
  'Balanced spatial experiment: pass 1 renders at 0.4 MP and the De-RoPE pass rebuilds at 1.5 MP. It is faster than native high-resolution De-RoPE but can give the oracle softer evidence.'

validate_workflow() {
  local workflow=$1 expected_model=$2 expected_lora=$3
  jq -e --arg expected_model "$expected_model" --arg expected_lora "$expected_lora" '
    . as $workflow
    | ([.nodes[].id] | length == (unique | length))
    and ([.nodes[] | select(.type == "UNETLoader") | .widgets_values[0]]) == [$expected_model]
    and ([.nodes[] | select(.type == "CLIPLoader") | .widgets_values[0]])
      == ["qwen3vl_32b_minimax_h3_bf16.safetensors"]
    and ([.nodes[] | select(.type == "VAELoader") | .widgets_values[0]] | sort)
      == (["minimax_h3_audio_vae_fp32.safetensors", "minimax_h3_video_vae_fp16.safetensors"] | sort)
    and ([.nodes[] | select(.type == "LoraLoaderModelOnly") | .widgets_values])
      == [[$expected_lora, 1]]
    and ([.nodes[] | select(.type == "BasicScheduler") | .widgets_values])
      == [["linear_quadratic", 12, 1]]
    and ([.nodes[] | select(.type == "KSamplerSelect") | .widgets_values]
      | all(. == ["gradient_estimation"]))
    and ([.nodes[] | select(.type == "H3InjectSchedule") | .widgets_values])
      == [["beta", 6, 0.5, "faithful detail 0.50 (metric best)"]]
    and ([.nodes[] | select(.type == "H3JerkOracle")] | length) == 1
    and ([.nodes[] | select(.type == "H3TimeSmear")] | length) == 1
    and ([.nodes[] | select(.type == "H3V2VInit")] | length) == 1
    and ([.nodes[] | select(.type == "H3ExactRecover")] | length) == 1
    and ([.nodes[] | select(.type == "H3AudioSmear")] | length) == 1
    and ([.nodes[] | select(.type == "H3AudioRecover")] | length) >= 1
    and ([.nodes[] | select(.type == "PathchSageAttentionKJ"
      or .type == "MiniMaxH3MemoryEfficientSageAttentionPatch")] | length) == 0
    and ([.nodes[] | select(.type == "MiniMaxChunkFeedForward")] | length) == 1
    and ([.links[] | select(.[1] == 127 and .[3] == 302 and .[4] == 0)])
      == [[9201, 127, 0, 302, 0, "MODEL"]]
    and ([.nodes[] | select(.type == "MarkdownNote" and .id == 9200)] | length) == 1
    and ((.nodes[] | select(.type == "BasicScheduler") | .inputs[0].link) as $base_model_link
      | any(.links[]; .[0] == $base_model_link and .[1] != 303))
    and ((.nodes[] | select(.type == "H3InjectSchedule") | .inputs[0].link) as $turbo_model_link
      | any(.links[]; .[0] == $turbo_model_link and .[1] == 303))
    and all(.links[]; . as $edge
      | any($workflow.nodes[]; .id == $edge[1]
          and any(.outputs[]?; any(.links[]?; . == $edge[0])))
      and any($workflow.nodes[]; .id == $edge[3]
          and any(.inputs[]?; .link == $edge[0])))
  ' "$workflow" >/dev/null
}

validate_workflow "$ref2va" minimax_h3_ref2va_bf16.safetensors \
  minimax_h3_ref2v_turbo_4step_v0.1_comfyui_bf16.safetensors
validate_workflow "$fast" minimax_h3_fl2va_bf16.safetensors \
  minimax_h3_fl2v_turbo_4step_v1.0_768p_comfyui_bf16.safetensors
validate_workflow "$upscale" minimax_h3_fl2va_bf16.safetensors \
  minimax_h3_fl2v_turbo_4step_v1.0_768p_comfyui_bf16.safetensors

jq -e '([.nodes[] | select(.type == "MiniMaxH3ReferenceToVideo")] | length) == 2
  and ([.nodes[] | select(.type == "LoadImage")] | length) == 1
  and ([.nodes[] | select(.type == "H3AudioRecover")] | length) == 2' "$ref2va" >/dev/null
jq -e '([.nodes[] | select(.type == "MiniMaxH3ImageToVideo")] | length) == 2
  and ([.nodes[] | select(.type == "ImageScale")] | length) == 1' "$fast" >/dev/null
jq -e '([.nodes[] | select(.type == "MiniMaxH3ImageToVideo")] | length) == 2
  and ([.nodes[] | select(.type == "ImageScale")] | length) == 1' "$upscale" >/dev/null

if grep -RqiE 'pruned_int8|nvfp4|int8_convrot|lightx2v|resolve/main|tree/main|ComfyUI-Manager|api[_-]?key|token' "$output_dir"; then
  echo 'De-RoPE Turbo workflows retain a lower-quality selector, mismatched community adapter, mutable model URL, Manager, or credential field' >&2
  exit 1
fi
[[ $(find "$output_dir" -type f -name '*.json' | wc -l) -eq 3 ]]
