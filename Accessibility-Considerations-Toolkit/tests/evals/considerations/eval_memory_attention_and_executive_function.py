"""Eval: cognitive-memory consideration (clause 4.2.10).

Five sub-tests verifying the consideration file transfers SME knowledge:

- AT recall
- Exploration strategy recall
- Interaction context recall
- Heuristic lens override application (Heuristic 6 — Recognition over Recall)
- Shared inheritance awareness

Each sub-test is a separate `@task` so it has its own rubric. Run with:

    python -m tests.evals tests/evals/considerations/eval_memory_attention_and_executive_function.py

Use `--consideration_context_mode all` to run the same tasks with all
elaborated considerations loaded in background context, while still grading
cognitive-memory answers.
"""

# NOTE: This eval grades responses against the cognitive-memory consideration, which
# adapts W3C COGA material. See considerations/cognitive-accessibility-sources.LICENSE.md for attribution.

from __future__ import annotations

from inspect_ai import Task, task
from inspect_ai.dataset import Sample
from inspect_ai.solver import generate, system_message

from tests.evals import _providers
from tests.evals._context import load_eval_consideration_context
from tests.evals._scorers import rubric_scorer

CONSIDERATION_ALIAS = "memory-attention-and-executive-function"
CONSIDERATION = load_eval_consideration_context(CONSIDERATION_ALIAS)


def _solver():
    return [system_message(CONSIDERATION), generate(**_providers.generation_config())]


@task
def at_recall() -> Task:
    return Task(
        name="memory_attention_and_executive_function_at_recall",
        dataset=[
            Sample(
                input=(
                    "Identify the assistive technologies and support tools "
                    "documented for this scope. For each, give a one-sentence interaction model "
                    "and name a concrete example."
                ),
            )
        ],
        solver=_solver(),
        scorer=rubric_scorer(
            [
                {
                    "id": "covers_reminder_calendar",
                    "description": (
                        "Mentions reminder / calendar / notification tools used to "
                        "offload dates, deadlines, and steps out of memory."
                    ),
                },
                {
                    "id": "covers_password_manager",
                    "description": (
                        "Mentions password managers that store / auto-fill "
                        "credentials so the user need not recall or transcribe them."
                    ),
                },
                {
                    "id": "covers_simplification_focus",
                    "description": (
                        "Mentions reading / de-clutter / focus or distraction-"
                        "removing extensions used to reduce clutter and sustain "
                        "attention."
                    ),
                },
                {
                    "id": "covers_form_autofill",
                    "description": (
                        "Mentions form autofill / autocomplete that re-enters "
                        "routine information to avoid recall and re-typing."
                    ),
                    "weight": 0.75,
                },
                {
                    "id": "covers_read_aloud_or_considerationlization",
                    "description": (
                        "Mentions text-to-speech / read-aloud OR considerationlization / "
                        "simplification semantics as a support."
                    ),
                    "weight": 0.75,
                },
                {
                    "id": "reframes_as_mainstream_reliance",
                    "description": (
                        "Frames support as a mix of mainstream features, browser "
                        "extensions, and reliance on built-in platform aids (Back, "
                        "undo, autosave) rather than a single dedicated AT."
                    ),
                    "weight": 1.5,
                },
            ]
        ),
    )


@task
def strategy_recall() -> Task:
    return Task(
        name="memory_attention_and_executive_function_strategy_recall",
        dataset=[
            Sample(
                input=(
                    "List the scope-specific exploration strategies to check "
                    "(NOT conditional shared strategies). For each, "
                    "describe the explicit access circumstances and requirements."
                ),
            )
        ],
        solver=_solver(),
        scorer=rubric_scorer(
            [
                {
                    "id": "orientation_reorientation",
                    "description": (
                        "Includes orientation / re-orientation — using headings, "
                        "breadcrumbs, and step indicators to recover context after "
                        "losing focus."
                    ),
                },
                {
                    "id": "chunked_task_progression",
                    "description": (
                        "Includes working through a task one step at a time, "
                        "relying on each step carrying forward needed information."
                    ),
                },
                {
                    "id": "recognition_over_recall",
                    "description": (
                        "Includes relying on recognition — familiar conventional "
                        "patterns and visible labels — rather than recalling paths "
                        "or shortcuts."
                    ),
                },
                {
                    "id": "distraction_management",
                    "description": (
                        "Includes managing distractions — pausing or blocking "
                        "moving content, notifications, and clutter to hold focus."
                    ),
                },
                {
                    "id": "offloading_external_aids",
                    "description": (
                        "Includes offloading information to external aids "
                        "(reminders, autofill, password managers, notes)."
                    ),
                },
                {
                    "id": "feedback_confirmed_action",
                    "description": (
                        "Includes confirming each action succeeded via explicit "
                        "feedback before proceeding."
                    ),
                },
                {
                    "id": "excludes_shared_only",
                    "description": (
                        "Focuses on consideration-specific strategies; shared "
                        "strategies (visual scanning, mouse / pointer, reading and "
                        "scrolling, form interaction, navigation and wayfinding, "
                        "touch / pointer) may be acknowledged as inherited but "
                        "should not dominate."
                    ),
                    "weight": 0.5,
                },
            ]
        ),
    )


