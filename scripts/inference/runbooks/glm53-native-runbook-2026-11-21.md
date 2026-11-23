# GLM-5.3 full (753B) on ds4-native — runbook (2026-11-21)

GLM-5.3 full (753B MoE, 78 layers, 256 routed Experts a layer, top-8) on ds4-native's GLM engine
(`ds4n-glm53-serve`, repo `peterstorm/ds4-native`, branch `glm53/counter-eviction`) behind Project
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
Engine report with receipts: ds4-native `docs/bench/glm53-serve/2026-11-21-serve.md`; the speed
settings (eviction, Slot shape, VRAM reserve, λ): `docs/bench/glm53-counter/2026-11-22-frontier-report.md`;
Backbone C's build: ds4-native `docs/bench/glm53-backbone-c/`.

## Why this profile exists

The four other primaries are GLM-5.3 *Flash* builds and DeepSeek-V4.1-Flash. This one is the full
GLM-5.3: about 20x the routed Expert weight of Flash, too large for two 96 GB GPUs. ds4-native
already streamed DeepSeek's Experts from the NVMe; the GLM engine applies the same idea to a model
whose Experts (375 GiB in MXFP4) are four times VRAM. It is slow (6-7 tok/s served on 2026-11-21;
~8 tok/s measured on the engine with the 2026-11-22 settings) and is served for quality, not speed.

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

