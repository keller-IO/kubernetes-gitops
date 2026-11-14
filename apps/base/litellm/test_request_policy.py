import asyncio
import copy
import importlib
import inspect
import shutil
import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest.mock import patch

from request_policy_core import PolicyViolation, validate_proxy_request



class FakeCustomLogger:
    enforces_request_content = False


class FakeHTTPException(Exception):
    def __init__(self, status_code, detail):
        self.status_code = status_code
        self.detail = detail
        super().__init__(detail)


def fake_dependency_modules():
    litellm = types.ModuleType("litellm")
    integrations = types.ModuleType("litellm.integrations")
    custom_logger = types.ModuleType("litellm.integrations.custom_logger")
    custom_logger.CustomLogger = FakeCustomLogger
    fastapi = types.ModuleType("fastapi")
    fastapi.HTTPException = FakeHTTPException
    return {
        "litellm": litellm,
        "litellm.integrations": integrations,
        "litellm.integrations.custom_logger": custom_logger,
        "fastapi": fastapi,
    }


def load_adapter():
    sys.modules.pop("request_policy", None)
    with patch.dict(sys.modules, fake_dependency_modules()):
        return importlib.import_module("request_policy")


def load_adapter_file(path):
    spec = importlib.util.spec_from_file_location("isolated_request_policy", path)
    module = importlib.util.module_from_spec(spec)
    cached_core = sys.modules.pop("request_policy_core", None)
    try:
        with patch.dict(sys.modules, fake_dependency_modules()):
            spec.loader.exec_module(module)
    finally:
        if cached_core is not None:
            sys.modules["request_policy_core"] = cached_core
    return module


def proxy_data(body, headers=None):
    return {
        "proxy_server_request": {
            "url": "http://testserver/v1/chat/completions",
            "method": "POST",
            "headers": {"content-type": "application/json"} if headers is None else headers,
            "body": body,
            "credential_fields": (),
            "arrival_time": 0.0,
        }
    }


def embedding_data(body, headers=None):
    data = proxy_data(body, headers)
    data["proxy_server_request"]["url"] = "http://testserver/v1/embeddings"
    return data


