# docs/research

Research receipts: the claim, the source, the raw evidence. Each dated
document is self-contained; raw API/registry responses live under the
matching `-evidence/` folder so a finding can be re-verified without
re-querying upstream.

| Date | Document | Evidence |
|---|---|---|
| 2026-08-18 | [`2026-08-18-qwen38-upstream-update-research.md`](2026-08-18-qwen38-upstream-update-research.md) — Qwen3.8-27B runbook upstream-update research (vLLM + SGLang, both engines' DSpark profiles, community evidence; drove the `-v2` scripts and `docs/runbooks/qwen38-27b-runbook-2026-08-18.md`) | [`qwen38-2026-08-18-evidence/`](qwen38-2026-08-18-evidence/) (vllm/, sglang/, recipes/, models/, docker/, community/) |

Convention: when a research document changes a pin or a script, the commit
that lands the change updates the matching `tests/*-contract.sh` in the same
commit, and the runbook section that carried the old claim gets a
supersession pointer rather than a silent rewrite.
