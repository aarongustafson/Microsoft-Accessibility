"""Deterministic eval: hidden answer-key grading for the cognitive-language consideration.

This task uses a deterministic scorer backed by a hidden answer key in
`Sample.metadata["answer_key"]`. The key is not sent to the model; only the prompt and
system context are.

These checks cover stable cognitive-language consideration knowledge that should reliably
be triggered by the evaluation context, including assistive-technology categories,
named assistive technologies, consideration-specific exploration strategies, the
scope-specific interaction contexts, inherited shared strategies, and bounded
behavior for reading dense text and completing form text inputs.

Run with:

    python -m tests.evals \
        copilot/gpt-5-mini \
        deterministic/language_and_communication.py

    python -m tests.evals \
        copilot/claude-sonnet-4.5 \
        deterministic/language_and_communication.py
"""

from __future__ import annotations

from inspect_ai import Task, task

from tests.evals._context import load_eval_consideration_context
from tests.evals.deterministic._consideration import build_consideration_deterministic_task

CONSIDERATION = load_eval_consideration_context("language-and-communication")


@task
def at_categories() -> Task:
    return build_consideration_deterministic_task(
        consideration_slug="language_and_communication",
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
        consideration_slug="language_and_communication",
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
        consideration_slug="language_and_communication",
        section_slug="exploration_strategies",
        task_name_suffix="",
        prompt=(
            "List the consideration-specific exploration strategies this cognitive-language "
            "evaluation covers. Exclude inherited conditional shared "
            "strategies. Use a short bullet list and keep each bullet to one "
            "line."
        ),
        consideration_prompt=CONSIDERATION,
    )()


@task
def interaction_contexts() -> Task:
    return build_consideration_deterministic_task(
        consideration_slug="language_and_communication",
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
        consideration_slug="language_and_communication",
        section_slug="shared_strategies",
        task_name_suffix="",
        prompt=(
            "List the inherited conditional shared exploration strategies that "
            "apply to this cognitive-language consideration. Use a short bullet list and "
            "keep each bullet to one line."
        ),
        consideration_prompt=CONSIDERATION,
    )()


@task
def behavior_reading_dense_text() -> Task:
    return build_consideration_deterministic_task(
        consideration_slug="language_and_communication",
        section_slug="behavior_reading_dense_text",
        task_name_suffix="",
        prompt=(
            "A user needing language or communication support encounters a page with long, dense "
            "paragraphs of technical or bureaucratic text with no icons or "
            "images. List the access checks relevant to this task to "
            "determine whether they can understand the content. Use a short "
            "bullet list and keep each bullet to one line."
        ),
        consideration_prompt=CONSIDERATION,
    )()


@task
def behavior_form_text_input() -> Task:
    return build_consideration_deterministic_task(
        consideration_slug="language_and_communication",
        section_slug="behavior_form_text_input",
        task_name_suffix="",
        prompt=(
            "A user needing language or communication support needs to fill in a free-text form field "
            "that requires typed input. List the documented access options to "
            "check first to assess whether the form supports their writing "
            "needs. Use a short bullet list and keep each bullet to one line."
        ),
        consideration_prompt=CONSIDERATION,
    )()
