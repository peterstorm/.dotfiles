from __future__ import annotations

import importlib.util
import sys
import unittest
from copy import deepcopy
from pathlib import Path

MODULE_PATH = (
    Path(__file__).parents[1]
    / "scripts/inference/voice/generate_expressive_voice_identity_auditions.py"
)
SPEC = importlib.util.spec_from_file_location("expressive_voice_identity", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
voice_identity = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = voice_identity
SPEC.loader.exec_module(voice_identity)


def valid_spec(engine: str = "voxcpm2") -> dict:
    generation = (
        {"cfgValue": 2.0, "inferenceTimesteps": 10, "optimize": False}
        if engine == "voxcpm2"
        else {"cfgScale": 4.0, "maxNewTokens": 1024, "repetitionPenalty": 1.1}
    )
    return {
        "schemaVersion": 1,
        "project": "AFTERSIGNAL RHEA identity exploration",
        "stage": "Development",
        "authority": "none",
        "engine": engine,
        "model": {
            "repository": "owner/model",
            "revision": "1" * 40,
            "sourceRepository": "owner/source",
            "sourceRevision": "2" * 40,
            "path": "/models/model",
        },
        "identity": {
            "name": "RHEA",
            "slug": "rhea",
            "language": "English",
            "instruction": "An original adult feminine voice with warm low resonance and ordinary conversational cadence.",
            "text": "Hey, give me a second. I thought I left it right here. Oh—found it. We're good.",
            "candidates": [
                {"id": "a", "seed": 1001},
                {"id": "b", "seed": 1002},
                {"id": "c", "seed": 1003},
            ],
        },
        "generation": generation,
    }


class ParseExpressiveVoiceIdentitySpecTest(unittest.TestCase):
    def test_parses_voxcpm2_spec_into_immutable_parameters(self) -> None:
        parsed = voice_identity.parse_spec(valid_spec("voxcpm2"))
        self.assertEqual("voxcpm2", parsed.engine)
        self.assertIsInstance(parsed.generation, voice_identity.VoxParameters)
        self.assertEqual(
            ("a", "b", "c"), tuple(c.identifier for c in parsed.identity.candidates)
        )

    def test_parses_breeze_spec_into_immutable_parameters(self) -> None:
        parsed = voice_identity.parse_spec(valid_spec("breeze-tts2"))
        self.assertEqual("breeze-tts2", parsed.engine)
        self.assertIsInstance(parsed.generation, voice_identity.BreezeParameters)

    def test_rejects_engine_parameter_mismatch(self) -> None:
        raw = valid_spec("voxcpm2")
        raw["generation"] = valid_spec("breeze-tts2")["generation"]
        with self.assertRaisesRegex(voice_identity.SpecError, "keys differ"):
            voice_identity.parse_spec(raw)

    def test_rejects_any_authority_during_generation(self) -> None:
        raw = valid_spec()
        raw["authority"] = "production"
        with self.assertRaisesRegex(
            voice_identity.SpecError, "Development with no authority"
        ):
            voice_identity.parse_spec(raw)

    def test_rejects_duplicate_candidate_seed(self) -> None:
        raw = valid_spec()
        raw["identity"]["candidates"][2]["seed"] = 1001
        with self.assertRaisesRegex(voice_identity.SpecError, "seed must be unique"):
            voice_identity.parse_spec(raw)

    def test_rejects_missing_candidate(self) -> None:
        raw = valid_spec()
        raw["identity"]["candidates"] = deepcopy(raw["identity"]["candidates"][:2])
        with self.assertRaisesRegex(voice_identity.SpecError, "exactly three"):
            voice_identity.parse_spec(raw)

    def test_rejects_relative_model_path(self) -> None:
        raw = valid_spec()
        raw["model"]["path"] = "models/model"
        with self.assertRaisesRegex(voice_identity.SpecError, "must be absolute"):
            voice_identity.parse_spec(raw)


if __name__ == "__main__":
    unittest.main()
