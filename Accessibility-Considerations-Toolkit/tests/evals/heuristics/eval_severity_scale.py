"""Severity scale evals for single-consideration and consideration-variance tasks.

This module has two tasks:
- severity_scale_assignment: one scenario -> one overall 0-4 rating.
- severity_consideration_variance: one scenario -> per-consideration ratings.

Both tasks use deterministic numeric scorers plus rubric-based quality
scoring. Consideration-variance also checks per-consideration label consistency.

Modes:
- EVAL_QUICK=1 runs only the first scenario in each task.
- EVAL_SEVERITY_EXPECTATION_MODE=strict|benchmark controls expected
  per-consideration severity windows (benchmark relaxes by +/-1).

Run:
    python -m tests.evals copilot/gpt-5-mini \
        heuristics/eval_severity_scale.py
"""

from __future__ import annotations

import os
import re
from typing import Any

from inspect_ai import Task, task
from inspect_ai.dataset import Sample
from inspect_ai.model import ChatMessageSystem, ChatMessageUser, get_model
from inspect_ai.scorer import Score, Target, accuracy, mean, scorer, stderr
from inspect_ai.solver import TaskState, generate, system_message

from tests.evals import _providers
from tests.evals._context import load_severity
from tests.evals._scorers import (
    Criterion,
    _JUDGE_INSTRUCTIONS,
    _parse_judge_output,
    _score_from_judgements,
    as_criteria,
    rubric_scorer,
)

SEVERITY = load_severity()


# --- Severity rating parsing ---------------------------------------------

_SEVERITY_LABELS = (
    "critical",
    "significant",
    "moderate",
    "low",
    "trivial",
)

_RATING_TO_LABEL: dict[int, str] = {
    0: "critical",
    1: "significant",
    2: "moderate",
    3: "low",
    4: "trivial",
}

# Strictness mode for scenario expectations:
# - strict: exact/range expectations as authored
# - benchmark: widen expectations by one step to reduce over-penalizing
#   borderline severity judgements in model-quality benchmarking.
_EXPECTATION_MODE_ENV = "EVAL_SEVERITY_EXPECTATION_MODE"

# Patterns that strongly indicate a number-label severity pair.
_RATING_LABEL_PATTERNS = (
    # "0 - Critical", "2: Moderate", "4 (Trivial)"
    re.compile(
        r"\b([0-4])\s*(?:[—–\-:]\s*|\(\s*)"
        r"(critical|significant|moderate|low|trivial)\b",
        re.IGNORECASE,
    ),
    # "Critical - 0", "Low: 3", "Trivial (4)"
    re.compile(
        r"\b(critical|significant|moderate|low|trivial)\b\s*"
        r"(?:[—–\-:]\s*|\(\s*)?([0-4])\b",
        re.IGNORECASE,
    ),
)

# Patterns that strongly indicate "this number is the severity rating".
# Ordered most-specific-first; first match wins.
_NUMERIC_PATTERNS = (
    # "0 — Critical", "2 - Moderate", "4 – Trivial"
    re.compile(
        r"\b([0-4])\s*[—–\-:]\s*(?:critical|significant|moderate|low|trivial)\b",
        re.IGNORECASE,
    ),
    # "Severity: 2", "Severity = 2", "Rating: 3"
    re.compile(
        r"\b(?:severity|rating|score)\b\s*[:=]?\s*([0-4])\b",
        re.IGNORECASE,
    ),
    # "rated as 2", "rate this 3"
    re.compile(
        r"\brate(?:d|s)?\s+(?:this\s+|it\s+|as\s+)?\s*([0-4])\b",
        re.IGNORECASE,
    ),
)


def _parse_overall_rating(text: str) -> int | None:
    text = re.sub(r"[*_`]+", "", text)
    for pattern in _NUMERIC_PATTERNS:
        m = pattern.search(text)
        if m:
            return int(m.group(1))
    return None


