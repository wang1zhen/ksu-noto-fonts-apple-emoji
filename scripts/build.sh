#!/bin/sh
# Build script for ksu-noto-fonts-apple-emoji (v1.0.3).
# Fetches pinned upstream fonts and licenses from sources.lock into .cache/downloads,
# verifies SHA-256 digests, builds the 8 TTFs + 4-face NotoSansCJK-Regular.ttc
# via tools/make_fonts.py, runs tools/check_fonts.py on build/fonts, builds the
# 3 fixed XML configs via tools/make_xml.py from the root OEM XML inputs, writes
# payload.sha256, packages dist/ksu-noto-fonts-apple-emoji-v1.0.3.zip, and verifies it.

set -eu

ROOT_DIR=$(CDPATH='' cd -- "${0%/*}/.." && pwd)
LOCK_FILE="$ROOT_DIR/sources.lock"
CACHE_DIR="${FONT_CACHE_DIR:-$ROOT_DIR/.cache/downloads}"
XML_INPUT_DIR="${FONT_XML_INPUT_DIR:-$ROOT_DIR}"
BUILD_DIR="$ROOT_DIR/build"
FONTS_BUILD_DIR="$BUILD_DIR/fonts"
STAGE_DIR="$BUILD_DIR/module"
DIST_DIR="$ROOT_DIR/dist"

fail() {
  printf 'BUILD ERROR: %s\n' "$1" >&2
  exit 1
}

[ -f "$LOCK_FILE" ] || fail "sources.lock not found at $LOCK_FILE"
[ -f "$ROOT_DIR/module/module.prop" ] || fail "module/module.prop not found"

MOD_ID=$(sed -n 's/^id=//p' "$ROOT_DIR/module/module.prop" | head -n 1)
MOD_VERSION=$(sed -n 's/^version=//p' "$ROOT_DIR/module/module.prop" | head -n 1)
MOD_VERSION_CODE=$(sed -n 's/^versionCode=//p' "$ROOT_DIR/module/module.prop" | head -n 1)
MOD_AUTHOR=$(sed -n 's/^author=//p' "$ROOT_DIR/module/module.prop" | head -n 1)

[ -n "$MOD_ID" ] || fail "missing id in module/module.prop"
[ -n "$MOD_VERSION" ] || fail "missing version in module/module.prop"
[ -n "$MOD_VERSION_CODE" ] || fail "missing versionCode in module/module.prop"
[ -n "$MOD_AUTHOR" ] || fail "missing author in module/module.prop"

[ "$MOD_ID" = "ksu_noto_fonts_apple_emoji" ] || fail "unexpected id in module/module.prop: $MOD_ID"
[ "$MOD_VERSION" = "v1.0.3" ] || fail "unexpected version in module/module.prop: $MOD_VERSION (expected v1.0.3)"
[ "$MOD_VERSION_CODE" = "103" ] || fail "unexpected versionCode in module/module.prop: $MOD_VERSION_CODE (expected 103)"
[ "$MOD_AUTHOR" = "wang1zhen" ] || fail "unexpected author in module/module.prop: $MOD_AUTHOR (expected wang1zhen)"

mkdir -p "$CACHE_DIR"
rm -rf "$BUILD_DIR"
mkdir -p "$FONTS_BUILD_DIR" "$STAGE_DIR" "$DIST_DIR"

verify_sha256() {
  file_path="$1"
  expected_hash="$2"
  actual_hash=$(sha256sum "$file_path" | awk '{print tolower($1)}')
  expected_lower=$(printf '%s' "$expected_hash" | tr '[:upper:]' '[:lower:]')
  [ "$actual_hash" = "$expected_lower" ]
}

download_file() {
  url="$1"
  dest="$2"
  tmp_dest="$dest.part.$$"
  rm -f "$tmp_dest"
  if command -v curl >/dev/null 2>&1; then
    curl -fL --retry 3 --connect-timeout 20 "$url" -o "$tmp_dest" || {
      rm -f "$tmp_dest"
      return 1
    }
  elif command -v wget >/dev/null 2>&1; then
    wget -q -O "$tmp_dest" "$url" || {
      rm -f "$tmp_dest"
      return 1
    }
  else
    fail "Neither curl nor wget is available for downloading assets"
  fi
  mv -f "$tmp_dest" "$dest"
}

printf '%s\n' "==> Checking and fetching locked upstream assets..."
while IFS='|' read -r kind dest_name upstream_ref url sha256 || [ -n "${kind:-}" ]; do
  case "$kind" in
    ''|\#*) continue ;;
  esac
  if [ -z "$dest_name" ] || [ -z "$url" ] || [ -z "$sha256" ]; then
    fail "Malformed entry in sources.lock: $kind|$dest_name"
  fi

  cached_file="$CACHE_DIR/$dest_name"
  if [ -f "$cached_file" ]; then
    if ! verify_sha256 "$cached_file" "$sha256"; then
      printf 'Cached file %s failed SHA-256 check, re-downloading...\n' "$dest_name"
      rm -f "$cached_file"
    fi
  fi

  if [ ! -f "$cached_file" ]; then
    printf 'Downloading %s (%s)...\n' "$dest_name" "$upstream_ref"
    download_file "$url" "$cached_file" || fail "Failed to download $url"
  fi

  if ! verify_sha256 "$cached_file" "$sha256"; then
    rm -f "$cached_file"
    fail "SHA-256 mismatch for $dest_name after download"
  fi

  case "$kind" in
    font)
      :
      ;;
    license)
      mkdir -p "$ROOT_DIR/licenses"
      cp -pf "$cached_file" "$ROOT_DIR/licenses/$dest_name"
      ;;
    *)
      fail "Unknown asset kind in sources.lock: $kind"
      ;;
  esac
