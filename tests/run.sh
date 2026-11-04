#!/bin/sh
# End-to-end regression test suite for ksu-noto-fonts-apple-emoji (v1.0.2).
# Covers:
# 1. ShellCheck static analysis (uses system shellcheck or .cache/shellcheck-*/shellcheck if present)
# 2. Excerpt fixture disclaimer verification
# 3. Direct fontxml.awk transformation, validate_only mode, & independent ElementTree verification (tests/verify_xml.py),
#    including CJK fallbackFor preservation, serif KsuReserved-* mapping without adding wght, axisless CJK wght pinning,
#    weight=1000 clamping to 900, and per-(fallbackFor, weight, style) uniqueness
# 4. Safe rejection on malformed / unsupported XML inputs (wrong root version, missing families,
#    duplicate CJK families, unexpected extra ja family, TTC index out-of-bounds / locale mismatch,
#    already-polluted input XML, unclosed tags/comments, same-line </family><family>,
#    unclosed <unexpected> before </familyset>, invalid nesting, unclosed <font>, content after </familyset>,
#    unsupported CJK family attributes, missing CJK fallbackFor)
# 5. Simulated full customize.sh / fontconfig.sh install & upgrade lifecycle:
#    - Success with active metamodule symlink (/data/adb/metamodule -> /data/adb/modules/meta_overlayfs + metamount.sh)
#    - Verification of 3 install-time KsuReserved-*.ttf copies, fingerprint, and sha256sums
#    - Upgrade idempotence (reuses original backup & KsuReserved-*.ttf copies when fingerprint + SHA-256 match)
#    - Rejection when trusted original system fonts are missing or polluted on fresh install
#    - Rejection on module upgrade when system fingerprint changes (OTA), backup metadata is missing,
#      KsuReserved-*.ttf or XML backup hash is corrupted, or reserved font is polluted with module payload
#    - Rejection when not running in KernelSU or when metamodule is missing/invalid/disabled
#    - Rejection when conflicting font module is enabled (and allowed when disabled/removed)
#    - Rejection when secondary partition overrides fonts.xml / font_fallback.xml
#    - Staging cleanup when 2nd or 3rd XML fails or on actual SIGTERM interruption
# 6. ZIP verifier negative tests (corrupted archive, missing required file, path traversal,
#    unexpected file, pre-baked system/etc config, KsuReserved-* copy leak, legacy KSU-* font leak, font hash mismatch)

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
grep -q "EXCERPT FIXTURE ONLY (NOT COMPLETE DEVICE FILE)" "$ROOT_DIR/tests/fixtures/fonts_base.excerpt.xml" || \
  fail "fonts_base.excerpt.xml missing excerpt disclaimer"
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

awk -v mode="base" -v stats="$TMP_BASE/xml/base.stats" \
  -f "$ROOT_DIR/module/tools/fontxml.awk" \
  "$ROOT_DIR/tests/fixtures/fonts_base.excerpt.xml" > "$TMP_BASE/xml/fonts_base.xml"
awk -v mode="base" -v validate_only=1 \
  -f "$ROOT_DIR/module/tools/fontxml.awk" \
  "$TMP_BASE/xml/fonts_base.xml"
python3 -I "$ROOT_DIR/tests/verify_xml.py" \
  "$ROOT_DIR/tests/fixtures/fonts_base.excerpt.xml" \
  "$TMP_BASE/xml/fonts_base.xml" \
  --mode base
pass "base XML transformation verified by validate_only and independent ElementTree parser"

# 3b. Verify CJK fallbackFor font with child <axis> tags is preserved verbatim in-place
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
pass "CJK fallbackFor font with child <axis> tags is preserved verbatim in-place"

# 3c. Verify normal CJK font without <axis tag="wght"> gets wght pinned while serif KsuReserved-* stays axisless
awk '
  /<font weight="400" style="normal" postScriptName="OPPO_Sans_4.0_SC">SysSans-Hans-Regular\.ttf/ {
    in_h400 = 1
    print "        <font weight=\"400\" style=\"normal\" postScriptName=\"OPPO_Sans_4.0_SC\">SysSans-Hans-Regular.ttf</font>"
    next
  }
  in_h400 && /<\/font>/ {
    in_h400 = 0
    next
  }
  in_h400 { next }
  { print }
' "$ROOT_DIR/tests/fixtures/fonts.excerpt.xml" > "$TMP_BASE/xml/leg_pin_in.xml"
awk -v mode="legacy" -v stats="$TMP_BASE/xml/leg_pin.stats" \
  -f "$ROOT_DIR/module/tools/fontxml.awk" \
  "$TMP_BASE/xml/leg_pin_in.xml" > "$TMP_BASE/xml/leg_pin_out.xml"
grep -q "pin=1" "$TMP_BASE/xml/leg_pin.stats" || fail "expected pin=1 when normal CJK node lacked wght axis"
awk -v mode="legacy" -v validate_only=1 \
  -f "$ROOT_DIR/module/tools/fontxml.awk" \
  "$TMP_BASE/xml/leg_pin_out.xml"
python3 -I "$ROOT_DIR/tests/verify_xml.py" \
  "$TMP_BASE/xml/leg_pin_in.xml" \
  "$TMP_BASE/xml/leg_pin_out.xml" \
  --mode legacy
pass "axisless normal CJK font gets wght pinned while fallbackFor=serif KsuReserved-* remains axisless"

# 4. Negative XML tests (safe rejection on unsupported/malformed structures)
assert_fails "reject fallback XML when run in legacy mode" "" \
  awk -v mode="legacy" -f "$ROOT_DIR/module/tools/fontxml.awk" "$ROOT_DIR/tests/fixtures/font_fallback.excerpt.xml"

assert_fails "reject fallback XML when run in base mode" "" \
  awk -v mode="base" -f "$ROOT_DIR/module/tools/fontxml.awk" "$ROOT_DIR/tests/fixtures/font_fallback.excerpt.xml"

assert_fails "reject legacy XML when run in fallback mode" "" \
  awk -v mode="fallback" -f "$ROOT_DIR/module/tools/fontxml.awk" "$ROOT_DIR/tests/fixtures/fonts.excerpt.xml"

assert_fails "reject legacy XML when run in base mode" "unexpected_base_sans_serif_font|unexpected_unnamed_western_in_base" \
  awk -v mode="base" -v stats="/dev/stderr" -f "$ROOT_DIR/module/tools/fontxml.awk" "$ROOT_DIR/tests/fixtures/fonts.excerpt.xml"

awk '
  /<family name="sys-sans-en">/ {
    print "    <family>"
    print "        <font supportedAxes=\"wght,ital\">Roboto-Regular.ttf"
    print "            <axis tag=\"wdth\" stylevalue=\"100\" />"
    print "        </font>"
    print "    </family>"
  }
  { print }
' "$ROOT_DIR/tests/fixtures/fonts_base.excerpt.xml" > "$TMP_BASE/xml/base_with_unnamed.xml"
assert_fails "reject base XML with unexpected unnamed family after sans-serif" "unexpected_unnamed_western_in_base" \
  awk -v mode="base" -v stats="/dev/stderr" -f "$ROOT_DIR/module/tools/fontxml.awk" "$TMP_BASE/xml/base_with_unnamed.xml"

assert_fails "reject base XML (with Roboto sans-serif) when run in legacy mode" "unexpected_legacy_sans_serif_font|unnamed_western_count_0" \
  awk -v mode="legacy" -v stats="/dev/stderr" -f "$ROOT_DIR/module/tools/fontxml.awk" "$ROOT_DIR/tests/fixtures/fonts_base.excerpt.xml"

awk '
  /<family>/ { skip_unnamed = 1 }
  skip_unnamed && /<\/family>/ { skip_unnamed = 0; next }
  skip_unnamed { next }
  { print }
' "$ROOT_DIR/tests/fixtures/fonts.excerpt.xml" > "$TMP_BASE/xml/legacy_no_unnamed.xml"
assert_fails "reject legacy XML missing unnamed Roboto family after sans-serif" "unnamed_western_count_0" \
  awk -v mode="legacy" -v stats="/dev/stderr" -f "$ROOT_DIR/module/tools/fontxml.awk" "$TMP_BASE/xml/legacy_no_unnamed.xml"

sed '/name="sys-sans-en"/,/<\/family>/d' "$ROOT_DIR/tests/fixtures/fonts_base.excerpt.xml" > "$TMP_BASE/xml/base_no_sys_sans.xml"
assert_fails "reject base XML missing sys-sans-en" "sys_sans_en_count_0" \
  awk -v mode="base" -v stats="/dev/stderr" -f "$ROOT_DIR/module/tools/fontxml.awk" "$TMP_BASE/xml/base_no_sys_sans.xml"

sed '/name="op-sans-en"/,/<\/family>/d' "$ROOT_DIR/tests/fixtures/fonts_base.excerpt.xml" > "$TMP_BASE/xml/base_no_op_sans.xml"
assert_fails "reject base XML missing op-sans-en" "op_sans_en_count_0" \
  awk -v mode="base" -v stats="/dev/stderr" -f "$ROOT_DIR/module/tools/fontxml.awk" "$TMP_BASE/xml/base_no_op_sans.xml"

# Missing ko family
sed '/lang="ko"/,/<\/family>/d' "$ROOT_DIR/tests/fixtures/font_fallback.excerpt.xml" > "$TMP_BASE/xml/no_ko.xml"
assert_fails "reject XML missing required ko family" "" \
  awk -v mode="fallback" -f "$ROOT_DIR/module/tools/fontxml.awk" "$TMP_BASE/xml/no_ko.xml"

# Missing sys-sans-en in legacy mode
sed '/name="sys-sans-en"/,/<\/family>/d' "$ROOT_DIR/tests/fixtures/fonts.excerpt.xml" > "$TMP_BASE/xml/no_sys_sans.xml"
assert_fails "reject legacy XML missing sys-sans-en" "" \
  awk -v mode="legacy" -f "$ROOT_DIR/module/tools/fontxml.awk" "$TMP_BASE/xml/no_sys_sans.xml"

# TTC index out-of-bounds (index="4") and locale index mismatch (index="0" in zh-Hans)
sed 's/index="2" supportedAxes="wght"/index="4" supportedAxes="wght"/' \
  "$ROOT_DIR/tests/fixtures/font_fallback.excerpt.xml" > "$TMP_BASE/xml/ttc_idx_oob_in.xml"
assert_fails "reject TTC index out-of-bounds (index=4) during transform" "ttc_index_mismatch:4:lang=zh-Hans" \
  awk -v mode="fallback" -v stats="/dev/stderr" -f "$ROOT_DIR/module/tools/fontxml.awk" "$TMP_BASE/xml/ttc_idx_oob_in.xml"

sed 's/index="2" supportedAxes="wght"/index="4" supportedAxes="wght"/' \
  "$TMP_BASE/xml/font_fallback.xml" > "$TMP_BASE/xml/ttc_idx_oob_out.xml"
assert_fails "reject TTC index out-of-bounds (index=4) in validate_only mode" "ttc_index_mismatch:4:lang=zh-Hans" \
  awk -v mode="fallback" -v validate_only=1 -v stats="/dev/stderr" -f "$ROOT_DIR/module/tools/fontxml.awk" "$TMP_BASE/xml/ttc_idx_oob_out.xml"
assert_fails "verify_xml.py rejects TTC index out-of-bounds (index=4)" "font diff mismatch" \
  python3 -I "$ROOT_DIR/tests/verify_xml.py" "$ROOT_DIR/tests/fixtures/font_fallback.excerpt.xml" "$TMP_BASE/xml/ttc_idx_oob_out.xml" --mode fallback

sed 's/index="1" supportedAxes="wght"/index="0" supportedAxes="wght"/' \
  "$ROOT_DIR/tests/fixtures/font_fallback.excerpt.xml" > "$TMP_BASE/xml/ttc_idx_wrong_lang.xml"
assert_fails "reject TTC index mismatch (index=0 in lang=ko)" "ttc_index_mismatch:0:lang=ko" \
  awk -v mode="fallback" -v stats="/dev/stderr" -f "$ROOT_DIR/module/tools/fontxml.awk" "$TMP_BASE/xml/ttc_idx_wrong_lang.xml"

# Reject already-modified XML passed as input to transform
assert_fails "reject already-transformed XML as transform input" "already_modified_font_in_input" \
  awk -v mode="fallback" -v stats="/dev/stderr" -f "$ROOT_DIR/module/tools/fontxml.awk" "$TMP_BASE/xml/font_fallback.xml"

# Reject validate_only XML if OEM postScriptName remains on Noto font
sed 's|<font weight="400" style="normal" index="2" supportedAxes="wght">NotoSansCJK-Regular.ttc</font>|<font weight="400" style="normal" index="2" supportedAxes="wght" postScriptName="NotoSansCJKJP-Regular">NotoSansCJK-Regular.ttc</font>|' \
  "$TMP_BASE/xml/font_fallback.xml" > "$TMP_BASE/xml/leaked_ps_out.xml"
