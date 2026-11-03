#!/usr/bin/env python3
"""Independent host-side XML output verifier for ksu-noto-fonts-apple-emoji.

Parses original and transformed font XML files using xml.etree.ElementTree and
verifies structural and semantic invariants:
1. Root <familyset> tag and version attribute match mode ('fallback' vs 'legacy').
2. Default sans-serif (and in legacy mode: unnamed Roboto family after sans-serif,
   sys-sans-en, op-sans-en) are replaced with KSU-NotoSans-Regular-VF.ttf and
   KSU-NotoSans-Italic-VF.ttf, wdth=100, weights 100..900, without Roboto ital
   axis, postScriptName, or weight 1000.
3. Non-target named families (sans-serif-condensed, roboto-flex, op-sans-num,
   serif, monospace, etc.), other language families (e.g. und-Arab), and all
   <alias> elements are preserved verbatim.
4. CJK locale families (zh-Hans, zh-Hant,zh-Bopo, first ja, ko) prepend a new
   dedicated <family lang="..."> containing KSU-NotoSansCJK{sc,tc,jp,kr}-VF.ttf
   plus verbatim copies of all original fallbackFor="..." <font> elements
   (including child <axis> tags), while preserving the original CJK <family>
   blocks completely untouched immediately after.
5. Within every <family>, font styles are unique per (fallbackFor, weight, style)
   so Android's FontFamily.Builder never encounters duplicate weight/slant within
   the same fallback target, without false positives across different fallbackFor
   targets. Specialized routing (e.g. serif) keeps the original primary font.
6. The second ja family (NotoSerifHentaigana.ttf) is preserved untouched.
7. KSU-AppleColorEmoji.ttf is inserted in a new <family lang="und-Zsye"> (without
   ignore="true") immediately before the first active und-Zsye family, while
   preserving any prior ignore="true" family (NotoColorEmojiLegacy.ttf) and
   subsequent active emoji families (NotoColorEmoji.ttf, NotoColorEmojiFlags.ttf).
8. Commented-out legacy CJK OTC blocks in raw text remain untouched.
"""

import argparse
import re
import sys
import xml.etree.ElementTree as ET


def normalize_elem(elem: ET.Element) -> tuple:
    children = tuple(normalize_elem(c) for c in list(elem))
    text = (elem.text or "").strip()
    return (elem.tag, tuple(sorted(elem.attrib.items())), text, children)


def font_filename(font_elem: ET.Element) -> str:
    return (font_elem.text or "").strip()


def font_axes(font_elem: ET.Element) -> dict:
    axes = {}
    for child in font_elem:
        if child.tag == "axis":
            axes[child.attrib.get("tag", "")] = child.attrib.get("stylevalue", "")
    return axes


def assert_family_style_uniqueness(fam: ET.Element, label: str) -> None:
    """Verify (weight, style) validity and uniqueness within each fallbackFor group of a <family>.

    Android parses weight with Integer.parseInt(weightStr) (default 400) and checks
    "italic".equals(styleStr) (treating any non-"italic" string as upright/normal),
    then partitions a <family>'s <font> children by fallbackFor (default "" vs
    named target like "serif") and builds a separate FontFamily.Builder for each
    partition. Duplicate effective (weight_int, is_italic) within the same fallbackFor
    partition throws in FontFamily.Builder. We enforce both strict canonical scalar
    syntax (weight in [1, 1000] without leading zeros, style in {"normal", "italic"})
    and uniqueness under Android's effective (weight_int, is_italic) semantics.
    """
    seen_by_target: dict[str, set[tuple[int, bool]]] = {}
    for idx, child in enumerate(fam):
        if child.tag != "font":
            raise AssertionError(f"{label}: unexpected non-font child <{child.tag}> in <family>")
        target = child.attrib.get("fallbackFor", "")
        weight_raw = child.attrib.get("weight", "400")
        style_raw = child.attrib.get("style", "normal")
        try:
            weight_int = int(weight_raw, 10)
        except ValueError as exc:
            raise AssertionError(f"{label}: non-integer weight={weight_raw!r} at font[{idx}]") from exc
        is_italic = style_raw == "italic"
        group = seen_by_target.setdefault(target, set())
        key = (weight_int, is_italic)
        if key in group:
            raise AssertionError(
                f"{label}: duplicate effective (weight={weight_int}, italic={is_italic}) "
                f"from raw (weight={weight_raw!r}, style={style_raw!r}) within fallbackFor={target!r} at font[{idx}]"
            )
        group.add(key)
        if not re.fullmatch(r"[1-9][0-9]*", weight_raw) or not (1 <= weight_int <= 1000):
            raise AssertionError(f"{label}: non-canonical or out-of-range weight={weight_raw!r} at font[{idx}]")
        if style_raw not in ("normal", "italic"):
            raise AssertionError(f"{label}: unsupported font style={style_raw!r} at font[{idx}]")


