#!/usr/bin/env python3
"""Compose validated BF16 Krea production workflows with optional FLUX stages."""

from __future__ import annotations

import argparse
import copy
import json
from pathlib import Path
from typing import Any

Graph = dict[str, Any]

IDENTITY_REMOVE_NODES = {163, 223}
DETAIL_NODE_IDS = {136, 137, 139, 141}
PROMPT_AUTHOR_ENCODER = "qwen3-vl-8b-heretic-1.3.0_bf16.safetensors"
SINGLE_VIEW_PROMPT = (
    "Generate exactly one new full-body left-facing side profile of the same subject, "
    "with the face and body viewed from the side. Preserve the subject's identity, "
    "species, anatomy, facial design, proportions, clothing, accessories, colors, and "
    "original visual medium. Replace the original pose, camera angle, framing, and "
    "background with one centered subject on a plain neutral studio background. No "
    "front view, three-quarter view, additional subjects, duplicate views, panels, "
    "triptych, contact sheet, inset, frame, poster, or displayed source image."
)
STYLE_PRESERVING_REFINEMENT_PROMPT = (
    "Refine this single image in high definition while preserving the exact subject "
    "identity, species, anatomy, facial design, proportions, pose, clothing, "
    "accessories, composition, colors, and original visual medium. Preserve native "
    "fur, hair, skin, fabric, material, line, and surface detail as appropriate. Keep "
    "exactly one subject. Do not photorealize, stylize, redesign, beautify, duplicate, "
    "add panels, or display the source image."
)
THREE_PANEL_SHEET_PROMPT = (
    "A THREE-PANEL CHARACTER REFERENCE SHEET composed as one horizontal frame, "
    "divided into exactly three equal vertical panels side by side. The exact same "
    "uploaded character and exact same outfit appear consistently. LEFT PANEL — "
    "FULL-BODY FRONT: complete direct front view from crown through footwear, squared "
    "to camera. CENTER PANEL — FULL-BODY REAR: complete direct back view turned 180 "
    "degrees away, face entirely invisible, backpack and rear outfit construction "
    "readable. RIGHT PANEL — MAGNIFIED FACE CLOSE-UP ONLY: a dramatically tighter and "
    "larger head-and-shoulders crop, from just above the crown down only to the "
    "collarbones; the face occupies most of the right panel from side to side. No torso "
    "below the collarbones, waist, hands, legs, footwear, or full-body figure in the "
    "right panel. Preserve the exact identity, species, face design, proportions, hair "
    "or fur, colors, clothing, footwear, accessories, and original visual medium from "
    "the uploaded approved full-look reference. Use the same flat 18% neutral gray "
    "field and identical even shadowless illumination in all panels. No cast or contact "
    "shadow, floor line, gradient, hotspot, vignette, glow, halo, light spill, bokeh, "
    "text, labels, numbering, extra panels, extra characters, source-image display, "
    "outer frame, or inset."
)

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


def ensure_optional_input(node: Graph, name: str, value_type: str) -> int:
    for slot, node_input in enumerate(node.get("inputs", [])):
        if node_input["name"] == name:
            return slot
    node.setdefault("inputs", []).append(
        {"name": name, "shape": 7, "type": value_type, "link": None}
    )
    return len(node["inputs"]) - 1


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


