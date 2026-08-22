#!/usr/bin/env python3
"""Build the BF16 Krea Identity Edit -> FLUX.2 Klein realism workflow."""

from __future__ import annotations

import argparse
import copy
import json
from pathlib import Path
from typing import Any

Graph = dict[str, Any]
Link = list[Any]

IDENTITY_REMOVE_NODES = {163, 223}
DETAIL_NODE_IDS = {136, 137, 139, 141}
FLUX_NODE_IDS = {
    46,
    47,
    48,
    49,
    50,
    51,
    52,
    53,
    54,
    55,
    56,
    57,
    58,
    59,
    60,
    61,
    62,
    63,
    64,
    65,
    96,
}


def nodes_by_id(graph: Graph) -> dict[int, Graph]:
    return {node["id"]: node for node in graph["nodes"]}


def copy_node(
    source: Graph, source_id: int, destination_id: int | None = None
) -> Graph:
    node = copy.deepcopy(nodes_by_id(source)[source_id])
    node["id"] = source_id if destination_id is None else destination_id
    node.get("properties", {}).pop("models", None)
    return node


def set_position(node: Graph, x: float, y: float) -> None:
    node["pos"] = [x, y]


def shift_position(node: Graph, dx: float, dy: float = 0) -> None:
    x, y = node["pos"]
    set_position(node, x + dx, y + dy)


def replace_title(label_node: Graph, title: str) -> None:
    label = json.loads(label_node["widgets_values"][0])
    label["text"] = title
    label_node["widgets_values"][0] = json.dumps(label, separators=(",", ":"))


def next_link_id(graph: Graph) -> int:
    return max((link[0] for link in graph["links"]), default=0) + 1


def add_link(
    graph: Graph,
    source_id: int,
    source_slot: int,
    destination_id: int,
    destination_slot: int,
    value_type: str,
) -> None:
    graph["links"].append(
        [
            next_link_id(graph),
            source_id,
            source_slot,
            destination_id,
            destination_slot,
            value_type,
        ]
    )


def remove_links_touching(graph: Graph, node_ids: set[int]) -> None:
    graph["links"] = [
        link
        for link in graph["links"]
        if link[1] not in node_ids and link[3] not in node_ids
    ]


def rebuild_port_links(graph: Graph) -> None:
    index = nodes_by_id(graph)
    for node in graph["nodes"]:
        for node_input in node.get("inputs", []):
            node_input["link"] = None
        for output in node.get("outputs", []):
            if "links" in output:
                output["links"] = []

    occupied_inputs: set[tuple[int, int]] = set()
    for link_id, source_id, source_slot, destination_id, destination_slot, _ in graph[
        "links"
    ]:
        source = index[source_id]
        destination = index[destination_id]
        if source_slot >= len(source.get("outputs", [])):
            raise ValueError(f"source slot does not exist: link {link_id}")
        if destination_slot >= len(destination.get("inputs", [])):
            raise ValueError(f"destination slot does not exist: link {link_id}")
        destination_key = (destination_id, destination_slot)
        if destination_key in occupied_inputs:
            raise ValueError(
                f"multiple links target input: node {destination_id} slot {destination_slot}"
            )
        occupied_inputs.add(destination_key)
        source_output = source["outputs"][source_slot]
        source_output.setdefault("links", []).append(link_id)
        destination["inputs"][destination_slot]["link"] = link_id


def normalize_orders(graph: Graph) -> None:
    for order, node in enumerate(graph["nodes"]):
        node["order"] = order


