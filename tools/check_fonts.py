#!/usr/bin/env python3
"""Host-side font validator for ksu-noto-fonts-apple-emoji.

Checks font family/PostScript names, variable axes (fvar), representative glyph
coverage, and CBDT/CBLC color bitmap tables for the Apple Emoji Linux font.
Run with: python3 -I tools/check_fonts.py <font_dir> [--lock sources.lock]
"""

import argparse
import hashlib
import os
import sys
from fontTools.ttLib import TTFont


EXPECTED_SPECS = {
    "KSU-NotoSans-Regular-VF.ttf": {
        "family": "Noto Sans",
        "subfamily": "Regular",
        "ps_prefix": "NotoSans-Regular",
        "axes": {
            "wght": (100.0, 400.0, 900.0),
            "wdth": (62.5, 100.0, 100.0),
        },
        "required_tables": ["fvar", "cmap", "GSUB", "GPOS"],
        "forbidden_tables": ["CBDT", "CBLC"],
        "min_glyphs": 2500,
        "codepoints": [0x0041, 0x0061, 0x0030, 0x00E9, 0x0142, 0x0391, 0x0410],
    },
    "KSU-NotoSans-Italic-VF.ttf": {
        "family": "Noto Sans",
        "subfamily": "Italic",
        "ps_prefix": "NotoSans-Italic",
        "axes": {
            "wght": (100.0, 400.0, 900.0),
            "wdth": (62.5, 100.0, 100.0),
        },
        "required_tables": ["fvar", "cmap", "GSUB", "GPOS"],
        "forbidden_tables": ["CBDT", "CBLC"],
        "min_glyphs": 2500,
        "codepoints": [0x0041, 0x0061, 0x0030, 0x00E9, 0x0142, 0x0391, 0x0410],
    },
    "KSU-NotoSansCJKsc-VF.ttf": {
        "family": "Noto Sans CJK SC",
        "subfamily": "Regular",
        "ps_prefix": "NotoSansCJKsc-",
        "axes": {
            "wght": (100.0, 100.0, 900.0),
        },
        "required_tables": ["fvar", "cmap", "GSUB", "GPOS"],
        "forbidden_tables": ["CBDT", "CBLC"],
        "min_glyphs": 40000,
        "codepoints": [0x4E2D, 0x6587, 0x5B57, 0x4F53, 0x9AA8, 0x76F4, 0x3002],
    },
    "KSU-NotoSansCJKtc-VF.ttf": {
        "family": "Noto Sans CJK TC",
        "subfamily": "Regular",
        "ps_prefix": "NotoSansCJKtc-",
        "axes": {
            "wght": (100.0, 100.0, 900.0),
        },
        "required_tables": ["fvar", "cmap", "GSUB", "GPOS"],
        "forbidden_tables": ["CBDT", "CBLC"],
        "min_glyphs": 40000,
        "codepoints": [0x4E2D, 0x570B, 0x7E41, 0x9AD4, 0x9AA8, 0x76F4, 0x3002],
    },
    "KSU-NotoSansCJKjp-VF.ttf": {
        "family": "Noto Sans CJK JP",
        "subfamily": "Regular",
        "ps_prefix": "NotoSansCJKjp-",
        "axes": {
            "wght": (100.0, 100.0, 900.0),
        },
        "required_tables": ["fvar", "cmap", "GSUB", "GPOS"],
        "forbidden_tables": ["CBDT", "CBLC"],
        "min_glyphs": 40000,
        "codepoints": [0x3042, 0x30A2, 0x65E5, 0x672C, 0x8A9E, 0x9AA8, 0x76F4],
    },
    "KSU-NotoSansCJKkr-VF.ttf": {
        "family": "Noto Sans CJK KR",
        "subfamily": "Regular",
        "ps_prefix": "NotoSansCJKkr-",
        "axes": {
            "wght": (100.0, 100.0, 900.0),
        },
        "required_tables": ["fvar", "cmap", "GSUB", "GPOS"],
        "forbidden_tables": ["CBDT", "CBLC"],
        "min_glyphs": 40000,
        "codepoints": [0xD55C, 0xAE00, 0xAC00, 0xB098, 0x4E2D, 0x9AA8, 0x76F4],
    },
    "KSU-AppleColorEmoji.ttf": {
        "family": "Apple Color Emoji",
        "subfamily": "Regular",
        "ps_prefix": "AppleColorEmoji",
        "axes": {},
        "required_tables": ["CBDT", "CBLC", "cmap"],
        "forbidden_tables": ["fvar", "sbix"],
        "min_glyphs": 1000,
        "codepoints": [0x1F600, 0x2764, 0x1F44D, 0x1F3FD, 0x200D, 0x1F525, 0x1F389],
        "check_cbdt": True,
    },
}


