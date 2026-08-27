from __future__ import annotations

import json
import logging
import mimetypes
import uuid
from collections.abc import Callable, Mapping
from dataclasses import dataclass
from pathlib import Path, PurePosixPath
from typing import Any, Protocol

VIDEO_EXTENSIONS = frozenset({".mp4", ".webm", ".mov", ".mkv"})
HISTORY_NAMESPACE = uuid.UUID("42df35a0-bdc4-4a36-ab4f-ecf97aa93215")
RECOVERED_OUTPUT_NODE_ID = "persistent-output-video"

JsonObject = dict[str, Any]
MetadataLoader = Callable[[Path], tuple[JsonObject, JsonObject | None]]


@dataclass(frozen=True)
class PersistentVideo:
    relative_path: PurePosixPath
    mtime_ns: int
    mtime_ms: int

    @property
    def filename(self) -> str:
        return self.relative_path.name

    @property
    def subfolder(self) -> str:
        parent = self.relative_path.parent
        return "" if parent == PurePosixPath(".") else parent.as_posix()

    @property
    def mime_type(self) -> str:
        guessed, _ = mimetypes.guess_type(self.filename)
        return guessed if guessed and guessed.startswith("video/") else "video/mp4"

    @property
    def history_id(self) -> str:
        return str(uuid.uuid5(HISTORY_NAMESPACE, self.relative_path.as_posix()))


class PromptQueueLike(Protocol):
    mutex: Any
    history: dict[str, JsonObject]


def discover_persistent_videos(output_root: Path) -> tuple[PersistentVideo, ...]:
    root = output_root.resolve()
    if not root.is_dir():
        return ()

    videos: list[PersistentVideo] = []
    for candidate in root.rglob("*"):
        if candidate.suffix.lower() not in VIDEO_EXTENSIONS or not candidate.is_file():
            continue
        resolved = candidate.resolve()
        if not resolved.is_relative_to(root):
            continue
        stat = resolved.stat()
        videos.append(
            PersistentVideo(
                relative_path=PurePosixPath(resolved.relative_to(root).as_posix()),
                mtime_ns=stat.st_mtime_ns,
                mtime_ms=stat.st_mtime_ns // 1_000_000,
            )
        )

    return tuple(sorted(videos, key=lambda video: (video.mtime_ns, video.relative_path)))


def _json_object(raw: str | None) -> JsonObject | None:
    if not raw:
        return None
    parsed = json.loads(raw)
    return parsed if isinstance(parsed, dict) else None


def load_video_metadata(video_path: Path) -> tuple[JsonObject, JsonObject | None]:
    import av

    with av.open(str(video_path)) as container:
        prompt = _json_object(container.metadata.get("prompt")) or {}
        workflow = _json_object(container.metadata.get("workflow"))
    return prompt, workflow


def _output_node_id(prompt: Mapping[str, Any]) -> str:
    save_nodes = sorted(
        str(node_id)
        for node_id, node in prompt.items()
        if isinstance(node, dict) and node.get("class_type") == "SaveVideo"
    )
    return save_nodes[0] if save_nodes else RECOVERED_OUTPUT_NODE_ID


def build_history_entry(
    output_root: Path,
    video: PersistentVideo,
    metadata_loader: MetadataLoader = load_video_metadata,
) -> JsonObject:
    try:
        prompt, workflow = metadata_loader(output_root / Path(video.relative_path))
    except Exception as error:
        logging.warning(
            "Persistent output history could not read metadata from %s: %s",
            video.relative_path,
            error,
        )
        prompt, workflow = {}, None

    output_node_id = _output_node_id(prompt)
    extra_data: JsonObject = {
        "client_id": "persistent-output-history",
        "create_time": video.mtime_ms,
        "persistent_output_history": True,
    }
    if workflow is not None:
        extra_data["extra_pnginfo"] = {"workflow": workflow}

    output = {
        "filename": video.filename,
        "subfolder": video.subfolder,
        "type": "output",
        "format": video.mime_type,
    }
    status = {
        "status_str": "success",
        "completed": True,
        "messages": [
            [
                "execution_start",
                {"prompt_id": video.history_id, "timestamp": video.mtime_ms},
            ],
            [
                "execution_success",
                {"prompt_id": video.history_id, "timestamp": video.mtime_ms},
            ],
        ],
    }
    return {
        "prompt": [
            video.mtime_ns,
            video.history_id,
            prompt,
            extra_data,
            [output_node_id] if output_node_id in prompt else [],
        ],
        "outputs": {output_node_id: {"video": [output]}},
        "status": status,
    }


def _history_video_paths(history: Mapping[str, JsonObject]) -> frozenset[str]:
    paths: set[str] = set()
    for history_item in history.values():
        outputs = history_item.get("outputs", {})
        if not isinstance(outputs, dict):
            continue
        for node_output in outputs.values():
            if not isinstance(node_output, dict):
                continue
            for values in node_output.values():
                if not isinstance(values, list):
                    continue
                for value in values:
                    if not isinstance(value, dict):
                        continue
                    filename = value.get("filename")
                    subfolder = value.get("subfolder", "")
                    if not isinstance(filename, str) or not isinstance(subfolder, str):
                        continue
                    if Path(filename).suffix.lower() not in VIDEO_EXTENSIONS:
                        continue
                    paths.add(PurePosixPath(subfolder, filename).as_posix())
    return frozenset(paths)


def merge_recovered_history(
    existing: Mapping[str, JsonObject],
    recovered: Mapping[str, JsonObject],
) -> tuple[dict[str, JsonObject], int]:
    merged = dict(existing)
    known_paths = set(_history_video_paths(existing))
    added = 0

    for history_id, entry in recovered.items():
        entry_paths = _history_video_paths({history_id: entry})
        if history_id in merged or entry_paths & known_paths:
            continue
        merged[history_id] = entry
        known_paths.update(entry_paths)
        added += 1

    return merged, added


def rehydrate_video_history(
    output_root: Path,
    prompt_queue: PromptQueueLike,
    metadata_loader: MetadataLoader = load_video_metadata,
) -> int:
    videos = discover_persistent_videos(output_root)
    recovered = {
        video.history_id: build_history_entry(output_root, video, metadata_loader)
        for video in videos
    }

    with prompt_queue.mutex:
        merged, added = merge_recovered_history(prompt_queue.history, recovered)
        prompt_queue.history.clear()
        prompt_queue.history.update(merged)
    return added


def _install_into_comfyui() -> None:
    import folder_paths
    from server import PromptServer

    server = getattr(PromptServer, "instance", None)
    if server is None:
        return

    added = rehydrate_video_history(
        Path(folder_paths.get_output_directory()),
        server.prompt_queue,
    )
    if added:
        logging.info("Persistent output history restored %d video entries", added)
        server.queue_updated()


try:
    _install_into_comfyui()
except ImportError:
    # Unit tests load this module outside ComfyUI.
    pass
except Exception:
    logging.exception("Persistent output history startup restoration failed")


NODE_CLASS_MAPPINGS: dict[str, type] = {}
NODE_DISPLAY_NAME_MAPPINGS: dict[str, str] = {}
