"""Pilot eval: low-vision consideration (clause 4.2.2).

Five sub-tests verifying the consideration file transfers SME knowledge:

- AT recall
- Exploration strategy recall
- Interaction context recall
- Heuristic lens override application
- Shared inheritance awareness

Each sub-test is a separate `@task` so it has its own rubric. Run with:

    python -m tests.evals tests/evals/considerations/eval_visual_adaptation.py

Use `--consideration_context_mode all` to run the same tasks with all
elaborated considerations loaded in background context, while still grading
low-vision answers.

Add `-T` to limit to one sub-test, e.g. `--task at_recall`.
"""

from __future__ import annotations

from pathlib import Path

from inspect_ai import Task, task
from inspect_ai.dataset import Sample
from inspect_ai.model import ChatMessageUser, ContentImage, ContentText
from inspect_ai.solver import generate, system_message

from tests.evals import _providers
from tests.evals._context import load_eval_consideration_context
from tests.evals._scorers import rubric_scorer

CONSIDERATION_ALIAS = "visual-adaptation"
CONSIDERATION = load_eval_consideration_context(CONSIDERATION_ALIAS)
COMBOBOX_IMAGE = (
    Path(__file__).resolve().parents[2]
    / "fixtures"
    / "images"
    / "combobox.png"
)


def _solver():
    return [system_message(CONSIDERATION), generate(**_providers.generation_config())]


def _combobox_image_prompt() -> list[ChatMessageUser]:
    return [
        ChatMessageUser(
            content=[
                ContentText(
                    text=(
                        "You are evaluating the attached synthetic service-selection screenshot from a low-vision "
                        "consideration perspective (EN 301 549 FPS 4.2.2).\n\n"
                        "Task:\n"
                        "1) Give an accessibility evaluation based only on visible evidence "
                        "in the screenshot.\n"
                        "2) Call out likely low-vision risks and likely strengths.\n"
                        "3) Separate confirmed observations from items that still require "
                        "interaction/tree checks.\n"
                        "4) Provide concrete remediation suggestions for the highest-impact "
                        "issues.\n"
                        "\nKeep the response concise but specific to what is visible."
                    )
                ),
                ContentImage(image=str(COMBOBOX_IMAGE), detail="low"),
            ]
        )
    ]


@task
def at_recall() -> Task:
    return Task(
        name="visual_adaptation_at_recall",
        dataset=[
            Sample(
                input=(
                    "Identify all assistive technology categories this evaluation scope documents. "
                    "For each, give a one-sentence interaction model that meaningfully "
                    "distinguishes it from the others, and name at least one concrete "
                    "example tool."
                ),
            )
        ],
        solver=_solver(),
        scorer=rubric_scorer(
            [
                {
                    "id": "covers_browser_zoom",
                    "description": (
                        "Mentions browser zoom AND notes that it triggers "
                        "content reflow / responsive breakpoints."
                    ),
                },
                {
                    "id": "covers_screen_magnifier_no_reflow",
                    "description": (
                        "Mentions a screen magnifier (ZoomText, Windows "
                        "Magnifier, or macOS Zoom) AND notes that it does "
                        "NOT trigger reflow — it magnifies the rendered "
                        "layout, requiring panning."
                    ),
                    "weight": 1.5,
                },
                {
                    "id": "covers_dpi_scaling",
                    "description": (
                        "Mentions OS-level text size or DPI / display scaling "
                        "as distinct from browser zoom."
                    ),
                    "weight": 0.75,
                },
                {
                    "id": "covers_high_contrast",
                    "description": (
                        "Mentions Windows High Contrast Mode or "
                        "forced-colours as a distinct AT category."
                    ),
                },
                {
                    "id": "covers_dual_channel",
                    "description": (
                        "Mentions a combined magnification + screen reader "
                        "configuration (e.g. Fusion / ZoomText + JAWS) as a "
                        "dual-channel AT setup."
                    ),
                    "weight": 0.5,
                },
                {
                    "id": "interaction_models_distinct",
                    "description": (
                        "Each AT entry has an interaction model that "
                        "meaningfully distinguishes it (not just renaming) — "
                        "e.g. reflow vs. panning, OS-wide vs. browser-only."
                    ),
                    "weight": 1.5,
                },
            ]
        ),
    )


