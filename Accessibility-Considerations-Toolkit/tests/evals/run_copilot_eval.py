"""Unified runner for eval tasks via the Copilot SDK provider.

This script programmatically calls inspect-ai and registers the
Copilot provider so that ``copilot/<model>`` identifiers resolve
through the local ``@github/copilot`` CLI.

Usage:

    python tests/evals/run_copilot_eval.py [--consideration_context_mode MODE] [--heuristic_context_mode MODE] [--severity_expectation_mode MODE] [--samples_per_test N] [--judge_model MODEL] [--quick] [model] [task_spec ...]

Examples:

    python -m tests.evals
    python -m tests.evals copilot/gpt-5-mini deterministic/visual_adaptation.py
    python -m tests.evals --consideration_context_mode all copilot/gpt-5-mini considerations/eval_visual_adaptation.py@at_recall
    python -m tests.evals --consideration_context_mode medium copilot/gpt-5-mini considerations/eval_visual_adaptation.py@at_recall
    python -m tests.evals copilot/gpt-5-mini all-deterministic
    python -m tests.evals copilot/gpt-5-mini all-negatives
    python -m tests.evals copilot/gpt-5-mini all-other
    python -m tests.evals copilot/gpt-5-mini all-heuristics
    python -m tests.evals copilot/gpt-5-mini all-methodology
    python -m tests.evals copilot/gpt-5-mini all-considerations
    python -m tests.evals copilot/gpt-5-mini heuristics/eval_heuristics_lens.py
    python -m tests.evals --quick copilot/gpt-5-mini heuristics/eval_heuristics_lens.py
    python -m tests.evals --heuristic_context_mode slim copilot/gpt-5-mini heuristics/eval_heuristics_lens.py
    python -m tests.evals --heuristic_context_mode full copilot/gpt-5-mini heuristics/eval_heuristics_lens.py
    python -m tests.evals --quick --heuristic_context_mode full copilot/gpt-5-mini heuristics/eval_heuristics_lens.py
    python -m tests.evals copilot/gpt-5-mini heuristics/eval_severity_scale.py
    python -m tests.evals copilot/gpt-5-mini heuristics/eval_severity_scale.py@severity_scale_assignment
    python -m tests.evals copilot/gpt-5-mini heuristics/eval_severity_scale.py@severity_consideration_variance
    python -m tests.evals --severity_expectation_mode strict copilot/gpt-5-mini heuristics/eval_severity_scale.py
    python -m tests.evals --severity_expectation_mode benchmark copilot/gpt-5-mini heuristics/eval_severity_scale.py
    python -m tests.evals copilot/claude-sonnet-4.5 deterministic/visual_adaptation.py

    python tests/evals/run_copilot_eval.py
    python tests/evals/run_copilot_eval.py copilot/gpt-5-mini smoke:smoke
    python tests/evals/run_copilot_eval.py --consideration_context_mode all copilot/gpt-5-mini considerations/eval_visual_adaptation.py@at_recall
    python tests/evals/run_copilot_eval.py --consideration_context_mode medium copilot/gpt-5-mini considerations/eval_visual_adaptation.py@at_recall
    python tests/evals/run_copilot_eval.py copilot/gpt-5-mini considerations/eval_visual_adaptation.py heuristics/eval_heuristic_1.py
    python tests/evals/run_copilot_eval.py copilot/gpt-5-mini all-heuristics
    python tests/evals/run_copilot_eval.py copilot/gpt-5-mini all-methodology
    python tests/evals/run_copilot_eval.py copilot/gpt-5-mini heuristics/eval_heuristics_lens.py
    python tests/evals/run_copilot_eval.py --quick copilot/gpt-5-mini heuristics/eval_heuristics_lens.py
    python tests/evals/run_copilot_eval.py --heuristic_context_mode slim copilot/gpt-5-mini heuristics/eval_heuristics_lens.py
    python tests/evals/run_copilot_eval.py --heuristic_context_mode full copilot/gpt-5-mini heuristics/eval_heuristics_lens.py
    python tests/evals/run_copilot_eval.py --quick --heuristic_context_mode full copilot/gpt-5-mini heuristics/eval_heuristics_lens.py
    python tests/evals/run_copilot_eval.py --samples_per_test 3 copilot/gpt-5-mini considerations/eval_keyboard_interaction.py
    python tests/evals/run_copilot_eval.py --severity_expectation_mode strict copilot/gpt-5-mini heuristics/eval_severity_scale.py
    python tests/evals/run_copilot_eval.py --severity_expectation_mode benchmark copilot/gpt-5-mini heuristics/eval_severity_scale.py
    python tests/evals/run_copilot_eval.py copilot/gpt-5-mini all
    python tests/evals/run_copilot_eval.py copilot/claude-sonnet-4.5 smoke_copilot:smoke_copilot
    python tests/evals/run_copilot_eval.py copilot/claude-sonnet-4.5 tests/evals/considerations/eval_visual_adaptation.py@at_recall

Defaults:
- consideration_context_mode: ``single`` (use ``all`` for compact supporting considerations, ``medium`` for medium briefs)
- heuristic_context_mode: ``unset`` (runner does not override `EVAL_FULL_CONTEXT` unless this flag is provided)
- severity_expectation_mode: ``unset`` (runner does not override `EVAL_SEVERITY_EXPECTATION_MODE` unless this flag is provided)
- samples_per_test: ``EVAL_SAMPLES_PER_TEST`` or ``1``
- quick: ``false`` (runner does not override `EVAL_QUICK` unless this flag is provided)
- model: ``EVAL_MODEL_PRIMARY`` or ``copilot/gpt-5-mini``
- tasks: ``smoke.py``
"""

