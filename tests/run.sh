#!/bin/sh
# End-to-end BusyBox 1.36.1 ash/awk & real 3-OEM XML regression runner for v2.0.0.
# Run with: KSU_TEST_BUSYBOX=/usr/lib/initcpio/busybox TMPDIR=/tmp/opencode sh tests/run.sh

set -eu

TEST_DIR=$(CDPATH='' cd -- "${0%/*}" && pwd)
ROOT_DIR=$(CDPATH='' cd -- "$TEST_DIR/.." && pwd)
BUSYBOX_BIN="${KSU_TEST_BUSYBOX:-/usr/lib/initcpio/busybox}"
BASE_TMP="${TMPDIR:-/tmp}"
mkdir -p "$BASE_TMP"
WORK_DIR="$BASE_TMP/ksu-noto-v200-test.$$"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() {
  printf 'TEST ERROR: %s\n' "$1" >&2
  exit 1
}

[ -x "$BUSYBOX_BIN" ] || fail "BusyBox binary not executable at $BUSYBOX_BIN"
for oem_xml in fonts.xml font_fallback.xml fonts_base.xml; do
  [ -f "$ROOT_DIR/$oem_xml" ] || fail "Required root OEM XML missing: $ROOT_DIR/$oem_xml (must not skip)"
done

BB_VER=$("$BUSYBOX_BIN" --help 2>&1 | head -n 1)
printf '==> Using BusyBox: %s (%s)\n' "$BUSYBOX_BIN" "$BB_VER"

BB_PATH="$WORK_DIR/bb_bin"
mkdir -p "$BB_PATH"
for applet in sh ash awk grep sed cp mv rm mkdir chmod cat sort head tr; do
  ln -sf "$BUSYBOX_BIN" "$BB_PATH/$applet"
done

run_bb_sh() {
  PATH="$BB_PATH:$PATH" "$BUSYBOX_BIN" ash "$@"
}

setup_mod() {
  target_mod="$1"
  rm -rf "$target_mod"
  mkdir -p "$target_mod/tools" "$target_mod/system/fonts"
  cp -pf "$ROOT_DIR/module/customize.sh" "$target_mod/customize.sh"
  cp -pf "$ROOT_DIR/module/tools/fontconfig.sh" "$target_mod/tools/fontconfig.sh"
  cp -pf "$ROOT_DIR/module/tools/fontxml.awk" "$target_mod/tools/fontxml.awk"
  for f in \
    KSU-NotoSans-Regular-VF.ttf \
    KSU-NotoSans-Italic-VF.ttf \
    KSU-NotoSansCJKsc-VF.ttf \
    KSU-NotoSansCJKtc-VF.ttf \
    KSU-NotoSansCJKjp-VF.ttf \
    KSU-NotoSansCJKkr-VF.ttf \
    KSU-AppleColorEmoji.ttf; do
    printf 'placeholder\n' > "$target_mod/system/fonts/$f"
  done
}

printf '%s\n' "==> [1/3] Running BusyBox ash/awk on synthetic fixtures..."
MOD1="$WORK_DIR/mod_fixture"
SYS1="$WORK_DIR/sys_fixture"
setup_mod "$MOD1"
mkdir -p "$SYS1/system/etc" "$SYS1/system/system_ext/etc"
cp -pf "$ROOT_DIR/tests/fixtures/fonts.excerpt.xml" "$SYS1/system/etc/fonts.xml"
cp -pf "$ROOT_DIR/tests/fixtures/font_fallback.excerpt.xml" "$SYS1/system/etc/font_fallback.xml"
cp -pf "$ROOT_DIR/tests/fixtures/fonts_base.excerpt.xml" "$SYS1/system/system_ext/etc/fonts_base.xml"

out1=$(FONT_CONFIG_ROOT="$SYS1" run_bb_sh "$MOD1/tools/fontconfig.sh" prepare)
printf '    %s\n' "$out1"
[ "$out1" = "ok=config files=3 western=8 cjk=12 sc=3 tc=3 jp=3 kr=3 emoji=3" ] || fail "unexpected fixture stats: $out1"

printf '%s\n' "==> [2/3] Running BusyBox ash/awk on real root 3-OEM XMLs (no skip)..."
MOD2="$WORK_DIR/mod_oem"
SYS2="$WORK_DIR/sys_oem"
ADB2="$WORK_DIR/adb_oem"
setup_mod "$MOD2"
mkdir -p "$SYS2/system/etc" "$SYS2/system_ext/etc" "$ADB2/modules"
cp -pf "$ROOT_DIR/fonts.xml" "$SYS2/system/etc/fonts.xml"
cp -pf "$ROOT_DIR/font_fallback.xml" "$SYS2/system/etc/font_fallback.xml"
cp -pf "$ROOT_DIR/fonts_base.xml" "$SYS2/system_ext/etc/fonts_base.xml"

out2=$(MODPATH="$MOD2" KSU="true" KSU_SDK_VERSION="36" KSU_ADB_ROOT="$ADB2" FONT_CONFIG_ROOT="$SYS2" run_bb_sh "$MOD2/customize.sh")
printf '%s\n' "$out2" | grep -q "ok=config files=3 western=8 cjk=12 sc=3 tc=3 jp=3 kr=3 emoji=3" || fail "OEM customize.sh stats mismatch"

python3 -I - "$MOD2/system" <<'PYEOF'
import os
import sys
import xml.etree.ElementTree as ET

sys_dir = sys.argv[1]
for rel in ("etc/fonts.xml", "etc/font_fallback.xml", "system_ext/etc/fonts_base.xml"):
    p = os.path.join(sys_dir, rel)
    assert os.path.isfile(p), f"Missing generated OEM XML: {p}"
    root = ET.parse(p).getroot()
    assert root.tag == "familyset", f"Unexpected root tag in {p}"
print("    Verified all 3 generated OEM XMLs parse cleanly with ElementTree.")
PYEOF

printf '%s\n' "==> [3/3] Running Python unittest suite..."
KSU_TEST_BUSYBOX="$BUSYBOX_BIN" python3 -I -m unittest discover -s "$ROOT_DIR/tests" -v

printf '%s\n' "All BusyBox + real OEM + unittest checks passed."
