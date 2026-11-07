"""
Two scenarios:

- A "trigger" case where the methodology should fire. The draft
  recommendation proposes non-standard keyboard behaviour, uses a
  custom widget where native semantics would be better, and suggests a
  visual-layout change to fix tab order.

- A "no-trigger" case where the recommendation already follows
  established platform/APG interaction patterns, uses native controls,
  and avoids redundant shortcuts.

Run with:

    inspect eval tests/evals/methodology/eval_standard_conventions.py \
        --model copilot/gpt-5-mini
"""

from __future__ import annotations

from inspect_ai import Task, task
from inspect_ai.dataset import Sample
from inspect_ai.solver import generate, system_message

from tests.evals import _providers
from tests.evals._context import load_methodology
from tests.evals._scorers import rubric_scorer

STANDARD_CONVENTIONS = load_methodology("standard-conventions")
SYSTEM = (
    "You are an accessibility evaluator reviewing draft recommendations. "
    "Apply the following principle exactly:\n\n"
    f"{STANDARD_CONVENTIONS}\n\n"
    "When asked to review a draft recommendation, decide whether to KEEP "
    "it as written, REVISE it, or DISMISS it. Justify your decision by "
    "explicitly checking for standard platform/APG patterns, keyboard "
    "discoverability, native-vs-ARIA choices, and whether the proposed "
    "fix can actually address the reported issue (for example, DOM order "
    "vs visual layout)."
)


@task
def standard_conventions_triggers() -> Task:
    """The principle SHOULD fire - recommendation diverges from
    standard interaction conventions."""
    return Task(
        name="standard_conventions_triggers",
        dataset=[
            Sample(
                input=(
                    "Draft recommendation to review:\n\n"
                    "  Issue context: Keyboard users report that focus moves "
                    "through a filter panel in an unexpected order. The panel "
                    "contains a custom country picker implemented as "
                    "<div role='combobox'> with scripted key handlers.\n"
                    "  Draft recommendation:\n"
                    "    1) Add keyboard shortcut Ctrl+J to jump to the next "
                    "field so users can bypass confusing tab order.\n"
                    "    2) Keep the custom combobox and add more ARIA roles "
                    "to match native behaviour.\n"
                    "    3) Use CSS position: sticky and visual reordering so "
                    "the panel appears in logical sequence for keyboard users.\n"
                    "    4) Keep Enter to submit and add Alt+Enter as an "
                    "additional submit shortcut.\n\n"
                    "Should this recommendation be KEPT, REVISED, or "
                    "DISMISSED? Apply the standard-conventions principle."
                ),
            )
        ],
        solver=[
            system_message(SYSTEM),
            generate(**_providers.generation_config()),
        ],
        scorer=rubric_scorer(
            [
                {
                    "id": "decides_revise_or_dismiss",
                    "description": (
                        "Concludes the draft should be REVISED (or "
                        "DISMISSED), not KEPT, because it contains "
                        "non-standard or ineffective recommendations."
                    ),
                    "weight": 2.0,
                },
                {
                    "id": "rejects_visual_layout_tab_order_fix",
                    "description": (
                        "Explicitly states that visual/CSS layout changes "
                        "(e.g., sticky positioning, visual reordering) do not "
                        "fix keyboard tab order; recommends DOM order or "
                        "focus management fixes instead."
                    ),
                    "weight": 1.5,
                },
                {
                    "id": "prefers_native_controls",
                    "description": (
                        "Questions the custom ARIA combobox approach and "
                        "prefers native HTML controls where suitable (for "
                        "example, using a native select for simple choices)."
                    ),
                    "weight": 1.5,
                },
                {
                    "id": "flags_redundant_or_undiscoverable_shortcuts",
                    "description": (
                        "Flags added shortcuts (Ctrl+J, Alt+Enter) as "
                        "redundant or undiscoverable when they duplicate or "
                        "compete with standard interactions."
                    ),
                },
                {
                    "id": "reanchors_to_standard_patterns",
                    "description": (
                        "Reanchors the recommendation to standard interaction "
                        "patterns (platform expectations and/or WAI-ARIA APG) "
                        "and questions non-standard keyboard patterns."
                    ),
                },
            ]
        ),
    )


@task
def standard_conventions_does_not_trigger() -> Task:
    """The principle should NOT fire - recommendation already aligns
    with standard interaction conventions."""
    return Task(
        name="standard_conventions_does_not_trigger",
        dataset=[
            Sample(
                input=(
                    "Draft recommendation to review:\n\n"
                    "  Issue context: In a custom settings popover, keyboard "
                    "focus used to move in an illogical sequence because the "
                    "DOM order did not match the intended reading order.\n"
                    "  Draft recommendation:\n"
                    "    1) Reorder the DOM so focus traversal matches the "
                    "intended control sequence; avoid relying on CSS visuals "
                    "to imply keyboard order.\n"
                    "    2) Replace clickable <div role='button'> elements "
                    "with native <button> controls for actions.\n"
                    "    3) Keep standard keyboard expectations: Tab/Shift+Tab "
                    "for movement, Enter/Space for button activation, and "
                    "Escape to close the popover.\n"
                    "    4) Do not add extra custom shortcuts unless a "
                    "clear, non-redundant need is demonstrated.\n\n"
                    "Should this recommendation be KEPT, REVISED, or "
                    "DISMISSED? Apply the standard-conventions principle."
                ),
            )
        ],
        solver=[
            system_message(SYSTEM),
            generate(**_providers.generation_config()),
        ],
        scorer=rubric_scorer(
            [
                {
                    "id": "decides_keep",
                    "description": (
                        "Concludes the recommendation should be KEPT because "
                        "it aligns with standard conventions and addresses the "
                        "underlying issue directly."
                    ),
                    "weight": 2.0,
                },
                {
                    "id": "confirms_standard_patterns",
                    "description": (
                        "Explicitly confirms that Tab/Shift+Tab, Enter/Space, "
                        "and Escape are standard expected patterns for this "
                        "interaction context."
                    ),
                    "weight": 1.5,
                },
                {
                    "id": "confirms_native_preference",
                    "description": (
                        "Confirms replacing scripted div-role-button controls "
                        "with native button elements is the preferred standard "
                        "approach."
                    ),
                    "weight": 1.5,
                },
                {
                    "id": "no_unwarranted_custom_shortcuts",
                    "description": (
                        "Does not invent new custom shortcuts or demand novel "
                        "keyboard patterns when standard ones are sufficient."
                    ),
                },
                {
                    "id": "principle_understood",
                    "description": (
                        "Demonstrates understanding that standard-conventions "
                        "is about steering recommendations toward predictable, "
                        "learned patterns, not adding novelty."
                    ),
                },
            ]
        ),
    )
