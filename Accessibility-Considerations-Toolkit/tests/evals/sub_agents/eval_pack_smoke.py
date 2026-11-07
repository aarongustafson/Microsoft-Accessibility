"""Smoke eval for the per-heuristic sub-agent harness.

Verifies the orchestrator wires up correctly:

- ``build_per_heuristic_tasks`` returns the expected number of tasks.
- Each focused system prompt is materially smaller than the full
  aggregate (proving the split is paying off for sub-agents).
- A single-heuristic dispatch actually runs and produces a scored
  response.

The model evaluation here uses the inspect-ai bridge minimally; the
goal is structural verification, not model-quality measurement.

Run with:

    inspect eval tests/evals/sub_agents/eval_pack_smoke.py \
        --model copilot/gpt-5-mini
"""

from __future__ import annotations

from inspect_ai import Task, task

from .. import _providers  # noqa: F401  (apply provider env on import)
from .._context import load_heuristic, load_heuristic_index, load_heuristics
from ._loaders import build_focused_system
from .heuristic_subtask import build_heuristic_subtask
from .orchestrator import build_per_heuristic_tasks, heuristics_in_scope

# Tiny test artifact used as the input across the smoke evaluation.
SMOKE_ARTIFACT = (
    "A web checkout page with a single-step form: full name, email, "
    "credit card number, expiry, CVV, and a 'Place order' button. "
    "Validation errors appear inline below each field. The Place "
    "order button is disabled until all fields are filled."
)


def _assert_focused_payload_is_smaller_than_aggregate(
    consideration_alias: str,
) -> None:
    """The heuristics portion of each focused payload (index + one
    heuristic) must be smaller than the full heuristics aggregate.
    The consideration portion is identical in focused and unfocused systems,
    so it doesn't factor into the comparison. Guards against
    regressions that would re-inline the full aggregate.
    """
    aggregate_size = len(load_heuristics().encode("utf-8"))
    index_size = len(load_heuristic_index().encode("utf-8"))
    for n in heuristics_in_scope():
        # Sanity-check that build_focused_system still works for this
        # consideration; the size comparison itself uses the heuristics-only
        # portion to stay apples-to-apples with the aggregate.
        build_focused_system(
            heuristic_number=n,
            consideration_alias=consideration_alias,
        )
        heuristic_size = len(load_heuristic(n).encode("utf-8"))
        focused_heuristics_size = index_size + heuristic_size
        assert focused_heuristics_size < aggregate_size, (
            f"Heuristic {n}: focused heuristics section "
            f"{focused_heuristics_size} B not smaller than aggregate "
            f"{aggregate_size} B"
        )


@task
def smoke_orchestrator_wiring() -> Task:
    """Build a single heuristic sub-task and execute it.

    This is the minimal end-to-end check that the orchestrator +
    sub-task factories compose into a runnable inspect-ai task. The
    focused-payload size assertion guards against regressions that
    would re-inline the full aggregate.
    """
    _assert_focused_payload_is_smaller_than_aggregate("visual-adaptation")

    tasks = build_per_heuristic_tasks(
        consideration_alias="visual-adaptation",
        artifact_description=SMOKE_ARTIFACT,
        heuristics=[1],
    )
    assert len(tasks) == 1
    return tasks[0]


@task
def smoke_full_fanout_wiring() -> Task:
    """Build a sub-task for each heuristic; return the first one.

    Asserts the orchestrator produces 10 distinct tasks for the
    default scope. Only the first task is executed by inspect-ai when
    this returns a single Task, but the construction of all 10 is
    what we verify.
    """
    tasks = build_per_heuristic_tasks(
        consideration_alias="keyboard-interaction",
        artifact_description=SMOKE_ARTIFACT,
    )
    assert len(tasks) == 10
    names = [t.name for t in tasks]
    assert len(set(names)) == 10, f"Sub-task names not unique: {names}"
    return tasks[0]


@task
def smoke_single_heuristic_subtask_factory() -> Task:
    """Direct sub-task factory call (bypassing orchestrator)."""
    return build_heuristic_subtask(
        heuristic_number=5,
        consideration_alias="memory-attention-and-executive-function",
        artifact_description=SMOKE_ARTIFACT,
    )
