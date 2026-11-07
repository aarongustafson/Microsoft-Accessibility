"""Eval: deaf consideration (clause 4.2.4).

Five sub-tests verifying the consideration file transfers SME knowledge:

- AT recall
- Exploration strategy recall
- Interaction context recall
- Heuristic lens override application
- Shared inheritance awareness

Each sub-test is a separate `@task` so it has its own rubric. Run with:

    python -m tests.evals tests/evals/considerations/eval_audio_alternatives.py

Use `--consideration_context_mode all` to run the same tasks with all
elaborated considerations loaded in background context, while still grading
deaf answers.

Add `-T` to limit to one sub-test, e.g. `--task at_recall`.
"""

from __future__ import annotations

from inspect_ai import Task, task
from inspect_ai.dataset import Sample
from inspect_ai.solver import generate, system_message

from tests.evals import _providers
from tests.evals._context import load_eval_consideration_context
from tests.evals._scorers import rubric_scorer

CONSIDERATION_ALIAS = "audio-alternatives"
CONSIDERATION = load_eval_consideration_context(CONSIDERATION_ALIAS)


def _solver():
    return [system_message(CONSIDERATION), generate(**_providers.generation_config())]


@task
def at_recall() -> Task:
    return Task(
        name="audio_alternatives_at_recall",
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
                    "id": "covers_captioning",
                    "description": (
                        "Mentions captions or auto-captions (for audio/video content) "
                        "as an AT category enabling access to spoken audio."
                    ),
                    "weight": 1.5,
                },
                {
                    "id": "covers_visual_alerts",
                    "description": (
                        "Mentions visual or haptic/vibration alerts as a category for "
                        "notifications and system feedback normally delivered via sound."
                    ),
                    "weight": 1.5,
                },
                {
                    "id": "covers_relay_services",
                    "description": (
                        "Mentions relay services (video relay services / VRS, text relay) "
                        "as an AT category for phone/voice communication."
                    ),
                    "weight": 1.0,
                },
                {
                    "id": "video_relay_specific",
                    "description": (
                        "If mentioning relay, distinguishes video relay (sign language) "
                        "from text relay, showing understanding of language modality."
                    ),
                    "weight": 1.0,
                },
                {
                    "id": "interaction_models_distinct",
                    "description": (
                        "Each AT entry has a distinct interaction model (e.g., reading "
                        "captions vs. receiving visual alerts vs. using relay for calls)."
                    ),
                    "weight": 1.5,
                },
            ]
        ),
    )


@task
def strategy_recall() -> Task:
    return Task(
        name="audio_alternatives_strategy_recall",
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
                    "id": "scanning_for_captions",
                    "description": (
                        "Includes scanning for caption controls on media players and "
                        "checking availability of captions/transcripts."
                    ),
                    "weight": 1.5,
                },
                {
                    "id": "checking_visual_alternatives",
                    "description": (
                        "Includes checking for visual alternatives to audio cues "
                        "(e.g., progress bars instead of beeps, flashing instead of "
                        "sound notifications)."
                    ),
                    "weight": 1.5,
                },
                {
                    "id": "verifying_text_channels",
                    "description": (
                        "Includes verifying that phone/voice features have text "
                        "alternatives (e.g., chat, email, text relay)."
                    ),
                    "weight": 1.0,
                },
                {
                    "id": "evaluating_sign_language",
                    "description": (
                        "Includes checking for sign language interpretation or video "
                        "relay availability for communication features."
                    ),
                    "weight": 1.0,
                },
                {
                    "id": "excludes_shared_only",
                    "description": (
                        "Lists strategies specific to deafness/auditory access. Shared "
                        "visual/pointer/reading strategies may be acknowledged but should "
                        "not dominate."
                    ),
                    "weight": 0.5,
                },
            ]
        ),
    )


@task
def variant_recall() -> Task:
    return Task(
        name="audio_alternatives_variant_recall",
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
                    "id": "sign_language_interaction_context",
                    "description": (
                        "Includes a sign language interaction context as distinct from "
                        "non-signing deaf users (different language modality and "
                        "communication preferences)."
                    ),
                    "weight": 1.5,
                },
                {
                    "id": "non_signing_interaction_context",
                    "description": (
                        "Includes a non-signing deaf interaction context, relying on written "
                        "text, lipreading (visual speech), and other non-sign modalities."
                    ),
                    "weight": 1.5,
                },
                {
                    "id": "differentiation_clear",
                    "description": (
                        "Each variant's differentiator is concrete (communication mode: "
                        "sign language vs. text vs. visual) and meaningfully distinct."
                    ),
                    "weight": 1.5,
                },
            ]
        ),
    )


@task
def lens_override_h1() -> Task:
    return Task(
        name="audio_alternatives_lens_override_h1",
        dataset=[
            Sample(
                input=(
                    "How does Heuristic 1 (Visibility of System Status) "
                    "apply when hearing cannot provide task information? Focus on what "
                    "this consideration's lens override adds beyond the generic "
                    "accessibility lens — visual feedback, captions, and "
                    "text alternatives."
                ),
            )
        ],
        solver=_solver(),
        scorer=rubric_scorer(
            [
                {
                    "id": "visual_status_feedback",
                    "description": (
                        "Notes that status updates must be available as visual feedback, "
                        "not just audio (progress indicators, visual confirmations, "
                        "on-screen status messages)."
                    ),
                    "weight": 2.0,
                },
                {
                    "id": "caption_availability",
                    "description": (
                        "Notes that any audio status (beeps, alerts, earcons, chimes) "
                        "must be paired with a simultaneous visible caption, text "
                        "equivalent, or other visual signal so deaf users receive the "
                        "same status information."
                    ),
                    "weight": 2.0,
                },
                {
                    "id": "consideration_specific",
                    "description": (
                        "The answer is specific to deaf user concerns and does not just "
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
        name="audio_alternatives_shared_inheritance",
        dataset=[
            Sample(
                input=(
                    "The conditional shared reference defines six exploration strategies: "
                    "Visual scanning and layout comprehension, Mouse / pointer "
                    "interaction, Reading and scrolling, Form interaction, "
                    "Navigation and wayfinding, Touch / pointer interaction. "
                    "For each, state whether THIS consideration inherits it and "
                    "justify document scope without inferring unrelated abilities. "
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
                        "States that this document inherits ALL conditional shared strategies: "
                        "visual scanning, mouse/pointer interaction, reading and scrolling, "
                        "form interaction, navigation and wayfinding, touch/pointer "
                        "interaction."
                    ),
                    "weight": 2.0,
                },
                {
                    "id": "no_false_exclusions",
                    "description": (
                        "Does NOT incorrectly exclude visual, pointer, or reading "
                        "strategies from this document's scope; does not infer "
                        "visual or motor abilities."
                    ),
                    "weight": 1.5,
                },
                {
                    "id": "justifications_grounded",
                    "description": (
                        "Justifications reference conditional applicability "
                        "in this scope (e.g., visual scanning for visual "
                        "status cues), without inferring unrelated abilities."
                    ),
                    "weight": 1.0,
                },
            ]
        ),
    )
