"""Thin async wrapper around the GitHub Copilot SDK for tool-less chat.

This wraps a single long-lived ``copilot.CopilotClient`` (which spawns the
``@github/copilot`` CLI as a subprocess) and exposes one method,
:meth:`CopilotRuntime.complete`, that opens a short-lived session with all
tools, MCP servers, and config discovery disabled. The session sees only
the messages we pass; it cannot read files, run shell commands, or load
``.github/copilot-instructions.md`` from the repository.

Why tool-less: the eval suite's rubric files and expected answers live in
the same repository as the prompt sources. Disabling every tool prevents
the model under test from reading them and gaming the rubric.
"""

from __future__ import annotations

import asyncio
import os
import tempfile
from datetime import datetime
from dataclasses import dataclass
from typing import Any

from copilot import CopilotClient, ChildProcessRuntimeConnection
from copilot.client import PingResponse
from copilot.session import Attachment
from copilot.session import PermissionRequestResult


def _coerce_ping_timestamp(raw: Any) -> int:
    if isinstance(raw, int):
        return raw
    if isinstance(raw, float):
        return int(raw)
    if isinstance(raw, str):
        text = raw.strip()
        if text.isdigit():
            return int(text)
        # Newer Copilot CLI builds may emit ISO-8601 instead of epoch ms.
        dt = datetime.fromisoformat(text.replace("Z", "+00:00"))
        return int(dt.timestamp() * 1000)
    raise ValueError(f"Unsupported ping timestamp type: {type(raw).__name__}")


def _install_ping_timestamp_compat() -> None:
    original = PingResponse.from_dict

    def _from_dict_compat(obj: Any) -> PingResponse:
        try:
            return original(obj)
        except (TypeError, ValueError):
            if not isinstance(obj, dict):
                raise
            message = obj.get("message")
            timestamp = obj.get("timestamp")
            protocol_version = obj.get("protocolVersion")
            if message is None or timestamp is None or protocol_version is None:
                raise
            return PingResponse(
                str(message),
                _coerce_ping_timestamp(timestamp),
                int(protocol_version),
            )

    PingResponse.from_dict = staticmethod(_from_dict_compat)


_install_ping_timestamp_compat()


def _reject_all(_request: Any, _invocation: Any) -> PermissionRequestResult:
    """Permission handler that rejects every tool-call permission request.

    Tool-less sessions should never trigger a permission request (the tool
    list is empty). This is a defense-in-depth fallback in case the CLI
    surfaces a built-in capability we did not enumerate.
    """
    return PermissionRequestResult(kind="reject")


@dataclass
class CopilotCompletion:
    """Result of one tool-less Copilot completion call."""

    text: str
    input_tokens: int
    output_tokens: int
    total_tokens: int
    model: str
    duration_ms: float | None


class CopilotRuntime:
    """Lazy, process-wide singleton wrapping ``CopilotClient``.

    The CLI spawn is expensive (several seconds), so we pay it once and
    reuse the client across every ``generate()`` call in an eval run.
    """

    _instance: "CopilotRuntime | None" = None
    _instance_lock = asyncio.Lock()

    def __init__(self) -> None:
        self._client: CopilotClient | None = None
        self._client_lock = asyncio.Lock()
        cli_path = os.environ.get("COPILOT_CLI_PATH", None)
        self._connection = ChildProcessRuntimeConnection(path=cli_path) if cli_path else None
        self._use_logged_in_user = True

    @classmethod
    async def instance(cls) -> "CopilotRuntime":
        async with cls._instance_lock:
            if cls._instance is None:
                cls._instance = cls()
            return cls._instance

    async def _ensure_started(self) -> CopilotClient:
        if self._client is not None:
            return self._client
        async with self._client_lock:
            if self._client is None:
                client = CopilotClient(connection=self._connection, use_logged_in_user=self._use_logged_in_user)
                await client.start()
                self._client = client
            return self._client

    async def aclose(self) -> None:
        async with self._client_lock:
            if self._client is not None:
                try:
                    await self._client.stop()
                finally:
                    self._client = None

    async def list_models(self) -> list[Any]:
        client = await self._ensure_started()
        return await client.list_models()

    async def complete(
        self,
        *,
        model: str,
        prompt: str,
        attachments: list[Attachment] | None = None,
        timeout_s: float = 60.0,
    ) -> CopilotCompletion:
        """Run one tool-less single-turn session and return the assistant text.

        ``prompt`` is sent verbatim as the single user message. Callers are
        responsible for collapsing multi-message ChatMessage histories into a
        single string (see ``provider.py``) — the Copilot CLI does not expose
        a multi-turn programmatic API for arbitrary message histories, only
        ``send`` per turn.
        """
        client = await self._ensure_started()
        events: list[Any] = []
        with tempfile.TemporaryDirectory(prefix="copilot-eval-") as workdir:
            session = await client.create_session(
                model=model,
                on_permission_request=_reject_all,
                tools=[],
                available_tools=[],
                mcp_servers={},
                enable_config_discovery=False,
                working_directory=workdir,
                on_event=events.append,
            )
            try:
                final_event = await session.send_and_wait(
                    prompt,
                    attachments=attachments,
                    timeout=timeout_s,
                )
            finally:
                try:
                    await session.disconnect()
                except Exception:
                    pass

        return _build_completion(model, final_event, events)


def _build_completion(
    model: str,
    final_event: Any,
    events: list[Any],
) -> CopilotCompletion:
    """Fold session events into a :class:`CopilotCompletion`.

    ``final_event`` is whatever ``send_and_wait`` returned. We prefer its
    payload for the assistant text, falling back to scanning ``events`` for
    the last ``assistant.message``. Token usage comes from
    ``assistant.usage`` events (one per LLM call).
    """
    text = _extract_assistant_text(final_event, events)
    input_tokens, output_tokens, duration_ms = _aggregate_usage(events)
    total_tokens = input_tokens + output_tokens
    return CopilotCompletion(
        text=text,
        input_tokens=input_tokens,
        output_tokens=output_tokens,
        total_tokens=total_tokens,
        model=model,
        duration_ms=duration_ms,
    )


def _event_type(event: Any) -> str:
    t = getattr(event, "type", None)
    return getattr(t, "value", None) or getattr(t, "name", None) or str(t)


def _extract_assistant_text(final_event: Any, events: list[Any]) -> str:
    candidates: list[Any] = []
    if final_event is not None:
        candidates.append(final_event)
    candidates.extend(reversed(events))
    for ev in candidates:
        if _event_type(ev) != "assistant.message":
            continue
        data = getattr(ev, "data", None)
        content = getattr(data, "content", None)
        if isinstance(content, str) and content:
            return content
    return ""


def _aggregate_usage(events: list[Any]) -> tuple[int, int, float | None]:
    input_tokens = 0
    output_tokens = 0
    duration_ms: float | None = None
    for ev in events:
        if _event_type(ev) != "assistant.usage":
            continue
        data = getattr(ev, "data", None)
        if data is None:
            continue
        # SDK exposes prompt_tokens/output_tokens on AssistantUsageData; some
        # variants use input_tokens. Tolerate both.
        prompt = getattr(data, "prompt_tokens", None)
        if prompt is None:
            prompt = getattr(data, "input_tokens", None)
        out = getattr(data, "output_tokens", None)
        if isinstance(prompt, (int, float)):
            input_tokens += int(prompt)
        if isinstance(out, (int, float)):
            output_tokens += int(out)
        d = getattr(data, "duration", None)
        if isinstance(d, (int, float)):
            duration_ms = (duration_ms or 0.0) + float(d)
    return input_tokens, output_tokens, duration_ms
