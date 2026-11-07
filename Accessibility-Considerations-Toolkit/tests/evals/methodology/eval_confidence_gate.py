"""Pilot eval: confidence-gate methodology principle.

Two scenarios:

- A "trigger" case where the methodology should fire — the model is
  presented with an unverified assumption being treated as a finding,
  and the correct response is to demote it to a manual check / open
  question.

- A "no-trigger" case where the model has clear evidence — and should
  NOT inject a spurious manual check or hedge unnecessarily.

Run with:

    inspect eval tests/evals/methodology/eval_confidence_gate.py \
        --model copilot/gpt-5-mini
"""

from __future__ import annotations

from inspect_ai import Task, task
from inspect_ai.dataset import Sample
from inspect_ai.solver import generate, system_message

from tests.evals import _providers
from tests.evals._context import load_methodology
from tests.evals._scorers import rubric_scorer

CONFIDENCE_GATE = load_methodology("confidence-gate")
SYSTEM = (
    "You are an accessibility evaluator producing findings from a manual "
    "evaluation pass. Apply the following principle exactly:\n\n"
    f"{CONFIDENCE_GATE}\n\n"
    "When asked to review a draft finding, decide whether to KEEP it as a "
    "finding, DEMOTE it (to a manual check, open question, or follow-up "
    "verification), or DISMISS it. Justify your decision by reference to "
    "the principle. Be precise about which evidence sources are present "
    "and which assumptions are unverified."
)


@task
def confidence_gate_triggers() -> Task:
    """The principle SHOULD fire — the draft finding rests on an
    unverified assumption."""
    return Task(
        name="confidence_gate_triggers",
        dataset=[
            Sample(
                input=(
                    "Draft finding to review:\n\n"
                    "  Title: Date picker is not accessible to screen reader users.\n"
                    "  Severity: 1 (Significant).\n"
                    "  Evidence: Screenshot shows a calendar grid component "
                    "labelled 'Pick a date'. The screenshot was taken with "
                    "no assistive technology active. The evaluator has not "
                    "tabbed into the component, has not inspected the "
                    "accessibility tree, and has not tested with a screen "
                    "reader. The component is from an unknown library.\n"
                    "  Recommendation: Ensure the date picker can be "
                    "operated and announced by a screen reader user, "
                    "including reaching it by keyboard, knowing what it "
                    "is, and selecting a date.\n\n"
                    "Should this be KEPT, DEMOTED, or DISMISSED? Apply the "
                    "confidence-gate principle."
                ),
            )
        ],
        solver=[
            system_message(SYSTEM),
            generate(**_providers.generation_config()),
        ],
        scorer=rubric_scorer(
            [
                {
                    "id": "decides_demote_or_dismiss",
                    "description": (
                        "Concludes the item should be DEMOTED (to a manual "
                        "check / open question / follow-up verification) "
                        "or DISMISSED — NOT kept as a confirmed finding "
                        "with severity."
                    ),
                    "weight": 2.0,
                },
                {
                    "id": "names_unverified_assumption",
                    "description": (
                        "Explicitly identifies that the finding rests on an "
                        "unverified assumption (e.g. 'no AT was used', 'tree "
                        "was not inspected', 'library unknown')."
                    ),
                    "weight": 1.5,
                },
                {
                    "id": "cites_principle",
                    "description": (
                        "References the confidence-gate principle by name "
                        "or paraphrases it correctly: do not assert a "
                        "finding that would collapse if the assumption "
                        "were wrong."
                    ),
                    "weight": 1.5,
                },
                {
                    "id": "lists_verification_steps",
                    "description": (
                        "Names concrete verification steps that would "
                        "elevate the manual check to a finding (e.g. tab "
                        "into the component, query the accessibility "
                        "tree, test with NVDA/JAWS/VoiceOver)."
                    ),
                },
                {
                    "id": "no_severity_assertion",
                    "description": (
                        "Does NOT continue to assert a severity rating on "
                        "the finding as if it were confirmed."
                    ),
                },
            ]
        ),
    )


@task
def confidence_gate_does_not_trigger() -> Task:
    """The principle should NOT fire — evidence is sufficient and the
    answer should not invent unnecessary uncertainty."""
    return Task(
        name="confidence_gate_does_not_trigger",
        dataset=[
            Sample(
                input=(
                    "Draft finding to review:\n\n"
                    "  Title: Search input has no accessible name.\n"
                    "  Severity: 1 (Significant).\n"
                    "  Evidence: Accessibility tree dump shows the input "
                    "with role='textbox' and name=''. Screenshot shows a "
                    "search icon to its left with no visible label. NVDA "
                    "announced 'edit, blank' when focused. The evaluator "
                    "tabbed to the field and confirmed no name is "
                    "announced.\n"
                    "  Recommendation: Add a programmatic accessible name "
                    "via a visible label or another mechanism that "
                    "exposes a name to assistive technology.\n\n"
                    "Should this be KEPT, DEMOTED, or DISMISSED? Apply the "
                    "confidence-gate principle."
                ),
            )
        ],
        solver=[
            system_message(SYSTEM),
            generate(**_providers.generation_config()),
        ],
        scorer=rubric_scorer(
            [
                {
                    "id": "decides_keep",
                    "description": (
                        "Concludes the verdict should be KEPT — the "
                        "observable, verifiable evidence (visual "
                        "inspection, click behaviour, keyboard focus) "
                        "is sufficient to support the conclusion without "
                        "unverified assumptions."
                    ),
                    "weight": 2.0,
                },
                {
                    "id": "identifies_evidence_sources",
                    "description": (
                        "Names the converging observable evidence sources: "
                        "visual inspection (label visible and readable), "
                        "click/interaction verification (clicking the label "
                        "focused the input), and keyboard verification "
                        "(label remained visible during focus)."
                    ),
                    "weight": 1.5,
                },
                {
                    "id": "no_unwarranted_demotion",
                    "description": (
                        "Does NOT demote this to a manual check or "
                        "fabricate uncertainty about the label pairing — "
                        "the observable evidence already meets the bar."
                    ),
                    "weight": 1.5,
                },
                {
                    "id": "principle_understood",
                    "description": (
                        "Demonstrates understanding that confidence-gate "
                        "is about preventing assertions on unverified "
                        "assumptions, NOT about treating every verdict "
                        "as uncertain."
                    ),
                },
            ]
        ),
    )
