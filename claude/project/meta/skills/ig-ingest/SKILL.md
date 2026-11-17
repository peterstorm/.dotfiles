---
name: ig-ingest
description: "Save Instagram reels, posts, carousels or whole profiles to the Obsidian vault as notes with caption, alt text, Whisper transcript and the text shown on screen or in the images (local OCR), optionally keeping the video file. Use when the user sends an instagram.com URL or @handle and wants it transcribed, saved, scraped, summarized, read, or 'turned into text'. NOT for stories, private accounts, or posting/liking."
allowed-tools: Read, Bash
---

# Instagram → Vault (caption, transcript, on-screen text)

One CLI does the whole job: Apify scrapes the post(s), the signed media URLs are downloaded immediately (they expire in ~2 days), and everything else runs locally on the homelab CPU:

- **Speech** → faster-whisper transcript.
- **Text in the video** (titles, lists, overlays) → ffmpeg samples a frame a second, Tesseract reads it, repeated text is collapsed, and burned-in subtitles that repeat the speech are counted rather than listed.
- **Text in photos / carousel images** → Tesseract on every image.
- **Alt text** → Instagram's own description of the post, when it has one.

```bash
bun ~/dev/claude-plugins/reclaw/scripts/ig-ingest.ts <instagram-url | @handle> [--limit N] [--video] [--force] [--no-screen-text] [--from-dataset FILE] [--model small|medium|large-v3]
```

Notes land at `~/dev/notes/remotevault/media/instagram/<handle>/<shortcode>.md` and are linked from `media/instagram/MOC.md` and the vault `changelog.md` automatically. Do not write these yourself.

## Input

| User sends | Command |
|---|---|
| a reel / post URL (`/reel/`, `/p/`, `/tv/`, `/<user>/reel/…`, tracking params fine) | `ig-ingest.ts <url>` |
| a profile URL or `@handle` | `ig-ingest.ts @handle [--limit N]` (default 20, max 200) |
| "and keep the video" / "download it too" | add `--video` → mp4 goes to `~/downloads/instagram/<handle>/<shortcode>.mp4`, **never into the vault** |
| Danish (or other non-English) speech | add `--model medium` (default `small` is weak outside English). Danish speech also switches OCR to Danish + English. |
| "just the transcript" / a big profile run where speed matters | add `--no-screen-text` (skips OCR; videos then download audio only) |
| "redo" / "overwrite" | add `--force` |
| "only the posts since …" / a profile bigger than 200 posts | scrape once with Apify directly (`onlyPostsNewerThan`, higher `resultsLimit`), save the dataset items JSON, then `ig-ingest.ts @handle --from-dataset FILE` — no second scrape, no token; run within ~2 days (signed URLs expire) |

Stories and private accounts are unsupported — say so instead of trying.

## Run it

**Single reel/post** — run in the foreground (`timeout` ≈ 600s). A 30 s reel takes ~20–30 s end to end; a carousel about a second per image.

**Profile** — ≈ 1 min per reel with OCR (Whisper reloads per post), so 250 reels ≈ 4 h. Launch long runs as a user unit so a chat-turn timeout or reclaw restart cannot kill them: `systemd-run --user --unit=ig-ingest-<handle> --collect --working-directory=$HOME/dev/claude-plugins/reclaw --setenv=PATH="$PATH" -p StandardOutput=file:$OUT -p StandardError=file:$LOG $(command -v bun) scripts/ig-ingest.ts …`. Shorter runs — can take 20+ minutes (≈ 0.6× realtime on CPU, plus OCR), longer than a chat turn. Start it in the background and poll:

```bash
LOG=/tmp/ig-ingest-<handle>.log; OUT=/tmp/ig-ingest-<handle>.json
nohup bun ~/dev/claude-plugins/reclaw/scripts/ig-ingest.ts @<handle> --limit N >"$OUT" 2>"$LOG" &
```