@task
def variant_recall() -> Task:
    return Task(
        name="memory_attention_and_executive_function_variant_recall",
        dataset=[
            Sample(
                input=(
                    "List the interaction contexts documented for this scope "
                    "(NOT the New/Expert shared contexts). For each, "
                    "describe explicit circumstances and requirements, not individual abilities."
                ),
            )
        ],
        solver=_solver(),
        scorer=rubric_scorer(
            [
                {
                    "id": "working_memory_variant",
                    "description": (
                        "Includes a working-memory-limited variant whose barrier is "
                        "carrying / transcribing information across steps."
                    ),
                },
                {
                    "id": "attention_distraction_variant",
                    "description": (
                        "Includes an attention- and distraction-sensitive variant "
                        "derailed by interruptions and moving content."
                    ),
                },
                {
                    "id": "executive_function_variant",
                    "description": (
                        "Includes an executive-function / processing-speed variant "
                        "needing planning support, clear steps, and more time."
                    ),
                },
                {
                    "id": "progressive_decline_variant",
                    "description": (
                        "Includes a progressive-memory-decline variant that cannot "
                        "learn new patterns and depends on familiar, unchanging "
                        "designs."
                    ),
                },
                {
                    "id": "differentiation_clear",
                    "description": (
                        "Each variant's differentiator is concrete and actionable, "
                        "not just renaming the consideration."
                    ),
                },
            ]
        ),
    )


@task
def lens_override_h6() -> Task:
    return Task(
        name="memory_attention_and_executive_function_lens_override_h6",
        dataset=[
            Sample(
                input=(
                    "How does Heuristic 6 (Recognition Rather than Recall) apply "
                    "when memory, attention, or executive-function support is needed? "
                    "Focus on what this consideration's lens override "
                    "adds beyond the generic accessibility lens."
                ),
            )
        ],
        solver=_solver(),
        scorer=rubric_scorer(
            [
                {
                    "id": "info_at_point_of_use",
                    "description": (
                        "States that everything needed to act must be visible at "
                        "the point of use, so the user never has to hold "
                        "information in mind."
                    ),
                    "weight": 1.5,
                },
                {
                    "id": "no_recall_across_steps",
                    "description": (
                        "Notes the user should not have to remember codes, prior "
                        "choices, menu locations, or shortcuts; carry data forward."
                    ),
                },
                {
                    "id": "labels_persist",
                    "description": (
                        "Notes that labels and instructions must not vanish when a "
                        "field gains focus."
                    ),
                },
                {
                    "id": "consideration_specific",
                    "description": (
                        "The answer is specific to memory / attention / executive "
                        "function concerns and does not just restate the generic "
                        "Heuristic 6 lens unchanged."
                    ),
                    "weight": 2.0,
                },
            ]
        ),
    )


@task
def shared_inheritance() -> Task:
    return Task(
        name="memory_attention_and_executive_function_shared_inheritance",
        dataset=[
            Sample(
                input=(
                    "The conditional shared reference defines six exploration strategies: "
                    "Visual scanning and layout comprehension, Mouse / pointer "
                    "interaction, Reading and scrolling, Form interaction, "
                    "Navigation and wayfinding, Touch / pointer interaction. For "
                    "each, state whether THIS consideration inherits it and justify in "
                    "one sentence based on document scope, not assumed unrelated "
                    "abilities. Do not introduce "
                    "strategies outside this list."
                ),
            )
        ],
        solver=_solver(),
        scorer=rubric_scorer(
            [
                {
                    "id": "all_strategies_apply",
                    "description": (
                        "States that this consideration has NO shared exclusions — all "
                        "six shared strategies are included conditionally in the "
                        "scope, not evidence about anyone's sensory or motor abilities."
                    ),
                    "weight": 2.0,
                },
                {
                    "id": "no_false_exclusions",
                    "description": (
                        "Does NOT incorrectly claim any shared strategy is "
                        "excluded for this consideration."
                    ),
                    "weight": 1.5,
                },
                {
                    "id": "justifications_grounded",
                    "description": (
                        "Justifications reference conditional applicability "
                        "in this scope (e.g. needing consistent "
                        "navigation, feedback, and reduced clutter), not generic "
                        "descriptions of the strategies themselves."
                    ),
                },
            ]
        ),
    )
