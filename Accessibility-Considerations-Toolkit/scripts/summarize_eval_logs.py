from __future__ import annotations

import argparse
import importlib.util
import json
from pathlib import Path
from typing import Any

from inspect_ai.log import read_eval_log


def _load_harness_mapper() -> Any:
    helper_path = Path(__file__).resolve().parent / "build_task_harness_map.py"
    spec = importlib.util.spec_from_file_location("build_task_harness_map", helper_path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Unable to load harness mapper from {helper_path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return getattr(module, "build_task_harness_map")


build_task_harness_map = _load_harness_mapper()


PRIMARY_SCORER_PREFERENCE = (
    "rubric_scorer",
    "answer_key_scorer",
    "must_mention",
    "must_not_mention",
)


def _remove_span(stack: list[dict[str, Any]], span_id: str | None) -> None:
    if span_id is None:
        return
    for index in range(len(stack) - 1, -1, -1):
        if stack[index].get("id") == span_id:
            del stack[index:]
            return


def _event_dump(event: Any) -> dict[str, Any]:
    if hasattr(event, "model_dump"):
        dumped = event.model_dump()
        if isinstance(dumped, dict):
            return dumped
    return {}


def _sample_token_breakdown(sample: Any) -> tuple[int, int]:
    candidate_tokens = 0
    judge_tokens = 0
    span_stack: list[dict[str, Any]] = []

    for event in sample.events or []:
        dumped = _event_dump(event)
        event_name = dumped.get("event")

        if event_name == "span_begin":
            span_stack.append(
                {
                    "id": dumped.get("id"),
                    "type": dumped.get("type"),
                    "name": dumped.get("name"),
                }
            )
            continue

        if event_name == "span_end":
            _remove_span(span_stack, dumped.get("id"))
            continue

        if event_name != "model":
            continue

        usage = ((dumped.get("output") or {}).get("usage") or {})
        total_tokens = int(usage.get("total_tokens") or 0)
        active_names = {span.get("name") for span in span_stack}
        active_types = {span.get("type") for span in span_stack}

        if "rubric_scorer" in active_names or "scorer" in active_types:
            judge_tokens += total_tokens
        else:
            candidate_tokens += total_tokens

    return candidate_tokens, judge_tokens


def _primary_score_value(sample: Any) -> float | None:
    scores = sample.scores or {}
    for scorer_name in PRIMARY_SCORER_PREFERENCE:
        score = scores.get(scorer_name)
        if score is not None:
            value = getattr(score, "value", None)
            return None if value is None else float(value)
    for score in scores.values():
        value = getattr(score, "value", None)
        return None if value is None else float(value)
    return None


def summarize_log(
    log_path: Path,
    model: str,
    task_harness_map: dict[str, str],
) -> dict[str, Any]:
    log = read_eval_log(log_path)
    samples = list(log.samples or [])
    task_name = log.eval.task
    sample_scores = [_primary_score_value(sample) for sample in samples]

    candidate_totals: list[int] = []
    judge_totals: list[int] = []
    for sample in samples:
        candidate_tokens, judge_tokens = _sample_token_breakdown(sample)
        candidate_totals.append(candidate_tokens)
        judge_totals.append(judge_tokens)

    sample_count = len(samples)
    candidate_avg = (sum(candidate_totals) / sample_count) if sample_count else 0.0
    judge_avg = (sum(judge_totals) / sample_count) if sample_count else 0.0

    return {
        "model": model,
        "task": task_name,
        "harness": task_harness_map.get(task_name, "unknown"),
        "status": log.status,
        "sample_count": sample_count,
        "avg_tokens_ex_judge": round(candidate_avg, 2),
        "avg_judge_tokens": round(judge_avg, 2),
        "sample_accuracies": sample_scores,
        "log_file": str(log_path),
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", required=True)
    parser.add_argument("--task-spec", dest="task_specs", action="append", default=[])
    parser.add_argument("logs", nargs="+")
    args = parser.parse_args()

    task_harness_map = build_task_harness_map(args.task_specs)
    summaries = [
        summarize_log(Path(log_path), args.model, task_harness_map)
        for log_path in args.logs
    ]
    print(json.dumps(summaries, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
