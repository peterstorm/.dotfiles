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
- `hf` plus `hf-xet` for pinned model downloads, including H3 artifacts too
  large for regular Hub HTTPS;
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
# The command returns only after checksum verification and DOWNLOAD_COMPLETE.
MUSE_VARIANT=abliterated bash scripts/comfyui/activate-creative-stack.sh
```

For an explicitly asynchronous transfer, add `MUSE_DOWNLOAD_DETACH=yes`; that
mode reports `DOWNLOAD_STARTED`, never completion, and requires following the
container logs until its marker is written.

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

- defaults to the Nix-configured loopback endpoint
  `http://127.0.0.1:8001/v1/chat/completions`; an operator can deliberately
  override the base with `MUSE_GLIMMER_BASE_URL`;
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
eight artifacts, 195,748,912,288 bytes total. H3 uses Nix-managed `hf-xet` for
the three oversized BF16 artifacts and preserves its local staging metadata
across retries, so interrupted transfers resume instead of restarting. The
maximum-quality baseline does not apply a Turbo LoRA and retains the original
50-step schedule. Start from the official Comfy templates:

- `video_minimax_h3_t2v`;
- `video_minimax_h3_i2v`;
- `video_minimax_h3_r2v`.

The practical single-GPU Comfy profile uses pruned INT8 ConvRot diffusion,
NVFP4-AWQ Qwen3-VL-32B, FP16 video VAE, and FP32 audio VAE. It occupies roughly
42.5 GB of weight files before optional LoRAs and leaves useful activation
headroom on one 96 GB card. This is the official practical Comfy profile, not
the maximum-fidelity original BF16 baseline.

### How the full BF16 profile is intended to run on one 96 GB GPU

#### The short version

**You do not manually unload the encoder, DiT, and VAEs between nodes in one
queued H3 job.** Queue one correctly constructed graph. ComfyUI requests each
component when that phase executes and its model manager evicts or partially
offloads the previous component to make room.

The operator has only three memory-management responsibilities:

1. before an H3 job, clear any **previous Krea or other H3 job** from ComfyUI;
2. build the graph with **exactly one H3 diffusion family**—FL2VA or REF2VA,
   never both;
3. between FL2VA and REF2VA jobs, clear ComfyUI again, or restart the service for
   a guaranteed clean GPU1 and process cache.

Do **not** split prompt encoding, diffusion, and decode into separate queue
submissions. Conditioning and the packed audio/video latent are in-memory graph
values. The phase hand-off belongs inside one ComfyUI execution.

#### Three different meanings of “loaded”

**Disk inventory is not simultaneous VRAM residency.** Confusion usually comes
from treating disk, host RAM, and VRAM as one pool:

| Location/state | Meaning | What the operator does |
|---|---|---|
| On disk under `/models/comfyui` | The file is available to a loader selector. It consumes no RAM or VRAM. | Both DiT families may remain on disk permanently. |
| Materialized/offloaded in host RAM | ComfyUI has created a model object or moved weights off GPU1. This still consumes the workstation's 91 GiB RAM. | Let the RAM-pressure cache evict unused outputs; use `/free` or restart between model families. |
| Resident or partially resident in GPU1 VRAM | The component is available for the current compute phase. In normal-VRAM mode ComfyUI may keep only part of a model resident. | Do not force residency or add third-party unload nodes. Watch the measured peak. |

A loader node appearing earlier in the graph does **not** mean every selected
file is simultaneously resident in VRAM. Loader nodes produce ComfyUI model
objects. Prompt encoding, sampling, and VAE encode/decode then ask the model
manager to make their particular model resident. Conversely, “unloaded from
VRAM” does not necessarily mean “deleted from RAM”; it can mean moved to CPU,
partially offloaded, or retained in the execution cache.

The complete 195.75 GB download therefore does not need to fit in VRAM or RAM at
once. Host RAM is still a real constraint during hand-offs, so the raw weight
arithmetic below is a **qualification hypothesis, not proof that the full BF16
workflow fits**.

#### Pick exactly one task family per saved workflow

Create separate saved copies of the official templates instead of one graph with
both DiTs and a switch:

