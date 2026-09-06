"""
Custom litellm handler for the Cline API.

Cline wraps non-streaming responses in a non-standard envelope:
    {"data": {actual_openai_response}, "success": true}

litellm's OpenAI provider calls ``model_dump()`` on the parsed
``ChatCompletion`` object, which includes the extra envelope fields.
``convert_to_model_response_object()`` then sees ``choices: None``
(from the outer envelope) and raises APIError(500).

Streaming is unaffected — Cline returns standard SSE without the
envelope, so streaming requests pass through unchanged.

This handler makes HTTP requests directly via httpx, strips the
Cline envelope for non-streaming responses, and passes through
streaming SSE chunks without modification.
"""

import json
import logging
from collections.abc import AsyncIterator, Callable, Iterator
from typing import Any

import httpx
from litellm.llms.custom_httpx.http_handler import AsyncHTTPHandler, HTTPHandler
from litellm.llms.custom_llm import CustomLLM
from litellm.types.utils import GenericStreamingChunk
from litellm.utils import ModelResponse

logger = logging.getLogger("litellm_logger")


def _build_request_headers(
    api_key: str | None,
    extra_headers: dict | None,
) -> dict[str, str]:
    """Build HTTP headers for the Cline API request."""
    headers: dict[str, str] = {
        "Content-Type": "application/json",
    }
    if api_key:
        headers["Authorization"] = f"Bearer {api_key}"
    if extra_headers:
        headers.update(extra_headers)
    return headers


def _build_request_body(
    model: str,
    messages: list,
    optional_params: dict,
    stream: bool,
) -> dict[str, Any]:
    """Build the JSON request body, forwarding supported params."""
    body: dict[str, Any] = {
        "model": model,
        "messages": messages,
        "stream": stream,
    }
    # Forward standard OpenAI-compatible params that Cline supports.
    for key in (
        "temperature",
        "top_p",
        "max_tokens",
        "max_completion_tokens",
        "stop",
        "n",
        "presence_penalty",
        "frequency_penalty",
        "logit_bias",
        "user",
        "seed",
        "response_format",
        "tools",
        "tool_choice",
        "parallel_tool_calls",
    ):
        if key in optional_params:
            body[key] = optional_params[key]
    return body


def _strip_cline_envelope(data: dict[str, Any]) -> dict[str, Any]:
    """Strip Cline's non-standard response envelope if present.

    Cline returns ``{"data": {openai_response}, "success": true}`` for
    non-streaming requests.  litellm expects a plain OpenAI response dict,
    so we unwrap the envelope when detected.
    """
    if (
        isinstance(data.get("data"), dict)
        and "success" in data
        and "choices" not in data
    ):
        return data["data"]
    return data


def _timeout_to_seconds(
    timeout: float | httpx.Timeout | None,
) -> float | None:
    """Convert litellm timeout to a plain float (seconds)."""
    if timeout is None:
        return None
    if isinstance(timeout, httpx.Timeout):
        return timeout.connect  # type: ignore[return-value]
    return float(timeout)


