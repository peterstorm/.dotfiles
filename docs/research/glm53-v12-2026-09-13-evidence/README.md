# GLM-5.3 v12 research evidence — captured 2026-09-13

Public upstream artifacts supporting
[`../2026-09-13-glm53-v12-source-port-research.md`](../2026-09-13-glm53-v12-source-port-research.md).

| File | Upstream source | SHA-256 |
|---|---|---|
| `upstream-glm-5.3-flash-spark-tp2-r2.md` | `local-inference-lab/rtx6kpro@74485e5262c31ddeaef7aae0aec9879bcef0d5cb` | `20215b983bbeb7737a16ee54f068e23b2cef75d9fd5d07b058a812480eb6cefb` |
| `tp2-experimental-r2-source.lock` | same repository/commit | `87bd0bbb39e690285567c1ed55551e2dbf8dcd14980944a0e8981abf276c1cd2` |
| `tp2-experimental-r2-artifact-audit.json` | same repository/commit | `257d4cf91af125fc711fb184049c9cd9cd865d5402af9e647e8c2703eea5ee0d` |
| `tp2-experimental-r2-registry.json` | same repository/commit | `87fcf824a2d873829bb3d30951cd6baf4a2afc58bc9951888c2abbdd7f022f88` |
| `tp2-experimental-r2-qualification.json` | same repository/commit | `c5da99118598e9e95209f94a838d6aca3a6d7ee7609234ee6f5a0c5b7aba10b9` |
| `r1-to-r2-recipe.diff` | `local-inference-lab/blackwell-llm-docker`, `e62d276..b91127b1` | `a163354252527c35d2332cc959b4f21228e32a50bae2a76291adbb040ffdb5f5` |
| `pr694-graph-memory-accounting.patch` | vLLM PR #694, commits `dd8e5ca3..d84208d4` | `e96960b22ee886099c22ba9060a89d0aa6f43d0a69875d79ea3774b34f457c24` |
| `pr710-sm120-mla-disjoint-bmm.patch` | vLLM PR #710, commits `dbdf960a..0eff5805` | `fdb8bcf11e138c90d42ba875dd4931c576956c91cbf0a61d27fd0dee475c1ca3` |
| `pr718-mamba-null-gap-cleanup.patch` | vLLM PR #718, commit `25fc3585` | `56ed9dd8181ae83ed7b9c66ee1b7fbd18f8981d309fc9acdd2c0190937aa3c37` |

The source lock is the authoritative upstream component identity. The three
patch exports pin the proposed v12-rc1 source inputs. The recipe diff is
restricted to `Dockerfile.glm-spark-tp2` and `serve-glm-spark-tp2.sh`, the R2
surface relevant to this assessment.
