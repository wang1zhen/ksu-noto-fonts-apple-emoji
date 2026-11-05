#!/system/bin/sh
# KernelSU module install script for OnePlus 13 / Android 16 / OxygenOS 16 (v1.0.3).
# Verifies KernelSU + Android 16 (API 36), ensures any previous active module installation
# under /data/adb/modules is removed and rebooted first, matches live device XML SHA-256
# digests against device-sources.sha256, and verifies bundled payload.sha256.

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
SYS_ROOT="${KSU_SYSTEM_ROOT:-}"

ui_print "************************************************"
ui_print " Noto Sans + Noto Sans CJK + Apple Emoji (v1.0.3)"
ui_print " Target: OnePlus 13 / Android 16 / OxygenOS 16"
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
if [ "$sdk" -ne 36 ]; then
  abort "! Unsupported Android SDK $sdk (requires Android 16 / API 36)"
fi

modpath_real="$(CDPATH='' cd -P -- "$MODPATH" 2>/dev/null && pwd || printf '%s' "$MODPATH")"
active_mod_dir="$ADB_ROOT/modules/$MODID"
if [ -e "$active_mod_dir" ] || [ -L "$active_mod_dir" ]; then
  active_real="$(CDPATH='' cd -P -- "$active_mod_dir" 2>/dev/null && pwd || printf '%s' "$active_mod_dir")"
  if [ "$active_real" != "$modpath_real" ]; then
    abort "! Existing module found at $active_mod_dir; uninstall previous version and reboot before installing v1.0.3"
  fi
fi

file_sha256() {
  sha256sum "$1" 2>/dev/null | awk '{print tolower($1)}'
}

DEV_MANIFEST="$MODPATH/device-sources.sha256"
if [ ! -f "$DEV_MANIFEST" ]; then
  abort "! Missing $DEV_MANIFEST in module package"
fi

ui_print "- Verifying current system XML hashes against device-sources.sha256..."
verified_sources=0
while read -r exp_hash rel_path || [ -n "${exp_hash:-}" ]; do
  case "${exp_hash:-}" in
    ''|\#*) continue ;;
  esac
  if [ -z "${rel_path:-}" ]; then
    abort "! Malformed line in device-sources.sha256"
  fi
  target_path="$SYS_ROOT/$rel_path"
  if [ ! -f "$target_path" ] && [ "$rel_path" = "system/system_ext/etc/fonts_base.xml" ]; then
    if [ -f "$SYS_ROOT/system_ext/etc/fonts_base.xml" ]; then
      target_path="$SYS_ROOT/system_ext/etc/fonts_base.xml"
    fi
  fi
  if [ ! -f "$target_path" ]; then
    abort "! Missing required device XML: /$rel_path"
  fi
  act_hash="$(file_sha256 "$target_path")"
  exp_lower="$(printf '%s' "$exp_hash" | tr '[:upper:]' '[:lower:]')"
  if [ -z "$act_hash" ] || [ "$act_hash" != "$exp_lower" ]; then
    abort "! Device XML hash mismatch for /$rel_path (uninstall old font modules & reboot, or unsupported ROM build)"
  fi
  verified_sources=$((verified_sources + 1))
done < "$DEV_MANIFEST"

if [ "$verified_sources" -ne 3 ]; then
  abort "! Expected 3 device XML entries in device-sources.sha256, found $verified_sources"
fi

PAYLOAD_MANIFEST="$MODPATH/payload.sha256"
if [ ! -f "$PAYLOAD_MANIFEST" ]; then
  abort "! Missing $PAYLOAD_MANIFEST in module package"
fi

ui_print "- Verifying packaged payload.sha256..."
verified_payload=0
while read -r exp_hash rel_path || [ -n "${exp_hash:-}" ]; do
  case "${exp_hash:-}" in
    ''|\#*) continue ;;
  esac
  if [ -z "${rel_path:-}" ]; then
    abort "! Malformed line in payload.sha256"
  fi
  case "$rel_path" in
    /*|*..*|*\\*)
      abort "! Unsafe path in payload.sha256: $rel_path"
      ;;
  esac
  target_file="$MODPATH/$rel_path"
  if [ ! -f "$target_file" ] || [ -L "$target_file" ]; then
    abort "! Missing packaged file: $rel_path"
  fi
  act_hash="$(file_sha256 "$target_file")"
  exp_lower="$(printf '%s' "$exp_hash" | tr '[:upper:]' '[:lower:]')"
  if [ -z "$act_hash" ] || [ "$act_hash" != "$exp_lower" ]; then
    abort "! Packaged file hash mismatch: $rel_path"
  fi
  verified_payload=$((verified_payload + 1))
done < "$PAYLOAD_MANIFEST"

if [ "$verified_payload" -lt 11 ]; then
  abort "! Incomplete payload.sha256 ($verified_payload entries)"
fi

set_perm_recursive "$MODPATH" 0 0 0755 0644
set_perm "$MODPATH/customize.sh" 0 0 0755

ui_print "- Verified 3 device XML hashes and $verified_payload packaged payload files."
ui_print "- Installation complete. Please reboot device to activate fonts."
