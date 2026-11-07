"""Validate the structural consistency of Accessibility Considerations Toolkit (Act) files.

Checks:
- Canonical YAML consideration schema structure and provenance
- YAML frontmatter schema in all consideration files
- Required H2 sections in elaborated considerations
- Shared content consistency across consideration files
- Heuristic lens override IDs reference valid heuristic numbers
- Stub considerations have required minimal structure

Can run as:
  python tests/validate_structure.py
  pytest tests/validate_structure.py
"""

from __future__ import annotations

import hashlib
import json
import re
import sys
from functools import lru_cache
from pathlib import Path

import yaml
from jsonschema import Draft202012Validator, FormatChecker

REPO_ROOT = Path(__file__).resolve().parent.parent
GOVERNANCE_ROOT = REPO_ROOT.parent
CONSIDERATIONS_DIR = REPO_ROOT / "considerations"
SCHEMAS_DIR = REPO_ROOT / "schemas"
HEURISTICS_DIR = REPO_ROOT / "heuristics"
METHODOLOGY_DIR = REPO_ROOT / "methodology"
STANDARDS_DIR = REPO_ROOT / "standards"
SHARED_MARKER_PATTERN = r"(?:\*\(from shared\)\*|_\(from shared\)_)"

REQUIRED_FRONTMATTER_FIELDS = {"clause", "title", "alias", "status"}
VALID_STATUSES = {"elaborated", "stub"}
VALID_HEURISTIC_IDS = set(range(1, 11))
COGA_CONSIDERATIONS = {
    "4.2.10-memory-attention-and-executive-function.md",
    "4.2.10-language-and-communication.md",
    "4.2.10-numeracy-and-numeric-information.md",
}
COGA_SCHEMAS = {
    "4.2.10-memory-attention-and-executive-function.consideration.yaml",
    "4.2.10-language-and-communication.consideration.yaml",
    "4.2.10-numeracy-and-numeric-information.consideration.yaml",
}
COGA_SOURCE_URLS = {
    "https://www.w3.org/TR/coga-usable/",
    "https://www.w3.org/TR/2026/DNOTE-coga-research-modules-20260205/",
}
COGA_REQUIRED_NOTICES = (
    'This software or document includes material copied from or derived from '
    '"Making Content Usable for People with Cognitive and Learning Disabilities" '
    '(<https://www.w3.org/TR/coga-usable/>). Copyright © 2021 W3C® '
    '(MIT, ERCIM, Keio, Beihang).',
    'This software or document includes material copied from or derived from '
    '"Cognitive Accessibility Research Modules" '
    '(<https://www.w3.org/TR/2026/DNOTE-coga-research-modules-20260205/>). '
    'Copyright © 2026 World Wide Web Consortium. '
    '<https://www.w3.org/copyright/software-license-2023/>',
)
W3C_SOFTWARE_LICENSE_SECTION_HASHES = {
    "W3C Software and Document License — 2015 version": (
        "34e42464894a3ef240de95b8178dca73f110df4305eee313f810837571ead1df"
    ),
    "W3C Software and Document License — 2023 version": (
        "90024cfac00df2e0beadb08f24d53b3f97b7bd0ed18a0976084fe7c014e751c5"
    ),
}
INTERPRETATION_REQUIRED_TEXT = (
    "Preserve qualifiers",
    "Do not compress multiple strategies into one supposedly universal behavior",
    "Avoid deficit framing",
    "do not replace research with the intended audience",
)
REQUIRED_CODEOWNERS = (
    "@aarongustafson",
    "@ferbonnin",
)
PROMPT_BEARING_CODEOWNER_PATHS = (
    "/Accessibility-Considerations-Toolkit/",
    "/Accessibility-Considerations-Toolkit/schemas/",
    "/Accessibility-Considerations-Toolkit/considerations/",
    "/Accessibility-Considerations-Toolkit/heuristics/",
    "/Accessibility-Considerations-Toolkit/methodology/",
    "/Accessibility-Considerations-Toolkit/standards/",
    "/Accessibility-Considerations-Toolkit/provenance.json",
    "/Accessibility-Considerations-Toolkit/LICENSE.txt",
    "/Accessibility-Considerations-Toolkit/tests/validate_structure.py",
    "/Accessibility-Considerations-Toolkit/tests/evals/",
    "/Accessibility-Considerations-Toolkit/tests/fixtures/",
    "/Accessibility-Considerations-Toolkit/scripts/",
    "/Accessibility-Considerations-Toolkit/AGENTS.md",
    "/Accessibility-Considerations-Toolkit/README.md",
    "/Accessibility-Considerations-Toolkit/CONTRIBUTING.md",
    "/.github/workflows/act-validate.yml",
    "/.github/instructions/act.instructions.md",
    "/.github/skills/consideration-to-schema/",
    "/.github/CODEOWNERS",
    "/.github/PULL_REQUEST_TEMPLATE.md",
)
CONDITIONAL_LANGUAGE = re.compile(
    r"\b(?:may|can|could|often|sometimes|some users|can vary|varies|depending on|not all)\b",
    re.IGNORECASE,
)

