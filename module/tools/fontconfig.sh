#!/system/bin/sh
# Install-time OxygenOS 16 / Android 16 font configuration generator.
# Reads the device's actual /system/etc/font_fallback.xml, /system/etc/fonts.xml, and
# (when present) /system_ext/etc/fonts_base.xml (including its /system/system_ext/etc/fonts_base.xml
# SAR alias), validates KernelSU environment, static metamodule entrypoint presence (metamount.sh),
# absence of unsupported partition overrides or conflicting font modules, stages adapted
# configs, validates output structure via fontxml.awk -v validate_only=1, and commits to
# $MODDIR/system/etc/ and $MODDIR/system/system_ext/etc/. Never writes to real system
# partitions and never mounts filesystems.
# Note: Static verification of metamount.sh at install time does not guarantee runtime
# mounting succeeded after reboot.

set -u

SCRIPT_DIR=${0%/*}
MODDIR=$(CDPATH='' cd -- "$SCRIPT_DIR/.." 2>/dev/null && pwd)
AWK_SCRIPT="$SCRIPT_DIR/fontxml.awk"
SYSTEM_ROOT=${FONT_CONFIG_ROOT:-}
ADB_ROOT=${FONT_ADB_ROOT:-/data/adb}
MODID="ksu_noto_fonts_apple_emoji"

STAGING_DIR="$MODDIR/.staging"
ORIGINAL_DIR="$MODDIR/config/original"
DATA_DIR="$MODDIR/data"
HAS_BASE_XML=0
BASE_XML_SRC=""

cleanup_staging() {
  if [ -n "${STAGING_DIR:-}" ] && [ -d "$STAGING_DIR" ]; then
    rm -rf "$STAGING_DIR"
  fi
}

fail() {
  cleanup_staging
  printf 'error=%s\n' "$1"
  exit 1
}

trap 'fail "interrupted"' INT TERM HUP

# 1. Verify required module fonts exist in $MODDIR/system/fonts
check_bundled_fonts() {
  for f in \
    KSU-NotoSans-Regular-VF.ttf \
    KSU-NotoSans-Italic-VF.ttf \
    KSU-NotoSansCJKsc-VF.ttf \
    KSU-NotoSansCJKtc-VF.ttf \
    KSU-NotoSansCJKjp-VF.ttf \
    KSU-NotoSansCJKkr-VF.ttf \
    KSU-AppleColorEmoji.ttf
  do
    if [ ! -s "$MODDIR/system/fonts/$f" ]; then
      fail "missing_bundled_font:$f"
    fi
  done
}

read_prop_val() {
  prop_file="$1"
  prop_key="$2"
  [ -f "$prop_file" ] && [ ! -L "$prop_file" ] || return 1
  sed -n "s/^[[:space:]]*${prop_key}[[:space:]]*=[[:space:]]*//p" "$prop_file" 2>/dev/null | head -n 1 | sed 's/[[:space:]]*$//'
}

has_metamodule_flag() {
  prop_file="$1"
  [ -f "$prop_file" ] && [ ! -L "$prop_file" ] || return 1
  grep -Eq '^[[:space:]]*metamodule[[:space:]]*=[[:space:]]*(1|true)[[:space:]]*$' "$prop_file" 2>/dev/null
}

has_valid_metamount_entry() {
  cand_dir="$1"
  [ -f "$cand_dir/metamount.sh" ] && [ ! -L "$cand_dir/metamount.sh" ] && [ -s "$cand_dir/metamount.sh" ]
}

is_valid_complete_metamodule_dir() {
  cand_dir="$1"
  expected_id="${2:-}"
  [ -d "$cand_dir" ] || return 1
  [ ! -e "$cand_dir/disable" ] && [ ! -e "$cand_dir/remove" ] || return 1
  has_metamodule_flag "$cand_dir/module.prop" || return 1
  cand_id=$(read_prop_val "$cand_dir/module.prop" "id" || :)
  [ -n "$cand_id" ] || return 1
  if [ -n "$expected_id" ] && [ "$cand_id" != "$expected_id" ]; then
    return 1
  fi
  has_valid_metamount_entry "$cand_dir"
}

