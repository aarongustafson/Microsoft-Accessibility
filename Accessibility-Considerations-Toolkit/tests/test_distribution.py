"""Distribution-path and original-image contracts, without model calls."""

from __future__ import annotations

import copy
import json
import struct
import zlib
from xml.etree import ElementTree

import pytest

from tests import validate_structure

ROOT = validate_structure.REPO_ROOT
IMAGES = ROOT / "tests" / "fixtures" / "images"


def _manifest():
    return json.loads((ROOT / "provenance.json").read_text(encoding="utf-8"))


def test_distribution_manifest_covers_sources_and_renders():
    manifest = _manifest()
    assert not validate_structure.validate_distribution_manifest(manifest)
    fixtures = next(item for item in manifest["materials"] if item["id"] == "original-eval-fixtures")
    assert set(fixtures["content"]) == {
        f"tests/fixtures/images/{name}.{suffix}"
        for name in ("combobox", "colour-contrast")
        for suffix in ("svg", "png")
    }
    assert fixtures["adaptation"] is False
    assert fixtures["upstreamLicense"] == "MIT"


@pytest.mark.parametrize("path", ("missing.png", "../outside.md", "/absolute.md"))
def test_manifest_rejects_missing_or_outside_paths(path):
    manifest = copy.deepcopy(_manifest())
    manifest["materials"][0]["requiredNotice"] = path
    assert validate_structure.validate_distribution_manifest(manifest)


def test_manifest_requires_wcag_notice_and_both_coga_representations():
    manifest = _manifest()
    manifest["materials"][0]["content"] = [
        path for path in manifest["materials"][0]["content"] if path.startswith("schemas/")
    ]
    manifest["materials"] = [
        item for item in manifest["materials"] if item["id"] != "w3c-wcag-reference"
    ]
    errors = validate_structure.validate_distribution_manifest(manifest)
    assert any("COGA content paths" in error.message for error in errors)
    assert any("Missing w3c-wcag-reference" in error.message for error in errors)


@pytest.mark.parametrize("value", (None, [], {"schemaVersion": 1, "materials": [None]}))
def test_manifest_reports_invalid_shape(value):
    assert validate_structure.validate_distribution_manifest(value)


def test_manifest_reports_invalid_source_urls():
    manifest = _manifest()
    manifest["materials"][0]["sourceUrls"] = [{"url": "invalid"}]
    assert validate_structure.validate_distribution_manifest(manifest)


@pytest.mark.parametrize("name", ("combobox", "colour-contrast"))
def test_png_dimensions_integrity_and_metadata(name):
    image = (IMAGES / f"{name}.png").read_bytes()
    assert image[:8] == b"\x89PNG\r\n\x1a\n"
    offset = 8
    chunks = []
    while offset < len(image):
        length = struct.unpack(">I", image[offset:offset + 4])[0]
        kind = image[offset + 4:offset + 8]
        payload = image[offset + 8:offset + 8 + length]
        checksum = struct.unpack(">I", image[offset + 8 + length:offset + 12 + length])[0]
        assert zlib.crc32(kind + payload) & 0xFFFFFFFF == checksum
        chunks.append(kind)
        if kind == b"IHDR":
            assert struct.unpack(">II", payload[:8]) == (960, 600)
        offset += length + 12
    assert chunks[0] == b"IHDR" and chunks[-1] == b"IEND"
    assert b"IDAT" in chunks
    assert not {b"eXIf", b"tEXt", b"zTXt", b"iTXt"} & set(chunks)
    source = ElementTree.parse(IMAGES / f"{name}.svg").getroot()
    assert source.attrib["width"] == "960" and source.attrib["height"] == "600"


def test_fixture_sources_keep_measurable_low_contrast_and_small_text():
    source = ElementTree.parse(IMAGES / "colour-contrast.svg").getroot()
    fills = {element.attrib.get("fill") for element in source.iter()}
    assert {"#ffff00", "#00dd00", "#00cccc"} <= fills
    assert any(element.attrib.get("font-size") == "11" for element in source.iter())
    for colour in ("#ffff00", "#00dd00", "#00cccc"):
        channels = [int(colour[index:index + 2], 16) / 255 for index in (1, 3, 5)]
        linear = [value / 12.92 if value <= 0.04045 else ((value + 0.055) / 1.055) ** 2.4 for value in channels]
        luminance = sum(value * weight for value, weight in zip(linear, (0.2126, 0.7152, 0.0722)))
        assert 1.05 / (luminance + 0.05) < 3


def test_all_image_tasks_use_original_pngs():
    from tests.evals.negative.eval_alternatives_to_colour_cues_difficulties import alternatives_to_colour_cues_test_website_image
    from tests.evals.negative.eval_visual_adaptation_difficulties import visual_adaptation_test_website_image
    from tests.evals.considerations.eval_keyboard_interaction import combobox_navigation_from_image
    from tests.evals.considerations.eval_visual_adaptation import image_combobox_review

    for builder, name in (
        (alternatives_to_colour_cues_test_website_image, "colour-contrast"),
        (visual_adaptation_test_website_image, "colour-contrast"),
        (combobox_navigation_from_image, "combobox"),
        (image_combobox_review, "combobox"),
    ):
        task = builder()
        assert len(task.dataset) == 1
        image = task.dataset[0].input[0].content[-1]
        assert image.image == str(IMAGES / f"{name}.png")
