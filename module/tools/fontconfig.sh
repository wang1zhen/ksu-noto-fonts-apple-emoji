#!/system/bin/sh
# Install-time Android font configuration capture & generation script (v2.0.0)
# Adapted from font-settings/tools/fontconfig.sh (MIT License, Copyright (c) 2026 yuzlyn)

SCRIPT_DIR=${0%/*}
MODDIR=$(CDPATH='' cd -- "$SCRIPT_DIR/.." 2>/dev/null && pwd)
AWK_SCRIPT="$SCRIPT_DIR/fontxml.awk"
SYSTEM_ROOT=${FONT_CONFIG_ROOT:-}
WORK_DIR="$MODDIR/.fontconfig.work.$$"
CAPTURE_DIR="$WORK_DIR/original"
STAGE_DIR="$WORK_DIR/system"
MANIFEST="$WORK_DIR/font-configs.list"
STATS_FILE="$WORK_DIR/fontxml.stats"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() {
  echo "error=$1"
  exit 1
}

valid_relative_path() {
  case "$1" in
    etc/fonts.xml|etc/font_fallback.xml|system_ext/etc/fonts.xml|system_ext/etc/fonts_base.xml|product/etc/fonts.xml|product/etc/fonts_customization.xml|vendor/etc/fonts.xml) return 0 ;;
    *) return 1 ;;
  esac
}

capture_one() {
  source="$SYSTEM_ROOT$1"
  relative="$2"
  [ -f "$source" ] || return 0
  [ -f "$CAPTURE_DIR/$relative" ] && return 0
  if grep -qE 'KSU-NotoSans|KSU-AppleColorEmoji|KsuReserved-|KsuAppleColorEmoji|(^|[^A-Za-z0-9._-])NotoSans-Italic\.ttf([^A-Za-z0-9._-]|$)' "$source" 2>/dev/null; then
    fail "self_overlay_detected"
  fi
  mkdir -p "$CAPTURE_DIR/${relative%/*}" || fail "config_capture_failed"
  cp -pf "$source" "$CAPTURE_DIR/$relative" || fail "config_capture_failed"
  printf '%s\n' "$relative" >> "$MANIFEST" || fail "config_manifest_failed"
}

capture_configs() {
  rm -rf "$WORK_DIR"
  mkdir -p "$CAPTURE_DIR" "$STAGE_DIR" || fail "config_capture_failed"
  : > "$MANIFEST" || fail "config_manifest_failed"

  capture_one /system/etc/fonts.xml etc/fonts.xml
  capture_one /system/etc/font_fallback.xml etc/font_fallback.xml
  capture_one /system_ext/etc/fonts.xml system_ext/etc/fonts.xml
  if [ ! -f "$CAPTURE_DIR/system_ext/etc/fonts.xml" ]; then
    capture_one /system/system_ext/etc/fonts.xml system_ext/etc/fonts.xml
  fi
  capture_one /system_ext/etc/fonts_base.xml system_ext/etc/fonts_base.xml
  if [ ! -f "$CAPTURE_DIR/system_ext/etc/fonts_base.xml" ]; then
    capture_one /system/system_ext/etc/fonts_base.xml system_ext/etc/fonts_base.xml
  fi
  capture_one /product/etc/fonts.xml product/etc/fonts.xml
  if [ ! -f "$CAPTURE_DIR/product/etc/fonts.xml" ]; then
    capture_one /system/product/etc/fonts.xml product/etc/fonts.xml
  fi
  capture_one /product/etc/fonts_customization.xml product/etc/fonts_customization.xml
  if [ ! -f "$CAPTURE_DIR/product/etc/fonts_customization.xml" ]; then
    capture_one /system/product/etc/fonts_customization.xml product/etc/fonts_customization.xml
  fi
  capture_one /vendor/etc/fonts.xml vendor/etc/fonts.xml
  if [ ! -f "$CAPTURE_DIR/vendor/etc/fonts.xml" ]; then
    capture_one /system/vendor/etc/fonts.xml vendor/etc/fonts.xml
  fi

  [ -f "$CAPTURE_DIR/etc/fonts.xml" ] || fail "system_fonts_config_missing"
}

generate_configs() {
  [ -f "$AWK_SCRIPT" ] || fail "font_config_generator_missing"

  for f in \
    KSU-NotoSans-Regular-VF.ttf \
    KSU-NotoSans-Italic-VF.ttf \
    KSU-NotoSansCJKsc-VF.ttf \
    KSU-NotoSansCJKtc-VF.ttf \
    KSU-NotoSansCJKjp-VF.ttf \
    KSU-NotoSansCJKkr-VF.ttf \
    KSU-AppleColorEmoji.ttf; do
    [ -f "$MODDIR/system/fonts/$f" ] || fail "packaged_font_missing"
  done

  total_western=0
  total_sc=0
  total_tc=0
  total_jp=0
  total_kr=0
  total_emoji=0
  total_files=0

  while IFS= read -r relative; do
    valid_relative_path "$relative" || fail "font_config_path_invalid"
    source="$CAPTURE_DIR/$relative"
    output="$STAGE_DIR/$relative"
    allow_unnamed=0
    [ "$relative" = "etc/fonts.xml" ] && allow_unnamed=1
    mkdir -p "${output%/*}" || fail "font_config_write_failed"
    rm -f "$STATS_FILE"

    awk \
      -v allow_unnamed="$allow_unnamed" \
      -v stats="$STATS_FILE" \
      -f "$AWK_SCRIPT" "$source" > "$output" || fail "font_config_generate_failed"

    [ -s "$STATS_FILE" ] || fail "font_config_generate_failed"
    # shellcheck disable=SC2046
    set -- $(cat "$STATS_FILE" 2>/dev/null)
    w_cnt=${1:-0}
    sc_cnt=${2:-0}
    tc_cnt=${3:-0}
    jp_cnt=${4:-0}
    kr_cnt=${5:-0}
    em_cnt=${6:-0}

    if [ "$relative" = "etc/fonts.xml" ] && [ "$w_cnt" -eq 0 ]; then
      fail "western_family_not_found"
    fi

    total_western=$((total_western + w_cnt))
    total_sc=$((total_sc + sc_cnt))
    total_tc=$((total_tc + tc_cnt))
    total_jp=$((total_jp + jp_cnt))
    total_kr=$((total_kr + kr_cnt))
    total_emoji=$((total_emoji + em_cnt))
    total_files=$((total_files + 1))
  done < "$MANIFEST"

  [ "$total_western" -gt 0 ] || fail "western_family_not_found"
  [ "$total_sc" -gt 0 ] || fail "cjk_sc_family_not_found"
  [ "$total_tc" -gt 0 ] || fail "cjk_tc_family_not_found"
  [ "$total_jp" -gt 0 ] || fail "cjk_jp_family_not_found"
  [ "$total_kr" -gt 0 ] || fail "cjk_kr_family_not_found"
  [ "$total_emoji" -gt 0 ] || fail "emoji_family_not_found"

  mkdir -p "$MODDIR/system" || fail "font_config_write_failed"
  chmod 0755 "$MODDIR/system" || fail "font_config_perm_failed"
  if [ -d "$MODDIR/system/fonts" ]; then
    chmod 0755 "$MODDIR/system/fonts" || fail "font_config_perm_failed"
    for f in "$MODDIR/system/fonts"/*; do
      [ -f "$f" ] || continue
      chmod 0644 "$f" || fail "font_config_perm_failed"
    done
  fi

  while IFS= read -r relative; do
    dest="$MODDIR/system/$relative"
    dest_dir="${dest%/*}"
    top_sub="${relative%%/*}"
    mkdir -p "$dest_dir" || fail "font_config_write_failed"
    chmod 0755 "$MODDIR/system/$top_sub" "$dest_dir" || fail "font_config_perm_failed"
    cp -pf "$STAGE_DIR/$relative" "$dest.new" || fail "font_config_write_failed"
    chmod 0644 "$dest.new" || fail "font_config_perm_failed"
    mv -f "$dest.new" "$dest" || fail "font_config_write_failed"
  done < "$MANIFEST"

  total_cjk=$((total_sc + total_tc + total_jp + total_kr))
  echo "ok=config files=$total_files western=$total_western cjk=$total_cjk sc=$total_sc tc=$total_tc jp=$total_jp kr=$total_kr emoji=$total_emoji"
}

case "${1:-prepare}" in
  prepare)
    capture_configs
    generate_configs
    ;;
  *) fail "invalid_config_command" ;;
esac
