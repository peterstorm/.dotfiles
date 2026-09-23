#!/usr/bin/env python3
"""Pure, pinned Qwen Image 2.1 adaptations of selected Krea 2 compositions.

Model-family-specific Krea sampler/encoder/LoRA nodes are never transplanted:
the official Qwen 2.1 graph is the execution contract; Krea contributes only
creative prompts and the direct/native-2K use cases.
"""

import argparse
import copy
import hashlib
import json
from pathlib import Path

T2I_SHA = "d33a6b36d530756e26ef4e25beb17d950daaea09d295475cd65f97f5d0af3b41"
EDIT_SHA = "d6dd8695469c20ca5e77b4bddf981b898ee0e034f0cfc5840c86f15b812ca081"
MODEL = "qwen_image_2.1_bf16.safetensors"
ENCODER = "qwen3vl_8b_bf16.safetensors"
VAE = "qwen_image_2.1_vae_bf16.safetensors"
REVISION = "5dc5850eb514a3685f6a03a2641728a8f7549c69"
TEMPLATE_REVISION = "371a7b7171bbd11e9cc92ef615ba5ad223d7e5b4"


def node(graph, identifier):
    matches = [entry for entry in graph["nodes"] if entry["id"] == identifier]
    if len(matches) != 1:
        raise ValueError(f"expected one node {identifier}, got {len(matches)}")
    return matches[0]


def read_json(path, digest=None):
    data = path.read_bytes()
    if digest and hashlib.sha256(data).hexdigest() != digest:
        raise ValueError(f"upstream template digest drift: {path}")
    return json.loads(data)


def adapt(template, *, prompt, resolution, prefix, edit=False):
    graph = copy.deepcopy(template)
    definitions = graph["definitions"]["subgraphs"]
    if len(definitions) != 1:
        raise ValueError("expected one official Qwen 2.1 subgraph")
    inner = definitions[0]
    required = {"UNETLoader", "CLIPLoader", "VAELoader", "TextEncodeQwenImage21", "KSampler"}
    types = {entry["type"] for entry in inner["nodes"]}
    if not required <= types or ("QwenImage21Cache" in types) != edit:
        raise ValueError(f"unexpected Qwen 2.1 execution contract: {types}")

    for entry in inner["nodes"]:
        if entry["type"] == "UNETLoader":
            entry["widgets_values"][0] = MODEL
        elif entry["type"] == "CLIPLoader":
            entry["widgets_values"][0] = ENCODER
        elif entry["type"] == "VAELoader":
            entry["widgets_values"][0] = VAE
        elif entry["type"] == "KSampler":
            entry["widgets_values"][2:4] = [50, 1]
            entry["widgets_values"][4:6] = ["euler", "simple"]
        elif entry["type"] == "QwenImage21Cache":
            entry["widgets_values"] = ["auto", "default"]

    outer = node(graph, 459)
    values = outer["widgets_values"]
    values[0 if not edit else 1] = prompt
    # Model, encoder, and VAE are also exposed as subgraph widgets: changing
    # only the inner loader would leave the outer selection on the INT8 files.
    for filename, replacement in (("qwen_image_2.1_int8_convrot.safetensors", MODEL),
                                  ("qwen3vl_8b_int8_convrot.safetensors", ENCODER)):
        if values.count(filename) != 1:
            raise ValueError(f"missing unique outer selector: {filename}")
        values[values.index(filename)] = replacement
    values[values.index(25)] = 50
    selector = node(graph, 13)
    selector["widgets_values"][:2] = resolution
    node(graph, 461)["widgets_values"][0] = prefix
    for entry in graph["nodes"]:
        if entry["type"] == "MarkdownNote":
            entry["widgets_values"] = [
                f"Qwen Image 2.1 BF16 research/evaluation only. Comfy-Org/Qwen-Image-2.1@{REVISION}; "
                f"templates@{TEMPLATE_REVISION}. This adapts Krea 2 creative content, NOT "
                "Krea-specific LoRAs, samplers, or enhancer nodes. Native 2K is direct, not "
                "Krea's extra pass. ComfyUI >=0.37.0 required. Qwen Research License "
                "prohibits commercial use without a separate commercial license."
            ]
    if edit:
        # Original template demo images were not shipped. Require explicit
        # user-supplied files before execution instead of silently using demos.
        for entry in graph["nodes"]:
            if entry["type"] == "LoadImage":
                entry["widgets_values"][0] = "qwen-image-2.1/select-local-reference.png"
    graph["extra"]["qwen_image_2_1_source_revision"] = TEMPLATE_REVISION
    graph["extra"]["qwen_image_2_1_model_revision"] = REVISION
    return graph


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--t2i-template", type=Path, required=True)
    parser.add_argument("--edit-template", type=Path, required=True)
    parser.add_argument("--krea-raw", type=Path, required=True)
    parser.add_argument("--krea-2k", type=Path, required=True)
    parser.add_argument("--krea-identity", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    args = parser.parse_args()

    t2i = read_json(args.t2i_template, T2I_SHA)
    edit = read_json(args.edit_template, EDIT_SHA)
    raw = read_json(args.krea_raw)
    large = read_json(args.krea_2k)
    identity = read_json(args.krea_identity)
    profiles = (
        ("01 Qwen Image 2.1 BF16 - Krea RAW composition.json",
         adapt(t2i, prompt=node(raw, 30)["widgets_values"][0],
               resolution=["1:1 (Square)", 1], prefix="Qwen21_BF16_KreaComposition")),
        ("02 Qwen Image 2.1 BF16 - Krea 2K direct.json",
         adapt(t2i, prompt=node(large, 212)["widgets_values"][0],
               resolution=["16:9 (Landscape Widescreen)", 4],
               prefix="Qwen21_BF16_Krea2K_Direct")),
        ("03 Qwen Image 2.1 BF16 - Krea single-view identity edit.json",
         adapt(edit, prompt=node(identity, 54)["widgets_values"][0],
               resolution=["1:1 (Square)", 1],
               prefix="Qwen21_BF16_KreaIdentity_Edit", edit=True)),
    )
    args.output_dir.mkdir(parents=True, exist_ok=True)
    for filename, graph in profiles:
        (args.output_dir / filename).write_text(json.dumps(graph, ensure_ascii=False, indent=2) + "\n")


if __name__ == "__main__":
    main()