REQUIRED_ELABORATED_SECTIONS = [
    "Evaluation Considerations",
    "Assistive Technologies",
    "Exploration Strategies",
    "Interaction Contexts",
    "Learning Considerations",
    "Heuristic Lens Overrides",
]
REQUIRED_SCHEMA_FIELDS = {
    "clause",
    "title",
    "alias",
    "status",
    "fps_statement",
}
REQUIRED_ELABORATED_SCHEMA_FIELDS = {
    "evaluation",
    "assistive_tech",
    "strategies",
    "interaction_contexts",
    "learning",
    "heuristic_overrides",
}
IDENTITY_SIMULATION = re.compile(
    r"\bas if you (?:are|were)\b"
    r"|\byou are (?:a|an) (?:person|user)\b"
    r"|\byour (?:senses|motor control|only barrier)\b"
    r"|\b(?:senses|motor control|language ability) (?:are |is )?(?:otherwise )?unaffected\b"
    r"|\b(?:the |a )?shared user(?:'s)?\b"
    r"|\barchetype\b",
    re.IGNORECASE,
)


def validate_access_framing(text: str, file_name: str) -> list[ValidationError]:
    """Reject simulated identities and unrelated capability assumptions."""
    return [
        ValidationError(file_name, f"Access guidance must not simulate a person: {match.group()}")
        for match in IDENTITY_SIMULATION.finditer(text)
    ]


def parse_frontmatter(path: Path) -> dict | None:
    """Extract YAML frontmatter from a markdown file."""
    text = path.read_text(encoding="utf-8")
    match = re.match(r"^---\n(.*?)\n---", text, re.DOTALL)
    if not match:
        return None
    return yaml.safe_load(match.group(1))


def get_h2_sections(path: Path) -> list[str]:
    """Extract H2 section titles from a markdown file."""
    text = path.read_text(encoding="utf-8")
    return re.findall(r"^## (.+)$", text, re.MULTILINE)


def get_h3_sections(path: Path, under_h2: str) -> list[str]:
    """Extract H3 section titles under a specific H2."""
    text = path.read_text(encoding="utf-8")
    # Find content between the target H2 and the next H2 (or end of file)
    pattern = rf"^## {re.escape(under_h2)}\n(.*?)(?=^## |\Z)"
    match = re.search(pattern, text, re.MULTILINE | re.DOTALL)
    if not match:
        return []
    section_text = match.group(1)
    return re.findall(r"^### (.+)$", section_text, re.MULTILINE)


def get_shared_content_markers(path: Path) -> list[str]:
    """Find all *(from shared)* markers in a consideration file."""
    text = path.read_text(encoding="utf-8")
    return re.findall(SHARED_MARKER_PATTERN, text)


def get_consideration_files() -> list[Path]:
    """Get all consideration files (excluding _shared-considerations.md)."""
    return sorted(
        p for p in CONSIDERATIONS_DIR.glob("4.2.*-*.md")
        if p.name != "_shared-considerations.md"
    )


def get_schema_files() -> list[Path]:
    """Get canonical YAML consideration schemas."""
    return sorted(SCHEMAS_DIR.glob("*.consideration.yaml"))


@lru_cache(maxsize=None)
def _schema_validator(status: str) -> Draft202012Validator:
    """Load the canonical JSON Schema validator for a consideration status."""
    schema_name = "consideration.schema.json" if status == "elaborated" else "consideration-stub.schema.json"
    schema = json.loads((SCHEMAS_DIR / schema_name).read_text(encoding="utf-8"))
    Draft202012Validator.check_schema(schema)
    return Draft202012Validator(schema, format_checker=FormatChecker())


class ValidationError:
    def __init__(self, file: str, message: str):
        self.file = file
        self.message = message

    def __str__(self):
        return f"{self.file}: {self.message}"


def _validate_provenance_object(
    file_name: str,
    provenance: object,
) -> list[ValidationError]:
    """Validate source metadata shared by Markdown and YAML representations."""
    if not isinstance(provenance, dict):
        return [ValidationError(file_name, "Missing provenance object")]

    errors = []
    source_urls = provenance.get("source_urls")
    if not isinstance(source_urls, list) or set(source_urls) != COGA_SOURCE_URLS:
        errors.append(ValidationError(file_name, "Provenance has incorrect source_urls"))
    expected = {
        "upstream_license": "W3C Software and Document License",
        "repository_license": "MIT",
        "required_notice": "considerations/cognitive-accessibility-sources.LICENSE.md",
        "adaptation": True,
    }
    for field, value in expected.items():
        if provenance.get(field) != value:
            errors.append(ValidationError(
                file_name,
                f"Provenance field {field!r} must be {value!r}",
            ))
    if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", str(provenance.get("reviewed_on", ""))):
        errors.append(ValidationError(file_name, "Provenance reviewed_on must be YYYY-MM-DD"))

    notice_path = REPO_ROOT / str(provenance.get("required_notice", ""))
    if not notice_path.is_file():
        errors.append(ValidationError(file_name, "Required provenance notice is missing"))
    return errors


