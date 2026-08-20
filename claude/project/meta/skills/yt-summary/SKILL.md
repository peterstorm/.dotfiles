---
name: yt-summary
description: "Summarizes YouTube videos by extracting transcripts and producing structured summaries. Use when user pastes a YouTube URL (youtube.com, youtu.be, shorts, live) and wants a summary, key takeaways, notes, or the transcript of a video. NOT for downloading videos/audio or summarizing articles and other non-YouTube content."
allowed-tools: Read, Bash, WebFetch, WebSearch, Write
---

# YouTube Video Summarizer

Extracts transcripts from YouTube videos and produces concise, structured summaries.

## Input Detection

Detect input from `$ARGUMENTS`:

1. **YouTube URL** — extract the video ID from any of these forms:
   - `youtube.com/watch?v=<ID>` (`v=` query param)
   - `youtu.be/<ID>` (first path segment; ignore `?si=` and other params)
   - `youtube.com/shorts/<ID>`, `youtube.com/live/<ID>`, `youtube.com/embed/<ID>`
2. **Flags** — strip before processing (see below)
3. **Non-YouTube input** — inform user this skill is for YouTube videos only

## Flags

- `--brief` — short summary with key takeaways only (no section breakdown)
- `--timestamps` — include approximate timestamps for key sections
- `--bullets` — output as bullet points only, no prose

Flags can appear anywhere in `$ARGUMENTS`. Strip them before processing.

## Step 1: Fetch Video Metadata

Get the real title and channel via YouTube's oEmbed endpoint (no API key, works for any public video):

```bash
curl -s "https://www.youtube.com/oembed?url=https://www.youtube.com/watch?v=<VIDEO_ID>&format=json"
```

Use `title` and `author_name` in the output header. If this fails, continue anyway and infer the title from transcript content.

## Step 2: Extract Transcript

Use `nix-shell` for ephemeral fetching — no permanent installation. The script lives in this skill's `scripts/` directory; resolve its absolute path from this SKILL.md's location. Redirect stderr to a scratch file so nix noise never mixes into the transcript, then read the file: it may contain a `NOTE:` line (language fallback / auto-translation — mention it in the output) or an `ERROR` line.

```bash
nix-shell -p python3Packages.youtube-transcript-api --run \
  "python3 <skill-dir>/scripts/fetch_transcript.py <VIDEO_ID>" 2><scratch>/yt-err.log
```

Add `--timestamps` to the script args when the `--timestamps` flag was given (prints `[MM:SS]`/`[H:MM:SS]` prefixes). `--languages en,da` overrides the preferred-language list if the user asks for a specific language.

**Exit codes** (from the script):
- `0` — transcript on stdout; check the log for a `NOTE:` line
- `2` — video has no captions at all (disabled/unavailable). yt-dlp won't help either → ask the user to paste the transcript
- `3` — YouTube is blocking this IP (bot detection) → try the yt-dlp fallback **with** `--cookies-from-browser chrome`
- `1` / other — read the log, then try the yt-dlp fallback

**yt-dlp fallback** (also the primary path if nix is unavailable). Prefers creator-uploaded captions over auto-generated; SRT is much cleaner than VTT for auto-captions:

```bash
yt-dlp --skip-download --write-subs --write-auto-subs --sub-langs en \
  --convert-subs srt -o "<scratch>/%(id)s" "<URL>"
```

Read the generated `.srt` from the scratch directory. Add `--cookies-from-browser chrome` if YouTube blocks the request. If both extractors fail, ask the user to paste the transcript text directly.

Never attempt to summarize placeholder/error text. If extraction fails, stop and ask for content.

**Long videos:** a multi-hour transcript can be very large. Read it in chunks if needed, but always summarize from the full content — never from just the beginning.

## Output Format

### Default Summary (Detailed)

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
🎬 [Title — from oEmbed, else inferred] · [Channel]
🔗 [YouTube URL]
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

**TL;DR:** [2-3 sentence summary of the entire video]

**Key Takeaways:**
1. [Most important point]
2. [Second most important point]
3. [Third most important point]
(up to 5-7 takeaways depending on video length)

**Who's talking:** [Speaker/channel context if identifiable]
**Who it's for:** [Target audience]

**Section Breakdown:**

### [Section 1 Title] [timestamp if available]
[2-3 sentence summary]

### [Section 2 Title] [timestamp if available]
[2-3 sentence summary]

...

**Notable Quotes:**
- "[Exact or near-exact quote]"
- "[Another quote]"

**Links/Resources Mentioned:**
- [Any tools, books, websites referenced in the video]

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

### With `--brief`

Same header, TL;DR, Key Takeaways, Who's talking / Who it's for — then stop. No section breakdown, quotes, or resources.

### With `--bullets`

Header, then flat bullet points only — no prose, no sections:

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
🎬 [Title] · [Channel]
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

- [Key point 1]
- [Key point 2]
- [Key point 3]
...
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

## Save as Note

After displaying the summary, ask the user if they want to save it as a note.

If yes:
1. Resolve the notes directory: `~/.dotfiles/.claude/notes/` (use `$HOME` to expand `~` at runtime)
2. Create the directory if it doesn't exist: `mkdir -p "$HOME/.dotfiles/.claude/notes/"`
3. Filename: `YYYY-MM-DD-[slugified-video-title].md`
4. Format the note as markdown with frontmatter:
   ```yaml
   ---
   title: [Video title]
   source: [YouTube URL]
   channel: [Channel name]
   date: YYYY-MM-DD
   speaker: [Speaker name if identified]
   type: yt-summary
   ---
   ```
5. Write the full summary (matching whichever format was used — default, brief, bullets) as the note body
6. Confirm save path to user

## Summary Principles

- **Be concise** — the point is to save the viewer time
- **Preserve specifics** — keep concrete numbers, names, tools, and actionable details
- **Skip filler** — ignore intros, outros, subscribe reminders, sponsor segments
- **Note bias** — if the video is selling something, briefly note that in the speaker context
- **Non-English content** — if the transcript was auto-translated or is in another language (the script prints a `NOTE:` when so), summarize in English and note the original language
