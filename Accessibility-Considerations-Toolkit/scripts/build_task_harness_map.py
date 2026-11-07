from __future__ import annotations

import argparse
import importlib
import inspect
import json
import sys
from pathlib import Path

from inspect_ai import Task


# Ensure tests.evals.* imports resolve when this script is invoked directly.
REPO_ROOT = Path(__file__).resolve().parents[1]
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))


def _normalize_module_name(module_name: str) -> str:
    module_name = module_name.strip().replace("\\", "/")
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


def _harness_from_task_spec(task_spec: str) -> str:
    normalized = task_spec.strip().replace("\\", "/")
    if normalized.startswith("tests/evals/"):
        normalized = normalized[len("tests/evals/") :]
    root = normalized.split("/", 1)[0].lower()
    if root == "considerations":
        return "consideration"
    if root == "deterministic":
        return "deterministic"
    if root == "negative":
        return "negative"
    if root:
        return root
    return "unknown"


def _load_task_names(task_spec: str) -> list[str]:
    module_name = task_spec
    attr = ""
    explicit_attr = False

    if "@" in task_spec:
        module_name, attr = task_spec.split("@", 1)
        explicit_attr = True
    elif ":" in task_spec:
        module_name, _, attr = task_spec.partition(":")
        explicit_attr = True

    module = importlib.import_module(_normalize_module_name(module_name))

    if explicit_attr:
        task_factory = getattr(module, attr)
        task_obj = task_factory()
        return [task_obj.name] if isinstance(task_obj, Task) else []

    names: list[str] = []
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
            raise RuntimeError(f"Unable to build eval task {module_name}.{name}") from exc
        if isinstance(maybe_task, Task):
            names.append(maybe_task.name)
    return names


def build_task_harness_map(task_specs: list[str]) -> dict[str, str]:
    mapping: dict[str, str] = {}
    for task_spec in task_specs:
        harness = _harness_from_task_spec(task_spec)
        for task_name in _load_task_names(task_spec):
            mapping.setdefault(task_name, harness)
    return mapping


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--task-spec", dest="task_specs", action="append", default=[])
    args = parser.parse_args()
    print(json.dumps(build_task_harness_map(args.task_specs), separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())