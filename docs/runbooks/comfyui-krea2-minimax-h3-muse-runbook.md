# ComfyUI creative stack — Krea 2 + MiniMax H3 + Muse Glimmer

Research snapshot: **2026-08-21**. Target: `desktop`, headless NixOS, Ryzen 9
9950X, 91 GiB RAM, 2× RTX PRO 6000 Blackwell 96 GiB over PCIe PHB.

## Decision

Use one Nix-managed ComfyUI service and keep the workflow native-first:

- **Muse Glimmer 30B BF16 + DFlash** on physical GPU0 writes and compiles
  creative briefs into model-ready prompts.
- **ComfyUI 0.31.1** on physical GPU1 runs local Krea 2 and exposes MiniMax H3
  workflows. The UI listens only on `127.0.0.1:8188` and is reached through an
  SSH tunnel.
- **Krea 2 Turbo BF16** is the default local image model. The official INT8
  ConvRot style-reference path and official style LoRAs are installed beside it.
- **MiniMax H3 API partner nodes** are the immediately usable H3 path in Denmark:
  text-to-video, first/last-frame, multimodal reference-to-video, Context IR
  prompt refinement, and 2K regeneration.
- **Local H3 core nodes use the separately authorized original unpruned BF16
  reference profile; downloads remain dual-gated by license acceptance and
  territorial authorization attestation.**

This deliberately does **not** install ComfyUI-Manager or permit mutable node
installs. Core supplies the standard generation nodes. The in-repo Muse adapter
and the three packs required by Pixaroma Episode 30 are immutable source pins:
Krea 2 Identity Edit, Krea2T Enhancer, and Pixaroma. The latter is a broad pack,
but it is now a concrete workflow dependency rather than speculative tooling;
ComfyUI remains loopback-only and systemd-confined.

## What is declarative and what is not

| Concern | Owner | Reproducibility |
|---|---|---|
| ComfyUI runtime | `machines/desktop/comfyui.nix` | Nix flake pin |
| CUDA PyTorch | Nixpkgs `torch-bin`, `triton-bin`, `torchvision-bin`, `torchaudio-bin` | Nix flake pin; no source build |
| Core nodes and template library | ComfyUI/Nix package | Nix flake pin |
| Muse prompt node | `comfyui/custom_nodes/muse_glimmer_prompt/` | immutable Nix-store path |
| Episode 30 node packs | GitHub commits in `machines/desktop/comfyui.nix` | immutable source hashes |
| Episode 30 workflows + six inputs | Pixaroma ZIP, installed under `/var/lib/comfyui/` | URL + exact SHA-256; 7/7 JSON gate |
| Curated creative suite | 51 official Comfy workflows under six task folders | pinned template package; exact file manifest + JSON gate |
| Full Template Library | 506 additional official workflows | Comfy package 0.11.37 in the Nix closure |
| Krea/edit/prompt model files | `/models/comfyui/` | HF revision + exact size + SHA-256 manifest |
| User workflows, input, output, database | `/var/lib/comfyui/` | mutable state, mode 0700/0750 |
| Comfy account/partner credits | Comfy account | external prepaid service |
| Muse bearer key | `~/.config/muse-glimmer/api-key` | private file, never a node widget |

The current flake resolves ComfyUI 0.31.1, frontend 1.48.7, workflow templates
0.11.37, and PyTorch 2.12.0 with CUDA 13.2 libraries. ComfyUI 0.31.1 exceeds
both upstream minimums: Krea 2 landed in 0.26 and MiniMax H3 requires 0.30+.

## Why this architecture

| Approach | Result |
|---|---|
| **Nix package + binary CUDA wheels + core nodes** | Chosen: immutable, fast to realize, no pip environment drift |
| Nix `cudaSupport=true` source build | Rejected: dry-run requires 119 local derivations including PyTorch, Triton, CUDA, NCCL, and OpenMPI |
| Docker/community ComfyUI image | Rejected: no official ComfyUI image and a second mutable supply chain |
| Python venv + ComfyUI-Manager | Rejected: mutable git/pip installs and weak rollback/reviewability |

