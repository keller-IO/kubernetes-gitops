from collections.abc import Mapping


# Jedes Modell hier ist fuer Chat freigeschaltet. Beide Anbieter sind mit genau
# COMMON_CHAT_PARAMETERS geprueft (Blablador 13.10.2026, SAIA 11.11.2026).
MODELS = frozenset({"hermes-blablador", "hermes-saia-qwen-coder"})

COMMON_CHAT_PARAMETERS = frozenset(
    {
        "temperature",
        "max_tokens",
        "stream",
        "stream_options",
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

# Embeddings sind ein eigener Vertrag (ADR 0011): nur Paperless, nur dieses
# Modell, nur die Felder, die der OpenAI-Client von llama-index sendet. Die
# Chat-Modelle sind hier bewusst nicht enthalten und umgekehrt.
EMBEDDING_MODELS = frozenset({"paperless-saia-embedding"})
EMBEDDING_PARAMETERS = frozenset({"encoding_format"})
EMBEDDING_ENCODING_FORMATS = frozenset({"float", "base64"})
# Wie LiteLLM den Hook fuer /v1/embeddings aufruft; alles andere gilt als Chat
# und unterliegt den strengeren Chat-Regeln.
EMBEDDING_CALL_TYPES = frozenset({"embeddings", "aembedding", "embedding"})
# llama-index sendet hoechstens embed_batch_size Texte je Anfrage (Standard 10).
MAX_EMBEDDING_INPUTS = 128

_REQUIRED_FIELDS = frozenset({"model", "messages"})
_ALLOWED_BODY_FIELDS = _REQUIRED_FIELDS | COMMON_CHAT_PARAMETERS | PROXY_INJECTED_FIELDS
_EMBEDDING_REQUIRED_FIELDS = frozenset({"model", "input"})
_ALLOWED_EMBEDDING_BODY_FIELDS = (
    _EMBEDDING_REQUIRED_FIELDS | EMBEDDING_PARAMETERS | PROXY_INJECTED_FIELDS
)


class PolicyViolation(ValueError):
    def __init__(self, *fields: str) -> None:
        self.fields = fields
        super().__init__(f"request rejected: {', '.join(fields)}")


def _validate_embedding_body(body: Mapping[str, object]) -> None:
    model = body.get("model")
    if not isinstance(model, str) or model not in EMBEDDING_MODELS:
        raise PolicyViolation("model")

    texts = body.get("input")
    if isinstance(texts, str):
        texts = [texts]
    if (
        not isinstance(texts, list)
        or not texts
        or len(texts) > MAX_EMBEDDING_INPUTS
        or any(not isinstance(text, str) or not text for text in texts)
    ):
        raise PolicyViolation("input")

    if "encoding_format" in body:
        encoding_format = body["encoding_format"]
        if (
            not isinstance(encoding_format, str)
            or encoding_format not in EMBEDDING_ENCODING_FORMATS
        ):
            raise PolicyViolation("encoding_format")

    if any(not isinstance(field, str) for field in body):
        raise PolicyViolation("proxy_server_request.body")

    body_fields = frozenset(body)
    rejected_fields = (body_fields & FORBIDDEN_LITELLM_CONTROLS) | (
        body_fields - _ALLOWED_EMBEDDING_BODY_FIELDS
    )
    if rejected_fields:
        raise PolicyViolation(*sorted(rejected_fields))


def validate_proxy_request(data: Mapping[str, object], call_type: object = None) -> None:
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

    if isinstance(call_type, str) and call_type in EMBEDDING_CALL_TYPES:
        _validate_embedding_body(body)
        return

    model = body.get("model")
    if not isinstance(model, str) or model not in MODELS:
        raise PolicyViolation("model")
    if not isinstance(body.get("messages"), list):
        raise PolicyViolation("messages")
    if "stream_options" in body:
        stream_options = body["stream_options"]
        if (
            body.get("stream") is not True
            or not isinstance(stream_options, Mapping)
            or frozenset(stream_options) != {"include_usage"}
            or stream_options.get("include_usage") is not True
        ):
            raise PolicyViolation("stream_options")

    if any(not isinstance(field, str) for field in body):
        raise PolicyViolation("proxy_server_request.body")

    body_fields = frozenset(body)
    rejected_fields = (body_fields & FORBIDDEN_LITELLM_CONTROLS) | (
        body_fields - _ALLOWED_BODY_FIELDS
    )
    if rejected_fields:
        raise PolicyViolation(*sorted(rejected_fields))
