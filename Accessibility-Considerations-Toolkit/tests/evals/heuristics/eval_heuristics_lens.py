"""Per-heuristic x per-consideration lens-override matrix eval.

This module defines one @task per heuristic (1-10). Each task runs across
all elaborated considerations (or one diagonal consideration in quick mode).

Per sample, the solver injects either:
- slim context (default): one heuristic entry + relevant consideration sections, or
- full context: full heuristics + full consideration file (EVAL_FULL_CONTEXT=1).

Scoring is judge-only rubric scoring, anchored to the consideration's matching
"Heuristic N" override text.

Quick mode: EVAL_QUICK=1 (10 cells instead of 80).

Run:
        python -m tests.evals copilot/gpt-5-mini \
                heuristics/eval_heuristics_lens.py
"""

from __future__ import annotations

import os
import re
from functools import lru_cache

import yaml
from inspect_ai import Task, task
from inspect_ai.dataset import Sample
from inspect_ai.model import ChatMessageSystem, ChatMessageUser, get_model
from inspect_ai.scorer import Score, Target, accuracy, mean, scorer, stderr
from inspect_ai.solver import Generate, Solver, TaskState, generate, solver

from tests.evals import _providers
from tests.evals._context import (
    extract_section,
    extract_consideration_section,
    load_heuristic,
    load_heuristics,
    load_consideration_by_alias,
    load_required_consideration_safeguards,
)
from tests.evals._scorers import (
    Criterion,
    _JUDGE_INSTRUCTIONS,
    _parse_judge_output,
    _score_from_judgements,
    as_criteria,
)

HEURISTICS = load_heuristics()

# All elaborated considerations (clauses 4.2.1–4.2.7b).
ELABORATED_CONSIDERATIONS: list[str] = [
    "nonvisual-access",
    "visual-adaptation",
    "alternatives-to-colour-cues",
    "audio-alternatives",
    "audio-adaptation",
    "alternatives-to-speech-input",
    "keyboard-interaction",
    "voice-control",
]

HEURISTICS_LIST: list[tuple[int, str]] = [
    (1, "Visibility of System Status"),
    (2, "Match Between System and Real World"),
    (3, "User Control and Freedom"),
    (4, "Consistency and Standards"),
    (5, "Error Prevention"),
    (6, "Recognition Rather than Recall"),
    (7, "Flexibility and Efficiency of Use"),
    (8, "Aesthetic and Minimalist Design"),
    (9, "Help Users Recognize, Diagnose, and Recover from Errors"),
    (10, "Help and Documentation"),
]

# Diagonal pairing used when EVAL_QUICK=1 — one consideration per heuristic.
QUICK_CONSIDERATION_FOR_HEURISTIC: dict[int, str] = {
    1: "visual-adaptation",
    2: "nonvisual-access",
    3: "keyboard-interaction",
    4: "voice-control",
    5: "audio-adaptation",
    6: "alternatives-to-colour-cues",
    7: "alternatives-to-speech-input",
    8: "visual-adaptation",
    9: "nonvisual-access",
    10: "audio-alternatives",
}


# --- Context helpers -----------------------------------------------------

_RESPONSE_VOCABULARY_FRAMING = (
    "# Response vocabulary\n\n"
    "Describe violations and user impact in experiential, behavioural "
    "terms \u2014 what the user perceives, hears, attempts, or cannot "
    "do. Do not name HTML elements, ARIA attributes or roles, CSS "
    "properties, JavaScript APIs, or WCAG success criteria. This is a "
    "vocabulary constraint only; it does not change which violation or "
    "impact you choose to describe."
)


@lru_cache(maxsize=None)
def _extract_heuristic_entry(h_id: int) -> str:
    """Return the body of heuristics/h<id>-*.md.

    Each split file already contains exactly one heuristic entry
    (Definition + Accessibility Lens), so no slicing is needed.
    """
    return load_heuristic(h_id).strip()


def _build_cell_context(alias: str, h_id: int) -> str:
    """Build a slimmed system-prompt context for one (alias, h_id) cell.

    Includes only the relevant heuristic entry and the consideration sections
    needed for the three-part answer: Evaluation Considerations, Assistive
    Technologies, Exploration Strategies, and Heuristic Lens Overrides.
    Set EVAL_FULL_CONTEXT=1 to bypass this and use full context instead.
    """
    heuristic_entry = _extract_heuristic_entry(h_id)
    consideration = load_consideration_by_alias(alias)
    consideration_prompt = extract_consideration_section(consideration, "Evaluation Considerations")
    at_section = extract_consideration_section(consideration, "Assistive Technologies")
    strat_section = extract_consideration_section(consideration, "Exploration Strategies")
    lens_section = extract_consideration_section(consideration, "Heuristic Lens Overrides")

    consideration_parts: list[str] = []
    if consideration_prompt:
        consideration_parts.append(f"## Evaluation Considerations\n\n{consideration_prompt}")
    if at_section:
        consideration_parts.append(f"## Assistive Technologies\n\n{at_section}")
    if strat_section:
        consideration_parts.append(f"## Exploration Strategies\n\n{strat_section}")
    if lens_section:
        consideration_parts.append(f"## Heuristic Lens Overrides\n\n{lens_section}")
    consideration_block = "\n\n".join(consideration_parts)

    return (
        f"{load_required_consideration_safeguards()}\n\n"
        f"{_RESPONSE_VOCABULARY_FRAMING}\n\n"
        f"# Heuristic {h_id} reference\n\n{heuristic_entry}\n\n"
        f"# Consideration reference (alias: {alias})\n\n{consideration_block}"
    )


