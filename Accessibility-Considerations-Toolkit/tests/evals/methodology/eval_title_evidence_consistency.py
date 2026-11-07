"""
Two scenarios:

- A "trigger" case where the methodology should fire — the draft
  finding has a title and severity that overstate what the evidence
  actually shows, and the correct response is to REVISE (rewrite title,
  recalibrate severity, re-scope recommendation) or DISMISS.

- A "no-trigger" case where title, severity, and recommendation are
  already aligned with the evidence — and the model should NOT
  fabricate inconsistency or downgrade a well-supported finding.

Run with:

    inspect eval tests/evals/methodology/eval_title_evidence_consistency.py \
        --model copilot/gpt-5-mini
"""

from __future__ import annotations

from inspect_ai import Task, task
from inspect_ai.dataset import Sample
from inspect_ai.solver import generate, system_message

from tests.evals import _providers
from tests.evals._context import load_methodology
from tests.evals._scorers import rubric_scorer

TITLE_EVIDENCE_CONSISTENCY = load_methodology("title-evidence-consistency")
SYSTEM = (
    "You are an accessibility evaluator performing a pre-submission "
    "review of draft findings. Apply the following principle exactly:\n\n"
    f"{TITLE_EVIDENCE_CONSISTENCY}\n\n"
    "When asked to review a draft finding, decide whether to KEEP it "
    "as written, REVISE it (rewrite the title, recalibrate the "
    "severity, and/or re-scope the recommendation so each element "
    "matches the recorded evidence), or DISMISS it. Justify your "
    "decision by reference to the principle, naming which of the "
    "three consistency checks (title↔evidence, severity↔evidence, "
    "recommendation↔evidence) pass or fail. Be precise about which "
    "language in the draft is or is not supported by the evidence."
)
@task
def title_evidence_consistency_triggers() -> Task:
    """The principle SHOULD fire — each draft finding has a title,
    severity, and/or recommendation that overstate what the evidence
    actually shows."""
    return Task(
        name="title_evidence_consistency_triggers",
        dataset=[
            Sample(
                input=(
                    "Draft finding to review:\n\n"
                    "  Title: Keyboard trap in date picker.\n"
                    "  Severity: 1 (Significant — blocks task completion "
                    "for keyboard-only users).\n"
                    "  Evidence: Evaluator tabbed into the 'Pick a date' "
                    "calendar grid. Arrow keys moved focus between date "
                    "cells as expected. Pressing Escape closed the "
                    "calendar and returned focus to the triggering input. "
                    "Pressing Shift+Tab from inside the grid also moved "
                    "focus back to the input. The only friction observed "
                    "was that the Escape key behaviour is not documented "
                    "on-screen and a first-time user might not discover "
                    "it immediately.\n"
                    "  Recommendation: Rebuild the date picker's keyboard "
                    "navigation model from scratch to ensure users are "
                    "not trapped. Consider replacing the component with "
                    "an accessible third-party library.\n\n"
                    "Should this be KEPT, REVISED, or DISMISSED? Apply "
                    "the title-evidence-consistency principle and name "
                    "which of the three consistency checks pass or fail."
                ),
            ),
            Sample(
                input=(
                    "Draft finding to review:\n\n"
                    "  Title: Site is completely unusable on mobile "
                    "devices.\n"
                    "  Severity: 1 (Significant — blocks core tasks "
                    "for all mobile users).\n"
                    "  Evidence: At a 320px viewport width on the "
                    "account settings page, the 'Two-factor "
                    "authentication backup codes' field label wraps "
                    "onto three lines and partially overlaps the "
                    "input border by approximately 2px on the right "
                    "edge. The input itself remains fully visible, "
                    "focusable, and editable. No other field on the "
                    "page exhibits the issue. All other tested "
                    "pages (sign-in, dashboard, profile, billing) "
                    "render correctly at the same viewport width. "
                    "The evaluator was able to complete the backup-"
                    "codes flow end-to-end at 320px without error.\n"
                    "  Recommendation: Rebuild the site's "
                    "responsive layout system using a modern CSS "
                    "framework. Consider commissioning a full "
                    "mobile-first redesign before continuing "
                    "feature work.\n\n"
                    "Should this be KEPT, REVISED, or DISMISSED? "
                    "Apply the title-evidence-consistency principle "
                    "and name which of the three consistency checks "
                    "pass or fail."
                ),
            ),
        ],
        solver=[
            system_message(SYSTEM),
            generate(**_providers.generation_config()),
        ],
        scorer=rubric_scorer(
            [
                {
                    "id": "decides_revise_or_dismiss",
                    "description": (
                        "Concludes the draft should be REVISED (or "
                        "DISMISSED) — NOT kept as written with the "
                        "current title, severity, and recommendation."
                    ),
                    "weight": 2.0,
                },
                {
                    "id": "flags_title_not_supported_by_evidence",
                    "description": (
                        "Explicitly identifies that the title is not "
                        "supported by the evidence — either because it "
                        "describes a failure mode the evidence "
                        "contradicts (e.g. calling something a 'keyboard "
                        "trap' when exits were observed) or because it "
                        "overgeneralises from a narrowly-scoped "
                        "observation. Names this as a failed "
                        "title↔evidence check."
                    ),
                    "weight": 1.5,
                },
                {
                    "id": "flags_severity_inflation",
                    "description": (
                        "Notes that the severity is calibrated to the "
                        "alarmist or overgeneralised title rather than "
                        "to the actual observed impact, and recommends "
                        "lowering the severity."
                    ),
                    "weight": 1.5,
                },
                {
                    "id": "flags_recommendation_overscope",
                    "description": (
                        "Notes that the recommendation addresses a "
                        "hypothetical catastrophic or sweeping failure "
                        "(rebuild from scratch / replace the component / "
                        "commission a full redesign) rather than the "
                        "specific, evidenced friction."
                    ),
                },
                {
                    "id": "proposes_accurate_title",
                    "description": (
                        "Suggests a revised title that accurately scopes "
                        "and describes the observed problem — naming "
                        "the specific component, behaviour, viewport, or "
                        "field actually evidenced (e.g. 'Date picker "
                        "dismissal requires non-obvious Escape key' or "
                        "'Backup-codes field label wraps at 320px "
                        "viewport')."
                    ),
                },
            ]
        ),
    )


