"""Provider / model wiring for inspect-ai eval tasks.

Reads `tests/evals/config.yaml` and exposes:

- `primary_model()`, `secondary_model()`, `judge_model()` — model identifiers.
- `generation_config()` — kwargs forwarded to inspect-ai generation.
- `rubric_threshold()`, `is_quick_mode()`.

All models route through the Copilot SDK provider (``copilot/<model>``).
Authentication is handled by the ``@github/copilot`` CLI — run
``copilot login`` once before first use.

Environment overrides (all optional):

- EVAL_MODEL_PRIMARY, EVAL_MODEL_SECONDARY, EVAL_MODEL_CLAUDE, EVAL_JUDGE_MODEL
- EVAL_RUBRIC_THRESHOLD
- EVAL_QUICK=1 enables quick mode (subset parameterized samples)
"""

from __future__ import annotations

import os
from functools import lru_cache
from pathlib import Path
from typing import Any

import yaml
from dotenv import load_dotenv

CONFIG_PATH = Path(__file__).resolve().parent / "config.yaml"
REPO_ROOT = Path(__file__).resolve().parents[2]


def _load_env_files() -> None:
    """Load local .env files for eval runs.

    `override=False` preserves explicit shell env vars when present.
    """
    load_dotenv(REPO_ROOT / ".env", override=False)
    load_dotenv(Path(__file__).resolve().parent / ".env", override=False)


@lru_cache(maxsize=1)
def _config() -> dict[str, Any]:
    with CONFIG_PATH.open(encoding="utf-8") as fh:
        return yaml.safe_load(fh)


def primary_model() -> str:
    return os.environ.get("EVAL_MODEL_PRIMARY") or _config()["models"]["primary"]


def secondary_model() -> str:
    return os.environ.get("EVAL_MODEL_SECONDARY") or _config()["models"]["secondary"]


def claude_model() -> str:
    return os.environ.get("EVAL_MODEL_CLAUDE") or _config()["models"]["claude"]


def judge_model() -> str:
    return os.environ.get("EVAL_JUDGE_MODEL") or _config()["judge"]


def rubric_threshold() -> float:
    raw = os.environ.get("EVAL_RUBRIC_THRESHOLD")
    if raw is not None:
        return float(raw)
    return float(_config()["rubric"]["default_threshold"])


def is_quick_mode() -> bool:
    return os.environ.get("EVAL_QUICK", "").lower() in {"1", "true", "yes"}


def generation_config() -> dict[str, Any]:
    gen = _config().get("generation", {}) or {}
    return {k: v for k, v in gen.items() if v is not None}


# Load .env on import so eval modules can simply `from . import _providers`.
_load_env_files()