def validate_schema(path: Path) -> list[ValidationError]:
    """Validate canonical consideration YAML used by downstream distributions."""
    try:
        data = yaml.safe_load(path.read_text(encoding="utf-8"))
    except (OSError, yaml.YAMLError) as exc:
        return [ValidationError(path.name, f"Cannot read consideration schema: {exc}")]
    if not isinstance(data, dict):
        return [ValidationError(path.name, "Consideration schema must be a mapping")]

    errors = []
    missing = REQUIRED_SCHEMA_FIELDS - set(data)
    if missing:
        errors.append(ValidationError(path.name, f"Missing schema fields: {missing}"))
    status = data.get("status")
    if status not in VALID_STATUSES:
        errors.append(ValidationError(path.name, f"Invalid schema status: {status!r}"))
        return errors

    schema_errors = sorted(
        _schema_validator(status).iter_errors(data),
        key=lambda error: [str(part) for part in error.absolute_path],
    )
    for error in schema_errors:
        location = ".".join(str(part) for part in error.absolute_path) or "<root>"
        errors.append(
            ValidationError(
                path.name,
                f"JSON Schema violation at {location}: {error.message}",
            )
        )
    if schema_errors:
        return errors

    if status == "elaborated":
        missing = REQUIRED_ELABORATED_SCHEMA_FIELDS - set(data)
        if missing:
            errors.append(ValidationError(path.name, f"Missing elaborated schema fields: {missing}"))
        for field in ("assistive_tech", "strategies", "interaction_contexts", "learning"):
            value = data.get(field)
            if not isinstance(value, list) or not value:
                errors.append(ValidationError(path.name, f"{field} must be a non-empty list"))
        evaluation = data.get("evaluation")
        if not isinstance(evaluation, dict) or not evaluation.get("scope") or not evaluation.get("checklist"):
            errors.append(ValidationError(path.name, "evaluation must include scope and checklist"))
        errors.extend(validate_access_framing(
            yaml.safe_dump(data, sort_keys=False), path.name,
        ))
        overrides = data.get("heuristic_overrides")
        if not isinstance(overrides, dict) or set(map(str, overrides)) != {
            str(value) for value in VALID_HEURISTIC_IDS
        }:
            errors.append(ValidationError(
                path.name,
                "heuristic_overrides must define every heuristic from 1 through 10",
            ))
        variation = yaml.safe_dump(
            {
                field: data.get(field, [])
                for field in ("assistive_tech", "strategies", "interaction_contexts", "learning")
            },
            sort_keys=False,
        )
        if not CONDITIONAL_LANGUAGE.search(variation):
            errors.append(ValidationError(
                path.name,
                "Schema variation content lacks conditional language",
            ))

    if path.name in COGA_SCHEMAS:
        errors.extend(_validate_provenance_object(path.name, data.get("provenance")))
        for variant in data.get("interaction_contexts", []):
            behavior = str(variant.get("behavior", ""))
            if not CONDITIONAL_LANGUAGE.search(behavior):
                errors.append(ValidationError(
                    path.name,
                    f"Interaction context {variant.get('id', '<unknown>')!r} lacks conditional language",
                ))
    elif "provenance" in data:
        errors.append(ValidationError(
            path.name,
            "Unexpected provenance on a consideration not listed in provenance.json",
        ))
    return errors


def validate_source_schema_identity() -> list[ValidationError]:
    """Require one generated artifact per access topic with matching metadata."""
    errors = []
    expected = {}
    aliases = set()
    for path in get_consideration_files():
        metadata = parse_frontmatter(path)
        if not isinstance(metadata, dict):
            continue
        alias = metadata.get("alias")
        if alias in aliases:
            errors.append(ValidationError(path.name, f"Duplicate access-topic alias: {alias}"))
        aliases.add(alias)
        expected[f"{path.stem}.consideration.yaml"] = metadata
    for name in expected.keys() - {path.name for path in get_schema_files()}:
        errors.append(ValidationError(name, "Missing generated access-topic schema"))
    for path in get_schema_files():
        if path.name not in expected:
            errors.append(ValidationError(path.name, "Generated schema has no authoring source"))
            continue
        try:
            data = yaml.safe_load(path.read_text(encoding="utf-8"))
        except (OSError, yaml.YAMLError):
            continue  # validate_schema reports the actual read or parse failure.
        if not isinstance(data, dict):
            continue
        for field in ("clause", "title", "alias", "status", "provenance"):
            if data.get(field) != expected[path.name].get(field):
                errors.append(ValidationError(path.name, f"Generated {field} differs from authoring source"))
        if data.get("shared_excludes", []) != expected[path.name].get("shared_excludes", []):
            errors.append(ValidationError(path.name, "Generated shared exclusions differ from authoring source"))
    return errors


