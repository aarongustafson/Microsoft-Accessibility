# Original synthetic evaluation fixtures

Copyright (c) Microsoft Corporation. These original SVG drawings and their PNG renders are covered
by the repository [MIT License](../../../LICENSE.txt). They contain invented generic interface text,
no photographs, customer information, testimonials, third-party branding or copied third-party
screenshots. Their provenance is recorded in [provenance.json](../../../provenance.json).

| Source                                     | PNG used by evals                          | Intended visible evidence                                                                                                                          |
| ------------------------------------------ | ------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------- |
| [combobox.svg](combobox.svg)               | [combobox.png](combobox.png)               | Service-selection screen with clear headings and spacing, a small trigger label, compact dropdown rows, and no visible focus indicator.            |
| [colour-contrast.svg](colour-contrast.svg) | [colour-contrast.png](colour-contrast.png) | Dense 11px white text on multicoloured bands, weak contrast on yellow/green/cyan, and colour-reliant group separation without headings or spacing. |

The SVGs are drawings, not functioning widgets. Static images cannot establish keyboard operability,
accessible names, focus behavior, reflow or forced-colours support. Eval prompts and rubrics must
separate visible evidence from claims needing interaction/tree checks.

## Rendering and review

The committed PNGs were rendered from the SVGs with Playwright/Chromium at a 960x600 viewport and
device scale factor 1, using `page.locator("svg").screenshot({path: ...})`. Re-render by opening
each local SVG in Chromium and capturing its SVG element at those dimensions. Do not fetch external
fonts or assets. Browser/font versions can change pixels; review and commit the source and render
together instead of assuming byte-identical output.

Offline tests check PNG dimensions, checksums, absence of EXIF/XMP/text metadata, source/notice
presence, low-contrast source colours and all four consuming tasks' image references. Human review
must still check intended visible evidence and absence of identifying content.

When changing a fixture, review every consuming prompt/rubric and run offline tests. Optional
authenticated image evals require approved data/services and are not part of offline CI.
Inspect/Copilot converts supplied images into model attachments: only supply approved fixtures.
