#!/usr/bin/env python3
"""Host-side font validator for ksu-noto-fonts-apple-emoji (v2.0.0).

Checks exact build/fonts manifest, upstream source SHA-256 and generated artifact
SHA-256 digests, internal font names and RFN compliance (Noto Sans CJK retains
original internal names and does not misuse Adobe's Reserved Font Name 'Source'
as a font family/PostScript name), variation axes, representative codepoints,
and Unicode cmap + format 14 UVS role isolation across all 7 standalone TTFs.
"""

import argparse
import hashlib
import os
import sys
from fontTools.ttLib import TTFont

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from make_fonts import (  # noqa: E402
    MANIFEST_FILENAME,
    is_unicode_subtable,
    load_lock_font_hashes,
    sha256_file,
    should_remove,
)


EXPECTED_TTF_SPECS: dict[str, dict] = {
    "KSU-NotoSans-Regular-VF.ttf": {
        "upstream": "KSU-NotoSans-Regular-VF.ttf",
        "kind": "isolated_western_ttf",
        "role": "western",
        "family": "Noto Sans",
        "subfamily": "Regular",
        "ps_prefix": "NotoSans-Regular",
        "axes": {"wght": (100.0, 400.0, 900.0), "wdth": (62.5, 100.0, 100.0)},
        "required_tables": ["fvar", "cmap", "GSUB", "GPOS", "HVAR", "gvar"],
        "forbidden_tables": ["CBDT", "CBLC"],
        "min_glyphs": 2500,
        "codepoints": [0x0041, 0x0061, 0x0030, 0x00E9, 0x0142, 0x0391, 0x0410],
        "forbidden_codepoints": [0x4E2D, 0x3002, 0x3042, 0xAC00],
    },
    "KSU-NotoSans-Italic-VF.ttf": {
        "upstream": "KSU-NotoSans-Italic-VF.ttf",
        "kind": "isolated_western_ttf",
        "role": "western",
        "family": "Noto Sans",
        "subfamily": "Italic",
        "ps_prefix": "NotoSans-Italic",
        "axes": {"wght": (100.0, 400.0, 900.0), "wdth": (62.5, 100.0, 100.0)},
        "required_tables": ["fvar", "cmap", "GSUB", "GPOS", "HVAR", "gvar"],
        "forbidden_tables": ["CBDT", "CBLC"],
        "min_glyphs": 2500,
        "codepoints": [0x0041, 0x0061, 0x0030, 0x00E9, 0x0142, 0x0391, 0x0410],
        "forbidden_codepoints": [0x4E2D, 0x3002, 0x3042, 0xAC00],
    },
    "KSU-NotoSansCJKsc-VF.ttf": {
        "upstream": "KSU-NotoSansCJKsc-VF.ttf",
        "kind": "isolated_chinese_ttf",
        "role": "chinese",
        "family": "Noto Sans CJK SC",
        "subfamily": "Regular",
        "ps_prefix": "NotoSansCJKsc-",
        "axes": {"wght": (100.0, 100.0, 900.0)},
        "required_tables": ["fvar", "cmap", "GSUB", "GPOS", "HVAR", "gvar"],
        "forbidden_tables": ["CBDT", "CBLC"],
        "min_glyphs": 40000,
        "codepoints": [0x4E2D, 0x6587, 0x5B57, 0x4F53, 0x9AA8, 0x76F4, 0x3002],
        "forbidden_codepoints": [0x0041, 0x0061, 0x0030, 0x0021, 0xFF01],
        "check_cjk_rfn": True,
    },
    "KSU-NotoSansCJKtc-VF.ttf": {
        "upstream": "KSU-NotoSansCJKtc-VF.ttf",
        "kind": "isolated_chinese_ttf",
        "role": "chinese",
        "family": "Noto Sans CJK TC",
        "subfamily": "Regular",
        "ps_prefix": "NotoSansCJKtc-",
        "axes": {"wght": (100.0, 100.0, 900.0)},
        "required_tables": ["fvar", "cmap", "GSUB", "GPOS", "HVAR", "gvar"],
        "forbidden_tables": ["CBDT", "CBLC"],
        "min_glyphs": 40000,
        "codepoints": [0x4E2D, 0x570B, 0x7E41, 0x9AD4, 0x9AA8, 0x76F4, 0x3002],
        "forbidden_codepoints": [0x0041, 0x0061, 0x0030, 0x0021, 0xFF01],
        "check_cjk_rfn": True,
    },
    "KSU-NotoSansCJKjp-VF.ttf": {
        "upstream": "KSU-NotoSansCJKjp-VF.ttf",
        "kind": "isolated_chinese_ttf",
        "role": "chinese",
        "family": "Noto Sans CJK JP",
        "subfamily": "Regular",
        "ps_prefix": "NotoSansCJKjp-",
        "axes": {"wght": (100.0, 100.0, 900.0)},
        "required_tables": ["fvar", "cmap", "GSUB", "GPOS", "HVAR", "gvar"],
        "forbidden_tables": ["CBDT", "CBLC"],
        "min_glyphs": 40000,
        "codepoints": [0x3042, 0x30A2, 0x65E5, 0x672C, 0x8A9E, 0x9AA8, 0x3002],
        "forbidden_codepoints": [0x0041, 0x0061, 0x0030, 0x0021, 0xFF01],
        "check_cjk_rfn": True,
    },
    "KSU-NotoSansCJKkr-VF.ttf": {
        "upstream": "KSU-NotoSansCJKkr-VF.ttf",
        "kind": "isolated_chinese_ttf",
        "role": "chinese",
        "family": "Noto Sans CJK KR",
        "subfamily": "Regular",
        "ps_prefix": "NotoSansCJKkr-",
        "axes": {"wght": (100.0, 100.0, 900.0)},
        "required_tables": ["fvar", "cmap", "GSUB", "GPOS", "HVAR", "gvar"],
        "forbidden_tables": ["CBDT", "CBLC"],
        "min_glyphs": 40000,
        "codepoints": [0xD55C, 0xAE00, 0xAC00, 0xB098, 0x4E2D, 0x9AA8, 0x3002],
        "forbidden_codepoints": [0x0041, 0x0061, 0x0030, 0x0021, 0xFF01],
        "check_cjk_rfn": True,
    },
    "KSU-AppleColorEmoji.ttf": {
        "upstream": "KSU-AppleColorEmoji.ttf",
        "kind": "exact_ttf",
        "role": "emoji",
        "family": "Apple Color Emoji",
        "subfamily": "Regular",
        "ps_prefix": "AppleColorEmoji",
        "axes": {},
        "required_tables": ["CBDT", "CBLC", "cmap"],
        "forbidden_tables": ["fvar", "sbix"],
        "min_glyphs": 1000,
        "codepoints": [0x1F600, 0x2764, 0x1F44D, 0x1F3FD, 0x200D, 0x1F525, 0x1F389],
        "forbidden_codepoints": [],
        "check_cbdt": True,
    },
}


