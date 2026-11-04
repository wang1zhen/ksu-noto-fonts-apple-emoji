# BusyBox awk XML transformer and finite-format validator for Android / OxygenOS 16 font configs.
# Supports three explicit modes (-v mode="fallback", -v mode="legacy", or -v mode="base"):
#   - fallback: modern VF configuration (font_fallback.xml, root <familyset> without version)
#   - legacy:   compat configuration (fonts.xml, root <familyset version="..."> with SysFont sans-serif + unnamed Roboto)
#   - base:     system_ext base configuration (fonts_base.xml, root <familyset version="..."> with Roboto sans-serif)
# Also supports -v validate_only=1 to validate generated XML output using the same
# finite-format state machine and node-level invariants.
#
# Architecture (v1.0.2 original-filename overlay):
#   - Preserves family sequence, <alias> elements, non-target families, and TTC indices intact
#   - Does NOT add CJK families and does NOT rebuild fallback chains
#   - Maps target <font> nodes in-place:
#     * Roboto-Regular.ttf: supportedAxes="wght,ital" -> "wght" + adjacent NotoSans-Italic.ttf (preserving wdth 75/100)
#     * SysFont-Regular.ttf (legacy sans-serif 100..900): strips ital=0 axis + adjacent NotoSans-Italic.ttf (wdth=100, wght=W)
#     * SysSans-En-Regular.ttf / OPSans-En-Regular.ttf: strips OEM postScriptName, clamps wght 1000->900 + adjacent NotoSans-Italic.ttf
#     * SysSans-Hans-Regular.ttf / SysSans-Hant-Regular.ttf:
#       - fallbackFor="serif": rewrites filename ONLY to KsuReserved-SysSans-Hans/Hant-Regular.ttf, preserving weight/style/PS/axes verbatim
#       - normal: strips OEM postScriptName, clamps wght 1000->900, pins wght=weight if missing
#     * NotoSansCJK-Regular.ttc: validates index in 0..3 matching locale (0=ja, 1=ko, 2=zh-Hans, 3=zh-Hant), strips OEM postScriptName,
#       pins wght=weight when supportedAxes is absent
#     * NotoColorEmoji.ttf: prepends one <family lang="und-Zsye"> with NotoColorEmoji.ttf (postScriptName="KsuAppleColorEmoji")
#       and rewrites the original active NotoColorEmoji.ttf node to KsuReserved-NotoColorEmoji.ttf (postScriptName="NotoColorEmoji")

function fail_xml(reason) {
  error_reason = reason
  if (stats != "") {
    print "ERROR " reason > stats
    close(stats)
  }
  exit 2
}

function get_attr(tag, attr_name,    pat_dq, pat_sq, val) {
  pat_dq = "(^|[[:space:]])" attr_name "[[:space:]]*=[[:space:]]*\"[^\"]*\""
  if (match(tag, pat_dq)) {
    val = substr(tag, RSTART, RLENGTH)
    sub("^.*[[:space:]]*" attr_name "[[:space:]]*=[[:space:]]*\"", "", val)
    sub("\"$", "", val)
    return val
  }
  pat_sq = "(^|[[:space:]])" attr_name "[[:space:]]*=[[:space:]]*'[^']*'"
  if (match(tag, pat_sq)) {
    val = substr(tag, RSTART, RLENGTH)
    sub("^.*[[:space:]]*" attr_name "[[:space:]]*=[[:space:]]*'", "", val)
    sub("'$", "", val)
    return val
  }
  return ""
}

function strip_comments(s,    out, idx, dd, before_c) {
  out = ""
  while ((idx = index(s, "<!--")) > 0) {
    before_c = substr(s, 1, idx - 1)
    if (index(before_c, "-->") > 0) {
      fail_xml("stray_comment_close")
    }
    out = out before_c
    s = substr(s, idx + 4)
    dd = index(s, "--")
    if (dd == 0) {
      fail_xml("unclosed_xml_comment")
    }
    if (substr(s, dd, 3) != "-->") {
      fail_xml("invalid_double_dash_in_comment")
    }
    s = substr(s, dd + 3)
  }
  if (index(s, "-->") > 0) {
    fail_xml("stray_comment_close")
  }
  return out s
}

function strip_line_comments(s,    out, c_start, dd, before_c) {
  out = ""
  while (length(s) > 0) {
    if (in_comment) {
      dd = index(s, "--")
      if (dd == 0) {
        s = ""
        break
      }
      if (substr(s, dd, 3) != "-->") {
        fail_xml("invalid_double_dash_in_comment")
      }
      s = substr(s, dd + 3)
      in_comment = 0
    } else {
      c_start = index(s, "<!--")
      if (c_start == 0) {
        if (index(s, "-->") > 0) {
          fail_xml("stray_comment_close")
        }
        out = out s
        s = ""
        break
      }
      before_c = substr(s, 1, c_start - 1)
      if (index(before_c, "-->") > 0) {
        fail_xml("stray_comment_close")
      }
      out = out before_c
      saw_before_decl = 1
      s = substr(s, c_start + 4)
      dd = index(s, "--")
      if (dd == 0) {
        in_comment = 1
        s = ""
        break
      }
      if (substr(s, dd, 3) != "-->") {
        fail_xml("invalid_double_dash_in_comment")
      }
      s = substr(s, dd + 3)
    }
  }
  return out
}