def build_workflow(identity_source: Graph, realism_source: Graph) -> Graph:
    graph = copy.deepcopy(identity_source)
    graph["nodes"] = [
        node for node in graph["nodes"] if node["id"] not in IDENTITY_REMOVE_NODES
    ]
    remove_links_touching(graph, IDENTITY_REMOVE_NODES)
    identity_nodes = nodes_by_id(graph)

    identity_nodes[194]["widgets_values"][0] = "krea2_turbo_bf16.safetensors"
    identity_nodes[195]["widgets_values"][0] = "qwen3vl_4b_bf16.safetensors"
    identity_nodes[231]["widgets_values"][0]["loras"][0]["name"] = (
        "krea2/krea2_identity_edit_v1_2.safetensors"
    )
    identity_nodes[231]["title"] = "Identity Edit v1.2 — strength 1.0"
    identity_nodes[232]["title"] = "Identity preservation — ref_boost 4"
    identity_nodes[221]["title"] = "Describe one controlled view or expression change"
    identity_nodes[226]["title"] = "Canonical identity reference"
    identity_nodes[199]["title"] = (
        "Krea identity result — inspect before final refinement"
    )
    identity_nodes[230]["title"] = "Identity QA — canonical reference vs Krea result"
    replace_title(
        identity_nodes[198],
        "Krea 2 Identity v1.2 + Selectable Realism + FLUX.2 Klein 9B BF16",
    )

    ultra_real = copy_node(realism_source, 142, 240)
    ultra_real["widgets_values"] = ["ultra_real_krea2_v2_bf16.safetensors", 0.6]
    ultra_real["mode"] = 4
    ultra_real["title"] = "BYPASSED — UltraReal Krea 2 v2 (enable instead of FameGrid)"
    set_position(ultra_real, 35, 25)

    famegrid = copy_node(realism_source, 142, 241)
    famegrid["widgets_values"] = ["famegrid_standard_krea2_bf16.safetensors", 0.65]
    famegrid["mode"] = 0
    famegrid["title"] = "ACTIVE — FameGrid Standard realism"
    set_position(famegrid, 35, 135)

    detail_nodes = [
        copy_node(realism_source, node_id) for node_id in sorted(DETAIL_NODE_IDS)
    ]
    detail = {node["id"]: node for node in detail_nodes}
    detail[137]["title"] = "Krea sampler — er_sde"
    detail[136]["title"] = "Detail Daemon — identity-aware Krea pass"
    detail[141]["widgets_values"] = ["simple", 10, 1]
    detail[141]["title"] = "Identity Edit baseline — 10 steps, denoise 1.0"
    detail[139]["widgets_values"] = [True, 530887432637999, "randomize", 1]
    detail[139]["title"] = "Krea Identity + realism sampling — CFG 1"
    set_position(detail[137], 780, -80)
    set_position(detail[136], 1080, -95)
    set_position(detail[141], 780, 245)
    set_position(detail[139], 1400, 65)

    flux_nodes = [
        copy_node(realism_source, node_id) for node_id in sorted(FLUX_NODE_IDS)
    ]
    for node in flux_nodes:
        shift_position(node, -2700)
    flux = {node["id"]: node for node in flux_nodes}
    flux[62]["widgets_values"][0] = "qwen_3_8b_bf16.safetensors"
    flux[63]["widgets_values"][0] = "flux-2-klein-9b-bf16.safetensors"
    flux[54]["widgets_values"][0] = (
        "Refine to high-definition photorealism. Preserve the person's exact identity, "
        "facial geometry, age, expression, hairstyle, body proportions, pose, wardrobe, "
        "framing, background, and all image content. Restore natural skin pores, fine hair, "
        "fabric texture, and optical detail. Do not redesign or beautify the subject."
    )
    flux[54]["title"] = "Identity-locked FLUX refinement instruction"
    flux[56]["widgets_values"][1] = 4
    flux[56]["title"] = "Four-megapixel handoff"
    flux[64]["title"] = "Match refined color to Krea identity result"
    flux[65]["title"] = "Final conservative sharpen"
    flux[46]["title"] = "Final photoreal character reference"
    flux[96]["mode"] = 0
    flux[96]["widgets_values"][0] = "CharacterSheet_Krea2_Identity_Klein9B"
    flux[96]["title"] = "Save approved character reference"
    set_position(flux[46], 4360, 40)
    set_position(flux[96], 4360, 500)

    set_position(identity_nodes[231], -350, -80)
    set_position(identity_nodes[232], 390, 180)
    set_position(identity_nodes[164], 1720, 180)
    set_position(identity_nodes[199], 1720, 500)
    set_position(identity_nodes[230], 1720, 850)

    graph["nodes"].extend([ultra_real, famegrid, *detail_nodes, *flux_nodes])

    # Replace the direct Identity Edit sampler and direct model-patch link.
    graph["links"] = [
        link for link in graph["links"] if not (link[1] == 231 and link[3] == 232)
    ]

    # Identity LoRA -> one realism LoRA -> Krea Identity model patch.
    add_link(graph, 231, 0, 240, 0, "MODEL")
    add_link(graph, 240, 0, 241, 0, "MODEL")
    add_link(graph, 241, 0, 232, 0, "MODEL")

    # Replace KSampler with Detail Daemon's custom sampler at the proven Identity settings.
    add_link(graph, 137, 0, 136, 0, "SAMPLER")
    add_link(graph, 136, 0, 139, 3, "SAMPLER")
    add_link(graph, 232, 0, 141, 0, "MODEL")
    add_link(graph, 141, 0, 139, 4, "SIGMAS")
    add_link(graph, 232, 0, 139, 0, "MODEL")
    add_link(graph, 224, 0, 139, 1, "CONDITIONING")
    add_link(graph, 228, 0, 139, 2, "CONDITIONING")
    add_link(graph, 162, 0, 139, 5, "LATENT")
    add_link(graph, 139, 0, 164, 0, "LATENT")

    # Copy the intact FLUX refinement subgraph, then bind it to the Identity result.
    for link in realism_source["links"]:
        if link[1] in FLUX_NODE_IDS and link[3] in FLUX_NODE_IDS:
            add_link(graph, link[1], link[2], link[3], link[4], link[5])
    add_link(graph, 164, 0, 56, 0, "IMAGE")

    graph["groups"] = [
        {
            "id": 1,
            "title": "Canonical reference and BF16 Krea loaders",
            "bounding": [-1080, 150, 650, 1070],
            "color": "#3f789e",
            "font_size": 24,
            "flags": {},
        },
        {
            "id": 2,
            "title": "Identity Edit v1.2 — change one view at a time",
            "bounding": [-700, -165, 1420, 1175],
            "color": "#8f6c3d",
            "font_size": 24,
            "flags": {},
        },
        {
            "id": 3,
            "title": "Choose exactly one Krea realism LoRA",
            "bounding": [-10, -20, 410, 275],
            "color": "#8f6c3d",
            "font_size": 20,
            "flags": {},
        },
        {
            "id": 4,
            "title": "Detail Daemon identity pass",
            "bounding": [735, -150, 950, 680],
            "color": "#6d5a8f",
            "font_size": 24,
            "flags": {},
        },
        {
            "id": 5,
            "title": "Identity QA — reject drift before approving",
            "bounding": [1680, 120, 670, 1190],
            "color": "#8f3f4d",
            "font_size": 24,
            "flags": {},
        },
        {
            "id": 6,
            "title": "FLUX.2 Klein 9B BF16 photoreal refinement",
            "bounding": [2375, 300, 2700, 1080],
            "color": "#3f789e",
            "font_size": 24,
            "flags": {},
        },
    ]

    for node in graph["nodes"]:
        node.get("properties", {}).pop("models", None)
    graph["extra"] = {
        "ds": {"scale": 0.65, "offset": [1250, 160]},
        "frontendVersion": identity_source.get("extra", {}).get(
            "frontendVersion", "1.45.21"
        ),
        "workflowRendererVersion": "LG",
    }
    rebuild_port_links(graph)
    normalize_orders(graph)
    graph["last_node_id"] = max(node["id"] for node in graph["nodes"])
    graph["last_link_id"] = max(link[0] for link in graph["links"])
    return graph