def get_name_record(font: TTFont, name_id: int) -> str:
    for rec in font["name"].names:
        if rec.nameID == name_id:
            try:
                return rec.toUnicode()
            except UnicodeDecodeError:
                continue
    return ""


def check_single_ttf(path: str, filename: str, spec: dict, expected_exact_sha: str = "") -> list[str]:
    errors: list[str] = []
    if not os.path.isfile(path):
        return [f"{filename}: file does not exist at {path}"]

    if expected_exact_sha:
        actual_sha = sha256_file(path)
        if actual_sha != expected_exact_sha:
            errors.append(f"{filename}: SHA-256 mismatch (expected {expected_exact_sha}, got {actual_sha})")

    try:
        font = TTFont(path, lazy=False)
    except Exception as exc:
        return errors + [f"{filename}: failed to parse TTFont: {exc}"]

    for tbl in ["head", "hhea", "maxp", "name", "OS/2", "post"] + list(spec["required_tables"]):
        if tbl not in font:
            errors.append(f"{filename}: missing required table '{tbl}'")

    for tbl in spec["forbidden_tables"]:
        if tbl in font:
            errors.append(f"{filename}: unexpected forbidden table '{tbl}'")

    family = get_name_record(font, 1)
    subfamily = get_name_record(font, 2)
    ps_name = get_name_record(font, 6)
    if family != spec["family"]:
        errors.append(f"{filename}: family name mismatch (expected '{spec['family']}', got '{family}')")
    if subfamily != spec["subfamily"]:
        errors.append(f"{filename}: subfamily mismatch (expected '{spec['subfamily']}', got '{subfamily}')")
    if not ps_name.startswith(spec["ps_prefix"]):
        errors.append(f"{filename}: PostScript name '{ps_name}' does not start with '{spec['ps_prefix']}'")

    if spec.get("check_cjk_rfn"):
        for rec in font["name"].names:
            if rec.nameID in (1, 3, 4, 6, 16, 18, 20, 21):
                try:
                    val = rec.toUnicode()
                except UnicodeDecodeError:
                    continue
                if "source" in val.lower():
                    errors.append(f"{filename}: nameID={rec.nameID} unexpectedly uses RFN 'Source': {val!r}")

    expected_axes = spec["axes"]
    if expected_axes:
        if "fvar" not in font:
            errors.append(f"{filename}: missing fvar table")
        else:
            actual_axes = {
                a.axisTag: (float(a.minValue), float(a.defaultValue), float(a.maxValue))
                for a in font["fvar"].axes
            }
            if set(actual_axes.keys()) != set(expected_axes.keys()):
                errors.append(f"{filename}: axis tags {sorted(actual_axes.keys())} != {sorted(expected_axes.keys())}")
            for tag, exp_bounds in expected_axes.items():
                if tag in actual_axes and any(abs(a - b) > 0.01 for a, b in zip(actual_axes[tag], exp_bounds)):
                    errors.append(f"{filename}: axis '{tag}' bounds {actual_axes[tag]} != {exp_bounds}")

    cmap = font.getBestCmap() or {}
    if len(cmap) < spec["min_glyphs"]:
        errors.append(f"{filename}: cmap size {len(cmap)} < {spec['min_glyphs']}")
    for cp in spec["codepoints"]:
        if cp not in cmap:
            errors.append(f"{filename}: missing representative codepoint U+{cp:04X}")
    for cp in spec["forbidden_codepoints"]:
        if cp in cmap:
            errors.append(f"{filename}: forbidden isolated codepoint U+{cp:04X} still mapped in best cmap")

    role = spec["role"]
    if role in ("western", "chinese"):
        unicode_cps: set[int] = set()
        for sub in font["cmap"].tables:
            if sub.format == 14:
                continue
            if not is_unicode_subtable(sub):
                continue
            leaked = [cp for cp in sub.cmap if should_remove(role, cp)]
            if leaked:
                errors.append(
                    f"{filename}: cmap format={sub.format} plat={sub.platformID} enc={sub.platEncID} "
                    f"retains {len(leaked)} forbidden {role} codepoints (first U+{leaked[0]:04X})"
                )
            unicode_cps.update(sub.cmap.keys())

        glyph_set = set(font.getGlyphOrder())
        for sub in font["cmap"].tables:
            if sub.format == 14 and hasattr(sub, "uvsDict"):
                for vs, pairs in sub.uvsDict.items():
                    for cp, gname in pairs:
                        if should_remove(role, cp) or cp not in unicode_cps:
                            errors.append(
                                f"{filename}: format 14 UVS U+{vs:04X} retains unmapped/isolated base U+{cp:04X}"
                            )
                        if gname is not None and gname not in glyph_set:
                            errors.append(
                                f"{filename}: format 14 UVS U+{vs:04X} U+{cp:04X} references missing glyph {gname!r}"
                            )

    if spec.get("check_cbdt") and "CBLC" in font and "CBDT" in font:
        strikes = getattr(font["CBLC"], "strikes", [])
        if not strikes:
            errors.append(f"{filename}: CBLC has 0 strikes")
        cbdt_data = getattr(font["CBDT"], "strikeData", None)
        if not cbdt_data or sum(len(s) for s in cbdt_data) == 0:
            errors.append(f"{filename}: CBDT strikeData is empty")

    font.close()
    return errors


