#!/usr/bin/env python3
"""Generate a three-candidate reference-free voice identity audition."""

from __future__ import annotations

import argparse
import hashlib
import json
import random
import re
import sys
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any, Literal


class SpecError(ValueError):
    """The input cannot represent a valid identity audition."""


@dataclass(frozen=True)
class ModelSpec:
    repository: str
    revision: str
    source_repository: str
    source_revision: str
    path: Path


@dataclass(frozen=True)
class Candidate:
    identifier: str
    seed: int


@dataclass(frozen=True)
class VoiceIdentity:
    name: str
    slug: str
    language: Literal["English"]
    instruction: str
    text: str
    candidates: tuple[Candidate, Candidate, Candidate]


@dataclass(frozen=True)
class VoxParameters:
    cfg_value: float
    inference_timesteps: int
    optimize: bool


@dataclass(frozen=True)
class BreezeParameters:
    cfg_scale: float
    max_new_tokens: int
    repetition_penalty: float


GenerationParameters = VoxParameters | BreezeParameters
Engine = Literal["voxcpm2", "breeze-tts2"]


@dataclass(frozen=True)
class AuditionSpec:
    project: str
    engine: Engine
    model: ModelSpec
    identity: VoiceIdentity
    generation: GenerationParameters


_SLUG = re.compile(r"^[a-z][a-z0-9-]{1,31}$")
_REVISION = re.compile(r"^[0-9a-f]{40}$")


