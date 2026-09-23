"""Qwen 2.1 source-template and Krea-to-Qwen compatibility contracts."""

import importlib.util
import json
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BUILDER = ROOT / "scripts/comfyui/build-qwen-image-2.1-krea-workflows.py"
TEMPLATES = ROOT / "comfyui/workflows/qwen-image-2.1-official"

spec = importlib.util.spec_from_file_location("qwen21_builder", BUILDER)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class QwenImage21WorkflowsTest(unittest.TestCase):
    def test_official_source_digests_and_pure_adapter(self):
        t2i = module.read_json(TEMPLATES / "image_qwen_image_2_1_t2i.json", module.T2I_SHA)
        edit = module.read_json(TEMPLATES / "image_qwen_image_2_1_image_edit.json", module.EDIT_SHA)
        original = json.dumps([t2i, edit], sort_keys=True)
        for template, is_edit in ((t2i, False), (edit, True)):
            graph = module.adapt(template, prompt="Krea prompt", resolution=["1:1 (Square)", 1],
                                 prefix="Qwen21_test", edit=is_edit)
            inner = graph["definitions"]["subgraphs"][0]
            selectors = {node["type"]: node["widgets_values"][0] for node in inner["nodes"]
                         if node["type"] in {"UNETLoader", "CLIPLoader", "VAELoader"}}
            self.assertEqual(selectors, {"UNETLoader": module.MODEL,
                                         "CLIPLoader": module.ENCODER, "VAELoader": module.VAE})
            outer = module.node(graph, 459)["widgets_values"]
            self.assertIn("Krea prompt", outer)
            self.assertIn(module.MODEL, outer)
            self.assertIn(module.ENCODER, outer)
            self.assertNotIn("qwen3vl_8b_int8_convrot.safetensors", outer)
            self.assertEqual(next(node["widgets_values"][2:6] for node in inner["nodes"]
                                  if node["type"] == "KSampler"), [50, 1, "euler", "simple"])
            self.assertFalse(any(node["type"].startswith("ComfyUI-Krea2T") for node in inner["nodes"]))
            self.assertEqual(module.node(graph, 13)["widgets_values"][1], 1)
        self.assertEqual(json.dumps([t2i, edit], sort_keys=True), original)

    def test_template_drift_is_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "source.json"
            path.write_text("{}")
            with self.assertRaisesRegex(ValueError, "digest drift"):
                module.read_json(path, module.T2I_SHA)

    def test_krea_specific_nodes_are_not_transplanted(self):
        with tempfile.TemporaryDirectory() as temp:
            temp = Path(temp)
            sources = []
            for identifier, text in ((30, "Krea RAW composition"),
                                     (212, "Krea 2K composition"),
                                     (54, "Krea identity edit")):
                path = temp / f"source-{identifier}.json"
                path.write_text(json.dumps({"nodes": [{"id": identifier,
                                                        "type": "ComfyUI-Krea2T-Enhancer",
                                                        "widgets_values": [text]}]}))
                sources.append(path)
            output = temp / "out"
            subprocess.run(["python3", str(BUILDER),
                            "--t2i-template", str(TEMPLATES / "image_qwen_image_2_1_t2i.json"),
                            "--edit-template", str(TEMPLATES / "image_qwen_image_2_1_image_edit.json"),
                            "--krea-raw", str(sources[0]),
                            "--krea-2k", str(sources[1]),
                            "--krea-identity", str(sources[2]),
                            "--output-dir", str(output)], check=True)
            files = sorted(output.glob("*.json"))
            self.assertEqual(len(files), 3)
            graphs = [json.loads(path.read_text()) for path in files]
            for graph, prompt in zip(graphs, ("Krea RAW composition", "Krea 2K composition",
                                              "Krea identity edit")):
                self.assertIn(prompt, module.node(graph, 459)["widgets_values"])
                self.assertNotIn("ComfyUI-Krea2T-Enhancer", json.dumps(graph))
            self.assertEqual(module.node(graphs[1], 13)["widgets_values"][1], 4)


if __name__ == "__main__":
    unittest.main()
