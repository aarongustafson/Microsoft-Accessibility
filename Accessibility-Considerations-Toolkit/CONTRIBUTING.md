# Contributing to Accessibility Considerations Toolkit (ACT)

## Elaborating a stub consideration

Markdown under `considerations/` is the authoring source. YAML under `schemas/` is generated for
structured distribution, not a separate authoring source. To elaborate a stub:

1. Read [keyboard interaction](considerations/4.2.7-keyboard-interaction.md) and
   [nonvisual access](considerations/4.2.1-nonvisual-access.md) for the Markdown structure.

2. Update the Markdown frontmatter:
   - Change `status: stub` to `status: elaborated`
   - Add `shared_excludes` if any shared strategies don't apply

3. Add all six required H2 sections: Evaluation Considerations, Assistive Technologies, Exploration
   Strategies, Interaction Contexts, Learning Considerations, and Heuristic Lens Overrides (1-10).

4. For each AT, include its name, category, platforms, device context, and interaction model.

5. For each strategy, include mechanisms, behavior, and UI requirements.

6. For each interaction context, include possible strategies, preferred navigation/AT, and interface
   expectations. Do not define a representative person or assume unrelated abilities.

7. Generate the matching YAML with the
   [consideration-to-schema skill](../.github/skills/consideration-to-schema/SKILL.md). Review
   fidelity, provenance, stable IDs, shared exclusions and
   [consideration.schema.json](schemas/consideration.schema.json) validation. Do not reconstruct
   Markdown from compressed YAML.

8. Run `python tests/validate_structure.py` and
   `python -m pytest tests/validate_structure.py tests -q`.

9. Complete the material-consideration review checklist in the pull request. Document evidence,
   limitations, the review method, and consented lived-experience perspectives without publishing
   reviewer identities or sensitive information.

## Updating shared content

Author shared strategies, interaction contexts, and learning considerations in
[considerations/\_shared-considerations.md](considerations/_shared-considerations.md). To update:

1. Edit `considerations/_shared-considerations.md`.
2. Propagate applicable inline Markdown copies, preserving `_(from shared)_` markers.
3. Regenerate `schemas/_shared-considerations.yaml` and affected consideration YAML with the
   conversion skill.
4. Review generated fidelity and run the offline validation commands above.

Validate copied shared bodies and schema structure. Passing structural checks is not proof of
complete semantic equivalence; review the original and generated entries directly.

## Adding a methodology principle

1. Create a new markdown file in `methodology/` with a clear, descriptive filename
2. Write the principle as a standalone reference document — it should be understandable without
   external context
3. Update `README.md` to include the new file in the repository structure section

## Licensing and provenance

- Keep the complete repository MIT notice in `LICENSE.txt` and `methodology/licensing.md`;
  validation requires the agent-readable Markdown copy to match.
- For copied or adapted material, document the source, version, reuse terms and required notices
  before adding content. Preserve supported provenance in authoring Markdown and generated YAML;
  update `provenance.json` for all distributed representations.
- Keep required third-party notices adjacent to the affected source. The W3C-derived cognitive
  considerations require `considerations/cognitive-accessibility-sources.LICENSE.md`; the WCAG
  reference requires `standards/wcag-requirements.LICENSE.md`.
- Do not use the repository MIT license to replace or obscure third-party terms.
- Consult the [source inventory](standards/sources.md). Attribution alone is not permission.
- Use original synthetic [image fixtures](tests/fixtures/images/README.md), not customer screenshots
  or third-party material without documented redistribution and privacy clearance.

## Responsible consideration use

Consideration content must evaluate possible interface barriers, not classify real people. Do not
infer disability, diagnosis, capability, or accommodation from behavior, zoom level, preferences,
errors, or assistive-technology use. Preserve conditional language, variations, limitations, and
intersectional needs. See `methodology/responsible-consideration-use.md` and
`methodology/consideration-interpretation.md`.

## AI-consumed content security

