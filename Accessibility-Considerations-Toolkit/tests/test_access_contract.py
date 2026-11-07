"""Source, structured-output, and framing contracts for access considerations."""

from __future__ import annotations

import re

import pytest
import yaml

from tests import validate_structure as structure

FILES = structure.get_consideration_files()


@pytest.mark.parametrize("path", FILES, ids=lambda path: path.stem)
def test_source_and_generated_metadata_and_section_counts_match(path):
    source = structure.parse_frontmatter(path)
    output = structure.SCHEMAS_DIR / f"{path.stem}.consideration.yaml"
    data = yaml.safe_load(output.read_text(encoding="utf-8"))
    for field in ("clause", "title", "alias", "status"):
        assert data[field] == source[field], (path.name, field)
    assert data.get("shared_excludes", []) == source.get("shared_excludes", [])
    assert data.get("provenance") == source.get("provenance")
    after_h1 = re.split(r"^# .+\n", path.read_text(encoding="utf-8"), maxsplit=1, flags=re.M)[1]
    statement = after_h1.strip().split("\n\n", 1)[0]
    assert " ".join(data["fps_statement"].split()) == " ".join(statement.split())
    if source["status"] == "stub":
        assert "evaluation" not in data and "strategies" not in data
        return
    for heading, field in (
        ("Assistive Technologies", "assistive_tech"),
        ("Exploration Strategies", "strategies"),
        ("Interaction Contexts", "interaction_contexts"),
        ("Learning Considerations", "learning"),
        ("Heuristic Lens Overrides", "heuristic_overrides"),
    ):
        entries = [
            name for name in structure.get_h3_sections(path, heading)
            if not re.search(structure.SHARED_MARKER_PATTERN, name)
        ]
        if heading == "Learning Considerations" and not entries:
            section = re.search(
                r"^## Learning Considerations\n(.*?)(?=^## |\Z)",
                path.read_text(encoding="utf-8"), re.M | re.S,
            ).group(1)
            entries = [
                line for line in section.splitlines()
                if re.match(r"^- \*\*[^*]+\*\*", line)
                and not re.search(structure.SHARED_MARKER_PATTERN, line)
            ]
        assert len(entries) == len(data[field]), (path.name, heading)
    assert set(data["evaluation"]) == {"scope", "access_constraints", "contexts", "checklist"}
    assert not structure.validate_access_framing(yaml.safe_dump(data), output.name)
    shared = yaml.safe_load((structure.SCHEMAS_DIR / "_shared-considerations.yaml").read_text())
    shared_ids = {
        item["id"] for field in ("strategies", "interaction_contexts", "learning")
        for item in shared[field]
    }
    assert set(data.get("shared_excludes", [])) <= shared_ids
    ids = {}
    for field in ("assistive_tech", "strategies", "interaction_contexts", "learning"):
        names = [item["id"] for item in data[field]]
        assert len(names) == len(set(names)), (path.name, field)
        assert all(re.fullmatch(r"[a-z0-9-]+", name) for name in names)
        ids[field] = set(names)
    for context in data["interaction_contexts"]:
        assert set(context["uses_at"]) <= ids["assistive_tech"], (path.name, context["id"])
        available_strategies = ids["strategies"] | {
            item["id"] for item in shared["strategies"]
            if item["id"] not in data.get("shared_excludes", [])
        }
        assert set(context.get("uses_strategies", [])) <= available_strategies, (path.name, context["id"])


@pytest.mark.parametrize("text", [
    "Evaluate as if you are a person with limited vision.",
    "Your senses are unaffected.",
    "Compare with the shared user's behavior.",
    "This is the archetype.",
])
def test_identity_simulation_is_rejected(text):
    assert structure.validate_access_framing(text, "example")


def test_access_conditions_are_not_identity_simulation():
    text = "Evaluate nonvisual navigation, including speech and Braille output. Some people may combine access strategies."
    assert not structure.validate_access_framing(text, "example")


def test_en_parent_numbers_are_not_synthetic_subclauses():
    metadata = [structure.parse_frontmatter(path) for path in FILES]
    assert sum(item["clause"] == "4.2.7" for item in metadata) == 2
    assert sum(item["clause"] == "4.2.10" for item in metadata) == 3
    assert all(re.fullmatch(r"4\.2\.\d+", item["clause"]) for item in metadata)