def _severity_label_for_rating(rating: int) -> str | None:
    return _RATING_TO_LABEL.get(rating)


def _extract_first_label(text: str) -> str | None:
    text = re.sub(r"[*_`]+", "", text)
    m = re.search(r"\b(critical|significant|moderate|low|trivial)\b", text, re.I)
    if not m:
        return None
    return m.group(1).strip().lower()


def _extract_rating_label_pairs(text: str) -> list[tuple[int, str]]:
    """Extract candidate (rating, label) pairs from text in reading order."""
    text = re.sub(r"[*_`]+", "", text)
    hits: list[tuple[int, int, str]] = []
    seen: set[tuple[int, int, str]] = set()
    for idx, pattern in enumerate(_RATING_LABEL_PATTERNS):
        for m in pattern.finditer(text):
            if idx == 0:
                rating = int(m.group(1))
                label = m.group(2).strip().lower()
            else:
                label = m.group(1).strip().lower()
                rating = int(m.group(2))
            key = (m.start(), rating, label)
            if key in seen:
                continue
            seen.add(key)
            hits.append(key)
    hits.sort(key=lambda t: t[0])
    return [(rating, label) for _, rating, label in hits]


def _label_matches_rating(rating: int, label: str) -> bool:
    expected = _severity_label_for_rating(rating)
    return expected is not None and label.strip().lower() == expected


def _expectation_mode() -> str:
    raw = os.environ.get(_EXPECTATION_MODE_ENV, "strict").strip().lower()
    return "benchmark" if raw == "benchmark" else "strict"


def _relax_expected_value(expected: Any) -> int | list[int]:
    if isinstance(expected, (list, tuple)) and len(expected) == 2:
        lo = int(expected[0])
        hi = int(expected[1])
        return [max(0, lo - 1), min(4, hi + 1)]
    value = int(expected)
    return [max(0, value - 1), min(4, value + 1)]


def _expectations_for_mode(expectations: dict[str, Any]) -> dict[str, Any]:
    mode = _expectation_mode()
    if mode == "strict":
        return dict(expectations)
    return {k: _relax_expected_value(v) for k, v in expectations.items()}


def _consideration_alias_pattern(consideration: str) -> str:
    """Build a tolerant regex for consideration aliases.

    Treats hyphen/underscore/space as interchangeable so aliases like
    "voice-control" match headings such as "Voice Access".
    """
    parts = [p for p in re.split(r"[-_\s]+", consideration.strip()) if p]
    if not parts:
        return re.escape(consideration)
    return r"\b" + r"[-_\s]*".join(re.escape(p) for p in parts) + r"\b"


def _consideration_scoped_text(text: str, consideration: str) -> str:
    """Extract consideration-specific block text if present, else nearby text.

    Block detection order:
    1. `Consideration: <alias>` labelled block (until next `Consideration:` or end).
    2. Markdown heading containing the alias (e.g. `#### Deaf` or
       `## Blind Consideration`) — slice until the next heading of equal or
       higher level, a horizontal rule (`---`/`***`), or end of text.
    3. Fallback: a wide window (~1200 chars) starting at the first
       alias mention. Wider than a single block so the rating-label
       pair almost always falls inside.
    """
    alias_pattern = _consideration_alias_pattern(consideration)

    # 1. Explicit `Consideration: <alias>` block.
    block_pattern = (
        rf"(?:^|\n)\s*(?:#+\s*)?consideration\s*:\s*{alias_pattern}\b"
        rf"(?P<body>[\s\S]*?)(?=(?:\n\s*(?:#+\s*)?consideration\s*:)|\Z)"
    )
    m = re.search(block_pattern, text, re.IGNORECASE)
    if m:
        return m.group("body")

    # 2. Markdown heading block. Match a heading line whose visible
    # content contains the alias, then slice until the next heading at
    # equal-or-higher level, a horizontal rule, or end of text.
    heading_pattern = re.compile(
        rf"(?:^|\n)(?P<hashes>#{{1,6}})[ \t]+"
        rf"(?P<title>[^\n]*{alias_pattern}[^\n]*)\n",
        re.IGNORECASE,
    )
    hm = heading_pattern.search(text)
    if hm:
        level = len(hm.group("hashes"))
        body_start = hm.end()
        # Terminate at next heading <= current level OR horizontal rule.
        next_heading = re.compile(
            rf"\n(?:#{{1,{level}}})[ \t]+\S|\n\s*(?:-{{3,}}|\*{{3,}})\s*\n",
        )
        nm = next_heading.search(text, body_start)
        body_end = nm.start() if nm else len(text)
        return text[hm.start():body_end]

    # 3. Wide fallback window.
    mention = re.search(alias_pattern, text, re.IGNORECASE)
    if not mention:
        return ""
    start = mention.start()
    end = min(len(text), mention.end() + 1200)
    return text[start:end]


