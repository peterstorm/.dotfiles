#!/usr/bin/env nix-shell
#!nix-shell -i python3 -p python3
# ruff: noqa: EXE005 — second shebang line is required by nix-shell.

from __future__ import annotations

import importlib.util
import os
import tempfile
import unittest
from pathlib import Path

MODULE_PATH = (
    Path(__file__).parents[1]
    / "comfyui/custom_nodes/muse_glimmer_prompt/__init__.py"
)
spec = importlib.util.spec_from_file_location("muse_glimmer_prompt", MODULE_PATH)
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)


class MusePromptContractTest(unittest.TestCase):
    def test_krea_message_uses_official_single_paragraph_contract(self) -> None:
        system, user = module.compile_messages(
            module.TASK_KREA2,
            'Editorial portrait with the title "NORTH"',
            "",
            5,
            "16:9",
        )
        self.assertIn("one prompt paragraph", system["content"])
        self.assertIn('title "NORTH"', user["content"])
        self.assertIn("reference_manifest:\n(none)", user["content"])

    def test_h3_base_schema_order_is_stable(self) -> None:
        system, _ = module.compile_messages(
            module.TASK_H3_BASE, "A crane shot crosses a harbor.", "", 5, "16:9"
        )
        fields = (
            "integrated_multimodal_description:",
            "overall_soundscape:",
            "non_diegetic_music:",
        )
        positions = [system["content"].index(field) for field in fields]
        self.assertEqual(positions, sorted(positions))

    def test_h3_reference_requires_manifest_and_preserves_labels(self) -> None:
        with self.assertRaisesRegex(ValueError, "requires a reference manifest"):
            module.compile_messages(
                module.TASK_H3_REFERENCE, "Animate the subject.", "", 5, "16:9"
            )
        _, user = module.compile_messages(
            module.TASK_H3_REFERENCE,
            "Keep the subject recognizable.",
            "<Picture 1>: identity; <Video 1>: camera motion",
            8,
            "9:16",
        )
        self.assertIn("<Picture 1>: identity", user["content"])
        self.assertIn("duration_seconds: 8", user["content"])

    def test_request_body_maps_muse_reasoning_without_credentials(self) -> None:
        messages = module.compile_messages(
            module.TASK_KREA2, "A paper sculpture.", "", 5, "1:1"
        )
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

    def test_invalid_task_duration_reasoning_and_token_budget_fail_closed(self) -> None:
        with self.assertRaises(ValueError):
            module.compile_messages("unknown", "brief", "", 5, "16:9")
        with self.assertRaises(ValueError):
            module.compile_messages(module.TASK_KREA2, "brief", "", 16, "16:9")
        messages = module.compile_messages(
            module.TASK_KREA2, "brief", "", 5, "16:9"
        )
        with self.assertRaises(ValueError):
            module.build_request_body(messages, "max", 4096)
        with self.assertRaises(ValueError):
            module.build_request_body(messages, "xhigh", 128)


if __name__ == "__main__":
    unittest.main()
