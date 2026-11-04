#!/usr/bin/env python3
"""Host-side font validator for ksu-noto-fonts-apple-emoji.

Checks exact build/fonts manifest, SHA-256 digests against sources.lock for the 8
TTF overlays, fontTools table/name/fvar/cmap/CBDT invariants on all 8 TTFs and all
4 faces of NotoSansCJK-Regular.ttc (0=JP, 1=KR, 2=SC, 3=TC), and native FreeType +
HarfBuzz face indexing, glyph mapping, and variable-weight shaping.
Run with: python3 -I tools/check_fonts.py <font_dir> [--lock sources.lock]
"""

import argparse
import ctypes
import ctypes.util
import hashlib
import io
import os
import struct
import sys
from fontTools.ttLib import TTCollection, TTFont


LATIN_UPRIGHT_SPEC = {
    "upstream": "KSU-NotoSans-Regular-VF.ttf",
    "family": "Noto Sans",
    "subfamily": "Regular",
    "ps_prefix": "NotoSans-Regular",
    "axes": {
        "wght": (100.0, 400.0, 900.0),
        "wdth": (62.5, 100.0, 100.0),
    },
    "required_tables": ["fvar", "cmap", "GSUB", "GPOS", "HVAR", "gvar"],
    "forbidden_tables": ["CBDT", "CBLC"],
    "min_glyphs": 2500,
    "codepoints": [0x0041, 0x0061, 0x0030, 0x00E9, 0x0142, 0x0391, 0x0410],
    "sample_text": "Hello Noto 0123",
    "sample_lang": "en",
}

EXPECTED_TTF_SPECS = {
    "SysFont-Regular.ttf": dict(LATIN_UPRIGHT_SPEC),
    "Roboto-Regular.ttf": dict(LATIN_UPRIGHT_SPEC),
    "SysSans-En-Regular.ttf": dict(LATIN_UPRIGHT_SPEC),
    "OPSans-En-Regular.ttf": dict(LATIN_UPRIGHT_SPEC),
    "NotoSans-Italic.ttf": {
        "upstream": "KSU-NotoSans-Italic-VF.ttf",
        "family": "Noto Sans",
        "subfamily": "Italic",
        "ps_prefix": "NotoSans-Italic",
        "axes": {
            "wght": (100.0, 400.0, 900.0),
            "wdth": (62.5, 100.0, 100.0),
        },
        "required_tables": ["fvar", "cmap", "GSUB", "GPOS", "HVAR", "gvar"],
        "forbidden_tables": ["CBDT", "CBLC"],
        "min_glyphs": 2500,
        "codepoints": [0x0041, 0x0061, 0x0030, 0x00E9, 0x0142, 0x0391, 0x0410],
        "sample_text": "Italic Noto 0123",
        "sample_lang": "en",
    },
    "SysSans-Hans-Regular.ttf": {
        "upstream": "KSU-NotoSansCJKsc-VF.ttf",
        "family": "Noto Sans CJK SC",
        "subfamily": "Regular",
        "ps_prefix": "NotoSansCJKsc-",
        "axes": {
            "wght": (100.0, 100.0, 900.0),
        },
        "required_tables": ["fvar", "cmap", "GSUB", "GPOS", "HVAR", "gvar"],
        "forbidden_tables": ["CBDT", "CBLC"],
        "min_glyphs": 40000,
        "codepoints": [0x4E2D, 0x6587, 0x5B57, 0x4F53, 0x9AA8, 0x76F4, 0x3002],
        "sample_text": "骨直中文字体",
        "sample_lang": "zh-Hans",
    },
    "SysSans-Hant-Regular.ttf": {
        "upstream": "KSU-NotoSansCJKtc-VF.ttf",
        "family": "Noto Sans CJK TC",
        "subfamily": "Regular",
        "ps_prefix": "NotoSansCJKtc-",
        "axes": {
            "wght": (100.0, 100.0, 900.0),
        },
        "required_tables": ["fvar", "cmap", "GSUB", "GPOS", "HVAR", "gvar"],
        "forbidden_tables": ["CBDT", "CBLC"],
        "min_glyphs": 40000,
        "codepoints": [0x4E2D, 0x570B, 0x7E41, 0x9AD4, 0x9AA8, 0x76F4, 0x3002],
        "sample_text": "骨直中國繁體",
        "sample_lang": "zh-Hant",
    },
    "NotoColorEmoji.ttf": {
        "upstream": "KSU-AppleColorEmoji.ttf",
        "family": "Apple Color Emoji",
        "subfamily": "Regular",
        "ps_prefix": "AppleColorEmoji",
        "axes": {},
        "required_tables": ["CBDT", "CBLC", "cmap"],
        "forbidden_tables": ["fvar", "sbix"],
        "min_glyphs": 1000,
        "codepoints": [0x1F600, 0x2764, 0x1F44D, 0x1F3FD, 0x200D, 0x1F525, 0x1F389],
        "check_cbdt": True,
        "sample_text": "\U0001F600\U0001F525\U0001F389",
        "sample_lang": "en",
    },
}

TTC_FILENAME = "NotoSansCJK-Regular.ttc"
MANIFEST_FILENAME = "font-manifest.txt"
TTC_SOURCES = [
    "KSU-NotoSansCJKjp-VF.ttf",  # index 0: JP
    "KSU-NotoSansCJKkr-VF.ttf",  # index 1: KR
    "KSU-NotoSansCJKsc-VF.ttf",  # index 2: SC
    "KSU-NotoSansCJKtc-VF.ttf",  # index 3: TC
]
SHARED_TTC_TABLES = ["fvar", "HVAR", "glyf", "gvar", "hhea", "hmtx", "loca", "maxp", "post"]

