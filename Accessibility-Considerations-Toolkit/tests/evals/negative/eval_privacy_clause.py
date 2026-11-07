"""Pilot negative test: clause 4.2.11 (Privacy) is NOT a consideration.

The repository explicitly does not model 4.2.11 as a consideration — privacy
is a cross-cutting supplementary concern documented in
``heuristics/index.md``. A correct response should:

- State that 4.2.11 is not a consideration in this repository.
- Redirect to the 'Privacy / Discreet' supplementary concern.
- NOT fabricate consideration-style content (assistive technologies,
  exploration strategies, lens overrides) for clause 4.2.11.

Run with:

    python -m tests.evals tests/evals/negative/eval_privacy_clause.py
"""

from __future__ import annotations

from inspect_ai import Task, task
from inspect_ai.dataset import Sample
from inspect_ai.solver import generate, system_message

from tests.evals import _providers
from tests.evals._context import load_shared, load_heuristic_index
from tests.evals._scorers import rubric_scorer

# The Privacy/Discreet supplementary concern lives in the heuristics
# index, so we only load that (~4 KB) instead of the full 15 KB
# aggregate. This is a focused-loading win the split layout enables.
SYSTEM = (
    "You are an accessibility evaluator answering questions about the "
    "Accessibility Considerations Toolkit (Act) knowledge base. Use only what is in your reference "
    "context. If something is not modelled, say so explicitly rather than "
    "improvising.\n\n"
    "# Heuristics index (supplementary concerns + Nielsen menu)\n\n"
    f"{load_heuristic_index()}\n\n"
    "# Shared reference\n\n"
    f"{load_shared()}"
)


@task
def privacy_clause_is_not_a_consideration() -> Task:
    return Task(
        name="privacy_clause_is_not_a_consideration",
        dataset=[
            Sample(
                input=(
                    "Provide the consideration definition for FPS clause 4.2.11 "
                    "(Privacy). Include its assistive technologies, "
                    "exploration strategies, interaction contexts, and heuristic "
                    "lens overrides."
                ),
            )
        ],
        solver=[
            system_message(SYSTEM),
            generate(**_providers.generation_config()),
        ],
        scorer=rubric_scorer(
            [
                {
                    "id": "states_not_modelled_as_consideration",
                    "description": (
                        "Explicitly states that 4.2.11 is NOT modelled as "
                        "a consideration in this repository."
                    ),
                    "weight": 2.0,
                },
                {
                    "id": "redirects_to_supplementary_concern",
                    "description": (
                        "Redirects the user to the 'Privacy / Discreet' "
                        "supplementary concern in the heuristics index as "
                        "the correct location for 4.2.11 coverage."
                    ),
                    "weight": 1.5,
                },
                {
                    "id": "does_not_fabricate_at",
                    "description": (
                        "Does NOT invent assistive technologies for a "
                        "4.2.11 consideration (e.g. listing 'privacy AT' or "
                        "specific products)."
                    ),
                    "weight": 1.5,
                },
                {
                    "id": "does_not_fabricate_strategies",
                    "description": (
                        "Does NOT invent exploration strategies, interaction "
                        "contexts, or heuristic lens overrides for a "
                        "4.2.11 consideration."
                    ),
                    "weight": 1.5,
                },
                {
                    "id": "explains_cross_cutting_nature",
                    "description": (
                        "Explains that privacy applies cross-cutting "
                        "across all considerations and heuristics — not as a "
                        "single consideration."
                    ),
                    "weight": 1.5,
                },
            ]
        ),
    )
