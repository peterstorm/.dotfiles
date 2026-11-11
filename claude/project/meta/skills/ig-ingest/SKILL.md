---
name: ig-ingest
description: "Save Instagram reels, posts, or whole profiles to the Obsidian vault as notes with caption + Whisper transcript (optionally keeping the video file). Use when the user sends an instagram.com URL or @handle and wants it transcribed, saved, scraped, summarized, or 'turned into text'. NOT for stories, private accounts, or posting/liking."
allowed-tools: Read, Bash
---

# Instagram → Vault (caption + transcript)

One CLI does the whole job: Apify scrapes the post(s), the signed media URL is downloaded immediately (they expire in ~2 days), faster-whisper transcribes it locally on the homelab CPU, and a note is written to the vault.

```bash
bun ~/dev/claude-plugins/reclaw/scripts/ig-ingest.ts <instagram-url | @handle> [--limit N] [--video] [--force] [--model small|medium|large-v3]
```

Notes land at `~/dev/notes/remotevault/media/instagram/<handle>/<shortcode>.md` and are linked from `media/instagram/MOC.md` and the vault `changelog.md` automatically. Do not write these yourself.

## Input

| User sends | Command |
|---|---|
| a reel / post URL (`/reel/`, `/p/`, `/tv/`, `/<user>/reel/…`, tracking params fine) | `ig-ingest.ts <url>` |
| a profile URL or `@handle` | `ig-ingest.ts @handle [--limit N]` (default 20, max 200) |
| "and keep the video" / "download it too" | add `--video` → mp4 goes to `~/downloads/instagram/<handle>/<shortcode>.mp4`, **never into the vault** |
| Danish (or other non-English) speech | add `--model medium` (default `small` is weak outside English) |
| "redo" / "overwrite" | add `--force` |

Stories and private accounts are unsupported — say so instead of trying.

## Run it

**Single reel/post** — run in the foreground (`timeout` ≈ 600s). A 30 s reel takes ~20 s end to end.

**Profile** — can take 20+ minutes (≈ 0.6× realtime on CPU), longer than a chat turn. Start it in the background and poll:

```bash
LOG=/tmp/ig-ingest-<handle>.log; OUT=/tmp/ig-ingest-<handle>.json
nohup bun ~/dev/claude-plugins/reclaw/scripts/ig-ingest.ts @<handle> --limit N >"$OUT" 2>"$LOG" &
```

Check `tail -3 "$LOG"` and whether `$OUT` is non-empty every minute or so. If it is still running when you must answer, tell the user it continues in the background and that re-running the same command is safe (existing notes are skipped, only missing ones are redone).

Before a profile run, tell the user the limit you are using and the cost: Apify charges about $0.0027 per post (free plan includes $5/month ≈ 1,800 posts). Each run is hard-capped by `maxTotalChargeUsd`.

## Output (JSON on stdout)

`summary` = `{ saved, transcribed, skippedExisting, failed, rejected }`; `outcomes[]` each `saved | skipped-existing | failed (stage: download|transcribe|write, reason)`; `warnings[]` for MOC/changelog upkeep.

Exit code 1 means a post failed or nothing was saved — still read the JSON and report it.

## Reply to the user

Only your **last message** is relayed. Make it self-contained:
- counts (saved / already there / failed) and, for ≤ 5 posts, the note paths as `[[media/instagram/<handle>/<shortcode>]]`
- for a single reel: a 2–4 line summary of what the transcript says, if they asked for one
- each failure with its `stage` and `reason`, and the fix (see below)
- if `--video` was used, where the mp4 is

## Failures

| Message | Meaning / fix |
|---|---|
| `APIFY_TOKEN is not set` | Token missing from the reclaw environment. Tell the user to add `apify_token` to `reclaw.yaml` (sops) and wire `APIFY_TOKEN` into the `reclaw-env` template in `~/.dotfiles/roles/reclaw/default.nix`, then rebuild. **Never ask them to paste the token into chat.** |
| `Apify HTTP 402` | Out of Apify credit/plan limit. |
| `scraper reported no_items` / empty | Private account, wrong handle, deleted post, or Instagram blocked the scrape — retry once, then report. |
| `Media download returned HTTP 403 (signed URL expired?)` | CDN link expired; re-run (the scrape gets fresh links). |
| `Whisper failed: …` | Report the tail of the message; first run downloads the model (~460 MB for `small`) and needs network. |
| photo/carousel without video | Saved as caption-only note (`_No video in this post._`) — not a failure. |

## Notes

- Pipeline details, cost and tradeoffs: vault `reclaw/implemented/instagram-ingest.md`.
- Env overrides: `RECLAW_VAULT_ROOT`, `RECLAW_IG_VIDEO_DIR`, `IG_WHISPER_MODEL`.
- Scraping is done by Apify (third party); Instagram's terms forbid scraping, so keep volumes personal-use sized.
