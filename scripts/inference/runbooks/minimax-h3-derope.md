# MiniMax H3 De-RoPE v1.0 — anti-smearing workflows

Development-only workflows for repairing fast-motion smearing with MatlowAI's Motion Lab De-RoPE pipeline.

Sources:

- [Machine Delusions video](https://youtu.be/IlVPJI9ceKM)
- [Video research receipt and timestamped findings](../research/2026-09-08-minimax-h3-derope-video-research.md)
- [`matlowai/ComfyUI-MAINodes`](https://github.com/matlowai/ComfyUI-MAINodes) v1.1.3 at `f4868b4a08e8a504ce86db54a17961d399ffa2bc` (GPL-3.0)

The video's Patreon graph is account-gated and is not copied. These workflows are adapted from the node author's public examples, each checksum-gated by `scripts/comfyui/build-minimax-h3-derope-workflows.sh`.

## Installed workflows

```text
/var/lib/comfyui/user/default/workflows/minimax-h3-derope-development-v1.0/
├── 01 MiniMax H3 De-RoPE v1.0 - FL2VA Automatic Full BF16 Development.json
├── 02 MiniMax H3 De-RoPE v1.0 - FL2VA Targeted Full BF16 Development.json
└── 03 MiniMax H3 De-RoPE v1.0 - REF2VA Audio Full BF16 Development.json
```

The v1.0 directory is immutable: deployment refuses to overwrite it with different content. Any graph change requires v1.1 or another new version. Existing production, Director, Turbo, Motion Context, and VDN workflows remain untouched.

For the maintained 12-step-base/6-step-Turbo repair recipes, use the separate immutable [`minimax-h3-derope-turbo-development-v1.1`](minimax-h3-derope-turbo.md) package. Do not add a Turbo LoRA directly to these older 25-step graphs; the node author reports that recipe becomes jerky and pixelated.

## What the nodes do

```text
pass-1 latent ──> H3 Jerk Oracle ──> hold map ───────────────┐
pass-1 frames ─────────────────────> H3 Time Smear ─> encode ├─> H3 V2V Init
pass-1 audio ──────────────────────> H3 Audio Smear ─> encode┘
                                                               │
                                     H3 Inject Schedule <───────┘
                                               │
                                      pass-2 diffusion/decode
                                               │
                         H3 Exact Recover + H3 Audio Recover
                                               │
                                    original frame count @ 24 fps
```

`H3 Jerk Heatmap` saves the oracle overlay for review. The targeted graph adds `H3 Manual Hold Map`, initially set to an example range: replace it after reviewing your own heatmap.

This is temporal repair, not conventional interpolation. The frames discarded by `H3 Exact Recover` were working time for pass 2; they are not added to the delivered runtime.

## Quality profile

Every graph is pinned to the workstation's unquantized stack:

| Role | Selector |
|---|---|
| FL2VA diffusion | `minimax_h3_fl2va_bf16.safetensors` |
| REF2VA diffusion | `minimax_h3_ref2va_bf16.safetensors` |
| text encoder | `qwen3vl_32b_minimax_h3_bf16.safetensors` |
| video VAE | `minimax_h3_video_vae_fp16.safetensors` |
| audio VAE | `minimax_h3_audio_vae_fp32.safetensors` |

Both passes use 25 steps, `res_multistep`, and the `simple` schedule. No Turbo LoRA, quantized selector, mutable model URL, Manager dependency, Sage patch, or chunked feed-forward speed patch survives the adaptation. Pass 2 starts with the `faithful detail 0.50` injection preset to limit choreography drift.

## Choosing a workflow

- **FL2VA Automatic:** first/last-frame family with oracle-selected high-motion spans. Start here for unattended diagnosis.
- **FL2VA Targeted:** first/last-frame family with manual time ranges. Use this after the automatic oracle map identifies a specific burst and you want lower cost or less global reinterpretation.
- **REF2VA Audio:** reference-image family. Replace `example.png` with the intended character/location reference. The primary output preserves pass-1 audio; the seeded-foley output is an explicit alternate.

## Operation

1. Stop other two-GPU inference workloads and start ComfyUI.
2. Open **User workflows → `minimax-h3-derope-development-v1.0`**.
3. Start with a 2–3 second legal H3 clip. The second pass can cost several times a baseline generation because held frames enlarge its temporal latent.
4. Set the prompt/reference/first frame and queue once.
5. Compare:
   - baseline output;
   - oracle heatmap;
   - dilated preview;
   - recovered output.
6. Scrub frame-by-frame around fast hands, faces, limbs, props, cloth, and camera changes, then review at normal speed.
7. For the targeted graph, enter only confirmed problem ranges in `H3 Manual Hold Map` and queue again.
8. If motion changes too much, lower injection below 0.50 or narrow the targeted range. If smear remains, compare a stronger injection deliberately rather than silently changing the default.
9. Keep original pass-1 audio unless the seeded pass-2 foley has been explicitly reviewed.

## Limits

- This does not guarantee improvement. The video shows that some spans remain unchanged or can look worse when the oracle does not intervene appropriately.
- A stronger second pass can invent poses or reinterpret choreography.
- Automatic heat masks do not know where a visually acceptable compositing seam belongs; prefer targeted time ranges before adding spatial masks.
- Long/high-resolution dilated passes scale steeply in memory and time. Prove a short clip first.
- Technical execution remains Development evidence, not Production authority.

## Verification

```bash
bash tests/minimax-h3-derope-workflows-contract.sh
sudo nixos-rebuild build --flake .#desktop
```

After deployment, ComfyUI must register `H3JerkOracle`, `H3TimeSmear`, `H3V2VInit`, `H3ExactRecover`, `H3AudioSmear`, `H3AudioRecover`, and `H3ManualHoldMap`, and all three installed workflow JSON files must parse successfully.
