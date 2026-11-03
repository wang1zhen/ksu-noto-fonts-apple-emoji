#!/bin/sh
# End-to-end regression test suite for ksu-noto-fonts-apple-emoji.
# Covers:
# 1. ShellCheck static analysis (uses system shellcheck or .cache/shellcheck-*/shellcheck if present)
# 2. Excerpt fixture disclaimer verification
# 3. Direct fontxml.awk transformation, validate_only mode, & independent ElementTree verification (tests/verify_xml.py),
#    including CJK fallbackFor-with-axis preservation and per-(fallbackFor, weight, style) uniqueness
# 4. Safe rejection on malformed / unsupported XML inputs (wrong root version, missing families,
#    duplicate CJK families, unexpected extra ja family, unclosed tags/comments, same-line </family><family>,
#    unclosed <unexpected> before </familyset>, invalid nesting, unclosed <font>, content after </familyset>,
#    unsupported CJK family attributes, missing CJK fallbackFor)
# 5. Simulated full customize.sh / fontconfig.sh install & upgrade lifecycle:
#    - Success with active metamodule symlink (/data/adb/metamodule -> /data/adb/modules/meta_overlayfs + metamount.sh)
#    - Success with unique scanned metamodule when /data/adb/metamodule symlink is absent
#    - Success with official modules_update staging contract (modules/<id>/update + modules_update/<id>/metamount.sh)
#    - Upgrade idempotence (reuses original backup even when live /system/etc has module XML)
#    - Rejection when not running in KernelSU
#    - Rejection when metamodule is missing, disabled, broken symlink, empty shell (no metamount.sh / 0-byte / symlink),
#      missing metamodule=1, uncontracted modules_update orphan, multiple candidates, or legacy KSU_LEGACY_MOUNT_OK bypass
#    - Rejection when conflicting font module is enabled (and allowed when disabled/removed)
#    - Rejection when secondary partition overrides fonts.xml / font_fallback.xml
#    - Staging cleanup when first XML succeeds and second XML fails
#    - Staging cleanup on actual SIGTERM interruption during XML transformation
# 6. ZIP verifier negative tests (corrupted archive, missing required file, path traversal,
#    unexpected file, pre-baked system/etc config, font hash mismatch)

set -eu

ROOT_DIR=$(CDPATH='' cd -- "${0%/*}/.." && pwd)
TMP_BASE=$(mktemp -d "${TMPDIR:-/tmp}/ksu-fonts-test.XXXXXX")
trap 'rm -rf "$TMP_BASE"' EXIT INT TERM HUP

pass_count=0

pass() {
  pass_count=$((pass_count + 1))
  printf 'PASS [%02d]: %s\n' "$pass_count" "$1"
}

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

assert_fails() {
  desc="$1"
  expected_pattern="$2"
  shift 2
  set +e
  out=$("$@" 2>&1)
  rc=$?
  set -e
  if [ "$rc" -eq 0 ]; then
    fail "$desc: expected non-zero exit code, got 0 (output: $out)"
  fi
  if [ -n "$expected_pattern" ]; then
    printf '%s\n' "$out" | grep -Eq "$expected_pattern" || \
      fail "$desc: output did not match '$expected_pattern' (got: $out)"
  fi
  pass "$desc"
}

# 1. ShellCheck static check (if available in PATH or .cache)
SC_BIN=""
if command -v shellcheck >/dev/null 2>&1; then
  SC_BIN="shellcheck"
else
  for candidate in "$ROOT_DIR"/.cache/shellcheck-*/shellcheck; do
    if [ -x "$candidate" ]; then
      SC_BIN="$candidate"
      break
    fi
  done
fi

if [ -n "$SC_BIN" ]; then
  "$SC_BIN" -s sh \
    "$ROOT_DIR/module/customize.sh" \
    "$ROOT_DIR/module/tools/fontconfig.sh" \
    "$ROOT_DIR/scripts/build.sh" \
    "$ROOT_DIR/scripts/verify_zip.sh" \
    "$ROOT_DIR/tests/run.sh"
  pass "shellcheck passed on all shell scripts"
fi

# 2. Excerpt fixture disclaimer check
grep -q "EXCERPT FIXTURE ONLY (NOT COMPLETE DEVICE FILE)" "$ROOT_DIR/tests/fixtures/font_fallback.excerpt.xml" || \
  fail "font_fallback.excerpt.xml missing excerpt disclaimer"
grep -q "EXCERPT FIXTURE ONLY (NOT COMPLETE DEVICE FILE)" "$ROOT_DIR/tests/fixtures/fonts.excerpt.xml" || \
  fail "fonts.excerpt.xml missing excerpt disclaimer"
pass "excerpt fixtures contain explicit non-complete disclaimer"

# 3. Direct awk transformation + validate_only + independent Python ElementTree verification
mkdir -p "$TMP_BASE/xml"
awk -v mode="fallback" -v stats="$TMP_BASE/xml/fb.stats" \
  -f "$ROOT_DIR/module/tools/fontxml.awk" \
  "$ROOT_DIR/tests/fixtures/font_fallback.excerpt.xml" > "$TMP_BASE/xml/font_fallback.xml"
awk -v mode="fallback" -v validate_only=1 \
  -f "$ROOT_DIR/module/tools/fontxml.awk" \
  "$TMP_BASE/xml/font_fallback.xml"
python3 -I "$ROOT_DIR/tests/verify_xml.py" \
  "$ROOT_DIR/tests/fixtures/font_fallback.excerpt.xml" \
  "$TMP_BASE/xml/font_fallback.xml" \
  --mode fallback
pass "fallback XML transformation verified by validate_only and independent ElementTree parser"

awk -v mode="legacy" -v stats="$TMP_BASE/xml/leg.stats" \
  -f "$ROOT_DIR/module/tools/fontxml.awk" \
  "$ROOT_DIR/tests/fixtures/fonts.excerpt.xml" > "$TMP_BASE/xml/fonts.xml"
awk -v mode="legacy" -v validate_only=1 \
  -f "$ROOT_DIR/module/tools/fontxml.awk" \
  "$TMP_BASE/xml/fonts.xml"
python3 -I "$ROOT_DIR/tests/verify_xml.py" \
  "$ROOT_DIR/tests/fixtures/fonts.excerpt.xml" \
  "$TMP_BASE/xml/fonts.xml" \
  --mode legacy