Nixpkgs' default ComfyUI package evaluates with source-built CPU PyTorch, and its
internal Python override discards a caller's package substitutions. The workstation
module therefore retains Nixpkgs' pinned ComfyUI source but explicitly rebuilds the
wrapper environment around pinned CUDA binary wheels plus CUDA 13.2 bindings.
Nix still realizes CUDA support libraries and Python wrappers, but it does **not**
compile PyTorch or Triton from source. The module also disables NVSHMEM's
non-installed test and example targets; Nixpkgs otherwise compiles their full
all-architecture matrix despite disabling the package check phase. Finally, it
relaxes the cu130 wheel's stale `setuptools<82` metadata cap, matching Nixpkgs'
source-Torch recipe. Nixpkgs' torchaudio 2.11 binary source resolves to a CUDA
12 wheel independently of the CUDA package override, so the module pins the
same release's official cu130/cp314 wheel by SHA-256. Torch and torchaudio
import checks remain enabled.

## Legal gates

### MiniMax H3 local weights: separate authorization required

The MiniMax H3 Community License defines the EU, UK, South Korea, and US as
**Excluded Territories**. Denmark is in the EU, so the community license alone
does not authorize local use. The operator reported obtaining separate MiniMax
permission on 2026-08-21. Archive the grant with the deployment record before
activation. The downloader requires both `MINIMAX_H3_ACCEPT_LICENSE=yes` and
`MINIMAX_H3_AUTHORIZED=yes`; neither defaults open.

MiniMax's own license Q&A separately states that the **MiniMax H3 API is
available globally** because MiniMax operates moderation and compliance
controls. The ComfyUI H3 partner nodes use hosted generation and are the legal
initial path, subject to Comfy/MiniMax service terms and account availability.

### Krea 2 weights: usable, but not open source

Krea 2 uses the Krea 2 Community License:

- local and commercial use is permitted below **$1,000,000 USD trailing
  twelve-month company-wide revenue**;
- commercial use at or above that threshold requires an enterprise license;
- the deployment must implement reasonable content-filter measures;
- outputs are owned by the user, subject to compliance;
- acceptable-use, attribution, distribution, and AI-disclosure duties still
  apply.

For this private, loopback-only single-user deployment, manual human review
before publishing or distributing an output is the initial content-filter
control explicitly contemplated by the license. Do not expose generation to
other users without adding technical moderation, reporting, and audit controls.
This is a license reading, not legal advice.

## 1. Apply the NixOS configuration

Build the pinned configuration before switching:

```bash
cd ~/.dotfiles
sudo nixos-rebuild build --flake .#desktop
nix-store --query --references result | grep -E 'comfyui|torch' | sort
sudo nixos-rebuild switch --flake .#desktop
```

The switch installs:

- `comfyui` with CUDA-capable Nix binary wheels;
- `hf` for pinned model downloads;
- FFmpeg;
- `comfyui.service`, installed but intentionally not boot-started while the
  normal Qwen TP2 profile owns both GPUs;
- `/models/comfyui/{diffusion_models,text_encoders,vae,loras,...}`;
- the immutable Muse, Krea edit, Krea enhancer, and Pixaroma nodes via an
  extra-path YAML in the Nix store;
- all seven Episode 30 workflows under
  `/var/lib/comfyui/user/default/workflows/pixaroma-ep30/` and all six supplied
  sample inputs under `/var/lib/comfyui/input/`;
- 51 curated official workflows under
  `/var/lib/comfyui/user/default/workflows/creative-suite/`, grouped into image,
  video, audio, 3D, enhancement, and hosted-frontier folders.

Verify that the unit is installed, explicitly inactive, and pinned to GPU1:

```bash
systemctl cat comfyui.service
! systemctl is-active --quiet comfyui.service
systemctl show comfyui -p Environment --value | grep CUDA_VISIBLE_DEVICES=1
! ss -H -ltn 'sport = :8188' | grep -q .
```

Do not start it directly while Qwen owns both cards. Section 3 performs the
transactional profile switch. After activation, acceptance requires:

- the listener is exactly `127.0.0.1:8188`, not `0.0.0.0`;
- logs list Muse, `Krea2EditModelPatch`, Krea2T Enhancer, and Pixaroma without
  import or database errors;
- `/var/lib/comfyui/user/comfyui.db` exists with no group/world access;
- exactly seven Episode 30 workflows and six source inputs are installed;
- Torch reports CUDA and the RTX PRO 6000 when a workflow starts;
- no firewall rule exposes 8188;
- ComfyUI-Manager is absent.

## 2. Open the UI safely

ComfyUI has no production-grade authentication. Never open port 8188 on the
LAN. From the client machine:

```bash
ssh -N -L 8188:127.0.0.1:8188 desktop
```

