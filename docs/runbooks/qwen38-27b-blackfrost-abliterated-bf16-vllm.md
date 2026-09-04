# Qwen3.8-27B Blackfrost Abliterated BF16 — pinned TP1 vLLM

Blackfrost's abliterated 27B is a weight-level derivative of `Qwen/Qwen3.8-27B` with a
reduced refusal surface. It is **not** the upstream safety-stock checkpoint and must not
be represented as one. Blackfrost measures 11 residual refusals across 450 cases (2.4%).

## Immutable closure

- Target: `Blackfrost-AI/Qwen3.8-27B-ABLITERATED-BF16@9d85770e5eb602322b4bceef55beda357e0bd0ca`
- vLLM image: `vllm/vllm-openai:nightly-a9a17e7095a66ef6c6685a1c7ddd657781a78d3c@sha256:3578c1fa6a9676e1de068b9d75c777cc865d251fadfbe6175ae82278739c6674`
- Optional DFlash2 draft: `incoai/Qwen3.8-27B-DFlash2@dedf8df68adfb1afeaf7b7480c0a0243108177b4`
- Served model: `qwen3.8-27b-blackfrost-abliterated`
- 31 artifacts, 55,586,061,398 bytes (51.77 GiB), each pinned by size and SHA-256 in
  `scripts/inference/qwen38/qwen38-27b-blackfrost-abliterated-bf16-v1.manifest`

The manifest is itself digest-pinned inside the downloader, so a tampered manifest fails
before any network access. LFS digests were taken from the Hub API at the pinned revision
before downloading; the small files were fetched and hashed at that same revision.

## Why it reuses the v3 profile

The checkpoint is structurally identical to `/models/Qwen3.8-27B`: same
`Qwen3_5ForConditionalGeneration` architecture, same `qwen3_5_text` 262144-token contract,
same 64 layers, no quantization config. The abliteration is a weight edit, not a structural
one, so the qualified TP1 profile serves it unchanged — same image, parsers, dtype, GDN
state policy, and GPU guards. The launcher refuses the checkpoint if any of those
structural facts differ.

## Download

```bash
cd ~/.dotfiles
bash scripts/inference/qwen38/download-qwen38-27b-blackfrost-abliterated-bf16.sh
docker logs -f qwen38-27b-blackfrost-abliterated-bf16-model-dl
```

Xet is deliberately disabled. `hf-xet` 1.6.0 stalls on this workstation for this
repository exactly as it does for Muse — every shard `.incomplete` file sits at zero bytes
with no transfer. Standard Hub HTTPS is slower but resumable and observable.

## Serve

```bash
cd ~/.dotfiles
scripts/inference/qwen38/run-qwen38-27b-blackfrost-abliterated-bf16-vllm.sh
```

Decoding defaults to target-only. Do not adopt DFlash2 until target-only chat, reasoning,
tool calls, and Pi behaviour are confirmed here — the same qualification rule the Muse FP8
runbook sets. DFlash2 pairs the official draft with an abliterated target, which is the
cross-pairing Muse Blackfrost already uses successfully:

```bash
QWEN_BLACKFROST_SPECULATION=dflash2 \
  scripts/inference/qwen38/run-qwen38-27b-blackfrost-abliterated-bf16-vllm.sh
```

## GPU and network contract

- Defaults to physical GPU0 through Docker `device=0`; the container sees one device,
  remapped internally to `CUDA_VISIBLE_DEVICES=0`.
- Refuses to start if the chosen GPU already holds more than 2048 MiB. Running beside Muse
  means `GPU_DEVICE=1` with ComfyUI stopped, since ComfyUI owns GPU1.
- ComfyUI must prove `CUDA_VISIBLE_DEVICES=1` while active.
- API binds `0.0.0.0:8000`, gated by the shared endpoint bearer key, matching every other
  profile and the firewall opening in `machines/desktop/default.nix`.
- Credentials are installed through a mode-0600 env file and never enter Docker argv.
- Host power policy permits at most 450 W.

## Behavioural note

The checkpoint's `chat_template.jinja` embeds a Blackfrost operational system prompt. That
is a real behavioural difference from both upstream Qwen and the local `qwen3.8-27b`
entry. Inspect it before treating outputs from the two as comparable.

## Contract

```bash
bash tests/qwen38-blackfrost-abliterated-bf16-contract.sh
```

## Stop

```bash
docker stop qwen38-27b-blackfrost-abliterated-bf16-vllm
```
