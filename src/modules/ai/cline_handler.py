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

This handler makes HTTP requests via litellm's shared HTTPHandler
(connection pooling), strips the Cline envelope for non-streaming
responses, and parses tool call deltas from streaming SSE chunks.
"""

import json
import logging
from collections.abc import AsyncIterator, Callable, Iterator
from typing import Any

import httpx
import litellm
from litellm.llms.custom_httpx.http_handler import AsyncHTTPHandler, HTTPHandler
from litellm.llms.custom_llm import CustomLLM, CustomLLMError
from litellm.types.utils import (
    ChatCompletionToolCallChunk,
    ChatCompletionToolCallFunctionChunk,
    ChatCompletionUsageBlock,
    GenericStreamingChunk,
)
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
    reasoning_effort: str | None = None,
) -> dict[str, Any]:
    """Build the JSON request body, forwarding all params from litellm.

    litellm's ``get_optional_params()`` for custom providers only puts
    provider-specific (non-standard) params into ``optional_params``.
    Standard OpenAI params (temperature, tools, etc.) are stripped by
    litellm before they reach the handler — that is a litellm limitation,
    not fixable here.  We forward everything litellm gives us.

    ``reasoning_effort`` is read separately from ``litellm_params``
    because litellm keeps it there rather than in ``optional_params``
    for custom providers.
    """
    body: dict[str, Any] = {
        "model": model,
        "messages": messages,
        "stream": stream,
    }
    body.update(optional_params)
    if reasoning_effort is not None:
        body["reasoning_effort"] = reasoning_effort
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


def _extract_reasoning_effort(litellm_params: dict | None) -> str | None:
    """Extract reasoning_effort from litellm_params if present."""
    if litellm_params is None:
        return None
    effort = litellm_params.get("reasoning_effort")
    return str(effort) if effort is not None else None


def _build_tool_use_chunk(
    tool_call: dict[str, Any],
) -> ChatCompletionToolCallChunk:
    """Build a ChatCompletionToolCallChunk from a streaming tool_call delta."""
    func = tool_call.get("function", {})
    return ChatCompletionToolCallChunk(
        id=tool_call.get("id"),
        type="function",
        function=ChatCompletionToolCallFunctionChunk(
            name=func.get("name"),
            arguments=func.get("arguments", ""),
        ),
        index=tool_call.get("index", 0),
    )


def _get_http_client(
    client: HTTPHandler | AsyncHTTPHandler | None,
    *,
    async_client: bool = False,
) -> HTTPHandler | AsyncHTTPHandler:
    """Return the provided client or fall back to litellm's shared singleton."""
    if client is not None:
        return client
    if async_client:
        return litellm.module_level_aclient
    return litellm.module_level_client


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
        reasoning_effort = _extract_reasoning_effort(litellm_params)
        body = _build_request_body(
            model,
            messages,
            optional_params,
            stream=False,
            reasoning_effort=reasoning_effort,
        )

        http_client = _get_http_client(client)
        try:
            response = http_client.post(
                url,
                json=body,
                headers=http_headers,
                timeout=timeout,
            )
            response_data = response.json()
        except httpx.HTTPStatusError as e:
            raise CustomLLMError(
                e.response.status_code,
                f"HTTP {e.response.status_code}: {e.response.text}",
            ) from e

        response_data = _strip_cline_envelope(response_data)

        # Build a fresh ModelResponse from the unwrapped Cline response.
        # Constructing from the dict lets litellm/Pydantic coerce the nested
        # dicts into proper Choice / Message objects, which is required by
        # post_call_processing (it accesses choice.message as an attribute).
        model_response = ModelResponse(**response_data)

        logging_obj.post_call(
            input=messages,
            original_response=response_data,
            api_key=api_key,
        )
        return model_response

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
        reasoning_effort = _extract_reasoning_effort(litellm_params)
        body = _build_request_body(
            model,
            messages,
            optional_params,
            stream=True,
            reasoning_effort=reasoning_effort,
        )

        http_client = _get_http_client(client)
        try:
            response = http_client.post(
                url,
                json=body,
                headers=http_headers,
                stream=True,
                timeout=timeout,
            )
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

                choices = chunk_data.get("choices", [])
                if not choices:
                    continue
                delta = choices[0].get("delta", {})
                finish_reason = choices[0].get("finish_reason")
                usage_block = chunk_data.get("usage")

                usage: Any = None
                if usage_block:
                    usage = ChatCompletionUsageBlock(**usage_block)

                # Parse tool call deltas from streaming response.
                tool_use: ChatCompletionToolCallChunk | None = None
                tool_calls = delta.get("tool_calls")
                if tool_calls:
                    tool_use = _build_tool_use_chunk(tool_calls[0])

                yield GenericStreamingChunk(
                    text=delta.get("content", "") or "",
                    tool_use=tool_use,
                    is_finished=finish_reason is not None,
                    finish_reason=finish_reason or "",
                    usage=usage,
                    index=choices[0].get("index", 0),
                )
        except httpx.HTTPStatusError as e:
            raise CustomLLMError(
                e.response.status_code,
                f"HTTP {e.response.status_code}: {e.response.text}",
            ) from e

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
        reasoning_effort = _extract_reasoning_effort(litellm_params)
        body = _build_request_body(
            model,
            messages,
            optional_params,
            stream=False,
            reasoning_effort=reasoning_effort,
        )

        http_client = _get_http_client(client, async_client=True)
        try:
            response = await http_client.post(
                url,
                json=body,
                headers=http_headers,
                timeout=timeout,
            )
            response_data = response.json()
        except httpx.HTTPStatusError as e:
            raise CustomLLMError(
                e.response.status_code,
                f"HTTP {e.response.status_code}: {e.response.text}",
            ) from e

        response_data = _strip_cline_envelope(response_data)

        model_response = ModelResponse(**response_data)

        logging_obj.post_call(
            input=messages,
            original_response=response_data,
            api_key=api_key,
        )
        return model_response

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
        reasoning_effort = _extract_reasoning_effort(litellm_params)
        body = _build_request_body(
            model,
            messages,
            optional_params,
            stream=True,
            reasoning_effort=reasoning_effort,
        )

        http_client = _get_http_client(client, async_client=True)
        try:
            response = await http_client.post(
                url,
                json=body,
                headers=http_headers,
                stream=True,
                timeout=timeout,
            )
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

                choices = chunk_data.get("choices", [])
                if not choices:
                    continue
                delta = choices[0].get("delta", {})
                finish_reason = choices[0].get("finish_reason")
                usage_block = chunk_data.get("usage")

                usage: Any = None
                if usage_block:
                    usage = ChatCompletionUsageBlock(**usage_block)

                # Parse tool call deltas from streaming response.
                tool_use: ChatCompletionToolCallChunk | None = None
                tool_calls = delta.get("tool_calls")
                if tool_calls:
                    tool_use = _build_tool_use_chunk(tool_calls[0])

                yield GenericStreamingChunk(
                    text=delta.get("content", "") or "",
                    tool_use=tool_use,
                    is_finished=finish_reason is not None,
                    finish_reason=finish_reason or "",
                    usage=usage,
                    index=choices[0].get("index", 0),
                )
        except httpx.HTTPStatusError as e:
            raise CustomLLMError(
                e.response.status_code,
                f"HTTP {e.response.status_code}: {e.response.text}",
            ) from e


# Module-level instance for litellm's get_instance_fn resolution.
# Config value: cline_handler.cline_handler
#   module = cline_handler.py, attribute = cline_handler (this instance)
cline_handler = ClineHandler()
