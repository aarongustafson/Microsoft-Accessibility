"""Eval: blind consideration (clause 4.2.1).

Five sub-tests verifying the consideration file transfers SME knowledge:

- AT recall
- Exploration strategy recall
- Interaction context recall
- Heuristic lens override application
- Shared inheritance awareness

Each sub-test is a separate `@task` so it has its own rubric. Run with:

    python -m tests.evals tests/evals/considerations/eval_nonvisual_access.py

Use `--consideration_context_mode all` to run the same tasks with all
elaborated considerations loaded in background context, while still grading
blind answers.

Add `-T` to limit to one sub-test, e.g. `--task at_recall`.
"""

from __future__ import annotations

from inspect_ai import Task, task
from inspect_ai.dataset import Sample
from inspect_ai.solver import generate, system_message

from tests.evals import _providers
from tests.evals._context import load_eval_consideration_context
from tests.evals._scorers import rubric_scorer

CONSIDERATION_ALIAS = "nonvisual-access"
CONSIDERATION = load_eval_consideration_context(CONSIDERATION_ALIAS)


def _solver():
    return [system_message(CONSIDERATION), generate(**_providers.generation_config())]


@task
def at_recall() -> Task:
    return Task(
        name="nonvisual_access_at_recall",
        dataset=[
            Sample(
                input=(
                    "Identify the assistive technology category(ies) this evaluation scope documents. "
                    "For each, give a one-sentence interaction model and name at least "
                    "one concrete tool, distinguished by platform where relevant."
                ),
            )
        ],
        solver=_solver(),
        scorer=rubric_scorer(
            [
                {
                    "id": "covers_screen_readers",
                    "description": (
                        "Mentions screen reader software (e.g., JAWS, NVDA, "
                        "VoiceOver, Narrator, TalkBack) as the primary AT "
                        "category for blind users."
                    ),
                    "weight": 2.0,
                },
                {
                    "id": "screen_reader_models_distinct",
                    "description": (
                        "Distinguishes screen readers by platform or interaction "
                        "model (e.g., JAWS/NVDA for desktop, VoiceOver for macOS/"
                        "iOS, TalkBack for Android, Narrator for Windows), showing "
                        "understanding of different contexts."
                    ),
                    "weight": 1.5,
                },
                {
                    "id": "covers_braille_display",
                    "description": (
                        "Mentions refreshable braille display as a distinct AT "
                        "category for users who read braille."
                    ),
                },
                {
                    "id": "no_false_categories",
                    "description": (
                        "Does NOT list visual/display-related ATs (magnifiers, zoom, "
                        "brightness, contrast) or mouse/pointer interaction AS ATs "
                        "AVAILABLE IN THIS EXPLICIT SCOPE. Mentioning them in a negated/contrastive "
                        "context (e.g., 'cannot use a magnifier') is acceptable and "
                        "counts as YES. Mark NO only if the answer presents these as "
                        "available or used by blind users."
                    ),
                    "weight": 2.0,
                },
            ]
        ),
    )


