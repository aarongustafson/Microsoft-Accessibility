"""Loaders for repository instruction files used as LLM context.

Each loader returns the file contents as a string, ready to embed in a
system prompt. Loaders never modify or duplicate content — they always
read from the canonical files in considerations/, heuristics/, methodology/,
and standards/.

When ``CONSIDERATION_SOURCE=schema``, consideration content is loaded from generated
YAML files in ``schemas/`` and rendered as self-contained YAML at load time. The
default (``CONSIDERATION_SOURCE=md``) reads raw markdown from ``considerations/``.
"""

from __future__ import annotations

import logging
import os
import re
from functools import lru_cache
from pathlib import Path

import yaml

logging.basicConfig(level=logging.INFO, format="%(name)s %(levelname)s: %(message)s")
logger = logging.getLogger(__name__)

REPO_ROOT = Path(__file__).resolve().parents[2]
CONSIDERATIONS_DIR = REPO_ROOT / "considerations"
SCHEMAS_DIR = REPO_ROOT / "schemas"
HEURISTICS_DIR = REPO_ROOT / "heuristics"
METHODOLOGY_DIR = REPO_ROOT / "methodology"
STANDARDS_DIR = REPO_ROOT / "standards"
_EVAL_CONSIDERATION_CONTEXT_MODE = "single"
_SINGLE_CONSIDERATION_CONTEXT_MODES = {"", "single", "specific", "consideration"}
_COMPACT_CONSIDERATION_CONTEXT_MODES = {"all", "multi", "multi-consideration", "all-considerations", "compact"}
_MEDIUM_CONSIDERATION_CONTEXT_MODES = {"medium", "medium-brief", "medium-briefs"}
_REQUIRED_CONSIDERATION_METHODOLOGY = (
    "licensing",
    "responsible-consideration-use",
    "consideration-interpretation",
)


def _read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


@lru_cache(maxsize=None)
def load_shared() -> str:
    return _read(CONSIDERATIONS_DIR / "_shared-considerations.md")


# ---------------------------------------------------------------------------
# Schema-based consideration loading (CONSIDERATION_SOURCE=schema)
# ---------------------------------------------------------------------------

def _get_consideration_source() -> str:
    """Return 'schema' or 'md' based on the CONSIDERATION_SOURCE env var."""
    source = os.environ.get("CONSIDERATION_SOURCE", "md").strip().lower()
    if source not in {"md", "schema"}:
        raise ValueError(f"Unsupported CONSIDERATION_SOURCE {source!r}; use 'md' or 'schema'.")
    return source


@lru_cache(maxsize=None)
def _load_consideration_schema_file(alias: str) -> dict:
    """Load a consideration YAML schema instance by alias from schemas/."""
    candidates = sorted(SCHEMAS_DIR.glob(f"*-{alias}.consideration.yaml"))
    if not candidates:
        candidates = sorted(SCHEMAS_DIR.glob(f"{alias}.consideration.yaml"))
    if not candidates:
        candidates = sorted(SCHEMAS_DIR.glob(f"{alias}-*.consideration.yaml"))
    if not candidates:
        raise FileNotFoundError(
            f"No consideration schema for alias '{alias}' in {SCHEMAS_DIR}"
        )
    if len(candidates) != 1:
        raise ValueError(
            f"Multiple consideration schemas for {alias!r}: "
            f"{[p.name for p in candidates]}; require a unique alias"
        )
    return yaml.safe_load(candidates[0].read_text(encoding="utf-8"))


@lru_cache(maxsize=None)
def _load_shared_schema() -> dict:
    """Load the structured shared YAML (schemas/_shared-considerations.yaml)."""
    path = SCHEMAS_DIR / "_shared-considerations.yaml"
    return yaml.safe_load(path.read_text(encoding="utf-8"))


