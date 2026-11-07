"""GitHub Copilot SDK provider for inspect-ai.

Importing this package registers the ``copilot`` model API so that
identifiers of the form ``copilot/<copilot-model-id>`` route through a
tool-less session against the local ``@github/copilot`` CLI.

Prerequisites:
- Node.js 22+ and ``@github/copilot`` CLI installed and on PATH.
- ``copilot login`` completed once (auth cached under
  ``%USERPROFILE%/.config/github-copilot``).
- ``github-copilot-sdk`` Python package installed.

See :mod:`runtime` for the tool-less session contract that prevents the
model under test from reading rubric files in this repository.
"""

from __future__ import annotations

from inspect_ai.model import ModelAPI
from inspect_ai.model._registry import modelapi


@modelapi(name="copilot")
def copilot() -> type[ModelAPI]:
    try:
        import copilot as _copilot_sdk  # noqa: F401
    except ImportError as exc:
        raise ImportError(
            "github-copilot-sdk is not installed. Install it with "
            "`pip install github-copilot-sdk` and ensure the @github/copilot "
            "CLI is on PATH."
        ) from exc

    from .provider import CopilotAPI

    return CopilotAPI


__all__ = ["copilot"]
