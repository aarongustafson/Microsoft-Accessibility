"""Offline regression coverage for generated consideration loading."""

from __future__ import annotations

import json
import shutil
import subprocess
import sys
from pathlib import Path

import pytest
import yaml

from tests.evals import _context

SCHEMA_FILES = sorted(_context.SCHEMAS_DIR.glob("*.consideration.yaml"))


@pytest.mark.parametrize("path", SCHEMA_FILES, ids=lambda path: path.stem)
def test_schema_loading_preserves_metadata_and_shared(path, monkeypatch):
    monkeypatch.setenv("CONSIDERATION_SOURCE", "schema")
    source = yaml.safe_load(path.read_text(encoding="utf-8"))
    rendered = yaml.safe_load(_context.load_consideration_by_alias(source["alias"]))
    for field in ("clause", "title", "alias", "status", "fps_statement", "provenance", "evaluation"):
        assert rendered.get(field) == source.get(field)
    if source["status"] == "stub":
        assert rendered == source
        return
    shared = _context._load_shared_schema()
    assert "evaluation" in rendered
    assert "scope" in rendered["evaluation"]
    assert "access_constraints" in rendered["evaluation"]
    assert "contexts" in rendered["evaluation"]
    assert "prompt" not in rendered
    assert "role" not in rendered["evaluation"]
    assert "blocked_input" not in rendered["evaluation"]
    for field in ("strategies", "interaction_contexts", "learning"):
        inherited = [
            {**item, "from_shared": True}
            for item in shared[field]
            if item["id"] not in source.get("shared_excludes", [])
        ]
        assert rendered[field] == source[field] + inherited


@pytest.mark.parametrize("source", ("md", "schema"))
@pytest.mark.parametrize("mode", ("single", "all", "medium"))
def test_stub_context_preserves_limits_and_required_safeguards(source, mode, monkeypatch):
    monkeypatch.setenv("CONSIDERATION_SOURCE", source)
    previous = _context.get_eval_consideration_context_mode()
    try:
        _context.set_eval_consideration_context_mode(mode)
        prompt = _context.load_eval_consideration_context("photosensitive-seizure-prevention")
    finally:
        _context.set_eval_consideration_context_mode(previous)
    assert "status: stub" in prompt
    for name in ("licensing", "responsible-consideration-use", "consideration-interpretation"):
        assert _context.load_methodology(name) in prompt
    if mode != "single":
        assert "do not borrow or infer" in prompt


def test_source_switch_does_not_reuse_other_source_cache(monkeypatch):
    monkeypatch.setenv("CONSIDERATION_SOURCE", "md")
    markdown = _context.load_consideration_by_alias("visual-adaptation")
    monkeypatch.setenv("CONSIDERATION_SOURCE", "schema")
    structured = _context.load_consideration_by_alias("visual-adaptation")
    assert markdown.startswith("---")
    assert structured.startswith("# Accessibility consideration:")
    assert structured != markdown


def test_invalid_source_is_reported(monkeypatch):
    monkeypatch.setenv("CONSIDERATION_SOURCE", "scheam")
    with pytest.raises(ValueError, match="Unsupported CONSIDERATION_SOURCE"):
        _context.load_consideration_by_alias("visual-adaptation")


@pytest.mark.parametrize("clause", ("4.2.7", "4.2.10"))
def test_markdown_clause_selection_requires_unique_alias(clause):
    with pytest.raises(ValueError, match="Multiple considerations"):
        _context.load_consideration(clause)


@pytest.mark.parametrize("source", ("md", "schema"))
@pytest.mark.parametrize("clause", ("4.2.7", "4.2.10"))
def test_alias_loader_rejects_ambiguous_parent_clause(source, clause, monkeypatch):
    monkeypatch.setenv("CONSIDERATION_SOURCE", source)
    with pytest.raises(ValueError, match="Multiple consideration"):
        _context.load_consideration_by_alias(clause)


