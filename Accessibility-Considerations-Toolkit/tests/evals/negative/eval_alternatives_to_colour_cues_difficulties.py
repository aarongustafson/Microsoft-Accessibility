"""Negative eval: color-blind user blocked by colour-reliant screenshot design.

This task follows the scenario-based negative-test pattern for consideration files,
using a static image fixture that should be judged as NOT meeting the
consideration's needs.

Run with:

    python -m tests.evals tests/evals/negative/eval_alternatives_to_colour_cues_difficulties.py
"""

from __future__ import annotations

from pathlib import Path

from inspect_ai import Task, task
from tests.evals.negative._image_scenarios import build_negative_image_task

TEST_WEBSITE_IMAGE = (
    Path(__file__).resolve().parents[2]
    / "fixtures"
    / "images"
    / "colour-contrast.png"
)


@task
def alternatives_to_colour_cues_test_website_image() -> Task:
    return build_negative_image_task(
        task_name="alternatives_to_colour_cues_test_website_image",
        consideration_alias="alternatives-to-colour-cues",
        image_path=TEST_WEBSITE_IMAGE,
        prompt_text=(
            "Evaluate the attached synthetic workshop-schedule screenshot as a negative test for the "
            "color-blind consideration (EN 301 549 FPS 4.2.3). Based only on visible "
            "evidence, decide whether this design likely makes the page "
            "difficult for a user who cannot reliably perceive colour "
            "differences. Focus on whether colour seems to be doing too much "
            "of the work for separating content, indicating structure, or "
            "making text legible against the background. State whether it "
            "appears to meet the consideration's needs, explain why or why not, and "
            "suggest concrete fixes."
        ),
        criteria=[
                {
                    "id": "states_it_does_not_meet_needs",
                    "description": (
                        "Explicitly states that the screenshot likely does NOT "
                        "adequately meet color-blind user needs, or clearly "
                        "describes it as a likely accessibility problem."
                    ),
                    "weight": 2.0,
                },
                {
                    "id": "grounds_in_colour_reliant_structure",
                    "description": (
                        "Grounds the answer in visible evidence that the design "
                        "leans heavily on multicolour striping or colour changes "
                        "to separate content blocks or create visual structure."
                    ),
                    "weight": 1.5,
                },
                {
                    "id": "calls_out_missing_non_colour_cues",
                    "description": (
                        "Calls out the lack of strong non-colour cues such as "
                        "clear borders, labels, icons, numbering, whitespace, or "
                        "other structural indicators that would still work if the "
                        "colour differences were harder to perceive."
                    ),
                    "weight": 1.5,
                },
                {
                    "id": "ties_problem_to_alternatives_to_colour_cues_consideration",
                    "description": (
                        "Ties the problem to color-blind consideration needs such as "
                        "scanning for non-colour cues, seeking explicit labels, "
                        "and not relying on colour alone to convey structure or "
                        "meaning."
                    ),
                    "weight": 1.0,
                },
                {
                    "id": "suggests_reasonable_fix",
                    "description": (
                        "Suggests at least one reasonable remediation, such as "
                        "replacing rainbow striping with clearer spacing and borders, "
                        "adding headings or labels per section, or ensuring structure "
                        "does not depend on colour differences alone."
                    ),
                    "weight": 1.0,
                },
        ],
    )