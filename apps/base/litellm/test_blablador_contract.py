import json
import os
import time
import unittest
import uuid

from openai import OpenAI


MODEL = "alias-code"
API_BASE = "https://api.blablador.fz-juelich.de/v1"
FUNCTION_NAME = "report_contract"


class BlabladorContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.client = OpenAI(
            api_key=os.environ["BLABLADOR_API_KEY"],
            base_url=API_BASE,
            timeout=60.0,
        )

    def assert_contract(self, condition, message):
        if not condition:
            raise AssertionError(message)

    def create_completion(self, contract, **parameters):
        try:
            return self.client.chat.completions.create(**parameters)
        except Exception:
            raise AssertionError(f"{contract} request failed") from None

    def test_chat_completion_schema_without_logging_content(self):
        started = time.monotonic()
        response = self.create_completion(
            "chat",
            model=MODEL,
            messages=[{"role": "user", "content": "Provide one short synthetic acknowledgement."}],
            temperature=0,
            max_tokens=2048,
        )
        elapsed = time.monotonic() - started

        self.assert_contract(isinstance(response.id, str) and bool(response.id), "response id schema mismatch")
        self.assert_contract(response.object == "chat.completion", "response object schema mismatch")
        self.assert_contract(isinstance(response.created, int), "response created schema mismatch")
        self.assert_contract(isinstance(response.model, str), "response model schema mismatch")
        self.assert_contract(bool(response.choices), "response choices schema mismatch")
        self.assert_contract(isinstance(response.choices[0].index, int), "choice index schema mismatch")
        self.assert_contract(response.choices[0].message.role == "assistant", "message role schema mismatch")
        self.assert_contract(isinstance(response.choices[0].message.content, str), "message content schema mismatch")
        print(f"contract=chat status=pass latency_seconds={elapsed:.3f}")

    def test_stream_emits_at_least_two_chunks(self):
        started = time.monotonic()
        stream = self.create_completion(
            "stream",
            model=MODEL,
            messages=[{"role": "user", "content": uuid.uuid4().hex}],
            temperature=0,
            max_tokens=32,
            stream=True,
        )
        chunk_count = 0
        try:
            for chunk in stream:
                chunk_count += 1
                self.assert_contract(isinstance(chunk.id, str), "stream chunk id schema mismatch")
                self.assert_contract(chunk.object == "chat.completion.chunk", "stream chunk object schema mismatch")
                self.assert_contract(isinstance(chunk.created, int), "stream chunk created schema mismatch")
                self.assert_contract(isinstance(chunk.model, str), "stream chunk model schema mismatch")
                self.assert_contract(isinstance(chunk.choices, list), "stream chunk choices schema mismatch")
        except AssertionError:
            raise
        except Exception:
            raise AssertionError("stream request failed") from None
        elapsed = time.monotonic() - started

        self.assert_contract(chunk_count >= 2, "stream emitted fewer than two chunks")
        print(f"contract=stream status=pass latency_seconds={elapsed:.3f} chunks={chunk_count}")

    def test_deterministic_tool_call_shape(self):
        started = time.monotonic()
        response = self.create_completion(
            "tool",
            model=MODEL,
            messages=[{"role": "user", "content": uuid.uuid4().hex}],
            temperature=0,
            max_tokens=2048,
            tools=[
                {
                    "type": "function",
                    "function": {
                        "name": FUNCTION_NAME,
                        "description": "Report contract status.",
                        "parameters": {
                            "type": "object",
                            "properties": {"status": {"type": "string"}},
                            "required": ["status"],
                            "additionalProperties": False,
                        },
                    },
                }
            ],
            tool_choice={"type": "function", "function": {"name": FUNCTION_NAME}},
        )
        elapsed = time.monotonic() - started

        self.assert_contract(bool(response.choices), "tool response choices schema mismatch")
        tool_calls = response.choices[0].message.tool_calls
        self.assert_contract(isinstance(tool_calls, list), "tool calls schema mismatch")
        self.assert_contract(len(tool_calls) == 1, "tool call count schema mismatch")
        self.assert_contract(tool_calls[0].type == "function", "tool call type schema mismatch")
        self.assert_contract(tool_calls[0].function.name == FUNCTION_NAME, "tool function name schema mismatch")
        try:
            arguments = json.loads(tool_calls[0].function.arguments)
        except (TypeError, json.JSONDecodeError):
            raise AssertionError("tool arguments are not valid JSON") from None
        self.assert_contract(isinstance(arguments, dict), "tool arguments are not a JSON object")
        print(f"contract=tool status=pass latency_seconds={elapsed:.3f}")


if __name__ == "__main__":
    unittest.main(verbosity=2)
