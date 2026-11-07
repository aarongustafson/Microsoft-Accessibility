"""Eval: cognitive-numeracy consideration (clause 4.2.10).

Five sub-tests verifying the consideration file transfers SME knowledge:

- AT recall
- Exploration strategy recall
- Interaction context recall
- Heuristic lens override application (Heuristic 5 — Error Prevention)
- Shared inheritance awareness

Each sub-test is a separate `@task` so it has its own rubric. Run with:

    python -m tests.evals tests/evals/considerations/eval_numeracy_and_numeric_information.py

Use `--consideration_context_mode all` to run the same tasks with all
elaborated considerations loaded in background context, while still grading
cognitive-numeracy answers.
"""

# NOTE: This eval grades responses against the cognitive-numeracy consideration, which
# adapts W3C COGA material. See considerations/cognitive-accessibility-sources.LICENSE.md for attribution.

from __future__ import annotations

from inspect_ai import Task, task
from inspect_ai.dataset import Sample
from inspect_ai.solver import generate, system_message

from tests.evals import _providers
from tests.evals._context import load_eval_consideration_context
from tests.evals._scorers import rubric_scorer

CONSIDERATION_ALIAS = "numeracy-and-numeric-information"
CONSIDERATION = load_eval_consideration_context(CONSIDERATION_ALIAS)


def _solver():
    return [system_message(CONSIDERATION), generate(**_providers.generation_config())]


@task
def at_recall() -> Task:
    return Task(
        name="numeracy_and_numeric_information_at_recall",
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
                    "id": "covers_calculator_conversion",
                    "description": (
                        "Mentions calculators and unit / currency conversion tools "
                        "used to offload arithmetic and conversions."
                    ),
                    "weight": 1.25,
                },
                {
                    "id": "covers_tts_numbers",
                    "description": (
                        "Mentions text-to-speech used to hear numbers, ideally "
                        "noting it often misreads long numbers, codes, or symbols."
                    ),
                },
                {
                    "id": "covers_visual_aids",
                    "description": (
                        "Mentions visual aids — color coding, spacing, larger fonts "
                        "— used to pick out the relevant figure and not lose place."
                    ),
                },
                {
                    "id": "covers_considerationlization_concepts",
                    "description": (
                        "Mentions considerationlization semantics that substitute or "
                        "augment numbers with non-numeric concepts (cold/warm/hot, "
                        "small/medium/large)."
                    ),
                    "weight": 0.75,
                },
                {
                    "id": "covers_locale_units",
                    "description": (
                        "Mentions reliance on platform locale / unit / currency / "
                        "date defaults to avoid conversions."
                    ),
                    "weight": 0.75,
                },
                {
                    "id": "reframes_around_offloading_math",
                    "description": (
                        "Frames the tools around offloading calculation and "
                        "reinforcing figures with non-numeric cues, rather than as "
                        "generic assistive technology."
                    ),
                },
            ]
        ),
    )


@task
def strategy_recall() -> Task:
    return Task(
        name="numeracy_and_numeric_information_strategy_recall",
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
                    "id": "concept_over_number",
                    "description": (
                        "Includes reading the concept behind a number (hot, large, "
                        "almost full) rather than the raw figure."
                    ),
                },
                {
                    "id": "offloading_calculation",
                    "description": (
                        "Includes getting the answer from a tool or expecting the "
                        "system to compute it rather than doing mental arithmetic."
                    ),
                },
                {
                    "id": "magnitude_by_proxy",
                    "description": (
                        "Includes judging relative size / time / price via "
                        "non-numeric proxies (images, 'half way', now-markers, "
                        "relative labels)."
                    ),
                },
                {
                    "id": "verification_double_checking",
                    "description": (
                        "Includes re-checking numbers and relying on summaries and "
                        "warnings because the user cannot tell when a value 'looks "
                        "wrong'."
                    ),
                },
                {
                    "id": "format_unit_normalization",
                    "description": (
                        "Includes sticking to familiar units / formats and relying "
                        "on locale defaults to avoid conversions."
                    ),
                },
                {
                    "id": "excludes_shared_only",
                    "description": (
                        "Focuses on consideration-specific strategies; shared "
                        "strategies may be acknowledged as inherited but should not "
                        "dominate."
                    ),
                    "weight": 0.5,
                },
            ]
        ),
    )


@task
def variant_recall() -> Task:
    return Task(
        name="numeracy_and_numeric_information_variant_recall",
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
                    "id": "number_calculation_variant",
                    "description": (
                        "Includes a number-and-calculation variant who cannot "
                        "reliably read, compare, or calculate with numbers."
                    ),
                },
                {
                    "id": "quantity_magnitude_variant",
                    "description": (
                        "Includes a quantity-and-magnitude variant who cannot judge "
                        "how much / how big / how far / how expensive."
                    ),
                },
                {
                    "id": "time_sequence_variant",
                    "description": (
                        "Includes a time-and-sequence variant who struggles with "
                        "numeric times, dates, durations, and ordering."
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
def lens_override_h5() -> Task:
    return Task(
        name="numeracy_and_numeric_information_lens_override_h5",
        dataset=[
            Sample(
                input=(
                    "How does Heuristic 5 (Error Prevention) apply when a task involves "
                    "difficulty interpreting numbers, quantities, and "
                    "mathematical concepts? Focus on what this consideration's lens "
                    "override adds beyond the generic accessibility lens."
                ),
            )
        ],
        solver=_solver(),
        scorer=rubric_scorer(
            [
                {
                    "id": "computes_for_user",
                    "description": (
                        "States that the system should compute totals, durations, "
                        "and conversions rather than requiring mental arithmetic."
                    ),
                    "weight": 1.5,
                },
                {
                    "id": "warns_unusual_values",
                    "description": (
                        "Notes warning on unusual / extreme quantities or totals "
                        "and showing a summary before commitment, since the user "
                        "cannot tell a value is wrong."
                    ),
                },
                {
                    "id": "forgiving_formats_and_defaults",
                    "description": (
                        "Notes accepting number formats, chunking long numbers, "
                        "defaulting to locale units/dates, preventing impossible "
                        "choices, and not requiring recalled PINs/codes/CVV."
                    ),
                },
                {
                    "id": "consideration_specific",
                    "description": (
                        "The answer is specific to numeracy concerns and does not "
                        "just restate the generic Heuristic 5 lens unchanged."
                    ),
                    "weight": 2.0,
                },
            ]
        ),
    )


@task
def shared_inheritance() -> Task:
    return Task(
        name="numeracy_and_numeric_information_shared_inheritance",
        dataset=[
            Sample(
                input=(
                    "The conditional shared reference defines six exploration strategies: "
                    "Visual scanning and layout comprehension, Mouse / pointer "
                    "interaction, Reading and scrolling, Form interaction, "
                    "Navigation and wayfinding, Touch / pointer interaction. For "
                    "each, state whether THIS consideration inherits it and justify in "
                    "one sentence based on document scope, not assumed unrelated "
                    "abilities. Do not introduce strategies outside this list."
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
                        "scope, not evidence about sensory, motor, or language abilities."
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
                        "in this scope (e.g. numeric format and calculation "
                        "support during reading), without assuming unrelated "
                        "scanning, reading, or navigation abilities."
                    ),
                },
            ]
        ),
    )
