---
name: consideration-to-schema
description: "Create or update Accessibility Considerations Toolkit (ACT) YAML from shared guidance and access-topic Markdown. Use when converting, serializing, migrating, synchronizing, refreshing, batching, or updating generated consideration schemas after Markdown sources change."
argument-hint: "<consideration-selector> [<consideration-selector> ...] | all"
user-invocable: true
disable-model-invocation: false
---

# Create or Update Consideration YAML Schema

Create or synchronize compact YAML representations of shared accessibility guidance and access-topic
Markdown. Markdown under `considerations/` is the source of truth; write only matching outputs under
`schemas/`. Never create or update Markdown from schema YAML. Identify possible interface barriers
and requirements, not a simulated person or community profile.

Shared markers are the italic text `(from shared)`, written as `_(from shared)_` by the formatter.
Accept equivalent `*(from shared)*` syntax when reading existing sources. All shared-entry
exclusions below apply to both spellings.

## Resource location and working directory

This skill applies only to `Accessibility-Considerations-Toolkit`. Resolve that resource as
`../../../Accessibility-Considerations-Toolkit` relative to this skill's directory. All paths and
commands below are relative to `Accessibility-Considerations-Toolkit`. From the monorepo root, first
run `cd Accessibility-Considerations-Toolkit`. Do not create `considerations/` or `schemas/` at the
monorepo root or in another project.

## Select considerations

Accept exactly one of these invocation forms:

- **Single**: one selector, such as `shared`, `keyboard-interaction`, `4.2.7-keyboard-interaction`,
  or `considerations/4.2.7-keyboard-interaction.md`.
- **List**: two or more selectors separated by spaces or commas.
- **All**: the literal selector `all`.

Discover sources from the current `considerations/` directory, not from files in `schemas/`:

1. Enumerate `considerations/*.md` dynamically so future consideration files are considered.
2. Include `considerations/_shared-considerations.md` when its frontmatter has `type: shared`.
   Exclude any other file whose name begins with `_`.
3. Include a regular consideration only when its frontmatter defines `clause`, `title`, `alias`, and
   `status`; ignore supporting Markdown such as license or source-note files.
4. Resolve `shared`, `_shared-considerations`, and its path or filename to
   `considerations/_shared-considerations.md`. Resolve topic selectors against relative path,
   filename, filename without `.md`, alias, or clause. Matching is case-insensitive after trimming.
   Clause-only selectors with multiple matches must report ambiguity rather than select one.
5. Reject ambiguous selectors and report their candidate paths. Report unmatched selectors; do not
   infer a source from an existing schema filename.
6. Deduplicate resolved sources while preserving the user's selector order. For `all`, process
   shared guidance first, then every discovered consideration in filename order.

Map `considerations/_shared-considerations.md` to `schemas/_shared-considerations.yaml`. For each
regular document, `considerations/<clause>-<alias>.md` maps to
`schemas/<clause>-<alias>.consideration.yaml`. Use the actual EN parent clause in filename and
metadata. Multiple documents share 4.2.7 or 4.2.10; their aliases disambiguate them.

## Process a batch

Apply the create-or-synchronize procedure independently to every selected source:

1. Read the Markdown source and derive its output path.
2. Create the YAML if the derived output does not exist; otherwise synchronize it.
3. Run the applicable shared or consideration self-check and JSON Schema validation when a matching
   JSON Schema exists.
4. If one source fails conversion or validation, record the failure and continue with the remaining
   sources. Do not leave a knowingly invalid output in place.
5. Finish with a summary grouped as `created`, `updated`, `unchanged`, and `failed`, listing source
   and output paths for each item.

Do not modify, delete, or use orphaned schema YAML files to generate Markdown. Batch direction is
always `considerations/*.md` → `schemas/*.yaml`.

## Quality gates

Apply these gates to every selected source. A failed gate marks that item `failed`; do not claim it
as created or updated.

### 1. Preflight source identity

- Run `python tests/validate_structure.py` before conversion and classify its errors. Invalid source
  metadata, section structure, provenance, notices, or access framing blocks conversion. Missing or
  stale generated YAML is a conversion target, not a reason to reject an otherwise valid Markdown
  source. Report unrelated failures rather than suppressing them; run full validation again after
  conversion.
