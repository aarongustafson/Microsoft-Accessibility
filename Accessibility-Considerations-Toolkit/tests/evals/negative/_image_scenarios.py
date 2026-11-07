"""Shared helpers for image-backed negative eval scenarios.

These helpers keep screenshot-based negative tests lightweight so future
scenarios can swap in any image fixture without reimplementing the same
evaluation context, image attachment, and task wiring.
"""

from __future__ import annotations

from pathlib import Path
from typing import Any

from inspect_ai import Task
from inspect_ai.dataset import Sample
from inspect_ai.model import ChatMessageUser, ContentImage, ContentText
from inspect_ai.solver import generate, system_message

from tests.evals import _providers
from tests.evals._context import load_eval_consideration_context
from tests.evals._scorers import Criterion, rubric_scorer


def build_negative_image_task(
    *,
    task_name: str,
    consideration_alias: str,
    image_path: Path,
    prompt_text: str,
    criteria: list[dict | Criterion] | None = None,
    scorer: Any = None,
    image_detail: str = "low",
) -> Task:
    if (criteria is None) == (scorer is None):
        raise ValueError("Provide exactly one of 'criteria' or 'scorer'")

    consideration = load_eval_consideration_context(consideration_alias)
    system = (
        "You are an accessibility evaluator answering questions about the "
        "Accessibility Considerations Toolkit (Act) knowledge base. Use only what is in your reference "
        "context. Evaluate access requirements and barriers under the explicit "
        "circumstances, not as a simulated person or a universal disability profile. "
        "If a request goes beyond that context, say so explicitly "
        "rather than improvising.\n\n"
        "# Consideration reference\n\n"
        f"{consideration}"
    )

    return Task(
        name=task_name,
        dataset=[
            Sample(
                input=[
                    ChatMessageUser(
                        content=[
                            ContentText(text=prompt_text),
                            ContentImage(image=str(image_path), detail=image_detail),
                        ]
                    )
                ],
            )
        ],
        solver=[
            system_message(system),
            generate(**_providers.generation_config()),
        ],
        scorer=scorer if scorer is not None else rubric_scorer(criteria),
    )