def _parse_consideration_rating(text: str, consideration: str) -> int | None:
    """Find a 0–4 rating attributed to `consideration` in `text`.

    Looks for the consideration alias followed (within a short window) by a
    severity number or label. The consideration may appear inside a list bullet
    or table row. Comparison is case-insensitive on the alias.
    """
    if not consideration:
        return None
    alias_pattern = _consideration_alias_pattern(consideration)

    scoped = _consideration_scoped_text(text, consideration)
    if scoped:
        rating = _parse_overall_rating(scoped)
        if rating is not None:
            return rating

    # Fallback: consideration mention near an inline severity expression.
    candidates = (
        rf"{alias_pattern}[\s\S]{{0,240}}?\b([0-4])\s*[—–\-:]\s*"
        rf"(?:{'|'.join(_SEVERITY_LABELS)})",
        rf"{alias_pattern}[\s\S]{{0,240}}?\bseverity\b\s*[:=]?\s*([0-4])\b",
        rf"{alias_pattern}[\s\S]{{0,240}}?\brate(?:d|s)?\s+(?:as\s+)?([0-4])\b",
    )
    for pat in candidates:
        m = re.search(pat, text, re.IGNORECASE)
        if m:
            return int(m.group(1))
    return None


@scorer(metrics=[accuracy(), stderr(), mean()])
def severity_label_consistency_scorer(*, require_label: bool):
    """Deterministically check rating-label consistency for Layer 2.

    If a label is present, it must match the extracted numeric rating per
    `heuristics/severity.md`.
    """

    async def score(state: TaskState, target: Target) -> Score:
        answer = state.output.completion or ""
        rating = _parse_overall_rating(answer)
        pairs = _extract_rating_label_pairs(answer)

        label: str | None = None
        if rating is not None and pairs:
            for pair_rating, pair_label in pairs:
                if pair_rating == rating:
                    label = pair_label
                    break
        if label is None and pairs:
            # Fallback to the first explicit pair when overall rating
            # extraction and pair ordering differ.
            _, label = pairs[0]
            if rating is None:
                rating = pairs[0][0]
        if label is None:
            label = _extract_first_label(answer)

        if rating is None:
            passed = False
            explanation = "No numeric severity rating (0-4) found."
        elif label is None:
            passed = not require_label
            explanation = (
                "No severity label found to validate."
                if require_label
                else "No severity label found; numeric-only answer accepted."
            )
        else:
            passed = _label_matches_rating(rating, label)
            expected = _severity_label_for_rating(rating)
            explanation = (
                f"rating={rating} label={label} expected_label={expected} "
                f"passed={passed}"
            )

        return Score(
            value=1.0 if passed else 0.0,
            answer=answer,
            explanation=explanation,
            metadata={
                "rating": rating,
                "label": label,
                "require_label": require_label,
            },
        )

    return score


