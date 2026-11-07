"""Accessibility Considerations Toolkit (Act) workflow, instruction, and governance contracts."""

from __future__ import annotations

from fnmatch import fnmatchcase
import json
from pathlib import Path

import pytest
import yaml

from tests import validate_structure

ROOT = validate_structure.GOVERNANCE_ROOT
RESOURCE = validate_structure.REPO_ROOT
WORKFLOW = ROOT / ".github" / "workflows" / "act-validate.yml"
INSTRUCTIONS = ROOT / ".github" / "instructions" / "act.instructions.md"
SKILL = ROOT / ".github" / "skills" / "consideration-to-schema" / "SKILL.md"


def _frontmatter(path: Path) -> dict:
    text = path.read_text(encoding="utf-8")
    assert text.startswith("---\n")
    return yaml.safe_load(text.split("---", 2)[1])


def test_workflow_runs_only_resource_commands_without_model_authentication():
    workflow = yaml.load(WORKFLOW.read_text(encoding="utf-8"), Loader=yaml.BaseLoader)
    assert workflow["permissions"] == {"contents": "read"}
    assert workflow["defaults"]["run"]["working-directory"] == RESOURCE.name
    assert set(workflow["on"]) == {"pull_request", "push", "workflow_dispatch"}
    assert workflow["on"]["push"]["branches"] == ["main"]
    job = workflow["jobs"]["validate"]
    assert job["strategy"]["matrix"]["python-version"] == ["3.12", "3.14"]
    steps = job["steps"]
    assert steps[0]["uses"] == "actions/checkout@v4"
    assert steps[0]["with"]["persist-credentials"] == "false"
    assert all("working-directory" not in step for step in steps)
    commands = [step["run"] for step in steps if "run" in step]
    assert commands == [
        "python -m pip install -r requirements-dev.txt",
        "python -m pip check",
        "python tests/validate_structure.py\n"
        "python -m pytest tests/validate_structure.py tests -q\n",
        "python -m pytest tests/test_schema_loading.py tests/test_prompt_safeguards.py "
        "tests/evals/sub_agents/test_per_heuristic_loading.py -q",
    ]
    assert steps[-1]["env"] == {"CONSIDERATION_SOURCE": "schema"}
    assert not any("secrets." in str(step) for step in steps)


@pytest.mark.parametrize("event", ["pull_request", "push"])
def test_workflow_path_filters_cover_act_but_not_windows_changes(event):
    workflow = yaml.load(WORKFLOW.read_text(encoding="utf-8"), Loader=yaml.BaseLoader)
    filters = workflow["on"][event]["paths"]
    expected = {
        "Accessibility-Considerations-Toolkit/**",
        ".github/workflows/act-validate.yml",
        ".github/instructions/act.instructions.md",
        ".github/skills/consideration-to-schema/**",
        ".github/CODEOWNERS",
        ".github/PULL_REQUEST_TEMPLATE.md",
    }
    assert set(filters) == expected
    for path in (
        "Accessibility-Considerations-Toolkit/considerations/4.2.1-nonvisual-access.md",
        "Accessibility-Considerations-Toolkit/schemas/_shared-considerations.yaml",
        "Accessibility-Considerations-Toolkit/requirements-dev.txt",
        "Accessibility-Considerations-Toolkit/tests/test_monorepo_integration.py",
        ".github/skills/consideration-to-schema/SKILL.md",
        ".github/instructions/act.instructions.md",
        ".github/workflows/act-validate.yml",
        ".github/CODEOWNERS",
        ".github/PULL_REQUEST_TEMPLATE.md",
    ):
        assert any(fnmatchcase(path, pattern) for pattern in filters), path
    for path in (
        "Maximize-All-Windows/src/Program.cs",
        ".github/workflows/release.yml",
        "Unrelated-Project/README.md",
    ):
        assert not any(fnmatchcase(path, pattern) for pattern in filters), path


def test_agent_instructions_and_skill_resolve_only_the_toolkit():
    instruction = _frontmatter(INSTRUCTIONS)
    assert instruction["description"]
    patterns = instruction["applyTo"].split(",")
    assert "Accessibility-Considerations-Toolkit/**" in patterns
    assert not any(fnmatchcase("Maximize-All-Windows/src/Program.cs", p) for p in patterns)
    assert (INSTRUCTIONS.parent / "../../Accessibility-Considerations-Toolkit/AGENTS.md").resolve() == (
        RESOURCE / "AGENTS.md"
    )
    skill = _frontmatter(SKILL)
    assert skill["name"] == SKILL.parent.name == "consideration-to-schema"
    assert skill["user-invocable"] is True
    assert skill["disable-model-invocation"] is False
    assert (SKILL.parent / "../../../Accessibility-Considerations-Toolkit").resolve() == RESOURCE
    text = " ".join(SKILL.read_text(encoding="utf-8").split())
    assert "All paths and commands below are relative to `Accessibility-Considerations-Toolkit`" in text
    assert "Markdown under `considerations/` is the source of truth" in text
    assert "Never create or update Markdown from schema YAML" in text


def test_governance_uses_monorepo_root_not_nested_github():
    assert ROOT == RESOURCE.parent
    assert not (RESOURCE / ".github" / "CODEOWNERS").exists()
    assert not (RESOURCE / ".github" / "PULL_REQUEST_TEMPLATE.md").exists()
    codeowners = (ROOT / ".github" / "CODEOWNERS").read_text(encoding="utf-8")
    assert not validate_structure.validate_codeowners(codeowners)
    template = (ROOT / ".github" / "PULL_REQUEST_TEMPLATE.md").read_text(encoding="utf-8")
    assert "For other projects, mark them not applicable" in template


def test_resource_local_paths_do_not_satisfy_monorepo_ownership():
    nested_policy = "\n".join(
        f"{path.replace('/Accessibility-Considerations-Toolkit', '')} "
        + " ".join(validate_structure.REQUIRED_CODEOWNERS)
        for path in validate_structure.PROMPT_BEARING_CODEOWNER_PATHS
    )
    assert validate_structure.validate_codeowners(nested_policy)


def test_markdown_formatter_is_pinned_and_scoped_to_resource():
    workflow = yaml.load(WORKFLOW.read_text(encoding="utf-8"), Loader=yaml.BaseLoader)
    steps = workflow["jobs"]["markdown"]["steps"]
    assert steps[1]["with"]["node-version"] == "22"
    assert steps[2]["run"] == "npm ci --ignore-scripts"
    assert steps[3]["run"] == "npm run format:md:check"
    package = json.loads((RESOURCE / "package.json").read_text())
    assert package["devDependencies"]["prettier"] == "3.6.2"
    for command in package["scripts"].values():
        assert '"**/*.md"' in command
        assert "../.github/skills/consideration-to-schema/SKILL.md" in command
        assert "../.github/instructions/act.instructions.md" in command
        assert "Maximize-All-Windows" not in command
        assert "--config .prettierrc.json" in command
