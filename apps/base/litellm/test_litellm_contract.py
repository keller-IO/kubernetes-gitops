import asyncio
import json
import os
import shutil
import sys
import tempfile
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

os.environ.setdefault("LITELLM_DONT_SHOW_FEEDBACK_BOX", "True")
os.environ.setdefault("LITELLM_LOCAL_MODEL_COST_MAP", "True")

from fastapi.testclient import TestClient
import litellm
from litellm.proxy.litellm_pre_call_utils import (
    _UNTRUSTED_METADATA_CONTROL_FIELDS,
    _UNTRUSTED_ROOT_CONTROL_FIELDS,
)
from litellm.proxy.proxy_server import app, initialize


MODEL = "hermes-blablador"
DEPLOYMENT_ID = "hermes-blablador"
WORK_DIR = Path(__file__).resolve().parent
EXPECTED_STRIPPED_ROOT_CONTROLS = frozenset(
    {
        "weights",
        "_router_weights",
        "proxy_server_request",
        "standard_logging_object",
        "secret_fields",
        "mock_response",
        "mock_tool_calls",
        "disable_global_guardrails",
        "disable_global_guardrail",
        "enable_prompt_caching",
        "opted_out_global_guardrails",
        "applied_guardrails",
        "applied_policies",
        "policy_sources",
        "guardrail_scan_ids",
        "guardrail_scan_metadata",
        "routing_decision",
        "litellm_gateway_injected_cache",
        "pillar_response_headers",
        "_guardrail_pipelines",
        "_pipeline_managed_guardrails",
        "callbacks",
        "service_callback",
        "logger_fn",
        "litellm_disabled_callbacks",
        "_agentic_loop_depth",
        "_agentic_loop_fingerprints",
        "_code_interpreter_interception_active",
        "_code_interpreter_interception_converted_stream",
        "_code_interpreter_interception_sandbox_key",
        "_code_interpreter_interception_session_scoped",
        "_headroom_interception_converted_stream",
        "max_agentic_loops",
        "client_side_timeout",
    }
)
EXPECTED_STRIPPED_METADATA_CONTROLS = frozenset(
    {
        "disable_global_guardrails",
        "disable_global_guardrail",
        "opted_out_global_guardrails",
        "pillar_response_headers",
        "_pillar_response_headers_trusted",
        "pillar_flagged",
        "pillar_scanners",
        "pillar_evidence",
        "pillar_evidence_truncated",
        "pillar_session_id_response",
        "applied_guardrails",
        "applied_policies",
        "policy_sources",
        "guardrail_scan_ids",
        "guardrail_scan_metadata",
        "routing_decision",
        "litellm_gateway_injected_cache",
        "_session_deployment_affinity_ttl",
        "_consumed_request_tags",
        "_routing_request_tags",
        "internal_call_origin",
        "standard_logging_object",
        "proxy_server_request",
        "secret_fields",
        "_guardrail_pipelines",
        "_pipeline_managed_guardrails",
        "client_disconnected",
        "error_information",
        "_pre_call_executed_guardrails",
    }
)


class StubState:
    def __init__(self):
        self._lock = threading.Lock()
        self.reset("success")

    def reset(self, scenario):
        with self._lock:
            self.scenario = scenario
            self.attempts = 0
            self.deployment_ids = []

    def record(self, deployment_id):
        with self._lock:
            self.attempts += 1
            self.deployment_ids.append(deployment_id)
            return self.scenario

    def snapshot(self):
        with self._lock:
            return self.attempts, tuple(self.deployment_ids)


class StubHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_POST(self):
        content_length = int(self.headers.get("content-length", "0"))
        self.rfile.read(content_length)
        scenario = self.server.state.record(self.headers.get("x-stub-deployment-id"))

        if scenario == "stream_failure":
            self.send_response(200)
            self.send_header("content-type", "text/event-stream")
            self.send_header("connection", "close")
            self.end_headers()
            chunk = {
                "id": "chatcmpl-stub",
                "object": "chat.completion.chunk",
                "created": 0,
                "model": "alias-code",
                "choices": [
                    {
                        "index": 0,
                        "delta": {"role": "assistant", "content": "synthetic"},
                        "finish_reason": None,
                    }
                ],
            }
            self.wfile.write(f"data: {json.dumps(chunk)}\n\n".encode())
            self.wfile.write(b"data: {invalid-json\n\n")
            self.wfile.flush()
            self.close_connection = True
            return

        if scenario == "success":
            status = 200
            payload = {
                "id": "chatcmpl-stub",
                "object": "chat.completion",
                "created": 0,
                "model": "alias-code",
                "choices": [
                    {
                        "index": 0,
                        "message": {"role": "assistant", "content": "synthetic"},
                        "finish_reason": "stop",
                    }
                ],
                "usage": {"prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2},
            }
        else:
            status = int(scenario)
            payload = {
                "error": {
                    "message": "controlled upstream failure",
                    "type": "controlled_error",
                    "param": None,
                    "code": str(status),
                }
            }

        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(body)))
        self.send_header("connection", "close")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, _format, *_args):
        return


