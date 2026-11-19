# Qwen3.8 Flash-Next FP8 vLLM v2 source-safe runbook

**Status:** runtime/state-safety qualified; semantic quality failed; candidate not promoted

**Profile:** `qwen38-flash-next-fp8-vllm-v2`

**Checkpoint:** `Qwen/Qwen3.8-Flash-Next-FP8@970c569adaca6b35532111fd6b27351b2baefe50`

**Safety posture:** candidate only, `restart=no`, prefix caching disabled

## Immutable identities

| Item | Identity |
|---|---|
| Public vLLM source | `e126687a9a828d513c01a07cd69f025f27d63280` |
| Deterministic source overlay | `c0ac28980016af357df50359d301648352eebbf2` |
| PyTorch build base | `pytorch/manylinux2_28-builder:cuda13.0-78e737ad29420ffc4800e677c51e2a852caf8359@sha256:c8d8dba2124931732d1b073dec1d8999cd4d6c5ff7c5e77232137e77d9f00f6a` |
| CUDA runtime base | `nvidia/cuda:13.0.3-base-ubuntu24.04@sha256:7c7413a56200486f71f181cad9310f6fd31b6bb21816ade15fc9c1e1e927a5c1` |
| Final image | `sha256:931c3c595e48f63c1900ee559966cad845673e37bdc2bd73ce5f49390a8154e1` |
| Qwen v1 rollback | `sha256:32a26fee4a4225b565017c36ce4f6589d716d608b59bbaa93c712a31a8433a32` |
| GLM v10 production image | `sha256:ef5f2fcb25d16abdcd800ff70b158e077780f2cb550a0ebf5bd1fe12e9f44553` |

The Qwen v2 image is built from the public source commit. It does not copy the GLM
`_C_stable_libtorch.abi3.so`; the complete vLLM wheel and exact persistent-top-k
extension are compiled in the Qwen source tree for SM120.

## Patchset

Apply in this exact order with `patch --batch --fuzz=0`:

| Patch | SHA-256 | Purpose |
|---|---|---|
| `qwen38-v2-ple-uva.patch` | `009d4acd2f3b96dd1b2e63b085855ad885e1d2832c0d6eb96d0e0ef4118b90b3` | Adapt PR #54371 pinned-host/UVA PLE and NP group support |
| `qwen38-v2-exact-persistent-topk.patch` | `8baae7bea9cb85cf72dfc86702187b0227ff585fcb81dbdc8b30747195c24395` | Exact lower-index tie handling and overflow fallback from PR #52149 |
| `qwen38-v2-accepted-state-safety.patch` | `db95c8dc58cf8ae7b89f61e7194649dab52eacc07cac447cb84bcf8404062ba8` | Adapt PR #50021 bounds and CPU-proven mixed GDN token partition |
| `qwen38-v2-qsa-canonical-order.patch` | `fca4f69894c8583665e9b0758f92ef661b6de68ed550c804588c485fc28159d3` | Sort selected compressed blocks before order-sensitive QSA reduction |
| `qwen38-v2-ple-state-safety.patch` | `653469b47e8e1eec7e45cf0aa1090796d78fb45c43ab91084bf950d18381cc5e` | Fail closed on invalid PLE accepted counts and decode/prefill/spec state rows |
| `qwen38-v2-large-topk-ties.patch` | `287c32801f6a7d8700849afad6b0efa03b1885063cdd37864265512fea3414bc` | Remove the multi-CTA boundary-tie race by selecting equal scores in global token-index order |

Upstream references are pinned to:

- PLE/UVA: `vllm#54371@905219234b0698b1f1ec2ed756de7051b080fb1c`;
- exact persistent top-k: `vllm#52149@b8f88c1a29f54dcc42f1b163db523bf362e845e3`;
- accepted-token state bounds: `vllm#50021@9a198c0f8452d0eb251509f02753853903d9f17f`.

## Build and proof

```bash
scripts/inference/qwen38/build-qwen38-flash-next-vllm-v2-image.sh
scripts/inference/qwen38/pull-qwen38-flash-next-vllm-v2-image.sh
```