def validate_frontmatter(path: Path) -> list[ValidationError]:
    """Validate frontmatter schema."""
    errors = []
    fm = parse_frontmatter(path)
    if fm is None:
        errors.append(ValidationError(path.name, "Missing YAML frontmatter"))
        return errors

    missing = REQUIRED_FRONTMATTER_FIELDS - set(fm.keys())
    if missing:
        errors.append(ValidationError(path.name, f"Missing frontmatter fields: {missing}"))

    if "status" in fm and fm["status"] not in VALID_STATUSES:
        errors.append(ValidationError(
            path.name,
            f"Invalid status '{fm['status']}'. Must be one of: {VALID_STATUSES}"
        ))

    if "shared_excludes" in fm and not isinstance(fm["shared_excludes"], list):
        errors.append(ValidationError(
            path.name,
            "shared_excludes must be a list"
        ))
    identity = re.fullmatch(r"(4\.2\.\d+)-([a-z0-9-]+)\.md", path.name)
    if not identity or (fm.get("clause"), fm.get("alias")) != identity.groups():
        errors.append(ValidationError(path.name, "Filename clause and alias must match frontmatter"))
    errors.extend(validate_access_framing(path.read_text(encoding="utf-8"), path.name))

    return errors


def validate_elaborated_sections(path: Path) -> list[ValidationError]:
    """Validate that elaborated considerations have all required H2 sections."""
    errors = []
    fm = parse_frontmatter(path)
    if fm is None or fm.get("status") != "elaborated":
        return errors

    sections = get_h2_sections(path)
    for required in REQUIRED_ELABORATED_SECTIONS:
        if required not in sections:
            errors.append(ValidationError(
                path.name,
                f"Missing required section: ## {required}"
            ))
    if sections != REQUIRED_ELABORATED_SECTIONS:
        errors.append(ValidationError(path.name, "Required sections must appear once in canonical order"))

    return errors


def _section_content(path: Path, heading: str) -> str | None:
    text = path.read_text(encoding="utf-8")
    text = re.sub(r"<!--.*?-->", "", text, flags=re.DOTALL)
    text = re.sub(r"```.*?```|~~~.*?~~~", "", text, flags=re.DOTALL)
    match = re.search(
        rf"^## {re.escape(heading)}\n(.*?)(?=^## |\Z)",
        text,
        re.MULTILINE | re.DOTALL,
    )
    if not match:
        return None
    return re.sub(r"^#{1,6}\s.*$", "", match.group(1), flags=re.MULTILINE).strip()


def validate_consideration_nuance(path: Path) -> list[ValidationError]:
    """Require substantive variation sections and conditional language."""
    errors = []
    fm = parse_frontmatter(path)
    if fm is None or fm.get("status") != "elaborated":
        return errors

    contents = []
    for section in (
        "Assistive Technologies",
        "Exploration Strategies",
        "Interaction Contexts",
        "Learning Considerations",
    ):
        content = _section_content(path, section)
        if content is None:
            continue
        if not re.search(r"[a-z0-9]", content, re.IGNORECASE):
            errors.append(ValidationError(path.name, f"Empty section: ## {section}"))
        contents.append(content)

    if contents and not CONDITIONAL_LANGUAGE.search("\n".join(contents)):
        errors.append(ValidationError(
            path.name,
            "Variation sections lack conditional language such as 'may' or 'some users'",
        ))
    return errors


def validate_provenance(path: Path) -> list[ValidationError]:
    """Validate machine-readable provenance for known adapted considerations."""
    if path.name not in COGA_CONSIDERATIONS:
        return []
    fm = parse_frontmatter(path) or {}
    provenance = fm.get("provenance")
    errors = _validate_provenance_object(path.name, provenance)
    if (
        isinstance(provenance, dict)
        and str(provenance.get("required_notice", "")) not in path.read_text(encoding="utf-8")
    ):
        errors.append(ValidationError(path.name, "Consideration does not reference its provenance notice"))
    return errors


