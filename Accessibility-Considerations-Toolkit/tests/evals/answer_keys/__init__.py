"""Answer key definitions for hidden-answer-key evals.

Answer keys are stored in one JSON registry per deterministic eval module
for easier maintenance. Each registry file contains a top-level object
whose keys are section slugs such as ``at_categories`` or
``shared_strategies``.

Example structure:

    {
      "threshold": 0.8,
      "items": [
        {
          "id": "item_1",
          "matches": ["expected phrase 1", "alias 1"]
        },
        {
          "id": "item_2",
          "matches": ["expected phrase 2"],
          "weight": 2.0
        }
      ]
    }

Use ``load_answer_key()`` or ``load_answer_key_from_file()`` to load keys in
eval tasks. The latter is kept as a compatibility alias for existing task
modules that still pass legacy names.
"""

from __future__ import annotations

import json
from functools import lru_cache
from pathlib import Path
from typing import Any


_ANSWER_KEY_DIR = Path(__file__).resolve().parent


@lru_cache(maxsize=None)
def _load_registry_file(filename: str) -> dict[str, Any]:
  file_path = _ANSWER_KEY_DIR / filename
  if not file_path.exists():
    raise FileNotFoundError(f"Answer key registry not found: {file_path}")

  with file_path.open(encoding="utf-8-sig") as fh:
    registry = json.load(fh)

  if not isinstance(registry, dict):
    raise ValueError(f"Answer key registry must be a JSON object: {file_path}")
  return registry


def _normalize_answer_key_name(name: str) -> str:
  normalized = name.strip()
  if normalized.endswith(".json"):
    normalized = normalized[:-5]
  return normalized


def _split_answer_key_name(name: str) -> tuple[str, str]:
  normalized = _normalize_answer_key_name(name)
  if "." in normalized:
    registry_name, key = normalized.split(".", 1)
    return f"{registry_name}.json", key

  candidates = sorted(_ANSWER_KEY_DIR.glob("*.json"), key=lambda path: len(path.stem), reverse=True)
  for candidate in candidates:
    registry_name = candidate.stem
    prefix = f"{registry_name}_"
    if normalized.startswith(prefix):
      return candidate.name, normalized[len(prefix):]

  raise KeyError(
    "Answer key name must be '<registry>.<key>' or a legacy "
    "'<registry>_<key>.json' filename"
  )


def load_answer_key(name: str) -> dict[str, Any]:
  """Load an answer key from a per-module registry.

  Args:
    name: Registry reference such as ``visual_adaptation.at_categories``. For
      compatibility, legacy filenames like
      ``visual_adaptation_at_categories.json`` are also accepted.

  Returns:
    The parsed answer key dict, ready for Sample.metadata["answer_key"].
  """
  registry_filename, key = _split_answer_key_name(name)
  registry = _load_registry_file(registry_filename)
  if key not in registry:
    raise KeyError(
      f"Answer key not found in registry {registry_filename}: {key}"
    )

  answer_key = registry[key]
  if not isinstance(answer_key, dict):
    raise ValueError(
      f"Answer key entry must be an object: {registry_filename}:{key}"
    )
  return answer_key


def load_answer_key_from_file(filename: str) -> dict[str, Any]:
  """Compatibility wrapper for loading an answer key by legacy filename.

    Args:
    filename: Legacy filename (e.g., "visual_adaptation_at_categories.json")
      or registry key.

    Returns:
        The parsed answer key dict, ready for Sample.metadata["answer_key"].
    """
  return load_answer_key(filename)