def resolve_effective_route_fonts(families: list[ET.Element], target_chain: str) -> list[ET.Element]:
    """Simulate Android SystemFonts pushFamilyToFallback routing for a locale's families.

    For a given named fallback chain (e.g. 'serif') or default chain (''):
    - If target_chain == '': collects normal fonts (fallbackFor is None) from each family.
    - If target_chain != '': for each family, if the family contains any <font fallbackFor=target_chain>,
      those specific fonts are routed to target_chain; otherwise (if the family has no
      fallbackFor=target_chain entries), its normal fonts are routed to target_chain!
    """
    routed: list[ET.Element] = []
    for fam in families:
        if fam.attrib.get("ignore", "").lower() == "true":
            continue
        fonts = [c for c in fam if c.tag == "font"]
        normal_fonts = [c for c in fonts if "fallbackFor" not in c.attrib]
        if target_chain == "":
            routed.extend(normal_fonts)
        else:
            specific_fonts = [c for c in fonts if c.attrib.get("fallbackFor") == target_chain]
            if specific_fonts:
                routed.extend(specific_fonts)
            else:
                routed.extend(normal_fonts)
    return routed


def assert_modern_western_family(fam: ET.Element, label: str) -> None:
    fonts = [c for c in fam if c.tag == "font"]
    if len(fonts) != 2:
        raise AssertionError(f"{label}: expected 2 <font> entries, got {len(fonts)}")

    reg, ita = fonts[0], fonts[1]
    if font_filename(reg) != "KSU-NotoSans-Regular-VF.ttf":
        raise AssertionError(f"{label}: first font must be KSU-NotoSans-Regular-VF.ttf, got {font_filename(reg)}")
    if reg.attrib != {"supportedAxes": "wght"}:
        raise AssertionError(f"{label}: unexpected attributes on regular font: {reg.attrib}")
    if font_axes(reg) != {"wdth": "100"}:
        raise AssertionError(f"{label}: regular font axes must be wdth=100, got {font_axes(reg)}")

    if font_filename(ita) != "KSU-NotoSans-Italic-VF.ttf":
        raise AssertionError(f"{label}: second font must be KSU-NotoSans-Italic-VF.ttf, got {font_filename(ita)}")
    if ita.attrib != {"style": "italic", "supportedAxes": "wght"}:
        raise AssertionError(f"{label}: unexpected attributes on italic font: {ita.attrib}")
    if font_axes(ita) != {"wdth": "100"}:
        raise AssertionError(f"{label}: italic font axes must be wdth=100, got {font_axes(ita)}")


def assert_legacy_western_family(fam: ET.Element, label: str) -> None:
    fonts = [c for c in fam if c.tag == "font"]
    if len(fonts) != 18:
        raise AssertionError(f"{label}: expected 18 <font> entries (100..900 normal+italic), got {len(fonts)}")

    idx = 0
    for w in range(100, 1000, 100):
        for st, expected_file in [("normal", "KSU-NotoSans-Regular-VF.ttf"), ("italic", "KSU-NotoSans-Italic-VF.ttf")]:
            f = fonts[idx]
            idx += 1
            if font_filename(f) != expected_file:
                raise AssertionError(f"{label}[{idx}]: expected {expected_file}, got {font_filename(f)}")
            if f.attrib != {"weight": str(w), "style": st}:
                raise AssertionError(f"{label}[{idx}]: unexpected font attrib {f.attrib}")
            if font_axes(f) != {"wdth": "100", "wght": str(w)}:
                raise AssertionError(f"{label}[{idx}]: unexpected axes {font_axes(f)}")


