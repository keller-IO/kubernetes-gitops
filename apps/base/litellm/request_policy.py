from fastapi import HTTPException
from litellm.integrations.custom_logger import CustomLogger

from request_policy_core import PolicyViolation, validate_proxy_request


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
