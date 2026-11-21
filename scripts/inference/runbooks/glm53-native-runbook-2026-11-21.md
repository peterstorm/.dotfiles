# GLM-5.3 full (753B) on ds4-native — runbook (2026-11-21)

Primary `glm-native`, served id `glm-5.3-uncensored-native`: kitaniai's
`GLM-5.3-UNCENSORED-MXFP4` (GLM-5.3 full, 753B MoE, 78 layers, 256 routed Experts a layer, top-8)
on ds4-native's GLM engine (`ds4n-glm53-serve`, repo `peterstorm/ds4-native`, branch
`glm53/engine-core`) behind Project Maya's OpenAI-compatible server on `:8000`.

Launcher: `scripts/inference/glm53/glm53-native/run-glm53-native.sh`.
Contract: `tests/glm53-native-contract.sh`. Switch: `switch-primary.sh glm-native`.
Engine report with receipts: ds4-native `docs/bench/glm53-serve/2026-11-21-serve.md`.

## Why this profile exists

The four other primaries are GLM-5.3 *Flash* builds and DeepSeek-V4.1-Flash. This one is the full
GLM-5.3: about 20x the routed Expert weight of Flash, too large for two 96 GB GPUs. ds4-native
already streamed DeepSeek's Experts from the NVMe; the GLM engine applies the same idea to a model
whose Experts (375 GiB in MXFP4) are four times VRAM. It is slow (6-7 tok/s) and is served for
quality, not speed.

## Layout on desktop