def verify_pair(orig_path: str, out_path: str, mode: str) -> None:
    with open(orig_path, "r", encoding="utf-8") as f:
        orig_raw = f.read()
    with open(out_path, "r", encoding="utf-8") as f:
        out_raw = f.read()

    if "EXCERPT FIXTURE ONLY" in orig_raw and "EXCERPT FIXTURE ONLY" not in out_raw:
        raise AssertionError(f"{out_path}: lost excerpt comment header")

    if mode == "legacy" and "Commented-out old CJK OTC families MUST remain untouched" in orig_raw:
        if "Commented-out old CJK OTC families MUST remain untouched" not in out_raw:
            raise AssertionError(f"{out_path}: commented-out CJK OTC block was altered or removed")

    orig_tree = ET.parse(orig_path)
    out_tree = ET.parse(out_path)
    orig_root = orig_tree.getroot()
    out_root = out_tree.getroot()

    if out_root.tag != "familyset":
        raise AssertionError(f"{out_path}: root tag is {out_root.tag}, expected familyset")
    if out_root.attrib != orig_root.attrib:
        raise AssertionError(f"{out_path}: root attributes changed from {orig_root.attrib} to {out_root.attrib}")
    if mode == "fallback" and "version" in out_root.attrib:
        raise AssertionError(f"{out_path}: fallback familyset must not have version attribute")
    if mode == "legacy" and "version" not in out_root.attrib:
        raise AssertionError(f"{out_path}: legacy familyset must have version attribute")

    for child in out_root:
        if child.tag not in ("family", "alias"):
            raise AssertionError(f"{out_path}: unexpected child tag <{child.tag}> under <familyset>")

    # Verify all <alias> elements are identical
    orig_aliases = [normalize_elem(e) for e in orig_root if e.tag == "alias"]
    out_aliases = [normalize_elem(e) for e in out_root if e.tag == "alias"]
    if orig_aliases != out_aliases:
        raise AssertionError(f"{out_path}: <alias> elements were modified")

    orig_families = [e for e in orig_root if e.tag == "family"]
    out_families = [e for e in out_root if e.tag == "family"]
    if len(out_families) != len(orig_families) + 5:
        raise AssertionError(
            f"{out_path}: expected +5 <family> (4 CJK + 1 Apple Emoji), got {len(orig_families)} -> {len(out_families)}"
        )

    # Verify per-(fallbackFor, weight, style) uniqueness on every <family> in output
    for fam_idx, fam in enumerate(out_families):
        fam_desc = fam.attrib.get("name") or fam.attrib.get("lang") or f"unnamed#{fam_idx}"
        assert_family_style_uniqueness(fam, f"{out_path}:family[{fam_idx}]({fam_desc})")

    # Check Western families
    sans_fams = [f for f in out_families if f.attrib.get("name") == "sans-serif"]
    if len(sans_fams) != 1:
        raise AssertionError(f"{out_path}: expected 1 sans-serif family, got {len(sans_fams)}")
    if mode == "fallback":
        assert_modern_western_family(sans_fams[0], "fallback:sans-serif")
    else:
        assert_legacy_western_family(sans_fams[0], "legacy:sans-serif")
        sans_idx = out_families.index(sans_fams[0])
        unnamed_fam = out_families[sans_idx + 1]
        if unnamed_fam.attrib != {}:
            raise AssertionError(f"{out_path}: expected unnamed family after sans-serif")
        assert_modern_western_family(unnamed_fam, "legacy:unnamed-after-sans-serif")

        for oplus_name in ("sys-sans-en", "op-sans-en"):
            matches = [f for f in out_families if f.attrib.get("name") == oplus_name]
            if len(matches) != 1:
                raise AssertionError(f"{out_path}: expected 1 {oplus_name} family, got {len(matches)}")
            assert_legacy_western_family(matches[0], f"legacy:{oplus_name}")

    # Check non-target named families are completely untouched
    for untouched_name in ("sans-serif-condensed", "roboto-flex", "op-sans-num", "serif", "monospace"):
        orig_u = [normalize_elem(f) for f in orig_families if f.attrib.get("name") == untouched_name]
        out_u = [normalize_elem(f) for f in out_families if f.attrib.get("name") == untouched_name]
        if orig_u != out_u:
            raise AssertionError(f"{out_path}: non-target family '{untouched_name}' was modified")

    # Check non-CJK language families (e.g. und-Arab) untouched
    orig_arab = [normalize_elem(f) for f in orig_families if f.attrib.get("lang") == "und-Arab"]
    out_arab = [normalize_elem(f) for f in out_families if f.attrib.get("lang") == "und-Arab"]
    if orig_arab != out_arab:
        raise AssertionError(f"{out_path}: non-CJK language family 'und-Arab' was modified")

    # Check CJK locale families
    cjk_map = {
        "zh-Hans": "KSU-NotoSansCJKsc-VF.ttf",
        "zh-Hant,zh-Bopo": "KSU-NotoSansCJKtc-VF.ttf",
        "ja": "KSU-NotoSansCJKjp-VF.ttf",
        "ko": "KSU-NotoSansCJKkr-VF.ttf",
    }
    for lang_key, expected_cjk_file in cjk_map.items():
        orig_cjk_list = [f for f in orig_families if f.attrib.get("lang") == lang_key]
        out_cjk_list = [f for f in out_families if f.attrib.get("lang") == lang_key]
        if len(orig_cjk_list) == 0 or len(out_cjk_list) != len(orig_cjk_list) + 1:
            raise AssertionError(
                f"{out_path}: expected +1 family for lang={lang_key}, got {len(orig_cjk_list)} -> {len(out_cjk_list)}"
            )

        orig_primary = orig_cjk_list[0]
        prepended_fam = out_cjk_list[0]
        preserved_primary = out_cjk_list[1]

        if prepended_fam.attrib != {"lang": lang_key}:
            raise AssertionError(
                f"{out_path}: prepended {lang_key} family attrib {prepended_fam.attrib} != {{'lang': {lang_key!r}}}"
            )

        # Verify original primary CJK family is preserved 100% verbatim right after prepended family
        if normalize_elem(preserved_primary) != normalize_elem(orig_primary):
            raise AssertionError(f"{out_path}: original CJK family for {lang_key} was not preserved verbatim")
        if out_families.index(preserved_primary) != out_families.index(prepended_fam) + 1:
            raise AssertionError(f"{out_path}: preserved {lang_key} family must immediately follow prepended family")

        # Verify prepended family contents: new KSU Noto CJK normal font(s) + verbatim fallbackFor fonts
        prep_fonts = [c for c in prepended_fam if c.tag == "font"]
        orig_fb_fonts = [normalize_elem(c) for c in orig_primary if c.tag == "font" and "fallbackFor" in c.attrib]
        if not orig_fb_fonts:
            raise AssertionError(f"{out_path}: original {lang_key} family had no fallbackFor fonts")

        if mode == "fallback":
            expected_normal_count = 1
            if len(prep_fonts) != expected_normal_count + len(orig_fb_fonts):
                raise AssertionError(f"{out_path}: unexpected font count in prepended fallback {lang_key} family")
            first_f = prep_fonts[0]
            if font_filename(first_f) != expected_cjk_file:
                raise AssertionError(f"{out_path}: {lang_key} first font != {expected_cjk_file}")
            if first_f.attrib != {"weight": "400", "style": "normal", "supportedAxes": "wght"}:
                raise AssertionError(f"{out_path}: {lang_key} unexpected attrib {first_f.attrib}")
            if font_axes(first_f) != {}:
                raise AssertionError(f"{out_path}: {lang_key} fallback VF should not have child axes")
        else:
            expected_normal_count = 9
            if len(prep_fonts) != expected_normal_count + len(orig_fb_fonts):
                raise AssertionError(f"{out_path}: unexpected font count in prepended legacy {lang_key} family")
            for i, w in enumerate(range(100, 1000, 100)):
                f = prep_fonts[i]
                if font_filename(f) != expected_cjk_file:
                    raise AssertionError(f"{out_path}: legacy {lang_key}[{i}] != {expected_cjk_file}")
                if f.attrib != {"weight": str(w), "style": "normal"}:
                    raise AssertionError(f"{out_path}: legacy {lang_key}[{i}] unexpected attrib {f.attrib}")
                if font_axes(f) != {"wght": str(w)}:
                    raise AssertionError(f"{out_path}: legacy {lang_key}[{i}] unexpected axes {font_axes(f)}")

        prep_fb_fonts = [normalize_elem(c) for c in prep_fonts[expected_normal_count:]]
        if prep_fb_fonts != orig_fb_fonts:
            raise AssertionError(
                f"{out_path}: {lang_key} prepended family did not preserve fallbackFor fonts (including axes) verbatim"
            )

        # Verify routing invariants:
        # 1) Default/sans chain ('') for this locale resolves KSU-NotoSansCJK*-VF.ttf first, followed by original fonts
        default_route = resolve_effective_route_fonts(out_cjk_list, "")
        if not default_route or font_filename(default_route[0]) != expected_cjk_file:
            raise AssertionError(f"{out_path}: {lang_key} default route does not prioritize {expected_cjk_file}")

        # 2) Every specialized fallbackFor chain (e.g. 'serif') keeps the exact same first-choice font as original
        fb_targets = sorted({c.attrib["fallbackFor"] for c in orig_primary if c.tag == "font" and "fallbackFor" in c.attrib})
        for target_chain in fb_targets:
            orig_route = resolve_effective_route_fonts(orig_cjk_list, target_chain)
            out_route = resolve_effective_route_fonts(out_cjk_list, target_chain)
            if not orig_route or not out_route:
                raise AssertionError(f"{out_path}: empty route for {lang_key} fallbackFor={target_chain}")
            if normalize_elem(out_route[0]) != normalize_elem(orig_route[0]):
                raise AssertionError(
                    f"{out_path}: {lang_key} specialized route '{target_chain}' first choice changed: "
                    f"{font_filename(orig_route[0])} -> {font_filename(out_route[0])}"
                )

        # If ja has a second original family (Hentaigana), verify it is untouched at index 2
        if lang_key == "ja":
            if len(out_cjk_list) != 3:
                raise AssertionError(
                    f"{out_path}: expected 3 ja families (prepended + primary + Hentaigana), got {len(out_cjk_list)}"
                )
            if normalize_elem(orig_cjk_list[1]) != normalize_elem(out_cjk_list[2]):
                raise AssertionError(f"{out_path}: second original ja family (Hentaigana) was modified")

    # Check Emoji families
    orig_emoji = [f for f in orig_families if f.attrib.get("lang", "").lower() == "und-zsye"]
    out_emoji = [f for f in out_families if f.attrib.get("lang", "").lower() == "und-zsye"]
    if len(out_emoji) != len(orig_emoji) + 1:
        raise AssertionError(f"{out_path}: expected +1 und-Zsye family, got {len(orig_emoji)} -> {len(out_emoji)}")

    if mode == "fallback":
        if [font_filename(f.find("font")) for f in out_emoji] != [
            "KSU-AppleColorEmoji.ttf",
            "NotoColorEmoji.ttf",
            "NotoColorEmojiFlags.ttf",
        ]:
            raise AssertionError(f"{out_path}: unexpected emoji order in fallback mode")
        if "ignore" in out_emoji[0].attrib:
            raise AssertionError(f"{out_path}: KSU-AppleColorEmoji family must not have ignore attribute")
    else:
        if [font_filename(f.find("font")) for f in out_emoji] != [
            "NotoColorEmojiLegacy.ttf",
            "KSU-AppleColorEmoji.ttf",
            "NotoColorEmoji.ttf",
            "NotoColorEmojiFlags.ttf",
        ]:
            raise AssertionError(f"{out_path}: unexpected emoji order in legacy mode")
        if out_emoji[0].attrib.get("ignore") != "true":
            raise AssertionError(f"{out_path}: first legacy emoji family must retain ignore='true'")
        if "ignore" in out_emoji[1].attrib:
            raise AssertionError(f"{out_path}: KSU-AppleColorEmoji family must not inherit ignore='true'")


