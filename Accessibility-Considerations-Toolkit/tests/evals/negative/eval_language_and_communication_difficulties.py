"""Negative eval: cognitive-language user blocked by dense jargon and text-only paths.

This task follows the scenario-based negative-test pattern for consideration files:
provide a bad interface scenario that should be judged as NOT meeting the
consideration's needs.

Run with:

    python -m tests.evals tests/evals/negative/eval_language_and_communication_difficulties.py
"""

from __future__ import annotations

from inspect_ai import Task, task

from tests.evals.negative._text_scenarios import build_negative_text_task


@task
def language_and_communication_jargon_and_text_only_barriers() -> Task:
    return build_negative_text_task(
        task_name="language_and_communication_jargon_and_text_only_barriers",
        consideration_alias="language-and-communication",
        prompt_text=(
            "Evaluate this app flow for the cognitive-language consideration. A user "
            "opens a government benefits portal to apply for housing assistance. "
            "The landing page is a single block of 400 words in small justified "
            "text with no headings, no bullet points, and no summary. It uses "
            "phrases like 'pursuant to subsection 14(b) of the Housing "
            "Affordability Reconciliation Act' and 'applicants must furnish "
            "corroborative documentation substantiating domiciliary tenure'. "
            "The navigation menu has no icons — only text labels using "
            "abbreviations ('HARA App', 'Elig. Calc.', 'Doc. Req.'). A key "
            "instruction reads 'Don't forget: this isn't rocket science!' with "
            "no literal explanation of the steps. The free-text 'Reason for "
            "Application' field requires a minimum of 150 characters, blocks "
            "paste, and rejects input with a red 'INVALID ENTRY' message that "
            "offers no explanation of what was wrong. All content is rendered "
            "as an image of text inside a canvas element, making it unreadable "
            "by text-to-speech tools. Does this meet the cognitive-language "
            "consideration's needs? Explain why or why not."
        ),
        criteria=[
            {
                "id": "states_it_does_not_meet_needs",
                "description": (
                    "Explicitly states that this does NOT adequately meet the "
                    "cognitive-language consideration's needs, or clearly describes it "
                    "as an accessibility problem or failure."
                ),
                "weight": 2.0,
            },
            {
                "id": "calls_out_dense_unstructured_text",
                "description": (
                    "Calls out that the 400-word block of justified text with "
                    "no headings, lists, or summary is inaccessible to users "
                    "who read slowly, need structure to extract meaning, or "
                    "rely on skimming."
                ),
                "weight": 1.5,
            },
            {
                "id": "calls_out_jargon_or_complex_language",
                "description": (
                    "Calls out that the legal jargon, complex vocabulary, "
                    "passive constructions, or unexplained abbreviations are "
                    "barriers for users with limited language processing."
                ),
                "weight": 1.5,
            },
            {
                "id": "calls_out_figurative_or_non_literal_language",
                "description": (
                    "Calls out that the idiom ('isn't rocket science') or "
                    "implied/non-literal language can mislead a literal-language "
                    "user and provides no concrete instruction."
                ),
                "weight": 1.0,
            },
            {
                "id": "calls_out_missing_symbols_or_icons",
                "description": (
                    "Calls out that the text-only navigation with unexplained "
                    "abbreviations and no familiar icons leaves symbol-dependent "
                    "or reading-impaired users unable to identify controls."
                ),
                "weight": 1.0,
            },
            {
                "id": "calls_out_free_text_or_paste_blocking",
                "description": (
                    "Calls out that requiring 150 characters of free text with "
                    "paste blocked and unhelpful error messages is a barrier "
                    "for users who rely on assisted expression, word prediction, "
                    "or AAC."
                ),
                "weight": 1.5,
            },
            {
                "id": "calls_out_image_of_text_blocking_tts",
                "description": (
                    "Calls out that rendering content as an image of text "
                    "in a canvas makes it inaccessible to text-to-speech, "
                    "reading tools, and dictionary/glossary popups."
                ),
                "weight": 1.5,
            },
            {
                "id": "ties_problems_to_language_and_communication_consideration",
                "description": (
                    "Ties failures to cognitive-language consideration needs such as "
                    "plain language, clear structure, familiar symbols, real "
                    "selectable text for TTS, forgiving input, literal wording, "
                    "or alternative formats."
                ),
                "weight": 1.0,
            },
            {
                "id": "suggests_reasonable_fix",
                "description": (
                    "Suggests at least one reasonable remediation, such as "
                    "plain-language rewrite, adding headings and summaries, "
                    "pairing navigation with icons, using real text instead "
                    "of images, enabling paste, providing clearer error "
                    "messages, or offering a simplified version."
                ),
                "weight": 1.0,
            },
        ],
    )
