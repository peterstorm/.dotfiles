#!/usr/bin/env python3
"""Start SGLang with an API key sourced from the container environment.

SGLang only exposes ``--api-key`` as a CLI option. Building ServerArgs in-process
keeps the secret out of Docker's command array and /proc/<pid>/cmdline. The
launcher supplies SGLANG_API_KEY through a mode-0600 Docker env file.
"""

from __future__ import annotations

import os
import sys

from sglang.launch_server import run_server
from sglang.srt.plugins import load_plugins
from sglang.srt.server_args import prepare_server_args
from sglang.srt.utils import kill_process_tree


class RedactedSecret(str):
    """String-compatible secret whose diagnostic representation is always masked."""

    def __repr__(self) -> str:
        return "'<redacted>'"


def main() -> None:
    cli_args = sys.argv[1:]
    if any(arg == "--api-key" or arg.startswith("--api-key=") for arg in cli_args):
        raise SystemExit("error: pass SGLANG_API_KEY via the private env file, not --api-key")

    api_key = os.environ.pop("SGLANG_API_KEY", "")
    if not api_key:
        raise SystemExit("error: SGLANG_API_KEY is required")

    load_plugins()
    server_args = prepare_server_args([*cli_args, "--api-key", api_key])
    server_args = server_args.derive(
        "secure-entrypoint-redaction", api_key=RedactedSecret(server_args.api_key)
    )
    try:
        run_server(server_args)
    finally:
        kill_process_tree(os.getpid(), include_parent=False)


if __name__ == "__main__":
    main()
