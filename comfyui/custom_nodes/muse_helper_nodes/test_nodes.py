"""Contract tests for the muse_helper_nodes pack.

Hermetic by design: fake torch/comfy.model_management/folder_paths stubs stand
in for the runtime, so the suite runs in the Nix build sandbox (no GPU, no
ComfyUI server). Each test asserts on the observable call contract the upstream
types expose, not on internal state.
"""

import importlib.util
import os
import pathlib
import sys
import tempfile
import types
import unittest


class FakeTorchCuda:
    # The sandbox has no GPU, so the default fake reports no CUDA; the CUDA-path
    # tests toggle this to exercise the allocator-release half of the sweep.
    cuda_enabled = False
    empty_cache_calls = 0
    ipc_collect_calls = 0

    @classmethod
    def is_available(cls):
        return cls.cuda_enabled

    @classmethod
    def empty_cache(cls):
        cls.empty_cache_calls += 1

    @classmethod
    def ipc_collect(cls):
        cls.ipc_collect_calls += 1


fake_torch = types.ModuleType("torch")
fake_torch.cuda = FakeTorchCuda
sys.modules["torch"] = fake_torch

fake_comfy = types.ModuleType("comfy")
fake_comfy.__path__ = []
fake_model_management = types.ModuleType("comfy.model_management")
fake_model_management.unload_all_models_calls = 0
fake_model_management.soft_empty_cache_calls = 0


class FakeModelManagement:
    @staticmethod
    def unload_all_models():
        fake_model_management.unload_all_models_calls += 1

    @staticmethod
    def soft_empty_cache():
        fake_model_management.soft_empty_cache_calls += 1


fake_model_management.unload_all_models = FakeModelManagement.unload_all_models
fake_model_management.soft_empty_cache = FakeModelManagement.soft_empty_cache
fake_comfy.model_management = fake_model_management
sys.modules["comfy"] = fake_comfy
sys.modules["comfy.model_management"] = fake_model_management

fake_folder_paths = types.ModuleType("folder_paths")
fake_folder_paths.output_directory = tempfile.mkdtemp(prefix="muse-helper-test-output-")
fake_folder_paths.get_output_directory = lambda: fake_folder_paths.output_directory
sys.modules["folder_paths"] = fake_folder_paths

spec = importlib.util.spec_from_file_location(
    "muse_helper_nodes_nodes", pathlib.Path(__file__).with_name("nodes.py")
)
nodes = importlib.util.module_from_spec(spec)
spec.loader.exec_module(nodes)


class AnyTypeBindingTests(unittest.TestCase):
    def test_wildcard_compares_unequal_to_nothing(self):
        self.assertFalse(nodes.any_type != "STRING")
        self.assertFalse(nodes.any_type != "FLOAT")
        self.assertFalse(nodes.any_type != "IMAGE")
        self.assertFalse(nodes.any_type != "VHS_FILENAMES")

    def test_registry_covers_all_four_upstream_types(self):
        self.assertEqual(
            sorted(nodes.NODE_CLASS_MAPPINGS),
            sorted([
                "MuseHelper: Show Anything",
                "MuseHelper: Preview Text",
                "MuseHelper: Save Text With Path",
                "MuseHelper: Purge VRAM",
            ]),
        )


class ShowAnythingTests(unittest.TestCase):
    def test_single_string_input_displays_and_passes_through(self):
        result = nodes.MuseHelperShowAnything().show_anything(
            ["Maximum Quality"], unique_id=["348"]
        )
        self.assertEqual(result["ui"], {"text": ["Maximum Quality"]})
        self.assertEqual(result["result"], (["Maximum Quality"],))

    def test_float_input_from_loader_is_normalized_to_a_list(self):
        result = nodes.MuseHelperShowAnything().show_anything(
            31.84, unique_id=["349"]
        )
        self.assertEqual(result["ui"]["text"], [31.84])

    def test_list_passthrough_keeps_every_item(self):
        result = nodes.MuseHelperShowAnything().show_anything(["a", "b"])
        self.assertEqual(result["result"], (["a", "b"],))


class PreviewTextTests(unittest.TestCase):
    def test_passthrough_returns_the_incoming_string(self):
        result = nodes.MuseHelperPreviewText().preview_text(
            ["compiled prompt"], unique_id=["171"]
        )
        self.assertEqual(result["result"], (["compiled prompt"],))
        self.assertEqual(result["ui"]["text"], ["compiled prompt"])

    def test_writeback_stamps_the_saved_workflow_metadata(self):
        workflow = {"nodes": [{"id": 171, "widgets_values": None}]}
        extra_pnginfo = [{"workflow": workflow}]
        nodes.MuseHelperPreviewText().preview_text(
            ["the exact prompt"], extra_pnginfo=extra_pnginfo, unique_id=["171"]
        )
        self.assertEqual(workflow["nodes"][0]["widgets_values"], ["the exact prompt"])

    def test_missing_workflow_metadata_is_reported_not_fatal(self):
        result = nodes.MuseHelperPreviewText().preview_text(["x"], extra_pnginfo=[])
        self.assertEqual(result["result"], (["x"],))