def build_single_view_character_workflow(
    identity_source: Graph, realism_source: Graph
) -> Graph:
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
    identity_nodes[232]["widgets_values"][0] = 1
    identity_nodes[232]["title"] = "Identity-preserving edit pass — neutral ref_boost 1"
    identity_nodes[221]["properties"]["promptState"]["text"] = SINGLE_VIEW_PROMPT
    identity_nodes[221]["title"] = "Request exactly one new view — edit angle as needed"
    identity_nodes[226]["title"] = "Canonical subject reference — identity only"
    source_state = json.loads(identity_nodes[226]["properties"]["loadImagePixState"])
    source_state.update(
        {
            "fit_w": 1024,
            "fit_h": 1024,
            "ratio_preset": "1:1",
            "ratio_w": 1,
            "ratio_h": 1,
            "ratio_action": "crop",
        }
    )
    identity_nodes[226]["properties"]["loadImagePixState"] = json.dumps(
        source_state, separators=(",", ":")
    )
    slider_state = identity_nodes[234]["properties"]["slidersState"]
    slider_state["sliders"][0]["value"] = 1
    identity_nodes[234]["title"] = (
        "Reference Boost — 1 identity baseline; lower only if pose is blocked"
    )
    resolution_state = copy.deepcopy(identity_nodes[235]["widgets_values"][0])
    resolution_state.update({"mode": "preset", "ratio": "1:1", "w": 1024, "h": 1024})
    identity_nodes[235]["properties"]["resolutionState"] = json.dumps(
        resolution_state, separators=(",", ":")
    )
    identity_nodes[235]["widgets_values"][0] = resolution_state
    identity_nodes[235]["title"] = (
        "Output canvas — keep 1:1 to prevent source-panel outpainting"
    )
    identity_nodes[199]["widgets_values"][0] = "CharacterSheet_Krea2_SingleView"
    identity_nodes[199]["title"] = "PRIMARY OUTPUT — clean Krea single view"
    identity_nodes[230]["title"] = "QA COMPARISON ONLY — not part of saved output"
    replace_title(
        identity_nodes[198],
        "Krea 2 Single-View Character + Optional Realism/FLUX.2 Klein 9B BF16",
    )

    ultra_real = copy_node(realism_source, 142, 240)
    ultra_real["widgets_values"] = ["ultra_real_krea2_v2_bf16.safetensors", 0.6]
    ultra_real["mode"] = 4
    ultra_real["title"] = "BYPASSED — optional UltraReal Krea 2 v2"
    set_position(ultra_real, 35, 25)

    famegrid = copy_node(realism_source, 142, 241)
    famegrid["widgets_values"] = ["famegrid_standard_krea2_bf16.safetensors", 0.65]
    famegrid["mode"] = 4
    famegrid["title"] = "BYPASSED — optional FameGrid Standard realism"
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
    flux[54]["widgets_values"][0] = STYLE_PRESERVING_REFINEMENT_PROMPT
    flux[54]["title"] = "Style- and composition-locked FLUX refinement instruction"
    flux[56]["widgets_values"][1] = 4
    flux[56]["title"] = "Optional four-megapixel handoff"
    flux[64]["title"] = "Match refined color to Krea single view"
    flux[65]["title"] = "Optional conservative sharpen"
    flux[46]["mode"] = 2
    flux[46]["title"] = "MUTED — optional FLUX preview (enable with Save node)"
    flux[96]["mode"] = 2
    flux[96]["widgets_values"][0] = "CharacterSheet_Krea2_SingleView_Klein9B"
    flux[96]["title"] = "MUTED — optional FLUX save (enable with Preview node)"
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

    # Identity LoRA -> two bypassed optional realism LoRAs -> model patch.
    add_link(graph, 231, 0, 240, 0, "MODEL")
    add_link(graph, 240, 0, 241, 0, "MODEL")
    add_link(graph, 241, 0, 232, 0, "MODEL")

    # Pre-encode the source reference at the sampler's target geometry. Reference
    # tokens preserve appearance; the independent sampler latent owns output pixels.
    target_latent_slot = ensure_optional_input(
        identity_nodes[232], "target_latent", "LATENT"
    )
    add_link(graph, 162, 0, 232, target_latent_slot, "LATENT")

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
    add_link(graph, 65, 0, 96, 0, "IMAGE")

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
            "title": "OPTIONAL realism — both LoRAs bypassed by default",
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
            "title": "OPTIONAL FLUX.2 Klein 9B BF16 — outputs muted by default",
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


