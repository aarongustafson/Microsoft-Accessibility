"""Deterministic eval: hidden answer-key grading for the hard-of-hearing consideration.

This task uses a deterministic scorer backed by a hidden answer key in
`Sample.metadata["answer_key"]`. The key is not sent to the model; only the prompt and
system context are.

These checks cover stable, factual consideration content that should reliably be
triggered by the evaluation context, including assistive-technology categories,
named assistive technologies, consideration-specific exploration strategies,
scope-specific interaction contexts, inherited shared strategies, and
bounded behaviors for audio clarity, captions as supplement, and unreliable
audio cues, including scenario tasks for complex pages and communication-heavy
interfaces.

Run with:

    python -m tests.evals \
        copilot/gpt-5-mini \
        deterministic/hearing_support.py

    python -m tests.evals \
        copilot/claude-sonnet-4.5 \
        deterministic/hearing_support.py
"""

from __future__ import annotations

from inspect_ai import Task, task

from tests.evals._context import load_eval_consideration_context
from tests.evals.deterministic._consideration import build_consideration_deterministic_task

CONSIDERATION = load_eval_consideration_context("hearing-support")


@task
def at_categories() -> Task:
    return build_consideration_deterministic_task(
        consideration_slug="hearing_support",
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
        consideration_slug="hearing_support",
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
        consideration_slug="hearing_support",
        section_slug="exploration_strategies",
        task_name_suffix="",
        prompt=(
            "List the consideration-specific exploration strategies this hard-of-hearing "
            "evaluation covers. Exclude inherited conditional shared "
            "strategies. Use a short bullet list and keep each bullet to one "
            "line."
        ),
        consideration_prompt=CONSIDERATION,
    )()


@task
def interaction_contexts() -> Task:
    return build_consideration_deterministic_task(
        consideration_slug="hearing_support",
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
        consideration_slug="hearing_support",
        section_slug="shared_strategies",
        task_name_suffix="",
        prompt=(
            "List the inherited conditional shared exploration strategies that "
            "apply to this hard-of-hearing consideration, then list excluded shared "
            "strategies in a separate section. Only report exclusions that are explicitly "
            "present in the consideration file's shared inheritance metadata or inline "
            "shared content. If there are no excluded shared strategies, write 'None' "
            "under the excluded section. Do not infer exclusions from the disability "
            "description. Use a short bullet list and keep each bullet to one line."
        ),
        consideration_prompt=CONSIDERATION,
    )()


@task
def behavior_media_audio_clarity() -> Task:
    return build_consideration_deterministic_task(
        consideration_slug="hearing_support",
        section_slug="behavior_media_audio_clarity",
        task_name_suffix="",
        prompt=(
            "A user needing supplementary cues or audio clarity starts media with spoken content and wants "
            "to decide whether the audio will be usable in their current "
            "listening conditions. List the documented access options to check "
            "first. Use a short bullet list and keep each bullet to one line."
        ),
        consideration_prompt=CONSIDERATION,
    )()


@task
def behavior_captions_as_supplement() -> Task:
    return build_consideration_deterministic_task(
        consideration_slug="hearing_support",
        section_slug="behavior_captions_as_supplement",
        task_name_suffix="",
        prompt=(
            "A user needing supplementary cues or audio clarity can hear some of a video or call but keeps "
            "missing words. List the access checks relevant to this task to "
            "use captions as a supplement rather than as the only channel. Use "
            "a short bullet list and keep each bullet to one line."
        ),
        consideration_prompt=CONSIDERATION,
    )()


@task
def behavior_audio_alert_redundancy() -> Task:
    return build_consideration_deterministic_task(
        consideration_slug="hearing_support",
        section_slug="behavior_audio_alert_redundancy",
        task_name_suffix="",
        prompt=(
            "A user needing supplementary cues or audio clarity is interacting with a page where important "
            "feedback may be signaled by sound. List the access checks "
            "needed to identify important "
            "events. Use a short bullet list and keep each bullet to one line."
        ),
        consideration_prompt=CONSIDERATION,
    )()


@task
def behavior_review_complex_page() -> Task:
    return build_consideration_deterministic_task(
        consideration_slug="hearing_support",
        section_slug="behavior_review_complex_page",
        task_name_suffix="",
        prompt=(
            "A user needing supplementary cues or audio clarity is reviewing a complex web page that "
            "includes a hero video with music under speech, a webinar signup "
            "panel, notification toasts with sounds, an onboarding clip, a "
            "support area with a phone number, and a form whose success or "
            "error feedback may include audio. List the access checks "
            "needed to determine whether the page remains usable "
            "when audio is only partly reliable. Use a short bullet list and "
            "keep each bullet to one line."
        ),
        consideration_prompt=CONSIDERATION,
    )()


@task
def behavior_review_communication_heavy_page() -> Task:
    return build_consideration_deterministic_task(
        consideration_slug="hearing_support",
        section_slug="behavior_review_communication_heavy_page",
        task_name_suffix="",
        prompt=(
            "A user needing supplementary cues or audio clarity is reviewing a communication-heavy "
            "interface for meetings, live announcements, and support. The "
            "page includes a meeting preview, call volume and noise "
            "suppression controls, live caption controls, participant join "
            "alerts, and phone-first support pathways. List the access cues "
            "and requirements to verify the experience works "
            "when audio is available but not fully reliable. Use a short "
            "bullet list and keep each bullet to one line."
        ),
        consideration_prompt=CONSIDERATION,
    )()