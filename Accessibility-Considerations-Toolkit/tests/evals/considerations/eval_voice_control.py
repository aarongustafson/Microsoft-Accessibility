"""Eval: voice-access consideration (clause 4.2.7b).

Five sub-tests verifying the consideration file transfers SME knowledge:

- AT recall
- Exploration strategy recall
- Interaction context recall
- Heuristic lens override application
- Shared inheritance awareness

Each sub-test is a separate `@task` so it has its own rubric. Run with:

    python -m tests.evals tests/evals/considerations/eval_voice_control.py

Use `--consideration_context_mode all` to run the same tasks with all
elaborated considerations loaded in background context, while still grading
voice-access answers.

Add `-T` to limit to one sub-test, e.g. `--task at_recall`.
"""

from __future__ import annotations

from inspect_ai import Task, task
from inspect_ai.dataset import Sample
from inspect_ai.solver import generate, system_message

from tests.evals import _providers
from tests.evals._context import load_eval_consideration_context
from tests.evals._scorers import rubric_scorer

CONSIDERATION_ALIAS = "voice-control"
CONSIDERATION = load_eval_consideration_context(CONSIDERATION_ALIAS)


def _solver():
    return [system_message(CONSIDERATION), generate(**_providers.generation_config())]


@task
def at_recall() -> Task:
    return Task(
        name="voice_control_at_recall",
        dataset=[
            Sample(
                input=(
                    "Identify the assistive technology category(ies) this evaluation scope documents. "
                    "For each, give a one-sentence interaction model and name at least "
                    "one concrete tool, distinguished by platform where relevant."
                ),
            )
        ],
        solver=_solver(),
        scorer=rubric_scorer(
            [
                {
                    "id": "covers_voice_control",
                    "description": (
                        "Mentions voice control software (e.g., Windows Voice Access, "
                        "macOS Voice Control, iOS Voice Control, Android Voice Access) as "
                        "the ONLY or PRIMARY AT category for this consideration."
                    ),
                    "weight": 2.0,
                },
                {
                    "id": "platform_specific_tools",
                    "description": (
                        "Distinguishes between different voice control platforms (Windows, "
                        "macOS, iOS, Android) and their specific capabilities."
                    ),
                    "weight": 1.5,
                },
                {
                    "id": "voice_interaction_model",
                    "description": (
                        "Explains that voice control operates by spoken commands to "
                        "activate controls, navigate, or dictate text input."
                    ),
                    "weight": 1.0,
                },
                {
                    "id": "no_false_categories",
                    "description": (
                        "Does NOT list manual input methods (keyboard, mouse, trackpad, "
                        "touchscreen) AS ATs AVAILABLE IN THIS EXPLICIT SCOPE. Mentioning them in a "
                        "negated/contrastive context (e.g., 'cannot use a keyboard or "
                        "mouse') is acceptable and counts as YES. Mark NO only if the "
                        "answer presents manual input as available or used by this "
                        "consideration, treating voice control as one option among many."
                    ),
                    "weight": 2.0,
                },
            ]
        ),
    )


@task
def strategy_recall() -> Task:
    return Task(
        name="voice_control_strategy_recall",
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
                    "id": "speaking_labels",
                    "description": (
                        "Includes speaking visible UI labels to activate controls "
                        "(e.g., 'click submit', 'select dropdown')."
                    ),
                    "weight": 1.5,
                },
                {
                    "id": "number_overlay_navigation",
                    "description": (
                        "Includes using numbered overlay navigation (e.g., 'show numbers' "
                        "then 'click 5') to activate off-label controls."
                    ),
                    "weight": 1.5,
                },
                {
                    "id": "grid_navigation",
                    "description": (
                        "Includes grid-based navigation (e.g., 'show grid', 'go to cell "
                        "3 5') for spatial navigation when labels are insufficient."
                    ),
                    "weight": 1.0,
                },
                {
                    "id": "dictation_input",
                    "description": (
                        "Includes using dictation to enter text without typing "
                        "(voice-to-text input)."
                    ),
                    "weight": 1.5,
                },
                {
                    "id": "voice_scrolling_navigation",
                    "description": (
                        "Includes voice commands for scrolling, navigation, and panning "
                        "around the interface."
                    ),
                    "weight": 1.0,
                },
                {
                    "id": "excludes_keyboard_interaction",
                    "description": (
                        "Lists voice-specific strategies. Keyboard-only or pointer-centric "
                        "strategies should NOT dominate."
                    ),
                    "weight": 1.5,
                },
            ]
        ),
    )


