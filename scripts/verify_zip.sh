#!/bin/sh
# Verifies one or more packaged KernelSU font module ZIP archives.
# Checks ZIP integrity, path safety (no '..', leading '/', backslashes, or symlinks),
# presence of all required files (including font-manifest.txt), absence of unexpected files,
# pre-baked system/etc XML, runtime backups, reserved OEM copies (KsuReserved-*), or legacy
# KSU-* font filenames, exact SHA-256 match against sources.lock and validated build/fonts
# artifacts (font-manifest.txt + all 9 font files), and full fontTools 4-face TTC structure,
# region/index/axis, and source table correspondence for NotoSansCJK-Regular.ttc.

set -eu

ROOT_DIR=$(CDPATH='' cd -- "${0%/*}/.." && pwd)
LOCK_FILE="${FONT_LOCK_FILE:-$ROOT_DIR/sources.lock}"
BUILD_FONTS_DIR="${FONT_BUILD_DIR:-$ROOT_DIR/build/fonts}"
CACHE_DIR="${FONT_CACHE_DIR:-$ROOT_DIR/.cache/downloads}"

if [ "$#" -lt 1 ]; then
  printf 'Usage: %s <zip_path> [zip_path...]\n' "$0" >&2
  exit 1
fi

if [ ! -f "$LOCK_FILE" ]; then
  printf 'VERIFY ERROR: lockfile not found: %s\n' "$LOCK_FILE" >&2
  exit 1
fi

for zip_path in "$@"; do
  if [ ! -f "$zip_path" ]; then
    printf 'VERIFY ERROR: ZIP file not found: %s\n' "$zip_path" >&2
    exit 1
  fi

  # If a companion .sha256 file exists alongside the ZIP, verify it matches
  if [ -f "${zip_path}.sha256" ]; then
    zip_dir=$(CDPATH='' cd -- "$(dirname "$zip_path")" && pwd)
    zip_base=$(basename "$zip_path")
    (
      cd "$zip_dir"
      sha256sum -c "${zip_base}.sha256" >/dev/null
    ) || {
      printf 'VERIFY ERROR: companion checksum check failed for %s.sha256\n' "$zip_path" >&2
      exit 1
    }
  fi

  python3 -I - "$zip_path" "$LOCK_FILE" "$ROOT_DIR" "$BUILD_FONTS_DIR" "$CACHE_DIR" <<'PYEOF'
import hashlib
import os
import stat
import sys
import zipfile

zip_path = sys.argv[1]
lock_path = sys.argv[2]
root_dir = sys.argv[3]
build_fonts_dir = sys.argv[4]
cache_dir = sys.argv[5]
default_lock_path = os.path.join(root_dir, "sources.lock")

sys.path.insert(0, os.path.join(root_dir, "tools"))
import check_fonts as cf

def fail(msg: str) -> None:
    print(f"VERIFY ERROR ({zip_path}): {msg}", file=sys.stderr)
    sys.exit(1)

raw_fonts = {}
expected_hashes = {}
with open(lock_path, "r", encoding="utf-8") as lf:
    for raw in lf:
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split("|")
        if len(parts) != 5:
            fail(f"malformed sources.lock line: {line}")
        kind, dest_name, _ref, _url, sha256 = parts
        if kind == "font":
            raw_fonts[dest_name] = sha256.lower()
        elif kind == "license":
            expected_hashes[f"licenses/{dest_name}"] = sha256.lower()
        else:
            fail(f"unknown kind in sources.lock: {kind}")

OVERLAY_TTF_MAP = {
    fname: spec["upstream"]
    for fname, spec in cf.EXPECTED_TTF_SPECS.items()
}

for target_name, upstream_name in sorted(OVERLAY_TTF_MAP.items()):
    if upstream_name not in raw_fonts:
        fail(f"missing {upstream_name} in {lock_path}")
    expected_hashes[f"system/fonts/{target_name}"] = raw_fonts[upstream_name]

for ttc_src in cf.TTC_SOURCES:
    if ttc_src not in raw_fonts:
        fail(f"missing TTC source font {ttc_src} in {lock_path}")

if not os.path.isdir(build_fonts_dir):
    fail(f"validated build fonts directory not found: {build_fonts_dir}")

build_manifest_path = os.path.join(build_fonts_dir, cf.MANIFEST_FILENAME)
if not os.path.isfile(build_manifest_path):
    fail(f"validated build font manifest not found: {build_manifest_path}")

try:
    with open(build_manifest_path, "rb") as bmf:
        build_manifest_bytes = bmf.read()
    build_manifest_text = build_manifest_bytes.decode("utf-8")
except Exception as exc:
    fail(f"failed to read build font manifest {build_manifest_path}: {exc}")