pass "legacy XML transformation verified by validate_only and independent ElementTree parser"

# 3b. Verify CJK fallbackFor font with child <axis> tags is copied intact into prepended CJK family
awk '
  /<font weight="400" style="normal" index="2" fallbackFor="serif">NotoSerifCJK-Regular\.ttc<\/font>/ {
    print "        <font weight=\"400\" style=\"normal\" index=\"2\" fallbackFor=\"serif\" supportedAxes=\"wght\">NotoSerifCJK-Regular.ttc"
    print "            <axis tag=\"wght\" stylevalue=\"400\" />"
    print "        </font>"
    next
  }
  { print }
' "$ROOT_DIR/tests/fixtures/font_fallback.excerpt.xml" > "$TMP_BASE/xml/fb_cjk_axis_in.xml"
awk -v mode="fallback" -v stats="$TMP_BASE/xml/fb_cjk_axis.stats" \
  -f "$ROOT_DIR/module/tools/fontxml.awk" \
  "$TMP_BASE/xml/fb_cjk_axis_in.xml" > "$TMP_BASE/xml/fb_cjk_axis_out.xml"
awk -v mode="fallback" -v validate_only=1 \
  -f "$ROOT_DIR/module/tools/fontxml.awk" \
  "$TMP_BASE/xml/fb_cjk_axis_out.xml"
python3 -I "$ROOT_DIR/tests/verify_xml.py" \
  "$TMP_BASE/xml/fb_cjk_axis_in.xml" \
  "$TMP_BASE/xml/fb_cjk_axis_out.xml" \
  --mode fallback
pass "CJK fallbackFor font with child <axis> tags is preserved verbatim in prepended family"

# 4. Negative XML tests (safe rejection on unsupported/malformed structures)
assert_fails "reject fallback XML when run in legacy mode" "" \
  awk -v mode="legacy" -f "$ROOT_DIR/module/tools/fontxml.awk" "$ROOT_DIR/tests/fixtures/font_fallback.excerpt.xml"

assert_fails "reject legacy XML when run in fallback mode" "" \
  awk -v mode="fallback" -f "$ROOT_DIR/module/tools/fontxml.awk" "$ROOT_DIR/tests/fixtures/fonts.excerpt.xml"

# Missing ko family
sed '/lang="ko"/,/<\/family>/d' "$ROOT_DIR/tests/fixtures/font_fallback.excerpt.xml" > "$TMP_BASE/xml/no_ko.xml"
assert_fails "reject XML missing required ko family" "" \
  awk -v mode="fallback" -f "$ROOT_DIR/module/tools/fontxml.awk" "$TMP_BASE/xml/no_ko.xml"

# Missing sys-sans-en in legacy mode
sed '/name="sys-sans-en"/,/<\/family>/d' "$ROOT_DIR/tests/fixtures/fonts.excerpt.xml" > "$TMP_BASE/xml/no_sys_sans.xml"
assert_fails "reject legacy XML missing sys-sans-en" "" \
  awk -v mode="legacy" -f "$ROOT_DIR/module/tools/fontxml.awk" "$TMP_BASE/xml/no_sys_sans.xml"

# Duplicate zh-Hans family
awk '
  /<\/familyset>/ {
    print "    <family lang=\"zh-Hans\">"
    print "        <font weight=\"400\" style=\"normal\">Extra.ttf</font>"
    print "        <font weight=\"400\" style=\"normal\" fallbackFor=\"serif\">ExtraSerif.ttf</font>"
    print "    </family>"
  }
  { print }
' "$ROOT_DIR/tests/fixtures/font_fallback.excerpt.xml" > "$TMP_BASE/xml/dup_zh.xml"
assert_fails "reject XML with duplicate zh-Hans family" "" \
  awk -v mode="fallback" -f "$ROOT_DIR/module/tools/fontxml.awk" "$TMP_BASE/xml/dup_zh.xml"

# Unexpected extra ja family (non-Hentaigana)
awk '
  /<\/familyset>/ {
    print "    <family lang=\"ja\">"
    print "        <font weight=\"400\" style=\"normal\">ExtraJa.ttf</font>"
    print "    </family>"
  }
  { print }
' "$ROOT_DIR/tests/fixtures/font_fallback.excerpt.xml" > "$TMP_BASE/xml/extra_ja.xml"
assert_fails "reject XML with unexpected third ja family" "" \
  awk -v mode="fallback" -f "$ROOT_DIR/module/tools/fontxml.awk" "$TMP_BASE/xml/extra_ja.xml"

# Unclosed XML comment
cp -pf "$ROOT_DIR/tests/fixtures/font_fallback.excerpt.xml" "$TMP_BASE/xml/unclosed_comment.xml"
printf '\n<!-- unclosed comment\n' >> "$TMP_BASE/xml/unclosed_comment.xml"
assert_fails "reject XML with unclosed comment" "" \
  awk -v mode="fallback" -f "$ROOT_DIR/module/tools/fontxml.awk" "$TMP_BASE/xml/unclosed_comment.xml"

# B1 negative: CJK family with unsupported extra attribute (e.g. variant="compact")
sed 's/<family lang="zh-Hans">/<family lang="zh-Hans" variant="compact">/' \
  "$ROOT_DIR/tests/fixtures/font_fallback.excerpt.xml" > "$TMP_BASE/xml/cjk_extra_attr.xml"
assert_fails "reject CJK family with unsupported attribute" "" \
  awk -v mode="fallback" -f "$ROOT_DIR/module/tools/fontxml.awk" "$TMP_BASE/xml/cjk_extra_attr.xml"

# B1 negative: CJK family missing fallbackFor entry
sed '/lang="zh-Hans"/,/<\/family>/{ /fallbackFor="serif"/d; }' \
  "$ROOT_DIR/tests/fixtures/font_fallback.excerpt.xml" > "$TMP_BASE/xml/cjk_no_fallbackfor.xml"
assert_fails "reject CJK family missing fallbackFor font" "" \
  awk -v mode="fallback" -f "$ROOT_DIR/module/tools/fontxml.awk" "$TMP_BASE/xml/cjk_no_fallbackfor.xml"

