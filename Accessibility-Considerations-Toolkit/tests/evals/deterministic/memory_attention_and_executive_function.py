"""Deterministic eval: hidden answer-key grading for the cognitive-memory consideration.

This task uses a deterministic scorer backed by a hidden answer key in
`Sample.metadata["answer_key"]`. The key is not sent to the model; only the prompt and
system context are.

These checks cover stable cognitive-memory consideration knowledge that should reliably
be triggered by the evaluation context, including assistive-technology categories,
named assistive technologies, consideration-specific exploration strategies, the
scope-specific interaction contexts, inherited shared strategies, and bounded
behavior for multi-step forms and distraction/interruption handling.

Run with:

    python -m tests.evals \
        copilot/gpt-5-mini \
        deterministic/memory_attention_and_executive_function.py

    python -m tests.evals \
        copilot/claude-sonnet-4.5 \
        deterministic/memory_attention_and_executive_function.py
"""

from __future__ import annotations

from inspect_ai import Task, task

from tests.evals._context import load_eval_consideration_context
from tests.evals.deterministic._consideration import build_consideration_deterministic_task

CONSIDERATION = load_eval_consideration_context("memory-attention-and-executive-function")


@task
def at_categories() -> Task:
    return build_consideration_deterministic_task(
        consideration_slug="memory_attention_and_executive_function",
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
        consideration_slug="memory_attention_and_executive_function",
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
        consideration_slug="memory_attention_and_executive_function",
        section_slug="exploration_strategies",
        task_name_suffix="",
        prompt=(
            "List the consideration-specific exploration strategies this cognitive-memory "
            "evaluation covers. Exclude inherited conditional shared "
            "strategies. Use a short bullet list and keep each bullet to one "
            "line."
        ),
        consideration_prompt=CONSIDERATION,
    )()


@task
def interaction_contexts() -> Task:
    return build_consideration_deterministic_task(
        consideration_slug="memory_attention_and_executive_function",
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
        consideration_slug="memory_attention_and_executive_function",
        section_slug="shared_strategies",
        task_name_suffix="",
        prompt=(
            "List the inherited conditional shared exploration strategies that "
            "apply to this cognitive-memory consideration. Use a short bullet list and keep "
            "each bullet to one line."
        ),
        consideration_prompt=CONSIDERATION,
    )()


@task
def behavior_multi_step_form() -> Task:
    return build_consideration_deterministic_task(
        consideration_slug="memory_attention_and_executive_function",
        section_slug="behavior_multi_step_form",
        task_name_suffix="",
        prompt=(
            "A user needing memory or attention support is filling out a multi-step online form. "
            "List the access checks relevant to this task to assess whether "
            "the form is safe and usable without relying on recall from "
            "previous steps. Use a short bullet list and keep each bullet to "
            "one line."
        ),
        consideration_prompt=CONSIDERATION,
    )()


@task
def behavior_distraction_interruption() -> Task:
    return build_consideration_deterministic_task(
        consideration_slug="memory_attention_and_executive_function",
        section_slug="behavior_distraction_interruption",
        task_name_suffix="",
        prompt=(
            "A user needing memory or attention support is working through a task when autoplaying "
            "content and notification popups appear on the page. List the "
            "access checks needed to determine whether the flow supports "
            "staying on track without loss of context. Use a short bullet "
            "list and keep each bullet to one line."
        ),
        consideration_prompt=CONSIDERATION,
    )()
