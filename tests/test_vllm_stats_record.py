#!/usr/bin/env python3
"""Unit tests for the model-aware, runtime-neutral inference ledger."""

import csv
import importlib.util
import json
import pathlib
import tempfile
import time
import unittest
from unittest import mock

ROOT = pathlib.Path(__file__).resolve().parents[1]


def load_module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


record = load_module("vllm_stats_record", ROOT / "scripts" / "vllm-stats-record.py")
heatmap = load_module("vllm_stats_heatmap", ROOT / "scripts" / "vllm-stats-heatmap.py")


class ParseCountersTest(unittest.TestCase):
    def test_parses_vllm_counters_per_model_and_sums_label_variants(self):
        parsed = record.parse_counters(
            """
# TYPE vllm:prompt_tokens_total counter
vllm:prompt_tokens_total{model_name="alpha",worker="0"} 100
vllm:prompt_tokens_total{model_name="alpha",worker="1"} 20
vllm:generation_tokens_total{model_name="alpha"} 30
vllm:request_success_total{finished_reason="stop",model_name="alpha"} 2
vllm:request_success_total{finished_reason="length",model_name="alpha"} 1
vllm:prompt_tokens_total{model_name="beta"} 50
vllm:generation_tokens_total{model_name="beta"} 10
vllm:request_success_total{model_name="beta"} 1
"""
        )
        self.assertEqual(
            parsed,
            (
                "vllm",
                {
                    "alpha": {"prompt": 120.0, "gen": 30.0, "req": 3.0},
                    "beta": {"prompt": 50.0, "gen": 10.0, "req": 1.0},
                },
            ),
        )

    def test_parses_sglang_streaming_counters_and_escaped_model_label(self):
        parsed = record.parse_counters(
            r'''
sglang:prompt_tokens_total{is_streaming="false",model_name="model\"one"} 100
sglang:prompt_tokens_total{is_streaming="true",model_name="model\"one"} 25
sglang:generation_tokens_total{is_streaming="false",model_name="model\"one"} 40
sglang:generation_tokens_total{is_streaming="true",model_name="model\"one"} 5
sglang:generation_tokens_histogram_count{model_name="model\"one"} 4
sglang:http_responses_total{endpoint="/metrics",status_code="200"} 999
'''
        )
        self.assertEqual(
            parsed,
            ("sglang", {'model"one': {"prompt": 125.0, "gen": 45.0, "req": 4.0}}),
        )

    def test_uses_explicit_unknown_model_bucket_when_label_is_absent(self):
        parsed = record.parse_counters(
            """
vllm:prompt_tokens_total 10
vllm:generation_tokens_total 5
vllm:request_success_total 1
"""
        )
        self.assertEqual(
            parsed,
            ("vllm", {record.UNKNOWN_MODEL: {"prompt": 10.0, "gen": 5.0, "req": 1.0}}),
        )

    def test_rejects_unknown_and_ambiguous_schemas(self):
        self.assertIsNone(record.parse_counters("other:counter 1\n"))
        both = """
vllm:prompt_tokens_total{} 1
vllm:generation_tokens_total{} 1
vllm:request_success_total{} 1
sglang:prompt_tokens_total{} 1
sglang:generation_tokens_total{} 1
sglang:generation_tokens_histogram_count{} 1
"""
        with self.assertRaisesRegex(ValueError, "ambiguous inference metric schemas"):
            record.parse_counters(both)


