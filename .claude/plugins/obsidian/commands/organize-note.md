---
name: organize-note
description: Clean up a single note — fix frontmatter, suggest wikilinks, update MOC
argument-hint: "<path-to-note>"
allowed-tools: ["Read", "Write", "Edit", "Glob", "Grep"]
---

Clean up a single note in the Obsidian vault at `/home/peterstorm/dev/notes/remotevault/`.

Load the `obsidian-vault` skill for conventions.

## Process

1. **Read the note** at the specified path
2. **Fix frontmatter**: add or correct YAML block to match standard (title, date, tags, aliases, up)
   - Infer title from filename or first `#` heading
   - Infer tags from content and folder location
   - Set `up` to the folder's MOC
3. **Scan for linkable terms**: Grep vault for notes whose titles/aliases appear in this note's content → suggest wikilinks
4. **Check MOC**: ensure the note is listed in its parent `MOC.md`. If not, add it.
5. **Log**: append changelog entry: `- **organized** [[note-name]] — <summary of changes>`
6. **Report**: what was changed, links suggested
