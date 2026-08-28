# GLM-5.3 Flash EXL3 K4 v37 TP2/MTP3 v2

**Status:** v37 image pulled and statically verified; checkpoint download resumed; not booted or locally qualified. Upstream v84 now supersedes v37 for the multimodal/DFlash2 path; this v2 remains the immutable 500K text-only rollback candidate.

This profile follows Brandon Music's published SM120 TP2 daily-driver settings rather than the
conservative v1 qualification envelope. It is a new profile: v1 remains available as the
128K, C1, eager, MTP-off rollback.

## Immutable identities

| Artifact | Identity |
|---|---|
| Checkpoint | `brandonmusic/GLM-5.3-Flash-EXL3-4bpw@4739eb1bcfd478e8a32da6358908567bc3a9ac51` |
| Serving manifest | 135 files, 175,715,798,014 bytes, SHA-256 `96bb2e8ebdc287233c142f05465ac180c34c25e47a3b8ef338882faced3f52b7` |
| Runtime settings revision | `brandonmusic/GLM-5.3-Flash-EXL3-4bpw@b526998ef7644d90569866ef1df82999e26dcbfc` |
| Upstream Compose SHA-256 | `e36d2cbcbe235587fb77160bfa39c54b7c260fa361bba67e294a5eff4890a7e3` |
| Upstream serve script SHA-256 | `7b23c26b8cafd1cc35cf240db0863fcdbda341e9fe9856965d35e86654217231` |
| v37 image index | `sha256:711df22b7ccb121fe7838f9dfa23b0ec8235280534be3a08fd55ed58d61d1989` |
| AMD64 image | `sha256:bb0f2c524f3d55c03df25f62b4c7353fcce6a77468876028da2d6e58530c5f24` |
| Image config | `sha256:8cdac4aa483d6be7bd1a18961e57dbeddefc102f9f786689eece8b8a7ed419aa` |

The runtime files did not exist at the immutable checkpoint revision. They are therefore pinned
as a separate settings input rather than pretending the serving checkpoint changed. The v37
image adds the label
`local-token-split-zero-row-and-kpool-live-write-count` for its GDN/DCP/MTP graph fix.

## Upstream-aligned envelope

| Setting | v2 value |
|---|---:|
| Tensor parallelism | 2 |
| Decode context parallelism | 1, A2A backend |
| Context | 499,968 tokens |
| Active sequences | 4 |
| Batched tokens | 2,048 |
| GPU memory utilization | 0.988 |
| Weight reader | EXL3 K4 routed experts |
| Attention | `B12X_MLA_SPARSE` |
| KV cache | `nvfp4_ds_mla` |
| MTP | probabilistic, 3 speculative tokens |
| Prefix caching | enabled |
| Chunked prefill | enabled |
| CUDA graphs | enabled; eager mode is not forced |
| Vision/video | disabled with `--language-model-only` |

TP2 and DCP are different dimensions. This profile uses the upstream Compose default of TP2
and DCP1. The v37 serve script permits DCP2, but changing DCP is outside this immutable profile
and requires separate qualification.

The repository launcher adds only local operational requirements around the upstream envelope:
port 8000, the stable Pi model name, offline checkpoint loading, private API-key injection,
`glm45` reasoning, `glm47` tools, immutable labels, GPU identity checks, and rollback handling.
It does not add `--enforce-eager` or disable prefix caching/MTP.

## Evidence and limitations

The upstream artifact is specifically published for SM120 TP2, and v37 claims a DCP/MTP graph
fix. That is relevant upstream evidence, but not proof on this desktop. Local qualification is
still required because:

- desktop driver `595.91.07` differs from the image's CUDA 13.3 build environment;
- the upstream machine, prompts, load shape, and soak duration are not encoded in Compose;
- 0.988 memory utilization leaves little recovery margin on 96 GiB cards;
- a 499,968-token capacity setting is not proof of coherent end-to-end 500K behavior;
- the custom vLLM/B12X overlay remains unavailable as a publicly reconstructible source tree.