def _render_consideration_from_schema(instance: dict) -> str:
    """Merge shared content into consideration schema instance and dump as YAML.

    The output is a self-contained YAML document with shared strategies,
    interaction contexts, and learning merged in (tagged from_shared: true) according
    to shared_excludes.
    """
    excludes = set(instance.get("shared_excludes", []))
    merged = {k: v for k, v in instance.items()}  # shallow copy preserving order

    if instance["status"] == "stub":
        return yaml.safe_dump(merged, allow_unicode=True, sort_keys=False, width=120)
    if instance["status"] != "elaborated":
        raise ValueError(f"Unsupported consideration status: {instance['status']!r}")

    shared = _load_shared_schema()

    # Merge shared strategies
    extra_strats = [
        {**s, "from_shared": True}
        for s in shared["strategies"]
        if s["id"] not in excludes
    ]
    merged["strategies"] = list(instance["strategies"]) + extra_strats

    # Merge shared interaction contexts
    extra_vars = [
        {**v, "from_shared": True}
        for v in shared["interaction_contexts"]
        if v["id"] not in excludes
    ]
    merged["interaction_contexts"] = list(instance["interaction_contexts"]) + extra_vars

    # Merge shared learning
    extra_learn = [
        {**lc, "from_shared": True}
        for lc in shared["learning"]
        if lc["id"] not in excludes
    ]
    merged["learning"] = list(instance["learning"]) + extra_learn

    header = (
        f"# Accessibility consideration: {instance['alias']} "
        f"(FPS {instance['clause']})\n"
        f"# Shared merged (excludes: {', '.join(sorted(excludes)) or 'none'})\n"
    )
    body = yaml.dump(
        merged,
        default_flow_style=False,
        allow_unicode=True,
        sort_keys=False,
        width=120,
    )
    return header + body


@lru_cache(maxsize=None)
def load_consideration(clause: str) -> str:
    """Load a consideration file by its clause number (e.g. '4.2.2').

    Picks the unique consideration file whose name starts with the clause.
    Raises FileNotFoundError if missing and ValueError if ambiguous.
    """
    candidates = sorted(CONSIDERATIONS_DIR.glob(f"{clause}-*.md"))
    if not candidates:
        raise FileNotFoundError(f"No consideration file for clause {clause}")
    if len(candidates) > 1:
        raise ValueError(
            f"Multiple considerations for clause {clause}: "
            f"{[p.name for p in candidates]}; use load_consideration_by_alias"
        )
    return _read(candidates[0])


def load_consideration_by_alias(alias: str) -> str:
    return _load_consideration_by_alias(alias, _get_consideration_source())


@lru_cache(maxsize=None)
def _load_consideration_by_alias(alias: str, source: str) -> str:
    if source == "schema":
        try:
            instance = _load_consideration_schema_file(alias)
        except FileNotFoundError:
            logger.warning(
                "Schema not found for consideration '%s'; falling back to markdown",
                alias,
            )
        else:
            result = _render_consideration_from_schema(instance)
            logger.info("Loaded consideration '%s' from schema (YAML)", alias)
            return result
    candidates = sorted(CONSIDERATIONS_DIR.glob(f"*-{alias}.md"))
    if not candidates:
        candidates = sorted(CONSIDERATIONS_DIR.glob(f"{alias}-*.md"))
    if not candidates:
        raise FileNotFoundError(f"No consideration file for alias '{alias}'")
    if len(candidates) != 1:
        raise ValueError(
            f"Multiple considerations for {alias!r}: "
            f"{[p.name for p in candidates]}; require a unique alias"
        )
    logger.info("Loaded consideration '%s' from markdown", alias)
    return _read(candidates[0])


# Ordered list of per-heuristic files. Index is the Nielsen number (1..10).
HEURISTIC_FILES: tuple[str, ...] = (
    "h1-visibility.md",
    "h2-match.md",
    "h3-control.md",
    "h4-consistency.md",
    "h5-error-prevention.md",
    "h6-recognition.md",
    "h7-flexibility.md",
    "h8-minimalist.md",
    "h9-errors.md",
    "h10-help.md",
)


@lru_cache(maxsize=None)
def load_heuristic_index() -> str:
    """Load the heuristics index file.

    Contains supplementary concerns (Privacy/Discreet, Bad Prediction) and a
    menu of the 10 Nielsen heuristics with filename pointers. Use this when
    the agent needs to plan which heuristics to load on demand.
    """
    return _read(HEURISTICS_DIR / "index.md")


@lru_cache(maxsize=None)
def load_heuristic(n: int) -> str:
    """Load a single Nielsen heuristic file by number (1..10)."""
    if not 1 <= n <= len(HEURISTIC_FILES):
        raise ValueError(f"Heuristic number out of range: {n}")
    return _read(HEURISTICS_DIR / HEURISTIC_FILES[n - 1])


