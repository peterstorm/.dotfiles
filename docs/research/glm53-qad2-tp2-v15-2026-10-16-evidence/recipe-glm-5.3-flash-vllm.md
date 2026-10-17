# GLM-5.3-Flash vLLM Recipe (vendored text, retrieved 2026-10-16)

Source: https://claude.ai/code/artifact/a7cd0b46-db88-4891-b132-99b39cb313c9 (third-party recipe page; HTML stripped to text, content otherwise verbatim).

```text

GLM-5.3-Flash vLLM Recipe
  Recipe · 2× RTX PRO 6000 Blackwell · TP2 / DCP2
  GLM-5.3-Flash on vLLM “karmic-kraken”
  Production recipe for local-inference-lab’s vLLM build: 1.84M tokens of KV cache in VRAM and a 1M context on two PCIe cards. In daily use since 2026-10-15 as the main model of an always-on personal agent, replacing SGLang v0.6.1.
  KV 1,844,162 tokctx 1,048,576effort high300 W per card
  Versions
    Imageghcr.io/local-inference-lab/vllm:karmic-kraken-beta-20261015.2
    Digestsha256:a7dc6c5f23310c0949e72fc1977fdcdaa5d8a4e1a9e7ee8f2482e6163b296178
    EnginevLLM v0.1.dev21832+g54e054785 (lab build) · torch 2.14.0a0 (NV 26.08) · CUDA 13.4
    Checkpointlocal-inference-lab/GLM-5.3-Flash-NVFP4-MXFP8-CSF-QAD
branch qad2-kda-w8a16-csf · commit 0a0417631b4065d16e9639f327f44a0a4237a537 · ~177 GB
    Launcherlil-serve --profile glm53-flash --hardware rtx-pro-6000-pcie --preset glm53-tp2
    Preset resolves toTP2 / DCP2 · MTP 3 tokens · FP8 KV · 7,650,410,496 B KV per GPU · 8 sequences · A4 expert prefill · VLLM_GLM53_KDA_MXFP8_ACTIVATION_MODE=prefill · VLLM_GLM53_MTP_DRAFT_HEAD=bf16 · tool parser glm47
    Changed vs the lab’s composeCACHE_MODE=vram (no host-RAM KV tier) and server-default effort high instead of the preset’s max
  Compose
  docker-compose.ymlCopy
name: glm53-flash-vllm
services:
  vllm:
    # Digest-pinned: beta tags can move.
    image: ghcr.io/local-inference-lab/vllm:karmic-kraken-beta-20261015.2@sha256:a7dc6c5f23310c0949e72fc1977fdcdaa5d8a4e1a9e7ee8f2482e6163b296178
    container_name: vllm_glm53_flash
    entrypoint: ["/usr/local/bin/lil-serve"]
    # Context = the preset's 1,048,576 on purpose: --max-model-len 524288 regroups the
    # hybrid KV cache and the pool drops 1,844,162 → 1,561,213 tokens on the same memory.
    command: ["--profile", "glm53-flash", "--hardware", "rtx-pro-6000-pcie", "--preset", "glm53-tp2",
              "--", "--cache-mode", "vram"]
    init: true
    ipc: host
    shm_size: 32gb
    stop_grace_period: 180s   # TP2: let CUDA tear down on both cards
    ulimits:
      memlock: { soft: -1, hard: -1 }
      stack: { soft: 67108864, hard: 67108864 }
    restart: unless-stopped
    ports:
      - "8001:8001"
    runtime: nvidia
    volumes:
      - ${HF_CACHE_DIR:?set in .env}:/root/.cache/huggingface:ro
      - ${RUNTIME_CACHE_DIR:?set in .env}:/cache
    environment:
      NVIDIA_VISIBLE_DEVICES: "${GPU_UUIDS:?set in .env}"
      HF_HUB_OFFLINE: "1"
      PRESET: glm53-tp2
      CACHE_MODE: vram          # KV in VRAM only (the lab's compose uses lmcache)
      # The preset defaults to reasoning_effort MAX; clients can still override per request.
      DEFAULT_CHAT_TEMPLATE_KWARGS: '{"reasoning_effort":"high","clear_thinking":false}'
      HOST: 0.0.0.0
      PORT: "8001"
      SERVED_MODEL_NAME: glm-5.3-flash
  .envCopy
# The two cards for TP2, by UUID (nvidia-smi -L), comma-joined, no spaces
GPU_UUIDS=GPU-xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx,GPU-yyyyyyyy-yyyy-yyyy-yyyy-yyyyyyyyyyyy
HF_CACHE_DIR=/path/to/hf-cache
RUNTIME_CACHE_DIR=/path/to/lil-runtime-glm53-tp2
  Setup
    Download the checkpoint into an HF cache (hub layout). It is a full download, not a delta on older branches.
  downloadCopy
docker run --rm -e HF_TOKEN -v /path/to/hf-cache:/root/.cache/huggingface \
  --entrypoint python3 ghcr.io/local-inference-lab/vllm:karmic-kraken-beta-20261015.2 -c \
  "from huggingface_hub import snapshot_download as s; print(s('local-inference-lab/GLM-5.3-Flash-NVFP4-MXFP8-CSF-QAD', revision='qad2-kda-w8a16-csf'))"
    Check the launcher before giving it GPUs. --print-config needs no GPU and catches a preset that moved. Look for --revision 0a041763…, --kv-cache-memory-bytes 7650410496 and your effort.
  print-configCopy
docker run --rm -v /path/to/hf-cache:/root/.cache/huggingface:ro -e HF_HUB_OFFLINE=1 -e PRESET=glm53-tp2 \
  -e CACHE_MODE=vram -e 'DEFAULT_CHAT_TEMPLATE_KWARGS={"reasoning_effort":"high","clear_thinking":false}' \
  --entrypoint /usr/local/bin/lil-serve ghcr.io/local-inference-lab/vllm:karmic-kraken-beta-20261015.2 \
  --profile glm53-flash --hardware rtx-pro-6000-pcie --preset glm53-tp2 --print-config -- --cache-mode vram
    Fill in .env, then docker compose up -d. First start takes ~8–9 min (kernel JIT); later starts ~4–5 min. The log should show GPU KV cache size: 1,844,162 tokens.
  Gotchas
    The preset defaults to reasoning effort max. Set DEFAULT_CHAT_TEMPLATE_KWARGS explicitly before comparing “high” with anything. On vLLM a per-request chat_template_kwargs.reasoning_effort overrides the server default (on SGLang it did not).
    Don’t pin a shorter context to save memory. --max-model-len 524288 rebalanced the hybrid cache groups and the pool fell from 1,844,162 to 1,561,213 tokens on the same 7.12 GiB per GPU. Keep 1M and cap context in the client.
    Give reasoning room. Thinking shares the max_tokens budget; a small budget can return an empty answer.
    Measure recall at temperature 1. The checkpoint’s defaults are temperature 1.0 / top_p 0.95, so that is what clients get. Temp-0 pass/fail runs misled us for a week.
    Keep the /cache volume. A new image retunes kernels on first boot; the cache keeps restarts fast.
  Measured
  2026-10-13 to 10-15, both cards at 300 W, same harness for every engine. The SGLang column is v0.6.1 with ormandj’s W4A16 checkpoint.
  Long-context recall, temperature 1 / top_p 0.95
  A synthetic table of Record NNNNNN: item, quantity, region rows with the question before the document. The scored records have a near-duplicate N/10 twin (003700 vs 000370), the case the model gets wrong. 80 samples per record.
    Hard lookalike records
This recipe, high
This recipe, max
SGLang, high
      ~300K-token prompt (5 records, n=400)
88.0%
93.8%
90.5%
      ~516K-token prompt (4 records, n=320)
78.8%
95.3%
77.8%
  At equal effort the engines tie. The misses are the model quoting the lookalike row after a short think at high; they grow with context length, and max fixes most of them.
  The same test on independent deployments
  To check whether the misses come from quantization or a serving engine, the same two hardest records ran on two hosted deployments we don’t control: Ollama cloud (FP8) and z.ai’s own API (the model’s maker). Identical 516K-token prompt (same token count on every host), temperature 1 / top_p 0.95, effort high.
    ~516K, high
003700
005700
Both
Thinking tokens, median
      This recipe (vLLM, NVFP4/MXFP8 qad2)
55.0% n=80
67.5% n=80
61.3%
~38
      SGLang v0.6.1 (ormandj W4A16)
60.0% n=80
56.3% n=80
58.1%
~38
      Ollama cloud (FP8)
57.5% n=40
75.0% n=40
66.3%
~38
      z.ai API (the maker)
70.0% n=40
82.1% n=39
75.9%
~55
      Max effort, 003700: this recipe / z.ai
83.8% / 90.0% n=80 / 20
—
—
~60 / ~57
  Every deployment makes the same mistake, quoting the lookalike row word for word (“Record 003700: item delta, quantity 219”, which is Record 000370’s line). So the weakness belongs to the model at high effort, not to a quant or an engine. z.ai’s API scores higher, but it still misses about one lookup in four, and its “high” thinks noticeably longer (~55 vs ~38 tokens), which may explain the gap. One z.ai request timed out with no answer and is left out.
  Quality and function
  GSM8K n=1,319 at high: 1,250 vs SGLang’s 1,255 (McNemar p=0.55). Tool-call template pass. Vision stress pass: a 7680×4320 image and 10×4K images in one request while three long decodes run, at least 1.1 GB free per GPU. OpenAI API contract pass; SGLang’s native /generate is absent, as expected.
  Speed
    3.5K-token prompt, same harness
This recipe
SGLang v0.6.1
      Decode, aggregate tok/s, C1 / C2 / C3 / C4
172.5 / 231.7 / 262.4 / 290.7
169.7 / 264.6 / 300.5 / 329.4
      Cold prefill tok/s, 8K / 32K / 128K
7,949 / 7,939 / 7,228
6,251 / 6,033 / 5,831
      Cold prefill tok/s, ~498K
6,496
—
      Short-turn time to first token
307 ms
204 ms
  Under a realistic agent load (two ~300K chats plus two ~50K subagent prompts at once), warm chat turns averaged about 10 s here against about 18 s on SGLang. A 430K cold prefill still stalls other streams on either engine.
Thanks to local-inference-lab (Festr and the RTX6kPRO bot) for the build, the root-cause work and the qad2 checkpoint, to Unat for the BF16-attention experiments, and to ormandj for the SGLang build used as the control.
```