class EmbeddingPolicyTests(unittest.TestCase):
    MODEL = "paperless-saia-embedding"
    CALL_TYPE = "aembedding"

    def assert_rejected_without_mutation(self, data, field, call_type=None):
        original = copy.deepcopy(data)

        with self.assertRaises(PolicyViolation) as raised:
            validate_proxy_request(data, self.CALL_TYPE if call_type is None else call_type)

        self.assertIn(field, str(raised.exception))
        self.assertEqual(data, original)

    def test_accepts_exact_embedding_request_for_every_embedding_call_type(self):
        # Mutation caught: rejecting what the llama-index OpenAI client sends or rewriting it.
        for call_type in ("embeddings", "aembedding", "embedding"):
            for body in (
                {"model": self.MODEL, "input": ["a", "b"], "encoding_format": "base64"},
                {"model": self.MODEL, "input": "a", "encoding_format": "float"},
                {"model": self.MODEL, "input": ["a"], "metadata": {}},
            ):
                with self.subTest(call_type=call_type, body=body):
                    data = embedding_data(body)
                    original = copy.deepcopy(data)

                    self.assertIsNone(validate_proxy_request(data, call_type))
                    self.assertEqual(data, original)

    def test_embedding_route_rejects_chat_and_unlisted_models(self):
        # Mutation caught: sharing one model set between chat and embeddings.
        for model in ("hermes-blablador", "hermes-saia-qwen-coder", "qwen3-embedding-4b", "", None, 1):
            with self.subTest(model=model):
                self.assert_rejected_without_mutation(
                    embedding_data({"model": model, "input": ["a"]}), "model"
                )

    def test_chat_route_rejects_embedding_model_for_every_other_call_type(self):
        # Mutation caught: treating an unknown call type as an embedding call.
        body = {"model": self.MODEL, "messages": [{"role": "user", "content": "x"}]}
        for call_type in (None, "acompletion", "completion", "text_completion", "moderation", 1):
            with self.subTest(call_type=call_type):
                data = proxy_data(body)
                original = copy.deepcopy(data)
                with self.assertRaises(PolicyViolation) as raised:
                    validate_proxy_request(data, call_type)
                self.assertIn("model", str(raised.exception))
                self.assertEqual(data, original)

    def test_embedding_body_without_messages_is_rejected_on_chat_route(self):
        data = proxy_data({"model": "hermes-blablador", "input": ["a"]})
        with self.assertRaises(PolicyViolation):
            validate_proxy_request(data, "acompletion")

    def test_rejects_malformed_or_oversized_input(self):
        for value in (None, "", [], [""], ["a", 1], [["a"]], {"a": 1}, 1, ["a"] * 129):
            with self.subTest(value=value if not isinstance(value, list) else len(value)):
                self.assert_rejected_without_mutation(
                    embedding_data({"model": self.MODEL, "input": value}), "input"
                )

        data = embedding_data({"model": self.MODEL, "input": ["a"] * 128})
        self.assertIsNone(validate_proxy_request(data, self.CALL_TYPE))

    def test_rejects_unknown_encoding_format(self):
        for value in ("binary", "", None, 1, ["float"]):
            with self.subTest(value=value):
                self.assert_rejected_without_mutation(
                    embedding_data(
                        {"model": self.MODEL, "input": ["a"], "encoding_format": value}
                    ),
                    "encoding_format",
                )

    def test_rejects_chat_parameters_provider_parameters_and_controls(self):
        # Mutation caught: reusing the chat allowlist or dropping the control denylist.
        for field in (
            "messages",
            "temperature",
            "max_tokens",
            "stream",
            "tools",
            "dimensions",
            "user",
            "input_type",
            "extra_body",
            "fallbacks",
            "api_base",
            "timeout",
            "num_retries",
            "drop_params",
        ):
            with self.subTest(field=field):
                self.assert_rejected_without_mutation(
                    embedding_data({"model": self.MODEL, "input": ["a"], field: 1}), field
                )

    def test_rejects_x_litellm_control_header(self):
        self.assert_rejected_without_mutation(
            embedding_data(
                {"model": self.MODEL, "input": ["a"]},
                headers={"X-LiteLLM-Timeout": "1"},
            ),
            "X-LiteLLM-Timeout",
        )

    def test_missing_or_malformed_proxy_snapshot_fails_closed(self):
        for data in ({}, {"proxy_server_request": None}, {"proxy_server_request": {"body": None, "headers": {}}}):
            with self.subTest(data=data):
                with self.assertRaises(PolicyViolation):
                    validate_proxy_request(data, self.CALL_TYPE)

    def test_adapter_passes_call_type_to_the_core(self):
        # Mutation caught: the adapter dropping call_type, which would apply chat rules to embeddings.
        adapter = load_adapter()
        policy = adapter.HermesRequestPolicy()
        data = embedding_data({"model": self.MODEL, "input": ["a"], "encoding_format": "base64"})

        result = asyncio.run(policy.async_pre_call_hook(None, None, data, "aembedding"))
        self.assertIs(result, data)

        with self.assertRaises(FakeHTTPException) as raised:
            asyncio.run(policy.async_pre_call_hook(None, None, data, "acompletion"))
        self.assertEqual(raised.exception.status_code, 400)


