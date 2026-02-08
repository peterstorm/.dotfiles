---
name: add-note
description: Create a new note in the Obsidian vault with proper frontmatter, linking, and placement
argument-hint: "[topic] [content]"
allowed-tools: ["Read", "Write", "Edit", "Glob", "Grep", "AskUserQuestion"]
---

Create a new atomic note in the Obsidian vault at `/home/peterstorm/dev/notes/remotevault/`.

Load the `obsidian-vault` skill for vault conventions and methodology.

## Determine Mode

If the user provided a clear topic AND content → use **direct mode**.
If the user described an idea loosely → use **conversational mode**.

### Direct Mode

1. Scan vault with Grep for existing notes on same/related topics
2. Determine correct folder from vault structure
3. Create note file using lowercase-with-dashes naming
4. Add standard frontmatter (title, date, tags, aliases, up)
5. Write content
6. Add `## Related` section
7. Propose 1-3 wikilinks with reasoning — ask user to confirm each
8. Update parent `MOC.md` with link to new note

### Conversational Mode

Ask these questions one at a time using AskUserQuestion:
1. Core idea — what's the one-sentence insight?
2. Domain/category — which area does this belong in?
3. Connections — does this relate to existing notes?
4. Tags — what themes does this touch?

Then proceed with direct mode steps.

## Always

- Search vault before creating to avoid duplicates
- Propose links with reasoning, never add silently
- Update the parent MOC after creating
- Append changelog entry: `- **added** [[note-name]] to \`folder/\``
