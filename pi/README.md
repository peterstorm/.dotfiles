# Pi Agent Configuration

This directory contains the pi coding agent configuration managed by home-manager. Files here are symlinked to `~/.pi/agent/` at activation time.

## Directory Structure

```
pi/
├── agents/           # Generic agents this repo owns (→ linked per file)
├── extensions/       # Custom extensions (→ ~/.pi/agent/extensions/)
│   ├── subagent/     # Generic subagent tool with skill injection
│   └── global-instructions.ts  # Standalone extension
├── prompts/          # Prompt templates (→ ~/.pi/agent/prompts/)
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
3. **Settings**: Copies `settings.json` on activation (preserves `lastChangelogVersion`)

### Why Directory Symlinks?

Using a single symlink per directory (instead of per-file) means:
- **Adding new files needs no rebuild** — just create the file in the dotfiles repo
- **Edits are live immediately** — no `home-manager switch` needed
- **Removing files just works** — delete from repo, done
- **`home-manager switch` only needed** when the nix module itself changes

`agents/` is the exception, because it is not purely source — Loom generates
into it.

## Packages (Plugins)

Pi loads packages from `settings.json`:

```json
{
  "packages": [
    "../../dev/claude-plugins/loom",
    "../../dev/claude-plugins/cortex"
  ]
}
```

Paths are relative to `~/.pi/agent/` (the agentDir). Each package has a `package.json` with a `pi` manifest declaring its extensions, skills, and prompts. Loom's native `pi/extension.ts` owns Loom guards and subagent-result state transitions; do not add a separate Loom bridge extension because it would process the same completion events twice.

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
bun test pi/extensions/subagent/agents.test.ts
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
