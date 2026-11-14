#!/usr/bin/env python3
"""Unit tests for the Hyperflare metrics bridge's functional core.

No network, no engine, no GPU. The cross-module test feeds the bridge's own
exposition through the ledger recorder's parser, so the two stay one contract.
"""

import http.server
import importlib.util
import json
import tempfile
import threading
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
SHARED = ROOT / "scripts" / "inference" / "shared"


def load_module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


bridge = load_module("hyperflare_metrics", SHARED / "hyperflare-metrics.py")
record = load_module("vllm_stats_record", SHARED / "vllm-stats-record.py")

# Shape of a real `flare run` exposition: labelled families interleaved with
# the unlabelled scalars the bridge reads (names from helios/src/server/metrics.rs
# at hyperflare-glm-20261112).
FLARE = """\
# HELP flare_host_cache_held_total Records held because the next tier could not accept them.
# TYPE flare_host_cache_held_total counter
flare_host_cache_held_total{tier="dram"} 0
flare_speculative_rounds_total{batch="1",width="6"} 40
flare_speculative_drafts_total{depth="1",source="mtp",outcome="accepted"} 31
flare_http_requests_total{api="chat"} 12
flare_prefill_tokens_total 9000
flare_cache_reused_tokens_total 4000
flare_host_cache_reused_tokens_total 1000
flare_generated_tokens_total 2500
flare_requests_completed_total 10
flare_requests_failed_total 1
flare_requests_cancelled_total 2
flare_active_requests 3
flare_pending_requests 1
flare_free_kv_pages 300
flare_total_kv_pages 400
flare_accepted_draft_tokens_total 1200
flare_verification_draft_tokens_total 2000
flare_draft_request_rounds_total 800
flare_verification_request_rounds_total 900
flare_first_response_median_seconds 0.48
"""

MODELS = {"object": "list", "data": [{"id": "glm-5.3-flash-hyperflare-tp2-v16", "object": "model"}]}


def series(text):
    """{name: (labels, value)} for the bridge's single-model exposition."""
    out = {}
    for line in text.splitlines():
        if line and not line.startswith("#"):
            parsed = record.parse_sample(line)
            if parsed:
                out[parsed[0]] = (parsed[1], parsed[2])
    return out


class ParseFlareTest(unittest.TestCase):
    def test_parses_every_required_scalar_and_ignores_labelled_families(self):
        counters = bridge.parse_flare(FLARE)
        self.assertIsInstance(counters, bridge.FlareCounters)
        self.assertEqual(counters.prefilled, 9000)
        self.assertEqual(counters.gpu_reused, 4000)
        self.assertEqual(counters.host_reused, 1000)
        self.assertEqual(counters.verify_rounds, 900)
        self.assertEqual(counters.first_response_median, 0.48)

    def test_other_runtimes_on_port_8000_are_not_hyperflare(self):
        vllm = 'vllm:prompt_tokens_total{model_name="x"} 1\nvllm:generation_tokens_total{model_name="x"} 1\n'
        result = bridge.parse_flare(vllm)
        self.assertIsInstance(result, bridge.NotHyperflare)
        self.assertIn("flare_prefill_tokens_total", result.reason)

    def test_a_labelled_series_never_stands_in_for_a_required_scalar(self):
        text = FLARE.replace("flare_generated_tokens_total 2500", 'flare_generated_tokens_total{rank="0"} 2500')
        self.assertIsInstance(bridge.parse_flare(text), bridge.NotHyperflare)

    def test_first_response_median_is_optional_before_any_sample(self):
        text = FLARE.replace("flare_first_response_median_seconds 0.48\n", "")
        counters = bridge.parse_flare(text)
        self.assertIsNone(counters.first_response_median)
        self.assertNotIn("hyperflare:first_response_median_seconds", series(bridge.render("m", counters)))

    def test_non_finite_values_are_not_numbers(self):
        text = FLARE.replace("flare_total_kv_pages 400", "flare_total_kv_pages NaN")
        self.assertIsInstance(bridge.parse_flare(text), bridge.NotHyperflare)


class ServedModelTest(unittest.TestCase):
    def test_first_model_id_is_served_model(self):
        self.assertEqual(bridge.served_model(MODELS), "glm-5.3-flash-hyperflare-tp2-v16")

    def test_missing_or_empty_model_list_is_rejected(self):
        for body in ({}, {"data": []}, {"data": [{"id": "  "}]}, {"data": ["x"]}, []):
            self.assertIsInstance(bridge.served_model(body), bridge.NotHyperflare, body)


