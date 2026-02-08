---
description: >
  This skill should be used when the user asks to "add a note", "create a note",
  "organize my vault", "audit vault", "find orphan notes", "find links",
  "refactor a note", "split a note", "merge notes", "add frontmatter",
  "fix frontmatter", "add tags", "create MOC", "link notes",
  "obsidian", "vault", "zettelkasten", or mentions note-taking, knowledge management,
  or second brain workflows. Manages an Obsidian vault using Zettelkasten/MOC methodology
  with enforced frontmatter standards, wikilink conventions, and folder structure.
version: 0.1.0
user-invocable: true
---

# Obsidian Vault Management

Manage an Obsidian vault at `/home/peterstorm/dev/notes/remotevault/` using filesystem operations. All interactions use Read, Write, Edit, Glob, and Grep tools — no MCP or REST API dependency.

## Core Methodology

### Zettelkasten Principles
- **Atomic notes**: one idea per note, self-contained
- **Link everything**: every note connects to at least one other note via wikilinks `[[note-name]]`
- **Bottom-up structure**: let organization emerge from connections, not rigid categories
- **MOCs (Maps of Content)**: index notes that curate links to related notes on a topic

### Note Lifecycle
1. **Capture**: create note with content
2. **Format**: add frontmatter, apply naming conventions
3. **Link**: connect to existing notes via wikilinks
4. **Place**: file in correct folder, update parent MOC
5. **Log**: append entry to changelog
6. **Review**: periodically find orphans and missing links

## Changelog

The vault maintains a changelog at `changelog.md` in the vault root. Every command that modifies the vault appends an entry.

### Changelog Format
```markdown
---
title: Changelog
date: 2026-02-04
tags: [moc, reference]
aliases: []
up: "[[_index]]"
---
# Changelog

## 2026-02-08

- **added** [[new-note-name]] to `concepts/`
- **organized** [[messy-note]] — fixed frontmatter, added 3 wikilinks
- **refactored** [[big-note]] → split into [[part-a]], [[part-b]], [[part-c]]
- **vault audit** — fixed 12 frontmatter, created 3 MOCs, resolved 5 orphans
```

### Entry Rules
- Group entries under `## YYYY-MM-DD` date headings
- If today's date heading exists, append under it; otherwise create it at the top (below frontmatter)
- Use bold action verb: **added**, **organized**, **refactored**, **merged**, **moved**, **vault audit**
- Wikilink all note names
- Keep entries single-line

### When to Log
All commands that modify notes: `add-note`, `organize-note`, `organize-vault`, `refactor-note`. Read-only commands (`find-orphans`, `find-links`) do not log.

## Vault Conventions

### Folder Structure
```
remotevault/
├── changelog.md           # Vault changelog
├── _index.md              # Vault entry point MOC
├── archive/               # Legacy projects, read-only
│   └── MOC.md
├── business/              # Business planning (dotslash.dev)
│   └── MOC.md
├── concepts/              # DDD, FP theory, patterns
│   └── MOC.md
├── homelab/               # Infrastructure, k8s, networking
│   └── MOC.md
├── languages/             # Haskell, Scala, Nix
│   └── MOC.md
├── personal/              # Recipes, workout, travel
│   └── MOC.md
├── programming/           # General programming (React, etc.)
│   └── MOC.md
├── reading/               # Book notes
│   └── MOC.md
├── work/                  # Work-related (oister)
│   └── MOC.md
└── pastedImages/
```

### Frontmatter Standard
Every note MUST have this frontmatter:
```yaml
---
title: Note Title
date: YYYY-MM-DD
tags: [tag1, tag2]
aliases: [alternate name]
up: "[[MOC]]"
---
```

- `title`: human-readable name
- `date`: creation date
- `tags`: lowercase, for filtering/search across domains
- `aliases`: alternate names so wikilinks work with different phrasings
- `up`: link to parent MOC for hierarchy navigation

### Naming Conventions
- **Notes**: lowercase-with-dashes (`nix-flake-overlays.md`)
- **MOCs**: always `MOC.md` inside their folder
- **No date prefixes** in filenames (date lives in frontmatter)

### MOC Format
MOCs are curated index notes, not auto-generated dumps:
```markdown
---
title: Languages
date: 2026-02-04
tags: [moc]
aliases: []
up: "[[_index]]"
---
# Languages

## Haskell
- [[type-level-programming]] - Type-level programming patterns
- [[monad-transformers]] - Monad transformer patterns

## Scala
- [[zio-basics]] - ZIO fundamentals

## Nix
- [[nix-flake-patterns]] - Flake configuration patterns
```

### Wikilink Conventions
- Use `[[note-name]]` format (filename without `.md`)
- Add pipe for display text when needed: `[[note-name|Display Text]]`
- Place contextual links inline where relevant
- Add a `## Related` section at note bottom for broader connections

## Note Creation Workflow

### Direct Mode
When user provides topic + content:
1. Scan vault for existing notes on same/related topics using Grep
2. Check if a note with the target filename already exists — if so, propose merging or renaming
3. Determine correct folder placement
3. Create note with frontmatter, content, and `## Related` section
4. Propose 1-3 wikilinks with reasoning — wait for confirmation
5. Update parent MOC with link to new note

### Conversational Mode
When user describes an idea loosely:
1. Ask about the **core idea** (what's the one-sentence insight?)
2. Ask about **domain/category** (which folder does this belong in?)
3. Ask about **connections** (does this relate to any existing work?)
4. Ask about **tags** (what themes does this touch?)
5. Then create the note following direct mode steps

### Link Discovery During Creation
On every note create:
- Search vault for notes sharing tags or keywords
- Check existing MOCs for related entries
- Propose links with reasoning: "this relates to [[X]] because..."
- Never add links silently — always confirm with user

## Vault Organization

### Full Vault Audit (`organize vault`)
1. Scan all notes for missing/malformed frontmatter → fix
2. Identify orphan notes (zero wikilinks in/out) → suggest placement and links
3. Reorganize folders per vault structure conventions
4. Create missing MOCs from note clusters
5. Create/update `_index.md` vault entry point
6. Report: notes processed, links added, orphans resolved

### Single Note Cleanup (`organize note`)
1. Add/fix frontmatter to match standard
2. Scan for linkable terms in content → suggest wikilinks
3. Ensure note appears in parent MOC

### Orphan Detection (`find orphans`)
- List all notes with zero inbound/outbound wikilinks
- For each, suggest: which MOC it belongs under, 1-2 link candidates

### Cross-Domain Link Discovery (`find links`)
- Scan vault for notes sharing tags/concepts but not linked
- Output suggestions with reasoning

### Note Refactoring (`refactor note`)
- Read note, identify distinct ideas (one per heading or concept)
- Propose split points to user
- On confirmation: create individual atomic notes with back-links, update MOC

## Additional Resources

### Reference Files

Read `references/folder-mapping.md` before executing a vault reorganization. Read `references/tag-taxonomy.md` when assigning tags to new or existing notes.

- **`references/folder-mapping.md`** - Maps old folder names to new structure
- **`references/tag-taxonomy.md`** - Recommended tag hierarchy for consistent tagging