is_valid_staged_metamodule() {
  staged_id="$1"
  [ -n "$staged_id" ] || return 1
  active_stub="$ADB_ROOT/modules/$staged_id"
  staged_dir="$ADB_ROOT/modules_update/$staged_id"
  [ -d "$active_stub" ] && [ -d "$staged_dir" ] || return 1
  if [ -e "$active_stub/disable" ] || [ -e "$active_stub/remove" ] || \
     [ -e "$staged_dir/disable" ] || [ -e "$staged_dir/remove" ]; then
    return 2
  fi
  [ -f "$active_stub/update" ] && [ ! -L "$active_stub/update" ] || return 1
  has_metamodule_flag "$active_stub/module.prop" || return 1
  stub_id=$(read_prop_val "$active_stub/module.prop" "id" || :)
  [ "$stub_id" = "$staged_id" ] || return 1
  is_valid_complete_metamodule_dir "$staged_dir" "$staged_id" || return 1
  return 0
}

validate_metamodule_candidate_dir() {
  cand_dir="$1"
  [ -d "$cand_dir" ] || return 1
  if [ -e "$cand_dir/disable" ] || [ -e "$cand_dir/remove" ]; then
    return 2
  fi
  has_metamodule_flag "$cand_dir/module.prop" || return 1
  cand_id=$(read_prop_val "$cand_dir/module.prop" "id" || :)
  [ -n "$cand_id" ] || return 1

  if [ -d "$ADB_ROOT/modules_update/$cand_id" ] || [ -e "$cand_dir/update" ]; then
    is_valid_staged_metamodule "$cand_id"
    return $?
  fi

  is_valid_complete_metamodule_dir "$cand_dir" "$cand_id" || return 1
  return 0
}

# 2. Check KernelSU environment and static metamodule entrypoint (metamount.sh)
check_ksu_mount_provider() {
  if [ "${KSU:-}" != "true" ] && [ "${KSU_VER_CODE:-}" = "" ]; then
    fail "not_running_in_kernelsu"
  fi

  # Reject any metamodule in modules_update that does not satisfy KernelSU's official staging contract
  if [ -d "$ADB_ROOT/modules_update" ]; then
    for u in "$ADB_ROOT/modules_update"/*; do
      [ -d "$u" ] || continue
      u_name=${u##*/}
      if has_metamodule_flag "$u/module.prop" || [ -e "$u/metamount.sh" ]; then
        is_valid_staged_metamodule "$u_name"
        st_rc=$?
        if [ "$st_rc" -eq 2 ]; then
          fail "metamodule_disabled_or_pending_removal"
        elif [ "$st_rc" -ne 0 ]; then
          fail "invalid_or_uncontracted_modules_update_metamodule:$u_name"
        fi
      fi
    done
  fi

  # Scan $ADB_ROOT/modules/* for metamodule candidates
  valid_scan_count=0
  valid_scan_id=""
  valid_scan_dir=""
  valid_staged_dir=""
  saw_disabled_meta=0
  if [ -d "$ADB_ROOT/modules" ]; then
    for m in "$ADB_ROOT/modules"/*; do
      [ -d "$m" ] || continue
      m_name=${m##*/}
      if has_metamodule_flag "$m/module.prop" || [ -e "$m/metamount.sh" ]; then
        if [ -e "$m/disable" ] || [ -e "$m/remove" ]; then
          saw_disabled_meta=1
          continue
        fi
        validate_metamodule_candidate_dir "$m"
        cand_rc=$?
        if [ "$cand_rc" -eq 2 ]; then
          fail "metamodule_disabled_or_pending_removal"
        elif [ "$cand_rc" -ne 0 ]; then
          fail "metamodule_incomplete_or_missing_metamount:$m_name"
        fi
        valid_scan_count=$((valid_scan_count + 1))
        valid_scan_id=$(read_prop_val "$m/module.prop" "id" || :)
        valid_scan_dir=$(CDPATH='' cd -P -- "$m" 2>/dev/null && pwd) || valid_scan_dir=""
        if [ -d "$ADB_ROOT/modules_update/$valid_scan_id" ]; then
          valid_staged_dir=$(CDPATH='' cd -P -- "$ADB_ROOT/modules_update/$valid_scan_id" 2>/dev/null && pwd) || valid_staged_dir=""
        fi
      fi
    done
  fi

  if [ "$valid_scan_count" -gt 1 ]; then
    fail "multiple_metamodules_detected"
  fi

  meta_dir="$ADB_ROOT/metamodule"
  if [ -e "$meta_dir" ] && [ ! -L "$meta_dir" ]; then
    fail "metamodule_not_a_symlink"
  fi
  if [ -L "$meta_dir" ]; then
    if [ ! -d "$meta_dir" ]; then
      fail "metamodule_broken_symlink"
    fi
    resolved_meta=$(CDPATH='' cd -P -- "$meta_dir" 2>/dev/null && pwd) || fail "metamodule_resolve_failed"
    if [ -e "$meta_dir/disable" ] || [ -e "$meta_dir/remove" ] || \
       [ -e "$resolved_meta/disable" ] || [ -e "$resolved_meta/remove" ]; then
      fail "metamodule_disabled_or_pending_removal"
    fi
    validate_metamodule_candidate_dir "$resolved_meta"
    meta_rc=$?
    if [ "$meta_rc" -eq 2 ]; then
      fail "metamodule_disabled_or_pending_removal"
    elif [ "$meta_rc" -ne 0 ]; then
      fail "metamodule_incomplete_or_missing_metamount"
    fi
    link_id=$(read_prop_val "$resolved_meta/module.prop" "id" || :)
    if [ "$valid_scan_count" -ne 1 ]; then
      fail "metamodule_symlink_target_not_in_modules"
    fi
    if [ "$valid_scan_id" != "$link_id" ]; then
      fail "multiple_metamodules_detected"
    fi
    if [ "$resolved_meta" != "$valid_scan_dir" ] && [ "$resolved_meta" != "$valid_staged_dir" ]; then
      fail "multiple_metamodules_detected"
    fi
    return 0
  fi

  if [ "$valid_scan_count" -eq 1 ]; then
    return 0
  fi
  if [ "$saw_disabled_meta" -eq 1 ]; then
    fail "metamodule_disabled_or_pending_removal"
  fi

  fail "ksu_mount_provider_missing_install_metamodule"
}