def build_three_panel_character_sheet_workflow(
    identity_source: Graph, realism_source: Graph
) -> Graph:
    graph = build_single_view_character_workflow(identity_source, realism_source)

    final_save = copy_node(graph, 96, 503)
    final_save["mode"] = 0
    final_save["widgets_values"][0] = "CharacterSheet_Krea2_3Panel"
    final_save["title"] = "SAVE — generated three-panel character sheet"
    set_position(final_save, 2150, 520)

    removed_nodes = FLUX_NODE_IDS | {199, 230}
    graph["nodes"] = [
        node for node in graph["nodes"] if node["id"] not in removed_nodes
    ]
    remove_links_touching(graph, removed_nodes)
    index = nodes_by_id(graph)

    replace_title(index[198], "Krea 2 — Three-Panel Character Sheet BF16")
    index[221]["properties"]["promptState"]["text"] = THREE_PANEL_SHEET_PROMPT
    index[221]["title"] = "Three-panel grammar — front / rear / tight face"
    index[224]["widgets_values"][1] = 1024
    index[224]["title"] = "Semantic identity grounding — approved reference"
    index[228]["widgets_values"][1] = 1024
    index[228]["title"] = "Reference-grounded unconditional conditioning"
    index[232]["widgets_values"][0] = 1
    index[232]["title"] = "Appearance identity tokens — neutral ref_boost 1"
    index[233]["title"] = "VAE-encode approved identity reference"
    index[139]["widgets_values"][1] = 530887432638002
    index[139]["title"] = "Generate all three panels in one native Krea pass"
    index[164]["title"] = "Decode complete horizontal character sheet"

    source_state = json.loads(index[226]["properties"]["loadImagePixState"])
    source_state.update(
        {
            "fit_w": 768,
            "fit_h": 1024,
            "ratio_preset": "3:4",
            "ratio_w": 3,
            "ratio_h": 4,
            "ratio_action": "crop",
        }
    )
    index[226]["properties"]["loadImagePixState"] = json.dumps(
        source_state, separators=(",", ":")
    )
    index[226]["title"] = "Approved reference — semantic + appearance identity"

    resolution_state = copy.deepcopy(index[235]["widgets_values"][0])
    resolution_state.update(
        {
            "mode": "custom",
            "ratio": "custom",
            "w": 1536,
            "h": 768,
            "custom_w": 1536,
            "custom_h": 768,
            "custom_ratio_w": 2,
            "custom_ratio_h": 1,
        }
    )
    index[235]["properties"]["resolutionState"] = json.dumps(
        resolution_state, separators=(",", ":")
    )
    index[235]["widgets_values"][0] = resolution_state
    index[235]["title"] = "Native three-panel target latent — 1536×768"
    slider_state = index[234]["properties"]["slidersState"]
    slider_state["sliders"][0]["value"] = 1
    index[234]["title"] = "Reference Boost — 1 identity baseline"

    graph["nodes"].append(final_save)

    # The approved image must feed both trained identity channels: grounded Qwen
    # encoding for semantics and clean VAE reference tokens for appearance. It is
    # never the sampler's initial latent; node 162 remains an independent target.
    add_link(graph, 164, 0, 503, 0, "IMAGE")

    graph["groups"] = [
        {
            "id": 1,
            "title": "Approved reference — semantic and appearance identity paths",
            "bounding": [-1080, 150, 650, 1070],
            "color": "#3f789e",
            "font_size": 24,
            "flags": {},
        },
        {
            "id": 2,
            "title": "Three-panel grammar and BF16 Identity Edit model",
            "bounding": [-700, -165, 1420, 1175],
            "color": "#8f6c3d",
            "font_size": 24,
            "flags": {},
        },
        {
            "id": 3,
            "title": "Independent target latent — native three-panel generation and save",
            "bounding": [735, -150, 2100, 1350],
            "color": "#6d5a8f",
            "font_size": 24,
            "flags": {},
        },
    ]
    for node in graph["nodes"]:
        node.get("properties", {}).pop("models", None)
    graph["extra"] = {
        **graph.get("extra", {}),
        "ds": {"scale": 0.68, "offset": [950, 180]},
    }
    rebuild_port_links(graph)
    normalize_orders(graph)
    graph["last_node_id"] = max(node["id"] for node in graph["nodes"])
    graph["last_link_id"] = max(link[0] for link in graph["links"])
    return graph