@scorer(metrics=[accuracy(), stderr(), mean()])
def severity_per_consideration_label_consistency_scorer(*, require_label: bool):
    """Deterministically check per-consideration rating-label consistency.

    In consideration-variance prompts, this scorer validates that each
    consideration's numeric severity and label agree with the severity scale.
    """

    async def score(state: TaskState, target: Target) -> Score:
        meta = state.metadata or {}
        expectations: dict[str, Any] = meta.get("expected_severities") or {}
        if not expectations:
            raise ValueError(
                "severity_per_consideration_label_consistency_scorer requires "
                "`expected_severities` in Sample.metadata"
            )
        answer = state.output.completion or ""
        per_consideration: dict[str, dict[str, Any]] = {}
        all_pass = True

        for consideration in expectations:
            scoped = _consideration_scoped_text(answer, consideration)
            rating = _parse_consideration_rating(answer, consideration)
            pairs = _extract_rating_label_pairs(scoped)

            label: str | None = None
            if rating is not None and pairs:
                for pair_rating, pair_label in pairs:
                    if pair_rating == rating:
                        label = pair_label
                        break
            if label is None and pairs:
                label = pairs[0][1]
                if rating is None:
                    rating = pairs[0][0]
            if label is None:
                label = _extract_first_label(scoped)

            if rating is None:
                ok = False
                reason = "No numeric severity rating found for consideration."
            elif label is None:
                ok = not require_label
                reason = (
                    "No severity label found for consideration."
                    if require_label
                    else "No label found; numeric-only accepted."
                )
            else:
                ok = _label_matches_rating(rating, label)
                expected_label = _severity_label_for_rating(rating)
                reason = (
                    f"rating={rating} label={label} "
                    f"expected_label={expected_label}"
                )

            if not ok:
                all_pass = False
            per_consideration[consideration] = {
                "rating": rating,
                "label": label,
                "passed": ok,
                "reason": reason,
            }

        explanation_lines = [f"all_passed={all_pass}"]
        for consideration, info in per_consideration.items():
            explanation_lines.append(
                f"- {consideration}: rating={info['rating']} label={info['label']} "
                f"passed={info['passed']} reason={info['reason']}"
            )

        return Score(
            value=1.0 if all_pass else 0.0,
            answer=answer,
            explanation="\n".join(explanation_lines),
            metadata={
                "per_consideration": per_consideration,
                "require_label": require_label,
            },
        )

    return score


def _rating_in_expected(
    rating: int,
    *,
    expected: int | None,
    expected_range: list[int] | tuple[int, int] | None,
) -> bool:
    if expected is not None:
        return rating == expected
    if expected_range is not None:
        lo, hi = expected_range
        return lo <= rating <= hi
    # No expectation provided — treat as pass to avoid silent regressions
    # in scenario authoring.
    return True


# --- Layer 2: deterministic numeric scorer -------------------------------


@scorer(metrics=[accuracy(), stderr(), mean()])
def severity_numeric_scorer():
    """Parse a single overall 0–4 rating from the answer and compare to
    `expected_severity` / `expected_severity_range` in `Sample.metadata`.
    """

    async def score(state: TaskState, target: Target) -> Score:
        meta = state.metadata or {}
        expected = meta.get("expected_severity")
        expected_range = meta.get("expected_severity_range")
        answer = state.output.completion or ""
        rating = _parse_overall_rating(answer)
        if rating is None:
            return Score(
                value=0.0,
                answer=answer,
                explanation="No severity rating (0–4) found in answer.",
                metadata={
                    "rating": None,
                    "expected_severity": expected,
                    "expected_severity_range": expected_range,
                },
            )
        passed = _rating_in_expected(
            rating,
            expected=expected,
            expected_range=expected_range,
        )
        return Score(
            value=1.0 if passed else 0.0,
            answer=answer,
            explanation=(
                f"rating={rating} expected={expected} "
                f"range={expected_range} passed={passed}"
            ),
            metadata={
                "rating": rating,
                "expected_severity": expected,
                "expected_severity_range": expected_range,
            },
        )

    return score


# --- Layer 2: scenarios --------------------------------------------------

