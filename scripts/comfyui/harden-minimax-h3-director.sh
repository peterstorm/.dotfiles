#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 || ! -d "$1" || -z "$2" ]]; then
  printf 'Usage: %s SOURCE_DIR OUTPUT_DIR\n' "$0" >&2
  exit 64
fi

source_dir=$1
output_dir=$2
mkdir -p "$output_dir"
cp -R "$source_dir"/. "$output_dir"
chmod -R u+w "$output_dir"

python3 - "$output_dir" <<'PY'
from pathlib import Path
import sys

root = Path(sys.argv[1])


def replace(relative: str, old: str, new: str) -> None:
    path = root / relative
    content = path.read_text(encoding="utf-8")
    if old not in content:
        raise RuntimeError(
            f"Director hardening target moved: {relative}: {old[:80]!r}"
        )
    path.write_text(content.replace(old, new), encoding="utf-8")


prompt = "lib/prompt_enhancer.py"
replace(prompt, "import re\n", "import re\nimport stat\n")
replace(prompt, "import urllib.request\n", "import urllib.request\nfrom pathlib import Path\n")
replace(
    prompt,
    'DEFAULT_OLLAMA_MODEL = "qwen3.5"',
    'DEFAULT_OLLAMA_MODEL = "qwen3.8-27b"',
)
replace(
    prompt,
    'DEFAULT_OPENAI_COMPAT_URL = "http://127.0.0.1:8080/v1"',
    'DEFAULT_OPENAI_COMPAT_URL = "http://127.0.0.1:8000/v1"',
)
replace(
    prompt,
    "DEFAULT_API_FORMAT = API_FORMAT_OLLAMA",
    "DEFAULT_API_FORMAT = API_FORMAT_OPENAI_COMPAT",
)
replace(
    prompt,
    '''def resolve_api_key(api_format: str, widget_key: str = "") -> str:
    key = (widget_key or "").strip()
    if key:
        return key
    if api_format == API_FORMAT_ZHIPU:
        return (
            os.environ.get("ZHIPU_API_KEY", "").strip()
            or os.environ.get("MINIMAX_PE_API_KEY", "").strip()
        )
    return ""
''',
    '''def resolve_api_key(api_format: str, widget_key: str = "") -> str:
    """Read credentials only from a private server-side file."""
    del api_format, widget_key
    key_file = os.environ.get("MINIMAX_H3_DIRECTOR_LLM_API_KEY_FILE", "").strip()
    if not key_file:
        return ""
    path = Path(key_file)
    try:
        mode = stat.S_IMODE(path.stat().st_mode)
        if mode & 0o077:
            raise RuntimeError(
                f"Director LLM API key file must be private (mode 0600): {path}"
            )
        return path.read_text(encoding="utf-8").strip()
    except OSError as error:
        raise RuntimeError(
            f"Director LLM API key file is unavailable: {path}"
        ) from error
''',
)
for relative in ("director/h3_latent_upscale.py", "director/segment_cache.py"):
    replace(relative, "weights_only=False", "weights_only=True")

routes = "director/http_routes.py"
replace(
    routes,
    "from server import PromptServer\n",
    "from server import PromptServer\n\n"
    "from .prompt_enhance_routes import register_prompt_enhance_routes\n",
)
replace(
    routes,
    '    _register_route(routes, "POST", "/minimax/director/detect_shots", minimax_detect_shots)\n'
    "    _ROUTES_REGISTERED = True\n",
    '    _register_route(routes, "POST", "/minimax/director/detect_shots", minimax_detect_shots)\n'
    "    register_prompt_enhance_routes(routes, _register_route)\n"
    "    _ROUTES_REGISTERED = True\n",
)

frontend = "web/js/minimax_prompt_enhancer.js"
replace(
    frontend,
    'const DEFAULT_LLM_URL = "http://127.0.0.1:11434/v1";',
    'const DEFAULT_LLM_URL = "http://127.0.0.1:8000/v1";',
)
replace(
    frontend,
    'const DEFAULT_LLM_MODEL = "qwen3.5";',
    'const DEFAULT_LLM_MODEL = "qwen3.8-27b";',
)
replace(
    frontend,
    'const DEFAULT_OPENAI_COMPAT_URL = "http://127.0.0.1:8080/v1";',
    'const DEFAULT_OPENAI_COMPAT_URL = "http://127.0.0.1:8000/v1";',
)
replace(
    frontend,
    'const DEFAULT_API_FORMAT = "Ollama";',
    'const DEFAULT_API_FORMAT = "OpenAI Compatible";',
)
replace(
    frontend,
    '    pe.apiKeyInput.autocomplete = "off";\n'
    '    pe.apiKeyInput.className = "minimax-pe-input";',
    '    pe.apiKeyInput.autocomplete = "off";\n'
    '    pe.apiKeyInput.disabled = true;\n'
    '    pe.apiKeyInput.placeholder = '
    '"Server-side key file (not stored in workflows)";\n'
    '    pe.apiKeyInput.className = "minimax-pe-input";',
)
replace(
    frontend,
    '            pe.apiKeyInput.placeholder = fmt === API_ZHIPU ? '
    '"智谱 API Key" : "OpenAI / llama-swap API Key（可选）";',
    '            pe.apiKeyInput.placeholder = '
    '"Server-side key file (not stored in workflows)";',
)
replace(
    frontend,
    '        if (w("llm_api_key")) pe.apiKeyInput.value = '
    'w("llm_api_key").value || "";',
    '        if (pe.apiKeyInput) pe.apiKeyInput.value = "";',
)
replace(
    frontend,
    '        set("llm_api_key", pe.apiKeyInput.value || "");',
    '        set("llm_api_key", "");',
)
PY

if grep -RqiE \
  'weights_only=False|apiKeyInput\.value = w\("llm_api_key"\)|set\("llm_api_key", pe\.apiKeyInput' \
  "$output_dir"; then
  printf 'Director hardening left an unsafe deserialization or workflow-secret path\n' >&2
  exit 1
fi
grep -q 'DEFAULT_OLLAMA_MODEL = "qwen3.8-27b"' "$output_dir/lib/prompt_enhancer.py"
grep -q 'DEFAULT_API_FORMAT = API_FORMAT_OPENAI_COMPAT' "$output_dir/lib/prompt_enhancer.py"
grep -q 'register_prompt_enhance_routes(routes, _register_route)' \
  "$output_dir/director/http_routes.py"
chmod -R a-w "$output_dir"
