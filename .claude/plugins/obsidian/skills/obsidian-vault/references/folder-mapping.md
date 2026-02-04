# Folder Mapping: Old → New

Migration map for vault reorganization. Use during `organize vault` command.

## Renames

| Old Path | New Path | Notes |
|----------|----------|-------|
| `dotslash.dev/` | `business/` | Including all subdirs (smart_website_agency/, chatbot/, plans/, pricing/, research/, seo-automation/) |
| `oister/` | `work/` | Including subdirs (code/, flexii/, infrastructure/, viaplay/) |
| `undo/` | `archive/` | All 13 legacy project folders |

## Merges

| Old Paths | New Path | Notes |
|-----------|----------|-------|
| `haskell/`, `scala/`, `nix/` | `languages/` | Create subdirs per language inside: `languages/haskell/`, `languages/scala/`, `languages/nix/` |

## Unchanged

| Path | Notes |
|------|-------|
| `concepts/` | Keep as-is |
| `homelab/` | Keep as-is |
| `personal/` | Keep as-is (includes computerStuff/, recipes/, workout/) |
| `programming/` | Keep as-is |
| `reading/` | Keep as-is |
| `pastedImages/` | Keep as-is |

## New Directories

| Path | Purpose |
|------|---------|
| `archive/` | Created from `undo/`, gets `MOC.md` |
| `_index.md` | Vault entry point MOC at root |

## Files to Create During Reorganization

Each folder gets a `MOC.md` if it doesn't have one:
- `_index.md` (root)
- `archive/MOC.md`
- `business/MOC.md`
- `concepts/MOC.md`
- `homelab/MOC.md`
- `languages/MOC.md`
- `personal/MOC.md`
- `programming/MOC.md`
- `reading/MOC.md`
- `work/MOC.md`

## Wikilink Updates

After renaming/moving files, scan ALL notes for broken wikilinks and update them to reflect new filenames/locations. Obsidian resolves wikilinks by filename (not path), so moves within the vault generally don't break links — but renames do.
