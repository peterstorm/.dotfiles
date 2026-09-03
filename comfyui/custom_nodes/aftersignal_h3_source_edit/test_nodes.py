import importlib.util
import pathlib
import sys
import types
import unittest

import torch


class NestedTensor:
    def __init__(self, streams):
        self.streams = tuple(streams)

    def unbind(self):
        return self.streams


def common_upscale(images, width, height, _method, _crop):
    return torch.nn.functional.interpolate(images, size=(height, width), mode="nearest")


comfy = types.ModuleType("comfy")
comfy.__path__ = []
comfy_nested = types.ModuleType("comfy.nested_tensor")
comfy_nested.NestedTensor = NestedTensor
comfy_utils = types.ModuleType("comfy.utils")
comfy_utils.common_upscale = common_upscale
comfy.nested_tensor = comfy_nested
comfy.utils = comfy_utils
sys.modules["comfy"] = comfy
sys.modules["comfy.nested_tensor"] = comfy_nested
sys.modules["comfy.utils"] = comfy_utils

spec = importlib.util.spec_from_file_location("aftersignal_h3_source_edit_nodes", pathlib.Path(__file__).with_name("nodes.py"))
nodes = importlib.util.module_from_spec(spec)
spec.loader.exec_module(nodes)


class FakeVae:
    def encode(self, frames):
        self.frames = frames
        return torch.full((1, 4, 7, 1, 1), 0.75)


class FakeVae2x2:
    def encode(self, frames):
        self.frames = frames
        return torch.full((1, 4, 7, 2, 2), 0.75)


class SourceVideoLatentTest(unittest.TestCase):
    def test_frame_conformance_spans_complete_source(self):
        indices = nodes.source_frame_indices(20, 22, torch.device("cpu"))
        self.assertEqual(indices.shape[0], 22)
        self.assertEqual(indices[0].item(), 0)
        self.assertEqual(indices[-1].item(), 19)
        self.assertTrue(bool(torch.all(indices[1:] >= indices[:-1])))

    def test_keyed_mask_is_nested_and_keeps_audio_generative(self):
        target_video = torch.zeros((1, 4, 7, 1, 1))
        target_audio = torch.ones((1, 2, 2, 37))
        target = {"samples": NestedTensor((target_video, target_audio))}
        source = torch.zeros((20, 12, 12, 3))
        source[..., 0] = 1.0
        source[..., 2] = 1.0

        output, _, _ = nodes.AFTERSIGNALH3SourceVideoLatent().encode(
            target, FakeVae(), source, mask_mode="magenta-yellow-keys"
        )
        video_mask, audio_mask = output["noise_mask"].unbind()

        self.assertEqual(tuple(video_mask.shape), (1, 1, 7, 1, 1))
        self.assertTrue(bool(torch.all(video_mask == 1)))
        self.assertTrue(bool(torch.all(audio_mask == 1)))

    def test_external_mask_marks_any_latent_cell_touched_by_a_regenerate_pixel(self):
        target_video = torch.zeros((1, 4, 7, 2, 2))
        target_audio = torch.ones((1, 2, 2, 37))
        target = {"samples": NestedTensor((target_video, target_audio))}
        source = torch.rand((20, 32, 32, 3))
        mask = torch.zeros((20, 32, 32, 3))
        mask[:, 0:2, 0:2, :] = 1.0  # one small top-left patch on every frame

        output, _, _ = nodes.AFTERSIGNALH3SourceVideoLatent().encode(
            target, FakeVae2x2(), source, mask_mode="external-mask", mask_frames=mask
        )
        video_mask, audio_mask = output["noise_mask"].unbind()

        self.assertEqual(tuple(video_mask.shape), (1, 1, 7, 2, 2))
        self.assertTrue(bool(torch.all(video_mask[..., 0, 0] == 1)))
        self.assertTrue(bool(torch.all(video_mask[..., 1, 1] == 0)))
        self.assertTrue(bool(torch.all(audio_mask == 1)))

    def test_external_mask_mode_requires_mask_frames(self):
        target = {"samples": NestedTensor((torch.zeros((1, 4, 7, 1, 1)), torch.ones((1, 2, 2, 37))))}
        with self.assertRaises(ValueError):
            nodes.AFTERSIGNALH3SourceVideoLatent().encode(
                target, FakeVae(), torch.rand((20, 12, 12, 3)), mask_mode="external-mask"
            )

    def test_source_replaces_video_stream_without_changing_audio(self):
        target_video = torch.zeros((1, 4, 7, 1, 1))
        target_audio = torch.ones((1, 2, 2, 37))
        target = {
            "samples": NestedTensor((target_video, target_audio)),
            "noise_mask": "must be removed",
        }
        source = torch.rand((20, 12, 12, 3))
        vae = FakeVae()

        output, source_count, target_count = nodes.AFTERSIGNALH3SourceVideoLatent().encode(
            target, vae, source
        )
        video, audio = output["samples"].unbind()

        self.assertEqual((source_count, target_count), (20, 22))
        self.assertEqual(tuple(vae.frames.shape), (22, 16, 16, 3))
        self.assertTrue(bool(torch.all(video == 0.75)))
        self.assertIs(audio, target_audio)
        self.assertNotIn("noise_mask", output)
        self.assertIn("noise_mask", target)


if __name__ == "__main__":
    unittest.main()
