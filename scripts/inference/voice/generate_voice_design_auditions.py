#!/usr/bin/env python3
"""Generate deterministic, checksummed Qwen3-TTS VoiceDesign auditions."""

from __future__ import annotations

import argparse
import hashlib
import json
import random
import re
import sys
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any


class SpecError(ValueError):
    """The audition specification cannot represent a valid generation run."""


@dataclass(frozen=True)
class ModelSpec:
    repository: str
    revision: str
    path: Path


@dataclass(frozen=True)
class GenerationSpec:
    temperature: float
    top_p: float
    max_new_tokens: int


@dataclass(frozen=True)
class Candidate:
    identifier: str
    seed: int


@dataclass(frozen=True)
class Member:
    name: str
    slug: str
    instruction: str
    text: str
    candidates: tuple[Candidate, ...]


@dataclass(frozen=True)
class AuditionSpec:
    project: str
    language: str
    model: ModelSpec
    generation: GenerationSpec
    members: tuple[Member, ...]


_SLUG = re.compile(r"^[a-z][a-z0-9-]{1,31}$")
_REVISION = re.compile(r"^[0-9a-f]{40}$")


def _object(value: Any, context: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise SpecError(f"{context} must be an object")
    return value


def _exact_keys(value: dict[str, Any], expected: set[str], context: str) -> None:
    actual = set(value)
    if actual != expected:
        missing = sorted(expected - actual)
        unknown = sorted(actual - expected)
        raise SpecError(f"{context} keys differ; missing={missing}, unknown={unknown}")


def _text(value: Any, context: str, *, minimum: int = 1) -> str:
    if not isinstance(value, str) or len(value.strip()) < minimum:
        raise SpecError(f"{context} must be a non-empty string of at least {minimum} characters")
    return value.strip()


def _integer(value: Any, context: str, *, minimum: int, maximum: int) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or not minimum <= value <= maximum:
        raise SpecError(f"{context} must be an integer from {minimum} through {maximum}")
    return value


def _number(value: Any, context: str, *, minimum: float, maximum: float) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise SpecError(f"{context} must be numeric")
    parsed = float(value)
    if not minimum <= parsed <= maximum:
        raise SpecError(f"{context} must be from {minimum} through {maximum}")
    return parsed


def parse_spec(raw: Any) -> AuditionSpec:
    root = _object(raw, "specification")
    _exact_keys(root, {"schemaVersion", "project", "language", "model", "generation", "members"}, "specification")
    if root["schemaVersion"] != 1:
        raise SpecError("schemaVersion must equal 1")

    language = _text(root["language"], "language")
    if language != "English":
        raise SpecError("language must equal English for this qualification")

    raw_model = _object(root["model"], "model")
    _exact_keys(raw_model, {"repository", "revision", "path"}, "model")
    revision = _text(raw_model["revision"], "model.revision")
    if not _REVISION.fullmatch(revision):
        raise SpecError("model.revision must be a full 40-character hexadecimal revision")
    model_path = Path(_text(raw_model["path"], "model.path"))
    if not model_path.is_absolute():
        raise SpecError("model.path must be absolute")
    model = ModelSpec(
        repository=_text(raw_model["repository"], "model.repository"),
        revision=revision,
        path=model_path,
    )

    raw_generation = _object(root["generation"], "generation")
    _exact_keys(raw_generation, {"temperature", "topP", "maxNewTokens"}, "generation")
    generation = GenerationSpec(
        temperature=_number(raw_generation["temperature"], "generation.temperature", minimum=0.1, maximum=2.0),
        top_p=_number(raw_generation["topP"], "generation.topP", minimum=0.1, maximum=1.0),
        max_new_tokens=_integer(raw_generation["maxNewTokens"], "generation.maxNewTokens", minimum=128, maximum=4096),
    )

    raw_members = root["members"]
    if not isinstance(raw_members, list) or not 1 <= len(raw_members) <= 4:
        raise SpecError("members must contain from one through four entries")

    members: list[Member] = []
    seen_names: set[str] = set()
    seen_slugs: set[str] = set()
    seen_seeds: set[int] = set()
    for member_index, raw_member_value in enumerate(raw_members, start=1):
        context = f"members[{member_index}]"
        raw_member = _object(raw_member_value, context)
        _exact_keys(raw_member, {"name", "slug", "instruction", "text", "candidates"}, context)
        name = _text(raw_member["name"], f"{context}.name")
        slug = _text(raw_member["slug"], f"{context}.slug")
        if not _SLUG.fullmatch(slug):
            raise SpecError(f"{context}.slug must match {_SLUG.pattern}")
        if name in seen_names or slug in seen_slugs:
            raise SpecError(f"{context} duplicates a member name or slug")
        seen_names.add(name)
        seen_slugs.add(slug)

        raw_candidates = raw_member["candidates"]
        if not isinstance(raw_candidates, list) or len(raw_candidates) != 3:
            raise SpecError(f"{context}.candidates must contain exactly three entries")
        candidates: list[Candidate] = []
        identifiers: set[str] = set()
        for candidate_index, raw_candidate_value in enumerate(raw_candidates, start=1):
            candidate_context = f"{context}.candidates[{candidate_index}]"
            raw_candidate = _object(raw_candidate_value, candidate_context)
            _exact_keys(raw_candidate, {"id", "seed"}, candidate_context)
            identifier = _text(raw_candidate["id"], f"{candidate_context}.id")
            if not re.fullmatch(r"[a-c]", identifier):
                raise SpecError(f"{candidate_context}.id must be a, b, or c")
            seed = _integer(raw_candidate["seed"], f"{candidate_context}.seed", minimum=0, maximum=2**31 - 1)
            if identifier in identifiers or seed in seen_seeds:
                raise SpecError(f"{candidate_context} duplicates an identifier or global seed")
            identifiers.add(identifier)
            seen_seeds.add(seed)
            candidates.append(Candidate(identifier=identifier, seed=seed))

        members.append(
            Member(
                name=name,
                slug=slug,
                instruction=_text(raw_member["instruction"], f"{context}.instruction", minimum=40),
                text=_text(raw_member["text"], f"{context}.text", minimum=40),
                candidates=tuple(candidates),
            )
        )

    return AuditionSpec(
        project=_text(root["project"], "project"),
        language=language,
        model=model,
        generation=generation,
        members=tuple(members),
    )


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def _generate(spec: AuditionSpec, output: Path) -> None:
    import numpy as np
    import soundfile as sf
    import torch
    from qwen_tts import Qwen3TTSModel

    if not spec.model.path.is_dir():
        raise FileNotFoundError(f"model directory is unavailable: {spec.model.path}")
    output.mkdir(parents=True, exist_ok=False)

    model = Qwen3TTSModel.from_pretrained(
        str(spec.model.path),
        device_map="cuda:0",
        dtype=torch.bfloat16,
        attn_implementation="sdpa",
        local_files_only=True,
    )

    outputs: list[dict[str, Any]] = []
    for member_index, member in enumerate(spec.members, start=1):
        member_dir = output / f"{member_index:02d}-{member.slug}"
        member_dir.mkdir(mode=0o750)
        for candidate in member.candidates:
            random.seed(candidate.seed)
            np.random.seed(candidate.seed)
            torch.manual_seed(candidate.seed)
            torch.cuda.manual_seed_all(candidate.seed)

            waves, sample_rate = model.generate_voice_design(
                text=member.text,
                language=spec.language,
                instruct=member.instruction,
                temperature=spec.generation.temperature,
                top_p=spec.generation.top_p,
                max_new_tokens=spec.generation.max_new_tokens,
            )
            if len(waves) != 1:
                raise RuntimeError(f"expected one waveform for {member.name} {candidate.identifier}, got {len(waves)}")

            destination = member_dir / f"{member.slug}-{candidate.identifier}.wav"
            temporary = destination.with_suffix(".wav.new")
            sf.write(temporary, waves[0], sample_rate, format="WAV", subtype="PCM_16")
            temporary.replace(destination)
            info = sf.info(destination)
            outputs.append(
                {
                    "member": member.name,
                    "slug": member.slug,
                    "candidate": candidate.identifier,
                    "seed": candidate.seed,
                    "file": destination.relative_to(output).as_posix(),
                    "sha256": _sha256(destination),
                    "sampleRate": info.samplerate,
                    "channels": info.channels,
                    "frames": info.frames,
                    "durationSeconds": info.duration,
                    "format": info.format,
                    "subtype": info.subtype,
                }
            )
            print(f"AUDITION_READY member={member.name} candidate={candidate.identifier} file={destination}", flush=True)

    receipt = {
        "schemaVersion": 1,
        "project": spec.project,
        "language": spec.language,
        "model": {
            "repository": spec.model.repository,
            "revision": spec.model.revision,
            "path": str(spec.model.path),
        },
        "generation": asdict(spec.generation),
        "outputs": outputs,
    }
    receipt_path = output / "receipt.json"
    receipt_path.write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")
    checksums = [f"{entry['sha256']}  {entry['file']}" for entry in outputs]
    checksums.append(f"{_sha256(receipt_path)}  receipt.json")
    (output / "SHA256SUMS").write_text("\n".join(checksums) + "\n", encoding="utf-8")


def _arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--spec", type=Path, required=True)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--validate-only", action="store_true")
    return parser.parse_args()


def main() -> int:
    arguments = _arguments()
    try:
        raw = json.loads(arguments.spec.read_text(encoding="utf-8"))
        spec = parse_spec(raw)
        if arguments.validate_only:
            print("VOICE_AUDITION_SPEC_VALID")
            return 0
        if arguments.output is None:
            raise SpecError("--output is required unless --validate-only is used")
        _generate(spec, arguments.output)
        print(f"VOICE_AUDITIONS_READY={arguments.output}")
        return 0
    except (SpecError, FileNotFoundError, json.JSONDecodeError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
