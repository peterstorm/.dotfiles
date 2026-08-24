from __future__ import annotations

import importlib.util
import sys
import unittest
from copy import deepcopy
from pathlib import Path


MODULE_PATH = Path(__file__).parents[1] / "scripts/inference/voice/generate_voice_design_auditions.py"
SPEC = importlib.util.spec_from_file_location("voice_auditions", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
voice_auditions = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = voice_auditions
SPEC.loader.exec_module(voice_auditions)


def valid_spec() -> dict:
    members = []
    for member_index, name in enumerate(("RHEA", "MICA", "SOL", "JUNE"), start=1):
        members.append(
            {
                "name": name,
                "slug": name.lower(),
                "instruction": "A distinct original adult voice speaking fluent natural English with controlled delivery.",
                "text": "This deliberately long audition sentence provides enough spoken material to compare identity and delivery.",
                "candidates": [
                    {"id": identifier, "seed": member_index * 100 + candidate_index}
                    for candidate_index, identifier in enumerate(("a", "b", "c"), start=1)
                ],
            }
        )
    return {
        "schemaVersion": 1,
        "project": "test",
        "language": "English",
        "model": {
            "repository": "Qwen/Qwen3-TTS-12Hz-1.7B-VoiceDesign",
            "revision": "5ecdb67327fd37bb2e042aab12ff7391903235d3",
            "path": "/models/voice-design",
        },
        "generation": {"temperature": 0.8, "topP": 0.9, "maxNewTokens": 2048},
        "members": members,
    }


class ParseAuditionSpecTest(unittest.TestCase):
    def test_parses_complete_english_four_member_spec(self) -> None:
        parsed = voice_auditions.parse_spec(valid_spec())
        self.assertEqual("English", parsed.language)
        self.assertEqual(4, len(parsed.members))
        self.assertTrue(all(len(member.candidates) == 3 for member in parsed.members))

    def test_rejects_non_english_qualification(self) -> None:
        raw = valid_spec()
        raw["language"] = "Korean"
        with self.assertRaisesRegex(voice_auditions.SpecError, "language must equal English"):
            voice_auditions.parse_spec(raw)

    def test_rejects_unknown_keys_instead_of_ignoring_typos(self) -> None:
        raw = valid_spec()
        raw["generation"]["top_p"] = raw["generation"].pop("topP")
        with self.assertRaisesRegex(voice_auditions.SpecError, "keys differ"):
            voice_auditions.parse_spec(raw)

    def test_rejects_duplicate_seed_across_members(self) -> None:
        raw = valid_spec()
        raw["members"][1]["candidates"][0]["seed"] = raw["members"][0]["candidates"][0]["seed"]
        with self.assertRaisesRegex(voice_auditions.SpecError, "global seed"):
            voice_auditions.parse_spec(raw)

    def test_rejects_path_traversal_slug(self) -> None:
        raw = valid_spec()
        raw["members"][0]["slug"] = "../rhea"
        with self.assertRaisesRegex(voice_auditions.SpecError, "slug must match"):
            voice_auditions.parse_spec(raw)

    def test_rejects_mutated_member_count(self) -> None:
        raw = valid_spec()
        raw["members"] = deepcopy(raw["members"][:3])
        with self.assertRaisesRegex(voice_auditions.SpecError, "exactly four"):
            voice_auditions.parse_spec(raw)


if __name__ == "__main__":
    unittest.main()