def validate_font_manifest_text(
    manifest_text: str,
    lock_font_hashes: dict[str, str],
    actual_artifact_hashes: dict[str, str],
) -> tuple[list[str], dict[str, str]]:
    errors: list[str] = []
    manifest_artifact_hashes: dict[str, str] = {}
    seen_paths: list[str] = []

    expected_by_path = {f"system/fonts/{fname}": spec for fname, spec in EXPECTED_TTF_SPECS.items()}

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
        if zip_path not in expected_by_path:
            errors.append(f"{MANIFEST_FILENAME}: unexpected path {zip_path}")
            continue

        spec = expected_by_path[zip_path]
        exp_src = spec["upstream"]
        exp_kind = spec["kind"]
        exp_src_sha = lock_font_hashes.get(exp_src, "")

        if kind != exp_kind:
            errors.append(f"{MANIFEST_FILENAME}: {zip_path} kind={kind!r} != {exp_kind!r}")
        if upstream_src != exp_src:
            errors.append(f"{MANIFEST_FILENAME}: {zip_path} upstream={upstream_src!r} != {exp_src!r}")
        if not exp_src_sha or upstream_sha != exp_src_sha:
            errors.append(f"{MANIFEST_FILENAME}: {zip_path} upstream_sha={upstream_sha!r} != lock {exp_src_sha!r}")
        if len(artifact_sha) != 64 or any(c not in "0123456789abcdef" for c in artifact_sha):
            errors.append(f"{MANIFEST_FILENAME}: {zip_path} invalid artifact_sha={artifact_sha!r}")
        if kind == "exact_ttf" and artifact_sha != upstream_sha:
            errors.append(f"{MANIFEST_FILENAME}: {zip_path} exact_ttf artifact_sha != upstream_sha")
        if spec["role"] == "chinese" and artifact_sha == upstream_sha:
            errors.append(f"{MANIFEST_FILENAME}: {zip_path} CJK font was not role-isolated (hash equals upstream)")

        if zip_path in actual_artifact_hashes and artifact_sha != actual_artifact_hashes[zip_path]:
            errors.append(
                f"{MANIFEST_FILENAME}: {zip_path} artifact_sha={artifact_sha} != actual {actual_artifact_hashes[zip_path]}"
            )
        manifest_artifact_hashes[zip_path] = artifact_sha

    if seen_paths != sorted(seen_paths):
        errors.append(f"{MANIFEST_FILENAME}: entries not sorted by zip_path")
    missing = sorted(set(expected_by_path.keys()) - set(manifest_artifact_hashes.keys()))
    if missing:
        errors.append(f"{MANIFEST_FILENAME}: missing required entries: {missing}")

    return errors, manifest_artifact_hashes


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate packaged module fonts.")
    parser.add_argument("font_dir", help="Directory containing generated module font files")
    parser.add_argument(
        "--lock",
        default=os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "sources.lock"),
        help="Path to sources.lock",
    )
    args = parser.parse_args()

    if not os.path.isdir(args.font_dir):
        print(f"ERROR: font directory not found: {args.font_dir}", file=sys.stderr)
        return 1
    if not os.path.isfile(args.lock):
        print(f"ERROR: lockfile not found: {args.lock}", file=sys.stderr)
        return 1

    lock_hashes = load_lock_font_hashes(args.lock)
    expected_files = set(EXPECTED_TTF_SPECS.keys()) | {MANIFEST_FILENAME}
    actual_files = set(os.listdir(args.font_dir))

    all_errors: list[str] = []
    if expected_files - actual_files:
        all_errors.append(f"missing files in {args.font_dir}: {sorted(expected_files - actual_files)}")
    if actual_files - expected_files:
        all_errors.append(f"unexpected files in {args.font_dir}: {sorted(actual_files - expected_files)}")

    actual_artifact_hashes: dict[str, str] = {}
    for filename, spec in sorted(EXPECTED_TTF_SPECS.items()):
        path = os.path.join(args.font_dir, filename)
        if os.path.isfile(path):
            actual_artifact_hashes[f"system/fonts/{filename}"] = sha256_file(path)
        exp_exact_sha = lock_hashes.get(spec["upstream"], "") if spec["kind"] == "exact_ttf" else ""
        errs = check_single_ttf(path, filename, spec, exp_exact_sha)
        if errs:
            all_errors.extend(errs)
        else:
            print(f"OK: {filename} (role={spec['role']})")

    manifest_path = os.path.join(args.font_dir, MANIFEST_FILENAME)
    if os.path.isfile(manifest_path):
        with open(manifest_path, "r", encoding="utf-8") as mf:
            m_errs, _ = validate_font_manifest_text(mf.read(), lock_hashes, actual_artifact_hashes)
        if m_errs:
            all_errors.extend(m_errs)
        else:
            print(f"OK: {MANIFEST_FILENAME} ({len(EXPECTED_TTF_SPECS)} verified entries)")

    if all_errors:
        for err in all_errors:
            print(f"ERROR: {err}", file=sys.stderr)
        return 1

    print(f"All {len(EXPECTED_TTF_SPECS)} font artifacts verified successfully.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