build_font_hashes = {}
build_font_sizes = {}
for fname in sorted(set(OVERLAY_TTF_MAP.keys()) | {cf.TTC_FILENAME}):
    fpath = os.path.join(build_fonts_dir, fname)
    if not os.path.isfile(fpath):
        fail(f"missing validated build font artifact: {fpath}")
    build_font_hashes[f"system/fonts/{fname}"] = cf.sha256_file(fpath)
    build_font_sizes[f"system/fonts/{fname}"] = os.path.getsize(fpath)

bm_errs, bm_hashes = cf.validate_font_manifest_text(
    build_manifest_text, raw_fonts, build_font_hashes
)
if bm_errs:
    fail(f"invalid build font manifest ({build_manifest_path}): {bm_errs[0]}")

ttc_zip_path = f"system/fonts/{cf.TTC_FILENAME}"
expected_hashes[ttc_zip_path] = bm_hashes[ttc_zip_path]

required_non_locked = {
    "module.prop",
    "customize.sh",
    "NOTICE.md",
    cf.MANIFEST_FILENAME,
    "tools/fontconfig.sh",
    "tools/fontxml.awk",
}

required_all = set(expected_hashes.keys()) | required_non_locked

if not zipfile.is_zipfile(zip_path):
    fail("not a valid ZIP archive")

