"""Deterministic eval: hidden answer-key grading for nonvisual access.

This task uses a deterministic scorer backed by a hidden answer key in
`Sample.metadata["answer_key"]`. The key is not sent to the model; only the prompt and
system context are.

These checks cover stable blind-consideration knowledge that should reliably be
triggered by the evaluation context, including assistive-technology categories,
named assistive technologies, consideration-specific exploration strategies, the
scope-specific interaction contexts, and bounded navigation behavior for common
tasks such as finding a button, reaching main content, navigating a complex
page efficiently, interacting with a form, or recovering from form errors.

Run with:

    python -m tests.evals \
        copilot/gpt-5-mini \
        deterministic/nonvisual_access.py

    python -m tests.evals \
        copilot/claude-sonnet-4.5 \
        deterministic/nonvisual_access.py
"""

from __future__ import annotations

from inspect_ai import Task, task

from tests.evals._context import load_eval_consideration_context
from tests.evals.deterministic._consideration import build_consideration_deterministic_task

CONSIDERATION = load_eval_consideration_context("nonvisual-access")


@task
def at_categories() -> Task:
    return build_consideration_deterministic_task(
        consideration_slug="nonvisual-access",
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
        consideration_slug="nonvisual-access",
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
        consideration_slug="nonvisual-access",
        section_slug="exploration_strategies",
        task_name_suffix="",
        prompt=(
            "List the exploration strategies documented for nonvisual "
            "access checks. Exclude inherited conditional shared "
            "strategies. Use a short bullet list and keep each bullet to one "
            "line."
        ),
        consideration_prompt=CONSIDERATION,
    )()


@task
def interaction_contexts() -> Task:
    return build_consideration_deterministic_task(
        consideration_slug="nonvisual-access",
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
def behavior_navigation_button() -> Task:
    return build_consideration_deterministic_task(
        consideration_slug="nonvisual-access",
        section_slug="behavior_navigation_button",
        task_name_suffix="",
        prompt=(
            "A user relying on nonvisual access needs to find a button somewhere on the page. "
            "List supported ways to locate it across common "
            "screen reader interaction patterns. Use a short bullet list and "
            "keep each bullet to one line."
        ),
        consideration_prompt=CONSIDERATION,
    )()


@task
def behavior_navigation_main_content() -> Task:
    return build_consideration_deterministic_task(
        consideration_slug="nonvisual-access",
        section_slug="behavior_navigation_main_content",
        task_name_suffix="",
        prompt=(
            "A user relying on nonvisual access lands on a busy page and wants to get oriented and "
            "reach the main content quickly. List the documented access options to "
            "try first, including at least one approach that would still work "
            "for a less experienced screen reader user. Use a short bullet "
            "list and keep each bullet to one line."
        ),
        consideration_prompt=CONSIDERATION,
    )()


@task
def behavior_navigation_complex_page() -> Task:
    return build_consideration_deterministic_task(
        consideration_slug="nonvisual-access",
        section_slug="behavior_navigation_complex_page",
        task_name_suffix="",
        prompt=(
            "A desktop screen-reader user relying on nonvisual access lands on a complex web page "
            "with a global navigation bar, a site search field, a promotional "
            "banner, a filter sidebar, a long results area, a comparison table, "
            "and a newsletter signup form near the end of the page. They want "
            "to get oriented quickly, skip repeated page chrome, jump to the "
            "main results, inspect the comparison table, complete the signup "
            "form, and confirm whether submission succeeded. List supported "
            "assistive-technology actions and exploration strategies to check "
            "for efficient task completion. Use a short bullet list and keep "
            "each bullet to one line."
        ),
        consideration_prompt=CONSIDERATION,
    )()


@task
def behavior_interaction_form() -> Task:
    return build_consideration_deterministic_task(
        consideration_slug="nonvisual-access",
        section_slug="behavior_interaction_form",
        task_name_suffix="",
        prompt=(
            "A user relying on nonvisual access needs to complete a form they have not seen before. "
            "List the access actions that can help to understand the form, move "
            "through it, and tell what happened after submission. Use a short "
            "bullet list and keep each bullet to one line."
        ),
        consideration_prompt=CONSIDERATION,
    )()


@task
def behavior_recovery_form_errors() -> Task:
    return build_consideration_deterministic_task(
        consideration_slug="nonvisual-access",
        section_slug="behavior_recovery_form_errors",
        task_name_suffix="",
        prompt=(
            "A user relying on nonvisual access submits a form and something goes wrong. List the "
            "access options to check to understand the problem, get back "
            "to the right place, and confirm they have recovered successfully. "
            "Use a short bullet list and keep each bullet to one line."
        ),
        consideration_prompt=CONSIDERATION,
    )()