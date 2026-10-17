import importlib.util
from pathlib import Path

from fastapi import HTTPException
from litellm.integrations.custom_logger import CustomLogger


_core_path = Path(__file__).with_name("request_policy_core.py")
_core_spec = importlib.util.spec_from_file_location("litellm_request_policy_core", _core_path)
if _core_spec is None or _core_spec.loader is None:
    raise ImportError("unable to load request policy core")
_core = importlib.util.module_from_spec(_core_spec)
_core_spec.loader.exec_module(_core)

PolicyViolation = _core.PolicyViolation
validate_proxy_request = _core.validate_proxy_request


class HermesRequestPolicy(CustomLogger):
    enforces_request_content = True

    async def async_pre_call_hook(
        self,
        user_api_key_dict,
        cache,
        data: dict,
        call_type,
    ) -> dict:
        try:
            validate_proxy_request(data)
        except PolicyViolation as exc:
            raise HTTPException(status_code=400, detail=str(exc)) from None
        return data


hermes_request_policy = HermesRequestPolicy()