TTC_FACE_SPECS = [
    {
        "index": 0,
        "upstream": "KSU-NotoSansCJKjp-VF.ttf",
        "family": "Noto Sans CJK JP",
        "subfamily": "Regular",
        "ps_prefix": "NotoSansCJKjp-",
        "axes": {"wght": (100.0, 100.0, 900.0)},
        "required_tables": ["fvar", "cmap", "GSUB", "GPOS", "HVAR", "gvar"],
        "forbidden_tables": ["CBDT", "CBLC"],
        "min_glyphs": 40000,
        "codepoints": [0x3042, 0x30A2, 0x65E5, 0x672C, 0x8A9E, 0x9AA8, 0x76F4],
        "sample_text": "骨直日本語あア",
        "sample_lang": "ja",
    },
    {
        "index": 1,
        "upstream": "KSU-NotoSansCJKkr-VF.ttf",
        "family": "Noto Sans CJK KR",
        "subfamily": "Regular",
        "ps_prefix": "NotoSansCJKkr-",
        "axes": {"wght": (100.0, 100.0, 900.0)},
        "required_tables": ["fvar", "cmap", "GSUB", "GPOS", "HVAR", "gvar"],
        "forbidden_tables": ["CBDT", "CBLC"],
        "min_glyphs": 40000,
        "codepoints": [0xD55C, 0xAE00, 0xAC00, 0xB098, 0x4E2D, 0x9AA8, 0x76F4],
        "sample_text": "骨直한국어가나",
        "sample_lang": "ko",
    },
    {
        "index": 2,
        "upstream": "KSU-NotoSansCJKsc-VF.ttf",
        "family": "Noto Sans CJK SC",
        "subfamily": "Regular",
        "ps_prefix": "NotoSansCJKsc-",
        "axes": {"wght": (100.0, 100.0, 900.0)},
        "required_tables": ["fvar", "cmap", "GSUB", "GPOS", "HVAR", "gvar"],
        "forbidden_tables": ["CBDT", "CBLC"],
        "min_glyphs": 40000,
        "codepoints": [0x4E2D, 0x6587, 0x5B57, 0x4F53, 0x9AA8, 0x76F4, 0x3002],
        "sample_text": "骨直中文字体",
        "sample_lang": "zh-Hans",
    },
    {
        "index": 3,
        "upstream": "KSU-NotoSansCJKtc-VF.ttf",
        "family": "Noto Sans CJK TC",
        "subfamily": "Regular",
        "ps_prefix": "NotoSansCJKtc-",
        "axes": {"wght": (100.0, 100.0, 900.0)},
        "required_tables": ["fvar", "cmap", "GSUB", "GPOS", "HVAR", "gvar"],
        "forbidden_tables": ["CBDT", "CBLC"],
        "min_glyphs": 40000,
        "codepoints": [0x4E2D, 0x570B, 0x7E41, 0x9AD4, 0x9AA8, 0x76F4, 0x3002],
        "sample_text": "骨直中國繁體",
        "sample_lang": "zh-Hant",
    },
]