@task
def strategy_recall() -> Task:
    return Task(
        name="visual_adaptation_strategy_recall",
        dataset=[
            Sample(
                input=(
                    "List the exploration strategies "
                    "documented for this scope (NOT conditional shared strategies). "
                    "For each, describe the access circumstances and interface requirements."
                ),
            )
        ],
        solver=_solver(),
        scorer=rubric_scorer(
            [
                {
                    "id": "zoomed_reading_reflow",
                    "description": (
                        "Includes 'Zoomed reading and text reflow' (or "
                        "equivalent) — increasing browser zoom and relying "
                        "on reflow."
                    ),
                },
                {
                    "id": "magnified_viewport_panning",
                    "description": (
                        "Includes magnified-viewport panning — moving a "
                        "small magnified viewport across the rendered "
                        "layout."
                    ),
                },
                {
                    "id": "focus_cursor_tracking",
                    "description": (
                        "Includes focus / cursor tracking as a strategy — "
                        "the magnifier following keyboard focus or pointer."
                    ),
                },
                {
                    "id": "high_contrast_scanning",
                    "description": (
                        "Includes scanning under high contrast / forced-"
                        "colours as a strategy."
                    ),
                },
                {
                    "id": "dual_channel_reading",
                    "description": (
                        "Includes dual-channel reading (magnification + "
                        "speech) as a strategy."
                    ),
                },
                {
                    "id": "excludes_shared_only",
                    "description": (
                        "Lists strategies that are consideration-specific. Strategies "
                        "marked as shared (visual scanning, mouse / pointer "
                        "interaction, reading and scrolling, form interaction, "
                        "navigation and wayfinding, touch / pointer "
                        "interaction) may be acknowledged as inherited but "
                        "should not dominate the list."
                    ),
                    "weight": 0.5,
                },
            ]
        ),
    )


@task
def variant_recall() -> Task:
    return Task(
        name="visual_adaptation_variant_recall",
        dataset=[
            Sample(
                input=(
                    "List the interaction contexts defined for this consideration "
                    "(scope-specific, NOT the New/Expert shared "
                    "contexts). Describe explicit circumstances and requirements "
                    "without predicting individual abilities."
                ),
            )
        ],
        solver=_solver(),
        scorer=rubric_scorer(
            [
                {
                    "id": "moderate_zoom_variant",
                    "description": (
                        "Includes a variant covering increased text size / "
                        "moderate browser zoom (relies on reflow, no "
                        "magnifier)."
                    ),
                },
                {
                    "id": "screen_magnifier_variant",
                    "description": (
                        "Includes a screen magnifier variant operating at "
                        "high magnification (e.g. 3×–8×) with a small "
                        "viewport requiring panning."
                    ),
                },
                {
                    "id": "high_contrast_variant",
                    "description": (
                        "Includes a contrast-sensitivity variant relying on "
                        "high contrast / forced-colours themes."
                    ),
                },
                {
                    "id": "dual_channel_variant",
                    "description": (
                        "Includes a dual-channel variant combining "
                        "magnification with a screen reader."
                    ),
                },
                {
                    "id": "differentiation_clear",
                    "description": (
                        "Each variant's differentiator is concrete and "
                        "actionable (e.g. specific zoom level, specific AT "
                        "combination), not just renaming the consideration."
                    ),
                },
            ]
        ),
    )


@task
def lens_override_h1() -> Task:
    return Task(
        name="visual_adaptation_lens_override_h1",
        dataset=[
            Sample(
                input=(
                    "How does Heuristic 1 (Visibility of System Status) "
                    "apply with magnification or forced-colours active? Focus on what "
                    "this consideration's lens override adds beyond the generic "
                    "accessibility lens — magnified viewport, forced-"
                    "colours, off-screen feedback, and similar concerns."
                ),
            )
        ],
        solver=_solver(),
        scorer=rubric_scorer(
            [
                {
                    "id": "viewport_locality",
                    "description": (
                        "Notes that status feedback must appear within (or "
                        "be brought into) the magnified viewport — distant "
                        "feedback may never be seen."
                    ),
                    "weight": 1.5,
                },
                {
                    "id": "forced_colours_status",
                    "description": (
                        "Notes that status indicators (progress bars, "
                        "spinners) must remain visible in forced-colours / "
                        "high-contrast mode."
                    ),
                },
                {
                    "id": "audio_supplement",
                    "description": (
                        "Suggests an audio / earcon channel that supplements "
                        "visual cues users may miss."
                    ),
                    "weight": 0.75,
                },
                {
                    "id": "focus_tracking",
                    "description": (
                        "Mentions magnifier focus tracking — bringing the "
                        "user to feedback near the activated control."
                    ),
                },
                {
                    "id": "consideration_specific",
                    "description": (
                        "The answer is specific to low-vision concerns and "
                        "does not just restate the generic Heuristic 1 "
                        "accessibility lens unchanged."
                    ),
                    "weight": 2.0,
                },
            ]
        ),
    )


