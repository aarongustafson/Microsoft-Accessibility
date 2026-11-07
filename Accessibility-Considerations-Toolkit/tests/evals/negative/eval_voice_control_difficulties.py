"""Negative eval: voice-access user blocked by unlabeled and drag-only UI.

This task follows the scenario-based negative-test pattern for consideration files:
provide a bad interface scenario that should be judged as NOT meeting the
consideration's needs.

Run with:

    python -m tests.evals tests/evals/negative/eval_voice_control_difficulties.py
"""

from __future__ import annotations

from inspect_ai import Task, task

from tests.evals.negative._text_scenarios import build_negative_text_task


@task
def voice_control_unlabeled_controls_and_drag_workflow() -> Task:
    return build_negative_text_task(
        task_name="voice_control_unlabeled_controls_and_drag_workflow",
        consideration_alias="voice-control",
        prompt_text=(
            "Evaluate this app flow for the voice-access consideration. A user opens a "
            "project board where the main actions are shown as unlabeled icon-only "
            "buttons. The visible tooltip says 'Settings' when hovered, but the "
            "underlying accessible name is 'Preferences panel'. Several controls "
            "appear only on mouse hover. Reordering tasks requires drag-and-drop, "
            "and the only way to move a card is to drag it into another column. A "
            "large canvas area also requires the user to click a specific spot with "
            "no visible label or list-based alternative. Does this meet the voice-"
            "access consideration's needs? Explain why or why not."
        ),
        criteria=[
            {
                "id": "states_it_does_not_meet_needs",
                "description": (
                    "Explicitly states that this does NOT adequately meet the "
                    "voice-access consideration's needs, or clearly describes it as an "
                    "accessibility problem or failure."
                ),
                "weight": 2.0,
            },
            {
                "id": "calls_out_label_name_mismatch",
                "description": (
                    "Calls out that icon-only or mislabeled controls break natural "
                    "voice commands because the visible label or meaning does not match "
                    "the accessible name the voice user would need to speak."
                ),
                "weight": 1.5,
            },
            {
                "id": "calls_out_hover_only_barrier",
                "description": (
                    "Calls out that controls revealed only on hover are a barrier for "
                    "voice-access users who cannot hover a pointer as a normal workflow."
                ),
                "weight": 1.5,
            },
            {
                "id": "calls_out_drag_or_canvas_barrier",
                "description": (
                    "Calls out that drag-and-drop or freeform canvas targeting is not "
                    "a reasonable primary workflow for voice access unless there is a "
                    "clear voice-operable alternative."
                ),
                "weight": 1.5,
            },
            {
                "id": "ties_problem_to_voice_control_consideration",
                "description": (
                    "Ties the failure to voice-access consideration needs such as speaking "
                    "visible labels, falling back to number overlays or grid navigation, "
                    "and requiring efficient voice-operable alternatives."
                ),
                "weight": 1.0,
            },
            {
                "id": "suggests_reasonable_fix",
                "description": (
                    "Suggests at least one reasonable remediation, such as matching "
                    "visible labels to accessible names, exposing controls without hover, "
                    "and providing explicit move buttons or menus instead of drag-only "
                    "interaction."
                ),
                "weight": 1.0,
            },
        ],
    )