assert_fails "reject validate_only XML with leaked OEM postScriptName on Noto font" "unexpected_postScriptName_on_noto_font" \
  awk -v mode="fallback" -v validate_only=1 -v stats="/dev/stderr" -f "$ROOT_DIR/module/tools/fontxml.awk" "$TMP_BASE/xml/leaked_ps_out.xml"

# Reject validate_only XML if KsuReserved serif node accidentally gets a wght axis
sed 's|>KsuReserved-SysSans-Hans-Regular.ttf|>KsuReserved-SysSans-Hans-Regular.ttf<axis tag="wght" stylevalue="400" />|' \
  "$TMP_BASE/xml/fonts.xml" > "$TMP_BASE/xml/serif_with_axis_out.xml"
assert_fails "reject validate_only XML when KsuReserved serif font has unexpected axis" "invalid_syssans_serif_node" \
  awk -v mode="legacy" -v validate_only=1 -v stats="/dev/stderr" -f "$ROOT_DIR/module/tools/fontxml.awk" "$TMP_BASE/xml/serif_with_axis_out.xml"

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

# CJK family with unsupported extra attribute (e.g. variant="compact")
sed 's/<family lang="zh-Hans">/<family lang="zh-Hans" variant="compact">/' \
  "$ROOT_DIR/tests/fixtures/font_fallback.excerpt.xml" > "$TMP_BASE/xml/cjk_extra_attr.xml"
assert_fails "reject CJK family with unsupported attribute" "" \
  awk -v mode="fallback" -f "$ROOT_DIR/module/tools/fontxml.awk" "$TMP_BASE/xml/cjk_extra_attr.xml"

# CJK family missing fallbackFor entry
sed '/lang="zh-Hans"/,/<\/family>/{ /fallbackFor="serif"/d; }' \
  "$ROOT_DIR/tests/fixtures/font_fallback.excerpt.xml" > "$TMP_BASE/xml/cjk_no_fallbackfor.xml"
assert_fails "reject CJK family missing fallbackFor font" "" \
  awk -v mode="fallback" -f "$ROOT_DIR/module/tools/fontxml.awk" "$TMP_BASE/xml/cjk_no_fallbackfor.xml"

# Duplicate (fallbackFor, weight, style) inside a family
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

# sans-serif </family> followed on the same line by another valid non-target <family>
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

# Unclosed <unexpected> tag inserted before </familyset>
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

# Invalid nesting (<alias> inside <family>, <axis> directly inside <family>, <font> directly in <familyset>)
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

# Unclosed <font> element inside <family>
sed 's|<font weight="400" style="normal">DroidSansMono.ttf</font>|<font weight="400" style="normal">DroidSansMono.ttf|' \
  "$ROOT_DIR/tests/fixtures/font_fallback.excerpt.xml" > "$TMP_BASE/xml/unclosed_font.xml"
assert_fails "reject unclosed <font> element inside <family>" "" \
  awk -v mode="fallback" -f "$ROOT_DIR/module/tools/fontxml.awk" "$TMP_BASE/xml/unclosed_font.xml"

# Trailing text/content after </familyset>
cp -pf "$ROOT_DIR/tests/fixtures/font_fallback.excerpt.xml" "$TMP_BASE/xml/trailing_text.xml"
printf 'trailing_text_after_root\n' >> "$TMP_BASE/xml/trailing_text.xml"
assert_fails "reject non-whitespace text after </familyset>" "" \
  awk -v mode="fallback" -f "$ROOT_DIR/module/tools/fontxml.awk" "$TMP_BASE/xml/trailing_text.xml"

# Leading-zero weight="0400" style="normal" in monospace alongside weight="400" style="normal"
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

# weight="400" style="bogus" in monospace alongside weight="400" style="normal"
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

# Lexical negative 1: bare '&' in XML
sed 's/DroidSansMono\.ttf/Droid\&SansMono.ttf/' \
  "$ROOT_DIR/tests/fixtures/font_fallback.excerpt.xml" > "$TMP_BASE/xml/bare_amp_in.xml"
assert_fails "reject bare ampersand '&' during transform" "disallowed_ampersand_or_entity" \
  awk -v mode="fallback" -v stats="/dev/stderr" -f "$ROOT_DIR/module/tools/fontxml.awk" "$TMP_BASE/xml/bare_amp_in.xml"

sed 's/DroidSansMono\.ttf/Droid\&SansMono.ttf/' \
  "$TMP_BASE/xml/font_fallback.xml" > "$TMP_BASE/xml/bare_amp_out.xml"
assert_fails "reject bare ampersand '&' in validate_only mode" "disallowed_ampersand_or_entity" \
  awk -v mode="fallback" -v validate_only=1 -v stats="/dev/stderr" -f "$ROOT_DIR/module/tools/fontxml.awk" "$TMP_BASE/xml/bare_amp_out.xml"

# Lexical negative 2: entity reference '&undefined;' in XML
sed 's/name="monospace"/name="mono\&undefined;space"/' \
  "$ROOT_DIR/tests/fixtures/font_fallback.excerpt.xml" > "$TMP_BASE/xml/entity_undef_in.xml"
assert_fails "reject '&undefined;' entity reference during transform" "disallowed_ampersand_or_entity" \
  awk -v mode="fallback" -v stats="/dev/stderr" -f "$ROOT_DIR/module/tools/fontxml.awk" "$TMP_BASE/xml/entity_undef_in.xml"

sed 's/name="monospace"/name="mono\&undefined;space"/' \
  "$TMP_BASE/xml/font_fallback.xml" > "$TMP_BASE/xml/entity_undef_out.xml"
assert_fails "reject '&undefined;' entity reference in validate_only mode" "disallowed_ampersand_or_entity" \
  awk -v mode="fallback" -v validate_only=1 -v stats="/dev/stderr" -f "$ROOT_DIR/module/tools/fontxml.awk" "$TMP_BASE/xml/entity_undef_out.xml"

# Lexical negative 3: malformed XML declaration '<?xml garbage?>'
sed '1s/.*/<?xml garbage?>/' \
  "$ROOT_DIR/tests/fixtures/font_fallback.excerpt.xml" > "$TMP_BASE/xml/bad_decl_in.xml"
assert_fails "reject malformed '<?xml garbage?>' declaration during transform" "invalid_xml_declaration" \
  awk -v mode="fallback" -v stats="/dev/stderr" -f "$ROOT_DIR/module/tools/fontxml.awk" "$TMP_BASE/xml/bad_decl_in.xml"

sed '1s/.*/<?xml garbage?>/' \
  "$TMP_BASE/xml/font_fallback.xml" > "$TMP_BASE/xml/bad_decl_out.xml"
assert_fails "reject malformed '<?xml garbage?>' declaration in validate_only mode" "invalid_xml_declaration" \
  awk -v mode="fallback" -v validate_only=1 -v stats="/dev/stderr" -f "$ROOT_DIR/module/tools/fontxml.awk" "$TMP_BASE/xml/bad_decl_out.xml"

# Lexical negative 4: comment containing internal '--' ('<!-- illegal -- comment -->')
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
    "$sim_dir/sysroot/system/fonts" \
    "$sim_dir/adb/modules/meta_overlayfs" \
    "$sim_dir/adb/modules_update" \
    "$sim_dir/modpath/tools" \
    "$sim_dir/modpath/system/fonts"

  cp -pf "$ROOT_DIR/tests/fixtures/font_fallback.excerpt.xml" "$sim_dir/sysroot/system/etc/font_fallback.xml"
  cp -pf "$ROOT_DIR/tests/fixtures/fonts.excerpt.xml" "$sim_dir/sysroot/system/etc/fonts.xml"
  printf 'ro.system.build.fingerprint=OnePlus/PJZ110/OP5D0DL1:16/BP2A.250605.031.A3/1730000000:user/release-keys\n' \
    > "$sim_dir/sysroot/system/build.prop"

  # Trusted original system fonts in /system/fonts
  for orig_f in SysSans-Hans-Regular.ttf SysSans-Hant-Regular.ttf NotoColorEmoji.ttf; do
    printf 'ORIG_SYSTEM_FONT_%s\n' "$orig_f" > "$sim_dir/sysroot/system/fonts/$orig_f"
  done

  cp -pf "$ROOT_DIR/module/module.prop" "$sim_dir/modpath/module.prop"
  cp -pf "$ROOT_DIR/module/customize.sh" "$sim_dir/modpath/customize.sh"
  cp -pf "$ROOT_DIR/module/tools/fontconfig.sh" "$sim_dir/modpath/tools/fontconfig.sh"
  cp -pf "$ROOT_DIR/module/tools/fontxml.awk" "$sim_dir/modpath/tools/fontxml.awk"

  # Create non-empty dummy module font files for install simulation
  for f in \
    Roboto-Regular.ttf \
    SysFont-Regular.ttf \
    SysSans-En-Regular.ttf \
    OPSans-En-Regular.ttf \
    NotoSans-Italic.ttf \
    SysSans-Hans-Regular.ttf \
    SysSans-Hant-Regular.ttf \
    NotoSansCJK-Regular.ttc \
    NotoColorEmoji.ttf
  do
    printf 'MODULE_PAYLOAD_FONT_%s\n' "$f" > "$sim_dir/modpath/system/fonts/$f"
  done

  # Default active metamodule with valid module.prop, non-empty metamount.sh, and /data/adb/metamodule symlink
  printf 'id=meta_overlayfs\nname=Meta OverlayFS\nmetamodule=1\n' > "$sim_dir/adb/modules/meta_overlayfs/module.prop"
  printf '#!/system/bin/sh\n# official metamodule mount entrypoint\nexit 0\n' > "$sim_dir/adb/modules/meta_overlayfs/metamount.sh"
  ln -s "modules/meta_overlayfs" "$sim_dir/adb/metamodule"
}

SIM="$TMP_BASE/sim"

# 5a. Normal install with active metamodule symlink + metamount.sh + 3 KsuReserved-*.ttf copies
setup_sim_env "$SIM"
KSU=true KSU_VER_CODE=30000 \
  FONT_CONFIG_ROOT="$SIM/sysroot" \
  FONT_ADB_ROOT="$SIM/adb" \
  MODPATH="$SIM/modpath" \
  sh "$SIM/modpath/customize.sh" >/dev/null

[ -f "$SIM/modpath/system/etc/font_fallback.xml" ] || fail "font_fallback.xml not committed"
[ -f "$SIM/modpath/system/etc/fonts.xml" ] || fail "fonts.xml not committed"
[ -f "$SIM/modpath/config/original/fingerprint" ] || fail "config/original/fingerprint not created"
[ -f "$SIM/modpath/config/original/sha256sums" ] || fail "config/original/sha256sums not created"
for orig_f in SysSans-Hans-Regular.ttf SysSans-Hant-Regular.ttf NotoColorEmoji.ttf; do
  res_f="KsuReserved-$orig_f"
  [ -f "$SIM/modpath/system/fonts/$res_f" ] || fail "$res_f not created in modpath/system/fonts"
  cmp -s "$SIM/modpath/system/fonts/$res_f" "$SIM/sysroot/system/fonts/$orig_f" || \
    fail "$res_f does not match original /system/fonts/$orig_f byte-for-byte"
done
[ ! -d "$SIM/modpath/.staging" ] || fail ".staging directory was not cleaned up"
python3 -I "$ROOT_DIR/tests/verify_xml.py" \
  "$ROOT_DIR/tests/fixtures/font_fallback.excerpt.xml" \
  "$SIM/modpath/system/etc/font_fallback.xml" \
  --mode fallback
python3 -I "$ROOT_DIR/tests/verify_xml.py" \
  "$ROOT_DIR/tests/fixtures/fonts.excerpt.xml" \
  "$SIM/modpath/system/etc/fonts.xml" \
  --mode legacy
pass "simulated customize.sh install succeeded, preserved 3 KsuReserved-*.ttf copies byte-for-byte, and recorded fingerprint + sha256sums"

# 5b. Upgrade simulation: move installed module to $ADB_ROOT/modules/$MODID, pollute live sysroot
#     with already-adapted XML and overlaid fonts, and verify upgrade reuses verified original backup + KsuReserved-*.ttf
mkdir -p "$SIM/adb/modules/ksu_noto_fonts_apple_emoji"
cp -prf "$SIM/modpath/." "$SIM/adb/modules/ksu_noto_fonts_apple_emoji/"
cp -pf "$SIM/modpath/system/etc/font_fallback.xml" "$SIM/sysroot/system/etc/font_fallback.xml"
cp -pf "$SIM/modpath/system/etc/fonts.xml" "$SIM/sysroot/system/etc/fonts.xml"
cp -pf "$SIM/modpath/system/fonts/"* "$SIM/sysroot/system/fonts/"
rm -rf "$SIM/modpath/config" "$SIM/modpath/system/etc" "$SIM/modpath/data" "$SIM/modpath/system/fonts/KsuReserved-"*