- Parse YAML frontmatter and Markdown structure; do not extract fields with ad hoc whole-file string
  replacement.
- For a regular consideration filename, require `<artifact-clause>-<alias>.md`. The filename alias
  must equal frontmatter `alias`.
- Require the filename clause to equal frontmatter `clause`.
- Reject duplicate aliases or duplicate derived output paths before editing any batch item.

### 2. Source fidelity and completeness

- Copy `clause`, `title`, `alias`, `status`, and `shared_excludes` exactly from frontmatter. Use the
  unique access-topic alias, not the shared clause alone, to select a document.
- Copy `fps_statement` exactly from the requirement paragraph after the H1; do not summarize or
  combine it with explanatory consideration prose.
- Every non-shared source entry must be represented exactly once in its output section. Compare
  source and output counts for assistive technology H3s, consideration-specific strategy H3s,
  interaction-context H3s, learning items, and heuristic H3s.
- Exclude every H3 marked `*(from shared)*`. Do not exclude unmarked consideration-specific content
  merely because it resembles shared content.
- Preserve source order within each output section. Never invent an AT, strategy, interaction
  context, expectation, learning fact, or heuristic claim that is not supported by the source.
- Preserve canonical accessibility and standards terminology verbatim when the source uses it. Do
  not replace terms such as `reflow`, `accessible name`, `focus order`, `forced colours`, or
  `captions` with generic descriptions, near-synonyms, or newly coined labels.
- Preserve distinctions the source makes between related terms. For example, browser zoom can
  trigger `reflow`, while screen magnification enlarges rendered content without triggering reflow;
  compression must not merge or obscure those concepts.
- Preserve semantic force: negation, modality, quantifiers, comparisons, causal relationships,
  exceptions, and scope boundaries must survive compression. Never turn `no excessive decoration`
  into `decoration`, `can be hard` into `is impossible`, or `except when essential` into an
  unconditional rule.
- Preserve every source number with its unit and purpose when it defines a threshold, range,
  command, timing, platform version, or standards reference. Do not retain a number while dropping
  what it measures.
- Preserve compact contrast pairs in the same field when their meaning depends on the distinction:
  `X does A; Y does not` is preferable to two generic summaries.
- Serialize generated YAML with ASCII characters by default, even when source prose uses a visually
  similar Unicode character. Use `x` for multiplication or dimensions (`24x24`), `-` for
  hyphens/dashes, `->` for arrows, `<=`/`>=` for inequalities, three periods for an ellipsis, and
  straight ASCII quotes/apostrophes. This normalization does not alter the underlying measurement or
  claim.
- Retain non-ASCII only when it carries meaning that an ASCII replacement would lose, such as
  source-language text, an official product/person name, or a canonical term that requires the
  character. Never emit Unicode confusables merely for typography.
- For updates, preserve unaffected IDs and wording. Recompress only the complete entries affected by
  source changes; avoid unrelated cleanup or style churn.

### 3. Structural and semantic integrity

- Reject empty or whitespace-only strings. Reject empty `platforms`, `mechanisms`, `expects`,
  `contexts`, and `checklist` lists when their source section supplies values.
- Require all IDs to match `^[a-z0-9-]+$` and be unique within their section.
- In **create mode**, derive IDs consistently from current source headings. A fresh generation does
  not need to reproduce IDs from a prior or deleted artifact; judge IDs by heading alignment, local
  naming consistency, uniqueness, and resolved references.
- In **synchronize mode**, preserve existing stable IDs unless their source concept was renamed.
- Require `shared_excludes` to contain only IDs present in `schemas/_shared-considerations.yaml`.
- Require every `uses_at` value to resolve to the same output's `assistive_tech[].id`. Serialize all
  ATs named by the interaction context; use `[]` when `**Primary AT**` is `None`.
- Require every consideration `uses_strategies` value to resolve to the same output's
  consideration-specific `strategies[].id`. Filter out shared strategy names because shared behavior
  merges separately; omit `uses_strategies` when no consideration-specific value remains.
- Require exactly heuristic keys `1` through `10`, each non-empty and traceable to the matching
  source heuristic.
- Ensure the YAML schema directive matches status: `consideration.schema.json` for `elaborated`,
  `consideration-stub.schema.json` for `stub`.

### 4. Safe write and validation