class StubServer(ThreadingHTTPServer):
    def __init__(self):
        super().__init__(("127.0.0.1", 0), StubHandler)
        self.state = StubState()


class LiteLLMContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = StubServer()
        cls.server_thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.server_thread.start()

        cls.temp_dir = tempfile.TemporaryDirectory()
        cls.config_dir = Path(cls.temp_dir.name).resolve()
        for filename in ("request_policy.py", "request_policy_core.py"):
            shutil.copy(WORK_DIR / filename, cls.config_dir / filename)

        config_path = cls.config_dir / "config.yaml"
        config_path.write_text(
            f"""
model_list:
  - model_name: {MODEL}
    litellm_params:
      model: openai/alias-code
      api_base: http://127.0.0.1:{cls.server.server_port}/v1
      api_key: sk-test
      headers:
        x-stub-deployment-id: {DEPLOYMENT_ID}
    model_info:
      id: {DEPLOYMENT_ID}
      mode: chat
router_settings:
  num_retries: 0
  disable_cooldowns: true
litellm_settings:
  drop_params: false
  callbacks: request_policy.hermes_request_policy
""".lstrip()
        )

        sys.modules.pop("request_policy", None)
        sys.modules.pop("request_policy_core", None)
        sys.path = [entry for entry in sys.path if Path(entry or ".").resolve() != WORK_DIR]
        asyncio.run(initialize(config=str(config_path)))

        callbacks = [
            callback
            for callback in litellm.callbacks
            if callback.__class__.__name__ == "HermesRequestPolicy"
        ]
        if len(callbacks) != 1:
            raise AssertionError("request policy callback did not load exactly once")
        cls.callback = callbacks[0]
        cls.callback_path = Path(
            cls.callback.__class__.async_pre_call_hook.__code__.co_filename
        ).resolve()
        cls.client = TestClient(app, raise_server_exceptions=False)

    @classmethod
    def tearDownClass(cls):
        if hasattr(cls, "client"):
            cls.client.close()
        if hasattr(cls, "server"):
            cls.server.shutdown()
            cls.server.server_close()
            cls.server_thread.join(timeout=5)
        if hasattr(cls, "temp_dir"):
            cls.temp_dir.cleanup()

    def setUp(self):
        self.server.state.reset("success")

    def request_body(self, **parameters):
        return {
            "model": MODEL,
            "messages": [{"role": "user", "content": "synthetic"}],
            **parameters,
        }

    def assert_single_attempt(self):
        attempts, deployment_ids = self.server.state.snapshot()
        self.assertEqual(attempts, 1)
        self.assertEqual(deployment_ids, (DEPLOYMENT_ID,))

    def test_callback_loads_from_config_directory_and_returns_http_400(self):
        self.assertEqual(self.callback_path.parent, self.config_dir)

        response = self.client.post(
            "/v1/chat/completions",
            json=self.request_body(frequency_penalty=0),
        )

        self.assertEqual(response.status_code, 400)
        self.assertEqual(self.server.state.snapshot()[0], 0)

        response = self.client.post(
            "/v1/chat/completions",
            headers={"X-LiteLLM-Num-Retries": "1"},
            json=self.request_body(),
        )

        self.assertEqual(response.status_code, 400)
        self.assertEqual(self.server.state.snapshot()[0], 0)

    def test_proxy_snapshot_matches_pinned_injected_fields(self):
        original = self.callback.async_pre_call_hook
        captured = {}

        async def capture_fields(user_api_key_dict, cache, data, call_type):
            proxy_request = data["proxy_server_request"]
            body = proxy_request["body"]
            captured["proxy_fields"] = frozenset(proxy_request)
            captured["body_fields"] = frozenset(body)
            return await original(user_api_key_dict, cache, data, call_type)

        self.callback.async_pre_call_hook = capture_fields
        self.addCleanup(setattr, self.callback, "async_pre_call_hook", original)

        response = self.client.post("/v1/chat/completions", json=self.request_body())

        self.assertEqual(response.status_code, 200)
        self.assertEqual(
            captured["proxy_fields"],
            frozenset({"url", "method", "headers", "body", "credential_fields", "arrival_time"}),
        )
        self.assertEqual(captured["body_fields"], frozenset({"model", "messages", "metadata"}))
        self.assert_single_attempt()

    def test_stripped_control_fields_are_ineffective(self):
        self.assertEqual(
            frozenset(_UNTRUSTED_ROOT_CONTROL_FIELDS),
            EXPECTED_STRIPPED_ROOT_CONTROLS,
        )
        self.assertEqual(
            frozenset(_UNTRUSTED_METADATA_CONTROL_FIELDS),
            EXPECTED_STRIPPED_METADATA_CONTROLS,
        )

        original = self.callback.async_pre_call_hook
        captured = []

        async def capture_fields(user_api_key_dict, cache, data, call_type):
            body = data["proxy_server_request"]["body"]
            metadata = body.get("metadata", {})
            captured.append(
                (
                    frozenset(body),
                    frozenset(
                        key
                        for key, value in metadata.items()
                        if value == "client-controlled"
                    ),
                )
            )
            return await original(user_api_key_dict, cache, data, call_type)

        self.callback.async_pre_call_hook = capture_fields
        self.addCleanup(setattr, self.callback, "async_pre_call_hook", original)

        for field in sorted(EXPECTED_STRIPPED_ROOT_CONTROLS):
            with self.subTest(location="root", field=field):
                self.server.state.reset("success")
                before = len(captured)
                value = (
                    ["HermesRequestPolicy"]
                    if field == "litellm_disabled_callbacks"
                    else "client-controlled"
                )
                response = self.client.post(
                    "/v1/chat/completions",
                    json=self.request_body(**{field: value}),
                )
                self.assertEqual(response.status_code, 200)
                self.assertEqual(len(captured), before + 1)
                self.assertNotIn(field, captured[-1][0])
                self.assert_single_attempt()

        for field in sorted(EXPECTED_STRIPPED_METADATA_CONTROLS):
            with self.subTest(location="metadata", field=field):
                self.server.state.reset("success")
                before = len(captured)
                response = self.client.post(
                    "/v1/chat/completions",
                    json=self.request_body(metadata={field: "client-controlled"}),
                )
                self.assertEqual(response.status_code, 200)
                self.assertEqual(len(captured), before + 1)
                self.assertNotIn(field, captured[-1][1])
                self.assert_single_attempt()

    def test_success_calls_blablador_once(self):
        response = self.client.post("/v1/chat/completions", json=self.request_body())

        self.assertEqual(response.status_code, 200)
        self.assert_single_attempt()

    def test_400_401_429_and_5xx_each_call_blablador_once(self):
        for status in (400, 401, 429, 500):
            with self.subTest(status=status):
                self.server.state.reset(status)
                self.client.post("/v1/chat/completions", json=self.request_body())
                self.assert_single_attempt()

    def test_upstream_http_status_class_is_preserved(self):
        for status in (400, 401, 429, 500):
            with self.subTest(status=status):
                self.server.state.reset(status)
                response = self.client.post("/v1/chat/completions", json=self.request_body())
                self.assertEqual(response.status_code // 100, status // 100)
                self.assert_single_attempt()

    def test_stream_does_not_retry_after_first_chunk(self):
        self.server.state.reset("stream_failure")
        data_events = []

        with self.client.stream(
            "POST",
            "/v1/chat/completions",
            json=self.request_body(stream=True),
        ) as response:
            self.assertEqual(response.status_code, 200)
            try:
                for line in response.iter_lines():
                    if line.startswith("data:"):
                        raw_event = line.removeprefix("data:").strip()
                        if raw_event != "[DONE]":
                            try:
                                data_events.append(json.loads(raw_event))
                            except json.JSONDecodeError:
                                continue
            except Exception:
                pass

        self.assertTrue(
            any(
                event.get("choices", [{}])[0].get("delta", {}).get("content") == "synthetic"
                for event in data_events
            )
        )
        self.assert_single_attempt()


if __name__ == "__main__":
    unittest.main(verbosity=2)