# 3. Check for conflicting active font modules in $ADB_ROOT/modules and $ADB_ROOT/modules_update
check_conflicting_modules() {
  for base in "$ADB_ROOT/modules" "$ADB_ROOT/modules_update"; do
    [ -d "$base" ] || continue
    for m in "$base"/*; do
      [ -d "$m" ] || continue
      m_name=${m##*/}
      [ "$m_name" = "$MODID" ] && continue
      [ -e "$m/disable" ] && continue
      [ -e "$m/remove" ] && continue

      if [ -d "$m/system/fonts" ] || \
         [ -f "$m/system/etc/fonts.xml" ] || \
         [ -f "$m/system/etc/font_fallback.xml" ] || \
         [ -f "$m/system/system_ext/etc/fonts.xml" ] || \
         [ -f "$m/system/system_ext/etc/font_fallback.xml" ] || \
         [ -f "$m/system/system_ext/etc/fonts_base.xml" ] || \
         [ -f "$m/system/product/etc/fonts.xml" ] || \
         [ -f "$m/system/product/etc/font_fallback.xml" ] || \
         [ -f "$m/system/product/etc/fonts_customization.xml" ]; then
        fail "conflicting_font_module:$m_name"
      fi
    done
  done
}

# 4. Check partition overrides and resolve supported /system_ext/etc/fonts_base.xml
resolve_system_ext_fonts_base() {
  HAS_BASE_XML=0
  BASE_XML_SRC=""
  p1="$SYSTEM_ROOT/system_ext/etc/fonts_base.xml"
  p2="$SYSTEM_ROOT/system/system_ext/etc/fonts_base.xml"

  if [ ! -e "$p1" ] && [ ! -L "$p1" ] && [ ! -e "$p2" ] && [ ! -L "$p2" ]; then
    return 0
  fi

  if [ -n "$SYSTEM_ROOT" ]; then
    sys_root_real=$(readlink -f "$SYSTEM_ROOT" 2>/dev/null || :)
    if [ -z "$sys_root_real" ]; then
      fail "unsupported_partition_font_override:/system_ext/etc/fonts_base.xml"
    fi
  else
    sys_root_real=""
  fi

  allow1="$sys_root_real/system_ext/etc/fonts_base.xml"
  allow2="$sys_root_real/system/system_ext/etc/fonts_base.xml"

  has_p1=0
  real_p1=""
  if [ -e "$p1" ] || [ -L "$p1" ]; then
    if [ ! -f "$p1" ]; then
      fail "unsupported_partition_font_override:/system_ext/etc/fonts_base.xml"
    fi
    real_p1=$(readlink -f "$p1" 2>/dev/null || :)
    if [ -z "$real_p1" ] || { [ "$real_p1" != "$allow1" ] && [ "$real_p1" != "$allow2" ]; }; then
      fail "unsupported_partition_font_override:/system_ext/etc/fonts_base.xml"
    fi
    has_p1=1
  fi

  has_p2=0
  real_p2=""
  if [ -e "$p2" ] || [ -L "$p2" ]; then
    if [ ! -f "$p2" ]; then
      fail "unsupported_partition_font_override:/system/system_ext/etc/fonts_base.xml"
    fi
    real_p2=$(readlink -f "$p2" 2>/dev/null || :)
    if [ -z "$real_p2" ] || { [ "$real_p2" != "$allow1" ] && [ "$real_p2" != "$allow2" ]; }; then
      fail "unsupported_partition_font_override:/system/system_ext/etc/fonts_base.xml"
    fi
    has_p2=1
  fi

  if [ "$has_p1" -eq 1 ] && [ "$has_p2" -eq 1 ]; then
    if [ "$real_p1" != "$real_p2" ]; then
      fail "unsupported_partition_font_override:/system_ext/etc/fonts_base.xml"
    fi
    HAS_BASE_XML=1
    BASE_XML_SRC="$real_p1"
    return 0
  fi

  if [ "$has_p1" -eq 1 ]; then
    # /system_ext/etc/fonts_base.xml exists without /system/system_ext/etc/fonts_base.xml mapping to it
    fail "unsupported_partition_font_override:/system_ext/etc/fonts_base.xml"
  fi

  # Only /system/system_ext/etc/fonts_base.xml exists: reject if /system_ext exists as a separate unaliased path
  if [ -e "$SYSTEM_ROOT/system_ext" ] || [ -L "$SYSTEM_ROOT/system_ext" ]; then
    fail "unsupported_partition_font_override:/system/system_ext/etc/fonts_base.xml"
  fi

  HAS_BASE_XML=1
  BASE_XML_SRC="$real_p2"
}