The build script verifies source identity, patch hashes, zero-fuzz application,
patched source hashes, deterministic overlay commit, base-image digests, final image
identity, and the GPU verifier. It first builds the complete public-source wheel, then
rebuilds `_C_stable_libtorch.abi3.so` from the final repaired source tree in a Qwen-owned
stage; the qualified extension is `sha256:c7d4513f12740b58f01b6903128227d02bda7f6c1d1491a50f4e38955824ea95`. The pull/proof script verifies labels, runtime
environment, installed source hashes, model registration, UVA PLE classes, and QSA
capability.

The GPU verifier independently gates:

- exact persistent top-k membership at 65,536 columns and rows 1/32/64/192/512;
- deterministic lowest-index ties and crowded-bin overflow;
- repeated launches and CUDA Graph replay;
- canonical QSA output against a `torch.topk` reference at realistic `k=512`;
- QSA tie repeatability and CUDA Graph replay;
- CPU-proven complete/disjoint mixed-token partitions;
- invalid accepted counts for causal-conv, selective-state, recurrent FLA, and sigmoid-gating paths;
- invalid accepted counts and invalid state rows for Qwen's PLE short convolution.

## Launch

```bash
scripts/inference/qwen38/run-qwen38-flash-next-fp8-vllm-v2.sh --preflight
scripts/inference/qwen38/switch-qwen38-flash-next-profile-v2.sh start
```

The immutable launch contract is:

- TP2 and NP2 over both RTX PRO 6000 Blackwell GPUs;
- PLE FP8 table in pinned host RAM through UVA;
- MTP with three draft tokens;
- one image and no video per request;
- 262,144-token maximum context;
- at most four concurrent sequences;
- prefix caching explicitly disabled, yielding effective Mamba cache mode `none`;
- API key supplied only through a mode-0600 env file;
- Docker restart policy `no`.

The switcher stops existing profiles transactionally, runs the complete GPU verifier
before model load, launches the candidate, requires authenticated readiness and zero
restarts, and runs the cache-isolated deterministic prefill probe. Any failure stops
the candidate and restores the previous profile set.

## Qualification gates

Keep the candidate at `restart=no`. Record cold and warm results separately.

1. Prove exact image/config/labels and checkpoint manifest.
2. Run the standalone GPU verifier before loading weights.
3. Require authenticated `/v1/models`, `/health`, zero restarts, and no Xid.
4. Confirm logs show pinned-host PLE allocation and MTP3 initialization.
5. Run repeated temperature-zero text and long-prefill output hashes.
6. Validate reasoning, tool calls, streaming, and one-image vision input.
7. Confirm MTP draft and accepted-token counters increase.
8. Run heterogeneous mixed prefill/decode traffic at sequence counts 1–4.
9. Run 128K and 262K retrieval probes without prefix caching.
10. Restart once at `restart=no`, repeat deterministic and state-safety probes, then soak.

Top-k repeatability, selected-set exactness, QSA output determinism, recurrent-state
safety, language quality, and prefix-cache equivalence are separate gates. A pass in
one does not imply another.

## Qualification outcome

Runtime and state-safety qualification passed, including cold/warm 10/10 deterministic
prefill, MTP3 activity, 120K and 248K retrieval, four-way mixed traffic, and a
30-minute/3,700-request soak with zero errors or restarts. The candidate was not
promoted because exact-instruction, tool-call, and synthetic red-image quality checks
failed. See
[`2026-09-01-qwen38-flash-next-v2-safe.md`](../../benchmarks/vllm-tps/2026-09-01-qwen38-flash-next-v2-safe.md)
for the complete receipt and attribution boundary.

## Rollback

The v1 image and launcher remain unchanged. To abandon v2:

```bash
scripts/inference/qwen38/switch-qwen38-flash-next-profile-v2.sh stop
scripts/inference/qwen38/switch-qwen38-flash-next-profile-v1.sh start
```

If GLM v10 was the previously active profile, the transactional v2 switcher restores
that existing container automatically on any v2 verifier, startup, or acceptance
failure. Do not enable prefix caching during rollback or qualification.