@solver
def inject_consideration_system_prompt() -> Solver:
    """Build the per-cell system prompt from Sample.metadata.

    Default: slimmed context — single heuristic entry + relevant consideration
    sections (Evaluation Considerations, Assistive Technologies, Exploration
    Strategies, Heuristic Lens Overrides).
    Set EVAL_FULL_CONTEXT=1 to inject the full heuristics aggregate
    (index + all 10 split files) + full consideration file for expanded
    instruction-size testing.
    """

    async def solve(state: TaskState, generate: Generate) -> TaskState:
        alias = (state.metadata or {}).get("consideration_alias")
        h_id = int((state.metadata or {}).get("heuristic_id", 0))
        if not alias or not h_id:
            raise ValueError(
                "Sample metadata must include 'consideration_alias' and 'heuristic_id'"
            )
        full_context = os.environ.get("EVAL_FULL_CONTEXT", "").lower() in {
            "1", "true", "yes"
        }
        if full_context:
            consideration = load_consideration_by_alias(alias)
            content = (
                f"{load_required_consideration_safeguards()}\n\n"
                f"{_RESPONSE_VOCABULARY_FRAMING}\n\n"
                f"# Heuristics reference\n\n{HEURISTICS}\n\n"
                f"# Consideration reference (alias: {alias})\n\n{consideration}"
            )
        else:
            content = _build_cell_context(alias, h_id)
        state.messages.insert(0, ChatMessageSystem(content=content))
        return state

    return solve


# Simplified prompt structure

def _prompt_for(h_id: int, h_title: str, alias: str) -> str:
    return (
        f"Apply Heuristic {h_id} ({h_title}) to the {alias} consideration. "
        f"Describe one concrete UI pattern that would violate this heuristic for the consideration, "
        f"and explain why it would fail."
    )


def _samples_for_heuristic(h_id: int, h_title: str) -> list[Sample]:
    if _providers.is_quick_mode():
        aliases = [QUICK_CONSIDERATION_FOR_HEURISTIC[h_id]]
    else:
        aliases = ELABORATED_CONSIDERATIONS
    return [
        Sample(
            input=_prompt_for(h_id, h_title, alias),
            metadata={
                "heuristic_id": h_id,
                "heuristic_title": h_title,
                "consideration_alias": alias,
                "label": f"h{h_id}_{alias}",
            },
        )
        for alias in aliases
    ]


# --- Source extraction helpers -------------------------------------------


def _consideration_lens_override(alias: str, h_id: int) -> str:
    """Return the raw text of `### Heuristic N — …` from the consideration's
    `## Heuristic Lens Overrides` section, or an empty string if absent.
    """
    consideration = load_consideration_by_alias(alias)
    if not consideration.startswith("---"):
        return yaml.safe_load(consideration).get("heuristic_overrides", {}).get(h_id, "")
    section = extract_section(consideration, "Heuristic Lens Overrides")
    if not section:
        return ""
    pattern = (
        rf"^###\s+Heuristic\s+{h_id}\s+[—–-].*?\n(.*?)"
        rf"(?=^###\s+Heuristic\s+\d+\b|\Z)"
    )
    m = re.search(pattern, section, re.MULTILINE | re.DOTALL)
    return m.group(1).strip() if m else ""


# --- Source-anchored rubric scorer ---------------------------------------

RUBRIC_CRITERIA: list[dict] = [
    {
        "id": "states_generic_lens",
        "description": (
            "States the generic accessibility lens for this heuristic as defined in heuristics/h<id>-*.md. "
            "Contextualizes or contrasts it for the named consideration, explaining how it applies differently "
            "given the consideration's assistive technology or context."
        ),
        "weight": 1.0,
    },
    {
        "id": "applies_consideration_lens",
        "description": (
            "Reproduces the consideration's lens override for this heuristic, capturing specific concerns "
            "like named AT behavior or interaction patterns."
        ),
        "weight": 1.5,
    },
    {
        "id": "concrete_violation",
        "description": (
            "Describes a specific UI pattern that would violate this heuristic for the consideration. "
            "Avoids generic categories like 'forms with errors.'"
        ),
        "weight": 1.5,
    },
    {
        "id": "violation_grounded_in_consideration",
        "description": (
            "Explains why the violation fails the user, referencing specific assistive technologies "
            "or exploration strategies from the consideration file."
        ),
        "weight": 1.0,
    },
]