# Scenarios are framed as `Context: …` (not `Consideration: …`) because consideration
# is part of the scenario description, not a swept variable in this layer.
SCENARIOS: list[dict[str, Any]] = [
    {
        "label": "screen_reader_unlabelled_primary_action",
        "expected_severity": 0,
        "input": (
            "Context: blind screen reader user (NVDA + Chrome).\n"
            "Issue: The 'Submit order' primary action in the checkout "
            "flow is an icon-only button with no accessible name. The "
            "screen reader announces only 'button'. There is no other "
            "way to complete checkout.\n\n"
            "Assign a severity (0–4) using the severity scale in your "
            "reference. Justify using the frequency, impact, persistence, "
            "and learnability dimensions."
        ),
    },
    {
        "label": "magnifier_focus_offscreen_every_form",
        "expected_severity": 1,
        "input": (
            "Context: low-vision screen magnifier user (ZoomText at 4x).\n"
            "Issue: After validation errors on long forms, focus is moved "
            "to a global error summary at the top of the page, but the "
            "magnified viewport stays where it was. The user must pan "
            "back to the top to find focus on every error. This happens "
            "on every form in the product.\n\n"
            "Assign a severity (0–4) and justify using the four "
            "dimensions."
        ),
    },
    {
        "label": "color_only_status_with_text_redundancy",
        "expected_severity_range": [2, 3],
        "input": (
            "Context: color-blind user (deuteranopia).\n"
            "Issue: A status column in a data table uses red and green "
            "dot icons to indicate failure / success. Each row also "
            "includes a textual status word ('Failed' / 'Succeeded') "
            "next to the dot. The dot is the only visual scan affordance.\n\n"
            "Assign a severity (0–4) and justify using the four "
            "dimensions, including any mitigation present."
        ),
    },
    {
        "label": "voice_control_no_visible_label_with_search_mitigation",
        "expected_severity_range": [1, 2],
        "input": (
            "Context: voice access user (Voice Access on Windows).\n"
            "Issue: The application sidebar contains 30+ navigation "
            "items rendered as icons with tooltips on hover but no "
            "visible text labels. A 'Search command' palette opens with "
            "a globally documented voice phrase and lets the user jump "
            "to any sidebar destination by name. The palette is not "
            "discoverable without reading documentation.\n\n"
            "Assign a severity (0–4) and justify using the four "
            "dimensions, accounting for the mitigation."
        ),
    },
    {
        "label": "audio_alternatives_decorative_audio_chime",
        "expected_severity": 4,
        "input": (
            "Context: deaf user.\n"
            "Issue: A subtle audio chime plays when a non-essential "
            "background sync completes. There is no visual indicator, "
            "but the sync result is also surfaced in a status bar that "
            "all users can see, and the user does not need to know about "
            "the sync to do anything.\n\n"
            "Assign a severity (0–4) and justify using the four "
            "dimensions."
        ),
    },
]


def _samples() -> list[Sample]:
    items = SCENARIOS
    if _providers.is_quick_mode():
        items = items[:1]
    return [
        Sample(
            input=s["input"],
            metadata={
                "label": s["label"],
                "expected_severity": s.get("expected_severity"),
                "expected_severity_range": s.get("expected_severity_range"),
            },
        )
        for s in items
    ]