done < "$LOCK_FILE"

printf '%s\n' "==> Generating module fonts and 4-face TTC with tools/make_fonts.py..."
python3 -I "$ROOT_DIR/tools/make_fonts.py" "$CACHE_DIR" "$FONTS_BUILD_DIR" --lock "$LOCK_FILE"

printf '%s\n' "==> Validating fonts with tools/check_fonts.py..."
python3 -I "$ROOT_DIR/tools/check_fonts.py" "$FONTS_BUILD_DIR" --lock "$LOCK_FILE"

printf '%s\n' "==> Generating fixed XML configs with tools/make_xml.py..."
python3 -I "$ROOT_DIR/tools/make_xml.py" "$XML_INPUT_DIR" "$STAGE_DIR"

printf '%s\n' "==> Staging KernelSU module directory..."
mkdir -p \
  "$STAGE_DIR/system/fonts" \
  "$STAGE_DIR/licenses"

cp -pf "$ROOT_DIR/module/module.prop" "$STAGE_DIR/module.prop"
cp -pf "$ROOT_DIR/module/customize.sh" "$STAGE_DIR/customize.sh"
cp -pf "$ROOT_DIR/NOTICE.md" "$STAGE_DIR/NOTICE.md"
cp -pf "$FONTS_BUILD_DIR/font-manifest.txt" "$STAGE_DIR/font-manifest.txt"
cp -pf "$ROOT_DIR/licenses/"*.txt "$STAGE_DIR/licenses/"
cp -pf "$FONTS_BUILD_DIR/"*.ttf "$STAGE_DIR/system/fonts/"
cp -pf "$FONTS_BUILD_DIR/"*.ttc "$STAGE_DIR/system/fonts/"

python3 -I - "$STAGE_DIR" <<'PYEOF'
import hashlib
import os
import sys

stage_dir = sys.argv[1]
payload_rel_paths = []
for root, dirs, files in os.walk(stage_dir):
    dirs.sort()
    files.sort()
    for f in files:
        full = os.path.join(root, f)
        rel = os.path.relpath(full, stage_dir).replace(os.sep, "/")
        if rel in ("payload.sha256", "customize.sh"):
            continue
        payload_rel_paths.append(rel)

payload_rel_paths.sort()
out_path = os.path.join(stage_dir, "payload.sha256")
with open(out_path, "w", encoding="utf-8", newline="\n") as pf:
    for rel in payload_rel_paths:
        h = hashlib.sha256()
        with open(os.path.join(stage_dir, rel), "rb") as fh:
            while True:
                chunk = fh.read(1024 * 1024)
                if not chunk:
                    break
                h.update(chunk)
        pf.write(f"{h.hexdigest().lower()}  {rel}\n")
PYEOF

chmod 0755 "$STAGE_DIR/customize.sh"
chmod 0644 \
  "$STAGE_DIR/module.prop" \
  "$STAGE_DIR/NOTICE.md" \
  "$STAGE_DIR/font-manifest.txt" \
  "$STAGE_DIR/device-sources.sha256" \
  "$STAGE_DIR/payload.sha256" \
  "$STAGE_DIR/system/etc/font_fallback.xml" \
  "$STAGE_DIR/system/etc/fonts.xml" \
  "$STAGE_DIR/system/system_ext/etc/fonts_base.xml"
chmod 0644 "$STAGE_DIR/licenses/"*.txt "$STAGE_DIR/system/fonts/"*.ttf "$STAGE_DIR/system/fonts/"*.ttc

ZIP_NAME="ksu-noto-fonts-apple-emoji-${MOD_VERSION}.zip"
ZIP_PATH="$DIST_DIR/$ZIP_NAME"
TMP_ZIP="$DIST_DIR/.tmp-${ZIP_NAME}"
rm -f "$TMP_ZIP" "$ZIP_PATH" "$ZIP_PATH.sha256"

printf '%s\n' "==> Packaging deterministic ZIP archive: $ZIP_PATH..."
python3 -I - "$STAGE_DIR" "$TMP_ZIP" <<'PYEOF'
import os
import stat
import sys
import zipfile

stage_dir = sys.argv[1]
out_zip = sys.argv[2]
FIXED_TIME = (2026, 1, 1, 0, 0, 0)

entries = []
for root, dirs, files in os.walk(stage_dir):
    dirs.sort()
    files.sort()
    for f in files:
        full_path = os.path.join(root, f)
        rel_path = os.path.relpath(full_path, stage_dir).replace(os.sep, "/")
        entries.append((rel_path, full_path))

entries.sort(key=lambda x: x[0])

with zipfile.ZipFile(out_zip, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=6) as zf:
    for rel_path, full_path in entries:
        st = os.stat(full_path)
        mode = stat.S_IMODE(st.st_mode)
        zi = zipfile.ZipInfo(filename=rel_path, date_time=FIXED_TIME)
        zi.compress_type = zipfile.ZIP_DEFLATED
        zi.create_system = 3  # Unix
        zi.external_attr = (stat.S_IFREG | mode) << 16
        with open(full_path, "rb") as fh:
            zf.writestr(zi, fh.read(), compress_type=zipfile.ZIP_DEFLATED, compresslevel=6)
PYEOF

mv -f "$TMP_ZIP" "$ZIP_PATH"
(
  cd "$DIST_DIR"
  sha256sum "$ZIP_NAME" > "${ZIP_NAME}.sha256"
)

printf '%s\n' "==> Verifying packaged ZIP..."
FONT_BUILD_DIR="$FONTS_BUILD_DIR" FONT_CACHE_DIR="$CACHE_DIR" sh "$ROOT_DIR/scripts/verify_zip.sh" "$ZIP_PATH"

printf 'Build succeeded: %s\n' "$ZIP_PATH"
