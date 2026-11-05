#!/usr/bin/env python3
"""Host-side font builder for ksu-noto-fonts-apple-emoji (v2.0.0).

Verifies locked upstream source fonts from sources.lock in <cache_dir>, applies
host-side Unicode cmap role isolation (rules adapted from font-settings
webroot/font-isolation.js) to the 2 Western Noto Sans VF TTFs and 4 Noto Sans CJK
SC/TC/JP/KR VF TTFs without altering internal font names, copies Apple Color Emoji
bytes verbatim, and writes font-manifest.txt with both upstream source SHA-256 and
generated artifact SHA-256 digests.
"""

import argparse
import hashlib
import os
import shutil
import sys
from fontTools.ttLib import TTFont


# Exact Unicode ranges from reference font-settings/webroot/font-isolation.js
LATIN_RANGES: list[tuple[int, int]] = [
    (0x0000, 0x036F),
    (0x1D00, 0x1DFF),
    (0x1E00, 0x1EFF),
    (0x2000, 0x218F),
    (0x2C60, 0x2C7F),
    (0xA700, 0xA7FF),
    (0xAB30, 0xAB6F),
    (0xFB00, 0xFB06),
    (0xFE20, 0xFE2F),
    (0xFF01, 0xFF5E),
    (0x10780, 0x107BF),
    (0x1D400, 0x1D7FF),
    (0x1DF00, 0x1DFFF),
]

CJK_RANGES: list[tuple[int, int]] = [
    (0x2E80, 0x303F),
    (0x3040, 0x33FF),
    (0x3400, 0x4DBF),
    (0x4E00, 0x9FFF),
    (0xA960, 0xA97F),
    (0xAC00, 0xD7FF),
    (0xF900, 0xFAFF),
    (0xFE10, 0xFE1F),
    (0xFE30, 0xFE4F),
    (0xFF00, 0xFFEF),
    (0x16FE0, 0x18DFF),
    (0x1AFF0, 0x1B2FF),
    (0x1F200, 0x1F2FF),
    (0x20000, 0x323AF),
]

FONT_ROLE_MAP: dict[str, tuple[str, str]] = {
    "KSU-NotoSans-Regular-VF.ttf": ("KSU-NotoSans-Regular-VF.ttf", "western"),
    "KSU-NotoSans-Italic-VF.ttf": ("KSU-NotoSans-Italic-VF.ttf", "western"),
    "KSU-NotoSansCJKsc-VF.ttf": ("KSU-NotoSansCJKsc-VF.ttf", "chinese"),
    "KSU-NotoSansCJKtc-VF.ttf": ("KSU-NotoSansCJKtc-VF.ttf", "chinese"),
    "KSU-NotoSansCJKjp-VF.ttf": ("KSU-NotoSansCJKjp-VF.ttf", "chinese"),
    "KSU-NotoSansCJKkr-VF.ttf": ("KSU-NotoSansCJKkr-VF.ttf", "chinese"),
    "KSU-AppleColorEmoji.ttf": ("KSU-AppleColorEmoji.ttf", "emoji"),
}

MANIFEST_FILENAME = "font-manifest.txt"


def in_ranges(code_point: int, ranges: list[tuple[int, int]]) -> bool:
    low = 0
    high = len(ranges) - 1
    while low <= high:
        mid = (low + high) >> 1
        start, end = ranges[mid]
        if code_point < start:
            high = mid - 1
        elif code_point > end:
            low = mid + 1
        else:
            return True
    return False


def should_remove(role: str, code_point: int) -> bool:
    if role == "chinese":
        return in_ranges(code_point, LATIN_RANGES)
    if role == "western":
        return in_ranges(code_point, CJK_RANGES)
    raise ValueError(f"Unsupported isolation role: {role}")


def is_unicode_subtable(subtable) -> bool:
    return (
        subtable.platformID == 0
        or (subtable.platformID == 3 and subtable.platEncID in (1, 10))
        or bool(subtable.isUnicode())
    )