check_unsupported_partition_overrides() {
  for extra_cfg in \
    /system_ext/etc/fonts.xml \
    /system_ext/etc/font_fallback.xml \
    /system/system_ext/etc/fonts.xml \
    /system/system_ext/etc/font_fallback.xml \
    /product/etc/fonts.xml \
    /product/etc/font_fallback.xml \
    /system/product/etc/fonts.xml \
    /system/product/etc/font_fallback.xml \
    /vendor/etc/fonts.xml \
    /vendor/etc/font_fallback.xml \
    /system/vendor/etc/fonts.xml \
    /system/vendor/etc/font_fallback.xml \
    /my_product/etc/fonts.xml \
    /my_product/etc/font_fallback.xml \
    /my_bigball/etc/fonts.xml \
    /my_bigball/etc/font_fallback.xml \
    /odm/etc/fonts.xml \
    /odm/etc/font_fallback.xml
  do
    if [ -f "$SYSTEM_ROOT$extra_cfg" ] || [ -L "$SYSTEM_ROOT$extra_cfg" ]; then
      fail "unsupported_partition_font_override:$extra_cfg"
    fi
  done

  resolve_system_ext_fonts_base
}

# 5. Stage original system font configs (reusing clean backup on module upgrade)
stage_originals() {
  src_fallback="$SYSTEM_ROOT/system/etc/font_fallback.xml"
  src_legacy="$SYSTEM_ROOT/system/etc/fonts.xml"
  old_orig="$ADB_ROOT/modules/$MODID/config/original"

  staged_orig_fb="$STAGING_DIR/orig/etc/font_fallback.xml"
  staged_orig_leg="$STAGING_DIR/orig/etc/fonts.xml"

  if [ -s "$ORIGINAL_DIR/etc/font_fallback.xml" ] && [ -s "$ORIGINAL_DIR/etc/fonts.xml" ]; then
    if grep -q "KSU-NotoSans-" "$ORIGINAL_DIR/etc/font_fallback.xml" 2>/dev/null || \
       grep -q "KSU-NotoSans-" "$ORIGINAL_DIR/etc/fonts.xml" 2>/dev/null; then
      fail "live_system_config_already_modified_without_backup"
    fi
    cp -pf "$ORIGINAL_DIR/etc/font_fallback.xml" "$staged_orig_fb" || fail "backup_copy_failed"
    cp -pf "$ORIGINAL_DIR/etc/fonts.xml" "$staged_orig_leg" || fail "backup_copy_failed"
  elif [ -s "$old_orig/etc/font_fallback.xml" ] && [ -s "$old_orig/etc/fonts.xml" ]; then
    if grep -q "KSU-NotoSans-" "$old_orig/etc/font_fallback.xml" 2>/dev/null || \
       grep -q "KSU-NotoSans-" "$old_orig/etc/fonts.xml" 2>/dev/null; then
      fail "live_system_config_already_modified_without_backup"
    fi
    cp -pf "$old_orig/etc/font_fallback.xml" "$staged_orig_fb" || fail "backup_copy_failed"
    cp -pf "$old_orig/etc/fonts.xml" "$staged_orig_leg" || fail "backup_copy_failed"
  else
    if [ ! -f "$src_fallback" ]; then
      fail "missing_system_font_fallback_xml"
    fi
    if [ ! -f "$src_legacy" ]; then
      fail "missing_system_fonts_xml"
    fi
    # Refuse if live /system/etc/fonts.xml already contains KSU-NotoSans markers (polluted live overlay without backup)
    if grep -q "KSU-NotoSans-" "$src_fallback" 2>/dev/null || grep -q "KSU-NotoSans-" "$src_legacy" 2>/dev/null; then
      fail "live_system_config_already_modified_without_backup"
    fi
    cp -pf "$src_fallback" "$staged_orig_fb" || fail "backup_copy_failed"
    cp -pf "$src_legacy" "$staged_orig_leg" || fail "backup_copy_failed"
  fi

  if [ "$HAS_BASE_XML" -eq 1 ]; then
    staged_orig_base="$STAGING_DIR/orig/system_ext/etc/fonts_base.xml"
    mkdir -p "$STAGING_DIR/orig/system_ext/etc" "$STAGING_DIR/system_ext/etc" || fail "backup_mkdir_failed"

    if [ -s "$ORIGINAL_DIR/system_ext/etc/fonts_base.xml" ]; then
      if grep -q "KSU-NotoSans-" "$ORIGINAL_DIR/system_ext/etc/fonts_base.xml" 2>/dev/null; then
        fail "live_system_config_already_modified_without_backup"
      fi
      cp -pf "$ORIGINAL_DIR/system_ext/etc/fonts_base.xml" "$staged_orig_base" || fail "backup_copy_failed"
    elif [ -s "$old_orig/system_ext/etc/fonts_base.xml" ]; then
      if grep -q "KSU-NotoSans-" "$old_orig/system_ext/etc/fonts_base.xml" 2>/dev/null; then
        fail "live_system_config_already_modified_without_backup"
      fi
      cp -pf "$old_orig/system_ext/etc/fonts_base.xml" "$staged_orig_base" || fail "backup_copy_failed"
    else
      if [ ! -f "$BASE_XML_SRC" ]; then
        fail "missing_system_ext_fonts_base_xml"
      fi
      if grep -q "KSU-NotoSans-" "$BASE_XML_SRC" 2>/dev/null; then
        fail "live_system_config_already_modified_without_backup"
      fi
      cp -pf "$BASE_XML_SRC" "$staged_orig_base" || fail "backup_copy_failed"
    fi
  fi
}