from __future__ import annotations

import inspect
import io
import os
import sys
from pathlib import Path

# Force UTF-8 stdout/stderr on Windows to avoid cp1252 encoding errors
# when printing LLM completions that contain smart quotes, em-dashes, etc.
if sys.stdout.encoding and sys.stdout.encoding.lower() != "utf-8":
    sys.stdout = io.TextIOWrapper(
        sys.stdout.buffer, encoding="utf-8", errors="replace", line_buffering=True
    )
if sys.stderr.encoding and sys.stderr.encoding.lower() != "utf-8":
    sys.stderr = io.TextIOWrapper(
        sys.stderr.buffer, encoding="utf-8", errors="replace", line_buffering=True
    )

# Ensure the repo root is on sys.path so ``tests.evals.copilot_provider``
# resolves whether this runner is invoked from the repo root or elsewhere.
_REPO_ROOT = Path(__file__).resolve().parents[2]
if str(_REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(_REPO_ROOT))

from inspect_ai import eval as inspect_eval  # noqa: E402
from inspect_ai import Task  # noqa: E402
from inspect_ai.dataset import MemoryDataset, Sample  # noqa: E402

from tests.evals import _context, _providers  # noqa: E402

# Task groups for the local runner. Add new modules to the appropriate base
# group and keep the combined group derived from those definitions.
CONSIDERATION_NON_DETERMINISTIC_TASK_SPECS = [
    "considerations/eval_visual_adaptation.py",
    "considerations/eval_nonvisual_access.py",
    "considerations/eval_alternatives_to_colour_cues.py",
    "considerations/eval_audio_alternatives.py",
    "considerations/eval_hearing_support.py",
    "considerations/eval_alternatives_to_speech_input.py",
    "considerations/eval_keyboard_interaction.py",
    "considerations/eval_voice_control.py",
    "considerations/eval_memory_attention_and_executive_function.py",
    "considerations/eval_language_and_communication.py",
    "considerations/eval_numeracy_and_numeric_information.py",
    "considerations/eval_photosensitive_seizure_prevention.py",
    "considerations/eval_pointer_interaction.py"
]

PILOT_DETERMINISTIC_TASK_SPECS = [
    "deterministic/visual_adaptation.py",
    "deterministic/nonvisual_access.py",
    "deterministic/alternatives_to_colour_cues.py",
    "deterministic/audio_alternatives.py",
    "deterministic/hearing_support.py",
    "deterministic/keyboard_interaction.py",
    "deterministic/alternatives_to_speech_input.py",
    "deterministic/voice_control.py",
]

NEGATIVE_TASK_SPECS = [
    "negative/eval_privacy_clause.py",
    "negative/eval_visual_adaptation_difficulties.py",
    "negative/eval_alternatives_to_colour_cues_difficulties.py",
    "negative/eval_audio_alternatives_difficulties.py",
    "negative/eval_alternatives_to_speech_input_difficulties.py",
    "negative/eval_hearing_support_difficulties.py",
    "negative/eval_keyboard_interaction_difficulties.py",
    "negative/eval_voice_control_difficulties.py",
]

PILOT_OTHER_TASK_SPECS = [
    "heuristics/eval_heuristic_1.py",
    "methodology/eval_confidence_gate.py",
]

