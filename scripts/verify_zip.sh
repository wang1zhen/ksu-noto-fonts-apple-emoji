#!/bin/sh
# Verifies one or more packaged KernelSU font module ZIP archives.
# Checks ZIP integrity, path safety (no '..', leading '/', backslashes, or symlinks),
# presence of all required files, absence of unexpected files or pre-baked system/etc XML,
# and exact SHA-256 match against sources.lock for all bundled fonts and licenses.

set -eu

ROOT_DIR=$(CDPATH='' cd -- "${0%/*}/.." && pwd)
LOCK_FILE="${FONT_LOCK_FILE:-$ROOT_DIR/sources.lock}"

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

  python3 -I - "$zip_path" "$LOCK_FILE" "$ROOT_DIR/sources.lock" <<'PYEOF'
import hashlib
import os
import stat
import sys
import zipfile

zip_path = sys.argv[1]
lock_path = sys.argv[2]
default_lock_path = sys.argv[3]

def fail(msg: str) -> None:
    print(f"VERIFY ERROR ({zip_path}): {msg}", file=sys.stderr)
    sys.exit(1)

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
            expected_hashes[f"system/fonts/{dest_name}"] = sha256.lower()
        elif kind == "license":
            expected_hashes[f"licenses/{dest_name}"] = sha256.lower()
        else:
            fail(f"unknown kind in sources.lock: {kind}")

required_non_locked = {
    "module.prop",
    "customize.sh",
    "NOTICE.md",
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

            if (
                name.startswith("system/etc/")
                or name.startswith("system/system_ext/")
                or name.startswith("system_ext/")
                or name.startswith("config/")
                or name.endswith(".xml")
                or name.endswith(".log")
            ):
                fail(f"pre-baked system/etc config or device XML/log is forbidden in ZIP: {name}")

            if name in seen_files:
                fail(f"duplicate entry in archive: {name}")
            seen_files.add(name)

            data = zf.read(name)
            if len(data) == 0:
                fail(f"empty file in archive: {name}")

            if name == "module.prop":
                prop_bytes = data

            if name in expected_hashes:
                actual_sha = hashlib.sha256(data).hexdigest().lower()
                if actual_sha != expected_hashes[name]:
                    fail(
                        f"SHA-256 mismatch for {name}: expected {expected_hashes[name]}, got {actual_sha}"
                    )

        missing = required_all - seen_files
        if missing:
            fail(f"missing required files in archive: {sorted(missing)}")

        unexpected = seen_files - required_all
        if unexpected:
            fail(f"unexpected files in archive: {sorted(unexpected)}")

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
            "version": "v1.0.1",
            "versionCode": "101",
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
