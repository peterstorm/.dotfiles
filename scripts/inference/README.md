# scripts/inference

Deployment scripts for the workstation's GPU inference endpoints. All of them run
on `desktop` (the two-RTX-PRO-6000 box), never on this dev machine. The runbooks
in `docs/runbooks/` are the source of truth for rationale; the contract tests in
`tests/` are the source of truth for the pins.

Layout (by model, then by role):

```
qwen38/    Qwen3.8 profiles: 27B BF16 downloaders and launchers, DSpark,
           locally validated DFlash2, digest-pinned official SGLang/vLLM v2
           profiles, and a vLLM TP1/BF16-KV v3 profile pinned to physical GPU0
           so physical GPU1 remains available to ComfyUI. The isolated
           Flash-Next FP8 TP2 profile offloads its 51.2B N-gram embedding to
           host RAM and uses a hash-gated exact-top-k3 overlay because the stock
           family-12 QSA kernel is non-deterministic. Existing 27B launchers remain validated rollback pins.
deepseek/  DeepSeek-V4-Flash-0731 r18 rollback plus the source-guarded
           DeepSeek-V4-Flash-Vision-Exp r21 overlay, downloader, launcher,
           transactional switcher, and target/fixed-K6 qualification probes.
glm53/     GLM-5.3-Flash profiles: immutable NVFP4 and EXL3 K4 checkpoints,
           digest-pinned custom vLLM SM120 images, a multimodal 262K NVFP4 TP2
           profile, a conservative 128K/C1 EXL3 rollback, an upstream-aligned
           v37 500K/C4/MTP3 text candidate, isolated v84 98K multimodal
           TP2/EP2/DCP2 rollback profiles for DFlash2-7 or built-in MTP3, a
           v84 384K multimodal MTP3 profile with 625,112-token cold and
           1,129,235-token warm NVFP4 capacity, an isolated text-only v6 using FP8 DS
           MLA KV, FlashInfer SM120 sparse MLA, InstantTensor, prefix caching,
           and MTP3, plus multimodal NVFP4 v7 with prefix caching and a 512-token
           long-prefill fairness cap. v6 measured 403,989 tokens on its cold JIT-cache
           boot and 737,953 after cache warmup, reproducing the roughly 700K claim;
           v7's cache correctness and latency remain unqualified.
shared/    Components more than one profile uses: the credential helper every
           launcher sources, the secret-safe SGLang entrypoint, GPU telemetry
           recording, throughput probing, the durable vLLM/SGLang/ds4-native
           stats recorder/heatmap, and the ds4-native Prometheus bridge
           (systemd units in machines/desktop/default.nix).
```

Conventions:

- Every launcher sources `shared/inference-api-key.sh` (via
  `$SCRIPT_DIR/../shared/inference-api-key.sh`) and never puts the API key in
  Docker arguments or the environment it inherits.
- Launchers fail closed: checkpoint pins, GPU power caps, port conflicts, and
  display-manager state are checked before anything is stopped or started.
- Monitoring never sits on the inference hot path. Engines expose Prometheus
  counters; `vllm-stats-record.py` turns per-interval deltas into the durable
  ledger, and `ds4-native-metrics.py` polls Maya's cached `/metrics` on :8000
  and re-exposes it model-labelled on :8010. Neither writes to an engine's
  stdin or asks it to compute anything, so prefill and decode are unaffected.
  The bridge takes DSpark acceptance from the engine's live STAT kept/verified
  ratio because the pinned Maya copy omits per-request draft counts from its
  history rows.
- Image and model revisions are pinned by digest/rev and asserted by the
  `tests/*-contract.sh` static contracts — change a pin and its contract in
  the same commit. Derived images additionally prove their pinned official-base
  rootfs prefix, exact overlay/config digest, and required runtime source markers.
- Qwen3.8 Flash-Next is experimental until its open-PR vLLM image, PLE RAM
  offload, TP2 capacity, multimodal, context, MTP, and soak gates pass.
- GLM-5.3 is experimental until its dated runbooks' SM120, capacity,
  correctness, tool-use, context, and soak gates pass. The EXL3 image has an
  additional publicly unreconstructible overlay-provenance limitation. Qwen
  remains unchanged; DS4 r18 remains the text-only rollback for the qualified
  r21 Vision candidate.
