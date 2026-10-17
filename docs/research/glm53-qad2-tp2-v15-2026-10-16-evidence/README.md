# GLM-5.3 qad2 TP2 v15 — evidence (2026-10-16)

- `recipe-glm-5.3-flash-vllm.md` — the third-party "GLM-5.3-Flash vLLM Recipe"
  page the v15 profile follows, stripped to text. Its SHA-256 is pinned by
  `tests/glm53-flash-qad2-tp2-v15-contract.sh`; the recipe's facts (image
  digest, checkpoint revision, launcher argv, KV bytes, effort high,
  `CACHE_MODE=vram`) are re-proven against the pulled image by
  `scripts/inference/glm53/pull-glm53-flash-qad2-tp2-v15-image.sh`.

The recipe's measurements (recall, GSM8K, speed) are the author's, at 300 W
per card; they are context for the choice, not claims this repository has
reproduced — except the KV pool and context, which the desktop boot matched
exactly (1,844,162 tokens, 1,048,576 context; see the runbook's Status).