function validate_and_parse_attrs(attr_str, allowed_csv,    rest, kv, eq, k, v, seen, allowed_arr, n, i, ok) {
  for (k in parsed_attrs) delete parsed_attrs[k]
  n = split(allowed_csv, allowed_arr, ",")
  rest = attr_str
  sub(/^[[:space:]]+/, "", rest)
  sub(/[[:space:]]+$/, "", rest)
  while (length(rest) > 0) {
    if (!match(rest, /^[A-Za-z_][A-Za-z0-9_.:-]*[[:space:]]*=[[:space:]]*("[^"]*"|'[^']*')([[:space:]]|$)/)) {
      fail_xml("malformed_attributes")
    }
    kv = substr(rest, 1, RLENGTH)
    rest = substr(rest, RLENGTH + 1)
    sub(/^[[:space:]]+/, "", rest)
    eq = index(kv, "=")
    k = substr(kv, 1, eq - 1)
    sub(/[[:space:]]+$/, "", k)
    v = substr(kv, eq + 1)
    sub(/^[[:space:]]+/, "", v)
    sub(/[[:space:]]+$/, "", v)
    v = substr(v, 2, length(v) - 2)
    if (k in seen) {
      fail_xml("duplicate_attribute_" k)
    }
    seen[k] = 1
    if (allowed_csv != "*") {
      ok = 0
      for (i = 1; i <= n; i++) {
        if (allowed_arr[i] == k) {
          ok = 1
          break
        }
      }
      if (!ok) {
        fail_xml("disallowed_attribute_" k)
      }
    }
    parsed_attrs[k] = v
  }
}

function handle_xml_text(txt,    trimmed) {
  if (length(txt) > 0) {
    saw_before_decl = 1
  }
  if (index(txt, ">") > 0) {
    fail_xml("stray_gt_in_text")
  }
  if (xml_state == "IN_FONT") {
    if (txt ~ /[^[:space:]]/) {
      if (cur_font_saw_axis) {
        fail_xml("unexpected_text_after_axis")
      }
      trimmed = txt
      sub(/^[[:space:]]+/, "", trimmed)
      sub(/[[:space:]]+$/, "", trimmed)
      if (trimmed ~ /[[:space:]]/) {
        fail_xml("invalid_whitespace_in_font_filename")
      }
      cur_font_text = cur_font_text trimmed
    }
    return
  }
  if (txt ~ /[^[:space:]]/) {
    fail_xml("unexpected_text_in_" xml_state)
  }
}

function handle_xml_tag(raw_tag,    inner, cname, is_self_closing, tname, attr_str, fb_group, w_val, w_num, st_val, st_norm, style_key, k) {
  inner = substr(raw_tag, 2, length(raw_tag) - 2)
  if (index(inner, "<") > 0) {
    fail_xml("nested_lt_in_tag")
  }

  # XML declaration: <?xml version="1.0" [encoding="..."] [standalone="yes|no"]?>
  if (inner ~ /^\?xml([[:space:]?]|$)/) {
    if (xml_state != "BEFORE_ROOT" || saw_xml_decl || saw_before_decl) {
      fail_xml("invalid_xml_declaration_position")
    }
    if (inner !~ /^\?xml[[:space:]]+version[[:space:]]*=[[:space:]]*("1\.0"|'1\.0')([[:space:]]+encoding[[:space:]]*=[[:space:]]*("[A-Za-z][A-Za-z0-9._-]*"|'[A-Za-z][A-Za-z0-9._-]*'))?([[:space:]]+standalone[[:space:]]*=[[:space:]]*("(yes|no)"|'(yes|no)'))?[[:space:]]*\?$/) {
      fail_xml("invalid_xml_declaration")
    }
    saw_xml_decl = 1
    saw_before_decl = 1
    return
  }

  saw_before_decl = 1

  if (inner ~ /^[\?!]/) {
    fail_xml("unsupported_pi_or_declaration")
  }

  # Closing tag: </...>
  if (inner ~ /^\//) {
    cname = substr(inner, 2)
    sub(/[[:space:]]+$/, "", cname)
    if (cname == "familyset") {
      if (xml_state != "IN_FAMILYSET") {
        fail_xml("unexpected_close_familyset_in_" xml_state)
      }
      saw_familyset_close = 1
      xml_state = "AFTER_ROOT"
      return
    }
    if (cname == "family") {
      if (xml_state != "IN_FAMILY") {
        fail_xml("unexpected_close_family_in_" xml_state)
      }
      if (cur_family_font_count < 1) {
        fail_xml("empty_family_without_fonts")
      }
      xml_state = "IN_FAMILYSET"
      cur_family_ignored = 0
      return
    }
    if (cname == "font") {
      if (xml_state != "IN_FONT") {
        fail_xml("unexpected_close_font_in_" xml_state)
      }
      if (cur_font_text == "" || cur_font_text !~ /^[A-Za-z0-9._+-]+\.(ttf|ttc|otf)$/) {
        fail_xml("invalid_or_empty_font_filename")
      }
      if (cur_font_text ~ /^KSU-/) {
        fail_xml("legacy_ksu_font_forbidden:" cur_font_text)
      }
      if (!validate_only) {
        if (cur_font_text == "NotoSans-Italic.ttf" || cur_font_text ~ /^KsuReserved-/ || cur_font_ps == "KsuAppleColorEmoji") {
          fail_xml("already_modified_font_in_input:" cur_font_text)
        }
      } else {
        if (cur_font_text == "Roboto-Regular.ttf" || cur_font_text == "SysFont-Regular.ttf" || \
            cur_font_text == "SysSans-En-Regular.ttf" || cur_font_text == "OPSans-En-Regular.ttf" || \
            cur_font_text == "NotoSans-Italic.ttf" || cur_font_text == "SysSans-Hans-Regular.ttf" || \
            cur_font_text == "SysSans-Hant-Regular.ttf" || cur_font_text == "NotoSansCJK-Regular.ttc") {
          if (cur_font_ps != "") {
            fail_xml("unexpected_postScriptName_on_noto_font:" cur_font_text)
          }
          if (cur_font_has_ital_axis || cur_font_has_wght_1000_axis) {
            fail_xml("forbidden_ital_or_1000_axis_on_noto_font:" cur_font_text)
          }
        }
        if (cur_font_text == "NotoColorEmoji.ttf" && cur_family_ignored) {
          fail_xml("apple_emoji_in_ignored_family")
        }
      }
      xml_state = "IN_FAMILY"
      return
    }
    fail_xml("unexpected_close_tag_" cname)
  }

  # Opening or self-closing tag
  is_self_closing = 0
  if (inner ~ /\/$/) {
    is_self_closing = 1
    sub(/\/$/, "", inner)
  }

  if (!match(inner, /^[A-Za-z_][A-Za-z0-9_.:-]*/)) {
    fail_xml("malformed_tag_name")
  }
  tname = substr(inner, RSTART, RLENGTH)
  attr_str = substr(inner, RSTART + RLENGTH)
  if (attr_str != "" && attr_str !~ /^[[:space:]]/) {
    fail_xml("malformed_tag_after_name_" tname)
  }

  if (tname == "familyset") {
    if (xml_state != "BEFORE_ROOT" || saw_familyset_open || is_self_closing) {
      fail_xml("invalid_familyset_open")
    }
    validate_and_parse_attrs(attr_str, "version")
    familyset_version = ("version" in parsed_attrs) ? parsed_attrs["version"] : ""
    if (mode == "fallback" && ("version" in parsed_attrs)) {
      fail_xml("unexpected_version_in_fallback_familyset")
    }
    if (mode == "legacy" || mode == "base") {
      if (familyset_version == "" || familyset_version !~ /^[0-9]+$/) {
        fail_xml("missing_or_invalid_version_in_" mode "_familyset")
      }
    }
    saw_familyset_open = 1
    xml_state = "IN_FAMILYSET"
    return
  }

  if (tname == "alias") {
    if (xml_state != "IN_FAMILYSET" || !is_self_closing) {
      fail_xml("invalid_alias_tag")
    }
    validate_and_parse_attrs(attr_str, "name,to,weight")
    if (!("name" in parsed_attrs) || parsed_attrs["name"] !~ /[^[:space:]]/ || !("to" in parsed_attrs) || parsed_attrs["to"] !~ /^[A-Za-z0-9_.:-]+$/) {
      fail_xml("missing_required_alias_attrs")
    }
    if ("weight" in parsed_attrs) {
      if (parsed_attrs["weight"] !~ /^[1-9][0-9]*$/ || (parsed_attrs["weight"] + 0) < 1 || (parsed_attrs["weight"] + 0) > 1000) {
        fail_xml("invalid_alias_weight:" parsed_attrs["weight"])
      }
    }
    return
  }

  if (tname == "family") {
    if (xml_state != "IN_FAMILYSET" || is_self_closing) {
      fail_xml("invalid_family_open")
    }
    validate_and_parse_attrs(attr_str, "name,lang,variant,ignore")
    if (("name" in parsed_attrs) && parsed_attrs["name"] !~ /^[A-Za-z0-9_.:-]+$/) {
      fail_xml("invalid_family_name")
    }
    if (("lang" in parsed_attrs) && parsed_attrs["lang"] !~ /^[A-Za-z0-9_,+-]+$/) {
      fail_xml("invalid_family_lang")
    }
    if (("variant" in parsed_attrs) && parsed_attrs["variant"] != "compact" && parsed_attrs["variant"] != "elegant") {
      fail_xml("invalid_family_variant")
    }
    if ("ignore" in parsed_attrs) {
      if (tolower(parsed_attrs["ignore"]) != "true" && tolower(parsed_attrs["ignore"]) != "false") {
        fail_xml("invalid_family_ignore")
      }
    }
    for (k in cur_family_styles) delete cur_family_styles[k]
    cur_family_font_count = 0
    cur_family_ignored = (tolower(("ignore" in parsed_attrs) ? parsed_attrs["ignore"] : "") == "true") ? 1 : 0
    xml_state = "IN_FAMILY"
    return
  }

  if (tname == "font") {
    if (xml_state != "IN_FAMILY" || is_self_closing) {
      fail_xml("invalid_font_open")
    }
    validate_and_parse_attrs(attr_str, "weight,style,index,fallbackFor,postScriptName,supportedAxes")
    if (("fallbackFor" in parsed_attrs) && parsed_attrs["fallbackFor"] !~ /^[A-Za-z0-9_.:-]+$/) {
      fail_xml("invalid_or_empty_fallbackFor_attribute")
    }
    if (("index" in parsed_attrs) && parsed_attrs["index"] !~ /^(0|[1-9][0-9]*)$/) {
      fail_xml("invalid_font_index:" parsed_attrs["index"])
    }
    if (("postScriptName" in parsed_attrs) && parsed_attrs["postScriptName"] !~ /^[A-Za-z0-9_.:-]+$/) {
      fail_xml("invalid_font_postScriptName")
    }
    if (("supportedAxes" in parsed_attrs) && parsed_attrs["supportedAxes"] !~ /^[A-Za-z0-9_,]+$/) {
      fail_xml("invalid_font_supportedAxes")
    }
    fb_group = ("fallbackFor" in parsed_attrs) ? parsed_attrs["fallbackFor"] : ""
    w_val = ("weight" in parsed_attrs) ? parsed_attrs["weight"] : "400"
    st_val = ("style" in parsed_attrs) ? parsed_attrs["style"] : "normal"
    if (w_val !~ /^[1-9][0-9]*$/) {
      fail_xml("invalid_font_weight:" w_val)
    }
    w_num = w_val + 0
    if (w_num < 1 || w_num > 1000) {
      fail_xml("out_of_range_font_weight:" w_val)
    }
    if (st_val != "normal" && st_val != "italic") {
      fail_xml("invalid_font_style:" st_val)
    }
    st_norm = (st_val == "italic") ? "italic" : "normal"
    style_key = fb_group "|" w_num "|" st_norm
    if (style_key in cur_family_styles) {
      fail_xml("duplicate_font_style_in_family:" style_key)
    }
    cur_family_styles[style_key] = 1

    cur_font_ps = ("postScriptName" in parsed_attrs) ? parsed_attrs["postScriptName"] : ""
    cur_font_has_ital_axis = (("supportedAxes" in parsed_attrs) && parsed_attrs["supportedAxes"] ~ /(^|,)ital(,|$)/) ? 1 : 0
    cur_font_has_wght_1000_axis = 0

    cur_family_font_count++
    cur_font_text = ""
    cur_font_saw_axis = 0
    xml_state = "IN_FONT"
    return
  }

  if (tname == "axis") {
    if (xml_state != "IN_FONT" || !is_self_closing) {
      fail_xml("invalid_axis_tag")
    }
    validate_and_parse_attrs(attr_str, "tag,stylevalue")
    if (!("tag" in parsed_attrs) || parsed_attrs["tag"] !~ /^[A-Za-z0-9]{4}$/ || !("stylevalue" in parsed_attrs) || parsed_attrs["stylevalue"] !~ /^-?(0|[1-9][0-9]*)(\.[0-9]+)?$/) {
      fail_xml("missing_or_invalid_axis_attrs")
    }
    if (parsed_attrs["tag"] == "ital") {
      cur_font_has_ital_axis = 1
    }
    if (parsed_attrs["tag"] == "wght" && (parsed_attrs["stylevalue"] + 0) > 900) {
      cur_font_has_wght_1000_axis = 1
    }
    cur_font_saw_axis = 1
    return
  }

  fail_xml("unexpected_tag_" tname)
}

function advance_xml_state(line_chunk,    lt, gt, text_part, raw_tag) {
  xml_buf = (xml_buf == "") ? line_chunk : (xml_buf "\n" line_chunk)
  while (length(xml_buf) > 0) {
    lt = index(xml_buf, "<")
    if (lt == 0) {
      handle_xml_text(xml_buf)
      xml_buf = ""
      break
    }
    if (lt > 1) {
      text_part = substr(xml_buf, 1, lt - 1)
      handle_xml_text(text_part)
      xml_buf = substr(xml_buf, lt)
    }
    gt = index(xml_buf, ">")
    if (gt == 0) {
      if (index(substr(xml_buf, 2), "<") > 0) {
        fail_xml("unclosed_tag_before_lt")
      }
      break
    }
    raw_tag = substr(xml_buf, 1, gt)
    xml_buf = substr(xml_buf, gt + 1)
    handle_xml_tag(raw_tag)
  }
}

function validate_cjk_family_header(header,    inner) {
  inner = header
  sub(/^[[:space:]]*<family/, "", inner)
  sub(/>[[:space:]]*$/, "", inner)
  validate_and_parse_attrs(inner, "lang")
  if (!("lang" in parsed_attrs) || parsed_attrs["lang"] == "") {
    fail_xml("cjk_missing_lang_attr")
  }
}

function parse_family_fonts(clean_block, open_end,    body, close_idx, f_start, rel_open_end, f_open_tag, rel_close, full_font_elem, f_inner, a_rest, a_tag, t_part, k) {
  for (k in fam_font_raw) delete fam_font_raw[k]
  for (k in fam_font_open) delete fam_font_open[k]
  for (k in fam_font_file) delete fam_font_file[k]
  for (k in fam_font_axis_count) delete fam_font_axis_count[k]
  for (k in fam_font_axis_tag) delete fam_font_axis_tag[k]
  for (k in fam_font_axis_val) delete fam_font_axis_val[k]
  fam_font_n = 0

  body = substr(clean_block, open_end + 1)
  close_idx = match(body, /<\/family[[:space:]]*>[[:space:]]*$/)
  if (close_idx == 0) {
    fail_xml("missing_close_family_tag")
  }
  body = substr(body, 1, close_idx - 1)

  while (match(body, /<font([[:space:]>]|$)/)) {
    f_start = RSTART
    if (substr(body, 1, f_start - 1) ~ /[^[:space:]]/) {
      fail_xml("unexpected_content_before_font")
    }
    body = substr(body, f_start)
    rel_open_end = index(body, ">")
    if (rel_open_end == 0) {
      fail_xml("unclosed_font_open_tag")
    }
    f_open_tag = substr(body, 1, rel_open_end)
    if (f_open_tag ~ /\/>$/) {
      fail_xml("self_closing_font_tag")
    }
    rel_close = index(body, "</font>")
    if (rel_close == 0) {
      fail_xml("unclosed_font_element")
    }
    full_font_elem = substr(body, 1, rel_close + 6)
    f_inner = substr(body, rel_open_end + 1, rel_close - rel_open_end - 1)
    body = substr(body, rel_close + 7)

    fam_font_n++
    fam_font_raw[fam_font_n] = full_font_elem
    fam_font_open[fam_font_n] = f_open_tag
    fam_font_axis_count[fam_font_n] = 0

    t_part = f_inner
    if (index(t_part, "<") > 0) {
      t_part = substr(t_part, 1, index(t_part, "<") - 1)
    }
    gsub(/[[:space:]]+/, "", t_part)
    fam_font_file[fam_font_n] = t_part

    a_rest = f_inner
    while (match(a_rest, /<axis[[:space:]][^>]*\/>/)) {
      a_tag = substr(a_rest, RSTART, RLENGTH)
      a_rest = substr(a_rest, RSTART + RLENGTH)
      fam_font_axis_count[fam_font_n]++
      fam_font_axis_tag[fam_font_n, fam_font_axis_count[fam_font_n]] = get_attr(a_tag, "tag")
      fam_font_axis_val[fam_font_n, fam_font_axis_count[fam_font_n]] = get_attr(a_tag, "stylevalue")
    }
  }

  if (body ~ /[^[:space:]]/) {
    fail_xml("unexpected_trailing_family_body_content")
  }
}

function is_target_font_file(fn) {
  return (fn == "Roboto-Regular.ttf" || fn == "SysFont-Regular.ttf" || \
          fn == "SysSans-En-Regular.ttf" || fn == "OPSans-En-Regular.ttf" || \
          fn == "NotoSans-Italic.ttf" || \
          fn == "SysSans-Hans-Regular.ttf" || fn == "SysSans-Hant-Regular.ttf" || \
          fn == "KsuReserved-SysSans-Hans-Regular.ttf" || fn == "KsuReserved-SysSans-Hant-Regular.ttf" || \
          fn == "NotoSansCJK-Regular.ttc" || \
          fn == "NotoColorEmoji.ttf" || fn == "KsuReserved-NotoColorEmoji.ttf")
}

function expected_ttc_index_for_lang(lang_val) {
  if (lang_val == "ja") return "0"
  if (lang_val == "ko") return "1"
  if (lang_val == "zh-Hans") return "2"
  if (lang_val == "zh-Hant,zh-Bopo" || lang_val == "zh-Bopo,zh-Hant") return "3"
  return ""
}

function process_family(    raw_block, clean_block, open_end, header, indent,
                            fam_name, fam_lang, fam_ignore, norm_lang,
                            cjk_role, is_unnamed_after_sans, has_target,
                            normal_cnt, fb_cnt, i, j, fn, f_open, w, st, idx, fb, ps, sa,
                            ac, wdth_val, wght_val, ital_val, clamped_w,
                            next_fn, next_open, next_ac, mod_raw) {
  raw_block = ""
  for (i = 1; i <= family_count; i++) {
    raw_block = raw_block family_lines[i] ((i < family_count) ? "\n" : "")
  }
  clean_block = strip_comments(raw_block)

  open_end = index(clean_block, ">")
  if (open_end == 0) {
    fail_xml("unclosed_family_open_tag")
  }
  header = substr(clean_block, 1, open_end)

  indent = family_lines[1]
  sub(/[^[:space:]].*$/, "", indent)

  fam_name = tolower(get_attr(header, "name"))
  fam_lang = get_attr(header, "lang")
  fam_ignore = tolower(get_attr(header, "ignore"))

  parse_family_fonts(clean_block, open_end)
  if (fam_font_n < 1) {
    fail_xml("empty_family_without_fonts")
  }

  # Track family roles and enforce mode-level family structure
  is_unnamed_after_sans = 0
  if (fam_name == "sans-serif") {
    if (fam_lang != "" || fam_ignore == "true") {
      fail_xml("invalid_western_family_sans-serif")
    }
    if (mode == "fallback" || mode == "base") {
      if (fam_font_file[1] != "Roboto-Regular.ttf") {
        fail_xml("unexpected_" mode "_sans_serif_font:" fam_font_file[1])
      }
    } else if (mode == "legacy") {
      if (fam_font_file[1] != "SysFont-Regular.ttf") {
        fail_xml("unexpected_legacy_sans_serif_font:" fam_font_file[1])
      }
    }
    count_sans_serif++
    prev_was_sans_serif = 1
  } else if (prev_was_sans_serif == 1 && fam_name == "" && fam_lang == "" && fam_ignore != "true") {
    prev_was_sans_serif = 0
    if (mode == "base") {
      fail_xml("unexpected_unnamed_western_in_base")
    }
    if (mode == "legacy" && count_unnamed_western == 0 && fam_font_file[1] == "Roboto-Regular.ttf") {
      is_unnamed_after_sans = 1
      count_unnamed_western++
    }
  } else {
    prev_was_sans_serif = 0
    if (fam_name == "sys-sans-en") {
      if (fam_lang != "" || fam_ignore == "true" || mode == "fallback") {
        fail_xml("invalid_western_family_sys-sans-en")
      }
      if (fam_font_file[1] != "SysSans-En-Regular.ttf") {
        fail_xml("unexpected_base_sys_sans_en_font")
      }
      count_sys_sans_en++
    } else if (fam_name == "op-sans-en") {
      if (fam_lang != "" || fam_ignore == "true" || mode == "fallback") {
        fail_xml("invalid_western_family_op-sans-en")
      }
      if (fam_font_file[1] != "OPSans-En-Regular.ttf") {
        fail_xml("unexpected_base_op_sans_en_font")
      }
      count_op_sans_en++
    }
  }

  # CJK locale family checks
  cjk_role = ""
  if (fam_lang == "zh-Hans") {
    if (count_zh_hans > 0) fail_xml("duplicate_cjk_family_zh-Hans")
    cjk_role = "zh-Hans"
    count_zh_hans++
  } else if (fam_lang == "zh-Hant,zh-Bopo" || fam_lang == "zh-Bopo,zh-Hant") {
    if (count_zh_hant > 0) fail_xml("duplicate_cjk_family_zh-Hant")
    cjk_role = "zh-Hant"
    count_zh_hant++
  } else if (fam_lang == "ja") {
    if (count_ja == 0) {
      if (clean_block ~ /Hentaigana/) fail_xml("unexpected_hentaigana_as_primary_ja")
      cjk_role = "ja"
      count_ja++
    } else if (count_ja == 1 && count_ja_hentaigana == 0 && clean_block ~ /NotoSerifHentaigana\.ttf/) {
      validate_cjk_family_header(header)
      count_ja_hentaigana++
    } else {
      fail_xml("unexpected_extra_ja_family")
    }
  } else if (fam_lang == "ko") {
    if (count_ko > 0) fail_xml("duplicate_cjk_family_ko")
    cjk_role = "ko"
    count_ko++
  }

  if (cjk_role != "") {
    validate_cjk_family_header(header)
    normal_cnt = 0
    fb_cnt = 0
    for (i = 1; i <= fam_font_n; i++) {
      fb = get_attr(fam_font_open[i], "fallbackFor")
      if (fb != "") fb_cnt++
      else normal_cnt++
    }
    if (normal_cnt < 1) fail_xml("cjk_missing_normal_font:" cjk_role)
    if (fb_cnt < 1) fail_xml("cjk_missing_fallbackFor_font:" cjk_role)
  }

  # Emoji family handling (lang="und-Zsye")
  norm_lang = tolower(fam_lang)
  if (norm_lang == "und-zsye") {
    if (fam_ignore == "true") {
      for (i = 1; i <= fam_font_n; i++) {
        if (fam_font_file[i] == "NotoColorEmoji.ttf" || fam_font_file[i] == "KsuReserved-NotoColorEmoji.ttf") {
          fail_xml("active_emoji_in_ignored_family")
        }
      }
      if (!validate_only) {
        for (i = 1; i <= family_count; i++) print family_lines[i]
      }
      return
    }

    if (!validate_only) {
      if (fam_font_file[1] == "NotoColorEmoji.ttf") {
        if (emoji_inserted || fam_font_n != 1) {
          fail_xml("invalid_active_emoji_family")
        }
        f_open = fam_font_open[1]
        if (get_attr(f_open, "weight") != "400" || get_attr(f_open, "style") != "normal" || \
            get_attr(f_open, "index") != "" || get_attr(f_open, "fallbackFor") != "" || \
            get_attr(f_open, "postScriptName") != "" || get_attr(f_open, "supportedAxes") != "" || \
            fam_font_axis_count[1] != 0) {
          fail_xml("unexpected_emoji_font_attrs")
        }
        print indent "<family lang=\"und-Zsye\">"
        print indent "    <font weight=\"400\" style=\"normal\" postScriptName=\"KsuAppleColorEmoji\">NotoColorEmoji.ttf</font>"
        print indent "</family>"
        print header
        print indent "    <font weight=\"400\" style=\"normal\" postScriptName=\"NotoColorEmoji\">KsuReserved-NotoColorEmoji.ttf</font>"
        print indent "</family>"
        emoji_inserted = 1
        count_emoji++
        return
      }
      for (i = 1; i <= family_count; i++) print family_lines[i]
      return
    } else {
      if (emoji_val_stage == 0) {
        if (fam_font_n != 1 || fam_font_file[1] != "NotoColorEmoji.ttf" || \
            get_attr(fam_font_open[1], "weight") != "400" || get_attr(fam_font_open[1], "style") != "normal" || \
            get_attr(fam_font_open[1], "postScriptName") != "KsuAppleColorEmoji" || \
            get_attr(fam_font_open[1], "index") != "" || get_attr(fam_font_open[1], "fallbackFor") != "" || \
            get_attr(fam_font_open[1], "supportedAxes") != "" || fam_font_axis_count[1] != 0) {
          fail_xml("first_active_emoji_not_ksu_apple")
        }
        emoji_val_stage = 1
        return
      } else if (emoji_val_stage == 1) {
        if (fam_font_n != 1 || fam_font_file[1] != "KsuReserved-NotoColorEmoji.ttf" || \
            get_attr(fam_font_open[1], "weight") != "400" || get_attr(fam_font_open[1], "style") != "normal" || \
            get_attr(fam_font_open[1], "postScriptName") != "NotoColorEmoji" || \
            get_attr(fam_font_open[1], "index") != "" || get_attr(fam_font_open[1], "fallbackFor") != "" || \
            get_attr(fam_font_open[1], "supportedAxes") != "" || fam_font_axis_count[1] != 0) {
          fail_xml("second_active_emoji_not_reserved_noto")
        }
        emoji_val_stage = 2
        count_emoji++
        return
      }
      for (i = 1; i <= fam_font_n; i++) {
        if (fam_font_file[i] == "NotoColorEmoji.ttf" || fam_font_file[i] == "KsuReserved-NotoColorEmoji.ttf") {
          fail_xml("unexpected_extra_active_emoji_font")
        }
      }
      return
    }
  }

  # Check if this family contains any target font node
  has_target = 0
  for (i = 1; i <= fam_font_n; i++) {
    if (is_target_font_file(fam_font_file[i])) {
      has_target = 1
      break
    }
  }

  if (!has_target) {
    if (!validate_only) {
      for (i = 1; i <= family_count; i++) print family_lines[i]
    }
    return
  }

  if (!validate_only) {
    print header
  }

  for (i = 1; i <= fam_font_n; i++) {
    fn = fam_font_file[i]
    f_open = fam_font_open[i]
    w = get_attr(f_open, "weight")
    st = get_attr(f_open, "style")
    idx = get_attr(f_open, "index")
    fb = get_attr(f_open, "fallbackFor")
    ps = get_attr(f_open, "postScriptName")
    sa = get_attr(f_open, "supportedAxes")
    ac = fam_font_axis_count[i]

    # 1. Roboto-Regular.ttf
    if (fn == "Roboto-Regular.ttf") {
      if (fam_name != "sans-serif" && fam_name != "sans-serif-condensed" && fam_name != "roboto" && !is_unnamed_after_sans) {
        fail_xml("unexpected_roboto_in_family:" fam_name)
      }
      if (w != "" || st != "" || idx != "" || fb != "" || ps != "") {
        fail_xml("unexpected_attrs_on_roboto")
      }
      if (ac != 1 || fam_font_axis_tag[i, 1] != "wdth") {
        fail_xml("missing_wdth_axis_on_roboto")
      }
      wdth_val = fam_font_axis_val[i, 1]
      if ((wdth_val + 0) != 75 && (wdth_val + 0) != 100) {
        fail_xml("unexpected_wdth_on_roboto:" wdth_val)
      }
      if (!validate_only) {
        if (sa != "wght,ital") {
          fail_xml("expected_wght_ital_on_roboto:" sa)
        }
        print indent "    <font supportedAxes=\"wght\">Roboto-Regular.ttf"
        print indent "        <axis tag=\"wdth\" stylevalue=\"" wdth_val "\" />"
        print indent "    </font>"
        print indent "    <font style=\"italic\" supportedAxes=\"wght\">NotoSans-Italic.ttf"
        print indent "        <axis tag=\"wdth\" stylevalue=\"" wdth_val "\" />"
        print indent "    </font>"
        count_roboto++
      } else {
        if (sa != "wght") {
          fail_xml("expected_wght_only_on_validated_roboto:" sa)
        }
        if (i + 1 > fam_font_n || fam_font_file[i + 1] != "NotoSans-Italic.ttf") {
          fail_xml("missing_paired_italic_after_roboto")
        }
        next_open = fam_font_open[i + 1]
        if (get_attr(next_open, "style") != "italic" || get_attr(next_open, "supportedAxes") != "wght" || \
            get_attr(next_open, "weight") != "" || get_attr(next_open, "index") != "" || \
            get_attr(next_open, "fallbackFor") != "" || get_attr(next_open, "postScriptName") != "" || \
            fam_font_axis_count[i + 1] != 1 || fam_font_axis_tag[i + 1, 1] != "wdth" || \
            fam_font_axis_val[i + 1, 1] != wdth_val) {
          fail_xml("invalid_paired_italic_after_roboto")
        }
        i++
        count_roboto++
      }
      continue
    }

    # 2. SysFont-Regular.ttf
    if (fn == "SysFont-Regular.ttf") {
      if (mode != "legacy" || fam_name != "sans-serif") {
        fail_xml("unexpected_sysfont_context")
      }
      if (st != "normal" || w == "" || (w + 0) < 100 || (w + 0) > 900 || idx != "" || fb != "" || ps != "" || sa != "") {
        fail_xml("invalid_sysfont_attrs")
      }
      if (!validate_only) {
        if (ac != 3) fail_xml("expected_3_axes_on_sysfont")
        ital_val = ""
        wdth_val = ""
        wght_val = ""
        for (j = 1; j <= ac; j++) {
          if (fam_font_axis_tag[i, j] == "ital") ital_val = fam_font_axis_val[i, j]
          else if (fam_font_axis_tag[i, j] == "wdth") wdth_val = fam_font_axis_val[i, j]
          else if (fam_font_axis_tag[i, j] == "wght") wght_val = fam_font_axis_val[i, j]
        }
        if (ital_val != "0" || (wdth_val + 0) != 100 || wght_val != w) {
          fail_xml("invalid_sysfont_axes")
        }
        print indent "    <font weight=\"" w "\" style=\"normal\">SysFont-Regular.ttf"
        print indent "        <axis tag=\"wdth\" stylevalue=\"" wdth_val "\" />"
        print indent "        <axis tag=\"wght\" stylevalue=\"" w "\" />"
        print indent "    </font>"
        print indent "    <font weight=\"" w "\" style=\"italic\">NotoSans-Italic.ttf"
        print indent "        <axis tag=\"wdth\" stylevalue=\"" wdth_val "\" />"
        print indent "        <axis tag=\"wght\" stylevalue=\"" w "\" />"
        print indent "    </font>"
        count_sysfont++
      } else {
        if (ac != 2 || fam_font_axis_tag[i, 1] != "wdth" || (fam_font_axis_val[i, 1] + 0) != 100 || \
            fam_font_axis_tag[i, 2] != "wght" || fam_font_axis_val[i, 2] != w) {
          fail_xml("invalid_validated_sysfont_axes")
        }
        wdth_val = fam_font_axis_val[i, 1]
        if (i + 1 > fam_font_n || fam_font_file[i + 1] != "NotoSans-Italic.ttf") {
          fail_xml("missing_paired_italic_after_sysfont")
        }
        next_open = fam_font_open[i + 1]
        if (get_attr(next_open, "weight") != w || get_attr(next_open, "style") != "italic" || \
            get_attr(next_open, "index") != "" || get_attr(next_open, "fallbackFor") != "" || \
            get_attr(next_open, "postScriptName") != "" || get_attr(next_open, "supportedAxes") != "" || \
            fam_font_axis_count[i + 1] != 2 || fam_font_axis_tag[i + 1, 1] != "wdth" || \
            fam_font_axis_val[i + 1, 1] != wdth_val || fam_font_axis_tag[i + 1, 2] != "wght" || \
            fam_font_axis_val[i + 1, 2] != w) {
          fail_xml("invalid_paired_italic_after_sysfont")
        }
        i++
        count_sysfont++
      }
      continue
    }

    # 3. SysSans-En-Regular.ttf / OPSans-En-Regular.ttf
    if (fn == "SysSans-En-Regular.ttf" || fn == "OPSans-En-Regular.ttf") {
      if ((fn == "SysSans-En-Regular.ttf" && fam_name != "sys-sans-en") || \
          (fn == "OPSans-En-Regular.ttf" && fam_name != "op-sans-en")) {
        fail_xml("unexpected_oplus_latin_family:" fn)
      }
      if (st != "normal" || w == "" || idx != "" || fb != "" || sa != "") {
        fail_xml("invalid_oplus_latin_attrs:" fn)
      }
      clamped_w = ((w + 0) > 900) ? "900" : w
      if (!validate_only) {
        if (ac != 1 || fam_font_axis_tag[i, 1] != "wght" || fam_font_axis_val[i, 1] != w) {
          fail_xml("invalid_oplus_latin_axis:" fn)
        }
        if ((w + 0) > 900) count_clamp++
        print indent "    <font weight=\"" w "\" style=\"normal\">" fn
        print indent "        <axis tag=\"wght\" stylevalue=\"" clamped_w "\" />"
        print indent "    </font>"
        print indent "    <font weight=\"" w "\" style=\"italic\">NotoSans-Italic.ttf"
        print indent "        <axis tag=\"wght\" stylevalue=\"" clamped_w "\" />"
        print indent "    </font>"
      } else {
        if (ps != "" || ac != 1 || fam_font_axis_tag[i, 1] != "wght" || fam_font_axis_val[i, 1] != clamped_w) {
          fail_xml("invalid_validated_oplus_latin:" fn)
        }
        if (i + 1 > fam_font_n || fam_font_file[i + 1] != "NotoSans-Italic.ttf") {
          fail_xml("missing_paired_italic_after_oplus_latin:" fn)
        }
        next_open = fam_font_open[i + 1]
        if (get_attr(next_open, "weight") != w || get_attr(next_open, "style") != "italic" || \
            get_attr(next_open, "index") != "" || get_attr(next_open, "fallbackFor") != "" || \
            get_attr(next_open, "postScriptName") != "" || get_attr(next_open, "supportedAxes") != "" || \
            fam_font_axis_count[i + 1] != 1 || fam_font_axis_tag[i + 1, 1] != "wght" || \
            fam_font_axis_val[i + 1, 1] != clamped_w) {
          fail_xml("invalid_paired_italic_after_oplus_latin:" fn)
        }
        i++
      }
      if (fn == "SysSans-En-Regular.ttf") count_syssans_en++
      else count_opsans_en++
      continue
    }

    # 4. SysSans-Hans-Regular.ttf / SysSans-Hant-Regular.ttf / KsuReserved-SysSans-Hans|Hant-Regular.ttf
    if (fn == "SysSans-Hans-Regular.ttf" || fn == "SysSans-Hant-Regular.ttf" || \
        fn == "KsuReserved-SysSans-Hans-Regular.ttf" || fn == "KsuReserved-SysSans-Hant-Regular.ttf") {
      if (mode == "fallback") {
        fail_xml("unexpected_syssans_cjk_in_fallback:" fn)
      }
      if ((fn ~ /Hans/ && cjk_role != "zh-Hans") || (fn ~ /Hant/ && cjk_role != "zh-Hant")) {
        fail_xml("mismatched_syssans_cjk_locale:" fn ":" fam_lang)
      }
      if (fb == "serif") {
        if (w != "400" || st != "normal" || idx != "" || sa != "" || ac != 0 || ps == "") {
          fail_xml("invalid_syssans_serif_node:" fn)
        }
        if (!validate_only) {
          if (fn ~ /^KsuReserved-/) fail_xml("already_reserved_in_input:" fn)
          mod_raw = fam_font_raw[i]
          if (fn == "SysSans-Hans-Regular.ttf") {
            sub(/SysSans-Hans-Regular\.ttf/, "KsuReserved-SysSans-Hans-Regular.ttf", mod_raw)
            count_serif_hans++
          } else {
            sub(/SysSans-Hant-Regular\.ttf/, "KsuReserved-SysSans-Hant-Regular.ttf", mod_raw)
            count_serif_hant++
          }
          print indent "    " mod_raw
        } else {
          if (fn !~ /^KsuReserved-/) fail_xml("unreserved_syssans_serif_in_validate:" fn)
          if (fn == "KsuReserved-SysSans-Hans-Regular.ttf") count_serif_hans++
          else count_serif_hant++
        }
        continue
      }

      # Normal SysSans-Hans / SysSans-Hant node (no fallbackFor)
      if (fn ~ /^KsuReserved-/ || fb != "" || st != "normal" || w == "" || idx != "" || sa != "") {
        fail_xml("invalid_normal_syssans_cjk_node:" fn)
      }
      clamped_w = ((w + 0) > 900) ? "900" : w
      if (!validate_only) {
        if (ac == 0) {
          count_pin++
        } else if (ac == 1 && fam_font_axis_tag[i, 1] == "wght" && fam_font_axis_val[i, 1] == w) {
          if ((w + 0) > 900) count_clamp++
        } else {
          fail_xml("invalid_normal_syssans_cjk_axis:" fn)
        }
        print indent "    <font weight=\"" w "\" style=\"normal\">" fn
        print indent "        <axis tag=\"wght\" stylevalue=\"" clamped_w "\" />"
        print indent "    </font>"
      } else {
        if (ps != "" || ac != 1 || fam_font_axis_tag[i, 1] != "wght" || fam_font_axis_val[i, 1] != clamped_w) {
          fail_xml("invalid_validated_syssans_cjk_node:" fn)
        }
      }
      if (fn == "SysSans-Hans-Regular.ttf") count_cjk_hans++
      else count_cjk_hant++
      continue
    }

    # 5. NotoSansCJK-Regular.ttc
    if (fn == "NotoSansCJK-Regular.ttc") {
      if (fb != "" || st != "normal" || w == "" || idx == "") {
        fail_xml("invalid_ttc_node_attrs")
      }
      if (idx != expected_ttc_index_for_lang(fam_lang)) {
        fail_xml("ttc_index_mismatch:" idx ":lang=" fam_lang)
      }
      clamped_w = ((w + 0) > 900) ? "900" : w
      if (sa == "wght") {
        if (mode != "fallback" || w != "400" || ac != 0) {
          fail_xml("invalid_modern_ttc_node")
        }
        if (!validate_only) {
          print indent "    <font weight=\"400\" style=\"normal\" index=\"" idx "\" supportedAxes=\"wght\">NotoSansCJK-Regular.ttc</font>"
        } else {
          if (ps != "") fail_xml("unexpected_ps_on_validated_ttc")
        }
      } else if (sa == "") {
        if (!validate_only) {
          if (ac == 0) {
            count_pin++
          } else if (ac == 1 && fam_font_axis_tag[i, 1] == "wght" && fam_font_axis_val[i, 1] == w) {
            if ((w + 0) > 900) count_clamp++
          } else {
            fail_xml("invalid_static_ttc_axis")
          }
          print indent "    <font weight=\"" w "\" style=\"normal\" index=\"" idx "\">NotoSansCJK-Regular.ttc"
          print indent "        <axis tag=\"wght\" stylevalue=\"" clamped_w "\" />"
          print indent "    </font>"
        } else {
          if (ps != "" || ac != 1 || fam_font_axis_tag[i, 1] != "wght" || fam_font_axis_val[i, 1] != clamped_w) {
            fail_xml("invalid_validated_static_ttc_node")
          }
        }
      } else {
        fail_xml("unsupported_ttc_supportedAxes:" sa)
      }
      count_ttc++
      continue
    }

    # Unexpected unpaired NotoSans-Italic.ttf or emoji in non-emoji family
    if (fn == "NotoSans-Italic.ttf" || fn == "NotoColorEmoji.ttf" || fn == "KsuReserved-NotoColorEmoji.ttf") {
      fail_xml("unexpected_target_font_position:" fn)
    }

    # Any non-target font inside this family (e.g. NotoSerifCJK-Regular.ttc fallbackFor="serif") is emitted verbatim
    if (!validate_only) {
      print indent "    " fam_font_raw[i]
    }
  }

  if (!validate_only) {
    print indent "</family>"
  }
}

BEGIN {
  if (mode != "fallback" && mode != "legacy" && mode != "base") {
    fail_xml("invalid_mode_" mode)
  }
  validate_only = (validate_only == 1 || validate_only == "1" || validate_only == "true") ? 1 : 0
  in_comment = 0
  in_family = 0
  in_family_open_tag = 0
  family_count = 0
  xml_state = "BEFORE_ROOT"
  xml_buf = ""
  saw_xml_decl = 0
  saw_before_decl = 0
  saw_familyset_open = 0
  saw_familyset_close = 0
  familyset_version = ""
  error_reason = ""
  cur_family_font_count = 0
  cur_family_ignored = 0
  cur_font_text = ""
  cur_font_ps = ""
  cur_font_saw_axis = 0
  cur_font_has_ital_axis = 0
  cur_font_has_wght_1000_axis = 0

  count_sans_serif = 0
  prev_was_sans_serif = 0
  count_unnamed_western = 0
  count_sys_sans_en = 0
  count_op_sans_en = 0
  count_zh_hans = 0
  count_zh_hant = 0
  count_ja = 0
  count_ja_hentaigana = 0
  count_ko = 0
  count_emoji = 0
  emoji_inserted = 0
  emoji_val_stage = 0

  count_roboto = 0
  count_sysfont = 0
  count_syssans_en = 0
  count_opsans_en = 0
  count_cjk_hans = 0
  count_cjk_hant = 0
  count_serif_hans = 0
  count_serif_hant = 0
  count_ttc = 0
  count_clamp = 0
  count_pin = 0
}

{
  line = $0
  if (NR > 1) {
    saw_before_decl = 1
  }
  if (line ~ /[\001-\010\013\014\016-\037\177]/) {
    fail_xml("illegal_xml_control_char")
  }
  clean_line = strip_line_comments(line)
  if (index(clean_line, "&") > 0) {
    fail_xml("disallowed_ampersand_or_entity")
  }

  if (in_family) {
    family_lines[++family_count] = line

    if (in_family_open_tag) {
      if (index(clean_line, "<") > 0) {
        fail_xml("unexpected_lt_in_family_open_tag")
      }
      gt_pos = index(clean_line, ">")
      if (gt_pos > 0) {
        if (substr(clean_line, gt_pos + 1) ~ /[^[:space:]]/) {
          fail_xml("content_after_family_open_on_same_line")
        }
        in_family_open_tag = 0
      }
    } else {
      if (clean_line ~ /<family([[:space:]>\/]|$)/) {
        fail_xml("nested_or_same_line_family_open")
      }
    }

    advance_xml_state(clean_line)

    if (!in_family_open_tag && clean_line ~ /<\/family([[:space:]>]|$)/) {
      if (clean_line !~ /^[[:space:]]*<\/family[[:space:]]*>[[:space:]]*$/) {
        fail_xml("family_close_not_isolated")
      }
      process_family()
      for (k in family_lines) delete family_lines[k]
      family_count = 0
      in_family = 0
    }
    next
  }

  # Outside <family>
  if (clean_line ~ /<\/family([[:space:]>]|$)/) {
    fail_xml("stray_family_close")
  }

  if (clean_line ~ /<family([[:space:]>\/]|$)/) {
    if (clean_line !~ /^[[:space:]]*<family([[:space:]>\/]|$)/) {
      fail_xml("family_open_not_isolated")
    }
    in_family = 1
    family_count = 1
    family_lines[1] = line
    gt_pos = index(clean_line, ">")
    if (gt_pos > 0) {
      if (substr(clean_line, gt_pos + 1) ~ /[^[:space:]]/) {
        fail_xml("content_after_family_open_on_same_line")
      }
      in_family_open_tag = 0
    } else {
      in_family_open_tag = 1
    }
    advance_xml_state(clean_line)
    next
  }

  advance_xml_state(clean_line)

  if (!validate_only) {
    print line
  }
}

END {
  if (error_reason != "") {
    exit 2
  }
  if (in_comment) {
    fail_xml("unclosed_xml_comment")
  }
  if (xml_buf ~ /[^[:space:]]/) {
    fail_xml("unclosed_tag_at_eof")
  }
  if (in_family || in_family_open_tag) {
    fail_xml("unclosed_family_block")
  }
  if (!saw_familyset_open || !saw_familyset_close || xml_state != "AFTER_ROOT") {
    fail_xml("missing_or_unclosed_familyset_root")
  }
  if (count_sans_serif != 1) {
    fail_xml("sans_serif_count_" count_sans_serif)
  }
  if (count_zh_hans != 1) {
    fail_xml("zh_hans_count_" count_zh_hans)
  }
  if (count_zh_hant != 1) {
    fail_xml("zh_hant_count_" count_zh_hant)
  }
  if (count_ja != 1) {
    fail_xml("ja_count_" count_ja)
  }
  if (count_ko != 1) {
    fail_xml("ko_count_" count_ko)
  }
  if (count_emoji != 1) {
    fail_xml("emoji_count_" count_emoji)
  }

  if (mode == "fallback") {
    if (count_roboto < 2 || count_sysfont != 0 || count_syssans_en != 0 || count_opsans_en != 0 || \
        count_cjk_hans != 0 || count_cjk_hant != 0 || count_serif_hans != 0 || count_serif_hant != 0 || \
        count_ttc != 4) {
      fail_xml("fallback_node_counts_mismatch")
    }
  } else if (mode == "legacy") {
    if (count_sys_sans_en != 1) fail_xml("sys_sans_en_count_" count_sys_sans_en)
    if (count_op_sans_en != 1) fail_xml("op_sans_en_count_" count_op_sans_en)
    if (count_unnamed_western != 1) fail_xml("unnamed_western_count_" count_unnamed_western)
    if (count_sysfont != 9 || count_roboto < 2 || count_syssans_en != 10 || count_opsans_en != 9 || \
        count_cjk_hans != 10 || count_cjk_hant != 10 || count_serif_hans != 1 || count_serif_hant != 1 || \
        count_ttc != 18) {
      fail_xml("legacy_node_counts_mismatch")
    }
  } else if (mode == "base") {
    if (count_sys_sans_en != 1) fail_xml("sys_sans_en_count_" count_sys_sans_en)
    if (count_op_sans_en != 1) fail_xml("op_sans_en_count_" count_op_sans_en)
    if (count_unnamed_western != 0) fail_xml("unnamed_western_count_" count_unnamed_western)
    if (count_sysfont != 0 || count_roboto < 2 || count_syssans_en != 10 || count_opsans_en != 9 || \
        count_cjk_hans != 10 || count_cjk_hant != 10 || count_serif_hans != 1 || count_serif_hant != 1 || \
        count_ttc != 18) {
      fail_xml("base_node_counts_mismatch")
    }
  }

  if (stats != "") {
    print "OK mode=" mode " roboto=" count_roboto " sysfont=" count_sysfont " sys_en=" count_syssans_en " op_en=" count_opsans_en " hans=" count_cjk_hans " hant=" count_cjk_hant " serif_reserved=" (count_serif_hans + count_serif_hant) " ttc=" count_ttc " emoji=" count_emoji " clamp=" count_clamp " pin=" count_pin > stats
    close(stats)
  }
}