- Parse the completed YAML before accepting it. Validate it against the referenced JSON Schema with
  Draft 2020-12 semantics.
- For a fidelity-only synchronization, record the output's normalized character count before editing
  and keep the final artifact at or below that count. When the repository tokenizer is available,
  also keep the final token count at or below its original value. If the caller supplies an explicit
  budget for create mode, enforce both supplied limits.
- Meet a fixed size budget by replacing generic explanation, repetition, or non-disambiguating
  examples with higher-priority atomic claims. Do not satisfy it by deleting negations, scope,
  exceptions, contrasts, measurements, canonical terms, or required source entries.
- If validation fails after an edit, repair that output or restore only the edit made during this
  run. Never leave a newly invalid file in place.
- Review the final diff. Only selected outputs may change, and synchronized outputs must not lose
  unaffected entries.
- Run `python tests/validate_structure.py` after the batch. Run `git diff --check` on changed
  outputs.
- When the shared changes, validate all consideration `shared_excludes` and strategy references
  against the updated shared, including considerations not selected in the command. Report
  downstream failures; never edit consideration Markdown to conceal them.

### 5. Final report

For each item, report its source, derived output, mode (`create` or `synchronize`), validation
result, and disposition (`created`, `updated`, `unchanged`, or `failed`). For failures, name the
violated gate and leave unrelated batch items processing normally.

When comparing a fresh create-mode result with an earlier artifact, treat ID-only differences as
expected generation variance. Report an ID difference as meaningful only when it maps an entry to
the wrong source concept, violates the current naming convention, creates a duplicate, or leaves a
reference unresolved. Compare semantic content, section coverage, terminology, and reference
integrity independently of exact historical ID spelling.

## Choose the mode

- **Create**: If a derived YAML does not exist, convert the full current consideration using all
  extraction rules below.
- **Synchronize**: If a derived YAML exists, inspect history for likely source changes, compare the
  current consideration directly with the current YAML, and update only fields affected by the
  consideration changes.

Derive matching paths from the source type and frontmatter. The shared maps to
`schemas/_shared-considerations.yaml`; for example, `considerations/4.2.7-keyboard-interaction.md`
maps to `schemas/4.2.7-keyboard-interaction.consideration.yaml`.

## Synchronize an existing YAML

Treat the current Markdown source as the source of truth. Git history is supporting evidence that
helps narrow the review; it never replaces checking the current source and output.

1. Check working-tree changes for both files with `git status --short -- <source> <output>` and
   `git diff HEAD -- <source> <output>`.
2. Find the most recent commit that changed the output with `git log -1 --format=%H -- <output>`.
3. If that commit exists, inspect source changes since it with
   `git diff <commit>..HEAD -- <source>`. Also inspect `git diff HEAD -- <source>` so staged or
   unstaged source changes are included.
4. If history is absent, incomplete, or shows no useful delta, read the full current source and
   output and compare them section by section.
5. Map each changed source section to its YAML field using the applicable shared or consideration
   extraction rules. Re-extract the complete affected entry or field, not just the changed sentence,
   so compression remains coherent.
6. Preserve YAML fields and entries unaffected by the source change. Preserve intentional
   uncommitted YAML edits unless they conflict with the current source; report conflicts instead of
   silently discarding them.
7. If an `id` changes, update every `uses_at` and `uses_strategies` reference to it. If status
   changes between `stub` and `elaborated`, rebuild the file using the correct schema rather than
   patching its old shape.
8. Run the full self-check. Validate the resulting YAML against the referenced JSON schema when a
   repository validator is available.

When history and the current source disagree, follow the current source. When meaning is ambiguous,
preserve the existing YAML wording and ask for clarification rather than inventing content.

Two consideration JSON Schemas exist:

- **`consideration.schema.json`** — for `status: elaborated` considerations (all sections required,
  fully populated)
- **`consideration-stub.schema.json`** — for `status: stub` considerations (only metadata: clause,
  title, alias, status, fps_statement)

If the source consideration has `status: stub`, produce a stub YAML referencing
`consideration-stub.schema.json` with only the metadata fields. The rest of this document covers
elaborated considerations.

## Inputs

1. **Source selection**: One selector, a selector list, or `all`
2. **Shared source**: `considerations/_shared-considerations.md`, selected explicitly or included by
   `all`
