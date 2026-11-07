"""Exact fidelity of marked, shared Markdown entries across all access topics."""

from __future__ import annotations

import re

import pytest

from tests import validate_structure as structure


def _entries(text):
    entries = {}
    for match in re.finditer(r"^### (.*?)\n(.*?)(?=^### |^## |\Z)", text, re.M | re.S):
        title = re.sub(rf" {structure.SHARED_MARKER_PATTERN}$", "", match[1])
        entries[title] = " ".join(match[2].split())
    return entries


@pytest.mark.parametrize("path", structure.get_consideration_files(), ids=lambda p: p.stem)
def test_all_marked_shared_bodies_match_authoring_source(path):
    shared = (structure.CONSIDERATIONS_DIR / "_shared-considerations.md").read_text()
    source = _entries(shared)
    text = path.read_text()
    copied = _entries(text)
    for title in re.findall(rf"^### (.*?) {structure.SHARED_MARKER_PATTERN}$", text, re.M):
        assert copied[title] == source[title], (path.name, title)
    learning = {
        match[1]: " ".join(match[2].split())
        for match in re.finditer(
            r"^- \*\*([^*]+)\*\*: (.*?)(?=^- \*\*|^## |\Z)", shared, re.M | re.S
        )
    }
    for match in re.finditer(
        rf"^- \*\*([^*]+)\*\* {structure.SHARED_MARKER_PATTERN}: (.*?)(?=^- \*\*|^## |\Z)",
        text, re.M | re.S,
    ):
        assert " ".join(match[2].split()) == learning[match[1]], (path.name, match[1])


@pytest.mark.parametrize("marker", ["*(from shared)*", "_(from shared)_"])
def test_shared_marker_accepts_equivalent_markdown_emphasis(tmp_path, marker):
    path = tmp_path / "example.md"
    path.write_text(f"### Navigation {marker}\n\nShared content.\n", encoding="utf-8")
    assert structure.get_shared_content_markers(path) == [marker]
    assert _entries(path.read_text()) == {"Navigation": "Shared content."}
