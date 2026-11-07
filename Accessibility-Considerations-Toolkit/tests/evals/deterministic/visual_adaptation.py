"""Deterministic eval: hidden answer-key grading for the low-vision consideration.

This task uses a deterministic scorer backed by a hidden answer key in
`Sample.metadata["answer_key"]`. The key is not sent to the model; only the prompt and
system context are.

These checks cover stable low-vision consideration knowledge that should reliably be
triggered by the evaluation context, including both assistive-technology categories
and named assistive technologies, the distinct low-vision user types the
evaluator must consider, the consideration-specific exploration strategies, the
scope-specific interaction contexts, and bounded behavior for zoomed reading,
magnified orientation, and forced-colours visibility, including scenario tasks
for complex pages and chart-heavy analytics views.

Run with:

    python -m tests.evals \
        copilot/gpt-5-mini \
        deterministic/visual_adaptation.py

    python -m tests.evals \
        copilot/claude-sonnet-4.5 \
        deterministic/visual_adaptation.py
"""

from __future__ import annotations

from inspect_ai import Task, task

from tests.evals._context import load_eval_consideration_context
from tests.evals.deterministic._consideration import build_consideration_deterministic_task

CONSIDERATION = load_eval_consideration_context("visual-adaptation")


@task
def at_categories() -> Task:
    return build_consideration_deterministic_task(
        consideration_slug="visual_adaptation",
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
        consideration_slug="visual_adaptation",
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
def contexts() -> Task:
    return build_consideration_deterministic_task(
        consideration_slug="visual_adaptation",
        section_slug="contexts",
        task_name_suffix="",
        prompt=(
            "When evaluating an interface with this consideration, list the distinct "
            "low-vision user types the evaluator must consider. Use a short "
            "bullet list and keep each bullet to one line."
        ),
        consideration_prompt=CONSIDERATION,
    )()


@task
def exploration_strategies() -> Task:
    return build_consideration_deterministic_task(
        consideration_slug="visual_adaptation",
        section_slug="exploration_strategies",
        task_name_suffix="",
        prompt=(
            "List the consideration-specific exploration strategies this low-vision "
            "evaluation covers. Exclude inherited conditional shared "
            "strategies. Use a short bullet list and keep each bullet to one "
            "line."
        ),
        consideration_prompt=CONSIDERATION,
    )()


@task
def interaction_contexts() -> Task:
    return build_consideration_deterministic_task(
        consideration_slug="visual_adaptation",
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
def behavior_zoomed_reading_reflow() -> Task:
    return build_consideration_deterministic_task(
        consideration_slug="visual_adaptation",
        section_slug="behavior_zoomed_reading_reflow",
        task_name_suffix="",
        prompt=(
            "A user needing magnification or visual adaptation increases text size or browser zoom because the "
            "default page is hard to read. List the documented access options to "
            "check first to tell whether the page still works comfortably. Use "
            "a short bullet list and keep each bullet to one line."
        ),
        consideration_prompt=CONSIDERATION,
    )()


@task
def behavior_magnified_viewport_orientation() -> Task:
    return build_consideration_deterministic_task(
        consideration_slug="visual_adaptation",
        section_slug="behavior_magnified_viewport_orientation",
        task_name_suffix="",
        prompt=(
            "A user needing magnification or visual adaptation is using a screen magnifier and can see only a "
            "small part of the interface at once. List the access checks "
            "needed for orientation and avoiding loss of content while "
            "moving around. Use a short bullet list and keep each bullet to one "
            "line."
        ),
        consideration_prompt=CONSIDERATION,
    )()


@task
def behavior_high_contrast_visibility() -> Task:
    return build_consideration_deterministic_task(
        consideration_slug="visual_adaptation",
        section_slug="behavior_high_contrast_visibility",
        task_name_suffix="",
        prompt=(
            "A user needing magnification or visual adaptation turns on a high-contrast or forced-colours theme "
            "before using the page. List the documented access options to check "
            "first to confirm the interface is still understandable and usable. "
            "Use a short bullet list and keep each bullet to one line."
        ),
        consideration_prompt=CONSIDERATION,
    )()


@task
def behavior_review_complex_page() -> Task:
    return build_consideration_deterministic_task(
        consideration_slug="visual_adaptation",
        section_slug="behavior_review_complex_page",
        task_name_suffix="",
        prompt=(
            "A user needing magnification or visual adaptation is reviewing a complex web page with a sticky "
            "header, filter sidebar, long results list, comparison table, "
            "newsletter signup form, autocomplete suggestions, and toast "
            "messages. They may use browser zoom, a screen magnifier, or a "
            "high-contrast theme. List the documented access options to check "
            "first to tell whether the page remains readable, oriented, and "
            "usable. Use a short bullet list and keep each bullet to one line."
        ),
        consideration_prompt=CONSIDERATION,
    )()


@task
def behavior_review_chart_heavy_analytics_page() -> Task:
    return build_consideration_deterministic_task(
        consideration_slug="visual_adaptation",
        section_slug="behavior_review_chart_heavy_analytics_page",
        task_name_suffix="",
        prompt=(
            "A user needing magnification or visual adaptation is reviewing a chart-heavy analytics page "
            "with multiple line and bar charts, a heatmap, legends, hover "
            "tooltips, summary cards, and filter controls. They may use 200% "
            "zoom, high magnification, or forced-colours mode. List the access "
            "checks needed to tell whether the charts and "
            "supporting controls remain readable and understandable. Use a "
            "short bullet list and keep each bullet to one line."
        ),
        consideration_prompt=CONSIDERATION,
    )()