KSU=true KSU_VER_CODE=30000 \
  FONT_CONFIG_ROOT="$SIM/sysroot" \
  FONT_ADB_ROOT="$SIM/adb" \
  MODPATH="$SIM/modpath" \
  sh "$SIM/modpath/customize.sh" >/dev/null

for orig_f in SysSans-Hans-Regular.ttf SysSans-Hant-Regular.ttf NotoColorEmoji.ttf; do
  res_f="KsuReserved-$orig_f"
  cmp -s "$SIM/modpath/system/fonts/$res_f" "$SIM/adb/modules/ksu_noto_fonts_apple_emoji/system/fonts/$res_f" || \
    fail "upgrade did not preserve $res_f byte-for-byte"
done
python3 -I "$ROOT_DIR/tests/verify_xml.py" \
  "$ROOT_DIR/tests/fixtures/font_fallback.excerpt.xml" \
  "$SIM/modpath/system/etc/font_fallback.xml" \
  --mode fallback
pass "simulated module upgrade verified fingerprint + SHA-256 and reused clean original XMLs and KsuReserved-*.ttf copies"

# 5b-2. Reject upgrade when system build fingerprint changes (OTA update while module was active)
rm -rf "$SIM/modpath/config" "$SIM/modpath/system/etc" "$SIM/modpath/data" "$SIM/modpath/system/fonts/KsuReserved-"*
printf 'ro.system.build.fingerprint=OnePlus/PJZ110/OP5D0DL1:16/BP2A.250605.031.A3/1740000000:user/release-keys\n' \
  > "$SIM/sysroot/system/build.prop"
assert_fails "reject module upgrade when system fingerprint changed after OTA" "system_fingerprint_changed_after_ota_disable_and_reboot" \
  env KSU=true KSU_VER_CODE=30000 \
  FONT_CONFIG_ROOT="$SIM/sysroot" FONT_ADB_ROOT="$SIM/adb" MODPATH="$SIM/modpath" \
  sh "$SIM/modpath/customize.sh"

# Restore matching fingerprint for subsequent upgrade negative tests
printf 'ro.system.build.fingerprint=OnePlus/PJZ110/OP5D0DL1:16/BP2A.250605.031.A3/1730000000:user/release-keys\n' \
  > "$SIM/sysroot/system/build.prop"

# 5b-3. Reject upgrade when a KsuReserved-*.ttf copy is corrupted (SHA-256 mismatch)
printf 'CORRUPTED_BYTES\n' > "$SIM/adb/modules/ksu_noto_fonts_apple_emoji/system/fonts/KsuReserved-SysSans-Hans-Regular.ttf"
assert_fails "reject module upgrade when KsuReserved-*.ttf hash mismatches sha256sums" "corrupted_backup_or_reserved_font_hash_mismatch:fonts/KsuReserved-SysSans-Hans-Regular.ttf" \
  env KSU=true KSU_VER_CODE=30000 \
  FONT_CONFIG_ROOT="$SIM/sysroot" FONT_ADB_ROOT="$SIM/adb" MODPATH="$SIM/modpath" \
  sh "$SIM/modpath/customize.sh"

# 5b-4. Reject upgrade when a KsuReserved-*.ttf copy is missing
rm -f "$SIM/adb/modules/ksu_noto_fonts_apple_emoji/system/fonts/KsuReserved-SysSans-Hans-Regular.ttf"
assert_fails "reject module upgrade when KsuReserved-*.ttf copy is missing" "incomplete_backup_or_reserved_fonts_disable_and_reboot:fonts/KsuReserved-SysSans-Hans-Regular.ttf" \
  env KSU=true KSU_VER_CODE=30000 \
  FONT_CONFIG_ROOT="$SIM/sysroot" FONT_ADB_ROOT="$SIM/adb" MODPATH="$SIM/modpath" \
  sh "$SIM/modpath/customize.sh"

# 5b-5. Reject upgrade when backup fingerprint / sha256sums metadata is missing
rm -f "$SIM/adb/modules/ksu_noto_fonts_apple_emoji/config/original/sha256sums"
assert_fails "reject module upgrade when config/original/sha256sums is missing" "missing_or_untrusted_backup_metadata_disable_and_reboot" \
  env KSU=true KSU_VER_CODE=30000 \
  FONT_CONFIG_ROOT="$SIM/sysroot" FONT_ADB_ROOT="$SIM/adb" MODPATH="$SIM/modpath" \
  sh "$SIM/modpath/customize.sh"

# 5b-5a. Reject fresh install when build.prop is missing or has no fingerprint (no default-system-fingerprint fallback)
setup_sim_env "$SIM"
rm -f "$SIM/sysroot/system/build.prop"
assert_fails "reject fresh install when system/build.prop is missing and no fingerprint is available" "unable_to_read_system_fingerprint" \
  env KSU=true KSU_VER_CODE=30000 \
  FONT_CONFIG_ROOT="$SIM/sysroot" FONT_ADB_ROOT="$SIM/adb" MODPATH="$SIM/modpath" \
  sh "$SIM/modpath/customize.sh"

setup_sim_env "$SIM"
printf 'ro.product.model=PJZ110\nro.system.build.fingerprint=\n' > "$SIM/sysroot/system/build.prop"
assert_fails "reject fresh install when build.prop has empty fingerprint" "unable_to_read_system_fingerprint" \
  env KSU=true KSU_VER_CODE=30000 \
  FONT_CONFIG_ROOT="$SIM/sysroot" FONT_ADB_ROOT="$SIM/adb" MODPATH="$SIM/modpath" \
  sh "$SIM/modpath/customize.sh"

setup_sim_env "$SIM"
printf 'ro.system.build.fingerprint=default-system-fingerprint\n' > "$SIM/sysroot/system/build.prop"
assert_fails "reject fresh install when build.prop contains placeholder default-system-fingerprint" "unable_to_read_system_fingerprint" \
  env KSU=true KSU_VER_CODE=30000 \
  FONT_CONFIG_ROOT="$SIM/sysroot" FONT_ADB_ROOT="$SIM/adb" MODPATH="$SIM/modpath" \
  sh "$SIM/modpath/customize.sh"

assert_fails "reject fresh install when FONT_SYSTEM_FINGERPRINT is placeholder default-system-fingerprint" "unable_to_read_system_fingerprint" \
  env KSU=true KSU_VER_CODE=30000 FONT_SYSTEM_FINGERPRINT="default-system-fingerprint" \
  FONT_CONFIG_ROOT="$SIM/sysroot" FONT_ADB_ROOT="$SIM/adb" MODPATH="$SIM/modpath" \
  sh "$SIM/modpath/customize.sh"

# 5b-5b. Reject upgrade when current system fingerprint is missing or when saved backup fingerprint is placeholder
setup_sim_env "$SIM"
KSU=true KSU_VER_CODE=30000 \
  FONT_CONFIG_ROOT="$SIM/sysroot" FONT_ADB_ROOT="$SIM/adb" MODPATH="$SIM/modpath" \
  sh "$SIM/modpath/customize.sh" >/dev/null
mkdir -p "$SIM/adb/modules/ksu_noto_fonts_apple_emoji"
cp -prf "$SIM/modpath/." "$SIM/adb/modules/ksu_noto_fonts_apple_emoji/"
rm -rf "$SIM/modpath/config" "$SIM/modpath/system/etc" "$SIM/modpath/data" "$SIM/modpath/system/fonts/KsuReserved-"*
rm -f "$SIM/sysroot/system/build.prop"
assert_fails "reject module upgrade when live system fingerprint is unavailable" "unable_to_read_system_fingerprint" \
  env KSU=true KSU_VER_CODE=30000 \
  FONT_CONFIG_ROOT="$SIM/sysroot" FONT_ADB_ROOT="$SIM/adb" MODPATH="$SIM/modpath" \
  sh "$SIM/modpath/customize.sh"

printf 'default-system-fingerprint\n' > "$SIM/adb/modules/ksu_noto_fonts_apple_emoji/config/original/fingerprint"
printf 'ro.system.build.fingerprint=OnePlus/PJZ110/OP5D0DL1:16/BP2A.250605.031.A3/1730000000:user/release-keys\n' \
  > "$SIM/sysroot/system/build.prop"
assert_fails "reject module upgrade when saved backup fingerprint is placeholder default-system-fingerprint" "missing_or_untrusted_backup_metadata_disable_and_reboot" \
  env KSU=true KSU_VER_CODE=30000 \
  FONT_CONFIG_ROOT="$SIM/sysroot" FONT_ADB_ROOT="$SIM/adb" MODPATH="$SIM/modpath" \
  sh "$SIM/modpath/customize.sh"

# 5b-5c. Allow explicit test fingerprint injection when FONT_CONFIG_ROOT is set
setup_sim_env "$SIM"
rm -f "$SIM/sysroot/system/build.prop"
KSU=true KSU_VER_CODE=30000 FONT_SYSTEM_FINGERPRINT="OnePlus/TestInjected/16:user/release-keys" \
  FONT_CONFIG_ROOT="$SIM/sysroot" FONT_ADB_ROOT="$SIM/adb" MODPATH="$SIM/modpath" \
  sh "$SIM/modpath/customize.sh" >/dev/null
[ "$(cat "$SIM/modpath/config/original/fingerprint")" = "OnePlus/TestInjected/16:user/release-keys" ] || \
  fail "explicit test fingerprint injection was not recorded"
pass "rejected missing/placeholder system fingerprints on install & upgrade and verified explicit test fingerprint injection"

# 5b-6. Reject fresh install when trusted original system font is missing in /system/fonts
setup_sim_env "$SIM"
rm -f "$SIM/sysroot/system/fonts/NotoColorEmoji.ttf"
assert_fails "reject fresh install when /system/fonts/NotoColorEmoji.ttf is missing" "missing_trusted_system_font:NotoColorEmoji.ttf" \
  env KSU=true KSU_VER_CODE=30000 \
  FONT_CONFIG_ROOT="$SIM/sysroot" FONT_ADB_ROOT="$SIM/adb" MODPATH="$SIM/modpath" \
  sh "$SIM/modpath/customize.sh"

# 5b-7. Reject fresh install when /system/fonts already contains KsuReserved-* or overlaid module font without backup
setup_sim_env "$SIM"
touch "$SIM/sysroot/system/fonts/KsuReserved-NotoColorEmoji.ttf"
assert_fails "reject fresh install when /system/fonts already contains KsuReserved-NotoColorEmoji.ttf" "live_system_fonts_already_polluted_without_backup:KsuReserved-NotoColorEmoji.ttf" \
  env KSU=true KSU_VER_CODE=30000 \
  FONT_CONFIG_ROOT="$SIM/sysroot" FONT_ADB_ROOT="$SIM/adb" MODPATH="$SIM/modpath" \
  sh "$SIM/modpath/customize.sh"

setup_sim_env "$SIM"
cp -pf "$SIM/modpath/system/fonts/SysSans-Hans-Regular.ttf" "$SIM/sysroot/system/fonts/SysSans-Hans-Regular.ttf"
assert_fails "reject fresh install when live /system/fonts/SysSans-Hans-Regular.ttf matches module payload hash" "live_system_font_already_overlaid_without_backup:SysSans-Hans-Regular.ttf" \
  env KSU=true KSU_VER_CODE=30000 \
  FONT_CONFIG_ROOT="$SIM/sysroot" FONT_ADB_ROOT="$SIM/adb" MODPATH="$SIM/modpath" \
  sh "$SIM/modpath/customize.sh"

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
if [ -d "$SIM/modpath/.staging" ] || [ -d "$SIM/modpath/system/etc" ] || \
   [ -e "$SIM/modpath/system/fonts/KsuReserved-NotoColorEmoji.ttf" ]; then
  fail "second-XML failure left .staging, partial system/etc, or KsuReserved-*.ttf behind"
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
if [ -d "$SIM/modpath/.staging" ] || [ -d "$SIM/modpath/system/etc" ] || \
   [ -e "$SIM/modpath/system/fonts/KsuReserved-NotoColorEmoji.ttf" ]; then
  fail "SIGTERM interruption left .staging, system/etc, or KsuReserved-*.ttf behind"
fi
pass "SIGTERM during second XML transform cleaned up staged first XML and exited cleanly"