A GPU-assisted `vllm serve --help=all` probe succeeded on driver `595.91.07` and confirmed the
DCP, B12X, prefix-cache, speculative, generation-config, reasoning, and tool parser flags. It
did not load weights or execute kernels and is not a runtime qualification.

## Download and image verification

The checkpoint downloader is resumable. A transient Hugging Face Xet response-decoding error
is safe to retry:

```bash
cd ~/.dotfiles
DEST="$HOME/models/GLM-5.3-Flash-EXL3-K4-v1" \
  bash scripts/inference/glm53/download-glm53-flash-exl3-k4-v1.sh

docker logs -f glm53-exl3-k4-v1-model-dl
```

Pull and prove the v37 image:

```bash
bash scripts/inference/glm53/pull-glm53-flash-exl3-k4-vllm-sm120-v2-image.sh
```

The probe checks the AMD64 config, 100-layer rootfs, source and package labels, v37 graph-fix
label, TP2 EXL3 reader, GLM architecture registration, and both sparse MLA cache layouts. It
writes a private identity receipt under `~/.local/state/glm53/`.

## Preflight and launch

Preflight verifies all 163.7 GiB without touching GPUs:

```bash
MODEL_HOST="$HOME/models/GLM-5.3-Flash-EXL3-K4-v1" \
CACHE_HOST="$HOME/.cache/glm53-flash-exl3-k4-sm120-v2" \
  bash scripts/inference/glm53/run-glm53-flash-exl3-k4-vllm-sm120-v2.sh --preflight
```

For the attended cold boot:

```bash
systemctl stop comfyui.service
nvidia-smi

MODEL_HOST="$HOME/models/GLM-5.3-Flash-EXL3-K4-v1" \
CACHE_HOST="$HOME/.cache/glm53-flash-exl3-k4-sm120-v2" \
  bash scripts/inference/glm53/switch-glm53-exl3-profile-v2.sh start

docker logs -f glm53-flash-exl3-k4-vllm-sm120-v2
```

The launcher fails closed unless the checkpoint and image identities pass, both RTX PRO 6000
GPUs are effectively idle, both expose at least 97,000 MiB, both use the expected 450 W limit,
and port 8000 is free. The bearer token is supplied only through a mode-0600 env file.

## Qualification order

1. Confirm authenticated `/v1/models`; confirm unauthenticated access is rejected.
2. Inspect startup logs for CUDA compatibility, OOM, graph-capture, NCCL, EXL3, B12X, and MTP errors.
3. Run deterministic short text, reasoning, multilingual, and code prompts.
4. Exercise native tool calls, including malformed and multi-tool edge cases.
5. Compare MTP output quality against v1 with MTP disabled if any corruption is suspected.
6. Measure C1 and C4 prefill/decode throughput, queueing, TTFT, and VRAM headroom.
7. Test 32K, 128K, 256K, and 499,968-token retrieval/coherence separately.
8. Monitor temperatures, PCIe/NCCL behavior, corrected errors, Xids, and host memory during soak.

Do not call the profile qualified merely because it boots. Promotion requires correctness,
context, tools, concurrency, performance, restart, and soak evidence.

## Rollback

Stop v2 and start conservative v1:

```bash
docker rm -f glm53-flash-exl3-k4-vllm-sm120-v2 2>/dev/null || true

MODEL_HOST="$HOME/models/GLM-5.3-Flash-EXL3-K4-v1" \
CACHE_HOST="$HOME/.cache/glm53-flash-exl3-k4-sm120-v1" \
MAX_MODEL_LEN=131072 MAX_NUM_SEQS=1 \
  bash scripts/inference/glm53/switch-glm53-exl3-profile-v1.sh start
```

To leave inference stopped and restore creative workloads instead:

```bash
docker rm -f glm53-flash-exl3-k4-vllm-sm120-v2 2>/dev/null || true
systemctl start comfyui.service
```

The checkpoint is source-available under the attribution-required ShapleyMcg License v1.0,
not an OSI license. Retain its bundled license and attribution notices.
