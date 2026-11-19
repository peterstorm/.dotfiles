# GLM-5.3 Flash EXL3 K4 v84 multimodal + MTP3 v4

**Status:** v84 image pulled and statically verified; target checkpoint still downloading; not
booted or locally qualified.

This is the immutable counterpart to the user-supplied RTX PRO 6000 MTP recipe. It keeps v3 as
the v84 DFlash2-7 profile and adds a separate built-in-MTP3 profile. No runtime toggle can turn
one into the other, so each profile retains a stable checkpoint, memory, licensing, and rollback
contract.

## Provenance

The supplied wrapper was not present in the pinned TR3 Hugging Face or GitHub trees. Its runtime
claims therefore remain unverified user-supplied evidence. The artifacts it names are real and
are already pinned by v3:

| Artifact | Identity |
|---|---|
| Target | `brandonmusic/GLM-5.3-Flash-EXL3-4bpw@4739eb1bcfd478e8a32da6358908567bc3a9ac51` |
| Byte-identical current publication | `brandonmusic/GLM-5.3-Flash-tr3-4bpw@5ab363a8dcf6405955fd5f99671e01a1c9fb124b` |
| v84 image index | `sha256:0f1cdcc8891f1cc3a444121eb61d366289a1cbba285f0892dcbb24bc94961692` |
| AMD64 image | `sha256:184cfdb86fb08902898999ce5d7101f5711e3138f82b4738ba823145c17f8140` |
| Image config | `sha256:f28ba4b2192d8306f2ab93be9ea868459f76e2fd5893d4eef9f7cc48f9180578` |
| Official multimodal template | Z.ai SHA-256 `34d5ee66b12fa6446cdae131c352b8f68cd85369e0e6fda115583805fada3891` |
| Embedded runtime provenance | SHA-256 `cf4b00958987cc50f94641592b1a8d74874adb4d671861ce12dd5e8f2907d907` |

The existing target verifier proves that the checkpoint contains one complete MTP layer and that
main plus MTP tensors were materialized. The shared v84 image verifier proves the native-PyTorch
vision-RoPE fallback, official template, model registration, TORCH_SDPA availability, source
hashes, and image identity. Run it through:

```bash
bash scripts/inference/glm53/pull-glm53-flash-exl3-k4-vllm-sm120-v3-image.sh
```

The puller's v3 name reflects where the shared image was introduced; v3 and v4 use the exact same
image digest and config.

## Immutable envelope

| Setting | v4 value |
|---|---:|
| Target parallelism | TP2 / EP2 / DCP2 |
| Context ceiling | 98,304 tokens |
| Sequences | 4 maximum |
| Batched tokens | 2,072 maximum |
| GPU memory utilization | 0.986, fixed |
| Speculation | built-in MTP, 3 draft tokens, probabilistic |
| External draft | none |
| Target KV | calibrated `nvfp4_ds_mla` |
| Prefix cache | disabled |
| Vision encoder | `TORCH_SDPA` |
| Media | up to four images; video disabled |
| Template | official Z.ai multimodal template embedded in v84 |

Unlike the supplied wrapper, v4 does not expose `MTP_TOKENS`, `NO_VISION`, `ENFORCE_EAGER`, or
arbitrary trailing arguments. Those combinations represent different qualification states:
v1 already provides eager text rollback, v2 provides long-context MTP text, v3 provides v84
vision with DFlash2, and v4 provides v84 vision with exactly MTP3.

The supplied measurements claimed roughly 122–126 tok/s C1 decode and 437K–673K allocated KV
tokens for MTP3. They do not identify an immutable receipt, test corpus, command output, driver,
repetition count, or failure distribution. Treat them as hypotheses for local measurement, not
qualification evidence. The 0.986 utilization is also intentionally more aggressive than v3's
0.95 vision-headroom setting.

## Preflight and launch

No DFlash2 checkpoint is required:

```bash
MODEL_HOST="$HOME/models/GLM-5.3-Flash-EXL3-K4-v1" \
CACHE_HOST="$HOME/.cache/glm53-flash-exl3-k4-sm120-v4" \
  bash scripts/inference/glm53/run-glm53-flash-exl3-k4-vllm-sm120-v4.sh --preflight
```

Attended boot after the target checkpoint is fully verified:

```bash
systemctl stop comfyui.service
nvidia-smi

MODEL_HOST="$HOME/models/GLM-5.3-Flash-EXL3-K4-v1" \
CACHE_HOST="$HOME/.cache/glm53-flash-exl3-k4-sm120-v4" \
  bash scripts/inference/glm53/switch-glm53-exl3-profile-v4.sh start

docker logs -f glm53-flash-exl3-k4-vllm-sm120-v4
```

The launcher fails closed on target and image identity, template hash, exact 0.986 utilization,
GPU identity/memory/power, active ComfyUI, and port conflicts. It serves
`glm-5.3-flash-exl3-k4-vision-mtp` on authenticated port 8000.

## Qualification and A/B

1. Prove authenticated model discovery and unauthenticated rejection.
2. Confirm TP2/EP2/DCP2, calibrated NVFP4 MLA, MTP3, TORCH_SDPA, the vision fallback, CUDA graphs,
   and disabled prefix caching in logs.
3. Repeat v3's local/remote/four-image, malformed-media, video-rejection, reasoning, tool, context,
   restart, and soak gates.
4. Compare v4 against target-only greedy output for exact parity and record MTP acceptance.
5. Compare v3 and v4 at their immutable defaults first; do not call it a controlled speculation
   A/B because utilization differs. A separately versioned equal-utilization pair is required for
   a strict performance comparison.
6. Fail v4 if 0.986 causes encoder warmup OOM, unsafe recovery margin, unstable graph capture, or
   materially worse image/context behavior. Roll back rather than silently lowering utilization.

## Rollback

The switcher transactionally restores the previously running repository-owned profile after a
failed launch or authenticated readiness gate. Manual rollback to v3:

```bash
docker rm -f glm53-flash-exl3-k4-vllm-sm120-v4 2>/dev/null || true
MODEL_HOST="$HOME/models/GLM-5.3-Flash-EXL3-K4-v1" \
DFLASH_HOST="$HOME/models/GLM-5.3-Flash-DFlash2-v1" \
  bash scripts/inference/glm53/switch-glm53-exl3-profile-v3.sh start
```

v4 uses no DFlash2 weights and therefore does not add the draft model's CC-BY-NC-ND-4.0 runtime
dependency. The target remains governed by ShapleyMCG License 1.0.