_SEVERITY_RUBRIC: list[dict] = [
    {
        "id": "uses_all_four_dimensions",
        "description": (
            "Justification explicitly addresses all four "
            "dimensions: frequency, impact, persistence, AND "
            "learnability."
        ),
        "weight": 1.5,
    },
    {
        "id": "justification_grounded",
        "description": (
            "Justifications cite concrete details from the "
            "scenario for each dimension rather than generic "
            "descriptions (e.g. exact frequency phrasing like "
            "'on every form submission' rather than 'often'; "
            "a specific impact constraint like 'screen reader "
            "announces only \"button\"' rather than 'blocked'; "
            "or a named mitigation element rather than 'a "
            "workaround is available')."
        ),
        "weight": 1.25,
    },
    {
        "id": "mitigation_handled",
        "description": (
            "When the scenario describes a mitigation "
            "(e.g. a redundant text label alongside a colour "
            "indicator, or an alternative navigation path "
            "confirmed in the scenario), the answer applies "
            "the severity scale's mitigation-aware guidance "
            "— discoverable mitigations lower severity; "
            "hard-to-discover mitigations are noted but do "
            "not lower severity. For scenarios without a "
            "mitigation, this criterion is satisfied if the "
            "answer correctly notes that no mitigation is "
            "present."
        ),
        "weight": 1.0,
    },
]


@task
def severity_scale_assignment() -> Task:
    system = f"# Severity reference\n\n{SEVERITY}"
    return Task(
        name="severity_scale_assignment",
        dataset=_samples(),
        solver=[
            system_message(system),
            generate(**_providers.generation_config()),
        ],
        # Two scorers: deterministic numeric correctness, and a separate
        # rubric for justification quality. A regression in either is
        # visible without blurring the signal.
        scorer=[
            severity_numeric_scorer(),
            severity_label_consistency_scorer(require_label=False),
            rubric_scorer(_SEVERITY_RUBRIC),
        ],
    )


# --- Layer 3: consideration-aware severity variance ----------------------------


# Each scenario describes ONE finding and lists the considerations to rate.
# `expected_severities` keys must match the consideration aliases in the
# prompt so the deterministic scorer can extract per-consideration ratings.
VARIANCE_SCENARIOS: list[dict[str, Any]] = [
    {
        "label": "focus_lost_after_action",
        "input": (
            "Focus lost after an action.\n\n"
            "Considerations to rate:\n"
            "- keyboard-only\n"
            "- low-vision\n"
            "- color-blind"
        ),
        "expected_severities": {
            "keyboard-interaction": 0,
            "visual-adaptation": 1,
            "alternatives-to-colour-cues": 4,
        },
    },
    {
        "label": "auto_playing_audio_no_controls",
        "input": (
            "Auto-playing audio without controls (no pause/stop or volume adjustment).\n\n"
            "Considerations to rate:\n"
            "- blind\n"
            "- deaf\n"
            "- voice-access"
        ),
        "expected_severities": {
            "nonvisual-access": 0,
            "audio-alternatives": 4,
            "voice-control": [1, 2],
        },
    },
    {
        "label": "form_labels_missing",
        "input": (
            "Form labels are missing (inputs only have placeholder text).\n\n"
            "Considerations to rate:\n"
            "- blind\n"
            "- low-vision\n"
            "- color-blind"
        ),
        "expected_severities": {
            "nonvisual-access": [0, 1],
            "visual-adaptation": [1, 2],
            "alternatives-to-colour-cues": 4,
        },
    },
]


def _variance_samples() -> list[Sample]:
    items = VARIANCE_SCENARIOS
    if _providers.is_quick_mode():
        items = items[:1]
    mode = _expectation_mode()
    return [
        Sample(
            input=s["input"],
            metadata={
                "label": s["label"],
                "expected_severities": _expectations_for_mode(
                    s["expected_severities"]
                ),
                "expected_severities_raw": s["expected_severities"],
                "expectation_mode": mode,
            },
        )
        for s in items
    ]


