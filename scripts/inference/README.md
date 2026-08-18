# scripts/inference

Deployment scripts for the workstation's GPU inference endpoints. All of them run
on `desktop` (the two-RTX-PRO-6000 box), never on this dev machine. The runbooks
in `docs/runbooks/` are the source of truth for rationale; the contract tests in
`tests/` are the source of truth for the pins.

Layout (by model, then by role):

```
qwen38/    Qwen3.8-27B profiles: downloaders, the vLLM BF16 launcher, the two
           experimental DSpark launchers (SGLang and vLLM), and the
           SGLang<->vLLM backend switcher for :8000.
           -v2 files in this folder are the 2026-08-18 upstream-updated
           versions (see docs/research/2026-08-18-qwen38-upstream-update-research.md);
           the un-suffixed files remain the validated 2026-08-16 pins.
deepseek/  DeepSeek-V4-Flash-0731 (Gilded Gnosis r33) downloader + launcher.
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
  the same commit.