class SaveTextWithPathTests(unittest.TestCase):
    def setUp(self):
        self.output_dir = tempfile.mkdtemp(prefix="muse-helper-save-")
        fake_folder_paths.output_directory = self.output_dir

    def tearDown(self):
        fake_folder_paths.output_directory = None

    def _save(self, text="compiled prompt", overwrite=False):
        return nodes.MuseHelperSaveTextWithPath().save_text(
            [text],
            ["Muse Collective/MiniMax H3 Prompt"],
            ["H3 Prompts"],
            ["Compiled Prompt"],
            [""],
            [overwrite],
            [".txt"],
        )

    def test_writes_nested_folder_path_under_the_output_directory(self):
        self._save()
        path = os.path.join(
            self.output_dir, "Muse Collective/MiniMax H3 Prompt",
            "H3 Prompts", "Compiled Prompt.txt",
        )
        with open(path, encoding="utf-8") as handle:
            self.assertEqual(handle.read(), "compiled prompt")

    def test_overwrite_false_adds_a_numbered_suffix(self):
        self._save()
        self._save(text="second run")
        first = os.path.join(
            self.output_dir, "Muse Collective/MiniMax H3 Prompt",
            "H3 Prompts", "Compiled Prompt.txt",
        )
        second = os.path.join(
            self.output_dir, "Muse Collective/MiniMax H3 Prompt",
            "H3 Prompts", "Compiled Prompt_001.txt",
        )
        with open(first, encoding="utf-8") as handle:
            self.assertEqual(handle.read(), "compiled prompt")
        with open(second, encoding="utf-8") as handle:
            self.assertEqual(handle.read(), "second run")

    def test_overwrite_true_replaces_the_existing_file(self):
        self._save()
        self._save(text="replaced", overwrite=True)
        path = os.path.join(
            self.output_dir, "Muse Collective/MiniMax H3 Prompt",
            "H3 Prompts", "Compiled Prompt.txt",
        )
        with open(path, encoding="utf-8") as handle:
            self.assertEqual(handle.read(), "replaced")

    def test_unknown_extension_falls_back_to_txt(self):
        nodes.MuseHelperSaveTextWithPath().save_text(
            ["x"], ["f"], [""], ["n"], [""], [True], [".exe"]
        )
        self.assertTrue(os.path.isfile(os.path.join(self.output_dir, "f", "n.txt")))


class PurgeVRAMTests(unittest.TestCase):
    def setUp(self):
        FakeTorchCuda.empty_cache_calls = 0
        FakeTorchCuda.ipc_collect_calls = 0
        fake_model_management.unload_all_models_calls = 0
        fake_model_management.soft_empty_cache_calls = 0

    def test_purge_models_unloads_every_resident_model(self):
        FakeTorchCuda.cuda_enabled = True
        nodes.MuseHelperPurgeVRAM().purge_vram(["ignored"], True, True)
        self.assertEqual(fake_model_management.unload_all_models_calls, 1)
        self.assertEqual(fake_model_management.soft_empty_cache_calls, 1)
        self.assertEqual(FakeTorchCuda.empty_cache_calls, 1)
        self.assertEqual(FakeTorchCuda.ipc_collect_calls, 1)

    def test_cache_only_purge_leaves_model_state_untouched(self):
        FakeTorchCuda.cuda_enabled = True
        nodes.MuseHelperPurgeVRAM().purge_vram(["ignored"], True, False)
        self.assertEqual(fake_model_management.unload_all_models_calls, 0)
        self.assertEqual(fake_model_management.soft_empty_cache_calls, 0)
        self.assertEqual(FakeTorchCuda.empty_cache_calls, 1)

    def test_no_cuda_sandbox_still_sweeps_python_garbage(self):
        FakeTorchCuda.cuda_enabled = False
        nodes.MuseHelperPurgeVRAM().purge_vram(["ignored"], True, True)
        self.assertEqual(fake_model_management.unload_all_models_calls, 1)
        self.assertEqual(FakeTorchCuda.empty_cache_calls, 0)
        self.assertEqual(FakeTorchCuda.ipc_collect_calls, 0)


if __name__ == "__main__":
    unittest.main()