# B1 negative: duplicate (fallbackFor, weight, style) inside a family
awk '
  /<family name="monospace">/ {
    print
    print "        <font weight=\"400\" style=\"normal\">DuplicateWeightStyle.ttf</font>"
    next
  }
  { print }
' "$ROOT_DIR/tests/fixtures/font_fallback.excerpt.xml" > "$TMP_BASE/xml/dup_style.xml"
assert_fails "reject family with duplicate (fallbackFor, weight, style)" "" \
  awk -v mode="fallback" -f "$ROOT_DIR/module/tools/fontxml.awk" "$TMP_BASE/xml/dup_style.xml"

# B2 case 1: sans-serif </family> followed on the same line by another valid non-target <family>
awk '
  /<family name="sans-serif">/ { in_ss = 1 }
  in_ss && /<\/family>/ {
    print "    </family><family name=\"custom-inline\"><font weight=\"400\" style=\"normal\">Inline.ttf</font></family>"
    in_ss = 0
    next
  }
  { print }
' "$ROOT_DIR/tests/fixtures/font_fallback.excerpt.xml" > "$TMP_BASE/xml/same_line_after_close.xml"
assert_fails "reject sans-serif </family> followed by another <family> on same line" "" \
  awk -v mode="fallback" -f "$ROOT_DIR/module/tools/fontxml.awk" "$TMP_BASE/xml/same_line_after_close.xml"

# B2 case 2: unclosed <unexpected> tag inserted before </familyset>
awk '
  /<\/familyset>/ {
    print "    <unexpected>"
  }
  { print }
' "$ROOT_DIR/tests/fixtures/font_fallback.excerpt.xml" > "$TMP_BASE/xml/unclosed_unexpected.xml"
assert_fails "reject unclosed <unexpected> before </familyset> during transform" "" \
  awk -v mode="fallback" -f "$ROOT_DIR/module/tools/fontxml.awk" "$TMP_BASE/xml/unclosed_unexpected.xml"

awk '
  /<\/familyset>/ {
    print "    <unexpected>"
  }
  { print }
' "$TMP_BASE/xml/font_fallback.xml" > "$TMP_BASE/xml/out_with_unexpected.xml"
assert_fails "reject unclosed <unexpected> before </familyset> in validate_only mode" "" \
  awk -v mode="fallback" -v validate_only=1 -f "$ROOT_DIR/module/tools/fontxml.awk" "$TMP_BASE/xml/out_with_unexpected.xml"

# B2 negative: invalid nesting (<alias> inside <family>, <axis> directly inside <family>, <font> directly in <familyset>)
awk '
  /<family name="monospace">/ {
    print
    print "        <alias name=\"bad-nest\" to=\"monospace\" />"
    next
  }
  { print }
' "$ROOT_DIR/tests/fixtures/font_fallback.excerpt.xml" > "$TMP_BASE/xml/bad_nest_alias.xml"
assert_fails "reject <alias> nested inside <family>" "" \
  awk -v mode="fallback" -f "$ROOT_DIR/module/tools/fontxml.awk" "$TMP_BASE/xml/bad_nest_alias.xml"

awk '
  /<family name="monospace">/ {
    print
    print "        <axis tag=\"wght\" stylevalue=\"400\" />"
    next
  }
  { print }
' "$ROOT_DIR/tests/fixtures/font_fallback.excerpt.xml" > "$TMP_BASE/xml/bad_nest_axis.xml"
assert_fails "reject <axis> directly inside <family> outside <font>" "" \
  awk -v mode="fallback" -f "$ROOT_DIR/module/tools/fontxml.awk" "$TMP_BASE/xml/bad_nest_axis.xml"

awk '
  /<\/familyset>/ {
    print "    <font weight=\"400\" style=\"normal\">StrayFont.ttf</font>"
  }
  { print }
' "$ROOT_DIR/tests/fixtures/font_fallback.excerpt.xml" > "$TMP_BASE/xml/bad_nest_font.xml"
assert_fails "reject <font> directly under <familyset> outside <family>" "" \
  awk -v mode="fallback" -f "$ROOT_DIR/module/tools/fontxml.awk" "$TMP_BASE/xml/bad_nest_font.xml"

# B2 negative: unclosed <font> element inside <family>
sed 's|<font weight="400" style="normal">DroidSansMono.ttf</font>|<font weight="400" style="normal">DroidSansMono.ttf|' \
  "$ROOT_DIR/tests/fixtures/font_fallback.excerpt.xml" > "$TMP_BASE/xml/unclosed_font.xml"
assert_fails "reject unclosed <font> element inside <family>" "" \
  awk -v mode="fallback" -f "$ROOT_DIR/module/tools/fontxml.awk" "$TMP_BASE/xml/unclosed_font.xml"

# B2 negative: trailing text/content after </familyset>
cp -pf "$ROOT_DIR/tests/fixtures/font_fallback.excerpt.xml" "$TMP_BASE/xml/trailing_text.xml"
printf 'trailing_text_after_root\n' >> "$TMP_BASE/xml/trailing_text.xml"
assert_fails "reject non-whitespace text after </familyset>" "" \
  awk -v mode="fallback" -f "$ROOT_DIR/module/tools/fontxml.awk" "$TMP_BASE/xml/trailing_text.xml"

# B2 negative: leading-zero weight="0400" style="normal" in monospace alongside weight="400" style="normal"
awk '
  /<family name="monospace">/ {
    print
    print "        <font weight=\"0400\" style=\"normal\">DupLeadingZero.ttf</font>"
    next
  }
  { print }
' "$ROOT_DIR/tests/fixtures/font_fallback.excerpt.xml" > "$TMP_BASE/xml/weight_0400_in.xml"
assert_fails "reject weight=0400 normal in monospace during transform" "" \
  awk -v mode="fallback" -f "$ROOT_DIR/module/tools/fontxml.awk" "$TMP_BASE/xml/weight_0400_in.xml"

awk '
  /<family name="monospace">/ {
    print
    print "        <font weight=\"0400\" style=\"normal\">DupLeadingZero.ttf</font>"
    next
  }
  { print }
' "$TMP_BASE/xml/font_fallback.xml" > "$TMP_BASE/xml/weight_0400_out.xml"
assert_fails "reject weight=0400 normal in monospace in validate_only mode" "" \
  awk -v mode="fallback" -v validate_only=1 -f "$ROOT_DIR/module/tools/fontxml.awk" "$TMP_BASE/xml/weight_0400_out.xml"
