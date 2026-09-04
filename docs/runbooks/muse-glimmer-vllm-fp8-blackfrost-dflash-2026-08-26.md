# Muse Glimmer vLLM — FP8 and Blackfrost BF16+DFlash

## Immutable closure

- vLLM image: `vllm/vllm-openai@sha256:413c8fbecb1204a218117c77a4ea4b3a211d5686ff99c31d82ba6dd0cec8c5a6`
- Image ID: `sha256:e90b8320f680a6a7b8daff87ad08cdf063a68d869880e662fd6d2cebfef689dc`
- vLLM: `0.26.1rc1.dev608+g99a10304d`
- FP8 target: `RedHatAI/Muse-Glimmer-30B-FP8-block@8ed2e29141d4fef439b9a0e15e0a2678bc190a82`
- Blackfrost BF16 target: `Blackfrost-AI/Muse-Glimmer-30B-Abliterated-BF16@1b489c23b583d609b6c17b00e1a877d1faac1ee2`
- Official Muse DFlash assistant: `meta-models/Muse-Glimmer-30B-assistant@e8192f3a8f617f74be2ce220360c89ef4789f39f`

All checkpoints must pass their exact size/SHA-256 manifests and matching `.download-complete` marker before launch.

## GPU and network contract

- Muse owns physical GPU0 through Docker `device=0`.
- The container receives only one visible device, remapped internally to `CUDA_VISIBLE_DEVICES=0`.
- ComfyUI must prove `CUDA_VISIBLE_DEVICES=1` while active.
- API binds `0.0.0.0:8001`, reachable on the LAN at `192.168.0.80:8001` and gated by the bearer key.
  This matches every other profile in `scripts/inference/`, the `8001` opening in
  `machines/desktop/default.nix`, and the Prometheus scrape of `192.168.0.80:8001`. An earlier
  loopback-only bind silently broke both that scrape and Pi's `desktop-muse` provider.
- API credentials are read from the private Muse key file and installed through a mode-0600 env file; they never enter Docker argv.
- Host power policy permits at most 450 W, matching `machines/desktop/default.nix`.
- `MAX_MODEL_LEN` defaults to the checkpoint-native 131072 and is refused above it. The KV
  pool is sized by `--gpu-memory-utilization`, not by the window, so raising the window
  costs no VRAM: the same 19.71 GiB pool holds 610,685 tokens either way, which is 4.66x
  concurrency at 131072 against `--max-num-seqs 2`. An earlier 32768 default left roughly
  sixteen seats' worth of KV allocated and unreachable.

## FP8 download

```bash
cd ~/.dotfiles
MUSE_FP8_DOWNLOAD_DETACH=yes \
  scripts/inference/muse/download-muse-glimmer-30b-fp8.sh

tail -f ~/.local/state/creative-model-downloads/muse-glimmer-30b-fp8.log
```

Xet is deliberately disabled. A live test against this repository stalled at a 16 KiB incomplete object; standard Hugging Face HTTPS is slower but resumable and observable.

## FP8 target-only qualification baseline

```bash
cd ~/.dotfiles
MUSE_FP8_SPECULATION=target-only \
  scripts/inference/muse/run-muse-glimmer-30b-fp8-vllm.sh
```

Do not start the FP8 DFlash profile until target-only chat, reasoning, tools, Director prompt fidelity, residency, and latency are preserved.

## FP8 plus DFlash candidate

```bash
cd ~/.dotfiles
MUSE_FP8_SPECULATION=dflash \
  scripts/inference/muse/run-muse-glimmer-30b-fp8-vllm.sh
```

Retain only if deterministic outputs are correct and matched prompts show a measurable throughput improvement over target-only.

## Blackfrost BF16 plus DFlash

```bash
cd ~/.dotfiles
scripts/inference/muse/run-muse-glimmer-30b-blackfrost-bf16-dflash-vllm.sh
```

Served model: `muse-glimmer-30b-blackfrost-bf16`.

First qualified startup on 2026-08-26:

- target load: 55.46 GiB checkpoint, 52.14 s;
- draft load: 4.76 GiB checkpoint, 4.77 s;
- combined model load: 56.97 GiB;
- steady GPU0 residency: approximately 77.7 GiB with 17.74 GiB KV cache;
- DFlash graphs captured successfully;
- API became healthy on loopback with no OOM or restart;
- exact smoke response at low reasoning: `MUSE READY`;
- initial DFlash log samples showed mean acceptance lengths from 4.8 to 8.0 and draft acceptance from 25.3% to 46.7%; these are smoke observations, not an A/B speed qualification.

Warnings retained:

- 4,096 scheduled tokens may cap speculative throughput;
- automatic reasoning token-ID initialization warns, although responses separated `reasoning` and `content` correctly;
- the first requests triggered expected cold Triton compilation;
- default high reasoning can consume a very small `max_tokens` budget before emitting content—use an adequate budget or request low reasoning for short Director operations.

## Director endpoint

Use these exact request values:

```json
{
  "llm_url": "http://127.0.0.1:8001/v1",
  "api_format": "OpenAI Compatible",
  "openai_compat_mode": "标准",
  "model": "muse-glimmer-30b-blackfrost-bf16"
}
```

The lowercase values `openai_compat` and `standard` are not accepted by upstream Director and fall back to Ollama `/api/chat`, producing HTTP 404.

The first `r2v` Director result used `image0/image1/image2` rather than H3’s `<Picture 1>/<Picture 2>/<Picture 3>` syntax. Preserve the raw response and treat any tag correction as an explicit adaptation until Director receives a deterministic schema repair.

## Stop

```bash
docker stop muse-glimmer-30b-blackfrost-bf16-dflash-vllm
```

The FP8 downloader is independent of the container and may continue while Blackfrost serves.