Open <http://127.0.0.1:8188>. The browser sees a localhost secure context,
which is also required for Comfy partner-node login.

For H3 or Krea partner nodes:

1. Open **Settings → User** and log into a Comfy account.
2. Open **Settings → Credits** and add only a controlled prepaid balance.
3. Confirm a partner workflow shows its price before queuing.
4. Do not use a LAN URL; partner login is restricted to localhost/HTTPS unless
   using a Comfy API-key integration.

Comfy partner nodes do not currently accept a provider API key directly. They
use a Comfy account and credits. Inputs and references are uploaded through
Comfy to the provider and are subject to both services' policies.

## 3. Activate the creative GPU profile

The transactional activator stops known Qwen/DeepSeek containers, keeps them
available for rollback, starts Nix-managed ComfyUI, and starts Muse on GPU0:

```bash
cd ~/.dotfiles
bash scripts/comfyui/activate-creative-stack.sh
```

Expected topology:

| Physical card | Process | Purpose |
|---|---|---|
| GPU0 | `muse-glimmer-30b-bf16-dflash` | prompt/script author, `:8001` |
| GPU1 | `comfyui.service` | Krea 2/local media generation |

The activator records which known inference containers were running and
whether ComfyUI was active, checks that the target GPUs were released, and
restores the complete prior profile if activation fails. It preserves an
already healthy Muse container rather than replacing it.

Check:

```bash
curl -fsS http://127.0.0.1:8188/system_stats | jq .
bash scripts/inference/qwen38/switch-qwen38-backend-v2.sh status
key="$(< ~/.config/muse-glimmer/api-key)"
curl -fsS -H "Authorization: Bearer $key" http://127.0.0.1:8001/v1/models | jq .
nvidia-smi --query-compute-apps=gpu_uuid,pid,used_memory --format=csv
```

ComfyUI itself uses little VRAM while idle, but Qwen must not remain on GPU1
when a local diffusion workflow loads. Partner-only H3 workflows do not need
local GPU inference, but preserving the same topology keeps Muse prompting
available.

## 4. Install the local Krea 2 production profile

Read <https://www.krea.ai/krea-2-licensing>, then deliberately acknowledge it:

```bash
cd ~/.dotfiles
KREA2_ACCEPT_LICENSE=yes bash scripts/comfyui/download-krea2-models.sh
```

The downloader fetches only these pinned production artifacts from
`Comfy-Org/Krea-2@e5ea8b4dd7f38f348b138eb0fe29f92c0e367e96`:

- Turbo diffusion model BF16 and Qwen3-VL-4B encoder BF16 for highest-fidelity
  local text-to-image;
- Turbo INT8 ConvRot and Qwen3-VL-4B FP8 for the official style-reference
  workflow;
- Qwen Image VAE;
- Krea style-reference LoRA;
- nine official Krea style LoRAs;
- Krea 2 Identity Edit v1.2 LoRA at
  `conradlocke/krea2-identity-edit@89e9e7a...`;
- outfit-transfer LoRA at
  `AliveAi/Krea-2-Edit-Outfit-Transfer@827dab8...`;
- the Episode 30 H3 prompt node's Qwen3-VL-8B Heretic FP8 encoder at
  `DreamFast/Qwen3-VL-8B-Heretic-1.3.0@28dc012...` (Apache-2.0).

Total download is about 71.8 GB. Every file has an exact expected byte count
and SHA-256. Files are downloaded to a same-filesystem staging tree, verified,
and atomically renamed into `/models/comfyui`; partial or corrupt profiles do
not become the completion marker.

Re-running the script verifies the complete profile and is idempotent:

```bash
KREA2_ACCEPT_LICENSE=yes bash scripts/comfyui/download-krea2-models.sh
# KREA2_MODELS_READY: Comfy-Org/Krea-2@e5ea8b...
```

Krea 2 RAW is intentionally omitted. RAW takes 52 steps and is the model to
fine-tune LoRAs against; Turbo is the 8-step production model and accepts RAW
LoRAs. Add RAW only when a real LoRA-training or diversity experiment justifies
another 26.3 GB artifact and a separate benchmark.

## 5. Best Krea 2 nodes and workflows

### Local, private, default

Open **Template Library → Image**:

1. **Krea-2: Text to Image** (`image_krea2_turbo_t2i`)
2. **Krea-2 Style Reference**
   (`image_krea2_turbo_int8_image_style_reference`)

