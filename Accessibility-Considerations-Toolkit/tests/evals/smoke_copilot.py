"""Smoke test for the Copilot SDK-backed provider.

Run with the dedicated runner (which registers the ``copilot`` provider
before resolving the model):

    python tests/evals/run_copilot_eval.py copilot/claude-sonnet-4.5 smoke_copilot:smoke_copilot

The standard ``inspect eval`` CLI will not work for ``copilot/*`` models
without an installed entry point — see ``run_copilot_eval.py``.

Prerequisites:
- ``@github/copilot`` CLI installed (``npm install -g @github/copilot``)
  and ``copilot --version`` reports >= 0.0.394.
- ``copilot login`` completed once.
- ``github-copilot-sdk`` Python package installed in the active venv.
"""

from __future__ import annotations

from inspect_ai import Task, task
from inspect_ai.dataset import Sample
from inspect_ai.scorer import includes
from inspect_ai.solver import generate


@task
def smoke_copilot() -> Task:
    return Task(
        dataset=[
            Sample(
                input=(
                    "Reply with the single word: ok. "
                    "Do not include any punctuation, quotes, or other text."
                ),
                target="ok",
            )
        ],
        solver=[generate()],
        scorer=includes(),
    )