assert_fails "verify_xml.py rejects weight=0400 normal in monospace" "" \
  python3 -I "$ROOT_DIR/tests/verify_xml.py" "$ROOT_DIR/tests/fixtures/font_fallback.excerpt.xml" "$TMP_BASE/xml/weight_0400_out.xml" --mode fallback

# B2 negative: weight="400" style="bogus" in monospace alongside weight="400" style="normal"
awk '
  /<family name="monospace">/ {
    print
    print "        <font weight=\"400\" style=\"bogus\">DupBogusStyle.ttf</font>"
    next
  }
  { print }
' "$ROOT_DIR/tests/fixtures/font_fallback.excerpt.xml" > "$TMP_BASE/xml/style_bogus_in.xml"
assert_fails "reject weight=400 style=bogus in monospace during transform" "" \
  awk -v mode="fallback" -f "$ROOT_DIR/module/tools/fontxml.awk" "$TMP_BASE/xml/style_bogus_in.xml"

awk '
  /<family name="monospace">/ {
    print
    print "        <font weight=\"400\" style=\"bogus\">DupBogusStyle.ttf</font>"
    next
  }
  { print }
' "$TMP_BASE/xml/font_fallback.xml" > "$TMP_BASE/xml/style_bogus_out.xml"
assert_fails "reject weight=400 style=bogus in monospace in validate_only mode" "" \
  awk -v mode="fallback" -v validate_only=1 -f "$ROOT_DIR/module/tools/fontxml.awk" "$TMP_BASE/xml/style_bogus_out.xml"
assert_fails "verify_xml.py rejects weight=400 style=bogus in monospace" "" \
  python3 -I "$ROOT_DIR/tests/verify_xml.py" "$ROOT_DIR/tests/fixtures/font_fallback.excerpt.xml" "$TMP_BASE/xml/style_bogus_out.xml" --mode fallback

# B2 lexical negative 1: bare '&' in XML
sed 's/DroidSansMono\.ttf/Droid\&SansMono.ttf/' \
  "$ROOT_DIR/tests/fixtures/font_fallback.excerpt.xml" > "$TMP_BASE/xml/bare_amp_in.xml"
assert_fails "reject bare ampersand '&' during transform" "disallowed_ampersand_or_entity" \
  awk -v mode="fallback" -v stats="/dev/stderr" -f "$ROOT_DIR/module/tools/fontxml.awk" "$TMP_BASE/xml/bare_amp_in.xml"

sed 's/DroidSansMono\.ttf/Droid\&SansMono.ttf/' \
  "$TMP_BASE/xml/font_fallback.xml" > "$TMP_BASE/xml/bare_amp_out.xml"
assert_fails "reject bare ampersand '&' in validate_only mode" "disallowed_ampersand_or_entity" \
  awk -v mode="fallback" -v validate_only=1 -v stats="/dev/stderr" -f "$ROOT_DIR/module/tools/fontxml.awk" "$TMP_BASE/xml/bare_amp_out.xml"

# B2 lexical negative 2: entity reference '&undefined;' in XML
sed 's/name="monospace"/name="mono\&undefined;space"/' \
  "$ROOT_DIR/tests/fixtures/font_fallback.excerpt.xml" > "$TMP_BASE/xml/entity_undef_in.xml"
assert_fails "reject '&undefined;' entity reference during transform" "disallowed_ampersand_or_entity" \
  awk -v mode="fallback" -v stats="/dev/stderr" -f "$ROOT_DIR/module/tools/fontxml.awk" "$TMP_BASE/xml/entity_undef_in.xml"

sed 's/name="monospace"/name="mono\&undefined;space"/' \
  "$TMP_BASE/xml/font_fallback.xml" > "$TMP_BASE/xml/entity_undef_out.xml"
assert_fails "reject '&undefined;' entity reference in validate_only mode" "disallowed_ampersand_or_entity" \
  awk -v mode="fallback" -v validate_only=1 -v stats="/dev/stderr" -f "$ROOT_DIR/module/tools/fontxml.awk" "$TMP_BASE/xml/entity_undef_out.xml"

# B2 lexical negative 3: malformed XML declaration '<?xml garbage?>'
sed '1s/.*/<?xml garbage?>/' \
  "$ROOT_DIR/tests/fixtures/font_fallback.excerpt.xml" > "$TMP_BASE/xml/bad_decl_in.xml"
assert_fails "reject malformed '<?xml garbage?>' declaration during transform" "invalid_xml_declaration" \
  awk -v mode="fallback" -v stats="/dev/stderr" -f "$ROOT_DIR/module/tools/fontxml.awk" "$TMP_BASE/xml/bad_decl_in.xml"

sed '1s/.*/<?xml garbage?>/' \
  "$TMP_BASE/xml/font_fallback.xml" > "$TMP_BASE/xml/bad_decl_out.xml"
assert_fails "reject malformed '<?xml garbage?>' declaration in validate_only mode" "invalid_xml_declaration" \
  awk -v mode="fallback" -v validate_only=1 -v stats="/dev/stderr" -f "$ROOT_DIR/module/tools/fontxml.awk" "$TMP_BASE/xml/bad_decl_out.xml"

# B2 lexical negative 4: comment containing internal '--' ('<!-- illegal -- comment -->')
awk '
  /<family name="monospace">/ {
    print "    <!-- illegal -- comment -->"
  }
  { print }
' "$ROOT_DIR/tests/fixtures/font_fallback.excerpt.xml" > "$TMP_BASE/xml/bad_comment_in.xml"
assert_fails "reject '<!-- illegal -- comment -->' during transform" "invalid_double_dash_in_comment" \
  awk -v mode="fallback" -v stats="/dev/stderr" -f "$ROOT_DIR/module/tools/fontxml.awk" "$TMP_BASE/xml/bad_comment_in.xml"

awk '
  /<family name="monospace">/ {
    print "    <!-- illegal -- comment -->"
  }
  { print }