@scorer(metrics=[accuracy(), stderr(), mean()])
def severity_per_consideration_scorer():
    """Parse one rating per consideration named in
    `metadata['expected_severities']` and require every per-consideration
    rating to land within its expected value or range.
    """

    async def score(state: TaskState, target: Target) -> Score:
        meta = state.metadata or {}
        expectations: dict[str, Any] = meta.get("expected_severities") or {}
        if not expectations:
            raise ValueError(
                "severity_per_consideration_scorer requires "
                "`expected_severities` in Sample.metadata"
            )
        answer = state.output.completion or ""
        per_consideration: dict[str, dict[str, Any]] = {}
        all_pass = True
        for consideration, expected_value in expectations.items():
            rating = _parse_consideration_rating(answer, consideration)
            if isinstance(expected_value, (list, tuple)):
                expected = None
                expected_range = list(expected_value)
            else:
                expected = int(expected_value)
                expected_range = None
            if rating is None:
                ok = False
            else:
                ok = _rating_in_expected(
                    rating,
                    expected=expected,
                    expected_range=expected_range,
                )
            if not ok:
                all_pass = False
            per_consideration[consideration] = {
                "rating": rating,
                "expected": expected,
                "expected_range": expected_range,
                "passed": ok,
            }
        explanation_lines = [
            f"all_passed={all_pass}",
        ]
        for consideration, info in per_consideration.items():
            explanation_lines.append(
                f"- {consideration}: rating={info['rating']} "
                f"expected={info['expected']} "
                f"range={info['expected_range']} "
                f"passed={info['passed']}"
            )
        return Score(
            value=1.0 if all_pass else 0.0,
            answer=answer,
            explanation="\n".join(explanation_lines),
            metadata={"per_consideration": per_consideration},
        )

    return score


_VARIANCE_RUBRIC: list[dict] = [
    {
        "id": "matches_expected_numeric_per_consideration",
        "description": (
            "Numeric severities for each requested consideration match the "
            "EXPECTED SEVERITIES reference block (exact values or "
            "within allowed ranges). Any out-of-range consideration fails "
            "this criterion."
        ),
        "weight": 1.0,
    },
    {
        "id": "explains_per_consideration_difference",
        "description": (
            "Each consideration's severity is grounded in that consideration's "
            "specific assistive technology or interaction strategy — "
            "not stated as a generic shared impact. Where ratings "
            "differ across considerations, the answer explains why. Where "
            "ratings converge, the answer correctly attributes the "
            "similar severity to each consideration's own situation rather "
            "than asserting an undifferentiated shared barrier. A "
            "bare list of ratings without per-consideration reasoning fails "
            "this criterion."
        ),
        "weight": 2.0,
    },
    {
        "id": "justification_grounded_in_scenario",
        "description": (
            "Each consideration's justification cites concrete details "
            "from the scenario rather than generic AT descriptions "
            "(e.g. 'focus moves off-screen without auto-scroll' for "
            "a keyboard-only impact claim, 'static text is "
            "screen-reader accessible so content is not lost' for a "
            "blind-consideration persistence argument, or 'arrow key "
            "navigation available between buttons' for an "
            "AT-specific workaround claim) rather than 'the user "
            "is blocked' or 'the user relies on their AT'."
        ),
        "weight": 1.25,
    },
    {
        "id": "uses_all_four_dimensions",
        "description": (
            "Each per-consideration justification touches the four severity "
            "dimensions (frequency, impact, persistence, learnability) "
            "either explicitly or in clear paraphrase."
        ),
        "weight": 1.5,
    },
    {
        "id": "mitigation_handled_per_consideration",
        "description": (
            "When the scenario contains a mitigation (e.g. equivalent "
            "static text alongside an inaccessible video, visible "
            "labels alongside icons), the answer applies the severity "
            "scale's mitigation-aware rules per consideration — discoverable "
            "mitigations lower severity for the considerations they actually "
            "help, not blanket across all considerations. For scenarios "
            "without a mitigation, this criterion is satisfied if the "
            "answer correctly notes that no mitigation applies."
        ),
        "weight": 1.0,
    },
]


def _format_expected_severities(expectations: dict[str, Any]) -> str:
    lines: list[str] = []
    for consideration, expected in expectations.items():
        if isinstance(expected, (list, tuple)) and len(expected) == 2:
            lines.append(f"- {consideration}: range {int(expected[0])}-{int(expected[1])}")
        else:
            lines.append(f"- {consideration}: exact {int(expected)}")
    return "\n".join(lines)


