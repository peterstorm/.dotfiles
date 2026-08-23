#!/usr/bin/env python3
"""Keep Pixaroma LoRA workflow state canonical across frontend storage fields."""

from __future__ import annotations

import argparse
import copy
import json
from pathlib import Path, PurePosixPath
from typing import Any

Graph = dict[str, Any]
PIXAROMA_LORA_NODE = "PixaromaLoraLoader"


def canonical_lora_name(raw_name: str) -> str:
    """Parse a ComfyUI model-relative LoRA name into its canonical POSIX form."""
    name = raw_name.strip().replace("\\", "/")
    path = PurePosixPath(name)
    if not name or path.is_absolute() or ".." in path.parts:
        raise ValueError(f"invalid model-relative LoRA name: {raw_name!r}")
    return path.as_posix()


def _property_state(node: Graph) -> Graph:
    if node.get("type") != PIXAROMA_LORA_NODE:
        raise ValueError("expected a PixaromaLoraLoader node")
    serialized = node.get("properties", {}).get("loraLoaderState")
    if not isinstance(serialized, str):
        raise TypeError("Pixaroma LoRA node is missing properties.loraLoaderState")
    try:
        state = json.loads(serialized)
    except json.JSONDecodeError as error:
        raise ValueError("invalid properties.loraLoaderState JSON") from error
    loras = state.get("loras")
    if not isinstance(loras, list) or not loras:
        raise ValueError("Pixaroma LoRA state must contain at least one LoRA")
    if not all(
        isinstance(lora, dict) and isinstance(lora.get("name"), str) for lora in loras
    ):
        raise ValueError("every Pixaroma LoRA entry must have a string name")
    return state


def synchronize_pixaroma_lora_state(
    node: Graph, selected_name: str | None = None
) -> None:
    """Write one canonical state to both fields consumed by the Pixaroma frontend."""
    state = _property_state(node)
    if selected_name is not None:
        if len(state["loras"]) != 1:
            raise ValueError("a selected LoRA override requires exactly one LoRA entry")
        state["loras"][0]["name"] = selected_name
    for lora in state["loras"]:
        lora["name"] = canonical_lora_name(lora["name"])
    node["properties"]["loraLoaderState"] = json.dumps(state, separators=(",", ":"))
    node["widgets_values"] = [copy.deepcopy(state)]


def validate_pixaroma_lora_state(node: Graph, expected_name: str | None = None) -> None:
    """Reject red/missing selectors and divergent serialized/widget state."""
    state = _property_state(node)
    widgets = node.get("widgets_values")
    if widgets != [state]:
        raise ValueError("Pixaroma LoRA property and widget states must be identical")
    names = [lora["name"] for lora in state["loras"]]
    canonical_names = [canonical_lora_name(name) for name in names]
    if names != canonical_names:
        raise ValueError("Pixaroma LoRA names must use POSIX separators")
    if expected_name is not None and names != [canonical_lora_name(expected_name)]:
        raise ValueError(f"unexpected Pixaroma LoRA selection: {names}")


def normalize_pixaroma_lora_graph(graph: Graph) -> Graph:
    """Return a graph with every Pixaroma LoRA selector synchronized."""
    normalized = copy.deepcopy(graph)
    for node in normalized.get("nodes", []):
        if node.get("type") == PIXAROMA_LORA_NODE:
            synchronize_pixaroma_lora_state(node)
    return normalized


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("workflow", nargs="+", type=Path)
    return parser.parse_args()


def main() -> None:
    for path in parse_args().workflow:
        graph = json.loads(path.read_text())
        normalized = normalize_pixaroma_lora_graph(graph)
        path.write_text(json.dumps(normalized, indent=2) + "\n")


if __name__ == "__main__":
    main()
