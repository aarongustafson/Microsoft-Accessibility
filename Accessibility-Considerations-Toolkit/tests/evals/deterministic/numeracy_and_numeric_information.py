"""Deterministic eval: hidden answer-key grading for the cognitive-numeracy consideration.

This task uses a deterministic scorer backed by a hidden answer key in
`Sample.metadata["answer_key"]`. The key is not sent to the model; only the prompt and
system context are.

These checks cover stable cognitive-numeracy consideration knowledge that should reliably
be triggered by the evaluation context, including assistive-technology categories,
named assistive technologies, consideration-specific exploration strategies, the
scope-specific interaction contexts, inherited shared strategies, and bounded
behavior for pricing comparison and date/time selection.

Run with:

    python -m tests.evals \
        copilot/gpt-5-mini \
        deterministic/numeracy_and_numeric_information.py

    python -m tests.evals \
        copilot/claude-sonnet-4.5 \
        deterministic/numeracy_and_numeric_information.py
"""

from __future__ import annotations

from inspect_ai import Task, task

from tests.evals._context import load_eval_consideration_context
from tests.evals.deterministic._consideration import build_consideration_deterministic_task

CONSIDERATION = load_eval_consideration_context("numeracy-and-numeric-information")


@task
def at_categories() -> Task:
    return build_consideration_deterministic_task(
        consideration_slug="numeracy_and_numeric_information",
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
        consideration_slug="numeracy_and_numeric_information",
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
        consideration_slug="numeracy_and_numeric_information",
        section_slug="exploration_strategies",
        task_name_suffix="",
        prompt=(
            "List the consideration-specific exploration strategies this cognitive-numeracy "
            "evaluation covers. Exclude inherited conditional shared "
            "strategies. Use a short bullet list and keep each bullet to one "
            "line."
        ),
        consideration_prompt=CONSIDERATION,
    )()


@task
def interaction_contexts() -> Task:
    return build_consideration_deterministic_task(
        consideration_slug="numeracy_and_numeric_information",
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
        consideration_slug="numeracy_and_numeric_information",
        section_slug="shared_strategies",
        task_name_suffix="",
        prompt=(
            "List the inherited conditional shared exploration strategies that "
            "apply to this cognitive-numeracy consideration. Use a short bullet list and "
            "keep each bullet to one line."
        ),
        consideration_prompt=CONSIDERATION,
    )()


@task
def behavior_pricing_comparison() -> Task:
    return build_consideration_deterministic_task(
        consideration_slug="numeracy_and_numeric_information",
        section_slug="behavior_pricing_comparison",
        task_name_suffix="",
        prompt=(
            "A user needing support interpreting numbers is reviewing a pricing page with multiple "
            "plans showing amounts in different currencies and units. List the "
            "access checks needed to assess whether the page supports "
            "comparison without mental arithmetic. Use a short bullet list "
            "and keep each bullet to one line."
        ),
        consideration_prompt=CONSIDERATION,
    )()


@task
def behavior_date_time_selection() -> Task:
    return build_consideration_deterministic_task(
        consideration_slug="numeracy_and_numeric_information",
        section_slug="behavior_date_time_selection",
        task_name_suffix="",
        prompt=(
            "A user needing support interpreting numbers needs to select check-in and check-out "
            "dates on a hotel booking page. List the documented access options to "
            "check first to determine whether they can complete the task "
            "without date arithmetic. Use a short bullet list and keep each "
            "bullet to one line."
        ),
        consideration_prompt=CONSIDERATION,
    )()
