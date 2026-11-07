"""Negative eval: user without speech blocked by voice-gated workflow.

This task follows the scenario-based negative-test pattern for consideration files:
provide a bad interface scenario that should be judged as NOT meeting the
consideration's needs.

Run with:

    python -m tests.evals tests/evals/negative/eval_alternatives_to_speech_input_difficulties.py
"""

from __future__ import annotations

from inspect_ai import Task, task

from tests.evals.negative._text_scenarios import build_negative_text_task


@task
def alternatives_to_speech_input_voice_gated_verification() -> Task:
    return build_negative_text_task(
        task_name="alternatives_to_speech_input_voice_gated_verification",
        consideration_alias="alternatives-to-speech-input",
        prompt_text=(
            "Evaluate this app flow for the without-speech consideration. A user "
            "tries to reset their bank password. After entering their username, "
            "the app opens a full-screen 'Speak now to verify your identity' "
            "overlay with a microphone button and a looping prompt that says "
            "'I didn't catch that, please try again.' There is no keyboard or "
            "text alternative on the screen, no skip or dismiss option, and the "
            "help link routes to a phone number with an IVR that asks the caller "
            "to say their account number aloud. Does this meet the without-"
            "speech consideration's needs? Explain why or why not."
        ),
        criteria=[
            {
                "id": "states_it_does_not_meet_needs",
                "description": (
                    "Explicitly states that this does NOT adequately meet the "
                    "without-speech consideration's needs, or clearly describes it as "
                    "an accessibility problem or failure."
                ),
                "weight": 2.0,
            },
            {
                "id": "calls_out_voice_only_blocker",
                "description": (
                    "Calls out that the verification step is voice-gated and "
                    "therefore blocks a user who cannot speak or whose speech is "
                    "not reliably recognized."
                ),
                "weight": 1.5,
            },
            {
                "id": "calls_out_missing_text_or_keyboard_fallback",
                "description": (
                    "Calls out the lack of an immediate text, keyboard, or other "
                    "non-voice fallback, including the lack of a skip or dismiss "
                    "path on the overlay."
                ),
                "weight": 1.5,
            },
            {
                "id": "calls_out_phone_ivr_barrier",
                "description": (
                    "Calls out that the phone-only IVR recovery path is also a "
                    "barrier because it requires spoken responses instead of a "
                    "text-based support or verification option."
                ),
                "weight": 1.5,
            },
            {
                "id": "ties_problem_to_alternatives_to_speech_input_consideration",
                "description": (
                    "Ties the failure to without-speech consideration needs such as "
                    "seeking text alternatives to voice features, avoiding voice-"
                    "gated workflows, and requiring non-voice alternatives for "
                    "authentication and support."
                ),
                "weight": 1.0,
            },
            {
                "id": "suggests_reasonable_fix",
                "description": (
                    "Suggests at least one reasonable remediation, such as adding "
                    "a password, passkey, SMS, email, security key, keypad, chat, "
                    "or web-form fallback and making the non-voice option equally "
                    "prominent."
                ),
                "weight": 1.0,
            },
        ],
    )