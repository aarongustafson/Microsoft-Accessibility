"""Pilot consistency check: shared propagation for low-vision consideration.

Deterministic — no LLM. Run via pytest:

    pytest tests/evals/consistency/test_shared_propagation.py

Verifies that every shared section the consideration claims to inherit
(via `*(from shared)*` markers) actually contains the corresponding
content from `considerations/_shared-considerations.md`.

This is a stricter check than `tests/validate_structure.py`: it
compares the consideration's inherited body text against the canonical
shared body, not just the presence of the marker.
"""

from __future__ import annotations

import re

import pytest

from tests.evals._context import extract_section, load_shared, load_consideration_by_alias
from tests.validate_structure import SHARED_MARKER_PATTERN

CONSIDERATION_ALIAS = "visual-adaptation"


@pytest.fixture(autouse=True)
def markdown_source(monkeypatch):
    """These checks compare authored Markdown bodies, not rendered YAML."""
    monkeypatch.setenv("CONSIDERATION_SOURCE", "md")


def _split_h3_sections(body: str) -> dict[str, str]:
    """Split a body string by H3 headings, returning {heading: content}.

    Heading names are stripped of trailing markers like *(from shared)*.
    """
    sections: dict[str, str] = {}
    pattern = re.compile(r"^### ([^\n]+)\n(.*?)(?=^### |\Z)", re.MULTILINE | re.DOTALL)
    for match in pattern.finditer(body):
        heading = match.group(1).strip()
        heading = re.sub(rf"\s*{SHARED_MARKER_PATTERN}\s*$", "", heading).strip()
        sections[heading] = match.group(2).strip()
    return sections


def _shared_strategies() -> dict[str, str]:
    body = extract_section(load_shared(), "Exploration Strategies", level=2)
    return _split_h3_sections(body)


def _consideration_inherited_strategies(alias: str) -> dict[str, str]:
    consideration = load_consideration_by_alias(alias)
    body = extract_section(consideration, "Exploration Strategies", level=2)
    sections: dict[str, str] = {}
    pattern = re.compile(
        rf"^### ([^\n]+?)\s*{SHARED_MARKER_PATTERN}\s*\n(.*?)(?=^### |\Z)",
        re.MULTILINE | re.DOTALL,
    )
    for match in pattern.finditer(body):
        sections[match.group(1).strip()] = match.group(2).strip()
    return sections


def _normalise(text: str) -> str:
    """Collapse whitespace differences for tolerant equality checks."""
    return re.sub(r"\s+", " ", text).strip()


@pytest.mark.parametrize(
    "alias",
    [CONSIDERATION_ALIAS],
)
def test_consideration_has_shared_markers(alias: str) -> None:
    inherited = _consideration_inherited_strategies(alias)
    assert inherited, (
        f"Consideration '{alias}' has no '*(from shared)*' strategy markers; "
        "either the consideration is missing inherited content or the marker "
        "format has drifted."
    )


@pytest.mark.parametrize(
    "alias",
    [CONSIDERATION_ALIAS],
)
def test_inherited_strategies_exist_in_shared(alias: str) -> None:
    shared = _shared_strategies()
    inherited = _consideration_inherited_strategies(alias)
    unknown = sorted(set(inherited) - set(shared))
    assert not unknown, (
        f"Consideration '{alias}' claims to inherit shared strategies that "
        f"are not defined in _shared-considerations.md: {unknown}"
    )


@pytest.mark.parametrize(
    "alias",
    [CONSIDERATION_ALIAS],
)
def test_inherited_content_matches_shared(alias: str) -> None:
    shared = _shared_strategies()
    inherited = _consideration_inherited_strategies(alias)
    drift: list[str] = []
    for heading, content in inherited.items():
        shared_content = shared.get(heading, "")
        if _normalise(content) != _normalise(shared_content):
            drift.append(heading)
    assert not drift, (
        f"Consideration '{alias}' has shared-marked strategies whose content "
        f"has drifted from _shared-considerations.md: {drift}. Update the consideration to "
        "match the shared or remove the *(from shared)* marker."
    )


def test_visual_adaptation_has_no_shared_exclusions() -> None:
    """The shared file's Exclusions table lists no exclusions for
    low-vision. Verify the consideration honours that — every shared
    exploration strategy appears in the consideration's Exploration
    Strategies section, even if not all are marked as inherited."""
    shared = _shared_strategies()
    consideration = load_consideration_by_alias(CONSIDERATION_ALIAS)
    body = extract_section(consideration, "Exploration Strategies", level=2)
    consideration_strategies = _split_h3_sections(body)
    missing = sorted(set(shared) - set(consideration_strategies))
    assert not missing, (
        "Low-vision consideration is missing shared exploration strategies "
        f"despite having no exclusions: {missing}"
    )