3. **Source considerations**: Markdown files discovered from `considerations/`, each with status
   `elaborated` (six H2 sections) or `stub` (H1 only)
4. **Shared output/reference**: `schemas/_shared-considerations.yaml` — strategies, interaction
   contexts, and learning guidance that merge at render time
5. **Consideration schema**: `schemas/consideration.schema.json` (elaborated) or
   `schemas/consideration-stub.schema.json` (stub)

## Shared output (`type: shared`)

Convert `considerations/_shared-considerations.md` only to `schemas/_shared-considerations.yaml`. It
is reusable supporting guidance, not a standalone topic evaluation. Do not add topic metadata,
evaluation fields, assistive technology, heuristic overrides, or a topic-schema directive.

```yaml
strategies:
  - id: <kebab-case-from-H3>
    mechanisms: [<kebab-case mechanism list>]
    context: <desktop|mobile|all>
    behavior:
      - <concise behavior fact>
    reqs:
      - <concise UI requirement>

interaction_contexts:
  - id: <kebab-case-from-H3>
    context: <desktop|mobile|all>
    uses_strategies: [<shared strategy ids>]
    behavior:
      - <concise user behavior fact>
    expects:
      - <concise expectation>

learning:
  - id: <kebab-case-topic>
    facts:
      - <concise evaluator-relevant fact>
```

Extract every H3 under `## Exploration Strategies` into `strategies`, every H3 under
`## Interaction Contexts` into `interaction_contexts`, and every labeled bullet under
`## Learning Considerations` into `learning`. Convert `**AT Mechanisms**` to `mechanisms`,
`**Device context**` to `context`, `**Preferred navigation**` to `uses_strategies`, descriptive
prose to `behavior`, `**UI Requirements**` to `reqs`, and `**Expectations**` to `expects`. Do not
serialize `## Shared Exclusions by Consideration`; each consideration's frontmatter remains
authoritative for `shared_excludes`.

Before finalizing the shared:

1. Ensure every ID is unique kebab-case.
2. Ensure every interaction context's `uses_strategies` value resolves to a shared strategy ID.
3. Ensure every `context` is `desktop`, `mobile`, or `all`.
4. Ensure `behavior`, `reqs`, `expects`, and `facts` are non-empty concise lists where applicable.
5. Validate against a dedicated shared JSON Schema if one is added to the repository later.

## Stub output (status: stub)

If the source consideration has `status: stub`, produce only:

```yaml
# yaml-language-server: $schema=consideration-stub.schema.json

clause: "<4.2.N>"
title: <EN 301 549 FPS official title>
alias: <kebab-case-short-name>
status: stub
fps_statement: <full FPS clause text from the H1 paragraph>
```

No other sections are needed. The rest of this document applies only to elaborated considerations.

## Critical rules (elaborated only)

- NEVER include content marked `*(from shared)*` in the output. Shared merges automatically at
  render.
- ALL `id` values must be kebab-case (`[a-z0-9-]+`).
- `heuristic_overrides` must have exactly 10 entries, keys `1` through `10`.
- All cross-references must resolve: each `uses_at[]` value → an `assistive_tech[].id`; each
  `uses_strategies[]` value → a consideration-specific `strategies[].id`.
- `clause` must be quoted: `"4.2.7"`.
- Condense all prose to 1–2 sentences max per field. Preserve technical specifics (key combos, AT
  names, WCAG refs). Remove hedging, repetition, and examples that don't disambiguate.

## Output structure

```yaml
# yaml-language-server: $schema=consideration.schema.json

clause: "<4.2.N>"
title: <EN 301 549 FPS official title>
alias: <kebab-case-short-name>
status: elaborated
fps_statement: <full FPS clause text from the H1 paragraph in the markdown consideration>
device_context: <desktop|mobile|all>
shared_excludes: [<shared strategy IDs irrelevant to this consideration>]

evaluation:
  scope: <access conditions and interface requirements to examine>
  access_constraints: [<dependencies excluded from this evaluation scope>]
  contexts:
    - "<Label> — <possible device, AT, or task conditions>"
  checklist:
    - "<Label>: <evaluation criterion>"

assistive_tech:
  - id: <kebab-case>
    category: <one-word category>
    platforms: [<platform list>]
    model: <how the AT works — 1–2 sentences>

strategies:
  - id: <kebab-case>
    mechanisms: [<kebab-case mechanism list>]
    behavior: <what the user does — 1–2 sentences>
    reqs: <what the UI must provide — 1–2 sentences>

interaction_contexts:
  - id: <kebab-case>
    behavior: <possible interaction conditions and strategies — 1–2 sentences>
    uses_at: [<assistive_tech ids; empty when Primary AT is None>]
    uses_strategies: [<consideration-specific strategy ids; omit when none remain>]
    expects:
      - <expectation>

learning:
  - id: <kebab-case>
    facts: <learning insight — 1–2 sentences>

heuristic_overrides:
  1: <consideration-specific lens — 2–4 sentences>
  2: ...
  ...
  10: ...
```

