"""Per-heuristic loading contract tests (deterministic, no model).

These verify the focused-loading guarantee that motivates the
heuristics split: each per-heuristic sub-agent must see only the
index plus the one heuristic it owns, never the full aggregate.

The orchestrator and inspect-ai task wiring are exercised by
``eval_pack_smoke.py``; this module covers what pytest can verify
without the inspect-ai dependency.
"""

from __future__ import annotations

import pytest

from .._context import (
    HEURISTIC_FILES,
    load_heuristic,
    load_heuristic_index,
    load_heuristics,
)
from ._loaders import (
    build_focused_system,
    focused_payload_bytes,
    heuristic_count,
)


def test_heuristic_count_matches_files() -> None:
    assert heuristic_count() == len(HEURISTIC_FILES) == 10


def test_focused_system_contains_required_sections() -> None:
    """Each focused payload must include the heuristics-index marker,
    the focused-heuristic marker, and the consideration marker.
    """
    system = build_focused_system(
        heuristic_number=3,
        consideration_alias="visual-adaptation",
    )
    assert "# Heuristics index" in system
    assert "# Heuristic 3 (focused detail)" in system
    assert "# Consideration reference" in system
    assert "**Definition**:" in system
    assert "**Accessibility Lens**:" in system


def test_focused_system_does_not_leak_other_heuristic_definitions() -> None:
    """Each focused payload includes exactly one heuristic body."""
    for n in range(1, 11):
        system = build_focused_system(
            heuristic_number=n,
            consideration_alias="visual-adaptation",
        )
        for other in range(1, 11):
            if other == n:
                continue
            other_body = load_heuristic(other)
            other_defs = [
                line for line in other_body.splitlines()
                if line.startswith("**Definition**:")
            ]
            if not other_defs:
                continue
            assert other_defs[0] not in system, (
                f"Focused payload for H{n} leaked H{other} definition."
            )


def test_focused_heuristic_section_is_smaller_than_aggregate() -> None:
    """The heuristics portion of a focused payload (index + one
    heuristic) must be smaller than the full aggregate. The consideration
    portion is identical in both focused and unfocused systems, so it
    doesn't factor into the comparison.
    """
    aggregate_heuristics = len(load_heuristics().encode("utf-8"))
    index_size = len(load_heuristic_index().encode("utf-8"))
    for n in range(1, 11):
        heuristic_size = len(load_heuristic(n).encode("utf-8"))
        focused_heuristics_size = index_size + heuristic_size
        assert focused_heuristics_size < aggregate_heuristics, (
            f"H{n} focused heuristics section ({focused_heuristics_size} B) "
            f"is not smaller than the aggregate ({aggregate_heuristics} B) - "
            f"focused loading lost its win."
        )


def test_focused_payload_bytes_is_reported() -> None:
    """``focused_payload_bytes`` returns a positive byte count that
    matches the encoded length of the system prompt."""
    for n in range(1, 11):
        size = focused_payload_bytes(
            heuristic_number=n,
            consideration_alias="visual-adaptation",
        )
        assert size > 0
        assert size == len(
            build_focused_system(
                heuristic_number=n,
                consideration_alias="visual-adaptation",
            ).encode("utf-8")
        )


def test_build_focused_system_rejects_out_of_range() -> None:
    with pytest.raises(ValueError):
        build_focused_system(heuristic_number=0, consideration_alias="visual-adaptation")
    with pytest.raises(ValueError):
        build_focused_system(heuristic_number=11, consideration_alias="visual-adaptation")


def test_consideration_content_appears_in_focused_system() -> None:
    system = build_focused_system(
        heuristic_number=1,
        consideration_alias="keyboard-interaction",
    )
    # The consideration file should contribute substantial content - a bare
    # "Consideration reference" header alone isn't enough.
    consideration_section_start = system.index("# Consideration reference")
    consideration_section = system[consideration_section_start:]
    assert len(consideration_section) > 1000, (
        "Consideration section appears truncated in focused system prompt"
    )
