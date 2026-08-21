#!/usr/bin/env nix-shell
#!nix-shell -i python3 -p python3
# ruff: noqa: EXE005 — second shebang line is required by nix-shell.

from __future__ import annotations

import importlib.util
import json
import os
import sys
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import ClassVar

MODULE_PATH = (
    Path(__file__).parents[1]
    / "comfyui/custom_nodes/muse_glimmer_prompt/__init__.py"
)
spec = importlib.util.spec_from_file_location("muse_glimmer_prompt", MODULE_PATH)
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
sys.modules[spec.name] = module
spec.loader.exec_module(module)


class MuseTestHandler(BaseHTTPRequestHandler):
    status = 200
    response_body = json.dumps(
        {"choices": [{"message": {"content": "server prompt"}}]}
    ).encode()
    observed_path = ""
    observed_authorization = ""
    observed_body: ClassVar[dict[str, object]] = {}

    def do_POST(self) -> None:
        content_length = int(self.headers.get("Content-Length", "0"))
        type(self).observed_path = self.path
        type(self).observed_authorization = self.headers.get("Authorization", "")
        type(self).observed_body = json.loads(self.rfile.read(content_length))
        self.send_response(type(self).status)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(type(self).response_body)

    def log_message(self, _format: str, *args: object) -> None:
        pass


class MusePromptContractTest(unittest.TestCase):
    def test_krea_message_uses_official_single_paragraph_contract(self) -> None:
        request = module.parse_prompt_request(
            module.TASK_KREA2,
            'Editorial portrait with the title "NORTH"',
            "",
            999,
            "16:9",
        )
        system, user = module.compile_messages(request)
        self.assertIn("one prompt paragraph", system["content"])
        self.assertIn('title "NORTH"', user["content"])
        self.assertNotIn("reference_manifest", user["content"])
        self.assertNotIn("duration_seconds", user["content"])

    def test_h3_base_schema_order_is_stable(self) -> None:
        request = module.parse_prompt_request(
            module.TASK_H3_BASE, "A crane shot crosses a harbor.", "", 5, "16:9"
        )
        system, _ = module.compile_messages(request)
        fields = (
            "integrated_multimodal_description:",
            "overall_soundscape:",
            "non_diegetic_music:",
        )
        positions = [system["content"].index(field) for field in fields]
        self.assertEqual(positions, sorted(positions))

    def test_h3_reference_requires_manifest_and_preserves_labels(self) -> None:
        with self.assertRaisesRegex(ValueError, "requires a reference manifest"):
            module.parse_prompt_request(
                module.TASK_H3_REFERENCE, "Animate the subject.", "", 5, "16:9"
            )
        request = module.parse_prompt_request(
            module.TASK_H3_REFERENCE,
            "Keep the subject recognizable.",
            "<Picture 1>: identity; <Video 1>: camera motion",
            8,
            "9:16",
        )
        _, user = module.compile_messages(request)
        self.assertIn("<Picture 1>: identity", user["content"])
        self.assertIn("duration_seconds: 8", user["content"])

    def test_request_body_maps_muse_reasoning_without_credentials(self) -> None:
        request = module.parse_prompt_request(
            module.TASK_KREA2, "A paper sculpture.", "", 5, "1:1"
        )
        messages = module.compile_messages(request)
        body = module.build_request_body(messages, "xhigh", 4096)
        self.assertEqual(body["model"], "muse-glimmer-30b")
        self.assertEqual(
            body["chat_template_kwargs"], {"reasoning_strength": "xhigh"}
        )
        self.assertEqual(body["top_k"], 64)
        self.assertNotIn("api_key", body)

    def test_private_key_rejects_group_or_world_access(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            key_path = Path(directory) / "api-key"
            key_path.write_text("secret\n", encoding="utf-8")
            os.chmod(key_path, 0o644)
            with self.assertRaisesRegex(RuntimeError, "must be private"):
                module.read_private_key(key_path)
            os.chmod(key_path, 0o600)
            self.assertEqual(module.read_private_key(key_path), "secret")

    def test_response_parser_returns_prompt_and_reasoning(self) -> None:
        prompt, reasoning = module.parse_response(
            {
                "choices": [
                    {
                        "message": {
                            "content": "final generation prompt",
                            "reasoning_content": "internal plan",
                        }
                    }
                ]
            }
        )
        self.assertEqual(prompt, "final generation prompt")
        self.assertEqual(reasoning, "internal plan")

    def test_http_boundary_posts_auth_and_parses_response(self) -> None:
        MuseTestHandler.status = 200
        MuseTestHandler.response_body = json.dumps(
            {"choices": [{"message": {"content": "server prompt"}}]}
        ).encode()
        server = ThreadingHTTPServer(("127.0.0.1", 0), MuseTestHandler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            prompt, reasoning = module.request_prompt(
                f"http://127.0.0.1:{server.server_port}/v1",
                "private-test-key",
                {"model": "muse-glimmer-30b", "messages": []},
                5,
            )
        finally:
            server.shutdown()
            server.server_close()
            thread.join()
        self.assertEqual(prompt, "server prompt")
        self.assertEqual(reasoning, "")
        self.assertEqual(MuseTestHandler.observed_path, "/v1/chat/completions")
        self.assertEqual(
            MuseTestHandler.observed_authorization, "Bearer private-test-key"
        )
        self.assertEqual(
            MuseTestHandler.observed_body["model"], "muse-glimmer-30b"
        )

    def test_http_error_preserves_status_and_redacts_body(self) -> None:
        MuseTestHandler.status = 401
        MuseTestHandler.response_body = b"token=provider-secret denied"
        server = ThreadingHTTPServer(("127.0.0.1", 0), MuseTestHandler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            with self.assertRaisesRegex(RuntimeError, r"Muse HTTP 401.*redacted") as raised:
                module.request_prompt(
                    f"http://127.0.0.1:{server.server_port}/v1",
                    "private-test-key",
                    {"model": "muse-glimmer-30b", "messages": []},
                    5,
                )
        finally:
            server.shutdown()
            server.server_close()
            thread.join()
        self.assertNotIn("provider-secret", str(raised.exception))

    def test_invalid_task_duration_reasoning_and_token_budget_fail_closed(self) -> None:
        with self.assertRaises(ValueError):
            module.parse_prompt_request("unknown", "brief", "", 5, "16:9")
        with self.assertRaises(ValueError):
            module.parse_prompt_request(
                module.TASK_H3_BASE, "brief", "", 16, "16:9"
            )
        request = module.parse_prompt_request(
            module.TASK_KREA2, "brief", "", 999, "16:9"
        )
        messages = module.compile_messages(request)
        with self.assertRaises(ValueError):
            module.build_request_body(messages, "max", 4096)
        with self.assertRaises(ValueError):
            module.build_request_body(messages, "xhigh", 128)


if __name__ == "__main__":
    unittest.main()
