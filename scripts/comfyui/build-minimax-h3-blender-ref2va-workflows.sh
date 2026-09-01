#!/usr/bin/env bash
# shellcheck disable=SC2016 # Workflow notes intentionally contain literal backticks.
set -euo pipefail

usage() {
  printf 'Usage: %s --base-source FILE --turbo-source FILE --pdd-source FILE --output-dir DIR\n' "$0" >&2
  exit 64
}

base_source=
turbo_source=
pdd_source=
output_dir=
while (($#)); do
  case "$1" in
    --base-source)
      [[ $# -ge 2 ]] || usage
      base_source=$2
      shift 2
      ;;
    --turbo-source)
      [[ $# -ge 2 ]] || usage
      turbo_source=$2
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

[[ -f "$base_source" && -f "$turbo_source" && -f "$pdd_source" && -n "$output_dir" ]] || usage
expected_pdd_source_sha=9ef2d4914e3256fb3d025be80b00f28047ea48d41c2d61b10558354b5c23ac69
[[ $(sha256sum "$pdd_source" | cut -d' ' -f1) == "$expected_pdd_source_sha" ]] || {
  echo "unexpected PDD workflow source checksum" >&2
  exit 1
}
mkdir -p "$output_dir"

precision_prompt='subject_definitions:
<Video 1> is the Blender motion carrier. It owns shot duration, camera trajectory, lens impression, framing, screen direction, object and proxy transforms, support contacts, contact order, mechanism timing, recoil, and final spatial state. It owns no final identity, anatomy, wardrobe, material, color, texture, lighting, environment design, acting, emotion, dialogue, or sound.
<Picture 1> is Subject A appearance authority only. Preserve its accepted identity, silhouette, proportions, wardrobe or construction, and materials without inheriting pose, camera, or background.
<Picture 2> is Subject B appearance authority only. Preserve its accepted identity or topology and materials without inheriting pose, camera, or background.
<Picture 3> is World appearance authority only. Preserve its geography, architecture, palette, and lighting without replacing the floor plane, action corridor, camera, or timing from <Video 1>.

summary:
[reference generation + video editing] Re-render the complete neutral Blender blockout in <Video 1> as one continuous final-looking shot. Preserve the source camera and physical event while replacing only the explicitly assigned proxy appearance.

source_priority:
- <Video 1> wins every disagreement about time, camera, framing, placement, screen side, support, path, contact order, mechanism state, and consequence.
- Pictures 1-3 win only for their assigned visible appearance roles.
- The prompt authors final causal action, performance, sound, and properties that are absent from the blockout.

detailed_description:
[Shot 1] Keep one continuous shot with no invented cut. Follow <Video 1> at source scale and timing. Describe the opening state, one causal action or mechanism beat, visible support before force, approach before contact, reaction only after contact, and a persistent final consequence. Keep contact and support visible. State the final character action and emotion explicitly; do not infer acting, gaze, facial expression, or dialogue from proxy poses.

overall_soundscape:
Author synchronized ambience, movement, contact, mechanism, and recovery sounds against <Video 1> timing. Do not inherit placeholder audio unless explicitly retained.

non_diegetic_music:
N/A unless separately authorized.

forbidden_transfer:
No gray proxy material, color-ID material, primitive anatomy, proxy proportions, viewport grid, workbench lighting, helper geometry, rig control, label, text, watermark, identity blend, subject-role swap, extra subject, invented cut, hidden contact, pre-contact reaction, collision reset, teleportation, or decorative effect concealing mechanics.'

sequence_prompt='subject_definitions:
<Video 1> is the complete Blender edit carrier. It owns every source cut, cut frame, camera trajectory, lens impression, framing, screen direction, object and proxy transform, location interval, support contact, mechanism event, and timeline transition. It owns no final identity, anatomy, wardrobe, material, color, texture, lighting, world design, acting, dialogue, or final sound.
<Picture 1> is Subject A appearance authority only. Preserve its accepted identity, silhouette, proportions, wardrobe or construction, and materials without inheriting pose, camera, or background.
<Picture 2> is Subject B or secondary cast appearance authority only. Preserve only the explicitly assigned visible properties.
<Picture 3> is World and look authority only. Preserve its geography, architecture, palette, and motivated lighting without changing source camera or timing.

summary:
[reference generation + video editing] Re-render the full cut-aware Blender carrier in <Video 1>. Preserve the exact source edit and transform timeline while replacing neutral proxies with the separately assigned appearance authorities.

source_priority:
- <Video 1> wins every disagreement about cuts, time, camera, framing, placement, screen side, path, support, mechanism state, and transition timing.
- Pictures 1-3 win only for their assigned visible appearance roles.
- Dialogue never creates coverage: a line remains inside its source shot, and an off-screen speaker remains off-screen.

timeline_contract:
List every source interval and its single location, camera setup, visible cast, physical event, and terminal state. Mark states that persist across cuts. Do not merge, reorder, repeat, omit, or invent intervals. A dark transition or reserved gap means only the explicitly declared transition or generated insert.

detailed_description:
Describe final action and performance inside the existing source coverage. Preserve countable subjects, stable role/color mapping, seat and screen geography, object continuity, support/contact order, and persistent consequences. Author gaze, emotion, dialogue, and microbehavior explicitly; never infer them from proxy pose or color.

overall_soundscape:
Author synchronized ambience, action, dialogue, mechanism, and cut accents against <Video 1> timing. Do not inherit placeholder audio unless explicitly retained.

non_diegetic_music:
N/A unless separately authorized.

forbidden_transfer:
No gray proxy material, color-ID material, primitive anatomy, proxy proportions, viewport grid, workbench lighting, helper geometry, rig control, label, text, watermark, identity blend, role swap, duplicate cast, invented cut, new coverage for dialogue, hidden contact, pre-contact reaction, collision reset, or undeclared location blend.'

base_note='## Blender REF2VA — unpruned BF16 quality baseline

`<Video 1>` is a 24 fps Blender viewport render, not operator-only QA. It is encoded by the core `MiniMaxH3ReferenceToVideo` node as the motion/edit carrier. Pictures 1-3 own final appearance only. This graph uses the installed unpruned BF16 Ref2VA model and BF16 Qwen encoder with the official base recipe: res_multistep, simple scheduler, 20 steps, no acceleration adapter. Development evidence only; reference authority is a prompt contract, not guaranteed frame-exact transfer.'
turbo_note='## Blender REF2VA — task-matched Turbo 4-step

`<Video 1>` is encoded as the motion/edit carrier. This graph uses the unpruned BF16 Ref2VA base plus `minimax_h3_ref2v_turbo_4step_v0.1_comfyui_bf16.safetensors` at strength 1.0: Euler/simple, 4 steps, shifts 12/3. It never stacks PDD or another distill adapter. The 5-second profile is the qualified speed control; the 15-second profile is a duration qualification candidate. Development evidence only.'
pdd_note='## Blender REF2VA — dedicated PDD 8-step

`<Video 1>` is encoded as the motion/edit carrier. PDD is not an ordinary LoRA: `MiniMaxH3PDDAccApply` supplies its Ref2VA trunk adapter, parallel-decoding head bank, and trained sigmas together. Required recipe: Euler, CFG 1, shifts 12/3, NFE 8, strengths 1/1, off-grid error. Never stack Turbo, cache, or another distill adapter. The 15-second profile is an unqualified duration candidate. Development evidence only.'

add_video_loader='{
  "id":500,
  "type":"VHS_LoadVideo",
  "pos":[-520,780],
  "size":[320,650],
  "flags":{},
  "order":4,
  "mode":0,
  "inputs":[
    {"shape":7,"name":"meta_batch","type":"VHS_BatchManager","link":null},
    {"shape":7,"name":"vae","type":"VAE","link":null},
    {"name":"video","type":"STRING","widget":{"name":"video"},"link":null},
    {"name":"force_rate","type":"INT","widget":{"name":"force_rate"},"link":null},
    {"name":"force_size","type":"COMBO","widget":{"name":"force_size"},"link":null},
    {"name":"custom_width","type":"INT","widget":{"name":"custom_width"},"link":null},
    {"name":"custom_height","type":"INT","widget":{"name":"custom_height"},"link":null},
    {"name":"frame_load_cap","type":"INT","widget":{"name":"frame_load_cap"},"link":null},
    {"name":"skip_first_frames","type":"INT","widget":{"name":"skip_first_frames"},"link":null},
    {"name":"select_every_nth","type":"INT","widget":{"name":"select_every_nth"},"link":null},
    {"shape":7,"name":"format","type":"COMBO","widget":{"name":"format"},"link":null}
  ],
  "outputs":[
    {"name":"IMAGE","type":"IMAGE","links":[500]},
    {"name":"frame_count","type":"INT","links":null},
    {"name":"audio","type":"AUDIO","links":null},
    {"name":"video_info","type":"VHS_VIDEOINFO","links":null}
  ],
  "properties":{"Node name for S&R":"VHS_LoadVideo"},
  "title":"Video 1 — Blender motion/edit carrier"
}'

build_standard() {
  local destination=$1 mode=$2 duration=$3 frames=$4 prompt=$5 prefix=$6 note=$7
  local source=$base_source
  [[ $mode == turbo ]] && source=$turbo_source
  jq \
    --arg mode "$mode" \
    --arg prompt "$prompt" \
    --arg prefix "$prefix" \
    --arg note "$note" \
    --argjson duration "$duration" \
    --argjson frames "$frames" \
    --argjson video_loader "$add_video_loader" '
      .last_node_id = 500
      | .last_link_id = (if $mode == "base" then 502 else 500 end)
      | if any(.nodes[]; .id == 141) then . else
          .nodes += [{
            "id":141,"type":"LoadImage","pos":[200,420],"size":[320,314],"flags":{},"order":6,"mode":0,
            "inputs":[{"name":"image","type":"COMBO","widget":{"name":"image"},"link":null},{"name":"upload","type":"IMAGEUPLOAD","widget":{"name":"upload"},"link":null}],
            "outputs":[{"name":"IMAGE","type":"IMAGE","links":[499]},{"name":"MASK","type":"MASK","links":null}],
            "properties":{"Node name for S&R":"LoadImage"},
            "widgets_values":["h3-blender-previz/WORLD_APPEARANCE.png","image"]
          }]
          | .links += [[499,141,0,136,5,"IMAGE"]]
        end
      | (.nodes[] | select(.id == 127)) |= (
          .title = "ON-DEMAND — unpruned BF16 Ref2VA"
          | .widgets_values = ["minimax_h3_ref2va_bf16.safetensors", "default"]
          | del(.properties.models)
        )
      | (.nodes[] | select(.id == 128)) |= (
          .title = "ON-DEMAND — BF16 Qwen3-VL-32B"
          | .widgets_values = ["qwen3vl_32b_minimax_h3_bf16.safetensors", "minimax", "default"]
          | del(.properties.models)
        )
      | (.nodes[] | select(.id == 115)) |= (
          .title = "Pinned Blender carrier output — 960×544"
          | .widgets_values = ["16:9 (Widescreen)", 0.5, 32]
        )
      | (.nodes[] | select(.id == 129) | .widgets_values) = [
          (if $duration == 5 then 64005 else 64015 end), "fixed"
        ]
      | (.nodes[] | select(.id == 132) | .widgets_values) = [$duration]
      | (.nodes[] | select(.id == 136)) |= (
          .title = "Blender Video 1 + three appearance authorities"
          | .inputs = [
              {"name":"clip","type":"CLIP","link":272},
              {"name":"vae","type":"VAE","link":273},
              {"name":"audio_vae","type":"VAE","link":274},
              {"label":"ref_image_0","name":"ref_images.ref_image_0","shape":7,"type":"IMAGE","link":278},
              {"label":"ref_image_1","name":"ref_images.ref_image_1","shape":7,"type":"IMAGE","link":282},
              {"label":"ref_image_2","name":"ref_images.ref_image_2","shape":7,"type":"IMAGE","link":(if $mode == "base" then 499 else 283 end)},
              {"label":"ref_video_0","name":"ref_videos.ref_video_0","shape":7,"type":"IMAGE","link":500},
              {"label":"ref_video_audio_0","name":"ref_video_audios.ref_video_audio_0","shape":7,"type":"AUDIO","link":null},
              {"label":"ref_audio_0","name":"ref_audios.ref_audio_0","shape":7,"type":"AUDIO","link":null},
              {"name":"prompt","type":"STRING","widget":{"name":"prompt"},"link":279},
              {"name":"width","type":"INT","widget":{"name":"width"},"link":276},
              {"name":"height","type":"INT","widget":{"name":"height"},"link":277},
              {"name":"length","type":"INT","widget":{"name":"length"},"link":275},
              {"name":"ref_image_size","type":"COMBO","widget":{"name":"ref_image_size"},"link":null}
            ]
          | .widgets_values = [$prompt,960,544,$frames,"match"]
        )
      | (.nodes[] | select(.id == 138) | .widgets_values) = [$prompt]
      | (.nodes[] | select(.id == 137)) |= (
          .title = "Picture 1 — Subject A appearance only"
          | .widgets_values = ["h3-blender-previz/SUBJECT_A_APPEARANCE.png", "image"]
          | del(.properties.models)
        )
      | (.nodes[] | select(.id == 139)) |= (
          .title = "Picture 2 — Subject B appearance only"
          | .widgets_values = ["h3-blender-previz/SUBJECT_B_APPEARANCE.png", "image"]
          | del(.properties.models)
        )
      | (.nodes[] | select(.id == 141)) |= (
          .title = "Picture 3 — World/look appearance only"
          | .widgets_values = ["h3-blender-previz/WORLD_APPEARANCE.png", "image"]
          | del(.properties.models)
        )
      | (.nodes[] | select(.id == 116 or .id == 117)) |= (
          .title = "Blender REF2VA Development contract"
          | .widgets_values = [$note]
        )
      | (.nodes[] | select(.id == 92) | .widgets_values[0]) = $prefix
      | .nodes += [($video_loader
          | .widgets_values = {
              "video": (if $duration == 5 then "h3-blender-previz/BLENDER_CARRIER_5S.mp4" else "h3-blender-previz/BLENDER_CARRIER_15S.mp4" end),
              "force_rate": 24,
              "force_size": "Disabled",
              "custom_width": 0,
              "custom_height": 0,
              "frame_load_cap": $frames,
              "skip_first_frames": 0,
              "select_every_nth": 1,
              "format": "AnimateDiff",
              "choose video to upload": "image"
            }
        )]
      | (.links[] | select(.[0] == 275) | .[4]) = 12
      | (.links[] | select(.[0] == 276) | .[4]) = 10
      | (.links[] | select(.[0] == 277) | .[4]) = 11
      | (.links[] | select(.[0] == 279) | .[4]) = 9
      | .links += [[500,500,0,136,6,"IMAGE"]]
      | if $mode == "base" then
          .nodes |= map(select(.id != 142 and .id != 143))
          | .links |= map(select(.[0] != 284 and .[0] != 285 and .[0] != 286))
          | .links += [[502,127,0,126,0,"MODEL"]]
          | (.nodes[] | select(.id == 127) | .outputs[0].links) = [252,502]
          | (.nodes[] | select(.id == 126) | .inputs[] | select(.name == "model") | .link) = 502
          | (.nodes[] | select(.id == 123) | .widgets_values) = ["res_multistep"]
          | (.nodes[] | select(.id == 124) | .widgets_values) = ["simple",20,1]
        else
          (.nodes[] | select(.id == 142)) |= (
              .title = "Task-matched Turbo shifts 12/3"
              | .widgets_values = [12,3]
            )
          | (.nodes[] | select(.id == 143)) |= (
              .title = "Ref2VA Turbo 4-step — strength 1.0"
              | .widgets_values = ["minimax_h3_ref2v_turbo_4step_v0.1_comfyui_bf16.safetensors",1]
              | del(.properties.models)
            )
          | (.nodes[] | select(.id == 123) | .widgets_values) = ["euler"]
          | (.nodes[] | select(.id == 124) | .widgets_values) = ["simple",4,1]
        end
      | walk(if type == "object" then del(.models) else . end)
    ' "$source" >"$destination"
}

build_pdd() {
  local destination=$1 duration=$2 frames=$3 prompt=$4 prefix=$5
  jq \
    --arg prompt "$prompt" \
    --arg prefix "$prefix" \
    --arg note "$pdd_note" \
    --argjson duration "$duration" \
    --argjson frames "$frames" \
    --argjson video_loader "$add_video_loader" '
      .last_node_id = 103
      | .last_link_id = 103
      | (.nodes[] | select(.id == 1)) |= (
          .title = "ON-DEMAND — unpruned BF16 Ref2VA"
          | .widgets_values = ["minimax_h3_ref2va_bf16.safetensors","default"]
          | del(.properties.models)
        )
      | (.nodes[] | select(.id == 2)) |= (
          .title = "ON-DEMAND — BF16 Qwen3-VL-32B"
          | .widgets_values = ["qwen3vl_32b_minimax_h3_bf16.safetensors","minimax","default"]
          | del(.properties.models)
        )
      | (.nodes[] | select(.id == 5)) |= (
          .title = "PDD training grid — shifts 12/3 exactly"
          | .widgets_values = [12,3]
        )
      | (.nodes[] | select(.id == 6)) |= (
          .title = "Dedicated Ref2VA PDD loader — trunk + heads + sigmas"
          | .widgets_values = ["MiniMax-H3-Ref2VA-Acc-8Step.safetensors","8",1,1,"error"]
        )
      | (.nodes[] | select(.id == 7)) |= (
          .title = "Blender Video 1 + three appearance authorities"
          | .inputs = (.inputs[0:3] + [
              {"label":"ref_image_0","name":"ref_images.ref_image_0","shape":7,"type":"IMAGE","link":100},
              {"label":"ref_image_1","name":"ref_images.ref_image_1","shape":7,"type":"IMAGE","link":101},
              {"label":"ref_image_2","name":"ref_images.ref_image_2","shape":7,"type":"IMAGE","link":102},
              {"label":"ref_video_0","name":"ref_videos.ref_video_0","shape":7,"type":"IMAGE","link":103},
              {"label":"ref_video_audio_0","name":"ref_video_audios.ref_video_audio_0","shape":7,"type":"AUDIO","link":null},
              {"label":"ref_audio_0","name":"ref_audios.ref_audio_0","shape":7,"type":"AUDIO","link":null}
            ])
          | .widgets_values = [$prompt,960,544,$frames,"match"]
        )
      | (.nodes[] | select(.id == 9)) |= (
          .title = "PDD requires Euler"
          | .widgets_values = ["euler"]
        )
      | (.nodes[] | select(.id == 10) | .widgets_values) = [
          (if $duration == 5 then 64005 else 64015 end), "fixed"
        ]
      | (.nodes[] | select(.id == 15) | .widgets_values[0]) = $prefix
      | (.nodes[] | select(.id == 17)) |= (
          .title = "Blender REF2VA PDD Development contract"
          | .widgets_values = [$note]
        )
      | (.nodes[] | select(.id == 18)) |= (
          .title = "Required PDD recipe — no BasicScheduler or Turbo"
          | .widgets_values = ["MiniMaxH3PDDAccApply sigmas → SamplerCustomAdvanced. Euler only; CFG 1; shifts 12/3; NFE 8; strengths 1/1; off-grid error. Video 1 is the Blender carrier."]
        )
      | .nodes += [
          ($video_loader
            | .id = 100
            | .outputs[0].links = [103]
            | .outputs[2].links = null
            | .widgets_values = {
                "video": (if $duration == 5 then "h3-blender-previz/BLENDER_CARRIER_5S.mp4" else "h3-blender-previz/BLENDER_CARRIER_15S.mp4" end),
                "force_rate":24,
                "force_size":"Disabled",
                "custom_width":0,
                "custom_height":0,
                "frame_load_cap":$frames,
                "skip_first_frames":0,
                "select_every_nth":1,
                "format":"AnimateDiff",
                "choose video to upload":"image"
              }),
          {
            "id":101,"type":"LoadImage","pos":[-520,-260],"size":[320,314],"flags":{},"order":4,"mode":0,
            "inputs":[{"name":"image","type":"COMBO","widget":{"name":"image"},"link":null},{"name":"upload","type":"IMAGEUPLOAD","widget":{"name":"upload"},"link":null}],
            "outputs":[{"name":"IMAGE","type":"IMAGE","links":[100]},{"name":"MASK","type":"MASK","links":null}],
            "properties":{"Node name for S&R":"LoadImage"},"title":"Picture 1 — Subject A appearance only",
            "widgets_values":["h3-blender-previz/SUBJECT_A_APPEARANCE.png","image"]
          },
          {
            "id":102,"type":"LoadImage","pos":[-160,-260],"size":[320,314],"flags":{},"order":5,"mode":0,
            "inputs":[{"name":"image","type":"COMBO","widget":{"name":"image"},"link":null},{"name":"upload","type":"IMAGEUPLOAD","widget":{"name":"upload"},"link":null}],
            "outputs":[{"name":"IMAGE","type":"IMAGE","links":[101]},{"name":"MASK","type":"MASK","links":null}],
            "properties":{"Node name for S&R":"LoadImage"},"title":"Picture 2 — Subject B appearance only",
            "widgets_values":["h3-blender-previz/SUBJECT_B_APPEARANCE.png","image"]
          },
          {
            "id":103,"type":"LoadImage","pos":[200,-260],"size":[320,314],"flags":{},"order":6,"mode":0,
            "inputs":[{"name":"image","type":"COMBO","widget":{"name":"image"},"link":null},{"name":"upload","type":"IMAGEUPLOAD","widget":{"name":"upload"},"link":null}],
            "outputs":[{"name":"IMAGE","type":"IMAGE","links":[102]},{"name":"MASK","type":"MASK","links":null}],
            "properties":{"Node name for S&R":"LoadImage"},"title":"Picture 3 — World/look appearance only",
            "widgets_values":["h3-blender-previz/WORLD_APPEARANCE.png","image"]
          }
        ]
      | .links += [
          [100,101,0,7,3,"IMAGE"],
          [101,102,0,7,4,"IMAGE"],
          [102,103,0,7,5,"IMAGE"],
          [103,100,0,7,6,"IMAGE"]
        ]
      | walk(if type == "object" then del(.models) else . end)
    ' "$pdd_source" >"$destination"
}

bf16_5="$output_dir/01 MiniMax H3 Blender REF2VA - 5s BF16 Quality Development.json"
turbo_5="$output_dir/02 MiniMax H3 Blender REF2VA - 5s Turbo 4-Step Development.json"
pdd_5="$output_dir/03 MiniMax H3 Blender REF2VA - 5s PDD 8-Step Development.json"
bf16_15="$output_dir/04 MiniMax H3 Blender REF2VA - 15s BF16 Quality Development.json"
turbo_15="$output_dir/05 MiniMax H3 Blender REF2VA - 15s Turbo 4-Step Duration Qualification.json"
pdd_15="$output_dir/06 MiniMax H3 Blender REF2VA - 15s PDD 8-Step Duration Qualification.json"

build_standard "$bf16_5" base 5 124 "$precision_prompt" \
  video/AFTERSIGNAL_H3_Blender_REF2VA_5s_BF16_Development "$base_note"
build_standard "$turbo_5" turbo 5 124 "$precision_prompt" \
  video/AFTERSIGNAL_H3_Blender_REF2VA_5s_Turbo4_Development "$turbo_note"
build_pdd "$pdd_5" 5 124 "$precision_prompt" \
  video/AFTERSIGNAL_H3_Blender_REF2VA_5s_PDD8_Development
build_standard "$bf16_15" base 15 362 "$sequence_prompt" \
  video/AFTERSIGNAL_H3_Blender_REF2VA_15s_BF16_Development "$base_note"
build_standard "$turbo_15" turbo 15 362 "$sequence_prompt" \
  video/AFTERSIGNAL_H3_Blender_REF2VA_15s_Turbo4_Development "$turbo_note"
build_pdd "$pdd_15" 15 362 "$sequence_prompt" \
  video/AFTERSIGNAL_H3_Blender_REF2VA_15s_PDD8_Development

jq -s -e '
  length == 6
  and all(.[]; . as $workflow
    | ([.nodes[].id] | length == (unique | length))
    and ([.links[][0]] | length == (unique | length))
    and all(.links[]; . as $edge
      | any($workflow.nodes[]; .id == $edge[1])
      and any($workflow.nodes[]; .id == $edge[3]))
    and ([.nodes[] | select(.type == "MiniMaxH3ReferenceToVideo") | .widgets_values[1:3]] == [[960,544]])
    and ([.nodes[] | select(.type == "UNETLoader") | .widgets_values[0]] == ["minimax_h3_ref2va_bf16.safetensors"])
    and ([.nodes[] | select(.type == "CLIPLoader") | .widgets_values[0]] == ["qwen3vl_32b_minimax_h3_bf16.safetensors"])
    and ([.nodes[] | select(.type == "VHS_LoadVideo") | [.widgets_values.force_rate,.widgets_values.select_every_nth]] == [[24,1]])
    and ([.nodes[] | select(.type == "MiniMaxH3ReferenceToVideo") | .inputs[] | select(.name == "ref_video_audios.ref_video_audio_0") | .link] == [null])
    and ([.nodes[] | select(.type == "VHS_LoadVideo") | .outputs[] | select(.name == "audio") | .links] == [null])
    and (([.nodes[] | select(.type == "LoadImage")] | length) == 3)
    and (([.nodes[] | select(.type == "EasyCache" or .type == "easy cleanGpuUsed")] | length) == 0)
  )
  and all(.[0:3][];
    ([.nodes[] | select(.type == "MiniMaxH3ReferenceToVideo") | .widgets_values[3]] == [124])
    and ([.nodes[] | select(.type == "VHS_LoadVideo") | .widgets_values.frame_load_cap] == [124]))
  and all(.[3:6][];
    ([.nodes[] | select(.type == "MiniMaxH3ReferenceToVideo") | .widgets_values[3]] == [362])
    and ([.nodes[] | select(.type == "VHS_LoadVideo") | .widgets_values.frame_load_cap] == [362]))
  and all([.[0],.[3]][];
    ([.nodes[] | select(.type == "LoraLoaderModelOnly" or .type == "MiniMaxH3PDDAccApply" or .type == "MiniMaxH3SigmaShift")] | length) == 0
    and ([.nodes[] | select(.type == "KSamplerSelect") | .widgets_values] == [["res_multistep"]])
    and ([.nodes[] | select(.type == "BasicScheduler") | .widgets_values] == [["simple",20,1]]))
  and all([.[1],.[4]][];
    ([.nodes[] | select(.type == "LoraLoaderModelOnly") | .widgets_values] == [["minimax_h3_ref2v_turbo_4step_v0.1_comfyui_bf16.safetensors",1]])
    and ([.nodes[] | select(.type == "MiniMaxH3SigmaShift") | .widgets_values] == [[12,3]])
    and ([.nodes[] | select(.type == "KSamplerSelect") | .widgets_values] == [["euler"]])
    and ([.nodes[] | select(.type == "BasicScheduler") | .widgets_values] == [["simple",4,1]])
    and ([.nodes[] | select(.type == "MiniMaxH3PDDAccApply")] | length) == 0)
  and all([.[2],.[5]][];
    ([.nodes[] | select(.type == "MiniMaxH3PDDAccApply") | .widgets_values] == [["MiniMax-H3-Ref2VA-Acc-8Step.safetensors","8",1,1,"error"]])
    and ([.nodes[] | select(.type == "MiniMaxH3SigmaShift") | .widgets_values] == [[12,3]])
    and ([.nodes[] | select(.type == "KSamplerSelect") | .widgets_values] == [["euler"]])
    and ([.nodes[] | select(.type == "BasicScheduler" or .type == "LoraLoaderModelOnly")] | length) == 0)
' "$bf16_5" "$turbo_5" "$pdd_5" "$bf16_15" "$turbo_15" "$pdd_15" >/dev/null

if grep -RqiE 'pruned_int8|nvfp4|resolve/main|tree/main|ComfyUI-Manager|api[_-]?key|token|EasyCache' "$output_dir"; then
  echo "Blender REF2VA workflows retain a lower-quality selector, mutable model URL, Manager, credential field, or cache node" >&2
  exit 1
fi
[[ $(find "$output_dir" -type f -name '*.json' | wc -l) -eq 6 ]]
