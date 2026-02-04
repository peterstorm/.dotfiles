---
name: find-orphans
description: List all notes with zero inbound or outbound wikilinks and suggest connections
allowed-tools: ["Read", "Glob", "Grep"]
---

Find all orphan notes in the Obsidian vault at `/home/peterstorm/dev/notes/remotevault/`.

Load the `obsidian-vault` skill for conventions.

## Process

1. **Glob** all `.md` files in vault (exclude `.obsidian/`, `.trash/`, `pastedImages/`)
2. For each note, check:
   - **Outbound links**: does the note contain any `[[wikilinks]]`?
   - **Inbound links**: does any other note link to this note's filename?
3. **Classify**:
   - **Full orphan**: no inbound AND no outbound links
   - **Partial orphan**: has outbound but no inbound (nothing links TO it)
4. For each orphan, suggest:
   - Which MOC it should appear in
   - 1-2 notes it could link to (based on tags, folder, content keywords)
5. **Report** as a table:
   ```
   | Note | Type | Suggested MOC | Suggested Links |
   ```

Do NOT make changes — only report findings and suggestions.
