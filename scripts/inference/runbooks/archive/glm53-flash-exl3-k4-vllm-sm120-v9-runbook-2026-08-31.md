# GLM-5.3 Flash EXL3 K4 v9 fast/safe CUDA-graph candidate — 2026-08-31

**Status:** immutable image built, GPU-probed, graph-booted, and basic throughput/vision/prefix
smoke-tested. Short C1 reached a usage-derived median **131.5 output tok/s** (4.28× v8's ~30.7),
but temperature-zero complete-message equivalence is still red (10/10 distinct outputs).
Long-context throughput, mixed-traffic soak, and promotion remain pending. The launcher keeps
`restart=no` and the switcher cannot promote it.

## Goal

Recover the throughput lost by v8 without dropping vision, built-in MTP3, prefix caching, FP8 DS
MLA KV, or the 359,000-token request envelope. v8 measured about 30.7 effective output tok/s after
forcing eager execution and replacing the sparse selector with a full-row `torch.topk`.

v9 keeps TP2/EP2/DCP1 and introduces two independent performance changes:

1. rebuild the vLLM stable extension with PR #52149's overflow-detecting exact persistent top-k,
   plus deterministic lower-token-index membership at an exactly tied boundary;
2. remove `--enforce-eager` after adding overlap-safe Mamba copies, narrow block-table guards, and
   persistent KPool circular-slot storage needed for safe CUDA-graph replay.

## Immutable identities

| Artifact | Identity |
|---|---|
| v84 AMD64 base manifest | `sha256:184cfdb86fb08902898999ce5d7101f5711e3138f82b4738ba823145c17f8140` |
| v84 base config | `sha256:f28ba4b2192d8306f2ab93be9ea868459f76e2fd5893d4eef9f7cc48f9180578` |
| v9 image config | `sha256:82ea6cb3874e4869d43993146bf52b2522f010c1206c7a5f7bd3ec04bc2bcdf2` |
| Existing #50021 + CPU-partition patch | `sha256:a8e288ec067fed7e2e38762ca71e6034982dc4d40dc02ceec5caa1dc319ace85` |
| v9 state/graph patch | `sha256:4ecec3de89f52125fc5884e4924ed5fb326bb1d9e6a97fc04a005147e22ea528` |
| v9 persistent-top-k patch | `sha256:8baae7bea9cb85cf72dfc86702187b0227ff585fcb81dbdc8b30747195c24395` |
| rebuilt `_C_stable_libtorch` | `sha256:b144bf4e1f0d2455e016191de4bca50bc72cdf517593b374940f9cb2fc68e415` |
| embedded vLLM base commit | `6dc2f516688fe6f84c6994dcd20fddf296853a6c` |

The derived image retains all 113 base rootfs layers as an exact prefix and adds two layers. The
build verifies every patch and affected source before and after application, compiles Python, and
rebuilds the CUDA stable extension for SM120.

## Pinned repairs

- **#50021** at `9a198c0f…`: accepted-token-derived KDA/GDN/Mamba/causal-conv bounds.
- **CPU-proven GLM partition:** exact mixed speculative/non-speculative token coverage.
- **#50729** merged as `a02cfccb…`: memmove semantics for overlapping Mamba state shifts while
  retaining the tiled path for distinct blocks.
- **#54296** at `191f82d7…`: V1 and V2 block-table row guards; invalid columns emit `PAD_SLOT_ID`.
- **KPool graph-address repair:** circular slots are written into the caller-owned persistent
  buffer rather than a transient clone.
- **#52149** at `b8f88c1a…`: candidate-overflow detection, widened histogram, and exact bounded
  FP32 radix fallback in every persistent-top-k dispatch path.
- **Deterministic boundary repair:** fallback collection uses contiguous block scans, so exact-score
  ties choose lower token indices without score perturbation or atomics deciding membership.

## Completed image probe

The GPU probe passed on both RTX PRO 6000 Blackwell cards. It verifies:

- exact source and compiled-extension hashes;
- crowded 33×32,769, K=2,048 selected-value equivalence with `torch.topk`;
- 50 repeats of an all-equal overflow case selecting exactly indices `0..2047`;
- 20 repeats of the 806,736-column #51782 regression;
- 20 overlap-safe 128-row Mamba copies against untouched snapshots;
- narrow V2 block-table rows producing `[28, -1, -1]` rather than reading another row;
- KPool circular output preserving the persistent destination address.

Direct crowded-overflow selector medians from the image probe:

| Selector | Median |
|---|---:|
| v9 persistent exact top-k | **0.0255 ms** |
| full-row `torch.topk` | **0.0584 ms** |

This is a 2.29× operator-level speedup for that forced-overflow cell. It is not an end-to-end
throughput claim; CUDA graphs are expected to be the larger service-level gain.

## Build and prove

Run only while the two GPUs can accommodate the short qualification probe:

```bash
bash scripts/inference/glm53/pull-glm53-flash-exl3-k4-vllm-sm120-v9-image.sh
```

The command writes the immutable receipt to:

```text
~/.local/state/glm53/exl3-k4-vllm-sm120-v9-image.identity
```

## Attended candidate launch

```bash
systemctl stop comfyui.service
bash scripts/inference/glm53/switch-glm53-exl3-profile-v9.sh start
```

The candidate must boot with:

- served model `glm-5.3-flash-exl3-k4-vision-fp8kv-mtp-359k-v9`;
- TP2 / EP2 / DCP1;
- GPU memory utilization fixed at the v8-proven 0.986; the first graph boot's duplicate graph
  estimate exposed only 2.9 GiB KV versus 3.19 GiB required, while 0.991 exceeded the display
  host's actual free VRAM, so v9 uses vLLM's documented
  `VLLM_MEMORY_PROFILER_ESTIMATE_CUDAGRAPHS=0` path instead of overcommitting the device;
- CUDA graphs enabled by omission of `--enforce-eager`;
- vision up to four images, video disabled;
- prefix caching and greedy built-in MTP3 enabled;
- restart policy still `no` after authenticated readiness.

The switcher writes each boot's exact KV receipt to:

```text
~/.local/state/glm53/exl3-k4-vllm-sm120-v9-kv-capacity.txt
```

## First graph boot and basic runtime evidence

The accepted boot captured FULL and PIECEWISE prefill/decode graphs, retained the candidate's
`restart=no` policy, and reported:

| Measurement | v9 graph boot |
|---|---:|
| Available KV cache memory | **4.62 GiB/GPU** |
| Engine KV token capacity | **517,558 tokens** |
| Full-359K concurrency | **1.44×** |
| Actual CUDA graph pool | **0.15 GiB/GPU** |
| Container restart count | **0** |
| Current-boot Xid/SXid/MMU events | **0** |

The disabled estimator had predicted 0.39 GiB while the captured pool used 0.15 GiB. After graph
capture and KV allocation, each card retained roughly 1.1 GiB outside the serving allocation.

Four short C1 probes each generated exactly 800 completion tokens. Usage-derived rates were
132.4, 130.0, 142.8, and 131.5 output tok/s; the three-repeat median was **131.5 tok/s**. TTFT was
107–196 ms and MTP mean accepted length was 2.67–2.94. The older shell probe's 48–49 "tok/s"
number counts SSE chunks rather than usage tokens and therefore undercounts multi-token deltas.
This short-context result clears the 2× v8 target, but it does not satisfy the required 128K gate.

Runtime capability smokes passed:

- a generated 32×32 red PNG returned exactly `red` and reported 16 image tokens;
- an 8,263-token repeated prefix returned `PREFIX_OK` both times; the second request reused 3,456
  tokens and fell from 3.77 s to 0.83 s;
- MTP draft/accept counters advanced and no engine/GPU fault appeared.

Correctness promotion remains blocked. Ten completed `temperature=0`, `seed=0`, low-reasoning
requests with the same 33-token prompt all stopped normally, but produced **10 distinct complete
content hashes**. The outputs were semantically valid and ended with the required marker, yet byte
identity failed. This confirms that #51782/top-k membership was real but not the only numerical
nondeterminism, matching v8's earlier finding. Do not promote this image until the remaining path
is isolated.

## Immediate qualification order

1. Confirm graph capture/replay in startup logs and zero current-boot Xid/SXid/MMU events.
2. Run fixed C1 1,024-token decode cells at empty, 32K, and 128K context; compare v8's ~30.7
   tok/s and record target steps/s plus MTP acceptance separately.
3. Repeat complete temperature-zero message hashes across cold, exact-warm, partial-warm, changed
   prefix, process restart, and graph-shape transitions.
4. Exercise one/four changed images, reasoning, tools, and explicit video rejection.
5. Admit a cold 100K/256K/350K prefill while cached MTP decode is active; require no starvation,
   index fault, output drift, or GPU error.
6. Run the 12-hour mixed soak. Only then create a separately reviewed promotion change.

The minimum performance gate is 2× v8 C1 throughput at 128K with no correctness regression; the
stretch target remains 90+ tok/s.

## Rollback

The switcher restores every previously running repository-owned profile if launch or acceptance
fails. Manual rollback to v8:

```bash
docker rm -f glm53-flash-exl3-k4-vllm-sm120-v9 2>/dev/null || true
bash scripts/inference/glm53/switch-glm53-exl3-profile-v8.sh start
```

Pi selector, only while the v9 candidate is actually serving:

```text
desktop-vllm/glm-5.3-flash-exl3-k4-vision-fp8kv-mtp-359k-v9:max
```