## Extraction rules per section

### Frontmatter → top-level fields

Copy metadata directly from frontmatter; the filename clause must match the actual parent clause,
including documents sharing 4.2.7 or 4.2.10. Copy `fps_statement` exactly from the requirement
paragraph following the H1, keeping software-scope caveats separate and explicit. Infer
`device_context` from AT platforms and strategy scope:

- All platforms or mixed → `all`
- Only desktop AT (keyboard, screen reader on desktop) → `desktop`
- Only mobile AT → `mobile`

### `## Evaluation Considerations` → `evaluation`

| Field                | Extract from                                                 | Format rule                                                         |
| -------------------- | ------------------------------------------------------------ | ------------------------------------------------------------------- |
| `scope`              | Access conditions and requirements to evaluate               | Evaluator task, not a simulated identity                            |
| `access_constraints` | Dependencies excluded from this evaluation lens              | Short tokens scoped to evaluation, not a person's overall abilities |
| `contexts`           | Possible task, device, and AT configurations                 | `"Label — relevant conditions"`; preserve overlap and variation     |
| `checklist`          | Bullet list under "For each screenshot/interface, consider:" | `"Short-label: criterion"`                                          |

### `## Assistive Technologies` → `assistive_tech`

Each H3 → one array entry. Extract:

- `id`: kebab-case derived from H3 title (e.g., "Auto-captions and live captioning" →
  `auto-captions`)
- `category`: from `**Category**` line in markdown
- `platforms`: from `**Platforms**` line → array
- `model`: condense the interaction-model paragraph to 1–2 sentences

### `## Exploration Strategies` → `strategies`

Each **consideration-specific** H3 → one array entry. SKIP any H3 ending with `*(from shared)*`.

- `id`: kebab-case from H3 title
- `mechanisms`: from `**AT Mechanisms**` → kebab-case array
- `behavior`: condense description paragraph → 1–2 sentences (what user does)
- `reqs`: condense `**UI Requirements**` → 1–2 sentences (what UI must provide)

### `## Interaction Contexts` → `interaction_contexts`

Each **consideration-specific** H3 → one array entry. SKIP `*(from shared)*` interaction contexts.

- `id`: kebab-case from H3 title
- `behavior`: condense description paragraph → 1–2 sentences
- `uses_at`: all matching `assistive_tech[].id` values listed under `**Primary AT**`, preserving
  source order; use `[]` for `None`
- `uses_strategies`: strategy IDs from `**Preferred navigation**`, preserving source order and
  filtering out every shared strategy; omit the field when no consideration-specific strategy
  remains
- `expects`: the `**Expectations**` bullet list, each condensed to one line

### `## Learning Considerations` → `learning`

Each **consideration-specific** H3 or paragraph → one array entry. SKIP `*(from shared)*`.

- `id`: kebab-case topic identifier
- `facts`: condense to 1–2 sentences of evaluator-relevant insight

### `## Heuristic Lens Overrides` → `heuristic_overrides`

Each `### Heuristic N — Title` → key N with value = compressed lens text (2–4 sentences). Focus on
what is UNIQUE to this consideration. Remove generic accessibility advice.

## Terminology fidelity

Accessibility terms often encode a testable requirement, platform behavior, or assistive-technology
interaction model. Treat them as protected vocabulary: preserve the source term exactly and compress
only the explanation around it. If a protected term first appears with an acronym expansion, retain
the expansion once.

Preserve these families and their distinctions:

- **Standards references and concepts**: WCAG success criterion numbers and names; `reflow`,
  `Use of Color`, `non-text contrast`, `focus order`, `reading order`, `DOM order`, `source order`,
  `target size`, `motion actuation`, `orientation`, `single-pointer`, `path-based gesture`, and
  `multipoint gesture`. These terms map to different requirements; do not replace them with generic
  phrases such as "layout change", "logical order", "target acquisition", or "motion input".
- **Accessibility semantics**: `accessible name`, `accessible description`, `role`, `state`,
  `accessibility tree`, `programmatically determined`, `programmatically associated`, `live region`,
  and `status message`. Do not shorten these to "label", "metadata", "structure", or "announcement"
  when the source is specifically discussing the programmatic concept.
- **Assistive-technology interaction models**: product and platform feature names plus mode names
  such as `virtual buffer`, `virtual cursor`, `PC Cursor`, `Virtual PC Cursor`, `JAWS Cursor`,
  `browse mode`, `forms mode`, `focus mode`, `scan mode`, and `Rotor`. Preserve product-defined
  capitalization and do not merge modes that have different keyboard behavior.
- **Media and communication alternatives**: distinguish `authored captions`, `auto-captions`,
  `live captioning`, `subtitles`, `transcript`, `audio description`, and
  `sign language interpretation`. Preserve distinct relay modalities such as
  `video relay service (VRS)`, `IP relay`, and `TTY relay`; "text alternative" or "text relay" is
  not always an equivalent replacement.
- **Hearing technologies**: distinguish `hearing aid`, `cochlear implant`, `telecoil (T-coil)`,
  `hearing loop`, `Bluetooth streaming`, and `mono audio`. These are different devices, coupling
  mechanisms, or output modes.
- **Cognitive and communication terminology**: expand
  `augmentative and alternative communication (AAC)` on first use and preserve terms such as
  `autocomplete`, `autofill`, `working memory`, and `executive function` when present. Do not
  collapse distinct cognitive functions or platform semantics into a broad phrase such as "cognitive
  support".

Also preserve source scope caveats. If a consideration distinguishes a normative EN 301 549
requirement from a software-evaluation proxy, or distinguishes an AT limitation from an application
defect, retain that boundary explicitly. Never make the compressed YAML imply that a proxy is the
standard's normative requirement.

## Claim-aware compression

Treat output length as a fidelity budget, not a uniform sentence allowance. Preserve source meaning
in this priority order:

1. Negations and prohibitions: `no`, `not`, `without`, `never`, and equivalent negative
   constructions.
2. Scope and force: `all`, `some`, `only`, `primary`, `supplementary`, `can`, `should`, `must`, and
   affected platforms or user groups.
3. Exceptions and boundaries: `unless`, `except`, `when essential`, normative-versus-proxy
   distinctions, and application defect versus AT limitation.
4. Testable distinctions and contrasts between related technologies, modes, modalities, or
   behaviors.
5. Numbers, units, standards references, keyboard commands, product names, and platform-specific
   behavior.
6. Causal links needed for evaluation: user constraint → failure mode → required interface behavior.
7. General explanation, repeated rationale, and non-disambiguating examples.

When space is constrained, compress or remove lower-priority repetition before shortening
higher-priority claims. Do not give every entry equal detail: straightforward entries can fund extra
words for exceptions, platform differences, multiple modalities, or easily confused concepts
elsewhere in the same artifact. Keep the resulting artifact at the normal compact schema budget;
fidelity improvements should replace low-value prose rather than increase total output size.

Express high-priority content as short atomic claims. Each clause should preserve one testable fact,
requirement, exception, or contrast. Prefer
`Activate on up-event; release outside the target cancels. Down-event allowed only when timing is essential.`
over a fluent summary that omits cancellation or the exception.

Before writing an entry, identify its semantic-risk markers in the source:

- polarity: `no`, `not`, `never`, `without`, `cannot`
- scope or modality: `all`, `some`, `only`, `may`, `can`, `should`, `must`, `primary`,
  `supplementary`
- exception or comparison: `unless`, `except`, `but`, `while`, `unlike`, `less`, `more`, `instead`
- measurable detail: numbers, units, ratios, versions, WCAG references, and key combinations

Ensure each marker's meaning remains represented in the compressed entry, even when the exact
connective is rewritten. A marker need not be copied mechanically, but its polarity, scope,
comparison, or measurement must not change.