class CounterDeltaTest(unittest.TestCase):
    def entry(self, engine, models, observed_at=100):
        return record.state_entry(engine, models, observed_at)

    def test_partial_scrape_preserves_missing_endpoint_baseline(self):
        old_a = self.entry("vllm", {"a": {"prompt": 10, "gen": 5, "req": 2}})
        old_b = self.entry("sglang", {"b": {"prompt": 20, "gen": 8, "req": 3}})
        new_a = self.entry("vllm", {"a": {"prompt": 12, "gen": 6, "req": 3}}, 200)
        self.assertEqual(
            record.merge_endpoint_states({"a": old_a, "b": old_b}, {"a": new_a}),
            {"a": new_a, "b": old_b},
        )

    def test_same_engine_computes_per_model_deltas_and_resets(self):
        previous = self.entry(
            "sglang",
            {
                "alpha": {"prompt": 100, "gen": 50, "req": 10},
                "beta": {"prompt": 20, "gen": 8, "req": 2},
            },
        )
        current = self.entry(
            "sglang",
            {
                "alpha": {"prompt": 120, "gen": 5, "req": 12},
                "beta": {"prompt": 25, "gen": 10, "req": 3},
            },
            200,
        )
        deltas, resets, changed = record.counter_deltas(previous, current)
        self.assertEqual(deltas["alpha"], {"prompt": 20.0, "gen": 5.0, "req": 2.0})
        self.assertEqual(deltas["beta"], {"prompt": 5.0, "gen": 2.0, "req": 1.0})
        self.assertEqual(resets, [("alpha", "gen")])
        self.assertFalse(changed)

    def test_legacy_aggregate_baseline_is_assigned_to_sole_current_model(self):
        previous = self.entry(
            "sglang", {record.LEGACY_MODEL: {"prompt": 100, "gen": 50, "req": 10}}
        )
        current = self.entry("sglang", {"qwen": {"prompt": 120, "gen": 60, "req": 12}}, 200)
        deltas, resets, changed = record.counter_deltas(previous, current)
        self.assertEqual(deltas, {"qwen": {"prompt": 20.0, "gen": 10.0, "req": 2.0}})
        self.assertEqual(resets, [])
        self.assertFalse(changed)

    def test_legacy_aggregate_with_multiple_models_preserves_transition_delta(self):
        previous = self.entry(
            "vllm", {record.LEGACY_MODEL: {"prompt": 100, "gen": 50, "req": 10}}
        )
        current = self.entry(
            "vllm",
            {
                "alpha": {"prompt": 90, "gen": 40, "req": 7},
                "beta": {"prompt": 30, "gen": 20, "req": 5},
            },
            200,
        )
        deltas, resets, changed = record.counter_deltas(previous, current)
        self.assertEqual(
            deltas,
            {record.LEGACY_MODEL: {"prompt": 20.0, "gen": 10.0, "req": 2.0}},
        )
        self.assertEqual(resets, [])
        self.assertFalse(changed)

    def test_engine_switch_counts_current_models_from_zero(self):
        previous = self.entry("vllm", {"deepseek": {"prompt": 10, "gen": 5, "req": 2}})
        current = self.entry("sglang", {"qwen": {"prompt": 100, "gen": 40, "req": 4}}, 200)
        deltas, resets, changed = record.counter_deltas(previous, current)
        self.assertEqual(deltas, current["models"])
        self.assertEqual(resets, [])
        self.assertTrue(changed)

    def test_missing_model_baseline_and_observation_time_survive_successful_scrape(self):
        previous = self.entry(
            "sglang",
            {
                "alpha": {"prompt": 100, "gen": 50, "req": 10},
                "beta": {"prompt": 20, "gen": 8, "req": 2},
            },
            100,
        )
        current = self.entry(
            "sglang", {"alpha": {"prompt": 120, "gen": 60, "req": 12}}, 200
        )
        merged = record.merge_endpoint_states({"endpoint": previous}, {"endpoint": current})["endpoint"]
        self.assertIn("beta", merged["models"])
        self.assertEqual(merged["model_observed_at"]["beta"], 100)

        reappeared = self.entry(
            "sglang", {"beta": {"prompt": 25, "gen": 10, "req": 3}}, 300
        )
        deltas, _, _ = record.counter_deltas(merged, reappeared)
        self.assertEqual(deltas["beta"], {"prompt": 5.0, "gen": 2.0, "req": 1.0})
        self.assertEqual(record.model_elapsed(merged, reappeared, "beta", 300), 200)

    def test_interval_rows_use_actual_elapsed_time(self):
        current = self.entry("sglang", {"qwen": {"prompt": 900, "gen": 90, "req": 3}}, 1000)
        rows = record.interval_rows(
            1000, "when", "endpoint", current,
            {"qwen": {"prompt": 900, "gen": 90, "req": 3}}, 300,
        )
        self.assertEqual(rows[0][8], 300)
        self.assertEqual(rows[0][9], "3.000000")
        self.assertEqual(rows[0][10], "0.300000")


