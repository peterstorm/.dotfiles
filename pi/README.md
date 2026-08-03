# Pi Agent Configuration

This directory contains the pi coding agent configuration managed by home-manager. Files here are symlinked to `~/.pi/agent/` at activation time.

## Directory Structure

```
pi/
├── agents/           # Agent markdown files (→ ~/.pi/agent/agents/)
├── extensions/       # Custom extensions (→ ~/.pi/agent/extensions/)
│   ├── subagent/     # Generic subagent tool with skill injection
│   └── global-instructions.ts  # Standalone extension
├── prompts/          # Prompt templates (→ ~/.pi/agent/prompts/)
├── settings.json     # Pi settings (copied, not symlinked — mutable at runtime)
└── README.md         # This file
```

## How It Works

The nix home-manager module at `roles/home-manager/core-apps/pi/default.nix`:

1. **Agents/Extensions/Prompts**: Creates directory-level symlinks:
   ```
   ~/.pi/agent/agents     → ~/.dotfiles/pi/agents
   ~/.pi/agent/extensions → ~/.dotfiles/pi/extensions
   ~/.pi/agent/prompts    → ~/.dotfiles/pi/prompts
   ```
2. **Settings**: Copies `settings.json` on activation (preserves `lastChangelogVersion`)

### Why Directory Symlinks?

Using a single symlink per directory (instead of per-file) means:
- **Adding new files needs no rebuild** — just create the file in the dotfiles repo
- **Edits are live immediately** — no `home-manager switch` needed
- **Removing files just works** — delete from repo, done
- **`home-manager switch` only needed** when the nix module itself changes

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

## Package Agents

Pi packages do not natively expose an `agents` resource. The custom subagent extension therefore discovers a conventional `agents/` directory from every configured **local** package in `settings.json`. Package agents load before user agents, and project agents load last, giving this override order:

`package < user < project`

This makes Loom's full roster available automatically when the Loom checkout adds an agent. The tracked per-agent symlinks remain for compatibility and immediate use in already-running Pi sessions, but correctness no longer depends on manually updating that list. In particular, both panel workflows are covered:

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
3. Resolves those relative paths to absolute skill directories
4. Passes them to `loadSkills({ skillPaths: [...] })`

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
bun pi/verify-agent-install.ts
nix flake check --no-build
```

Expected skill-injection output includes:
```
architecture-agent → [architecture-tech-lead]
grill-agent → [grill]
java-test-agent → [java-test-engineer]
code-implementer-agent → [code-implementer]
ts-test-agent → [ts-test-engineer]
deepen-agent → [deepen]
frontend-agent → [nextjs-frontend-design]
security-agent → [security-expert]
```

## Adding a New Agent

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
4. Run `home-manager switch` (or the file is already live if `.pi/agent/` points here)

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
