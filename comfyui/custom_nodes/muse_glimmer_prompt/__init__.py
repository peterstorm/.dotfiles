"""ComfyUI node for compiling Krea 2 and MiniMax H3 prompts with Muse Glimmer."""

from __future__ import annotations

import json
import os
import re
import stat
import urllib.error
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Any

TASK_KREA2 = "Krea 2 image"
TASK_H3_BASE = "MiniMax H3 base"
TASK_H3_REFERENCE = "MiniMax H3 reference"
TASKS = (TASK_KREA2, TASK_H3_BASE, TASK_H3_REFERENCE)
REASONING_STRENGTHS = ("low", "medium", "high", "xhigh")

KREA2_INSTRUCTION = """You are an expert prompt engineer for Krea 2. Expand the brief into one faithful, cohesive natural-language image prompt. Internally choose the most suitable medium, composition, framing, grounded detail, lighting, and palette. Preserve every requested subject, action, color, spatial relationship, and medium. Do not invent unsupported objects or characters. Put any requested visible text in double quotes. If the brief is already detailed, polish rather than replace it. Return only one prompt paragraph: no planning, headings, bullets, JSON, markdown, or commentary."""

H3_BASE_INSTRUCTION = """You are writing a production-ready MiniMax H3 prompt for text-to-video, image-to-video, or first/last-frame video. Preserve the brief exactly while making timing physically achievable. Describe the overall scene, then timed shots with composition, subject blocking, action, lens/camera motion, lighting, continuity, dialogue, diegetic sound, and music. Return only these fields in this exact order:
integrated_multimodal_description: ...
overall_soundscape: ...
non_diegetic_music: ...
Do not emit markdown fences, analysis, or unresolved reference labels."""

H3_REFERENCE_INSTRUCTION = """You are writing a production-ready MiniMax H3 reference-to-video prompt. Use only the supplied reference labels and assign each one an explicit job such as identity, wardrobe, style, environment, motion, camera, or voice. Preserve the brief, reference identity, and temporal feasibility. Return only these fields in this exact order:
subject_definitions: ...
summary: ...
retention_analysis: ...
detailed_description: ...
overall_soundscape: ...
non_diegetic_music: ...
Do not emit markdown fences, analysis, or invent unresolved reference labels."""

TASK_INSTRUCTIONS = {
    TASK_KREA2: KREA2_INSTRUCTION,
    TASK_H3_BASE: H3_BASE_INSTRUCTION,
    TASK_H3_REFERENCE: H3_REFERENCE_INSTRUCTION,
}


@dataclass(frozen=True)
class KreaImageRequest:
    brief: str
    aspect_ratio: str


@dataclass(frozen=True)
class H3BaseRequest:
    brief: str
    duration_seconds: int
    aspect_ratio: str


@dataclass(frozen=True)
class H3ReferenceRequest:
    brief: str
    reference_manifest: str
    duration_seconds: int
    aspect_ratio: str


CreativePromptRequest = KreaImageRequest | H3BaseRequest | H3ReferenceRequest


def parse_prompt_request(
    task: str,
    brief: str,
    reference_manifest: str,
    duration_seconds: int,
    aspect_ratio: str,
) -> CreativePromptRequest:
    """Parse UI values into one task-specific validated prompt request."""
    normalized_brief = brief.strip()
    if not normalized_brief:
        raise ValueError("creative brief must not be empty")
    if task == TASK_KREA2:
        return KreaImageRequest(normalized_brief, aspect_ratio)
    if task not in (TASK_H3_BASE, TASK_H3_REFERENCE):
        raise ValueError(f"unsupported creative task: {task}")
    if not 4 <= duration_seconds <= 15:
        raise ValueError("MiniMax H3 duration must be between 4 and 15 seconds")
    if task == TASK_H3_BASE:
        return H3BaseRequest(normalized_brief, duration_seconds, aspect_ratio)
    normalized_references = reference_manifest.strip()
    if not normalized_references:
        raise ValueError("MiniMax H3 reference prompting requires a reference manifest")
    return H3ReferenceRequest(
        normalized_brief, normalized_references, duration_seconds, aspect_ratio
    )


def compile_messages(
    request: CreativePromptRequest,
) -> tuple[dict[str, str], dict[str, str]]:
    """Compile a validated request into system and user Muse chat messages."""
    if isinstance(request, KreaImageRequest):
        task = TASK_KREA2
        user_sections = (
            f"task: {task}",
            f"aspect_ratio: {request.aspect_ratio}",
            f"creative_brief:\n{request.brief}",
        )
    elif isinstance(request, H3BaseRequest):
        task = TASK_H3_BASE
        user_sections = (
            f"task: {task}",
            f"duration_seconds: {request.duration_seconds}",
            f"aspect_ratio: {request.aspect_ratio}",
            f"creative_brief:\n{request.brief}",
        )
    else:
        task = TASK_H3_REFERENCE
        user_sections = (
            f"task: {task}",
            f"duration_seconds: {request.duration_seconds}",
            f"aspect_ratio: {request.aspect_ratio}",
            f"reference_manifest:\n{request.reference_manifest}",
            f"creative_brief:\n{request.brief}",
        )
    return (
        {"role": "system", "content": TASK_INSTRUCTIONS[task]},
        {"role": "user", "content": "\n\n".join(user_sections)},
    )