def _build_lens_judge_prompt(
    answer: str,
    criteria: list[Criterion],
    *,
    alias: str,
    h_id: int,
    h_title: str,
    override_text: str,
) -> str:
    criteria_block = "\n".join(
        f"- id: {c.id}\n  description: {c.description}" for c in criteria
    )
    reference = (
        override_text.strip()
        or "(No override entry found in the consideration file for this heuristic.)"
    )
    return (
        f"CONSIDERATION: {alias}\n"
        f"HEURISTIC: {h_id} — {h_title}\n\n"
        "REFERENCE OVERRIDE (verbatim from the consideration's "
        "`## Heuristic Lens Overrides` section, between <<< and >>>):\n<<<\n"
        f"{reference}\n>>>\n\n"
        "ANSWER UNDER REVIEW (between <<< and >>>):\n<<<\n"
        f"{answer}\n>>>\n\n"
        "RUBRIC CRITERIA:\n"
        f"{criteria_block}\n\n"
        "Grade `applies_consideration_lens` against the REFERENCE OVERRIDE — "
        "the answer must reproduce its specific concerns, not just the "
        "generic heuristic.\n\n"
        "Return only the JSON object specified in your instructions."
    )


@scorer(metrics=[accuracy(), stderr(), mean()])
def heuristic_lens_scorer(
    criteria: list[dict | Criterion],
    *,
    judge: str | None = None,
    threshold: float | None = None,
):
    """Source-anchored rubric scorer judged against the consideration's
    lens-override entry. Six criteria; no pre-gate."""
    parsed = as_criteria(criteria)
    judge_id = judge or _providers.judge_model()
    pass_threshold = (
        threshold if threshold is not None else _providers.rubric_threshold()
    )

    async def score(state: TaskState, target: Target) -> Score:
        meta = state.metadata or {}
        alias = str(meta.get("consideration_alias", ""))
        h_id = int(meta.get("heuristic_id", 0))
        h_title = str(meta.get("heuristic_title", ""))
        if not alias or not h_id:
            raise ValueError(
                "heuristic_lens_scorer requires `consideration_alias` and "
                "`heuristic_id` in Sample.metadata"
            )

        answer = state.output.completion or ""
        override_text = _consideration_lens_override(alias, h_id)
        judge_obj = get_model(judge_id)
        result = await judge_obj.generate(
            input=[
                ChatMessageSystem(content=_JUDGE_INSTRUCTIONS),
                ChatMessageUser(
                    content=_build_lens_judge_prompt(
                        answer,
                        parsed,
                        alias=alias,
                        h_id=h_id,
                        h_title=h_title,
                        override_text=override_text,
                    )
                ),
            ]
        )
        judgements = _parse_judge_output(result.completion)
        raw_score, breakdown = _score_from_judgements(parsed, judgements)
        passed = raw_score >= pass_threshold
        explanation_lines = [
            f"score={raw_score:.2f} threshold={pass_threshold:.2f} "
            f"passed={passed}",
        ]
        for b in breakdown:
            explanation_lines.append(
                f"- [{b['verdict']}] {b['id']} (weight {b['weight']:.1f}): "
                f"{b['reason']}"
            )
        return Score(
            value=1.0 if passed else 0.0,
            answer=answer,
            explanation="\n".join(explanation_lines),
            metadata={
                "score": raw_score,
                "threshold": pass_threshold,
                "criteria": breakdown,
                "judge_model": judge_id,
                "override_present": bool(override_text),
            },
        )

    return score


def _make_task(h_id: int, h_title: str) -> Task:
    return Task(
        name=f"heuristic_lens_h{h_id}",
        dataset=_samples_for_heuristic(h_id, h_title),
        solver=[
            inject_consideration_system_prompt(),
            generate(**_providers.generation_config()),
        ],
        scorer=heuristic_lens_scorer(RUBRIC_CRITERIA),
    )


# One @task per heuristic; each runs across all 8 elaborated considerations
# (or 1 in quick mode).


@task
def heuristic_lens_h1() -> Task:
    return _make_task(1, "Visibility of System Status")


@task
def heuristic_lens_h2() -> Task:
    return _make_task(2, "Match Between System and Real World")


@task
def heuristic_lens_h3() -> Task:
    return _make_task(3, "User Control and Freedom")


@task
def heuristic_lens_h4() -> Task:
    return _make_task(4, "Consistency and Standards")


@task
def heuristic_lens_h5() -> Task:
    return _make_task(5, "Error Prevention")


@task
def heuristic_lens_h6() -> Task:
    return _make_task(6, "Recognition Rather than Recall")


@task
def heuristic_lens_h7() -> Task:
    return _make_task(7, "Flexibility and Efficiency of Use")


@task
def heuristic_lens_h8() -> Task:
    return _make_task(8, "Aesthetic and Minimalist Design")


@task
def heuristic_lens_h9() -> Task:
    return _make_task(
        9, "Help Users Recognize, Diagnose, and Recover from Errors"
    )


@task
def heuristic_lens_h10() -> Task:
    return _make_task(10, "Help and Documentation")
