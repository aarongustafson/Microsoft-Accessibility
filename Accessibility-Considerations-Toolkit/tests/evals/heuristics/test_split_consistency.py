"""Consistency tests for the split heuristics layout.

These verify the contract that the new per-heuristic file layout preserves
the same logical content as the original aggregate ``heuristics.md`` did,
and that the back-compat ``load_heuristics()`` concatenator yields output
that can still be parsed by callers expecting the legacy structure.
"""

from __future__ import annotations

import re

from .._context import (
    HEURISTIC_FILES,
    HEURISTICS_DIR,
    load_heuristic,
    load_heuristic_index,
    load_heuristics,
)


def test_index_file_exists_and_lists_all_ten_heuristics() -> None:
    index = load_heuristic_index()
    for fname in HEURISTIC_FILES:
        assert fname in index, f"index.md must reference {fname}"


def test_index_contains_supplementary_concerns() -> None:
    index = load_heuristic_index()
    assert "## Supplementary Concerns" in index
    assert "Privacy" in index
    assert "Bad Prediction" in index


def test_each_heuristic_file_has_definition_and_lens() -> None:
    for n in range(1, len(HEURISTIC_FILES) + 1):
        body = load_heuristic(n)
        assert body.startswith(f"# {n}."), (
            f"Heuristic file {HEURISTIC_FILES[n - 1]} must start with '# {n}.'"
        )
        assert "**Definition**:" in body
        assert "**Accessibility Lens**:" in body


def test_per_heuristic_files_are_small_enough_for_focused_loading() -> None:
    """Each per-heuristic file should be small enough that loading a single
    heuristic into a sub-agent context is cheap. Soft cap at 4 KB per file.
    """
    for fname in HEURISTIC_FILES:
        size = (HEURISTICS_DIR / fname).stat().st_size
        assert size < 4096, f"{fname} is {size} bytes; expected < 4096"


def test_back_compat_aggregate_contains_all_heuristics() -> None:
    """The legacy ``load_heuristics()`` shim must still expose all 10
    heuristics so existing eval consumers keep working.
    """
    full = load_heuristics()
    headings = re.findall(r"^# (\d+)\.\s", full, re.MULTILINE)
    assert headings == [str(n) for n in range(1, 11)]


def test_no_aggregate_source_file() -> None:
    """The old monolithic ``heuristics.md`` must no longer exist; the split
    files are the single source of truth.
    """
    assert not (HEURISTICS_DIR / "heuristics.md").exists(), (
        "Old monolithic heuristics.md should have been removed."
    )