def build_request_body(
    messages: tuple[dict[str, str], dict[str, str]],
    reasoning_strength: str,
    max_tokens: int,
) -> dict[str, Any]:
    """Build the OpenAI-compatible request without credentials or endpoint state."""
    if reasoning_strength not in REASONING_STRENGTHS:
        raise ValueError(f"unsupported reasoning strength: {reasoning_strength}")
    if not 256 <= max_tokens <= 8192:
        raise ValueError("max_tokens must be between 256 and 8192")
    return {
        "model": "muse-glimmer-30b",
        "messages": list(messages),
        "temperature": 1.0,
        "top_p": 0.95,
        "top_k": 64,
        "max_tokens": max_tokens,
        "chat_template_kwargs": {"reasoning_strength": reasoning_strength},
    }


def read_private_key(path: Path) -> str:
    """Read a non-empty key only when group and other permissions are absent."""
    try:
        key_stat = path.stat()
        mode = stat.S_IMODE(key_stat.st_mode)
        if mode & 0o077:
            raise RuntimeError(f"Muse API key file must be private (mode 0600): {path}")
        key = path.read_text(encoding="utf-8").strip()
    except OSError as error:
        raise RuntimeError(f"Muse API key file is unavailable: {path}") from error
    if not key:
        raise RuntimeError(f"Muse API key file is empty: {path}")
    return key


def parse_response(payload: dict[str, Any]) -> tuple[str, str]:
    """Parse the single assistant result returned by the local Muse endpoint."""
    try:
        message = payload["choices"][0]["message"]
        prompt = message["content"].strip()
    except (KeyError, IndexError, TypeError, AttributeError) as error:
        raise RuntimeError("Muse returned no usable prompt") from error
    if not prompt:
        raise RuntimeError("Muse returned an empty prompt")
    reasoning = message.get("reasoning_content") or message.get("reasoning") or ""
    return prompt, str(reasoning).strip()


def sanitize_http_error_body(raw_body: bytes) -> str:
    """Return a bounded printable error detail with common credentials redacted."""
    detail = raw_body.decode("utf-8", errors="replace")
    detail = " ".join(detail.split())
    detail = re.sub(
        r"(?i)\b(api[_ -]?key|authorization|bearer|token)\b\s*[:=]?\s*\S+",
        r"\1 [redacted]",
        detail,
    )
    return detail[:256]


def request_prompt(
    endpoint: str,
    api_key: str,
    body: dict[str, Any],
    timeout_seconds: int,
) -> tuple[str, str]:
    """Imperative HTTP boundary for the local OpenAI-compatible Muse service."""
    request = urllib.request.Request(
        f"{endpoint.rstrip('/')}/chat/completions",
        data=json.dumps(body).encode("utf-8"),
        headers={
            "Authorization": f"Bearer {api_key}",
            "Content-Type": "application/json",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout_seconds) as response:
            payload = json.load(response)
    except urllib.error.HTTPError as error:
        detail = sanitize_http_error_body(error.read(1024))
        suffix = f": {detail}" if detail else ""
        raise RuntimeError(
            f"Muse HTTP {error.code} {error.reason}{suffix}"
        ) from error
    except urllib.error.URLError as error:
        raise RuntimeError(f"Muse connection failed: {error.reason}") from error
    except TimeoutError as error:
        raise RuntimeError("Muse request timed out") from error
    except json.JSONDecodeError as error:
        raise RuntimeError("Muse returned malformed JSON") from error
    return parse_response(payload)


class MuseGlimmerPrompt:
    """Compile a creative brief into a directly connectable generation prompt."""

    @classmethod
    def INPUT_TYPES(cls) -> dict[str, Any]:
        return {
            "required": {
                "task": (TASKS,),
                "brief": ("STRING", {"multiline": True, "default": ""}),
                "duration_seconds": ("INT", {"default": 5, "min": 4, "max": 15}),
                "aspect_ratio": (
                    ("16:9", "9:16", "1:1", "4:3", "3:4", "21:9"),
                ),
                "reasoning_strength": (REASONING_STRENGTHS, {"default": "xhigh"}),
                "max_tokens": (
                    "INT",
                    {"default": 4096, "min": 256, "max": 8192, "step": 256},
                ),
            },
            "optional": {
                "reference_manifest": (
                    "STRING",
                    {
                        "multiline": True,
                        "default": "",
                        "placeholder": "<Picture 1>: identity; <Video 1>: motion; <Audio 1>: voice",
                    },
                ),
            },
        }

    RETURN_TYPES = ("STRING", "STRING")
    RETURN_NAMES = ("prompt", "reasoning")
    FUNCTION = "generate"
    CATEGORY = "creative/Muse Glimmer"

    def generate(
        self,
        task: str,
        brief: str,
        duration_seconds: int,
        aspect_ratio: str,
        reasoning_strength: str,
        max_tokens: int,
        reference_manifest: str = "",
    ) -> tuple[str, str]:
        request = parse_prompt_request(
            task, brief, reference_manifest, duration_seconds, aspect_ratio
        )
        messages = compile_messages(request)
        body = build_request_body(messages, reasoning_strength, max_tokens)
        key_path = Path(
            os.environ.get(
                "MUSE_GLIMMER_API_KEY_FILE",
                "/home/peterstorm/.config/muse-glimmer/api-key",
            )
        )
        endpoint = os.environ.get(
            "MUSE_GLIMMER_BASE_URL", "http://127.0.0.1:8001/v1"
        )
        api_key = read_private_key(key_path)
        return request_prompt(endpoint, api_key, body, timeout_seconds=600)


NODE_CLASS_MAPPINGS = {"MuseGlimmerPrompt": MuseGlimmerPrompt}
NODE_DISPLAY_NAME_MAPPINGS = {"MuseGlimmerPrompt": "Muse Glimmer Creative Prompt"}
