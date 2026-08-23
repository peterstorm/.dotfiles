#!/usr/bin/env python3
"""Build a validated local-BF16 contest production pack from audited graphs."""

from __future__ import annotations

import argparse
import copy
import json
import math
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Literal

from pixaroma_workflow_state import (
    synchronize_pixaroma_lora_state,
    validate_pixaroma_lora_state,
)

Graph = dict[str, Any]
QualityTier = Literal["turbo", "raw"]
IDENTITY_EDIT_LORA = "krea2/krea2_identity_edit_v1_2.safetensors"
OUTFIT_TRANSFER_LORA = "krea2/krea_outfittransfer.safetensors"

FACE_LOCK_PROMPT = (
    "Create one canonical chest-up face lock from the complete Muse-authored character "
    "specification pasted here. Frame from forehead to upper chest with the face filling "
    "most of the image. Use a plain black neutral baseline top, a single flat 18% neutral "
    "gray color field, completely shadowless illumination, zero cast or contact shadow, "
    "zero light spill, true skin tone, fine flattering biological skin detail, even "
    "edge-to-edge sharpness, and no environmental context."
)
ADDITION_PROMPT = (
    "Paste the complete Muse-authored addition or re-lock prompt here. Preserve the "
    "attached character's exact identity and every unchanged feature. Change only the "
    "explicitly requested permanent hair, marking, piercing, scar, makeup, body, or "
    "expression feature. Return one canonical chest-up identity plate on a flat 18% "
    "neutral gray field with shadowless light and zero cast shadow or light spill."
)
FULL_LOOK_PROMPT = (
    "Paste the complete Muse-authored full-look outfit prompt here. Preserve the attached "
    "face lock's exact identity, face geometry, skin tone, hair, and body proportions. "
    "Render one full-body figure head to footwear in a tall vertical frame, with the "
    "approved outfit, layering, materials, accessories, and styling fully readable. Use "
    "a flat 18% neutral gray color field, shadowless illumination, and zero cast or "
    "contact shadow or light spill."
)
EXPRESSION_SET_PROMPT = (
    "A three-panel expression reference composed as one horizontal image with three equal "
    "vertical panels. Paste the complete Muse-authored expression-set prompt here. The "
    "same attached character appears chest-up at identical scale, identity, wardrobe, "
    "framing, and true skin tone in every panel. Only the explicitly described facial "
    "muscles, gaze, lids, brows, mouth, and jaw differ. Flat 18% neutral gray field, "
    "shadowless light, zero cast shadow or light spill, and no text or labels."
)
HEADLESS_SHEET_PROMPT = (
    "A three-panel character reference sheet composed as one horizontal image with three "
    "equal vertical panels. Paste the complete Muse-authored character-sheet prompt here. "
    "Describe identity and wardrobe once. LEFT: full-body front with the head and hair "
    "removed, full headroom preserved, and the garment's correct ghost-mannequin hollow "
    "or clean neck termination. CENTER: strict full-body rear with head attached. RIGHT: "
    "tight chest-up face lock filling the panel. Keep identity, wardrobe, skin tone, and "
    "materials identical. Flat 18% neutral gray field, shadowless light, zero shadow or "
    "spill in every panel, and no text, labels, numbering, or extra panels."
)
SIX_PANEL_PROMPT = (
    "OPTIONAL REDUCED-DETAIL FORMAT. A single six-panel character sheet in a three-column "
    "by two-row grid. Paste the complete Muse-authored six-panel prompt here. Describe "
    "identity and wardrobe once, then specify full-body front, left profile chest-up, "
    "full-body rear, right profile chest-up, front chest-up face lock, and one requested "
    "detail close-up. Keep identity, wardrobe, skin tone, scale, flat 18% neutral gray, "
    "shadowless illumination, and zero cast shadow or spill consistent in every cell. No "
    "rendered text, labels, or numbering."
)
GARMENT_PLATE_PROMPT = (
    "Paste the complete Muse-authored invisible-mannequin garment-repair prompt here. "
    "Render one failed garment only, holding its full worn three-dimensional shape on an "
    "invisible body. Preserve exact construction, material, weave, cut, closures, seams, "
    "hardware, pattern scale, and drape. No head, neck, hands, body, mannequin, hanger, "
    "stand, anatomy, or ghosting. Flat 18% neutral gray field, shadowless illumination, "
    "zero cast shadow or light spill, even sharpness, and real material detail."
)
ENVIRONMENT_PROMPT = (
    "Paste the complete five-paragraph Muse-authored cinematic environment or scene-plate "
    "prompt here without shortening it. Generate one still frame with the requested "
    "composition, world, physical light, atmosphere, lens character, materials, grade, "
    "and realism close. No prompt enhancement, style LoRA, on-screen text, captions, "
    "watermarks, or unrequested characters."
)
CHARACTER_WORLD_PROMPT = (
    "Paste the complete Muse-authored character-in-environment scene-plate prompt here. "
    "Picture 1 carries the approved character identity and wardrobe. Picture 2 carries "
    "world geometry, set dressing, palette, and atmosphere only. Preserve those roles "
    "without averaging or compositing either source into a visible panel. Generate one "
    "new cinematic still with the requested action, composition, camera, light, and "
    "finish, with no text, labels, watermarks, duplicate subjects, or source display."
)
OUTFIT_TRANSFER_PROMPT = (
    "Keep the person in Picture 1 exactly and apply only the wearable outfit and "
    "accessories from Picture 2. Preserve the identity, face, bone structure, body type, "
    "skin tone, hair, pose, and hands from Picture 1. Preserve the garments, colors, "
    "materials, cut, fit, hem positions, footwear, jewelry, and accessories from Picture "
    "2. Ignore its model, background, hangers, stands, packaging, and labels. Full-body "
    "framing on a flat 18% neutral gray field with shadowless illumination and zero cast "
    "shadow or light spill."
)
KLEIN_FINISH_PROMPT = (
    "Conservatively finish this accepted still at high fidelity. Preserve every subject, "
    "identity, expression, pose, body proportion, object, color, spatial relationship, "
    "composition, framing, wardrobe, background, visible physical text, and visual "
    "medium. Restore only natural skin, hair, fabric, material, optical, and fine surface "
    "detail. Do not add, remove, redesign, beautify, relight, recrop, or restyle anything."
)
H3_T2V_PROMPT = (
    "Paste one complete Muse-authored Cinema Director prompt here. Use this text-only "
    "workflow for a pure environment, atmospheric motion plate, or scene that requires no "
    "identity reference. Keep one coherent shot or an explicitly timecoded sequence no "
    "longer than 15 seconds, including capture cadence, camera movement, physical action, "
    "last frame, and Sound Bed. No on-screen text, captions, logos, or watermarks."
)
H3_FL2VA_PROMPT = (
    "Paste one complete Muse-authored Cinema Director prompt here. <Picture 1> is the exact "
    "approved opening composition. Preserve its identity, wardrobe, world, palette, and "
    "visual style while executing the stated action, camera movement, environmental "
    "motion, dialogue, effects, ambience, and music. Keep the shot at 15 seconds or less "
    "and generate no on-screen text, captions, logos, or watermarks."
)
H3_FL2VA_LAST_PROMPT = (
    "Paste one complete Muse-authored Cinema Director prompt here. <Picture 1> is the exact "
    "opening composition and <Picture 2> is the exact closing composition. Preserve "
    "identity, wardrobe, world, palette, and style while moving continuously and "
    "plausibly between them. The prompt owns action, camera, atmosphere, dialogue, sound "
    "effects, ambience, and music. Keep the shot at 15 seconds or less and generate no "
    "on-screen text, captions, logos, or watermarks."
)
H3_REF_PROMPT = (
    "Paste one complete Muse-authored Cinema Director prompt here. <Picture 1> carries the "
    "approved full-look character identity and wardrobe. <Picture 2> carries only its "
    "explicit world, prop, second-character, or style role. Preserve the stated reference "
    "roles and continuity while executing one coherent action and camera move with "
    "dialogue, effects, ambience, and music. Keep the shot at 15 seconds or less; add no "
    "unrequested characters, wardrobe changes, on-screen text, captions, or watermarks."
)


