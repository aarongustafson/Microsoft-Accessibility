"""Eval: keyboard-only consideration (clause 4.2.7).

Core recall tests verify the consideration file transfers SME knowledge:

- AT recall
- Exploration strategy recall
- Interaction context recall
- Heuristic lens override application
- Shared inheritance awareness

Applied scenario tests add more benchmark-stable checks for focus handling,
keyboard-only navigation, and issue diagnosis.

Each sub-test is a separate `@task` so it has its own rubric. Run with:

    python -m tests.evals tests/evals/considerations/eval_keyboard_interaction.py

Use `--consideration_context_mode all` to run the same tasks with all
elaborated considerations loaded in background context, while still grading
keyboard-only answers.

Add `-T` to limit to one sub-test, e.g. `--task at_recall`.
"""

from __future__ import annotations

from pathlib import Path

from inspect_ai import Task, task
from inspect_ai.dataset import Sample
from inspect_ai.solver import generate, system_message

from tests.evals import _providers
from tests.evals._context import load_eval_consideration_context
from tests.evals._deterministic_scorer import must_mention, must_not_mention
from tests.evals._scorers import Criterion, rubric_scorer
from tests.evals.negative._image_scenarios import build_negative_image_task
from tests.evals.negative._text_scenarios import build_negative_text_task

CONSIDERATION_ALIAS = "keyboard-interaction"
CONSIDERATION = load_eval_consideration_context(CONSIDERATION_ALIAS)


def _solver():
    return [system_message(CONSIDERATION), generate(**_providers.generation_config())]


def _keyboard_scenario_scorers(
    criteria: list[dict | Criterion],
    *,
    required_tokens: tuple[str, ...] = (),
    forbidden_tokens: tuple[str, ...] = (),
):
    scorers = []
    if required_tokens:
        scorers.append(must_mention(required_tokens))
    if forbidden_tokens:
        scorers.append(must_not_mention(forbidden_tokens))
    scorers.append(rubric_scorer(criteria))
    return scorers


@task
def at_recall() -> Task:
    return Task(
        name="keyboard_interaction_at_recall",
        dataset=[
            Sample(
                input=(
                    "Identify the assistive technology category(ies) this evaluation scope documents. "
                    "For each, give a one-sentence interaction model. If the consideration "
                    "uses only one category, name at least one concrete example tool "
                    "within it, and clarify which common input methods this consideration "
                    "does NOT use."
                ),
            )
        ],
        solver=_solver(),
        scorer=rubric_scorer(
            [
                {
                    "id": "covers_keyboard",
                    "description": (
                        "Mentions standard keyboard as the primary AT for keyboard-only "
                        "users (no mouse or pointer device)."
                    ),
                    "weight": 2.0,
                },
                {
                    "id": "clarifies_no_mouse",
                    "description": (
                        "Clarifies that mouse/pointer input is unavailable or excluded "
                        "in the stated keyboard-only scope, not for every person."
                    ),
                    "weight": 1.5,
                },
                {
                    "id": "no_false_categories",
                    "description": (
                        "Does NOT list mouse, pointer, trackpad, touchscreen, or other "
                        "pointing devices AS ATs AVAILABLE IN THIS EXPLICIT SCOPE. Mentioning them in a "
                        "negated/contrastive context (e.g., 'cannot use a mouse') is "
                        "REQUIRED and counts as YES, not NO. Treat this criterion as NO "
                        "only if the answer presents pointing devices as available or "
                        "used input methods for this consideration."
                    ),
                    "weight": 2.0,
                },
            ]
        ),
    )


@task
def strategy_recall() -> Task:
    return Task(
        name="keyboard_interaction_strategy_recall",
        dataset=[
            Sample(
                input=(
                    "List the exploration strategies "
                    "documented for this scope (NOT conditional shared strategies). "
                    "For each, describe the access circumstances and interface requirements."
                ),
            )
        ],
        solver=_solver(),
        scorer=rubric_scorer(
            [
                {
                    "id": "tab_through_elements",
                    "description": (
                        "Includes tab-through navigation for accessing interactive "
                        "elements sequentially."
                    ),
                    "weight": 1.5,
                },
                {
                    "id": "focus_indicator_tracking",
                    "description": (
                        "Includes focus indicator tracking to maintain orientation and "
                        "understand where keyboard focus is located."
                    ),
                    "weight": 1.5,
                },
                {
                    "id": "arrow_key_navigation",
                    "description": (
                        "Includes arrow key navigation within widgets (e.g., selecting "
                        "from dropdowns, moving through menus)."
                    ),
                    "weight": 1.0,
                },
                {
                    "id": "keyboard_shortcuts",
                    "description": (
                        "Includes using keyboard shortcuts (access keys, hotkeys, "
                        "application shortcuts) for efficient navigation."
                    ),
                    "weight": 1.5,
                },
                {
                    "id": "visual_page_structure",
                    "description": (
                        "Includes visually scanning page structure and layout to understand "
                        "content organization and find targets before tabbing."
                    ),
                    "weight": 1.0,
                },
                {
                    "id": "excludes_mouse_only",
                    "description": (
                        "Lists keyboard-specific strategies. Mouse/pointer-only strategies "
                        "should NOT appear."
                    ),
                    "weight": 1.5,
                },
            ]
        ),
    )