## Compression style

Write like concise technical documentation, not conversational prose:

- ✓ `Tab/Shift+Tab navigates. Enter/Space activates. Arrows in composite widgets.`
- ✗
  `The user navigates by pressing the Tab key to move forward and Shift+Tab to move backward through interactive elements.`
- ✓ `Caption controls visible in player UI, not buried in submenus. Captions ideally default-on.`
- ✗
  `The user expects that caption controls will be visible and discoverable within the media player's user interface, rather than being hidden in a nested settings submenu.`
- ✓
  `Reflow / wrap to fit: At around 320 CSS pixels, in-scope text containers avoid cross-line horizontal scrolling.`
- ✗ `Wrap to fit: Narrow text containers avoid scrolling across lines.`

Preserve: AT names, keyboard shortcuts, platform specifics, WCAG references, and canonical
accessibility or standards terms exactly as written in the source. Retain a source term even when a
shorter paraphrase seems equivalent; compression may shorten the surrounding explanation, not rename
the concept. Remove: rhetorical or unsupported hedging, restating the obvious, redundant examples,
and filler transitions. Preserve `may`, `might`, `can`, or `could` when it encodes real user
variability, conditional capability, uncertainty, or a weaker requirement than `must`.

## Worked example (input → output)

**Markdown input** (from `## Exploration Strategies`):

```markdown
### Scanning for caption controls on media

For video or multimedia, evaluate discovery of caption/subtitle controls through the
access methods in scope: a CC button, subtitles toggle, or caption settings.
Check default state, toggling, font size, colour, and positioning without assuming
one person's preferences or navigation strategy.

**AT Mechanisms**: Visual scanning, mouse/touch interaction with player controls
**Device context**: All

**UI Requirements**: Caption controls must be visible and discoverable in the media
player UI — not buried in a settings submenu. Captions should ideally be on by
default or clearly togglable. Caption quality (accuracy, timing, speaker
identification) matters — auto-generated captions without review may have
significant errors. For live content, live captioning must be available and clearly
indicated.
```

**YAML output**:

```yaml
- id: caption-controls-scanning
  mechanisms: [visual-scanning, mouse, touch]
  behavior: For video/multimedia, evaluate discovery of CC controls, subtitles toggles, and caption settings through in-scope access methods. Check defaults and adjustment without assuming one preference or navigation strategy.
  reqs: Caption controls visible in player UI, not buried in submenus. Captions ideally default-on or clearly toggleable. Caption quality matters — authored preferred over auto-generated; live captioning available and clearly indicated.
```

## Self-check before finalizing

1. Source/output metadata and artifact identity pass the quality gates
2. Source/output section counts match after excluding marked shared content
3. Every `id` is kebab-case and unique within its section
4. No `*(from shared)*` content appears anywhere in the output
5. `heuristic_overrides` has exactly keys 1–10, no more, no less
6. Every `uses_at[]` value resolves, `None` is represented by `uses_at: []`, consideration
   `uses_strategies` contains no shared IDs, and `shared_excludes` references resolve
7. Required strings and lists are non-empty
8. No field contains more than 2 sentences (except `heuristic_overrides` values: up to 4)
9. `clause` is the quoted artifact clause from the filename
10. The YAML schema directive matches consideration status
11. All string values that contain colons, quotes, or special YAML characters are double-quoted —
    unquoted values with `: ` mid-text break the YAML parser and cause silent field loss
12. JSON Schema validation, structure validation, and `git diff --check` pass
13. Canonical accessibility terminology and source-defined distinctions are preserved; no technical
    term is replaced only by a generic paraphrase
14. Negations, modal force, quantifiers, comparisons, causal links, exceptions, and scope boundaries
    retain the source meaning
15. Every testable number retains its unit and purpose; no threshold, range, standards reference,
    version, or key command is silently dropped
16. High-risk claims use compact atomic clauses, and output size is controlled by removing
    lower-value repetition rather than weakening those claims
17. Fidelity-only synchronization does not increase normalized character count or token count when
    token measurement is available; any caller-supplied create-mode budget is met
18. Generated YAML uses ASCII equivalents for typographic or confusable Unicode characters unless
    retaining a non-ASCII character is semantically necessary
