#!/usr/bin/env python3
"""Host-side font builder for ksu-noto-fonts-apple-emoji.

Verifies locked upstream source fonts from sources.lock in <cache_dir>, stages the
8 original-filename TTF overlays, and builds the 4-face NotoSansCJK-Regular.ttc
(index 0=JP, 1=KR, 2=SC, 3=TC) with table sharing into <out_dir>.
"""

import argparse
import hashlib
import os
import shutil
import sys
from fontTools.ttLib import TTCollection, TTFont


UPSTREAM_TTF_MAP = {
    "SysFont-Regular.ttf": "KSU-NotoSans-Regular-VF.ttf",
    "Roboto-Regular.ttf": "KSU-NotoSans-Regular-VF.ttf",
    "SysSans-En-Regular.ttf": "KSU-NotoSans-Regular-VF.ttf",
    "OPSans-En-Regular.ttf": "KSU-NotoSans-Regular-VF.ttf",
    "NotoSans-Italic.ttf": "KSU-NotoSans-Italic-VF.ttf",
    "SysSans-Hans-Regular.ttf": "KSU-NotoSansCJKsc-VF.ttf",
    "SysSans-Hant-Regular.ttf": "KSU-NotoSansCJKtc-VF.ttf",
    "NotoColorEmoji.ttf": "KSU-AppleColorEmoji.ttf",
}

TTC_FILENAME = "NotoSansCJK-Regular.ttc"
TTC_SOURCES = [
    "KSU-NotoSansCJKjp-VF.ttf",  # index 0: JP
    "KSU-NotoSansCJKkr-VF.ttf",  # index 1: KR
    "KSU-NotoSansCJKsc-VF.ttf",  # index 2: SC
    "KSU-NotoSansCJKtc-VF.ttf",  # index 3: TC
]
MANIFEST_FILENAME = "font-manifest.txt"


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
    parser = argparse.ArgumentParser(description="Build original-filename module font payload.")
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

    required_sources = set(UPSTREAM_TTF_MAP.values()) | set(TTC_SOURCES)
    for src_name in sorted(required_sources):
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
    for target_name, src_name in sorted(UPSTREAM_TTF_MAP.items()):
        src_path = os.path.join(args.cache_dir, src_name)
        dst_path = os.path.join(args.out_dir, target_name)
        shutil.copyfile(src_path, dst_path)
        dst_sha = sha256_file(dst_path)
        src_sha = lock_hashes[src_name]
        if dst_sha != src_sha:
            print(f"ERROR: staged {target_name} hash mismatch", file=sys.stderr)
            return 1
        manifest_rows.append(
            ("overlay_ttf", f"system/fonts/{target_name}", src_name, src_sha, dst_sha)
        )
        print(f"Staged {target_name} <- {src_name}")

    ttc_out = os.path.join(args.out_dir, TTC_FILENAME)
    ttc_fonts = [
        TTFont(os.path.join(args.cache_dir, s), lazy=True, recalcTimestamp=False)
        for s in TTC_SOURCES
    ]
    ttc = TTCollection()
    ttc.fonts = ttc_fonts
    ttc.save(ttc_out, shareTables=True)
    for f in ttc_fonts:
        f.close()

    ttc_sha = sha256_file(ttc_out)
    ttc_src_names = ",".join(f"{idx}={s}" for idx, s in enumerate(TTC_SOURCES))
    ttc_src_shas = ",".join(f"{idx}={lock_hashes[s]}" for idx, s in enumerate(TTC_SOURCES))
    manifest_rows.append(
        ("generated_ttc", f"system/fonts/{TTC_FILENAME}", ttc_src_names, ttc_src_shas, ttc_sha)
    )
    manifest_rows.sort(key=lambda r: r[1])

    manifest_path = os.path.join(args.out_dir, MANIFEST_FILENAME)
    with open(manifest_path, "w", encoding="utf-8", newline="\n") as mf:
        mf.write("# Generated font artifact manifest for ksu-noto-fonts-apple-emoji (v1.0.2)\n")
        mf.write("# Format: kind|zip_path|upstream_sources|upstream_source_sha256|artifact_sha256\n")
        for row in manifest_rows:
            mf.write("|".join(row) + "\n")

    ttc_size = os.path.getsize(ttc_out)
    print(f"Built {TTC_FILENAME} ({ttc_size} bytes, sha256={ttc_sha}, 4 faces: 0=JP, 1=KR, 2=SC, 3=TC)")
    print(f"Wrote {MANIFEST_FILENAME} ({len(manifest_rows)} entries)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
