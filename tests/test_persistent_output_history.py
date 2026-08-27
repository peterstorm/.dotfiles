#!/usr/bin/env nix-shell
#!nix-shell -i python3 -p python3
# ruff: noqa: EXE005 — second shebang line is required by nix-shell.

from __future__ import annotations

import importlib.util
import sys
import tempfile
import threading
import unittest
from pathlib import Path
from types import ModuleType

MODULE_PATH = (
    Path(__file__).resolve().parents[1]
    / "comfyui/custom_nodes/persistent_output_history/__init__.py"
)


def load_module() -> ModuleType:
    spec = importlib.util.spec_from_file_location("persistent_output_history", MODULE_PATH)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Unable to load {MODULE_PATH}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


class FakePromptQueue:
    def __init__(self, history: dict | None = None) -> None:
        self.mutex = threading.RLock()
        self.history = dict(history or {})


class PersistentOutputHistoryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.module = load_module()

    def test_discovers_supported_videos_in_mtime_order_without_symlink_escape(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            nested = root / "video"
            nested.mkdir()
            first = root / "first.mp4"
            second = nested / "second.WEBM"
            ignored = root / "notes.txt"
            outside = root.parent / "outside.mp4"
            first.write_bytes(b"first")
            second.write_bytes(b"second")
            ignored.write_text("ignored")
            outside.write_bytes(b"outside")
            (root / "escaped.mp4").symlink_to(outside)
            first.touch()
            second.touch()

            videos = self.module.discover_persistent_videos(root)

            self.assertEqual(
                {video.relative_path.as_posix() for video in videos},
                {"first.mp4", "video/second.WEBM"},
            )
            self.assertEqual(len(videos), 2)

    def test_builds_stable_previewable_entry_with_embedded_workflow(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            path = root / "video" / "clip.mp4"
            path.parent.mkdir()
            path.write_bytes(b"video")
            video = self.module.discover_persistent_videos(root)[0]

            def metadata_loader(_: Path) -> tuple[dict, dict]:
                return (
                    {"92": {"class_type": "SaveVideo", "inputs": {}}},
                    {"id": "workflow-id", "nodes": []},
                )

            first = self.module.build_history_entry(root, video, metadata_loader)
            second = self.module.build_history_entry(root, video, metadata_loader)

            self.assertEqual(video.history_id, second["prompt"][1])
            self.assertEqual(first, second)
            self.assertEqual(first["prompt"][2]["92"]["class_type"], "SaveVideo")
            self.assertEqual(
                first["prompt"][3]["extra_pnginfo"]["workflow"]["id"],
                "workflow-id",
            )
            self.assertEqual(
                first["outputs"]["92"]["video"],
                [
                    {
                        "filename": "clip.mp4",
                        "subfolder": "video",
                        "type": "output",
                        "format": "video/mp4",
                    }
                ],
            )
            self.assertTrue(first["status"]["completed"])

    def test_metadata_failure_keeps_video_watchable(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            path = root / "clip.mkv"
            path.write_bytes(b"video")
            video = self.module.discover_persistent_videos(root)[0]

            def failing_loader(_: Path) -> tuple[dict, None]:
                raise ValueError("bad metadata")

            entry = self.module.build_history_entry(root, video, failing_loader)

            self.assertEqual(entry["prompt"][2], {})
            self.assertEqual(
                entry["outputs"][self.module.RECOVERED_OUTPUT_NODE_ID]["video"][0][
                    "filename"
                ],
                "clip.mkv",
            )

    def test_merge_is_idempotent_and_deduplicates_an_existing_output_path(self) -> None:
        existing_id = "existing"
        existing = {
            existing_id: {
                "outputs": {
                    "1": {
                        "video": [
                            {
                                "filename": "clip.mp4",
                                "subfolder": "video",
                                "type": "output",
                            }
                        ]
                    }
                }
            }
        }
        recovered = {
            "stable": {
                "outputs": {
                    "2": {
                        "video": [
                            {
                                "filename": "clip.mp4",
                                "subfolder": "video",
                                "type": "output",
                            }
                        ]
                    }
                }
            }
        }

        merged, added = self.module.merge_recovered_history(existing, recovered)
        merged_again, added_again = self.module.merge_recovered_history(
            merged, recovered
        )

        self.assertEqual(merged, existing)
        self.assertEqual(added, 0)
        self.assertEqual(merged_again, existing)
        self.assertEqual(added_again, 0)

    def test_rehydrates_video_only_and_preserves_existing_history(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "one.mp4").write_bytes(b"one")
            (root / "two.mov").write_bytes(b"two")
            (root / "image.png").write_bytes(b"image")
            queue = FakePromptQueue({"existing": {"outputs": {}}})

            def metadata_loader(_: Path) -> tuple[dict, None]:
                return {}, None

            added = self.module.rehydrate_video_history(
                root, queue, metadata_loader
            )
            added_again = self.module.rehydrate_video_history(
                root, queue, metadata_loader
            )

            self.assertEqual(added, 2)
            self.assertEqual(added_again, 0)
            self.assertIn("existing", queue.history)
            self.assertEqual(len(queue.history), 3)


if __name__ == "__main__":
    unittest.main()
