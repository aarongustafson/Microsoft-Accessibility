"""Deterministic scorers for Accessibility Considerations Toolkit (Act) eval tasks.

This module contains the hidden-answer-key scorer and simple token-based
deterministic checks used by smoke tests and closed-set evals.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from typing import Any, Iterable

from inspect_ai.scorer import Score, Target, accuracy, mean, scorer, stderr
from inspect_ai.solver import TaskState


@dataclass(frozen=True)
class AnswerKeyItem:
    id: str
    matches: tuple[str, ...]
    weight: float = 1.0


@dataclass(frozen=True)
class ForbiddenAnswerKeyItem:
    id: str
    matches: tuple[str, ...]


def _normalize_match_text(value: str) -> str:
    lowered = value.casefold()
    lowered = re.sub(r"[^\w\s]+", " ", lowered)
    lowered = re.sub(r"\s+", " ", lowered)
    return lowered.strip()


def _coerce_match_list(value: Any) -> tuple[str, ...]:
    if isinstance(value, str):
        candidates = [value]
    elif isinstance(value, Iterable):
        candidates = [item for item in value if isinstance(item, str)]
    else:
        candidates = []

    normalized = [item.strip() for item in candidates if item and item.strip()]
    if not normalized:
        raise ValueError("Answer key items must include at least one match string")
    return tuple(normalized)


def _answer_key_item_from_value(value: Any, index: int) -> AnswerKeyItem:
    if isinstance(value, str):
        return AnswerKeyItem(
            id=f"item_{index}",
            matches=(value,),
        )

    if not isinstance(value, dict):
        raise TypeError("Answer key items must be strings or dicts")

    item_id = str(value.get("id") or f"item_{index}")
    matches = value.get("matches")
    if matches is None:
        matches = value.get("match")
    if matches is None:
        matches = value.get("aliases")
    if matches is None:
        matches = value.get("description")

    return AnswerKeyItem(
        id=item_id,
        matches=_coerce_match_list(matches),
        weight=float(value.get("weight", 1.0)),
    )


def _forbidden_answer_key_item_from_value(
    value: Any, index: int
) -> ForbiddenAnswerKeyItem:
    if isinstance(value, str):
        return ForbiddenAnswerKeyItem(
            id=f"forbidden_item_{index}",
            matches=(value,),
        )

    if not isinstance(value, dict):
        raise TypeError("Forbidden answer key items must be strings or dicts")

    item_id = str(value.get("id") or f"forbidden_item_{index}")
    matches = value.get("matches")
    if matches is None:
        matches = value.get("match")
    if matches is None:
        matches = value.get("aliases")
    if matches is None:
        matches = value.get("description")

    return ForbiddenAnswerKeyItem(
        id=item_id,
        matches=_coerce_match_list(matches),
    )


def parse_answer_key(
    target: Any,
    *,
    default_threshold: float = 0.8,
) -> tuple[list[AnswerKeyItem], list[ForbiddenAnswerKeyItem], float]:
    if isinstance(target, str):
        items_source = [target]
        forbidden_items_source: list[Any] = []
        threshold = default_threshold
    elif isinstance(target, list):
        items_source = target
        forbidden_items_source = []
        threshold = default_threshold
    elif isinstance(target, dict):
        items_source = target.get("items")
        if items_source is None:
            raise ValueError("Answer key target dict must include an 'items' list")
        forbidden_items_source = target.get("forbidden_items", [])
        threshold = float(target.get("threshold", default_threshold))
    else:
        raise TypeError(
            "Answer key target must be a string, a list of items, or a dict"
        )

    items = [
        _answer_key_item_from_value(item, index)
        for index, item in enumerate(items_source, start=1)
    ]
    if not items:
        raise ValueError("Answer key target must include at least one item")
    forbidden_items = [
        _forbidden_answer_key_item_from_value(item, index)
        for index, item in enumerate(forbidden_items_source, start=1)
    ]
    return items, forbidden_items, threshold


def score_answer_key(
    answer: str,
    target: Any,
    *,
    default_threshold: float = 0.8,
) -> tuple[float, bool, list[dict[str, Any]], float]:
    items, forbidden_items, threshold = parse_answer_key(
        target, default_threshold=default_threshold
    )
    normalized_answer = f" {_normalize_match_text(answer)} "
    total_weight = sum(item.weight for item in items) or 1.0
    matched_weight = 0.0
    breakdown: list[dict[str, Any]] = []

    for item in items:
        matched_phrase = None
        normalized_matches = [_normalize_match_text(candidate) for candidate in item.matches]
        for candidate in normalized_matches:
            if candidate and f" {candidate} " in normalized_answer:
                matched_phrase = candidate
                break

        matched = matched_phrase is not None
        if matched:
            matched_weight += item.weight

        breakdown.append(
            {
                "id": item.id,
                "kind": "required",
                "weight": item.weight,
                "matched": matched,
                "matched_phrase": matched_phrase,
                "matches": list(item.matches),
            }
        )

    forbidden_hit = False
    for item in forbidden_items:
        matched_phrase = None
        normalized_matches = [_normalize_match_text(candidate) for candidate in item.matches]
        for candidate in normalized_matches:
            if candidate and f" {candidate} " in normalized_answer:
                matched_phrase = candidate
                break

        matched = matched_phrase is not None
        if matched:
            forbidden_hit = True

        breakdown.append(
            {
                "id": item.id,
                "kind": "forbidden",
                "weight": 0.0,
                "matched": not matched,
                "matched_phrase": matched_phrase,
                "matches": list(item.matches),
            }
        )

    raw_score = matched_weight / total_weight
    passed = (raw_score >= threshold) and not forbidden_hit
    return raw_score, passed, breakdown, threshold


def _answer_key_source(target: Any, metadata: dict[str, Any] | None) -> Any:
    if metadata and "answer_key" in metadata:
        return metadata["answer_key"]
    return target


@scorer(metrics=[accuracy(), stderr(), mean()])
def answer_key_scorer(*, threshold: float = 0.8):
    """Deterministic scorer for hidden answer-key evals.

    The answer key may be provided either in `Sample.metadata["answer_key"]`
    or directly in `Sample.target`.

    Supported answer-key shapes are:
    - `"expected phrase"`
    - `["expected phrase", {"id": ..., "matches": [...], "weight": ...}]`
    - `{"items": [...], "threshold": 0.8}`

    Each item matches when any of its normalized phrases appears in the
    answer. The raw score is the weighted match fraction across items.
    """

    async def score(state: TaskState, target: Target) -> Score:
        answer = state.output.completion or ""
        answer_key = _answer_key_source(target, getattr(state, "metadata", None))
        raw_score, passed, breakdown, pass_threshold = score_answer_key(
            answer,
            answer_key,
            default_threshold=threshold,
        )
        explanation_lines = [
            f"score={raw_score:.2f} threshold={pass_threshold:.2f} passed={passed}",
        ]
        for item in breakdown:
            explanation_lines.append(
                f"- [{'MATCH' if item['matched'] else 'MISS'}] {item['id']} "
                f"(weight {item['weight']:.1f})"
            )
        return Score(
            value=1.0 if passed else 0.0,
            answer=answer,
            explanation="\n".join(explanation_lines),
            metadata={
                "score": raw_score,
                "threshold": pass_threshold,
                "items": breakdown,
            },
        )

    return score


@scorer(metrics=[accuracy(), stderr()])
def must_mention(tokens: Iterable[str], *, case_sensitive: bool = False):
    """Pass if every token appears as a substring of the answer."""
    needles = list(tokens)

    async def score(state: TaskState, target: Target) -> Score:
        answer = state.output.completion or ""
        haystack = answer if case_sensitive else answer.lower()
        missing = []
        for tok in needles:
            probe = tok if case_sensitive else tok.lower()
            if probe not in haystack:
                missing.append(tok)
        passed = not missing
        return Score(
            value=1.0 if passed else 0.0,
            answer=answer,
            explanation=("all tokens present" if passed else f"missing: {missing}"),
            metadata={"missing": missing, "required": needles},
        )

    return score


@scorer(metrics=[accuracy(), stderr()])
def must_not_mention(tokens: Iterable[str], *, case_sensitive: bool = False):
    """Pass if no token appears in the answer. Useful for refusal /
    'do not fabricate' checks."""
    needles = list(tokens)

    async def score(state: TaskState, target: Target) -> Score:
        answer = state.output.completion or ""
        haystack = answer if case_sensitive else answer.lower()
        present = []
        for tok in needles:
            probe = tok if case_sensitive else tok.lower()
            if probe in haystack:
                present.append(tok)
        passed = not present
        return Score(
            value=1.0 if passed else 0.0,
            answer=answer,
            explanation=("no forbidden tokens" if passed else f"present: {present}"),
            metadata={"present": present, "forbidden": needles},
        )

    return score