ALL_HEURISTICS_TASK_SPECS = [
    "heuristics/eval_heuristics_lens.py",
    "heuristics/eval_severity_scale.py",
]

ALL_METHODOLOGY_TASK_SPECS = [
    "methodology/eval_confidence_gate.py",
    "methodology/eval_design_system_trust.py",
    "methodology/eval_consideration_coverage_priority.py",
    "methodology/eval_consideration_strategy_filter.py",
    "methodology/eval_standard_conventions.py",
    "methodology/eval_title_evidence_consistency.py",
]

PILOT_ALL_TASK_SPECS = [
    *PILOT_OTHER_TASK_SPECS,
    *NEGATIVE_TASK_SPECS,
    *PILOT_DETERMINISTIC_TASK_SPECS,
    *CONSIDERATION_NON_DETERMINISTIC_TASK_SPECS,
]

TASK_SPEC_GROUPS = {
    "all": PILOT_ALL_TASK_SPECS,
    "all-deterministic": PILOT_DETERMINISTIC_TASK_SPECS,
    "all-heuristics": ALL_HEURISTICS_TASK_SPECS,
    "all-methodology": ALL_METHODOLOGY_TASK_SPECS,
    "all-negatives": NEGATIVE_TASK_SPECS,
    "all-other": PILOT_OTHER_TASK_SPECS,
    "all-considerations": CONSIDERATION_NON_DETERMINISTIC_TASK_SPECS,
}


def _summarize_target(target: object) -> str:
    if isinstance(target, dict) and "items" in target:
        items = target.get("items")
        count = len(items) if isinstance(items, list) else "?"
        threshold = target.get("threshold", "default")
        return f"<hidden answer key: items={count} threshold={threshold}>"
    return repr(target)


def _summarize_sample(sample: object) -> str:
    metadata = getattr(sample, "metadata", None)
    if isinstance(metadata, dict) and isinstance(metadata.get("answer_key"), dict):
        return _summarize_target(metadata["answer_key"])
    return _summarize_target(getattr(sample, "target", None))


def _looks_like_model(value: str) -> bool:
    return value.startswith("openai-api/") or value.startswith("copilot/")


def _normalize_heuristic_context_mode(value: str) -> str:
    mode = value.strip().lower()
    if mode in {"slim", "default", "compact"}:
        return "slim"
    if mode in {"full", "expanded"}:
        return "full"
    raise ValueError(
        "--heuristic_context_mode must be one of: slim, full"
    )


def _normalize_severity_expectation_mode(value: str) -> str:
    mode = value.strip().lower()
    if mode in {"strict", "benchmark"}:
        return mode
    raise ValueError(
        "--severity_expectation_mode must be one of: strict, benchmark"
    )


def _parse_runner_args(
    argv: list[str],
) -> tuple[str, str | None, str | None, int, str | None, bool, list[str], str]:
    consideration_context_mode = "single"
    heuristic_context_mode: str | None = None
    severity_expectation_mode: str | None = None
    samples_per_test = max(1, int(os.environ.get("EVAL_SAMPLES_PER_TEST", "1")))
    judge_model: str | None = None
    quick_mode = False
    remaining: list[str] = []
    index = 0

    while index < len(argv):
        arg = argv[index]
        if arg == "--consideration_context_mode":
            if index + 1 >= len(argv):
                raise ValueError("--consideration_context_mode requires a value")
            consideration_context_mode = argv[index + 1].strip().lower() or "single"
            index += 2
            continue
        if arg == "--heuristic_context_mode":
            if index + 1 >= len(argv):
                raise ValueError("--heuristic_context_mode requires a value")
            heuristic_context_mode = _normalize_heuristic_context_mode(
                argv[index + 1]
            )
            index += 2
            continue
        if arg == "--severity_expectation_mode":
            if index + 1 >= len(argv):
                raise ValueError("--severity_expectation_mode requires a value")
            severity_expectation_mode = _normalize_severity_expectation_mode(
                argv[index + 1]
            )
            index += 2
            continue
        if arg == "--samples_per_test":
            if index + 1 >= len(argv):
                raise ValueError("--samples_per_test requires a value")
            raw_value = argv[index + 1].strip()
            if not raw_value:
                raise ValueError("--samples_per_test requires a positive integer")
            try:
                parsed_value = int(raw_value)
            except ValueError as exc:
                raise ValueError("--samples_per_test must be a positive integer") from exc
            if parsed_value < 1:
                raise ValueError("--samples_per_test must be >= 1")
            samples_per_test = parsed_value
            index += 2
            continue
        if arg == "--judge_model":
            if index + 1 >= len(argv):
                raise ValueError("--judge_model requires a value")
            judge_model = argv[index + 1].strip() or None
            if judge_model is None:
                raise ValueError("--judge_model requires a non-empty value")
            index += 2
            continue
        if arg == "--quick":
            quick_mode = True
            index += 1
            continue
        remaining.append(arg)
        index += 1

    model = _providers.primary_model()
    task_specs: list[str] = ["smoke.py"]

    if remaining:
        if _looks_like_model(remaining[0]):
            model = remaining[0]
            task_specs = remaining[1:] or task_specs
        else:
            task_specs = remaining

    return (
        consideration_context_mode,
        heuristic_context_mode,
        severity_expectation_mode,
        samples_per_test,
        judge_model,
        quick_mode,
        task_specs,
        model,
    )


