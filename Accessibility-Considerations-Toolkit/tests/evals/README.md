# LLM evaluation suite

These tests verify that the instruction files in this repository (considerations, heuristics,
methodology, standards) actually transfer accessibility subject-matter expertise to an LLM. The
harness is [inspect-ai](https://inspect.aisi.org.uk/), driven from Python.

Authenticated LLM evaluations are **manually invoked**, not run on CI pull requests. Offline
structural, provenance, fixture, loader and consistency tests are configured in
[CI](../../../.github/workflows/act-validate.yml), subject to authorized runner availability. Each
granular model task isolates instruction artifacts and grades the model's output against
expectations rooted in the source file.

Evaluation tasks identify access considerations, possible barriers and interface requirements from
explicit circumstances. They do not simulate people, predict individual behavior from disability
labels, or assume unrelated abilities. Shared entries are conditional reference strategies, not a
default person's capabilities.

## Status

The maintained suite covers all 12 elaborated considerations and photosensitive-stub handling.
Heuristic lens evaluations span the 10 heuristics; methodology and negative evaluations cover
selected principles and scenarios. Coverage is not certification of every consideration, device,
standard or model. A passing offline suite does not demonstrate LLM behavior.

| Category      | Example artifact                | Module                                     |
| ------------- | ------------------------------- | ------------------------------------------ |
| Consideration | `4.2.2-visual-adaptation.md`    | `considerations/eval_visual_adaptation.py` |
| Heuristic     | Heuristic 1 + severity scale    | `heuristics/eval_heuristic_1.py`           |
| Methodology   | `confidence-gate.md`            | `methodology/eval_confidence_gate.py`      |
| Consistency   | Shared propagation (low-vision) | `consistency/test_shared_propagation.py`   |
| Negative      | Clause 4.2.11 refusal           | `negative/eval_privacy_clause.py`          |

## Setup

Follow the [Windows or macOS/Linux setup](../../README.md#development-and-offline-validation) from
the resource directory. Use Python 3.12 or 3.14, the offline CI matrix. Reading content requires no
development dependencies.

All models route through the GitHub Copilot SDK provider. No API keys needed.

### Copilot SDK setup

One-time setup:

1. Install Node.js 22 or later.
2. Install the Copilot CLI globally:

   ```pwsh
   npm install -g @github/copilot
   ```

3. Authenticate with `copilot login`. A Copilot entitlement and access to the selected models are
   required. Do not commit authentication state.
4. Verify `copilot --version` and select models available to your account. CLI and SDK versions
   evolve together; use the declared development dependencies.

Run evals via the local runner:

```pwsh
python tests\evals\run_copilot_eval.py copilot/gpt-5-mini smoke:smoke
python tests\evals\run_copilot_eval.py copilot/claude-sonnet-4.5 smoke_copilot:smoke_copilot
python tests\evals\run_copilot_eval.py copilot/gpt-5-mini tests/evals/considerations/eval_visual_adaptation.py@at_recall
```

### Hidden answer-key evals ("pop quiz")

Use `answer_key_scorer()` for deterministic checks where the expected answer must stay out of the
model prompt.

These are a good fit for stable consideration facts or bounded access-strategy checks that should
reliably be triggered by the prompt, such as:

- assistive technology categories for a consideration
- distinct interaction contexts and access requirements the evaluator must consider
- consideration-specific exploration strategies the evaluator must keep in scope
- other closed-set recall where an answer key is clearer than LLM judging
- stable scenario prompts with a bounded set of documented access options or requirements

**Per-consideration convention:**

- Put deterministic consideration modules in `tests/evals/deterministic/<alias>.py`.
- Use one task per section or bounded behavior, with names of the form
  `<alias>_<section>_deterministic`.
- Prefer the shared builder in `tests/evals/deterministic/_consideration.py` so task shape, naming,
  and hidden-answer-key wiring stay consistent.
- Keep answer keys in `tests/evals/answer_keys/<alias>.json`, with one top-level key per section
  slug.
- Keep recall slugs aligned with canonical section names such as `at_categories` or
  `interaction_contexts`.
- Name behavior slugs as `behavior_<mode>_<target>` so future tasks sort and group predictably, for
  example `behavior_navigation_button`, `behavior_interaction_form`, or
  `behavior_recovery_form_errors`.

**Deterministic coverage examples (not exhaustive):**

- `visual_adaptation` covers `at_categories`, `contexts`, `exploration_strategies`, and
  `interaction_contexts`.
- `nonvisual_access` covers `at_categories`, `assistive_technologies`, `exploration_strategies`,
  `interaction_contexts`, `behavior_navigation_button`, `behavior_navigation_main_content`,
  `behavior_interaction_form`, and `behavior_recovery_form_errors`.
- `alternatives_to_colour_cues` covers `at_categories`, `assistive_technologies`,
  `exploration_strategies`, `interaction_contexts`, `behavior_interpretation_state_feedback`, and
  `behavior_interaction_affordance`.
- `keyboard_interaction`, `audio_alternatives`, `hearing_support`, `alternatives_to_speech_input`,
  and `voice_control` each cover `at_categories`, `exploration_strategies`, `interaction_contexts`,
  and `shared_strategies`.

- `pointer_interaction`, `memory_attention_and_executive_function`, `language_and_communication`,
  and `numeracy_and_numeric_information` also have maintained deterministic modules and answer-key
  registries.
- `photosensitive_seizure_prevention` remains a stub, with a refusal/non-fabrication model task
  rather than invented closed-set recall facts.

**Answer key organization:**

- Store answer keys in per-module registries such as `answer_keys/visual_adaptation.json`, using one
  top-level key per section slug (for example, `at_categories`).
- Use `load_answer_key()` with a name like `visual_adaptation.at_categories`.
  `load_answer_key_from_file()` remains as a compatibility wrapper for the shared builder.
- Store the loaded key in `Sample.metadata["answer_key"]`.
- Keep `Sample.target` for plain string or list targets only; `inspect-ai` validates that field and
  will reject arbitrary dicts.
- The default pass threshold is `0.8`, so responses pass at 80% weighted coverage or better.

**Behavior-task leniency:**

- For `behavior_*` tasks, expect slight wording differences across supported models even when the
  underlying consideration behavior is correct.
- Make behavior answer keys more alias-rich than fact-recall keys. Include alternate phrasings
  observed from both current target models instead of overfitting to one exact wording.
- Before treating a behavior-task answer key as stable, run that task against both current supported
  models: `copilot/gpt-5-mini` and `copilot/claude-sonnet-4.5`.
- Add aliases for equivalent phrasing differences that preserve the same consideration behavior.
  Keep `forbidden_items` focused on genuinely wrong strategies, not harmless wording variation.

**Example answer key registry file** (`answer_keys/visual_adaptation.json`):

```json
{
  "at_categories": {
    "threshold": 0.8,
    "items": [
      {"id": "browser_zoom", "matches": ["browser zoom", "page zoom"]},
      {"id": "magnifier", "matches": ["screen magnifier", "zoomtext"]},
      {"id": "high_contrast", "matches": ["high contrast", "forced colors"]}
    ]
  }
}
```

**Example task using the loader:**

```python
from tests.evals._context import load_eval_consideration_context
from tests.evals.deterministic._consideration import build_consideration_deterministic_task

CONSIDERATION = load_eval_consideration_context("visual-adaptation")


@task
def at_categories_deterministic() -> Task:
  return build_consideration_deterministic_task(
    consideration_slug="visual_adaptation",
    section_slug="at_categories",
    prompt="Name the assistive technology categories described in this consideration.",
    consideration_prompt=CONSIDERATION,
  )()
```

See `deterministic/visual_adaptation.py` for the complete working example and
`answer_keys/visual_adaptation.json` for the corresponding answer-key registry.

**Safety note.** The provider opens a tool-less, single-turn session per generation: `tools=[]`,
`available_tools=[]`, `mcp_servers={}`, `enable_config_discovery=False`, plus a permission handler
that rejects all requests. The model under test cannot read repository files, run shell commands, or
load `.github/copilot-instructions.md`. This boundary is what makes it acceptable to run benchmarks
whose answer keys live in the same repository.

To target a different model or provider, override these env vars:

| Variable                | Purpose                                                    |
| ----------------------- | ---------------------------------------------------------- |
| `EVAL_MODEL_PRIMARY`    | Model under test (default `copilot/gpt-5-mini`)            |
| `EVAL_MODEL_SECONDARY`  | Mid-tier model (default `copilot/claude-haiku-4.5`)        |
| `EVAL_MODEL_CLAUDE`     | Claude model (default `copilot/claude-sonnet-4.5`)         |
| `EVAL_JUDGE_MODEL`      | Judge model for rubric scoring                             |
| `EVAL_RUBRIC_THRESHOLD` | Pass threshold (default 0.8)                               |
| `EVAL_QUICK`            | `1` to subset parameterized samples                        |
| `COPILOT_CLI_PATH`      | Path to the `copilot` binary (default: resolved from PATH) |

## Running

Shortest launcher (Copilot models):

```pwsh
python -m tests.evals [--consideration_context_mode MODE] [--heuristic_context_mode MODE] [--severity_expectation_mode MODE] [--quick] [model] [task ...]
```

`consideration_context_mode` options:

- `single` — target consideration only
- `all` — full target consideration plus compact supporting-consideration catalog (default
  multi-consideration mode)
- `medium` — full target consideration plus medium supporting-consideration briefs

All three modes prepend the complete licensing, responsible-consideration-use, and
consideration-interpretation methodology documents through `load_eval_consideration_context()`.
Focused heuristic evaluators use the same safeguard loader in slim and full modes, and
`sub_agents/_loaders.py` prepends it to every per-heuristic sub-agent system prompt. Low-level
`load_consideration_by_alias()` calls return raw consideration content; custom prompt builders must
wrap that content with `with_required_consideration_safeguards()` or include the three documents
explicitly. Deterministic, negative and smoke tasks also use safeguarded evaluation contexts.

`heuristic_context_mode` options (for `heuristics/eval_heuristics_lens.py`):

- `slim` — force slim context injection (`EVAL_FULL_CONTEXT=0`)
- `full` — force full heuristics + full consideration injection (`EVAL_FULL_CONTEXT=1`)

`severity_expectation_mode` options (for `heuristics/eval_severity_scale.py`):

- `strict` — authored expected windows
- `benchmark` — widened per-consideration windows by ±1

`--quick`:

- sets `EVAL_QUICK=1` for fast subset runs

If a task is a module path without `@task_name` (for example,
`considerations/eval_visual_adaptation.py`), the runner executes all tasks in that module.

Pass multiple task specs to evaluate a list of files in one run. The legacy `all` group combines
consideration evals with selected deterministic, negative and heuristic/methodology tasks; it is not
the entire suite. `all-deterministic` runs the original eight-consideration group; pass the
cognitive and limited-reach module paths explicitly for additional coverage. `all-negatives` and
`all-other` are selected legacy subsets. Use `all-heuristics` for heuristic lens + severity scale
evals, and `all-methodology` for every methodology eval module. Use `all-considerations` to run
every elaborated consideration's non-deterministic eval module.

Examples:

```pwsh
python -m tests.evals
python -m tests.evals copilot/gpt-5-mini considerations/eval_visual_adaptation.py
python -m tests.evals copilot/gpt-5-mini deterministic/visual_adaptation.py
python -m tests.evals copilot/gpt-5-mini considerations/eval_visual_adaptation.py heuristics/eval_heuristic_1.py
python -m tests.evals copilot/gpt-5-mini all-deterministic
python -m tests.evals copilot/gpt-5-mini all-negatives
python -m tests.evals copilot/gpt-5-mini all-other
python -m tests.evals copilot/gpt-5-mini all-heuristics
python -m tests.evals copilot/gpt-5-mini all-methodology
python -m tests.evals copilot/gpt-5-mini all-considerations
python -m tests.evals copilot/gpt-5-mini heuristics/eval_heuristics_lens.py
python -m tests.evals --quick copilot/gpt-5-mini heuristics/eval_heuristics_lens.py
python -m tests.evals --heuristic_context_mode slim copilot/gpt-5-mini heuristics/eval_heuristics_lens.py
python -m tests.evals --heuristic_context_mode full copilot/gpt-5-mini heuristics/eval_heuristics_lens.py
python -m tests.evals --quick --heuristic_context_mode full copilot/gpt-5-mini heuristics/eval_heuristics_lens.py
python -m tests.evals copilot/gpt-5-mini heuristics/eval_severity_scale.py
python -m tests.evals copilot/gpt-5-mini heuristics/eval_severity_scale.py@severity_scale_assignment
python -m tests.evals copilot/gpt-5-mini heuristics/eval_severity_scale.py@severity_consideration_variance
python -m tests.evals --severity_expectation_mode strict copilot/gpt-5-mini heuristics/eval_severity_scale.py
python -m tests.evals --severity_expectation_mode benchmark copilot/gpt-5-mini heuristics/eval_severity_scale.py
python -m tests.evals copilot/gpt-5-mini all
python -m tests.evals copilot/gpt-5-mini smoke:smoke
python -m tests.evals --consideration_context_mode all copilot/gpt-5-mini considerations/eval_visual_adaptation.py@at_recall
python -m tests.evals --consideration_context_mode medium copilot/gpt-5-mini considerations/eval_visual_adaptation.py@at_recall
python -m tests.evals copilot/claude-sonnet-4.5 considerations/eval_visual_adaptation.py@at_recall
python -m tests.evals copilot/claude-sonnet-4.5 deterministic/visual_adaptation.py
python -m tests.evals copilot/claude-sonnet-4.5 tests/evals/considerations/eval_visual_adaptation.py@at_recall
```

All elaborated consideration evals (Phase 2.5a):

**PowerShell:**

```pwsh
python -m tests.evals copilot/gpt-5-mini `
  considerations/eval_nonvisual_access.py `
  considerations/eval_alternatives_to_colour_cues.py `
  considerations/eval_audio_alternatives.py `
  considerations/eval_hearing_support.py `
  considerations/eval_alternatives_to_speech_input.py `
  considerations/eval_keyboard_interaction.py `
  considerations/eval_voice_control.py
```

**Bash:**

```bash
python -m tests.evals copilot/gpt-5-mini \
  considerations/eval_nonvisual_access.py \
  considerations/eval_alternatives_to_colour_cues.py \
  considerations/eval_audio_alternatives.py \
  considerations/eval_hearing_support.py \
  considerations/eval_alternatives_to_speech_input.py \
  considerations/eval_keyboard_interaction.py \
  considerations/eval_voice_control.py
```

Smoke test (one Sample, fastest sanity check):

```pwsh
python -m inspect_ai eval tests/evals/smoke.py --model copilot/gpt-5-mini
```

Legacy combined task group (not every LLM task):

```pwsh
python -m tests.evals copilot/gpt-5-mini all
```

Legacy eight-consideration deterministically scored model subset:

```pwsh
python -m tests.evals copilot/gpt-5-mini all-deterministic
```

Selected heuristic/methodology subset:

```pwsh
python -m tests.evals copilot/gpt-5-mini all-other
```

Heuristic-only subset (heuristic lens + severity scale; excludes `eval_heuristic_1.py`):

```pwsh
python -m tests.evals copilot/gpt-5-mini all-heuristics
```

All methodology evals:

```pwsh
python -m tests.evals copilot/gpt-5-mini all-methodology
```

All elaborated considerations, non-deterministic evals only:

```pwsh
python -m tests.evals copilot/gpt-5-mini all-considerations
```

Heuristic lens matrix eval (default slim context):

```pwsh
python -m tests.evals copilot/gpt-5-mini heuristics/eval_heuristics_lens.py
```

Heuristic lens matrix eval with explicit runner mode (slim or full):

```pwsh
python -m tests.evals --heuristic_context_mode slim copilot/gpt-5-mini heuristics/eval_heuristics_lens.py
python -m tests.evals --heuristic_context_mode full copilot/gpt-5-mini heuristics/eval_heuristics_lens.py
```

Heuristic lens matrix eval in quick mode (10 cells):

```pwsh
python -m tests.evals --quick copilot/gpt-5-mini heuristics/eval_heuristics_lens.py
```

Heuristic lens matrix eval in full-context mode:

```pwsh
$env:EVAL_FULL_CONTEXT = "1"
python -m tests.evals copilot/gpt-5-mini heuristics/eval_heuristics_lens.py
```

Heuristic lens matrix eval with quick + full-context mode:

```pwsh
python -m tests.evals --quick --heuristic_context_mode full copilot/gpt-5-mini heuristics/eval_heuristics_lens.py
```

Severity-scale evals (both `severity_scale_assignment` and `severity_consideration_variance`):

```pwsh
python -m tests.evals copilot/gpt-5-mini heuristics/eval_severity_scale.py
```

Single severity task:

```pwsh
python -m tests.evals copilot/gpt-5-mini heuristics/eval_severity_scale.py@severity_scale_assignment
python -m tests.evals copilot/gpt-5-mini heuristics/eval_severity_scale.py@severity_consideration_variance
```

Severity-scale evals in benchmark expectation mode (widens per-consideration windows by ±1):

```pwsh
python -m tests.evals --severity_expectation_mode benchmark copilot/gpt-5-mini heuristics/eval_severity_scale.py
```

Severity-scale evals in strict expectation mode:

```pwsh
python -m tests.evals --severity_expectation_mode strict copilot/gpt-5-mini heuristics/eval_severity_scale.py
```

Env-var equivalents (still supported for compatibility):

```pwsh
$env:EVAL_QUICK = "1"
$env:EVAL_FULL_CONTEXT = "1"
$env:EVAL_SEVERITY_EXPECTATION_MODE = "benchmark"
```

Severity-scale evals via Copilot/Claude:

```pwsh
python -m tests.evals copilot/claude-sonnet-4.5 heuristics/eval_severity_scale.py
```

Equivalent explicit file list:

```pwsh
python -m tests.evals copilot/gpt-5-mini `
  considerations/eval_visual_adaptation.py `
  deterministic/visual_adaptation.py `
  heuristics/eval_heuristic_1.py `
  methodology/eval_confidence_gate.py `
  negative/eval_privacy_clause.py
```

Single sub-task:

```pwsh
python -m inspect_ai eval tests/evals/considerations/eval_visual_adaptation.py@at_recall `
  --model copilot/gpt-5-mini
```

Unified runner (works in both modes):

```pwsh
python -m tests.evals copilot/gpt-5-mini considerations/eval_visual_adaptation.py@at_recall
python -m tests.evals copilot/claude-sonnet-4.5 considerations/eval_visual_adaptation.py@at_recall
python -m tests.evals copilot/gpt-5-mini deterministic/visual_adaptation.py
python -m tests.evals copilot/claude-sonnet-4.5 deterministic/visual_adaptation.py
```

Low-vision consideration eval with all-consideration background context:

```pwsh
python -m tests.evals --consideration_context_mode all `
  copilot/gpt-5-mini `
  considerations/eval_visual_adaptation.py@at_recall
```

Low-vision consideration eval with medium supporting briefs:

```pwsh
python -m tests.evals --consideration_context_mode medium `
  copilot/gpt-5-mini `
  considerations/eval_visual_adaptation.py@at_recall
```

Offline validation (no LLM, no authentication):

```pwsh
python tests/validate_structure.py
python -m pytest tests/validate_structure.py tests -q
```

## Source modes

`CONSIDERATION_SOURCE=md` (default) loads the authoring Markdown, including inline shared copies.
`CONSIDERATION_SOURCE=schema` loads generated YAML and merges applicable shared items for elaborated
considerations only. Stubs remain minimal. Set the source before running a task; invalid values are
reported as errors. Single, compact and medium supporting contexts all follow the selected source
mode, with source-partitioned caches. Raw loaders remain raw.

Generated instances use `*.consideration.yaml`, `evaluation.scope`, `evaluation.access_constraints`,
`evaluation.contexts`, `interaction_contexts`, `shared_excludes` and `from_shared`. Elaborated
Markdown uses the `## Evaluation Considerations` heading. Schema validation uses
`consideration.schema.json` and `consideration-stub.schema.json`.

Clause numbers `4.2.7` and `4.2.10` identify multiple documents. Markdown and schema selection
reject these ambiguous parent numbers; select a unique alias such as `keyboard-interaction` or
`language-and-communication`. Missing references remain errors. Only a missing consideration schema
file falls back to Markdown; missing shared files, required methodology or ambiguous selections are
not swallowed.

```sh
CONSIDERATION_SOURCE=schema python -m pytest tests/test_schema_loading.py tests/test_prompt_safeguards.py tests/evals/sub_agents/test_per_heuristic_loading.py -q
```

In PowerShell, set `$env:CONSIDERATION_SOURCE = "schema"` first and remove it after the command. The
[PowerShell wrappers](../../scripts/) also accept a YAML consideration selector where supported.
Wrappers preserve an explicit `CONSIDERATION_SOURCE` unless a YAML selector requests schema mode,
reject ambiguous clause selectors and missing YAML paths, and restore the environment. Their dry-run
mode prints commands without starting a model session; the wrappers locate either a Windows or POSIX
virtual environment and create the ignored log directory on first use.

## Data flow and artifacts

Model evaluations send assembled reference content, task examples and image attachments to the
selected Copilot/model service. Rubric judging also sends the model response and rubric to the
judge. Tool-less sessions prevent repository/tool access, not disclosure of supplied prompts. Use
only approved, redistributable examples; do not supply private customer data, credentials or
identifying screenshots. See the [original synthetic fixtures](../fixtures/images/README.md).

Inspect logs can contain prompts, outputs, rubric results, model identifiers and usage data. Keep
`logs/` and local authentication/environment files out of source control and public bundles. Delete
specific unneeded log files deliberately; do not publish a log just because its eval passed.
Generation and judging can consume paid quota and incur cost; start with one task or `--quick`.
Record Python, dependency, CLI and model versions with results, since dependencies are not locked.

## Viewing `.eval` files

Inspect writes eval results to binary `.eval` log files (typically in `logs/`). Use the commands
below to inspect them.

Interactive viewer (browse all logs in `logs/`):

```pwsh
python -m inspect_ai view start --log-dir logs
```

List available logs:

```pwsh
python -m inspect_ai log list --log-dir logs
```

Print one `.eval` file as JSON in the terminal:

```pwsh
python -m inspect_ai log dump logs/<your-log-file>.eval
```

Convert `.eval` to `.json` for sharing or offline inspection:

```pwsh
python -m inspect_ai log convert logs/<your-log-file>.eval --to json
```

## Cost note

Each rubric scorer issues one judge-model call per sample. The pilot runs ~10 samples plus a judge
call per sample, so a full pilot pass is roughly 20 model calls. GitHub Models' free tier
rate-limits aggressively; if you hit limits, run modules one at a time or set `EVAL_QUICK=1`.

## Related

- [tests/validate_structure.py](../validate_structure.py) — fast, schema-level validation of the
  markdown files. Always run this before committing changes to `considerations/` or `heuristics/`.