' "$TMP_BASE/xml/font_fallback.xml" > "$TMP_BASE/xml/bad_comment_out.xml"
assert_fails "reject '<!-- illegal -- comment -->' in validate_only mode" "invalid_double_dash_in_comment" \
  awk -v mode="fallback" -v validate_only=1 -v stats="/dev/stderr" -f "$ROOT_DIR/module/tools/fontxml.awk" "$TMP_BASE/xml/bad_comment_out.xml"

# 5. Simulated installation & environment checks
setup_sim_env() {
  sim_dir="$1"
  rm -rf "$sim_dir"
  mkdir -p \
    "$sim_dir/sysroot/system/etc" \
    "$sim_dir/adb/modules/meta_overlayfs" \
    "$sim_dir/adb/modules_update" \
    "$sim_dir/modpath/tools" \
    "$sim_dir/modpath/system/fonts"

  cp -pf "$ROOT_DIR/tests/fixtures/font_fallback.excerpt.xml" "$sim_dir/sysroot/system/etc/font_fallback.xml"
  cp -pf "$ROOT_DIR/tests/fixtures/fonts.excerpt.xml" "$sim_dir/sysroot/system/etc/fonts.xml"
  cp -pf "$ROOT_DIR/module/module.prop" "$sim_dir/modpath/module.prop"
  cp -pf "$ROOT_DIR/module/customize.sh" "$sim_dir/modpath/customize.sh"
  cp -pf "$ROOT_DIR/module/tools/fontconfig.sh" "$sim_dir/modpath/tools/fontconfig.sh"
  cp -pf "$ROOT_DIR/module/tools/fontxml.awk" "$sim_dir/modpath/tools/fontxml.awk"

  # Create non-empty dummy font files for install simulation
  for f in \
    KSU-NotoSans-Regular-VF.ttf \
    KSU-NotoSans-Italic-VF.ttf \
    KSU-NotoSansCJKsc-VF.ttf \
    KSU-NotoSansCJKtc-VF.ttf \
    KSU-NotoSansCJKjp-VF.ttf \
    KSU-NotoSansCJKkr-VF.ttf \
    KSU-AppleColorEmoji.ttf
  do
    printf 'DUMMY_FONT_%s\n' "$f" > "$sim_dir/modpath/system/fonts/$f"
  done

  # Default active metamodule with valid module.prop, non-empty metamount.sh, and /data/adb/metamodule symlink
  printf 'id=meta_overlayfs\nname=Meta OverlayFS\nmetamodule=1\n' > "$sim_dir/adb/modules/meta_overlayfs/module.prop"
  printf '#!/system/bin/sh\n# official metamodule mount entrypoint\nexit 0\n' > "$sim_dir/adb/modules/meta_overlayfs/metamount.sh"
  ln -s "modules/meta_overlayfs" "$sim_dir/adb/metamodule"
}

SIM="$TMP_BASE/sim"

# 5a. Normal install with active metamodule symlink + metamount.sh
setup_sim_env "$SIM"
KSU=true KSU_VER_CODE=30000 \
  FONT_CONFIG_ROOT="$SIM/sysroot" \
  FONT_ADB_ROOT="$SIM/adb" \
  MODPATH="$SIM/modpath" \
  sh "$SIM/modpath/customize.sh" >/dev/null

[ -f "$SIM/modpath/system/etc/font_fallback.xml" ] || fail "font_fallback.xml not committed"
[ -f "$SIM/modpath/system/etc/fonts.xml" ] || fail "fonts.xml not committed"
[ ! -d "$SIM/modpath/.staging" ] || fail ".staging directory was not cleaned up"
python3 -I "$ROOT_DIR/tests/verify_xml.py" \
  "$ROOT_DIR/tests/fixtures/font_fallback.excerpt.xml" \
  "$SIM/modpath/system/etc/font_fallback.xml" \
  --mode fallback
python3 -I "$ROOT_DIR/tests/verify_xml.py" \
  "$ROOT_DIR/tests/fixtures/fonts.excerpt.xml" \
  "$SIM/modpath/system/etc/fonts.xml" \
  --mode legacy
pass "simulated customize.sh install succeeded with active metamodule symlink and metamount.sh"

# 5b. Upgrade simulation: move installed module to $ADB_ROOT/modules/$MODID, pollute live sysroot
#     with already-adapted XML, and verify upgrade reuses clean original backup
mkdir -p "$SIM/adb/modules/ksu_noto_fonts_apple_emoji"
cp -prf "$SIM/modpath/." "$SIM/adb/modules/ksu_noto_fonts_apple_emoji/"
cp -pf "$SIM/modpath/system/etc/font_fallback.xml" "$SIM/sysroot/system/etc/font_fallback.xml"
cp -pf "$SIM/modpath/system/etc/fonts.xml" "$SIM/sysroot/system/etc/fonts.xml"
rm -rf "$SIM/modpath/config" "$SIM/modpath/system/etc" "$SIM/modpath/data"

KSU=true KSU_VER_CODE=30000 \
  FONT_CONFIG_ROOT="$SIM/sysroot" \
  FONT_ADB_ROOT="$SIM/adb" \
  MODPATH="$SIM/modpath" \
  sh "$SIM/modpath/customize.sh" >/dev/null

python3 -I "$ROOT_DIR/tests/verify_xml.py" \
  "$ROOT_DIR/tests/fixtures/font_fallback.excerpt.xml" \
  "$SIM/modpath/system/etc/font_fallback.xml" \
  --mode fallback
pass "simulated module upgrade preserved clean original backup without double-patching"

# 5c. Metamodule discovery via unique scan when /data/adb/metamodule link is absent
setup_sim_env "$SIM"
rm -f "$SIM/adb/metamodule"
KSU=true KSU_VER_CODE=30000 \
  FONT_CONFIG_ROOT="$SIM/sysroot" \
  FONT_ADB_ROOT="$SIM/adb" \
  MODPATH="$SIM/modpath" \
  sh "$SIM/modpath/customize.sh" >/dev/null
pass "accept install when /data/adb/metamodule link is absent but unique valid metamodule exists in modules/"