@task
def variant_recall() -> Task:
    return Task(
        name="keyboard_interaction_variant_recall",
        dataset=[
            Sample(
                input=(
                    "List the interaction contexts defined for this consideration "
                    "(scope-specific, NOT the New/Expert shared "
                    "contexts). Describe explicit circumstances and requirements "
                    "without predicting individual abilities."
                ),
            )
        ],
        solver=_solver(),
        scorer=rubric_scorer(
            [
                {
                    "id": "limited_motor_variant",
                    "description": (
                        "Includes a limited fine motor control variant (difficulty "
                        "with precise pointer movements, mouse operation)."
                    ),
                    "weight": 1.5,
                },
                {
                    "id": "one_handed_variant",
                    "description": (
                        "Includes a one-handed keyboard interaction context with distinct "
                        "strategies from two-handed users."
                    ),
                    "weight": 1.5,
                },
                {
                    "id": "differentiation_clear",
                    "description": (
                        "Each variant's differentiator is concrete (fine motor limitation, "
                        "hand availability, dexterity level) and actionable."
                    ),
                    "weight": 1.0,
                },
            ]
        ),
    )


@task
def lens_override_h1() -> Task:
    return Task(
        name="keyboard_interaction_lens_override_h1",
        dataset=[
            Sample(
                input=(
                    "How does Heuristic 1 (Visibility of System Status) "
                    "apply when operating by keyboard alone? Focus on what "
                    "this consideration's lens override adds beyond the generic "
                    "accessibility lens — keyboard accessibility and focus "
                    "visibility."
                ),
            )
        ],
        solver=_solver(),
        scorer=rubric_scorer(
            [
                {
                    "id": "focus_indicator_prominent",
                    "description": (
                        "Notes that status updates must be discoverable via keyboard focus "
                        "and have prominent visual focus indicators (not just visible on-screen)."
                    ),
                    "weight": 2.0,
                },
                {
                    "id": "keyboard_navigation_status",
                    "description": (
                        "Emphasizes that status messages or indicators must be reachable "
                        "via keyboard navigation (tab, arrow keys, focus management)."
                    ),
                    "weight": 1.5,
                },
                {
                    "id": "status_not_pointer_dependent",
                    "description": (
                        "Notes that status feedback must NOT require mouse hover or pointer "
                        "interaction to be discovered or read."
                    ),
                    "weight": 1.5,
                },
                {
                    "id": "consideration_specific",
                    "description": (
                        "The answer is specific to keyboard-only concerns and does not just "
                        "restate the generic Heuristic 1 lens unchanged."
                    ),
                    "weight": 2.0,
                },
            ]
        ),
    )


@task
def shared_inheritance() -> Task:
    return Task(
        name="keyboard_interaction_shared_inheritance",
        dataset=[
            Sample(
                input=(
                    "Which shared exploration strategies does this consideration "
                    "inherit, and which are excluded? For each, justify in "
                    "one sentence."
                ),
            )
        ],
        solver=_solver(),
        scorer=rubric_scorer(
            [
                {
                    "id": "identifies_exclusions",
                    "description": (
                        "Correctly identifies that mouse/pointer interaction is NOT applicable "
                        "to keyboard-only users."
                    ),
                    "weight": 2.0,
                },
                {
                    "id": "inherits_vision_reading",
                    "description": (
                        "Correctly identifies that visual scanning, reading and scrolling, "
                        "form interaction, and navigation and wayfinding ARE inherited "
                        "(keyboard-only users still see and interact with forms)."
                    ),
                    "weight": 1.5,
                },
                {
                    "id": "justifications_grounded",
                    "description": (
                        "Justifications explain WHY (e.g., 'mouse is excluded; keyboard users "
                        "cannot use pointer devices') rather than just restating inclusions."
                    ),
                    "weight": 1.0,
                },
            ]
        ),
    )