These are official Comfy templates using core nodes. No custom package is
needed. For the normal image workflow, select:

- `krea2_turbo_bf16.safetensors`;
- `qwen3vl_4b_bf16.safetensors`;
- `qwen_image_vae.safetensors`;
- 8 steps;
- 1K for iteration, then 2.0 megapixels for the selected final.

For style reference, use the official dedicated combination:

- `krea2_turbo_int8_convrot.safetensors`;
- `qwen3vl_4b_fp8_scaled.safetensors`;
- `qwen_image_vae.safetensors`;
- `krea2_style_reference.safetensors`.

Krea's local prompting rules are simple: natural language, faithful detail,
long prompts when useful, and exact visible text in double quotes. The Muse
node embeds Krea's official expansion contract.

### Pixaroma Episode 30 — complete imported bundle

The source is [Episode 30](https://www.youtube.com/watch?v=rGVf3m19yM8),
`Ep30 Workflows.zip`, 5,823,896 bytes, SHA-256
`46fcbc0e630f5a4ee028bdd841d04f26ca97ca538c3c33d2923159d9b1f59799`.
Nix installs all seven workflows and six included example images on every
ComfyUI start:

1. `Krea 2 + Edit Lora`
2. `Krea 2 + Edit Lora - Custom Ratio`
3. `Krea 2 + Edit Lora - Character and Background`
4. `Krea 2 + One Image Outfit Lora`
5. `Krea 2 + Outfit Transfer 2`
6. `Minimax H3 Text 2 Video Prompt Generator`
7. `Minimax H3 First Frame 2 Video Prompt Generator`

The deployment normalizes three stale saved selectors without changing graph
topology: nested Krea diffusion paths become this workstation's flat pinned
path, the Krea editor uses the official pinned Qwen3-VL-4B FP8 encoder, and the
archive's nonexistent `OutfitRock (1).jpeg` becomes its actual
`OutfitRock.jpeg`.

The transcript establishes that this is **not an official Krea edit model**. It
combines Krea 2 Turbo, an edit LoRA, `Krea2EditGroundedEncode`,
`Krea2EditModelPatch`, and the Krea2T enhancer. Baseline settings are LoRA 1.0,
10 steps, CFG 1, `er_sde`/`simple`, and one-megapixel images snapped to multiples
of 16. `ref_boost` is the preservation dial: 0 creates a variation, 1–4 is the
useful identity range, and 10 can over-constrain limbs and requested changes.
Use up to 2 MP only after a 1 MP result works; the video measured roughly
16–17 seconds at 1 MP and 46 seconds at 2 MP on its host.

The edit suite covers same-ratio instruction edits, custom portrait/landscape
output, character-plus-background composition, one-reference outfit generation,
and two-reference try-on. For outfit photos, crop away the original wearer's
head/body when possible; the transcript shows two visible people confuse the
LoRA. The exact Krea nodes are pinned to Identity Edit v1.2.5, enhancer commit
`cf88950`, and Pixaroma `c1aaee4`; no Manager update is allowed.

The two H3 workflows use Pixaroma's local Qwen3-VL-8B prompt generator. The
transcript reports that its 4B experiment missed instructions, while 8B was more
reliable; it switches among text, first-frame, and first+last-frame formulas and
scales action count to duration. Enable its `release_model` setting before a
larger downstream workflow. Muse Glimmer 30B remains the preferred prompt author
for quality and reference mode, while these two workflows preserve the video's
self-contained ComfyUI option.

### Curated creative suite

There are three distinct workflow inventories; do not conflate them:

- **58 user workflows:** seven pinned Pixaroma Episode 30 graphs plus 51 curated
  official graphs installed into the workflow browser.
- **506 official templates:** the complete pinned Comfy Template Library remains
  available through **Templates** without duplicating every graph into user state.
- **Models:** only Krea/Edit dependencies are covered by the production downloader.
  Other local graphs are discoverable but remain weightless until their own model
  profile is licensed, pinned, downloaded, and qualified.

The curated 51 are selected from Comfy's official immutable template package,
not community workflow aggregators. They provide:

| Folder | Count | Production capabilities |
|---|---:|---|
| `image` | 11 | Krea 2 BF16/INT8/style; Qwen Image 2512; Qwen Edit 2511/INT8/relight/layers; Flux.2 Klein 9B generation/edit; Z-Image Turbo INT8 |
| `video` | 9 | LTX-2.3 T2V/I2V/FLF/IA2V; HunyuanVideo 1.5 T2V/I2V; Wan 2.2 T2V/I2V/FLF |
| `audio` | 3 | ACE-Step 1.5 music and Stable Audio 3 Medium |
| `3d` | 2 | Hunyuan3D single-view and turbo multiview reconstruction |
| `enhance` | 4 | SeedVR2 image/video restoration, interpolation upscale, and GAN upscale |
| `cloud` | 22 | MiniMax H3; Seedream 5 Pro; Nano Banana 2; Flux; Runway; Veo 3; Wan 2.7; Topaz; ElevenLabs; Seed Audio |

This is deliberately a curated production surface rather than "install every
community JSON." It prioritizes first-party workflows, current model families,
multiple generation/edit/reference modes, audio and 3D coverage, and core/API
nodes that do not require ComfyUI-Manager. Hosted graphs require a Comfy account,
credits, and remote upload. Local non-Krea graphs require separate model storage
and validation; their presence does not claim that their weights are installed.

### Hosted Krea partner nodes

Use these only when hosted Medium/Large is desired and remote upload is
acceptable:

- **Krea2ImageNode**: Medium Turbo, Medium, or Large; prompt, ratio,
  resolution, creativity, seed, optional moodboard UUID.
- **Krea2StyleReferenceNode**: chain up to ten uploaded style images with
  strength from -2 to 2, then connect to `Krea2ImageNode`.

Medium is positioned for expressive illustration; Large for expressive
photorealism. Partner references are uploaded to Comfy API storage. This is
not the private local path.

## 6. Use Muse Glimmer as the prompt author

### Standard and abliterated BF16 variants

The default remains the qualified upstream `meta-models/Muse-Glimmer-30B`.
The stack also supports the requested
[`mlasli/Muse-Glimmer-30B-Abliterated-BF16`](https://huggingface.co/mlasli/Muse-Glimmer-30B-Abliterated-BF16)
at immutable revision `daf5fab76a0351a583714a92d88ebdb6eb48af35`.
Despite the request describing it as a quant, that repository is **full BF16**:
its two model shards total 59,553,433,736 bytes. The three large artifacts are
SHA-256 checked after download. Its model card reports weight-level refusal
suppression at alpha 0.15 but no formal capability benchmark, so it is an
experimental creative variant—not a replacement for the standard baseline.

Download and activate it explicitly:

```bash
MUSE_VARIANT=abliterated bash scripts/inference/muse/download-muse-glimmer-30b.sh
# Wait for DOWNLOAD_COMPLETE, then:
MUSE_VARIANT=abliterated bash scripts/comfyui/activate-creative-stack.sh
```

Both variants use distinct model directories, caches, download containers, and
runtime container names. They share the official BF16 DFlash assistant. DFlash
sampling remains output-exact because the target verifies candidates, but the
modified target may accept fewer draft tokens; benchmark acceptance and speed
before declaring the variant qualified. The repository's Q8/Q6/Q4 GGUF releases
are actual quantizations, but they are not installed because this SGLang DFlash
profile does not provide a qualified Muse GGUF path.

Add **creative → Muse Glimmer → Muse Glimmer Creative Prompt**.

Inputs:

- `task`: `Krea 2 image`, `MiniMax H3 base`, or `MiniMax H3 reference`;
- `brief`: the human creative brief;
- `duration_seconds`: 4–15 for H3 planning;
- `aspect_ratio`;
- `reasoning_strength`: default `xhigh`;
- `max_tokens`: default 4096;
- `reference_manifest`: required for H3 reference mode.

Outputs:

- `prompt`: connect this directly to the generation node's prompt input;
- `reasoning`: optional inspection/debug output; never feed it to generation.

The node:

- calls only `http://127.0.0.1:8001/v1/chat/completions`;
- reads the bearer key from the mode-0600 Muse key file on each request;
- never stores the key in workflow JSON or a UI widget;
- uses Muse's model-card sampling defaults (`temperature=1`, `top_p=.95`,
  `top_k=64`) and maps reasoning through
  `chat_template_kwargs.reasoning_strength`;
- fails closed if the key is missing, permissive, empty, or Muse is down.

### Krea recipe

```text
Muse Glimmer Creative Prompt [task=Krea 2 image]
  prompt → Krea-2 local subgraph “Text String (User Prompt)”
          → sampler → VAE Decode → SaveImage
```

If the template prompt is a widget, right-click it and choose **Convert widget
to input**, then connect Muse's `prompt` output.

### H3 API recipe

```text
creative brief
  → Muse Glimmer Creative Prompt [MiniMax H3 base/reference]
  → optional MinimaxHailuo03ContextIRNode
  → H3 Text / First-Last-Frame / Reference node
  → optional MinimaxHailuo03RegenerateNode (2K)
  → SaveVideo
```

Muse supplies story, shot, and sound judgment. Context IR is the provider's
multimodal rewrite and is useful when the same references can be supplied in
the same order. Do not assume they are equivalent; save both prompts in the
workflow record.

## 7. Best MiniMax H3 API nodes — usable now

Search `MiniMax H3` in the node menu or load the official API templates:

- `api_minimax_h3_t2v`: text-to-video with native stereo audio;
- `api_minimax_h3_flf2v`: required first frame, optional last frame;
- `api_minimax_h3_r2v`: references for identity, style, motion, camera, voice;
- `MinimaxHailuo03ContextIRNode`: hosted multimodal prompt enhancement;
- `MinimaxHailuo03RegenerateNode`: re-render an unmodified 768p H3 output at
  2K with the exact original prompt and references.

The class names retain `Hailuo03`, but their model selector is **MiniMax H3**.
They are the current built-in H3 partner nodes, not old Hailuo 02 nodes.

### Reference constraints

- up to 9 images;
- up to 3 videos, each 2–15 seconds, no more than 15 seconds total;
- videos at approximately 23.976–60 FPS;
- up to 3 audio clips, each 2–15 seconds, no more than 15 seconds total;
- audio references require at least one image or video anchor;
- images at least 256×256 and aspect ratio 0.4–2.5;
- use the same media in the same order for Muse manifest, Context IR,
  generation, and 2K regeneration.

Assign every reference one job:

```text
Image 1: subject identity and face proportions.
Image 2: wardrobe materials and palette only.
Video 1: camera orbit and pacing only.
Audio 1: voice timbre and cadence only.
```

For local H3 syntax after licensing, labels become `<Picture 1>`, `<Video 1>`,
and `<Audio 1>`. The Muse node's manifest is passed through verbatim, so use
labels appropriate to the target node.

### Best hosted production chain

1. Generate Krea 2 concept frames locally.
2. Choose and manually review the exact references.
3. Ask Muse for four micro-film concepts; select one yourself.
4. Ask Muse to compile the selected concept as H3 reference mode.
5. Run Context IR with the same media order.
6. Generate a 5-second preview.
7. Check identity, motion, dialogue timing, audio sync, and disclosure needs.
8. Generate the final 4–15-second 768p source.
9. Pass the **unmodified** source, exact prompt, and same references to
   Regenerate for 2K.
10. Archive prompts, references, seed, node versions, cost, and output paths.

## 8. Local H3 nodes — ready only after authorization

ComfyUI core already includes:

- `EmptyMiniMaxH3LatentAV`;
- `MiniMaxH3ImageToVideo` for T2V/I2V/first-last-frame;
- `MiniMaxH3ReferenceToVideo` for image/video/audio references;
- `MiniMaxH3AddGuide` for image, clip, or audio anchors at arbitrary frames;
- `MiniMaxH3SigmaShift` with baseline video shift 12 and audio shift 3;
- core model/CLIP/VAE loaders, sampler, `CreateVideo`, and `SaveVideo`.

With separate authorization in force, install the pinned maximum-quality BF16 profile:

```bash
MINIMAX_H3_ACCEPT_LICENSE=yes MINIMAX_H3_AUTHORIZED=yes \
  bash scripts/comfyui/download-minimax-h3-models.sh
```

The manifest downloads both original unpruned BF16 task families, the shared
Qwen3-VL-32B BF16 encoder, video/audio VAEs, and all three optional Turbo LoRAs:
eight artifacts, 195,748,912,288 bytes total. The maximum-quality baseline does
not apply a Turbo LoRA and retains the original 50-step schedule. Start from the
official Comfy templates:

- `video_minimax_h3_t2v`;
- `video_minimax_h3_i2v`;
- `video_minimax_h3_r2v`.

The practical single-GPU Comfy profile uses pruned INT8 ConvRot diffusion,
NVFP4-AWQ Qwen3-VL-32B, FP16 video VAE, and FP32 audio VAE. It occupies roughly
42.5 GB of weight files before optional LoRAs and leaves useful activation
headroom on one 96 GB card. This is the official practical Comfy profile, not
the maximum-fidelity original BF16 baseline.

For maximum fidelity, preserve the separate runbook's original BF16/50-step
TP2 qualification path. Full H3 BF16 diffusion is 66.3 GB per task family and
the BF16 text encoder is 51.5 GB; ComfyUI is not a drop-in tensor-parallel
replacement for the vLLM-Omni/SGLang TP2 recipes.

## 9. Custom-node policy

| Node pack | Assessment |
|---|---|
| Krea 2 Identity Edit | **Installed**, Apache-2.0, pinned v1.2.5 source; required for dual image/latent edit conditioning |
| ComfyUI-Krea2T-Enhancer | **Installed**, MIT, pinned to the workflow's exact commit |
| Pixaroma | **Installed**, pinned to Episode 30 commit; broad route/node surface accepted only because all seven requested workflows depend on it and the service is confined to loopback |
| ComfyUI-Manager | Mutable git/pip state outside Nix; intentionally absent |
| VideoHelperSuite | Established, but core `VIDEO`, `LoadVideo`, `CreateVideo`, and `SaveVideo` cover this stack |
| KJNodes | Useful only if later qualifying Sage Attention or specialty video operations; broad dependency surface |
| rgthree-comfy | Good UI ergonomics, no generation capability required here |
| IF AI Tools | Archived and dependency-heavy; the in-repo Muse node is narrower and uses the existing endpoint |
| New H3 “director/turbo/cache” nodes | Too new and overlapping with native H3; no baseline evidence yet |

After a clean native baseline, KJNodes plus Sage Attention is the first optional
performance experiment worth considering. Comfy's H3 guide reports roughly 2×
speed potential with minimal quality loss, but it requires a wheel matched to
Torch/CUDA and introduces fallback paths for non-BF16/FP16 layers. Package and
benchmark it separately; do not silently fold it into the reference profile.

## 10. Security and privacy

- Port 8188 is loopback-only. Use SSH forwarding; never add a firewall rule.
- Muse's key stays in a mode-0600 file and is read at execution time.
- Local Muse + local Krea prompts/references stay on the workstation.
- Partner nodes upload prompts and media to Comfy/provider infrastructure.
  Treat faces, voices, customer assets, unreleased products, and location data
  as external disclosure.
- Comfy's proxy path does not establish Krea API Zero Data Retention. If ZDR is
  mandatory, design a direct Krea API adapter and verify the workspace policy
  instead of assuming partner-node behavior.
- Keep prepaid partner credits low; inspect usage after every production batch.
- Manually review Krea outputs before publication to satisfy the initial private
  deployment's content-filter control.
- Add AI disclosure/provenance where law or platform policy requires it.

## 11. Validation gate

Do not call the stack qualified until:

- [ ] Nix evaluation and build pass from the pinned flake.
- [ ] `comfyui.service` stays inactive after reboot, then explicit creative-profile
      activation starts it on loopback only.
- [ ] Comfy logs load Muse plus all three pinned Episode 30 packs with no failed imports.
- [ ] Seven Episode 30 workflows, 51 curated workflows, and six sample inputs are present.
- [ ] Every curated workflow parses and every required node type is registered.
- [ ] Muse and Comfy are isolated to physical GPU0/GPU1 respectively.
- [ ] `Krea 2 + Edit Lora` completes at 1 MP with fixed seed and `ref_boost=4`.
- [ ] Custom-ratio, character/background, and both outfit workflows complete.
- [ ] Both Episode 30 local H3 prompt workflows produce their expected schema.
- [ ] Standard Muse→Krea BF16 1K and 2K images complete.
- [ ] Abliterated Muse starts from its pinned marker, completes the same fixed
      prompt corpus, and records quality, refusal behavior, throughput, and
      effective DFlash acceptance versus standard.
- [ ] A local Krea style-reference generation completes with the dedicated
      INT8/FP8/style-reference files.
- [ ] Fixed seed/prompt Krea reruns are compared for determinism.
- [ ] H3 API T2V, first/last-frame, and reference workflows each complete.
- [ ] Context IR output preserves the same reference ordering.
- [ ] H3 2K regeneration accepts the unmodified 768p source.
- [ ] No Xid, OOM, service restart, or unexpected GPU owner occurs.
- [ ] Partner usage/cost and remote-data handling are recorded.
- [ ] The separate H3 authorization is archived and the eight-artifact marker
      matches the pinned repository revision.

Commands:

```bash
bash tests/comfyui-creative-stack-contract.sh
./tests/test_muse_glimmer_prompt.py
nix eval .#nixosConfigurations.desktop.config.systemd.services.comfyui.serviceConfig.ExecStart
nix build .#nixosConfigurations.desktop.config.system.build.toplevel --dry-run

journalctl -k -b | grep -Ei 'NVRM|Xid|fallen off|AER'
journalctl -u comfyui -b --no-pager
docker inspect muse-glimmer-30b-bf16-dflash \
  --format 'status={{.State.Status}} restarts={{.RestartCount}} oom={{.State.OOMKilled}}'
```

## 12. Stop or switch away

Stop only the creative components:

```bash
sudo systemctl stop comfyui

docker stop -t 30 muse-glimmer-30b-bf16-dflash
```

Restore the desired inference backend explicitly, for example:

```bash
DFLASH2_NATIVE_IMAGE=sha256:af311253309cebbd021d4f7cc4da695d30434182e89407818200754f0d788880 \
  bash scripts/inference/qwen38/switch-qwen38-backend-v2.sh dflash2-native
```

The Comfy state, Krea models, inputs, outputs, and workflows remain on disk.

## Sources

Sources accessed 2026-08-21:

- [Pixaroma Episode 30 video and transcript](https://www.youtube.com/watch?v=rGVf3m19yM8)
- [Pixaroma workflow index](https://workflows.pixaroma.com/)
- [Muse Glimmer 30B Abliterated BF16](https://huggingface.co/mlasli/Muse-Glimmer-30B-Abliterated-BF16)
- [Krea 2 Identity Edit nodes](https://github.com/lbouaraba/comfyui-krea2edit)
- [Krea 2 Identity Edit weights](https://huggingface.co/conradlocke/krea2-identity-edit)
- [Krea2T Enhancer](https://github.com/capitan01R/ComfyUI-Krea2T-Enhancer)
- [Pixaroma nodes](https://github.com/pixaroma/ComfyUI-Pixaroma)
- [Outfit Transfer LoRA](https://huggingface.co/AliveAi/Krea-2-Edit-Outfit-Transfer)
- [ComfyUI MiniMax H3 local workflows](https://docs.comfy.org/tutorials/video/minimax/minimax-h3)
- [ComfyUI MiniMax H3 API workflows](https://docs.comfy.org/tutorials/partner-nodes/minimax/minimax-h3)
- [ComfyUI Krea 2 local workflows](https://docs.comfy.org/tutorials/image/krea/krea-2)
- [ComfyUI Krea 2 partner nodes](https://docs.comfy.org/tutorials/partner-nodes/krea2/krea2-t2i)
- [ComfyUI partner-node security/account model](https://docs.comfy.org/tutorials/partner-nodes/overview)
- [ComfyUI 0.31.1 source](https://github.com/Comfy-Org/ComfyUI/tree/v0.31.1)
- [ComfyUI workflow templates](https://github.com/Comfy-Org/workflow_templates)
- [Krea 2 official repository](https://github.com/krea-ai/krea-2)
- [Krea 2 prompting guide](https://github.com/krea-ai/krea-2/blob/main/docs/prompting.md)
- [Krea 2 LLM expansion prompt](https://github.com/krea-ai/krea-2/blob/main/docs/expansion.txt)
- [Krea 2 Community License](https://www.krea.ai/krea-2-licensing)
- [Comfy-Org Krea 2 artifacts](https://huggingface.co/Comfy-Org/Krea-2)
- [MiniMax H3 model card](https://huggingface.co/MiniMaxAI/MiniMax-H3)
- [MiniMax H3 license](https://huggingface.co/MiniMaxAI/MiniMax-H3/blob/main/LICENSE)
- [MiniMax H3 license Q&A](https://huggingface.co/MiniMaxAI/MiniMax-H3/blob/main/docs/QA-about-License.md)
- [MiniMax H3 prompt-writing skill](https://github.com/MiniMax-AI/MiniMax-H3/tree/d21241f0a4b3acbb34c97dae47fa417b7065e438/skills/h3-prompt-writing)
- [Krea API Zero Data Retention](https://www.krea.ai/docs/developers/zdr)

For full-fidelity H3 architecture, memory, and licensing analysis, also read
`docs/runbooks/local-ai-video-script-runbook.md`.
