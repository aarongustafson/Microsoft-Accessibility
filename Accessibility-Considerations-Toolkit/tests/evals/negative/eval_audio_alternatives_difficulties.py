"""Negative eval: missing alternatives to audio-only instructions and support.

This task follows the scenario-based negative-test pattern for consideration files:
provide a bad interface scenario that should be judged as NOT meeting the
consideration's needs.

Run with:

    python -m tests.evals tests/evals/negative/eval_audio_alternatives_difficulties.py
"""

from __future__ import annotations

from inspect_ai import Task, task
from tests.evals.negative._text_scenarios import build_negative_text_task


@task
def audio_alternatives_audio_only_onboarding_and_support() -> Task:
    return build_negative_text_task(
        task_name="audio_alternatives_audio_only_onboarding_and_support",
        consideration_alias="audio-alternatives",
        prompt_text=(
            "Evaluate this app flow when spoken audio is unavailable. A new user "
            "opens a financial app for the first time. The setup flow "
            "autoplays a welcome video with spoken instructions but no "
            "captions or transcript. When identity verification fails, "
            "the app plays an error tone and briefly vibrates, but shows "
            "no persistent visual error message. The help screen tells "
            "the user to call a phone number for support and does not "
            "offer chat, email, SMS, or a web form. Does this meet the "
            "stated non-audio access requirements? Explain why or why not."
        ),
        criteria=[
                {
                    "id": "states_it_does_not_meet_needs",
                    "description": (
                        "Explicitly states that this does NOT adequately meet "
                        "the stated non-audio access requirements, or clearly describes it as an "
                        "accessibility problem or failure."
                    ),
                    "weight": 2.0,
                },
                {
                    "id": "calls_out_missing_captions_or_transcript",
                    "description": (
                        "Calls out that the spoken onboarding video is inaccessible "
                        "without captions or a transcript."
                    ),
                    "weight": 1.5,
                },
                {
                    "id": "calls_out_missing_visual_status_feedback",
                    "description": (
                        "Calls out that the error state relies on an audio cue and/or "
                        "ephemeral feedback without a persistent visible message or "
                        "other clear visual status indicator."
                    ),
                    "weight": 1.5,
                },
                {
                    "id": "calls_out_phone_only_support_barrier",
                    "description": (
                        "Calls out that phone-only support is a barrier and that the "
                        "flow needs a text-based alternative such as chat, email, SMS, "
                        "or a web form."
                    ),
                    "weight": 1.5,
                },
                {
                    "id": "ties_problem_to_deaf_consideration",
                    "description": (
                        "Ties the failure to non-audio access requirements such as captions, "
                        "visual alternatives to audio cues, and text channels for "
                        "voice or phone features."
                    ),
                    "weight": 1.0,
                },
                {
                    "id": "suggests_reasonable_fix",
                    "description": (
                        "Suggests at least one reasonable remediation, such as adding "
                        "captions/transcripts, providing persistent visual error text, "
                        "or offering chat and other text-based support options."
                    ),
                    "weight": 1.0,
                },
        ],
    )