@dataclass(frozen=True)
class IdentityVariant:
    title: str
    prompt: str
    source_ratio: str
    source_width: int
    source_height: int
    output_width: int
    output_height: int
    output_prefix: str


@dataclass(frozen=True)
class SheetVariant:
    title: str
    prompt: str
    output_width: int
    output_height: int
    output_prefix: str


IDENTITY_VARIANTS = {
    "addition": IdentityVariant(
        "Character Addition / Canonical Re-lock",
        ADDITION_PROMPT,
        "3:4",
        768,
        1024,
        768,
        1024,
        "Contest_Character_Addition_Relock",
    ),
    "full-look": IdentityVariant(
        "Character Full-Look Outfit Plate",
        FULL_LOOK_PROMPT,
        "3:4",
        768,
        1024,
        768,
        1344,
        "Contest_Character_FullLook",
    ),
}
SHEET_VARIANTS = {
    "expressions": SheetVariant(
        "Character Three-Expression Identity Set",
        EXPRESSION_SET_PROMPT,
        1536,
        768,
        "Contest_Character_ExpressionSet",
    ),
    "headless-sheet": SheetVariant(
        "Character Three-Panel Headless Working Sheet",
        HEADLESS_SHEET_PROMPT,
        1536,
        768,
        "Contest_Character_HeadlessSheet",
    ),
    "six-panel": SheetVariant(
        "OPTIONAL Character Six-Panel Sheet — Reduced Detail",
        SIX_PANEL_PROMPT,
        1536,
        1024,
        "Contest_Character_6Panel_ReducedDetail",
    ),
}