def validate_graph(graph: Graph) -> None:
    node_ids = [node["id"] for node in graph["nodes"]]
    link_ids = [link[0] for link in graph["links"]]
    if len(node_ids) != len(set(node_ids)):
        raise ValueError("duplicate node id")
    if len(link_ids) != len(set(link_ids)):
        raise ValueError("duplicate link id")
    rebuild_port_links(copy.deepcopy(graph))

    index = nodes_by_id(graph)
    required_types = {
        "ColorMatch",
        "DetailDaemonSamplerNode",
        "Krea2EditGroundedEncode",
        "Krea2EditModelPatch",
        "LoraLoaderModelOnly",
        "ReferenceLatent",
        "SaveImage",
    }
    present_types = {node["type"] for node in graph["nodes"]}
    missing_types = required_types - present_types
    if missing_types:
        raise ValueError(f"missing required node types: {sorted(missing_types)}")
    if index[240]["mode"] != 4 or index[241]["mode"] != 0:
        raise ValueError("exactly FameGrid must be active by default")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--identity", required=True, type=Path)
    parser.add_argument("--realism", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    identity = json.loads(args.identity.read_text())
    realism = json.loads(args.realism.read_text())
    workflow = build_workflow(identity, realism)
    validate_graph(workflow)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(workflow, indent=2) + "\n")


if __name__ == "__main__":
    main()
