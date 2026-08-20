#!/usr/bin/env python3
"""Fetch a YouTube transcript to stdout. Notes/errors go to stderr.

Usage: fetch_transcript.py VIDEO_ID [--timestamps] [--languages en,da]

Exit codes:
  0  transcript printed
  2  no captions exist (TranscriptsDisabled / VideoUnavailable) — yt-dlp won't help either
  3  YouTube is blocking this IP (RequestBlocked / IpBlocked) — try yt-dlp --cookies-from-browser
  1  anything else
"""
import argparse
import sys

from youtube_transcript_api import YouTubeTranscriptApi


def format_stamp(start_seconds: float) -> str:
    minutes, seconds = divmod(int(start_seconds), 60)
    hours, minutes = divmod(minutes, 60)
    return f"{hours}:{minutes:02d}:{seconds:02d}" if hours else f"{minutes:02d}:{seconds:02d}"


def render(entries, with_timestamps: bool) -> str:
    if with_timestamps:
        return "\n".join(f"[{format_stamp(e.start)}] {e.text}" for e in entries)
    return "\n".join(e.text for e in entries)


def fetch(api: YouTubeTranscriptApi, video_id: str, languages: list[str]):
    """Preferred languages first; else any available track, auto-translated to English."""
    try:
        return api.fetch(video_id, languages=languages)
    except Exception as err:
        name = type(err).__name__
        if name in ("TranscriptsDisabled", "VideoUnavailable"):
            fail(2, f"{name}: this video has no captions at all — {err}")
        if name in ("RequestBlocked", "IpBlocked"):
            fail(3, f"{name}: YouTube is blocking requests from this IP — {err}")
        track = next(iter(api.list(video_id)))
        original = track.language
        if track.language_code.split("-")[0] != "en" and track.is_translatable:
            track = track.translate("en")
            print(f"NOTE: no transcript in {languages}; auto-translated from {original}.", file=sys.stderr)
        else:
            print(f"NOTE: no transcript in {languages}; using {original} track as-is.", file=sys.stderr)
        return track.fetch()


def fail(code: int, message: str):
    print(f"ERROR {message}", file=sys.stderr)
    sys.exit(code)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("video_id")
    parser.add_argument("--timestamps", action="store_true")
    parser.add_argument("--languages", default="en")
    args = parser.parse_args()
    languages = [lang.strip() for lang in args.languages.split(",") if lang.strip()]

    try:
        entries = fetch(YouTubeTranscriptApi(), args.video_id, languages)
    except Exception as err:
        fail(1, f"{type(err).__name__}: {err}")
    print(render(entries, args.timestamps))


if __name__ == "__main__":
    main()
