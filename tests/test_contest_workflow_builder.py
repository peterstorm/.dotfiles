#!/usr/bin/env nix-shell
#!nix-shell -i python3 -p python3
# ruff: noqa: EXE005 — second shebang line is required by nix-shell.

from __future__ import annotations

import importlib.util
import json
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BUILDER = ROOT / "scripts/comfyui/build-contest-production-workflows.py"
SPEC = importlib.util.spec_from_file_location("contest_workflow_builder", BUILDER)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


def minimal_graph() -> dict:
    return {
        "nodes": [
            {
                "id": 1,
                "type": "Source",
                "order": 9,
                "inputs": [],
                "outputs": [{"name": "value", "type": "VALUE", "links": None}],
                "properties": {"models": [{"url": "mutable metadata"}]},
            },
            {
                "id": 2,
                "type": "Destination",
                "order": 8,
                "inputs": [{"name": "value", "type": "VALUE", "link": None}],
                "outputs": [],
            },
        ],
        "links": [],
        "last_node_id": 2,
        "last_link_id": 0,
    }


class ContestWorkflowBuilderTest(unittest.TestCase):
    def test_finalize_rebuilds_ports_and_strips_mutable_model_metadata(self) -> None:
        graph = minimal_graph()
        link_id = MODULE.add_link(graph, 1, 0, 2, 0, "VALUE")

        result = MODULE.finalize(graph)

        self.assertEqual(result["nodes"][0]["outputs"][0]["links"], [link_id])
        self.assertEqual(result["nodes"][1]["inputs"][0]["link"], link_id)
        self.assertEqual([node["order"] for node in result["nodes"]], [0, 1])
        self.assertNotIn("models", result["nodes"][0]["properties"])
        self.assertEqual(result["last_link_id"], link_id)

    def test_finalize_rejects_two_links_to_one_input(self) -> None:
        graph = minimal_graph()
        graph["nodes"].insert(
            1,
            {
                "id": 3,
                "type": "SecondSource",
                "inputs": [],
                "outputs": [{"name": "value", "type": "VALUE", "links": None}],
            },
        )
        MODULE.add_link(graph, 1, 0, 2, 0, "VALUE")
        MODULE.add_link(graph, 3, 0, 2, 0, "VALUE")

        with self.assertRaisesRegex(ValueError, "multiple links target"):
            MODULE.finalize(graph)

    def test_image_geometry_uses_reduced_ratio_not_pixel_dimensions(self) -> None:
        node = {
            "properties": {
                "loadImagePixState": json.dumps(
                    {
                        "fit_w": 1024,
                        "fit_h": 1024,
                        "ratio_preset": "1:1",
                        "ratio_w": 1,
                        "ratio_h": 1,
                    }
                )
            }
        }

        MODULE.set_pixaroma_image_geometry(node, "3:4", 768, 1024)
        state = json.loads(node["properties"]["loadImagePixState"])

        self.assertEqual(
            (state["ratio_preset"], state["ratio_w"], state["ratio_h"]),
            ("3:4", 3, 4),
        )
        self.assertEqual((state["fit_w"], state["fit_h"]), (768, 1024))

    def test_output_geometry_reduces_custom_ratio(self) -> None:
        node = {
            "widgets_values": [{"w": 1024, "h": 1024}],
            "properties": {"resolutionState": "{}"},
        }

        MODULE.set_pixaroma_output_geometry(node, 768, 1344)
        state = node["widgets_values"][0]

        self.assertEqual((state["custom_ratio_w"], state["custom_ratio_h"]), (4, 7))
        self.assertEqual((state["w"], state["h"]), (768, 1344))

    def test_string_replacement_is_recursive_and_non_mutating(self) -> None:
        source = {"nested": ["model-fp8", {"value": "model-fp8"}]}

        result = MODULE.replace_strings(source, {"model-fp8": "model-bf16"})

        self.assertEqual(result, {"nested": ["model-bf16", {"value": "model-bf16"}]})
        self.assertEqual(source, {"nested": ["model-fp8", {"value": "model-fp8"}]})


if __name__ == "__main__":
    unittest.main()