Consideration schemas, considerations, heuristics, methodology, standards references, Copilot
instructions, repository skills, and model-evaluation prompts or rubrics may become model context.
Changes to those paths and their governance files require CODEOWNER review.

- Review prompt-bearing changes for instructions that override consumer policy, redirect tool use,
  request secrets, conceal behavior, or promote external text from data to trusted instructions.
- Keep quoted, copied, and example content clearly bounded and preserve its provenance.
- Do not instruct consumers to fetch a mutable branch at runtime. Consumers should pin an immutable
  commit or submodule revision, preserve source provenance, and generate exact hashes in their
  downstream distribution manifest.
- Source review reduces the chance of introducing hostile instructions; it does not replace
  downstream prompt separation, runtime input handling, or integrity verification.

The structural validator checks required content, provenance, and selected safeguards. It cannot
prove that prose is stereotype-free or safe in every model and prompt composition. Material changes
still require human accessibility, Responsible AI, and adversarial-content review.

## File structure conventions

- Author considerations in Markdown under `considerations/`; distribute generated YAML with the
  generated shared guidance, required safeguards, provenance and notices. Markdown consumers still
  need safeguards.
- All H2 section headers in consideration files are considered required for elaborated
  considerations
- Shared content included in consideration files has an italic `(from shared)` suffix on the H3
  header. Prettier writes `_(from shared)_`; validation also accepts `*(from shared)*`.
- Stub considerations need only frontmatter and the H1 title + description
- Use access-topic aliases to select documents when several share an EN clause.
- When consideration content adapts an external source, keep all source-derived material in the
  consideration files and document attribution in a co-located `*.LICENSE.md` notice (e.g.,
  `considerations/cognitive-accessibility-sources.LICENSE.md`)
- Every elaborated consideration must contain substantive assistive-technology,
  exploration-strategy, interaction-context, and learning-consideration sections with conditional
  language.

## Framing and schema contract

Identify possible interface barriers, access strategies, and requirements, rather than asking an
evaluator to impersonate a person. A selected access topic is not evidence of disability, diagnosis,
behavior, or unrelated capabilities. Use explicit task and device conditions; preserve meaningful
variation and overlap between topics.

Generated elaborated YAML uses `evaluation.scope`, `evaluation.access_constraints`,
`evaluation.contexts`, and `evaluation.checklist`, plus `interaction_contexts`. Shared guidance uses
`shared_excludes` and `from_shared` at consumption time. The seizure-prevention stub remains
metadata-only.

## Setup and review

### Markdown formatting

Run `npm ci` to install the pinned Prettier version, then `npm run format:md` before submitting
Markdown changes. Use `npm run format:md:check` to verify formatting without editing files. Prose
wraps at 100 columns; Markdown tables, long links, code samples, and headings may be longer.
Published license notices and the verbatim license copy are excluded.

### Maintained files and generated outputs

Keep the authoring content, generated schema distribution, offline tests, evaluation task
definitions, answer keys, and synthetic SVG/PNG fixtures under version control. The YAML and fixture
renders are reviewed deliverables, not disposable test results. Keep the scripts and optional
model-evaluation tooling so contributors can maintain and validate those deliverables.

Do not commit local environments, dependency installations, Python/pytest caches, evaluation logs
under `logs/`, summary tables under `tests/test_outputs/`, or temporary pytest work directories.
These are runtime outputs, may contain evaluated prompts or sensitive data, and are excluded by
`.gitignore`. Test helpers should use pytest's temporary-directory fixtures instead of creating
scratch trees in the repository. The migration checklist is private preparation material and remains
excluded from the public export.

See [README.md](README.md#development-and-offline-validation) for Windows and macOS/Linux setup.
Offline validation does not require model authentication. Authenticated evals are manual and must
follow the [evaluation data-flow guidance](tests/evals/README.md#data-flow-and-artifacts). Review
contributions under the [Code of Conduct](../CODE_OF_CONDUCT.md). Report vulnerabilities privately
using [SECURITY.md](../SECURITY.md).
