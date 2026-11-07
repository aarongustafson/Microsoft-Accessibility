"""Deterministic eval: hidden answer-key grading for the keyboard-only consideration.

This task uses a deterministic scorer backed by a hidden answer key in
`Sample.metadata["answer_key"]`. The key is not sent to the model; only the prompt and
system context are.

These checks cover stable keyboard-only consideration knowledge that should reliably
be triggered by the evaluation context, including assistive-technology categories,
named assistive technologies, consideration-specific exploration strategies, the
scope-specific interaction contexts, inherited shared strategies, and bounded
behavior for reaching a visible action efficiently, operating custom widgets,
and escaping overlays without getting trapped, including scenario tasks for
complex pages and rich interaction interfaces.

Run with:

    python -m tests.evals \
        copilot/gpt-5-mini \
        deterministic/keyboard_interaction.py

    python -m tests.evals \
        copilot/claude-sonnet-4.5 \
        deterministic/keyboard_interaction.py
"""

from __future__ import annotations

from inspect_ai import Task, task

from tests.evals._context import load_eval_consideration_context
from tests.evals.deterministic._consideration import build_consideration_deterministic_task

CONSIDERATION = load_eval_consideration_context("keyboard-interaction")


@task
def at_categories() -> Task:
    return build_consideration_deterministic_task(
        consideration_slug="keyboard_interaction",
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
        consideration_slug="keyboard_interaction",
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
        consideration_slug="keyboard_interaction",
        section_slug="exploration_strategies",
        task_name_suffix="",
        prompt=(
            "List the consideration-specific exploration strategies this keyboard-only "
            "evaluation covers. Exclude inherited conditional shared "
            "strategies. Use a short bullet list and keep each bullet to one "
            "line."
        ),
        consideration_prompt=CONSIDERATION,
    )()


@task
def interaction_contexts() -> Task:
    return build_consideration_deterministic_task(
        consideration_slug="keyboard_interaction",
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
        consideration_slug="keyboard_interaction",
        section_slug="shared_strategies",
        task_name_suffix="",
        prompt=(
            "List the inherited conditional shared exploration strategies that "
            "apply to this keyboard-only consideration, and also name any excluded shared "
            "strategy. Use a short bullet list and keep each bullet to one line."
        ),
        consideration_prompt=CONSIDERATION,
    )()


@task
def behavior_navigation_primary_action() -> Task:
    return build_consideration_deterministic_task(
        consideration_slug="keyboard_interaction",
        section_slug="behavior_navigation_primary_action",
        task_name_suffix="",
        prompt=(
            "A user operating by keyboard alone can already see the page and knows which "
            "primary action they want. List the documented access options to "
            "check first to reach it efficiently without a mouse. Use a "
            "short bullet list and keep each bullet to one line."
        ),
        consideration_prompt=CONSIDERATION,
    )()


@task
def behavior_interaction_custom_widget() -> Task:
    return build_consideration_deterministic_task(
        consideration_slug="keyboard_interaction",
        section_slug="behavior_interaction_custom_widget",
        task_name_suffix="",
        prompt=(
            "A user operating by keyboard alone reaches a custom widget such as a menu, "
            "tablist, dropdown, or date picker. List the access checks "
            "needed to tell whether it is fully operable without a "
            "mouse. Use a short bullet list and keep each bullet to one line."
        ),
        consideration_prompt=CONSIDERATION,
    )()


@task
def behavior_escape_overlay() -> Task:
    return build_consideration_deterministic_task(
        consideration_slug="keyboard_interaction",
        section_slug="behavior_escape_overlay",
        task_name_suffix="",
        prompt=(
            "A user operating by keyboard alone opens a dialog, menu, or other overlay and "
            "wants to continue or back out safely. List the access checks "
            "needed to avoid traps or loss of context. "
            "Use a short bullet list and keep each bullet to one line."
        ),
        consideration_prompt=CONSIDERATION,
    )()


@task
def behavior_review_complex_page() -> Task:
    return build_consideration_deterministic_task(
        consideration_slug="keyboard_interaction",
        section_slug="behavior_review_complex_page",
        task_name_suffix="",
        prompt=(
            "A user operating by keyboard alone is reviewing a complex web page with a "
            "sticky header, skip link, filter sidebar, long results area, "
            "comparison table, newsletter signup form, and an occasional "
            "promo modal. They can see the page and know what they want, but "
            "must operate everything without a mouse. List the access checks "
            "needed to tell whether the page is efficient and "
            "safe to use by keyboard only. Use a short bullet list and keep "
            "each bullet to one line."
        ),
        consideration_prompt=CONSIDERATION,
    )()


@task
def behavior_review_interaction_heavy_page() -> Task:
    return build_consideration_deterministic_task(
        consideration_slug="keyboard_interaction",
        section_slug="behavior_review_interaction_heavy_page",
        task_name_suffix="",
        prompt=(
            "A user operating by keyboard alone is reviewing a rich interaction interface "
            "with a left navigation pane, toolbar, tablist, custom dropdowns, "
            "date picker, command palette, and modal dialogs. List the access "
            "checks needed to verify the interface is fully "
            "operable and does not trap them when using only the keyboard. Use "
            "a short bullet list and keep each bullet to one line."
        ),
        consideration_prompt=CONSIDERATION,
    )()