@task
def shared_inheritance() -> Task:
    return Task(
        name="visual_adaptation_shared_inheritance",
        dataset=[
            Sample(
                input=(
                    "The conditional shared reference defines six exploration strategies: "
                    "Visual scanning and layout comprehension, Mouse / pointer "
                    "interaction, Reading and scrolling, Form interaction, "
                    "Navigation and wayfinding, Touch / pointer interaction. "
                    "For each, state whether THIS consideration inherits it and "
                    "justify document scope without inferring unrelated "
                    "abilities. Do not introduce strategies "
                    "outside this list."
                ),
            )
        ],
        solver=_solver(),
        scorer=rubric_scorer(
            [
                {
                    "id": "all_strategies_apply",
                    "description": (
                        "States that the low-vision consideration has NO shared "
                        "exclusions — visual scanning, mouse / pointer "
                        "interaction, reading and scrolling, form "
                        "interaction, navigation and wayfinding, and touch "
                        "/ pointer interaction all apply."
                    ),
                    "weight": 2.0,
                },
                {
                    "id": "no_false_exclusions",
                    "description": (
                        "Does NOT incorrectly claim mouse/pointer or visual "
                        "scanning is excluded for low-vision users (those "
                        "are excluded for blind / keyboard-only considerations, "
                        "not low-vision)."
                    ),
                    "weight": 1.5,
                },
                {
                    "id": "justifications_grounded",
                    "description": (
                        "Justifications reference conditional applicability "
                        "in this scope (e.g. visual scanning "
                        "with magnification), not generic descriptions of "
                        "the strategies themselves."
                    ),
                },
            ]
        ),
    )


@task
def image_combobox_review() -> Task:
    return Task(
        name="visual_adaptation_image_combobox_review",
        dataset=[
            Sample(
                input=_combobox_image_prompt(),
            )
        ],
        solver=_solver(),
        scorer=rubric_scorer(
            [
                {
                    "id": "grounded_visual_evidence",
                    "description": (
                        "Grounds the evaluation in visible screenshot details "
                        "(e.g. small combobox trigger text, compact dropdown "
                        "options, layout density, or contrast-dependent cues), "
                        "rather than generic accessibility advice."
                    ),
                    "weight": 1.5,
                },
                {
                    "id": "applies_visual_adaptation_lens",
                    "description": (
                        "Applies low-vision specific reasoning such as zoom/reflow "
                        "readability, magnified viewport scanning effort, target "
                        "discernibility, or forced-colours robustness."
                    ),
                    "weight": 1.5,
                },
                {
                    "id": "balanced_strengths_and_risks",
                    "description": (
                        "Includes at least one likely strength and at least one "
                        "likely risk in the screenshot, instead of only one-sided "
                        "criticism."
                    ),
                    "weight": 1.5,
                },
                {
                    "id": "confidence_gated_claims",
                    "description": (
                        "Distinguishes confirmed visual observations from items that "
                        "cannot be proven from a static screenshot alone (e.g. keyboard "
                        "flow, focus movement, accessibility tree semantics)."
                    ),
                    "weight": 1.5,
                },
                {
                    "id": "actionable_remediation",
                    "description": (
                        "Provides concrete remediation steps for highest-impact low-vision "
                        "issues (for example larger control text, stronger contrast, clearer "
                        "focus styling, spacing improvements)."
                    ),
                    "weight": 1.5,
                },
            ]
        ),
    )
