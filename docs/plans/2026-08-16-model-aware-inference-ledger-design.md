# Model-aware durable inference statistics

## Decision

Extend the existing runtime-neutral token ledger and static statistics page with model identity and interval-average served throughput. Preserve every historical total without pretending that old aggregate rows can be assigned to a model.

## Durable schema

Migrate `stats.csv` atomically from the legacy five-column schema to:

```text
ts,when,model,engine,endpoint,prompt_tokens,generation_tokens,requests,interval_seconds,prompt_tokens_per_second,generation_tokens_per_second
```

Legacy rows whose identity cannot be established become `Historical aggregate` rows with `engine=legacy`; their speed fields remain empty. Known historical intervals may be reattributed only through declarative, non-overlapping timestamp ranges backed by independent runtime evidence. The desktop range from the explicit `SGLang pre-ledger backfill` row through the final pre-migration scrape is assigned to `qwen3.8-27b`, because SGLang served only Qwen on the mutually exclusive endpoint. Migration and post-migration repair are atomic, idempotent, and preserve prompt, generation, request, and all-model lifetime totals exactly. New scrapes parse Prometheus `model_name` labels, maintain counters per endpoint/model, and append one row per model. The endpoint's actual elapsed observation interval—not an assumed 900 seconds—is the rate denominator.

The state schema gains endpoint and per-model observation times plus a per-model counter map. Legacy aggregate endpoint states migrate losslessly. If a legacy endpoint has exactly one current model, its aggregate baseline is assigned to that model. If several models appear at migration, the knowable transition delta remains `Historical aggregate` while exact per-model baselines are seeded. Temporarily absent models retain their own baseline and observation time so they cannot be double-counted when they return.

Pending transactions contain all rows for one observation and remain idempotently recoverable. Recovery inspects only the bounded CSV tail; normal recording never scans the forever-growing ledger. CSV migration uses write/fsync/atomic rename before any new interval is committed.

## Interface

The page remains self-contained static HTML. A keyboard-accessible selector switches between All models, each named model, and Historical aggregate. Selection updates:

- lifetime and recent totals;
- activity calendar and 14-day bars;
- a 24-hour prompt/output served-throughput chart.

A comparison table remains visible and shows each model's totals and latest measured prompt/output rates. Historical aggregate remains explicit for genuinely unsplittable rows rather than being attributed to a current model.

Rates are labelled **served throughput** and documented as token deltas divided by elapsed wall time. They describe delivered traffic, including idle time, not raw prefill-kernel or decode-only speed.

## Validation

Unit tests cover Prometheus label parsing, per-model aggregation, state migration, bounded legacy attribution and overlap rejection, post-schema repair, crash-recovery ordering and de-duplication, model switches, multi-row transaction recovery, rate calculation, HTML selector/chart/table output, and HTML escaping. Deployment validation renders production data in a temporary directory, loads desktop and mobile views in a browser, and verifies lifetime totals are unchanged by migration.
