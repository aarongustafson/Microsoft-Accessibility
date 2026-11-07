"""Negative eval: keyboard-only user blocked by trap and hover-only controls.

This task follows the scenario-based negative-test pattern for consideration files:
provide a bad interface scenario that should be judged as NOT meeting the
consideration's needs.

Run with:

    python -m tests.evals tests/evals/negative/eval_keyboard_interaction_difficulties.py
"""

from __future__ import annotations

from inspect_ai import Task, task

from tests.evals.negative._text_scenarios import build_negative_text_task


@task
def keyboard_interaction_focus_trap_and_hover_actions() -> Task:
    return build_negative_text_task(
        task_name="keyboard_interaction_focus_trap_and_hover_actions",
        consideration_alias="keyboard-interaction",
        prompt_text=(
            "Evaluate this app flow for the keyboard-only consideration. A user tabs "
            "into a product configurator. The visible focus ring disappears after "
            "the third control. Additional options appear only on mouse hover over "
            "small info icons. A custom dropdown opens with Enter, but Tab no longer "
            "moves focus out of it and Escape does nothing. The primary 'Save' action "
            "is visually present but can only be reached after tabbing through 28 "
            "minor controls, and the final confirmation requires pressing Ctrl+Shift+S "
            "simultaneously. Does this meet the keyboard-only consideration's needs? Explain "
            "why or why not."
        ),
        criteria=[
            {
                "id": "states_it_does_not_meet_needs",
                "description": (
                    "Explicitly states that this does NOT adequately meet the "
                    "keyboard-only consideration's needs, or clearly describes it as an "
                    "accessibility problem or failure."
                ),
                "weight": 2.0,
            },
            {
                "id": "calls_out_focus_visibility_failure",
                "description": (
                    "Calls out that the missing or disappearing focus indicator leaves "
                    "the keyboard user unable to track where input will act."
                ),
                "weight": 1.5,
            },
            {
                "id": "calls_out_hover_only_or_unreachable_content",
                "description": (
                    "Calls out that hover-only information or controls are not reliably "
                    "available to a keyboard-only user."
                ),
                "weight": 1.5,
            },
            {
                "id": "calls_out_keyboard_trap_or_keystroke_burden",
                "description": (
                    "Calls out the keyboard trap in the custom dropdown and/or the "
                    "excessive tab sequence to reach the primary action."
                ),
                "weight": 1.5,
            },
            {
                "id": "calls_out_simultaneous_key_barrier",
                "description": (
                    "Calls out that the simultaneous Ctrl+Shift+S requirement is a "
                    "barrier for one-handed keyboard users or users with limited dexterity."
                ),
                "weight": 1.0,
            },
            {
                "id": "ties_problem_to_keyboard_interaction_consideration",
                "description": (
                    "Ties the failure to keyboard-only consideration needs such as visible "
                    "focus tracking, Tab reachability, keyboard escape paths, hover-on-"
                    "focus parity, and keystroke efficiency."
                ),
                "weight": 1.0,
            },
            {
                "id": "suggests_reasonable_fix",
                "description": (
                    "Suggests at least one reasonable remediation, such as restoring a "
                    "strong focus indicator, exposing hover content on focus, fixing the "
                    "dropdown keyboard pattern, reducing tab stops, or replacing simultaneous "
                    "shortcuts with single-key or sequential alternatives."
                ),
                "weight": 1.0,
            },
        ],
    )