def build_prompt_enhancer_refinement_workflow(
    prompt_enhancer_source: Graph, realism_source: Graph
) -> Graph:
    graph = copy.deepcopy(prompt_enhancer_source)
    existing_ids = set(nodes_by_id(graph))
    collisions = existing_ids & FLUX_NODE_IDS
    if collisions:
        raise ValueError(f"FLUX refinement node IDs collide: {sorted(collisions)}")

    source_nodes = nodes_by_id(graph)
    replace_title(
        source_nodes[198],
        "Krea 2 Prompt Enhancer → FLUX.2 Klein 9B BF16 Realism",
    )
    source_nodes[195]["title"] = "Krea conditioning — required 4B 12×2560 stack"
    source_nodes[199]["title"] = "Krea result — inspect before FLUX refinement"

    prompt_author = copy_node(graph, 195, 218)
    prompt_author["widgets_values"] = [PROMPT_AUTHOR_ENCODER, "krea2", "default"]
    prompt_author["title"] = "Prompt author only — BF16 Qwen3-VL-8B Heretic"
    shift_position(prompt_author, 0, 950)
    graph["nodes"].append(prompt_author)
    prompt_author_links = [
        link for link in graph["links"] if link[1:5] == [195, 0, 213, 0]
    ]
    if len(prompt_author_links) != 1:
        raise ValueError("expected one shared 4B encoder link to TextGenerate")
    prompt_author_links[0][1] = 218

    note = json.loads(source_nodes[217]["widgets_values"][0])
    note["content"] += (
        "<h2>FLUX.2 Klein realism finish</h2>"
        "<p>A separate full-BF16 Qwen3-VL-8B Heretic encoder authors the prompt; "
        "it never feeds Krea conditioning. Krea remains connected to the required "
        "4B 12×2560 encoder stack. The result then flows into a four-megapixel, "
        "full-BF16 FLUX.2 Klein 9B reference-latent pass whose conservative "
        "instruction preserves composition and subjects while restoring natural "
        "texture and optical detail.</p>"
    )
    source_nodes[217]["widgets_values"][0] = json.dumps(note, separators=(",", ":"))

    flux_nodes = [
        copy_node(realism_source, node_id) for node_id in sorted(FLUX_NODE_IDS)
    ]
    for node in flux_nodes:
        shift_position(node, -4300)
    flux = {node["id"]: node for node in flux_nodes}
    flux[62]["widgets_values"][0] = "qwen_3_8b_bf16.safetensors"
    flux[63]["widgets_values"][0] = "flux-2-klein-9b-bf16.safetensors"
    flux[54]["widgets_values"][0] = (
        "Refine to high-definition photorealism while keeping the entire source image "
        "faithful. Preserve every subject, identity, expression, pose, body proportion, "
        "object, color, spatial relationship, composition, framing, wardrobe, background, "
        "and visible text. Restore natural skin, hair, material texture, and optical detail "
        "where appropriate. Do not add, remove, redesign, or beautify anything."
    )
    flux[54]["title"] = "Content-locked FLUX realism instruction"
    flux[56]["widgets_values"][1] = 4
    flux[56]["title"] = "Four-megapixel Krea handoff"
    flux[64]["title"] = "Match refined color to the Krea result"
    flux[65]["title"] = "Final conservative sharpen"
    flux[46]["title"] = "Final FLUX.2 Klein realistic image"
    flux[96]["mode"] = 0
    flux[96]["widgets_values"][0] = "Ep24_3c_Krea2_Enhancer_Klein9B_Realism"
    flux[96]["title"] = "Save Krea → Klein realism result"

    graph["nodes"].extend(flux_nodes)
    for link in realism_source["links"]:
        if link[1] in FLUX_NODE_IDS and link[3] in FLUX_NODE_IDS:
            add_link(graph, link[1], link[2], link[3], link[4], link[5])
    add_link(graph, 164, 0, 56, 0, "IMAGE")
    add_link(graph, 65, 0, 96, 0, "IMAGE")

    graph["groups"] = [
        *graph.get("groups", []),
        {
            "id": max(
                (group.get("id", 0) for group in graph.get("groups", [])),
                default=0,
            )
            + 1,
            "title": "FLUX.2 Klein 9B BF16 realistic finishing stage",
            "bounding": [700, 300, 2700, 1080],
            "color": "#3f789e",
            "font_size": 24,
            "flags": {},
        },
    ]
    for node in graph["nodes"]:
        node.get("properties", {}).pop("models", None)
    graph["extra"] = {
        **graph.get("extra", {}),
        "ds": {"scale": 0.65, "offset": [1120, 160]},
        "workflowRendererVersion": "LG",
    }
    rebuild_port_links(graph)
    normalize_orders(graph)
    graph["last_node_id"] = max(node["id"] for node in graph["nodes"])
    graph["last_link_id"] = max(link[0] for link in graph["links"])
    return graph


