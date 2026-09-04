#!/usr/bin/env bash
# Build the two VDN-H3 workstation workflows from the video
# "DeltaNet Minimax H3 in ComfyUI — Faster Base Model Without Losing Quality":
# the text-to-video head-to-head (VDN vs the Turbo route) and the reference-to-video
# comparison (VDN vs the previously qualified REF2VA Turbo control).
#
# The exact Patreon JSONs are account-gated, so both graphs are adapted from the
# pinned upstream sources:
#   - T2V: ComfyUI-VDN-H3 v1.3.1's shipped example (the same 2-branch, shared-sampler,
#     Switch topology the video demos), reselected onto the workstation's full-BF16
#     profile with the on-recipe 8-step Turbo LoRA.
#   - R2V: the pinned ModelTC REF2VA Turbo example with the VDN patch branch inserted;
#     each branch samples its own trained recipe against the same prompt/references.
set -euo pipefail

usage() {
  printf 'Usage: %s --vdn-t2v-source FILE --ref2v-source FILE --output-dir DIR\n' "$0" >&2
  exit 64
}

vdn_t2v_source=
ref2v_source=
output_dir=
while (($#)); do
  case "$1" in
    --vdn-t2v-source)
      [[ $# -ge 2 ]] || usage
      vdn_t2v_source=$2
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

[[ -f "$vdn_t2v_source" && -f "$ref2v_source" && -n "$output_dir" ]] || usage
expected_vdn_t2v_source_sha=5abad5ea329d1b4cebc6dc8aa4bdb66a2f5440a5a77d27070ed065ada9667e5c
expected_ref2v_source_sha=b906a154f9a45047714c43c038d345a6c645fda44e53f3b6f6aef23d3e179028
[[ $(sha256sum "$vdn_t2v_source" | cut -d' ' -f1) == "$expected_vdn_t2v_source_sha" ]] || {
  echo "unexpected VDN example workflow source checksum" >&2
  exit 1
}
[[ $(sha256sum "$ref2v_source" | cut -d' ' -f1) == "$expected_ref2v_source_sha" ]] || {
  echo "unexpected REF2VA Turbo source checksum" >&2
  exit 1
}
mkdir -p "$output_dir"

t2v="$output_dir/VDN-H3-VS-fastvideoH3_t2v.json"
r2v="$output_dir/Minimax-H3VDN-R2V.json"

t2v_note='## VDN-H3 vs FastVideo H3 — T2V comparison (BF16 workstation profile)

Adapted from the pinned ComfyUI-VDN-H3 v1.3.1 example workflow (the same 2-branch, shared-sampler Switch topology the source video demos). Both branches sample 8 steps, er_sde / beta — the VDN released recipe — from the same fixed noise seed.

- TRUE branch ("True = VDNH3"): full-BF16 FL2VA + ApplyVDNH3 (stage-dmd-step-250, apply_turbo_adapter ON, lora_mode merge, branch_weights cache_gpu) + MiniMaxChunkFeedForward. No Turbo LoRA on the VDN branch — the released 8-step model replaces it entirely.
- FALSE branch: full-BF16 FL2VA + minimax_h3_fl2v_turbo_8step_v1.0_comfyui_bf16.safetensors at strength 1.0 + comfy kitchen attention + Scheduled Sol Attention.

Deviation from upstream: the on-recipe 8-step Turbo LoRA replaces the upstream resized 4-step rank-64 LoRA at 0.65, and the full-BF16 base, CLIP, and video VAE replace the lower-precision int8 selectors (bf16 where possible). Flip the Switch widget to compare branches side by side.

Source-video findings to judge against: VDN keeps fast-motion areas clean where the Turbo route starts pixelating; both outputs are raw first-sampling results with no latent upsampling.'

r2v_note='## Minimax-H3 VDN — REF2VA comparison (BF16 workstation profile)

Adapted from the pinned ModelTC REF2VA Turbo example for the VDN-H3 node port. Both branches share the same prompt, reference images, resolution (1344×768, reference resize match), duration, and fixed noise seed; each branch samples its own trained recipe.

- VDN branch: full-BF16 REF2VA + ApplyVDNH3 (stage-dmd-step-250, apply_turbo_adapter ON, lora_mode merge, branch_weights cache_gpu). 8 steps, er_sde / beta, no Turbo LoRA.
- Control branch: full-BF16 REF2VA + ref2v Turbo 4-step LoRA at strength 1.0 + comfy kitchen attention + Scheduled Sol Attention + video/audio sigma shift 12/3. 4 steps, Euler / simple.

Drop the three reference images (subject_1.png, subject_2.png, environment.png) into the loaders before queueing. VDN is confirmed working with the ref2v base (source video 05:03). The Sage Attention branch from the source video is intentionally absent: SageAttention is not installed on this workstation, and the source video itself concluded Comfy Kitchen + Sol is indistinguishable from it.

Do not stack the Scheduled Sol Attention patch or any Turbo LoRA into the VDN branch — the VDN patch owns the attention path, and the released 8-step turbo adapter replaces community Turbo LoRAs.'

# --- T2V: adapt the pinned VDN example onto the workstation BF16 profile ---
jq --arg note "$t2v_note" '
  (.nodes[] | select(.id == 1)) |= (
      .widgets_values[0] = "minimax_h3_fl2va_bf16.safetensors"
      | .widgets_values_named.unet_name = "minimax_h3_fl2va_bf16.safetensors"
    )
  | (.nodes[] | select(.id == 2)) |= (
      .widgets_values[0] = "qwen3vl_32b_minimax_h3_bf16.safetensors"
      | .widgets_values_named.clip_name = "qwen3vl_32b_minimax_h3_bf16.safetensors"
    )
  | (.nodes[] | select(.id == 4)) |= (
      .widgets_values[0] = "minimax_h3_video_vae_fp16.safetensors"
      | .widgets_values_named.vae_name = "minimax_h3_video_vae_fp16.safetensors"
    )
  | (.nodes[] | select(.id == 21)) |= (
      .widgets_values = ["minimax_h3_fl2v_turbo_8step_v1.0_comfyui_bf16.safetensors", 1]
      | .widgets_values_named = {"lora_name": "minimax_h3_fl2v_turbo_8step_v1.0_comfyui_bf16.safetensors", "strength_model": 1}
    )
  | (.nodes[] | select(.id == 16) | .widgets_values[0]) = "video/VDN-H3_VS_fastvideoH3_t2v"
  | (.nodes[] | select(.id == 25) | .properties.ver) = "183f33d8a7b3c6322d83be95ae369251a63b3198"
  | (.nodes[] | select(.id == 20)) |= (
      .type = "MiniMaxH3ScheduledSolAttentionPatch"
      | .properties = {"Node name for S&R": "MiniMaxH3ScheduledSolAttentionPatch"}
      | .widgets_values = [true, 1.2, 0.8, "linear", 12288, false, 0.2, "diag", false, false, "exact_kv_and_rows", ""]
      | .outputs = [(.outputs[0]), {"name": "tau_graph", "type": "IMAGE", "links": null}]
    )
  | .last_node_id = ([.last_node_id, 100] | max)
  | .nodes += [{
      "id": 100,
      "type": "MarkdownNote",
      "pos": [500, -600],
      "size": [500, 620],
      "flags": {},
      "order": 14,
      "mode": 0,
      "inputs": [],
      "outputs": [],
      "properties": {},
      "title": "VDN-H3 vs FastVideo H3 — T2V comparison contract",
      "widgets_values": [$note]
    }]
  | walk(if type == "object" then del(.models) else . end)
' "$vdn_t2v_source" >"$t2v"

jq -e '
  . as $root
  | ([.nodes[] | select(.type == "ApplyVDNH3")] | length) == 1
  and ([.nodes[] | select(.type == "ApplyVDNH3") | .widgets_values]
    == [["stage-dmd-step-250", true, 1, "merge", "cache_gpu", true, "grouped"]])
  and ([.nodes[] | select(.type == "UNETLoader") | .widgets_values[0]]
    == ["minimax_h3_fl2va_bf16.safetensors"])
  and ([.nodes[] | select(.type == "UNETLoader") | .widgets_values_named.unet_name]
    == ["minimax_h3_fl2va_bf16.safetensors"])
  and ([.nodes[] | select(.type == "CLIPLoader") | .widgets_values[0]]
    == ["qwen3vl_32b_minimax_h3_bf16.safetensors"])
  and ([.nodes[] | select(.type == "CLIPLoader") | .widgets_values_named.clip_name]
    == ["qwen3vl_32b_minimax_h3_bf16.safetensors"])
  and ([.nodes[] | select(.type == "VAELoader") | .widgets_values[0]]
    | sort == (["minimax_h3_audio_vae_fp32.safetensors", "minimax_h3_video_vae_fp16.safetensors"] | sort))
  and ([.nodes[] | select(.id == 4) | .widgets_values_named.vae_name]
    == ["minimax_h3_video_vae_fp16.safetensors"])
  and ([.nodes[] | select(.type == "LoraLoaderModelOnly") | .widgets_values]
    == [["minimax_h3_fl2v_turbo_8step_v1.0_comfyui_bf16.safetensors", 1]])
  and ([.nodes[] | select(.type == "LoraLoaderModelOnly") | .widgets_values_named.lora_name]
    == ["minimax_h3_fl2v_turbo_8step_v1.0_comfyui_bf16.safetensors"])
  and ([.nodes[] | select(.type == "Switch")] | length) == 1
  and ([.nodes[] | select(.type == "BasicScheduler") | .widgets_values] == [["beta", 8, 1]])
  and ([.nodes[] | select(.type == "KSamplerSelect") | .widgets_values] == [["er_sde"]])
  and ([.nodes[] | select(.type == "MiniMaxH3ScheduledSolAttentionPatch")] | length) == 1
  and ([.nodes[] | select(.type == "MiniMaxH3ScheduledSolAttentionPatch") | .widgets_values]
    == [[true, 1.2, 0.8, "linear", 12288, false, 0.2, "diag", false, false, "exact_kv_and_rows", ""]])
  and ([.nodes[] | select(.type == "MiniMaxChunkFeedForward")] | length) == 1
  and ([.nodes[] | select(.type == "MarkdownNote")] | length) == 1
  and all(.links[]; . as $edge
    | any($root.nodes[]; .id == $edge[1]) and any($root.nodes[]; .id == $edge[3]))
' "$t2v" >/dev/null

# --- R2V: VDN branch beside the qualified REF2VA Turbo control ---
# Branch A (ids 200/210/206/208/211/212/213/214/215): BF16 REF2VA -> ApplyVDNH3 ->
#   own guider/sampler/decode chain, 8 steps er_sde/beta, no Turbo LoRA.
# Branch B (source chain + ids 217/218): BF16 REF2VA -> Turbo LoRA -> comfy kitchen
#   attention -> Scheduled Sol Attention -> sigma shift, 4 steps Euler/simple.
# Shared: prompt, references, resolution, duration, fixed noise, Qwen/VAE loaders.
# Links 300-315 wire branch A; 316-318 insert the attention chain into branch B.
jq --slurpfile vdn_source "$vdn_t2v_source" --arg note "$r2v_note" '
  (.nodes[] | select(.id == 128) | .widgets_values[0]) = "qwen3vl_32b_minimax_h3_bf16.safetensors"
  | (.nodes[] | select(.id == 137)) |= (
      .title = "Picture 1 — subject 1 appearance" | .widgets_values[0] = "subject_1.png"
    )
  | (.nodes[] | select(.id == 139)) |= (
      .title = "Picture 2 — subject 2 appearance" | .widgets_values[0] = "subject_2.png"
    )
  | (.nodes[] | select(.id == 141)) |= (
      .title = "Picture 3 — environment only" | .widgets_values[0] = "environment.png"
    )
  | (.nodes[] | select(.id == 92) | .widgets_values[0]) = "video/VDN-H3_R2V_Turbo4_Control"
  | (.nodes[] | select(.id == 116 or .id == 117)) |= (
      .title = "VDN REF2VA comparison contract"
      | .widgets_values = [$note]
    )
  | .last_node_id = ([.last_node_id, 220] | max)
  | .last_link_id = ([.last_link_id, 318] | max)
  | (.nodes[] | select(.id == 126)) as $guider
  | (.nodes[] | select(.id == 123)) as $ksel
  | (.nodes[] | select(.id == 124)) as $sched
  | (.nodes[] | select(.id == 125)) as $sampler
  | (.nodes[] | select(.id == 122)) as $vdecode
  | (.nodes[] | select(.id == 121)) as $vdecode_audio
  | (.nodes[] | select(.id == 130)) as $createvideo
  | (.nodes[] | select(.id == 92)) as $savevideo
  | .nodes += [
      ($vdn_source[0].nodes[] | select(.id == 25)
        | .id = 200
        | .pos = [-1500, -600]
        | .order = 20
        | .properties.ver = "183f33d8a7b3c6322d83be95ae369251a63b3198"
        | .inputs[0].link = 300
        | .outputs[0].links = [301])
    ]
  | .nodes += [
      ($guider
        | .id = 210
        | .pos[0] -= 620
        | .order = 21
        | .title = "VDN branch guider"
        | .inputs[0].link = 301
        | .inputs[1].link = 302
        | .outputs[0].links = [304])
    ]
  | .nodes += [
      ($ksel
        | .id = 206
        | .pos[0] -= 310
        | .pos[1] += 560
        | .order = 22
        | .title = "VDN requires er_sde"
        | .widgets_values = ["er_sde"]
        | .outputs[0].links = [305])
    ]
  | .nodes += [
      ($sched
        | .id = 208
        | .pos[0] -= 620
        | .pos[1] += 560
        | .order = 23
        | .title = "VDN trained recipe — beta, 8 steps"
        | .widgets_values = ["beta", 8, 1]
        | .inputs[0].link = 306
        | .outputs[0].links = [307])
    ]
  | .nodes += [
      ($sampler
        | .id = 211
        | .pos[0] -= 310
        | .order = 24
        | .title = "VDN branch sampler — 8 steps"
        | .inputs[0].link = 303
        | .inputs[1].link = 304
        | .inputs[2].link = 305
        | .inputs[3].link = 307
        | .inputs[4].link = 308
        | .outputs[0].links = [309, 310])
    ]
  | .nodes += [
      ($vdecode
        | .id = 212
        | .pos[0] -= 310
        | .order = 25
        | .title = "VDN branch video decode"
        | .inputs[0].link = 309
        | .inputs[1].link = 311
        | .outputs[0].links = [313])
    ]
  | .nodes += [
      ($vdecode_audio
        | .id = 213
        | .pos[0] -= 310
        | .pos[1] += 560
        | .order = 26
        | .title = "VDN branch audio decode"
        | .inputs[0].link = 310
        | .inputs[1].link = 312
        | .outputs[0].links = [314])
    ]
  | .nodes += [
      ($createvideo
        | .id = 214
        | .pos[0] -= 310
        | .order = 27
        | .title = "VDN branch video"
        | .inputs[0].link = 313
        | .inputs[1].link = 314
        | .outputs[0].links = [315])
    ]
  | .nodes += [
      ($savevideo
        | .id = 215
        | .pos[0] -= 310
        | .order = 28
        | .title = "PRIMARY OUTPUT — native VDN REF2VA"
        | .widgets_values[0] = "video/VDN-H3_R2V_VDN"
        | .inputs[0].link = 315
        | .outputs[0].links = [])
    ]
  | .nodes += [
      ($vdn_source[0].nodes[] | select(.id == 19)
        | .id = 217
        | .pos = [-1500, 60]
        | .order = 29
        | .title = "Control branch — comfy kitchen attention"
        | .inputs[0].link = 316
        | .outputs[0].links = [317])
    ]
  | .nodes += [
      ($vdn_source[0].nodes[] | select(.id == 20)
        | .id = 218
        | .pos = [-1500, 180]
        | .order = 30
        | .title = "Control branch — Scheduled Sol Attention"
        | .type = "MiniMaxH3ScheduledSolAttentionPatch"
        | .properties = {"Node name for S&R": "MiniMaxH3ScheduledSolAttentionPatch"}
        | .widgets_values = [true, 1.2, 0.8, "linear", 12288, false, 0.2, "diag", false, false, "exact_kv_and_rows", ""]
        | .outputs = [(.outputs[0]), {"name": "tau_graph", "type": "IMAGE", "links": null}]
        | .inputs[0].link = 317
        | .outputs[0].links = [318])
    ]
  | .nodes += [{
      "id": 220,
      "type": "MarkdownNote",
      "pos": [-2200, -600],
      "size": [500, 620],
      "flags": {},
      "order": 31,
      "mode": 0,
      "inputs": [],
      "outputs": [],
      "properties": {},
      "title": "VDN REF2VA comparison contract",
      "widgets_values": [$note]
    }]
  | .links += [
      [300, 127, 0, 200, 0, "MODEL"],
      [301, 200, 0, 210, 0, "MODEL"],
      [302, 136, 0, 210, 1, "CONDITIONING"],
      [303, 129, 0, 211, 0, "NOISE"],
      [304, 210, 0, 211, 1, "GUIDER"],
      [305, 206, 0, 211, 2, "SAMPLER"],
      [306, 127, 0, 208, 0, "MODEL"],
      [307, 208, 0, 211, 3, "SIGMAS"],
      [308, 136, 1, 211, 4, "LATENT"],
      [309, 211, 0, 212, 0, "LATENT"],
      [310, 211, 0, 213, 0, "LATENT"],
      [311, 119, 0, 212, 1, "VAE"],
      [312, 120, 0, 213, 1, "VAE"],
      [313, 212, 0, 214, 0, "IMAGE"],
      [314, 213, 0, 214, 1, "AUDIO"],
      [315, 214, 0, 215, 0, "VIDEO"],
      [316, 143, 0, 217, 0, "MODEL"],
      [317, 217, 0, 218, 0, "MODEL"],
      [318, 218, 0, 142, 0, "MODEL"]
    ]
  | .links |= map(select(.[0] != 284))
  | walk(if type == "object" then del(.models) else . end)
' "$ref2v_source" >"$r2v"

jq -e '
  . as $root
  | ([.nodes[] | select(.type == "ApplyVDNH3")] | length) == 1
  and ([.nodes[] | select(.type == "ApplyVDNH3") | .widgets_values]
    == [["stage-dmd-step-250", true, 1, "merge", "cache_gpu", true, "grouped"]])
  and ([.nodes[] | select(.type == "UNETLoader") | .widgets_values[0]]
    == ["minimax_h3_ref2va_bf16.safetensors"])
  and ([.nodes[] | select(.type == "CLIPLoader") | .widgets_values[0]]
    == ["qwen3vl_32b_minimax_h3_bf16.safetensors"])
  and ([.nodes[] | select(.type == "SamplerCustomAdvanced")] | length) == 2
  and ([.nodes[] | select(.type == "BasicGuider")] | length) == 2
  and ([.nodes[] | select(.type == "BasicScheduler") | .widgets_values]
    | sort == ([["beta", 8, 1], ["simple", 4, 1]] | sort))
  and ([.nodes[] | select(.type == "KSamplerSelect") | .widgets_values]
    | sort == ([["er_sde"], ["euler"]] | sort))
  and ([.nodes[] | select(.type == "LoraLoaderModelOnly") | .widgets_values]
    == [["minimax_h3_ref2v_turbo_4step_v0.1_comfyui_bf16.safetensors", 1]])
  and ([.nodes[] | select(.type == "MiniMaxH3SigmaShift") | .widgets_values] == [[12, 3]])
  and ([.nodes[] | select(.type == "MiniMaxH3ScheduledSolAttentionPatch")] | length) == 1
  and ([.nodes[] | select(.type == "MiniMaxH3ScheduledSolAttentionPatch") | .widgets_values]
    == [[true, 1.2, 0.8, "linear", 12288, false, 0.2, "diag", false, false, "exact_kv_and_rows", ""]])
  and ([.nodes[] | select(.type == "ModelAttentionBackend") | .widgets_values]
    == [["comfy kitchen attention"]])
  and ([.nodes[] | select(.type == "SaveVideo")] | length) == 2
  and ([.nodes[] | select(.type == "SaveVideo") | .widgets_values[0]]
    | sort == (["video/VDN-H3_R2V_VDN", "video/VDN-H3_R2V_Turbo4_Control"] | sort))
  and ([.nodes[] | select(.type == "MiniMaxH3ReferenceToVideo") | .widgets_values[1:5]]
    == [[1344, 768, 124, "match"]])
  and all(.links[]; . as $edge
    | any($root.nodes[]; .id == $edge[1]) and any($root.nodes[]; .id == $edge[3]))
  # Branch A: the VDN guider is fed by ApplyVDNH3; both samplers share the fixed noise.
  and ([.links[] | select(.[0] == 301)] == [[301, 200, 0, 210, 0, "MODEL"]])
  and ([.links[] | select(.[0] == 303 or .[0] == 253) | .[1]] | all(. == 129))
  # Branch B: the control guider stays behind LoRA -> kitchen -> Sol -> sigma shift,
  # never behind the VDN patch.
  and ([.links[] | select(.[0] == 286)] == [[286, 142, 0, 126, 0, "MODEL"]])
  and ([.links[] | select(.[0] == 318)] == [[318, 218, 0, 142, 0, "MODEL"]])
  and ([.links[] | select(.[0] == 284)] | length) == 0
  # The VDN branch has exactly one model source: ApplyVDNH3.
  and ([.nodes[] | select(.id == 200) | .inputs[0].link] == [300])
  and ([.nodes[] | select(.id == 210) | .inputs[0].link] == [301])
  and ([.nodes[] | select(.id == 210) | .inputs[1].link] == [302])
' "$r2v" >/dev/null

if grep -RqiE 'pruned_int8|nvfp4|resolve/main|tree/main|ComfyUI-Manager|int8_convrot|int8-convrot' "$output_dir"; then
  echo "VDN workflows retain a lower-precision selector, mutable model URL, or Manager dependency" >&2
  exit 1
fi
[[ $(find "$output_dir" -type f -name '*.json' | wc -l) -eq 2 ]]
