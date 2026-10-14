import asyncio
import copy
import importlib
import inspect
import sys
import types
import unittest
from unittest.mock import patch

from request_policy_core import PolicyViolation, validate_proxy_request


MODEL = "hermes-blablador"


class FakeCustomLogger:
    enforces_request_content = False


class FakeHTTPException(Exception):
    def __init__(self, status_code, detail):
        self.status_code = status_code
        self.detail = detail
        super().__init__(detail)


def load_adapter():
    litellm = types.ModuleType("litellm")
    integrations = types.ModuleType("litellm.integrations")
    custom_logger = types.ModuleType("litellm.integrations.custom_logger")
    custom_logger.CustomLogger = FakeCustomLogger
    fastapi = types.ModuleType("fastapi")
    fastapi.HTTPException = FakeHTTPException
    modules = {
        "litellm": litellm,
        "litellm.integrations": integrations,
        "litellm.integrations.custom_logger": custom_logger,
        "fastapi": fastapi,
    }
    sys.modules.pop("request_policy", None)
    with patch.dict(sys.modules, modules):
        return importlib.import_module("request_policy")


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


class RequestPolicyTests(unittest.TestCase):
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
                "model": MODEL,
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

    def test_rejects_other_model_or_missing_messages(self):
        # Mutation caught: accepting a different route target or a body without list-valued messages.
        cases = (
            ("other model", {"model": "other-model", "messages": []}, "model"),
            ("missing messages", {"model": MODEL}, "messages"),
            ("malformed messages", {"model": MODEL, "messages": {}}, "messages"),
        )

        for name, body, field in cases:
            with self.subTest(name=name):
                self.assert_rejected_without_mutation(proxy_data(body), field)

    def test_rejects_unknown_provider_parameter(self):
        # Mutation caught: forwarding a provider parameter outside the empirically verified allowlist.
        data = proxy_data(
            {
                "model": MODEL,
                "messages": [],
                "frequency_penalty": "provider-value-must-not-leak",
            }
        )

        self.assert_rejected_without_mutation(data, "frequency_penalty")
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
                        "model": MODEL,
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
                    {"model": MODEL, "messages": []},
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
                "model": MODEL,
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
        data = proxy_data({"model": MODEL, "messages": []})

        parameters = tuple(inspect.signature(adapter.HermesRequestPolicy.async_pre_call_hook).parameters)
        result = asyncio.run(
            adapter.hermes_request_policy.async_pre_call_hook(None, None, data, "acompletion")
        )

        self.assertEqual(parameters, ("self", "user_api_key_dict", "cache", "data", "call_type"))
        self.assertTrue(adapter.HermesRequestPolicy.enforces_request_content)
        self.assertIsInstance(adapter.hermes_request_policy, adapter.HermesRequestPolicy)
        self.assertIs(result, data)

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


if __name__ == "__main__":
    unittest.main(verbosity=2)
