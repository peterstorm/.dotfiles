#!/usr/bin/env bash
# Build the Realism People LoRA variants of the two VDN-H3 workstation
# workflows: the fal rank-32 realism adapter wired into BOTH branches of each
# graph (the comparison stays apples-to-apples -- the variable remains the
# attention route, not the LoRA) with the trigger word prepended to the prompt.
set -euo pipefail

usage() {
  printf 'Usage: %s --t2v-source FILE --r2v-source FILE --output-dir DIR\n' "$0" >&2
  exit 64
}

t2v_source=
r2v_source=
output_dir=
while (($#)); do
  case "$1" in
    --t2v-source)
      [[ $# -ge 2 ]] || usage
      t2v_source=$2
      shift 2
      ;;
    --r2v-source)
      [[ $# -ge 2 ]] || usage
      r2v_source=$2
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

[[ -f "$t2v_source" && -f "$r2v_source" && -n "$output_dir" ]] || usage
expected_t2v_source_sha=4d99fe6283616f7f49ae610f54fa987a6dfea206c48fd86f961870d8d48d24c9
expected_r2v_source_sha=90c3d8086533160e8653a7c8b42515382f87c23fafce08cb563fd1cebd897a0f
[[ $(sha256sum "$t2v_source" | cut -d' ' -f1) == "$expected_t2v_source_sha" ]] || {
  echo "unexpected built T2V source checksum" >&2
  exit 1
}
[[ $(sha256sum "$r2v_source" | cut -d' ' -f1) == "$expected_r2v_source_sha" ]] || {
  echo "unexpected built R2V source checksum" >&2
  exit 1
}
mkdir -p "$output_dir"

T2V_OUT="$output_dir/VDN-H3-VS-fastvideoH3_t2v + Realism People LoRA.json"
R2V_OUT="$output_dir/Minimax-H3VDN-R2V + Realism People LoRA.json"

# --- T2V: realism LoRA on both branches of the shared-sampler comparison ---
# Nodes 101/102 (LoraLoaderModelOnly); links 200/201. Retarget 56 (UNET -> VDN)
# and 45 (UNET -> turbo LoRA) through the new loaders.
jq '(.nodes[] | select(.id == 21)) as $lora
| .last_node_id = ([.last_node_id, 103] | max)
| .last_link_id = ([.last_link_id, 201] | max)
| .nodes += [
    ($lora
      | .id = 101
      | .pos = [-1500, -750]
      | .order = 32
      | .title = "Realism People LoRA - VDN branch"
      | .widgets_values = ["h3-realism-people-t2v-i2v-r2v.safetensors", 1]
      | .widgets_values_named = {"lora_name": "h3-realism-people-t2v-i2v-r2v.safetensors", "strength_model": 1}
      | .inputs[0].link = 56
      | .outputs[0].links = [200])
  ]
| .nodes += [
    ($lora
      | .id = 102
      | .pos = [-1500, -300]
      | .order = 33
      | .title = "Realism People LoRA - turbo branch"
      | .widgets_values = ["h3-realism-people-t2v-i2v-r2v.safetensors", 1]
      | .widgets_values_named = {"lora_name": "h3-realism-people-t2v-i2v-r2v.safetensors", "strength_model": 1}
      | .inputs[0].link = 45
      | .outputs[0].links = [201])
  ]
| .links |= map(
    if .[0] == 56 then [56, 1, 0, 101, 0, "MODEL"]
    elif .[0] == 45 then [45, 1, 0, 102, 0, "MODEL"]
    else . end)
| .links += [[200, 101, 0, 25, 0, "MODEL"], [201, 102, 0, 21, 0, "MODEL"]]
| (.nodes[] | select(.id == 25) | .inputs[0].link) = 200
| (.nodes[] | select(.id == 21) | .inputs[0].link) = 201
| (.nodes[] | select(.id == 6)) |= (
    .widgets_values[0] = "r34l1sm, " + .widgets_values[0]
    | .widgets_values_named.prompt = "r34l1sm, " + .widgets_values_named.prompt
  )
| (.nodes[] | select(.id == 16) | .widgets_values[0]) = "video/VDN-H3_VS_fastvideoH3_t2v_realism"
| .nodes += [{
    "id": 103,
    "type": "MarkdownNote",
    "pos": [1100, -600],
    "size": [500, 620],
    "flags": {},
    "order": 34,
    "mode": 0,
    "inputs": [],
    "outputs": [],
    "properties": {},
    "title": "Realism People LoRA contract",
    "widgets_values": ["## fal Realism People LoRA\n\nPinned from fal/MiniMax-H3-Realism-People-LoRA@039cc8579d7aa357a882d7f4111b25da4f72dccc (rank 32, 1500 steps, high-resolution bucket; MiniMax-H3 Community License). One adapter covers t2v, i2v and r2v - it only touches the shared attention projections, so it composes with the VDN runtime patch and with the Turbo LoRA. Trigger word r34l1sm starts every prompt; scale 1.0 intended, 0.6-0.8 lighter. Wired into BOTH branches so the Switch comparison stays apples-to-apples."]
  }]
| walk(if type == "object" then del(.models) else . end)
' "$t2v_source" >"$T2V_OUT"
jq -e '. as $root
| ([.nodes[] | select(.type == "LoraLoaderModelOnly")] | length) == 3
and ([.nodes[] | select(.type == "LoraLoaderModelOnly") | .widgets_values[0]]
  | sort == (["h3-realism-people-t2v-i2v-r2v.safetensors",
              "h3-realism-people-t2v-i2v-r2v.safetensors",
              "minimax_h3_fl2v_turbo_8step_v1.0_comfyui_bf16.safetensors"] | sort))
and ([.links[] | select(.[0] == 56)] == [[56, 1, 0, 101, 0, "MODEL"]])
and ([.links[] | select(.[0] == 45)] == [[45, 1, 0, 102, 0, "MODEL"]])
and ([.links[] | select(.[0] == 200)] == [[200, 101, 0, 25, 0, "MODEL"]])
and ([.links[] | select(.[0] == 201)] == [[201, 102, 0, 21, 0, "MODEL"]])
and ([.nodes[] | select(.id == 25) | .inputs[0].link] == [200])
and ([.nodes[] | select(.id == 21) | .inputs[0].link] == [201])
and ([.nodes[] | select(.id == 6) | .widgets_values[0] | startswith("r34l1sm, ")])
and ([.nodes[] | select(.id == 6) | .widgets_values_named.prompt | startswith("r34l1sm, ")])
and ([.nodes[] | select(.type == "ApplyVDNH3") | .widgets_values]
  == [["stage-dmd-step-250", true, 1, "merge", "cache_gpu", true, "grouped"]])
and ([.nodes[] | select(.type == "SaveVideo") | .widgets_values[0]]
  == ["video/VDN-H3_VS_fastvideoH3_t2v_realism"])
and ([.nodes[] | select(.type == "MarkdownNote")] | length) == 2
and all(.links[]; . as $edge
  | any($root.nodes[]; .id == $edge[1]) and any($root.nodes[]; .id == $edge[3]))
' "$T2V_OUT" >/dev/null

# --- R2V: realism LoRA on both branches of the per-recipe comparison ---
# Nodes 230/231 (LoraLoaderModelOnly); links 330/331. Retarget 300 (UNET -> VDN)
# and 285 (UNET -> turbo LoRA) through the new loaders. The sigma schedulers
# keep the raw UNET: sigmas do not depend on LoRA weights.
jq '(.nodes[] | select(.id == 143)) as $lora
| .last_node_id = ([.last_node_id, 232] | max)
| .last_link_id = ([.last_link_id, 331] | max)
| .nodes += [
    ($lora
      | .id = 230
      | .pos = [-1500, -750]
      | .order = 32
      | .title = "Realism People LoRA - VDN branch"
      | .widgets_values = ["h3-realism-people-t2v-i2v-r2v.safetensors", 1]
      | .inputs[0].link = 300
      | .outputs[0].links = [330])
  ]
| .nodes += [
    ($lora
      | .id = 231
      | .pos = [-1500, -300]
      | .order = 33
      | .title = "Realism People LoRA - control branch"
      | .widgets_values = ["h3-realism-people-t2v-i2v-r2v.safetensors", 1]
      | .inputs[0].link = 285
      | .outputs[0].links = [331])
  ]
| .links |= map(
    if .[0] == 300 then [300, 127, 0, 230, 0, "MODEL"]
    elif .[0] == 285 then [285, 127, 0, 231, 0, "MODEL"]
    else . end)
| .links += [[330, 230, 0, 200, 0, "MODEL"], [331, 231, 0, 143, 0, "MODEL"]]
| (.nodes[] | select(.id == 200) | .inputs[0].link) = 330
| (.nodes[] | select(.id == 143) | .inputs[0].link) = 331
| (.nodes[] | select(.id == 138)) |= (
    .widgets_values[0] = "r34l1sm\n\n" + .widgets_values[0]
  )
| (.nodes[] | select(.id == 92) | .widgets_values[0]) = "video/VDN-H3_R2V_Turbo4_Control_realism"
| (.nodes[] | select(.id == 215) | .widgets_values[0]) = "video/VDN-H3_R2V_VDN_realism"
| .nodes += [{
    "id": 232,
    "type": "MarkdownNote",
    "pos": [1100, -600],
    "size": [500, 620],
    "flags": {},
    "order": 34,
    "mode": 0,
    "inputs": [],
    "outputs": [],
    "properties": {},
    "title": "Realism People LoRA contract",
    "widgets_values": ["## fal Realism People LoRA\n\nPinned from fal/MiniMax-H3-Realism-People-LoRA@039cc8579d7aa357a882d7f4111b25da4f72dccc (rank 32, 1500 steps, high-resolution bucket; MiniMax-H3 Community License). One adapter covers t2v, i2v and r2v - it only touches the shared attention projections, so it composes with the VDN runtime patch and with the Turbo LoRA. Trigger word r34l1sm starts every prompt; scale 1.0 intended, 0.6-0.8 lighter. Wired into BOTH branches so the comparison stays apples-to-apples."]
  }]
| walk(if type == "object" then del(.models) else . end)
' "$r2v_source" >"$R2V_OUT"
jq -e '. as $root
| ([.nodes[] | select(.type == "LoraLoaderModelOnly")] | length) == 3
and ([.nodes[] | select(.type == "LoraLoaderModelOnly") | .widgets_values[0]]
  | sort == (["h3-realism-people-t2v-i2v-r2v.safetensors",
              "h3-realism-people-t2v-i2v-r2v.safetensors",
              "minimax_h3_ref2v_turbo_4step_v0.1_comfyui_bf16.safetensors"] | sort))
and ([.links[] | select(.[0] == 300)] == [[300, 127, 0, 230, 0, "MODEL"]])
and ([.links[] | select(.[0] == 285)] == [[285, 127, 0, 231, 0, "MODEL"]])
and ([.links[] | select(.[0] == 330)] == [[330, 230, 0, 200, 0, "MODEL"]])
and ([.links[] | select(.[0] == 331)] == [[331, 231, 0, 143, 0, "MODEL"]])
and ([.nodes[] | select(.id == 200) | .inputs[0].link] == [330])
and ([.nodes[] | select(.id == 143) | .inputs[0].link] == [331])
and ([.nodes[] | select(.id == 210) | .inputs[0].link] == [301])
and ([.nodes[] | select(.type == "ApplyVDNH3") | .widgets_values]
  == [["stage-dmd-step-250", true, 1, "merge", "cache_gpu", true, "grouped"]])
and all(.links[]; . as $edge
  | any($root.nodes[]; .id == $edge[1]) and any($root.nodes[]; .id == $edge[3]))
and ([.nodes[] | select(.id == 138) | .widgets_values[0] | startswith("r34l1sm")])
and ([.nodes[] | select(.type == "SaveVideo") | .widgets_values[0]]
  | sort == (["video/VDN-H3_R2V_VDN_realism", "video/VDN-H3_R2V_Turbo4_Control_realism"] | sort))
and ([.nodes[] | select(.type == "MarkdownNote")] | length) == 5
' "$R2V_OUT" >/dev/null

if grep -RqiE 'pruned_int8|nvfp4|resolve/main|tree/main|ComfyUI-Manager|int8_convrot|int8-convrot' "$output_dir"; then
  echo "Realism workflows retain a lower-precision selector, mutable model URL, or Manager dependency" >&2
  exit 1
fi
[[ $(find "$output_dir" -type f -name '*.json' | wc -l) -eq 2 ]]