def load_graph(path: Path) -> Graph:
    return json.loads(path.read_text())


def nodes_by_id(graph: Graph) -> dict[int, Graph]:
    return {node["id"]: node for node in graph["nodes"]}


def next_link_id(graph: Graph) -> int:
    return max((link[0] for link in graph["links"]), default=0) + 1


def add_link(
    graph: Graph,
    source_id: int,
    source_slot: int,
    destination_id: int,
    destination_slot: int,
    value_type: str,
) -> int:
    link_id = next_link_id(graph)
    graph["links"].append(
        [link_id, source_id, source_slot, destination_id, destination_slot, value_type]
    )
    return link_id


def remove_nodes(graph: Graph, node_ids: set[int]) -> None:
    graph["nodes"] = [node for node in graph["nodes"] if node["id"] not in node_ids]
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
        if source_id not in index or destination_id not in index:
            raise ValueError(f"link {link_id} references a missing node")
        source = index[source_id]
        destination = index[destination_id]
        if source_slot >= len(source.get("outputs", [])):
            raise ValueError(f"link {link_id} has an invalid source slot")
        if destination_slot >= len(destination.get("inputs", [])):
            raise ValueError(f"link {link_id} has an invalid destination slot")
        destination_key = (destination_id, destination_slot)
        if destination_key in occupied_inputs:
            raise ValueError(f"multiple links target {destination_key}")
        occupied_inputs.add(destination_key)
        source["outputs"][source_slot].setdefault("links", []).append(link_id)
        destination["inputs"][destination_slot]["link"] = link_id


def validate_graph(graph: Graph) -> None:
    node_ids = [node["id"] for node in graph["nodes"]]
    link_ids = [link[0] for link in graph["links"]]
    if len(node_ids) != len(set(node_ids)):
        raise ValueError("duplicate node id")
    if len(link_ids) != len(set(link_ids)):
        raise ValueError("duplicate link id")
    index = nodes_by_id(graph)
    for link in graph["links"]:
        if link[1] not in index or link[3] not in index:
            raise ValueError(f"dangling link {link[0]}")