class RequestPolicyTests(unittest.TestCase):
    MODEL = "hermes-blablador"

    def assert_rejected_without_mutation(self, data, field):
        original = copy.deepcopy(data)

        with self.assertRaises(PolicyViolation) as raised:
            validate_proxy_request(data)

        self.assertIn(field, str(raised.exception))
        self.assertEqual(data, original)

    def test_accepts_exact_model_messages_and_common_parameters(self):
        # Mutation caught: omitting a verified common parameter or rewriting accepted request data.
        data = proxy_data(
            {
                "model": self.MODEL,
                "messages": [{"role": "user", "content": "synthetic"}],
                "temperature": 0,
                "max_tokens": 64,
                "stream": False,
                "tools": [],
                "tool_choice": "auto",
            }
        )
        original = copy.deepcopy(data)

        self.assertIsNone(validate_proxy_request(data))
        self.assertEqual(data, original)

    def test_accepts_only_hermes_usage_stream_options(self):
        # Mutation caught: rejecting Hermes' usage stream extension or allowing it to carry controls.
        data = proxy_data(
            {
                "model": self.MODEL,
                "messages": [],
                "stream": True,
                "stream_options": {"include_usage": True},
            }
        )
        original = copy.deepcopy(data)

        self.assertIsNone(validate_proxy_request(data))
        self.assertEqual(data, original)

        invalid_values = (
            {"include_usage": False},
            {"include_usage": True, "extra": True},
            {},
            True,
            {"include_usage": 1},
            {"include_usage": 1.0},
        )
        for value in invalid_values:
            with self.subTest(value=value):
                invalid = proxy_data(
                    {
                        "model": self.MODEL,
                        "messages": [],
                        "stream": True,
                        "stream_options": value,
                    }
                )
                self.assert_rejected_without_mutation(invalid, "stream_options")

        non_streaming = proxy_data(
            {
                "model": self.MODEL,
                "messages": [],
                "stream": False,
                "stream_options": {"include_usage": True},
            }
        )
        self.assert_rejected_without_mutation(non_streaming, "stream_options")

    def test_rejects_other_model_or_missing_messages(self):
        # Mutation caught: accepting a different route target or a body without list-valued messages.
        cases = (
            ("other model", {"model": "other-model", "messages": []}, "model"),
            ("upstream Blablador name", {"model": "alias-code", "messages": []}, "model"),
            ("upstream SAIA name", {"model": "qwen3-coder-next", "messages": []}, "model"),
            ("other SAIA model", {"model": "glm-5.3", "messages": []}, "model"),
            ("missing model", {"messages": []}, "model"),
            ("unhashable model", {"model": ["hermes-blablador"], "messages": []}, "model"),
            ("missing messages", {"model": self.MODEL}, "messages"),
            ("malformed messages", {"model": self.MODEL, "messages": {}}, "messages"),
        )

        for name, body, field in cases:
            with self.subTest(name=name):
                self.assert_rejected_without_mutation(proxy_data(body), field)

    def test_rejects_unknown_provider_parameter(self):
        # Mutation caught: forwarding a provider parameter outside the empirically verified allowlist.
        data = proxy_data(
            {
                "model": self.MODEL,
                "messages": [],
                "frequency_penalty": "provider-value-must-not-leak",
            }
        )

        self.assert_rejected_without_mutation(data, "frequency_penalty")
        with self.assertRaises(PolicyViolation) as raised:
            validate_proxy_request(data)
        self.assertNotIn("provider-value-must-not-leak", str(raised.exception))

    def test_rejects_reasoning_effort_without_mutation(self):
        # Regression contract: Hermes must suppress this unverified field instead of proxying it.
        data = proxy_data(
            {
                "model": self.MODEL,
                "messages": [],
                "reasoning_effort": "provider-value-must-not-leak",
            }
        )

        self.assert_rejected_without_mutation(data, "reasoning_effort")
        with self.assertRaises(PolicyViolation) as raised:
            validate_proxy_request(data)
        self.assertNotIn("provider-value-must-not-leak", str(raised.exception))

    def test_rejects_extra_body_and_routing_retry_drop_timeout_controls(self):
        # Mutation caught: allowing a client to override LiteLLM routing, retry, drop, or timeout behavior.
        controls = (
            "extra_body",
            "fallbacks",
            "max_fallbacks",
            "router_settings_override",
            "num_retries",
            "drop_params",
            "additional_drop_params",
            "api_base",
            "user_config",
            "timeout",
            "request_timeout",
            "stream_timeout",
        )

        for control in controls:
            with self.subTest(control=control):
                data = proxy_data(
                    {
                        "model": self.MODEL,
                        "messages": [],
                        control: "control-value-must-not-leak",
                    }
                )
                self.assert_rejected_without_mutation(data, control)
                with self.assertRaises(PolicyViolation) as raised:
                    validate_proxy_request(data)
                self.assertNotIn("control-value-must-not-leak", str(raised.exception))

    def test_rejects_x_litellm_control_header_case_insensitively(self):
        # Mutation caught: checking the x-litellm prefix case-sensitively and allowing a casing bypass.
        for header in ("x-litellm-num-retries", "X-LiteLLM-Num-Retries", "x-LiTeLlM-drop-params"):
            with self.subTest(header=header):
                data = proxy_data(
                    {"model": self.MODEL, "messages": []},
                    headers={header: "header-value-must-not-leak"},
                )
                self.assert_rejected_without_mutation(data, header)
                with self.assertRaises(PolicyViolation) as raised:
                    validate_proxy_request(data)
                self.assertNotIn("header-value-must-not-leak", str(raised.exception))

    def test_missing_or_malformed_proxy_snapshot_fails_closed(self):
        # Mutation caught: treating an absent or malformed normalized proxy snapshot as trustworthy.
        cases = (
            ("missing request", {}, "proxy_server_request"),
            ("malformed request", {"proxy_server_request": []}, "proxy_server_request"),
            ("missing body", {"proxy_server_request": {"headers": {}}}, "proxy_server_request.body"),
            (
                "malformed body",
                {"proxy_server_request": {"headers": {}, "body": []}},
                "proxy_server_request.body",
            ),
            ("missing headers", {"proxy_server_request": {"body": {}}}, "proxy_server_request.headers"),
            (
                "malformed headers",
                {"proxy_server_request": {"headers": [], "body": {}}},
                "proxy_server_request.headers",
            ),
        )

        for name, data, field in cases:
            with self.subTest(name=name):
                self.assert_rejected_without_mutation(data, field)

    def test_versioned_proxy_injected_fields_are_ignored_without_mutation(self):
        # Mutation caught: forwarding rejection of v1.104.0's metadata injection or mutation of its snapshot.
        data = proxy_data(
            {
                "model": self.MODEL,
                "messages": [],
                "metadata": {
                    "litellm_api_version": "1.104.0",
                    "user_api_key": "redacted",
                    "requester_metadata": {},
                },
            }
        )
        original = copy.deepcopy(data)

        self.assertIsNone(validate_proxy_request(data))
        self.assertEqual(data, original)

    def test_adapter_matches_four_argument_hook_and_returns_original_data(self):
        # Mutation caught: changing LiteLLM's hook interface, marker, or returning a copied request.
        adapter = load_adapter()
        data = proxy_data({"model": self.MODEL, "messages": []})

        parameters = tuple(inspect.signature(adapter.HermesRequestPolicy.async_pre_call_hook).parameters)
        result = asyncio.run(
            adapter.hermes_request_policy.async_pre_call_hook(None, None, data, "acompletion")
        )

        self.assertEqual(parameters, ("self", "user_api_key_dict", "cache", "data", "call_type"))
        self.assertTrue(adapter.HermesRequestPolicy.enforces_request_content)
        self.assertIsInstance(adapter.hermes_request_policy, adapter.HermesRequestPolicy)
        self.assertIs(result, data)

    def test_adapter_loads_core_from_its_own_directory(self):
        # Mutation caught: relying on the callback directory being present in global sys.path.
        source_dir = Path(__file__).resolve().parent
        with tempfile.TemporaryDirectory() as directory:
            isolated_dir = Path(directory)
            for filename in ("request_policy.py", "request_policy_core.py"):
                shutil.copy(source_dir / filename, isolated_dir / filename)
            original_path = sys.path
            sys.path = [entry for entry in sys.path if Path(entry or ".").resolve() != source_dir]
            try:
                adapter = load_adapter_file(isolated_dir / "request_policy.py")
            finally:
                sys.path = original_path

        self.assertIsInstance(adapter.hermes_request_policy, adapter.HermesRequestPolicy)

    def test_adapter_translates_policy_violation_to_http_400(self):
        # Mutation caught: leaking a policy exception or mapping rejection to a non-400 response.
        adapter = load_adapter()
        data = proxy_data({"model": "provider-value-must-not-leak", "messages": []})

        with self.assertRaises(FakeHTTPException) as raised:
            asyncio.run(
                adapter.hermes_request_policy.async_pre_call_hook(None, None, data, "acompletion")
            )

        self.assertEqual(raised.exception.status_code, 400)
        self.assertIn("model", raised.exception.detail)
        self.assertNotIn("provider-value-must-not-leak", raised.exception.detail)


class SaiaRequestPolicyTests(RequestPolicyTests):
    # Dieselben Faelle fuer das zweite freigeschaltete Modell.
    MODEL = "hermes-saia-qwen-coder"


if __name__ == "__main__":
    unittest.main(verbosity=2)