def validate_coga_notice(coga_notice: str) -> list[ValidationError]:
    """Validate complete, version-specific W3C notices for adapted COGA material."""
    errors = []
    normalized_notice = " ".join(coga_notice.split())
    for value in (*COGA_SOURCE_URLS, *COGA_REQUIRED_NOTICES):
        if " ".join(value.split()) not in normalized_notice:
            errors.append(ValidationError(
                "considerations/cognitive-accessibility-sources.LICENSE.md",
                f"Missing or incorrect W3C notice: {value}",
            ))

    for heading, expected_hash in W3C_SOFTWARE_LICENSE_SECTION_HASHES.items():
        section_match = re.search(
            rf"^## {re.escape(heading)}\s*$\n(.*?)(?=^## |\Z)",
            coga_notice,
            re.MULTILINE | re.DOTALL,
        )
        if not section_match:
            errors.append(ValidationError(
                "considerations/cognitive-accessibility-sources.LICENSE.md",
                f"Missing W3C license section: {heading}",
            ))
            continue
        normalized_section = " ".join(section_match.group(1).split())
        actual_hash = hashlib.sha256(normalized_section.encode("utf-8")).hexdigest()
        if actual_hash != expected_hash:
            errors.append(ValidationError(
                "considerations/cognitive-accessibility-sources.LICENSE.md",
                f"{heading} complete normalized license text differs from the canonical copy",
            ))

    obsolete_2026_notice = "Copyright © 2026 W3C® (MIT, ERCIM, Keio, Beihang)"
    if obsolete_2026_notice in coga_notice:
        errors.append(ValidationError(
            "considerations/cognitive-accessibility-sources.LICENSE.md",
            "The 2026 source uses the obsolete 2015 copyright-holder form",
        ))
    return errors


def validate_interpretation_guidance(text: str) -> list[ValidationError]:
    """Require the policy statements that bound stereotype-prone consideration use."""
    errors = []
    normalized = " ".join(text.split())
    for value in INTERPRETATION_REQUIRED_TEXT:
        if " ".join(value.split()).lower() not in normalized.lower():
            errors.append(ValidationError(
                "methodology/consideration-interpretation.md",
                f"Missing required interpretation safeguard: {value}",
            ))
    return errors


def validate_codeowners(text: str) -> list[ValidationError]:
    """Require owner review for every source of AI-consumed repository content."""
    errors = []
    entries = {
        parts[0]: parts[1:]
        for line in text.splitlines()
        if (parts := line.split()) and not parts[0].startswith("#")
    }
    for path in PROMPT_BEARING_CODEOWNER_PATHS:
        owners = entries.get(path, [])
        for owner in REQUIRED_CODEOWNERS:
            if owner not in owners:
                errors.append(ValidationError(
                    ".github/CODEOWNERS",
                    f"{path} must require {owner}",
                ))
    return errors


def validate_cross_cutting_controls() -> list[ValidationError]:
    """Validate controls that must travel with consideration and standards content."""
    errors = []
    license_text = (REPO_ROOT / "LICENSE.txt").read_text(encoding="utf-8")
    licensing_path = METHODOLOGY_DIR / "licensing.md"
    responsible_path = METHODOLOGY_DIR / "responsible-consideration-use.md"
    interpretation_path = METHODOLOGY_DIR / "consideration-interpretation.md"
    for path in (licensing_path, responsible_path, interpretation_path):
        if not path.is_file():
            errors.append(ValidationError(str(path.relative_to(REPO_ROOT)), "Required methodology missing"))

    if licensing_path.is_file() and license_text not in licensing_path.read_text(encoding="utf-8"):
        errors.append(ValidationError(
            "methodology/licensing.md",
            "Does not embed the repository MIT license verbatim",
        ))
    if responsible_path.is_file():
        responsible = responsible_path.read_text(encoding="utf-8")
        for phrase in (
            "infer whether an identifiable person has a disability",
            "At 200% zoom",
            "The employee is a person with low vision",
        ):
            if phrase not in responsible:
                errors.append(ValidationError(
                    "methodology/responsible-consideration-use.md",
                    f"Missing required safeguard: {phrase}",
                ))
    if interpretation_path.is_file():
        errors.extend(validate_interpretation_guidance(
            interpretation_path.read_text(encoding="utf-8")
        ))

    codeowners_path = GOVERNANCE_ROOT / ".github" / "CODEOWNERS"
    if not codeowners_path.is_file():
        errors.append(ValidationError(".github/CODEOWNERS", "Required owner policy missing"))
    else:
        errors.extend(validate_codeowners(codeowners_path.read_text(encoding="utf-8")))
    pr_template = GOVERNANCE_ROOT / ".github" / "PULL_REQUEST_TEMPLATE.md"
    if not pr_template.is_file():
        errors.append(ValidationError(
            ".github/PULL_REQUEST_TEMPLATE.md",
            "Required review checklist missing",
        ))
    else:
        template_text = pr_template.read_text(encoding="utf-8")
        for phrase in (
            "AI-consumed content security",
            "override consumer policy",
            "pin an immutable commit or submodule revision",
        ):
            if phrase not in template_text:
                errors.append(ValidationError(
                    ".github/PULL_REQUEST_TEMPLATE.md",
                    f"Missing prompt-content review check: {phrase}",
                ))

    shared = (CONSIDERATIONS_DIR / "_shared-considerations.md").read_text(encoding="utf-8")
    if "Do not infer" not in shared or "responsible-consideration-use.md" not in shared:
        errors.append(ValidationError(
            "considerations/_shared-considerations.md",
            "Missing responsible consideration-use reminder",
        ))

    coga_notice_path = CONSIDERATIONS_DIR / "cognitive-accessibility-sources.LICENSE.md"
    coga_notice = coga_notice_path.read_text(encoding="utf-8")
    errors.extend(validate_coga_notice(coga_notice))

    wcag_path = STANDARDS_DIR / "wcag-requirements.md"
    wcag_notice = STANDARDS_DIR / "wcag-requirements.LICENSE.md"
    wcag = wcag_path.read_text(encoding="utf-8")
    if not wcag_notice.is_file():
        errors.append(ValidationError(str(wcag_notice.relative_to(REPO_ROOT)), "Required notice missing"))
    for value in (
        "wcag-requirements.LICENSE.md",
        "https://www.w3.org/TR/WCAG22/",
        "not the authoritative specification",
    ):
        if value not in wcag:
            errors.append(ValidationError(
                "standards/wcag-requirements.md",
                f"Missing distribution warning: {value}",
            ))

    manifest_path = REPO_ROOT / "provenance.json"
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        errors.append(ValidationError("provenance.json", f"Cannot read manifest: {exc}"))
        return errors
    errors.extend(validate_distribution_manifest(manifest))
    return errors


