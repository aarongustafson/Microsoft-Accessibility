# Accessibility Considerations Toolkit (Act)

Reference guidance for identifying considerations that can make user experiences more accessible.
For designers, researchers, accessibility evaluators, and developers of AI agents and evaluation
tools.

## What this is

A knowledge base of access considerations, assistive-technology interaction patterns,
accessibility-focused usability heuristics, evaluation methodology, and standards references.
Markdown is the authoring source and human-readable reference; generated YAML supports structured
consumption by agents and evaluation pipelines.

The documents use **EN 301 549 Functional Performance Statements (FPS)** as an organizing reference.
They examine interface requirements and possible barriers across access strategies, devices, and
task contexts. They do not represent individuals or disability communities, predict a person's
behavior, or replace individual input.

## Development and community involvement

The toolkit distinguishes three foundations:

- **Established accessibility knowledge:** standards, assistive-technology interaction patterns, and
  documented research.
- **Expert interpretation:** our team's synthesis of that knowledge into AI-consumable guidance.
- **Community validation:** direct input from people with disabilities on the relevance and
  completeness of the access considerations.

We welcome people with disabilities to help review and improve this resource. Reference guidance and
automated evaluations do not replace co-design and testing with people with disabilities. No
individual's perspective represents an entire disability community.

**Automated evaluations cannot identify every accessibility issue.** A result with no findings is
not proof of accessibility or standards conformance. Use automated checks alongside manual
evaluation, assistive-technology testing, and research with people with disabilities.

## Who this is for

- **Agent developers** building evaluation, design-review, or requirements-analysis tools.
- **Accessibility evaluators** investigating interface barriers through different access methods.
- **Designers and researchers** examining AT interaction patterns and inclusive design options.
- **Anyone** seeking access considerations for making user experiences more accessible.

## Resource structure

```text
considerations/                 # Authored Markdown and adjacent source notices
  _shared-considerations.md      # Reusable, conditionally applicable guidance
  4.2.N-<access-topic>.md         # EN-linked access considerations
  cognitive-accessibility-sources.LICENSE.md
schemas/                        # Generated structured distribution
  _shared-considerations.yaml
  4.2.N-<access-topic>.consideration.yaml
  consideration.schema.json
  consideration-stub.schema.json
heuristics/                     # Nielsen heuristic definitions and accessibility lenses
methodology/                    # Evaluation principles, safeguards, and licensing
standards/                      # Supporting WCAG reference and source inventory
tests/                          # Offline checks and optional model evaluations
scripts/                        # Evaluation wrappers and result-processing tools
provenance.json                 # Resource-relative source, notice, and fixture inventory
```

## Access topics and status

| EN clause | Document                                                                                                      | Status                   |
| --------- | ------------------------------------------------------------------------------------------------------------- | ------------------------ |
| 4.2.1     | [Nonvisual access](considerations/4.2.1-nonvisual-access.md)                                                  | Elaborated               |
| 4.2.2     | [Visual adaptation](considerations/4.2.2-visual-adaptation.md)                                                | Elaborated               |
| 4.2.3     | [Alternatives to colour cues](considerations/4.2.3-alternatives-to-colour-cues.md)                            | Elaborated               |
| 4.2.4     | [Audio alternatives](considerations/4.2.4-audio-alternatives.md)                                              | Elaborated               |
| 4.2.5     | [Hearing support](considerations/4.2.5-hearing-support.md)                                                    | Elaborated               |
| 4.2.6     | [Alternatives to speech input](considerations/4.2.6-alternatives-to-speech-input.md)                          | Elaborated               |
| 4.2.7     | [Keyboard interaction](considerations/4.2.7-keyboard-interaction.md)                                          | Elaborated               |
| 4.2.7     | [Voice control](considerations/4.2.7-voice-control.md)                                                        | Elaborated               |
| 4.2.8     | [Pointer interaction](considerations/4.2.8-pointer-interaction.md)                                            | Elaborated software lens |
| 4.2.9     | [Photosensitive seizure prevention](considerations/4.2.9-photosensitive-seizure-prevention.md)                | Stub                     |
| 4.2.10    | [Memory, attention, and executive function](considerations/4.2.10-memory-attention-and-executive-function.md) | Elaborated               |
| 4.2.10    | [Language and communication](considerations/4.2.10-language-and-communication.md)                             | Elaborated               |
| 4.2.10    | [Numeracy and numeric information](considerations/4.2.10-numeracy-and-numeric-information.md)                 | Elaborated               |

Documents sharing a clause are distinguished by their access-topic alias. The pointer document
examines software operation alongside EN 4.2.8; it does not replace that clause's physical
hardware-reach requirements. The seizure-prevention stub does not yet supply detailed strategies or
technologies.

Privacy (FPS 4.2.11) applies across topics; see the supplementary concern in
[heuristics/index.md](heuristics/index.md). These mappings are supporting guidance, not claims of
normative coverage or standards conformance.

## How to use