# 5t. Reject when bundled font is missing
setup_sim_env "$SIM"
rm -f "$SIM/modpath/system/fonts/NotoSansCJK-Regular.ttc"
assert_fails "reject install when bundled font is missing" "missing_bundled_font:NotoSansCJK-Regular.ttc" \
  env KSU=true KSU_VER_CODE=30000 \
  FONT_CONFIG_ROOT="$SIM/sysroot" FONT_ADB_ROOT="$SIM/adb" MODPATH="$SIM/modpath" \
  sh "$SIM/modpath/customize.sh"

# 5u. 3-XML install with /system_ext/etc/fonts_base.xml + /system/system_ext -> ../system_ext SAR path alias (processed once)
setup_sim_env "$SIM"
mkdir -p "$SIM/sysroot/system_ext/etc"
cp -pf "$ROOT_DIR/tests/fixtures/fonts_base.excerpt.xml" "$SIM/sysroot/system_ext/etc/fonts_base.xml"
ln -s "../system_ext" "$SIM/sysroot/system/system_ext"

KSU=true KSU_VER_CODE=30000 \
  FONT_CONFIG_ROOT="$SIM/sysroot" \
  FONT_ADB_ROOT="$SIM/adb" \
  MODPATH="$SIM/modpath" \
  sh "$SIM/modpath/customize.sh" >/dev/null

[ -f "$SIM/modpath/system/etc/font_fallback.xml" ] || fail "3-XML install: font_fallback.xml not committed"
[ -f "$SIM/modpath/system/etc/fonts.xml" ] || fail "3-XML install: fonts.xml not committed"
[ -f "$SIM/modpath/system/system_ext/etc/fonts_base.xml" ] || fail "3-XML install: system/system_ext/etc/fonts_base.xml not committed"
[ -f "$SIM/modpath/config/original/etc/font_fallback.xml" ] || fail "3-XML install: original/etc/font_fallback.xml missing"
[ -f "$SIM/modpath/config/original/etc/fonts.xml" ] || fail "3-XML install: original/etc/fonts.xml missing"
[ -f "$SIM/modpath/config/original/system_ext/etc/fonts_base.xml" ] || fail "3-XML install: original/system_ext/etc/fonts_base.xml missing"
[ -f "$SIM/modpath/data/base.stats" ] || fail "3-XML install: data/base.stats missing"
[ ! -d "$SIM/modpath/.staging" ] || fail "3-XML install: .staging not cleaned up"
python3 -I "$ROOT_DIR/tests/verify_xml.py" \
  "$ROOT_DIR/tests/fixtures/fonts_base.excerpt.xml" \
  "$SIM/modpath/system/system_ext/etc/fonts_base.xml" \
  --mode base
pass "3-XML install succeeded with /system_ext/etc/fonts_base.xml + /system/system_ext SAR symlink alias"

# 5v. Reverse path alias (/system/system_ext/etc/fonts_base.xml real file + /system_ext -> system/system_ext symlink)
setup_sim_env "$SIM"
mkdir -p "$SIM/sysroot/system/system_ext/etc"
cp -pf "$ROOT_DIR/tests/fixtures/fonts_base.excerpt.xml" "$SIM/sysroot/system/system_ext/etc/fonts_base.xml"
ln -s "system/system_ext" "$SIM/sysroot/system_ext"

KSU=true KSU_VER_CODE=30000 \
  FONT_CONFIG_ROOT="$SIM/sysroot" \
  FONT_ADB_ROOT="$SIM/adb" \
  MODPATH="$SIM/modpath" \
  sh "$SIM/modpath/customize.sh" >/dev/null

python3 -I "$ROOT_DIR/tests/verify_xml.py" \
  "$ROOT_DIR/tests/fixtures/fonts_base.excerpt.xml" \
  "$SIM/modpath/system/system_ext/etc/fonts_base.xml" \
  --mode base
pass "3-XML install succeeded with reverse /system_ext -> system/system_ext symlink alias"

# 5w. Reject when /system_ext/etc/fonts_base.xml and /system/system_ext/etc/fonts_base.xml are two independent copies
setup_sim_env "$SIM"
mkdir -p "$SIM/sysroot/system_ext/etc" "$SIM/sysroot/system/system_ext/etc"
cp -pf "$ROOT_DIR/tests/fixtures/fonts_base.excerpt.xml" "$SIM/sysroot/system_ext/etc/fonts_base.xml"
cp -pf "$ROOT_DIR/tests/fixtures/fonts_base.excerpt.xml" "$SIM/sysroot/system/system_ext/etc/fonts_base.xml"
assert_fails "reject when /system_ext/etc/fonts_base.xml and /system/system_ext/etc/fonts_base.xml are independent copies" "unsupported_partition_font_override:/system_ext/etc/fonts_base.xml" \
  env KSU=true KSU_VER_CODE=30000 \
  FONT_CONFIG_ROOT="$SIM/sysroot" FONT_ADB_ROOT="$SIM/adb" MODPATH="$SIM/modpath" \
  sh "$SIM/modpath/customize.sh"

# 5x. Reject when /system_ext/etc/fonts_base.xml is a symlink to an unknown target or broken symlink
setup_sim_env "$SIM"
mkdir -p "$SIM/sysroot/system_ext/etc" "$SIM/sysroot/vendor_custom"
cp -pf "$ROOT_DIR/tests/fixtures/fonts_base.excerpt.xml" "$SIM/sysroot/vendor_custom/custom_base.xml"
ln -s "../../vendor_custom/custom_base.xml" "$SIM/sysroot/system_ext/etc/fonts_base.xml"
ln -s "../system_ext" "$SIM/sysroot/system/system_ext"
assert_fails "reject when fonts_base.xml is a symlink to an unknown target path" "unsupported_partition_font_override:/system_ext/etc/fonts_base.xml" \
  env KSU=true KSU_VER_CODE=30000 \
  FONT_CONFIG_ROOT="$SIM/sysroot" FONT_ADB_ROOT="$SIM/adb" MODPATH="$SIM/modpath" \
  sh "$SIM/modpath/customize.sh"

setup_sim_env "$SIM"
mkdir -p "$SIM/sysroot/system_ext/etc"
ln -s "nonexistent_target.xml" "$SIM/sysroot/system_ext/etc/fonts_base.xml"
ln -s "../system_ext" "$SIM/sysroot/system/system_ext"
assert_fails "reject when fonts_base.xml is a broken symlink" "unsupported_partition_font_override:/system_ext/etc/fonts_base.xml" \
  env KSU=true KSU_VER_CODE=30000 \
  FONT_CONFIG_ROOT="$SIM/sysroot" FONT_ADB_ROOT="$SIM/adb" MODPATH="$SIM/modpath" \
  sh "$SIM/modpath/customize.sh"

# 5y. Reject when /system_ext/etc/fonts_base.xml exists without /system/system_ext mapping (ambiguous mapping)
setup_sim_env "$SIM"
mkdir -p "$SIM/sysroot/system_ext/etc"
cp -pf "$ROOT_DIR/tests/fixtures/fonts_base.excerpt.xml" "$SIM/sysroot/system_ext/etc/fonts_base.xml"
assert_fails "reject when /system_ext/etc/fonts_base.xml has no /system/system_ext alias mapping" "unsupported_partition_font_override:/system_ext/etc/fonts_base.xml" \
  env KSU=true KSU_VER_CODE=30000 \
  FONT_CONFIG_ROOT="$SIM/sysroot" FONT_ADB_ROOT="$SIM/adb" MODPATH="$SIM/modpath" \
  sh "$SIM/modpath/customize.sh"

# 5z. Reject other /system_ext overrides (/system_ext/etc/fonts.xml and /system_ext/etc/font_fallback.xml)
setup_sim_env "$SIM"
mkdir -p "$SIM/sysroot/system_ext/etc"
touch "$SIM/sysroot/system_ext/etc/fonts.xml"
assert_fails "reject /system_ext/etc/fonts.xml override" "unsupported_partition_font_override:/system_ext/etc/fonts.xml" \
  env KSU=true KSU_VER_CODE=30000 \
  FONT_CONFIG_ROOT="$SIM/sysroot" FONT_ADB_ROOT="$SIM/adb" MODPATH="$SIM/modpath" \
  sh "$SIM/modpath/customize.sh"

setup_sim_env "$SIM"
mkdir -p "$SIM/sysroot/system_ext/etc"
touch "$SIM/sysroot/system_ext/etc/font_fallback.xml"
assert_fails "reject /system_ext/etc/font_fallback.xml override" "unsupported_partition_font_override:/system_ext/etc/font_fallback.xml" \
  env KSU=true KSU_VER_CODE=30000 \
  FONT_CONFIG_ROOT="$SIM/sysroot" FONT_ADB_ROOT="$SIM/adb" MODPATH="$SIM/modpath" \
  sh "$SIM/modpath/customize.sh"

# 5aa. Upgrade from 2-XML backup (has config/original/etc/* + KsuReserved-*.ttf, polluted live /system/etc/*, clean live /system_ext/etc/fonts_base.xml)
setup_sim_env "$SIM"
KSU=true KSU_VER_CODE=30000 \
  FONT_CONFIG_ROOT="$SIM/sysroot" \
  FONT_ADB_ROOT="$SIM/adb" \
  MODPATH="$SIM/modpath" \
  sh "$SIM/modpath/customize.sh" >/dev/null

mkdir -p "$SIM/adb/modules/ksu_noto_fonts_apple_emoji"
cp -prf "$SIM/modpath/." "$SIM/adb/modules/ksu_noto_fonts_apple_emoji/"
cp -pf "$SIM/modpath/system/etc/font_fallback.xml" "$SIM/sysroot/system/etc/font_fallback.xml"
cp -pf "$SIM/modpath/system/etc/fonts.xml" "$SIM/sysroot/system/etc/fonts.xml"
rm -rf "$SIM/modpath/config" "$SIM/modpath/system/etc" "$SIM/modpath/system/system_ext" "$SIM/modpath/data" "$SIM/modpath/system/fonts/KsuReserved-"*

mkdir -p "$SIM/sysroot/system_ext/etc"
cp -pf "$ROOT_DIR/tests/fixtures/fonts_base.excerpt.xml" "$SIM/sysroot/system_ext/etc/fonts_base.xml"
ln -s "../system_ext" "$SIM/sysroot/system/system_ext"

KSU=true KSU_VER_CODE=30000 \
  FONT_CONFIG_ROOT="$SIM/sysroot" \
  FONT_ADB_ROOT="$SIM/adb" \
  MODPATH="$SIM/modpath" \
  sh "$SIM/modpath/customize.sh" >/dev/null

[ -f "$SIM/modpath/config/original/etc/font_fallback.xml" ] || fail "2->3 XML upgrade: missing original/etc/font_fallback.xml"
[ -f "$SIM/modpath/config/original/etc/fonts.xml" ] || fail "2->3 XML upgrade: missing original/etc/fonts.xml"
[ -f "$SIM/modpath/config/original/system_ext/etc/fonts_base.xml" ] || fail "2->3 XML upgrade: missing original/system_ext/etc/fonts_base.xml"
python3 -I "$ROOT_DIR/tests/verify_xml.py" \
  "$ROOT_DIR/tests/fixtures/fonts_base.excerpt.xml" \
  "$SIM/modpath/system/system_ext/etc/fonts_base.xml" \
  --mode base
pass "upgrade from 2-XML verified backup succeeded and captured clean fonts_base.xml backup"

# 5ab. Upgrade from 3-XML backup when all 3 live XMLs already contain adapted markers
rm -rf "$SIM/adb/modules/ksu_noto_fonts_apple_emoji"
mkdir -p "$SIM/adb/modules/ksu_noto_fonts_apple_emoji"
cp -prf "$SIM/modpath/." "$SIM/adb/modules/ksu_noto_fonts_apple_emoji/"
cp -pf "$SIM/modpath/system/system_ext/etc/fonts_base.xml" "$SIM/sysroot/system_ext/etc/fonts_base.xml"
rm -rf "$SIM/modpath/config" "$SIM/modpath/system/etc" "$SIM/modpath/system/system_ext" "$SIM/modpath/data" "$SIM/modpath/system/fonts/KsuReserved-"*

KSU=true KSU_VER_CODE=30000 \
  FONT_CONFIG_ROOT="$SIM/sysroot" \
  FONT_ADB_ROOT="$SIM/adb" \
  MODPATH="$SIM/modpath" \
  sh "$SIM/modpath/customize.sh" >/dev/null

python3 -I "$ROOT_DIR/tests/verify_xml.py" \
  "$ROOT_DIR/tests/fixtures/fonts_base.excerpt.xml" \
  "$SIM/modpath/system/system_ext/etc/fonts_base.xml" \
  --mode base
pass "upgrade from 3-XML backup reused all 3 clean backups and KsuReserved-*.ttf copies without double-patching"

