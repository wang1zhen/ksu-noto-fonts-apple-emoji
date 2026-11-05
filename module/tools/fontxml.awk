# Install-time Android font XML generator for ksu_noto_fonts_apple_emoji (v2.0.0)
# Adapted from font-settings/tools/fontxml.awk (MIT License, Copyright (c) 2026 yuzlyn)

function fail_xml(code) {
  exit_error = code
  exit 1
}

function attribute(tag, name,    pattern, value) {
  pattern = "(^|[[:space:]])" name "[[:space:]]*=[[:space:]]*(\"[^\"]*\"|'[^']*')"
  if (!match(tag, pattern)) return ""
  value = substr(tag, RSTART, RLENGTH)
  sub(/^[[:space:]]*[^=]+=[[:space:]]*/, "", value)
  return substr(value, 2, length(value) - 2)
}

function valid_attrs(s,    rest) {
  rest = s
  while (rest !~ /^[[:space:]]*$/) {
    if (!match(rest, /^[[:space:]]+[A-Za-z_][A-Za-z0-9_.:-]*[[:space:]]*=[[:space:]]*("[^"]*"|'[^']*')/)) return 0
    rest = substr(rest, RSTART + RLENGTH)
  }
  return 1
}

function check_open_tag(tag, name, allow_empty,    inner) {
  if (tag !~ ("^<" name "([[:space:]>])") || tag !~ />$/) return 0
  inner = substr(tag, length(name) + 2, length(tag) - length(name) - 2)
  if (!allow_empty && inner ~ /^[[:space:]]*$/) return 0
  return valid_attrs(inner)
}

function check_self_tag(tag, name,    inner) {
  if (tag !~ ("^<" name "[[:space:]]") || tag !~ /\/>$/) return 0
  inner = substr(tag, length(name) + 2, length(tag) - length(name) - 3)
  if (inner ~ /^[[:space:]]*$/) return 0
  return valid_attrs(inner)
}

function has_lang(norm, tok) {
  return index(norm, "," tok ",") > 0 || index(norm, "," tok "-") > 0
}

function cjk_role(lang,    norm, sc, tc, ja, ko, hits) {
  norm = "," tolower(lang) ","
  gsub(/[[:space:]_;]+/, ",", norm)
  gsub(/_/, "-", norm)
  gsub(/,+/, ",", norm)

  sc = (has_lang(norm, "zh-hans") || has_lang(norm, "zh-cn") || has_lang(norm, "zh-sg")) ? 1 : 0
  tc = (has_lang(norm, "zh-hant") || has_lang(norm, "zh-bopo") || has_lang(norm, "zh-tw") || has_lang(norm, "zh-hk") || has_lang(norm, "zh-mo") || has_lang(norm, "yue")) ? 1 : 0
  ja = has_lang(norm, "ja") ? 1 : 0
  ko = has_lang(norm, "ko") ? 1 : 0

  hits = sc + tc + ja + ko
  if (hits > 1) fail_xml("mixed_cjk_region")
  if (sc) return "cjk_sc"
  if (tc) return "cjk_tc"
  if (ja) return "cjk_jp"
  if (ko) return "cjk_kr"
  if (has_lang(norm, "zh")) fail_xml("ambiguous_zh_region")
  return ""
}

function family_role(header, block,    name, lang, ignore, cjk, rest, fname) {
  name = tolower(attribute(header, "name"))
  lang = attribute(header, "lang")
  ignore = tolower(attribute(header, "ignore"))

  if (ignore == "true") return ""

  if (name == "sans-serif" || name == "sys-sans-en" || name == "op-sans-en") {
    if (lang != "") fail_xml("unsupported_family_structure")
    return "western"
  }

  if (lang != "") {
    if (tolower(lang) ~ /(^|[,;[:space:]])und-zsye([,;[:space:]]|$)/) {
      if (emoji_fonts > 0) return ""
      rest = block
      while (match(rest, /[A-Za-z0-9._-]+\.(ttf|otf|ttc)/)) {
        fname = substr(rest, RSTART, RLENGTH)
        if (fname !~ /([Ff]lags|[Cc]ompat)/) return "emoji"
        rest = substr(rest, RSTART + RLENGTH)
      }
      return ""
    }
    cjk = cjk_role(lang)
    if (cjk != "") {
      if (cjk == "cjk_jp" && block ~ /[Hh]entaigana/) return ""
      return cjk
    }
    return ""
  }

  if (allow_unnamed == 1 && unnamed_default == 0 && name == "" && lang == "" &&
      block ~ /\.(ttf|otf|ttc)/ && block !~ /[Ee]moji|[Ss]ymbol|[Mm]ath/) {
    unnamed_default = 1
    return "western"
  }
  return ""
}

function clamp_weight(w) {
  if (w !~ /^[0-9]+$/) return 400
  w = w + 0
  if (w < 100) return 100
  if (w > 900) return 900
  return w
}

function emit_family(    header, block, role, indent, i, j, k, trimmed, opening, after_open,
                         body_line, weight, style, fallback, sup_axes, has_wght_axis,
                         nslot, s, line, file, wval, fcnt) {
  if (family_lines[family_count] !~ /^[[:space:]]*<\/family>[[:space:]]*$/) {
    fail_xml("unsupported_family_structure")
  }
  header = family_lines[1]
  sub(/^[[:space:]]*/, "", header)
  j = 1
  while (j < family_count && header !~ />/) {
    if (family_lines[j] ~ /<font|<\/font>|<axis|<alias|<\/family>/) fail_xml("unsupported_family_structure")
    j++
    header = header " " family_lines[j]
  }
  gsub(/[\r\n\t]+/, " ", header)
  sub(/[[:space:]]*$/, "", header)
  if (!check_open_tag(header, "family", 1)) {
    fail_xml("unsupported_family_structure")
  }

  block = ""
  for (i = 1; i <= family_count; i++) {
    block = block " " family_lines[i]
  }
  if (block ~ /KSU-NotoSans|KSU-AppleColorEmoji|KsuReserved-|KsuAppleColorEmoji|(^|[^A-Za-z0-9._-])NotoSans-Italic\.ttf([^A-Za-z0-9._-]|$)/) {
    fail_xml("self_overlay_detected")
  }

  indent = family_lines[1]
  sub(/[^[:space:]].*$/, "", indent)

  nslot = 0
  i = j + 1
  while (i < family_count) {
    trimmed = family_lines[i]
    sub(/^[[:space:]]+/, "", trimmed)
    sub(/[[:space:]]+$/, "", trimmed)
    if (trimmed == "") {
      i++
      continue
    }
    if (trimmed !~ /^<font([[:space:]>]|$)/) fail_xml("unsupported_family_structure")

    opening = trimmed
    while (i < family_count && opening !~ />/) {
      if (opening ~ /<\/font>|<axis|<family|<\/family>/) fail_xml("unsupported_family_structure")
      i++
      body_line = family_lines[i]
      sub(/^[[:space:]]+/, "", body_line)
      sub(/[[:space:]]+$/, "", body_line)
      if (body_line ~ /^</) fail_xml("unsupported_family_structure")
      opening = opening " " body_line
    }
    if (opening !~ />/) fail_xml("unsupported_family_structure")
    gsub(/[\r\n\t]+/, " ", opening)
    after_open = opening
    sub(/^<font[^>]*>[[:space:]]*/, "", after_open)
    sub(/>.*/, ">", opening)
    if (!check_open_tag(opening, "font", 1)) fail_xml("unsupported_family_structure")

    weight = attribute(opening, "weight")
    style = tolower(attribute(opening, "style"))
    fallback = attribute(opening, "fallbackFor")
    sup_axes = tolower(attribute(opening, "supportedAxes"))
    has_wght_axis = (sup_axes ~ /(^|[,[:space:]])wght([,[:space:]]|$)/) ? 1 : 0

    if (weight == "" && !has_wght_axis) weight = "400"
    if (style != "" && style != "normal" && style != "italic") {
      fail_xml("unsupported_font_style")
    }

    nslot++
    slot_weight[nslot] = weight
    slot_style[nslot] = style
    slot_fallback[nslot] = fallback
    slot_wght_axis[nslot] = has_wght_axis

    fcnt = 0
    if (after_open != "") {
      if (after_open ~ /^[A-Za-z0-9._-]+\.(ttf|otf|ttc)[[:space:]]*<\/font>$/) {
        fcnt = 1
        i++
        continue
      }
      if (after_open !~ /^[A-Za-z0-9._-]+\.(ttf|otf|ttc)$/) fail_xml("unsupported_family_structure")
      fcnt = 1
    }

    i++
    while (i < family_count) {
      body_line = family_lines[i]
      sub(/^[[:space:]]+/, "", body_line)
      sub(/[[:space:]]+$/, "", body_line)
      if (body_line == "") {
        i++
        continue
      }
      if (body_line == "</font>") break
      if (body_line ~ /^[A-Za-z0-9._-]+\.(ttf|otf|ttc)[[:space:]]*<\/font>$/) {
        fcnt++
        break
      }
      if (body_line ~ /^[A-Za-z0-9._-]+\.(ttf|otf|ttc)$/) {
        fcnt++
        i++
        continue
      }
      if (check_self_tag(body_line, "axis")) {
        i++
        continue
      }
      fail_xml("unsupported_family_structure")
    }
    if (i >= family_count || fcnt != 1) fail_xml("unsupported_family_structure")
    i++
  }

  role = family_role(header, block)
  if (role == "") {
    for (k = 1; k <= family_count; k++) print family_lines[k]
    return
  }

  if (nslot == 0) fail_xml("empty_target_family")

  print indent header

  if (role == "emoji") {
    line = indent "    <font"
    if (slot_weight[1] != "") line = line " weight=\"" slot_weight[1] "\""
    else line = line " weight=\"400\""
    if (slot_style[1] != "") line = line " style=\"" slot_style[1] "\""
    else line = line " style=\"normal\""
    if (slot_fallback[1] != "") line = line " fallbackFor=\"" slot_fallback[1] "\""
    line = line ">" emoji_file "</font>"
    print line
    print indent "</family>"
    emoji_fonts++
    return
  }

  for (s = 1; s <= nslot; s++) {
    if (role == "western") {
      file = (slot_style[s] == "italic") ? western_italic : western_regular
    } else if (role == "cjk_sc") {
      file = cjk_sc_file
    } else if (role == "cjk_tc") {
      file = cjk_tc_file
    } else if (role == "cjk_jp") {
      file = cjk_jp_file
    } else if (role == "cjk_kr") {
      file = cjk_kr_file
    }

    line = indent "    <font"
    if (slot_weight[s] != "") line = line " weight=\"" slot_weight[s] "\""
    if (slot_style[s] != "") line = line " style=\"" slot_style[s] "\""
    if (slot_fallback[s] != "") line = line " fallbackFor=\"" slot_fallback[s] "\""
    if (slot_wght_axis[s] == 1) line = line " supportedAxes=\"wght\""
    line = line ">"
    print line
    print indent "        " file
    if (slot_wght_axis[s] == 0) {
      wval = clamp_weight(slot_weight[s])
      print indent "        <axis tag=\"wght\" stylevalue=\"" wval "\"/>"
    }
    print indent "    </font>"
  }
  print indent "</family>"

  if (role == "western") western_fonts++
  else if (role == "cjk_sc") cjk_sc_fonts++
  else if (role == "cjk_tc") cjk_tc_fonts++
  else if (role == "cjk_jp") cjk_jp_fonts++
  else if (role == "cjk_kr") cjk_kr_fonts++
}

function handle_active_line(line,    trimmed, inner) {
  trimmed = line
  sub(/^[[:space:]]+/, "", trimmed)
  sub(/[[:space:]]+$/, "", trimmed)

  if (in_family) {
    if (trimmed ~ /^<family([[:space:]>]|$)/ || trimmed ~ /<familyset/ || trimmed ~ /<\/familyset>/) {
      fail_xml("nested_family_structure")
    }
    family_lines[++family_count] = line
    if (trimmed ~ /<\/family>/) {
      if (trimmed !~ /^<\/family>$/) fail_xml("unsupported_family_structure")
      emit_family()
      delete family_lines
      family_count = 0
      in_family = 0
    }
    return
  }

  if (trimmed == "") {
    print line
    return
  }

  if (seen_familyset_close) fail_xml("content_after_familyset_close")

  if (!seen_familyset) {
    if (trimmed ~ /^<\?xml[[:space:]]/ && trimmed ~ /\?>$/) {
      inner = substr(trimmed, 6, length(trimmed) - 7)
      if (seen_xml_decl || inner ~ /^[[:space:]]*$/ || !valid_attrs(inner)) fail_xml("invalid_xml_decl")
      seen_xml_decl = 1
      print line
      return
    }
    if (check_open_tag(trimmed, "familyset", 1)) {
      seen_familyset = 1
      print line
      return
    }
    fail_xml("unexpected_line_before_root")
  }

  if (trimmed == "</familyset>") {
    seen_familyset_close = 1
    print line
    return
  }

  if (check_self_tag(trimmed, "alias")) {
    print line
    return
  }

  if (trimmed ~ /^<family([[:space:]>]|$)/) {
    if (trimmed ~ /<\/family>/) fail_xml("unsupported_family_structure")
    in_family = 1
    family_count = 1
    family_lines[1] = line
    return
  }

  fail_xml("unexpected_root_element")
}

BEGIN {
  in_family = 0
  in_comment = 0
  family_count = 0
  seen_xml_decl = 0
  seen_familyset = 0
  seen_familyset_close = 0
  unnamed_default = 0
  exit_error = ""

  western_fonts = 0
  cjk_sc_fonts = 0
  cjk_tc_fonts = 0
  cjk_jp_fonts = 0
  cjk_kr_fonts = 0
  emoji_fonts = 0

  if (western_regular == "") western_regular = "KSU-NotoSans-Regular-VF.ttf"
  if (western_italic == "") western_italic = "KSU-NotoSans-Italic-VF.ttf"
  if (cjk_sc_file == "") cjk_sc_file = "KSU-NotoSansCJKsc-VF.ttf"
  if (cjk_tc_file == "") cjk_tc_file = "KSU-NotoSansCJKtc-VF.ttf"
  if (cjk_jp_file == "") cjk_jp_file = "KSU-NotoSansCJKjp-VF.ttf"
  if (cjk_kr_file == "") cjk_kr_file = "KSU-NotoSansCJKkr-VF.ttf"
  if (emoji_file == "") emoji_file = "KSU-AppleColorEmoji.ttf"
}

{
  raw = $0
  rest = raw
  active = ""

  while (rest != "") {
    if (in_comment) {
      idx = index(rest, "-->")
      if (idx == 0) {
        rest = ""
      } else {
        in_comment = 0
        rest = substr(rest, idx + 3)
      }
    } else {
      idx = index(rest, "<!--")
      if (idx == 0) {
        active = active rest
        rest = ""
      } else {
        active = active substr(rest, 1, idx - 1)
        in_comment = 1
        rest = substr(rest, idx + 4)
      }
    }
  }

  if (raw ~ /<!--/ || raw ~ /-->/ || in_comment) {
    if (active !~ /^[[:space:]]*$/) {
      fail_xml("comment_shares_tag_line")
    }
    if (in_family) next
    print raw
    next
  }

  handle_active_line(raw)
}

END {
  if (exit_error != "") exit 1
  if (in_comment || in_family || !seen_familyset || !seen_familyset_close) exit 1
  if (stats != "") {
    print western_fonts, cjk_sc_fonts, cjk_tc_fonts, cjk_jp_fonts, cjk_kr_fonts, emoji_fonts > stats
  }
}
