"""Negative eval: cognitive-numeracy user blocked by bare numbers and required math.

This task follows the scenario-based negative-test pattern for consideration files:
provide a bad interface scenario that should be judged as NOT meeting the
consideration's needs.

Run with:

    python -m tests.evals tests/evals/negative/eval_numeracy_and_numeric_information_difficulties.py
"""

from __future__ import annotations

from inspect_ai import Task, task

from tests.evals.negative._text_scenarios import build_negative_text_task


@task
def numeracy_and_numeric_information_bare_numbers_and_required_math() -> Task:
    return build_negative_text_task(
        task_name="numeracy_and_numeric_information_bare_numbers_and_required_math",
        consideration_alias="numeracy-and-numeric-information",
        prompt_text=(
            "Evaluate this app flow for the cognitive-numeracy consideration. A user "
            "opens a travel booking site to reserve a hotel. The search results "
            "show 14 hotels in a dense table with prices listed only in a foreign "
            "currency (¥18,500/night, ¥24,200/night) with no conversion to the "
            "user's local currency and no cheaper/dearer labels or sorting. Check-in "
            "and check-out dates are shown as '07/08/2026' and '08/08/2026' with no "
            "written-out month and no 'number of nights' total. The user must "
            "mentally calculate the total cost by multiplying the nightly rate by "
            "the number of nights — there is no computed total shown anywhere. A "
            "room-size field displays '28.5 m²' with no visual reference, no "
            "comparison like 'about the size of a large living room', and no "
            "imperial alternative. The quantity selector lets the user type any "
            "number of rooms with no warning — typing '20' by accident proceeds "
            "to payment without confirmation. A chart compares hotel ratings using "
            "only a numeric score (7.8, 8.2, 8.9) with no summary or verbal "
            "description of what the scores mean. Does this meet the "
            "cognitive-numeracy consideration's needs? Explain why or why not."
        ),
        criteria=[
            {
                "id": "states_it_does_not_meet_needs",
                "description": (
                    "Explicitly states that this does NOT adequately meet the "
                    "cognitive-numeracy consideration's needs, or clearly describes "
                    "it as an accessibility problem or failure."
                ),
                "weight": 2.0,
            },
            {
                "id": "calls_out_foreign_currency_no_conversion",
                "description": (
                    "Calls out that prices in a foreign currency with no "
                    "conversion to the user's locale and no relative labels "
                    "(cheaper/dearer) leave the user unable to judge cost."
                ),
                "weight": 1.5,
            },
            {
                "id": "calls_out_required_mental_arithmetic",
                "description": (
                    "Calls out that the user must mentally multiply nightly "
                    "rate by number of nights to know the total cost, which "
                    "is a barrier when the system should compute and display "
                    "the total."
                ),
                "weight": 1.5,
            },
            {
                "id": "calls_out_ambiguous_dates_or_missing_duration",
                "description": (
                    "Calls out that the numeric date format is ambiguous "
                    "(day/month vs month/day) and/or that the number of "
                    "nights is not computed and shown, forcing the user to "
                    "calculate duration."
                ),
                "weight": 1.5,
            },
            {
                "id": "calls_out_bare_number_without_concrete_reference",
                "description": (
                    "Calls out that the room size in square metres alone, "
                    "and/or the rating scores as bare numbers, carry no "
                    "meaning without a concrete reference, visual, verbal "
                    "description, or familiar-unit alternative."
                ),
                "weight": 1.0,
            },
            {
                "id": "calls_out_missing_unusual_quantity_warning",
                "description": (
                    "Calls out that the quantity selector accepts extreme "
                    "values like 20 rooms without warning or confirmation "
                    "before proceeding to payment."
                ),
                "weight": 1.0,
            },
            {
                "id": "ties_problems_to_numeracy_and_numeric_information_consideration",
                "description": (
                    "Ties failures to cognitive-numeracy consideration needs such "
                    "as system-computed totals, locale-appropriate units and "
                    "currency, non-numeric reinforcement, concrete magnitude "
                    "references, unusual-value warnings, or unambiguous dates."
                ),
                "weight": 1.0,
            },
            {
                "id": "suggests_reasonable_fix",
                "description": (
                    "Suggests at least one reasonable remediation, such as "
                    "showing a computed total, converting to local currency, "
                    "writing out dates with month names, adding 'N nights' "
                    "duration, providing size comparisons, adding verbal "
                    "rating labels, or warning on unusual quantities."
                ),
                "weight": 1.0,
            },
        ],
    )
