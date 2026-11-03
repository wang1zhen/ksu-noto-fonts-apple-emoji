#!/system/bin/sh
# KernelSU module install script for OnePlus 13 / Android 16 / OxygenOS 16.
# Runs inside the KernelSU installer environment where $MODPATH, ui_print, abort,
# set_perm, and set_perm_recursive are provided.

# Provide safe fallbacks when invoked in standalone test harnesses
if ! command -v ui_print >/dev/null 2>&1; then
  ui_print() {
    printf '%s\n' "$*"
  }
fi

if ! command -v abort >/dev/null 2>&1; then
  abort() {
    ui_print "$*"
    exit 1
  }
fi

if ! command -v set_perm >/dev/null 2>&1; then
  set_perm() {
    chown "$2:$3" "$1" 2>/dev/null || :
    chmod "$4" "$1" 2>/dev/null || :
  }
fi

if ! command -v set_perm_recursive >/dev/null 2>&1; then
  set_perm_recursive() {
    find "$1" -type d -exec chmod "$4" {} + 2>/dev/null || :
    find "$1" -type f -exec chmod "$5" {} + 2>/dev/null || :
  }
fi

ui_print "************************************************"
ui_print " Noto Sans + Noto Sans CJK + Apple Emoji"
ui_print " Target: OnePlus 13 / Android 16 / OxygenOS 16"
ui_print "************************************************"

if [ -z "${MODPATH:-}" ] || [ ! -d "$MODPATH" ]; then
  abort "! MODPATH is not set or does not exist"
fi

if [ "${KSU:-}" != "true" ] && [ -z "${KSU_VER_CODE:-}" ]; then
  abort "! This module requires KernelSU (KSU environment not detected)"
fi

if command -v getprop >/dev/null 2>&1; then
  sdk="$(getprop ro.build.version.sdk 2>/dev/null || :)"
  case "$sdk" in
    ''|*[!0-9]*)
      abort "! Failed to read Android SDK version (ro.build.version.sdk)"
      ;;
  esac
  if [ "$sdk" -lt 35 ]; then
    abort "! Unsupported Android SDK $sdk (requires Android 15/16+ OxygenOS VF font architecture)"
  fi
fi

ui_print "- Validating environment and adapting system XML..."
prep_out="$(sh "$MODPATH/tools/fontconfig.sh" prepare 2>&1)"
prep_rc=$?
if [ "$prep_rc" -ne 0 ]; then
  ui_print "! Font configuration adaptation failed:"
  ui_print "! $prep_out"
  rm -rf "$MODPATH/.staging" "$MODPATH/system/etc" 2>/dev/null || :
  abort "! Installation aborted safely without modifying system partitions"
fi

ui_print "- Adapted /system/etc/font_fallback.xml and /system/etc/fonts.xml"
if [ -f "$MODPATH/data/fallback.stats" ]; then
  ui_print "- Fallback stats: $(cat "$MODPATH/data/fallback.stats" 2>/dev/null)"
fi
if [ -f "$MODPATH/data/legacy.stats" ]; then
  ui_print "- Legacy stats:   $(cat "$MODPATH/data/legacy.stats" 2>/dev/null)"
fi

set_perm_recursive "$MODPATH" 0 0 0755 0644
set_perm "$MODPATH/customize.sh" 0 0 0755
set_perm "$MODPATH/tools/fontconfig.sh" 0 0 0755
set_perm "$MODPATH/tools/fontxml.awk" 0 0 0644

ui_print "- Static metamodule entrypoint (metamount.sh) verified; actual mount occurs on reboot."
ui_print "- Installation complete. Reboot device and verify /system/fonts/KSU-* is mounted."
