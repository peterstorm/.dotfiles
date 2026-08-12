---
name: idea-analyzer
description: "Critically analyzes business ideas from documents, YouTube transcripts, blog posts, URLs, or pasted text. Detects hype/affiliate marketing, assesses viability, and evaluates fit for dotslash.dev — an AI consultancy AND productized SMB agency targeting Copenhagen. Use when user mentions 'analyze this idea', 'is this worth pursuing', 'evaluate this', 'idea-analyzer', or pastes content asking if a business idea is good. Supports deep analysis with competitive research."
allowed-tools: Read, Bash, WebFetch, WebSearch, Glob, Grep, Write, Edit
---

# Idea Analyzer

Critically evaluate business ideas from any media source. Filter hype from substance. Assess fit for dotslash.dev — both the AI consulting segment and the productized SMB offering.

## Input Detection

Detect input type from `$ARGUMENTS`:

1. **Starts with `http`/`https`** → URL
   - YouTube URL (`youtube.com`, `youtu.be`) → see YouTube Extraction below
   - Any other URL → WebFetch to extract article content
2. **Starts with `/` or `~`** → file path → Read tool
3. **Flag: `--refresh-context`** → regenerate business context (see below)
4. **Everything else** → treat as pasted text content

### YouTube Extraction

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

Never attempt to analyze placeholder/error text. If extraction fails, stop and ask for content.

### Extraction Failure Handling

If content extraction fails for any reason (paywall, 403, empty content, broken URL, missing file):
- Inform the user what failed and why
- Ask them to paste the content directly
- Do NOT attempt to analyze error messages or partial/placeholder content

## Flags

- `--deep` — full structured report with competitive landscape, Danish market lens, implementation sketch
- `--save` — persist analysis as Obsidian note in `business/idea-analysis/`
- `--refresh-context` — re-read vault business notes and regenerate `references/business-context.md`

Flags can appear anywhere in `$ARGUMENTS`. Strip them before processing content.

## Analysis Process

### Step 1: Extract Content

Based on detected input type, extract the raw content to analyze. Follow the extraction and failure handling rules above.

### Step 2: Identify the Core Idea

Before scoring, extract:
- **What is the idea?** — one sentence
- **Who is it for?** — target customer
- **How does it make money?** — revenue model
- **Who's presenting it?** — source credibility context

### Step 3: Load Context & Criteria

Read evaluation criteria from reference files:
- [Hype Detection Patterns](references/hype-detection.md)
- [Business Context](references/business-context.md) — covers BOTH segments (AI consulting + SMB product)
- [Scoring Rubric](references/scoring-rubric.md)

**Important:** When assessing dotslash.dev fit, evaluate against BOTH business segments:
- Segment A: AI consulting (strategy, implementation, partnership for tech teams)
- Segment B: Productized SMB offering (chatbots + websites for Copenhagen local businesses)
An idea can fit one, both, or neither. Cross-segment fit (serves both) scores highest.

### Step 4: Output Results

Analyze in English regardless of input language. If input is in Danish, extract and translate key claims before scoring.

**Default (quick verdict):**

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
📋 IDEA: [Auto-extracted idea title]
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

🔍 Idea Viability     [🟢|🟡|🔴] [Verdict] — [One-line rationale]
⚠️ Hype/BS Score      [🟢|🟡|🔴] [Verdict] — [One-line rationale]
🏢 dotslash.dev Fit   [🟢|🟡|🔴] [Verdict] — [One-line rationale]
💰 Effort vs Payoff   [🟢|🟡|🔴] [Verdict] — [One-line rationale]

💬 One-liner: "[Actionable summary — what to do with this]"

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

For dotslash.dev Fit, specify WHICH segment(s) the idea applies to:
- "🟢 Strong fit (Segment B)" or "🟡 Explore further (both segments)" etc.

Traffic light meanings:
- 🟢 = Strong / Low risk / Strong fit / High payoff
- 🟡 = Explore further / Medium risk / Partial fit / Medium payoff
- 🔴 = Skip / High risk / Poor fit / Low payoff

Verdict labels: "Strong fit", "Explore further", "Skip", "Hype trap", "Steal one piece", "Park for later"

**With `--deep` flag:**

Produce the full structured report. See [Deep Analysis Template](references/deep-analysis-template.md) for the complete format.

When using `--deep`, you MUST:
- Use `WebSearch` to research the competitive landscape — find real companies doing this
- Use `WebSearch` to check Danish/Nordic market specifics — local players, demand signals
- Ground all sections in evidence, not speculation
- Evaluate fit against BOTH business segments separately

### Step 5: Save (if `--save`)

If `--save` flag is present:

1. Create the directory if it doesn't exist: `mkdir -p /home/peterstorm/dev/notes/remotevault/business/idea-analysis/`
2. Create file at `/home/peterstorm/dev/notes/remotevault/business/idea-analysis/YYYY-MM-DD-[slugified-idea-title].md`
3. Add frontmatter:
   ```yaml
   ---
   date: YYYY-MM-DD
   type: idea-analysis
   source: [URL or "pasted" or filename]
   verdict: [quick verdict summary]
   viability: [🟢|🟡|🔴]
   hype-risk: [🟢|🟡|🔴]
   business-fit: [🟢|🟡|🔴]
   segment-fit: [A|B|both|neither]
   tags: [idea-analysis]
   ---
   ```
4. Write the full analysis as note content
5. Add `[[MOC|Business MOC]]` and `[[dotslash.dev - Unified Business Identity]]` backlinks
6. Confirm save location to user

## Refresh Context (`--refresh-context`)

When invoked with `--refresh-context`:

1. Read vault business strategy files:
   - `business/MOC.md`
   - `business/dotslash.dev/dotslash.dev - Unified Business Identity.md`
   - `business/dotslash.dev/smb/strategy/dotslash.dev - Master Business Plan 2026.md`
   - `business/dotslash.dev/smb/strategy/Pricing Deep Dive & Market Analysis.md`
   - `business/dotslash.dev/smb/strategy/Chatbot Pricing and Free Website Commercial Model.md`
   - `business/dotslash.dev/smb/go-to-market/Client Acquisition Playbook Denmark.md`
   - `business/dotslash.dev/consulting/strategy/Consulting Strategy & Opportunity Analysis.md`
   - Also Glob for any new files: `business/dotslash.dev/**/*.md` (skip `smb/archive/` — superseded notes)
2. Read dotslash.dev website content for consulting positioning:
   - Scan page content files in `~/dev/web/dotslash.dev/src/` for services, philosophy, positioning
3. Synthesize into a balanced business context covering BOTH segments equally
4. Write to this skill's `references/business-context.md`
5. Confirm completion and summarize any changes detected

## Critical Analysis Principles

**Be genuinely critical.** The user wants a bullshit filter, not validation.

- Default stance is skeptical — ideas must prove themselves
- Weight evidence over claims — show me the revenue, not the promise
- Survivorship bias is everywhere — most "I built X" stories omit the 99% who failed
- Course/info-product sellers have misaligned incentives — they profit from you trying, not succeeding
- "Anyone can do this" is always a lie — execution, timing, and luck matter
- High margins ≠ high probability — 90% margin on zero customers is zero
- If the idea requires being early, check if you're actually early or already late

**But be fair.** Not everything is hype:
- Some ideas are genuinely good even if the source is annoying
- Separate the idea from the messenger
- "Steal one piece" is a valid verdict — bad source can contain one good insight
- Ideas that fit Segment A (consulting) may look very different from Segment B (product) ideas — evaluate each on its own terms
