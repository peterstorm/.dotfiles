# DeepSeek V4 Flash Vision r21 v1 qualification

**Result:** PASS for one-image vision, fixed-K6 DSpark, prefix caching, tools,
structured output, near-limit context, restart, and mixed soak

## Identity

- Checkpoint: `deepseek-ai/DeepSeek-V4-Flash-Vision-Exp@86f746b36186f0e567729a5c06a8c918caba82a9`
- Base: `voipmonitor/vllm@sha256:ed525dec1a4ac5cf7f19c7cf2fb29661389d71a29ff8de91aade8e6785e10291`
- vLLM tree: `d6cf36ae0dc30d48fd656a3c34a353ec62074922`
- Overlay: `sha256:800f7ad21304e8be633428ad0db4ef49839b75bff84071b84ef9f44c78042469`
- Image: `sha256:f5b3c70a39613bd2459bc186068e8e67720cf69b407a7c91b12a0585bf0ed183`
- Runtime: TP2, DCP1, B12X W4A8, DGLIN, FP8 KV, fixed DSpark K6,
  prefix cache enabled, chunked multimodal input disabled, `restart=no`

## Startup and capacity

- Target-only model allocation: 76.31 GiB/GPU.
- K6 model allocation: 81.86 GiB/GPU.
- K6 captured target, DSpark, and DFlash context-KV graphs through 56 rows.
- K6 KV capacity: 559,184 tokens.
- Maximum 312,000-token concurrency: 1.79x.
- `VLLM_USE_B12X_MHC=0` was active for checkpoint `rms_norm_eps=1e-20`.

## Correctness

- 96x96 red image: correctly identified red.
- 96x96 blue image: correctly identified blue.
- 1800x1800 green image: 349 multimodal tokens, correctly identified green.
- Required `get_weather` tool call: emitted valid `{"city":"Paris"}` arguments.
- Strict JSON schema: emitted `{"city":"Paris","country":"France"}`.
- K6 image-boundary generation completed without `indexSelectSmallIndex`, proving
  the draft embedding and direct Markov-anchor safeguards were exercised.
- All six speculative positions accepted tokens.

## Context and cache

| Prompt | Cold wall time | Cached wall time | Cached tokens | Result |
|---|---:|---:|---:|---|
| 120,135 tokens + image | 20 s | 2 s | 120,064 | red |
| 300,135 tokens + image | 35 s | 2 s | 300,032 | red |

The 300K cell corresponds to approximately 8.58K cold prompt tok/s including image
encoding and 254 generated tokens. Both cached cells retained correct image semantics.

## Decode comparison

Same 1,024-token streamed technical-prose request:

| Mode | TTFT | Decode tok/s | Overall tok/s |
|---|---:|---:|---:|
| target only | 0.223 s | 126.1 | 122.9 |
| fixed K6 | 0.164 s | 171.0 | 166.6 |

K6 improved measured decode rate by 35.6%. It is also the smallest legal DSpark depth:
K3 is below checkpoint `dspark_block_size=5`; K5 is not divisible by the three
predictor layers.

After the mixed soak, K6 counters were:

- 127,430 drafts;
- 764,580 draft tokens;
- 358,565 accepted draft tokens;
- 46.9% token acceptance;
- 2.81 accepted draft tokens per target step.

## Soak and restart

- Duration: 1,801 seconds.
- Batches: 962.
- Requests: 3,848.
- Traffic: concurrent short text, 4K text, 117-token red image, and 349-token green image.
- HTTP/schema errors: 0.
- CUDA/illegal-address/index-select/Xid/traceback log matches: 0.
- Restarts: 0.
- A manual stop/start completed, followed by passing text and red-image probes;
  Docker restart count remained zero.

## Repeatability boundary

Five temperature-zero cached repetitions all correctly identified red and all used
512 cached prompt tokens after the first request. Their complete reasoning/answer
hashes differed, and answer wording varied slightly. Vision semantics and cache safety
passed; byte-level generation determinism did not.