@task
def title_evidence_consistency_does_not_trigger() -> Task:
    """The principle should NOT fire — each draft finding's title,
    severity, and recommendation are already proportionate to the
    evidence."""
    return Task(
        name="title_evidence_consistency_does_not_trigger",
        dataset=[
            Sample(
                input=(
                    "Draft finding to review:\n\n"
                    "  Title: Submit button has no accessible name.\n"
                    "  Severity: 1 (Significant — screen reader users "
                    "cannot identify the primary action on the form).\n"
                    "  Evidence: Accessibility tree dump for the form "
                    "submission control reports role='button' with "
                    "name=''. NVDA screen reader recording announces "
                    "only 'button' when focus reaches the control, with "
                    "no accessible name or text content. Visual "
                    "inspection confirms the button displays only an "
                    "icon (a paper-airplane glyph) with no visible text "
                    "label and no aria-label attribute in the DOM.\n"
                    "  Recommendation: Add an accessible name to the "
                    "submit button via aria-label='Send message' or "
                    "visually hidden text, matching the button's "
                    "intended action.\n\n"
                    "Should this be KEPT, REVISED, or DISMISSED? Apply "
                    "the title-evidence-consistency principle and name "
                    "which of the three consistency checks pass or fail."
                ),
            ),
            Sample(
                input=(
                    "Draft finding to review:\n\n"
                    "  Title: Body text on the marketing landing "
                    "page fails WCAG 2.1 AA contrast minimum.\n"
                    "  Severity: 1 (Significant — body text is "
                    "unreadable for users with low vision and for "
                    "many users in bright-light conditions).\n"
                    "  Evidence: Measured contrast ratio of the "
                    "primary body-text colour (#9a9a9a) against the "
                    "page background (#ffffff) using the WebAIM "
                    "contrast checker is 2.6:1. WCAG 2.1 SC 1.4.3 "
                    "requires a minimum of 4.5:1 for normal-size "
                    "body text. The body text in question is 16px "
                    "regular weight — i.e. not 'large text' under "
                    "the SC definition (which would relax the "
                    "threshold to 3:1). The same colour token is "
                    "used for all paragraph copy on the landing "
                    "page (verified across three sections).\n"
                    "  Recommendation: Darken the body-text colour "
                    "token to a value that achieves at least 4.5:1 "
                    "against the page background (e.g. #595959 "
                    "measures 7.0:1) and re-verify with the "
                    "contrast checker.\n\n"
                    "Should this be KEPT, REVISED, or DISMISSED? "
                    "Apply the title-evidence-consistency principle "
                    "and name which of the three consistency checks "
                    "pass or fail."
                ),
            ),
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
                        "Concludes the finding should be KEPT as "
                        "written — the title, severity, and "
                        "recommendation are each grounded in and "
                        "proportionate to the recorded evidence."
                    ),
                    "weight": 2.0,
                },
                {
                    "id": "no_unwarranted_revision",
                    "description": (
                        "Does NOT propose softening the title, lowering "
                        "the severity, or narrowing the recommendation. "
                        "Recognises that strong language is appropriate "
                        "when the evidence supports it."
                    ),
                    "weight": 1.5,
                },
                {
                    "id": "confirms_alignment",
                    "description": (
                        "Explicitly walks through the three consistency "
                        "checks and confirms each one passes: title "
                        "matches evidence (empty accessible name), "
                        "severity matches impact (screen reader users "
                        "blocked), recommendation addresses the actual "
                        "problem (add an accessible name)."
                    ),
                    "weight": 1.5,
                },
                {
                    "id": "principle_understood",
                    "description": (
                        "Demonstrates understanding that "
                        "title-evidence-consistency is about ensuring "
                        "language matches evidence, NOT about reflexively "
                        "softening every finding or treating every "
                        "severity-1 rating as suspect."
                    ),
                },
            ]
        ),
    )