def load_all_elaborated_consideration_briefs() -> str:
    return _load_all_elaborated_consideration_briefs(_get_consideration_source())


def _elaborated_consideration_documents(source: str):
    """Read briefs in the selected source mode without synthesizing identities."""
    if source == "schema":
        for path in sorted(SCHEMAS_DIR.glob("*.consideration.yaml")):
            instance = _load_consideration_schema_file(
                yaml.safe_load(_read(path))["alias"]
            )
            if instance["status"] != "elaborated":
                continue
            instance = yaml.safe_load(_render_consideration_from_schema(instance))
            evaluation = instance["evaluation"]
            lines = [
                yaml.safe_dump(
                    {key: instance[key] for key in ("clause", "alias", "title", "status")},
                    sort_keys=False,
                ).strip(),
                "## Evaluation Considerations",
                yaml.safe_dump(evaluation, allow_unicode=True, sort_keys=False).strip(),
            ]
            for section, field in (
                ("Exploration Strategies", "strategies"),
                ("Interaction Contexts", "interaction_contexts"),
            ):
                lines.append(f"## {section}")
                lines.extend(f"### {item['id']}" for item in instance[field])
            yield path, "\n".join(lines)
        return
    for path in sorted(CONSIDERATIONS_DIR.glob("*.md")):
        if path.name.startswith("_"):
            continue
        text = _read(path)
        if re.search(r"^status:\s*elaborated\s*$", text, re.MULTILINE):
            yield path, text


@lru_cache(maxsize=None)
def _load_all_elaborated_consideration_briefs(source: str) -> str:
    considerations: list[str] = []
    for path, text in _elaborated_consideration_documents(source):
        clause_match = re.search(r"^clause:\s*(.+?)\s*$", text, re.MULTILINE)
        alias_match = re.search(r"^alias:\s*(.+?)\s*$", text, re.MULTILINE)
        title_match = re.search(r"^title:\s*(.+?)\s*$", text, re.MULTILINE)
        clause = clause_match.group(1).strip().strip('"\'') if clause_match else ""
        alias = alias_match.group(1).strip().strip('"\'') if alias_match else path.stem
        title = title_match.group(1).strip().strip('"\'') if title_match else ""
        consideration_prompt = extract_section(text, "Evaluation Considerations")
        strategy_headings = _extract_h3_headings(extract_section(text, "Exploration Strategies"))
        variant_headings = _extract_h3_headings(extract_section(text, "Interaction Contexts"))
        brief_lines = [f"## {alias} ({clause} — {title})"]
        if consideration_prompt:
            brief_lines.extend(["### Evaluation Considerations", consideration_prompt])
        if strategy_headings:
            brief_lines.append("### Exploration Strategy Headings")
            brief_lines.extend(f"- {heading}" for heading in strategy_headings)
        if variant_headings:
            brief_lines.append("### Interaction Context Headings")
            brief_lines.extend(f"- {heading}" for heading in variant_headings)
        considerations.append("\n".join(brief_lines))
    return "\n\n".join(considerations)


@lru_cache(maxsize=None)
def load_heuristics() -> str:
    """Back-compat aggregator: concatenates the index and all 10 heuristic
    files into a single string. New callers should prefer
    ``load_heuristic_index()`` plus targeted ``load_heuristic(n)`` calls so
    they only pay for the heuristics the evaluation actually needs.
    """
    parts: list[str] = [load_heuristic_index().rstrip()]
    for n in range(1, len(HEURISTIC_FILES) + 1):
        parts.append(load_heuristic(n).rstrip())
    return "\n\n".join(parts) + "\n"


@lru_cache(maxsize=None)
def load_severity() -> str:
    return _read(HEURISTICS_DIR / "severity.md")


@lru_cache(maxsize=None)
def load_methodology(name: str) -> str:
    return _read(METHODOLOGY_DIR / f"{name}.md")


@lru_cache(maxsize=None)
def load_required_consideration_safeguards() -> str:
    """Load methodology that must accompany every consideration evaluation prompt."""
    return "\n\n".join(
        f"# Required methodology: methodology/{name}.md\n\n{load_methodology(name)}"
        for name in _REQUIRED_CONSIDERATION_METHODOLOGY
    )


