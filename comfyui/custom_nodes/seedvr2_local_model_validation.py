"""Fail-closed validation for declaratively installed SeedVR2 weights."""

from __future__ import annotations

import hashlib
from pathlib import Path
from typing import Any

from .constants import DOWNLOAD_CHUNK_SIZE, find_model_file
from .model_registry import MODEL_REGISTRY


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as artifact:
        while chunk := artifact.read(DOWNLOAD_CHUNK_SIZE):
            digest.update(chunk)
    return digest.hexdigest()


def validate_installed_weight(
    dit_model: str,
    vae_model: str,
    model_dir: str | None = None,
    debug: Any = None,
) -> bool:
    """Validate both pinned artifacts without downloading or mutating model state."""
    del model_dir
    for model_type, filename in (("DiT", dit_model), ("VAE", vae_model)):
        model_info = MODEL_REGISTRY.get(filename)
        if model_info is None:
            if debug:
                debug.log(
                    f"Unregistered {model_type} model rejected: {filename}",
                    level="ERROR",
                    category="setup",
                    force=True,
                )
            return False

        artifact = Path(find_model_file(filename))
        if not artifact.is_file() or _sha256(artifact) != model_info.sha256:
            if debug:
                debug.log(
                    f"Missing or corrupt immutable {model_type} model: {filename}",
                    level="ERROR",
                    category="setup",
                    force=True,
                )
            return False
        if debug:
            debug.log(
                f"Immutable {model_type} model validated: {artifact}",
                category="setup",
                force=True,
            )
    return True