def validate_single_view_character_graph(graph: Graph) -> None:
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
    if index[240]["mode"] != 4 or index[241]["mode"] != 4:
        raise ValueError("all optional realism LoRAs must be bypassed by default")
    if index[232]["widgets_values"][0] != 1:
        raise ValueError(
            "single-view identity preservation must default to ref_boost 1"
        )
    if index[234]["properties"]["slidersState"]["sliders"][0]["value"] != 1:
        raise ValueError("the connected reference-boost slider must default to 1")
    source_resolution = json.loads(index[226]["properties"]["loadImagePixState"])
    if (
        source_resolution["ratio_preset"],
        source_resolution["fit_w"],
        source_resolution["fit_h"],
    ) != ("1:1", 1024, 1024):
        raise ValueError("the canonical source must be preprocessed to a 1:1 canvas")
    output_resolution = index[235]["widgets_values"][0]
    if (output_resolution["ratio"], output_resolution["w"], output_resolution["h"]) != (
        "1:1",
        1024,
        1024,
    ):
        raise ValueError(
            "single-view output must default to a 1:1 source-matched canvas"
        )
    target_latent_slot = next(
        slot
        for slot, node_input in enumerate(index[232]["inputs"])
        if node_input["name"] == "target_latent"
    )
    if not any(
        link[1:5] == [162, 0, 232, target_latent_slot] for link in graph["links"]
    ):
        raise ValueError("the Krea model patch must receive the sampler target latent")
    if index[46]["mode"] != 2 or index[96]["mode"] != 2:
        raise ValueError("optional FLUX outputs must be muted by default")
    if not any(link[1:5] == [65, 0, 96, 0] for link in graph["links"]):
        raise ValueError("optional FLUX output must be connected to its save node")


def validate_three_panel_character_sheet_graph(graph: Graph) -> None:
    node_ids = [node["id"] for node in graph["nodes"]]
    link_ids = [link[0] for link in graph["links"]]
    if len(node_ids) != len(set(node_ids)):
        raise ValueError("duplicate node id")
    if len(link_ids) != len(set(link_ids)):
        raise ValueError("duplicate link id")
    rebuild_port_links(copy.deepcopy(graph))

    index = nodes_by_id(graph)
    if any(node_id in index for node_id in FLUX_NODE_IDS):
        raise ValueError(
            "three-panel generation must not include the optional FLUX stage"
        )
    if index[240]["mode"] != 4 or index[241]["mode"] != 4:
        raise ValueError("three-panel generation must preserve style by default")
    if index[232]["widgets_values"][0] != 1:
        raise ValueError(
            "three-panel identity preservation must default to ref_boost 1"
        )
    if index[234]["properties"]["slidersState"]["sliders"][0]["value"] != 1:
        raise ValueError("the connected reference-boost slider must default to 1")

    source_resolution = json.loads(index[226]["properties"]["loadImagePixState"])
    if (
        source_resolution["ratio_preset"],
        source_resolution["fit_w"],
        source_resolution["fit_h"],
    ) != ("3:4", 768, 1024):
        raise ValueError("three-panel identity grounding must use a 3:4 source plate")
    output_resolution = index[235]["widgets_values"][0]
    if (output_resolution["w"], output_resolution["h"]) != (1536, 768):
        raise ValueError("the native three-panel canvas must be 1536×768")
    if (
        index[224]["widgets_values"][1] != 1024
        or index[228]["widgets_values"][1] != 1024
    ):
        raise ValueError("human identity grounding must default to 1024 pixels")

    if {node["id"] for node in graph["nodes"] if node["type"] == "SamplerCustom"} != {
        139
    }:
        raise ValueError("the complete sheet must be generated in one Krea pass")
    if {
        node["id"]
        for node in graph["nodes"]
        if node["type"] == "Krea2EditGroundedEncode"
    } != {224, 228}:
        raise ValueError("the sheet must use one positive and one negative encoder")

    prompt = index[221]["properties"]["promptState"]["text"]
    required_markers = (
        "THREE-PANEL CHARACTER REFERENCE SHEET",
        "FULL-BODY FRONT",
        "FULL-BODY REAR",
        "MAGNIFIED FACE CLOSE-UP ONLY",
        "flat 18% neutral gray",
    )
    missing_markers = [marker for marker in required_markers if marker not in prompt]
    if missing_markers:
        raise ValueError(f"invalid three-panel grammar: {missing_markers}")
    if index[503]["mode"] != 0 or index[503]["widgets_values"][0] != (
        "CharacterSheet_Krea2_3Panel"
    ):
        raise ValueError("the final three-panel sheet must be saved")

    target_latent_slot = next(
        slot
        for slot, node_input in enumerate(index[232]["inputs"])
        if node_input["name"] == "target_latent"
    )
    required_links = {
        (226, 0, 224, 1),
        (226, 0, 228, 1),
        (226, 0, 233, 0),
        (196, 0, 233, 1),
        (233, 0, 232, 1),
        (196, 0, 232, 4),
        (226, 0, 232, 5),
        (162, 0, 232, target_latent_slot),
        (162, 0, 139, 5),
        (164, 0, 503, 0),
    }
    actual_links = {tuple(link[1:5]) for link in graph["links"]}
    missing_links = required_links - actual_links
    if missing_links:
        raise ValueError(
            f"incomplete identity-preserving three-panel graph: {sorted(missing_links)}"
        )
    if any(link[1] in {226, 233} and link[3] == 139 for link in graph["links"]):
        raise ValueError(
            "the reference must provide tokens, never sampler initialization"
        )