@task
def combobox_navigation_from_image() -> Task:
    image_path = Path(__file__).resolve().parents[2] / "fixtures" / "images" / "combobox.png"
    return build_negative_image_task(
        task_name="keyboard_interaction_combobox_navigation_from_image",
        consideration_alias=CONSIDERATION_ALIAS,
        image_path=image_path,
        prompt_text=(
            "You are evaluating this synthetic service-selection image for a keyboard-only user. "
            "Describe how the user would navigate to and use the dropdown/combobox "
            "with only the keyboard, step by step. Then identify likely accessibility "
            "issues visible or inferable from the screenshot that could block or slow "
            "keyboard use. End with a clear judgement on whether the user can complete "
            "selection reliably, including uncertainty if image evidence is insufficient."
        ),
        scorer=_keyboard_scenario_scorers(
            [
                {
                    "id": "keyboard_path_described",
                    "description": (
                        "Provides a concrete keyboard interaction path to use the combobox "
                        "(e.g., focus movement via Tab/Shift+Tab plus opening/selection keys "
                        "such as Enter/Space/Arrow keys and closing with Escape)."
                    ),
                    "weight": 2.0,
                },
                {
                    "id": "issues_identified",
                    "description": (
                        "Identifies plausible keyboard-accessibility risks from the UI state, "
                        "such as weak/absent visible focus, unclear expanded state, hidden "
                        "options, clipped popup, or potential focus loss/trap during interaction."
                    ),
                    "weight": 2.0,
                },
                {
                    "id": "judgement_with_confidence",
                    "description": (
                        "Ends with a clear judgement about whether keyboard-only users can "
                        "reliably complete selection, and qualifies confidence/uncertainty "
                        "because screenshots cannot prove full keyboard behavior."
                    ),
                    "weight": 1.5,
                },
                {
                    "id": "consideration_aligned_language",
                    "description": (
                        "Keeps analysis aligned to keyboard-only user needs (focus visibility, "
                        "operability without pointer) and avoids suggesting mouse-only actions."
                    ),
                    "weight": 1.5,
                },
            ],
            required_tokens=("keyboard", "focus"),
            forbidden_tokens=("click the dropdown", "hover over", "use the mouse"),
        ),
        image_detail="high",
    )


@task
def menu_button_focus_scenario() -> Task:
    return build_negative_text_task(
        task_name="keyboard_interaction_menu_button_focus_scenario",
        consideration_alias=CONSIDERATION_ALIAS,
        prompt_text=(
            "A page has a button labeled 'Account'. A keyboard-only user presses Tab "
            "until the button is focused, then presses Enter. A flyout menu appears below "
            "the button, but visible focus stays on the button and Arrow Down does nothing. "
            "Describe whether the user can operate this pattern reliably, explain the likely "
            "keyboard-only issues, and describe what correct keyboard behavior should be."
        ),
        scorer=_keyboard_scenario_scorers(
            [
                {
                    "id": "detects_focus_management_failure",
                    "description": (
                        "Identifies that the menu is not reliably keyboard-operable because "
                        "focus does not move into the opened menu or otherwise provide a working "
                        "keyboard interaction path."
                    ),
                    "weight": 2.0,
                },
                {
                    "id": "describes_expected_navigation",
                    "description": (
                        "Describes correct keyboard behavior, such as opening with Enter/Space, "
                        "moving focus into the menu or first item, navigating items with arrow "
                        "keys, and closing with Escape."
                    ),
                    "weight": 2.0,
                },
                {
                    "id": "judges_user_cannot_rely",
                    "description": (
                        "Makes a clear judgement that the keyboard-only user cannot reliably use "
                        "the menu in its current state, or can do so only with serious friction."
                    ),
                    "weight": 1.5,
                },
                {
                    "id": "consideration_specific_reasoning",
                    "description": (
                        "Explains the impact in keyboard-only terms such as focus visibility, "
                        "operability, orientation, or inability to reach menu items without a pointer."
                    ),
                    "weight": 1.5,
                },
            ],
            required_tokens=("focus",),
            forbidden_tokens=("click the account button", "hover over", "use the mouse"),
        ),
    )


@task
def status_message_focus_scenario() -> Task:
    return build_negative_text_task(
        task_name="keyboard_interaction_status_message_focus_scenario",
        consideration_alias=CONSIDERATION_ALIAS,
        prompt_text=(
            "A keyboard-only user activates a 'Save settings' button with Enter. The form stays "
            "focused on the same button, and a green confirmation message appears at the top-right "
            "of the page with no focus movement. Explain the impact on this consideration, whether the "
            "user can be confident the action succeeded, and what better behavior would look like."
        ),
        scorer=_keyboard_scenario_scorers(
            [
                {
                    "id": "identifies_status_visibility_problem",
                    "description": (
                        "Identifies that the success message may be missed because focus stays on the "
                        "button while the visible status appears elsewhere."
                    ),
                    "weight": 2.0,
                },
                {
                    "id": "explains_keyboard_interaction_impact",
                    "description": (
                        "Explains that keyboard-only users track the interface through visible focus and "
                        "cannot rely on pointer location or hover cues to discover remote status changes."
                    ),
                    "weight": 2.0,
                },
                {
                    "id": "proposes_better_feedback_pattern",
                    "description": (
                        "Describes better behavior such as moving focus to the result, placing confirmation "
                        "adjacent to the action, or otherwise making the status discoverable from the current "
                        "keyboard position."
                    ),
                    "weight": 1.5,
                },
                {
                    "id": "clear_judgement",
                    "description": (
                        "Gives a clear judgement on whether the user can confidently tell the save succeeded."
                    ),
                    "weight": 1.5,
                },
            ],
            required_tokens=("focus", "keyboard"),
            forbidden_tokens=("hover", "click the message", "move the mouse"),
        ),
    )