@task
def variant_recall() -> Task:
    return Task(
        name="voice_control_variant_recall",
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
                    "id": "cannot_use_hands_variant",
                    "description": (
                        "Includes a user who cannot use hands at all (relying entirely "
                        "on voice control) as distinct from supplementary voice users."
                    ),
                    "weight": 1.5,
                },
                {
                    "id": "differentiation_clear",
                    "description": (
                        "Variant differentiators are concrete (degree of hand disability, "
                        "primary input modality) and actionable."
                    ),
                    "weight": 1.0,
                },
            ]
        ),
    )


@task
def lens_override_h1() -> Task:
    return Task(
        name="voice_control_lens_override_h1",
        dataset=[
            Sample(
                input=(
                    "How does Heuristic 1 (Visibility of System Status) "
                    "apply when relying on voice control? Focus on what "
                    "this consideration's lens override adds beyond the generic "
                    "accessibility lens — voice feedback, labels, and discovery."
                ),
            )
        ],
        solver=_solver(),
        scorer=rubric_scorer(
            [
                {
                    "id": "visible_labels_required",
                    "description": (
                        "Notes that status messages must be visible on-screen (so the user "
                        "can speak them to interact) or clearly labeled for discovery."
                    ),
                    "weight": 2.0,
                },
                {
                    "id": "discoverable_via_voice",
                    "description": (
                        "Emphasizes that status must be discoverable via voice control "
                        "(either visible labels or accessible through numbered overlays)."
                    ),
                    "weight": 1.5,
                },
                {
                    "id": "text_availability",
                    "description": (
                        "Notes that status text must be perceivable (not audio-only feedback "
                        "that cannot be spoken back)."
                    ),
                    "weight": 1.0,
                },
                {
                    "id": "focus_visibility",
                    "description": (
                        "Considers that status updates must remain visible and stable; "
                        "dynamic changes must be perceivable and not disappear before "
                        "voice command can be given."
                    ),
                    "weight": 1.5,
                },
                {
                    "id": "consideration_specific",
                    "description": (
                        "The answer is specific to voice-access concerns and does not just "
                        "restate the generic Heuristic 1 lens unchanged."
                    ),
                    "weight": 2.0,
                },
            ]
        ),
    )


@task
def shared_inheritance() -> Task:
    return Task(
        name="voice_control_shared_inheritance",
        dataset=[
            Sample(
                input=(
                    "Which shared exploration strategies does this consideration "
                    "inherit, and which are excluded? For each, justify in "
                    "one sentence."
                ),
            )
        ],
        solver=_solver(),
        scorer=rubric_scorer(
            [
                {
                    "id": "identifies_exclusions",
                    "description": (
                        "Correctly identifies that mouse/pointer interaction is NOT applicable "
                        "to voice-only users (those who cannot use hands)."
                    ),
                    "weight": 1.5,
                },
                {
                    "id": "inherits_visual_reading",
                    "description": (
                        "Correctly identifies that visual scanning and reading and scrolling "
                        "ARE inherited (voice-access users can see and must scan visually)."
                    ),
                    "weight": 1.5,
                },
                {
                    "id": "inherits_navigation_forms",
                    "description": (
                        "Correctly identifies that navigation and wayfinding and form "
                        "interaction ARE inherited (achieved via voice commands)."
                    ),
                    "weight": 1.0,
                },
                {
                    "id": "justifications_grounded",
                    "description": (
                        "Justifications explain WHY (e.g., 'visual scanning applies; they scan "
                        "to find visible labels to speak') rather than just restating "
                        "inclusions/exclusions."
                    ),
                    "weight": 1.0,
                },
            ]
        ),
    )
