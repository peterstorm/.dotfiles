# Qwen3.8 Flash-Next FP8 vLLM v2 source-safe qualification

**Result:** runtime and state-safety gates passed; semantic quality gate failed; not promoted

## Identity

| Item | Value |
|---|---|
| vLLM source | `e126687a9a828d513c01a07cd69f025f27d63280` |
| Base source overlay | `815d965f7ccddd6a2b2da072a4a492115fc3a7e1` |
| Repaired source overlay | `c0ac28980016af357df50359d301648352eebbf2` |
| Final image | `sha256:931c3c595e48f63c1900ee559966cad845673e37bdc2bd73ce5f49390a8154e1` |
| Rebuilt stable extension | `sha256:c7d4513f12740b58f01b6903128227d02bda7f6c1d1491a50f4e38955824ea95` |
| Checkpoint | `Qwen/Qwen3.8-Flash-Next-FP8@970c569adaca6b35532111fd6b27351b2baefe50` |
| Topology | TP2, NP2, MTP3 |
| Prefix caching | disabled |
| Restart policy | `no` |

The image was reconstructed from the public vLLM commit. No GLM binary was copied.
The complete base wheel was built first; `_C_stable_libtorch.abi3.so` was then rebuilt
from the final Qwen source tree after adding deterministic global token-index ordering
for multi-CTA boundary ties.

## Static and GPU verifier

The static proof passed installed-source hashes, image labels, Qwen4Exp registration,
UVA PLE capability, final build identity, and the stable-extension hash.

The standalone GPU verifier passed:

- exact selected values and repeatable selected sets at 65,536 columns, `k=512`,
  and rows 1, 32, 64, 192, and 512;
- deterministic lower-index selection for equal-score boundaries in the large
  multi-CTA path;
- crowded-bin overflow and CUDA Graph replay;
- QSA output equality against a `torch.topk` reference at rows 1/32/64/192/512;
- QSA equal-score output repeatability and CUDA Graph replay;
- CPU-proven complete/disjoint mixed GDN token partitions;
- fail-closed invalid accepted counts in causal-conv, selective-state, recurrent
  FLA, sigmoid-gating, and Qwen PLE short-conv paths;
- fail-closed invalid Qwen PLE decode, prefill, and speculative state rows.

The verifier exposed and caused repair of a gap in the PR #52149-derived patch: its
single-CTA overflow fallback was exact, but the persistent large-row path still used
a global atomic to select equal-score pivot elements across CTAs. The final Qwen patch
publishes per-CTA equal counts, derives a CTA prefix in token-range order, and ranks
matches within each chunk by warp ballot.

## Live runtime evidence

Startup resolved `Qwen4ExpForConditionalGeneration` and `Qwen4ExpMTP`. Both TP workers
reported the PLE embedding as FP8, CPU-resident, and pinned. The runtime exposed
1,513,483 KV tokens and 5.77x maximum concurrency at 262,144 context. Authenticated
readiness passed with zero restarts.

- Cache-isolated greedy prefill: identical top-20 vector for 10/10 launches before
  restart and 10/10 after a manual stop/start cycle.
- MTP: counters increased to 381 drafts, 1,143 draft tokens, and 708 accepted tokens
  before the restart; all three accepted-position metrics were active.
- Long context: 120,032 prompt tokens completed in 11 seconds and retrieved the
  `QWEN-V2-NEEDLE-7391` needle.
- Near maximum context: 248,030 prompt tokens completed in 22 seconds and retrieved
  the `QWEN-V2-MAX-8827` needle.
- Mixed traffic: concurrent 1,013-, 8,013-, 32,013-, and 64,013-token requests all
  returned HTTP 200 with zero restart.
- Soak: 1,801 seconds, 925 four-request batches, 3,700 requests, zero HTTP/schema
  errors, zero matching CUDA/illegal-address/index-select/Xid/traceback log errors,
  and zero restarts.

## Independent quality gate

The runtime was not promoted because quality was inconsistent even though the safety
and repeatability gates passed.

Passed examples:

- raw completion answered that the capital of France is Paris;
- ordinary chat answered the same question correctly;
- long-context needle retrieval succeeded;
- the image request executed the multimodal path successfully.

Failed examples:

- an exact four-word instruction returned a generic greeting with thinking disabled;
- the same instruction with thinking enabled entered repetitive reasoning and exhausted
  512 tokens without an answer;
- a required `get_weather` tool invocation emitted prose and no tool call;
- a synthetic solid-red image was described as uniform but the model did not identify
  the color red.

These failures are recorded as a semantic/model-or-checkpoint integration gate, not a
top-k or recurrent-state failure. They must be compared against the immutable v1
rollback before deciding whether the source baseline, chat/tool templates, merged
Qwen implementation, or checkpoint behavior is responsible.

## Final state

The v2 container was stopped with restart count zero and restart policy `no`. The GLM
v10 container was restored healthy with restart count zero and restart policy `no`.
The immutable Qwen v1 image remains available at
`sha256:32a26fee4a4225b565017c36ce4f6589d716d608b59bbaa93c712a31a8433a32`.