| Saved workflow | Start from | Diffusion selector | Purpose |
|---|---|---|---|
| `MiniMax H3 BF16 — T2V` | `video_minimax_h3_t2v` | `minimax_h3_fl2va_bf16.safetensors` | Text-to-video/audio |
| `MiniMax H3 BF16 — I2V` | `video_minimax_h3_i2v` | `minimax_h3_fl2va_bf16.safetensors` | First frame, last frame, or both |
| `MiniMax H3 BF16 — R2V` | `video_minimax_h3_r2v` | `minimax_h3_ref2va_bf16.safetensors` | Image/video/audio references |

In the official T2V/I2V templates, the four model selectors are exposed on the
large MiniMax H3 subgraph node. The R2V template shows individual `UNETLoader`,
`CLIPLoader`, and `VAELoader` nodes. Save a copy before changing selectors.

All three use:

- text encoder: `qwen3vl_32b_minimax_h3_bf16.safetensors`;
- video VAE: `minimax_h3_video_vae_fp16.safetensors`;
- audio VAE: `minimax_h3_audio_vae_fp32.safetensors`;
- `UNETLoader` weight dtype: `default`—the file itself is BF16;
- `CLIPLoader` type: `minimax`, device: `default`;
- batch size 1;
- no Turbo LoRA for the maximum-quality 50-step baseline.

Delete, disconnect, or mute unrelated output branches before queueing. ComfyUI
executes every active output branch needed by the prompt; merely moving an
unused Krea or second H3 branch to the side does not make it inert.

#### What happens automatically inside one queued job

The exact phase order differs slightly by task because the native H3
conditioning nodes perform their own preprocessing.

**T2V / FL2VA without keyframes**

1. The loaders expose the BF16 Qwen encoder, FL2VA DiT, and two VAEs as model
   objects.
2. `MiniMaxH3ImageToVideo` asks Qwen3-VL-32B to encode the prompt.
3. `SamplerCustomAdvanced` requests the FL2VA DiT. Before loading it, ComfyUI's
   `load_models_gpu()` calls its memory-release path and can evict or partially
   offload Qwen from GPU1.
4. The sampler produces one packed latent containing video and audio streams.
5. `VAEDecode` requests the video VAE; `VAEDecodeAudio` requests the audio VAE.
   Each request can evict the DiT or the other VAE as necessary.
6. `CreateVideo` muxes decoded frames and audio; `SaveVideo` writes the result.

**I2V / FL2VA with first or last frames**

1. `MiniMaxH3ImageToVideo` first encodes the prompt with Qwen.
2. It then requests the video VAE to encode the supplied keyframe or keyframes.
   This is already a Qwen → VAE phase transition before sampling.
3. The sampler requests only the FL2VA DiT and produces the packed latent.
4. Video and audio decode proceed through their respective VAEs.

**R2V / REF2VA**

1. `MiniMaxH3ReferenceToVideo` requests the video and/or audio VAEs to encode the
   supplied references.
2. It then requests Qwen to encode the prompt plus reference presentation.
3. The sampler requests only the REF2VA DiT. Reference latents remain graph data
   and are supplied at each sampling step; the FL2VA DiT is not involved.
4. Video and audio VAEs decode the packed result, then `CreateVideo` muxes it.

These are automatic transitions. Do not press `/free`, restart ComfyUI, or stop
the service while a prompt is running; doing so invalidates the in-memory job.

#### Why the arithmetic is plausible—but not yet a qualification result

Physical GPU1 reports 97,887 MiB = 95.59 GiB. The service starts with
`--reserve-vram 8`, so ComfyUI targets roughly 87.59 GiB for managed weights and
workspace:

| Compute phase | Principal resident weights | File size | Raw margin inside the 87.59 GiB budget |
|---|---|---:|---:|
| Prompt encoding | Qwen3-VL-32B BF16 | 47.97 GiB | 39.62 GiB |
| Diffusion | one BF16 DiT | 61.73 GiB | 25.86 GiB |
| Diffusion with optional Turbo | one DiT + one LoRA | 63.55 GiB | 24.04 GiB |
| Decode | video + audio VAEs | 5.41 GiB | 82.18 GiB |

The margin must also cover conditioning, packed video/audio latents, reference
latents, attention workspace, temporary copies, decoded frames, and allocator
fragmentation. REF2VA with `ref_image_size=max`, several videos, or long audio
can consume much more than the weight-only table suggests. During a GPU phase,
offloaded weights and cached node outputs also consume host RAM.