try:
    with zipfile.ZipFile(zip_path, "r") as zf:
        bad_member = zf.testzip()
        if bad_member is not None:
            fail(f"CRC check failed on member: {bad_member}")

        seen_files = set()
        prop_bytes = None
        manifest_bytes = None
        ttc_bytes = None
        sc_bytes = None
        tc_bytes = None
        zip_font_hashes = {}
        deferred_ttc_errors = []

        for info in zf.infolist():
            name = info.filename
            if not name:
                fail("empty entry filename")
            if name.startswith("/") or "\\" in name:
                fail(f"unsafe path in archive: {name}")
            norm_parts = name.split("/")
            if ".." in norm_parts or "." in norm_parts:
                fail(f"unsafe relative path traversal in archive: {name}")

            mode = (info.external_attr >> 16) & 0xFFFF
            if stat.S_ISLNK(mode):
                fail(f"symlink entry is forbidden in archive: {name}")

            if name.endswith("/"):
                continue

            base_entry = os.path.basename(name)
            if (
                name.startswith("system/etc/")
                or name.startswith("system/system_ext/")
                or name.startswith("system_ext/")
                or name.startswith("config/")
                or name.startswith("data/")
                or name.endswith(".xml")
                or name.endswith(".log")
            ):
                fail(f"pre-baked system/etc config or device XML/log is forbidden in ZIP: {name}")

            if base_entry.startswith("KsuReserved-"):
                fail(f"reserved OEM system font copy is forbidden in public ZIP: {name}")

            if base_entry.startswith("KSU-"):
                fail(f"legacy KSU-* font filename is forbidden in v1.0.2 ZIP: {name}")

            if name in seen_files:
                fail(f"duplicate entry in archive: {name}")
            seen_files.add(name)

            data = zf.read(name)
            if len(data) == 0:
                fail(f"empty file in archive: {name}")

            if name == "module.prop":
                prop_bytes = data
            elif name == cf.MANIFEST_FILENAME:
                manifest_bytes = data

            actual_sha = hashlib.sha256(data).hexdigest().lower()

            if name.startswith("system/fonts/"):
                zip_font_hashes[name] = actual_sha
                if name in build_font_hashes:
                    if len(data) != build_font_sizes[name] or actual_sha != build_font_hashes[name]:
                        err_msg = (
                            f"packaged font bytes mismatch against validated build artifact for {name}: "
                            f"expected sha256={build_font_hashes[name]} ({build_font_sizes[name]} bytes), "
                            f"got sha256={actual_sha} ({len(data)} bytes)"
                        )
                        if name == ttc_zip_path:
                            deferred_ttc_errors.append(err_msg)
                        else:
                            fail(err_msg)

            if name in expected_hashes:
                if actual_sha != expected_hashes[name]:
                    err_msg = f"SHA-256 mismatch for {name}: expected {expected_hashes[name]}, got {actual_sha}"
                    if name == ttc_zip_path:
                        deferred_ttc_errors.append(err_msg)
                    else:
                        fail(err_msg)

            if name == ttc_zip_path:
                ttc_bytes = data
            elif name == "system/fonts/SysSans-Hans-Regular.ttf":
                sc_bytes = data
            elif name == "system/fonts/SysSans-Hant-Regular.ttf":
                tc_bytes = data

        missing = required_all - seen_files
        if missing:
            fail(f"missing required files in archive: {sorted(missing)}")

        unexpected = seen_files - required_all
        if unexpected:
            fail(f"unexpected files in archive: {sorted(unexpected)}")

        if manifest_bytes is None:
            fail(f"{cf.MANIFEST_FILENAME} missing from archive")
        try:
            manifest_text = manifest_bytes.decode("utf-8")
        except UnicodeDecodeError as exc:
            fail(f"{cf.MANIFEST_FILENAME} is not valid UTF-8: {exc}")

        if ttc_bytes is None or sc_bytes is None or tc_bytes is None:
            fail("missing required CJK TTC/TTF payload in archive")

        if zip_font_hashes.get("system/fonts/SysSans-Hans-Regular.ttf") != raw_fonts[cf.TTC_SOURCES[2]]:
            fail(f"SysSans-Hans-Regular.ttf in archive does not match locked {cf.TTC_SOURCES[2]} SHA-256")
        if zip_font_hashes.get("system/fonts/SysSans-Hant-Regular.ttf") != raw_fonts[cf.TTC_SOURCES[3]]:
            fail(f"SysSans-Hant-Regular.ttf in archive does not match locked {cf.TTC_SOURCES[3]} SHA-256")

        source_ttfs = {2: sc_bytes, 3: tc_bytes}
        for idx in (0, 1):
            src_name = cf.TTC_SOURCES[idx]
            exp_src_sha = raw_fonts[src_name]
            cand_path = os.path.join(cache_dir, src_name)
            if not os.path.isfile(cand_path):
                fail(
                    f"missing required cached CJK source font for TTC face {idx} ({src_name}) at {cand_path} "
                    f"(set FONT_CACHE_DIR to directory containing locked upstream fonts)"
                )
            actual_src_sha = cf.sha256_file(cand_path)
            if actual_src_sha != exp_src_sha:
                fail(
                    f"SHA-256 mismatch for cached CJK source font for TTC face {idx} ({src_name}) at {cand_path}: "
                    f"expected {exp_src_sha}, got {actual_src_sha} (check FONT_CACHE_DIR)"
                )
            with open(cand_path, "rb") as fh:
                source_ttfs[idx] = fh.read()

        ttc_errs = cf.validate_ttc_bytes(
            ttc_bytes,
            filename=ttc_zip_path,
            source_ttfs=source_ttfs,
            check_size_bounds=False,
        )

        zm_errs, _zm_hashes = cf.validate_font_manifest_text(
            manifest_text, raw_fonts, zip_font_hashes
        )

        combined_errors = []
        if ttc_errs:
            combined_errors.append(f"invalid TTC payload ({ttc_errs[0]})")
        if zm_errs:
            combined_errors.append(f"invalid {cf.MANIFEST_FILENAME} in archive: {zm_errs[0]}")
        if manifest_bytes != build_manifest_bytes:
            combined_errors.append(
                f"{cf.MANIFEST_FILENAME} in archive does not match validated {build_manifest_path}"
            )
        combined_errors.extend(deferred_ttc_errors)
        if combined_errors:
            fail("; ".join(combined_errors))

        if prop_bytes is None:
            fail("module.prop missing from archive")
        try:
            prop_text = prop_bytes.decode("utf-8")
        except UnicodeDecodeError as exc:
            fail(f"module.prop is not valid UTF-8: {exc}")

        props = {}
        for raw_line in prop_text.splitlines():
            s = raw_line.strip()
            if not s or s.startswith("#"):
                continue
            if "=" not in s:
                fail(f"malformed line in module.prop: {raw_line!r}")
            k, v = s.split("=", 1)
            props[k.strip()] = v.strip()

        expected_props = {
            "id": "ksu_noto_fonts_apple_emoji",
            "author": "wang1zhen",
            "version": "v1.0.2",
            "versionCode": "102",
        }
        for req_k, exp_v in expected_props.items():
            act_v = props.get(req_k, "")
            if not act_v:
                fail(f"missing required key '{req_k}' in module.prop")
            if act_v != exp_v:
                fail(f"invalid module.prop {req_k}={act_v!r} (expected {exp_v!r})")

        zip_base = os.path.basename(zip_path)
        expected_zip_base = f"ksu-noto-fonts-apple-emoji-{props['version']}.zip"
        if (
            zip_base.startswith("ksu-noto-fonts-apple-emoji-")
            or os.path.abspath(lock_path) == os.path.abspath(default_lock_path)
        ):
            if zip_base != expected_zip_base:
                fail(f"ZIP filename mismatch: expected {expected_zip_base}, got {zip_base}")

except zipfile.BadZipFile as exc:
    fail(f"corrupted ZIP file: {exc}")

print(f"OK: {zip_path} ({len(required_all)} verified entries)")
PYEOF
done
