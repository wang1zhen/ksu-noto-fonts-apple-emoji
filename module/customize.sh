#!/system/bin/sh
# KernelSU module install script for ksu_noto_fonts_apple_emoji (v2.0.0)
# Adapted from font-settings/customize.sh (MIT License, Copyright (c) 2026 yuzlyn)

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

MODID="ksu_noto_fonts_apple_emoji"
ADB_ROOT="${KSU_ADB_ROOT:-/data/adb}"
SYS_ROOT="${FONT_CONFIG_ROOT:-${KSU_SYSTEM_ROOT:-}}"

ui_print "************************************************"
ui_print " Noto Sans + Noto Sans CJK + Apple Emoji (v2.0.0)"
ui_print " by wang1zhen (based on font-settings by yuzlyn)"
ui_print "************************************************"

if [ -z "${MODPATH:-}" ] || [ ! -d "$MODPATH" ]; then
  abort "! MODPATH is not set or does not exist"
fi

if [ "${KSU:-}" != "true" ] && [ -z "${KSU_VER_CODE:-}" ]; then
  abort "! This module requires KernelSU (KSU environment not detected)"
fi

sdk="${KSU_SDK_VERSION:-}"
if [ -z "$sdk" ] && command -v getprop >/dev/null 2>&1; then
  sdk="$(getprop ro.build.version.sdk 2>/dev/null || :)"
fi
case "$sdk" in
  ''|*[!0-9]*)
    abort "! Failed to read Android SDK version (ro.build.version.sdk)"
    ;;
esac
if [ "$sdk" -lt 26 ]; then
  abort "! Unsupported Android SDK $sdk (requires Android 8.0 / API 26+)"
fi

modpath_real="$(CDPATH='' cd -P -- "$MODPATH" 2>/dev/null && pwd || printf '%s' "$MODPATH")"
active_mod_dir="$ADB_ROOT/modules/$MODID"
if [ -e "$active_mod_dir" ] || [ -L "$active_mod_dir" ]; then
  active_real="$(CDPATH='' cd -P -- "$active_mod_dir" 2>/dev/null && pwd || printf '%s' "$active_mod_dir")"
  if [ "$active_real" != "$modpath_real" ]; then
    abort "! Existing module found at $active_mod_dir; uninstall previous version and reboot before installing v2.0.0"
  fi
fi

ui_print "- Capturing stock Android font XMLs and generating module configs..."
if ! config_result="$(FONT_CONFIG_ROOT="$SYS_ROOT" sh "$MODPATH/tools/fontconfig.sh" prepare 2>&1)"; then
  ui_print "! Failed to adapt device font configuration: $config_result"
  case "$config_result" in
    *self_overlay_detected*)
      abort "! Active module font references detected in /system; uninstall old module and reboot first"
      ;;
    *)
      abort "! Aborting installation without modifying system"
      ;;
  esac
fi

ui_print "- $config_result"

set_perm_recursive "$MODPATH" 0 0 0755 0644
set_perm "$MODPATH/customize.sh" 0 0 0755
set_perm "$MODPATH/tools/fontconfig.sh" 0 0 0755
set_perm "$MODPATH/tools/fontxml.awk" 0 0 0644

ui_print "- Installation complete. Please reboot device to activate fonts."
