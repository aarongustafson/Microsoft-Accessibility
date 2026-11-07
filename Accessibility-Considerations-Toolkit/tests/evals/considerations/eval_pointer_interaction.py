"""Pilot eval: limited-reach consideration (clause 4.2.8).

Five sub-tests verifying the consideration file transfers SME knowledge:

- AT recall
- Exploration strategy recall
- Interaction context recall
- Heuristic lens override application
- Shared inheritance awareness

This consideration is the pointer-modality motor consideration: a user with limited
dexterity, strength, or reach who operates the interface with a pointing
device (touch, trackball, head pointer, eye-gaze, mouth/head stick,
switch-driven pointer) often on a mounted device. It carries the user needs
around target size and spacing, single-pointer operability, freedom from
dragging and complex gestures, recovery from accidental activation, transient
hover/focus content, and independence from device motion or a fixed orientation.

Each sub-test is a separate `@task` so it has its own rubric. Run with:

    python -m tests.evals tests/evals/considerations/eval_pointer_interaction.py

Use `--consideration_context_mode all` to run the same tasks with all
elaborated considerations loaded in background context, while still grading
limited-reach answers.

Add `--task at_recall` to limit to one sub-test.
"""

from __future__ import annotations

from inspect_ai import Task, task
from inspect_ai.dataset import Sample
from inspect_ai.solver import generate, system_message

from tests.evals import _providers
from tests.evals._context import load_eval_consideration_context
from tests.evals._scorers import rubric_scorer

CONSIDERATION_ALIAS = "pointer-interaction"
CONSIDERATION = load_eval_consideration_context(CONSIDERATION_ALIAS)


def _solver():
    return [system_message(CONSIDERATION), generate(**_providers.generation_config())]


@task
def at_recall() -> Task:
    return Task(
        name="pointer_interaction_at_recall",
        dataset=[
            Sample(
                input=(
                    "Identify all assistive technology / input methods documented "
                    "for this scope. For each, give a distinct interaction model "
                    "and the constraints to check in the stated configuration "
                    "(e.g. dwell activation, dragging alternatives, mounted-device "
                    "motion). Do not infer a person's motor abilities from AT use."
                ),
            )
        ],
        solver=_solver(),
        scorer=rubric_scorer(
            [
                {
                    "id": "covers_touch_limited_dexterity",
                    "description": (
                        "Mentions a touchscreen operated with limited dexterity / "
                        "tremor AND notes single-tap reliance with overshoot / "
                        "drift and difficulty with multi-finger gestures."
                    ),
                },
                {
                    "id": "covers_trackball_adapted_mouse",
                    "description": (
                        "Mentions a trackball or adapted / oversized mouse AND notes "
                        "difficulty holding a button while repositioning (dragging)."
                    ),
                },
                {
                    "id": "covers_head_or_eye_pointer",
                    "description": (
                        "Mentions a head-tracking pointer and/or eye-gaze pointer AND "
                        "notes dwell-based, positional activation that can fire on any "
                        "control the pointer rests on."
                    ),
                    "weight": 1.5,
                },
                {
                    "id": "covers_switch_or_stick",
                    "description": (
                        "Mentions a switch-driven / scanning pointer and/or a "
                        "mouth/head stick as a single-point, step-based input."
                    ),
                },
                {
                    "id": "covers_mounted_device",
                    "description": (
                        "Mentions a fixed-mounted device (e.g. wheelchair-mounted) "
                        "that cannot be tilted, shaken, or rotated."
                    ),
                    "weight": 1.5,
                },
                {
                    "id": "interaction_models_distinct",
                    "description": (
                        "Each entry has an interaction model that meaningfully "
                        "distinguishes it (not just renaming) and ties to a motor "
                        "constraint, rather than generic 'pointer' restating."
                    ),
                    "weight": 1.5,
                },
            ]
        ),
    )


@task
def strategy_recall() -> Task:
    return Task(
        name="pointer_interaction_strategy_recall",
        dataset=[
            Sample(
                input=(
                    "List the scope-specific exploration strategies to check "
                    "(NOT conditional shared strategies). For each, "
                    "describe the explicit access circumstances and requirements."
                ),
            )
        ],
        solver=_solver(),
        scorer=rubric_scorer(
            [
                {
                    "id": "single_pointer_no_gestures",
                    "description": (
                        "Includes single-pointer activation without path-based or "
                        "multi-point gestures."
                    ),
                },
                {
                    "id": "avoid_dragging",
                    "description": (
                        "Includes avoiding / replacing dragging with a non-drag "
                        "single-pointer alternative."
                    ),
                    "weight": 1.5,
                },
                {
                    "id": "target_size_spacing",
                    "description": (
                        "Includes acquiring small / closely-spaced targets and the "
                        "need for size and spacing."
                    ),
                },
                {
                    "id": "accidental_activation_recovery",
                    "description": (
                        "Includes recovering from accidental activation via "
                        "up-event / abort / undo."
                    ),
                    "weight": 1.5,
                },
                {
                    "id": "motion_and_orientation",
                    "description": (
                        "Includes operating without device motion and/or "
                        "working with a fixed device orientation."
                    ),
                },
                {
                    "id": "transient_hover_focus",
                    "description": (
                        "Includes managing transient hover / focus content so it is "
                        "persistent, hoverable, and dismissible."
                    ),
                },
                {
                    "id": "excludes_shared_only",
                    "description": (
                        "Lists strategies that are consideration-specific. Strategies "
                        "marked as shared (visual scanning, mouse / pointer "
                        "interaction, reading and scrolling, form interaction, "
                        "navigation and wayfinding, touch / pointer interaction) may "
                        "be acknowledged as inherited but should not dominate the list."
                    ),
                    "weight": 0.5,
                },
            ]
        ),
    )