- Engine `DS4N_COMMIT=d398fae043df6e50e5023bb3d463b533d558591d` (branch `glm53/latent-split`: the
  Latent split, each GPU holding half the KV cache's Latent rows, bit-identical (ds4-native
  `docs/bench/glm53-split/2026-11-23-split-report.md`); on `glm53/deferred-misses`' Loads on CUDA
  events and `--defer`, on `glm53/counter-eviction`'s Cohorts, GLM Ledger, `--eviction`,
  `--slot-profile`, `--runtime-reserve-gib`; before it `1ceb9d49bf`, `fec4e0c1d1`, and before that
  `6866989971`, sessions `min_lost` 16). `--install` fetches `~/dev/ds4-native`'s origin, builds that
  commit in `ds4-native-dev:2`, runs the core tests (17M Sessions assertions among them), installs
  the binary by commit.
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
| `CONTEXT` | 202752 | The Ledger plans every GPU allocation from the card's size, then fills the rest with Expert Slots: since the Latent split, 86 a layer at 202,752 (the launcher's maximum; the owner: enough for now) with the reserve below (64K: 95; `ds4n-glm53-ledger --capacity N --reserve-gib 2.25`; the engine opens 409,600 at 72). Raised from 65536 on 2026-11-23 (owner: "i needed that upped"); before the split, served at 202,752 (74 Slots) it decoded **6.84 tok/s** against 8.50 at 64K (−19.5%), and a 165,942-token prompt read at 448.7 tok/s and peaked at 95,166 MiB on GPU 0 (ds4-native `docs/bench/glm53-context/2026-11-23-context-cost.md`). Conversations longer than ~42K tokens do not fit `CHECKPOINT_GB`: one another request displaces is read again when it returns. |
| `LAMBDA` | 0.03 | **λ 0.03** cache-conditional routing for written tokens (owner's choice 2026-11-20): a resident Expert's score gets +λ before the top-8, so fewer Experts are read from the NVMe. Prompts route exactly. `LAMBDA=0` is the model's exact routing (with `SLOT_SHAPE=equal`). λ 0.035 and 0.04 were measured on 2026-11-22: +5-7% decode, but most positions' KL worse; rejected. |
| `EVICTION` | counter:55 | Each resident Expert keeps a use count, halved every 55 tokens; a miss evicts the lowest. ~10% faster than `lru` at λ 0.03; timing only at λ 0. |
| `RUNTIME_RESERVE_GIB` | 2.25 | VRAM a GPU keeps for what the Ledger does not plan (CUDA context, workspaces). 2.25 gave 92 Slots at 64K before the Latent split (the engine's 3.75: 90); a 39,200-token prompt at 92 peaked 1.7 GiB under the card. |
| `SLOT_SHAPE` | fitted | Spreads the Ledger's Slots over the Sparse layers by `glm53/glm53-native/slot-profile-l0.03-counter55.txt`: 4% fewer VRAM misses than `equal`, no measured KL cost. Fitted for λ 0.03 under counter:55 only; another λ or policy is refused unless `SLOT_SHAPE=equal`. |
| `DEFER` | 4 | Expert Deferral for written tokens (owner, 2026-11-23): an Expert that missed VRAM, outside the token's 4 heaviest of 8 Route slots, waits one Sparse layer, its read overlapping that layer's compute. +8.7% decode at equal reads; KL free (0.0699 vs 0.0710, paired), top-1 88.75% vs 89.57% (−23 of 2,800, p 0.15: at the 89% bar's edge, the owner's call). `2` and `0` are faster but cost real quality (KL +11% / +81%). `off` serves without it. Prompts never defer. |
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

The idle-GPU gate also keeps the Expert Slots reproducible. The engine's Ledger plans the Slots from
the card's size (CUDA's total rounded down to whole 256 MiB) and the runtime reserve, never from free
memory, and refuses to open if an allocation drifts from its plan or if less than 1 GiB is left after
opening. Something else on a GPU at launch makes the open fail instead of silently costing Slots.

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

## Measured on the engine (2026-11-22, the current settings; not yet through Maya)

`ds4n-glm53-decode` at 64K, λ 0.03, RAM tier 38, 256 tokens on each of the four corpus prompts (the
frontier report, receipts beside it):

| configuration | decode, pooled | teacher-forced misses | KL vs exact, top-1 |
|---|---|---|---|
| LRU, 90 equal Slots | 6.91 tok/s | 15.0% (84 Slots) | 0.068, 89.4% (84 Slots) |
| **counter:55, 92 fitted Slots (served)** | **7.95 tok/s** | **12.1%** | **0.071, 89.6%** |

KL differences under ~±0.004 between residency settings are re-rolled Routes, not quality (the
report's paired test). Gates: `--check` with these settings is bit-identical to the oracle on all 78
layers and the head; the 92-Slot open passes the Ledger's drift check. The first launch should record
the served decode speed here.

## Measured through Maya (2026-11-23 night, the Latent split at 202,752: the current settings)

`uncensored-native` at `9feeacf6` (engine `d398fae0`): ready in 78 s, **86 Slots** per Sparse layer
(profile), RAM tier 37, `deferral protect 4`; claims 34.21 GB a GPU (43.06 before the split), GPU 0
2.18 GB free after open. The same four chats (ds4-native
`docs/bench/glm53-context/2026-11-23-served-speed.sh`; receipt
`docs/bench/glm53-split/receipts/served-202752.out`), while another client's ~46K-token prompts ran
between them:

| reply | decode | store reads a token |
|---|---|---|
| B-tree balancing (first after open, cold) | 7.55 tok/s | 42.1 |
| ISO 8601 duration parser | 8.40 tok/s | 37.4 |
| the 1929 crash | 8.32 tok/s | 36.6 |
| TLS 1.3 key exchange | 8.43 tok/s | 35.0 |
| **pooled** | **8.16 tok/s** | 37.8 |

Against **6.84 tok/s** (49.0 reads a token) at 202,752 before the split: **+19%**, close to the 64K
shape's 8.50 at 2.5× its context.

## Measured through Maya (2026-11-23, 64K, before the context raise)

`uncensored-native` at `70f446d3` (engine `1ceb9d49`): ready in 77 s, 92 Slots per Sparse layer
(profile), RAM tier 37, `deferral protect 4`; GPU 0 1.95 GB free after open. Four chats in turn, 300
tokens each, no reasoning (ds4-native `docs/bench/glm53-defer/2026-11-23-served-speed.sh`):

| reply | decode | store reads a token |
|---|---|---|
| B-tree balancing | 8.15 tok/s | 37.8 |
| ISO 8601 duration parser | 8.39 tok/s | 37.4 |
| the 1929 crash | 8.80 tok/s | 33.8 |
| TLS 1.3 key exchange | 8.68 tok/s | 34.0 |
| **pooled** | **8.50 tok/s** | 35.7 |

Against 6.2–7.1 served on 2026-11-21 (83 Slots, LRU) and the engine bench's 8.61 at 35.9 reads (below).
A 30-token prompt takes 6–7 s after the first (15.5 s cold), as before.

## Measured on the engine (2026-11-23, deferral)

The same shape, the four corpus prompts, compared at equal store reads (each setting writes its own
text under λ, so its own Misses: one common 2.34 ms a read, read at 35.9 reads a token; ds4-native
`docs/bench/glm53-defer/2026-11-23-defer-report.md`):

| `DEFER` | decode at equal reads | KL vs exact (paired vs off) | top-1 (paired vs off) |
|---|---|---|---|
| off (the reads on CUDA events: +1.8%, the same tokens) | 7.92 tok/s | 0.0710 | 2508 (89.57%) |
| **4 (served)** | **8.61 tok/s (+8.7%)** | **0.0699 (−1%, free)** | **2485 (−23, p 0.15)** |
| 2 | 9.03 tok/s | 0.0786 (+11%) | 2479 (−29) |
| 0 | 9.34 tok/s | 0.1284 (+81%) | 2406 (−102) |

Gates: `--check` with `--defer 0` (every Miss deferred) and without deferral are both bit-identical
to the oracle on all 78 layers and the head (ds4-native `1ceb9d4`).

## Pi

`pi/models.json` carries the three served ids (202,752 context, text, reasoning). The GLM guard gives
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
- 2026-11-22: speed settings (owner: "more speed at an acceptable quality loss"). Engine `fec4e0c1`:
  Cohorts and the Ledger (83 → 90 Slots at 64K), then `EVICTION=counter:55`, `SLOT_SHAPE=fitted`
  and `RUNTIME_RESERVE_GIB=2.25` (92 Slots): 7.95 tok/s on the engine against LRU-90's 6.91. λ stays
  0.03; 0.035 and 0.04 measured and rejected.
- 2026-11-23: deferral (owner: "go ahead with --defer 4"). Engine branch `glm53/deferred-misses`:
  Expert reads land on CUDA events (+1.8%, the same tokens), and `DEFER=4` defers a written token's
  low-ranked Misses one Sparse layer: 8.61 tok/s on the engine at equal reads against 7.92.
  Relaunched as `uncensored-native`: **8.50 tok/s served** through Maya.
- 2026-11-23: `CONTEXT` 65,536 → 202,752 (owner: "i needed that upped"): 74 Slots, 6.84 tok/s.
- 2026-11-23: the Latent split (owner: "serve the split, but we're fine at 200k for now"). Engine
  `d398fae0` (`glm53/latent-split`): each GPU holds half the Latent rows, bit-identical; 86 Slots at
  202,752; **8.16 tok/s served** (+19%).
