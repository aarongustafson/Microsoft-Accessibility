from __future__ import annotations

from tests.evals._scorers import parse_answer_key, score_answer_key


def test_parse_answer_key_reads_forbidden_items() -> None:
    items, forbidden_items, threshold = parse_answer_key(
        {
            "threshold": 1.0,
            "items": [{"id": "alpha", "matches": ["Alpha"]}],
            "forbidden_items": [{"id": "beta", "matches": ["Beta"]}],
        }
    )

    assert threshold == 1.0
    assert [item.id for item in items] == ["alpha"]
    assert [item.id for item in forbidden_items] == ["beta"]


def test_score_answer_key_fails_when_forbidden_item_is_present() -> None:
    raw_score, passed, breakdown, threshold = score_answer_key(
        "- Alpha\n- Keyboard navigation and focus management",
        {
            "threshold": 1.0,
            "items": [{"id": "alpha", "matches": ["Alpha"]}],
            "forbidden_items": [
                {
                    "id": "excluded_keyboard_navigation",
                    "matches": ["keyboard navigation and focus management"],
                }
            ],
        },
    )

    assert raw_score == 1.0
    assert threshold == 1.0
    assert passed is False
    assert breakdown[-1]["kind"] == "forbidden"
    assert breakdown[-1]["matched"] is False


def test_score_answer_key_passes_when_forbidden_item_is_absent() -> None:
    raw_score, passed, breakdown, threshold = score_answer_key(
        "- Alpha",
        {
            "threshold": 1.0,
            "items": [{"id": "alpha", "matches": ["Alpha"]}],
            "forbidden_items": [
                {
                    "id": "excluded_keyboard_navigation",
                    "matches": ["keyboard navigation and focus management"],
                }
            ],
        },
    )

    assert raw_score == 1.0
    assert threshold == 1.0
    assert passed is True
    assert breakdown[-1]["kind"] == "forbidden"
    assert breakdown[-1]["matched"] is True