Check `tail -3 "$LOG"` and whether `$OUT` is non-empty every minute or so. If it is still running when you must answer, tell the user it continues in the background and that re-running the same command is safe (existing notes are skipped, only missing ones are redone).

A `nohup` run lives in your turn's process scope: it survives your reply, but it is killed if your turn times out, if `reclaw.service` restarts, or after 4 hours. Any of those leaves the profile partly ingested, and re-running finishes it. If a run might go near 4 hours or must survive a restart, use the user unit above instead.

Before a profile run, tell the user the limit you are using and the cost: Apify charges about $0.0027 per post (free plan includes $5/month ≈ 1,800 posts, billing month 11th–10th). Each run is hard-capped by `maxTotalChargeUsd`. Transcription and OCR are local and cost nothing.

## Output (JSON on stdout)

`summary` = `{ saved, transcribed, textRead, skippedExisting, failed, rejected }`; `outcomes[]` each `saved | skipped-existing | failed (stage: download|transcribe|read-text|write, reason)`; `warnings[]` for MOC/changelog upkeep.

Exit code 1 means a post failed or nothing was saved — still read the JSON and report it.

## Note sections

`## Caption`, then `## Alt text` (when Instagram has one), then by media:

- **video** — `## Transcript` (`_No speech detected._` for silent reels) and `## On-screen text` (`[m:ss] text` at first appearance; `_N subtitle lines repeating the speech left out._` when it dropped burned-in captions).
- **photo / carousel** — `## Text in images`, one `**Image n**` block per image that has text (no numbering for a single photo).
- **no media** — `_No media found in this post._`

OCR is Tesseract: clean overlay text reads well; stylised or hand-lettered fonts come out garbled (`Iearn` for `learn`, `Al` for `AI`). When summarising, treat on-screen text as a noisy source and lean on the caption and transcript.

## Reply to the user

Only your **last message** is relayed. Make it self-contained:
- counts (saved / already there / failed) and, for ≤ 5 posts, the note paths as `[[media/instagram/<handle>/<shortcode>]]`
- for a single post: a 2–4 line summary of what it says (caption, speech and on-screen text together), if they asked for one
- each failure with its `stage` and `reason`, and the fix (see below)
- if `--video` was used, where the mp4 is

## Failures

| Message | Meaning / fix |
|---|---|
| `No Apify token: APIFY_TOKEN is unset and … is unreadable` | The token comes from `APIFY_TOKEN`, else the sops secret `/run/secrets/reclaw-apify-token` (chat sessions don't inherit service secrets, so they use the file). If the file is missing, `apify_token` is missing from `reclaw.yaml` (sops) or the secret isn't declared in `~/.dotfiles/roles/reclaw/default.nix` — rebuild. **Never ask the user to paste the token into chat.** |
| `Apify HTTP 402` | Out of Apify credit for this billing month (resets on the 11th). |
| `scraper reported no_items` / empty | Private account, wrong handle, deleted post, or Instagram blocked the scrape — retry once, then report. |
| `Media download returned HTTP 403 (signed URL expired?)` | CDN link expired; re-run (the scrape gets fresh links). |
| `Whisper failed: …` | Report the tail of the message; first run downloads the model (~460 MB for `small`) and needs network. |
| `read-text` stage: `Reading text failed: …` | ffmpeg/Tesseract failed (first run fetches them via nix and needs network). Re-run; if it persists, re-run with `--no-screen-text` so the note still gets saved, and report the reason. |
| post without media | Saved as caption-only note — not a failure. |

## Notes

- Pipeline details, cost and tradeoffs: vault `reclaw/implemented/instagram-ingest.md`.
- Env overrides: `RECLAW_VAULT_ROOT`, `RECLAW_IG_VIDEO_DIR`, `IG_WHISPER_MODEL`, `APIFY_TOKEN_FILE`.
- Scraping is done by Apify (third party); Instagram's terms forbid scraping, so keep volumes personal-use sized.