# 5d. Official KernelSU modules_update staging contract (modules/<id>/update + modules_update/<id>/metamount.sh)
setup_sim_env "$SIM"
rm -f "$SIM/adb/modules/meta_overlayfs/metamount.sh"
touch "$SIM/adb/modules/meta_overlayfs/update"
mkdir -p "$SIM/adb/modules_update/meta_overlayfs"
printf 'id=meta_overlayfs\nname=Meta OverlayFS\nmetamodule=1\n' > "$SIM/adb/modules_update/meta_overlayfs/module.prop"
printf '#!/system/bin/sh\nexit 0\n' > "$SIM/adb/modules_update/meta_overlayfs/metamount.sh"
KSU=true KSU_VER_CODE=30000 \
  FONT_CONFIG_ROOT="$SIM/sysroot" \
  FONT_ADB_ROOT="$SIM/adb" \
  MODPATH="$SIM/modpath" \
  sh "$SIM/modpath/customize.sh" >/dev/null
pass "accept metamodule staged under official KernelSU modules/<id>/update + modules_update/<id> contract"

# 5e. Reject uncontracted orphan metamodule in modules_update (missing modules/<id>/update contract)
setup_sim_env "$SIM"
rm -rf "$SIM/adb/metamodule" "$SIM/adb/modules/meta_overlayfs"
mkdir -p "$SIM/adb/modules_update/meta_overlayfs"
printf 'id=meta_overlayfs\nmetamodule=1\n' > "$SIM/adb/modules_update/meta_overlayfs/module.prop"
printf '#!/system/bin/sh\nexit 0\n' > "$SIM/adb/modules_update/meta_overlayfs/metamount.sh"
assert_fails "reject orphan metamodule in modules_update without official staging contract" "invalid_or_uncontracted_modules_update_metamodule" \
  env KSU=true KSU_VER_CODE=30000 \
  FONT_CONFIG_ROOT="$SIM/sysroot" FONT_ADB_ROOT="$SIM/adb" MODPATH="$SIM/modpath" \
  sh "$SIM/modpath/customize.sh"

# 5f. Reject when not running in KernelSU
setup_sim_env "$SIM"
assert_fails "reject install when KSU env is missing" "requires KernelSU|not_running_in_kernelsu" \
  env -u KSU -u KSU_VER_CODE \
  FONT_CONFIG_ROOT="$SIM/sysroot" FONT_ADB_ROOT="$SIM/adb" MODPATH="$SIM/modpath" \
  sh "$SIM/modpath/customize.sh"

# 5g. Reject when mount provider / metamodule is completely missing
setup_sim_env "$SIM"
rm -rf "$SIM/adb/metamodule" "$SIM/adb/modules/meta_overlayfs"
assert_fails "reject install when metamodule is missing" "ksu_mount_provider_missing_install_metamodule" \
  env KSU=true KSU_VER_CODE=30000 \
  FONT_CONFIG_ROOT="$SIM/sysroot" FONT_ADB_ROOT="$SIM/adb" MODPATH="$SIM/modpath" \
  sh "$SIM/modpath/customize.sh"

# 5h. Reject legacy version heuristic / KSU_LEGACY_MOUNT_OK bypass when metamodule is missing
setup_sim_env "$SIM"
rm -rf "$SIM/adb/metamodule" "$SIM/adb/modules/meta_overlayfs"
assert_fails "reject legacy KSU_VER_CODE / KSU_LEGACY_MOUNT_OK bypass without metamodule" "ksu_mount_provider_missing_install_metamodule" \
  env KSU=true KSU_VER_CODE=15000 KSU_LEGACY_MOUNT_OK=1 \
  FONT_CONFIG_ROOT="$SIM/sysroot" FONT_ADB_ROOT="$SIM/adb" MODPATH="$SIM/modpath" \
  sh "$SIM/modpath/customize.sh"

# 5i. Reject broken /data/adb/metamodule symlink even if another module exists
setup_sim_env "$SIM"
rm -f "$SIM/adb/metamodule"
ln -s "modules/nonexistent_meta" "$SIM/adb/metamodule"
assert_fails "reject install when /data/adb/metamodule is a broken symlink" "metamodule_broken_symlink" \
  env KSU=true KSU_VER_CODE=30000 \
  FONT_CONFIG_ROOT="$SIM/sysroot" FONT_ADB_ROOT="$SIM/adb" MODPATH="$SIM/modpath" \
  sh "$SIM/modpath/customize.sh"

# 5i-2. Reject when /data/adb/metamodule is a standalone regular directory (not a symlink)
setup_sim_env "$SIM"
rm -rf "$SIM/adb/metamodule" "$SIM/adb/modules/meta_overlayfs"
mkdir -p "$SIM/adb/metamodule"
printf 'id=meta_overlayfs\nname=Meta OverlayFS\nmetamodule=1\n' > "$SIM/adb/metamodule/module.prop"
printf '#!/system/bin/sh\nexit 0\n' > "$SIM/adb/metamodule/metamount.sh"
assert_fails "reject install when /data/adb/metamodule is a regular directory instead of symlink" "metamodule_not_a_symlink" \
  env KSU=true KSU_VER_CODE=30000 \
  FONT_CONFIG_ROOT="$SIM/sysroot" FONT_ADB_ROOT="$SIM/adb" MODPATH="$SIM/modpath" \
  sh "$SIM/modpath/customize.sh"

# 5i-3. Reject when /data/adb/metamodule is a symlink pointing outside /data/adb/modules
setup_sim_env "$SIM"
rm -rf "$SIM/adb/metamodule" "$SIM/adb/modules/meta_overlayfs"
mkdir -p "$SIM/adb/standalone_meta"
printf 'id=meta_overlayfs\nname=Meta OverlayFS\nmetamodule=1\n' > "$SIM/adb/standalone_meta/module.prop"
printf '#!/system/bin/sh\nexit 0\n' > "$SIM/adb/standalone_meta/metamount.sh"
ln -s "standalone_meta" "$SIM/adb/metamodule"
assert_fails "reject install when /data/adb/metamodule symlink points outside /data/adb/modules" "metamodule_symlink_target_not_in_modules" \
  env KSU=true KSU_VER_CODE=30000 \
  FONT_CONFIG_ROOT="$SIM/sysroot" FONT_ADB_ROOT="$SIM/adb" MODPATH="$SIM/modpath" \
  sh "$SIM/modpath/customize.sh"

