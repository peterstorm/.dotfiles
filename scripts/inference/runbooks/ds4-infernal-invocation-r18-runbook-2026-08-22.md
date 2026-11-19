# DeepSeek-V4-Flash — Infernal Invocation r18

This is the workstation runbook for `deepseek-ai/DeepSeek-V4-Flash-0731` on the two
RTX PRO 6000 Blackwell cards in `desktop`. It replaces Gilded Gnosis r33 as the active
DS4 deployment while preserving the same model ID, API key, port, and pinned checkpoint.

**Deployment status:** repository integration complete; upstream TP2/DCP1 qualification
passed. The r18 image has not yet been cold-started or soak-tested on this workstation.
Do not copy the local r33 performance receipt forward as an r18 result.

## Immutable release identity

| Item | Value |
|---|---|
| Upstream runbook | [`ds4dspark-infernal-invocation-r18.md`](https://github.com/local-inference-lab/rtx6kpro/blob/9cfa57adc77a60f8ec800c976b831356f32d8190/models/ds4dspark-infernal-invocation-r18.md) |
| Image | `voipmonitor/vllm:infernal-invocation-vllmf0fa1ce-b12x75787c7-fi1ac6942-cu133-torch213-20260818-r18` |
| Registry digest | `sha256:414ec7d0d28358cfd8af0697f330f5c8acbb80e4dc4e5ba69c9fd5b5855ea804` |
| Image ID | `sha256:955e088a85b5378b00275842bc839eea8cb04ca0782ed79eaa3a967d11fd22e5` |
| Model revision | `9e165c30e2704aec5d9d593cce3eebd58bbef1cb` |
| vLLM tree | `f0fa1cefc1865d316c2478525f550e7646addc40` |
| B12X tree | `75787c7a7431b3bea414d2ebf5f2b8671b23eb33` |
| LMCache tree | `e045d729bc5c4c63a40e13d032f42923de97812f` |
| Runtime | CUDA 13.3, PyTorch 2.13.0, NCCL 2.31.2, CUTLASS DSL 4.6.2, FlashInfer 0.6.18, LMCache 0.5.2+glm52dcp.5, XGrammar 0.2.5, InstantTensor 0.1.9 |
| Upstream receipt | [`infernal-invocation-r18-remote-gpu.json`](https://github.com/local-inference-lab/blackwell-llm-docker/blob/main/validation/infernal-invocation-r18-remote-gpu.json) |

The checkpoint revision is unchanged from r33; do not download the 155 GiB model again
when `/models/DeepSeek-V4-Flash-0731` is already complete. The runtime cache is deliberately
new and release-scoped at `/models/vllm-cache/infernal-invocation-r18`; do not point r18
at the r33 JIT cache.

## Qualified serving contract

The qualified profile is:

- TP2/DCP1 on direct-root-port Blackwell GPUs;
- `deepseek_v4_fp8` target and draft quantization;
- B12X W4A8 MoE/linear kernels and compressed MLA attention;
- FP8 compressed MLA KV plus FP32 sliding-window compressor state;
- fixed **probabilistic** DSpark K5;
- FULL CUDA graphs for target/verifier decode, DSpark proposal, and DFlash context-KV;
- PIECEWISE or uncaptured prefill;
- InstantTensor `BUFFERED` loading;
- strict structured output through XGrammar 0.2.5;
- native vLLM offload and LMCache off unless selected independently.

Upstream qualified `MAX_MODEL_LEN=262144`, `MAX_NUM_SEQS=32`, and graph cap 192. Its C1
receipt was 164.46 aggregate tok/s and 64.40 target steps/s. Acceptance was 2.55 emitted
tokens per target step, so compare target-step rate—not raw emitted-token rate—against
releases with different acceptance.

## Prepare and launch

Host P2P, IOMMU, ReBAR, ZFS, headless, and Docker/CDI setup remains as documented in
[`new-desktop-install.md`](new-desktop-install.md). Verify the workstation is headless and
both cards are available:

```bash
sudo systemctl stop display-manager
nvidia-smi --query-gpu=index,memory.used,power.limit --format=csv
nvidia-smi topo -p2p rw
```

Download only if the pinned checkpoint is absent:

```bash
bash scripts/inference/deepseek/download-ds4-flash.sh
docker logs -f ds4-model-dl
```

Launch the digest-pinned local profile:

```bash
bash scripts/inference/deepseek/run-ds4-infernal-invocation-r18.sh
docker logs -f ds4-infernal-invocation-cu133-r18
```

The launcher:

- removes stale r31/r33 containers that could still own host port 8000;
- resolves the shared inference credential through `shared/inference-api-key.sh`;
- writes the key to a mode-0600 env file, never Docker argv;
- mounts the checkpoint read-only and keeps r18 JIT artifacts persistent;
- uses `/usr/local/bin/lmcache-mp-wrapper.sh` followed by
  `/usr/local/bin/serve-ds4-flash.sh`, matching the r18 Compose entrypoint;
- pins the image by registry digest;
- exposes `deepseek-v4-flash` at the existing authenticated `http://desktop:8000/v1`.

## Local scheduler envelope

The launcher retains this workstation's eight-agent r33 scheduler shape:

```text
MAX_MODEL_LEN=1048576
MAX_NUM_SEQS=8
MAX_NUM_BATCHED_TOKENS=4096
GPU_MEMORY_UTILIZATION=0.975
GRAPH=auto
```

At fixed K5, eight scheduler slots make 48 reachable all-decode rows:

```text
MAX_NUM_SEQS * (1 + DSPARK_TOKENS) = 8 * 6 = 48
```

`GRAPH=auto` derives that cap. The one-million-token setting is an **implemented launcher
envelope, not an r18 qualification result**: upstream explicitly lists full-context
1,048,576-token execution as unsupported by the receipt. First validate the default local
profile at ordinary agent context sizes; use the upstream-qualified envelope when isolating
a release regression:

```bash
MAX_MODEL_LEN=262144 MAX_NUM_SEQS=32 MAX_NUM_BATCHED_TOKENS=4096 \
  bash scripts/inference/deepseek/run-ds4-infernal-invocation-r18.sh
```

For the normal lower-concurrency local profile, all scheduler values remain overrideable:

```bash
MAX_MODEL_LEN=262144 MAX_NUM_SEQS=8 \
  bash scripts/inference/deepseek/run-ds4-infernal-invocation-r18.sh
```

## Health, authentication, and Pi

The unauthenticated health endpoint should return 200:

```bash
curl -fsS http://127.0.0.1:8000/health
docker inspect --format '{{.State.Status}} restarts={{.RestartCount}}' \
  ds4-infernal-invocation-cu133-r18
```

Keep the key out of curl's argv for authenticated probes:

```bash
auth_curl() {
  local key
  key="$(< ~/.config/ds4-flash/api-key)"
  printf 'header = "Authorization: Bearer %s"\n' "$key" | curl --config - "$@"
}

auth_curl -fsS http://127.0.0.1:8000/v1/models | jq

auth_curl -fsS http://127.0.0.1:8000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "deepseek-v4-flash",
    "messages": [{"role": "user", "content": "Reply with exactly OK."}],
    "reasoning_effort": "low",
    "max_tokens": 2048
  }' | jq
```

Pi's model contract does not change:

```bash
pi --model desktop-vllm/deepseek-v4-flash:high
```

The `low`, `high`, and `max` reasoning efforts remain request-time contracts and are
independent of DSpark draft depth.

## Optional serving modes

Only fixed probabilistic K5 has the physical-GPU performance receipt. These modes are
implemented but require a fresh correctness/performance gate on this host:

| Mode | Launch override | Status |
|---|---|---|
| Target only | `MODE=dspark-mtp0` | Correctness/performance baseline |
| Fixed K7 | `DSPARK_TOKENS=7 DSPARK_DEPTH_MODE=fixed` | Implemented, not performance-qualified |
| Confidence-controlled K7 | `DSPARK_TOKENS=7 DSPARK_DEPTH_MODE=dynamic` | Implemented, not performance-qualified |

Example:

```bash
DSPARK_TOKENS=7 DSPARK_DEPTH_MODE=fixed \
  bash scripts/inference/deepseek/run-ds4-infernal-invocation-r18.sh
```

## Native vLLM KV offload

Native offload has a pinned CPU L1 tier plus persistent filesystem L2. This workstation
mounts `/models/native-l2` into the container and defaults to a checkpoint/port-scoped path.
The ZFS dataset has a 512 GiB quota; keep that quota and `NATIVE_L2_GB` in step.

```bash
KV_OFFLOADING_SIZE=16 \
NATIVE_L2_GB=512 \
NATIVE_L2_PATH=/native-l2/deepseek-v4-flash-0731/8000 \
  bash scripts/inference/deepseek/run-ds4-infernal-invocation-r18.sh
```

Because the launcher uses host IPC, `KV_OFFLOADING_SIZE` consumes the host `/dev/shm`;
this machine has 48 GiB total. Leave runtime headroom. The filesystem path must remain
persistent and unique per checkpoint revision and cache geometry.

Upstream's r18 restart gate used a 2 GiB CPU tier and 64 GiB filesystem tier, found all
695 published objects after a complete vLLM process restart, read 607,357,440 bytes from
L2, and reproduced exact concurrent outputs.

## LMCache

LMCache is selected independently through the r18 multiprocess wrapper:

```bash
LMCACHE_MODE=disk \
LMCACHE_L1_GB=24 \
LMCACHE_L2_GB=512 \
LMCACHE_L2_PATH=/cache/lmcache/8000 \
  bash scripts/inference/deepseek/run-ds4-infernal-invocation-r18.sh
```

Every service port needs a distinct LMCache endpoint and L2 path. The upstream process
restart gate restored all 94 chunks for a 24,349-token request, reported 24,064 cached
prompt tokens, and preserved completion SHA-256
`9d3dcd6699ae22a7d31ca493d8dbee975121aad91e8db31d7674a950e1beba37`.

**Never enable native offload and LMCache together.** They have independent cache
ownership and transfer protocols. The default launcher leaves both off.

## Commit-pinned Compose reference

The local script is derived from the upstream profile at the commit that introduced and
locked r18:

```bash
curl -LO https://raw.githubusercontent.com/local-inference-lab/blackwell-llm-docker/07c6aa551bdfb7a97b8cfc7345eeefdc9bf1536f/examples/docker-compose-ds4-infernal-invocation-cu133-r18.yml

GPUS=0,1 TP_SIZE=2 DCP_SIZE=1 \
MAX_MODEL_LEN=1048576 MAX_NUM_SEQS=8 MAX_NUM_BATCHED_TOKENS=4096 \
JIT_CACHE=/models/vllm-cache/infernal-invocation-r18 \
CONTAINER_TMP=/models/vllm-cache/infernal-invocation-r18/tmp \
  docker compose -f docker-compose-ds4-infernal-invocation-cu133-r18.yml up -d
```

Prefer the repository launcher on this workstation: it additionally pins the registry
digest, uses the established served-model name, points directly at the checkpoint, mounts
the dedicated native-L2 dataset, and supplies the API key through a private env file.
The upstream Compose `image:` is a mutable tag and should not be treated as equivalent to
the digest-pinned launcher.

## First local validation gate

Before marking r18 locally qualified:

1. Confirm the registry resolves the pinned digest and Docker reports image ID
   `sha256:955e088a85b5378b00275842bc839eea8cb04ca0782ed79eaa3a967d11fd22e5`.
2. Cold-start with a clean r18 cache; record load, compile, graph-capture, and readiness
   times plus peak VRAM and restart count.
3. Confirm logs show FULL target, DSpark, and DFlash context-KV graph capture through the
   required 48 rows for the local MNS8/K5 profile.
4. Pass authenticated low/high/max reasoning, strict required/named/automatic tools,
   structured output, streaming, and malformed-tool recovery.
5. Run concurrency 1 and 8 decode measurements and record target steps/s, accepted tokens
   per target step, aggregate emitted tok/s, and latency separately.
6. Repeat the eight-agent long-context pressure test; do not inherit r33's 1M-capacity
   result without rerunning it on r18.
7. If enabling native offload or LMCache, run a complete process-restart replay and verify
   exact outputs plus durable-object/chunk restoration.
8. Run a sustained soak while watching `/var/lib/gpu-telemetry`, Xids, container restarts,
   `/dev/shm`, ZFS usage, and the inference ledger.

Static repository integration is checked with:

```bash
bash tests/ds4-release-contract.sh
bash tests/inference-api-key-contract.sh
```

## Qualification limits

Upstream qualifies TP2/DCP1 fixed probabilistic K5, B12X W4A8, FP8 compressed MLA KV,
FULL target/draft/context-KV graphs, strict tools at concurrency 8, native filesystem
replay, and LMCache disk replay. It does **not** qualify DCP greater than one, TP other than
two, K7 runtime performance, full 1,048,576-token execution, or model quality. Its
measurements used direct-root-port GPUs; switched-PCIe results are not comparable.