| what | where |
|---|---|
| Expert store (all 78 layers' routed Experts, one file) | `/models/glm53-store/experts.ds4n` (dataset `rpool/models/glm53-store`, recordsize 1M, compression zle) |
| Backbone A (kitaniai's own dense weights, 88 parts) | `/models/glm53-store/backbone-uncensored/` |
| Backbone B (dealignai CYBERSECURITY edits on A, 124 tensors) | `/models/glm53-store/backbone-cyber/` + `VARIANT.json` |
| checkpoint metadata (config, tokenizer, template) | `/models/glm53-native/kitaniai/` (revision `559df987`) |
| engine binary per commit | `/models/glm53-native/serve/bin/ds4n-glm53-serve-<commit12>` (+ `.commit`) |
| tokenizer in Maya's form | `/models/glm53-native/serve/tokenizer/` |
| server config (rewritten each launch) | `/models/glm53-native/serve/glm53-native.json` |
| engine + server log | `/models/glm53-native/serve/glm53-native.log` |
| Maya server (shared with the DS4.1 launcher) | `/models/ds41/native/maya-b3fa99ec244e-<patch12>/` |
| API key env for the container | `~/.config/glm53-native/server.env` |

## Pins

- Engine `DS4N_COMMIT=686698997171a6264b9004f6708497c4209930a0` (sessions `min_lost` 16). `--install`
  builds it from that commit of `~/dev/ds4-native` in `ds4-native-dev:2`, runs the core tests
  (17M Sessions assertions among them), installs the binary by commit.
- Tokenizer: `--install` runs ds4-native `tools/glm53-serve/write_tokenizer.py` on the checkpoint's
  `tokenizer.json` with `--check`: Maya's tokenizer and HF `tokenizers` agree id for id over 36
  texts (28,223 ids, 0 differ), including chats rendered by both templates.
- Maya `b3fa99ec` + `deepseek/ds41-1017-native/maya-serve-keepalive.patch`: the same patched copy
  as the DS4.1 launcher (keyed by commit and patch hash; whichever installs first builds it).
- Backbone provenance at every launch: A has 88 parts and no variant record; `WEIGHTS=cyber`
  requires `VARIANT.json` naming `dealignai/GLM-5.3-CYBERSECURITY-FP8@5915c1b8` built on A.

## Settings (and why)

| setting | default | why |
|---|---|---|
| `CONTEXT` | 65536 | Each 1K positions cost ~0.2 GB VRAM a GPU, about a quarter of a VRAM Slot per Sparse layer; 64K leaves 83 Slots per layer (16K: 97). |
| `LAMBDA` | 0.03 | **λ 0.03** cache-conditional routing for written tokens (owner's choice 2026-11-20): a resident Expert's score gets +λ before the top-8, so fewer Experts are read from the NVMe. Prompts route exactly. `LAMBDA=0` is the model's exact routing. |
| `RAM_RESERVE_GIB` | 10 | The RAM tier pins what is available at load less this and the checkpoints; the reserve keeps the OS and ZFS ARC (capped at 4 GiB) alive. Pinned RAM wedged this host once. |
| `CHECKPOINT_GB` | 4 | Host RAM for conversations set aside (~95.2 KB a token: ~42K tokens). |
| `REASONING_EFFORT` | high | GLM's template default is max; at a few tok/s max is hours. A request's own effort wins. |
| `THINKING_BUDGET` | 8192 | Maya closes reasoning there and the model answers (~20-30 min of thinking at most). |
| sampling | T 1.0, top_p 0.95, rep 1.1 | the checkpoint's `generation_config.json`. |

## Operate

```bash
# once per engine commit (no GPUs needed)
scripts/inference/glm53/glm53-native/run-glm53-native.sh --install
# check every pin
scripts/inference/glm53/glm53-native/run-glm53-native.sh --preflight
# make it the primary (idle gate, stop the current primary, wait for free GPUs, launch, roll back on failure)
scripts/inference/switch-primary.sh glm-native
# from Pi
/switch glm-native
```

`switch-primary.sh toggle` refuses on `glm-native`: GLM-5.3 full has no stock build here, so it has
no stock/uncensored counterpart. Name the primary to leave it.

Loading takes ~80 s (the Backbone, the VRAM Slots, then the RAM tier's pinning). The launcher waits
until `/v1/models` lists the served id, then promotes the container to `restart=unless-stopped`.

The cyber Backbone serves with `WEIGHTS=cyber scripts/inference/glm53/glm53-native/run-glm53-native.sh --launch`
as `glm-5.3-cyber-native`. It is not a primary: Pi's catalog does not offer it, and the switcher
counts the container serving it as foreign (`other:glm53-native`). Stop it by hand.

## Gates (as the DS4.1 launcher)

comfyui stopped; exactly two idle RTX PRO 6000s (≤ 1 GiB used each); no other running `glm53-*`
container (the RAM tier must not share host memory with a CPU replay or another load); port 8000 free.

The idle-GPU gate also keeps the Expert Slots reproducible. GLM's engine has no Ledger yet: it sizes
its Slots from the VRAM still free after everything else is loaded (83 per Sparse layer at 64K, the
same on every launch so far). Anything else on a GPU at launch would silently cost Slots, and so
speed (ds4-native plan, Phase 4).

## Measured (2026-11-21, 64K, λ 0.03, through Maya)

| case | result |
|---|---|
| load | 79-83 s: 83 Slots per Sparse layer, RAM tier 37-38 records per layer |
| first chat (30-token prompt, cold) | prompt 14.3 s; 67 tokens at 6.81 tok/s |
| 4,519-token prompt | read at 197 tok/s (22.9 s); reply 399 tokens at 6.23 tok/s; 12.9% of Expert reads missed VRAM (11,568 RAM tier, 19,355 NVMe); 54 of 64 s waiting on reads |
| reasoning request (effort high) | 366 tokens at 7.05 tok/s; `reasoning_content` parsed |
| next turn of a chat | X2 reused 102 of 114 prompt tokens (12 read, 3.1 s) |
| another conversation, then back | Y set X aside (141 tokens); X3 resumed at 141 of 149 (8 read, 2.2 s) |
| a conversation branching from a held one | C shares 10 template tokens with D: D stays held; D2 resumed 44 of 52 |
| client disconnect mid-stream | engine cancelled after 39 tokens |
| bit-exactness (ds4n-glm53-serve-check) | save/rewind/restore and resumed turns: 0 of ~46.5M logits differ from reading again |

Receipts: ds4-native `docs/bench/glm53-serve/` (`2026-11-21-maya-e2e-engine.err.txt`,
`2026-11-21-maya-e2e-responses.jsonl`, `2026-11-21-servecheck.*`, `2026-11-21-serve-smoke.*`).

Short prompts cost seconds whatever their length: a prompt sweep reads every Expert any of its
tokens routes to, so 27 tokens read ~as many Experts as a few hundred.

## Pi

`pi/models.json` carries `glm-5.3-uncensored-native` (64K context, text, reasoning). The GLM guard
gives it the tuned-build profile (its id contains `uncensored`), which is inert here: Maya forwards
only `enable_thinking` and `reasoning_effort` from `chat_template_kwargs` and reads no
`thinking_token_budget`. Maya's own `thinking_budget` (8192) bounds reasoning, and past reasoning
stays in the prompt, so a chat's next turn is a pure append to the cached tokens.

## Monitoring

The ds4-native metrics bridge (`:8010`) is engine-agnostic and labels series with the served id:
`ds4:*{model_name="glm-5.3-uncensored-native"}`.

## Troubleshooting

- `engine ... is not installed`: run `--install` (the binary is keyed by `DS4N_COMMIT`).
- `glm53-* containers are running`: a Hyperflare GLM primary is up; switch with `switch-primary.sh`, which stops it first.
- The engine exits 2 with `failed` lines in the log: a Decoder (CUDA) failure; the caches and Slots
  may disagree, so the engine does not continue. Maya starts it again at the next request
  (`[maya] the engine had stopped (exit code 2); starting it again`, ~80 s) and the held
  conversations are gone. Read `glm53-native.log` for the failure; a repeat needs the engine fixed.
- A request answered `ERR ... not finite`: that request's logits were NaN/Inf; its conversation was
  dropped and the engine stays up.

## History

- 2026-11-21: first served. Sessions bug found in the e2e run (a restored Checkpoint sharing only
  template tokens was freed, losing that conversation) and fixed in the planner (`26ea3db`);
  `min_lost` 64 → 16 (`6866989`) because short conversations were never kept. Primary `glm-native`
  added to `switch-primary.sh`, the profile catalog and Pi.