def strip_model_metadata(value: Any) -> None:
    if isinstance(value, dict):
        properties = value.get("properties")
        if isinstance(properties, dict):
            properties.pop("models", None)
        for item in value.values():
            strip_model_metadata(item)
    elif isinstance(value, list):
        for item in value:
            strip_model_metadata(item)


def finalize(graph: Graph) -> Graph:
    for node in graph["nodes"]:
        if node.get("type") == "PixaromaLoraLoader":
            synchronize_pixaroma_lora_state(node)
    strip_model_metadata(graph)
    for order, node in enumerate(graph["nodes"]):
        node["order"] = order
    rebuild_port_links(graph)
    graph["last_node_id"] = max(node["id"] for node in graph["nodes"])
    graph["last_link_id"] = max((link[0] for link in graph["links"]), default=0)
    validate_graph(graph)
    return graph


def set_label_text(node: Graph, text: str) -> None:
    label = json.loads(node["widgets_values"][0])
    label["text"] = text
    node["widgets_values"][0] = json.dumps(label, separators=(",", ":"))


def set_prompt_node(node: Graph, prompt: str) -> None:
    if node.get("widgets_values"):
        node["widgets_values"][0] = prompt
    prompt_state = node.get("properties", {}).get("promptState")
    if prompt_state is not None:
        prompt_state["text"] = prompt


def ratio_parts(ratio: str) -> tuple[int, int]:
    width, height = ratio.split(":", maxsplit=1)
    return int(width), int(height)


def set_pixaroma_image_geometry(
    node: Graph, ratio: str, width: int, height: int
) -> None:
    ratio_width, ratio_height = ratio_parts(ratio)
    state = json.loads(node["properties"]["loadImagePixState"])
    state.update(
        {
            "fit_w": width,
            "fit_h": height,
            "cover_w": width,
            "cover_h": height,
            "ratio_preset": ratio,
            "ratio_w": ratio_width,
            "ratio_h": ratio_height,
            "ratio_action": "crop",
        }
    )
    node["properties"]["loadImagePixState"] = json.dumps(state, separators=(",", ":"))


def set_pixaroma_output_geometry(node: Graph, width: int, height: int) -> None:
    divisor = math.gcd(width, height)
    state = copy.deepcopy(node["widgets_values"][0])
    state.update(
        {
            "mode": "custom",
            "ratio": "custom",
            "w": width,
            "h": height,
            "custom_w": width,
            "custom_h": height,
            "custom_ratio_w": width // divisor,
            "custom_ratio_h": height // divisor,
        }
    )
    node["widgets_values"][0] = state
    node["properties"]["resolutionState"] = json.dumps(state, separators=(",", ":"))


def build_t2i_variant(
    source: Graph,
    *,
    title: str,
    prompt: str,
    width: int,
    height: int,
    prefix: str,
) -> Graph:
    graph = copy.deepcopy(source)
    remove_nodes(graph, {47, 48, 49, 50})
    index = nodes_by_id(graph)
    pipeline = index[30]
    pipeline["title"] = f"{title} — paste the complete Muse prompt"
    pipeline["widgets_values"][0] = prompt
    pipeline["widgets_values"][1] = False
    pipeline["widgets_values"][3] = 2048
    pipeline["widgets_values"][4] = width
    pipeline["widgets_values"][5] = height
    pipeline["widgets_values"][7] = False
    index[29]["title"] = f"SAVE — {title}"
    index[29]["widgets_values"][0] = prefix
    return finalize(graph)


