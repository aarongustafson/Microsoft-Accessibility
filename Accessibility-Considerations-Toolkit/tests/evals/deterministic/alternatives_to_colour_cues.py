"""Deterministic eval: hidden answer-key grading for the color-blind consideration.

This task uses a deterministic scorer backed by a hidden answer key in
`Sample.metadata["answer_key"]`. The key is not sent to the model; only the prompt and
system context are.

These checks cover stable color-blind-consideration knowledge that should reliably
be triggered by the evaluation context, including assistive-technology categories,
named assistive technologies, consideration-specific exploration strategies, the
scope-specific interaction contexts, and bounded behaviors for interpreting state
and identifying interactive affordances without relying on colour alone,
including a complex-page scenario with multiple colour-encoded signals.

Run with:

    python -m tests.evals \
        copilot/gpt-5-mini \
        deterministic/alternatives_to_colour_cues.py

    python -m tests.evals \
        copilot/claude-sonnet-4.5 \
        deterministic/alternatives_to_colour_cues.py
"""

from __future__ import annotations

from inspect_ai import Task, task

from tests.evals._context import load_eval_consideration_context
from tests.evals.deterministic._consideration import build_consideration_deterministic_task

CONSIDERATION = load_eval_consideration_context("alternatives-to-colour-cues")


@task
def at_categories() -> Task:
    return build_consideration_deterministic_task(
        consideration_slug="alternatives_to_colour_cues",
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
        consideration_slug="alternatives_to_colour_cues",
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
        consideration_slug="alternatives_to_colour_cues",
        section_slug="exploration_strategies",
        task_name_suffix="",
        prompt=(
            "List the consideration-specific exploration strategies this color-blind "
            "evaluation covers. Exclude inherited conditional shared "
            "strategies. Use a short bullet list and keep each bullet to one "
            "line."
        ),
        consideration_prompt=CONSIDERATION,
    )()


@task
def interaction_contexts() -> Task:
    return build_consideration_deterministic_task(
        consideration_slug="alternatives_to_colour_cues",
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
def behavior_interpretation_state_feedback() -> Task:
    return build_consideration_deterministic_task(
        consideration_slug="alternatives_to_colour_cues",
        section_slug="behavior_interpretation_state_feedback",
        task_name_suffix="",
        prompt=(
            "A user who cannot rely on colour differences encounters status and selection changes in an "
            "interface and needs to work out what changed without relying on "
            "colour. List the accessible cues to verify for this task. Use a short "
            "bullet list and keep each bullet to one line."
        ),
        consideration_prompt=CONSIDERATION,
    )()


@task
def behavior_interaction_affordance() -> Task:
    return build_consideration_deterministic_task(
        consideration_slug="alternatives_to_colour_cues",
        section_slug="behavior_interaction_affordance",
        task_name_suffix="",
        prompt=(
            "A user who cannot rely on colour differences lands on a page and needs to figure out what "
            "is interactive and what is just static content. List the access "
            "cues to check without relying on colour alone. "
            "Use a short bullet list and keep each bullet to one line."
        ),
        consideration_prompt=CONSIDERATION,
    )()


@task
def behavior_navigation_red_button_protanopia() -> Task:
    return build_consideration_deterministic_task(
        consideration_slug="alternatives_to_colour_cues",
        section_slug="behavior_navigation_red_button_protanopia",
        task_name_suffix="",
        prompt=(
            "A user with protanopia is told to use the control that another "
            "person describes only as 'the red button'. List the access cues "
            "to verify which control is meant. Use "
            "a short bullet list and keep each bullet to one line."
        ),
        consideration_prompt=CONSIDERATION,
    )()


@task
def behavior_review_complex_page() -> Task:
    return build_consideration_deterministic_task(
        consideration_slug="alternatives_to_colour_cues",
        section_slug="behavior_review_complex_page",
        task_name_suffix="",
        prompt=(
            "A user who cannot rely on colour differences is reviewing a complex web page that includes "
            "a dashboard summary with red, green, and yellow status badges, a "
            "line chart with multiple coloured series and a legend, a filter "
            "panel with selected chips shown mainly by colour, a table where "
            "negative values are red and positive values are green, and a form "
            "whose validation states are shown with coloured borders. List the "
            "access cues and requirements to check to understand the page "
            "without relying on colour alone. Use a short bullet list and keep "
            "each bullet to one line."
        ),
        consideration_prompt=CONSIDERATION,
    )()


@task
def behavior_review_chart_heavy_analytics_page() -> Task:
    return build_consideration_deterministic_task(
        consideration_slug="alternatives_to_colour_cues",
        section_slug="behavior_review_chart_heavy_analytics_page",
        task_name_suffix="",
        prompt=(
            "A user who cannot rely on colour differences is reviewing a chart-heavy analytics page "
            "with multiple line and bar charts, a heatmap, coloured legends, "
            "red and green trend indicators, and hover tooltips that reveal "
            "series details. They need to compare data series, understand "
            "which trends are positive or negative, and tell whether the "
            "charts remain interpretable without relying on colour alone. "
            "List the access cues and requirements to check. Use a "
            "short bullet list and keep each bullet to one line."
        ),
        consideration_prompt=CONSIDERATION,
    )()
