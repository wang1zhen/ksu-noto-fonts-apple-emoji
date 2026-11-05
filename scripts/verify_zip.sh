#!/bin/sh
# Verifies one or more packaged KernelSU font module ZIP archives (v2.0.0).
# Checks ZIP integrity, path safety, exact required entry set (7 standalone role-isolated TTFs,
# font-manifest.txt, tools/fontconfig.sh, tools/fontxml.awk, module.prop, customize.sh,
# LICENSE, NOTICE.md, 3 license files), absence of fixed XMLs / TTCs / OEM copies / WebUI /
# action / service / post-fs-data scripts, and exact SHA-256 match against sources.lock and
# validated build/fonts artifacts.

set -eu

ROOT_DIR=$(CDPATH='' cd -- "${0%/*}/.." && pwd)
LOCK_FILE="${FONT_LOCK_FILE:-$ROOT_DIR/sources.lock}"
BUILD_FONTS_DIR="${FONT_BUILD_DIR:-$ROOT_DIR/build/fonts}"

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

  python3 -I - "$zip_path" "$LOCK_FILE" "$ROOT_DIR" "$BUILD_FONTS_DIR" <<'PYEOF'
import hashlib
import os
import stat
import sys
import zipfile

zip_path = sys.argv[1]
lock_path = sys.argv[2]
root_dir = sys.argv[3]
build_fonts_dir = sys.argv[4]
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

if not os.path.isdir(build_fonts_dir):
    fail(f"validated build fonts directory not found: {build_fonts_dir}")

build_manifest_path = os.path.join(build_fonts_dir, cf.MANIFEST_FILENAME)
if not os.path.isfile(build_manifest_path):
    fail(f"validated build font manifest not found: {build_manifest_path}")

with open(build_manifest_path, "rb") as bmf:
    build_manifest_bytes = bmf.read()
build_manifest_text = build_manifest_bytes.decode("utf-8")

build_font_hashes = {}
build_font_sizes = {}
for fname in sorted(cf.EXPECTED_TTF_SPECS.keys()):
    fpath = os.path.join(build_fonts_dir, fname)
    if not os.path.isfile(fpath):
        fail(f"missing validated build font artifact: {fpath}")
    rel = f"system/fonts/{fname}"
    build_font_hashes[rel] = cf.sha256_file(fpath)
    build_font_sizes[rel] = os.path.getsize(fpath)
    expected_hashes[rel] = build_font_hashes[rel]

bm_errs, _bm_hashes = cf.validate_font_manifest_text(
    build_manifest_text, raw_fonts, build_font_hashes
)
if bm_errs:
    fail(f"invalid build font manifest ({build_manifest_path}): {bm_errs[0]}")

repo_file_map = {
    "module.prop": os.path.join(root_dir, "module", "module.prop"),
    "customize.sh": os.path.join(root_dir, "module", "customize.sh"),
    "tools/fontconfig.sh": os.path.join(root_dir, "module", "tools", "fontconfig.sh"),
    "tools/fontxml.awk": os.path.join(root_dir, "module", "tools", "fontxml.awk"),
    "LICENSE": os.path.join(root_dir, "LICENSE"),
    "NOTICE.md": os.path.join(root_dir, "NOTICE.md"),
}
for zrel, rpath in repo_file_map.items():
    if not os.path.isfile(rpath):
        fail(f"missing source file in repository: {rpath}")
    expected_hashes[zrel] = cf.sha256_file(rpath)

expected_hashes[cf.MANIFEST_FILENAME] = hashlib.sha256(build_manifest_bytes).hexdigest().lower()
required_all = set(expected_hashes.keys())

FORBIDDEN_PREFIXES = (
    "webroot/",
    "webui/",
    "config/",
    "data/",
    "emoji/",
    "system/etc/",
    "system/system_ext/",
    "system/product/",
    "system/vendor/",
)
FORBIDDEN_NAMES = {
    "action.sh",
    "service.sh",
    "post-fs-data.sh",
    "tools/fontctl.sh",
    "device-sources.sha256",
    "payload.sha256",
    "system/fonts/NotoSansCJK-Regular.ttc",
    "system/fonts/Roboto-Regular.ttf",
    "system/fonts/SysFont-Regular.ttf",
    "system/fonts/SysSans-En-Regular.ttf",
    "system/fonts/OPSans-En-Regular.ttf",
    "system/fonts/SysSans-Hans-Regular.ttf",
    "system/fonts/SysSans-Hant-Regular.ttf",
    "system/fonts/NotoColorEmoji.ttf",
    "system/fonts/NotoSans-Italic.ttf",
}

if not zipfile.is_zipfile(zip_path):
    fail("not a valid ZIP archive")

try:
    with zipfile.ZipFile(zip_path, "r") as zf:
        bad_member = zf.testzip()
        if bad_member is not None:
            fail(f"CRC check failed on member: {bad_member}")

        seen_files = set()
        file_bytes = {}
        zip_font_hashes = {}

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
            if any(name.startswith(p) for p in FORBIDDEN_PREFIXES) or name in FORBIDDEN_NAMES:
                fail(f"forbidden file or directory in v2.0.0 ZIP: {name}")
            if name.endswith(".ttc") or name.endswith(".xml") or name.endswith(".log"):
                fail(f"forbidden TTC/XML/log entry in v2.0.0 ZIP: {name}")
            if base_entry.startswith("KsuReserved-") or base_entry.startswith("FontSetting"):
                fail(f"forbidden OEM or legacy font entry in ZIP: {name}")

            if name in seen_files:
                fail(f"duplicate entry in archive: {name}")
            seen_files.add(name)

            data = zf.read(name)
            if len(data) == 0:
                fail(f"empty file in archive: {name}")

            file_bytes[name] = data
            actual_sha = hashlib.sha256(data).hexdigest().lower()

            if name.startswith("system/fonts/"):
                zip_font_hashes[name] = actual_sha
                if name in build_font_sizes and len(data) != build_font_sizes[name]:
                    fail(
                        f"size mismatch for {name}: expected {build_font_sizes[name]} bytes, got {len(data)}"
                    )

            if name in expected_hashes and actual_sha != expected_hashes[name]:
                fail(
                    f"SHA-256 mismatch for {name}: expected {expected_hashes[name]}, got {actual_sha}"
                )

        missing = required_all - seen_files
        if missing:
            fail(f"missing required files in archive: {sorted(missing)}")

        unexpected = seen_files - required_all
        if unexpected:
            fail(f"unexpected files in archive: {sorted(unexpected)}")

        manifest_text = file_bytes[cf.MANIFEST_FILENAME].decode("utf-8")
        zm_errs, _ = cf.validate_font_manifest_text(manifest_text, raw_fonts, zip_font_hashes)
        if zm_errs:
            fail(f"invalid {cf.MANIFEST_FILENAME} in archive: {zm_errs[0]}")

        awk_text = file_bytes["tools/fontxml.awk"].decode("utf-8")
        fc_text = file_bytes["tools/fontconfig.sh"].decode("utf-8")
        for font_fname in cf.EXPECTED_TTF_SPECS:
            if font_fname not in awk_text or font_fname not in fc_text:
                fail(f"packaged font {font_fname} not referenced in tools/fontxml.awk and tools/fontconfig.sh")

        prop_text = file_bytes["module.prop"].decode("utf-8")
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
            "version": "v2.0.0",
            "versionCode": "200",
        }
        for req_k, exp_v in expected_props.items():
            act_v = props.get(req_k, "")
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