ComfyUI 0.31.1 runs its RAM-pressure cache by default. On this 91 GiB host it
tries to retain roughly 9 GiB of free RAM and evicts cached node outputs as
pressure rises. Its model manager also supports partial GPU residency. Those are
safety mechanisms, not a guarantee: the full BF16 profile remains unqualified
until both FL2VA and REF2VA complete while measured VRAM and RAM stay healthy.

#### Exact operator workflow for the first BF16 qualification

1. Activate the creative profile normally. This stops the normal TP2 Qwen
   backend, leaves Muse on physical GPU0, and gives physical GPU1 to ComfyUI:

   ```bash
   cd ~/.dotfiles
   bash scripts/comfyui/activate-creative-stack.sh
   ```

2. Confirm the queue is empty **before** clearing memory:

   ```bash
   curl -fsS http://127.0.0.1:8188/queue |
     jq -e '(.queue_running | length) == 0 and (.queue_pending | length) == 0'
   ```

3. Clear models and execution cache left by Krea or an earlier H3 family:

   ```bash
   curl -fsS \
     -H 'Content-Type: application/json' \
     --data '{"unload_models":true,"free_memory":true}' \
     http://127.0.0.1:8188/free >/dev/null
   sleep 2
   ```

   `unload_models` releases registered GPU models. `free_memory` also resets the
   execution cache and triggers garbage collection. The endpoint asks the
   ComfyUI worker to perform the cleanup; call it only with an idle queue.

4. Verify the clean baseline:

   ```bash
   nvidia-smi --id=1 \
     --query-gpu=index,memory.used,memory.free \
     --format=csv,noheader,nounits
   free -h
   curl -fsS http://127.0.0.1:8188/system_stats | jq '{
     ram_free_gib: (.system.ram_free / 1073741824),
     gpu: [.devices[] | {
       name,
       vram_free_gib: (.vram_free / 1073741824),
       torch_vram_free_gib: (.torch_vram_free / 1073741824)
     }]
   }'
   ```

   `nvidia-smi --id=1` means physical GPU1. Because the service sets
   `CUDA_VISIBLE_DEVICES=1`, ComfyUI logs call that same card `cuda:0`; this is
   renumbering inside the process, not use of physical GPU0.

5. Open only `MiniMax H3 BF16 — T2V`. Start with:

   - 1344×768 or 768×1344;
   - approximately 5 seconds / 124 frames;
   - batch size 1;
   - 50 steps;
   - no Turbo LoRA;
   - fixed seed;
   - one queued prompt, no parallel Krea job.

6. In another terminal, record both GPU1 and host memory while the graph runs:

   ```bash
   watch -n 1 'nvidia-smi --id=1 \
     --query-gpu=timestamp,memory.used,memory.free,utilization.gpu \
     --format=csv,noheader,nounits; free -h | sed -n "1,2p"'
   ```

   Follow model transitions separately:

   ```bash
   journalctl -fu comfyui | grep --line-buffered -E \
     'Requested to load|loaded completely|loaded partially|Unloading|OOM|out of memory'
   ```

7. After T2V succeeds, save the output and peak measurements. Clear memory again
   with `/free`, then qualify I2V with one keyframe.

8. Before R2V, use `/free` again—or use the stronger clean-slate operation:

   ```bash
   sudo systemctl restart comfyui.service
   ```

   Restarting ComfyUI releases all process-owned GPU1 VRAM and host RAM. It does
   not stop Muse on GPU0. Wait for `http://127.0.0.1:8188/system_stats` before
   queueing `MiniMax H3 BF16 — R2V`.

9. Qualify R2V conservatively: one image, `ref_image_size=match`, 124 frames,
   batch 1, no Turbo. Add references, use `max`, or increase duration only after
   the baseline succeeds.

Repeated jobs using the **same** family may keep the cache for faster reloads if
RAM remains healthy. Always clear between Krea and H3, between FL2VA and REF2VA,
after an OOM, or whenever selector changes make residency uncertain.

#### What not to do

- Do not connect FL2VA and REF2VA loaders to one active output graph.
- Do not queue T2V/I2V and R2V simultaneously.
- Do not queue Krea and H3 simultaneously on GPU1.
- Do not set the 48 GiB Qwen `CLIPLoader` to `cpu` as a first workaround; that
  moves compute and pressure to the 91 GiB host rather than solving residency.
