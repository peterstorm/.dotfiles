---
name: yt-summary
description: "Summarizes YouTube videos by extracting transcripts and producing structured summaries. Use when user pastes a YouTube URL and wants a summary, key takeaways, or notes from a video. Supports youtube.com and youtu.be links."
allowed-tools: Read, Bash, WebFetch, WebSearch, Write
---

# YouTube Video Summarizer

Extracts transcripts from YouTube videos and produces concise, structured summaries.

## Input Detection

Detect input from `$ARGUMENTS`:

1. **YouTube URL** (`youtube.com`, `youtu.be`) — extract video ID and fetch transcript
2. **Flags** — strip before processing (see below)
3. **Non-YouTube input** — inform user this skill is for YouTube videos only

## Flags

- `--detailed` — longer summary with section-by-section breakdown
- `--timestamps` — include approximate timestamps for key sections
- `--bullets` — output as bullet points only, no prose

Flags can appear anywhere in `$ARGUMENTS`. Strip them before processing.

## Transcript Extraction

Extract the video ID from the URL (`v=` param, or path segment for `youtu.be` links).

Use `nix-shell` for ephemeral transcript fetching — no permanent installation:

```bash
nix-shell -p python3Packages.youtube-transcript-api --run "python3 -c \"
from youtube_transcript_api import YouTubeTranscriptApi
ytt = YouTubeTranscriptApi()
transcript = ytt.fetch('<VIDEO_ID>')
for entry in transcript:
    print(entry.text)
\""
```

Filter out nix store download noise (lines starting with `these`, `copying`, `  /nix`) from stdout before processing.

**Fallback chain:**
1. **nix-shell + youtube-transcript-api** (primary — works for any public video, no API key needed)
2. **If nix is unavailable**, try: `yt-dlp --write-auto-sub --skip-download --sub-lang en -o "/tmp/%(id)s" <URL>` then read the generated .vtt file
3. **If both fail**, ask the user to paste the transcript text directly

Never attempt to summarize placeholder/error text. If extraction fails, stop and ask for content.

### Timestamp Extraction (when `--timestamps` flag used)

Use this variant to capture start times:

```bash
nix-shell -p python3Packages.youtube-transcript-api --run "python3 -c \"
from youtube_transcript_api import YouTubeTranscriptApi
ytt = YouTubeTranscriptApi()
transcript = ytt.fetch('<VIDEO_ID>')
for entry in transcript:
    minutes = int(entry.start // 60)
    seconds = int(entry.start % 60)
    print(f'[{minutes:02d}:{seconds:02d}] {entry.text}')
\""
```

## Output Format

### Default Summary

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
🎬 [Video Title — inferred from content]
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

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

### With `--detailed`

Add after the default output:

```
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
```

### With `--bullets`

Replace all prose with bullet points:

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
🎬 [Video Title]
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
   source: [YouTube URL]
   date: YYYY-MM-DD
   speaker: [Speaker name if identified]
   type: yt-summary
   ---
   ```
5. Write the full summary (matching whichever format was used — default, detailed, bullets) as the note body
6. Confirm save path to user

## Summary Principles

- **Be concise** — the point is to save the viewer time
- **Preserve specifics** — keep concrete numbers, names, tools, and actionable details
- **Skip filler** — ignore intros, outros, subscribe reminders, sponsor segments
- **Note bias** — if the video is selling something, briefly note that in the speaker context
- **Non-English content** — if transcript is not English, summarize in English but note original language