@pytest.mark.parametrize("alias", ("keyboard-interaction", "voice-control",
                                 "language-and-communication",
                                 "memory-attention-and-executive-function",
                                 "numeracy-and-numeric-information"))
@pytest.mark.parametrize("source", ("md", "schema"))
def test_shared_clause_aliases_remain_loadable(alias, source, monkeypatch):
    monkeypatch.setenv("CONSIDERATION_SOURCE", source)
    assert f"alias: {alias}" in _context.load_consideration_by_alias(alias)


@pytest.mark.parametrize("source", ("md", "schema"))
def test_missing_reference_remains_an_error(source, monkeypatch):
    monkeypatch.setenv("CONSIDERATION_SOURCE", source)
    with pytest.raises(FileNotFoundError, match="No consideration file"):
        _context.load_consideration_by_alias("not-a-documented-access-topic")


def test_missing_schema_file_still_falls_back_to_markdown(monkeypatch):
    monkeypatch.setenv("CONSIDERATION_SOURCE", "schema")

    def missing_schema(alias):
        raise FileNotFoundError(alias)

    monkeypatch.setattr(_context, "_load_consideration_schema_file", missing_schema)
    _context._load_consideration_by_alias.cache_clear()
    try:
        assert _context.load_consideration_by_alias("visual-adaptation").startswith("---")
    finally:
        _context._load_consideration_by_alias.cache_clear()


@pytest.mark.parametrize("loader", (
    _context.load_all_elaborated_consideration_briefs,
    lambda: _context.load_all_elaborated_consideration_catalog_except("visual-adaptation"),
    lambda: _context.load_all_elaborated_consideration_medium_briefs_except("visual-adaptation"),
))
def test_brief_cache_is_partitioned_by_source_mode(loader, monkeypatch):
    monkeypatch.setenv("CONSIDERATION_SOURCE", "md")
    markdown = loader()
    monkeypatch.setenv("CONSIDERATION_SOURCE", "schema")
    structured = loader()
    assert "nonvisual-access" in markdown
    assert "nonvisual-access" in structured
    assert structured != markdown
    assert "scope:" in structured
    monkeypatch.setenv("CONSIDERATION_SOURCE", "md")
    assert loader() == markdown


def test_missing_shared_does_not_fall_back_to_markdown(monkeypatch):
    def missing_shared():
        raise FileNotFoundError("Missing shared")

    monkeypatch.setenv("CONSIDERATION_SOURCE", "schema")
    monkeypatch.setattr(_context, "_load_shared_schema", missing_shared)
    _context._load_consideration_by_alias.cache_clear()
    try:
        with pytest.raises(FileNotFoundError, match="Missing shared"):
            _context.load_consideration_by_alias("visual-adaptation")
    finally:
        _context._load_consideration_by_alias.cache_clear()


def test_resource_loaders_work_after_relocation(tmp_path):
    resource = tmp_path / "monorepo" / "resource"
    for folder in ("considerations", "schemas", "heuristics", "methodology", "standards"):
        shutil.copytree(_context.REPO_ROOT / folder, resource / folder)
    module = resource / "tests" / "evals" / "_context.py"
    module.parent.mkdir(parents=True)
    shutil.copyfile(Path(_context.__file__), module)
    code = (
        "import importlib.util, json; "
        f"spec = importlib.util.spec_from_file_location('context', {str(module)!r}); "
        "context = importlib.util.module_from_spec(spec); spec.loader.exec_module(context); "
        "print(json.dumps({'root': str(context.REPO_ROOT), "
        "'prompt': context.load_eval_consideration_context('photosensitive-seizure-prevention')}))"
    )
    result = subprocess.run(
        [sys.executable, "-c", code],
        cwd=tmp_path,
        check=True,
        capture_output=True,
        text=True,
    )
    payload = json.loads(result.stdout)
    assert payload["root"] == str(resource)
    assert "status: stub" in payload["prompt"]