def build_identity_variant(
    source: Graph, variant: IdentityVariant, quality_tier: QualityTier
) -> Graph:
    graph = copy.deepcopy(source)
    index = nodes_by_id(graph)
    set_label_text(index[198], f"{variant.title} — {quality_tier.upper()} BF16")
    set_prompt_node(index[221], variant.prompt)
    index[221]["title"] = "PASTE COMPLETE MUSE PROMPT — sent directly to Krea"
    index[226]["title"] = "Picture 1 — canonical identity reference"
    set_pixaroma_image_geometry(
        index[226], variant.source_ratio, variant.source_width, variant.source_height
    )
    set_pixaroma_output_geometry(
        index[235], variant.output_width, variant.output_height
    )
    index[235]["title"] = (
        f"Independent target canvas — {variant.output_width}×{variant.output_height}"
    )
    index[224]["widgets_values"][1] = 1024
    index[228]["widgets_values"][1] = 1024
    index[232]["widgets_values"][0] = 1
    index[234]["properties"]["slidersState"]["sliders"][0]["value"] = 1
    synchronize_pixaroma_lora_state(index[231], IDENTITY_EDIT_LORA)
    index[199]["title"] = "PRIMARY OUTPUT — inspect identity before approval"
    index[199]["widgets_values"][0] = f"{variant.output_prefix}_{quality_tier.upper()}"
    return finalize(graph)


def build_sheet_variant(source: Graph, variant: SheetVariant) -> Graph:
    graph = copy.deepcopy(source)
    index = nodes_by_id(graph)
    set_label_text(index[198], f"{variant.title} — RAW BF16")
    set_prompt_node(index[221], variant.prompt)
    index[221]["title"] = "PASTE COMPLETE MUSE SHEET PROMPT — one image, one sampler"
    set_pixaroma_output_geometry(
        index[235], variant.output_width, variant.output_height
    )
    index[235]["title"] = (
        f"Independent sheet canvas — {variant.output_width}×{variant.output_height}"
    )
    synchronize_pixaroma_lora_state(index[231], IDENTITY_EDIT_LORA)
    index[503]["title"] = f"SAVE — {variant.title}"
    index[503]["widgets_values"][0] = variant.output_prefix
    return finalize(graph)


def build_character_world_variant(source: Graph, quality_tier: QualityTier) -> Graph:
    graph = copy.deepcopy(source)
    index = nodes_by_id(graph)
    index[194]["widgets_values"][0] = (
        "krea2_raw_bf16.safetensors"
        if quality_tier == "raw"
        else "krea2_turbo_bf16.safetensors"
    )
    index[195]["widgets_values"][0] = "qwen3vl_4b_bf16.safetensors"
    index[196]["widgets_values"][0] = "qwen_image_vae.safetensors"
    synchronize_pixaroma_lora_state(index[231], IDENTITY_EDIT_LORA)
    index[232]["widgets_values"][0] = 1
    index[234]["properties"]["slidersState"]["sliders"][0]["value"] = 1
    index[224]["widgets_values"][1] = 1024
    index[228]["widgets_values"][1] = 1024
    index[226]["title"] = "Picture 1 — approved full-look character"
    index[236]["title"] = "Picture 2 — world plate only"
    set_pixaroma_image_geometry(index[226], "3:4", 768, 1024)
    set_pixaroma_image_geometry(index[236], "16:9", 1344, 768)
    set_pixaroma_output_geometry(index[235], 1344, 768)
    index[235]["title"] = "Independent cinematic target canvas — 1344×768"
    set_prompt_node(index[221], CHARACTER_WORLD_PROMPT)
    index[221]["title"] = "PASTE COMPLETE MUSE SCENE-PLATE PROMPT"
    index[163]["widgets_values"][2:7] = (
        [20, 3, "euler", "simple", 1]
        if quality_tier == "raw"
        else [10, 1, "er_sde", "simple", 1]
    )
    index[163]["title"] = (
        "RAW production — 20 steps, CFG 3"
        if quality_tier == "raw"
        else "Turbo preview — 10 steps, CFG 1"
    )
    index[199]["title"] = "SAVE — character and world scene plate"
    index[199]["widgets_values"][0] = f"Contest_CharacterWorld_{quality_tier.upper()}"
    if quality_tier == "raw":
        remove_nodes(graph, {207})
        add_link(graph, 194, 0, 231, 0, "MODEL")
    return finalize(graph)


