from collections.abc import Mapping


MODEL = "hermes-blablador"

COMMON_CHAT_PARAMETERS = frozenset(
    {
        "temperature",
        "max_tokens",
        "stream",
        "tools",
        "tool_choice",
    }
)

FORBIDDEN_LITELLM_CONTROLS = frozenset(
    {
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
    }
)

PROXY_INJECTED_FIELDS = frozenset({"metadata"})

_REQUIRED_FIELDS = frozenset({"model", "messages"})
_ALLOWED_BODY_FIELDS = _REQUIRED_FIELDS | COMMON_CHAT_PARAMETERS | PROXY_INJECTED_FIELDS


class PolicyViolation(ValueError):
    def __init__(self, *fields: str) -> None:
        self.fields = fields
        super().__init__(f"request rejected: {', '.join(fields)}")


def validate_proxy_request(data: Mapping[str, object]) -> None:
    if not isinstance(data, Mapping):
        raise PolicyViolation("proxy_server_request")

    proxy_request = data.get("proxy_server_request")
    if not isinstance(proxy_request, Mapping):
        raise PolicyViolation("proxy_server_request")

    body = proxy_request.get("body")
    if not isinstance(body, Mapping):
        raise PolicyViolation("proxy_server_request.body")

    headers = proxy_request.get("headers")
    if not isinstance(headers, Mapping):
        raise PolicyViolation("proxy_server_request.headers")

    for header in headers:
        if not isinstance(header, str):
            raise PolicyViolation("proxy_server_request.headers")
        if header.lower().startswith("x-litellm-"):
            raise PolicyViolation(header)

    if body.get("model") != MODEL:
        raise PolicyViolation("model")
    if not isinstance(body.get("messages"), list):
        raise PolicyViolation("messages")

    if any(not isinstance(field, str) for field in body):
        raise PolicyViolation("proxy_server_request.body")

    body_fields = frozenset(body)
    rejected_fields = (body_fields & FORBIDDEN_LITELLM_CONTROLS) | (
        body_fields - _ALLOWED_BODY_FIELDS
    )
    if rejected_fields:
        raise PolicyViolation(*sorted(rejected_fields))