def _build_variance_judge_prompt(
    answer: str,
    criteria: list[Criterion],
    *,
    expectations: dict[str, Any],
) -> str:
    criteria_block = "\n".join(
        f"- id: {c.id}\n  description: {c.description}" for c in criteria
    )
    expected_block = _format_expected_severities(expectations)
    mode_note = (
        "Note: expectations are strict authored values/ranges."
        if _expectation_mode() == "strict"
        else "Note: expectations are benchmark-mode relaxed by +/-1 severity step."
    )
    return (
        "EXPECTED SEVERITIES (per consideration):\n"
        f"{expected_block}\n"
        f"{mode_note}\n\n"
        "ANSWER UNDER REVIEW (between <<< and >>>):\n<<<\n"
        f"{answer}\n>>>\n\n"
        "RUBRIC CRITERIA:\n"
        f"{criteria_block}\n\n"
        "For `matches_expected_numeric_per_consideration`, compare the answer's "
        "numeric severity per consideration against EXPECTED SEVERITIES exactly. "
        "Do not infer missing consideration ratings.\n\n"
        "Return only the JSON object specified in your instructions."
    )


@scorer(metrics=[accuracy(), stderr(), mean()])
def severity_variance_rubric_scorer(
    criteria: list[dict | Criterion],
    *,
    judge: str | None = None,
    threshold: float | None = None,
):
    """LLM-as-judge rubric scorer for consideration-variance severity tasks.

    Unlike the generic rubric scorer, this includes per-sample expected
    consideration severities in the judge prompt so numeric alignment can be
    judged explicitly as part of the rubric.
    """
    parsed = as_criteria(criteria)
    judge_id = judge or _providers.judge_model()
    pass_threshold = (
        threshold if threshold is not None else _providers.rubric_threshold()
    )

    async def score(state: TaskState, target: Target) -> Score:
        answer = state.output.completion or ""
        expectations = (state.metadata or {}).get("expected_severities") or {}
        if not expectations:
            raise ValueError(
                "severity_variance_rubric_scorer requires "
                "`expected_severities` in Sample.metadata"
            )

        judge_obj = get_model(judge_id)
        result = await judge_obj.generate(
            input=[
                ChatMessageSystem(content=_JUDGE_INSTRUCTIONS),
                ChatMessageUser(
                    content=_build_variance_judge_prompt(
                        answer,
                        parsed,
                        expectations=expectations,
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
            },
        )

    return score


_VARIANCE_OUTPUT_DIRECTIVE = (
    "# Output format\n\n"
    "For every consideration listed in the prompt, emit EXACTLY ONE integer "
    "severity rating from 0 to 4 using the scale in the severity "
    "reference. Pair the integer with its label (e.g. `Severity: 4 — "
    "Trivial`).\n\n"
    "Do NOT use ranges (e.g. `3-4`, `3 to 4`), `N/A`, `Not applicable`, "
    "or any non-numeric stand-in. If a consideration is not meaningfully "
    "impacted by the finding, rate it `4 — Trivial` and explain why "
    "the impact is negligible for that consideration. Hedging or ambiguity "
    "in the rating itself is treated as an incorrect answer.\n"
)


@task
def severity_consideration_variance() -> Task:
    system = (
        f"# Severity reference\n\n{SEVERITY}\n\n"
        f"{_VARIANCE_OUTPUT_DIRECTIVE}"
    )
    return Task(
        name="severity_consideration_variance",
        dataset=_variance_samples(),
        solver=[
            system_message(system),
            generate(**_providers.generation_config()),
        ],
        # Deterministic scorer remains the source of truth for numeric
        # per-consideration severity correctness; rubric scores explanation quality
        # and (now) expected numeric alignment in the judge path.
        scorer=[
            severity_per_consideration_scorer(),
            severity_per_consideration_label_consistency_scorer(require_label=True),
            severity_variance_rubric_scorer(_VARIANCE_RUBRIC),
        ],
    )
