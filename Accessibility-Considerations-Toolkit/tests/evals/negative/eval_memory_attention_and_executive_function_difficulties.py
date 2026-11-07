"""Negative eval: cognitive-memory user blocked by recall demands and lost context.

This task follows the scenario-based negative-test pattern for consideration files:
provide a bad interface scenario that should be judged as NOT meeting the
consideration's needs.

Run with:

    python -m tests.evals tests/evals/negative/eval_memory_attention_and_executive_function_difficulties.py
"""

from __future__ import annotations

from inspect_ai import Task, task

from tests.evals.negative._text_scenarios import build_negative_text_task


@task
def memory_attention_and_executive_function_recall_demands_and_lost_context() -> Task:
    return build_negative_text_task(
        task_name="memory_attention_and_executive_function_recall_demands_and_lost_context",
        consideration_alias="memory-attention-and-executive-function",
        prompt_text=(
            "Evaluate this app flow for the cognitive-memory consideration. A user "
            "begins a 9-step insurance claim form. There is no progress indicator "
            "and no step headings — just a page number at the bottom. On step 3, "
            "the user is shown a 6-digit reference code and told to 'remember this "
            "for step 7'. The code disappears when they advance. On step 5, a "
            "promotional popup autoplays a video ad with sound, and dismissing it "
            "reloads the page, clearing all fields on that step. On step 7, the "
            "form asks the user to type the reference code from step 3 — paste is "
            "disabled. After 4 minutes of inactivity the session silently times "
            "out, discarding all entered data without warning. The browser Back "
            "button returns to step 1 and erases everything. There is no autosave, "
            "no draft recovery, and no confirmation that any step was saved. Does "
            "this meet the cognitive-memory consideration's needs? Explain why or why not."
        ),
        criteria=[
            {
                "id": "states_it_does_not_meet_needs",
                "description": (
                    "Explicitly states that this does NOT adequately meet the "
                    "cognitive-memory consideration's needs, or clearly describes it "
                    "as an accessibility problem or failure."
                ),
                "weight": 2.0,
            },
            {
                "id": "calls_out_recall_across_steps",
                "description": (
                    "Calls out that requiring the user to remember a reference "
                    "code from step 3 and reproduce it at step 7 (with paste "
                    "disabled) is a barrier for a working-memory-limited user."
                ),
                "weight": 1.5,
            },
            {
                "id": "calls_out_missing_orientation_signposts",
                "description": (
                    "Calls out that the lack of step headings, progress "
                    "indicator, or clear context means the user cannot "
                    "reorient after a distraction or know where they are "
                    "in the process."
                ),
                "weight": 1.5,
            },
            {
                "id": "calls_out_interruption_and_data_loss",
                "description": (
                    "Calls out that the autoplaying popup disrupts focus "
                    "and/or that dismissing it clears entered data, which "
                    "is catastrophic for a user who cannot easily re-enter "
                    "information."
                ),
                "weight": 1.5,
            },
            {
                "id": "calls_out_timeout_or_back_button_data_loss",
                "description": (
                    "Calls out that the silent session timeout discarding "
                    "all data and/or the Back button erasing progress are "
                    "barriers because the user needs to take breaks and "
                    "navigate without penalty."
                ),
                "weight": 1.5,
            },
            {
                "id": "calls_out_missing_feedback_or_autosave",
                "description": (
                    "Calls out the absence of confirmation that steps were "
                    "saved, and/or the lack of autosave or draft recovery, "
                    "leaving the user unsure whether actions succeeded."
                ),
                "weight": 1.0,
            },
            {
                "id": "ties_problems_to_memory_attention_and_executive_function_consideration",
                "description": (
                    "Ties the failures to cognitive-memory consideration needs "
                    "such as nothing to recall across steps, persistent "
                    "signposts, freedom from interruptions, predictable "
                    "Back/undo, autosave, or immediate feedback."
                ),
                "weight": 1.0,
            },
            {
                "id": "suggests_reasonable_fix",
                "description": (
                    "Suggests at least one reasonable remediation, such as "
                    "carrying the reference code forward automatically, "
                    "adding a progress indicator with step headings, "
                    "removing or deferring the popup, enabling paste, "
                    "adding autosave, extending or warning before timeout, "
                    "or making Back preserve entered data."
                ),
                "weight": 1.0,
            },
        ],
    )
