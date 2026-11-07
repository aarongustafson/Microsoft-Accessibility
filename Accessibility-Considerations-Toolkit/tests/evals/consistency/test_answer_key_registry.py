from __future__ import annotations

from tests.evals.answer_keys import load_answer_key, load_answer_key_from_file


def test_load_answer_key_reads_registry_entry_by_key() -> None:
    answer_key = load_answer_key("visual_adaptation.at_categories")

    assert answer_key["threshold"] == 0.8
    assert answer_key["items"][0]["id"] == "browser_zoom"


def test_load_answer_key_from_file_accepts_module_key_name() -> None:
    by_key = load_answer_key("visual_adaptation.at_categories")
    by_filename = load_answer_key_from_file("visual_adaptation.at_categories")

    assert by_filename == by_key


def test_load_answer_key_from_file_accepts_legacy_filename() -> None:
    by_key = load_answer_key("visual_adaptation.at_categories")
    by_filename = load_answer_key_from_file("visual_adaptation_at_categories.json")

    assert by_filename == by_key