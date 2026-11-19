# MiniMax H3 De-RoPE Turbo v1.1 — qualification workflows

Development-only Turbo variants of the Motion Lab De-RoPE pipeline. Use these when the full 25+25-step package is too slow for iteration, then compare any keeper against the slower control in [`minimax-h3-derope.md`](minimax-h3-derope.md).

Sources are the maintained August 19 recipes in [`matlowai/ComfyUI-MAINodes`](https://github.com/matlowai/ComfyUI-MAINodes) v1.1.3 at `f4868b4a08e8a504ce86db54a17961d399ffa2bc`:

- `examples/motion_pipeline_ref2va_audioinit.json`
- `examples/motion_pipeline_fast_iterate.json`
- `examples/motion_pipeline_upscale_derope.json`

Every source is checksum-gated by [`scripts/comfyui/build-minimax-h3-derope-turbo-workflows.sh`](../../scripts/comfyui/build-minimax-h3-derope-turbo-workflows.sh). The Patreon workflow shown in the source video is not copied.

## Installed workflows

```text
/var/lib/comfyui/user/default/workflows/minimax-h3-derope-turbo-development-v1.1/
├── 01 MiniMax H3 De-RoPE Turbo v1.1 - REF2VA Balanced Audio Development.json
├── 02 MiniMax H3 De-RoPE Turbo v1.1 - FL2VA Fast Iterate Development.json
└── 03 MiniMax H3 De-RoPE Turbo v1.1 - FL2VA Upscale Development.json
```

The directory is immutable. A graph change requires a new version; deployment refuses a differing overwrite. The full-quality v1.0 De-RoPE graphs and all existing Turbo workflow families remain unchanged.

Turbo package v1.0 is superseded: its first live smoke test failed at the source `PathchSageAttentionKJ` node because the pinned ComfyUI environment intentionally has no `sageattention` module. V1.1 removes both SageAttention-dependent nodes, wires the BF16 base directly into the exact chunked-feed-forward patch, and uses ComfyUI's supported PyTorch attention path. Do not use the v1.0 folder.

## Why this is not “add a LoRA to the old graph”

MAINodes documents that putting a Turbo LoRA into the older 25-step/simple/`res_multistep` graph makes pass 2 jerky and pixelated. These variants preserve the complete measured Turbo recipe instead:

| Stage | Recipe |
|---|---|
| pass 1 — choreography | task-matched unpruned BF16 base, 12 steps, `linear_quadratic`, `gradient_estimation` |
| oracle and retime | `H3JerkOracle` → `H3TimeSmear`, balanced hold map |
| pass 2 — repair | task-matched 4-step Turbo adapter at 1.0, `beta`, six total schedule steps |
| injection | `faithful detail 0.50`, so three of the six pass-2 steps execute |
| recovery | `H3ExactRecover` at 24 fps; original pass-1 audio is the safe default |

The source's exact `MiniMaxChunkFeedForward` patch is retained. The two optional SageAttention patches are deliberately absent because they cannot execute in the pinned environment; the first smoke test proved that failure boundary before any sampling began.

## Pinned workstation selectors

| Profile | Base model | Pass-2 adapter |
|---|---|---|
| REF2VA Balanced Audio | `minimax_h3_ref2va_bf16.safetensors` | `minimax_h3_ref2v_turbo_4step_v0.1_comfyui_bf16.safetensors` |
| FL2VA Fast Iterate | `minimax_h3_fl2va_bf16.safetensors` | `minimax_h3_fl2v_turbo_4step_v1.0_768p_comfyui_bf16.safetensors` |
| FL2VA Upscale | `minimax_h3_fl2va_bf16.safetensors` | `minimax_h3_fl2v_turbo_4step_v1.0_768p_comfyui_bf16.safetensors` |

All three use `qwen3vl_32b_minimax_h3_bf16.safetensors`, the FP16 video VAE, and the FP32 audio VAE. Turbo is downstream of pass 1 and cannot decide the initial choreography.

## Choosing a profile

- **REF2VA Balanced Audio:** the author’s recommended starting point. Replace `example.png` with one appearance reference. It runs at 1344×768 for 124 frames and writes baseline, oracle/dilated diagnostics, recovered original-audio output, and an explicit seeded-foley alternate.
- **FL2VA Fast Iterate:** low-resolution scouting at roughly 0.2 MP for pass 1 and 0.4 MP for repair. Use it to choose prompt, seed, and choreography—not to judge final detail.
- **FL2VA Upscale:** pass 1 at roughly 0.4 MP with repair at 1.5 MP. It trades softer oracle evidence for a faster high-resolution result.

## Qualification trial

1. Stop other two-GPU inference workloads and start ComfyUI.
2. Open **User workflows → `minimax-h3-derope-turbo-development-v1.1`**.
3. Start with the REF2VA Balanced Audio graph and a 2–5 second reference-safe test.
4. Preserve prompt, input, seed, duration, and output from the baseline and recovered arms.
5. Scrub both outputs frame by frame around the oracle’s hot burst, then watch at normal speed with audio.
6. Compare against the full-BF16 25+25-step REF2VA graph before keeping a final. Turbo winning on speed does not establish equal detail or identity retention.
7. Use Fast Iterate for prompt/seed search and Upscale only after the motion pattern is worth a larger repair pass.

Judge fast hands, faces, limbs, props, cloth, rotating edges, camera motion, lip sync, and audio transitions. A successful queue is technical evidence only; these workflows remain Development-only.

## First desktop qualification — 2026-09-08

The first v1.0 queue failed before sampling at `PathchSageAttentionKJ` with `ModuleNotFoundError: sageattention`. That failure produced no media and is the reason for the immutable v1.1 correction.

V1.1 then completed two real two-pass queues on `desktop`:

| Trial | Result | Runtime | Outputs |
|---|---|---:|---|
| FL2VA Fast Iterate, source prompt/seeds | success | 91 s after the failed run had already staged models | baseline + recovered, 107 frames at 24 fps; 448² baseline and 640² recovered |
| REF2VA Balanced Audio, generated synthetic reference, 2.3 s | success | 190 s after a ComfyUI restart | baseline + recovered + seeded-foley alternate, each 56 frames at 24 fps and 1024² |

Outputs are retained under `/var/lib/comfyui/output/video/DeRoPE_Turbo_v1_1/` with `Smoke_` prefixes. `ffprobe` confirmed exact matching frame count, rate, duration, stereo 32 kHz audio, and decodability for each paired result. The REF2VA baseline/recovered pair measured SSIM `0.881230`; global `blurdetect` means were `7.9202085` and `7.8838733`, respectively. Those whole-frame measurements show close structural retention but are not a motion-smear verdict.

Contact-sheet review found the REF2VA repair materially more promising than the scout: it kept the subject, setting, major poses, and sword trajectory close while rendering the bright sword arc and fast-turn silhouettes more cleanly. The low-resolution Fast Iterate result showed much larger pose reinterpretation, confirming its role as a prompt/seed scout rather than a keeper path. Normal-speed human playback and listening are still required before any quality promotion.

## Verification

```bash
bash tests/minimax-h3-derope-turbo-workflows-contract.sh
sudo nixos-rebuild build --flake .#desktop
```

After deployment, load all three graphs in ComfyUI and confirm there are no missing-node warnings. A live qualification should produce at least the paired baseline and recovered videos and finish with an empty queue.