def isolate_font_file(src_path: str, dst_path: str, role: str) -> None:
    if role == "emoji":
        shutil.copyfile(src_path, dst_path)
        return

    font = TTFont(src_path, recalcTimestamp=False)
    cmap_table = font["cmap"]

    supported_unicode = 0
    remaining_unicode_cps: set[int] = set()

    for sub in cmap_table.tables:
        if sub.format == 14:
            continue
        if not is_unicode_subtable(sub):
            continue
        if sub.format in (0, 4, 6, 10, 12, 13):
            supported_unicode += 1
        to_delete = [cp for cp in sub.cmap if should_remove(role, cp)]
        for cp in to_delete:
            del sub.cmap[cp]
        remaining_unicode_cps.update(sub.cmap.keys())

    if supported_unicode == 0:
        font.close()
        raise ValueError(f"{src_path}: no supported Unicode cmap subtable found")

    glyph_set = set(font.getGlyphOrder())
    for sub in cmap_table.tables:
        if sub.format == 14 and hasattr(sub, "uvsDict"):
            cleaned_uvs: dict[int, list[tuple[int, str | None]]] = {}
            for vs, pairs in sub.uvsDict.items():
                kept: list[tuple[int, str | None]] = []
                for cp, glyph_name in pairs:
                    if should_remove(role, cp) or cp not in remaining_unicode_cps:
                        continue
                    if glyph_name is not None and glyph_name not in glyph_set:
                        raise ValueError(
                            f"{src_path}: format 14 UVS U+{vs:04X} U+{cp:04X} references unknown glyph {glyph_name!r}"
                        )
                    kept.append((cp, glyph_name))
                if kept:
                    cleaned_uvs[vs] = kept
            sub.uvsDict = cleaned_uvs

    font.save(dst_path)
    font.close()


def sha256_file(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        while True:
            chunk = f.read(1024 * 1024)
            if not chunk:
                break
            h.update(chunk)
    return h.hexdigest().lower()


def load_lock_font_hashes(lock_path: str) -> dict[str, str]:
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


def main() -> int:
    parser = argparse.ArgumentParser(description="Build module font payload with role isolation.")
    parser.add_argument("cache_dir", help="Directory containing locked upstream KSU-*.ttf files")
    parser.add_argument("out_dir", help="Output directory for generated build/fonts payload")
    parser.add_argument(
        "--lock",
        default=os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "sources.lock"),
        help="Path to sources.lock",
    )
    args = parser.parse_args()

    if not os.path.isdir(args.cache_dir):
        print(f"ERROR: cache directory not found: {args.cache_dir}", file=sys.stderr)
        return 1
    if not os.path.isfile(args.lock):
        print(f"ERROR: lockfile not found: {args.lock}", file=sys.stderr)
        return 1

    try:
        lock_hashes = load_lock_font_hashes(args.lock)
    except Exception as exc:
        print(f"ERROR: failed to read lockfile {args.lock}: {exc}", file=sys.stderr)
        return 1

    for target_name, (src_name, _role) in sorted(FONT_ROLE_MAP.items()):
        src_path = os.path.join(args.cache_dir, src_name)
        if not os.path.isfile(src_path):
            print(f"ERROR: missing upstream font in cache: {src_path}", file=sys.stderr)
            return 1
        exp_sha = lock_hashes.get(src_name, "")
        if not exp_sha:
            print(f"ERROR: {src_name} missing from {args.lock}", file=sys.stderr)
            return 1
        act_sha = sha256_file(src_path)
        if act_sha != exp_sha:
            print(
                f"ERROR: SHA-256 mismatch for cached {src_name} (expected {exp_sha}, got {act_sha})",
                file=sys.stderr,
            )
            return 1

    os.makedirs(args.out_dir, exist_ok=True)
    for existing in os.listdir(args.out_dir):
        full = os.path.join(args.out_dir, existing)
        if os.path.isfile(full) or os.path.islink(full):
            os.unlink(full)
        else:
            shutil.rmtree(full)

    manifest_rows: list[tuple[str, str, str, str, str]] = []
    for target_name, (src_name, role) in sorted(FONT_ROLE_MAP.items()):
        src_path = os.path.join(args.cache_dir, src_name)
        dst_path = os.path.join(args.out_dir, target_name)
        isolate_font_file(src_path, dst_path, role)
        src_sha = lock_hashes[src_name]
        dst_sha = sha256_file(dst_path)
        kind = "exact_ttf" if role == "emoji" else f"isolated_{role}_ttf"
        if role == "emoji" and dst_sha != src_sha:
            print(f"ERROR: emoji {target_name} hash changed unexpectedly", file=sys.stderr)
            return 1
        manifest_rows.append((kind, f"system/fonts/{target_name}", src_name, src_sha, dst_sha))
        print(f"Built {target_name} (role={role}, src={src_sha[:12]}..., out={dst_sha[:12]}...)")

    manifest_rows.sort(key=lambda r: r[1])
    manifest_path = os.path.join(args.out_dir, MANIFEST_FILENAME)
    with open(manifest_path, "w", encoding="utf-8", newline="\n") as mf:
        mf.write("# Generated font artifact manifest for ksu-noto-fonts-apple-emoji (v2.0.0)\n")
        mf.write("# Format: kind|zip_path|upstream_source|upstream_source_sha256|artifact_sha256\n")
        for row in manifest_rows:
            mf.write("|".join(row) + "\n")

    print(f"Wrote {MANIFEST_FILENAME} ({len(manifest_rows)} entries)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