# 6. Validate generated XML invariants before committing using fontxml.awk validate_only mode
verify_generated_xml() {
  out_file="$1"
  mode="$2"
  stats_file="$3"

  [ -s "$out_file" ] || fail "empty_generated_xml:$mode"
  [ -s "$stats_file" ] || fail "missing_stats_file:$mode"

  stats_line=$(cat "$stats_file" 2>/dev/null)
  case "$stats_line" in
    OK\ *) ;;
    *) fail "awk_validation_failed:$mode:$stats_line" ;;
  esac

  for req_font in \
    KSU-NotoSans-Regular-VF.ttf \
    KSU-NotoSans-Italic-VF.ttf \
    KSU-NotoSansCJKsc-VF.ttf \
    KSU-NotoSansCJKtc-VF.ttf \
    KSU-NotoSansCJKjp-VF.ttf \
    KSU-NotoSansCJKkr-VF.ttf \
    KSU-AppleColorEmoji.ttf
  do
    grep -q "$req_font" "$out_file" || fail "missing_font_ref_in_${mode}:$req_font"
  done

  awk -v mode="$mode" -v validate_only=1 -f "$AWK_SCRIPT" "$out_file" >/dev/null || \
    fail "post_check_xml_structure_failed:$mode"
}

run_prepare() {
  [ -f "$AWK_SCRIPT" ] || fail "missing_awk_script"
  check_bundled_fonts
  check_ksu_mount_provider
  check_conflicting_modules
  check_unsupported_partition_overrides

  cleanup_staging
  mkdir -p "$STAGING_DIR/etc" "$STAGING_DIR/orig/etc" || fail "staging_mkdir_failed"
  stage_originals

  awk -v mode="fallback" -v stats="$STAGING_DIR/fallback.stats" \
    -f "$AWK_SCRIPT" "$STAGING_DIR/orig/etc/font_fallback.xml" \
    > "$STAGING_DIR/etc/font_fallback.xml" || fail "fallback_xml_transform_failed:$(cat "$STAGING_DIR/fallback.stats" 2>/dev/null)"

  verify_generated_xml "$STAGING_DIR/etc/font_fallback.xml" "fallback" "$STAGING_DIR/fallback.stats"

  awk -v mode="legacy" -v stats="$STAGING_DIR/legacy.stats" \
    -f "$AWK_SCRIPT" "$STAGING_DIR/orig/etc/fonts.xml" \
    > "$STAGING_DIR/etc/fonts.xml" || fail "legacy_xml_transform_failed:$(cat "$STAGING_DIR/legacy.stats" 2>/dev/null)"

  verify_generated_xml "$STAGING_DIR/etc/fonts.xml" "legacy" "$STAGING_DIR/legacy.stats"

  if [ "$HAS_BASE_XML" -eq 1 ]; then
    awk -v mode="base" -v stats="$STAGING_DIR/base.stats" \
      -f "$AWK_SCRIPT" "$STAGING_DIR/orig/system_ext/etc/fonts_base.xml" \
      > "$STAGING_DIR/system_ext/etc/fonts_base.xml" || fail "base_xml_transform_failed:$(cat "$STAGING_DIR/base.stats" 2>/dev/null)"

    verify_generated_xml "$STAGING_DIR/system_ext/etc/fonts_base.xml" "base" "$STAGING_DIR/base.stats"
  fi

  mkdir -p "$ORIGINAL_DIR/etc" "$MODDIR/system/etc" "$DATA_DIR" || fail "system_etc_mkdir_failed"
  cp -pf "$STAGING_DIR/orig/etc/font_fallback.xml" "$ORIGINAL_DIR/etc/font_fallback.xml" || fail "backup_copy_failed"
  cp -pf "$STAGING_DIR/orig/etc/fonts.xml" "$ORIGINAL_DIR/etc/fonts.xml" || fail "backup_copy_failed"
  chmod 0644 "$STAGING_DIR/etc/font_fallback.xml" "$STAGING_DIR/etc/fonts.xml" || fail "chmod_failed"
  mv -f "$STAGING_DIR/etc/font_fallback.xml" "$MODDIR/system/etc/font_fallback.xml" || fail "commit_fallback_failed"
  mv -f "$STAGING_DIR/etc/fonts.xml" "$MODDIR/system/etc/fonts.xml" || fail "commit_legacy_failed"
  cp -pf "$STAGING_DIR/fallback.stats" "$DATA_DIR/fallback.stats" 2>/dev/null || :
  cp -pf "$STAGING_DIR/legacy.stats" "$DATA_DIR/legacy.stats" 2>/dev/null || :

  if [ "$HAS_BASE_XML" -eq 1 ]; then
    mkdir -p "$ORIGINAL_DIR/system_ext/etc" "$MODDIR/system/system_ext/etc" || fail "system_ext_etc_mkdir_failed"
    cp -pf "$STAGING_DIR/orig/system_ext/etc/fonts_base.xml" "$ORIGINAL_DIR/system_ext/etc/fonts_base.xml" || fail "backup_copy_failed"
    chmod 0644 "$STAGING_DIR/system_ext/etc/fonts_base.xml" || fail "chmod_failed"
    mv -f "$STAGING_DIR/system_ext/etc/fonts_base.xml" "$MODDIR/system/system_ext/etc/fonts_base.xml" || fail "commit_base_failed"
    cp -pf "$STAGING_DIR/base.stats" "$DATA_DIR/base.stats" 2>/dev/null || :
  else
    rm -rf "$MODDIR/system/system_ext" "$ORIGINAL_DIR/system_ext" "$DATA_DIR/base.stats" 2>/dev/null || :
  fi

  cleanup_staging
  printf 'ok=prepared\n'
}

case "${1:-prepare}" in
  prepare) run_prepare ;;
  *) fail "invalid_command:${1:-}" ;;
esac
