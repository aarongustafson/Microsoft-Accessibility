"""Orchestrator for per-heuristic sub-agent evaluation.

The orchestrator decides which heuristics are in scope for an
evaluation and produces one focused sub-task per heuristic. Each
sub-task is built by ``build_heuristic_subtask`` and gets only the
heuristics index plus the one heuristic file it owns plus the
consideration.

This file is the entry point for the fan-out pattern: instead of one
big task with the entire heuristics aggregate, the orchestrator
returns a list of small tasks the eval runner can dispatch in
parallel.
"""

from __future__ import annotations

from collections.abc import Iterable

from inspect_ai import Task

from ._loaders import heuristic_count
from .heuristic_subtask import build_heuristic_subtask


def heuristics_in_scope(
    requested: Iterable[int] | None = None,
) -> list[int]:
    """Return the list of heuristic numbers the orchestrator will fan
    out to. By default all 10 are in scope; pass *requested* to limit
    the set (e.g. ``[1, 4, 7]`` for a focused review).
    """
    available = list(range(1, heuristic_count() + 1))
    if requested is None:
        return available
    requested_list = list(dict.fromkeys(int(n) for n in requested))
    out_of_range = [n for n in requested_list if n not in available]
    if out_of_range:
        raise ValueError(f"Heuristic numbers out of range: {out_of_range}")
    return requested_list


def build_per_heuristic_tasks(
    *,
    consideration_alias: str,
    artifact_description: str,
    heuristics: Iterable[int] | None = None,
) -> list[Task]:
    """Produce one focused sub-task per heuristic in scope.

    Args:
        consideration_alias: Consideration alias (e.g. ``"visual-adaptation"``) shared by
            all sub-tasks in this run.
        artifact_description: Plain-text description of the artifact.
            Passed verbatim to each sub-task.
        heuristics: Optional explicit list of heuristic numbers to
            evaluate. Defaults to all 10.
    """
    numbers = heuristics_in_scope(heuristics)
    return [
        build_heuristic_subtask(
            heuristic_number=n,
            consideration_alias=consideration_alias,
            artifact_description=artifact_description,
        )
        for n in numbers
    ]