- Do not add mutable “model unload” custom nodes. Native model management and the
  loopback `/free` endpoint are the supported controls.
- Do not call `/free` between nodes of a running graph.
- Do not interpret a low post-phase `nvidia-smi` value as proof that RAM is free;
  inspect both `/system_stats` and `free -h`.
- Do not call the profile qualified from file-size arithmetic alone.

#### Failure and recovery decision tree

| Symptom | Meaning | Recovery |
|---|---|---|
| GPU OOM during Qwen | Prompt/reference tokens or transient workspace exceeded the phase margin. | Restart ComfyUI; retry T2V with no references, 124 frames, batch 1. |
| GPU OOM during sampling | DiT plus latent/attention workspace exceeded GPU1. | Restart; keep 768 short edge, reduce duration/references; do not add Turbo. |
| GPU OOM during decode | Decoded-frame or VAE workspace peak exceeded the remaining memory. | Restart; reduce duration first, then resolution; use tiled decode only after validating H3 compatibility. |
| Host RAM approaches zero or swap thrashes | Offloaded weights plus cached graph values exceed practical host memory. | Restart; use one output branch and fewer references. If it recurs, use the practical quantized profile. |
| FL2VA works but REF2VA fails | Reference latents/tokens make REF2VA materially heavier. | Use `match`, one short reference, and 124 frames; otherwise use the practical profile or a future TP2 profile. |
| Memory remains allocated after `/free` | Worker cleanup has not run yet, or a graph/cache still owns references. | Confirm queue idle; wait; if still retained, restart `comfyui.service`. |

The official practical artifacts are the known lower-memory fallback, but the
maximum-BF16 downloader does **not** install them. They require their own pinned,
checksum-verified profile before these selectors can be used:

- `minimax_h3_fl2va_pruned_int8_convrot.safetensors` or
  `minimax_h3_ref2va_pruned_int8_convrot.safetensors`;
- `qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors`;
- the same video/audio VAEs.

That practical profile is not the requested maximum-fidelity baseline, but it is
preferable to an unstable BF16 run. A future full-BF16 TP2 profile could provide
more aggregate VRAM, but it would own both GPUs: Muse and ComfyUI GPU generation
would have to stop. It is not part of the current single-GPU ComfyUI profile.

| Concurrent work | Current status |
|---|---|
| Muse on GPU0 + Krea on GPU1 | Supported |
| Muse on GPU0 + one full BF16 H3 family on GPU1 | Candidate topology; must pass the qualification above |
| Krea + H3 generating on GPU1 | Unsupported; serialize and clear between them |
| FL2VA + REF2VA in one active graph | Unsupported and unnecessary |
| Full BF16 H3 TP2 over both GPUs | Separate future profile; Muse and ComfyUI generation must stop |

## 9. Make a character-driven short film, one scene at a time

### Are all the starting workflows present?

**The workflow definitions needed for this production loop are declaratively
present, but that does not by itself mean every local generation path is ready
to run.** There are four separate readiness gates:

1. **Definition present:** the JSON or native node exists in the pinned Nix
   closure.
2. **Installed generation active:** that closure has been switched and ComfyUI
   has started once to install the user workflows.
3. **Weights ready:** the checksum marker and artifacts are in `/models`, not
   merely in the user-owned download staging tree.
4. **Runtime qualified:** the exact graph has completed on this hardware with
   acceptable RAM, VRAM, quality, and stability.

The starting surface is:

