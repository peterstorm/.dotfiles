# Qwen3.8-27B DFlash2 on official vLLM — 2026-08-25

## Verdict

DFlash2 is now merged upstream in vLLM and documented in the official Qwen3.8
recipe. A custom source build is no longer the preferred artifact.

Use the new, isolated profile:

```bash
bash scripts/inference/qwen38/download-qwen38-27b-dflash2-v2.sh
bash scripts/inference/qwen38/pull-qwen38-dflash2-vllm-v2-image.sh
bash scripts/inference/qwen38/switch-qwen38-backend-v4.sh dflash2-vllm-official
```

The old `dflash2-vllm` mode, PR-head image, build script, GHCR workflow, cache,
env file, and measured benchmark receipt remain intact as rollback evidence.

**Qualification status:** statically verified only. The desktop was not contacted
while this profile was prepared, so the official image has not been pulled or
GPU-qualified locally.

## What changed upstream

1. vLLM PR [#52816](https://github.com/vllm-project/vllm/pull/52816), native
   DFlash2 support, merged on 2026-08-21 as
   `b389ac29465b33f9e9c534df221ea3c129e9793f`.
2. The official vLLM recipes PR
   [#837](https://github.com/vllm-project/recipes/pull/837) merged on 2026-08-24.
   It documents `incoai/Qwen3.8-27B-DFlash2`, method `dflash`, and seven
   speculative tokens for Qwen3.8-27B.
3. PR [#52560](https://github.com/vllm-project/vllm/pull/52560) accidentally
   removed DFlash2's decoder-layer extension point on 2026-08-22. The 08-24
   nightly therefore advertises DFlash2 but cannot load its convolution weights.
4. PR [#53435](https://github.com/vllm-project/vllm/pull/53435) restored that
   extension point and added a regression test. It merged on 2026-08-25 as
   `a9a17e7095a66ef6c6685a1c7ddd657781a78d3c`; the official nightly built
   directly from that commit is the pin used here.

The old local image stops at PR commit `66e5414c`; upstream merged final head
`3406ec1d`. The merged series additionally takes candidate top-k from vLLM's
logits processor, removes a redundant draft-logits fill, carries the reviewed
test corrections, and supports quantized target heads. The selected nightly
also includes #52193's TP>1 speculative workspace sizing, directly relevant to
this TP2 profile.

Latest stable vLLM is still `v0.27.1` from 2026-08-11 and predates DFlash2.
The special official `vllm/vllm-openai:qwen38` image is source commit
`3a0914114705fa38d4c3171d0746c1a6b6f10209`, also before DFlash2. “Official”
here means an official immutable nightly, not a stable release.

## Immutable artifact

| Item | Pin |
|---|---|
| Image tag | `vllm/vllm-openai:nightly-a9a17e7095a66ef6c6685a1c7ddd657781a78d3c` |
| Multi-platform digest | `sha256:3578c1fa6a9676e1de068b9d75c777cc865d251fadfbe6175ae82278739c6674` |
| Linux/amd64 manifest | `sha256:2786e1d3301cb1039a3695c20aafd15b608adefd4c8380c2ed1457b24813c4a4` |
| Embedded source label | `a9a17e7095a66ef6c6685a1c7ddd657781a78d3c` |
| Created | `2026-08-25T05:21:44Z` |
| Build receipt | <https://buildkite.com/vllm/release-v2/builds/5600> |
| Official recipe revision | `e3c120d2b692f6bf99bf1ae5b0e8b6ed1aadafe7` |
| CUDA architecture list | includes `12.0` for RTX PRO 6000 Blackwell |

The launcher pins the multi-platform registry digest, checks
`ai.vllm.build.commit`, imports the target registry and DFlash2 speculator, and
inspects `DFlashQwen3Model` to prove the #53435 layer-class fix is present.
Merely finding `DFlash2DraftModel` in the registry is insufficient: broken
nightlies have that registration too.

## Qwen and draft audit

Neither checkpoint needs a new download version:

| Checkpoint | Current upstream head | Result |
|---|---|---|
| `Qwen/Qwen3.8-27B` | `1d4bf0f2ff6012fd82039f2fa52739d0dd7c60c0` | Already pinned locally; config and chat template unchanged |
| `incoai/Qwen3.8-27B-DFlash2` | `dedf8df68adfb1afeaf7b7480c0a0243108177b4` | Already pinned by the v2 downloader |

The target's model card now links the official vLLM recipe, but the model,
tokenizer, template, and generation configuration have not moved. Tool parser
`qwen3_coder`, reasoning parser `qwen3`, thinking defaults, and the official
thinking sampling set remain correct.

The merged recipe currently requires seven speculative tokens: DFlash2 block
size eight minus the bonus position. Recipes PR #839 proposes five only as a
Hopper performance choice. RTX PRO 6000 is SM120 Blackwell, so this profile
keeps seven and makes the depth non-configurable to avoid persisted graph/cache
collisions across shapes.

## Profile shape

`run-qwen38-27b-bf16-dflash2-vllm-v2.sh` intentionally keeps the locally
measured vLLM DFlash2 quality shape:

```text
weights / KV:              BF16 / BF16
GDN state:                 FP32
TP:                        2
physical GPU order:        1,0
native context:            262144
max sequences:             8
max batched tokens:        4096
GPU memory utilization:    0.92
DFlash2 speculative depth: 7 (fixed)
attention:                 FlashInfer
prefix cache:              enabled
chunked prefill:            enabled
```

This is deliberately not the open recipes PR #831's TP1 RTX PRO 6000 MTP
profile. Keeping TP2 and the old admission settings isolates the official
engine update in the first A/B. Tune TP, batching, or precision only after that
receipt exists.

The new profile has its own:

- container: `qwen38-27b-bf16-dflash2-vllm-v2`;
- cache: `/models/vllm-cache/qwen38-bf16-dflash2-official-v2`;
- private env file: `~/.config/qwen38/vllm-dflash2-official-v2.env`;
- switch mode: `dflash2-vllm-official`;
- fallback: the previously measured `dflash2-vllm` PR image.

The API key remains env-file-only. The launcher validates checkpoint geometry,
image provenance, both GPU caps and idle memory, archives old container logs,
and rejects a foreign listener on port 8000 before launch.

## Open upstream risks

Do not promote this profile solely because the artifact is official:

- [#53477](https://github.com/vllm-project/vllm/issues/53477): DFlash2 may
  reprocess context on every multi-turn reply despite prefix caching. This is a
  direct agent-workload risk and must be measured with repeated shared-prefix
  turns.
- [#53366](https://github.com/vllm-project/vllm/issues/53366) /
  [#53292](https://github.com/vllm-project/vllm/pull/53292): speculative depth
  is not yet safely isolated in every persisted compile/startup cache key. This
  profile fixes depth at seven and uses a new cache root.
- [#53612](https://github.com/vllm-project/vllm/issues/53612): full-vocabulary
  draft initialization can transiently OOM 24-GiB cards. It does not reproduce
  the previous TP2/96-GiB shape, but startup memory still belongs in the gate.
- [#53628](https://github.com/vllm-project/vllm/pull/53628) is ROCm-specific;
  this CUDA profile is unaffected.
- Quantized-drafter issues #51581/#53122 do not apply: this profile uses the
  canonical BF16 drafter.

## First desktop qualification

1. Run `download-qwen38-27b-dflash2-v2.sh`; it verifies/reuses the canonical
   weights and installs the Inco AI revision marker required by the launcher.
2. Pull and verify the digest with `pull-qwen38-dflash2-vllm-v2-image.sh`.
3. Confirm both GPUs are idle and capped at or below 450 W.
4. Launch `switch-qwen38-backend-v4.sh dflash2-vllm-official`.
5. Require log evidence for `Qwen3_5ForConditionalGeneration`,
   `DFlash2Qwen3ForCausalLM`, native block size eight, and no missing
   `attention_conv` / `mlp_conv` weights.
6. Pass authenticated text, image, low/medium/xhigh reasoning, automatic/named/
   required tool calls, streaming, and malformed-tool recovery.
7. Record `vllm:spec_decode_num_{drafts,accepted}_tokens_total`; compute
   effective acceptance length. Near 1.0 is a wiring failure.
8. A/B against the old immutable PR image with identical prompts and settings at
   concurrency 1 and 8. Record TTFT, TPOT, emitted tok/s, aggregate tok/s,
   acceptance, preemptions, and useful KV capacity.
9. Run a multi-turn shared-prefix ladder. Compare per-turn cached-token counts,
   prefill tokens, and TTFT to target-only and MTP controls. Any full-context
   reprocessing reproduces #53477 and blocks promotion for Pi.
10. Run 32K/108K/262K needles and the sustained tool-use soak while monitoring
    Xids, OOMs, NCCL failures, restarts, and the durable inference ledger.
11. Promote only if it beats or materially de-risks the old PR artifact. Until
    then, `dflash2-vllm` remains the vLLM fallback and SGLang remains the active
    production family.

Static contract:

```bash
bash tests/qwen38-dflash2-vllm-official-v2-contract.sh
```
