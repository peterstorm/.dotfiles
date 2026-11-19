# Pi Agent Configuration

This directory contains the pi coding agent configuration managed by home-manager. Files here are symlinked to `~/.pi/agent/` at activation time.

## Directory Structure

```
pi/
├── agents/           # Generic agents this repo owns (→ linked per file)
├── extensions/       # Custom extensions (→ ~/.pi/agent/extensions/)
│   ├── creative-project-scope/ # Trusted ~/dev/creative subtree resources
│   ├── glm-guard/    # Keeps a served GLM's reasoning from poisoning its own context
│   ├── monitor/      # Background monitors whose completion wakes the session
│   ├── model-routing/ # Pure child-model routing policy
│   ├── subagent/     # Generic subagent tool with skill injection
│   ├── global-instructions.ts  # Standalone extension
│   └── reload-runtime.ts       # LLM-callable parent-session reload with auto-continue
├── prompts/          # Prompt templates (→ ~/.pi/agent/prompts/)
├── skills/           # Global skills this repo owns (→ linked per skill dir)
│   └── impeccable/   # Impeccable design skill, pi-flavored v4.0.4 release
├── project-skills/   # Reviewed skills installed only into named projects
│   └── creative/     # Cinema skills → ~/dev/creative/.pi/skills/
├── models.json       # Custom providers/models (→ ~/.pi/agent/models.json)
├── model-routing.json # Local/cloud child routing policy (symlinked)
├── settings.json     # Pi settings (copied, not symlinked — mutable at runtime)
└── README.md         # This file
```

## How It Works

The nix home-manager module at `roles/home-manager/core-apps/pi/default.nix`:

1. **Extensions/Prompts**: directory-level symlinks:
   ```
   ~/.pi/agent/extensions → ~/.dotfiles/pi/extensions
   ~/.pi/agent/prompts    → ~/.dotfiles/pi/prompts
   ```
2. **Agents**: `~/.pi/agent/agents` is a **real directory**, populated at
   activation from two sources — see "Agents" below.
3. **Models**: Symlinks `~/.pi/agent/models.json` to the tracked custom-model catalog.
4. **Model routing**: Symlinks `~/.pi/agent/model-routing.json` to the tracked
   model classification/default policy.
5. **Skills**: `~/.pi/agent/skills` is a **real directory** (like `agents` — pi
   discovers skills there recursively, and other tools may add their own). Each
   skill under `pi/skills/` is linked per-directory:
   ```
   ~/.pi/agent/skills/impeccable → ~/.dotfiles/pi/skills/impeccable
   ```
   Drop a new skill directory (with a `SKILL.md`) into `pi/skills/` and it
   appears on the next activation — no rebuild. Stale links to removed skills
   are pruned.
6. **Creative project resources**: links four reviewed archive skills, MiniMax's
   revision-pinned official music-caption and H3 prompt-writing skills, and
   thirteen MIT-licensed authored production skills into `~/dev/creative/.pi/skills/`
   through Home Manager. The same project receives a revision-pinned MCP adapter
   setting and an allowlisted Blender MCP config. The global
   `creative-project-scope` extension exposes those resources only when the
   canonical cwd is `~/dev/creative` or a descendant; siblings and symlink escapes
   remain excluded.
7. **Settings**: Copies `settings.json` on activation (preserves `lastChangelogVersion`).

### Global skills (`pi/skills`)

