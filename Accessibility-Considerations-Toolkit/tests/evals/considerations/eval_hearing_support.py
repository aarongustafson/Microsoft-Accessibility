"""Eval: hard-of-hearing consideration (clause 4.2.5).

Five sub-tests verifying the consideration file transfers SME knowledge:

- AT recall
- Exploration strategy recall
- Interaction context recall
- Heuristic lens override application
- Shared inheritance awareness

Each sub-test is a separate `@task` so it has its own rubric. Run with:

    python -m tests.evals tests/evals/considerations/eval_hearing_support.py

Use `--consideration_context_mode all` to run the same tasks with all
elaborated considerations loaded in background context, while still grading
hard-of-hearing answers.

Add `-T` to limit to one sub-test, e.g. `--task at_recall`.
"""

from __future__ import annotations

from inspect_ai import Task, task
from inspect_ai.dataset import Sample
from inspect_ai.solver import generate, system_message

from tests.evals import _providers
from tests.evals._context import load_eval_consideration_context
from tests.evals._scorers import rubric_scorer

CONSIDERATION_ALIAS = "hearing-support"
CONSIDERATION = load_eval_consideration_context(CONSIDERATION_ALIAS)


def _solver():
    return [system_message(CONSIDERATION), generate(**_providers.generation_config())]


@task
def at_recall() -> Task:
    return Task(
        name="hearing_support_at_recall",
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
                    "id": "covers_hearing_aids",
                    "description": (
                        "Mentions hearing aids or cochlear implants as an AT category "
                        "that amplifies or processes audio input."
                    ),
                    "weight": 1.5,
                },
                {
                    "id": "covers_audio_settings",
                    "description": (
                        "Mentions audio settings or enhancements (mono output, "
                        "equalizer, noise reduction, volume boost) as an AT category."
                    ),
                    "weight": 1.5,
                },
                {
                    "id": "covers_captions_supplementary",
                    "description": (
                        "Mentions captions as a supplementary AT category (not primary, "
                        "as it is for deaf users) to help with audio clarity."
                    ),
                    "weight": 1.0,
                },
                {
                    "id": "distinguishes_from_audio_alternatives",
                    "description": (
                        "Clearly distinguishes hard-of-hearing AT from deaf AT categories "
                        "(e.g., amplification vs. captions as primary)."
                    ),
                    "weight": 1.5,
                },
                {
                    "id": "interaction_models_distinct",
                    "description": (
                        "Each AT entry has a distinct interaction model (e.g., amplification "
                        "vs. audio tuning vs. captions)."
                    ),
                    "weight": 1.0,
                },
            ]
        ),
    )


@task
def strategy_recall() -> Task:
    return Task(
        name="hearing_support_strategy_recall",
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
                    "id": "checking_audio_controls",
                    "description": (
                        "Includes checking for audio quality and volume controls "
                        "to optimize listening experience."
                    ),
                    "weight": 1.5,
                },
                {
                    "id": "looking_for_captions",
                    "description": (
                        "Includes looking for captions as a supplement to audio "
                        "when hearing is difficult or context is unclear."
                    ),
                    "weight": 1.0,
                },
                {
                    "id": "checking_visual_redundancy",
                    "description": (
                        "Includes verifying that visual cues or text backup audio "
                        "information that may be missed due to hearing difficulty."
                    ),
                    "weight": 1.5,
                },
                {
                    "id": "noise_separation",
                    "description": (
                        "Includes strategies for verifying background noise separation "
                        "or mono audio mode to reduce hearing strain."
                    ),
                    "weight": 1.0,
                },
                {
                    "id": "excludes_shared_only",
                    "description": (
                        "Lists strategies specific to hard-of-hearing. Shared "
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
        name="hearing_support_variant_recall",
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
                    "id": "device_interaction_context",
                    "description": (
                        "Includes a variant with an assistive hearing device "
                        "(hearing aids or cochlear implants) distinct from "
                        "unaided hard-of-hearing users."
                    ),
                    "weight": 1.5,
                },
                {
                    "id": "unaided_variant",
                    "description": (
                        "Includes an unaided hard-of-hearing variant (without "
                        "assistive devices) relying on audio enhancement and captions."
                    ),
                    "weight": 1.5,
                },
                {
                    "id": "differentiation_clear",
                    "description": (
                        "Each variant's differentiator is concrete (device vs. no device, "
                        "or degree of hearing loss) and actionable."
                    ),
                    "weight": 1.0,
                },
            ]
        ),
    )


@task
def lens_override_h1() -> Task:
    return Task(
        name="hearing_support_lens_override_h1",
        dataset=[
            Sample(
                input=(
                    "How does Heuristic 1 (Visibility of System Status) "
                    "apply when audio clarity or supplementary cues are needed? Focus on what "
                    "this consideration's lens override adds beyond the generic "
                    "accessibility lens — audio clarity, caption support, and "
                    "visual alternatives."
                ),
            )
        ],
        solver=_solver(),
        scorer=rubric_scorer(
            [
                {
                    "id": "audio_clarity_required",
                    "description": (
                        "Notes that audio status feedback must be clear and audible "
                        "(considering hearing loss, background noise, or hearing aid "
                        "limitations)."
                    ),
                    "weight": 2.0,
                },
                {
                    "id": "caption_backup",
                    "description": (
                        "Suggests that critical audio status should have caption/text "
                        "backup for situations where audio is unreliable or unclear."
                    ),
                    "weight": 1.5,
                },
                {
                    "id": "visual_status_supplement",
                    "description": (
                        "Mentions visual indicators (lights, icons, progress bars) that "
                        "supplement audio feedback for redundancy."
                    ),
                    "weight": 1.0,
                },
                {
                    "id": "background_noise_consideration",
                    "description": (
                        "Considers how background noise or poor audio quality affects "
                        "perceivability of audio status signals."
                    ),
                    "weight": 0.75,
                },
                {
                    "id": "consideration_specific",
                    "description": (
                        "The answer is specific to hard-of-hearing concerns and does not "
                        "just restate the generic Heuristic 1 lens unchanged."
                    ),
                    "weight": 2.0,
                },
            ]
        ),
    )


@task
def shared_inheritance() -> Task:
    return Task(
        name="hearing_support_shared_inheritance",
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
                        "States that this document inherits ALL conditional shared "
                        "strategies: visual scanning, mouse/pointer interaction, reading "
                        "and scrolling, form interaction, navigation and wayfinding, "
                        "touch/pointer interaction."
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
                        "in this scope, without inferring unrelated abilities."
                    ),
                    "weight": 1.0,
                },
            ]
        ),
    )
