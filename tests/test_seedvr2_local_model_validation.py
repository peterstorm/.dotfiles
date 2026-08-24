#!/usr/bin/env nix-shell
#!nix-shell -i python3 -p python3
# ruff: noqa: EXE005 — second shebang line is required by nix-shell.
"""Behavioral tests for the fail-closed SeedVR2 model validator."""

from __future__ import annotations

import hashlib
import importlib.util
import sys
import tempfile
import types
import unittest
from pathlib import Path
from types import SimpleNamespace

ROOT = Path(__file__).resolve().parents[1]
VALIDATOR = ROOT / "comfyui/custom_nodes/seedvr2_local_model_validation.py"


class ValidationFixture:
    def __init__(self, root: Path) -> None:
        self.root = root
        self.registry: dict[str, SimpleNamespace] = {}
        self.paths: dict[str, str] = {}

    def add(self, filename: str, content: bytes) -> None:
        path = self.root / filename
        path.write_bytes(content)
        self.paths[filename] = str(path)
        self.registry[filename] = SimpleNamespace(
            sha256=hashlib.sha256(content).hexdigest()
        )

    def load(self):
        package_name = "seedvr2_validator_test"
        package = types.ModuleType(package_name)
        package.__path__ = []
        constants = types.ModuleType(f"{package_name}.constants")
        constants.DOWNLOAD_CHUNK_SIZE = 4
        constants.find_model_file = lambda filename: self.paths.get(
            filename, str(self.root / filename)
        )
        registry = types.ModuleType(f"{package_name}.model_registry")
        registry.MODEL_REGISTRY = self.registry
        sys.modules[package_name] = package
        sys.modules[constants.__name__] = constants
        sys.modules[registry.__name__] = registry
        spec = importlib.util.spec_from_file_location(
            f"{package_name}.local_model_validation", VALIDATOR
        )
        if spec is None or spec.loader is None:
            raise RuntimeError("could not load local SeedVR2 validator")
        module = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = module
        spec.loader.exec_module(module)
        return module


class LocalModelValidationTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.fixture = ValidationFixture(Path(self.temporary_directory.name))
        self.fixture.add("dit.safetensors", b"immutable dit")
        self.fixture.add("vae.safetensors", b"immutable vae")
        self.validator = self.fixture.load()

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    def test_accepts_two_registered_checksum_matching_files(self) -> None:
        self.assertTrue(
            self.validator.validate_installed_weight(
                "dit.safetensors", "vae.safetensors"
            )
        )

    def test_rejects_missing_registered_file(self) -> None:
        Path(self.fixture.paths["dit.safetensors"]).unlink()
        self.assertFalse(
            self.validator.validate_installed_weight(
                "dit.safetensors", "vae.safetensors"
            )
        )

    def test_rejects_checksum_drift(self) -> None:
        Path(self.fixture.paths["vae.safetensors"]).write_bytes(b"drift")
        self.assertFalse(
            self.validator.validate_installed_weight(
                "dit.safetensors", "vae.safetensors"
            )
        )

    def test_rejects_unregistered_model(self) -> None:
        self.assertFalse(
            self.validator.validate_installed_weight(
                "unknown.safetensors", "vae.safetensors"
            )
        )


if __name__ == "__main__":
    unittest.main()