class CsvMigrationTest(unittest.TestCase):
    def test_migrates_legacy_rows_atomically_without_changing_totals(self):
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / "stats.csv"
            path.write_text(
                "ts,when,prompt_tokens,generation_tokens,requests\n"
                "100,old,1000,200,2\n"
                "200,new,3000,400,4\n"
            )
            self.assertTrue(record.migrate_csv_schema(str(path)))
            self.assertFalse(record.migrate_csv_schema(str(path)))
            with path.open(newline="") as stream:
                rows = list(csv.DictReader(stream))
            self.assertEqual({row["model"] for row in rows}, {record.LEGACY_MODEL})
            self.assertEqual(sum(int(row["prompt_tokens"]) for row in rows), 4000)
            self.assertEqual(sum(int(row["generation_tokens"]) for row in rows), 600)
            self.assertTrue(all(row["prompt_tokens_per_second"] == "" for row in rows))

    def test_heatmap_loader_accepts_unmigrated_legacy_file(self):
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / "stats.csv"
            path.write_text(
                "ts,when,prompt_tokens,generation_tokens,requests\n"
                "100,old,1000,200,2\n"
            )
            rows = heatmap.load(str(path))
            self.assertEqual(rows[0]["model"], heatmap.LEGACY_MODEL)
            self.assertIsNone(rows[0]["generation_rate"])


class TransactionTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.old_paths = (record.STATE, record.CSVFILE, record.PENDING)
        record.STATE = str(pathlib.Path(self.directory.name) / "state")
        record.CSVFILE = str(pathlib.Path(self.directory.name) / "stats.csv")
        record.PENDING = str(pathlib.Path(self.directory.name) / "pending.json")

    def tearDown(self):
        record.STATE, record.CSVFILE, record.PENDING = self.old_paths
        self.directory.cleanup()

    def rows(self):
        current = record.state_entry(
            "sglang",
            {
                "alpha": {"prompt": 10, "gen": 5, "req": 1},
                "beta": {"prompt": 20, "gen": 8, "req": 2},
            },
            100,
        )
        return current, record.interval_rows(100, "when", "endpoint", current, current["models"], None)

    def test_failed_csv_write_leaves_recoverable_multi_model_transaction(self):
        state, rows = self.rows()
        with mock.patch.object(record, "append_csv_rows_once", side_effect=OSError("disk full")):
            with self.assertRaisesRegex(OSError, "disk full"):
                record.commit_interval({"endpoint": state}, rows)
        self.assertTrue(pathlib.Path(record.PENDING).exists())
        self.assertFalse(pathlib.Path(record.STATE).exists())

        self.assertTrue(record.recover_pending_interval())
        self.assertEqual(record.load_state(), {"endpoint": state})
        with open(record.CSVFILE, newline="") as stream:
            written = list(csv.reader(stream))
        self.assertEqual(len(written), 3)

    def test_recovery_is_idempotent_when_all_rows_were_already_appended(self):
        state, rows = self.rows()
        payload = {"state": {"endpoint": state}, "rows": rows}
        record.append_csv_rows_once(rows)
        record.atomic_json_write(record.PENDING, payload)
        record.recover_pending_interval()
        with open(record.CSVFILE, newline="") as stream:
            written = list(csv.reader(stream))
        self.assertEqual(len(written), 3)


