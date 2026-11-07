"""Eval: cognitive-language consideration (clause 4.2.10).

Five sub-tests verifying the consideration file transfers SME knowledge:

- AT recall
- Exploration strategy recall
- Interaction context recall
- Heuristic lens override application (Heuristic 2 — Match Between System and
  Real World, including audience-appropriate-language calibration)
- Shared inheritance awareness

Each sub-test is a separate `@task` so it has its own rubric. Run with:

    python -m tests.evals tests/evals/considerations/eval_language_and_communication.py

Use `--consideration_context_mode all` to run the same tasks with all
elaborated considerations loaded in background context, while still grading
cognitive-language answers.
"""

# NOTE: This eval grades responses against the cognitive-language consideration, which
# adapts W3C COGA material. See considerations/cognitive-accessibility-sources.LICENSE.md for attribution.

from __future__ import annotations

from inspect_ai import Task, task
from inspect_ai.dataset import Sample
from inspect_ai.solver import generate, system_message

from tests.evals import _providers
from tests.evals._context import load_eval_consideration_context
from tests.evals._scorers import rubric_scorer

CONSIDERATION_ALIAS = "language-and-communication"
CONSIDERATION = load_eval_consideration_context(CONSIDERATION_ALIAS)


def _solver():
    return [system_message(CONSIDERATION), generate(**_providers.generation_config())]


@task
def at_recall() -> Task:
    return Task(
        name="language_and_communication_at_recall",
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
                    "id": "covers_read_aloud",
                    "description": (
                        "Mentions text-to-speech / read-aloud (ideally with "
                        "synchronized highlighting) as a primary route to "
                        "comprehension."
                    ),
                    "weight": 1.25,
                },
                {
                    "id": "covers_reading_simplification",
                    "description": (
                        "Mentions reading / simplification toolbars or extensions "
                        "that reformat, summarize, or simplify text."
                    ),
                },
                {
                    "id": "covers_symbol_aac",
                    "description": (
                        "Mentions symbol sets / AAC systems for understanding and "
                        "expression, and the importance of familiar symbols."
                    ),
                    "weight": 1.25,
                },
                {
                    "id": "covers_writing_support",
                    "description": (
                        "Mentions spell-check, grammar, or word-prediction tools "
                        "that help the user produce text."
                    ),
                    "weight": 0.75,
                },
                {
                    "id": "covers_definition_or_translation",
                    "description": (
                        "Mentions dictionary / glossary pop-ups OR translation / "
                        "phonetic readers OR considerationlization semantics."
                    ),
                    "weight": 0.75,
                },
                {
                    "id": "interaction_models_distinct",
                    "description": (
                        "Each tool has an interaction model that meaningfully "
                        "distinguishes it (decode vs. simplify vs. symbolize vs. "
                        "produce), not just renaming."
                    ),
                },
            ]
        ),
    )


@task
def strategy_recall() -> Task:
    return Task(
        name="language_and_communication_strategy_recall",
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
                    "id": "decoding_supported_reading",
                    "description": (
                        "Includes decoding-supported reading — using read-aloud, "
                        "rulers, or spacing to decode text rather than reading "
                        "fluently."
                    ),
                },
                {
                    "id": "skim_for_structure",
                    "description": (
                        "Includes extracting meaning from structure — headings, "
                        "summaries, lists, key points — rather than reading every "
                        "word."
                    ),
                },
                {
                    "id": "symbol_icon_navigation",
                    "description": (
                        "Includes recognizing content and controls by familiar "
                        "symbols or icons."
                    ),
                },
                {
                    "id": "literal_interpretation",
                    "description": (
                        "Includes taking language literally and needing explicit "
                        "meaning, checking for explanations of non-literal content."
                    ),
                },
                {
                    "id": "alternative_format_substitution",
                    "description": (
                        "Includes switching to an easier format (summary, simpler "
                        "version, image, video, read-aloud) when text is too dense."
                    ),
                },
                {
                    "id": "assisted_expression",
                    "description": (
                        "Includes producing input via word-prediction, symbols, or "
                        "speech rather than unaided typing and spelling."
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
        name="language_and_communication_variant_recall",
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
                    "id": "reading_disability_variant",
                    "description": (
                        "Includes a context of slow or effortful decoding, "
                        "with support from read-aloud "
                        "and structure."
                    ),
                },
                {
                    "id": "language_processing_variant",
                    "description": (
                        "Includes a context of comprehension or expression "
                        "difficulty needing short, "
                        "literal text."
                    ),
                },
                {
                    "id": "symbol_aac_variant",
                    "description": (
                        "Includes a context using symbols or AAC and "
                        "requiring familiar, consistently labelled symbols."
                    ),
                },
                {
                    "id": "literal_language_variant",
                    "description": (
                        "Includes a literal-language context where metaphor, "
                        "idiom, sarcasm, or implied content may obstruct comprehension."
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
def lens_override_h2() -> Task:
    return Task(
        name="language_and_communication_lens_override_h2",
        dataset=[
            Sample(
                input=(
                    "How does Heuristic 2 (Match Between System and Real World) "
                    "apply when language or communication support is needed? "
                    "Include how to judge whether "
                    "specialized domain terminology (for example, in an admin "
                    "console or a scientific tool) is or is not a clarity problem."
                ),
            )
        ],
        solver=_solver(),
        scorer=rubric_scorer(
            [
                {
                    "id": "plain_literal_language",
                    "description": (
                        "Notes the need for common words, simple active sentences, "
                        "and literal language with non-literal content explained."
                    ),
                },
                {
                    "id": "familiar_symbols",
                    "description": (
                        "Notes pairing important controls and headings with "
                        "familiar real-world symbols."
                    ),
                    "weight": 0.75,
                },
                {
                    "id": "audience_appropriate_calibration",
                    "description": (
                        "States that clarity is relative to the actual user base "
                        "and domain — necessary domain terminology the audience "
                        "knows and needs is NOT a clarity failure, and should not "
                        "be flagged as 'unclear words' for that audience."
                    ),
                    "weight": 2.0,
                },
                {
                    "id": "flags_unsupported_not_domain",
                    "description": (
                        "Distinguishes what TO flag (gratuitous or unexplained "
                        "jargon, coined words, inconsistent terms, necessary domain "
                        "terms left unsupported by definitions/examples) from what "
                        "NOT to flag (domain-correct vocabulary the audience relies "
                        "on)."
                    ),
                    "weight": 1.5,
                },
                {
                    "id": "consideration_specific",
                    "description": (
                        "The answer is specific to language / communication "
                        "concerns and does not just restate the generic Heuristic 2 "
                        "lens unchanged."
                    ),
                    "weight": 1.5,
                },
            ]
        ),
    )


@task
def shared_inheritance() -> Task:
    return Task(
        name="language_and_communication_shared_inheritance",
        dataset=[
            Sample(
                input=(
                    "The conditional shared reference defines six exploration strategies: "
                    "Visual scanning and layout comprehension, Mouse / pointer "
                    "interaction, Reading and scrolling, Form interaction, "
                    "Navigation and wayfinding, Touch / pointer interaction. For "
                    "each, state whether THIS consideration inherits it and justify in "
                    "one sentence based on document scope, not assumed unrelated "
                    "abilities. Do not introduce strategies outside "
                    "this list."
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
                        "in this scope (e.g. reading with read-aloud support, "
                        "recognizing symbols), not generic descriptions of the "
                        "strategies themselves."
                    ),
                },
            ]
        ),
    )
