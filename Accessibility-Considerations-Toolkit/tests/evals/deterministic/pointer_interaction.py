"""Deterministic eval: hidden answer-key grading for the limited-reach consideration.

This task uses a deterministic scorer backed by a hidden answer key in
`Sample.metadata["answer_key"]`. The key is not sent to the model; only the prompt and
system context are.

These checks cover stable limited-reach consideration knowledge that should reliably
be triggered by the evaluation context, including assistive-technology categories,
named assistive technologies, consideration-specific exploration strategies, the
scope-specific interaction contexts, inherited shared strategies, and bounded
behavior for assessing target sizes and drag alternatives.

Run with:

    python -m tests.evals \
        copilot/gpt-5-mini \
        deterministic/pointer_interaction.py

    python -m tests.evals \
        copilot/claude-sonnet-4.5 \
        deterministic/pointer_interaction.py
"""

from __future__ import annotations

from inspect_ai import Task, task

from tests.evals._context import load_eval_consideration_context
from tests.evals.deterministic._consideration import build_consideration_deterministic_task

CONSIDERATION = load_eval_consideration_context("pointer-interaction")


@task
def at_categories() -> Task:
    return build_consideration_deterministic_task(
        consideration_slug="pointer_interaction",
        section_slug="at_categories",
        task_name_suffix="",
        prompt=(
            "Name the assistive technology categories described in this "
            "consideration. Use a short bullet list and keep each bullet to one "
            "line."
        ),
        consideration_prompt=CONSIDERATION,
    )()


@task
def assistive_technologies() -> Task:
    return build_consideration_deterministic_task(
        consideration_slug="pointer_interaction",
        section_slug="assistive_technologies",
        task_name_suffix="",
        prompt=(
            "List the named assistive technologies described in this "
            "consideration's Assistive Technologies section. Use the specific "
            "technology names from the consideration, not just broad categories. "
            "Use a short bullet list and keep each bullet to one line."
        ),
        consideration_prompt=CONSIDERATION,
    )()


@task
def exploration_strategies() -> Task:
    return build_consideration_deterministic_task(
        consideration_slug="pointer_interaction",
        section_slug="exploration_strategies",
        task_name_suffix="",
        prompt=(
            "List the consideration-specific exploration strategies this limited-reach "
            "evaluation covers. Exclude inherited conditional shared "
            "strategies. Use a short bullet list and keep each bullet to one "
            "line."
        ),
        consideration_prompt=CONSIDERATION,
    )()


@task
def interaction_contexts() -> Task:
    return build_consideration_deterministic_task(
        consideration_slug="pointer_interaction",
        section_slug="interaction_contexts",
        task_name_suffix="",
        prompt=(
            "List the scope-specific interaction contexts defined for this "
            "consideration. Exclude the New/Expert shared contexts. "
            "Use a short bullet list and keep each bullet to one line."
        ),
        consideration_prompt=CONSIDERATION,
    )()


@task
def shared_strategies() -> Task:
    return build_consideration_deterministic_task(
        consideration_slug="pointer_interaction",
        section_slug="shared_strategies",
        task_name_suffix="",
        prompt=(
            "List the inherited conditional shared exploration strategies that "
            "apply to this limited-reach consideration. Use a short bullet list and keep "
            "each bullet to one line."
        ),
        consideration_prompt=CONSIDERATION,
    )()


@task
def behavior_target_assessment() -> Task:
    return build_consideration_deterministic_task(
        consideration_slug="pointer_interaction",
        section_slug="behavior_target_assessment",
        task_name_suffix="",
        prompt=(
            "A user operating with the stated pointer constraints is reviewing a page with many small clickable "
            "elements close together. List the documented access options to check "
            "first to assess whether the targets are safe and reachable for "
            "them. Use a short bullet list and keep each bullet to one line."
        ),
        consideration_prompt=CONSIDERATION,
    )()


@task
def behavior_drag_alternative() -> Task:
    return build_consideration_deterministic_task(
        consideration_slug="pointer_interaction",
        section_slug="behavior_drag_alternative",
        task_name_suffix="",
        prompt=(
            "A user operating with the stated pointer constraints encounters a slider or reorder control that "
            "requires dragging. List the access checks relevant to this task "
            "to determine if there is a usable single-pointer alternative. "
            "Use a short bullet list and keep each bullet to one line."
        ),
        consideration_prompt=CONSIDERATION,
    )()