# 5ac. Reject when live /system_ext/etc/fonts_base.xml is polluted and no backup exists
setup_sim_env "$SIM"
mkdir -p "$SIM/sysroot/system_ext/etc"
cp -pf "$TMP_BASE/xml/fonts_base.xml" "$SIM/sysroot/system_ext/etc/fonts_base.xml"
ln -s "../system_ext" "$SIM/sysroot/system/system_ext"
assert_fails "reject polluted live fonts_base.xml when no original backup exists" "live_system_config_already_modified_without_backup" \
  env KSU=true KSU_VER_CODE=30000 \
  FONT_CONFIG_ROOT="$SIM/sysroot" FONT_ADB_ROOT="$SIM/adb" MODPATH="$SIM/modpath" \
  sh "$SIM/modpath/customize.sh"

# 5ad. Staging cleanup when 1st and 2nd XMLs succeed and 3rd XML (fonts_base.xml) fails
setup_sim_env "$SIM"
mkdir -p "$SIM/sysroot/system_ext/etc"
printf '<familyset version="23"><unexpected></familyset>\n' > "$SIM/sysroot/system_ext/etc/fonts_base.xml"
ln -s "../system_ext" "$SIM/sysroot/system/system_ext"
assert_fails "reject install when 1st and 2nd XMLs succeed and 3rd XML (fonts_base.xml) fails" "base_xml_transform_failed" \
  env KSU=true KSU_VER_CODE=30000 \
  FONT_CONFIG_ROOT="$SIM/sysroot" FONT_ADB_ROOT="$SIM/adb" MODPATH="$SIM/modpath" \
  sh "$SIM/modpath/customize.sh"
if [ -d "$SIM/modpath/.staging" ] || [ -d "$SIM/modpath/system/etc" ] || \
   [ -d "$SIM/modpath/system/system_ext" ] || [ -d "$SIM/modpath/config" ] || \
   [ -e "$SIM/modpath/system/fonts/KsuReserved-NotoColorEmoji.ttf" ]; then
  fail "third-XML failure left .staging, system/etc, system/system_ext, config, or KsuReserved-*.ttf behind"
fi
pass "cleaned up .staging and prevented any partial commit when 3rd XML (fonts_base.xml) failed"

# 5ae. Staging cleanup on actual SIGTERM during 3rd XML (mode=base) transformation after 1st and 2nd XMLs are staged
setup_sim_env "$SIM"
mkdir -p "$SIM/sysroot/system_ext/etc"
cp -pf "$ROOT_DIR/tests/fixtures/fonts_base.excerpt.xml" "$SIM/sysroot/system_ext/etc/fonts_base.xml"
ln -s "../system_ext" "$SIM/sysroot/system/system_ext"
mkdir -p "$TMP_BASE/term_base_bin"
cat <<EOF > "$TMP_BASE/term_base_bin/awk"
#!/bin/sh
for arg in "\$@"; do
  if [ "\$arg" = "mode=base" ]; then
    if [ -s "$SIM/modpath/.staging/etc/font_fallback.xml" ] && [ -s "$SIM/modpath/.staging/etc/fonts.xml" ]; then
      touch "$TMP_BASE/saw_staged_first_two_xmls"
    fi
    kill -TERM "\$PPID" 2>/dev/null || :
    exit 143
  fi
done
exec "$REAL_AWK" "\$@"
EOF
chmod 0755 "$TMP_BASE/term_base_bin/awk"

assert_fails "trap SIGTERM during 3rd XML (mode=base) transform and report interrupted" "error=interrupted" \
  env PATH="$TMP_BASE/term_base_bin:$PATH" KSU=true KSU_VER_CODE=30000 \
  FONT_CONFIG_ROOT="$SIM/sysroot" FONT_ADB_ROOT="$SIM/adb" MODPATH="$SIM/modpath" \
  sh "$SIM/modpath/tools/fontconfig.sh" prepare
[ -f "$TMP_BASE/saw_staged_first_two_xmls" ] || fail "SIGTERM 3rd-XML test did not stage first two XMLs before signal"
if [ -d "$SIM/modpath/.staging" ] || [ -d "$SIM/modpath/system/etc" ] || \
   [ -d "$SIM/modpath/system/system_ext" ] || [ -d "$SIM/modpath/config" ] || \
   [ -e "$SIM/modpath/system/fonts/KsuReserved-NotoColorEmoji.ttf" ]; then
  fail "SIGTERM during 3rd XML left .staging, system/etc, system/system_ext, config, or KsuReserved-*.ttf behind"
fi
pass "SIGTERM during 3rd XML (mode=base) transform cleaned up staged files and left zero partial results"

# 5af. BusyBox awk + ash compatibility tests (and full OEM XML validation when root XML files are present)
BB_BIN="${KSU_TEST_BUSYBOX:-}"
if [ -n "$BB_BIN" ]; then
  [ -x "$BB_BIN" ] || fail "KSU_TEST_BUSYBOX is set ($BB_BIN) but not executable"
elif command -v busybox >/dev/null 2>&1; then
  BB_BIN=$(command -v busybox)
elif [ -x /usr/lib/initcpio/busybox ]; then
  BB_BIN="/usr/lib/initcpio/busybox"
fi

if [ -f "$ROOT_DIR/font_fallback.xml" ] || [ -f "$ROOT_DIR/fonts.xml" ] || [ -f "$ROOT_DIR/fonts_base.xml" ]; then
  [ -f "$ROOT_DIR/font_fallback.xml" ] || fail "root OEM XML test: missing $ROOT_DIR/font_fallback.xml"
  [ -f "$ROOT_DIR/fonts.xml" ] || fail "root OEM XML test: missing $ROOT_DIR/fonts.xml"
  [ -f "$ROOT_DIR/fonts_base.xml" ] || fail "root OEM XML test: missing $ROOT_DIR/fonts_base.xml"
  [ -n "$BB_BIN" ] || fail "root OEM XML test requires BusyBox (set KSU_TEST_BUSYBOX or install busybox)"
fi