def validate_distribution_manifest(manifest: object) -> list[ValidationError]:
    """Check packaged representations and notices relative to the resource root."""
    errors = []
    if not isinstance(manifest, dict):
        return [ValidationError("provenance.json", "Manifest must be an object")]
    materials = manifest.get("materials")
    if manifest.get("schemaVersion") != 1 or not isinstance(materials, list):
        errors.append(ValidationError("provenance.json", "Invalid manifest shape"))
        return errors
    ids = set()
    for material in materials:
        if not isinstance(material, dict):
            return [ValidationError("provenance.json", "Material must be an object")]
        material_id = material.get("id")
        if not isinstance(material_id, str) or not material_id or material_id in ids:
            errors.append(ValidationError("provenance.json", "Material IDs must be unique non-empty strings"))
        else:
            ids.add(material_id)
        content = material.get("content")
        if not isinstance(content, list) or not content or not all(isinstance(path, str) for path in content):
            errors.append(ValidationError("provenance.json", "Material content must list file paths"))
            continue
        source_urls = material.get("sourceUrls")
        if not isinstance(source_urls, list) or not all(isinstance(url, str) for url in source_urls):
            errors.append(ValidationError("provenance.json", "Material sourceUrls must be a list of strings"))
        paths = content + [material.get("requiredNotice"), material.get("requiredRepositoryNotice")]
        for value in paths:
            if not isinstance(value, str) or not value or Path(value).is_absolute() or ".." in Path(value).parts:
                errors.append(ValidationError("provenance.json", f"Invalid resource-relative path: {value!r}"))
            elif not (REPO_ROOT / value).is_file():
                errors.append(ValidationError("provenance.json", f"Required distribution file missing: {value}"))
    if errors:
        return errors
    coga = next((item for item in materials if item.get("id") == "w3c-coga-considerations"), None)
    if not isinstance(coga, dict):
        errors.append(ValidationError("provenance.json", "Missing w3c-coga-considerations material"))
        return errors
    if set(coga.get("content", [])) != (
        {f"schemas/{name}" for name in COGA_SCHEMAS}
        | {f"considerations/{name}" for name in COGA_CONSIDERATIONS}
    ):
        errors.append(ValidationError("provenance.json", "COGA content paths are incomplete"))
    if set(coga.get("sourceUrls", [])) != COGA_SOURCE_URLS:
        errors.append(ValidationError("provenance.json", "COGA source URLs are incorrect"))
    for field, value in {
        "requiredNotice": "considerations/cognitive-accessibility-sources.LICENSE.md",
        "requiredRepositoryNotice": "LICENSE.txt",
        "upstreamLicense": "W3C Software and Document License",
        "repositoryLicense": "MIT",
        "adaptation": True,
    }.items():
        if coga.get(field) != value:
            errors.append(ValidationError(
                "provenance.json",
                f"Field {field!r} must be {value!r}",
            ))
    wcag = next((item for item in materials if item.get("id") == "w3c-wcag-reference"), None)
    if not isinstance(wcag, dict):
        errors.append(ValidationError("provenance.json", "Missing w3c-wcag-reference material"))
    else:
        expected = {
            "content": ["standards/wcag-requirements.md"],
            "requiredNotice": "standards/wcag-requirements.LICENSE.md",
            "requiredRepositoryNotice": "LICENSE.txt",
            "sourceUrls": ["https://www.w3.org/TR/WCAG22/"],
            "upstreamLicense": "W3C Document License (2023)",
            "repositoryLicense": "MIT",
            "adaptation": True,
        }
        for field, value in expected.items():
            if wcag.get(field) != value:
                errors.append(ValidationError("provenance.json", f"WCAG field {field!r} must be {value!r}"))
    return errors


