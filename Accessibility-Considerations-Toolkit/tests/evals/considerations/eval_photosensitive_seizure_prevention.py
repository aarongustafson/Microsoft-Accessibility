"""Eval: photosensitive consideration (clause 4.2.9) — STUB.

One sub-test verifying the model handles stub consideration content appropriately:

- Stub acknowledgement (refuses fabrication, defers to limitations)

Stub considerations have minimal elaboration and should NOT be treated as if they have
detailed AT categories, exploration strategies, or variant definitions. Run with:

    python -m tests.evals tests/evals/considerations/eval_photosensitive_seizure_prevention.py

Use `--consideration_context_mode all` to load the same stub task with all
elaborated considerations in background context, while still grading the
target photosensitive stub response.
"""

from __future__ import annotations

from inspect_ai import Task, task
from inspect_ai.dataset import Sample
from inspect_ai.solver import generate, system_message

from tests.evals import _providers
from tests.evals._context import load_eval_consideration_context
from tests.evals._scorers import rubric_scorer

CONSIDERATION_ALIAS = "photosensitive-seizure-prevention"
CONSIDERATION = load_eval_consideration_context(CONSIDERATION_ALIAS)


def _solver():
    return [system_message(CONSIDERATION), generate(**_providers.generation_config())]


@task
def stub_acknowledgement() -> Task:
    return Task(
        name="photosensitive_seizure_prevention_stub_acknowledgement",
        dataset=[
            Sample(
                input=(
                    "List the assistive technologies, exploration strategies, "
                    "and interaction contexts for this consideration."
                ),
            )
        ],
        solver=_solver(),
        scorer=rubric_scorer([
                {
                    "id": "declines_fabrication",
                    "description": (
                        "Does not fabricate or invent detailed assistive technologies, "
                        "exploration strategies, or interaction contexts beyond what the stub "
                        "consideration file contains."
                    ),
                    "weight": 2.0,
                },
                {
                    "id": "stays_within_clause_scope",
                    "description": (
                        "Stays within the high-level scope of clause 4.2.9 (photosensitive "
                        "seizure triggers) without over-elaborating into invented "
                        "categories."
                    ),
                    "weight": 1.0,
                },
            ])
    )