class RecorderIntegrationTest(unittest.TestCase):
    def test_existing_aggregate_baseline_becomes_one_model_without_double_counting(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            old_globals = (
                record.DIR, record.STATE, record.CSVFILE, record.PENDING, record.URLS,
            )
            try:
                record.DIR = directory
                record.STATE = str(root / "state")
                record.CSVFILE = str(root / "stats.csv")
                record.PENDING = str(root / "pending.json")
                record.URLS = ["endpoint"]
                pathlib.Path(record.CSVFILE).write_text(
                    "ts,when,prompt_tokens,generation_tokens,requests\n"
                    "1000,old,1000,200,2\n"
                )
                pathlib.Path(record.STATE).write_text(
                    json.dumps(
                        {
                            "endpoint": {
                                "engine": "sglang",
                                "counters": {"prompt": 100, "gen": 50, "req": 10},
                            }
                        }
                    )
                )
                current = (
                    "sglang",
                    {"qwen": {"prompt": 130.0, "gen": 65.0, "req": 12.0}},
                )
                with mock.patch.object(record, "scrape", return_value=current), mock.patch.object(
                    record.time, "time", return_value=1900
                ):
                    self.assertEqual(record.main(), 0)

                with open(record.CSVFILE, newline="") as stream:
                    rows = list(csv.DictReader(stream))
                self.assertEqual(rows[0]["model"], record.LEGACY_MODEL)
                self.assertEqual(rows[1]["model"], "qwen")
                self.assertEqual(rows[1]["prompt_tokens"], "30")
                self.assertEqual(rows[1]["generation_tokens"], "15")
                self.assertEqual(rows[1]["interval_seconds"], "900")
                self.assertEqual(rows[1]["generation_tokens_per_second"], "0.016667")
            finally:
                record.DIR, record.STATE, record.CSVFILE, record.PENDING, record.URLS = old_globals


class StateMigrationTest(unittest.TestCase):
    def test_migrates_earliest_flat_json_state_as_vllm(self):
        with tempfile.TemporaryDirectory() as directory:
            old_state = record.STATE
            try:
                record.STATE = str(pathlib.Path(directory) / "state")
                pathlib.Path(record.STATE).write_text(
                    json.dumps({record.DEFAULT_URL: {"prompt": 10, "gen": 5, "req": 2}})
                )
                state = record.load_state()[record.DEFAULT_URL]
                self.assertEqual(state["engine"], "vllm")
                self.assertEqual(state["models"][record.LEGACY_MODEL]["gen"], 5)
            finally:
                record.STATE = old_state

    def test_migrates_aggregate_json_state_without_losing_counters(self):
        with tempfile.TemporaryDirectory() as directory:
            old_state = record.STATE
            try:
                record.STATE = str(pathlib.Path(directory) / "state")
                pathlib.Path(record.STATE).write_text(
                    json.dumps(
                        {
                            record.DEFAULT_URL: {
                                "engine": "sglang",
                                "counters": {"prompt": 10, "gen": 5, "req": 2},
                            }
                        }
                    )
                )
                state = record.load_state()[record.DEFAULT_URL]
                self.assertEqual(state["engine"], "sglang")
                self.assertEqual(
                    state["models"],
                    {record.LEGACY_MODEL: {"prompt": 10.0, "gen": 5.0, "req": 2.0}},
                )
            finally:
                record.STATE = old_state


class HeatmapTest(unittest.TestCase):
    def sample_rows(self):
        now = int(time.time())
        return [
            {
                "ts": now - 900, "when": "2026-08-16 03:15:00", "model": heatmap.LEGACY_MODEL,
                "engine": "legacy", "endpoint": "legacy", "prompt": 1000.0,
                "generation": 200.0, "requests": 2.0, "interval": None,
                "prompt_rate": None, "generation_rate": None,
            },
            {
                "ts": now, "when": "2026-08-16 03:30:00", "model": "qwen3.8-27b",
                "engine": "sglang", "endpoint": "local", "prompt": 9000.0,
                "generation": 900.0, "requests": 4.0, "interval": 900.0,
                "prompt_rate": 10.0, "generation_rate": 1.0,
            },
            {
                "ts": now, "when": "2026-08-16 03:30:00", "model": "unsafe<script>",
                "engine": "vllm", "endpoint": "local-2", "prompt": 4500.0,
                "generation": 450.0, "requests": 3.0, "interval": 900.0,
                "prompt_rate": 5.0, "generation_rate": 0.5,
            },
        ]

    def test_aggregation_sums_models_and_latest_rates(self):
        summary = heatmap.aggregate(self.sample_rows())
        self.assertEqual(summary["total_prompt"], 14500)
        self.assertEqual(summary["total_generation"], 1550)
        self.assertEqual(summary["latest_prompt_rate"], 15)
        self.assertEqual(summary["latest_generation_rate"], 1.5)

    def test_page_has_model_selector_comparison_and_throughput_chart(self):
        with tempfile.TemporaryDirectory() as directory:
            output = pathlib.Path(directory) / "heatmap" / "index.html"
            summary = heatmap.render(self.sample_rows(), str(output))
            page = output.read_text()
            self.assertIn('aria-label="Filter statistics by model"', page)
            self.assertIn("All models", page)
            self.assertIn("qwen3.8-27b", page)
            self.assertIn("unsafe&lt;script&gt;", page)
            self.assertNotIn("unsafe<script>", page)
            self.assertIn("Model comparison", page)
            self.assertIn("Served throughput · 24 hours", page)
            self.assertIn("prompt-line", page)
            self.assertIn("generation-line", page)
            self.assertIn("including idle time", page)
            self.assertEqual(summary["total_gen"], 1550)
            self.assertEqual(summary["models"][-1], heatmap.LEGACY_MODEL)


if __name__ == "__main__":
    unittest.main()
