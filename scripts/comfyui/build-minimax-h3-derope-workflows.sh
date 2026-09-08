#!/usr/bin/env bash
# Build full-BF16 MiniMax H3 De-RoPE workflows from MatlowAI's pinned public
# Motion Lab examples. The Patreon graph shown in the source video is not
# redistributed; these use the node author's GPL-3.0 public examples instead.
set -euo pipefail

usage() {
  printf 'Usage: %s --automatic-source FILE --targeted-source FILE --ref2va-source FILE --output-dir DIR\n' "$0" >&2
  exit 64
}

automatic_source=
targeted_source=
ref2va_source=
output_dir=
while (($#)); do
  case "$1" in
    --automatic-source)
      [[ $# -ge 2 ]] || usage
      automatic_source=$2
      shift 2
      ;;
    --targeted-source)
      [[ $# -ge 2 ]] || usage
      targeted_source=$2
      shift 2
      ;;
    --ref2va-source)
      [[ $# -ge 2 ]] || usage
      ref2va_source=$2
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

[[ -f "$automatic_source" && -f "$targeted_source" && -f "$ref2va_source" && -n "$output_dir" ]] || usage

require_sha256() {
  local file=$1 expected=$2 label=$3 actual
  actual=$(sha256sum "$file" | cut -d' ' -f1)
  [[ "$actual" == "$expected" ]] || {
    printf 'unexpected %s source checksum: %s\n' "$label" "$actual" >&2
    exit 1
  }
}

require_sha256 "$automatic_source" 7773d9e1b6b795b6d8cc8605e9af1e25fd7a1525992815c77ea5da1b1c7f3d4f 'automatic De-RoPE workflow'
require_sha256 "$targeted_source" dd055dc1c62c49135706f3cee94cd46b2ef4720d5829f30a731c9e2bf384edba 'targeted De-RoPE workflow'
require_sha256 "$ref2va_source" c1f8613eedab77d275e6ed48e00792a1ceb751a27d3dbe0d3c8a05197bd162c5 'REF2VA De-RoPE workflow'

mkdir -p "$output_dir"
automatic="$output_dir/01 MiniMax H3 De-RoPE v1.0 - FL2VA Automatic Full BF16 Development.json"
targeted="$output_dir/02 MiniMax H3 De-RoPE v1.0 - FL2VA Targeted Full BF16 Development.json"
ref2va="$output_dir/03 MiniMax H3 De-RoPE v1.0 - REF2VA Audio Full BF16 Development.json"

common_note=$'## MiniMax H3 De-RoPE v1.0 — Development\n\nSource technique: Machine Delusions, “Fixing MiniMax H3 Motion Smearing with De-RoPE” (IlVPJI9ceKM). Implementation and public workflow source: MatlowAI ComfyUI-MAINodes v1.1.3, GPL-3.0.\n\nPass 1 creates the baseline choreography. H3 Jerk Oracle detects fast-motion bursts from its latent; H3 Time Smear repeats affected frames; pass 2 re-diffuses the slowed init; H3 Exact Recover drops held frames to restore exact 24 fps. H3 Audio Smear/VAEEncodeAudio seed the slowed performance, and H3 Audio Recover keeps the original baseline performance by default.\n\nThis workstation adaptation replaces every quantized selector with the installed full-BF16 diffusion/text stack and keeps the video’s 25-step, no-Turbo-LoRA two-pass baseline. Start with 2–3 seconds. De-RoPE is expensive and may reinterpret motion; compare the baseline, oracle map, dilated preview, and recovered output frame-by-frame before keeping it.'

build_fl2va() {
  local source=$1 destination=$2 note_title=$3 baseline_prefix=$4 oracle_prefix=$5 dilated_prefix=$6 recovered_prefix=$7
  jq \
    --arg note "$common_note" \
    --arg note_title "$note_title" \
    --arg baseline_prefix "$baseline_prefix" \
    --arg oracle_prefix "$oracle_prefix" \
    --arg dilated_prefix "$dilated_prefix" \
    --arg recovered_prefix "$recovered_prefix" '
      (.nodes[] | select(.id == 127) | .widgets_values[0]) = "minimax_h3_fl2va_bf16.safetensors"
      | (.nodes[] | select(.id == 128) | .widgets_values[0]) = "qwen3vl_32b_minimax_h3_bf16.safetensors"
      | (.nodes[] | select(.id == 119) | .widgets_values[0]) = "minimax_h3_video_vae_fp16.safetensors"
      | (.nodes[] | select(.id == 120) | .widgets_values[0]) = "minimax_h3_audio_vae_fp32.safetensors"
      | (.nodes[] | select(.type == "BasicScheduler") | .widgets_values) = ["simple", 25, 1]
      | (.nodes[] | select(.type == "KSamplerSelect") | .widgets_values) = ["res_multistep"]
      | (.nodes[] | select(.type == "H3InjectSchedule") | .widgets_values) =
          ["simple", 25, 0.5, "faithful detail 0.50 (metric best)"]
      | (.nodes[] | select(.id == 92) | .widgets_values[0]) = $baseline_prefix
      | (.nodes[] | select(.id == 218) | .widgets_values[0]) = $oracle_prefix
      | (.nodes[] | select(.id == 212) | .widgets_values[0]) = $dilated_prefix
      | (.nodes[] | select(.id == 215) | .widgets_values[0]) = $recovered_prefix
      | .last_node_id = ([.last_node_id, 1000] | max)
      | .nodes += [{
          "id": 1000,
          "type": "MarkdownNote",
          "pos": [-700, -900],
          "size": [620, 560],
          "flags": {},
          "order": 30,
          "mode": 0,
          "inputs": [],
          "outputs": [],
          "properties": {},
          "title": $note_title,
          "widgets_values": [$note]
        }]
      | walk(if type == "object" then del(.models) else . end)
    ' "$source" >"$destination"
}

build_fl2va \
  "$automatic_source" "$automatic" \
  'De-RoPE v1.0 automatic oracle — read before queueing' \
  'video/DeRoPE_v1_0/FL2VA_Automatic_Baseline' \
  'video/DeRoPE_v1_0/FL2VA_Automatic_Oracle' \
  'video/DeRoPE_v1_0/FL2VA_Automatic_Dilated' \
  'video/DeRoPE_v1_0/FL2VA_Automatic_Recovered'

build_fl2va \
  "$targeted_source" "$targeted" \
  'De-RoPE v1.0 targeted ranges — review oracle, then edit ranges' \
  'video/DeRoPE_v1_0/FL2VA_Targeted_Baseline' \
  'video/DeRoPE_v1_0/FL2VA_Targeted_Oracle' \
  'video/DeRoPE_v1_0/FL2VA_Targeted_Dilated' \
  'video/DeRoPE_v1_0/FL2VA_Targeted_Recovered'

# The public REF2VA starting graph uses speed patches and a Turbo LoRA. Remove
# those nodes and feed the same full-BF16 base model directly into both passes;
# this preserves the video-described 25-step/no-Turbo quality baseline.
jq --arg note "$common_note" '
  (.nodes[] | select(.id == 127) | .widgets_values[0]) = "minimax_h3_ref2va_bf16.safetensors"
  | (.nodes[] | select(.id == 128) | .widgets_values[0]) = "qwen3vl_32b_minimax_h3_bf16.safetensors"
  | (.nodes[] | select(.id == 119) | .widgets_values[0]) = "minimax_h3_video_vae_fp16.safetensors"
  | (.nodes[] | select(.id == 120) | .widgets_values[0]) = "minimax_h3_audio_vae_fp32.safetensors"
  | .nodes |= map(select(.id != 300 and .id != 301 and .id != 302 and .id != 303))
  | .links |= map(select(
      (.[1] != 300 and .[3] != 300)
      and (.[1] != 301 and .[3] != 301)
      and (.[1] != 302 and .[3] != 302)
      and (.[1] != 303 and .[3] != 303)))
  | (.nodes[] | select(.id == 127) | .outputs[0].links) = [1001, 1002, 1003, 1004]
  | (.nodes[] | select(.id == 124)) |= (
      .inputs[0].link = 1001 | .widgets_values = ["simple", 25, 1])
  | (.nodes[] | select(.id == 126) | .inputs[0].link) = 1002
  | (.nodes[] | select(.id == 204)) |= (
      .inputs[0].link = 1003
      | .widgets_values = ["simple", 25, 0.5, "faithful detail 0.50 (metric best)"])
  | (.nodes[] | select(.id == 207) | .inputs[0].link) = 1004
  | (.nodes[] | select(.id == 135 or .id == 136) | .widgets_values) = ["res_multistep"]
  | (.nodes[] | select(.id == 92) | .widgets_values[0]) = "video/DeRoPE_v1_0/REF2VA_Baseline"
  | (.nodes[] | select(.id == 215) | .widgets_values[0]) = "video/DeRoPE_v1_0/REF2VA_Recovered_Original_Audio"
  | (.nodes[] | select(.id == 9105) | .widgets_values[0]) = "video/DeRoPE_v1_0/REF2VA_Recovered_Seeded_Foley"
  | .links += [
      [1001, 127, 0, 124, 0, "MODEL"],
      [1002, 127, 0, 126, 0, "MODEL"],
      [1003, 127, 0, 204, 0, "MODEL"],
      [1004, 127, 0, 207, 0, "MODEL"]
    ]
  | .last_node_id = ([.last_node_id, 1000] | max)
  | .last_link_id = ([.last_link_id, 1004] | max)
  | .nodes += [{
      "id": 1000,
      "type": "MarkdownNote",
      "pos": [-700, -900],
      "size": [620, 620],
      "flags": {},
      "order": 40,
      "mode": 0,
      "inputs": [],
      "outputs": [],
      "properties": {},
      "title": "De-RoPE v1.0 REF2VA + audio — read before queueing",
      "widgets_values": [$note + "\n\nREF2VA: replace example.png with the subject/location reference you intend to preserve. The primary recovered output keeps pass 1 audio; the seeded-foley output is an explicit alternate."]
    }]
  | walk(if type == "object" then del(.models) else . end)
' "$ref2va_source" >"$ref2va"

validate_workflow() {
  local workflow=$1 expected_model=$2
  jq -e --arg expected_model "$expected_model" '
    . as $workflow
    | ([.nodes[] | select(.type == "UNETLoader") | .widgets_values[0]]) == [$expected_model]
    and ([.nodes[] | select(.type == "CLIPLoader") | .widgets_values[0]])
      == ["qwen3vl_32b_minimax_h3_bf16.safetensors"]
    and ([.nodes[] | select(.type == "VAELoader") | .widgets_values[0]] | sort)
      == (["minimax_h3_audio_vae_fp32.safetensors", "minimax_h3_video_vae_fp16.safetensors"] | sort)
    and ([.nodes[] | select(.type == "BasicScheduler") | .widgets_values]
      | all(. == ["simple", 25, 1]))
    and ([.nodes[] | select(.type == "H3InjectSchedule") | .widgets_values]
      | all(. == ["simple", 25, 0.5, "faithful detail 0.50 (metric best)"]))
    and ([.nodes[] | select(.type == "KSamplerSelect") | .widgets_values]
      | all(. == ["res_multistep"]))
    and ([.nodes[] | select(.type == "H3JerkOracle")] | length) == 1
    and ([.nodes[] | select(.type == "H3TimeSmear")] | length) == 1
    and ([.nodes[] | select(.type == "H3V2VInit")] | length) == 1
    and ([.nodes[] | select(.type == "H3ExactRecover")] | length) == 1
    and ([.nodes[] | select(.type == "H3AudioSmear")] | length) == 1
    and ([.nodes[] | select(.type == "H3AudioRecover")] | length) >= 1
    and ([.nodes[] | select(.type == "LoraLoaderModelOnly")] | length) == 0
    and ([.nodes[] | select(.type == "MarkdownNote")] | length) >= 1
    and all(.links[]; . as $edge
      | any($workflow.nodes[]; .id == $edge[1]
          and any(.outputs[]?; any(.links[]?; . == $edge[0])))
      and any($workflow.nodes[]; .id == $edge[3]
          and any(.inputs[]?; .link == $edge[0])))
  ' "$workflow" >/dev/null
}

validate_workflow "$automatic" 'minimax_h3_fl2va_bf16.safetensors'
validate_workflow "$targeted" 'minimax_h3_fl2va_bf16.safetensors'
validate_workflow "$ref2va" 'minimax_h3_ref2va_bf16.safetensors'

jq -e '([.nodes[] | select(.type == "H3ManualHoldMap")] | length) == 1' "$targeted" >/dev/null
jq -e '([.nodes[] | select(.type == "MiniMaxH3ReferenceToVideo")] | length) == 2' "$ref2va" >/dev/null

if grep -RqiE 'pruned_int8|nvfp4|int8_convrot|LoraLoaderModelOnly|lightx2v|resolve/main|tree/main|ComfyUI-Manager' "$output_dir"; then
  echo 'De-RoPE workflows retain a lower-quality selector, Turbo LoRA, mutable model URL, or Manager dependency' >&2
  exit 1
fi
[[ $(find "$output_dir" -type f -name '*.json' | wc -l) -eq 3 ]]