@task
def variant_recall() -> Task:
    return Task(
        name="pointer_interaction_variant_recall",
        dataset=[
            Sample(
                input=(
                    "List the interaction contexts defined for this consideration "
                    "(scope-specific, NOT the New/Expert shared contexts). "
                    "For each, describe what differentiates them from the others in "
                    "one sentence."
                ),
            )
        ],
        solver=_solver(),
        scorer=rubric_scorer(
            [
                {
                    "id": "low_precision_pointer_variant",
                    "description": (
                        "Includes a low-precision pointer user (tremor / spasticity) "
                        "using a trackball / adapted mouse or direct touch who "
                        "overshoots and double-activates."
                    ),
                },
                {
                    "id": "dwell_pointer_variant",
                    "description": (
                        "Includes a head-pointer / eye-gaze dwell user who cannot "
                        "drag or gesture and whose positional activation can fire on "
                        "any rested-on control."
                    ),
                    "weight": 1.5,
                },
                {
                    "id": "mounted_device_variant",
                    "description": (
                        "Includes a mounted-device wheelchair user with a fixed "
                        "orientation and no device-motion input."
                    ),
                    "weight": 1.5,
                },
                {
                    "id": "differentiation_clear",
                    "description": (
                        "Each variant's differentiator is concrete and actionable "
                        "(specific input method and motor constraint), not just "
                        "renaming the consideration."
                    ),
                },
            ]
        ),
    )


@task
def lens_override_h5() -> Task:
    return Task(
        name="pointer_interaction_lens_override_h5",
        dataset=[
            Sample(
                input=(
                    "How does Heuristic 5 (Error Prevention) apply under the stated "
                    "pointer precision or device constraints? Focus on what this consideration's lens "
                    "override adds beyond the generic accessibility lens \u2014 target "
                    "size and spacing, dense clusters, dragging/gestures, and "
                    "destructive controls."
                ),
            )
        ],
        solver=_solver(),
        scorer=rubric_scorer(
            [
                {
                    "id": "target_size_spacing",
                    "description": (
                        "Notes that targets at least 24x24 CSS pixels (or with "
                        "sufficient spacing so a 24px circle does not overlap "
                        "neighbours) physically prevent mis-activation."
                    ),
                    "weight": 1.5,
                },
                {
                    "id": "destructive_isolation",
                    "description": (
                        "Notes keeping small destructive controls (delete, close x) "
                        "away from other targets and/or confirming irreversible actions."
                    ),
                },
                {
                    "id": "prefer_single_pointer",
                    "description": (
                        "Notes preferring single-pointer interactions over drags / "
                        "gestures the user may botch midway."
                    ),
                },
                {
                    "id": "dense_layout_risk",
                    "description": (
                        "Calls out dense toolbars, tiny close buttons, or stacked "
                        "menu rows as setting the user up to hit the wrong control."
                    ),
                },
                {
                    "id": "consideration_specific",
                    "description": (
                        "The answer is specific to limited-dexterity pointer concerns "
                        "and does not just restate the generic Heuristic 5 lens "
                        "unchanged."
                    ),
                    "weight": 2.0,
                },
            ]
        ),
    )


@task
def shared_inheritance() -> Task:
    return Task(
        name="pointer_interaction_shared_inheritance",
        dataset=[
            Sample(
                input=(
                    "The conditional shared reference defines six exploration strategies: "
                    "Visual scanning and layout comprehension, Mouse / pointer "
                    "interaction, Reading and scrolling, Form interaction, "
                    "Navigation and wayfinding, Touch / pointer interaction. "
                    "For each, state whether THIS consideration inherits it and justify in "
                    "one sentence based on scope, without inferring unrelated abilities. "
                    "Do not introduce strategies outside this list."
                ),
            )
        ],
        solver=_solver(),
        scorer=rubric_scorer(
            [
                {
                    "id": "all_strategies_apply",
                    "description": (
                        "States that the limited-reach consideration has NO shared "
                        "exclusions \u2014 visual scanning, mouse / pointer interaction, "
                        "reading and scrolling, form interaction, navigation and "
                        "wayfinding, and touch / pointer interaction all apply."
                    ),
                    "weight": 2.0,
                },
                {
                    "id": "no_false_exclusions",
                    "description": (
                        "Does NOT incorrectly claim mouse/pointer or touch interaction "
                        "is excluded \u2014 this document includes both as conditional reference strategies "
                        "(those are excluded for keyboard-only / voice-access, not "
                        "limited-reach)."
                    ),
                    "weight": 1.5,
                },
                {
                    "id": "justifications_grounded",
                    "description": (
                        "Justifications reference conditional applicability "
                        "under the stated pointer constraints (e.g. "
                        "pointer interaction with overshoot, touch with single taps "
                        "not multi-finger gestures), not generic descriptions of the "
                        "strategies themselves."
                    ),
                },
            ]
        ),
    )
