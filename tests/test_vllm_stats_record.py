#!/usr/bin/env python3
"""Unit tests for the runtime-neutral inference token ledger."""

import importlib.util
import json
import pathlib
import tempfile
import unittest
from unittest import mock


ROOT = pathlib.Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "vllm_stats_record", ROOT / "scripts" / "vllm-stats-record.py"
)
record = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(record)

HEATMAP_SPEC = importlib.util.spec_from_file_location(
    "vllm_stats_heatmap", ROOT / "scripts" / "vllm-stats-heatmap.py"
)
heatmap = importlib.util.module_from_spec(HEATMAP_SPEC)
HEATMAP_SPEC.loader.exec_module(heatmap)


class ParseCountersTest(unittest.TestCase):
    def test_parses_and_sums_vllm_counter_labels(self):
        parsed = record.parse_counters(
            """
# TYPE vllm:prompt_tokens_total counter
vllm:prompt_tokens_total{model_name="model",worker="0"} 100
vllm:prompt_tokens_total{model_name="model",worker="1"} 20
vllm:generation_tokens_total{model_name="model"} 30
vllm:request_success_total{finished_reason="stop",model_name="model"} 2
vllm:request_success_total{finished_reason="length",model_name="model"} 1
"""
        )
        self.assertEqual(parsed, ("vllm", {"prompt": 120.0, "gen": 30.0, "req": 3.0}))

    def test_parses_sglang_streaming_counters_and_completed_generations(self):
        parsed = record.parse_counters(
            """
sglang:prompt_tokens_total{is_streaming="false",model_name="model"} 100
sglang:prompt_tokens_total{is_streaming="true",model_name="model"} 25
sglang:generation_tokens_total{is_streaming="false",model_name="model"} 40
sglang:generation_tokens_total{is_streaming="true",model_name="model"} 5
sglang:generation_tokens_histogram_count{model_name="model"} 4
sglang:http_responses_total{endpoint="/metrics",status_code="200"} 999
"""
        )
        self.assertEqual(parsed, ("sglang", {"prompt": 125.0, "gen": 45.0, "req": 4.0}))

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
    def test_partial_scrape_preserves_missing_endpoint_baseline(self):
        old_a = record.state_entry("vllm", {"prompt": 10, "gen": 5, "req": 2})
        old_b = record.state_entry("sglang", {"prompt": 20, "gen": 8, "req": 3})
        new_a = record.state_entry("vllm", {"prompt": 12, "gen": 6, "req": 3})
        merged = record.merge_endpoint_states({"a": old_a, "b": old_b}, {"a": new_a})
        self.assertEqual(merged, {"a": new_a, "b": old_b})

    def test_same_engine_uses_deltas_and_detects_resets(self):
        previous = record.state_entry("sglang", {"prompt": 100, "gen": 50, "req": 10})
        current = record.state_entry("sglang", {"prompt": 120, "gen": 5, "req": 12})
        deltas, resets, changed = record.counter_deltas(previous, current)
        self.assertEqual(deltas, {"prompt": 20, "gen": 5, "req": 2})
        self.assertEqual(resets, ["gen"])
        self.assertFalse(changed)

    def test_engine_switch_counts_new_namespace_from_zero(self):
        previous = record.state_entry("vllm", {"prompt": 1, "gen": 1, "req": 1})
        current = record.state_entry("sglang", {"prompt": 100, "gen": 40, "req": 4})
        deltas, resets, changed = record.counter_deltas(previous, current)
        self.assertEqual(deltas, current["counters"])
        self.assertEqual(resets, [])
        self.assertTrue(changed)


class HeatmapTest(unittest.TestCase):
    def test_page_names_all_engines_and_discloses_last_ledger_record(self):
        with tempfile.TemporaryDirectory() as directory:
            old_dir = heatmap.DIR
            try:
                heatmap.DIR = directory
                stats = pathlib.Path(directory) / "stats.csv"
                stats.write_text(
                    "ts,when,prompt_tokens,generation_tokens,requests\n"
                    "1700000000,2023-11-14 22:13:20,100,20,2\n"
                )
                output = pathlib.Path(directory) / "heatmap" / "index.html"
                heatmap.render(heatmap.load(str(stats)), str(output))
                page = output.read_text()
                self.assertIn("Local inference token usage", page)
                self.assertIn("all engines and models", page)
                self.assertIn("ledger last recorded 2023-11-14 22:13:20", page)
                self.assertIn("detects vLLM and SGLang", page)
            finally:
                heatmap.DIR = old_dir


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

    def test_failed_csv_write_leaves_recoverable_transaction_and_does_not_advance_state(self):
        state = {"endpoint": record.state_entry("sglang", {"prompt": 10, "gen": 5, "req": 1})}
        row = [1700000000, "when", "10", "5", "1"]
        with mock.patch.object(record, "append_csv_row_once", side_effect=OSError("disk full")):
            with self.assertRaisesRegex(OSError, "disk full"):
                record.commit_interval(state, row)
        self.assertTrue(pathlib.Path(record.PENDING).exists())
        self.assertFalse(pathlib.Path(record.STATE).exists())

        self.assertTrue(record.recover_pending_interval())
        self.assertEqual(record.load_state(), state)
        with open(record.CSVFILE, newline="") as f:
            rows = list(record.csv.reader(f))
        self.assertEqual(rows.count([str(value) for value in row]), 1)

    def test_recovery_is_idempotent_when_csv_row_was_already_appended(self):
        state = {"endpoint": record.state_entry("sglang", {"prompt": 10, "gen": 5, "req": 1})}
        row = [1700000000, "when", "10", "5", "1"]
        payload = {"state": state, "row": row}
        record.append_csv_row_once(row)
        record.atomic_json_write(record.PENDING, payload)
        record.recover_pending_interval()
        with open(record.CSVFILE, newline="") as f:
            rows = list(record.csv.reader(f))
        self.assertEqual(rows.count([str(value) for value in row]), 1)


class StateMigrationTest(unittest.TestCase):
    def test_migrates_legacy_json_state_as_vllm(self):
        with tempfile.TemporaryDirectory() as directory:
            old_state = record.STATE
            try:
                record.STATE = str(pathlib.Path(directory) / "state")
                pathlib.Path(record.STATE).write_text(
                    json.dumps({record.DEFAULT_URL: {"prompt": 10, "gen": 5, "req": 2}})
                )
                self.assertEqual(
                    record.load_state(),
                    {
                        record.DEFAULT_URL: record.state_entry(
                            "vllm", {"prompt": 10, "gen": 5, "req": 2}
                        )
                    },
                )
            finally:
                record.STATE = old_state


if __name__ == "__main__":
    unittest.main()