`impeccable/` is the pi-compiled flavor of the [Impeccable design skill](https://github.com/pbakaus/impeccable)
(skill v4.0.4, Apache-2.0), vendored from the official release bundle served by
`npx impeccable install` — byte-identical to the upstream `skill-v4.0.4` tag's
`.pi/skills/impeccable`. To update: re-run the official installer in a sandboxed
HOME (`HOME=$(mktemp -d) npx -y impeccable@latest install --providers=pi --scope=global -y`)
and copy the resulting `~/.pi/agent/skills/impeccable` over `pi/skills/impeccable`,
keeping the vendored tree at the released tag rather than repo-main WIP.
Use it from pi as `/skill:impeccable` or just ask for a design pass.

### Creative project skills (`pi/project-skills/creative`)

The user-supplied, documentation-only cinema package has no bundled redistribution
license, so its text is not committed to this public repository. Nix fetches the
public Dropbox archive at the immutable archive hash recorded in
`pi/project-skills/creative/provenance.json`, then verifies every extracted file
against its own SHA-256 before Home Manager installs these third-party project-local
skills:

- `banana-pro-director-30`
- `character-builder`
- `cinema-director`
- `story-bible-builder` and its three relative reference documents

Nix also fetches MiniMax's official `music-caption-rewriter` and
`h3-prompt-writing` skills from exact MiniMax-Music3 and MiniMax-H3 revisions
and source hashes in the provenance file, including their relative assets under
the applicable upstream community licenses.

The repository owns thirteen MIT-licensed companion skills:

- `action-physics-production` — support, force, contact order, momentum,
  conditioning strategy, proof coverage, and sampled-frame action QA;
- `blender-previz` — MCP-assisted minimal camera, spacing, contact, and mechanism
  previsualization with contact-sheet gates and a model-agnostic blocking-video
  carrier handoff;
- `blocking-continuity` — normalized staging, screen direction, map qualification,
  and fail-closed spatial QA;
- `ensemble-action-production` — local-only Krea 2, MiniMax Music 3, and MiniMax H3
  production orchestration;
- `h3-prompt-distillation` — constraint ledger, channel allocation, and distillation
  of multi-skill shot contracts to H3's response budget before official formatting;
- `human-motion-realism-production` — evidence-informed gaze, blink, breathing,
  support, gesture, fidget, response-latency, and dense sampled-frame QA;
- `identity-realism-production` — mandatory Krea/Klein face A/B qualification and
  accepted high-fidelity identity handoff to production H3;
- `krea2-cinematic-still-production` — explicit asset modes, reference-role routing,
  physical camera contracts, photographic material direction, and fail-closed Krea still QA;
- `location-world-production` — location canon, personless plates, light contracts,
  look bible, ambient motion, and set-state continuity;
- `performance-direction` — playable actor and listener work with sampled-frame QA;
- `prop-continuity` — prop scale, mating geometry, action coverage, and semantic QA;
- `synthetic-voice-production` — immutable original VoiceAnchors, dialogue cloning,
  stem-safe singing conversion, versioning, and listening acceptance;
- `wardrobe-asset-production` — approved front/rear/detail packages, serialized
  lineage, immutable versions, and visible construction evidence.

These authored skills adapt model-agnostic production lessons without modifying or
republishing the unlicensed archive or uploaded reference text.

Start Pi at the root or in any project below it:

```bash
cd ~/dev/creative/productions/<project>
pi
```

Pi requires an applicable project-trust decision before the scoped extension
contributes skills or initializes MCP. Approve the creative root/parent trust only
after verifying the canonical path; use `/trust` if it should persist, then restart
Pi as instructed. The project-local package is
`nicobailon/pi-mcp-adapter@ff234b862359e722bf4dc1c99cde62278d4b8eb3`; its
Blender server launches lazily through `ssh desktop` and exposes only scene/object
inspection, viewport screenshots, and approval-gated code execution. Starting Pi
outside the canonical creative subtree does not discover these eighteen skills or
load Blender MCP. Pi's native `.pi/skills` lookup remains cwd-local in the pinned
runtime; `creative-project-scope` supplies the root skill path to trusted descendant
sessions and initializes the adapter with the root `.mcp.json`.

### Why Directory Symlinks?

Using a single symlink per directory (instead of per-file) means:
- **Adding new files needs no rebuild** — just create the file in the dotfiles repo
- **Edits are live immediately** — no `home-manager switch` needed
- **Removing files just works** — delete from repo, done
- **`home-manager switch` only needed** when the nix module itself changes

`agents/` is the exception, because it is not purely source — Loom generates
into it.

### monitor: background watches that wake the session (`extensions/monitor/`)

Long-running waits (a CI run, a build, a deploy, a file that eventually appears) must not
hold the turn: the `monitor` tool spawns the command under bash and returns immediately, so
the session stays interactive. When the command exits, the extension injects a message with
the exit code and the last 4 KB of output — steering the current turn or triggering one if
the session is idle — so the model can act on a green (or red) run without anyone watching
the terminal. The footer shows the running count (`ctx.ui.setStatus`); `/monitors` lists
every monitor on record and `/monitors cancel <name>` kills one; `monitor_cancel` is the
equivalent model-callable tool. Up to 8 monitors run at once.

The session journal is the durable state, so monitors survive `/reload` and session resume:
the tool journals a `monitor` entry carrying the full spec (pid, log and exit-code sidecar
paths) when it spawns, and each new extension instance re-adopts unfinished monitors at
`session_start` — polling live pids and verifying each against the monitor's argv marker
before trusting it (a recycled pid is classified as ended while pi was away, never
adopted; the `ChildProcess` handle died with the old instance, so the command's exit code
is recovered from the sidecar the spawn wrapper writes), and completing dead ones as
"ended while pi was not watching". Children deliberately outlive
`session_shutdown`: a CI watch surviving a session switch is the point, and the journal is
what makes that safe. The pure decision surface (journal projection, total parsing, tail
extraction, message formats) lives in `extensions/monitor/state.ts`; the shell owns
processes, files, timers and message injection.

Contracts: `pi/tests/monitor.test.ts` (unit), `pi/tests/monitor-regression.test.ts`
(repair pins for the pid-identity and process-tree-cancel criticals),
`pi/tests/monitor-spawn-failure.test.ts` (the spawn-failure completion arm),
`pi/tests/monitor-e2e.test.ts` (SDK
end-to-end against a fake model server, including the reload re-adoption and missed-completion
paths) and `tests/pi-monitor-contract.sh` (deployed CLI binary; a fast command's completion
lands mid-turn and is asserted through to the final assistant stop — long-running completions
after teardown are the SDK contract's subject, mirroring the reload carve-out).

## Local AI Workstation

`models.json` registers one OpenAI-compatible provider on the `desktop` workstation
with the four **primary** models, served by two engines that take turns on port 8000:

- `desktop-vllm/warmind-1017-native` — jcartu's abliterated WARMIND-1017 on ds4-native behind Maya's server: Experts streamed from the NVMe, DSpark, 262,144-token context, conversations kept as KV checkpoints in RAM. **Pi's default model.**
- `desktop-vllm/deepseek-v4.1-flash-native` — stock DeepSeek-V4.1-Flash-1017 at released precision on the same engine; only the Backbone differs.
- `desktop-vllm/glm-5.3-flash-hyperflare-tp2-v16` — GLM-5.3-Flash (NVIDIA FP4-Local) on NVIDIA Hyperflare as the recipe's TP2/DCP2 package: 8 slots, MTP 5, ~2.2M KV tokens, vision. The engine serves a 1,048,576-token context but the catalog caps it at **400K** (2026-11-15: at 1M both GLM builds spiral into degenerate reasoning, so Pi compacts earlier). GLM always thinks; `reasoning_effort` `low`/`high` select that effort and anything else gives max. Runbook `scripts/inference/runbooks/glm53-flash-hyperflare-tp2-v16-runbook-2026-11-13.md`.
- `desktop-vllm/glm-5.3-flash-hyperflare-tp2-uncensored` — the `uncensored` primary (variant `uncensored`, since 2026-11-15): dealignai's GLM-5.3-Flash-UNCENSORED-NVFP4 (`745aac2f`, the refusal edit in every layer, experts included) converted by `scripts/inference/glm53/glm53-uncensored-convert.py` into v16's storage formats — dense FP8, slab-CSF expert scales with the gate/up globals folded, and v16's vision tower, expert input scales and chat template — so it fits v16's GPU budget (2,271,744 KV tokens against v16's 2,240,000). Same engine, flags, 400K catalog cap and vision as v16. On the 21-prompt refusal probe it refused none at default effort (four answers ran out of the probe's 4K-token cap mid-thinking) and one at low effort (a request for copyrighted lyrics), against v16's 3 and the retired `cyber-hybrid-bf16`'s 6. Reached by name and as WARMIND's toggle target (2026-11-16: the toggle from WARMIND lands here, not on v16). It replaced the CYBERSECURITY splices (`cyber-hybrid`, `cyber-hybrid-bf16`), retired the same day. Build and rationale in the runbook's *Variant: uncensored* section.

Thinking defaults to **max** everywhere (2026-11-14): each primary's `defaultThinkingLevel`,
Pi's global `defaultThinkingLevel` (cloud models start at `max` too; Home Manager copies
`settings.json` into `~/.pi/agent` on activation), the `served-max` target for a cloud parent's children, and the ds41 engine's server-side
`reasoning_effort` for requests that name none. Choose less per session with `Shift+Tab` or a
`:low`/`:high` suffix; reclaw pins `:medium` on purpose (`roles/reclaw/default.nix`).

Switch the primary with `scripts/inference/switch-primary.sh` (from any machine; off
`desktop` it re-runs itself there over ssh):

```bash
scripts/inference/switch-primary.sh            # toggle: GLM or uncensored -> WARMIND, WARMIND -> uncensored, DeepSeek -> GLM
scripts/inference/switch-primary.sh glm        # or uncensored / warmind / deepseek: exactly that one
scripts/inference/switch-primary.sh status
```

It refuses to cut over while :8000 has requests in flight, and brings the previous
primary back if the new one fails to start. Both engines answer **any** model id with
whatever is loaded, so a pinned session keeps working across a switch — with its
entry's limits, which is why the default is WARMIND (262K, safe on either engine)
rather than GLM's 400K entry. The switcher prints the id that matches what now serves.

From inside Pi, `/switch` does the same and moves the session along
(`extensions/primary-switch/`):

```text
/switch                 toggle, like the script with no argument
/switch glm             or uncensored / warmind / deepseek: exactly that one
/switch status          what serves now, and what toggle would do
```

It waits for the current turn to finish (the cutover is idle-gated), runs
`switch-primary.sh` (whose gates, acceptance and rollback apply unchanged), reads the
served id from the script's `PRIMARY:` report, polls `desktop-vllm`'s `/v1/models` every
3 s until that id is served (up to 5 min), then selects `desktop-vllm/<id>` for this
session. The id comes from the script, so the extension keeps no copy of the primaries
table. Progress shows in the footer; a failed stage (`script`, `report`, `serve`,
`model`) is reported with its reason and leaves the session model unchanged. With the
primary already serving it is a no-op on desktop that still moves the session onto it.

### glm-guard: GLM thinking that cannot run away (`extensions/glm-guard/`)

GLM-5.3 on Hyperflare has no thinking off-switch, and the package's chat template defaults
`clear_thinking` to **false**, so every earlier turn's reasoning is replayed into each new prompt.
A model that thinks long (dealignai's tunes think about twice as long as upstream) then
fills its own context with its old reasoning (51-62% of the prompt in the failing sessions) and
degenerates into a loop. The symptom varies (`ih-ih-ih`, `= their = their`, `= = = =`); the
precondition does not. A replay of the failing turns on the live server (same prompt, same seeds),
measured on the retired CYBERSECURITY hybrid that produced them:

| turn | as Pi sent it | with `clear_thinking` |
|---|---|---|
| 259, 216,539 tokens | 8/8 loops | 0/8, prompt 106,550 tokens |
| 96, 141,101 tokens | 8/16 spirals | 0/16, prompt 53,858 tokens |
| 96, cleared then padded back to 133,652 tokens | n/a | 0/8 (so it is the reasoning, not the length) |

The `uncensored` build that replaced it held both turns 0/8 as Pi sent them; `clear_thinking` still
halved its prompt (259: 216,539 → 106,550 tokens; 96: 141,101 → 53,858) and its median thinking
(259: 12,686 → 5,702 characters), so the guard stays on for it.

A `before_provider_request` hook asks the server which model it is serving (the primaries share
one port and answer to any model id, so a session pinned to WARMIND can be talking to the uncensored GLM;
the answer is cached for 30 s) and, for a GLM:

- every GLM: a thinking-off request (`--thinking off`) is raised to `reasoning_effort: low`;
- the tuned build (`uncensored`): `chat_template_kwargs.clear_thinking: true`, and a
  `thinking_token_budget` by effort (low 2,048, high 4,096, max 8,192; from the p95/p99 of 1,468
  real thinking blocks). Hyperflare closes the reasoning at the budget and the model then answers.

It never overrides a field the request already sets, fails open (an unreachable server leaves the
request untouched) and `PI_GLM_GUARD=off` disables it. A session picks it up on `/reload`; the first
request afterwards re-prefills the shorter prompt once. `clear_thinking` clears reasoning from
*earlier user turns*; reasoning inside the current tool chain stays, and a budget bounds a runaway
thinking block without preventing it. Probe and evidence: `scripts/inference/shared/probe-glm-drift.py`.

Every other local profile (DeepSeek V4 Flash and Vision, the GLM-5.3 v10–v15 vLLM
builds, Qwen3.8 27B/Blackfrost/Flash-Next, the Maya EXL3 DeepSeek-V4.1) left the
catalog on 2026-11-14. Their launchers and runbooks stay, and their contracts assert
the ids are absent; restore an entry from git history before pointing Pi at one. The
sections below are the history of those profiles.

Every launcher synchronizes the DeepSeek, Qwen, and GLM key
files to one endpoint credential, so switching models, runtimes, or ports does
not change Pi authentication. Launching through `sudo` still resolves `SUDO_USER` and
writes the invoking desktop user's files—never a private `/root` credential. The key is
never committed: Pi reads it locally on `desktop`, or retrieves it through the hardened
`ssh desktop` alias when running elsewhere.

### DeepSeek V4 Flash

The Infernal Invocation r18 runtime supports exactly three reasoning-effort contracts.
They are one model with a per-request Pi setting, not separate models:

| Pi level | DeepSeek behavior |
|---|---|
| `low` | Normal 0731 reasoning prompt |
| `high` | Thorough “absolute maximum” reasoning prefix |
| `max` | Exhaustive “beyond maximum” reasoning prefix |

Pi hides unsupported `minimal`, `medium`, and `xhigh` levels for this model. The tracked
model catalog assigns DeepSeek Flash a model-specific default of `max`. The Nix-built Pi
package carries a small patch (`pi-model-default-thinking.patch`) that applies this default
to new sessions and model switches without modifying Pi's global cloud-model default.
Precedence on a model switch: scoped `model:level` > the per-model level saved in settings >
a level you chose this session (`--thinking`, `Shift+Tab`, SDK `thinkingPreference`) > the
model's `defaultThinkingLevel` > the global default. Resumed sessions preserve their
recorded level. Use
`Shift+Tab` to cycle `off → low → high → max`. The command-line equivalent is:

```bash
pi --model desktop-vllm/deepseek-v4-flash:max
```

A second patch, `pi-autocontinue-after-compact.patch`, resumes the
agent turn automatically after *threshold* auto-compaction instead of
stalling for input. Upstream ends the turn after a post-run compaction unless
the user queued a message; with the patch the turn continues from the
compaction boundary. (Upstream already compacts *between* a tool result and the
next request, so that case needs no resume.) Overflow compaction with a completed answer is not auto-continued
(that response already finished). Disable per-session with
`{"compaction": {"autoContinue": false}}` in `~/.pi/agent/settings.json`;
`enabled`, `reserveTokens`, and `keepRecentTokens` are unchanged.

The server may be offline while editing or selecting the catalog, but it must be running
before sending a prompt. Verify discovery without contacting the server:

```bash
pi --list-models deepseek-v4-flash
```

### DeepSeek V4.1 Flash 1017 (Project Maya)

Not a vLLM server: Project Maya's `maya-ds4` engine (v1.1.21 plus the
conversation-slot PR), which keeps the most-used experts in the two RTX PRO
6000s' VRAM, reads the rest in place from the model files while holding its
own anonymous heap copy of the most-routed ones (not a pinned tier, not page
cache), and keeps DeepSeek's Engram tables on a 16K-record ZFS dataset
(`scripts/inference/runbooks/ds41-1017-maya-exl35-runbook-2026-10-21.md`). Measured on
the served config (262,144 context, 8,192-token prompt chunks, DSpark on): 83-138
tok/s decode (108-135 on 58-88K-token conversations, 104 at 205K), 1,420-1,950 tok/s
prefill on a cold prompt (10K-25K tokens) — level with v1.1.17's 1,541 tok/s at
20K, because the release notes' ~1.5x prompt skip needs one GPU per layer and
this profile is `--tp 2`. Maya keeps the last conversation's KV, so a
continued conversation only pays for its new tokens (a 71.5K-token
conversation's next turn: 28 tokens read, 114 ms); a new or rewritten history
pays the cold rate, ~1,700 tok/s even at 200K (a 205,180-token prompt read in
120 s). The engine parks the four least-recently-used conversations
(in RAM, then in `<pack>/slots`), so switching between an agent's parent and
its workers costs their new tokens instead of a re-read — a parked
conversation restores in 0.1-0.5 s, and `SLOT_KEEP=0` on the run script turns
it off.

- **Auth**: every endpoint needs the shared inference key, including
  `/metrics` (401 without it), so the vLLM switchers' idle gate cannot read
  Maya's load — stop Maya before starting another profile.

- **Context**: the catalog's 262,144 is the server's own `--max-context`,
  proven by retrieval, not by a flag: a 205,180-token prompt with facts buried
  at 15% and 80% depth answered with both (2026-10-22). The pack is YaRN x16
  over a 65,536 base, so half the model's 1,048,576 remains in reach — but
  524,288 waits for its own needle run, and `metrics.trained_context` is null.
  Larger values are not a Pi tweak — a 32,768-token prompt chunk wedged the
  host, and the context is pinned in the run script after measurement.
- **Thinking**: Maya maps `reasoning_effort` `low`, `high` and `max`
  (`medium` → high, `xhigh` → max, `none` → off); the catalog exposes those
  three and defaults to DeepSeek's own `high`.
- **Model id**: Maya answers any model name with this model, so a client
  still pinned to a GLM id silently gets DeepSeek with GLM's catalog limits —
  select this entry explicitly.

```bash
pi --list-models deepseek-v4.1-flash
pi --model desktop-vllm/deepseek-v4.1-flash:high
```

### DeepSeek-V4.1-Flash-1017 on ds4-native

`deepseek-v4.1-flash-native` is the same model at its released precision
(MXFP4 Experts, FP8 dense) on ds4-native (`peterstorm/ds4-native`): Experts
streamed from the NVMe into a VRAM Expert cache, Exact against the engine's
reference, DSpark drafting. It runs behind Project Maya's own server
(`serve/server.py` at `b3fa99e`, plus `maya-serve-keepalive.patch`: keep-alives
while tokens flow with nothing to send, so a large file write's held-back
parameter no longer trips Node's 300 s read timeout), so the chat encoding,
thinking levels and tool calls behave as on the Maya entry above; only the
engine differs. Launch it with
`scripts/inference/deepseek/ds41-1017-native/run-ds41-1017-native.sh`
(`--install` once per pinned engine commit, then `--launch`; `--stop`).

- **Context**: 262,144 (the executor's), text only — proven by retrieval: a
  246,234-token prompt with facts at 15% and 80% depth answered with both
  (cold read 71 s, 3,470 tok/s; reply 37.6 tok/s). A cold prompt reads at
  ~3,400 tok/s at that length, so only a conversation's first prompt pays it.
  `maxTokens` is the whole 262,144 and the server runs with
  `--fit-max-tokens`, so every reply gets the room left beside its prompt: a
  reply, reasoning included, is bounded by the context alone.
- **Conversations**: an agent's next step and a chat's next turn read only
  their new tokens (a 22K-token pi session's steps read 20-830 tokens). A
  conversation another one took the GPUs from is kept as a KV checkpoint in
  RAM (6 GB of them, least recently used dropped first; a 4.5K-token one is
  0.12 GB, set aside in ~25 ms, back in 8 ms), so a parent and its subagents
  stop re-reading each other's prompts; a subagent's first prompt resumes
  where it leaves the parent's system prompt. Four requests run at once
  (`LANES=4`, since 2026-11-13), their rows sharing the engine's Rounds, each
  reply the bits it is alone: parallel subagents all write within seconds
  (each slower while they share: five reviewers of one diff 115 tok/s in all
  against 91 taking turns); a fifth waits in line, kept alive. A lone request
  pays ~10 % for the VRAM the Lanes take (`LANES=1` takes turns as before).
- **Speed**: decode 40-115 tok/s on a first session while the Expert cache
  learns the domain (Misses stream from the NVMe); a cold prompt reads at
  ~700 tok/s at 7K and several thousand tok/s on long prompts.
- **Thinking**: no cap of its own (`thinking_budget` 262,144; Maya's default
  is 32,768). The reasoning may use the reply's room less the quarter Maya
  keeps for the answer (at least 1,024), so a reply never ends without one.
  Until 2026-11-02 the 32,768 reply cap left 24,576 to think; a
  31,291-token reasoning-plus-file-write reply was cut by the read timeout
  1,477 tokens short of that cap.

```bash
pi --model desktop-vllm/deepseek-v4.1-flash-native:high
```

### WARMIND-1017 on ds4-native

`warmind-1017-native` is jcartu's `WARMIND-1017` v1.1 (`orth4c`, 2026-11-16,
revision `a6382f22`), an abliteration of DeepSeek-V4.1-Flash-1017: 132 tensors
re-written — `attn.wo_b` and `ffn.shared_experts.w2`, weights and scales, in
layers 4–36 — and every other byte DeepSeek's, so the routed Experts, Engram
tables and DSpark head are the ones the entry above serves. It answers requests
the stock model refuses. v1.1 projects a 4-dimensional "the source does not
say" abstention subspace out of the refusal direction before the
norm-preserving biprojection (alpha 3.0–3.5 per layer to keep full strength):
jcartu measured v1.0's extra fabrication on SQuAD 2.0 unanswerables cut from
+13.6 to +4.6 points over stock (+1.6 with a grounding prompt, within noise),
TruthfulQA MC1 82.5 → 84.7 % (stock 87.1), 0/100 refusals. ds4-native keeps
all 132 tensors in its Backbone, so this entry is a second 10 GB Backbone
beside the shared Expert store; the launcher serves it by default (`WEIGHTS=deepseek` for the release,
`WEIGHTS=warmind-v1.0` for the alpha-3 v1.0 served 2026-11-05 to 2026-11-16,
under the same name) and refuses a Backbone whose header names another source.
Context, conversations and thinking behave as above. Maya answers any model
name with what is loaded, so `/v1/models` is how to tell which one is up, and
the container's `ai.peterstorm.inference.backbone` label which revision.

- **Verified**: `bun tools/hf-backbone/cli.ts verify` (ds4-native) against
  DeepSeek's Backbone and WARMIND's `DERIVATIVE.json`: all 132 re-written
  tensors carry the manifest's bytes, the other 1,129 are DeepSeek's (v1.0
  2026-11-05; v1.1 2026-11-16, by its fetch script before it promotes the file).
- **Speed** (v1.0; 2026-11-05, the stock A/B's victim-tier arm on a fresh engine,
  seed 424242): warm code reply 131-134 tok/s (stock 126-136), decode at 7K-48K
  context 85-87 (stock 81-87), prefill 1,085 / 1,963 / 4,735 tok/s at 7K / 14K /
  48K tokens (stock 1,091-1,152 / 1,962-2,063 / 4,714-4,988). Short-prompt prose
  ran 101-104 against stock's 107-114: its different text needed 15-30 % more
  Expert loads.

```bash
scripts/inference/deepseek/ds41-1017-native/run-ds41-1017-native.sh --launch   # returns once serving; restart=unless-stopped
pi --model desktop-vllm/warmind-1017-native:high
```

### GLM-5.3 Flash EXL3 K4

Legacy NVFP4 v2, EXL3 v1/v2, and 98K MTP v4 launchers remain immutable deployment
rollbacks, but are intentionally omitted from Pi's model picker. The picker exposes only
the DFlash benchmark arm, validated v5 rollback, active text FP8 v6, and vision NVFP4 v7
candidate.

The separate EXL3 K4 profile uses a digest-pinned custom Infernal Invocation vLLM
image with B12X's NVFP4 MLA KV cache. The upstream-aligned v37 TP2 candidate exposes
499,968 text tokens, concurrency four, prefix caching, CUDA graphs, and three-token MTP;
the v30 128K/C1/eager/MTP-off profile remains its conservative rollback. Both remain
experimental because the custom GLM overlay is not publicly reconstructible and local
RTX PRO 6000 correctness, long-context, performance, tool-use, and soak evidence is pending.

The separate v84 vision entry uses the same verified target tensors with a pinned DFlash2
checkpoint, native-PyTorch vision-RoPE fallback, the official Z.ai multimodal template,
TORCH_SDPA encoder attention, at most four images, no video, and a conservative 98,304-token
ceiling. It intentionally has a distinct model ID because its context and input contract differ
from the 499,968-token text-only v37 profile. A second v84 entry uses the checkpoint's
built-in MTP head for three draft tokens instead of the external DFlash2 model. It retains the
same 98,304-token multimodal boundary but follows the supplied 0.986-utilization recipe.
The immutable v5 profile retains that exact image, target, calibrated NVFP4 MLA KV cache,
vision path, and MTP3 settings while raising only the request ceiling to 393,216. It allocated
625,112 KV tokens on a cold kernel-cache boot and 1,129,235 after cache warmup, providing
1.59× and 2.87× theoretical full-context concurrency respectively. Long-context vision and
concurrency still require separate local qualification.

The text-only FP8 v6 profile reproduces the supplied FP8 DS MLA, FlashInfer SM120 sparse MLA,
InstantTensor, prefix-cache, and MTP3 recipe without changing v5. Immutable v7 instead derives
from the multimodal v5 envelope: it retains calibrated `nvfp4_ds_mla`, B12X sparse MLA,
TORCH_SDPA vision, four-image support, and MTP3, then enables prefix caching and adds a
512-token `long_prefill_token_threshold`. The cap prevents one cold long prefill from consuming
the full 2,072-token scheduler iteration and starving an active decode request. v6 is active:
its cold JIT-cache boot measured 403,989 KV tokens, while its warm-cache boot measured 737,953
(1.88× its 393,216-token ceiling), reproducing the author's roughly 700K expectation. Full v6
runtime qualification and all v7 boot, prefix-cache, vision, and latency qualification remain
pending.

```bash
pi --list-models glm-5.3-flash-exl3-k4-vision-fp8kv-mtp-359k-v11
pi --model desktop-vllm/glm-5.3-flash-exl3-k4-vision-fp8kv-mtp-359k-v11:max
pi --list-models glm-5.3-flash-exl3-k4-vision-fp8kv-mtp-359k-v10
pi --model desktop-vllm/glm-5.3-flash-exl3-k4-vision-fp8kv-mtp-359k-v10:max
pi --list-models glm-5.3-flash-spark-tp2-v14
pi --model desktop-vllm/glm-5.3-flash-spark-tp2-v14:max
pi --list-models glm-5.3-flash-qad2-tp2-v15
pi --model desktop-vllm/glm-5.3-flash-qad2-tp2-v15:max
```

### GLM-5.3 Flash qad2 TP2 (v15)

v15 follows the third-party "GLM-5.3-Flash vLLM Recipe" (vendored in
`docs/research/glm53-qad2-tp2-v15-2026-10-16-evidence/`): the Karmic Kraken
beta build `20261015.2`, pulled **by digest** because beta tags move, serves
`local-inference-lab/GLM-5.3-Flash-NVFP4-MXFP8-CSF-QAD` at revision
`0a041763…` through `lil-serve --preset glm53-tp2` (TP2/DCP2, MTP3, eight
slots, 4096-token prefill budget, 7,650,410,496 B/GPU fixed FP8 KV, A4 expert
prefill, vision). It runs GPU-only (`CACHE_MODE=vram`) and sets the server
default to effort **high** instead of the preset's max. vLLM honours
per-request `chat_template_kwargs.reasoning_effort`, so the catalog's
`defaultThinkingLevel: max` and the `:low` / `:high` suffixes still choose the
effort per request.

The recipe reports **1,844,162** KV tokens with a 1,048,576 context. It also
warns against pinning a shorter `--max-model-len`: that regroups the hybrid
KV cache and *shrinks* the pool (to 1,561,213 at 524,288). The server keeps
its 1M, and the catalog caps **sessions** at **524,288**, which leaves room
for about 3.5 full-length sessions in the shared pool across the eight slots.
The exact boot values are in
`~/.local/state/glm53/flash-qad2-tp2-v15-boot-receipt.txt`.

See `scripts/inference/runbooks/glm53-flash-qad2-tp2-v15-runbook-2026-10-16.md`.

### GLM-5.3 Flash Spark TP2 (v14)

v14 is a **stock upstream deployment**, not a derived image: the Karmic Kraken
beta channel image (digest-pinned by the pull script) serves
`local-inference-lab/GLM-5.3-Flash-NVFP4-Spark` through `PRESET=glm53-spark-tp2`
(TP2/DCP2, MTP3, four slots, 3072-token prefill budget, 3996 MiB/GPU fixed FP8
KV, vision, and a memory-resolved context that reports roughly 983K tokens
GPU-only or 924K with the optional LMCache tier). The served model id is
`glm-5.3-flash-spark-tp2-v14` — the repository sets `SERVED_MODEL_NAME`, which
overrides the preset's generic `GLM-5.3-Flash` identifier, so Pi and the
benchmark catalog can attest the exact runtime profile. The checkpoint is
pre-downloaded at the pinned revision (`a6082410…`) into a host hub cache and
served offline (`HF_HUB_OFFLINE=1`, `MODEL_REVISION`), so the engine cannot
fetch a different revision.

The catalog registers **350,000** tokens as the per-session context window by
 deliberate choice, not the boot-resolved ceiling: the preset auto-fit
`max_model_len` to **983,040** (KV cache 986,295 tokens) with **1.00×**
concurrency for full-context requests — a single session growing toward 980k
would starve every parallel subagent slot. At 350,000 tokens per session the
shared KV budget still admits ~2.8 concurrent slots, which is what Loom's
parallel children need. The exact server-resolved limit is recorded in
`~/.local/state/glm53/flash-spark-tp2-v14-boot-receipt.txt`; benchmarks or
curl clients that deliberately want >350k context address the server directly
(it still serves up to 983,040 tokens per request).

Enabling the LMCache tier (RAM 16 GiB + 64 GiB disk, `CACHE_MODE=lmcache` on
the run script) lowers the server ceiling to roughly 924K; the 350k session
cap and the tier are independent choices, and the tier stays off by default.

v14 is unlaunchable until the pull script records the image id in the run
script (same fail-closed shape as v13) and the checkpoint download script
writes the pinned-revision marker; the switch script only promotes
`restart=unless-stopped` after an accepted boot.

### Qwen3.8 27B

Qwen runs multimodal BF16 at its native 262,144-token context. Its checkpoint-native
chat template accepts `low`, `medium`, and `xhigh` reasoning; Pi hides every other level
and defaults new Qwen sessions to `xhigh`. The model-specific compatibility settings send
one `system` role and map Pi's thinking state into `chat_template_kwargs` without changing
DeepSeek's wire format.

```bash
pi --list-models qwen3.8-27b
pi --model desktop-vllm/qwen3.8-27b:xhigh
```

The catalog is available before the server starts. Prompts work after either Qwen launcher
has brought `qwen3.8-27b` up on port 8000.

### Qwen3.8 Flash-Next FP8

The experimental Flash-Next profile serves the official 125B/6B-active multimodal FP8
checkpoint at its native 262,144-token context. Its 51.2B-element N-gram table is kept in
host RAM with `VLLM_PLE_CPU_OFFLOAD=1`, while TP2 places the remaining model across both
RTX PRO 6000 GPUs. Pi exposes the checkpoint's `low`, `medium`, and `xhigh` reasoning
levels and defaults to `xhigh`. The profile remains unqualified because its vLLM model and
offload support are based on open PRs and the special runtime image has no embedded source
commit identity.

```bash
pi --list-models qwen3.8-flash-next-fp8
pi --model desktop-vllm/qwen3.8-flash-next-fp8:xhigh
```

### Qwen3.8 27B Blackfrost Abliterated

A weight-level derivative of `Qwen/Qwen3.8-27B` with a reduced refusal surface — not the
upstream safety-stock checkpoint. It is structurally identical to `qwen3.8-27b`, so it
serves through the same pinned TP1 vLLM profile at the native 262,144-token context, with
the same reasoning contract: Pi maps `low` and `xhigh` into
`chat_template_kwargs.reasoning_effort` and hides the levels Qwen3.8 does not implement.

```bash
pi --list-models qwen3.8-27b-blackfrost-abliterated
pi --model desktop-vllm/qwen3.8-27b-blackfrost-abliterated:xhigh
```

It shares port 8000 with the other `desktop-vllm` models, so exactly one of them serves at
a time. Note that its chat template embeds a Blackfrost operational system prompt, which is
a real behavioural difference from the stock `qwen3.8-27b` entry.

## Child Model Routing

`model-routing.json` is the explicit policy boundary between parent-session models and
nested Pi workloads. Provider names, endpoint URLs, and model prices are never used to
guess whether a model is local.

**Children run on whatever local model is served right now.** The policy classifies
`desktop-vllm/*` (and `llama.cpp/*`) as local; desktop-vllm parents route to a *served* target
instead of a fixed id:

| Active parent | Subagent launch binding |
|---|---|
| desktop-vllm model (any of the three primaries, even one that is not the served one) | The model desktop-vllm serves now, at the **parent's** thinking level (`local-desktop-children-use-served`) |
| Any other local model (e.g. `llama.cpp/*`) | The local parent itself (`other-local-children-inherit-parent`): desktop-vllm's served model says nothing about it |
| Cloud model, agent `worker` | The cloud parent itself (`cloud-workers-use-parent`) |
| Any other cloud or unknown model | The model desktop-vllm serves now, at `max` (`served-max`) |

```json
{
  "targets": {
    "served": { "served": "desktop-vllm" },
    "served-max": { "served": "desktop-vllm", "thinkingLevel": "max" }
  }
}
```

A target names exactly one of `model` (a fixed `provider/id`) or `served` (a provider). The
policy stays pure: once per `subagent` tool call the extension asks each provider a rule
depends on for `GET {baseUrl}/models` (with the provider's catalog key), requires exactly
one model that is in Pi's catalog, and passes that answer into routing as data
(`model-routing/served.ts`). A served target without `thinkingLevel` inherits the
parent's; with one, it is pinned (cloud efforts such as `xhigh` do not exist on the local
models). If the probe fails, routing fails before spawn with the reason ("cannot reach
desktop-vllm: …") — there is no silent fallback to a stale id. Children therefore follow
`scripts/inference/switch-primary.sh` without any config change, and get the served model's
own catalog limits (GLM's 400K cap, WARMIND's 262K).

A parallel `subagent` call names at most 8 tasks and runs up to 8 at once
(`MAX_PARALLEL_TASKS`, `MAX_CONCURRENCY` in `extensions/subagent/index.ts`; separate knobs).
8 matches desktop: GLM v16 serves 8 slots, and ds4-native runs 4 Lanes and keeps the
rest alive in its queue.

Every child receives one routing decision snapshotted at the beginning of its parent tool
call: the served-model probe happens once there, so parallel tasks and chains cannot drift
if `/model` changes or the primary switches mid-call. Overrides launch with one exact
`--model` plus `--thinking` pair and no fallback list. Policy parse failures stop before
spawn, while declared model expressions remain opaque so Pi can resolve aliases and
colon-bearing model IDs. Tool-result details retain the declared binding, effective
binding, rule ID, parent class, and SHA-256 policy digest for auditability. Loom's own model
guard defers the effective Pi binding to this launcher policy (Claude Code spawns still
require the declared binding exactly); no Loom source or generated agent file needs
routing-specific changes.

Rules can select by `parentClass`, `parentModel`, `workload`, Loom `model-profile`, and
agent name. Every additional selector increases specificity; the most-specific matching
rule wins. Equal-specificity rules that could match the same request are rejected. A
`declared` target preserves an agent declaration, `parent` uses the snapshotted parent
binding, and `named` chooses a configured exact or served target. Do not embed model IDs
in extension code.

Cortex already preserves its declared cheap cloud extraction target for known cloud
providers and reuses unknown/custom active models, including both desktop providers; DeepSeek's
catalog default makes local extraction children use `max` unless an explicit level is passed.
Centralized Cortex-specific
rule selectors would require Cortex to consume this policy API, but are not needed for the
initial local-parent behavior.

## Packages (Plugins)

Pi loads packages from `settings.json`:

```json
{
  "packages": [
    { "source": "../../dev/claude-plugins/loom", "extensions": [] },
    "git:github.com/peterstorm/pi-goal@v0.1.0",
    "../../dev/claude-plugins/cortex",
    "../../dev/claude-plugins/obsidian"
  ]
}
```

Local paths are relative to `~/.pi/agent/` (the agentDir). The Pi Goal entry is instead an immutable Git release; Pi installs it under `~/.pi/agent/git/` and does not depend on a development worktree. Packages may declare resources in a `package.json` Pi manifest or expose Pi's conventional resource directories. Loom, Pi Goal, and Cortex use manifests; Obsidian's conventional `skills/` directory exposes `obsidian-vault` from the same canonical source used by its Claude plugin. The Home Manager Claude workspace activation provisions the local plugin checkouts, while Pi owns the pinned Pi Goal clone. Use Obsidian from Pi as `/skill:obsidian-vault` or ask naturally about the vault.

Pi Goal is a standalone Pi extension from `github.com/peterstorm/pi-goal`; it provides `/goal` and loads after Loom so its optional `review-and-fix-clean` evaluator can consume Loom's process-local review authority. Loom remains listed as a local package for the custom subagent's agent/skill discovery, but `"extensions": []` disables its Pi package entry. The auto-discovered `pi/extensions/loom-runtime-loader.ts` is the sole loader of Loom's native `pi/extension.ts`, so `/reload-runtime` refreshes its module graph. Do not enable the package extension as well: it registers Loom's tools twice and Pi refuses to start.

## Agents

`~/.pi/agent/agents` is a real directory holding two kinds of file:

| Kind | Source | Tracked in git? |
|---|---|---|
| symlink | `~/.dotfiles/pi/agents/*.md` — the generic agents this repo owns (`planner`, `scout`, `reviewer`, `worker`) | yes |
| real file | Loom's roster, rendered per machine by `loom/scripts/sync-pi-agents.sh` | **no** |

### Why agents/ is not a directory symlink

Loom's sync script writes into `${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}/agents`.
While that path was a symlink into this repo, Loom's build output landed inside
version control. Those renders must not be committed:

- they bake in an **absolute** package root (`loom-package-root`, base64) plus
  the inlined bodies of every preloaded skill, so they are machine-bound;
- they carry a `loom-agent-digest` of the source agent, so they go stale on
  every Loom commit.

### Why symlinking Loom's raw agents does not work either

Loom's Pi extension registers a pre-tool-use guard
(`engine/src/handlers/pre-tool-use/validate-agent-model.ts`) that resolves
`$PI_CODING_AGENT_DIR/agents/<name>.md` and **fails closed** twice:

- absent file → `BLOCKED: Pi agent '<name>' has no generated definition`
- not byte-for-byte the current render → `BLOCKED: Pi agent policy failed`

A symlink to `loom/agents/<name>.md` fails the second check: the source declares
`model: sonnet` with `${CLAUDE_PLUGIN_ROOT}` placeholders, while the guard
demands the rendered form with an explicit provider/model/thinking binding.

So the render is mandatory, and `home.activation.piAgents` runs it on every
`hm-apply` (after `claudePluginsWorkspace` has provisioned the Loom checkout and
its `node_modules`). It also prunes renders whose source agent Loom has dropped,
which the sync script itself does not do.

Between rebuilds — Loom moves faster than the rebuild cycle — re-render with:

```bash
loom-sync     # = ~/dev/claude-plugins/loom/scripts/sync-pi-agents.sh
```

Then `/reload` in Pi.

### Package discovery

Pi packages do not natively expose an `agents` resource. The custom subagent extension therefore discovers a conventional `agents/` directory from every configured **local** package in `settings.json`. Package agents load before user agents, and project agents load last, giving this override order:

`package < user < project`

This makes Loom's full roster **visible** as soon as the Loom checkout adds an
agent, with no dotfiles change. Note that visibility alone is not enough:
spawning still needs the generated definition above, so an unsynced agent shows
up in the roster and then blocks. Both panel workflows are covered:

- Architecture panel: `arch-interviewer-agent`, `arch-designer-agent`, `arch-judge-agent`
- Review refutation panel: `review-verifier-agent`

The package resolver supports string and object-form local package entries and ignores npm/git sources that Pi installs elsewhere.

## Skill Injection into Subagents

### The Problem

When pi spawns a subagent (child `pi` process), it passes the agent's body as `--append-system-prompt`. Pi's `loadSkills()` API doesn't resolve packages from `settings.json` — it only uses explicitly provided `skillPaths`. This meant agents with `skills:` in their frontmatter got an empty skill map (0 skills found).

### The Fix (`extensions/subagent/agents.ts`)

The custom subagent extension adds `resolvePackageSkillPaths()` which:

1. Reads `~/.pi/agent/settings.json` to find declared packages
2. For each package, reads its `package.json` → `pi.skills` array
3. Falls back to the conventional `skills/` directory when the manifest declares
   none — Loom ships `skills/` but declares only `pi.extensions`, so a
   manifest-only lookup returns an empty map
4. Resolves those relative paths to absolute skill directories
5. Passes them to `loadSkills({ skillPaths: [...] })`

### Two routes, never both

A skill reaches a Pi agent one of two ways:

| Route | Heading in the prompt | Applies to |
|---|---|---|
| Loom inlines it at render time | `## Preloaded Loom Skill: <name>` | every agent in Loom's roster |
| This extension injects it from the skill map | `## Preloaded Skill: <name>` | any other agent declaring `skills:` |

Loom's renderer reads each declared skill and embeds its body in the generated
definition, so **Loom's agents already carry their skills** regardless of what
the skill map contains. `resolveSkillContents()` therefore skips any skill the
agent body already preloads (`hasPreloadedSkill()`); without that check a Loom
agent would carry the entire skill twice — for `arch-designer-agent` that is
~6 KB of duplicated prompt.

`verify-agent-install.ts` asserts exactly one preload, so both the missing and
the duplicated case fail loudly.

This gives us a complete skill name → file path map. When an agent declares:

```yaml
---
name: java-test-agent
skills:
  - java-test-engineer
---
```

The extension:
1. Parses `skills: [java-test-engineer]` from frontmatter
2. Looks up `java-test-engineer` in the skill map → finds the SKILL.md path
3. Reads the skill file, strips its frontmatter
4. Appends the full skill body to the agent's system prompt:

```
---
## Preloaded Skill: java-test-engineer
Skill directory: /path/to/skills/java-test-engineer
When the skill references relative paths, resolve them against: /path/to/skills/java-test-engineer

<full skill instructions>
```

### Verification

```bash
# From any project directory:
bun -e '
import { discoverAgents } from "'$HOME'/.pi/agent/extensions/subagent/agents.ts";
const { agents } = discoverAgents(process.cwd(), "user");
for (const a of agents.filter(a => a.systemPrompt.includes("Preloaded Skill"))) {
  const skills = [...a.systemPrompt.matchAll(/## Preloaded Skill: (.+)/g)].map(m => m[1]);
  console.log(`${a.name} → [${skills.join(", ")}]`);
}
'
```

Run the complete install verification after changing Pi package or agent wiring:

```bash
cd ~/.dotfiles
./pi/verify.sh --tests          # routing + subagent tests with Pi SDK resolution
pi-verify                       # = ./pi/verify.sh
nix flake check --no-build
```

`verify-agent-install.ts` needs `@earendil-works/pi-coding-agent`, which ships
inside pi's own Nix store closure and nowhere in this repo — `pi/verify.sh`
derives that path from the `pi` on `$PATH` and sets `NODE_PATH`. Invoking the
`.ts` directly fails to resolve the module.

It asserts the whole contract: `agents/` is a real directory, every owned agent
is linked, every Loom agent has a render that Loom's *own* validator accepts
byte-for-byte, no orphan renders survive, and the panel roster plus skill
injection are live.

Expected skill-injection output includes:
```
architecture-agent → [architecture-tech-lead]
arch-designer-agent → [architecture-tech-lead]
grill-agent → [grill]
java-test-agent → [java-test-engineer]
code-implementer-agent → [code-implementer]
ts-test-agent → [ts-test-engineer]
deepen-agent → [deepen]
frontend-agent → [nextjs-frontend-design]
security-agent → [security-expert]
```

## Adding a New Agent

For a **Loom** agent, add it to `~/dev/claude-plugins/loom/agents/` and run
`loom-sync`. Never hand-write one into `pi/agents/` — Loom's guard only accepts
its own render.

For a generic agent this repo owns:

1. Create `pi/agents/my-agent.md`:
   ```yaml
   ---
   name: my-agent
   description: What this agent does
   model: claude-sonnet-4-5
   skills:
     - my-skill-name
   ---

   You are a specialist. Follow the patterns from the preloaded my-skill-name skill.
   ```

2. The agent body (below `---`) becomes the system prompt
3. Skills listed in frontmatter are resolved and appended automatically
4. Run `hm-apply` to link it into `~/.pi/agent/agents/`. Editing an
   already-linked agent is live — only adding or removing one needs the rebuild.

## Adding a New Extension

Create `pi/extensions/my-extension.ts` or `pi/extensions/my-extension/index.ts`
with a default `ExtensionAPI` factory. The Nix Home Manager module already
symlinks the whole directory into `~/.pi/agent/extensions`, so adding or
editing a file needs **no Home Manager rebuild**. Run `/reload` once in each
active Pi session to load the new code; new sessions discover it at startup.

`reload-runtime.ts` registers the LLM-callable `reload_runtime` tool. The Pi SDK
treats `sendUserMessage("/reload-runtime")` as plain user text unless
`expandPromptTemplates` is set, and then runs the command *immediately*, even
mid-run. The Nix overlay's `pi-extension-command-after-idle.patch` adds an
explicit `executeCommandAfterIdle` opt-in. It waits for the agent run to settle, then
dispatches *only* a registered extension command; unknown commands fail rather
than reaching the model. The command calls Pi's real `ctx.reload()` on the
**parent** session, not a child subagent. Apply the updated Nix package and
**restart Pi completely** once: `/reload` reloads extensions but cannot replace
the running Pi core binary. Later reloads can use the model-callable tool.

The reload would otherwise strand the task: pi sits idle until the next human
prompt. The tool therefore journals a `reload-runtime-auto-continue` custom
entry (`{kind: "pending", ts}`, the typed `ReloadContinueMarker` union) before
dispatching the command — the one channel that outlives the reload, since a
reload replaces the extension instance and invalidates the old runner. The
reloaded instance's `session_start` handler (`reason: "reload"`) consumes the
newest marker exactly once, sends the `"[runtime-reloaded] Continue from where
you left off."` user prompt, and only then journals the `consumed` twin — the
reload-side twin of the compaction auto-continue nudge
(`pi-autocontinue-after-compact.patch`). There is no wall-clock freshness gate:
the deferred dispatch fires after the whole calling turn settles, however long
its tail, and the reload that lands is the one the marker asked for; a crashed
run or fork re-enters the session with a different `session_start` reason and
never reaches this consumer. A manual `/reload` finds only the `consumed`
marker and stays idle. The decision is the pure `shouldReloadAutoContinue()`
over the session journal, parsed through `parseReloadContinueMarker()`. The
contracts live in `pi/tests/reload-runtime.test.ts` (unit),
`pi/tests/reload-autocontinue.test.ts` (SDK end-to-end against a fake model
server: continuation turn plus the manual-reload negative control),
`pi/tests/reload-continue-regression.test.ts` (repair regression pin) and
`tests/pi-reload-autocontinue-contract.sh` (real CLI binary). The continuation
turn matters in live sessions (TUI, RPC); in one-shot `pi -p` the process tears
down while that extension-triggered turn is still starting, and a finished
one-shot prompt should not be resumed anyway — the same completed-answer
carve-out the compaction auto-continue applies.

Run `./pi/verify.sh --tests` after extension changes (including the real SDK
command-dispatch test).

## Upgrading Pi

Pi is not pinned in this repo. `overlays/pi-coding-agent.nix` takes the package
from the `llm-agents` flake input (`numtide/llm-agents.nix`, which tracks npm
releases, lockfile and hashes) and adds the three patches in `overlays/patches/`,
so upgrading is:

```bash
nix flake update llm-agents
./hm-apply.sh            # Mac;  ./system-apply.sh on NixOS hosts
./pi/verify.sh --tests && ./pi/verify.sh && bash tests/pi-compaction-autocontinue-contract.sh && bash tests/pi-reload-autocontinue-contract.sh
```

The patches apply to the unbundled `dist/` tree of the npm tarball (the overlay
builds the Node entry point `dist/cli.js`, not upstream's minified
`dist/bundle/` or Bun binary). If a release changes the code a patch touches the
build fails in `patchPhase`; rebase the patch against the new tarball
(`npm pack @earendil-works/pi-coding-agent@<version>`, edit a copy of `dist/`,
`diff -ruN a/dist b/dist`) and re-run the checks above. Check the release's
CHANGELOG first — a patch whose behavior shipped upstream should be deleted.
