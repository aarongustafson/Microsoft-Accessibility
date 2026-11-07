"""Deterministic eval: hidden answer-key grading for the deaf consideration.

This task uses a deterministic scorer backed by a hidden answer key in
`Sample.metadata["answer_key"]`. The key is not sent to the model; only the prompt and
system context are.

These checks cover stable, factual consideration content that should reliably be
triggered by the evaluation context, including assistive-technology categories,
named assistive technologies, consideration-specific exploration strategies,
scope-specific interaction contexts, inherited shared strategies, and
bounded behaviors for video captions, audio cues, and common web-page audio
barriers, including scenario tasks for complex pages and communication-heavy
interfaces.

Run with:

    python -m tests.evals \
        copilot/gpt-5-mini \
        deterministic/audio_alternatives.py

    python -m tests.evals \
        copilot/claude-sonnet-4.5 \
        deterministic/audio_alternatives.py
"""

from __future__ import annotations

from inspect_ai import Task, task

from tests.evals._context import load_eval_consideration_context
from tests.evals.deterministic._consideration import build_consideration_deterministic_task

CONSIDERATION = load_eval_consideration_context("audio-alternatives")


@task
def at_categories() -> Task:
    return build_consideration_deterministic_task(
        consideration_slug="audio-alternatives",
        section_slug="at_categories",
        task_name_suffix="",
        prompt=(
            "Name the assistive technology categories described in this "
            "consideration. Use a short bullet list and keep each bullet to one "
            "line."
        ),
        consideration_prompt=CONSIDERATION,
    )()


@task
def assistive_technologies() -> Task:
    return build_consideration_deterministic_task(
        consideration_slug="audio-alternatives",
        section_slug="assistive_technologies",
        task_name_suffix="",
        prompt=(
            "List the named assistive technologies described in this "
            "consideration's Assistive Technologies section. Use the specific "
            "technology names from the consideration, not just broad categories. "
            "Use a short bullet list and keep each bullet to one line."
        ),
        consideration_prompt=CONSIDERATION,
    )()


@task
def exploration_strategies() -> Task:
    return build_consideration_deterministic_task(
        consideration_slug="audio-alternatives",
        section_slug="exploration_strategies",
        task_name_suffix="",
        prompt=(
            "List the consideration-specific exploration strategies this deaf "
            "evaluation covers. Exclude inherited conditional shared "
            "strategies. Use a short bullet list and keep each bullet to one "
            "line."
        ),
        consideration_prompt=CONSIDERATION,
    )()


@task
def interaction_contexts() -> Task:
    return build_consideration_deterministic_task(
        consideration_slug="audio-alternatives",
        section_slug="interaction_contexts",
        task_name_suffix="",
        prompt=(
            "List the scope-specific interaction contexts defined for this "
            "consideration. Exclude the New/Expert shared contexts. "
            "Use a short bullet list and keep each bullet to one line."
        ),
        consideration_prompt=CONSIDERATION,
    )()


@task
def shared_strategies() -> Task:
    return build_consideration_deterministic_task(
        consideration_slug="audio-alternatives",
        section_slug="shared_strategies",
        task_name_suffix="",
        prompt=(
            "List the inherited conditional shared exploration strategies that "
            "apply to this deaf consideration, then list excluded shared strategies in a "
            "separate section. Only report exclusions that are explicitly present in the "
            "consideration file's shared inheritance metadata or inline shared content. If "
            "there are no excluded shared strategies, write 'None' under the excluded "
            "section. Do not infer exclusions from the disability description. Use a short "
            "bullet list and keep each bullet to one line."
        ),
        consideration_prompt=CONSIDERATION,
    )()


@task
def behavior_interaction_video_captions() -> Task:
    return build_consideration_deterministic_task(
        consideration_slug="audio-alternatives",
        section_slug="behavior_interaction_video_captions",
        task_name_suffix="",
        prompt=(
            "A user who cannot rely on hearing starts a video that appears to include important "
            "spoken information. List the documented access options to check "
            "first to decide whether they can follow it without hearing. Use "
            "a short bullet list and keep each bullet to one line."
        ),
        consideration_prompt=CONSIDERATION,
    )()


@task
def behavior_feedback_audio_alerts() -> Task:
    return build_consideration_deterministic_task(
        consideration_slug="audio-alternatives",
        section_slug="behavior_feedback_audio_alerts",
        task_name_suffix="",
        prompt=(
            "A user who cannot rely on hearing performs an action on a web page and wants to know "
            "whether anything happened, even if the page normally uses sound "
            "for feedback. List the on-screen access cues to verify. "
            "Use a short bullet list and keep each bullet to one line."
        ),
        consideration_prompt=CONSIDERATION,
    )()


@task
def behavior_review_web_page_audio_barriers() -> Task:
    return build_consideration_deterministic_task(
        consideration_slug="audio-alternatives",
        section_slug="behavior_review_web_page_audio_barriers",
        task_name_suffix="",
        prompt=(
            "A user who cannot rely on hearing is interacting with a typical web page and wants to "
            "spot features that may break because they depend on hearing. "
            "List the access barriers and requirements to check. Use a "
            "short bullet list and keep each bullet to one line."
        ),
        consideration_prompt=CONSIDERATION,
    )()


@task
def behavior_review_complex_page() -> Task:
    return build_consideration_deterministic_task(
        consideration_slug="audio-alternatives",
        section_slug="behavior_review_complex_page",
        task_name_suffix="",
        prompt=(
            "A user who cannot rely on hearing is reviewing a complex web page that includes a "
            "hero video, a live webinar signup panel, notification toasts, "
            "an audio-based onboarding clip, a support section that promotes "
            "calling a phone number, and a form whose success and error "
            "feedback may include sounds. List the documented access options to "
            "check first to determine whether the page remains usable without "
            "hearing. Use a short bullet list and keep each bullet to one "
            "line."
        ),
        consideration_prompt=CONSIDERATION,
    )()


@task
def behavior_review_communication_heavy_page() -> Task:
    return build_consideration_deterministic_task(
        consideration_slug="audio-alternatives",
        section_slug="behavior_review_communication_heavy_page",
        task_name_suffix="",
        prompt=(
            "A user who cannot rely on hearing is reviewing a communication-heavy interface for "
            "joining video meetings, receiving live announcements, and "
            "contacting support. The page includes a meeting preview, live "
            "caption controls, participant join alerts, a request-an-"
            "interpreter option, and phone-first support pathways. List the "
            "access cues and requirements to check to verify the "
            "experience works without hearing. Use a short bullet list and "
            "keep each bullet to one line."
        ),
        consideration_prompt=CONSIDERATION,
    )()