# 5j. Reject empty-shell metamodule (only module.prop with metamodule=1, missing metamount.sh)
setup_sim_env "$SIM"
rm -f "$SIM/adb/modules/meta_overlayfs/metamount.sh"
assert_fails "reject empty-shell metamodule missing metamount.sh" "metamodule_incomplete_or_missing_metamount" \
  env KSU=true KSU_VER_CODE=30000 \
  FONT_CONFIG_ROOT="$SIM/sysroot" FONT_ADB_ROOT="$SIM/adb" MODPATH="$SIM/modpath" \
  sh "$SIM/modpath/customize.sh"

# 5k. Reject metamodule with empty (0-byte) metamount.sh
setup_sim_env "$SIM"
: > "$SIM/adb/modules/meta_overlayfs/metamount.sh"
assert_fails "reject metamodule with 0-byte metamount.sh" "metamodule_incomplete_or_missing_metamount" \
  env KSU=true KSU_VER_CODE=30000 \
  FONT_CONFIG_ROOT="$SIM/sysroot" FONT_ADB_ROOT="$SIM/adb" MODPATH="$SIM/modpath" \
  sh "$SIM/modpath/customize.sh"

# 5l. Reject metamodule where metamount.sh is a symlink instead of a regular file
setup_sim_env "$SIM"
mv "$SIM/adb/modules/meta_overlayfs/metamount.sh" "$SIM/adb/modules/meta_overlayfs/real_mount.sh"
ln -s "real_mount.sh" "$SIM/adb/modules/meta_overlayfs/metamount.sh"
assert_fails "reject metamodule where metamount.sh is a symlink" "metamodule_incomplete_or_missing_metamount" \
  env KSU=true KSU_VER_CODE=30000 \
  FONT_CONFIG_ROOT="$SIM/sysroot" FONT_ADB_ROOT="$SIM/adb" MODPATH="$SIM/modpath" \
  sh "$SIM/modpath/customize.sh"

# 5m. Reject metamodule with metamount.sh when module.prop lacks metamodule=1
setup_sim_env "$SIM"
printf 'id=meta_overlayfs\nname=Not A Metamodule\n' > "$SIM/adb/modules/meta_overlayfs/module.prop"
assert_fails "reject metamodule missing metamodule=1 in module.prop" "metamodule_incomplete_or_missing_metamount" \
  env KSU=true KSU_VER_CODE=30000 \
  FONT_CONFIG_ROOT="$SIM/sysroot" FONT_ADB_ROOT="$SIM/adb" MODPATH="$SIM/modpath" \
  sh "$SIM/modpath/customize.sh"

# 5n. Reject when multiple active metamodule candidates exist
setup_sim_env "$SIM"
rm -f "$SIM/adb/metamodule"
mkdir -p "$SIM/adb/modules/meta_second"
printf 'id=meta_second\nmetamodule=1\n' > "$SIM/adb/modules/meta_second/module.prop"
printf '#!/system/bin/sh\nexit 0\n' > "$SIM/adb/modules/meta_second/metamount.sh"
assert_fails "reject install when multiple active metamodules exist" "multiple_metamodules_detected" \
  env KSU=true KSU_VER_CODE=30000 \
  FONT_CONFIG_ROOT="$SIM/sysroot" FONT_ADB_ROOT="$SIM/adb" MODPATH="$SIM/modpath" \
  sh "$SIM/modpath/customize.sh"

# 5o. Reject when metamodule is disabled
setup_sim_env "$SIM"
touch "$SIM/adb/metamodule/disable"
assert_fails "reject install when metamodule is disabled" "metamodule_disabled_or_pending_removal" \
  env KSU=true KSU_VER_CODE=30000 \
  FONT_CONFIG_ROOT="$SIM/sysroot" FONT_ADB_ROOT="$SIM/adb" MODPATH="$SIM/modpath" \
  sh "$SIM/modpath/customize.sh"

# 5p. Reject when another active font module exists; allow when it has 'disable' file
setup_sim_env "$SIM"
mkdir -p "$SIM/adb/modules/other_font_mod/system/fonts"
assert_fails "reject install when conflicting font module is active" "conflicting_font_module:other_font_mod" \
  env KSU=true KSU_VER_CODE=30000 \
  FONT_CONFIG_ROOT="$SIM/sysroot" FONT_ADB_ROOT="$SIM/adb" MODPATH="$SIM/modpath" \
  sh "$SIM/modpath/customize.sh"

touch "$SIM/adb/modules/other_font_mod/disable"
KSU=true KSU_VER_CODE=30000 \
  FONT_CONFIG_ROOT="$SIM/sysroot" \
  FONT_ADB_ROOT="$SIM/adb" \
  MODPATH="$SIM/modpath" \
  sh "$SIM/modpath/customize.sh" >/dev/null
pass "allow install when other font module is disabled"

# 5q. Reject when secondary partition has font override (e.g. /my_product/etc/fonts.xml)
setup_sim_env "$SIM"
mkdir -p "$SIM/sysroot/my_product/etc"
touch "$SIM/sysroot/my_product/etc/fonts.xml"
assert_fails "reject install when secondary partition overrides fonts.xml" "unsupported_partition_font_override:/my_product/etc/fonts.xml" \
  env KSU=true KSU_VER_CODE=30000 \
  FONT_CONFIG_ROOT="$SIM/sysroot" FONT_ADB_ROOT="$SIM/adb" MODPATH="$SIM/modpath" \
  sh "$SIM/modpath/customize.sh"
if [ -d "$SIM/modpath/.staging" ] || [ -d "$SIM/modpath/system/etc" ]; then
  fail "failed install left staging or system/etc behind"
fi
pass "failed install cleaned up staging and system/etc"

# 5r. Staging cleanup when first XML (font_fallback.xml) succeeds and second XML (fonts.xml) fails
setup_sim_env "$SIM"
printf '<familyset version="23"><unexpected></familyset>\n' > "$SIM/sysroot/system/etc/fonts.xml"
assert_fails "reject install when first XML succeeds and second XML fails" "legacy_xml_transform_failed" \
  env KSU=true KSU_VER_CODE=30000 \
  FONT_CONFIG_ROOT="$SIM/sysroot" FONT_ADB_ROOT="$SIM/adb" MODPATH="$SIM/modpath" \
  sh "$SIM/modpath/customize.sh"
if [ -d "$SIM/modpath/.staging" ] || [ -d "$SIM/modpath/system/etc" ]; then
  fail "second-XML failure left .staging or partial system/etc behind"
