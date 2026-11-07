"""Shared scorers for Accessibility Considerations Toolkit (Act) eval tasks.

Provides:

- `rubric_scorer(criteria, judge=..., threshold=...)` — LLM-as-judge
    rubric scoring. Each criterion keeps a coarse verdict of YES,
    PARTIAL, or NO and may also carry a stricter fractional accuracy in
    [0, 1]. The weighted mean across criteria is the raw score, and the
    sample passes if raw >= threshold.

- Deterministic scorers are implemented in `_deterministic_scorer.py` and
    re-exported here for compatibility.

Custom scorers compose: a task can chain `must_mention` (cheap
gate) with `rubric_scorer` (semantic) to fail-fast on obviously
broken outputs.
"""

from __future__ import annotations

import json
import re
from dataclasses import dataclass
from typing import Any, Iterable

from inspect_ai.model import ChatMessageSystem, ChatMessageUser, get_model
from inspect_ai.scorer import (
    Score,
    Target,
    accuracy,
    mean,
    scorer,
    stderr,
)
from inspect_ai.solver import TaskState

from tests.evals import _providers
from tests.evals._deterministic_scorer import (
    AnswerKeyItem,
    ForbiddenAnswerKeyItem,
    answer_key_scorer,
    must_mention,
    must_not_mention,
    parse_answer_key,
    score_answer_key,
)


@dataclass(frozen=True)
class Criterion:
    id: str
    description: str
    weight: float = 1.0


def as_criteria(spec: Iterable[dict | Criterion]) -> list[Criterion]:
    out: list[Criterion] = []
    for item in spec:
        if isinstance(item, Criterion):
            out.append(item)
        else:
            out.append(
                Criterion(
                    id=item["id"],
                    description=item["description"],
                    weight=float(item.get("weight", 1.0)),
                )
            )
    return out


_JUDGE_INSTRUCTIONS = """You are an evaluator grading whether an answer meets each criterion in a rubric.

For each criterion, decide:
- "YES" — the answer clearly and substantively meets the criterion.
- "PARTIAL" — the answer addresses the criterion but is incomplete, vague, or partially incorrect.
- "NO" — the answer does not meet the criterion at all.

Also assign an "accuracy" score in the range 0.0 to 1.0 for each criterion.
- 1.0 means the criterion is fully satisfied.
- 0.0 means the criterion is not satisfied at all.
- Intermediate values capture partial fulfillment more precisely (for example 0.58).

Be strict but fair. Do not credit content that the answer merely implies; the answer must demonstrate the criterion. Do not penalise extra correct content beyond what the criterion asks.

Output your judgement as a JSON object with this exact shape, and nothing else:

{
  "judgements": [
        {
            "id": "<criterion id>",
            "verdict": "YES|PARTIAL|NO",
            "accuracy": <float from 0.0 to 1.0>,
            "reason": "<one sentence>"
        }
  ]
}
"""


def _build_judge_prompt(answer: str, criteria: list[Criterion]) -> str:
    criteria_block = "\n".join(
        f"- id: {c.id}\n  description: {c.description}" for c in criteria
    )
    return (
        "ANSWER UNDER REVIEW (between <<< and >>>):\n<<<\n"
        f"{answer}\n>>>\n\n"
        "RUBRIC CRITERIA:\n"
        f"{criteria_block}\n\n"
        "Return only the JSON object specified in your instructions."
    )


def _parse_judge_output(raw: str) -> dict[str, dict]:
    """Extract per-criterion verdicts from judge output. Tolerant of
    code fences and surrounding prose. Returns {criterion_id: judgement}."""
    cleaned = raw.strip()
    cleaned = re.sub(r"^```(?:json)?\s*|\s*```$", "", cleaned, flags=re.MULTILINE)
    # Find the first JSON object in the text
    match = re.search(r"\{.*\}", cleaned, re.DOTALL)
    if not match:
        return {}
    try:
        data = json.loads(match.group(0))
    except json.JSONDecodeError:
        return {}
    judgements = data.get("judgements", [])
    return {j["id"]: j for j in judgements if isinstance(j, dict) and "id" in j}


_VERDICT_VALUES = {"YES": 1.0, "PARTIAL": 0.5, "NO": 0.0}


def _coerce_accuracy(raw_accuracy: Any, verdict: str) -> float:
    """Parse a judge-supplied fractional accuracy, falling back to the coarse
    verdict value if the field is missing or invalid.

    Accepts either a 0..1 float or a 0..100 percentage for robustness.
    """
    if raw_accuracy is None:
        return _VERDICT_VALUES.get(verdict, 0.0)

    try:
        accuracy = float(raw_accuracy)
    except (TypeError, ValueError):
        return _VERDICT_VALUES.get(verdict, 0.0)

    if 0.0 <= accuracy <= 1.0:
        return accuracy
    if 1.0 < accuracy <= 100.0:
        return accuracy / 100.0
    return _VERDICT_VALUES.get(verdict, 0.0)


def _score_from_judgements(
    criteria: list[Criterion], judgements: dict[str, dict]
) -> tuple[float, list[dict]]:
    total_weight = sum(c.weight for c in criteria) or 1.0
    rolled = 0.0
    breakdown: list[dict] = []
    for c in criteria:
        j = judgements.get(c.id, {})
        verdict = str(j.get("verdict", "")).upper()
        verdict_value = _VERDICT_VALUES.get(verdict)
        if verdict_value is None:
            # Treat missing/garbled judgements as NO so we never silently pass.
            verdict = "MISSING"
            verdict_value = 0.0
        accuracy = _coerce_accuracy(j.get("accuracy"), verdict)
        rolled += accuracy * c.weight
        breakdown.append(
            {
                "id": c.id,
                "weight": c.weight,
                "verdict": verdict,
                "verdict_value": verdict_value,
                "accuracy": accuracy,
                "reason": j.get("reason", ""),
            }
        )
    return rolled / total_weight, breakdown


@scorer(metrics=[accuracy(), stderr(), mean()])
def rubric_scorer(
    criteria: list[dict | Criterion],
    *,
    judge: str | None = None,
    threshold: float | None = None,
):
    """LLM-as-judge rubric scorer.

    Returns Score with:
    - value: 1.0 if weighted score >= threshold else 0.0 (binary pass/fail
      so accuracy() reports pass rate).
    - answer: model's raw output.
    - explanation: per-criterion verdict/reason summary.
        - metadata.score: raw weighted accuracy in [0, 1].
    - metadata.threshold: pass threshold used.
        - metadata.criteria: per-criterion breakdown including coarse verdict
            and fractional accuracy.
    """
    parsed = as_criteria(criteria)
    judge_id = judge or _providers.judge_model()
    pass_threshold = (
        threshold if threshold is not None else _providers.rubric_threshold()
    )

    async def score(state: TaskState, target: Target) -> Score:
        answer = state.output.completion or ""
        judge_obj = get_model(judge_id)
        result = await judge_obj.generate(
            input=[
                ChatMessageSystem(content=_JUDGE_INSTRUCTIONS),
                ChatMessageUser(content=_build_judge_prompt(answer, parsed)),
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
                f"- [{b['verdict']}] {b['id']} (weight {b['weight']:.1f}, "
                f"accuracy {b['accuracy']:.2f}): "
                f"{b['reason']}"
            )
        return Score(
            value=raw_score,
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
