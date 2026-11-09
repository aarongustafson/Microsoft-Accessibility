"""Evaluate task-contextual coverage planning without ranking communities.

Task and criterion identifiers and weights remain stable across the migration.
"""

from __future__ import annotations

from inspect_ai import Task, task
from inspect_ai.dataset import Sample
from inspect_ai.solver import generate, system_message

from tests.evals import _providers
from tests.evals._context import load_methodology
from tests.evals._scorers import rubric_scorer

CONSIDERATION_COVERAGE_PRIORITY = load_methodology("consideration-coverage-priority")
SYSTEM = (
    "Plan accessibility evaluation coverage for the explicit interface and task. "
    "Prioritize core-task blockers, likely UI barriers and breadth across access "
    "methods, not disability communities or divergence from a default person. "
    "Decide KEEP or REORDER a proposed plan and explain the evidence, omitted "
    "topics and uncertainty. Candidate priorities are not fixed rankings.\n\n"
    f"{CONSIDERATION_COVERAGE_PRIORITY}"
)


@task
def consideration_coverage_priority_triggers() -> Task:
    return Task(
        name="consideration_coverage_priority_triggers",
        dataset=[Sample(input=(
            "Review a plan for a real-time video meeting application with live "
            "audio/video, screen sharing, chat, mute/camera toggles and participant "
            "actions revealed on hover. The scoped core task is joining and "
            "following a spoken meeting. Only four topics can be tested today. "
            "Proposed order: nonvisual access, visual adaptation, alternatives "
            "to colour cues, keyboard interaction, audio alternatives, hearing "
            "support, voice control. Rationale: 'We always start with vision "
            "topics; they are universally most important.' Caption availability, "
            "speaker identification and audio clarity have not been tested. "
            "Should this plan be KEPT or REORDERED? Give a context-specific order "
            "and reasons, including omitted topics and remaining uncertainty."
        ))],
        solver=[system_message(SYSTEM), generate(**_providers.generation_config())],
        scorer=rubric_scorer([
            {"id": "decides_reorder", "weight": 2.0, "description": (
                "Reorders the plan based on the stated spoken-meeting task "
                "rather than defending its universal vision-first rationale."
            )},
            {"id": "prioritizes_deaf_and_hoh", "weight": 2.0, "description": (
                "Includes audio alternatives and audio adaptation among the "
                "first four checks, identifying captions/speaker information "
                "and audio clarity for the core spoken-meeting task; does "
                "not equate this with a ranking of deaf or hard-of-hearing people."
            )},
            {"id": "cites_task_contextual_divergence", "weight": 1.5, "description": (
                "Explains task-contextual differences in input/output dependencies "
                "and likely UI barriers, not divergence from a shared/default "
                "person or a disability label as proof of individual behavior."
            )},
            {"id": "demotes_low_divergence_considerations", "description": (
                "Defers at least one less directly scoped visual topic to make "
                "room for spoken-communication checks, while preserving it as "
                "an omitted topic rather than assuming there are no barriers."
            )},
            {"id": "no_static_ordering", "description": (
                "Rejects universal, alphabetical or clause-number priority; "
                "explains coverage breadth and uncertainty without claiming "
                "four topics represent every access method or community."
            )},
        ]),
    )


@task
def consideration_coverage_priority_does_not_trigger() -> Task:
    return Task(
        name="consideration_coverage_priority_does_not_trigger",
        dataset=[Sample(input=(
            "Review a follow-up plan for a multi-step checkout form with labelled "
            "fields and colour, icon and descriptive-text validation feedback. "
            "Scope today: input operation, focus, label-based voice targeting, "
            "magnification/reflow and validation identification. Only four topics "
            "can be checked. Recent tests verified that error text and icons "
            "remain identifiable without colour for these fields. Proposed "
            "order: keyboard interaction, voice control, visual adaptation, "
            "alternatives to colour cues. Rationale: first verify core input "
            "operation and label targeting, then magnification/field proximity; "
            "recheck the already-tested non-colour feedback last. Nonvisual, "
            "language, memory/attention, numeracy and other topics are explicitly "
            "scheduled separately, not claimed as covered. No contradictory "
            "risk evidence is supplied. Should this scoped plan be KEPT or "
            "REORDERED? Explain the reasons and limits."
        ))],
        solver=[system_message(SYSTEM), generate(**_providers.generation_config())],
        scorer=rubric_scorer([
            {"id": "decides_keep", "weight": 2.0, "description": (
                "Keeps the reasonable scoped follow-up plan rather than "
                "arbitrarily reordering it."
            )},
            {"id": "justifies_keyboard_and_voice_top", "weight": 1.5, "description": (
                "Justifies keyboard focus/activation and voice label targeting "
                "as core-task dependencies needing verification."
            )},
            {"id": "justifies_colorblind_low", "weight": 1.5, "description": (
                "Defers the non-colour feedback recheck based on recent verified "
                "text/icon identification, not presumed abilities or the mere "
                "presence of icons; does not dismiss this topic universally."
            )},
            {"id": "principle_understood", "description": (
                "Uses task risk, interaction differences and coverage breadth; "
                "acknowledges separately scheduled and untested topics instead "
                "of treating this plan as complete representation."
            )},
            {"id": "no_invented_reorder", "description": (
                "Does not invent evidence or a fixed ranking to reorder the "
                "reasonable scoped plan; records uncertainty without asserting "
                "that untested access methods work."
            )},
        ]),
    )
