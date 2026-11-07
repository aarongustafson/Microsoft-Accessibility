"""
Two scenarios:

- A "trigger" case where the methodology should fire — a draft finding
  pins documented standard behavior of a *named* design-system
  component, and the correct response is to DISMISS it (the library
  owns that behavior).

- A "no-trigger" case where the principle should NOT silence the
  evaluator — a named design system is in use, but the issue lives at
  the composition / workflow layer that the library does not own, so
  the finding should be KEPT.

Run with:

    inspect eval tests/evals/methodology/eval_design_system_trust.py \
        --model copilot/gpt-5-mini
"""

from __future__ import annotations

from inspect_ai import Task, task
from inspect_ai.dataset import Sample
from inspect_ai.solver import generate, system_message

from tests.evals import _providers
from tests.evals._context import load_methodology
from tests.evals._scorers import rubric_scorer

DESIGN_SYSTEM_TRUST = load_methodology("design-system-trust")
SYSTEM = (
    "You are an accessibility evaluator reviewing draft findings "
    "produced during a manual evaluation pass. Apply the following "
    "principle exactly:\n\n"
    f"{DESIGN_SYSTEM_TRUST}\n\n"
    "When asked to review a draft finding, decide whether to KEEP it "
    "as a finding, DEMOTE it (to a manual check / open question), or "
    "DISMISS it (not a finding). Justify your decision by reference "
    "to the principle. Be precise about which layer the issue lives "
    "at: (a) standard documented behavior of a named design-system "
    "primitive, (b) configuration or composition of those primitives "
    "in the application, or (c) application-workflow concerns that "
    "no single primitive owns."
)


@task
def design_system_trust_triggers() -> Task:
    """The principle SHOULD fire — the draft finding pins documented
    standard behavior on a named design-system primitive, so the
    library owns it and the item is not a finding."""
    return Task(
        name="design_system_trust_triggers",
        dataset=[
            Sample(
                input=(
                    "Draft finding to review:\n\n"
                    "  Title: Fluent UI Slider does not support keyboard "
                    "adjustment for keyboard-only users.\n"
                    "  Severity: 2 (Moderate).\n"
                    "  Evidence: The 'Volume' control on the audio "
                    "settings panel is the standard Fluent UI Slider "
                    "primitive (imported from @fluentui/react-components, "
                    "no custom wrapper). The evaluator did not test arrow "
                    "keys on the focused slider, but assumes the slider "
                    "does not handle them and that we need to wire up "
                    "custom onKeyDown handlers for ArrowLeft / ArrowRight / "
                    "Home / End to make it keyboard accessible.\n"
                    "  Recommendation: Add a custom onKeyDown handler "
                    "that decrements / increments the slider value on "
                    "ArrowLeft / ArrowRight and jumps to min / max on "
                    "Home / End.\n\n"
                    "Should this be KEPT, DEMOTED, or DISMISSED? Apply "
                    "the design-system-trust principle."
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
                    "id": "decides_dismiss_or_not_a_finding",
                    "description": (
                        "Concludes the draft is DISMISSED / not a "
                        "finding / no action required — NOT kept as a "
                        "finding and NOT demoted to a manual check on "
                        "whether arrow-key behavior works."
                    ),
                    "weight": 2.0,
                },
                {
                    "id": "identifies_named_design_system",
                    "description": (
                        "Explicitly names Fluent UI (or the Fluent UI "
                        "Slider primitive) as the reason the documented "
                        "behavior is trusted."
                    ),
                    "weight": 1.5,
                },
                {
                    "id": "names_standard_component_behavior",
                    "description": (
                        "States that arrow-key (and Home/End) keyboard "
                        "adjustment is documented standard behavior of "
                        "the slider primitive — i.e. the library owns "
                        "this, not the application."
                    ),
                    "weight": 1.5,
                },
                {
                    "id": "cites_principle",
                    "description": (
                        "References the design-system-trust principle "
                        "by name or paraphrases it correctly: trust the "
                        "documented accessibility of named design-system "
                        "components; do not flag their standard "
                        "behavior."
                    ),
                    "weight": 1.5,
                },
                {
                    "id": "no_invented_remediation",
                    "description": (
                        "Does NOT continue to recommend adding a custom "
                        "onKeyDown handler or otherwise re-implementing "
                        "behavior that the slider primitive already "
                        "provides."
                    ),
                },
            ]
        ),
    )


@task
def design_system_trust_does_not_trigger() -> Task:
    """The principle should NOT fire — a named design system is in
    use, but the issue lives at the composition / workflow layer that
    the library does not own, so the finding should be KEPT."""
    return Task(
        name="design_system_trust_does_not_trigger",
        dataset=[
            Sample(
                input=(
                    "Draft finding to review:\n\n"
                    "  Title: Focus is lost when advancing between "
                    "steps in the booking wizard.\n"
                    "  Severity: 1 (Significant).\n"
                    "  Evidence: The booking wizard is composed from "
                    "Fluent UI primitives — Stepper for the step "
                    "indicator, Form / Input / Button for each step's "
                    "body, and Dialog for the confirmation modal at "
                    "the end. The evaluator pressed Enter on the "
                    "'Continue' button at the end of step 2. The step "
                    "container swapped to step 3, but document.activeElement "
                    "remained on the now-unmounted 'Continue' button "
                    "from step 2. The next Tab press moved focus to "
                    "the page's top-level skip link rather than to "
                    "anything inside step 3. The application code does "
                    "not call focus() on the new step container on "
                    "step change.\n"
                    "  Recommendation: When the active step changes, "
                    "programmatically move focus to the step 3 "
                    "container (or its heading) so keyboard users "
                    "resume inside the new step.\n\n"
                    "Should this be KEPT, DEMOTED, or DISMISSED? Apply "
                    "the design-system-trust principle."
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
                        "Concludes the finding should be KEPT — the "
                        "issue is a real accessibility problem that the "
                        "design-system-trust principle does not silence."
                    ),
                    "weight": 2.0,
                },
                {
                    "id": "identifies_composition_or_workflow_layer",
                    "description": (
                        "Places the issue at the composition / workflow "
                        "layer (focus management across step transitions "
                        "in application code), NOT inside any single "
                        "Fluent UI primitive."
                    ),
                    "weight": 1.5,
                },
                {
                    "id": "no_unwarranted_dismissal",
                    "description": (
                        "Does NOT dismiss the finding on the grounds "
                        "that Fluent UI is a trusted library or that "
                        "any of Stepper / Form / Dialog should handle "
                        "cross-step focus internally."
                    ),
                    "weight": 1.5,
                },
                {
                    "id": "principle_understood",
                    "description": (
                        "Demonstrates understanding that "
                        "design-system-trust is about trusting "
                        "standard documented behavior of named "
                        "primitives, NOT about silencing every finding "
                        "on a page that uses a named design system."
                    ),
                },
                {
                    "id": "no_invented_uncertainty",
                    "description": (
                        "Does NOT demote the finding to a manual check "
                        "by speculating that Fluent UI might internally "
                        "manage cross-step focus — the evidence shows "
                        "the application code is responsible and is "
                        "not doing it."
                    ),
                },
            ]
        ),
    )