class RenderTest(unittest.TestCase):
    def setUp(self):
        self.out = series(bridge.render("glm-5.3-flash-hyperflare-tp2-v16", bridge.parse_flare(FLARE)))

    def test_every_series_carries_the_served_model(self):
        for name, (labels, _) in self.out.items():
            self.assertEqual(labels, {"model_name": "glm-5.3-flash-hyperflare-tp2-v16"}, name)

    def test_prompt_tokens_count_prefix_reuse_like_vllm(self):
        self.assertEqual(self.out["hyperflare:prompt_tokens_total"][1], 9000 + 4000 + 1000)
        self.assertEqual(self.out["hyperflare:prompt_tokens_prefilled_total"][1], 9000)
        self.assertEqual(self.out["hyperflare:prompt_tokens_cached_total"][1], 5000)

    def test_kv_usage_is_used_share_of_the_pool(self):
        self.assertEqual(self.out["hyperflare:kv_pages_used"][1], 100)
        self.assertEqual(self.out["hyperflare:kv_cache_usage_ratio"][1], 0.25)

    def test_empty_pool_reports_zero_usage_not_a_division_error(self):
        text = FLARE.replace("flare_total_kv_pages 400", "flare_total_kv_pages 0").replace(
            "flare_free_kv_pages 300", "flare_free_kv_pages 0")
        out = series(bridge.render("m", bridge.parse_flare(text)))
        self.assertEqual(out["hyperflare:kv_cache_usage_ratio"][1], 0)

    def test_speculative_and_request_counters_pass_through(self):
        self.assertEqual(self.out["hyperflare:spec_accepted_tokens_total"][1], 1200)
        self.assertEqual(self.out["hyperflare:spec_draft_rounds_total"][1], 800)
        self.assertEqual(self.out["hyperflare:requests_total"][1], 10)
        self.assertEqual(self.out["hyperflare:requests_running"][1], 3)
        self.assertEqual(self.out["hyperflare:first_response_median_seconds"][1], 0.48)

    def test_model_label_is_escaped(self):
        text = bridge.render('a"b\\c', bridge.parse_flare(FLARE))
        self.assertIn('model_name="a\\"b\\\\c"', text)
        self.assertEqual(series(text)["hyperflare:model_info"][0]["model_name"], 'a"b\\c')


class LedgerContractTest(unittest.TestCase):
    def test_recorder_reads_the_bridge_as_one_hyperflare_model(self):
        exposition = bridge.render("glm-5.3-flash-hyperflare-tp2-v16", bridge.parse_flare(FLARE))
        engine, models = record.parse_counters(exposition)
        self.assertEqual(engine, "hyperflare")
        self.assertEqual(
            models,
            {"glm-5.3-flash-hyperflare-tp2-v16": {"prompt": 14000.0, "gen": 2500.0, "req": 10.0}},
        )

    def test_raw_flare_exposition_is_not_a_ledger_schema(self):
        # :8000 itself must not be double-counted alongside the bridge on :8011.
        self.assertIsNone(record.parse_counters(FLARE))


class StubEngine:
    """A throwaway HTTP server standing in for whatever owns :8000."""

    def __init__(self, routes):
        self.routes = routes  # path -> (status, body); missing path -> 404
        self.seen = []
        stub = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):  # noqa: N802
                stub.seen.append((self.path, self.headers.get("Authorization")))
                status, body = stub.routes.get(self.path, (404, ""))
                payload = body.encode()
                self.send_response(status)
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)

            def log_message(self, *args):
                pass

        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.url = f"http://127.0.0.1:{self.server.server_address[1]}"
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def close(self):
        self.server.shutdown()
        self.server.server_close()


class SourceShellTest(unittest.TestCase):
    """The 503 mapping the recorder and the switcher rely on."""

    def setUp(self):
        self.key = tempfile.NamedTemporaryFile("w", delete=False)
        self.key.write("secret-key\n")
        self.key.close()

    def tearDown(self):
        pathlib.Path(self.key.name).unlink()

    def scrape(self, routes):
        engine = StubEngine(routes)
        try:
            return bridge.Source(engine.url, pathlib.Path(self.key.name)).scrape(), engine.seen
        finally:
            engine.close()

    def test_hyperflare_engine_is_translated_and_only_models_is_authenticated(self):
        (status, body), seen = self.scrape({"/metrics": (200, FLARE), "/v1/models": (200, json.dumps(MODELS))})
        self.assertEqual(status, 200)
        self.assertIn('hyperflare:model_info{model_name="glm-5.3-flash-hyperflare-tp2-v16"} 1', body)
        self.assertEqual(dict(seen), {"/metrics": None, "/v1/models": "Bearer secret-key"})

    def test_another_runtime_on_8000_is_503_without_sending_the_key(self):
        (status, body), seen = self.scrape({"/metrics": (200, 'vllm:prompt_tokens_total{model_name="q"} 1\n')})
        self.assertEqual(status, 503)
        self.assertIn("not a Hyperflare server", body)
        self.assertEqual([path for path, _ in seen], ["/metrics"])

    def test_rejected_key_and_bad_models_body_are_503(self):
        for models in [(401, "unauthorized"), (200, "not json"), (200, json.dumps({"data": []}))]:
            (status, body), _ = self.scrape({"/metrics": (200, FLARE), "/v1/models": models})
            self.assertEqual(status, 503, models)
            self.assertTrue(body.startswith("# hyperflare bridge:"), body)

    def test_unreachable_engine_is_503(self):
        engine = StubEngine({})
        url = engine.url
        engine.close()
        status, body = bridge.Source(url, pathlib.Path(self.key.name)).scrape()
        self.assertEqual(status, 503)
        self.assertIn("URLError", body)

    def test_log_state_distinguishes_503_reasons(self):
        self.assertNotEqual(
            bridge.log_state(503, "# hyperflare bridge: URLError: refused\n"),
            bridge.log_state(503, "# hyperflare bridge: HTTPError: HTTP Error 401\n"),
        )
        self.assertEqual(bridge.log_state(200, "a"), bridge.log_state(200, "b"))


if __name__ == "__main__":
    unittest.main()
