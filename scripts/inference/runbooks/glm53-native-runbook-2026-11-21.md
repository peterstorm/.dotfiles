# GLM-5.3 full (753B) on ds4-native — runbook (2026-11-21)

GLM-5.3 full (753B MoE, 78 layers, 256 routed Experts a layer, top-8) on ds4-native's GLM engine
(`ds4n-glm53-serve`, repo `peterstorm/ds4-native`, branch `glm53/engine-core`) behind Project
Maya's OpenAI-compatible server on `:8000`. Three primaries share the container `glm53-native`, the
Expert store (kitaniai's `GLM-5.3-UNCENSORED-MXFP4` Experts, which no surgery touches) and the
engine; each serves its own Backbone (the dense weights):

| primary | served id | `WEIGHTS` | Backbone |
|---|---|---|---|
| `glm-native` | `glm-5.3-native` | `stock` | zai's release (Backbone C) |
| `uncensored-native` | `glm-5.3-uncensored-native` | `uncensored` | kitaniai's own: dealignai's UNCENSORED surgery (Backbone A) |
| `cyber-native` | `glm-5.3-cyber-native` | `cyber` | dealignai's CYBERSECURITY surgery (Backbone B) |

Launcher: `scripts/inference/glm53/glm53-native/run-glm53-native.sh` (`WEIGHTS` defaults to
`uncensored`). Contract: `tests/glm53-native-contract.sh`. Switch: `switch-primary.sh glm-native`,
`switch-primary.sh uncensored-native`, `switch-primary.sh cyber-native`.
Engine report with receipts: ds4-native `docs/bench/glm53-serve/2026-11-21-serve.md`; Backbone C's
build: ds4-native `docs/bench/glm53-backbone-c/`.

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
| Backbone C (zai's stock weights for those 124 tensors on A) | `/models/glm53-store/backbone-stock/` + `VARIANT.json` |
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
  requires `VARIANT.json` naming `dealignai/GLM-5.3-CYBERSECURITY-FP8@5915c1b8` built on A, and
  `WEIGHTS=stock` one naming `zai-org/GLM-5.3-BF16@abf42e6c` built on A.

## Where the three Backbones come from

Both dealignai surgeries (CRACK) edit the same 124 tensors of zai's GLM-5.3: `self_attn.o_proj` in
layers 12-77 and `mlp.shared_experts.down_proj` in layers 20-77, the writers into the residual
stream. Their base is JANGQ-AI's FP8 of zai's BF16 (128×128 blocks, FP32 scale = amax / 448, codes
rounded to nearest-even E4M3). kitaniai converted the UNCENSORED one to MXFP4 (Quark) as A.

- B (cyber): the 124 CYBERSECURITY tensors through kitaniai's recipe onto a reflink of A.
- C (stock): the same 124 tensors re-made from zai's BF16 (`abf42e6c`) the way JANGQ made the
  surgeries' base, then kitaniai's recipe. The chain is proven: on the 29 tensors the surgeries
  leave alone (o_proj 0-11, shared down_proj 3-19), it reproduces A bit for bit. Each re-made
  tensor is cross-checked against zai's own FP8 release (a different quantizer): the build aborts
  under 95% identical E4M3 codes (measured ~99.9%).
- The routed Experts are zai's in all three: no surgery touches them.

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
# make one the primary (idle gate, stop the current primary, wait for free GPUs, launch, roll back on failure)
scripts/inference/switch-primary.sh glm-native          # stock
scripts/inference/switch-primary.sh uncensored-native   # uncensored
scripts/inference/switch-primary.sh cyber-native        # cyber
# from Pi
/switch glm-native
```

`switch-primary.sh toggle` swaps `glm-native` and `uncensored-native` (stock and uncensored, as for
the other engines). It refuses on `cyber-native`, which has no counterpart: name the primary to
leave it. Changing Backbone restarts the container (~80 s); the switcher reads which one serves
from the container's `served-model` label.

By hand, without the switcher (`--stop` first if another Backbone serves):

```bash
WEIGHTS=stock scripts/inference/glm53/glm53-native/run-glm53-native.sh --launch
WEIGHTS=uncensored scripts/inference/glm53/glm53-native/run-glm53-native.sh --launch
WEIGHTS=cyber scripts/inference/glm53/glm53-native/run-glm53-native.sh --launch
```

Loading takes ~80 s (the Backbone, the VRAM Slots, then the RAM tier's pinning). The launcher waits
until `/v1/models` lists the served id, then promotes the container to `restart=unless-stopped`.

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

`pi/models.json` carries the three served ids (64K context, text, reasoning). The GLM guard gives
`glm-5.3-uncensored-native` the tuned-build profile (its id contains `uncensored`) and the other two
upstream GLM's; both are inert here: Maya forwards
only `enable_thinking` and `reasoning_effort` from `chat_template_kwargs` and reads no
`thinking_token_budget`. Maya's own `thinking_budget` (8192) bounds reasoning, and past reasoning
stays in the prompt, so a chat's next turn is a pure append to the cached tokens.

## Monitoring

The ds4-native metrics bridge (`:8010`) is engine-agnostic and labels series with the served id:
`ds4:*{model_name="glm-5.3-native"}` (or `-uncensored-native`, `-cyber-native`).

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
- 2026-11-21: three Backbones, three primaries. Backbone C (zai's stock) built; `glm-native` now
  serves it as `glm-5.3-native`; the uncensored Backbone became `uncensored-native` (served id
  unchanged) and the cyber one `cyber-native`. The cyber surgery's FP8 delta (the download B was
  built from) was deleted for disk, owner-approved; B itself is kept.
