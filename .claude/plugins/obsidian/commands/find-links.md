---
name: find-links
description: Discover cross-domain link opportunities between notes that share concepts but aren't connected
allowed-tools: ["Read", "Glob", "Grep"]
---

Discover missing cross-domain links in the Obsidian vault at `/home/peterstorm/dev/notes/remotevault/`.

Load the `obsidian-vault` skill for conventions.

## Process

1. **Glob** all `.md` files (exclude `.obsidian/`, `.trash/`, `pastedImages/`)
2. **Build tag map**: read frontmatter of each note, group notes by tags
3. **Find shared-tag pairs**: notes sharing 2+ tags that don't already link to each other
4. **Keyword scan**: for each note, extract key terms from headings and content. Search vault for other notes containing those terms.
5. **Cross-domain focus**: prioritize suggestions that connect notes across different folders (e.g., `reading/` ↔ `business/`, `concepts/` ↔ `languages/`)
6. **Report** suggestions with reasoning:
   ```
   [[domain-driven-design-basics]] ↔ [[agency-architecture]]
     reason: both discuss bounded contexts
     shared tags: [ddd, pattern]
   ```

Do NOT make changes — only report findings. Let user decide which links to add.