@task
def strategy_recall() -> Task:
    return Task(
        name="nonvisual_access_strategy_recall",
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
                    "id": "heading_navigation",
                    "description": (
                        "Includes heading-based navigation as a primary strategy "
                        "for scanning page structure via screen reader."
                    ),
                },
                {
                    "id": "landmark_navigation",
                    "description": (
                        "Includes navigation by ARIA landmarks (main, nav, aside, "
                        "region) for orienting within a page."
                    ),
                },
                {
                    "id": "element_list_navigation",
                    "description": (
                        "Includes using the screen reader's elements list (links, "
                        "buttons, headings, form fields) to jump to desired content."
                    ),
                    "weight": 1.5,
                },
                {
                    "id": "sequential_reading",
                    "description": (
                        "Includes sequential top-to-bottom reading with the screen "
                        "reader as a fallback or detailed review strategy."
                    ),
                },
                {
                    "id": "keyboard_shortcuts",
                    "description": (
                        "Includes keyboard shortcuts (e.g., JAWS/NVDA find, "
                        "application shortcuts) for efficient navigation."
                    ),
                    "weight": 0.75,
                },
                {
                    "id": "excludes_shared_only",
                    "description": (
                        "Lists strategies that are screen-reader-specific. "
                        "Strategies marked as shared (form interaction, navigation "
                        "and wayfinding, touch/pointer interaction) may be acknowledged "
                        "but should not dominate; visual/pointer-only strategies "
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
        name="nonvisual_access_variant_recall",
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
                    "id": "desktop_screen_reader_variant",
                    "description": (
                        "Includes a desktop screen reader variant (e.g., JAWS/NVDA "
                        "on Windows, VoiceOver on macOS) as distinct from mobile."
                    ),
                    "weight": 1.5,
                },
                {
                    "id": "mobile_screen_reader_variant",
                    "description": (
                        "Includes a mobile screen reader variant (VoiceOver on iOS, "
                        "TalkBack on Android) with touch-based interaction."
                    ),
                    "weight": 1.5,
                },
                {
                    "id": "braille_display_variant",
                    "description": (
                        "Includes a braille display interaction context, distinguishing "
                        "tactile reading from speech-only users."
                    ),
                },
                {
                    "id": "beginner_variant",
                    "description": (
                        "Includes a beginner/novice screen reader interaction context "
                        "with distinct strategies from expert users."
                    ),
                    "weight": 1.0,
                },
                {
                    "id": "differentiation_clear",
                    "description": (
                        "Each variant's differentiator is concrete and actionable "
                        "(e.g., specific screen reader, platform, skill level, or "
                        "AT combination), not just renaming the consideration."
                    ),
                },
            ]
        ),
    )


@task
def lens_override_h1() -> Task:
    return Task(
        name="nonvisual_access_lens_override_h1",
        dataset=[
            Sample(
                input=(
                    "How does Heuristic 1 (Visibility of System Status) "
                    "apply during nonvisual access with the documented AT configurations? Focus on what "
                    "this consideration's lens override adds beyond the generic "
                    "accessibility lens — screen reader feedback, audio cues, "
                    "and similar concerns."
                ),
            )
        ],
        solver=_solver(),
        scorer=rubric_scorer(
            [
                {
                    "id": "screen_reader_announcement",
                    "description": (
                        "Notes that status updates must be announced to screen "
                        "readers, not just visible on screen. Example: live regions, "
                        "aria-live, or spoken feedback."
                    ),
                    "weight": 2.0,
                },
                {
                    "id": "offline_screen_reader",
                    "description": (
                        "Addresses status updates that occur off-screen or in "
                        "floating elements that may be missed by screen reader focus."
                    ),
                    "weight": 1.5,
                },
                {
                    "id": "accessibility_tree_accuracy",
                    "description": (
                        "Emphasizes that semantics in the accessibility tree must "
                        "accurately reflect the interface state, not just visual state."
                    ),
                    "weight": 1.5,
                },
                {
                    "id": "audio_supplement",
                    "description": (
                        "Mentions audio cues or earcons that provide non-speech "
                        "feedback as a supplement to screen reader output."
                    ),
                    "weight": 0.75,
                },
                {
                    "id": "consideration_specific",
                    "description": (
                        "The answer is specific to blind/screen reader concerns and "
                        "does not just restate the generic Heuristic 1 lens unchanged."
                    ),
                    "weight": 2.0,
                },
            ]
        ),
    )


@task
def shared_inheritance() -> Task:
    return Task(
        name="nonvisual_access_shared_inheritance",
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
                        "Correctly identifies that visual scanning is NOT applicable "
                        "to blind users (they cannot visually scan or comprehend layouts visually)."
                    ),
                    "weight": 2.0,
                },
                {
                    "id": "inherits_form_nav_reading",
                    "description": (
                        "Correctly identifies that form interaction, navigation and "
                        "wayfinding, and reading and scrolling ARE inherited from shared "
                        "(blind users still interact with forms, navigate, and read)."
                    ),
                    "weight": 1.5,
                },
                {
                    "id": "inherits_touch_pointer",
                    "description": (
                        "Correctly identifies that touch/pointer interaction is inherited "
                        "(mobile screen reader users interact via touch)."
                    ),
                    "weight": 1.0,
                },
                {
                    "id": "justifications_grounded",
                    "description": (
                        "Justifications explain WHY (e.g., 'visual scanning is excluded "
                        "because blind users cannot see visual cues') rather than just "
                        "restating whether included/excluded."
                    ),
                    "weight": 1.0,
                },
            ]
        ),
    )
