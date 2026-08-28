# Pi Agent Configuration

This directory contains the pi coding agent configuration managed by home-manager. Files here are symlinked to `~/.pi/agent/` at activation time.

## Directory Structure

```
pi/
├── agents/           # Generic agents this repo owns (→ linked per file)
├── extensions/       # Custom extensions (→ ~/.pi/agent/extensions/)
│   ├── model-routing/ # Pure child-model routing policy
│   ├── subagent/     # Generic subagent tool with skill injection
│   └── global-instructions.ts  # Standalone extension
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
6. **Creative project skills**: links four reviewed archive skills, MiniMax's
   revision-pinned music-caption skill, and four MIT-licensed authored production
   skills into `~/dev/creative/.pi/skills/` through Home Manager. They are not
   present in `~/.pi/agent/skills`, package settings, or any ancestor directory,
   so Pi discovers them only when its working directory is exactly
   `~/dev/creative`.
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

The repository owns nine MIT-licensed companion skills:

- `action-physics-production` — support, force, contact order, momentum,
  conditioning strategy, proof coverage, and sampled-frame action QA;
- `blocking-continuity` — normalized staging, screen direction, map qualification,
  and fail-closed spatial QA;
- `ensemble-action-production` — local-only Krea 2, MiniMax Music 3, and MiniMax H3
  production orchestration;
- `human-motion-realism-production` — evidence-informed gaze, blink, breathing,
  support, gesture, fidget, response-latency, and dense sampled-frame QA;
- `identity-realism-production` — mandatory Krea/Klein face A/B qualification and
  accepted high-fidelity identity handoff to production H3;
- `performance-direction` — playable actor and listener work with sampled-frame QA;
- `prop-continuity` — prop scale, mating geometry, action coverage, and semantic QA;
- `synthetic-voice-production` — immutable original VoiceAnchors, dialogue cloning,
  stem-safe singing conversion, versioning, and listening acceptance;
- `wardrobe-asset-production` — approved front/rear/detail packages, serialized
  lineage, immutable versions, and visible construction evidence.

These authored skills adapt model-agnostic production lessons without modifying or
republishing the unlicensed archive or uploaded reference text.

Start Pi in the project to expose them:

```bash
cd ~/dev/creative
pi
```

Pi requires an explicit project-trust decision before loading `.pi/skills`.
Approve the prompt after verifying the path is exactly `~/dev/creative`; use
`/trust` if that decision should persist, then restart Pi as instructed. Starting
Pi elsewhere does not discover these fifteen skills. Pi intentionally applies
ancestor traversal to `.agents/skills`, not `.pi/skills`; this setup uses the
Pi-only `.pi` location, so start the session from the creative project root.

### Why Directory Symlinks?

Using a single symlink per directory (instead of per-file) means:
- **Adding new files needs no rebuild** — just create the file in the dotfiles repo
- **Edits are live immediately** — no `home-manager switch` needed
- **Removing files just works** — delete from repo, done
- **`home-manager switch` only needed** when the nix module itself changes

`agents/` is the exception, because it is not purely source — Loom generates
into it.

## Local AI Workstation

`models.json` registers two OpenAI-compatible providers on the `desktop` workstation
with eight selectable models:

- `desktop-vllm/deepseek-v4-flash`
- `desktop-vllm/glm-5.3-flash-nvfp4`
- `desktop-vllm/glm-5.3-flash-exl3-k4`
- `desktop-vllm/glm-5.3-flash-exl3-k4-vision`
- `desktop-vllm/glm-5.3-flash-exl3-k4-vision-mtp`
- `desktop-vllm/qwen3.8-27b`
- `desktop-vllm/qwen3.8-flash-next-fp8`
- `desktop-muse/muse-glimmer-30b`

DeepSeek, GLM, and Qwen alternate on port 8000. Muse runs concurrently on port 8001 when
GPU capacity permits. Every launcher synchronizes the DeepSeek, Qwen, GLM, and Muse key
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
model catalog assigns DeepSeek Flash a model-specific default of `max`. The pinned Pi
package carries a small upstream patch that applies this default to new sessions and model
switches without modifying Pi's global cloud-model default. Explicit `--thinking` and
scoped `model:level` values win, and resumed sessions preserve their recorded level. Use
`Shift+Tab` to cycle `off → low → high → max`. The command-line equivalent is:

```bash
pi --model desktop-vllm/deepseek-v4-flash:max
```

The server may be offline while editing or selecting the catalog, but it must be running
before sending a prompt. Verify discovery without contacting the server:

```bash
pi --list-models deepseek-v4-flash
```

### GLM-5.3 Flash NVFP4

The experimental vLLM v2 profile serves text plus one image from the immutable
`local-inference-lab/GLM-5.3-Flash-NVFP4` revision at a 262,144-token qualification
context. Its checkpoint template supports `low`, `high`, and `max` reasoning effort;
Pi hides the other levels and defaults GLM sessions to `max`. The model remains
selectable while offline, but it must not replace a qualified Qwen/DeepSeek service
until the SM120, TP2 capacity, long-context, and image gates in the dated runbook pass.

```bash
pi --list-models glm-5.3-flash-nvfp4
pi --model desktop-vllm/glm-5.3-flash-nvfp4:max
```

### GLM-5.3 Flash EXL3 K4

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
same 98,304-token multimodal boundary but follows the supplied 0.986-utilization recipe and
requires separate local capacity, vision, and output-parity qualification.

```bash
pi --list-models glm-5.3-flash-exl3-k4
pi --model desktop-vllm/glm-5.3-flash-exl3-k4:max
pi --list-models glm-5.3-flash-exl3-k4-vision
pi --model desktop-vllm/glm-5.3-flash-exl3-k4-vision:max
pi --list-models glm-5.3-flash-exl3-k4-vision-mtp
pi --model desktop-vllm/glm-5.3-flash-exl3-k4-vision-mtp:max
```

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

### Muse Glimmer 30B

Muse Glimmer runs the BF16 language model and official BF16 DFlash draft at its native
131,072-token context. The initial profile is text-only. Pi maps `low`, `medium`, `high`,
and `xhigh` into the checkpoint's `chat_template_kwargs.reasoning_strength` value and
hides unsupported off, minimal, and max levels. SGLang's native `muse` parsers expose the
model's ATEM reasoning and tool protocol as OpenAI-compatible fields.

```bash
pi --list-models muse-glimmer-30b
pi --model desktop-muse/muse-glimmer-30b:xhigh
```

The separate provider is required because Muse listens on port 8001 while Qwen remains on
port 8000. Both `desktop-vllm/*` and `desktop-muse/*` are explicitly classified as local by
`model-routing.json`, so nested Pi workloads inherit either local parent exactly.

## Child Model Routing

`model-routing.json` is the explicit policy boundary between parent-session models and
nested Pi workloads. Provider names, endpoint URLs, and model prices are never used to
guess whether a model is local.

The policy classifies `desktop-vllm/*` and `desktop-muse/*` as local and applies this invariant:

| Active parent | Subagent launch binding |
|---|---|
| Explicitly classified local model | Exact parent model and thinking level |
| Cloud model | Agent's declared `model:` binding |
| Unknown/unclassified model | Agent's declared `model:` binding |

An agent without `model:` retains Pi's configured child default under cloud/unknown
parents, but follows the parent under a local parent. The one deliberate override:
under a local parent, **every** child — including Loom's calibrated declarations
such as `openai-codex/gpt-5.6-sol:high` — inherits the parent's exact model and
thinking level. Loom's own model guard is reconciled to this: it proves the
synced render and spawn scope, and defers the effective Pi binding to this
launcher policy (Claude Code spawns still require the declared binding exactly).
No Loom source or generated agent file needs routing-specific changes.

Every child receives one routing decision snapshotted at the beginning of its parent tool
call. Parallel tasks and chains therefore cannot drift if `/model` changes concurrently.
Local overrides launch with one exact `--model` plus `--thinking` pair and no cloud
fallback list. Routing policy parse failures stop before spawn, while declared model
expressions remain opaque so Pi can resolve aliases and colon-bearing model IDs. Tool-result
details retain the declared binding, effective binding, rule ID, parent
class, and SHA-256 policy digest for auditability.

Rules can select by `parentClass`, `parentModel`, `workload`, Loom `model-profile`, and
agent name. Every additional selector increases specificity; the most-specific matching
rule wins. Equal-specificity rules that could match the same request are rejected. The
tracked policy publishes `qwen` and `glm` as named exact targets beside parent inheritance:

```json
{
  "targets": {
    "qwen": {
      "model": "desktop-vllm/qwen3.8-27b",
      "thinkingLevel": "xhigh"
    },
    "glm": {
      "model": "desktop-vllm/glm-5.3-flash-exl3-k4-vision-mtp",
      "thinkingLevel": "max"
    }
  }
}
```

A `declared` target preserves an agent declaration, `parent` uses the snapshotted parent
binding, and `named` chooses one configured exact target. Add a more-specific rule referring
to `qwen` or `glm` when a workload should intentionally differ from its parent; do not embed
model IDs in extension code.

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
    "../../dev/claude-plugins/loom",
    "git:github.com/peterstorm/pi-goal@v0.1.0",
    "../../dev/claude-plugins/cortex",
    "../../dev/claude-plugins/obsidian"
  ]
}
```

Local paths are relative to `~/.pi/agent/` (the agentDir). The Pi Goal entry is instead an immutable Git release; Pi installs it under `~/.pi/agent/git/` and does not depend on a development worktree. Packages may declare resources in a `package.json` Pi manifest or expose Pi's conventional resource directories. Loom, Pi Goal, and Cortex use manifests; Obsidian's conventional `skills/` directory exposes `obsidian-vault` from the same canonical source used by its Claude plugin. The Home Manager Claude workspace activation provisions the local plugin checkouts, while Pi owns the pinned Pi Goal clone. Use Obsidian from Pi as `/skill:obsidian-vault` or ask naturally about the vault.

Pi Goal is a standalone Pi extension from `github.com/peterstorm/pi-goal`; it provides `/goal` and loads after Loom so its optional `review-and-fix-clean` evaluator can consume Loom's process-local review authority. Loom's native `pi/extension.ts` owns Loom guards and subagent-result state transitions; do not add a separate Loom bridge extension because it would process the same completion events twice.

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

1. Create a directory: `pi/extensions/my-extension/`
2. Add an `index.ts` that exports a default function:
   ```typescript
   import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
   export default function (pi: ExtensionAPI) {
     // Register tools, hooks, commands
   }
   ```
3. Run `home-manager switch` to symlink it

## Editing Extensions

Files in `pi/extensions/` are real source files in your dotfiles repo. Edit directly:

```bash
$EDITOR ~/.dotfiles/pi/extensions/subagent/agents.ts
```

Changes take effect immediately — no rebuild needed.