def sha256_file(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        while True:
            chunk = f.read(1024 * 1024)
            if not chunk:
                break
            h.update(chunk)
    return h.hexdigest().lower()


def load_lock_hashes(lock_path: str) -> dict[str, str]:
    hashes: dict[str, str] = {}
    with open(lock_path, "r", encoding="utf-8") as f:
        for raw in f:
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            parts = line.split("|")
            if len(parts) != 5:
                raise ValueError(f"Malformed line in {lock_path}: {line}")
            kind, dest_name, _ref, _url, sha256 = parts
            if kind == "font":
                hashes[dest_name] = sha256.lower()
    return hashes


def get_name_record(font: TTFont, name_id: int) -> str:
    for rec in font["name"].names:
        if rec.nameID == name_id:
            try:
                return rec.toUnicode()
            except UnicodeDecodeError:
                continue
    return ""


def validate_ttfont_obj(font: TTFont, label: str, spec: dict) -> tuple[list[str], dict]:
    errors: list[str] = []

    core_tables = ["head", "hhea", "maxp", "name", "OS/2", "post"]
    for tbl in core_tables + list(spec["required_tables"]):
        if tbl not in font:
            if tbl in spec["required_tables"]:
                errors.append(f"{label}: missing required table '{tbl}'")
            else:
                errors.append(f"{label}: missing core SFNT table '{tbl}'")
            continue
        try:
            raw_tbl = font.reader[tbl]
            if not raw_tbl:
                errors.append(f"{label}: empty table '{tbl}'")
        except Exception as exc:
            errors.append(f"{label}: failed to read raw table '{tbl}': {exc}")

    for tbl in spec["forbidden_tables"]:
        if tbl in font:
            errors.append(f"{label}: unexpected forbidden table '{tbl}'")

    for decomp_tbl in ["head", "hhea", "maxp", "name"] + [
        t for t in ("fvar", "cmap", "HVAR", "GSUB", "GPOS", "CBLC", "CBDT") if t in spec["required_tables"]
    ]:
        if decomp_tbl in font:
            try:
                _ = font[decomp_tbl]
            except Exception as exc:
                errors.append(f"{label}: failed to decompile table '{decomp_tbl}': {exc}")

    if "name" in font:
        try:
            family = get_name_record(font, 1)
            subfamily = get_name_record(font, 2)
            ps_name = get_name_record(font, 6)
        except Exception as exc:
            family, subfamily, ps_name = "", "", ""
            errors.append(f"{label}: failed to read name records: {exc}")

        if family != spec["family"]:
            errors.append(f"{label}: family name mismatch (expected '{spec['family']}', got '{family}')")
        if subfamily != spec["subfamily"]:
            errors.append(f"{label}: subfamily mismatch (expected '{spec['subfamily']}', got '{subfamily}')")
        if not ps_name.startswith(spec["ps_prefix"]):
            errors.append(
                f"{label}: PostScript name mismatch (expected prefix '{spec['ps_prefix']}', got '{ps_name}')"
            )

    expected_axes = spec["axes"]
    if expected_axes:
        if "fvar" not in font:
            errors.append(f"{label}: missing fvar table for variable font")
        else:
            try:
                actual_axes = {
                    a.axisTag: (float(a.minValue), float(a.defaultValue), float(a.maxValue))
                    for a in font["fvar"].axes
                }
                if set(actual_axes.keys()) != set(expected_axes.keys()):
                    errors.append(
                        f"{label}: axis tags mismatch (expected {sorted(expected_axes.keys())}, got {sorted(actual_axes.keys())})"
                    )
                for tag, exp_bounds in expected_axes.items():
                    if tag in actual_axes:
                        act_bounds = actual_axes[tag]
                        if any(abs(a - b) > 0.01 for a, b in zip(act_bounds, exp_bounds)):
                            errors.append(
                                f"{label}: axis '{tag}' bounds {act_bounds} != expected {exp_bounds}"
                            )
            except Exception as exc:
                errors.append(f"{label}: failed to inspect fvar axes: {exc}")

    try:
        cmap = font.getBestCmap() or {}
    except Exception as exc:
        cmap = {}
        errors.append(f"{label}: failed to read best cmap: {exc}")

    if len(cmap) < spec["min_glyphs"]:
        errors.append(
            f"{label}: cmap size {len(cmap)} is smaller than minimum required {spec['min_glyphs']}"
        )

    for cp in spec["codepoints"]:
        if cp not in cmap:
            errors.append(f"{label}: missing required representative codepoint U+{cp:04X}")

    if spec.get("check_cbdt"):
        if "CBLC" in font and "CBDT" in font:
            try:
                strikes = getattr(font["CBLC"], "strikes", [])
                if not strikes:
                    errors.append(f"{label}: CBLC table has 0 bitmap strikes")
                else:
                    bit_depths = {s.bitmapSizeTable.bitDepth for s in strikes}
                    if 32 not in bit_depths:
                        errors.append(f"{label}: CBLC strikes missing 32-bit color depth (got {sorted(bit_depths)})")
                    non_empty_strikes = sum(1 for s in strikes if getattr(s, "indexSubTables", []))
                    if non_empty_strikes == 0:
                        errors.append(f"{label}: CBLC strikes contain no indexSubTables")
                cbdt_data = getattr(font["CBDT"], "strikeData", None)
                if not cbdt_data or sum(len(s) for s in cbdt_data) == 0:
                    errors.append(f"{label}: CBDT strikeData is missing or empty")
            except Exception as exc:
                errors.append(f"{label}: failed to inspect CBLC/CBDT strikes: {exc}")

    return errors, cmap


def check_single_ttf(path: str, filename: str, spec: dict, expected_sha: str = "") -> list[str]:
    errors: list[str] = []
    if not os.path.isfile(path):
        return [f"{filename}: file does not exist at {path}"]

    if expected_sha:
        actual_sha = sha256_file(path)
        if actual_sha != expected_sha:
            errors.append(
                f"{filename}: SHA-256 mismatch (expected {expected_sha}, got {actual_sha})"
            )

    try:
        font = TTFont(path, lazy=False)
    except Exception as exc:
        return errors + [f"{filename}: failed to parse TTFont: {exc}"]

    obj_errs, _cmap = validate_ttfont_obj(font, filename, spec)
    errors.extend(obj_errs)
    font.close()
    return errors


def validate_ttc_bytes(
    ttc_bytes: bytes,
    filename: str = TTC_FILENAME,
    source_ttfs: dict[int, bytes] | None = None,
    check_size_bounds: bool = False,
) -> list[str]:
    errors: list[str] = []
    size = len(ttc_bytes)
    if check_size_bounds and (size < 30_000_000 or size > 55_000_000):
        errors.append(f"{filename}: unexpected TTC size {size} bytes (expected ~37.6MB shared TTC)")

    if size < 28 or ttc_bytes[:4] != b"ttcf":
        return errors + [f"{filename}: invalid TTC magic header {ttc_bytes[:4]!r} (expected b'ttcf')"]

    _maj, _min, num_faces = struct.unpack(">HHI", ttc_bytes[4:12])
    if num_faces != len(TTC_FACE_SPECS):
        return errors + [
            f"{filename}: unexpected TTC header face count {num_faces} (expected {len(TTC_FACE_SPECS)})"
        ]

    offsets = struct.unpack(f">{num_faces}I", ttc_bytes[12 : 12 + 4 * num_faces])
    if len(set(offsets)) != num_faces or any(off < 28 or off >= size for off in offsets):
        return errors + [f"{filename}: invalid or duplicate TTC face directory offsets: {offsets}"]

    try:
        ttc = TTCollection(io.BytesIO(ttc_bytes), lazy=False)
    except Exception as exc:
        return errors + [f"{filename}: failed to parse TTCollection: {exc}"]

    if len(ttc.fonts) != len(TTC_FACE_SPECS):
        errors.append(f"{filename}: expected {len(TTC_FACE_SPECS)} faces, got {len(ttc.fonts)}")
        return errors

    bone_gids: dict[int, int] = {}
    for spec in TTC_FACE_SPECS:
        idx = spec["index"]
        label = f"{filename}[{idx}]"
        face = ttc.fonts[idx]
        face_errs, cmap = validate_ttfont_obj(face, label, spec)
        errors.extend(face_errs)
        if 0x9AA8 in cmap:
            try:
                bone_gids[idx] = face.getGlyphID(cmap[0x9AA8])
            except Exception as exc:
                errors.append(f"{label}: failed to resolve glyph ID for U+9AA8: {exc}")

    if len(bone_gids) == 4:
        if len({bone_gids[0], bone_gids[2], bone_gids[3]}) != 3:
            errors.append(
                f"{filename}: regional glyph U+9AA8 (骨) not distinct across JP/SC/TC faces: {bone_gids}"
            )

    # Verify shared table byte equality across all 4 TTC faces
    face0_keys = set(ttc.fonts[0].reader.keys())
    for idx in range(1, len(TTC_FACE_SPECS)):
        if set(ttc.fonts[idx].reader.keys()) != face0_keys:
            errors.append(
                f"{filename}[{idx}]: table tag set {sorted(ttc.fonts[idx].reader.keys())} != face 0 {sorted(face0_keys)}"
            )
    for shared_tag in SHARED_TTC_TABLES:
        if all(shared_tag in ttc.fonts[i].reader for i in range(len(TTC_FACE_SPECS))):
            ref_bytes = ttc.fonts[0].reader[shared_tag]
            for idx in range(1, len(TTC_FACE_SPECS)):
                if ttc.fonts[idx].reader[shared_tag] != ref_bytes:
                    errors.append(
                        f"{filename}: shared table '{shared_tag}' differs between face 0 and face {idx}"
                    )

    # Verify TTC face tables against all 4 locked source CJK TTFs (fail closed if any source is missing)
    for spec in TTC_FACE_SPECS:
        idx = spec["index"]
        src_name = spec["upstream"]
        label = f"{filename}[{idx}]"
        src_bytes = source_ttfs.get(idx) if source_ttfs else None
        if not src_bytes:
            errors.append(
                f"{label}: missing verified CJK source TTF {src_name} for TTC face table comparison"
            )
            continue
        try:
            src_font = TTFont(io.BytesIO(src_bytes), lazy=True)
        except Exception as exc:
            errors.append(f"{label}: failed to open source TTF for comparison: {exc}")
            continue
        face = ttc.fonts[idx]
        ttc_tags = set(face.reader.keys())
        src_tags = set(src_font.reader.keys())
        if ttc_tags != src_tags:
            errors.append(
                f"{label}: table set mismatch vs source TTF ({sorted(ttc_tags)} != {sorted(src_tags)})"
            )
        for tag in sorted(ttc_tags & src_tags):
            b_ttc = face.reader[tag]
            b_src = src_font.reader[tag]
            if tag == "head":
                if (
                    len(b_ttc) != len(b_src)
                    or len(b_ttc) < 36
                    or b_ttc[:8] != b_src[:8]
                    or b_ttc[12:28] != b_src[12:28]
                    or b_ttc[36:] != b_src[36:]
                ):
                    errors.append(f"{label}: 'head' table mismatch vs source TTF")
            elif b_ttc != b_src:
                errors.append(f"{label}: table '{tag}' bytes mismatch vs source TTF")
        src_font.close()

    for f in ttc.fonts:
        f.close()
    return errors


def check_ttc(
    path: str,
    filename: str,
    source_ttfs: dict[int, bytes] | None = None,
) -> list[str]:
    if not os.path.isfile(path):
        return [f"{filename}: file does not exist at {path}"]
    with open(path, "rb") as fh:
        data = fh.read()
    return validate_ttc_bytes(
        data,
        filename=filename,
        source_ttfs=source_ttfs,
        check_size_bounds=True,
    )


def validate_font_manifest_text(
    manifest_text: str,
    lock_font_hashes: dict[str, str],
    actual_artifact_hashes: dict[str, str],
) -> tuple[list[str], dict[str, str]]:
    errors: list[str] = []
    manifest_artifact_hashes: dict[str, str] = {}
    seen_paths: list[str] = []

    expected_overlay = {
        f"system/fonts/{fname}": spec["upstream"]
        for fname, spec in EXPECTED_TTF_SPECS.items()
    }
    expected_ttc_path = f"system/fonts/{TTC_FILENAME}"
    expected_ttc_sources = ",".join(f"{idx}={s}" for idx, s in enumerate(TTC_SOURCES))
    missing_ttc_locks = [s for s in TTC_SOURCES if s not in lock_font_hashes]
    if missing_ttc_locks:
        errors.append(f"{MANIFEST_FILENAME}: missing TTC source fonts in lockfile: {missing_ttc_locks}")
        expected_ttc_src_shas = ""
    else:
        expected_ttc_src_shas = ",".join(
            f"{idx}={lock_font_hashes[s]}" for idx, s in enumerate(TTC_SOURCES)
        )

    for raw_line in manifest_text.splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split("|")
        if len(parts) != 5:
            errors.append(f"{MANIFEST_FILENAME}: malformed line: {line!r}")
            continue
        kind, zip_path, upstream_src, upstream_sha, artifact_sha = parts
        seen_paths.append(zip_path)
        if zip_path in manifest_artifact_hashes:
            errors.append(f"{MANIFEST_FILENAME}: duplicate entry for {zip_path}")
            continue

        if len(artifact_sha) != 64 or any(c not in "0123456789abcdef" for c in artifact_sha):
            errors.append(f"{MANIFEST_FILENAME}: invalid artifact SHA-256 for {zip_path}: {artifact_sha!r}")

        manifest_artifact_hashes[zip_path] = artifact_sha

        if kind == "overlay_ttf":
            if zip_path not in expected_overlay:
                errors.append(f"{MANIFEST_FILENAME}: unexpected overlay_ttf path {zip_path}")
                continue
            exp_src = expected_overlay[zip_path]
            exp_src_sha = lock_font_hashes.get(exp_src, "")
            if upstream_src != exp_src:
                errors.append(
                    f"{MANIFEST_FILENAME}: {zip_path} upstream_sources={upstream_src!r} != expected {exp_src!r}"
                )
            if not exp_src_sha or upstream_sha != exp_src_sha:
                errors.append(
                    f"{MANIFEST_FILENAME}: {zip_path} upstream_source_sha256={upstream_sha!r} != lock {exp_src_sha!r}"
                )
            if artifact_sha != upstream_sha:
                errors.append(
                    f"{MANIFEST_FILENAME}: {zip_path} overlay_ttf artifact_sha256={artifact_sha!r} != upstream_source_sha256={upstream_sha!r}"
                )
        elif kind == "generated_ttc":
            if zip_path != expected_ttc_path:
                errors.append(f"{MANIFEST_FILENAME}: unexpected generated_ttc path {zip_path}")
                continue
            if upstream_src != expected_ttc_sources:
                errors.append(
                    f"{MANIFEST_FILENAME}: {zip_path} upstream_sources={upstream_src!r} != expected {expected_ttc_sources!r}"
                )
            if expected_ttc_src_shas and upstream_sha != expected_ttc_src_shas:
                errors.append(
                    f"{MANIFEST_FILENAME}: {zip_path} upstream_source_sha256={upstream_sha!r} != lock {expected_ttc_src_shas!r}"
                )
        else:
            errors.append(f"{MANIFEST_FILENAME}: unknown kind {kind!r} for {zip_path}")

        if zip_path in actual_artifact_hashes:
            act_sha = actual_artifact_hashes[zip_path]
            if artifact_sha != act_sha:
                errors.append(
                    f"{MANIFEST_FILENAME}: {zip_path} artifact_sha256={artifact_sha} != actual {act_sha}"
                )

    if seen_paths != sorted(seen_paths):
        errors.append(f"{MANIFEST_FILENAME}: entries are not in canonical sorted order by zip_path")

    expected_all_paths = set(expected_overlay.keys()) | {expected_ttc_path}
    missing_paths = sorted(expected_all_paths - set(manifest_artifact_hashes.keys()))
    unexpected_paths = sorted(set(manifest_artifact_hashes.keys()) - expected_all_paths)
    if missing_paths:
        errors.append(f"{MANIFEST_FILENAME}: missing required font entries: {missing_paths}")
    if unexpected_paths:
        errors.append(f"{MANIFEST_FILENAME}: unexpected font entries: {unexpected_paths}")

    return errors, manifest_artifact_hashes


class _FTFaceRec(ctypes.Structure):
    _fields_ = [
        ("num_faces", ctypes.c_long),
        ("face_index", ctypes.c_long),
        ("face_flags", ctypes.c_long),
        ("style_flags", ctypes.c_long),
        ("num_glyphs", ctypes.c_long),
        ("family_name", ctypes.c_char_p),
        ("style_name", ctypes.c_char_p),
    ]


class _HBVarAxisInfo(ctypes.Structure):
    _fields_ = [
        ("axis_index", ctypes.c_uint),
        ("tag", ctypes.c_uint32),
        ("name_id", ctypes.c_uint),
        ("flags", ctypes.c_uint),
        ("min_value", ctypes.c_float),
        ("default_value", ctypes.c_float),
        ("max_value", ctypes.c_float),
        ("reserved", ctypes.c_uint * 5),
    ]


class _HBVariation(ctypes.Structure):
    _fields_ = [
        ("tag", ctypes.c_uint32),
        ("value", ctypes.c_float),
    ]


class _HBGlyphInfo(ctypes.Structure):
    _fields_ = [
        ("codepoint", ctypes.c_uint32),
        ("mask", ctypes.c_uint32),
        ("cluster", ctypes.c_uint32),
        ("var1", ctypes.c_uint32),
        ("var2", ctypes.c_uint32),
    ]


class _HBGlyphExtents(ctypes.Structure):
    _fields_ = [
        ("x_bearing", ctypes.c_int32),
        ("y_bearing", ctypes.c_int32),
        ("width", ctypes.c_int32),
        ("height", ctypes.c_int32),
    ]


def _hb_tag(tag_str: str) -> int:
    b = tag_str.encode("ascii")
    return (b[0] << 24) | (b[1] << 16) | (b[2] << 8) | b[3]


def check_native_freetype_and_harfbuzz(font_dir: str) -> list[str]:
    errors: list[str] = []
    ft_lib_name = ctypes.util.find_library("freetype")
    hb_lib_name = ctypes.util.find_library("harfbuzz")

    if not ft_lib_name:
        return ["Native FreeType library (libfreetype) not found"]
    if not hb_lib_name:
        return ["Native HarfBuzz library (libharfbuzz) not found"]

    ft = ctypes.CDLL(ft_lib_name)
    hb = ctypes.CDLL(hb_lib_name)

    # FreeType bindings
    ft.FT_Init_FreeType.argtypes = [ctypes.POINTER(ctypes.c_void_p)]
    ft.FT_Init_FreeType.restype = ctypes.c_int
    ft.FT_Done_FreeType.argtypes = [ctypes.c_void_p]
    ft.FT_Done_FreeType.restype = ctypes.c_int
    ft.FT_New_Face.argtypes = [
        ctypes.c_void_p,
        ctypes.c_char_p,
        ctypes.c_long,
        ctypes.POINTER(ctypes.POINTER(_FTFaceRec)),
    ]
    ft.FT_New_Face.restype = ctypes.c_int
    ft.FT_Done_Face.argtypes = [ctypes.c_void_p]
    ft.FT_Done_Face.restype = ctypes.c_int
    ft.FT_Get_Postscript_Name.argtypes = [ctypes.c_void_p]
    ft.FT_Get_Postscript_Name.restype = ctypes.c_char_p
    ft.FT_Get_Char_Index.argtypes = [ctypes.c_void_p, ctypes.c_ulong]
    ft.FT_Get_Char_Index.restype = ctypes.c_uint

    ft_lib = ctypes.c_void_p()
    if ft.FT_Init_FreeType(ctypes.byref(ft_lib)) != 0:
        return ["FT_Init_FreeType failed"]

    ttc_path = os.path.join(font_dir, TTC_FILENAME).encode("utf-8")
    ft_bone_gids: dict[int, int] = {}
    for spec in TTC_FACE_SPECS:
        idx = spec["index"]
        face_ptr = ctypes.POINTER(_FTFaceRec)()
        rc = ft.FT_New_Face(ft_lib, ttc_path, idx, ctypes.byref(face_ptr))
        if rc != 0:
            errors.append(f"FreeType: FT_New_Face failed on {TTC_FILENAME}[{idx}] with rc={rc}")
            continue
        face = face_ptr.contents
        fam = (face.family_name or b"").decode("utf-8", errors="replace")
        ps = (ft.FT_Get_Postscript_Name(face_ptr) or b"").decode("utf-8", errors="replace")
        if face.num_faces != 4:
            errors.append(f"FreeType: {TTC_FILENAME}[{idx}] num_faces={face.num_faces} != 4")
        if fam != spec["family"]:
            errors.append(f"FreeType: {TTC_FILENAME}[{idx}] family={fam!r} != {spec['family']!r}")
        if not ps.startswith(spec["ps_prefix"]):
            errors.append(f"FreeType: {TTC_FILENAME}[{idx}] ps={ps!r} does not start with {spec['ps_prefix']!r}")
        for cp in spec["codepoints"]:
            gid = ft.FT_Get_Char_Index(face_ptr, cp)
            if gid == 0:
                errors.append(f"FreeType: {TTC_FILENAME}[{idx}] FT_Get_Char_Index(U+{cp:04X}) == 0")
        ft_bone_gids[idx] = ft.FT_Get_Char_Index(face_ptr, 0x9AA8)
        ft.FT_Done_Face(face_ptr)

    if len(ft_bone_gids) == 4:
        if (
            ft_bone_gids[0] == ft_bone_gids[2]
            or ft_bone_gids[2] == ft_bone_gids[3]
            or ft_bone_gids[0] == ft_bone_gids[3]
        ):
            errors.append(f"FreeType: {TTC_FILENAME} regional GIDs for U+9AA8 not distinct: {ft_bone_gids}")

    # Out-of-bounds index 4 must fail in FreeType
    oob_face = ctypes.POINTER(_FTFaceRec)()
    if ft.FT_New_Face(ft_lib, ttc_path, 4, ctypes.byref(oob_face)) == 0:
        ft.FT_Done_Face(oob_face)
        errors.append(f"FreeType: {TTC_FILENAME}[4] unexpectedly succeeded on out-of-range face index")

    for filename, spec in sorted(EXPECTED_TTF_SPECS.items()):
        p = os.path.join(font_dir, filename).encode("utf-8")
        face_ptr = ctypes.POINTER(_FTFaceRec)()
        rc = ft.FT_New_Face(ft_lib, p, 0, ctypes.byref(face_ptr))
        if rc != 0:
            errors.append(f"FreeType: FT_New_Face failed on {filename} with rc={rc}")
            continue
        face = face_ptr.contents
        if face.num_faces != 1:
            errors.append(f"FreeType: {filename} num_faces={face.num_faces} != 1")
        for cp in spec["codepoints"]:
            if ft.FT_Get_Char_Index(face_ptr, cp) == 0:
                errors.append(f"FreeType: {filename} FT_Get_Char_Index(U+{cp:04X}) == 0")
        ft.FT_Done_Face(face_ptr)

    ft.FT_Done_FreeType(ft_lib)

    # HarfBuzz bindings
    hb.hb_blob_create_from_file_or_fail.argtypes = [ctypes.c_char_p]
    hb.hb_blob_create_from_file_or_fail.restype = ctypes.c_void_p
    hb.hb_blob_destroy.argtypes = [ctypes.c_void_p]
    hb.hb_face_count.argtypes = [ctypes.c_void_p]
    hb.hb_face_count.restype = ctypes.c_uint
    hb.hb_face_create.argtypes = [ctypes.c_void_p, ctypes.c_uint]
    hb.hb_face_create.restype = ctypes.c_void_p
    hb.hb_face_destroy.argtypes = [ctypes.c_void_p]
    hb.hb_ot_var_get_axis_infos.argtypes = [
        ctypes.c_void_p,
        ctypes.c_uint,
        ctypes.POINTER(ctypes.c_uint),
        ctypes.POINTER(_HBVarAxisInfo),
    ]
    hb.hb_ot_var_get_axis_infos.restype = ctypes.c_uint
    hb.hb_font_create.argtypes = [ctypes.c_void_p]
    hb.hb_font_create.restype = ctypes.c_void_p
    hb.hb_font_destroy.argtypes = [ctypes.c_void_p]
    hb.hb_font_set_variations.argtypes = [ctypes.c_void_p, ctypes.POINTER(_HBVariation), ctypes.c_uint]
    hb.hb_buffer_create.argtypes = []
    hb.hb_buffer_create.restype = ctypes.c_void_p
    hb.hb_buffer_destroy.argtypes = [ctypes.c_void_p]
    hb.hb_buffer_add_utf8.argtypes = [
        ctypes.c_void_p,
        ctypes.c_char_p,
        ctypes.c_int,
        ctypes.c_uint,
        ctypes.c_int,
    ]
    hb.hb_buffer_guess_segment_properties.argtypes = [ctypes.c_void_p]
    hb.hb_language_from_string.argtypes = [ctypes.c_char_p, ctypes.c_int]
    hb.hb_language_from_string.restype = ctypes.c_void_p
    hb.hb_buffer_set_language.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
    hb.hb_shape.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_uint]
    hb.hb_buffer_get_glyph_infos.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_uint)]
    hb.hb_buffer_get_glyph_infos.restype = ctypes.POINTER(_HBGlyphInfo)
    hb.hb_font_get_glyph_extents.argtypes = [
        ctypes.c_void_p,
        ctypes.c_uint32,
        ctypes.POINTER(_HBGlyphExtents),
    ]
    hb.hb_font_get_glyph_extents.restype = ctypes.c_int

    def shape_check(path_bytes: bytes, face_idx: int, label: str, spec: dict) -> tuple[int, list[int]]:
        blob = hb.hb_blob_create_from_file_or_fail(path_bytes)
        if not blob:
            errors.append(f"HarfBuzz: failed to open blob for {label}")
            return 0, []
        face = hb.hb_face_create(blob, face_idx)
        axis_count = ctypes.c_uint(4)
        axes_arr = (_HBVarAxisInfo * 4)()
        hb.hb_ot_var_get_axis_infos(face, 0, ctypes.byref(axis_count), axes_arr)
        if axis_count.value != len(spec["axes"]):
            errors.append(
                f"HarfBuzz: {label} axis count {axis_count.value} != expected {len(spec['axes'])}"
            )

        weights = [100.0, 400.0, 900.0] if "wght" in spec["axes"] else [400.0]
        widths_by_w: list[int] = []
        first_gid = 0
        for w in weights:
            font = hb.hb_font_create(face)
            if "wght" in spec["axes"]:
                if "wdth" in spec["axes"]:
                    vars_arr = (_HBVariation * 2)(
                        _HBVariation(_hb_tag("wght"), w),
                        _HBVariation(_hb_tag("wdth"), 100.0),
                    )
                    hb.hb_font_set_variations(font, vars_arr, 2)
                else:
                    vars_arr = (_HBVariation * 1)(_HBVariation(_hb_tag("wght"), w))
                    hb.hb_font_set_variations(font, vars_arr, 1)

            buf = hb.hb_buffer_create()
            text_bytes = spec["sample_text"].encode("utf-8")
            hb.hb_buffer_add_utf8(buf, text_bytes, len(text_bytes), 0, len(text_bytes))
            hb.hb_buffer_guess_segment_properties(buf)
            lang_bytes = spec["sample_lang"].encode("ascii")
            hb.hb_buffer_set_language(buf, hb.hb_language_from_string(lang_bytes, len(lang_bytes)))
            hb.hb_shape(font, buf, None, 0)

            length = ctypes.c_uint(0)
            infos = hb.hb_buffer_get_glyph_infos(buf, ctypes.byref(length))
            if length.value == 0:
                errors.append(f"HarfBuzz: {label} shaped 0 glyphs at wght={w}")
            else:
                gids = [infos[i].codepoint for i in range(length.value)]
                if any(g == 0 for g in gids):
                    errors.append(f"HarfBuzz: {label} produced .notdef (gid=0) at wght={w}: {gids}")
                first_gid = gids[0]
                ext = _HBGlyphExtents()
                if hb.hb_font_get_glyph_extents(font, first_gid, ctypes.byref(ext)):
                    widths_by_w.append(ext.width)

            hb.hb_buffer_destroy(buf)
            hb.hb_font_destroy(font)

        if "wght" in spec["axes"] and len(widths_by_w) == 3:
            if not (widths_by_w[0] < widths_by_w[1] < widths_by_w[2]):
                errors.append(
                    f"HarfBuzz: {label} glyph extent width did not increase with wght 100/400/900: {widths_by_w}"
                )

        # Also check wdth=75 condensed shaping on Latin variable fonts
        if "wdth" in spec["axes"]:
            font100 = hb.hb_font_create(face)
            v100 = (_HBVariation * 2)(_HBVariation(_hb_tag("wght"), 400.0), _HBVariation(_hb_tag("wdth"), 100.0))
            hb.hb_font_set_variations(font100, v100, 2)
            ext100 = _HBGlyphExtents()
            hb.hb_font_get_glyph_extents(font100, first_gid, ctypes.byref(ext100))
            hb.hb_font_destroy(font100)

            font75 = hb.hb_font_create(face)
            v75 = (_HBVariation * 2)(_HBVariation(_hb_tag("wght"), 400.0), _HBVariation(_hb_tag("wdth"), 75.0))
            hb.hb_font_set_variations(font75, v75, 2)
            ext75 = _HBGlyphExtents()
            hb.hb_font_get_glyph_extents(font75, first_gid, ctypes.byref(ext75))
            hb.hb_font_destroy(font75)

            if not (0 < ext75.width < ext100.width):
                errors.append(
                    f"HarfBuzz: {label} wdth=75 width ({ext75.width}) not narrower than wdth=100 ({ext100.width})"
                )

        hb.hb_face_destroy(face)
        hb.hb_blob_destroy(blob)
        return first_gid, widths_by_w

    ttc_blob = hb.hb_blob_create_from_file_or_fail(ttc_path)
    if not ttc_blob:
        errors.append(f"HarfBuzz: failed to open {TTC_FILENAME}")
    else:
        face_cnt = hb.hb_face_count(ttc_blob)
        if face_cnt != 4:
            errors.append(f"HarfBuzz: {TTC_FILENAME} hb_face_count={face_cnt} != 4")
        hb.hb_blob_destroy(ttc_blob)

    hb_bone_gids: dict[int, int] = {}
    for spec in TTC_FACE_SPECS:
        idx = spec["index"]
        gid0, _w = shape_check(ttc_path, idx, f"{TTC_FILENAME}[{idx}]", spec)
        hb_bone_gids[idx] = gid0

    if len(hb_bone_gids) == 4:
        if (
            hb_bone_gids[0] == hb_bone_gids[2]
            or hb_bone_gids[2] == hb_bone_gids[3]
            or hb_bone_gids[0] == hb_bone_gids[3]
        ):
            errors.append(f"HarfBuzz: {TTC_FILENAME} shaped GIDs for U+9AA8 not distinct: {hb_bone_gids}")

    for filename, spec in sorted(EXPECTED_TTF_SPECS.items()):
        p = os.path.join(font_dir, filename).encode("utf-8")
        shape_check(p, 0, filename, spec)

    if not errors:
        print(
            f"OK: Native FreeType ({ft_lib_name}) + HarfBuzz ({hb_lib_name}) verified 4 TTC faces + 8 TTFs "
            f"(TTC U+9AA8 GIDs: JP={hb_bone_gids[0]}, KR={hb_bone_gids[1]}, SC={hb_bone_gids[2]}, TC={hb_bone_gids[3]})"
        )
    return errors


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate packaged module fonts.")
    parser.add_argument("font_dir", help="Directory containing generated module font files")
    parser.add_argument(
        "--lock",
        default=os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "sources.lock"),
        help="Path to sources.lock (verifies SHA-256 unless --no-lock is set)",
    )
    parser.add_argument(
        "--no-lock",
        action="store_true",
        help="Skip SHA-256 verification against sources.lock",
    )
    args = parser.parse_args()

    if not os.path.isdir(args.font_dir):
        print(f"ERROR: font directory not found: {args.font_dir}", file=sys.stderr)
        return 1

    expected_fonts = set(EXPECTED_TTF_SPECS.keys()) | {TTC_FILENAME}
    expected_files = set(expected_fonts)
    if not args.no_lock:
        expected_files.add(MANIFEST_FILENAME)
    actual_files = set(os.listdir(args.font_dir))
    allowed_files = set(expected_files) | {MANIFEST_FILENAME}
    missing_files = sorted(expected_files - actual_files)
    unexpected_files = sorted(actual_files - allowed_files)

    all_errors: list[str] = []
    if missing_files:
        all_errors.append(f"missing expected font files in {args.font_dir}: {missing_files}")
    if unexpected_files:
        all_errors.append(f"unexpected files in {args.font_dir}: {unexpected_files}")

    lock_hashes: dict[str, str] = {}
    if not args.no_lock:
        if not args.lock or not os.path.isfile(args.lock):
            print(f"ERROR: lockfile not found: {args.lock}", file=sys.stderr)
            return 1
        try:
            lock_hashes = load_lock_hashes(args.lock)
        except Exception as exc:
            print(f"ERROR: failed to read lockfile {args.lock}: {exc}", file=sys.stderr)
            return 1

    actual_artifact_hashes: dict[str, str] = {}
    for filename, spec in sorted(EXPECTED_TTF_SPECS.items()):
        path = os.path.join(args.font_dir, filename)
        if os.path.isfile(path):
            actual_artifact_hashes[f"system/fonts/{filename}"] = sha256_file(path)
        exp_sha = ""
        if not args.no_lock:
            upstream_name = spec["upstream"]
            exp_sha = lock_hashes.get(upstream_name, "")
            if not exp_sha:
                all_errors.append(f"{filename}: missing SHA-256 entry for {upstream_name} in {args.lock}")
                continue
        errs = check_single_ttf(path, filename, spec, exp_sha)
        if errs:
            all_errors.extend(errs)
        else:
            print(f"OK: {filename}")

    ttc_path = os.path.join(args.font_dir, TTC_FILENAME)
    if os.path.isfile(ttc_path):
        actual_artifact_hashes[f"system/fonts/{TTC_FILENAME}"] = sha256_file(ttc_path)

    source_ttfs: dict[int, bytes] = {}
    for idx, overlay_name in ((2, "SysSans-Hans-Regular.ttf"), (3, "SysSans-Hant-Regular.ttf")):
        src_name = TTC_SOURCES[idx]
        overlay_path = os.path.join(args.font_dir, overlay_name)
        exp_src_sha = lock_hashes.get(src_name, "")
        if not exp_src_sha:
            all_errors.append(f"{TTC_FILENAME}[{idx}]: missing SHA-256 entry for {src_name} in {args.lock}")
        elif not os.path.isfile(overlay_path):
            all_errors.append(
                f"{TTC_FILENAME}[{idx}]: missing CJK source font {overlay_name} ({src_name}) at {overlay_path}"
            )
        else:
            act_src_sha = sha256_file(overlay_path)
            if act_src_sha != exp_src_sha:
                all_errors.append(
                    f"{TTC_FILENAME}[{idx}]: SHA-256 mismatch for CJK source font {overlay_name} ({src_name}) "
                    f"at {overlay_path} (expected {exp_src_sha}, got {act_src_sha})"
                )
            else:
                with open(overlay_path, "rb") as fh:
                    source_ttfs[idx] = fh.read()

    cache_dir = os.environ.get(
        "FONT_CACHE_DIR",
        os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), ".cache", "downloads"),
    )
    for idx in (0, 1):
        src_name = TTC_SOURCES[idx]
        cand_path = os.path.join(cache_dir, src_name)
        exp_src_sha = lock_hashes.get(src_name, "")
        if not exp_src_sha:
            all_errors.append(f"{TTC_FILENAME}[{idx}]: missing SHA-256 entry for {src_name} in {args.lock}")
        elif not os.path.isfile(cand_path):
            all_errors.append(
                f"{TTC_FILENAME}[{idx}]: missing cached CJK source font {src_name} at {cand_path} "
                f"(set FONT_CACHE_DIR to directory containing locked upstream fonts)"
            )
        else:
            act_src_sha = sha256_file(cand_path)
            if act_src_sha != exp_src_sha:
                all_errors.append(
                    f"{TTC_FILENAME}[{idx}]: SHA-256 mismatch for cached CJK source font {src_name} at {cand_path} "
                    f"(expected {exp_src_sha}, got {act_src_sha}; check FONT_CACHE_DIR)"
                )
            else:
                with open(cand_path, "rb") as fh:
                    source_ttfs[idx] = fh.read()

    ttc_errs = check_ttc(ttc_path, TTC_FILENAME, source_ttfs=source_ttfs)
    if ttc_errs:
        all_errors.extend(ttc_errs)
    else:
        print(f"OK: {TTC_FILENAME} (4 faces: 0=JP, 1=KR, 2=SC, 3=TC)")

    if not args.no_lock:
        manifest_path = os.path.join(args.font_dir, MANIFEST_FILENAME)
        if not os.path.isfile(manifest_path):
            all_errors.append(f"{MANIFEST_FILENAME}: file does not exist at {manifest_path}")
        else:
            try:
                with open(manifest_path, "r", encoding="utf-8") as mf:
                    manifest_text = mf.read()
                m_errs, _m_hashes = validate_font_manifest_text(
                    manifest_text, lock_hashes, actual_artifact_hashes
                )
                if m_errs:
                    all_errors.extend(m_errs)
                else:
                    print(f"OK: {MANIFEST_FILENAME} (9 verified font artifact entries)")
            except Exception as exc:
                all_errors.append(f"{MANIFEST_FILENAME}: failed to read/validate manifest: {exc}")

    native_errs = check_native_freetype_and_harfbuzz(args.font_dir)
    if native_errs:
        all_errors.extend(native_errs)

    if all_errors:
        for err in all_errors:
            print(f"ERROR: {err}", file=sys.stderr)
        return 1

    print(f"All {len(expected_fonts)} font artifacts verified successfully.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
