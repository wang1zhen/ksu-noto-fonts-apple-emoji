# BusyBox awk XML transformer and finite-format validator for Android / OxygenOS 16 font configs.
# Supports three explicit modes (-v mode="fallback", -v mode="legacy", or -v mode="base"):
#   - fallback: modern VF configuration (font_fallback.xml, root <familyset> without version)
#   - legacy:   compat configuration (fonts.xml, root <familyset version="..."> with unnamed Roboto after sans-serif)
#   - base:     system_ext base configuration (fonts_base.xml, root <familyset version="..."> without unnamed Roboto after sans-serif)
# Also supports -v validate_only=1 to validate generated XML output using the same
# finite-format state machine and style-uniqueness checks instead of tag counting.
#
# Enforces a strict finite XML format:
#   - Uniform comment stripping (single-line and multi-line <!-- ... -->)
#   - <family ...> opening tag and </family> closing tag must occupy their own logical lines
#   - Tag-whitelist state machine: single <familyset> root, legal nesting of
#     familyset -> family -> font -> axis, and top-level <alias .../> inside familyset
#   - Rejects unknown tags, invalid nesting, unclosed tags/comments, or content after </familyset>
#   - Preserves original CJK <family> blocks intact and prepends a dedicated <family lang="...">
#     containing the new KSU Noto Sans CJK normal font(s) plus verbatim copies of all
#     fallbackFor="..." <font> elements (including child <axis> tags) from the original family.

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
      if (cur_font_text ~ /^KSU-NotoSans/) {
        if (cur_font_has_forbidden_ksu_attr) {
          fail_xml("forbidden_attr_on_ksu_notosans_font")
        }
      }
      if (cur_font_text == "KSU-AppleColorEmoji.ttf") {
        if (cur_family_ignored) {
          fail_xml("ksu_emoji_in_ignored_family")
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

    cur_font_has_forbidden_ksu_attr = 0
    if (("index" in parsed_attrs) || ("postScriptName" in parsed_attrs) || w_num == 1000) {
      cur_font_has_forbidden_ksu_attr = 1
    }
    if (("supportedAxes" in parsed_attrs) && parsed_attrs["supportedAxes"] ~ /ital/) {
      cur_font_has_forbidden_ksu_attr = 1
    }

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
    if (parsed_attrs["tag"] == "ital" || (parsed_attrs["stylevalue"] + 0) == 1000) {
      cur_font_has_forbidden_ksu_attr = 1
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

function emit_modern_western_fonts(indent) {
  print indent "    <font supportedAxes=\"wght\">KSU-NotoSans-Regular-VF.ttf"
  print indent "        <axis tag=\"wdth\" stylevalue=\"100\" />"
  print indent "    </font>"
  print indent "    <font style=\"italic\" supportedAxes=\"wght\">KSU-NotoSans-Italic-VF.ttf"
  print indent "        <axis tag=\"wdth\" stylevalue=\"100\" />"
  print indent "    </font>"
}

function emit_legacy_western_fonts(indent,    w, styles, s_idx, st, file_name) {
  styles[1] = "normal"
  styles[2] = "italic"
  for (w = 100; w <= 900; w += 100) {
    for (s_idx = 1; s_idx <= 2; s_idx++) {
      st = styles[s_idx]
      file_name = (st == "italic") ? "KSU-NotoSans-Italic-VF.ttf" : "KSU-NotoSans-Regular-VF.ttf"
      print indent "    <font weight=\"" w "\" style=\"" st "\">" file_name
      print indent "        <axis tag=\"wdth\" stylevalue=\"100\" />"
      print indent "        <axis tag=\"wght\" stylevalue=\"" w "\" />"
      print indent "    </font>"
    }
  }
}

function emit_modern_cjk_font(indent, cjk_file) {
  print indent "    <font weight=\"400\" style=\"normal\" supportedAxes=\"wght\">" cjk_file "</font>"
}

function emit_legacy_cjk_fonts(indent, cjk_file,    w) {
  for (w = 100; w <= 900; w += 100) {
    print indent "    <font weight=\"" w "\" style=\"normal\">" cjk_file
    print indent "        <axis tag=\"wght\" stylevalue=\"" w "\" />"
    print indent "    </font>"
  }
}

function extract_cjk_fallback_fonts(clean_block, open_end,    body, close_idx, f_start, rel_open_end, f_open_tag, rel_close, full_font_elem, fb_val, normal_count, k) {
  for (k in extracted_fb_fonts) delete extracted_fb_fonts[k]
  extracted_fb_count = 0
  normal_count = 0

  body = substr(clean_block, open_end + 1)
  close_idx = match(body, /<\/family[[:space:]]*>[[:space:]]*$/)
  if (close_idx == 0) {
    fail_xml("cjk_missing_close_family_tag")
  }
  body = substr(body, 1, close_idx - 1)

  while (match(body, /<font([[:space:]>]|$)/)) {
    f_start = RSTART
    if (substr(body, 1, f_start - 1) ~ /[^[:space:]]/) {
      fail_xml("cjk_unexpected_content_before_font")
    }
    body = substr(body, f_start)
    rel_open_end = index(body, ">")
    if (rel_open_end == 0) {
      fail_xml("cjk_unclosed_font_open_tag")
    }
    f_open_tag = substr(body, 1, rel_open_end)
    if (f_open_tag ~ /\/>$/) {
      fail_xml("cjk_self_closing_font_tag")
    }
    rel_close = index(body, "</font>")
    if (rel_close == 0) {
      fail_xml("cjk_unclosed_font_element")
    }
    full_font_elem = substr(body, 1, rel_close + 6)
    body = substr(body, rel_close + 7)

    fb_val = get_attr(f_open_tag, "fallbackFor")
    if (f_open_tag ~ /(^|[[:space:]])fallbackFor([[:space:]=]|$)/ && fb_val == "") {
      fail_xml("cjk_malformed_fallbackFor_attr")
    }
    if (fb_val != "") {
      extracted_fb_fonts[++extracted_fb_count] = full_font_elem
    } else {
      normal_count++
    }
  }

  if (body ~ /[^[:space:]]/) {
    fail_xml("cjk_unexpected_trailing_body_content")
  }
  if (normal_count < 1) {
    fail_xml("cjk_missing_normal_font")
  }
  if (extracted_fb_count < 1) {
    fail_xml("cjk_missing_fallbackFor_font")
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

function process_family(    raw_block, clean_block, open_end, header, indent,
                            fam_name, fam_lang, fam_ignore, norm_lang,
                            cjk_role, cjk_file, i, j, has_font) {
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

  has_font = (clean_block ~ /<font([[:space:]>]|$)/)

  if (validate_only) {
    validate_family_block(clean_block, header, open_end, fam_name, fam_lang, fam_ignore, has_font)
    return
  }

  # 1. Western default sans-serif and OxygenOS English sans families
  if (fam_name == "sans-serif" || ((mode == "legacy" || mode == "base") && (fam_name == "sys-sans-en" || fam_name == "op-sans-en"))) {
    if (fam_lang != "" || fam_ignore == "true" || !has_font) {
      fail_xml("invalid_western_family_" fam_name)
    }
    if (mode == "base") {
      if (fam_name == "sans-serif" && clean_block !~ /Roboto-Regular\.ttf/) {
        fail_xml("unexpected_base_sans_serif_font")
      }
      if (fam_name == "sys-sans-en" && clean_block !~ /SysSans-En-Regular\.ttf/) {
        fail_xml("unexpected_base_sys_sans_en_font")
      }
      if (fam_name == "op-sans-en" && clean_block !~ /OPSans-En-Regular\.ttf/) {
        fail_xml("unexpected_base_op_sans_en_font")
      }
    }
    print indent "<family name=\"" get_attr(header, "name") "\">"
    if (mode == "fallback") {
      emit_modern_western_fonts(indent)
    } else {
      emit_legacy_western_fonts(indent)
    }
    print indent "</family>"
    if (fam_name == "sans-serif") {
      count_sans_serif++
      prev_was_sans_serif = 1
    } else if (fam_name == "sys-sans-en") {
      count_sys_sans_en++
      prev_was_sans_serif = 0
    } else if (fam_name == "op-sans-en") {
      count_op_sans_en++
      prev_was_sans_serif = 0
    }
    return
  }

  # 2. Unnamed default family right after sans-serif in legacy fonts.xml (rejected in base mode)
  if (prev_was_sans_serif == 1 && fam_name == "" && fam_lang == "" && fam_ignore != "true") {
    if (mode == "base") {
      fail_xml("unexpected_unnamed_western_in_base")
    }
    if (mode == "legacy" && count_unnamed_western == 0 && clean_block ~ /Roboto-Regular\.ttf/) {
      prev_was_sans_serif = 0
      if (!has_font) {
        fail_xml("empty_unnamed_western_family")
      }
      print indent "<family>"
      emit_modern_western_fonts(indent)
      print indent "</family>"
      count_unnamed_western++
      return
    }
  }
  prev_was_sans_serif = 0

  # 3. Emoji family (lang="und-Zsye")
  norm_lang = tolower(fam_lang)
  if (norm_lang == "und-zsye") {
    if (fam_ignore == "true") {
      for (i = 1; i <= family_count; i++) print family_lines[i]
      return
    }
    if (!emoji_inserted) {
      if (!has_font) {
        fail_xml("empty_emoji_family")
      }
      print indent "<family lang=\"und-Zsye\">"
      print indent "    <font weight=\"400\" style=\"normal\">KSU-AppleColorEmoji.ttf</font>"
      print indent "</family>"
      emoji_inserted = 1
      count_emoji++
    }
    for (i = 1; i <= family_count; i++) print family_lines[i]
    return
  }

  # 4. CJK locale families: zh-Hans, zh-Hant,zh-Bopo, ja (first is primary, second is Hentaigana), ko
  cjk_role = ""
  cjk_file = ""
  if (fam_lang == "zh-Hans") {
    if (count_zh_hans > 0) {
      fail_xml("duplicate_cjk_family_zh-Hans")
    }
    cjk_role = "zh-Hans"
    cjk_file = "KSU-NotoSansCJKsc-VF.ttf"
  } else if (fam_lang == "zh-Hant,zh-Bopo" || fam_lang == "zh-Bopo,zh-Hant") {
    if (count_zh_hant > 0) {
      fail_xml("duplicate_cjk_family_zh-Hant")
    }
    cjk_role = "zh-Hant"
    cjk_file = "KSU-NotoSansCJKtc-VF.ttf"
  } else if (fam_lang == "ja") {
    if (count_ja == 0) {
      cjk_role = "ja"
      cjk_file = "KSU-NotoSansCJKjp-VF.ttf"
    } else if (count_ja == 1 && count_ja_hentaigana == 0 && clean_block ~ /NotoSerifHentaigana\.ttf/) {
      validate_cjk_family_header(header)
      count_ja_hentaigana++
      for (i = 1; i <= family_count; i++) print family_lines[i]
      return
    } else {
      fail_xml("unexpected_extra_ja_family")
    }
  } else if (fam_lang == "ko") {
    if (count_ko > 0) {
      fail_xml("duplicate_cjk_family_ko")
    }
    cjk_role = "ko"
    cjk_file = "KSU-NotoSansCJKkr-VF.ttf"
  }

  if (cjk_role != "") {
    if (!has_font) {
      fail_xml("empty_cjk_family_" cjk_role)
    }
    validate_cjk_family_header(header)
    if (cjk_role == "ja" && clean_block ~ /Hentaigana/) {
      fail_xml("unexpected_hentaigana_as_primary_ja")
    }
    extract_cjk_fallback_fonts(clean_block, open_end)

    # Prepend a dedicated <family lang="..."> containing the new KSU Noto Sans CJK
    # normal font(s) plus verbatim copies of all fallbackFor <font> elements,
    # then emit the original CJK <family> untouched.
    print indent "<family lang=\"" fam_lang "\">"
    if (mode == "fallback") {
      emit_modern_cjk_font(indent, cjk_file)
    } else {
      emit_legacy_cjk_fonts(indent, cjk_file)
    }
    for (j = 1; j <= extracted_fb_count; j++) {
      print indent "    " extracted_fb_fonts[j]
    }
    print indent "</family>"

    for (i = 1; i <= family_count; i++) print family_lines[i]

    if (cjk_role == "zh-Hans") count_zh_hans++
    else if (cjk_role == "zh-Hant") count_zh_hant++
    else if (cjk_role == "ja") count_ja++
    else if (cjk_role == "ko") count_ko++
    return
  }

  # All other families are emitted verbatim.
  for (i = 1; i <= family_count; i++) print family_lines[i]
}

function validate_family_block(clean_block, header, open_end, fam_name, fam_lang, fam_ignore, has_font,    norm_lang, cjk_role, cjk_file) {
  if (!has_font) {
    fail_xml("empty_family_in_validate")
  }
  if (fam_name == "sans-serif" || ((mode == "legacy" || mode == "base") && (fam_name == "sys-sans-en" || fam_name == "op-sans-en"))) {
    if (fam_lang != "" || fam_ignore == "true") {
      fail_xml("invalid_western_family_" fam_name)
    }
    if (clean_block !~ /KSU-NotoSans-Regular-VF\.ttf/ || clean_block !~ /KSU-NotoSans-Italic-VF\.ttf/) {
      fail_xml("missing_ksu_western_fonts_in_" fam_name)
    }
    if (fam_name == "sans-serif") {
      count_sans_serif++
      prev_was_sans_serif = 1
    } else if (fam_name == "sys-sans-en") {
      count_sys_sans_en++
      prev_was_sans_serif = 0
    } else if (fam_name == "op-sans-en") {
      count_op_sans_en++
      prev_was_sans_serif = 0
    }
    return
  }

  if (prev_was_sans_serif == 1 && fam_name == "" && fam_lang == "" && fam_ignore != "true") {
    if (mode == "base") {
      fail_xml("unexpected_unnamed_western_in_base")
    }
    if (mode == "legacy" && count_unnamed_western == 0) {
      prev_was_sans_serif = 0
      if (clean_block ~ /KSU-NotoSans-Regular-VF\.ttf/ && clean_block ~ /KSU-NotoSans-Italic-VF\.ttf/) {
        count_unnamed_western++
        return
      }
    }
  }
  prev_was_sans_serif = 0

  norm_lang = tolower(fam_lang)
  if (norm_lang == "und-zsye") {
    if (fam_ignore == "true") {
      if (clean_block ~ /KSU-AppleColorEmoji\.ttf/) {
        fail_xml("ksu_emoji_in_ignored_family")
      }
      return
    }
    if (!emoji_inserted) {
      if (clean_block !~ /KSU-AppleColorEmoji\.ttf/) {
        fail_xml("first_active_emoji_not_ksu")
      }
      emoji_inserted = 1
      count_emoji++
    }
    return
  }

  cjk_role = ""
  cjk_file = ""
  if (fam_lang == "zh-Hans") {
    cjk_role = "zh-Hans"
    cjk_file = "KSU-NotoSansCJKsc-VF.ttf"
  } else if (fam_lang == "zh-Hant,zh-Bopo" || fam_lang == "zh-Bopo,zh-Hant") {
    cjk_role = "zh-Hant"
    cjk_file = "KSU-NotoSansCJKtc-VF.ttf"
  } else if (fam_lang == "ja") {
    cjk_role = "ja"
    cjk_file = "KSU-NotoSansCJKjp-VF.ttf"
  } else if (fam_lang == "ko") {
    cjk_role = "ko"
    cjk_file = "KSU-NotoSansCJKkr-VF.ttf"
  }

  if (cjk_role != "") {
    validate_cjk_family_header(header)
    if (cjk_role == "ja" && count_ja == 2 && count_ja_hentaigana == 0 && clean_block ~ /NotoSerifHentaigana\.ttf/) {
      count_ja_hentaigana++
      return
    }
    extract_cjk_fallback_fonts(clean_block, open_end)
    if (cjk_role == "zh-Hans") {
      if (count_zh_hans == 0) {
        if (index(clean_block, cjk_file) == 0) fail_xml("missing_prepended_cjk_sc")
      } else if (count_zh_hans == 1) {
        if (clean_block ~ /KSU-NotoSansCJK/) fail_xml("polluted_original_cjk_sc")
      } else {
        fail_xml("unexpected_extra_zh_hans_family")
      }
      count_zh_hans++
    } else if (cjk_role == "zh-Hant") {
      if (count_zh_hant == 0) {
        if (index(clean_block, cjk_file) == 0) fail_xml("missing_prepended_cjk_tc")
      } else if (count_zh_hant == 1) {
        if (clean_block ~ /KSU-NotoSansCJK/) fail_xml("polluted_original_cjk_tc")
      } else {
        fail_xml("unexpected_extra_zh_hant_family")
      }
      count_zh_hant++
    } else if (cjk_role == "ja") {
      if (count_ja == 0) {
        if (index(clean_block, cjk_file) == 0) fail_xml("missing_prepended_cjk_jp")
      } else if (count_ja == 1) {
        if (clean_block ~ /KSU-NotoSansCJK/ || clean_block ~ /Hentaigana/) fail_xml("invalid_original_cjk_jp")
      } else {
        fail_xml("unexpected_extra_ja_family")
      }
      count_ja++
    } else if (cjk_role == "ko") {
      if (count_ko == 0) {
        if (index(clean_block, cjk_file) == 0) fail_xml("missing_prepended_cjk_kr")
      } else if (count_ko == 1) {
        if (clean_block ~ /KSU-NotoSansCJK/) fail_xml("polluted_original_cjk_kr")
      } else {
        fail_xml("unexpected_extra_ko_family")
      }
      count_ko++
    }
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
  cur_font_saw_axis = 0
  cur_font_has_forbidden_ksu_attr = 0

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
  if (mode == "legacy") {
    if (count_sys_sans_en != 1) {
      fail_xml("sys_sans_en_count_" count_sys_sans_en)
    }
    if (count_op_sans_en != 1) {
      fail_xml("op_sans_en_count_" count_op_sans_en)
    }
    if (count_unnamed_western != 1) {
      fail_xml("unnamed_western_count_" count_unnamed_western)
    }
  }
  if (mode == "base") {
    if (count_sys_sans_en != 1) {
      fail_xml("sys_sans_en_count_" count_sys_sans_en)
    }
    if (count_op_sans_en != 1) {
      fail_xml("op_sans_en_count_" count_op_sans_en)
    }
    if (count_unnamed_western != 0) {
      fail_xml("unnamed_western_count_" count_unnamed_western)
    }
  }
  expected_cjk = validate_only ? 2 : 1
  if (count_zh_hans != expected_cjk) {
    fail_xml("zh_hans_count_" count_zh_hans)
  }
  if (count_zh_hant != expected_cjk) {
    fail_xml("zh_hant_count_" count_zh_hant)
  }
  if (count_ja != expected_cjk) {
    fail_xml("ja_count_" count_ja)
  }
  if (count_ko != expected_cjk) {
    fail_xml("ko_count_" count_ko)
  }
  if (count_emoji != 1) {
    fail_xml("emoji_count_" count_emoji)
  }

  if (stats != "") {
    print "OK mode=" mode " sans=" count_sans_serif " unnamed=" count_unnamed_western " sys_en=" count_sys_sans_en " op_en=" count_op_sans_en " sc=" count_zh_hans " tc=" count_zh_hant " ja=" count_ja " ko=" count_ko " emoji=" count_emoji > stats
    close(stats)
  }
}