def _expanded_samples_for_task(task: Task, samples_per_test: int) -> MemoryDataset | None:
    if samples_per_test <= 1:
        return None

    source_dataset = task.dataset
    source_samples = list(source_dataset)
    expanded: list[Sample] = []

    for source_index, source_sample in enumerate(source_samples, start=1):
        for replica_index in range(samples_per_test):
            sample = source_sample.model_copy(deep=True)
            metadata = dict(sample.metadata or {})
            metadata["sample_replica_index"] = replica_index + 1
            metadata["sample_replica_count"] = samples_per_test
            sample.metadata = metadata

            replica_suffix = f"r{replica_index + 1}"
            if sample.id is None:
                sample.id = f"{task.name}-s{source_index}-{replica_suffix}"
            else:
                sample.id = f"{sample.id}-{replica_suffix}"

            expanded.append(sample)

    return MemoryDataset(
        samples=expanded,
        name=getattr(source_dataset, "name", None),
        location=getattr(source_dataset, "location", None),
        shuffled=getattr(source_dataset, "shuffled", False),
    )


def _apply_samples_per_test(tasks: list[Task], samples_per_test: int) -> None:
    if samples_per_test <= 1:
        return

    for task in tasks:
        expanded = _expanded_samples_for_task(task, samples_per_test)
        if expanded is not None:
            task.dataset = expanded


def _expand_task_specs(task_specs: list[str]) -> list[str]:
    expanded: list[str] = []
    for spec in task_specs:
        expanded.extend(TASK_SPEC_GROUPS.get(spec.strip().lower(), [spec]))
    return expanded


def _normalize_module_name(module_name: str) -> str:
    """Normalize path/module input into an importable tests.evals module."""
    module_name = module_name.strip()

    # Accept filesystem-like task specs, e.g. tests/evals/smoke.py or
    # tests\\evals\\considerations\\eval_visual_adaptation.py.
    module_name = module_name.replace("\\", "/")
    if module_name.endswith(".py"):
        module_name = module_name[:-3]
    if module_name.startswith("./"):
        module_name = module_name[2:]
    if module_name.startswith("tests/evals/"):
        module_name = module_name[len("tests/evals/") :]

    module_name = module_name.replace("/", ".")

    if module_name.startswith("tests.evals."):
        return module_name
    if module_name == "tests.evals":
        return module_name
    return f"tests.evals.{module_name}"


def _is_zero_arg_callable(fn: object) -> bool:
    """Return True when ``fn`` can be called without required args."""
    if not inspect.isfunction(fn):
        return False
    try:
        sig = inspect.signature(fn)
    except (TypeError, ValueError):
        return False

    for param in sig.parameters.values():
        if param.kind in {
            inspect.Parameter.POSITIONAL_ONLY,
            inspect.Parameter.POSITIONAL_OR_KEYWORD,
            inspect.Parameter.KEYWORD_ONLY,
        } and param.default is inspect.Parameter.empty:
            return False
    return True


