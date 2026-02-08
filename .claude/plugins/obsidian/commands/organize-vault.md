---
name: organize-vault
description: Full vault audit — fix frontmatter, create MOCs, reorganize folders, archive legacy, resolve orphans
allowed-tools: ["Read", "Write", "Edit", "Glob", "Grep", "Bash", "TodoWrite", "AskUserQuestion"]
---

Run a full audit and reorganization of the Obsidian vault at `/home/peterstorm/dev/notes/remotevault/`.

Load the `obsidian-vault` skill for vault conventions. Reference `references/folder-mapping.md` for rename/merge mapping and `references/tag-taxonomy.md` for tag standards.

## Process

Use TodoWrite to track progress through these steps:

### 1. Scan Vault State
- Glob all `.md` files
- Count notes per folder
- List notes missing frontmatter
- List orphan notes (no wikilinks in/out)
- Report current state to user

### 2. Reorganize Folders
Per folder-mapping.md:
- Rename `dotslash.dev/` → `business/`
- Rename `oister/` → `work/`
- Move `undo/` → `archive/`
- Merge `haskell/`, `scala/`, `nix/` → `languages/` (with subdirs)
- Confirm with user before executing moves

### 3. Fix Frontmatter
For each note missing or malformed frontmatter:
- Add standard YAML block (title, date, tags, aliases, up)
- Infer title from filename or first heading
- Infer tags from folder and content
- Set `up` to parent MOC

### 4. Create MOCs
For each folder, create `MOC.md` listing all notes in that folder with brief descriptions. Create `_index.md` at vault root linking to all MOCs.

### 5. Resolve Orphans
For each orphan note:
- Suggest which MOC it belongs under
- Suggest 1-2 wikilink candidates
- Ask user to confirm before adding links

### 6. Log
Append changelog entry: `- **vault audit** — <summary: N frontmatter fixed, N MOCs created, N orphans resolved, N folders reorganized>`

### 7. Report
Summary: notes processed, frontmatter fixed, MOCs created, orphans resolved, folders reorganized.
