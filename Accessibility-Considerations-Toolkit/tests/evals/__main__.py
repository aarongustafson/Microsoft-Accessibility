"""Eval launcher entrypoint.

Usage:
    python -m tests.evals [--consideration_context_mode MODE] [--heuristic_context_mode MODE] [--severity_expectation_mode MODE] [--quick] [model] [task ...]

If a task is a module file/path with no @task selector,
all tasks in that module are executed.
Use all, all-deterministic, all-other, all-negatives, all-considerations,
or all-heuristics to run the built-in pilot task groups.
"""

from __future__ import annotations

import sys

from tests.evals.run_copilot_eval import main


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))