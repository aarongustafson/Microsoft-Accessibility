## Summary

<!-- Describe the change and the affected project(s). -->

## Validation

<!-- List exact commands and results, or explain what was not run and why. -->

## Accessibility Considerations Toolkit (Act) review

<!-- The sections below apply only to Act and its supporting instructions, skill,
workflow, or governance. For other projects, mark them not applicable. -->

## Content provenance

Complete these checks when changing ACT considerations, heuristics, methodology, or standards:

- [ ] External sources, versions or dates, applicable licenses, adaptation status, and required
      notices are recorded.
- [ ] `provenance.json` and any affected consideration frontmatter match the source content.
- [ ] Required MIT and third-party notices remain complete and adjacent to distributable content.
- [ ] `python tests/validate_structure.py` passes (run from `Accessibility-Considerations-Toolkit`).

## AI-consumed content security

Complete these checks when changing ACT considerations, schemas, heuristics, methodology, standards,
repository skills, agent instructions, or model-evaluation prompts and rubrics:

- [ ] A CODEOWNER reviewed changes that can become agent or model context.
- [ ] Content was reviewed for instructions that could override consumer policy, redirect tool use,
      request secrets, conceal behavior, or treat untrusted text as trusted instructions.
- [ ] Examples and quoted external content remain clearly bounded as data rather than executable
      agent instructions.
- [ ] Consumers can pin an immutable commit or submodule revision; adapted materials retain source
      provenance, and downstream package manifests can verify exact distributed-content hashes.
      No guidance requires consuming a mutable branch.
- [ ] Downstream runtime prompt-boundary and integrity enforcement remains explicit and is not
      represented as a guarantee provided by this source repository.

## Material consideration changes

- [ ] Evidence sources, review dates, and known limitations or omissions are documented.
- [ ] Participatory review records the method and represented lived-experience perspectives without
      publishing identities or sensitive information without consent.
- [ ] Universal and deficit-framed claims were removed or supported by appropriate evidence.
- [ ] Qualifiers, alternatives, exceptions, device/AT differences, and expertise differences remain.
- [ ] The content evaluates interface barriers and does not infer disability, diagnosis,
      capability, or accommodation for a real person.