class ClineHandler(CustomLLM):
    """litellm custom handler that strips Cline's non-standard response envelope."""

    def completion(
        self,
        model: str,
        messages: list,
        api_base: str,
        custom_prompt_dict: dict,
        model_response: ModelResponse,
        print_verbose: Callable,
        encoding: Any,
        api_key: str | None,
        logging_obj: Any,
        optional_params: dict,
        acompletion: bool | None = None,
        litellm_params: dict | None = None,
        logger_fn: Callable | None = None,
        headers: dict | None = None,
        timeout: float | httpx.Timeout | None = None,
        client: HTTPHandler | None = None,
    ) -> ModelResponse:
        url = f"{api_base.rstrip('/')}/chat/completions"
        http_headers = _build_request_headers(api_key, headers)
        body = _build_request_body(model, messages, optional_params, stream=False)
        timeout_s = _timeout_to_seconds(timeout)

        with httpx.Client(timeout=timeout_s) as http_client:
            response = http_client.post(url, json=body, headers=http_headers)
            response.raise_for_status()
            response_data = response.json()

        response_data = _strip_cline_envelope(response_data)

        # Build a fresh ModelResponse from the unwrapped Cline response.
        # Constructing from the dict lets litellm/Pydantic coerce the nested
        # dicts into proper Choice / Message objects, which is required by
        # post_call_processing (it accesses choice.message as an attribute).
        return ModelResponse(**response_data)

    def streaming(
        self,
        model: str,
        messages: list,
        api_base: str,
        custom_prompt_dict: dict,
        model_response: ModelResponse,
        print_verbose: Callable,
        encoding: Any,
        api_key: str | None,
        logging_obj: Any,
        optional_params: dict,
        acompletion: bool | None = None,
        litellm_params: dict | None = None,
        logger_fn: Callable | None = None,
        headers: dict | None = None,
        timeout: float | httpx.Timeout | None = None,
        client: HTTPHandler | None = None,
    ) -> Iterator[GenericStreamingChunk]:
        url = f"{api_base.rstrip('/')}/chat/completions"
        http_headers = _build_request_headers(api_key, headers)
        body = _build_request_body(model, messages, optional_params, stream=True)
        timeout_s = _timeout_to_seconds(timeout)

        with (
            httpx.Client(timeout=timeout_s) as http_client,
            http_client.stream(
                "POST", url, json=body, headers=http_headers
            ) as response,
        ):
            response.raise_for_status()
            for line in response.iter_lines():
                if not line.startswith("data: "):
                    continue
                payload = line[len("data: ") :]
                if payload.strip() == "[DONE]":
                    break
                try:
                    chunk_data = json.loads(payload)
                except json.JSONDecodeError:
                    continue
                # Standard SSE chunk — Cline does NOT wrap streaming
                # in an envelope.
                choices = chunk_data.get("choices", [])
                if not choices:
                    continue
                delta = choices[0].get("delta", {})
                finish_reason = choices[0].get("finish_reason")
                usage_block = chunk_data.get("usage")

                usage: Any = None
                if usage_block:
                    from litellm.types.utils import ChatCompletionUsageBlock

                    usage = ChatCompletionUsageBlock(**usage_block)

                yield GenericStreamingChunk(
                    text=delta.get("content", "") or "",
                    tool_use=None,
                    is_finished=finish_reason is not None,
                    finish_reason=finish_reason or "",
                    usage=usage,
                    index=choices[0].get("index", 0),
                )

    async def acompletion(
        self,
        model: str,
        messages: list,
        api_base: str,
        custom_prompt_dict: dict,
        model_response: ModelResponse,
        print_verbose: Callable,
        encoding: Any,
        api_key: str | None,
        logging_obj: Any,
        optional_params: dict,
        acompletion: bool | None = None,
        litellm_params: dict | None = None,
        logger_fn: Callable | None = None,
        headers: dict | None = None,
        timeout: float | httpx.Timeout | None = None,
        client: AsyncHTTPHandler | None = None,
    ) -> ModelResponse:
        url = f"{api_base.rstrip('/')}/chat/completions"
        http_headers = _build_request_headers(api_key, headers)
        body = _build_request_body(model, messages, optional_params, stream=False)
        timeout_s = _timeout_to_seconds(timeout)

        async with httpx.AsyncClient(timeout=timeout_s) as http_client:
            response = await http_client.post(url, json=body, headers=http_headers)
            response.raise_for_status()
            response_data = response.json()

        response_data = _strip_cline_envelope(response_data)

        # Build a fresh ModelResponse from the unwrapped Cline response.
        # Constructing from the dict lets litellm/Pydantic coerce the nested
        # dicts into proper Choice / Message objects, which is required by
        # post_call_processing (it accesses choice.message as an attribute).
        return ModelResponse(**response_data)

    async def astreaming(
        self,
        model: str,
        messages: list,
        api_base: str,
        custom_prompt_dict: dict,
        model_response: ModelResponse,
        print_verbose: Callable,
        encoding: Any,
        api_key: str | None,
        logging_obj: Any,
        optional_params: dict,
        acompletion: bool | None = None,
        litellm_params: dict | None = None,
        logger_fn: Callable | None = None,
        headers: dict | None = None,
        timeout: float | httpx.Timeout | None = None,
        client: AsyncHTTPHandler | None = None,
    ) -> AsyncIterator[GenericStreamingChunk]:
        url = f"{api_base.rstrip('/')}/chat/completions"
        http_headers = _build_request_headers(api_key, headers)
        body = _build_request_body(model, messages, optional_params, stream=True)
        timeout_s = _timeout_to_seconds(timeout)

        async with (
            httpx.AsyncClient(timeout=timeout_s) as http_client,
            http_client.stream(
                "POST", url, json=body, headers=http_headers
            ) as response,
        ):
            response.raise_for_status()
            async for line in response.aiter_lines():
                if not line.startswith("data: "):
                    continue
                payload = line[len("data: ") :]
                if payload.strip() == "[DONE]":
                    break
                try:
                    chunk_data = json.loads(payload)
                except json.JSONDecodeError:
                    continue
                # Standard SSE chunk — Cline does NOT wrap streaming
                # in an envelope.
                choices = chunk_data.get("choices", [])
                if not choices:
                    continue
                delta = choices[0].get("delta", {})
                finish_reason = choices[0].get("finish_reason")
                usage_block = chunk_data.get("usage")

                usage: Any = None
                if usage_block:
                    from litellm.types.utils import ChatCompletionUsageBlock

                    usage = ChatCompletionUsageBlock(**usage_block)

                yield GenericStreamingChunk(
                    text=delta.get("content", "") or "",
                    tool_use=None,
                    is_finished=finish_reason is not None,
                    finish_reason=finish_reason or "",
                    usage=usage,
                    index=choices[0].get("index", 0),
                )


# Module-level instance for litellm's get_instance_fn resolution.
# Config value: cline_handler.cline_handler
#   module = cline_handler.py, attribute = cline_handler (this instance)
cline_handler = ClineHandler()
