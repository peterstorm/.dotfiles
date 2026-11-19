# Local AI video script and MiniMax H3 runbook

Research snapshot: **2026-08-18**. Target workstation: 2× RTX PRO 6000 Blackwell
Workstation Edition (97,887 MiB each), 96 GiB host RAM, headless NixOS.

This document remains the maximum-fidelity H3 architecture and licensing analysis.
For the Nix-managed ComfyUI deployment, Krea 2 image workflows, Muse prompt node,
and immediately usable hosted H3 reference/video workflows, use
[`comfyui-krea2-minimax-h3-muse-runbook.md`](comfyui-krea2-minimax-h3-muse-runbook.md).

## Decision

Use **Muse Glimmer 30B BF16** as the scriptwriter and H3 prompt author.

Why:

- On the current [EQ-Bench Creative Writing v3](https://eqbench.com/creative_writing.html)
  snapshot, Muse Glimmer scores **1787.4 Elo / 16.26 rubric**. The comparable local-size
  alternatives trail substantially: Gemma 4 31B is 1365.5 / 16.01, Gemma 4 26B-A4B is
  1300.9 / 16.03, Gemma 4 12B is 1285.8 / 15.71, and NVIDIA Nemotron 3.5 Lightning
  30B-A3B NVFP4 is 1275.9 / 14.39.
- Its Apache-2.0 BF16 checkpoint is 55.49 GiB, fits comfortably on one card, supports
  images, and has strong instruction following. Its lossless DFlash assistant can improve
  generation speed without changing the target distribution.
- MiniMax publishes an official, portable
  [H3 prompt-writing skill](https://github.com/MiniMax-AI/MiniMax-H3/tree/main/skills/h3-prompt-writing).
  That scaffold supplies the video-specific structure Muse itself was not explicitly
  trained for.

This is not a claim that EQ-Bench directly measures short-film scripts—it is the strongest
current independent evidence for prose quality among models that fit easily on this machine.
The final gate is a small blind evaluation using the actual video brief and H3 outputs.

### Alternatives

| Model | BF16 artifact | CW v3 Elo | Use it when |
|---|---:|---:|---|
| **Muse Glimmer 30B** | 55.49 GiB | **1787.4** | Default: best current creative-writing evidence and Apache-2.0 |
| Gemma 4 31B | 58.28 GiB | 1365.5 | A second voice for blind A/Bs; stronger general reasoning than its writing rank suggests |
| Gemma 4 12B | 22.31 GiB | 1285.8 | A small fallback when memory matters more than writing quality |
| Gemma 4 26B-A4B | 48.10 GiB | 1300.9 | Fast MoE inference, but no quality case over Muse for this task |
| Qwen3.8-27B | 51.76 GiB | not listed | Coding/agent work; do not infer creative rank from unrelated benchmarks |

The much higher-scoring Qwen3.8-2.4T-A95B is not a workstation model: its 2.4T total
parameters do not fit 192 GiB VRAM. Do not confuse it with Qwen3.8-27B.

## Legal stop: H3 local weights are not currently licensed for Denmark

MiniMax H3 is open-weight but **not open source**. Its community license defines the EU,
UK, South Korea, and US as “Excluded Territories” and grants no right to run or display the
weights there. Denmark is in the EU.

**Do not download or run the local H3 weights until MiniMax grants a separate license.**
Apply through [MiniMax’s H3 license form](https://platform.minimax.io/h3-license). Archive
written authorization with the deployment record. This is a license reading, not legal
advice.

Muse Glimmer is Apache-2.0 and can still be evaluated independently. MiniMax’s hosted API
has separate service terms; confirm account availability and terms rather than assuming the
weight license applies to the API.

## What “H3 at max fidelity” actually means

The complete H3 system has three stages:

1. **H3-Context-IR** — hosted-only; the open release does not include its models/services.
2. **H3-Base** — available locally, producing up to 768p-short-edge video with native
   32 kHz stereo audio at 24 FPS.
3. **H3-Regenerate-2K** — hosted-only in the current release.

Therefore:

- **Highest-fidelity local-only path:** H3-Base with released BF16/FP32 math, eager
  execution, full 50-step denoising, and no approximation. Output is 768p, not 2K.
- **Full official 2K path:** hosted Context-IR → local or hosted H3-Base → hosted
  Regenerate-2K. It is not fully local.
- Muse plus the official H3 prompt skill is a useful local replacement for Context-IR, but
  it is not bit-equivalent to MiniMax’s undisclosed multi-stage hosted system.

For a reference-quality H3-Base run, keep all of the following:

- BF16 transformer/text-encoder weights and the checkpoint’s FP32 components;
- 50 inference steps, `flow_shift=12`, `audio_flow_shift=3` as the initial baseline;
- eager execution and an exact attention backend;
- one task family (`fl2va` for text/first/last frame, or `ref2va` for references);
- no Turbo LoRA, INT8/FP8/NVFP4 quantization, Cache-DiT, approximate attention, or
  `torch.compile` consistency shortcut.

SGLang documents that its current `torch.compile` path changes numerical output. Weight
placement/offload can be lossless, but this workstation’s 96 GiB host RAM rules out the
published 384-GiB-class layerwise-offload recipe.

## Residency plan: sequential, not simultaneous

Do **not** promise concurrent Muse BF16 and full-fidelity H3 on this host.

A single original H3 FL2VA checkpoint family occupies about **134.1 GiB on disk** across
its transformer, text encoder, video VAE, and audio VAE. The current vLLM-Omni recipe has a
specific 2× RTX PRO 6000 TP2 profile, sharding the DiT and text encoder over both cards.
That profile needs both GPUs and has not published a memory receipt for this exact
96-GiB-RAM workstation.

Muse BF16 plus its BF16 DFlash assistant is roughly 60.2 GiB. Co-residency would consume
H3’s activation and VAE-decode headroom, contend for both cards, and has no qualified
recipe. A smaller quantized writer might happen to fit, but that is not the max-fidelity
baseline.

Use this lifecycle:

1. Run Muse on one GPU and create all script/prompt candidates.
2. Save the selected production packet to disk.
3. Stop Muse and verify both cards are nearly empty.
4. Start H3-Base TP2 across both cards and render.
5. Stop H3 before restarting the writer for revisions.

If uninterrupted concurrency becomes a hard requirement, first qualify Gemma 4 12B Q4 on
CPU or spare VRAM against a completed H3 baseline. Treat that as a separate, lower-quality
profile—not the reference setup.

## Script-to-video workflow

### 1. Write the creative brief

Keep the brief concrete:

```text
Goal: <what the viewer should feel or do>
Duration: <4–15 seconds>
Format: <9:16, 16:9, ...>
Audience/platform: <where it will run>
Subject/product: <must remain recognizable>
Tone: cool and edgy, defined as <specific tension/subculture/material language>
Must include: <dialogue, action, logo, object, sound>
Must avoid: <cliches, unsafe/IP-sensitive elements, continuity failures>
Input mode: T2VA | I2VA | FL2VA | L2VA | Ref2VA
References: <Picture 1 / Video 1 / Audio 1 mappings>
```

Translate “cool and edgy” into decisions. Prefer a visual contradiction, one iconic prop,
a hard editorial beat, tactile materials, and a specific camera move. Reject generic neon
alleys, hooded figures, random glitch, purple cyberpunk haze, and the word “cinematic” when
it is not backed by composition, lens, motion, light, and sound.

### 2. Generate candidates with Muse

Use the model-card defaults: `temperature=1.0`, `top_p=0.95`, `top_k=64`. Start with high
reasoning. Generate four independent candidates rather than repeatedly asking one thread to
rewrite itself.

Prompt:

```text
You are writing a production-ready micro-film for MiniMax H3.

Create four genuinely different concepts from the brief. Each must fit the requested
4–15 second runtime and be shootable as one or two shots. Hook the viewer in the first
second. Use concrete blocking, camera movement, lighting, material detail, synchronized
sound, and dialogue timing. “Edgy” must come from tension and art direction, not generic
cyberpunk vocabulary.

For each concept output:
1. title and one-sentence logline;
2. exact timeline with timestamps;
3. spoken dialogue, if any;
4. picture action and camera direction;
5. diegetic sound and music beat;
6. continuity risks and H3 failure risks.

Then rank the four against novelty, immediate hook, visual legibility, temporal feasibility,
and freedom from AI cliches. Do not write the final H3 prompt yet.

BRIEF:
<paste brief>
```

Select the concept yourself; do not blindly accept the model’s ranking. Dialogue must fit
real speech time, and every visible action must complete inside the duration.

### 3. Compile the selected script into H3 syntax

Use the official H3 prompt-writing skill at a pinned revision. For base/keyframe modes its
final field order is:

```text
integrated_multimodal_description: ...
overall_soundscape: ...
non_diegetic_music: ...
```

For Ref2VA the required order is:

```text
subject_definitions: ...
summary: ...
retention_analysis: ...
detailed_description: ...
overall_soundscape: ...
non_diegetic_music: ...
```

Rules:

- Keep section names, reference labels, timestamps, and shot order exact.
- Write rewrite sections in English; preserve spoken dialogue, lyrics, and visible text in
  their requested language.
- Every shot must specify composition, subjects, environment, action, camera, sound, and
  when each reference appears.
- Prefer literal visual/audio instructions over plot summary or mood adjectives.
- Do not invent unresolved `<Picture N>`, `<Video N>`, or `<Audio N>` labels.

Store a production packet containing the original brief, selected script, final H3 prompt,
seed, model revisions, generation settings, and output paths. This makes rerenders and blind
comparisons reproducible.

### 4. Free the GPUs

Before H3:

```bash
docker ps --format 'table {{.Names}}\t{{.Status}}'
nvidia-smi --query-gpu=index,name,memory.used,power.limit --format=csv
systemctl is-active display-manager
```

Stop the writer container and the display manager. Do not proceed until both GPUs are below
about 2 GiB used and remain at the workstation’s current diagnostic power cap.

### 5. Launch H3 only after authorization

Use the current vLLM-Omni recipe’s **`rtx_pro_6000_2x`** profile as the starting topology:

- one task family loaded;
- 2 GPUs;
- DiT tensor parallel 2;
- sequence parallel 1 / Ring 1;
- text-encoder tensor parallel 2;
- tiled VAE patch parallel 2;
- BF16, resident, eager, no distributed layerwise offload.

Generate the exact command from the pinned recipe version rather than copying an old nightly
command. H3 support is in **vLLM-Omni**, not the ordinary vLLM wheel. Preserve the current
container/source revision and image digest in the production packet.

Start with a 5-second 1344×768 T2VA request at 50 steps. Only then test longer clips and
Ref2VA. The first qualification must record peak memory on each GPU; “weights fit” does not
prove that the longest packed attention sequence and tiled VAE decode fit.

### 6. Acceptance gate

Do not call the workstation profile qualified until all are true:

- [ ] Written H3 authorization covers the deployment territory and use case.
- [ ] Both GPUs remain visible; no Xid, ECC, CUDA, NCCL, or container restart occurs.
- [ ] A 5-second 1344×768, 50-step T2VA request completes with 24 FPS video and 32 kHz
      stereo audio.
- [ ] The intended maximum duration/aspect ratio completes with at least 8 GiB peak VRAM
      headroom per card.
- [ ] Three fixed seeds rerun reproducibly under the pinned runtime.
- [ ] Output is compared against the same prompt through the official API where permitted.
- [ ] At least ten real briefs are scored blind for hook, originality, shot feasibility,
      prompt adherence, dialogue timing, visual continuity, and sound alignment.
- [ ] Muse beats Gemma 4 31B often enough on those briefs to justify the benchmark-based
      choice; otherwise switch based on the local evidence.

## Practical operating modes

| Goal | Writer | Video path | Recommendation |
|---|---|---|---|
| Best local script quality | Muse Glimmer BF16 + DFlash | none | Can evaluate now |
| Fully local video after licensing | Muse sequentially | H3-Base BF16 TP2, 768p | Preferred privacy path; first qualify memory |
| Highest official H3 fidelity | Muse for ideation | Hosted Context-IR + Base + hosted 2K regeneration | Only route to the current complete 2K system |
| Always-on writer while rendering | Gemma 4 12B quantized, experimental | H3-Base TP2 | Lower-quality, unqualified fallback |

## Sources

Accessed 2026-08-18 unless noted.

- [EQ-Bench Creative Writing v3 leaderboard](https://eqbench.com/creative_writing.html)
- [Muse Glimmer 30B model card](https://huggingface.co/meta-models/Muse-Glimmer-30B)
- [Gemma 4 31B model card](https://huggingface.co/google/gemma-4-31B-it)
- [Gemma 4 26B-A4B model card](https://huggingface.co/google/gemma-4-26B-A4B-it)
- [Gemma 4 12B model card](https://huggingface.co/google/gemma-4-12B-it)
- [MiniMax H3 model card and deployment overview](https://huggingface.co/MiniMaxAI/MiniMax-H3)
- [MiniMax H3 community license](https://huggingface.co/MiniMaxAI/MiniMax-H3/blob/main/LICENSE)
- [MiniMax H3 license Q&A](https://huggingface.co/MiniMaxAI/MiniMax-H3/blob/main/docs/QA-about-License.md)
- [Official H3 prompt-writing skill](https://github.com/MiniMax-AI/MiniMax-H3/tree/d21241f0a4b3acbb34c97dae47fa417b7065e438/skills/h3-prompt-writing)
- [vLLM MiniMax H3 recipe](https://github.com/vllm-project/recipes/blob/682624e295fb17c5ae3110d2d02f05e3eeddf494/models/MiniMaxAI/MiniMax-H3.yaml)
- [SGLang MiniMax H3 cookbook](https://github.com/sgl-project/sglang/blob/63d783bbe0955237ec41f9ddabf7235ddf04673c/docs/cookbook/diffusion/MiniMax/MiniMax-H3.mdx)
