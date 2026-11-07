"""Evaluate evidence-based access strategy filtering, not predicted behavior.

Task and criterion identifiers and weights remain stable across the migration.
"""

from __future__ import annotations

from inspect_ai import Task, task
from inspect_ai.dataset import Sample
from inspect_ai.solver import generate, system_message

from tests.evals import _providers
from tests.evals._context import load_eval_consideration_context, load_methodology
from tests.evals._scorers import rubric_scorer

CONSIDERATION_STRATEGY_FILTER = load_methodology("consideration-strategy-filter")


def _system_for(consideration_alias: str) -> str:
    return (
        "Evaluate the draft finding using explicit task circumstances and verified "
        "interface evidence. Documented strategies are checks to perform, not "
        "predictions of how a person will behave. A working alternative resolves "
        "only the tested strategy; it does not prove all access methods work.\n\n"
        f"{CONSIDERATION_STRATEGY_FILTER}\n\n"
        f"{load_eval_consideration_context(consideration_alias)}\n\n"
        "Decide KEEP or DISMISS within the stated scope. Name the relevant access "
        "strategies, evidence, remaining checks, and uncertainty. Do not infer "
        "discoverability from layout or semantics alone."
    )


@task
def consideration_strategy_filter_triggers() -> Task:
    return Task(
        name="consideration_strategy_filter_triggers",
        dataset=[Sample(input=(
            "Review this draft finding: 'Shipping options is hard to discover "
            "because it is two thirds down the checkout page; add a skip link.' "
            "Scope: reaching the section using desktop screen-reader heading "
            "navigation, not the entire checkout or every access method. "
            "Verified evidence: descriptive, correctly nested H2 headings and a "
            "main landmark are exposed in the accessibility tree. In NVDA and "
            "JAWS tests, heading navigation and the headings list each reached "
            "'Shipping options', announced it, and positioned reading at its "
            "content. No failure was observed for this scoped task. Sequential "
            "reading, keyboard-only navigation, mobile AT, and checkout operation "
            "have not been tested. Should the position-only finding be KEPT or "
            "DISMISSED within this scope? Explain the evidence and limits."
        ))],
        solver=[system_message(_system_for("nonvisual-access")),
                generate(**_providers.generation_config())],
        scorer=rubric_scorer([
            {"id": "decides_dismiss", "weight": 2.0, "description": (
                "Dismisses the position-only finding within the explicitly tested "
                "heading-navigation scope, not as proof the whole page is accessible."
            )},
            {"id": "names_covering_strategy", "weight": 2.0, "description": (
                "Names documented heading navigation or headings-list navigation "
                "and ties it to the verified NVDA/JAWS access evidence; a generic "
                "claim that headings are discoverable is insufficient."
            )},
            {"id": "cites_principle", "weight": 1.5, "description": (
                "Applies the access strategy filter: verify reaching, identifying "
                "and operating in scope; a working alternative does not prove "
                "every method works."
            )},
            {"id": "rejects_skip_link_recommendation", "description": (
                "Rejects a mandatory skip link solely to fix page position in "
                "this tested scope, without claiming skip links have no value "
                "for untested methods or other tasks."
            )},
            {"id": "no_sighted_framing", "description": (
                "Does not invent a failure contradicting the tested heading "
                "navigation or assume scrolling visually is the only access "
                "path; explicitly preserves uncertainty about untested "
                "sequential, keyboard-only, mobile, or operation paths."
            )},
        ]),
    )


@task
def consideration_strategy_filter_does_not_trigger() -> Task:
    return Task(
        name="consideration_strategy_filter_does_not_trigger",
        dataset=[Sample(input=(
            "Review this draft finding: 'Delete account cannot be reached using "
            "keyboard navigation with magnifier focus tracking.' At 6x "
            "magnification the viewport is centred on profile fields. Delete "
            "account appears only on pointer hover over a small, unlabelled gear "
            "at the far top-right. Verified keyboard tests cannot focus or "
            "activate the gear or menu; magnifier focus tracking never reaches "
            "them. The accessibility tree exposes no named Delete account "
            "action, heading, or landmark. Panning can reveal the gear, but "
            "its appearance alone does not identify the destructive action. "
            "A pointer tester eventually found and activated it on hover. "
            "Recommendation: provide a visibly labelled action reachable and "
            "operable by keyboard, with programmatic identification. Should "
            "the keyboard/magnification finding be KEPT or DISMISSED? Explain "
            "what the successful pointer alternative does and does not establish."
        ))],
        solver=[system_message(_system_for("visual-adaptation")),
                generate(**_providers.generation_config())],
        scorer=rubric_scorer([
            {"id": "decides_keep", "weight": 2.0, "description": (
                "Keeps the evidence-backed keyboard/magnifier focus-tracking "
                "barrier despite successful pointer access."
            )},
            {"id": "enumerates_failed_strategies", "weight": 2.0, "description": (
                "Names keyboard navigation with focus/cursor tracking and "
                "explains the tested focus/activation failure; distinguishes "
                "panning to the gear from identifying and operating the action."
            )},
            {"id": "principle_understood", "weight": 1.5, "description": (
                "Explains that a working pointer alternative is scoped evidence, "
                "not proof that keyboard or every other access strategy works."
            )},
            {"id": "no_invented_strategy", "weight": 1.5, "description": (
                "Does not invent keyboard, screen-reader, or other access that "
                "contradicts the observed focus and tree failures, or assume "
                "everyone can hover every element."
            )},
            {"id": "no_unwarranted_dismissal", "description": (
                "Does not dismiss the finding because the action exists in the "
                "DOM, matches a common pattern, or worked for the pointer tester; "
                "retains the labelled keyboard-operable remediation."
            )},
        ]),
    )