def sha256_file(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        while True:
            chunk = f.read(1024 * 1024)
            if not chunk:
                break
            h.update(chunk)
    return h.hexdigest()


def load_lock_hashes(lock_path: str) -> dict:
    hashes = {}
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


def check_single_font(path: str, filename: str, spec: dict, expected_sha: str = "") -> list:
    errors = []
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

    for tbl in spec["required_tables"]:
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
        errors.append(
            f"{filename}: PostScript name mismatch (expected prefix '{spec['ps_prefix']}', got '{ps_name}')"
        )

    expected_axes = spec["axes"]
    if expected_axes:
        if "fvar" not in font:
            errors.append(f"{filename}: missing fvar table for variable font")
        else:
            actual_axes = {
                a.axisTag: (float(a.minValue), float(a.defaultValue), float(a.maxValue))
                for a in font["fvar"].axes
            }
            if set(actual_axes.keys()) != set(expected_axes.keys()):
                errors.append(
                    f"{filename}: axis tags mismatch (expected {sorted(expected_axes.keys())}, got {sorted(actual_axes.keys())})"
                )
            for tag, exp_bounds in expected_axes.items():
                if tag in actual_axes:
                    act_bounds = actual_axes[tag]
                    if any(abs(a - b) > 0.01 for a, b in zip(act_bounds, exp_bounds)):
                        errors.append(
                            f"{filename}: axis '{tag}' bounds {act_bounds} != expected {exp_bounds}"
                        )

    try:
        cmap = font.getBestCmap() or {}
    except Exception as exc:
        cmap = {}
        errors.append(f"{filename}: failed to read best cmap: {exc}")

    if len(cmap) < spec["min_glyphs"]:
        errors.append(
            f"{filename}: cmap size {len(cmap)} is smaller than minimum required {spec['min_glyphs']} (regional subset or truncated font?)"
        )

    for cp in spec["codepoints"]:
        if cp not in cmap:
            errors.append(f"{filename}: missing required representative codepoint U+{cp:04X}")

    if spec.get("check_cbdt"):
        if "CBLC" in font and "CBDT" in font:
            strikes = getattr(font["CBLC"], "strikes", [])
            if not strikes:
                errors.append(f"{filename}: CBLC table has 0 bitmap strikes")
            else:
                bit_depths = {s.bitmapSizeTable.bitDepth for s in strikes}
                if 32 not in bit_depths:
                    errors.append(f"{filename}: CBLC strikes missing 32-bit color depth (got {sorted(bit_depths)})")
                non_empty_strikes = sum(1 for s in strikes if getattr(s, "indexSubTables", []))
                if non_empty_strikes == 0:
                    errors.append(f"{filename}: CBLC strikes contain no indexSubTables")
            cbdt_data = getattr(font["CBDT"], "strikeData", None)
            if not cbdt_data or sum(len(s) for s in cbdt_data) == 0:
                errors.append(f"{filename}: CBDT strikeData is missing or empty")

    font.close()
    return errors


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate packaged module fonts.")
    parser.add_argument("font_dir", help="Directory containing KSU-*.ttf font files")
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

    lock_hashes = {}
    if not args.no_lock:
        if not args.lock or not os.path.isfile(args.lock):
            print(f"ERROR: lockfile not found: {args.lock}", file=sys.stderr)
            return 1
        try:
            lock_hashes = load_lock_hashes(args.lock)
        except Exception as exc:
            print(f"ERROR: failed to read lockfile {args.lock}: {exc}", file=sys.stderr)
            return 1

    all_errors = []
    for filename, spec in sorted(EXPECTED_SPECS.items()):
        path = os.path.join(args.font_dir, filename)
        exp_sha = ""
        if not args.no_lock:
            exp_sha = lock_hashes.get(filename, "")
            if not exp_sha:
                all_errors.append(f"{filename}: missing SHA-256 entry in lockfile {args.lock}")
                continue
        errs = check_single_font(path, filename, spec, exp_sha)
        if errs:
            all_errors.extend(errs)
        else:
            print(f"OK: {filename}")

    if all_errors:
        for err in all_errors:
            print(f"ERROR: {err}", file=sys.stderr)
        return 1

    print(f"All {len(EXPECTED_SPECS)} fonts verified successfully.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
