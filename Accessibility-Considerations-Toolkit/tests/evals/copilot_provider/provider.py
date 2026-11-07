"""inspect-ai ``ModelAPI`` provider that routes through the GitHub Copilot SDK.

Model identifiers take the form ``copilot/<copilot-model-id>``, e.g.
``copilot/claude-sonnet-4.5``. The portion after ``copilot/`` is passed
verbatim to ``CopilotClient.create_session(model=...)``; valid IDs come
from ``CopilotClient.list_models()``.

The provider runs **tool-less, single-turn** sessions. See
:mod:`runtime` for the safety rationale: the eval rubric files live in
this repository and a tool-enabled session could read them.
"""

from __future__ import annotations

import base64
import mimetypes
from pathlib import Path
from typing import Any
from urllib.parse import unquote_to_bytes

from inspect_ai.model import (
    ChatCompletionChoice,
    ChatMessage,
    ChatMessageAssistant,
    GenerateConfig,
    ModelAPI,
    ModelOutput,
    ModelUsage,
)
from inspect_ai.tool import ToolChoice, ToolInfo

from .runtime import CopilotCompletion, CopilotRuntime


def _flatten_messages(messages: list[ChatMessage]) -> tuple[str, list[dict[str, str]]]:
    """Collapse message history into one prompt plus Copilot attachments.

    The Copilot CLI's session model does not accept arbitrary OpenAI-style
    message histories; ``session.send`` takes one user prompt per turn.
    For a single-turn eval this is sufficient: we concatenate role-tagged
    sections so the model sees the system prompt and any prior context.
    Non-text ``ContentImage`` items are mapped into Copilot attachments.
    """
    parts: list[str] = []
    attachments: list[dict[str, str]] = []

    for msg in messages:
        role = getattr(msg, "role", None) or "user"

        block_lines: list[str] = []
        for item in getattr(msg, "content_list", []):
            item_type = getattr(item, "type", "")
            if item_type == "text":
                text = getattr(item, "text", "")
                if text and text.strip():
                    block_lines.append(text)
                continue

            if item_type == "image":
                image_ref = getattr(item, "image", "")
                attachment = _image_to_attachment(image_ref)
                if attachment:
                    attachments.append(attachment)
                    display = attachment.get("displayName") or "image"
                    block_lines.append(f"[Attached image: {display}]")
                else:
                    block_lines.append(f"[Image reference (not attached): {image_ref}]")
                continue

            # Include any unsupported content types as plain text fallback.
            block_lines.append(str(item))

        content = "\n".join(line for line in block_lines if line.strip()).strip()
        if not content:
            continue

        if role == "system":
            parts.append(f"# System instructions\n{content}")
        elif role == "user":
            parts.append(f"# User\n{content}")
        elif role == "assistant":
            parts.append(f"# Assistant (prior turn)\n{content}")
        else:
            parts.append(f"# {role.capitalize()}\n{content}")

    return "\n\n".join(parts).strip(), attachments


def _image_to_attachment(image: str) -> dict[str, str] | None:
    if not image:
        return None

    if image.startswith("data:"):
        return _data_uri_to_blob_attachment(image)

    path = Path(image).expanduser()
    if path.exists() and path.is_file():
        return {
            "type": "file",
            "path": str(path.resolve()),
            "displayName": path.name,
        }

    decoded = _try_decode_base64(image)
    if decoded is not None:
        return {
            "type": "blob",
            "data": base64.b64encode(decoded).decode("ascii"),
            "mimeType": "image/png",
            "displayName": "inline-image.png",
        }

    return None


def _data_uri_to_blob_attachment(image: str) -> dict[str, str] | None:
    try:
        header, payload = image.split(",", 1)
    except ValueError:
        return None

    mime = header[5:].split(";", 1)[0] or "application/octet-stream"
    if ";base64" in header:
        raw = _try_decode_base64(payload)
        if raw is None:
            return None
        data = base64.b64encode(raw).decode("ascii")
    else:
        data = base64.b64encode(unquote_to_bytes(payload)).decode("ascii")

    ext = mimetypes.guess_extension(mime) or ""
    display = f"inline-image{ext}" if ext else "inline-image"
    return {
        "type": "blob",
        "data": data,
        "mimeType": mime,
        "displayName": display,
    }


def _try_decode_base64(value: str) -> bytes | None:
    try:
        return base64.b64decode(value, validate=True)
    except Exception:
        return None


class CopilotAPI(ModelAPI):
    """Routes inspect-ai generate calls through ``copilot.CopilotClient``."""

    def __init__(
        self,
        model_name: str,
        base_url: str | None = None,
        api_key: str | None = None,
        api_key_vars: list[str] = [],
        config: GenerateConfig = GenerateConfig(),
        **model_args: Any,
    ) -> None:
        super().__init__(
            model_name=model_name,
            base_url=base_url,
            api_key=api_key,
            api_key_vars=api_key_vars,
            config=config,
        )
        self._timeout_s: float = float(model_args.get("timeout", 90.0))

    async def aclose(self) -> None:
        runtime = await CopilotRuntime.instance()
        await runtime.aclose()

    async def generate(
        self,
        input: list[ChatMessage],
        tools: list[ToolInfo],
        tool_choice: ToolChoice,
        config: GenerateConfig,
    ) -> ModelOutput:
        if tools:
            raise ValueError(
                "The 'copilot' provider runs tool-less sessions for safety; "
                "task-supplied tools are not forwarded. Remove 'tools' from "
                "the task or use a different provider."
            )
        prompt, attachments = _flatten_messages(input)
        runtime = await CopilotRuntime.instance()
        completion: CopilotCompletion = await runtime.complete(
            model=self.model_name,
            prompt=prompt,
            attachments=attachments or None,
            timeout_s=self._timeout_s,
        )
        return _to_model_output(completion)


def _to_model_output(completion: CopilotCompletion) -> ModelOutput:
    message = ChatMessageAssistant(content=completion.text, source="generate")
    choice = ChatCompletionChoice(message=message, stop_reason="stop")
    usage = ModelUsage(
        input_tokens=completion.input_tokens,
        output_tokens=completion.output_tokens,
        total_tokens=completion.total_tokens,
    )
    return ModelOutput(
        model=completion.model,
        choices=[choice],
        completion=completion.text,
        usage=usage,
        time=(completion.duration_ms / 1000.0) if completion.duration_ms else None,
    )