def self_test_style_uniqueness_helper() -> None:
    """Unit test for assert_family_style_uniqueness:
    - Same (weight, style) across different fallbackFor values must pass (no false positive).
    - Same (weight, style) within the same fallbackFor value must raise AssertionError.
    """
    ok_fam = ET.fromstring(
        '<family lang="zh-Hans">'
        '<font weight="400" style="normal">KSU-NotoSansCJKsc-VF.ttf</font>'
        '<font weight="400" style="normal" fallbackFor="serif">NotoSerifCJK-Regular.ttc</font>'
        "</family>"
    )
    assert_family_style_uniqueness(ok_fam, "self_test:different_fallbackFor")

    dup_normal_fam = ET.fromstring(
        '<family lang="zh-Hans">'
        '<font weight="400" style="normal">KSU-NotoSansCJKsc-VF.ttf</font>'
        '<font weight="400" style="normal">NotoSansCJK-Regular.ttc</font>'
        "</family>"
    )
    try:
        assert_family_style_uniqueness(dup_normal_fam, "self_test:dup_normal")
    except AssertionError:
        pass
    else:
        raise AssertionError("self_test failed: duplicate normal (400, normal) was not rejected")

    dup_serif_fam = ET.fromstring(
        '<family lang="zh-Hans">'
        '<font weight="400" style="normal" fallbackFor="serif">A.ttc</font>'
        '<font weight="400" style="normal" fallbackFor="serif">B.ttc</font>'
        "</family>"
    )
    try:
        assert_family_style_uniqueness(dup_serif_fam, "self_test:dup_serif")
    except AssertionError:
        pass
    else:
        raise AssertionError("self_test failed: duplicate serif (400, normal) was not rejected")

    dup_leading_zero_fam = ET.fromstring(
        '<family name="monospace">'
        '<font weight="400" style="normal">DroidSansMono.ttf</font>'
        '<font weight="0400" style="normal">DupZero.ttf</font>'
        "</family>"
    )
    try:
        assert_family_style_uniqueness(dup_leading_zero_fam, "self_test:dup_leading_zero_weight")
    except AssertionError:
        pass
    else:
        raise AssertionError("self_test failed: weight=0400 colliding with weight=400 was not rejected")

    dup_bogus_style_fam = ET.fromstring(
        '<family name="monospace">'
        '<font weight="400" style="normal">DroidSansMono.ttf</font>'
        '<font weight="400" style="bogus">DupBogus.ttf</font>'
        "</family>"
    )
    try:
        assert_family_style_uniqueness(dup_bogus_style_fam, "self_test:dup_bogus_style")
    except AssertionError:
        pass
    else:
        raise AssertionError("self_test failed: style=bogus colliding with style=normal was not rejected")


def main() -> int:
    parser = argparse.ArgumentParser(description="Verify transformed font XML output.")
    parser.add_argument("orig_xml", help="Original input XML")
    parser.add_argument("out_xml", help="Transformed output XML")
    parser.add_argument("--mode", required=True, choices=["fallback", "legacy"])
    args = parser.parse_args()

    try:
        self_test_style_uniqueness_helper()
        verify_pair(args.orig_xml, args.out_xml, args.mode)
    except Exception as exc:
        print(f"XML VERIFY FAILED ({args.mode}): {exc}", file=sys.stderr)
        return 1

    print(f"XML VERIFY OK ({args.mode}): {args.out_xml}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