def build_outfit_transfer_variant(source: Graph) -> Graph:
    graph = copy.deepcopy(source)
    index = nodes_by_id(graph)
    index[226]["title"] = "Picture 1 — canonical character identity"
    index[236]["title"] = "Picture 2 — approved outfit and pose source"
    set_pixaroma_image_geometry(index[226], "3:4", 768, 1024)
    set_pixaroma_image_geometry(index[236], "3:4", 768, 1024)
    set_pixaroma_output_geometry(index[235], 768, 1344)
    index[235]["title"] = "Full-body target canvas — 768×1344"
    index[224]["widgets_values"][1] = 1024
    index[228]["widgets_values"][1] = 1024
    synchronize_pixaroma_lora_state(index[231], OUTFIT_TRANSFER_LORA)
    index[232]["widgets_values"][0] = 1
    index[238]["title"] = "Editable local outfit-transfer role instruction"
    index[238]["widgets_values"] = [OUTFIT_TRANSFER_PROMPT, ""]
    index[199]["title"] = "SAVE — approved character in approved outfit"
    index[199]["widgets_values"][0] = "Contest_OutfitTransfer_Turbo"
    return finalize(graph)


def replace_strings(value: Any, replacements: dict[str, str]) -> Any:
    if isinstance(value, str):
        result = value
        for old, new in replacements.items():
            result = result.replace(old, new)
        return result
    if isinstance(value, list):
        return [replace_strings(item, replacements) for item in value]
    if isinstance(value, dict):
        return {key: replace_strings(item, replacements) for key, item in value.items()}
    return value


def build_klein_finish_variant(source: Graph) -> Graph:
    graph = copy.deepcopy(source)
    remove_nodes(graph, {92, 97, 121, 122})
    graph = replace_strings(
        graph,
        {
            "flux-2-klein-9b-fp8.safetensors": "flux-2-klein-9b-bf16.safetensors",
            "qwen_3_8b_fp8mixed.safetensors": "qwen_3_8b_bf16.safetensors",
            "full_encoder_small_decoder.safetensors": "flux2-vae.safetensors",
        },
    )
    index = nodes_by_id(graph)
    index[76]["title"] = "Accepted still — sole edit reference"
    index[75]["title"] = "Full-BF16 conservative Klein finish"
    index[75]["widgets_values"][0:4] = [
        "flux-2-klein-9b-bf16.safetensors",
        "qwen_3_8b_bf16.safetensors",
        "flux2-vae.safetensors",
        KLEIN_FINISH_PROMPT,
    ]
    index[9]["title"] = "SAVE — identity- and composition-locked finish"
    index[9]["widgets_values"][0] = "Contest_AcceptedStill_Klein9B_BF16"
    return finalize(graph)


def build_h3_t2v_variant(source: Graph) -> Graph:
    graph = copy.deepcopy(source)
    index = nodes_by_id(graph)
    index[105]["title"] = "PURE ENVIRONMENT / TEXT-ONLY — BF16 FL2VA family"
    index[105]["widgets_values"][0:5] = [H3_T2V_PROMPT, 1344, 768, 5, 556589502035082]
    index[115]["title"] = "Native 768p short edge — 1344×768"
    index[115]["widgets_values"] = ["16:9 (Widescreen)", 0.98, 32]
    index[92]["title"] = "SAVE — accepted text-only H3 shot"
    index[92]["widgets_values"][0] = "video/Contest_H3_T2V_Environment"
    index[117]["title"] = "SAFE PHASE — run h3-model-phase prepare fl2va first"
    return finalize(graph)