| Production job | Open this | Where it appears | Additional readiness requirement |
|---|---|---|---|
| Canonical character image | `image_krea2_turbo_t2i` | User workflows → `creative-suite/image`, and Templates → Image | Krea production marker in `/models/comfyui` |
| Style-led character image | `image_krea2_turbo_int8_image_style_reference` | User workflows → `creative-suite/image`, and Templates → Image | Krea INT8/FP8/style artifacts |
| Identity-preserving views and expressions | `Krea 2 + Edit Lora` or `Krea 2 + Edit Lora - Custom Ratio` | User workflows → `pixaroma-ep30` | Krea Identity Edit weights and pinned edit nodes |
| Character in a designed location | `Krea 2 + Edit Lora - Character and Background` | User workflows → `pixaroma-ep30` | Character and background reference images |
| Wardrobe variants | `Krea 2 + One Image Outfit Lora` or `Krea 2 + Outfit Transfer 2` | User workflows → `pixaroma-ep30` | Outfit-transfer weights and clean clothing references |
| Story, screenplay, and scene cards | Muse Glimmer in Pi | Select `desktop-muse/muse-glimmer-30b` | Muse target and DFlash draft markers; Muse endpoint healthy |
| Per-scene H3 prompt compilation | `Muse Glimmer Creative Prompt` | Add node → creative → Muse Glimmer | Muse endpoint healthy; accepted scene card already written |
| Text-only local H3 scene | `video_minimax_h3_t2v` | Templates → Video | Local H3 marker; save a BF16 FL2VA copy as described above |
| First/last-frame local H3 scene | `video_minimax_h3_i2v` | Templates → Video | Local H3 marker; save a BF16 FL2VA copy |
| Character/reference-led local H3 scene | `video_minimax_h3_r2v` | Templates → Video | Local H3 marker; save a BF16 REF2VA copy |
| Hosted H3 scene | `api_minimax_h3_t2v`, `api_minimax_h3_flf2v`, or `api_minimax_h3_r2v` | User workflows → `creative-suite/cloud` | Comfy account, credits, and acceptance of remote upload |

The complete pinned Template Library also remains available through the
**Templates** button. The three local H3 templates are not duplicated into the
51-workflow user-curated folder; search the official Template Library for
`MiniMax H3`, then save the BF16 copies under the names from Section 8.

After switching the NixOS generation and starting ComfyUI once, verify the user
workflow inventory:

```bash
test "$(find /var/lib/comfyui/user/default/workflows/pixaroma-ep30 \
  -type f -name '*.json' | wc -l)" -eq 7
test "$(find /var/lib/comfyui/user/default/workflows/creative-suite \
  -type f -name '*.json' | wc -l)" -eq 51
```

Verify local model publication separately:

```bash
test -f /models/comfyui/.krea2-production-complete
test -f /models/comfyui/.minimax-h3-bf16-complete
test -f /models/Muse-Glimmer-30B-Abliterated-BF16/.download-complete
test -f /models/Muse-Glimmer-30B-assistant/.download-complete
```

A marker under `~/.local/state/creative-model-staging/` means the download is
staged; it does **not** satisfy these runtime checks until the artifacts are
promoted into `/models`. Likewise, a present H3 workflow is not a claim that the
full BF16 profile has passed the qualification in Section 8.

### The recommended production shape

Do not ask one generation to invent a character, tell a complete story, preserve
continuity, perform several camera setups, and deliver a finished film. Treat the
project as a sequence of approved artifacts:

```text
story brief
  → character and visual bibles
  → separate canonical character reference images
  → screenplay
  → one scene card per clip
  → Krea storyboard/keyframe for that scene
  → one H3 clip
  → accept or regenerate that clip
  → continuity handoff to the next scene
  → edit accepted clips together
```

The unit of progress is an **accepted scene**, not a long prompt. For initial
qualification, make each H3 scene one coherent shot or beat of approximately
five seconds. A later edit can join those clips into a sequence. This gives you a
stable point at which to reject drift before it contaminates every later scene.

### Step 1 — create a small project bible

Create a mutable project directory outside the Nix store. For example:

```text
~/creative-projects/clockwork-city/
├── project.md
├── characters/
│   └── mara/
│       ├── character-bible.md
│       └── references/
│           ├── mara-face-front.png
│           ├── mara-face-three-quarter.png
│           ├── mara-profile.png
│           ├── mara-full-front.png
│           ├── mara-full-back.png
│           └── mara-expression-determined.png
├── locations/
│   ├── rooftop-dusk.md
│   └── references/
├── scenes/
│   ├── 010-rooftop-arrival/
│   │   ├── scene.md
│   │   ├── first-frame.png
│   │   ├── generation-record.md
│   │   └── accepted.mp4
│   └── 020-clocktower-entry/
└── edit/
    ├── concat.txt
    └── final.mp4
```

`project.md` should fix the facts that must not drift:

- logline, genre, audience, emotional arc, and target duration;
- aspect ratio, frame rate, color language, lens language, and rendering style;
- character names and relationships;
- locations and time-of-day progression;
- prohibited changes—for example no wardrobe changes, no age drift, no extra
  jewelry, no animated/cartoon rendering;
