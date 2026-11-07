"""Parameterized per-heuristic loading evaluation.

Verifies the focused-loading contract across all 10 heuristics with a
live model: each heuristic gets its own ``Task`` built via the
sub-agent factory, so the model only ever sees the index + the one
heuristic + the consideration. The model must apply the correct heuristic
and stay in scope.

Use this eval to validate that the split layout works end-to-end
across the entire Nielsen set, not just Heuristic 1.

Run with:

    inspect eval tests/evals/heuristics/eval_per_heuristic_loading.py \
        --model copilot/gpt-5-mini

To run for a specific heuristic only:

    inspect eval tests/evals/heuristics/eval_per_heuristic_loading.py@h7

(each ``h<N>`` function below is its own selectable task).
"""

from __future__ import annotations

from inspect_ai import Task, task

from ..sub_agents.heuristic_subtask import build_heuristic_subtask

# Shared artifact used across all 10 sub-tasks. Kept compact so the
# model's attention is on heuristic application, not artifact recall.
ARTIFACT_DESCRIPTION = (
    "A multi-step web checkout flow with three steps: shipping, "
    "payment, and review. Step indicators sit at the top. Each step "
    "has a 'Continue' button and a 'Back' link. Validation errors "
    "appear inline below each field with red text. Submitting the "
    "final step shows a green success message and clears the form."
)

CONSIDERATION_ALIAS = "visual-adaptation"


def _h(n: int) -> Task:
    return build_heuristic_subtask(
        heuristic_number=n,
        consideration_alias=CONSIDERATION_ALIAS,
        artifact_description=ARTIFACT_DESCRIPTION,
    )


@task
def h1() -> Task:
    return _h(1)


@task
def h2() -> Task:
    return _h(2)


@task
def h3() -> Task:
    return _h(3)


@task
def h4() -> Task:
    return _h(4)


@task
def h5() -> Task:
    return _h(5)


@task
def h6() -> Task:
    return _h(6)


@task
def h7() -> Task:
    return _h(7)


@task
def h8() -> Task:
    return _h(8)


@task
def h9() -> Task:
    return _h(9)


@task
def h10() -> Task:
    return _h(10)