def validate_heuristic_overrides(path: Path) -> list[ValidationError]:
    """Validate heuristic lens override IDs are valid (1-10)."""
    errors = []
    fm = parse_frontmatter(path)
    if fm is None or fm.get("status") != "elaborated":
        return errors

    h3s = get_h3_sections(path, "Heuristic Lens Overrides")
    for h3 in h3s:
        # Extract heuristic number from "Heuristic N — ..."
        match = re.match(r"Heuristic (\d+)", h3)
        if match:
            hid = int(match.group(1))
            if hid not in VALID_HEURISTIC_IDS:
                errors.append(ValidationError(
                    path.name,
                    f"Invalid heuristic ID {hid} in lens overrides. Valid: 1-10"
                ))
        else:
            errors.append(ValidationError(
                path.name,
                f"Heuristic lens override '{h3}' doesn't match expected format 'Heuristic N — ...'"
            ))

    return errors


def validate_shared_consistency() -> list[ValidationError]:
    """Check that all elaborated considerations include shared content markers."""
    errors = []
    for path in get_consideration_files():
        fm = parse_frontmatter(path)
        if fm is None or fm.get("status") != "elaborated":
            continue

        markers = get_shared_content_markers(path)
        if not markers:
            errors.append(ValidationError(
                path.name,
                "Elaborated consideration has no '*(from shared)*' markers — "
                "shared content may not be included"
            ))

    return errors


def validate_stub_structure(path: Path) -> list[ValidationError]:
    """Validate that stub considerations have minimal required structure."""
    errors = []
    fm = parse_frontmatter(path)
    if fm is None or fm.get("status") != "stub":
        return errors

    text = path.read_text(encoding="utf-8")
    if not re.search(r"^# ", text, re.MULTILINE):
        errors.append(ValidationError(path.name, "Stub consideration missing H1 title"))

    return errors


def run_validation() -> list[ValidationError]:
    """Run all validations and return errors."""
    all_errors = []

    # Check considerations directory exists
    if not CONSIDERATIONS_DIR.exists():
        all_errors.append(ValidationError("considerations/", "Directory does not exist"))
        return all_errors

    if not SCHEMAS_DIR.exists():
        all_errors.append(ValidationError("schemas/", "Directory does not exist"))
        return all_errors
    schema_shared = SCHEMAS_DIR / "_shared-considerations.yaml"
    if not schema_shared.is_file():
        all_errors.append(ValidationError("schemas/_shared-considerations.yaml", "Schema shared missing"))
    for path in get_schema_files():
        all_errors.extend(validate_schema(path))

    # Check shared exists
    shared_path = CONSIDERATIONS_DIR / "_shared-considerations.md"
    if not shared_path.exists():
        all_errors.append(ValidationError("considerations/_shared-considerations.md", "Shared file missing"))

    # Validate each consideration file
    for path in get_consideration_files():
        all_errors.extend(validate_frontmatter(path))
        all_errors.extend(validate_elaborated_sections(path))
        all_errors.extend(validate_consideration_nuance(path))
        all_errors.extend(validate_provenance(path))
        all_errors.extend(validate_heuristic_overrides(path))
        all_errors.extend(validate_stub_structure(path))

    # Cross-file validations
    all_errors.extend(validate_source_schema_identity())
    all_errors.extend(validate_shared_consistency())
    all_errors.extend(validate_cross_cutting_controls())

    return all_errors


# --- pytest integration ---

def test_all_validations():
    """Pytest entry point — runs all validations."""
    errors = run_validation()
    if errors:
        error_messages = "\n".join(f"  - {e}" for e in errors)
        raise AssertionError(f"Validation errors found:\n{error_messages}")


def test_cognitive_schema_requires_provenance(tmp_path):
    """Canonical cognitive schemas cannot lose their source metadata."""
    source = SCHEMAS_DIR / "4.2.10-memory-attention-and-executive-function.consideration.yaml"
    data = yaml.safe_load(source.read_text(encoding="utf-8"))
    data.pop("provenance")
    candidate = tmp_path / source.name
    candidate.write_text(yaml.safe_dump(data, sort_keys=False), encoding="utf-8")
    errors = validate_schema(candidate)
    assert any("Missing provenance object" in error.message for error in errors)


def test_elaborated_schema_requires_substantive_variation(tmp_path):
    """Canonical elaborated schemas cannot ship an empty strategy collection."""
    source = SCHEMAS_DIR / "4.2.10-memory-attention-and-executive-function.consideration.yaml"
    data = yaml.safe_load(source.read_text(encoding="utf-8"))
    data["strategies"] = []
    candidate = tmp_path / source.name
    candidate.write_text(yaml.safe_dump(data, sort_keys=False), encoding="utf-8")
    errors = validate_schema(candidate)
    assert any(
        "JSON Schema violation at strategies" in error.message for error in errors
    )