def with_required_consideration_safeguards(consideration_context: str) -> str:
    """Prepend mandatory licensing, responsible-use, and interpretation policy."""
    return f"{load_required_consideration_safeguards()}\n\n# Consideration evaluation context\n\n{consideration_context}"


@lru_cache(maxsize=None)
def load_standard(name: str) -> str:
    """Load a standards reference file from ``standards/`` by base name
    (e.g. 'wcag-requirements')."""
    return _read(STANDARDS_DIR / f"{name}.md")


def set_eval_consideration_context_mode(mode: str) -> None:
    normalized = mode.strip().lower() or "single"
    allowed = (
        _SINGLE_CONSIDERATION_CONTEXT_MODES
        | _COMPACT_CONSIDERATION_CONTEXT_MODES
        | _MEDIUM_CONSIDERATION_CONTEXT_MODES
    )
    if normalized not in allowed:
        raise ValueError(
            "Unsupported consideration_context_mode "
            f"'{mode}'. Use 'single', 'all', or 'medium'."
        )

    global _EVAL_CONSIDERATION_CONTEXT_MODE
    _EVAL_CONSIDERATION_CONTEXT_MODE = normalized


def get_eval_consideration_context_mode() -> str:
    return _EVAL_CONSIDERATION_CONTEXT_MODE


def load_eval_consideration_context(alias: str) -> str:
    mode = get_eval_consideration_context_mode()
    if mode in _SINGLE_CONSIDERATION_CONTEXT_MODES:
        return with_required_consideration_safeguards(load_consideration_by_alias(alias))
    if mode in _COMPACT_CONSIDERATION_CONTEXT_MODES | _MEDIUM_CONSIDERATION_CONTEXT_MODES:
        primary_consideration = load_consideration_by_alias(alias)
        is_elaborated = bool(
            re.search(r"^status:\s*elaborated\s*$", primary_consideration, re.MULTILINE)
        )
        supporting_label = "Compact Catalog"
        supporting_considerations = load_all_elaborated_consideration_catalog_except(alias)
        if mode in _MEDIUM_CONSIDERATION_CONTEXT_MODES:
            supporting_label = "Medium Briefs"
            supporting_considerations = load_all_elaborated_consideration_medium_briefs_except(alias)
        background_instruction = (
            "Use the additional consideration briefs only as background context. "
            "Answer for the target consideration unless the prompt explicitly asks for multi-"
            "consideration synthesis. These are interface-evaluation scopes, not simulated "
            "people or predictions of individual behavior. Identify access requirements "
            "from explicit task circumstances; do not infer unrelated abilities. "
            "Do not average considerations together, substitute another scope's "
            "requirements, or dump the full loaded bundle back to the user."
        )
        if not is_elaborated:
            background_instruction += (
                " The primary consideration is a stub and remains authoritative. "
                "If the prompt asks for assistive technologies, exploration strategies, "
                "or interaction contexts that the stub does not define, explicitly acknowledge that "
                "the consideration is not yet elaborated and do not borrow or infer those "
                "details from the background considerations."
            )
        context = (
            "You are running a consideration eval module with all elaborated consideration briefs "
            "loaded into context. The primary target consideration for this module is "
            f"'{alias}'. The primary consideration definition below is authoritative for task "
            f"answers. {background_instruction}\n\n"
            f"# Primary Consideration (Authoritative)\n\n{primary_consideration}\n\n"
            f"# Multi-Consideration Guidance\n\n{load_methodology('multi-consideration')}\n\n"
            f"# Other Loaded Considerations ({supporting_label})\n\n"
            f"{supporting_considerations}"
        )
        return with_required_consideration_safeguards(context)
    raise ValueError(
        "Unsupported consideration_context_mode "
        f"'{mode}'. Use 'single', 'all', or 'medium'."
    )


def _extract_h3_headings(text: str) -> list[str]:
    return re.findall(r"^###\s+(.+?)\s*$", text, re.MULTILINE)


def load_all_elaborated_consideration_catalog_except(alias: str) -> str:
    return _load_all_elaborated_consideration_catalog_except(alias, _get_consideration_source())