def _object(value: Any, context: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise SpecError(f"{context} must be an object")
    return value


def _exact_keys(value: dict[str, Any], expected: set[str], context: str) -> None:
    actual = set(value)
    if actual != expected:
        raise SpecError(
            f"{context} keys differ; missing={sorted(expected - actual)}, "
            f"unknown={sorted(actual - expected)}"
        )


def _text(value: Any, context: str, *, minimum: int = 1) -> str:
    if not isinstance(value, str) or len(value.strip()) < minimum:
        raise SpecError(f"{context} must contain at least {minimum} characters")
    return value.strip()


def _integer(value: Any, context: str, *, minimum: int, maximum: int) -> int:
    if (
        isinstance(value, bool)
        or not isinstance(value, int)
        or not minimum <= value <= maximum
    ):
        raise SpecError(
            f"{context} must be an integer from {minimum} through {maximum}"
        )
    return value


def _number(value: Any, context: str, *, minimum: float, maximum: float) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise SpecError(f"{context} must be numeric")
    parsed = float(value)
    if not minimum <= parsed <= maximum:
        raise SpecError(f"{context} must be from {minimum} through {maximum}")
    return parsed


def _revision(value: Any, context: str) -> str:
    parsed = _text(value, context)
    if not _REVISION.fullmatch(parsed):
        raise SpecError(f"{context} must be a full hexadecimal Git revision")
    return parsed


def _parse_model(raw_value: Any) -> ModelSpec:
    raw = _object(raw_value, "model")
    _exact_keys(
        raw,
        {"repository", "revision", "sourceRepository", "sourceRevision", "path"},
        "model",
    )
    path = Path(_text(raw["path"], "model.path"))
    if not path.is_absolute():
        raise SpecError("model.path must be absolute")
    return ModelSpec(
        repository=_text(raw["repository"], "model.repository"),
        revision=_revision(raw["revision"], "model.revision"),
        source_repository=_text(raw["sourceRepository"], "model.sourceRepository"),
        source_revision=_revision(raw["sourceRevision"], "model.sourceRevision"),
        path=path,
    )


def _parse_identity(raw_value: Any) -> VoiceIdentity:
    raw = _object(raw_value, "identity")
    _exact_keys(
        raw,
        {"name", "slug", "language", "instruction", "text", "candidates"},
        "identity",
    )
    slug = _text(raw["slug"], "identity.slug")
    if not _SLUG.fullmatch(slug):
        raise SpecError(f"identity.slug must match {_SLUG.pattern}")
    if raw["language"] != "English":
        raise SpecError("identity.language must equal English")
    raw_candidates = raw["candidates"]
    if not isinstance(raw_candidates, list) or len(raw_candidates) != 3:
        raise SpecError("identity.candidates must contain exactly three entries")
    candidates: list[Candidate] = []
    identifiers: set[str] = set()
    seeds: set[int] = set()
    for index, raw_candidate_value in enumerate(raw_candidates, start=1):
        context = f"identity.candidates[{index}]"
        raw_candidate = _object(raw_candidate_value, context)
        _exact_keys(raw_candidate, {"id", "seed"}, context)
        identifier = _text(raw_candidate["id"], f"{context}.id")
        if identifier not in {"a", "b", "c"} or identifier in identifiers:
            raise SpecError(f"{context}.id must be one unique value from a, b, c")
        seed = _integer(
            raw_candidate["seed"], f"{context}.seed", minimum=0, maximum=2**31 - 1
        )
        if seed in seeds:
            raise SpecError(f"{context}.seed must be unique")
        identifiers.add(identifier)
        seeds.add(seed)
        candidates.append(Candidate(identifier=identifier, seed=seed))
    if identifiers != {"a", "b", "c"}:
        raise SpecError("identity candidate identifiers must be exactly a, b, and c")
    return VoiceIdentity(
        name=_text(raw["name"], "identity.name"),
        slug=slug,
        language="English",
        instruction=_text(raw["instruction"], "identity.instruction", minimum=40),
        text=_text(raw["text"], "identity.text", minimum=40),
        candidates=(candidates[0], candidates[1], candidates[2]),
    )


def _parse_generation(engine: Engine, raw_value: Any) -> GenerationParameters:
    raw = _object(raw_value, "generation")
    if engine == "voxcpm2":
        _exact_keys(raw, {"cfgValue", "inferenceTimesteps", "optimize"}, "generation")
        if not isinstance(raw["optimize"], bool):
            raise SpecError("generation.optimize must be boolean")
        return VoxParameters(
            cfg_value=_number(
                raw["cfgValue"], "generation.cfgValue", minimum=1.0, maximum=3.0
            ),
            inference_timesteps=_integer(
                raw["inferenceTimesteps"],
                "generation.inferenceTimesteps",
                minimum=4,
                maximum=30,
            ),
            optimize=raw["optimize"],
        )
    _exact_keys(raw, {"cfgScale", "maxNewTokens", "repetitionPenalty"}, "generation")
    return BreezeParameters(
        cfg_scale=_number(
            raw["cfgScale"], "generation.cfgScale", minimum=1.0, maximum=8.0
        ),
        max_new_tokens=_integer(
            raw["maxNewTokens"], "generation.maxNewTokens", minimum=128, maximum=2048
        ),
        repetition_penalty=_number(
            raw["repetitionPenalty"],
            "generation.repetitionPenalty",
            minimum=1.0,
            maximum=2.0,
        ),
    )


def parse_spec(raw_value: Any) -> AuditionSpec:
    raw = _object(raw_value, "specification")
    _exact_keys(
        raw,
        {
            "schemaVersion",
            "project",
            "stage",
            "authority",
            "engine",
            "model",
            "identity",
            "generation",
        },
        "specification",
    )
    if raw["schemaVersion"] != 1:
        raise SpecError("schemaVersion must equal 1")
    if raw["stage"] != "Development" or raw["authority"] != "none":
        raise SpecError("the audition must be Development with no authority")
    engine = raw["engine"]
    if engine not in {"voxcpm2", "breeze-tts2"}:
        raise SpecError("engine must equal voxcpm2 or breeze-tts2")
    return AuditionSpec(
        project=_text(raw["project"], "project"),
        engine=engine,
        model=_parse_model(raw["model"]),
        identity=_parse_identity(raw["identity"]),
        generation=_parse_generation(engine, raw["generation"]),
    )


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def _audio_entry(path: Path, output: Path, candidate: Candidate) -> dict[str, Any]:
    import soundfile as sf

    info = sf.info(path)
    return {
        "candidate": candidate.identifier,
        "seed": candidate.seed,
        "file": path.relative_to(output).as_posix(),
        "sha256": _sha256(path),
        "sampleRate": info.samplerate,
        "channels": info.channels,
        "frames": info.frames,
        "durationSeconds": info.duration,
        "format": info.format,
        "subtype": info.subtype,
        "nativeUnprocessed": True,
    }


def _generate_voxcpm2(spec: AuditionSpec, output: Path) -> list[dict[str, Any]]:
    import soundfile as sf
    from voxcpm import VoxCPM

    parameters = spec.generation
    if not isinstance(parameters, VoxParameters):
        raise SpecError("voxcpm2 requires VoxParameters")
    model = VoxCPM.from_pretrained(
        str(spec.model.path),
        load_denoiser=False,
        local_files_only=True,
        optimize=parameters.optimize,
        device="cuda:0",
    )
    designed_text = f"({spec.identity.instruction}){spec.identity.text}"
    entries: list[dict[str, Any]] = []
    for candidate in spec.identity.candidates:
        waveform = model.generate(
            text=designed_text,
            cfg_value=parameters.cfg_value,
            inference_timesteps=parameters.inference_timesteps,
            seed=candidate.seed,
        )
        destination = output / f"{spec.identity.slug}-{candidate.identifier}.wav"
        temporary = destination.with_suffix(".wav.new")
        sf.write(
            temporary,
            waveform,
            model.tts_model.sample_rate,
            format="WAV",
            subtype="PCM_16",
        )
        temporary.replace(destination)
        entries.append(_audio_entry(destination, output, candidate))
        print(
            f"IDENTITY_CANDIDATE_READY engine={spec.engine} candidate={candidate.identifier}",
            flush=True,
        )
    return entries


def _generate_breeze(spec: AuditionSpec, output: Path) -> list[dict[str, Any]]:
    import soundfile as sf
    import torch
    from breeze_infer.runtime import (
        resolve_device,
        set_all_seeds,
        update_generation_config_for_breeze,
    )
    from breeze_infer.templates import get_template, prepare_inputs
    from models.breeze import BreezeForConditionalGeneration
    from models.breeze_config import BreezeConfig
    from models.fast_streaming import FastBreezeStreamingRuntime, FastStreamingConfig
    from qwen_tts import Qwen3TTSTokenizer
    from transformers import AutoTokenizer

    parameters = spec.generation
    if not isinstance(parameters, BreezeParameters):
        raise SpecError("breeze-tts2 requires BreezeParameters")
    device = resolve_device()
    tokenizer = AutoTokenizer.from_pretrained(spec.model.path, fix_mistral_regex=True)
    config = BreezeConfig.from_pretrained(spec.model.path)
    config.text_encoder_config.preferred_attn_implementation = "eager"
    model = BreezeForConditionalGeneration.from_pretrained(
        spec.model.path,
        config=config,
        dtype=torch.bfloat16,
        attn_implementation="eager",
    )
    model.to(device).eval()
    audio_tokenizer = Qwen3TTSTokenizer.from_pretrained(
        str(spec.model.path / "audio_tokenizer"), device_map=device
    )
    update_generation_config_for_breeze(model)
    runtime = FastBreezeStreamingRuntime(
        model,
        audio_tokenizer,
        FastStreamingConfig(
            max_new_tokens=parameters.max_new_tokens,
            max_seq_len=2048,
            fast_all=False,
            fast_text_encoder=False,
            fast_backbone_prefill=False,
            fast_backbone_decode=False,
            fast_depth_decoder=False,
            fast_codec=False,
            repetition_penalty=parameters.repetition_penalty,
        ),
        tokenizer=tokenizer,
    )
    entries: list[dict[str, Any]] = []
    for candidate in spec.identity.candidates:
        set_all_seeds(candidate.seed)
        request = {
            "id": candidate.identifier,
            "text": spec.identity.text,
            "instruction": spec.identity.instruction,
            "speaker": "S0",
        }
        inputs = prepare_inputs(
            tokenizer,
            audio_tokenizer,
            model,
            [request],
            get_template("tts_instruction"),
            guidance_scale=parameters.cfg_scale,
            guidance_scale_ref=None,
            guidance_scale_ins=None,
        )
        destination = output / f"{spec.identity.slug}-{candidate.identifier}.wav"
        temporary = destination.with_suffix(".wav.new")
        with sf.SoundFile(
            temporary,
            mode="w",
            samplerate=runtime.sample_rate,
            channels=1,
            subtype="PCM_16",
            format="WAV",
        ) as output_file:
            for chunk in runtime.iter_audio_chunks(
                inputs, request_id=candidate.identifier
            ):
                output_file.write(chunk.audio)
        temporary.replace(destination)
        entries.append(_audio_entry(destination, output, candidate))
        print(
            f"IDENTITY_CANDIDATE_READY engine={spec.engine} candidate={candidate.identifier}",
            flush=True,
        )
    return entries


def _generate(spec: AuditionSpec, output: Path) -> None:
    if not spec.model.path.is_dir():
        raise FileNotFoundError(f"model directory is unavailable: {spec.model.path}")
    output.mkdir(parents=True, exist_ok=False)
    random.seed(0)
    outputs = (
        _generate_voxcpm2(spec, output)
        if spec.engine == "voxcpm2"
        else _generate_breeze(spec, output)
    )
    receipt = {
        "schemaVersion": 1,
        "project": spec.project,
        "stage": "Development",
        "authority": "none",
        "engine": spec.engine,
        "model": {
            "repository": spec.model.repository,
            "revision": spec.model.revision,
            "sourceRepository": spec.model.source_repository,
            "sourceRevision": spec.model.source_revision,
            "path": str(spec.model.path),
        },
        "identity": {
            "name": spec.identity.name,
            "slug": spec.identity.slug,
            "language": spec.identity.language,
            "instruction": spec.identity.instruction,
            "text": spec.identity.text,
        },
        "generation": asdict(spec.generation),
        "compatibilityAdaptations": (
            [
                "Breeze nested text_encoder preferred_attn_implementation: flash_attention_2 -> eager"
            ]
            if spec.engine == "breeze-tts2"
            else []
        ),
        "outputs": outputs,
        "technicalQaOnly": True,
        "userSelectionRequired": True,
        "productionAuthority": False,
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
        spec = parse_spec(json.loads(arguments.spec.read_text(encoding="utf-8")))
        if arguments.validate_only:
            print(f"EXPRESSIVE_VOICE_IDENTITY_SPEC_VALID engine={spec.engine}")
            return 0
        if arguments.output is None:
            raise SpecError("--output is required unless --validate-only is used")
        _generate(spec, arguments.output)
        print(f"EXPRESSIVE_VOICE_IDENTITY_AUDITIONS_READY={arguments.output}")
        return 0
    except (SpecError, FileNotFoundError, json.JSONDecodeError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
