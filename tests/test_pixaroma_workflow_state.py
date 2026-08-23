#!/usr/bin/env nix-shell
#!nix-shell -i python3 -p python3
# ruff: noqa: EXE005 — second shebang line is required by nix-shell.

from __future__ import annotations

import copy
import json
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts/comfyui"))

from pixaroma_workflow_state import (
    canonical_lora_name,
    normalize_pixaroma_lora_graph,
    synchronize_pixaroma_lora_state,
    validate_pixaroma_lora_state,
)


def lora_state(name: str) -> dict:
    return {
        "version": 1,
        "loras": [
            {
                "id": "identity",
                "name": name,
                "on": True,
                "sm": 1,
                "sc": 1,
                "triggers": [],
                "custom": [],
            }
        ],
        "sep": ", ",
    }


def lora_node(property_name: str, widget_name: str | None = None) -> dict:
    property_state = lora_state(property_name)
    widget_state = lora_state(widget_name or property_name)
    return {
        "id": 231,
        "type": "PixaromaLoraLoader",
        "properties": {"loraLoaderState": json.dumps(property_state)},
        "widgets_values": [widget_state],
    }


class PixaromaWorkflowStateTest(unittest.TestCase):
    def test_graph_normalization_is_non_mutating_and_synchronizes_both_fields(
        self,
    ) -> None:
        source = {
            "nodes": [
                lora_node(
                    r"krea2\krea2_identity_edit_v1_2.safetensors",
                    "krea2/krea2_identity_edit_v1_2.safetensors",
                )
            ]
        }
        original = copy.deepcopy(source)

        normalized = normalize_pixaroma_lora_graph(source)
        node = normalized["nodes"][0]

        self.assertEqual(source, original)
        validate_pixaroma_lora_state(node, "krea2/krea2_identity_edit_v1_2.safetensors")
        self.assertEqual(
            json.loads(node["properties"]["loraLoaderState"]),
            node["widgets_values"][0],
        )

    def test_selected_name_updates_property_and_widget_state_together(self) -> None:
        node = lora_node(r"krea2\old.safetensors")

        synchronize_pixaroma_lora_state(node, "krea2/krea_outfittransfer.safetensors")

        validate_pixaroma_lora_state(node, "krea2/krea_outfittransfer.safetensors")

    def test_validation_rejects_divergent_frontend_state(self) -> None:
        node = lora_node(
            r"krea2\krea2_identity_edit_v1_2.safetensors",
            "krea2/krea2_identity_edit_v1_2.safetensors",
        )

        with self.assertRaisesRegex(ValueError, "must be identical"):
            validate_pixaroma_lora_state(node)

    def test_model_name_parser_rejects_paths_outside_the_lora_root(self) -> None:
        for invalid in ("", "/tmp/model.safetensors", "../model.safetensors"):
            with (
                self.subTest(invalid=invalid),
                self.assertRaisesRegex(ValueError, "invalid model-relative"),
            ):
                canonical_lora_name(invalid)


if __name__ == "__main__":
    unittest.main()
