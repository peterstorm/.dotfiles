---
name: refactor-note
description: Split a large note into atomic notes with back-links, or merge related notes
argument-hint: "<path-to-note>"
allowed-tools: ["Read", "Write", "Edit", "Glob", "Grep", "AskUserQuestion"]
---

Refactor a note in the Obsidian vault at `/home/peterstorm/dev/notes/remotevault/`.

Load the `obsidian-vault` skill for conventions.

## Split Flow (default)

1. **Read the note** at specified path
2. **Identify split points**: each `##` heading or distinct concept = potential atomic note
3. **Propose splits** to user:
   ```
   Split "Big Note" into:
   1. concept-a.md — "Section about concept A"
   2. concept-b.md — "Section about concept B"
   3. concept-c.md — "Section about concept C"
   Keep original as MOC linking to all splits? [y/n]
   ```
4. On confirmation:
   - Create each atomic note with proper frontmatter
   - Add `[[back-link]]` to original/sibling notes in `## Related` section
   - Either convert original into a MOC linking to splits, or delete it
   - Update parent MOC with new note entries

## Merge Flow

If user asks to merge notes:
1. Read all specified notes
2. Combine content under unified headings
3. Create single note with merged frontmatter (union of tags, earliest date)
4. Add all wikilinks from source notes
5. Delete source notes
6. Update MOCs to reference merged note

Always confirm destructive actions (delete, overwrite) with user before executing.
