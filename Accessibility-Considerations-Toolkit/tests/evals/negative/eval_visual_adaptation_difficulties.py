"""Negative eval: low-vision user blocked by weak contrast and indicators.

This task follows the scenario-based negative-test pattern for consideration files:
provide a bad interface scenario that should be judged as NOT meeting the
consideration's needs.

Run with:

    python -m tests.evals tests/evals/negative/eval_visual_adaptation_difficulties.py
"""

from __future__ import annotations

from pathlib import Path

from inspect_ai import Task, task
from tests.evals.negative._image_scenarios import build_negative_image_task
from tests.evals.negative._text_scenarios import build_negative_text_task

TEST_WEBSITE_IMAGE = (
    Path(__file__).resolve().parents[2]
    / "fixtures"
    / "images"
    / "colour-contrast.png"
)


@task
def visual_adaptation_weak_contrast_and_focus_indicators() -> Task:
    return build_negative_text_task(
        task_name="visual_adaptation_weak_contrast_and_focus_indicators",
        consideration_alias="visual-adaptation",
        prompt_text=(
            "Evaluate this app flow for the low-vision consideration. A "
            "desktop user opens a settings page at 200% zoom. Section "
            "headings are light gray on an off-white background, form "
            "field borders are thin pale gray lines, helper text is "
            "smaller and lower-contrast than the body text, and the "
            "selected tab is shown only by a subtle color shift. When "
            "the user tabs through the page, focus is indicated only by "
            "a faint box-shadow. In Windows High Contrast or forced-"
            "colours mode, that focus treatment disappears and some "
            "section dividers vanish. Does this meet the low-vision "
            "consideration's needs? Explain why or why not."
        ),
        criteria=[
                {
                    "id": "states_it_does_not_meet_needs",
                    "description": (
                        "Explicitly states that this does NOT adequately meet "
                        "the low-vision consideration's needs, or clearly describes "
                        "it as an accessibility problem or failure."
                    ),
                    "weight": 2.0,
                },
                {
                    "id": "identifies_low_contrast_and_weak_states",
                    "description": (
                        "Identifies that low contrast text, subtle tab-state "
                        "changes, and weak visual indicators make the interface "
                        "hard to read or distinguish for low-vision users."
                    ),
                    "weight": 1.5,
                },
                {
                    "id": "calls_out_focus_and_forced_colours_failure",
                    "description": (
                        "Calls out that focus indication and/or other structural "
                        "visual cues fail in high contrast or forced-colours "
                        "mode, including the risk of relying on box-shadow-only "
                        "focus styling."
                    ),
                    "weight": 1.5,
                },
                {
                    "id": "ties_problem_to_visual_adaptation_consideration",
                    "description": (
                        "Ties the problem to low-vision consideration needs such as "
                        "contrast sensitivity, high-contrast scanning, zoomed "
                        "reading, or the need for thick, high-contrast focus "
                        "rings, borders, and state changes."
                    ),
                    "weight": 1.0,
                },
                {
                    "id": "suggests_reasonable_fix",
                    "description": (
                        "Suggests at least one reasonable remediation, such as "
                        "increasing contrast, using outline-based focus styles, "
                        "adding non-colour state indicators, thickening borders, "
                        "or preserving dividers and indicators in forced-colours "
                        "mode."
                    ),
                    "weight": 1.0,
                },
        ],
    )


@task
def visual_adaptation_test_website_image() -> Task:
    return build_negative_image_task(
        task_name="visual_adaptation_test_website_image",
        consideration_alias="visual-adaptation",
        image_path=TEST_WEBSITE_IMAGE,
        prompt_text=(
            "Evaluate the attached synthetic workshop-schedule screenshot as a negative test for the "
            "low-vision consideration (EN 301 549 FPS 4.2.2). Based only on visible "
            "evidence, decide whether this design likely makes the page "
            "difficult for a low-vision user. Focus on readability, contrast, "
            "visual clutter, scaling risk, and the ability to distinguish "
            "content blocks. State whether it appears to meet the consideration's "
            "needs, explain why or why not, and suggest concrete fixes."
        ),
        criteria=[
                {
                    "id": "states_it_does_not_meet_needs",
                    "description": (
                        "Explicitly states that the screenshot likely does NOT "
                        "adequately meet low-vision user needs, or clearly "
                        "describes it as a likely accessibility problem."
                    ),
                    "weight": 2.0,
                },
                {
                    "id": "grounds_in_visible_legibility_problems",
                    "description": (
                        "Grounds the answer in visible evidence such as tiny "
                        "text, dense copy, weak text/background contrast on some "
                        "bands, or a visually cluttered layout that would be hard "
                        "to scan or read at low vision."
                    ),
                    "weight": 1.5,
                },
                {
                    "id": "calls_out_orientation_and_segmentation_risk",
                    "description": (
                        "Calls out that the dense rainbow-striping and crowded "
                        "presentation make it difficult to distinguish sections, "
                        "maintain orientation, or identify clear visual landmarks."
                    ),
                    "weight": 1.5,
                },
                {
                    "id": "ties_problem_to_visual_adaptation_consideration",
                    "description": (
                        "Ties the problem to low-vision consideration needs such as "
                        "zoomed reading, contrast sensitivity, magnified viewport "
                        "scanning, or the need for clearer structure and stronger "
                        "visual indicators."
                    ),
                    "weight": 1.0,
                },
                {
                    "id": "suggests_reasonable_fix",
                    "description": (
                        "Suggests at least one reasonable remediation, such as "
                        "simplifying the layout, increasing text size, improving "
                        "contrast, reducing decorative backgrounds, or using clearer "
                        "section boundaries and spacing."
                    ),
                    "weight": 1.0,
                },
        ],
    )