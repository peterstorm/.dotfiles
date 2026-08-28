# scripts/inference

Deployment scripts for the workstation's GPU inference endpoints. All of them run
on `desktop` (the two-RTX-PRO-6000 box), never on this dev machine. The runbooks
in `docs/runbooks/` are the source of truth for rationale; the contract tests in
`tests/` are the source of truth for the pins.

Layout (by model, then by role):

```
qwen38/    Qwen3.8 profiles: 27B BF16 downloaders and launchers, DSpark,
           locally validated DFlash2, digest-pinned official SGLang/vLLM v2
           profiles, and an isolated Flash-Next FP8 TP2 profile whose 51.2B
           N-gram embedding is offloaded to host RAM. Existing 27B launchers
           remain validated rollback pins.
deepseek/  DeepSeek-V4-Flash-0731 (Infernal Invocation r18) downloader + launcher.
glm53/     GLM-5.3-Flash profiles: immutable NVFP4 and EXL3 K4 checkpoints,
           digest-pinned custom vLLM SM120 images, a multimodal 262K NVFP4 TP2
           profile, a conservative 128K/C1 EXL3 rollback, an upstream-aligned
           v37 500K/C4/MTP3 text candidate, isolated v84 98K multimodal
           TP2/EP2/DCP2 rollback profiles for DFlash2-7 or built-in MTP3, a
           v84 384K multimodal MTP3 candidate backed by measured 830K-token
           NVFP4 KV capacity, and an isolated text-only v6 reproduction using
           FP8 DS MLA KV, FlashInfer SM120 sparse MLA, InstantTensor, prefix
           caching, and MTP3. The v6 author's roughly 700K-token capacity claim
           remains unqualified until its first local boot.
muse/      Muse Glimmer 30B (BF16 + DFlash) downloader + launcher.
profiles/  Cross-model profiles (the concurrent Qwen + Muse dual switcher).
shared/    Components more than one profile uses: the credential helper every
           launcher sources, the secret-safe SGLang entrypoint, GPU telemetry
           recording, throughput probing, and the durable vLLM/SGLang stats
           recorder/heatmap (systemd units in machines/desktop/default.nix).
```

Conventions:

- Every launcher sources `shared/inference-api-key.sh` (via
  `$SCRIPT_DIR/../shared/inference-api-key.sh`) and never puts the API key in
  Docker arguments or the environment it inherits.
- Launchers fail closed: checkpoint pins, GPU power caps, port conflicts, and
  display-manager state are checked before anything is stopped or started.
- Image and model revisions are pinned by digest/rev and asserted by the
  `tests/*-contract.sh` static contracts — change a pin and its contract in
  the same commit. Derived images additionally prove their pinned official-base
  rootfs prefix, exact overlay/config digest, and required runtime source markers.
- Qwen3.8 Flash-Next is experimental until its open-PR vLLM image, PLE RAM
  offload, TP2 capacity, multimodal, context, MTP, and soak gates pass.
- GLM-5.3 is experimental until its dated runbooks' SM120, capacity,
  correctness, tool-use, context, and soak gates pass. The EXL3 image has an
  additional publicly unreconstructible overlay-provenance limitation. Qwen
  and DS4 remain unchanged rollback profiles.
