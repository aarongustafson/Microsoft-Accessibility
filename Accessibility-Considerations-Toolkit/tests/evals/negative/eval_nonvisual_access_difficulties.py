"""Negative eval: nonvisual access burdened by excessive tabbing before content.

This task establishes the desired negative-test shape for consideration files:
provide a bad interface scenario that should be judged as NOT meeting the
consideration's needs.

Run with:

    python -m tests.evals tests/evals/negative/eval_nonvisual_access_difficulties.py
"""

from __future__ import annotations

from inspect_ai import Task, task
from tests.evals.negative._text_scenarios import build_negative_text_task


@task
def nonvisual_access_too_many_tabs_before_content() -> Task:
    return build_negative_text_task(
        task_name="nonvisual_access_too_many_tabs_before_content",
        consideration_alias="nonvisual-access",
        prompt_text=(
            "Evaluate this app flow for nonvisual access. A desktop "
            "screen reader user opens an article page. Keyboard focus "
            "starts on the site logo, then moves through 18 global "
            "navigation links, 6 utility buttons, 4 promotional "
            "links, and 3 filter controls before the user can reach "
            "the main article heading. There is no skip link, no "
            "main landmark or useful heading structure exposed to AT, "
            "and the page is meant to be used with Tab to reach the "
            "content. Does this meet the stated nonvisual access requirements? "
            "Explain why or why not."
        ),
        criteria=[
                {
                    "id": "states_it_does_not_meet_needs",
                    "description": (
                        "Explicitly states that this does NOT adequately meet "
                        "the stated nonvisual access requirements, or clearly describes it as "
                        "an accessibility problem or failure."
                    ),
                    "weight": 2.0,
                },
                {
                    "id": "identifies_excessive_tabbing_burden",
                    "description": (
                        "Identifies that forcing the user through a long tab "
                        "sequence before reaching main content is inefficient, "
                        "fatiguing, or disorienting in this screen-reader "
                        "user."
                    ),
                    "weight": 1.5,
                },
                {
                    "id": "calls_out_missing_bypass_or_structure",
                    "description": (
                        "Calls out the lack of a bypass mechanism or structure, "
                        "such as a skip link, robust heading structure, or "
                        "clear landmark-based access to main content."
                    ),
                    "weight": 1.5,
                },
                {
                    "id": "ties_problem_to_blind_consideration_navigation",
                    "description": (
                        "Ties the failure to documented nonvisual navigation options "
                        "from the reference context, such as tab-through "
                        "interactive elements, heading navigation, landmark "
                        "navigation, elements lists, or beginner users relying "
                        "on Tab and sequential reading."
                    ),
                    "weight": 1.0,
                },
                {
                    "id": "suggests_reasonable_fix",
                    "description": (
                        "Suggests at least one reasonable remediation, such as "
                        "adding a skip link, exposing a main landmark, reducing "
                        "tab stops before content, or improving heading-based "
                        "navigation."
                    ),
                    "weight": 1.0,
                },
        ],
    )