def _load_tasks(spec: str) -> Task | list[Task]:
    module_name = spec
    attr = ""
    explicit_attr = False

    if "@" in spec:
        # Support inspect-style shorthand: module.py@task_name
        module_name, attr = spec.split("@", 1)
        explicit_attr = True
    elif ":" in spec:
        module_name, _, attr = spec.partition(":")
        explicit_attr = True

    module_name = _normalize_module_name(module_name)
    module = __import__(module_name, fromlist=["*"])

    if explicit_attr:
        task_factory = getattr(module, attr)
        task = task_factory()
        if not isinstance(task, Task):
            raise TypeError(f"{module_name}:{attr} did not return an inspect_ai.Task")
        return task

    tasks: list[Task] = []
    task_errors: list[str] = []
    for name, candidate in vars(module).items():
        if name.startswith("_"):
            continue
        if not _is_zero_arg_callable(candidate):
            continue
        if getattr(candidate, "__module__", "") != module.__name__:
            continue
        try:
            maybe_task = candidate()
        except Exception as exc:
            task_errors.append(f"{name}: {type(exc).__name__}: {exc}")
            continue
        if isinstance(maybe_task, Task):
            tasks.append(maybe_task)

    if not tasks:
        if task_errors:
            joined = "\n".join(f"- {err}" for err in task_errors)
            raise RuntimeError(
                f"Task discovery found callable candidates in module '{module_name}', "
                "but task construction failed:\n"
                f"{joined}"
            )
        raise RuntimeError(
            f"No inspect-ai task functions discovered in module '{module_name}'. "
            "Use module.py@task_name to select a specific task."
        )

    return tasks


def _maybe_register_copilot_provider(model: str) -> None:
    """Register local copilot provider only when needed."""
    if not model.startswith("copilot/"):
        return

    try:
        # Side-effect import runs @modelapi("copilot") registration.
        import tests.evals.copilot_provider  # noqa: F401
    except ModuleNotFoundError as exc:  # pragma: no cover - user env specific
        missing = getattr(exc, "name", "")
        if missing and "copilot" in missing:
            raise RuntimeError(
                "Copilot provider dependencies are missing. Install the "
                "eval requirements and ensure the github-copilot-sdk "
                "package is available in this environment."
            ) from exc
        raise


def main(argv: list[str]) -> int:
    (
        consideration_context_mode,
        heuristic_context_mode,
        severity_expectation_mode,
        samples_per_test,
        judge_model,
        quick_mode,
        task_specs,
        model,
    ) = _parse_runner_args(argv)
    _context.set_eval_consideration_context_mode(consideration_context_mode)

    if heuristic_context_mode is not None:
        # eval_heuristics_lens.py reads EVAL_FULL_CONTEXT; this flag provides
        # a runner-native switch while preserving env-var compatibility.
        os.environ["EVAL_FULL_CONTEXT"] = "1" if heuristic_context_mode == "full" else "0"

    if severity_expectation_mode is not None:
        # eval_severity_scale.py reads EVAL_SEVERITY_EXPECTATION_MODE.
        os.environ["EVAL_SEVERITY_EXPECTATION_MODE"] = severity_expectation_mode

    if quick_mode:
        # Many eval modules use EVAL_QUICK=1 for faster smoke-like runs.
        os.environ["EVAL_QUICK"] = "1"

    if judge_model is not None:
        os.environ["EVAL_JUDGE_MODEL"] = judge_model

    # On Windows, inspect-ai's default `{task}_{id}` log filename pattern can
    # push the realtime sample-buffer SQLite path over MAX_PATH for long task
    # names. Keep the repo default shorter unless the user has overridden it.
    os.environ.setdefault("INSPECT_EVAL_LOG_FILE_PATTERN", "{task}")

    task_specs = _expand_task_specs(task_specs)

    _maybe_register_copilot_provider(model)
    if judge_model is not None:
        _maybe_register_copilot_provider(judge_model)

    all_tasks: list[Task] = []
    for task_spec in task_specs:
        loaded = _load_tasks(task_spec)
        if isinstance(loaded, list):
            all_tasks.extend(loaded)
        else:
            all_tasks.append(loaded)

    _apply_samples_per_test(all_tasks, samples_per_test)

    logs = inspect_eval(tasks=all_tasks, model=model, display="plain")

    all_success = True
    print()
    for log in logs:
        status = log.status
        samples = log.samples or []
        all_success = all_success and status == "success"
        print(f"task: {log.eval.task}")
        print(f"status: {status}")
        print(f"samples: {len(samples)}")
        for sample in samples:
            completion = sample.output.completion if sample.output else ""
            score = None
            if sample.scores:
                first_scorer = next(iter(sample.scores.values()))
                score = first_scorer.value
            print(
                "  - "
                f"target={_summarize_sample(sample)} "
                f"completion={completion!r} score={score}"
            )
        print()

    return 0 if all_success else 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