fi
pass "cleaned up .staging and prevented partial commit when first XML succeeded and second XML failed"

# 5s. Staging cleanup on actual SIGTERM signal during XML transformation (after first XML is staged)
setup_sim_env "$SIM"
REAL_AWK=$(command -v awk)
mkdir -p "$TMP_BASE/term_bin"
cat <<EOF > "$TMP_BASE/term_bin/awk"
#!/bin/sh
for arg in "\$@"; do
  if [ "\$arg" = "mode=legacy" ]; then
    # Verify first XML is currently staged, then deliver SIGTERM to parent fontconfig.sh
    if [ -s "$SIM/modpath/.staging/etc/font_fallback.xml" ]; then
      touch "$TMP_BASE/saw_staged_first_xml"
    fi
    kill -TERM "\$PPID" 2>/dev/null || :
    exit 143
  fi
done
exec "$REAL_AWK" "\$@"
EOF
chmod 0755 "$TMP_BASE/term_bin/awk"

assert_fails "trap SIGTERM during XML transform and report interrupted" "error=interrupted" \
  env PATH="$TMP_BASE/term_bin:$PATH" KSU=true KSU_VER_CODE=30000 \
  FONT_CONFIG_ROOT="$SIM/sysroot" FONT_ADB_ROOT="$SIM/adb" MODPATH="$SIM/modpath" \
  sh "$SIM/modpath/tools/fontconfig.sh" prepare
[ -f "$TMP_BASE/saw_staged_first_xml" ] || fail "SIGTERM test did not stage first XML before signal"
if [ -d "$SIM/modpath/.staging" ] || [ -d "$SIM/modpath/system/etc" ]; then
  fail "SIGTERM interruption left .staging or system/etc behind"
fi
pass "SIGTERM during second XML transform cleaned up staged first XML and exited cleanly"

# 5t. Reject when bundled font is missing
setup_sim_env "$SIM"
rm -f "$SIM/modpath/system/fonts/KSU-AppleColorEmoji.ttf"
assert_fails "reject install when bundled font is missing" "missing_bundled_font:KSU-AppleColorEmoji.ttf" \
  env KSU=true KSU_VER_CODE=30000 \
  FONT_CONFIG_ROOT="$SIM/sysroot" FONT_ADB_ROOT="$SIM/adb" MODPATH="$SIM/modpath" \
  sh "$SIM/modpath/customize.sh"

# 6. ZIP verifier negative tests using synthetic mini lockfile & ZIPs
MINI_DIR="$TMP_BASE/zip_tests"
mkdir -p "$MINI_DIR"
MINI_LOCK="$MINI_DIR/mini.lock"
cat <<'EOF' > "$MINI_LOCK"
font|KSU-MiniFont.ttf|test@1|https://example.invalid/KSU-MiniFont.ttf|5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03
license|OFL-Mini.txt|test@1|https://example.invalid/OFL-Mini.txt|5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03
EOF

python3 -I - "$MINI_DIR" <<'PYEOF'
import sys, zipfile

base = sys.argv[1]
hello = b"hello\n"  # sha256 = 5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03

def make_zip(path, entries):
    with zipfile.ZipFile(path, "w") as zf:
        for k, v in entries.items():
            zf.writestr(k, v)

valid_entries = {
    "module.prop": b"id=test\n",
    "customize.sh": b"#!/system/bin/sh\n",
    "NOTICE.md": b"notice\n",
    "tools/fontconfig.sh": b"#!/system/bin/sh\n",
    "tools/fontxml.awk": b"BEGIN {}\n",
    "system/fonts/KSU-MiniFont.ttf": hello,
    "licenses/OFL-Mini.txt": hello,
}

make_zip(f"{base}/valid.zip", valid_entries)

missing_entries = dict(valid_entries)
del missing_entries["tools/fontxml.awk"]
make_zip(f"{base}/missing.zip", missing_entries)

bad_hash_entries = dict(valid_entries)
bad_hash_entries["system/fonts/KSU-MiniFont.ttf"] = b"tampered\n"
make_zip(f"{base}/bad_hash.zip", bad_hash_entries)

traversal_entries = dict(valid_entries)
traversal_entries["../evil.sh"] = b"evil\n"
make_zip(f"{base}/traversal.zip", traversal_entries)

prebaked_entries = dict(valid_entries)
prebaked_entries["system/etc/fonts.xml"] = b"<familyset/>\n"
make_zip(f"{base}/prebaked.zip", prebaked_entries)

with open(f"{base}/corrupt.zip", "wb") as f:
    f.write(b"not a zip file at all")
PYEOF

FONT_LOCK_FILE="$MINI_LOCK" sh "$ROOT_DIR/scripts/verify_zip.sh" "$MINI_DIR/valid.zip" >/dev/null
pass "verify_zip.sh accepted valid synthetic ZIP"

assert_fails "verify_zip.sh rejects missing required file" "missing required files" \
  env FONT_LOCK_FILE="$MINI_LOCK" sh "$ROOT_DIR/scripts/verify_zip.sh" "$MINI_DIR/missing.zip"

assert_fails "verify_zip.sh rejects tampered font SHA-256" "SHA-256 mismatch" \
  env FONT_LOCK_FILE="$MINI_LOCK" sh "$ROOT_DIR/scripts/verify_zip.sh" "$MINI_DIR/bad_hash.zip"

assert_fails "verify_zip.sh rejects path traversal entry" "unsafe relative path traversal" \
  env FONT_LOCK_FILE="$MINI_LOCK" sh "$ROOT_DIR/scripts/verify_zip.sh" "$MINI_DIR/traversal.zip"

assert_fails "verify_zip.sh rejects pre-baked system/etc XML" "pre-baked system/etc config is forbidden" \
  env FONT_LOCK_FILE="$MINI_LOCK" sh "$ROOT_DIR/scripts/verify_zip.sh" "$MINI_DIR/prebaked.zip"

assert_fails "verify_zip.sh rejects corrupted non-ZIP file" "not a valid ZIP archive" \
  env FONT_LOCK_FILE="$MINI_LOCK" sh "$ROOT_DIR/scripts/verify_zip.sh" "$MINI_DIR/corrupt.zip"

printf '==> All %d test checks passed!\n' "$pass_count"