@lru_cache(maxsize=None)
def _load_all_elaborated_consideration_catalog_except(alias: str, source: str) -> str:
    items: list[str] = []
    for path, text in _elaborated_consideration_documents(source):
        alias_match = re.search(r"^alias:\s*(.+?)\s*$", text, re.MULTILINE)
        item_alias = alias_match.group(1).strip().strip('"\'') if alias_match else path.stem
        if item_alias == alias:
            continue
        clause_match = re.search(r"^clause:\s*(.+?)\s*$", text, re.MULTILINE)
        title_match = re.search(r"^title:\s*(.+?)\s*$", text, re.MULTILINE)
        clause = clause_match.group(1).strip().strip('"\'') if clause_match else ""
        title = title_match.group(1).strip().strip('"\'') if title_match else ""
        consideration_prompt = re.sub(r"\s+", " ", extract_section(text, "Evaluation Considerations")).strip()
        summary = consideration_prompt[:220].rsplit(" ", 1)[0] if len(consideration_prompt) > 220 else consideration_prompt
        items.append(f"- {item_alias} ({clause} — {title}): {summary}")
    return "\n".join(items)


def load_all_elaborated_consideration_medium_briefs_except(alias: str) -> str:
    return _load_all_elaborated_consideration_medium_briefs_except(alias, _get_consideration_source())


@lru_cache(maxsize=None)
def _load_all_elaborated_consideration_medium_briefs_except(alias: str, source: str) -> str:
    items: list[str] = []
    for path, text in _elaborated_consideration_documents(source):
        alias_match = re.search(r"^alias:\s*(.+?)\s*$", text, re.MULTILINE)
        item_alias = alias_match.group(1).strip().strip('"\'') if alias_match else path.stem
        if item_alias == alias:
            continue
        clause_match = re.search(r"^clause:\s*(.+?)\s*$", text, re.MULTILINE)
        title_match = re.search(r"^title:\s*(.+?)\s*$", text, re.MULTILINE)
        clause = clause_match.group(1).strip().strip('"\'') if clause_match else ""
        title = title_match.group(1).strip().strip('"\'') if title_match else ""
        consideration_prompt = re.sub(r"\s+", " ", extract_section(text, "Evaluation Considerations")).strip()
        if len(consideration_prompt) > 320:
            consideration_prompt = consideration_prompt[:320].rsplit(" ", 1)[0] + "..."
        strategy_headings = _extract_h3_headings(
            extract_section(text, "Exploration Strategies")
        )[:3]
        variant_headings = _extract_h3_headings(
            extract_section(text, "Interaction Contexts")
        )[:3]

        lines = [f"## {item_alias} ({clause} — {title})"]
        if consideration_prompt:
            lines.append(f"Evaluation considerations: {consideration_prompt}")
        if strategy_headings:
            lines.append("Strategy headings: " + "; ".join(strategy_headings))
        if variant_headings:
            lines.append("Interaction context headings: " + "; ".join(variant_headings))
        items.append("\n".join(lines))
    return "\n\n".join(items)


def extract_section(text: str, heading: str, level: int = 2) -> str:
    """Return the raw text under a markdown heading, up to the next
    same-or-higher-level heading or end of file. Used by deterministic
    consistency checks; not used to rewrite content."""
    marker = "#" * level
    pattern = rf"^{re.escape(marker)} {re.escape(heading)}\n(.*?)(?=^#{{1,{level}}} |\Z)"
    match = re.search(pattern, text, re.MULTILINE | re.DOTALL)
    if not match:
        return ""
    return match.group(1).strip()


def extract_consideration_section(text: str, heading: str) -> str:
    """Extract a canonical section from raw Markdown or rendered schema YAML."""
    if text.startswith("---"):
        return extract_section(text, heading)
    fields = {
        "Evaluation Considerations": "evaluation",
        "Assistive Technologies": "assistive_tech",
        "Exploration Strategies": "strategies",
        "Interaction Contexts": "interaction_contexts",
        "Learning Considerations": "learning",
        "Heuristic Lens Overrides": "heuristic_overrides",
    }
    instance = yaml.safe_load(text)
    field = fields[heading]
    if field not in instance:
        return ""
    return yaml.safe_dump(
        instance[field], allow_unicode=True, sort_keys=False, width=120
    ).strip()