- dialogue spelling and pronunciation;
- continuity facts that survive scene boundaries.

The project bible is human-reviewed source material. Do not let a later model
silently rewrite it because a generated frame happened to look interesting.

### Step 2 — build an operational character sheet with Krea

For generation, a useful “character sheet” is primarily a **folder of separate,
high-resolution reference images**, optionally accompanied by a contact sheet
for human review. H3 gets stronger evidence from separate face, profile, and
full-body references than from one crowded grid containing many tiny views.

#### 2.1 Write the immutable character anchors

In `character-bible.md`, separate invariants from variables:

```text
Invariant identity:
- Mara Venn, 32, angular oval face, high cheekbones, narrow hazel eyes.
- Short asymmetrical black bob; one silver streak over the right temple.
- Small healed diagonal scar through the left eyebrow.
- Lean 170 cm silhouette; deliberate upright posture.

Canonical wardrobe:
- Charcoal wool flight coat ending above the knee.
- Oxidized brass clasps; dark teal lining; no logos.
- Black boots, thin burgundy gloves, brass mechanical wristwatch.

Style anchors:
- Live-action practical photography, restrained teal/amber grade.
- Fine 35 mm grain, soft halation, realistic skin texture.

Allowed variables:
- Pose, facial expression, camera angle, and dirt/wetness required by a scene.

Forbidden drift:
- No hair-length change, no missing scar, no blue eyes, no costume redesign,
  no extra people in a single-character reference.
```

Use concrete geometry, materials, colors, and asymmetrical details. Avoid vague
labels such as “beautiful cyberpunk woman”; they do not provide enough identity
constraints to detect drift.

#### 2.2 Generate and approve one canonical anchor

Open `image_krea2_turbo_t2i` and generate a neutral, well-lit, single-character
image before attempting action poses. Start at 1K. Ask for a full body or
three-quarter body, visible face, simple neutral background, realistic lens, and
no props obscuring the silhouette.

Generate a small candidate set, then choose **one** canonical anchor manually.
Record its exact prompt, seed, model selectors, dimensions, and output filename.
Do not average several almost-matching faces into the identity definition.

#### 2.3 Derive one clean view at a time

Open `Krea 2 + Edit Lora` or its custom-ratio variant. Feed the canonical anchor
and request one controlled change per output:

1. face front, neutral expression;
2. face three-quarter, neutral expression;
3. clean left or right profile;
4. full body front;
5. full body back;
6. one story-relevant expression;
7. optional hands, signature prop, or wardrobe-material detail.

Keep identity language and wardrobe language identical across prompts. Change
only the requested view or expression. Begin with `ref_boost=4`; lower it if the
edit refuses a necessary pose and raise it cautiously if identity drifts.

Reject any candidate that changes face geometry, eye color, scar side, hair
parting, age, body silhouette, or canonical materials. A polished inconsistent
image is not a useful reference.

#### 2.4 Add style, wardrobe, and location references separately

- Use the official Krea style-reference workflow for palette, texture, lighting,
  and rendering language—not as the sole identity reference.
- Use `One Image Outfit` or `Outfit Transfer 2` only when the story requires a
  wardrobe variant. Crop away the source model's face/body when possible.
- Use `Character and Background` to create a scene keyframe containing the
  approved character and an approved location.
- Keep identity, wardrobe, style, location, and prop images as separate files so
  each can be assigned one explicit job in an H3 R2V manifest.

Create a contact sheet for yourself if useful, but pass the original individual
images to H3. Mark only approved images as canonical; move rejected experiments
out of the reference directory.

### Step 3 — write the story and scene cards with Muse

Use Muse in two distinct roles:

1. **Free-form writer/director in Pi:** select
   `desktop-muse/muse-glimmer-30b` to develop the story, screenplay, and scene
   breakdown interactively.
2. **Per-scene prompt compiler in ComfyUI:** use `Muse Glimmer Creative Prompt`
   only after a scene card is approved, with task `MiniMax H3 base` or
   `MiniMax H3 reference`.

The ComfyUI node is deliberately task-shaped; it is not the best interface for
an open-ended writers' room. Start the Pi conversation by pasting the approved
project and character bibles, then use a request like:

