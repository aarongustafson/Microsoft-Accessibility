"""Negative eval: hard-of-hearing user blocked by poor audio support.

This task follows the scenario-based negative-test pattern for consideration files:
provide a bad interface scenario that should be judged as NOT meeting the
consideration's needs.

Run with:

    python -m tests.evals tests/evals/negative/eval_hearing_support_difficulties.py
"""

from __future__ import annotations

from inspect_ai import Task, task

from tests.evals.negative._text_scenarios import build_negative_text_task


@task
def hearing_support_poor_audio_and_caption_support() -> Task:
    return build_negative_text_task(
        task_name="hearing_support_poor_audio_and_caption_support",
        consideration_alias="hearing-support",
        prompt_text=(
            "Evaluate this app flow for the hard-of-hearing consideration. A user "
            "joins a training webinar where the presenter speaks quietly over "
            "background music. The player has only a basic play/pause button and "
            "a single system-volume reminder, with no dialogue boost, no separate "
            "speech/music control, and no mono-audio option. Auto-captions are "
            "available only after opening a nested settings menu, they lag behind "
            "the speaker, and they do not identify speakers. Important completion "
            "and error cues are also announced with soft chimes and no persistent "
            "visual indicator. Does this meet the hard-of-hearing consideration's needs? "
            "Explain why or why not."
        ),
        criteria=[
            {
                "id": "states_it_does_not_meet_needs",
                "description": (
                    "Explicitly states that this does NOT adequately meet the "
                    "hard-of-hearing consideration's needs, or clearly describes it as "
                    "an accessibility problem or failure."
                ),
                "weight": 2.0,
            },
            {
                "id": "calls_out_poor_audio_clarity_or_controls",
                "description": (
                    "Calls out that quiet speech mixed with background audio and "
                    "missing audio-enhancement controls make the content hard to "
                    "hear reliably."
                ),
                "weight": 1.5,
            },
            {
                "id": "calls_out_caption_quality_or_discoverability",
                "description": (
                    "Calls out that captions are hard to discover, low quality, or "
                    "insufficient as a supplement because they lag, are buried in "
                    "settings, or lack speaker identification."
                ),
                "weight": 1.5,
            },
            {
                "id": "calls_out_missing_visual_redundancy",
                "description": (
                    "Calls out that important audio cues such as completion or error "
                    "signals need persistent visual equivalents, not soft chimes alone."
                ),
                "weight": 1.5,
            },
            {
                "id": "ties_problem_to_hearing_support_consideration",
                "description": (
                    "Ties the failure to hard-of-hearing consideration needs such as audio "
                    "clarity, captions as a supplement, mono audio, and visual backup "
                    "for unreliable audio cues."
                ),
                "weight": 1.0,
            },
            {
                "id": "suggests_reasonable_fix",
                "description": (
                    "Suggests at least one reasonable remediation, such as speech "
                    "enhancement controls, more prominent and higher-quality captions, "
                    "mono audio, or persistent visible status feedback."
                ),
                "weight": 1.0,
            },
        ],
    )