Read the relevant [considerations](considerations/) and examine the actual interface, access
methods, and task evidence. Several topics may apply together. Do not assume unrelated capabilities
from the selected topic or treat an available alternative as usable by everyone.

Always include [licensing](methodology/licensing.md),
[responsible use](methodology/responsible-consideration-use.md), and
[interpretation guidance](methodology/consideration-interpretation.md) with distributed
considerations. Preserve adjacent third-party notices and [provenance.json](provenance.json). The
[WCAG reference](standards/wcag-requirements.md) can annotate findings; it is not an authoritative
specification or a guarantee of compliance.

For structured use, distribute the generated topic YAML with
[shared YAML](schemas/_shared-considerations.yaml). For elaborated documents, append applicable
shared `strategies`, `interaction_contexts`, and `learning` entries whose IDs are not in
`shared_excludes`, tagging them `from_shared: true`. Do not append those fields to a stub.
Exclusions scope evaluation strategies, not a person's capabilities.

With development dependencies installed, this local example merges shared guidance and includes
required safeguards without a model call:

```sh
# From the resource directory
CONSIDERATION_SOURCE=schema python -c "from tests.evals._context import load_eval_consideration_context; print(load_eval_consideration_context('visual-adaptation'))"
```

In PowerShell, set `$env:CONSIDERATION_SOURCE = "schema"` before the Python command and remove it
afterwards with `Remove-Item Env:CONSIDERATION_SOURCE`. The default source is `md`. Low-level
`load_consideration_by_alias()` returns raw content; custom prompt builders must call
`with_required_consideration_safeguards()` or include all three safeguards explicitly. Supporting
multi-topic briefs remain Markdown-based.

## Authoring and shared guidance

Edit Markdown first, including applicable inline shared copies marked `_(from shared)_`. Use the
[consideration-to-schema skill](../.github/skills/consideration-to-schema/SKILL.md) to synchronize
generated YAML, then review fidelity, references, provenance, and size. Do not reconstruct Markdown
from compressed YAML. See [CONTRIBUTING.md](CONTRIBUTING.md).

## Development and offline validation

Use Python 3.12 or 3.14, create a virtual environment, and install
[requirements-dev.txt](requirements-dev.txt). Reading the knowledge base needs no Python, Copilot
subscription, or credentials.

For Markdown formatting, install the pinned development formatter with `npm ci`, then run
`npm run format:md` or `npm run format:md:check`. These commands use 100-column prose wrapping;
tables, links, code blocks, and other indivisible syntax may exceed that width. License notices
retain their published formatting. Node.js is only needed for formatting, not for reading the
resource or running Python validation.

```sh
# macOS / Linux, from the resource directory
python3 -m venv .venv
source .venv/bin/activate
python -m pip install -r requirements-dev.txt
python tests/validate_structure.py
python -m pytest tests/validate_structure.py tests -q
```

```powershell
# Windows, from the resource directory
python -m venv .venv
.venv\Scripts\Activate.ps1
python -m pip install -r requirements-dev.txt
python tests/validate_structure.py
python -m pytest tests/validate_structure.py tests -q
```

For generated-schema consumption, also run:

```sh
CONSIDERATION_SOURCE=schema python -m pytest tests/test_schema_loading.py tests/test_prompt_safeguards.py tests/evals/sub_agents/test_per_heuristic_loading.py -q
```

[Offline CI](../.github/workflows/act-validate.yml) runs structure, provenance, fixtures, loaders,
and consistency checks without model calls. Runners must be enabled by repository policy.
Dependencies have minimum versions rather than a locked environment; record installed versions when
comparing results. See the [evaluation guide](tests/evals/README.md) for optional model evaluations,
rubric grading, hidden answer-key scoring, and data-flow boundaries.

## Safe downstream consumption

This repository stores prompt-bearing content. Consumers should pin reviewed immutable revisions,
preserve provenance and notices, generate exact distribution hashes, review updates, and keep
untrusted runtime input separate from reference guidance. Enforce prompt-boundary and integrity
controls in the consuming application.

CODEOWNERS and tests do not guarantee safe downstream prompt composition or stereotype-free prose.
Structural checks do not prove complete semantic equivalence or replace human accessibility,
community, Responsible AI, or content-rights review.

The renamed paths, access-topic aliases, schema fields, loader functions, evaluation task names, and
`CONSIDERATION_SOURCE` setting form a new interface. Consumers must update their references
together; retired identifiers are not retained as compatibility aliases.

## Contributing, licensing, security, and support

See [CONTRIBUTING.md](CONTRIBUTING.md). Original contributions are covered by the
[MIT License](LICENSE.txt); upstream material has additional terms described in
[licensing](methodology/licensing.md) and the [source inventory](standards/sources.md).

Consumers should pin reviewed immutable commits, not mutable branches. A toolkit release/tag
convention is not yet defined; another project's release is not a release of this resource.

Use GitHub issues for resource questions and bugs. Report vulnerabilities privately using
[SECURITY.md](../SECURITY.md), not public issues. See the [Code of Conduct](../CODE_OF_CONDUCT.md).
