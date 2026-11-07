"""Negative eval: limited-reach user blocked by small targets, drag-only, and gestures.

This task follows the scenario-based negative-test pattern for consideration files:
provide a bad interface scenario that should be judged as NOT meeting the
consideration's needs.

Run with:

    python -m tests.evals tests/evals/negative/eval_pointer_interaction_difficulties.py
"""

from __future__ import annotations

from inspect_ai import Task, task

from tests.evals.negative._text_scenarios import build_negative_text_task


@task
def pointer_interaction_small_targets_drag_and_gestures() -> Task:
    return build_negative_text_task(
        task_name="pointer_interaction_small_targets_drag_and_gestures",
        consideration_alias="pointer-interaction",
        prompt_text=(
            "Evaluate this app flow for the limited-reach consideration. A user with "
            "tremor opens a photo-editing app on a tablet mounted to their "
            "wheelchair. The toolbar has 18 icon-only buttons packed tightly "
            "together at 16×16 pixels with 2px gaps. To crop an image, the only "
            "method is to drag corner handles inward — there is no numeric input "
            "or tap-to-set alternative. Applying a filter requires a two-finger "
            "pinch gesture on the canvas with no button equivalent. The undo "
            "function is triggered by shaking the device — there is no on-screen "
            "undo button. When the user accidentally taps 'Delete', the photo is "
            "removed immediately on the down-event with no confirmation and no "
            "way to recover. The app displays 'Please rotate to portrait mode' "
            "and blocks all interaction until the device is turned. Does this "
            "meet the limited-reach consideration's needs? Explain why or why not."
        ),
        criteria=[
            {
                "id": "states_it_does_not_meet_needs",
                "description": (
                    "Explicitly states that this does NOT adequately meet the "
                    "limited-reach consideration's needs, or clearly describes it as "
                    "an accessibility problem or failure."
                ),
                "weight": 2.0,
            },
            {
                "id": "calls_out_small_target_size_or_spacing",
                "description": (
                    "Calls out that the 16×16px toolbar buttons with 2px gaps "
                    "are too small and too closely spaced for a user with "
                    "tremor, head pointer, or eye-gaze, causing mis-activation."
                ),
                "weight": 1.5,
            },
            {
                "id": "calls_out_drag_only_interaction",
                "description": (
                    "Calls out that the crop function relying solely on "
                    "dragging corner handles is a barrier because the user "
                    "cannot reliably press-hold-move-release, and no "
                    "single-pointer alternative is offered."
                ),
                "weight": 1.5,
            },
            {
                "id": "calls_out_gesture_only_or_motion_only",
                "description": (
                    "Calls out that the pinch gesture for filters and/or the "
                    "shake-to-undo have no on-screen single-pointer alternative, "
                    "blocking users who cannot perform multi-point gestures or "
                    "move a mounted device."
                ),
                "weight": 1.5,
            },
            {
                "id": "calls_out_down_event_or_irreversible_delete",
                "description": (
                    "Calls out that the Delete action fires on the down-event "
                    "without confirmation or undo, removing the user's ability "
                    "to abort by moving off before release."
                ),
                "weight": 1.5,
            },
            {
                "id": "calls_out_orientation_lock",
                "description": (
                    "Calls out that blocking interaction until the device is "
                    "rotated to portrait is a barrier for a user with a "
                    "fixed-mounted device who cannot change orientation."
                ),
                "weight": 1.0,
            },
            {
                "id": "ties_problems_to_pointer_interaction_consideration",
                "description": (
                    "Ties failures to limited-reach consideration needs such as "
                    "target size (24px minimum), single-pointer operability, "
                    "freedom from dragging and complex gestures, up-event "
                    "activation, device-motion independence, or orientation "
                    "flexibility."
                ),
                "weight": 1.0,
            },
            {
                "id": "suggests_reasonable_fix",
                "description": (
                    "Suggests at least one reasonable remediation, such as "
                    "increasing target size/spacing, adding numeric crop "
                    "inputs, providing button alternatives for gestures, "
                    "adding an on-screen undo button, using up-event "
                    "activation with confirmation, or removing the "
                    "orientation lock."
                ),
                "weight": 1.0,
            },
        ],
    )
