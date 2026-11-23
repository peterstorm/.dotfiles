# scripts/inference — index

The map for this folder. Three sources of truth, in this order of authority:

1. **Runbooks** (`runbooks/`, archived ones in `runbooks/archive/`) — *why*: rationale, measured
   decisions, history of a profile.
2. **Contract tests** (`../../tests/*-contract.sh`, `*-unit.py`) — *pins*: image digests, commits,
   file lists, flags. If a launcher and its contract disagree, the contract wins.
3. **Launchers** (this tree) — *executors*: they implement what the pins declare and the runbooks
   justify.

## Primaries (the models Pi offers)

One engine on both GPUs at a time; switch with
`switch-primary.sh [toggle|PRIMARY|status]`
([runbook](runbooks/switch-primary-runbook-2026-11-19.md)).

| primary | served id | engine | launcher | runbook | contract / unit tests | key pins |
|---|---|---|---|---|---|---|
| `glm` | `glm-5.3-flash-hyperflare-tp2-v16` | Hyperflare (AzallazA fork) | `glm53/switch-glm53-hyperflare-tp2-v16.sh` → `run-glm53-flash-hyperflare-tp2-v16.sh` (VARIANT=v16) | [v16 runbook](runbooks/glm53-flash-hyperflare-tp2-v16-runbook-2026-11-13.md) | `glm53-flash-hyperflare-tp2-v16-contract.sh` | image `peterstorm/glm53-hyperflare:ac9136b-cu131`, checkpoint `nvidia/GLM-5.3-Flash-FP4-Local@76348ddb`, package receipt |
| `uncensored` | `glm-5.3-flash-hyperflare-tp2-uncensored` | Hyperflare, same launcher (VARIANT=uncensored) | same switcher | v16 runbook + `glm53/hyperflare-variants.sh` header | same contract (variant table pinned) | dealignai NVFP4 `@745aac2` → `glm53-uncensored-convert.py` → export receipt |
| `warmind` | `warmind-1017-native` | ds4-native + Maya | `deepseek/ds41-1017-native/run-ds41-1017-native.sh` (WEIGHTS=warmind) | [ds41-1017-native runbook](runbooks/ds41-1017-native-runbook-2026-11-19.md) | `switch-primary-unit.sh`, ds4-native repo tests | engine `DS4N_COMMIT=d3274aa`, Maya `b3fa99ec`, WARMIND v1.1 `@a6382f22` |
| `deepseek` | `deepseek-v4.1-flash-native` | ds4-native + Maya, same launcher (WEIGHTS=deepseek) | same launcher | same runbook | same | DeepSeek `@1bae0e10` |
| `glm-native` | `glm-5.3-native` | ds4-native GLM engine (`ds4n-glm53-serve`) + Maya; GLM-5.3 full 753B, 64K, 8.5 tok/s served (2026-11-23; 6-7 before 2026-11-22); zai's stock Backbone | `glm53/glm53-native/run-glm53-native.sh` (WEIGHTS=stock) | [glm53-native runbook](runbooks/glm53-native-runbook-2026-11-21.md) | `glm53-native-contract.sh`, `switch-primary-unit.sh`, ds4-native repo tests | engine `DS4N_COMMIT=1ceb9d49`, Maya `b3fa99ec`, kitaniai Experts `@559df987`, zai BF16 `@abf42e6c`, λ 0.03, counter:55, fitted Slots, 2.25 GiB VRAM reserve, defer 4 |
| `uncensored-native` | `glm-5.3-uncensored-native` | same engine and container; dealignai's UNCENSORED Backbone (kitaniai's own) | same launcher (WEIGHTS=uncensored, its default) | same runbook | same | kitaniai `@559df987` |
| `cyber-native` | `glm-5.3-cyber-native` | same engine and container; dealignai's CYBERSECURITY Backbone; no toggle counterpart | same launcher (WEIGHTS=cyber) | same runbook | same | dealignai CYBERSECURITY `@5915c1b8` |

Engine code lives in its own repos, pinned by commit: `~/dev/ds4-native` (the engine; GitHub
`peterstorm/ds4-native`) and Project Maya (donor server, vendored checkout under `/models/ds41/`).
The dotfiles own deployment: launchers, pins, runbooks, contracts, systemd bridges.

## Runbook map (live)

| family | runbook |
|---|---|
| ds4-native | `ds41-1017-native-runbook-2026-11-19.md` (warmind + deepseek, the native engine), `glm53-native-runbook-2026-11-21.md` (GLM-5.3 full on its GLM engine) |
| glm53 | `glm53-flash-hyperflare-tp2-v16-runbook-2026-11-13.md` (v16 + uncensored variant; v14/v15 rollback sections inside), `glm53-flash-spark-tp2-v14-runbook-2026-09-19.md`, `glm53-flash-qad2-tp2-v15-runbook-2026-10-16.md`, `glm53-flash-exl3-k4-vllm-sm120-v10-runbook-2026-08-31.md` (exl3 rollback pin) |
| qwen38 | `qwen38-27b-runbook-2026-08-18.md`, dflash2 (runbook, official, vllm-official, tp1-bf16kv-v3), flash-next fp8 v1/v2, blackfrost bf16 |
| deepseek | `ds4-infernal-invocation-r18-runbook-2026-08-22.md` (r18 rollback), `ds4-flash-vision-r21-v1-runbook-2026-09-01.md`, `ds4-flash-vision-karmic-kraken-v1-runbook-2026-09-21.md`, `ds41-1017-maya-exl35-runbook-2026-10-21.md` (EXL3 predecessor) |
| ops | `new-desktop-install.md`, `gpu-inference-crash-triage.md` |
| creative (out of inference scope, kept here for one home) | `comfyui-*`, `minimax-h3-*`, `muse-*`, `local-ai-video-script-runbook.md`, `qwen-image-*`, `gaming-desktop.md`, `h3-motion-context-resize-v1.1.md` |

`archive/` holds runbooks of superseded versions and dated research/plan/trial notes (glm53 exl3
v1–v9, nvfp4-v2, the Maya Q8 trial, qwen38 topk research, exl3 5.05bpw plan, v2 safety plan,
dflash2 candidate trial). They are records of their date — paths inside them are not rewritten.

## Conventions

- **A variant is not shippable until its runbook exists in the same commit.** New launcher + new
  contract test + new (or updated) runbook, or the switcher refuses it in review.
- Every launcher sources `shared/inference-api-key.sh`; the API key never enters Docker arguments
  or inherited environment (see the README below for the full list).
- Runbook file names carry their date: `<profile>-runbook-<yyyy-mm-dd>.md`. A new deployment of
  the same profile appends a section to the existing runbook; a new engine or storage generation
  gets a new file.
- The primaries table above is the only place that has to stay current; everything else may lag
  one version, `archive/` never has to be updated.
