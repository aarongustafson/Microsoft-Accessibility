"""Deterministic eval: hidden answer-key grading for the voice-access consideration.

This task uses a deterministic scorer backed by a hidden answer key in
`Sample.metadata["answer_key"]`. The key is not sent to the model; only the prompt and
system context are.

These checks cover stable voice-access consideration knowledge that should reliably
be triggered by the evaluation context, including assistive-technology categories,
named assistive technologies, consideration-specific exploration strategies,
scope-specific interaction contexts, inherited shared strategies, and bounded
behavior for label-based activation, fallback targeting, and dictation,
including scenario tasks for complex pages and rich interaction interfaces.

Run with:

    python -m tests.evals \
        copilot/gpt-5-mini \
        deterministic/voice_control.py

    python -m tests.evals \
        copilot/claude-sonnet-4.5 \
        deterministic/voice_control.py
"""

from __future__ import annotations

from inspect_ai import Task, task

from tests.evals._context import load_eval_consideration_context
from tests.evals.deterministic._consideration import build_consideration_deterministic_task

CONSIDERATION = load_eval_consideration_context("voice-control")


@task
def at_categories() -> Task:
    return build_consideration_deterministic_task(
        consideration_slug="voice_control",
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
        consideration_slug="voice_control",
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
        consideration_slug="voice_control",
        section_slug="exploration_strategies",
        task_name_suffix="",
        prompt=(
            "List the consideration-specific exploration strategies this voice-access "
            "evaluation covers. Exclude inherited conditional shared "
            "strategies. Use a short bullet list and keep each bullet to one "
            "line."
        ),
        consideration_prompt=CONSIDERATION,
    )()


@task
def interaction_contexts() -> Task:
    return build_consideration_deterministic_task(
        consideration_slug="voice_control",
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
        consideration_slug="voice_control",
        section_slug="shared_strategies",
        task_name_suffix="",
        prompt=(
            "List the inherited conditional shared exploration strategies that "
            "apply to this voice-access consideration, then list excluded shared strategies "
            "in a separate section. Only report exclusions that are explicitly present in "
            "the consideration file's shared inheritance metadata or inline shared content. "
            "Do not infer additional exclusions from the disability description. Follow "
            "the consideration file literally: if a shared strategy appears inline in the "
            "consideration, treat it as applicable even if it seems surprising; if a shared "
            "strategy is named in `shared_excludes`, list it under excluded shared "
            "strategies. In this consideration, `mouse-pointer-interaction` is the explicit "
            "shared exclusion, while `Touch / pointer interaction` still appears inline "
            "and must remain in the applicable list. Use a short bullet list and keep each "
            "bullet to one line."
        ),
        consideration_prompt=CONSIDERATION,
    )()


@task
def behavior_activate_visible_control() -> Task:
    return build_consideration_deterministic_task(
        consideration_slug="voice_control",
        section_slug="behavior_activate_visible_control",
        task_name_suffix="",
        prompt=(
            "A user relying on voice control can see the control they want and wants the "
            "fastest way to activate it without using their hands. List the "
            "access checks needed to tell whether natural "
            "voice commands will work. Use a short bullet list and keep each "
            "bullet to one line."
        ),
        consideration_prompt=CONSIDERATION,
    )()


@task
def behavior_fallback_targeting_unlabeled_control() -> Task:
    return build_consideration_deterministic_task(
        consideration_slug="voice_control",
        section_slug="behavior_fallback_targeting_unlabeled_control",
        task_name_suffix="",
        prompt=(
            "A user relying on voice control finds a control they can see but cannot "
            "activate by saying its obvious name. List supported alternative "
            "access options to reach it and tell whether the interface is "
            "still workable. Use a short bullet list and keep each bullet to "
            "one line."
        ),
        consideration_prompt=CONSIDERATION,
    )()


@task
def behavior_dictation_text_input() -> Task:
    return build_consideration_deterministic_task(
        consideration_slug="voice_control",
        section_slug="behavior_dictation_text_input",
        task_name_suffix="",
        prompt=(
            "A user relying on voice control reaches a text field and needs to enter a "
            "sentence by dictation, then continue through the form. List the "
            "access checks needed to see whether text entry "
            "and editing will work smoothly. Use a short bullet list and keep "
            "each bullet to one line."
        ),
        consideration_prompt=CONSIDERATION,
    )()


@task
def behavior_review_complex_page() -> Task:
    return build_consideration_deterministic_task(
        consideration_slug="voice_control",
        section_slug="behavior_review_complex_page",
        task_name_suffix="",
        prompt=(
            "A user relying on voice control is reviewing a complex web page with a "
            "sticky header, search box, filter sidebar, long results area, "
            "comparison table, newsletter signup form, and occasional promo "
            "modal. They can see the page clearly but must operate it "
            "entirely by voice. List the access checks relevant to this task "
            "to tell whether the page is efficient and workable without any "
            "hand input. Use a short bullet list and keep each bullet to one "
            "line."
        ),
        consideration_prompt=CONSIDERATION,
    )()


@task
def behavior_review_interaction_heavy_page() -> Task:
    return build_consideration_deterministic_task(
        consideration_slug="voice_control",
        section_slug="behavior_review_interaction_heavy_page",
        task_name_suffix="",
        prompt=(
            "A user relying on voice control is reviewing a rich interaction interface "
            "with a left navigation pane, toolbar, icon-only buttons, custom "
            "dropdowns, command palette, date picker, modal dialogs, and text "
            "fields that support dictation. List the documented access options to "
            "check first to verify the interface remains efficient by voice, "
            "and that fallback methods are available when natural commands "
            "fail. Use a short bullet list and keep each bullet to one line."
        ),
        consideration_prompt=CONSIDERATION,
    )()