def test_elaborated_schema_rejects_malformed_nested_values(tmp_path):
    """Canonical JSON Schema validation rejects malformed nested consideration values."""
    source = SCHEMAS_DIR / "4.2.2-visual-adaptation.consideration.yaml"
    source_data = yaml.safe_load(source.read_text(encoding="utf-8"))
    mutations = (
        ("empty assistive technology", lambda data: data["assistive_tech"].__setitem__(0, {})),
        ("missing evaluation field", lambda data: data["evaluation"].pop("access_constraints")),
        ("null heuristic override", lambda data: data["heuristic_overrides"].__setitem__("1", None)),
    )
    for label, mutate in mutations:
        data = yaml.safe_load(yaml.safe_dump(source_data, sort_keys=False))
        mutate(data)
        candidate = tmp_path / f"{label.replace(' ', '-')}.consideration.yaml"
        candidate.write_text(yaml.safe_dump(data, sort_keys=False), encoding="utf-8")
        errors = validate_schema(candidate)
        assert any("JSON Schema violation" in error.message for error in errors), label


def test_cognitive_interaction_context_requires_conditional_language(tmp_path):
    """A qualifier elsewhere cannot mask an absolute cognitive interaction context."""
    source = SCHEMAS_DIR / "4.2.10-memory-attention-and-executive-function.consideration.yaml"
    data = yaml.safe_load(source.read_text(encoding="utf-8"))
    data["interaction_contexts"][0]["behavior"] = "This user always follows one fixed strategy."
    candidate = tmp_path / source.name
    candidate.write_text(yaml.safe_dump(data, sort_keys=False), encoding="utf-8")
    errors = validate_schema(candidate)
    assert any("lacks conditional language" in error.message for error in errors)


def test_interpretation_guidance_rejects_missing_anti_stereotype_policy():
    """Policy existence alone cannot satisfy the interpretation safeguard."""
    text = (METHODOLOGY_DIR / "consideration-interpretation.md").read_text(encoding="utf-8")
    incomplete = text.replace(
        "Do not compress multiple strategies into one supposedly universal behavior.",
        "",
    )
    errors = validate_interpretation_guidance(incomplete)
    assert any("universal behavior" in error.message for error in errors)


def test_codeowners_rejects_unowned_prompt_content():
    """Prompt-bearing source paths cannot silently lose required owner review."""
    text = (GOVERNANCE_ROOT / ".github" / "CODEOWNERS").read_text(encoding="utf-8")
    owner_list = " ".join(REQUIRED_CODEOWNERS)
    incomplete = text.replace(f"/Accessibility-Considerations-Toolkit/methodology/ {owner_list}", "")
    errors = validate_codeowners(incomplete)
    assert any("/methodology/" in error.message for error in errors)


def test_coga_notice_rejects_incomplete_2015_license():
    """The 2023 license copy cannot mask missing terms in the 2015 notice."""
    notice = (CONSIDERATIONS_DIR / "cognitive-accessibility-sources.LICENSE.md").read_text(encoding="utf-8")
    incomplete = notice.replace(
        "https://www.w3.org/Consortium/Legal/copyright-software-short-notice",
        "https://example.invalid/missing-2015-short-notice",
    )
    errors = validate_coga_notice(incomplete)
    assert any("2015 version complete normalized license text differs" in error.message for error in errors)


def test_coga_notice_rejects_removed_permission_grants():
    """Both complete W3C permission grants must remain in the distributed notice."""
    notice = (CONSIDERATIONS_DIR / "cognitive-accessibility-sources.LICENSE.md").read_text(encoding="utf-8")
    incomplete, replacements = re.subn(
        r"Permission to copy, modify, and distribute this work,.*?"
        r"of the work or portions thereof, including modifications:\n",
        "",
        notice,
        flags=re.DOTALL,
    )
    assert replacements == 2
    errors = validate_coga_notice(incomplete)
    assert sum(
        "complete normalized license text differs" in error.message
        for error in errors
    ) == 2


def test_coga_notice_rejects_obsolete_2026_holder():
    """The 2026 source must retain the copyright-holder form from the 2023 license."""
    notice = (CONSIDERATIONS_DIR / "cognitive-accessibility-sources.LICENSE.md").read_text(encoding="utf-8")
    obsolete = notice.replace(
        "Copyright © 2026 World Wide Web Consortium.",
        "Copyright © 2026 W3C® (MIT, ERCIM, Keio, Beihang).",
    )
    errors = validate_coga_notice(obsolete)
    assert any("obsolete 2015 copyright-holder form" in error.message for error in errors)


# --- CLI entry point ---

if __name__ == "__main__":
    errors = run_validation()
    if errors:
        print(f"FAILED — {len(errors)} validation error(s):\n")
        for e in errors:
            print(f"  ✗ {e}")
        sys.exit(1)
    else:
        consideration_count = len(get_schema_files())
        elaborated = sum(
            1
            for path in get_schema_files()
            if yaml.safe_load(path.read_text(encoding="utf-8")).get("status") == "elaborated"
        )
        print(f"PASSED — {consideration_count} consideration schemas validated ({elaborated} elaborated)")
        sys.exit(0)