def build_h3_fl2va_variant(source: Graph, include_last_frame: bool) -> Graph:
    graph = copy.deepcopy(source)
    index = nodes_by_id(graph)
    index[105]["widgets_values"][0] = (
        H3_FL2VA_LAST_PROMPT if include_last_frame else H3_FL2VA_PROMPT
    )
    index[105]["title"] = (
        "BF16 FL2VA — exact first and last frames"
        if include_last_frame
        else "BF16 FL2VA — exact first frame"
    )
    index[92]["widgets_values"][0] = (
        "video/Contest_H3_FL2VA_FirstLast"
        if include_last_frame
        else "video/Contest_H3_FL2VA_FirstFrame"
    )
    if include_last_frame:
        last_frame = copy.deepcopy(index[114])
        last_frame["id"] = 500
        last_frame["title"] = "Picture 2 — exact approved last frame"
        last_frame["widgets_values"][0] = "last_frame.png"
        graph["nodes"].append(last_frame)
        add_link(graph, 500, 0, 105, 1, "IMAGE")
    return finalize(graph)


def build_h3_ref_variant(source: Graph) -> Graph:
    graph = copy.deepcopy(source)
    index = nodes_by_id(graph)
    index[137]["title"] = "Picture 1 — approved full-look character"
    index[139]["title"] = "Picture 2 — explicit world / prop / second-character role"
    set_prompt_node(index[138], H3_REF_PROMPT)
    index[138]["title"] = "PASTE COMPLETE MUSE CINEMA DIRECTOR PROMPT"
    index[132]["widgets_values"][0] = 5
    index[92]["widgets_values"][0] = "video/Contest_H3_REF2VA_CharacterWorld"
    index[92]["title"] = "SAVE — accepted reference-conditioned H3 shot"
    return finalize(graph)