def validate_prompt_enhancer_refinement_graph(graph: Graph) -> None:
    node_ids = [node["id"] for node in graph["nodes"]]
    link_ids = [link[0] for link in graph["links"]]
    if len(node_ids) != len(set(node_ids)):
        raise ValueError("duplicate node id")
    if len(link_ids) != len(set(link_ids)):
        raise ValueError("duplicate link id")
    rebuild_port_links(copy.deepcopy(graph))

    index = nodes_by_id(graph)
    if index[194]["widgets_values"][0] != "krea2_turbo_bf16.safetensors":
        raise ValueError("Krea stage must use the BF16 diffusion model")
    if index[195]["widgets_values"][0] != (
        "huihui_qwen3vl_4b_abliterated_bf16.safetensors"
    ):
        raise ValueError("Krea stage must preserve the Episode 24 abliterated encoder")
    if index[196]["widgets_values"][0] != "qwen_image_vae.safetensors":
        raise ValueError("Krea stage must preserve the Qwen Image VAE")
    if index[218]["widgets_values"] != [PROMPT_AUTHOR_ENCODER, "krea2", "default"]:
        raise ValueError("prompt author must use the isolated BF16 8B Heretic encoder")
    if not any(link[1:5] == [218, 0, 213, 0] for link in graph["links"]):
        raise ValueError("8B Heretic encoder is not connected to TextGenerate")
    if any(link[1] == 218 and link[3] == 6 for link in graph["links"]):
        raise ValueError("8B Heretic encoder must never feed Krea conditioning")
    if index[62]["widgets_values"][0] != "qwen_3_8b_bf16.safetensors":
        raise ValueError("FLUX stage must use the BF16 Qwen encoder")
    if index[63]["widgets_values"][0] != "flux-2-klein-9b-bf16.safetensors":
        raise ValueError("FLUX stage must use the BF16 Klein diffusion model")
    if index[51]["widgets_values"][0] != "flux2-vae.safetensors":
        raise ValueError("FLUX stage must use the FLUX.2 VAE")
    if index[56]["widgets_values"][1] != 4:
        raise ValueError("FLUX handoff must target four megapixels")
    if index[96]["mode"] != 0:
        raise ValueError("the final FLUX result must be saved")
    if not any(link[1:5] == [164, 0, 56, 0] for link in graph["links"]):
        raise ValueError("Krea output is not connected to the FLUX refinement stage")
    if not any(link[1:5] == [65, 0, 96, 0] for link in graph["links"]):
        raise ValueError("FLUX refinement output is not connected to its save node")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--single-view", type=Path)
    source.add_argument("--three-panel", type=Path)
    source.add_argument("--prompt-enhancer", type=Path)
    parser.add_argument("--realism", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    realism = json.loads(args.realism.read_text())
    if args.single_view is not None:
        workflow = build_single_view_character_workflow(
            json.loads(args.single_view.read_text()), realism
        )
        validate_single_view_character_graph(workflow)
    elif args.three_panel is not None:
        workflow = build_three_panel_character_sheet_workflow(
            json.loads(args.three_panel.read_text()), realism
        )
        validate_three_panel_character_sheet_graph(workflow)
    else:
        workflow = build_prompt_enhancer_refinement_workflow(
            json.loads(args.prompt_enhancer.read_text()), realism
        )
        validate_prompt_enhancer_refinement_graph(workflow)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(workflow, indent=2) + "\n")


if __name__ == "__main__":
    main()