```text
Act as a screenwriter and visual director. The project and character bibles
below are binding continuity constraints; do not silently alter them.

Write a 35–45 second short film as 7–9 separately generatable scene cards.
Each card must be one coherent visual beat lasting about 4–6 seconds. Across the
cards, create a clear setup, escalation, turn, climax, and final image.

For each scene output:
- scene ID and dramatic purpose;
- exact duration;
- continuity entering the scene;
- opening frame composition;
- one primary subject action;
- camera position and one camera movement;
- environment movement;
- exact dialogue, sound effects, ambience, and music cue;
- closing frame composition;
- continuity passed to the next scene;
- required character/location/prop references;
- recommended H3 mode: T2V, I2V/FL2VA, or R2V/REF2VA;
- objective acceptance checks.

Keep each card independently generatable. Do not hide several locations or major
time jumps inside one card. Return the screenplay first, then the numbered scene
cards. Do not write final H3 prompts until I approve the cards.

[PASTE PROJECT BIBLE]
[PASTE CHARACTER BIBLE]
```

Review the screenplay yourself. Check motivation, pacing, continuity, feasible
shot count, and whether every dialogue line can fit its clip. Ask Muse to revise
specific cards rather than regenerating the entire story after every note.

Save each accepted card in `scenes/<id>-<slug>/scene.md`. A useful card looks
like:

```text
Scene: 020-clocktower-entry
Purpose: Mara chooses to enter despite hearing the mechanism wake.
Duration: 5 seconds / 124 frames
Mode: R2V / REF2VA
Continuity in: coat and hair wet; brass watch in left hand; dusk exterior.
Opening frame: medium rear three-quarter at the clocktower threshold.
Action: she raises the watch; inner gears answer and the door opens once.
Camera: 40 mm, slow shoulder-height push of less than one meter.
Audio: rain on stone, watch ticking, one deep gear engagement, no dialogue.
Closing frame: Mara in silhouette against warm machinery inside the doorway.
Continuity out: door open; warm light on right side of coat; watch still raised.
References: Picture 1 Mara full body; Picture 2 coat material; Picture 3 doorway.
Acceptance: face and hair match; scar side correct if visible; one door only;
no wardrobe change; watch remains in left hand; no text or watermark.
```

### Step 4 — make a storyboard or first frame for each scene

Before spending H3 sampling time, establish composition cheaply with Krea:

- use Krea T2I for location-only establishing frames;
- use `Character and Background` for a canonical character in the scene;
- use Identity Edit for a new pose while preserving the accepted face/outfit;
- use style reference to carry the project's visual language.

Save the accepted frame as `first-frame.png` in that scene directory. Record the
Krea prompt and seed. The frame is a composition contract, not merely
inspiration: compare the generated H3 opening against it.

A useful production order is to finish the script and character references,
then make **all scene keyframes with Krea in one pass**. After they are approved,
clear Krea from ComfyUI and render H3 scenes. This minimizes repeated Krea ↔ H3
model swaps. If a scene needs a revised keyframe later, finish the active H3 job,
wait for an idle queue, clear memory, return to Krea, and clear again before H3.

### Step 5 — choose the H3 mode for one scene

| Need | Mode | Family | Guidance |
|---|---|---|---|
| Establishing shot with no recurring identity | T2V | FL2VA | Text only; simplest qualification path |
| Exact opening composition or previous scene's final frame | I2V | FL2VA | Supply first frame; optional last frame for a required endpoint |
| Character identity, wardrobe, voice, motion, or several references | R2V | REF2VA | Start with one or two images and `ref_image_size=match` |

Prefer I2V when one approved frame carries enough continuity. Prefer R2V when
identity must survive a large pose/camera change or when audio/video references
have explicit roles. More references are not automatically better; conflicting
images make the target ambiguous and increase token and memory pressure.

If most scenes use the same family, render them consecutively to reuse the model
cache. Still queue only one scene at a time. Use the Section 8 `/free` operation
when changing FL2VA ↔ REF2VA, Krea ↔ H3, or after any OOM.

### Step 6 — compile and render exactly one scene

For each accepted scene card:

1. Open only the corresponding saved BF16 H3 workflow.
2. Confirm no unrelated output branch is active and the queue is empty.
3. Load the approved first/last frame or references in the exact documented
   order.