def validate_pack(workflows: dict[str, Graph]) -> None:
    if len(workflows) != 21:
        raise ValueError("contest pack must contain exactly 21 workflows")
    forbidden = (
        "krea2_turbo_int8",
        "krea2_turbo_fp8",
        "flux-2-klein-9b-fp8",
        "qwen_3_8b_fp8",
        "pruned_int8",
        "nvfp4",
        "/resolve/main/",
        "/tree/main/",
        "comfyui-manager",
    )
    violations = {
        marker: [
            filename
            for filename, graph in workflows.items()
            if marker in json.dumps(graph).lower()
        ]
        for marker in forbidden
    }
    violations = {marker: files for marker, files in violations.items() if files}
    if violations:
        raise ValueError(f"forbidden selectors or dependencies: {violations}")
    for graph in workflows.values():
        validate_graph(graph)
        for node in graph["nodes"]:
            if node.get("type") == "PixaromaLoraLoader":
                validate_pixaroma_lora_state(node)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    for name in (
        "turbo-t2i",
        "raw-t2i",
        "turbo-identity",
        "raw-identity",
        "raw-sheet",
        "character-world",
        "outfit-transfer",
        "raw-klein-chain",
        "klein-edit",
        "h3-t2v",
        "h3-fl2va",
        "h3-ref2va",
    ):
        parser.add_argument(f"--{name}", required=True, type=Path)
    parser.add_argument("--output-dir", required=True, type=Path)
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    turbo_t2i = load_graph(args.turbo_t2i)
    raw_t2i = load_graph(args.raw_t2i)
    turbo_identity = load_graph(args.turbo_identity)
    raw_identity = load_graph(args.raw_identity)
    raw_sheet = load_graph(args.raw_sheet)
    h3_fl2va = load_graph(args.h3_fl2va)
    workflows = {
        "01 Character Face Lock - Turbo BF16 Preview.json": build_t2i_variant(
            turbo_t2i,
            title="Character Face Lock — Turbo BF16 Preview",
            prompt=FACE_LOCK_PROMPT,
            width=768,
            height=1024,
            prefix="Contest_FaceLock_Turbo",
        ),
        "02 Character Face Lock - RAW BF16 Production.json": build_t2i_variant(
            raw_t2i,
            title="Character Face Lock — RAW BF16 Production",
            prompt=FACE_LOCK_PROMPT,
            width=768,
            height=1024,
            prefix="Contest_FaceLock_RAW",
        ),
        "03 Character Addition Re-Lock - Turbo BF16 Preview.json": build_identity_variant(
            turbo_identity, IDENTITY_VARIANTS["addition"], "turbo"
        ),
        "04 Character Addition Re-Lock - RAW BF16 Production.json": build_identity_variant(
            raw_identity, IDENTITY_VARIANTS["addition"], "raw"
        ),
        "05 Character Full-Look Outfit - Turbo BF16 Preview.json": build_identity_variant(
            turbo_identity, IDENTITY_VARIANTS["full-look"], "turbo"
        ),
        "06 Character Full-Look Outfit - RAW BF16 Production.json": build_identity_variant(
            raw_identity, IDENTITY_VARIANTS["full-look"], "raw"
        ),
        "07 Character Outfit Transfer - Turbo BF16 Adapter.json": build_outfit_transfer_variant(
            load_graph(args.outfit_transfer)
        ),
        "08 Character Expression Set - RAW BF16 Production.json": build_sheet_variant(
            raw_sheet, SHEET_VARIANTS["expressions"]
        ),
        "09 Character Headless Three-Panel Sheet - RAW BF16 Production.json": build_sheet_variant(
            raw_sheet, SHEET_VARIANTS["headless-sheet"]
        ),
        "10 OPTIONAL Character Six-Panel Sheet - RAW BF16 Reduced Detail.json": build_sheet_variant(
            raw_sheet, SHEET_VARIANTS["six-panel"]
        ),
        "11 Invisible-Mannequin Garment Repair - RAW BF16.json": build_t2i_variant(
            raw_t2i,
            title="Invisible-Mannequin Garment Repair — RAW BF16",
            prompt=GARMENT_PLATE_PROMPT,
            width=768,
            height=1024,
            prefix="Contest_GarmentRepair_RAW",
        ),
        "12 Environment or Scene Plate - Turbo BF16 Preview.json": build_t2i_variant(
            turbo_t2i,
            title="Environment or Scene Plate — Turbo BF16 Preview",
            prompt=ENVIRONMENT_PROMPT,
            width=1344,
            height=768,
            prefix="Contest_ScenePlate_Turbo",
        ),
        "13 Environment or Scene Plate - RAW BF16 Production.json": build_t2i_variant(
            raw_t2i,
            title="Environment or Scene Plate — RAW BF16 Production",
            prompt=ENVIRONMENT_PROMPT,
            width=1344,
            height=768,
            prefix="Contest_ScenePlate_RAW",
        ),
        "14 Character and World Scene Plate - Turbo BF16 Preview.json": build_character_world_variant(
            load_graph(args.character_world), "turbo"
        ),
        "15 Character and World Scene Plate - RAW BF16 Production.json": build_character_world_variant(
            load_graph(args.character_world), "raw"
        ),
        "16 Krea RAW to FLUX Klein 9B - 4MP Production Finish.json": load_graph(
            args.raw_klein_chain
        ),
        "17 Accepted Still to FLUX Klein 9B - BF16 Conservative Finish.json": build_klein_finish_variant(
            load_graph(args.klein_edit)
        ),
        "18 H3 T2V Pure Environment - BF16 Production.json": build_h3_t2v_variant(
            load_graph(args.h3_t2v)
        ),
        "19 H3 FL2VA First Frame - BF16 Production.json": build_h3_fl2va_variant(
            h3_fl2va, False
        ),
        "20 H3 FL2VA First and Last Frames - BF16 Production.json": build_h3_fl2va_variant(
            h3_fl2va, True
        ),
        "21 H3 REF2VA Character and World References - BF16 Production.json": build_h3_ref_variant(
            load_graph(args.h3_ref2va)
        ),
    }
    validate_pack(workflows)
    args.output_dir.mkdir(parents=True, exist_ok=True)
    for filename, graph in workflows.items():
        (args.output_dir / filename).write_text(json.dumps(graph, indent=2) + "\n")


if __name__ == "__main__":
    main()
