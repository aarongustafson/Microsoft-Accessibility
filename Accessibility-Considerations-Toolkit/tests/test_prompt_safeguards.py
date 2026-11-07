"""Regression tests for required methodology in consideration evaluation prompts."""

from __future__ import annotations

import ast
import importlib
import re

import pytest
import yaml

from tests.evals import _context
from tests.evals.heuristics.eval_heuristic_1 import REQUIRED_CONSIDERATION_SAFEGUARDS
from tests.evals.heuristics.eval_heuristics_lens import _build_cell_context
from tests.evals.sub_agents.heuristic_subtask import build_heuristic_subtask

REQUIRED_METHODOLOGY = (
    "licensing",
    "responsible-consideration-use",
    "consideration-interpretation",
)


def _assert_required_methodology(prompt: str) -> None:
    for name in REQUIRED_METHODOLOGY:
        assert f"methodology/{name}.md" in prompt
        assert _context.load_methodology(name) in prompt


@pytest.mark.parametrize("mode", ("single", "all-considerations", "medium"))
def test_consideration_context_modes_include_required_methodology(mode):
    previous_mode = _context.get_eval_consideration_context_mode()
    try:
        _context.set_eval_consideration_context_mode(mode)
        prompt = _context.load_eval_consideration_context("visual-adaptation")
    finally:
        _context.set_eval_consideration_context_mode(previous_mode)

    _assert_required_methodology(prompt)


def test_focused_heuristic_context_includes_required_methodology():
    _assert_required_methodology(_build_cell_context("visual-adaptation", 1))
    _assert_required_methodology(REQUIRED_CONSIDERATION_SAFEGUARDS)


def test_sub_agent_system_prompt_includes_required_methodology():
    task = build_heuristic_subtask(
        heuristic_number=1,
        consideration_alias="visual-adaptation",
        artifact_description="A search form with delayed results.",
    )
    system_solver = list(task.solver)[0]
    system_prompt = system_solver.__dict__["__registry_params__"]["template"]

    _assert_required_methodology(system_prompt)


IDENTITY_SIMULATION = re.compile(
    r"\bas if you (?:are|were)\b|\byou are (?:a|an) "
    r"(?:person|user|blind|deaf|disabled)\b|"
    r"\byour (?:senses|motor|only barrier)\b|"
    r"\b(?:senses|motor control|abilities|language) (?:are|is) unaffected\b|"
    r"\bshared user\b|\b(?:dyslexia|autistic) archetype\b",
    re.IGNORECASE,
)


@pytest.mark.parametrize("source", ("md", "schema"))
@pytest.mark.parametrize("mode", ("single", "all", "medium"))
def test_generated_eval_contexts_do_not_simulate_an_identity(source, mode, monkeypatch):
    monkeypatch.setenv("CONSIDERATION_SOURCE", source)
    previous_mode = _context.get_eval_consideration_context_mode()
    try:
        _context.set_eval_consideration_context_mode(mode)
        for path in sorted(_context.SCHEMAS_DIR.glob("*.consideration.yaml")):
            alias = yaml.safe_load(path.read_text(encoding="utf-8"))["alias"]
            assert not IDENTITY_SIMULATION.search(_context.load_eval_consideration_context(alias))
    finally:
        _context.set_eval_consideration_context_mode(previous_mode)


@pytest.mark.parametrize("source", ("md", "schema"))
def test_all_brief_renderings_are_evaluation_scopes(source, monkeypatch):
    monkeypatch.setenv("CONSIDERATION_SOURCE", source)
    for brief in (
        _context.load_all_elaborated_consideration_briefs(),
        _context.load_all_elaborated_consideration_catalog_except("visual-adaptation"),
        _context.load_all_elaborated_consideration_medium_briefs_except("visual-adaptation"),
    ):
        assert "nonvisual-access" in brief
        assert not IDENTITY_SIMULATION.search(brief)
        assert "Consideration Prompt" not in brief
        assert "User Variant" not in brief
    assert "Evaluation Considerations" in _context.load_all_elaborated_consideration_briefs()


@pytest.mark.parametrize("source", ("md", "schema"))
def test_focused_heuristic_context_preserves_scope_and_at(source, monkeypatch):
    monkeypatch.setenv("CONSIDERATION_SOURCE", source)
    prompt = _build_cell_context("visual-adaptation", 1)
    _assert_required_methodology(prompt)
    assert "## Evaluation Considerations" in prompt
    assert "browser-zoom" in prompt.lower() or "browser zoom" in prompt.lower()
    assert not IDENTITY_SIMULATION.search(prompt)


def test_raw_reference_loader_does_not_add_safeguards(monkeypatch):
    monkeypatch.setenv("CONSIDERATION_SOURCE", "md")
    raw = _context.load_consideration_by_alias("visual-adaptation")
    assert raw == (_context.CONSIDERATIONS_DIR / "4.2.2-visual-adaptation.md").read_text(encoding="utf-8")
    assert "# Required methodology:" not in raw
    _assert_required_methodology(_context.with_required_consideration_safeguards(raw))


@pytest.mark.parametrize("path", sorted(
    path for path in (_context.REPO_ROOT / "tests/evals/deterministic").glob("*.py")
    if not path.name.startswith("_")
), ids=lambda path: path.stem)
def test_deterministic_task_prompts_are_scoped_and_safeguarded(path):
    module = importlib.import_module(f"tests.evals.deterministic.{path.stem}")
    for node in ast.parse(path.read_text(encoding="utf-8")).body:
        if not isinstance(node, ast.FunctionDef):
            continue
        if not any(isinstance(item, ast.Name) and item.id == "task" for item in node.decorator_list):
            continue
        task = getattr(module, node.name)()
        for sample in task.dataset:
            assert isinstance(sample.input, str)
            assert not IDENTITY_SIMULATION.search(sample.input)
            assert "they would" not in sample.input
            assert "user variants" not in sample.input
            assert isinstance(sample.metadata["answer_key"], dict)
        system_solver = list(task.solver)[0]
        system_prompt = system_solver.__dict__["__registry_params__"]["template"]
        _assert_required_methodology(system_prompt)
        assert not IDENTITY_SIMULATION.search(system_prompt)