4. Add `Muse Glimmer Creative Prompt` before the H3 prompt input.
5. Select `MiniMax H3 base` for T2V/I2V or `MiniMax H3 reference` for R2V.
6. For R2V, provide an explicit manifest such as:

   ```text
   <Picture 1>: Mara identity and face geometry only.
   <Picture 2>: canonical coat materials and colors only.
   <Picture 3>: clocktower doorway architecture and lighting only.
   ```

7. Paste the scene card as the brief. Inspect Muse's returned prompt; it must not
   contradict the scene card or renumber references.
8. Queue one 768p, approximately five-second, batch-1 generation.
9. Monitor RAM/VRAM as described in Section 8.
10. Do not queue the next scene until this scene is accepted or deliberately
    abandoned.

A fixed seed makes technical comparisons easier, but changing the prompt or
reference set changes the experiment. Preserve every attempted prompt and seed
in `generation-record.md` rather than overwriting the evidence.

### Step 7 — review continuity before moving on

Review a scene in isolation and immediately after the previously accepted scene.
Use objective checks:

- identity: face geometry, age, hair parting, scar side, body silhouette;
- wardrobe: cut, fasteners, material, color, dirt/wetness, carried props;
- space: screen direction, doorway/window positions, time of day, weather;
- action: correct hand, prop state, start pose, end pose, no duplicated limbs;
- camera: one intended move, stable horizon, no accidental cut or zoom;
- audio: exact dialogue, voice identity, sync, ambience, no unwanted music;
- output: no text, subtitle, logo, watermark, or unexplained extra person.

If it fails, regenerate **that scene only**. Change one cause at a time: prompt,
reference, seed, or mode. Do not repair identity drift by redefining the character
bible after the fact.

When a scene passes:

1. copy or link the exact MP4 to `accepted.mp4`;
2. save the final prompt, seed, model family, selector names, dimensions, frame
   count, references in order, and observed RAM/VRAM peaks;
3. update the next scene's `Continuity in` from what actually appears in the
   accepted closing frame;
4. extract the final frame if it should anchor the next I2V scene.

For example:

```bash
ffmpeg -sseof -0.1 -i accepted.mp4 -frames:v 1 -update 1 next-first-frame.png
```

Do not feed a degraded contact sheet or social-media transcode forward; use the
original accepted output or source reference.

### Step 8 — assemble only accepted scenes

Keep resolution, frame rate, codec, and audio layout consistent if you want a
stream-copy concat. Create `edit/concat.txt`:

```text
file '../scenes/010-rooftop-arrival/accepted.mp4'
file '../scenes/020-clocktower-entry/accepted.mp4'
file '../scenes/030-mechanism-wakes/accepted.mp4'
```

Then try lossless concatenation:

```bash
cd ~/creative-projects/clockwork-city/edit
ffmpeg -f concat -safe 0 -i concat.txt -c copy final.mp4
```

If stream copy rejects mismatched formats, normalize once in the final edit
rather than repeatedly transcoding scene references. Watch the assembled film
for audio discontinuities, pacing, color drift, and continuity mistakes that
were not obvious clip by clip.

### Recommended first exercise

Do not begin with a nine-scene epic. Prove the pipeline with one character and
three clips:

1. **Scene 010 — arrival:** I2V/FL2VA from a Krea rooftop keyframe; character
   walks to a locked door.
2. **Scene 020 — decision:** R2V/REF2VA with the canonical face and coat; close
   shot of the character choosing to use the watch.
3. **Scene 030 — consequence:** I2V/FL2VA from Scene 020's accepted final frame;
   the door opens and warm machinery is revealed.

Accept each scene before creating the next continuity handoff. This small test
exercises Krea identity editing, Muse scene compilation, both H3 families,
`/free` family transitions, native audio, and final assembly without hiding
problems inside a long generation.

## 10. Custom-node policy

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

## 11. Security and privacy

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

## 12. Validation gate

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
- [ ] H3 BF16 FL2VA T2V and one-keyframe I2V each complete at 768p/124 frames
      with Muse active on GPU0; record both GPU1 VRAM and host RAM peaks.
- [ ] After the FL2VA job finishes, the idle-queue `/free` operation or a
      ComfyUI restart clears its model/cache state.
- [ ] H3 BF16 REF2VA then completes with one matched-size image at 768p/124
      frames, without either DiT co-residing, host swapping, or a GPU OOM.
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

## 13. Stop or switch away

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