if [ -n "$BB_BIN" ]; then
  BB_DIR="$TMP_BASE/bb_env"
  mkdir -p "$BB_DIR"
  for applet in sh ash awk sed grep readlink cp mv rm mkdir chmod chown cat head tail cut tr wc ls ln touch printf test true false env sha256sum; do
    ln -sf "$BB_BIN" "$BB_DIR/$applet"
  done
  ln -sf "$BB_BIN" "$BB_DIR/["

  # BusyBox awk vs system awk/gawk parity on synthetic excerpt fixtures
  mkdir -p "$TMP_BASE/bb_fixture_xml"
  for pair in \
    "fallback:$ROOT_DIR/tests/fixtures/font_fallback.excerpt.xml:fb_fix" \
    "legacy:$ROOT_DIR/tests/fixtures/fonts.excerpt.xml:leg_fix" \
    "base:$ROOT_DIR/tests/fixtures/fonts_base.excerpt.xml:base_fix"
  do
    mode=${pair%%:*}
    rest=${pair#*:}
    in_xml=${rest%%:*}
    tag=${rest#*:}
    "$BB_BIN" awk -v mode="$mode" -v stats="$TMP_BASE/bb_fixture_xml/$tag.bb.stats" \
      -f "$ROOT_DIR/module/tools/fontxml.awk" "$in_xml" > "$TMP_BASE/bb_fixture_xml/$tag.bb.xml"
    "$BB_BIN" awk -v mode="$mode" -v validate_only=1 \
      -f "$ROOT_DIR/module/tools/fontxml.awk" "$TMP_BASE/bb_fixture_xml/$tag.bb.xml"
    awk -v mode="$mode" -v stats="$TMP_BASE/bb_fixture_xml/$tag.sys.stats" \
      -f "$ROOT_DIR/module/tools/fontxml.awk" "$in_xml" > "$TMP_BASE/bb_fixture_xml/$tag.sys.xml"
    cmp -s "$TMP_BASE/bb_fixture_xml/$tag.bb.xml" "$TMP_BASE/bb_fixture_xml/$tag.sys.xml" || \
      fail "BusyBox awk vs system awk output mismatch on fixture $tag"
    cmp -s "$TMP_BASE/bb_fixture_xml/$tag.bb.stats" "$TMP_BASE/bb_fixture_xml/$tag.sys.stats" || \
      fail "BusyBox awk vs system awk stats mismatch on fixture $tag"
  done
  pass "BusyBox awk transformation and validate_only match system awk byte-for-byte on all 3 fixtures"

  # BusyBox ash simulated 3-XML installation on fixtures
  setup_sim_env "$SIM"
  mkdir -p "$SIM/sysroot/system_ext/etc"
  cp -pf "$ROOT_DIR/tests/fixtures/fonts_base.excerpt.xml" "$SIM/sysroot/system_ext/etc/fonts_base.xml"
  ln -s "../system_ext" "$SIM/sysroot/system/system_ext"
  PATH="$BB_DIR:$PATH" KSU=true KSU_VER_CODE=30000 \
    FONT_CONFIG_ROOT="$SIM/sysroot" \
    FONT_ADB_ROOT="$SIM/adb" \
    MODPATH="$SIM/modpath" \
    "$BB_BIN" ash "$SIM/modpath/customize.sh" >/dev/null
  cmp -s "$SIM/modpath/system/system_ext/etc/fonts_base.xml" "$TMP_BASE/bb_fixture_xml/base_fix.bb.xml" || \
    fail "BusyBox ash fixture install output mismatch for fonts_base.xml"
  pass "BusyBox ash + BusyBox awk simulated 3-XML installation succeeded on fixtures"

  # Full OEM XML tests (auto-detected when root font_fallback.xml, fonts.xml, fonts_base.xml exist)
  if [ -f "$ROOT_DIR/font_fallback.xml" ] && [ -f "$ROOT_DIR/fonts.xml" ] && [ -f "$ROOT_DIR/fonts_base.xml" ]; then
    OEM_DIR="$TMP_BASE/oem_xml"
    mkdir -p "$OEM_DIR"
    for pair in \
      "fallback:$ROOT_DIR/font_fallback.xml:fb_oem" \
      "legacy:$ROOT_DIR/fonts.xml:leg_oem" \
      "base:$ROOT_DIR/fonts_base.xml:base_oem"
    do
      mode=${pair%%:*}
      rest=${pair#*:}
      in_xml=${rest%%:*}
      tag=${rest#*:}
      "$BB_BIN" awk -v mode="$mode" -v stats="$OEM_DIR/$tag.bb.stats" \
        -f "$ROOT_DIR/module/tools/fontxml.awk" "$in_xml" > "$OEM_DIR/$tag.bb.xml"
      "$BB_BIN" awk -v mode="$mode" -v validate_only=1 \
        -f "$ROOT_DIR/module/tools/fontxml.awk" "$OEM_DIR/$tag.bb.xml"
      awk -v mode="$mode" -v stats="$OEM_DIR/$tag.gawk.stats" \
        -f "$ROOT_DIR/module/tools/fontxml.awk" "$in_xml" > "$OEM_DIR/$tag.gawk.xml"
      cmp -s "$OEM_DIR/$tag.bb.xml" "$OEM_DIR/$tag.gawk.xml" || \
        fail "Full OEM XML ($tag): BusyBox awk vs gawk output mismatch"
      cmp -s "$OEM_DIR/$tag.bb.stats" "$OEM_DIR/$tag.gawk.stats" || \
        fail "Full OEM XML ($tag): BusyBox awk vs gawk stats mismatch"
      python3 -I "$ROOT_DIR/tests/verify_xml.py" "$in_xml" "$OEM_DIR/$tag.bb.xml" --mode "$mode"
    done
    pass "full OEM XMLs (font_fallback.xml, fonts.xml, fonts_base.xml) verified with BusyBox awk, validate_only, gawk parity, and verify_xml.py"

    assert_fails "reject full OEM fonts_base.xml when run in legacy mode" "unexpected_legacy_sans_serif_font|unnamed_western_count_0" \
      "$BB_BIN" awk -v mode="legacy" -v stats="/dev/stderr" -f "$ROOT_DIR/module/tools/fontxml.awk" "$ROOT_DIR/fonts_base.xml"

    assert_fails "reject full OEM fonts.xml when run in base mode" "unexpected_base_sans_serif_font|unexpected_unnamed_western_in_base" \
      "$BB_BIN" awk -v mode="base" -v stats="/dev/stderr" -f "$ROOT_DIR/module/tools/fontxml.awk" "$ROOT_DIR/fonts.xml"

    # Full BusyBox ash simulated installation with the 3 real OEM XMLs and SAR path alias
    OEM_SIM="$TMP_BASE/oem_sim"
    setup_sim_env "$OEM_SIM"
    cp -pf "$ROOT_DIR/font_fallback.xml" "$OEM_SIM/sysroot/system/etc/font_fallback.xml"
    cp -pf "$ROOT_DIR/fonts.xml" "$OEM_SIM/sysroot/system/etc/fonts.xml"
    mkdir -p "$OEM_SIM/sysroot/system_ext/etc"
    cp -pf "$ROOT_DIR/fonts_base.xml" "$OEM_SIM/sysroot/system_ext/etc/fonts_base.xml"
    ln -s "../system_ext" "$OEM_SIM/sysroot/system/system_ext"

    PATH="$BB_DIR:$PATH" KSU=true KSU_VER_CODE=30000 \
      FONT_CONFIG_ROOT="$OEM_SIM/sysroot" \
      FONT_ADB_ROOT="$OEM_SIM/adb" \
      MODPATH="$OEM_SIM/modpath" \
      "$BB_BIN" ash "$OEM_SIM/modpath/customize.sh" >/dev/null

    cmp -s "$OEM_SIM/modpath/system/etc/font_fallback.xml" "$OEM_DIR/fb_oem.bb.xml" || \
      fail "BusyBox ash full OEM install: font_fallback.xml output mismatch"
    cmp -s "$OEM_SIM/modpath/system/etc/fonts.xml" "$OEM_DIR/leg_oem.bb.xml" || \
      fail "BusyBox ash full OEM install: fonts.xml output mismatch"
    cmp -s "$OEM_SIM/modpath/system/system_ext/etc/fonts_base.xml" "$OEM_DIR/base_oem.bb.xml" || \
      fail "BusyBox ash full OEM install: fonts_base.xml output mismatch"
    cmp -s "$OEM_SIM/modpath/config/original/etc/font_fallback.xml" "$ROOT_DIR/font_fallback.xml" || \
      fail "BusyBox ash full OEM install: original font_fallback.xml backup mismatch"
    cmp -s "$OEM_SIM/modpath/config/original/etc/fonts.xml" "$ROOT_DIR/fonts.xml" || \
      fail "BusyBox ash full OEM install: original fonts.xml backup mismatch"
    cmp -s "$OEM_SIM/modpath/config/original/system_ext/etc/fonts_base.xml" "$ROOT_DIR/fonts_base.xml" || \
      fail "BusyBox ash full OEM install: original fonts_base.xml backup mismatch"
    for orig_f in SysSans-Hans-Regular.ttf SysSans-Hant-Regular.ttf NotoColorEmoji.ttf; do
      cmp -s "$OEM_SIM/modpath/system/fonts/KsuReserved-$orig_f" "$OEM_SIM/sysroot/system/fonts/$orig_f" || \
        fail "BusyBox ash full OEM install: KsuReserved-$orig_f mismatch"
    done
    pass "BusyBox ash simulated 3-XML installation succeeded on full OEM XMLs with SAR alias, clean backups, and KsuReserved-*.ttf copies"
  fi
fi

# 6. ZIP verifier negative tests using valid fixture fonts, 4-face TTC, and font-manifest.txt
MINI_DIR="$TMP_BASE/zip_tests"
mkdir -p "$MINI_DIR/cache" "$MINI_DIR/build_fonts"
MINI_LOCK="$MINI_DIR/mini.lock"

python3 -I - "$ROOT_DIR" "$MINI_DIR" "$MINI_LOCK" <<'PYEOF'
import hashlib
import io
import os
import shutil
import struct
import subprocess
import sys
import zipfile

root_dir = sys.argv[1]
base = sys.argv[2]
lock_path = sys.argv[3]
cache_dir = os.path.join(base, "cache")
build_dir = os.path.join(base, "build_fonts")

sys.path.insert(0, os.path.join(root_dir, "tools"))
from fontTools.fontBuilder import FontBuilder
from fontTools.pens.ttGlyphPen import TTGlyphPen
from fontTools.ttLib import TTCollection, TTFont, newTable
from fontTools.ttLib.tables._c_m_a_p import CmapSubtable
import check_fonts as cf


def sha256_bytes(b: bytes) -> str:
    return hashlib.sha256(b).hexdigest().lower()


def build_vf_ttf(
    family,
    subfamily,
    ps_name,
    axes_spec,
    min_glyphs,
    codepoints,
    reg_idx=None,
    extra_box=200,
    drop_cp=None,
):
    fb = FontBuilder(1000, isTTF=True)
    glyph_order = [".notdef", "g_base", "g_reg0", "g_reg1", "g_reg2", "g_reg3"]
    fb.setupGlyphOrder(glyph_order)
    pen = TTGlyphPen(None)
    pen.moveTo((100, 0))
    pen.lineTo((100, extra_box))
    pen.lineTo((600, extra_box))
    pen.lineTo((600, 0))
    pen.closePath()
    g = pen.glyph()
    fb.setupGlyf({gn: g for gn in glyph_order})

    cmap_dict = {cp: "g_base" for cp in range(0x20000, 0x20000 + min_glyphs + 5)}
    cmap_dict[0x4E00] = "g_base"
    for cp in codepoints:
        cmap_dict[cp] = "g_base"
    if reg_idx is not None:
        cmap_dict[0x9AA8] = f"g_reg{reg_idx}"
    if drop_cp is not None:
        cmap_dict.pop(drop_cp, None)

    st = CmapSubtable.newSubtable(12)
    st.platformID = 3
    st.platEncID = 10
    st.language = 0
    st.cmap = cmap_dict
    fb.font["cmap"] = newTable("cmap")
    fb.font["cmap"].tableVersion = 0
    fb.font["cmap"].tables = [st]

    fb.setupHorizontalMetrics({gn: (600, 100) for gn in glyph_order})
    fb.setupHorizontalHeader(ascent=800, descent=-200)
    fb.setupNameTable(
        {
            "familyName": family,
            "styleName": subfamily,
            "psName": ps_name,
            "uniqueFontIdentifier": ps_name,
            "fullName": f"{family} {subfamily}",
            "version": "Version 1.0",
        }
    )
    fb.setupOS2()
    fb.setupPost()
    fvar_axes = [(tag, mn, df, mx, tag) for tag, (mn, df, mx) in axes_spec.items()]
    fb.setupFvar(axes=fvar_axes, instances=[])

    font = fb.font
    for tag in ("GSUB", "GPOS"):
        t = newTable(tag)
        t.decompile(b"\x00\x01\x00\x00\x00\x0a\x00\x0c\x00\x0e\x00\x00\x00\x00\x00\x00", font)
        font[tag] = t

    hvar = newTable("HVAR")
    axis_cnt = len(axes_spec)
    hvar_raw = (
        b"\x00\x01\x00\x00"
        b"\x00\x00\x00\x14"
        b"\x00\x00\x00\x00"
        b"\x00\x00\x00\x00"
        b"\x00\x00\x00\x00"
        b"\x00\x01"
        b"\x00\x00\x00\x08"
        b"\x00\x00"
        + axis_cnt.to_bytes(2, "big")
        + b"\x00\x00"
    )
    hvar.decompile(hvar_raw, font)
    font["HVAR"] = hvar

    gvar = newTable("gvar")
    gvar.version = 1
    gvar.reserved = 0
    gvar.variations = {gn: [] for gn in glyph_order}
    font["gvar"] = gvar

    buf = io.BytesIO()
    font.save(buf, reorderTables=False)
    return buf.getvalue()


latin_reg_spec = cf.EXPECTED_TTF_SPECS["Roboto-Regular.ttf"]
latin_ita_spec = cf.EXPECTED_TTF_SPECS["NotoSans-Italic.ttf"]
emoji_spec = cf.EXPECTED_TTF_SPECS["NotoColorEmoji.ttf"]

upstream_blobs = {
    "KSU-NotoSans-Regular-VF.ttf": build_vf_ttf(
        latin_reg_spec["family"],
        latin_reg_spec["subfamily"],
        "NotoSans-Regular",
        latin_reg_spec["axes"],
        latin_reg_spec["min_glyphs"],
        latin_reg_spec["codepoints"],
    ),
    "KSU-NotoSans-Italic-VF.ttf": build_vf_ttf(
        latin_ita_spec["family"],
        latin_ita_spec["subfamily"],
        "NotoSans-Italic",
        latin_ita_spec["axes"],
        latin_ita_spec["min_glyphs"],
        latin_ita_spec["codepoints"],
    ),
    "KSU-AppleColorEmoji.ttf": b"EMOJI_FIXTURE_PAYLOAD\n",
}

for spec in cf.TTC_FACE_SPECS:
    upstream_blobs[spec["upstream"]] = build_vf_ttf(
        spec["family"],
        spec["subfamily"],
        spec["ps_prefix"] + "VF",
        spec["axes"],
        spec["min_glyphs"],
        spec["codepoints"],
        reg_idx=spec["index"],
    )

licenses = {
    "OFL-NotoSans.txt": b"OFL NotoSans\n",
    "OFL-NotoSansCJK.txt": b"OFL NotoSansCJK\n",
    "LICENSE-apple-emoji-ttf.txt": b"MIT Apple Emoji\n",
}

lock_lines = []
for name, data in sorted(upstream_blobs.items()):
    with open(os.path.join(cache_dir, name), "wb") as fh:
        fh.write(data)
    lock_lines.append(f"font|{name}|test@1|https://example.invalid/{name}|{sha256_bytes(data)}")

for name, data in sorted(licenses.items()):
    with open(os.path.join(cache_dir, name), "wb") as fh:
        fh.write(data)
    lock_lines.append(f"license|{name}|test@1|https://example.invalid/{name}|{sha256_bytes(data)}")

with open(lock_path, "w", encoding="utf-8", newline="\n") as lf:
    lf.write("\n".join(lock_lines) + "\n")

subprocess.run(
    [sys.executable, "-I", os.path.join(root_dir, "tools", "make_fonts.py"), cache_dir, build_dir, "--lock", lock_path],
    check=True,
    stdout=subprocess.DEVNULL,
)


def make_zip(path, entries):
    with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_STORED) as zf:
        for k in sorted(entries.keys()):
            zf.writestr(k, entries[k])


valid_prop = (
    b"id=ksu_noto_fonts_apple_emoji\n"
    b"name=Noto Sans + Noto Sans CJK + Apple Emoji (OOS16)\n"
    b"version=v1.0.2\n"
    b"versionCode=102\n"
    b"author=wang1zhen\n"
    b"description=Test\n"
)

valid_entries = {
    "module.prop": valid_prop,
    "customize.sh": b"#!/system/bin/sh\n",
    "NOTICE.md": b"notice\n",
    "tools/fontconfig.sh": b"#!/system/bin/sh\n",
    "tools/fontxml.awk": b"BEGIN {}\n",
}
for lic_name, lic_data in licenses.items():
    valid_entries[f"licenses/{lic_name}"] = lic_data
for fname in os.listdir(build_dir):
    with open(os.path.join(build_dir, fname), "rb") as fh:
        data = fh.read()
    if fname == cf.MANIFEST_FILENAME:
        valid_entries[fname] = data
    else:
        valid_entries[f"system/fonts/{fname}"] = data

make_zip(f"{base}/valid.zip", valid_entries)
make_zip(f"{base}/ksu-noto-fonts-apple-emoji-v1.0.2.zip", valid_entries)
make_zip(f"{base}/ksu-noto-fonts-apple-emoji-v1.0.1.zip", valid_entries)

missing_entries = dict(valid_entries)
del missing_entries["tools/fontxml.awk"]
make_zip(f"{base}/missing.zip", missing_entries)

missing_manifest = dict(valid_entries)
del missing_manifest["font-manifest.txt"]
make_zip(f"{base}/missing_manifest.zip", missing_manifest)

bad_hash_entries = dict(valid_entries)
bad_hash_entries["system/fonts/Roboto-Regular.ttf"] = b"tampered\n"
make_zip(f"{base}/bad_hash.zip", bad_hash_entries)

traversal_entries = dict(valid_entries)
traversal_entries["../evil.sh"] = b"evil\n"
make_zip(f"{base}/traversal.zip", traversal_entries)

prebaked_entries = dict(valid_entries)
prebaked_entries["system/etc/fonts.xml"] = b"<familyset/>\n"
make_zip(f"{base}/prebaked.zip", prebaked_entries)

prebaked_base_entries = dict(valid_entries)
prebaked_base_entries["system/system_ext/etc/fonts_base.xml"] = b"<familyset/>\n"
make_zip(f"{base}/prebaked_base.zip", prebaked_base_entries)

leaked_log_entries = dict(valid_entries)
leaked_log_entries["KernelSU_Next_install_log.log"] = b"log\n"
make_zip(f"{base}/leaked_log.zip", leaked_log_entries)

reserved_leak_entries = dict(valid_entries)
reserved_leak_entries["system/fonts/KsuReserved-NotoColorEmoji.ttf"] = b"reserved\n"
make_zip(f"{base}/reserved_leak.zip", reserved_leak_entries)

legacy_ksu_entries = dict(valid_entries)
legacy_ksu_entries["system/fonts/KSU-NotoSans-Regular-VF.ttf"] = b"legacy\n"
make_zip(f"{base}/legacy_ksu.zip", legacy_ksu_entries)

bad_author_entries = dict(valid_entries)
bad_author_entries["module.prop"] = valid_prop.replace(b"author=wang1zhen", b"author=wrong")
make_zip(f"{base}/bad_author.zip", bad_author_entries)

no_version_entries = dict(valid_entries)
no_version_entries["module.prop"] = valid_prop.replace(b"version=v1.0.2\n", b"")
make_zip(f"{base}/no_version.zip", no_version_entries)

with open(f"{base}/corrupt.zip", "wb") as f:
    f.write(b"not a zip file at all")


def rewrite_manifest_ttc_sha(manifest_bytes: bytes, new_ttc_sha: str) -> bytes:
    lines = []
    for line in manifest_bytes.decode("utf-8").splitlines():
        if line.startswith("generated_ttc|system/fonts/NotoSansCJK-Regular.ttc|"):
            parts = line.split("|")
            parts[4] = new_ttc_sha
            line = "|".join(parts)
        lines.append(line)
    return ("\n".join(lines) + "\n").encode("utf-8")


def stage_custom_ttc_case(case_name: str, fake_ttc: bytes):
    case_build = os.path.join(base, f"build_{case_name}")
    shutil.copytree(build_dir, case_build)
    fake_sha = sha256_bytes(fake_ttc)
    new_manifest = rewrite_manifest_ttc_sha(valid_entries["font-manifest.txt"], fake_sha)
    with open(os.path.join(case_build, cf.TTC_FILENAME), "wb") as fh:
        fh.write(fake_ttc)
    with open(os.path.join(case_build, cf.MANIFEST_FILENAME), "wb") as fh:
        fh.write(new_manifest)
    entries = dict(valid_entries)
    entries["system/fonts/NotoSansCJK-Regular.ttc"] = fake_ttc
    entries["font-manifest.txt"] = new_manifest
    make_zip(f"{base}/{case_name}.zip", entries)


# B2-1: 28-byte valid ttcf header + 4 faces + all zeros (both raw in ZIP and with matching manifest/build_dir)
fake_header_zeros = b"ttcf" + struct.pack(">HHI4I", 1, 0, 4, 28, 60, 92, 124) + b"\x00" * 256
raw_header_zeros_entries = dict(valid_entries)
raw_header_zeros_entries["system/fonts/NotoSansCJK-Regular.ttc"] = fake_header_zeros
make_zip(f"{base}/ttc_header_zeros_raw.zip", raw_header_zeros_entries)
stage_custom_ttc_case("ttc_header_zeros", fake_header_zeros)

# B2-2: Valid TTC header + SFNT face headers + corrupted/zeroed body in the middle of the TTC
orig_ttc = valid_entries["system/fonts/NotoSansCJK-Regular.ttc"]
corrupt_body_ttc = bytearray(orig_ttc)
# Zero out everything from offset 200 to the end so header and face offset table remain intact
corrupt_body_ttc[200:] = b"\x00" * (len(corrupt_body_ttc) - 200)
stage_custom_ttc_case("ttc_corrupt_body", bytes(corrupt_body_ttc))

# B2-3: Tampered 4-face TTC where face 0 is SC instead of JP (wrong region/family/U+9AA8)
sc_font_bytes = upstream_blobs["KSU-NotoSansCJKsc-VF.ttf"]
wrong_region_fonts = [
    TTFont(io.BytesIO(sc_font_bytes), lazy=True, recalcTimestamp=False),
    TTFont(io.BytesIO(upstream_blobs["KSU-NotoSansCJKkr-VF.ttf"]), lazy=True, recalcTimestamp=False),
    TTFont(io.BytesIO(sc_font_bytes), lazy=True, recalcTimestamp=False),
    TTFont(io.BytesIO(upstream_blobs["KSU-NotoSansCJKtc-VF.ttf"]), lazy=True, recalcTimestamp=False),
]
wrong_ttc = TTCollection()
wrong_ttc.fonts = wrong_region_fonts
wrong_ttc_buf = io.BytesIO()
wrong_ttc.save(wrong_ttc_buf, shareTables=True)
stage_custom_ttc_case("ttc_wrong_region", wrong_ttc_buf.getvalue())

# B2-4: Tampered 4-face TTC where all 4 faces have valid specs/names/axes, but face 2's glyf table
# differs from the locked SysSans-Hans-Regular.ttf source font
alt_cjk_fonts = [
    TTFont(
        io.BytesIO(
            build_vf_ttf(
                s["family"],
                s["subfamily"],
                s["ps_prefix"] + "VF",
                s["axes"],
                s["min_glyphs"],
                s["codepoints"],
                reg_idx=s["index"],
                extra_box=550,  # altered glyph outline vs locked source TTF
            )
        ),
        lazy=True,
        recalcTimestamp=False,
    )
    for s in cf.TTC_FACE_SPECS
]
alt_ttc = TTCollection()
alt_ttc.fonts = alt_cjk_fonts
alt_ttc_buf = io.BytesIO()
alt_ttc.save(alt_ttc_buf, shareTables=True)
stage_custom_ttc_case("ttc_table_mismatch", alt_ttc_buf.getvalue())

# B2-4b: Tampered 4-face TTC where face 0 (JP) drops U+4E00 from cmap while keeping all
# representative codepoints, min_glyphs, shared tables, and synced manifest/build hashes
jp_spec = cf.TTC_FACE_SPECS[0]
jp_drop_u4e00_bytes = build_vf_ttf(
    jp_spec["family"],
    jp_spec["subfamily"],
    jp_spec["ps_prefix"] + "VF",
    jp_spec["axes"],
    jp_spec["min_glyphs"],
    jp_spec["codepoints"],
    reg_idx=jp_spec["index"],
    drop_cp=0x4E00,
)
jp_cmap_drop_fonts = [
    TTFont(io.BytesIO(jp_drop_u4e00_bytes), lazy=True, recalcTimestamp=False),
    TTFont(io.BytesIO(upstream_blobs["KSU-NotoSansCJKkr-VF.ttf"]), lazy=True, recalcTimestamp=False),
    TTFont(io.BytesIO(upstream_blobs["KSU-NotoSansCJKsc-VF.ttf"]), lazy=True, recalcTimestamp=False),
    TTFont(io.BytesIO(upstream_blobs["KSU-NotoSansCJKtc-VF.ttf"]), lazy=True, recalcTimestamp=False),
]
jp_cmap_drop_ttc = TTCollection()
jp_cmap_drop_ttc.fonts = jp_cmap_drop_fonts
jp_cmap_drop_buf = io.BytesIO()
jp_cmap_drop_ttc.save(jp_cmap_drop_buf, shareTables=True)
stage_custom_ttc_case("ttc_jp_cmap_drop", jp_cmap_drop_buf.getvalue())

# B2-5: Manifest inconsistencies (bad source hash, bad artifact hash, unsorted manifest)
bad_src_manifest_entries = dict(valid_entries)
bad_src_manifest_entries["font-manifest.txt"] = valid_entries["font-manifest.txt"].replace(
    sha256_bytes(upstream_blobs["KSU-NotoSans-Regular-VF.ttf"]).encode("utf-8"),
    b"0" * 64,
    1,
)
make_zip(f"{base}/manifest_bad_src_sha.zip", bad_src_manifest_entries)

bad_art_manifest_entries = dict(valid_entries)
bad_art_manifest_entries["font-manifest.txt"] = rewrite_manifest_ttc_sha(
    valid_entries["font-manifest.txt"], "f" * 64
)
make_zip(f"{base}/manifest_bad_art_sha.zip", bad_art_manifest_entries)

unsorted_lines = [
    ln
    for ln in valid_entries["font-manifest.txt"].decode("utf-8").splitlines()
    if ln and not ln.startswith("#")
]
unsorted_lines.reverse()
unsorted_manifest_entries = dict(valid_entries)
unsorted_manifest_entries["font-manifest.txt"] = ("\n".join(unsorted_lines) + "\n").encode("utf-8")
make_zip(f"{base}/manifest_unsorted.zip", unsorted_manifest_entries)
PYEOF

# Prepare negative cache directories (missing JP, missing KR, corrupted JP, corrupted KR)
cp -prf "$MINI_DIR/cache" "$MINI_DIR/cache_no_jp"
rm -f "$MINI_DIR/cache_no_jp/KSU-NotoSansCJKjp-VF.ttf"

cp -prf "$MINI_DIR/cache" "$MINI_DIR/cache_no_kr"
rm -f "$MINI_DIR/cache_no_kr/KSU-NotoSansCJKkr-VF.ttf"

cp -prf "$MINI_DIR/cache" "$MINI_DIR/cache_bad_jp"
printf 'CORRUPTED_JP_CACHE\n' > "$MINI_DIR/cache_bad_jp/KSU-NotoSansCJKjp-VF.ttf"

cp -prf "$MINI_DIR/cache" "$MINI_DIR/cache_bad_kr"
printf 'CORRUPTED_KR_CACHE\n' > "$MINI_DIR/cache_bad_kr/KSU-NotoSansCJKkr-VF.ttf"

FONT_LOCK_FILE="$MINI_LOCK" FONT_BUILD_DIR="$MINI_DIR/build_fonts" FONT_CACHE_DIR="$MINI_DIR/cache" \
  sh "$ROOT_DIR/scripts/verify_zip.sh" "$MINI_DIR/valid.zip" >/dev/null
FONT_LOCK_FILE="$MINI_LOCK" FONT_BUILD_DIR="$MINI_DIR/build_fonts" FONT_CACHE_DIR="$MINI_DIR/cache" \
  sh "$ROOT_DIR/scripts/verify_zip.sh" "$MINI_DIR/ksu-noto-fonts-apple-emoji-v1.0.2.zip" >/dev/null
pass "verify_zip.sh accepted valid synthetic ZIP with 4-face TTC + font-manifest.txt and matching v1.0.2 filename"

assert_fails "verify_zip.sh rejects missing required file" "missing required files" \
  env FONT_LOCK_FILE="$MINI_LOCK" FONT_BUILD_DIR="$MINI_DIR/build_fonts" FONT_CACHE_DIR="$MINI_DIR/cache" \
  sh "$ROOT_DIR/scripts/verify_zip.sh" "$MINI_DIR/missing.zip"

assert_fails "verify_zip.sh rejects missing font-manifest.txt in ZIP" "missing required files" \
  env FONT_LOCK_FILE="$MINI_LOCK" FONT_BUILD_DIR="$MINI_DIR/build_fonts" FONT_CACHE_DIR="$MINI_DIR/cache" \
  sh "$ROOT_DIR/scripts/verify_zip.sh" "$MINI_DIR/missing_manifest.zip"

assert_fails "verify_zip.sh rejects tampered font SHA-256" "packaged font bytes mismatch|SHA-256 mismatch" \
  env FONT_LOCK_FILE="$MINI_LOCK" FONT_BUILD_DIR="$MINI_DIR/build_fonts" FONT_CACHE_DIR="$MINI_DIR/cache" \
  sh "$ROOT_DIR/scripts/verify_zip.sh" "$MINI_DIR/bad_hash.zip"

assert_fails "verify_zip.sh rejects 28-byte valid TTC header + 4 faces + all zeros (raw replacement)" "invalid TTC payload" \
  env FONT_LOCK_FILE="$MINI_LOCK" FONT_BUILD_DIR="$MINI_DIR/build_fonts" FONT_CACHE_DIR="$MINI_DIR/cache" \
  sh "$ROOT_DIR/scripts/verify_zip.sh" "$MINI_DIR/ttc_header_zeros_raw.zip"

assert_fails "verify_zip.sh rejects 28-byte valid TTC header + 4 faces + all zeros even when manifest & build_dir match its hash" "invalid TTC payload" \
  env FONT_LOCK_FILE="$MINI_LOCK" FONT_BUILD_DIR="$MINI_DIR/build_ttc_header_zeros" FONT_CACHE_DIR="$MINI_DIR/cache" \
  sh "$ROOT_DIR/scripts/verify_zip.sh" "$MINI_DIR/ttc_header_zeros.zip"

assert_fails "verify_zip.sh rejects TTC with valid header and zeroed/corrupted body even when manifest & build_dir match" "invalid TTC payload" \
  env FONT_LOCK_FILE="$MINI_LOCK" FONT_BUILD_DIR="$MINI_DIR/build_ttc_corrupt_body" FONT_CACHE_DIR="$MINI_DIR/cache" \
  sh "$ROOT_DIR/scripts/verify_zip.sh" "$MINI_DIR/ttc_corrupt_body.zip"

assert_fails "verify_zip.sh rejects tampered 4-face TTC with wrong face region/family even when manifest & build_dir match" "invalid TTC payload.*family name mismatch" \
  env FONT_LOCK_FILE="$MINI_LOCK" FONT_BUILD_DIR="$MINI_DIR/build_ttc_wrong_region" FONT_CACHE_DIR="$MINI_DIR/cache" \
  sh "$ROOT_DIR/scripts/verify_zip.sh" "$MINI_DIR/ttc_wrong_region.zip"

assert_fails "verify_zip.sh rejects tampered 4-face TTC whose glyf table mismatches locked source TTF even when manifest matches" "invalid TTC payload.*table 'glyf' bytes mismatch vs source TTF" \
  env FONT_LOCK_FILE="$MINI_LOCK" FONT_BUILD_DIR="$MINI_DIR/build_ttc_table_mismatch" FONT_CACHE_DIR="$MINI_DIR/cache" \
  sh "$ROOT_DIR/scripts/verify_zip.sh" "$MINI_DIR/ttc_table_mismatch.zip"

assert_fails "verify_zip.sh rejects tampered 4-face TTC dropping JP U+4E00 from cmap even when manifest & build_dir match" "invalid TTC payload.*NotoSansCJK-Regular\.ttc\[0\]: table 'cmap' bytes mismatch vs source TTF" \
  env FONT_LOCK_FILE="$MINI_LOCK" FONT_BUILD_DIR="$MINI_DIR/build_ttc_jp_cmap_drop" FONT_CACHE_DIR="$MINI_DIR/cache" \
  sh "$ROOT_DIR/scripts/verify_zip.sh" "$MINI_DIR/ttc_jp_cmap_drop.zip"

assert_fails "verify_zip.sh rejects valid ZIP when cached JP source font (KSU-NotoSansCJKjp-VF.ttf) is missing" "missing required cached CJK source font for TTC face 0 \(KSU-NotoSansCJKjp-VF\.ttf\)" \
  env FONT_LOCK_FILE="$MINI_LOCK" FONT_BUILD_DIR="$MINI_DIR/build_fonts" FONT_CACHE_DIR="$MINI_DIR/cache_no_jp" \
  sh "$ROOT_DIR/scripts/verify_zip.sh" "$MINI_DIR/valid.zip"

assert_fails "verify_zip.sh rejects valid ZIP when cached KR source font (KSU-NotoSansCJKkr-VF.ttf) is missing" "missing required cached CJK source font for TTC face 1 \(KSU-NotoSansCJKkr-VF\.ttf\)" \
  env FONT_LOCK_FILE="$MINI_LOCK" FONT_BUILD_DIR="$MINI_DIR/build_fonts" FONT_CACHE_DIR="$MINI_DIR/cache_no_kr" \
  sh "$ROOT_DIR/scripts/verify_zip.sh" "$MINI_DIR/valid.zip"

assert_fails "verify_zip.sh rejects valid ZIP when cached JP source font (KSU-NotoSansCJKjp-VF.ttf) fails SHA-256 check" "SHA-256 mismatch for cached CJK source font for TTC face 0 \(KSU-NotoSansCJKjp-VF\.ttf\)" \
  env FONT_LOCK_FILE="$MINI_LOCK" FONT_BUILD_DIR="$MINI_DIR/build_fonts" FONT_CACHE_DIR="$MINI_DIR/cache_bad_jp" \
  sh "$ROOT_DIR/scripts/verify_zip.sh" "$MINI_DIR/valid.zip"

assert_fails "verify_zip.sh rejects valid ZIP when cached KR source font (KSU-NotoSansCJKkr-VF.ttf) fails SHA-256 check" "SHA-256 mismatch for cached CJK source font for TTC face 1 \(KSU-NotoSansCJKkr-VF\.ttf\)" \
  env FONT_LOCK_FILE="$MINI_LOCK" FONT_BUILD_DIR="$MINI_DIR/build_fonts" FONT_CACHE_DIR="$MINI_DIR/cache_bad_kr" \
  sh "$ROOT_DIR/scripts/verify_zip.sh" "$MINI_DIR/valid.zip"

assert_fails "check_fonts.py rejects when cached JP source font (KSU-NotoSansCJKjp-VF.ttf) is missing" "NotoSansCJK-Regular\.ttc\[0\]: missing cached CJK source font KSU-NotoSansCJKjp-VF\.ttf" \
  env FONT_CACHE_DIR="$MINI_DIR/cache_no_jp" \
  python3 -I "$ROOT_DIR/tools/check_fonts.py" "$MINI_DIR/build_fonts" --lock "$MINI_LOCK"

assert_fails "check_fonts.py rejects when cached KR source font (KSU-NotoSansCJKkr-VF.ttf) is missing" "NotoSansCJK-Regular\.ttc\[1\]: missing cached CJK source font KSU-NotoSansCJKkr-VF\.ttf" \
  env FONT_CACHE_DIR="$MINI_DIR/cache_no_kr" \
  python3 -I "$ROOT_DIR/tools/check_fonts.py" "$MINI_DIR/build_fonts" --lock "$MINI_LOCK"

assert_fails "check_fonts.py rejects when cached JP source font (KSU-NotoSansCJKjp-VF.ttf) fails SHA-256 check" "NotoSansCJK-Regular\.ttc\[0\]: SHA-256 mismatch for cached CJK source font KSU-NotoSansCJKjp-VF\.ttf" \
  env FONT_CACHE_DIR="$MINI_DIR/cache_bad_jp" \
  python3 -I "$ROOT_DIR/tools/check_fonts.py" "$MINI_DIR/build_fonts" --lock "$MINI_LOCK"

assert_fails "check_fonts.py rejects when cached KR source font (KSU-NotoSansCJKkr-VF.ttf) fails SHA-256 check" "NotoSansCJK-Regular\.ttc\[1\]: SHA-256 mismatch for cached CJK source font KSU-NotoSansCJKkr-VF\.ttf" \
  env FONT_CACHE_DIR="$MINI_DIR/cache_bad_kr" \
  python3 -I "$ROOT_DIR/tools/check_fonts.py" "$MINI_DIR/build_fonts" --lock "$MINI_LOCK"

assert_fails "check_fonts.py rejects tampered 4-face TTC dropping JP U+4E00 from cmap when cache is present" "NotoSansCJK-Regular\.ttc\[0\]: table 'cmap' bytes mismatch vs source TTF" \
  env FONT_CACHE_DIR="$MINI_DIR/cache" \
  python3 -I "$ROOT_DIR/tools/check_fonts.py" "$MINI_DIR/build_ttc_jp_cmap_drop" --lock "$MINI_LOCK"

assert_fails "verify_zip.sh rejects font-manifest.txt with tampered upstream_source_sha256" "invalid font-manifest.txt in archive.*upstream_source_sha256" \
  env FONT_LOCK_FILE="$MINI_LOCK" FONT_BUILD_DIR="$MINI_DIR/build_fonts" FONT_CACHE_DIR="$MINI_DIR/cache" \
  sh "$ROOT_DIR/scripts/verify_zip.sh" "$MINI_DIR/manifest_bad_src_sha.zip"

assert_fails "verify_zip.sh rejects font-manifest.txt with tampered TTC artifact_sha256" "invalid font-manifest.txt in archive.*artifact_sha256" \
  env FONT_LOCK_FILE="$MINI_LOCK" FONT_BUILD_DIR="$MINI_DIR/build_fonts" FONT_CACHE_DIR="$MINI_DIR/cache" \
  sh "$ROOT_DIR/scripts/verify_zip.sh" "$MINI_DIR/manifest_bad_art_sha.zip"

assert_fails "verify_zip.sh rejects font-manifest.txt when entries are not in canonical sorted order" "invalid font-manifest.txt in archive.*canonical sorted order" \
  env FONT_LOCK_FILE="$MINI_LOCK" FONT_BUILD_DIR="$MINI_DIR/build_fonts" FONT_CACHE_DIR="$MINI_DIR/cache" \
  sh "$ROOT_DIR/scripts/verify_zip.sh" "$MINI_DIR/manifest_unsorted.zip"

assert_fails "verify_zip.sh rejects when ZIP font/manifest bytes differ from validated build directory" "packaged font bytes mismatch|does not match validated" \
  env FONT_LOCK_FILE="$MINI_LOCK" FONT_BUILD_DIR="$MINI_DIR/build_ttc_table_mismatch" FONT_CACHE_DIR="$MINI_DIR/cache" \
  sh "$ROOT_DIR/scripts/verify_zip.sh" "$MINI_DIR/valid.zip"

assert_fails "verify_zip.sh rejects path traversal entry" "unsafe relative path traversal" \
  env FONT_LOCK_FILE="$MINI_LOCK" FONT_BUILD_DIR="$MINI_DIR/build_fonts" FONT_CACHE_DIR="$MINI_DIR/cache" \
  sh "$ROOT_DIR/scripts/verify_zip.sh" "$MINI_DIR/traversal.zip"

assert_fails "verify_zip.sh rejects pre-baked system/etc XML" "pre-baked system/etc config" \
  env FONT_LOCK_FILE="$MINI_LOCK" FONT_BUILD_DIR="$MINI_DIR/build_fonts" FONT_CACHE_DIR="$MINI_DIR/cache" \
  sh "$ROOT_DIR/scripts/verify_zip.sh" "$MINI_DIR/prebaked.zip"

assert_fails "verify_zip.sh rejects pre-baked system/system_ext/etc/fonts_base.xml" "pre-baked system/etc config or device XML/log is forbidden" \
  env FONT_LOCK_FILE="$MINI_LOCK" FONT_BUILD_DIR="$MINI_DIR/build_fonts" FONT_CACHE_DIR="$MINI_DIR/cache" \
  sh "$ROOT_DIR/scripts/verify_zip.sh" "$MINI_DIR/prebaked_base.zip"

assert_fails "verify_zip.sh rejects leaked install log in ZIP" "pre-baked system/etc config or device XML/log is forbidden" \
  env FONT_LOCK_FILE="$MINI_LOCK" FONT_BUILD_DIR="$MINI_DIR/build_fonts" FONT_CACHE_DIR="$MINI_DIR/cache" \
  sh "$ROOT_DIR/scripts/verify_zip.sh" "$MINI_DIR/leaked_log.zip"

assert_fails "verify_zip.sh rejects leaked KsuReserved-* font in ZIP" "reserved OEM system font copy is forbidden in public ZIP" \
  env FONT_LOCK_FILE="$MINI_LOCK" FONT_BUILD_DIR="$MINI_DIR/build_fonts" FONT_CACHE_DIR="$MINI_DIR/cache" \
  sh "$ROOT_DIR/scripts/verify_zip.sh" "$MINI_DIR/reserved_leak.zip"

assert_fails "verify_zip.sh rejects legacy KSU-* font in ZIP" "legacy KSU-\\* font filename is forbidden in v1.0.2 ZIP" \
  env FONT_LOCK_FILE="$MINI_LOCK" FONT_BUILD_DIR="$MINI_DIR/build_fonts" FONT_CACHE_DIR="$MINI_DIR/cache" \
  sh "$ROOT_DIR/scripts/verify_zip.sh" "$MINI_DIR/legacy_ksu.zip"

assert_fails "verify_zip.sh rejects wrong author in module.prop" "invalid module.prop author=" \
  env FONT_LOCK_FILE="$MINI_LOCK" FONT_BUILD_DIR="$MINI_DIR/build_fonts" FONT_CACHE_DIR="$MINI_DIR/cache" \
  sh "$ROOT_DIR/scripts/verify_zip.sh" "$MINI_DIR/bad_author.zip"

assert_fails "verify_zip.sh rejects missing version in module.prop" "missing required key 'version'" \
  env FONT_LOCK_FILE="$MINI_LOCK" FONT_BUILD_DIR="$MINI_DIR/build_fonts" FONT_CACHE_DIR="$MINI_DIR/cache" \
  sh "$ROOT_DIR/scripts/verify_zip.sh" "$MINI_DIR/no_version.zip"

assert_fails "verify_zip.sh rejects ZIP filename version mismatch" "ZIP filename mismatch" \
  env FONT_LOCK_FILE="$MINI_LOCK" FONT_BUILD_DIR="$MINI_DIR/build_fonts" FONT_CACHE_DIR="$MINI_DIR/cache" \
  sh "$ROOT_DIR/scripts/verify_zip.sh" "$MINI_DIR/ksu-noto-fonts-apple-emoji-v1.0.1.zip"

assert_fails "verify_zip.sh rejects corrupted non-ZIP file" "not a valid ZIP archive" \
  env FONT_LOCK_FILE="$MINI_LOCK" FONT_BUILD_DIR="$MINI_DIR/build_fonts" FONT_CACHE_DIR="$MINI_DIR/cache" \
  sh "$ROOT_DIR/scripts/verify_zip.sh" "$MINI_DIR/corrupt.zip"

printf '==> All %d test checks passed!\n' "$pass_count"
