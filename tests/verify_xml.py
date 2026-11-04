#!/usr/bin/env python3
"""Independent host-side XML output verifier for ksu-noto-fonts-apple-emoji (v1.0.2).

Parses original and transformed font XML files using xml.etree.ElementTree and
independently verifies structural and node-level diff invariants:
1. Root <familyset> tag and version attribute match mode ('fallback', 'legacy', 'base').
2. Top-level <familyset> child sequence (<family> and <alias>) is preserved in exact
   order, with zero <alias> changes, zero CJK <family> additions, and only a single
   prepended <family lang="und-Zsye"> (NotoColorEmoji.ttf with postScriptName="KsuAppleColorEmoji")
   immediately before the original active NotoColorEmoji.ttf family.
3. Every non-target <family> and every non-target <font> node (sys-serif, roboto-flex,
   serif, monospace, NotoSerifCJK-Regular.ttc, NotoSerifHentaigana.ttf, und-Arab, etc.)
   is preserved 100% verbatim.
4. Target <font> nodes match the exact approved node-level transformation:
   - Roboto-Regular.ttf: supportedAxes="wght,ital" -> "wght" + adjacent NotoSans-Italic.ttf
     preserving wdth (75 / 75.0 / 100 / 100.0).
   - SysFont-Regular.ttf (legacy sans-serif 100..900): strips ital=0 axis + adjacent
     NotoSans-Italic.ttf (wdth=100, wght=W).
   - SysSans-En-Regular.ttf / OPSans-En-Regular.ttf: strips OEM postScriptName, clamps
     wght 1000->900 + adjacent NotoSans-Italic.ttf.
   - SysSans-Hans-Regular.ttf / SysSans-Hant-Regular.ttf:
     * fallbackFor="serif": rewrites filename ONLY to KsuReserved-SysSans-Hans/Hant-Regular.ttf,
       keeping weight, style, fallbackFor="serif", postScriptName="OPPO_Sans_4.0_SC|TC", and 0 axes.
     * normal: strips OEM postScriptName, clamps wght 1000->900, pins wght=min(W,900).
   - NotoSansCJK-Regular.ttc: preserves index in 0..3 matching locale (0=ja, 1=ko, 2=zh-Hans,
     3=zh-Hant,zh-Bopo), strips OEM postScriptName, pins wght=min(W,900) when supportedAxes is absent.
   - NotoColorEmoji.ttf: active family rewritten to KsuReserved-NotoColorEmoji.ttf with
     postScriptName="NotoColorEmoji" after the prepended KsuAppleColorEmoji family.
5. Within every <family>, font styles are unique per (fallbackFor, weight, style).
"""

import argparse
import re
import sys
import xml.etree.ElementTree as ET


NOTO_REPLACED_FILES = {
    "Roboto-Regular.ttf",
    "SysFont-Regular.ttf",
    "SysSans-En-Regular.ttf",
    "OPSans-En-Regular.ttf",
    "NotoSans-Italic.ttf",
    "SysSans-Hans-Regular.ttf",
    "SysSans-Hant-Regular.ttf",
    "NotoSansCJK-Regular.ttc",
}

EXPECTED_TTC_INDEX = {
    "ja": "0",
    "ko": "1",
    "zh-Hans": "2",
    "zh-Hant,zh-Bopo": "3",
    "zh-Bopo,zh-Hant": "3",
}


def normalize_elem(elem: ET.Element) -> tuple:
    children = tuple(normalize_elem(c) for c in list(elem))
    text = (elem.text or "").strip()
    return (elem.tag, tuple(sorted(elem.attrib.items())), text, children)


def make_font_norm(attrib: dict[str, str], filename: str, axes: list[tuple[str, str]]) -> tuple:
    axis_children = tuple(
        ("axis", tuple(sorted({"tag": tag, "stylevalue": val}.items())), "", ())
        for tag, val in axes
    )
    return ("font", tuple(sorted(attrib.items())), filename, axis_children)


def font_filename(font_elem: ET.Element) -> str:
    return (font_elem.text or "").strip()


def font_axes_list(font_elem: ET.Element) -> list[tuple[str, str]]:
    axes = []
    for child in font_elem:
        if child.tag != "axis":
            raise AssertionError(f"Unexpected child <{child.tag}> inside <font>")
        axes.append((child.attrib.get("tag", ""), child.attrib.get("stylevalue", "")))
    return axes


def assert_family_style_uniqueness(fam: ET.Element, label: str) -> None:
    """Verify (weight, style) validity and uniqueness within each fallbackFor group of a <family>."""
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


def is_active_main_emoji_family(fam: ET.Element) -> bool:
    if fam.attrib.get("lang", "").lower() != "und-zsye":
        return False
    if fam.attrib.get("ignore", "").lower() == "true":
        return False
    fonts = [c for c in fam if c.tag == "font"]
    return len(fonts) == 1 and font_filename(fonts[0]) == "NotoColorEmoji.ttf"


def build_expected_family_fonts(orig_fam: ET.Element, mode: str, stats: dict[str, int]) -> list[tuple]:
    fam_lang = orig_fam.attrib.get("lang", "")
    fam_ignore = orig_fam.attrib.get("ignore", "").lower() == "true"
    expected: list[tuple] = []

    for f in orig_fam:
        if f.tag != "font":
            raise AssertionError(f"Unexpected non-font child <{f.tag}> in original family")
        fn = font_filename(f)
        attrib = dict(f.attrib)
        axes = font_axes_list(f)

        if fn == "Roboto-Regular.ttf":
            if attrib != {"supportedAxes": "wght,ital"} or len(axes) != 1 or axes[0][0] != "wdth":
                raise AssertionError(f"Unexpected original Roboto-Regular.ttf node: attrib={attrib}, axes={axes}")
            wdth_val = axes[0][1]
            if float(wdth_val) not in (75.0, 100.0):
                raise AssertionError(f"Unexpected wdth={wdth_val} on Roboto-Regular.ttf")
            expected.append(make_font_norm({"supportedAxes": "wght"}, "Roboto-Regular.ttf", [("wdth", wdth_val)]))
            expected.append(
                make_font_norm(
                    {"style": "italic", "supportedAxes": "wght"},
                    "NotoSans-Italic.ttf",
                    [("wdth", wdth_val)],
                )
            )
            stats["roboto"] += 1
            continue

        if fn == "SysFont-Regular.ttf":
            w = attrib.get("weight", "")
            axes_dict = dict(axes)
            if (
                mode != "legacy"
                or attrib != {"weight": w, "style": "normal"}
                or axes_dict != {"ital": "0", "wdth": "100", "wght": w}
            ):
                raise AssertionError(f"Unexpected SysFont-Regular.ttf node: attrib={attrib}, axes={axes}")
            expected.append(
                make_font_norm(
                    {"weight": w, "style": "normal"},
                    "SysFont-Regular.ttf",
                    [("wdth", "100"), ("wght", w)],
                )
            )
            expected.append(
                make_font_norm(
                    {"weight": w, "style": "italic"},
                    "NotoSans-Italic.ttf",
                    [("wdth", "100"), ("wght", w)],
                )
            )
            stats["sysfont"] += 1
            continue

        if fn in ("SysSans-En-Regular.ttf", "OPSans-En-Regular.ttf"):
            w = attrib.get("weight", "")
            clamped_w = "900" if int(w) > 900 else w
            if int(w) > 900:
                stats["clamp"] += 1
            expected.append(
                make_font_norm(
                    {"weight": w, "style": "normal"},
                    fn,
                    [("wght", clamped_w)],
                )
            )
            expected.append(
                make_font_norm(
                    {"weight": w, "style": "italic"},
                    "NotoSans-Italic.ttf",
                    [("wght", clamped_w)],
                )
            )
            stats["oplus_latin"] += 1
            continue

        if fn in ("SysSans-Hans-Regular.ttf", "SysSans-Hant-Regular.ttf"):
            if attrib.get("fallbackFor") == "serif":
                reserved_fn = f"KsuReserved-{fn}"
                if axes != [] or "postScriptName" not in attrib:
                    raise AssertionError(f"Unexpected serif SysSans node: attrib={attrib}, axes={axes}")
                expected.append(make_font_norm(attrib, reserved_fn, []))
                stats["serif_reserved"] += 1
            else:
                w = attrib.get("weight", "")
                clamped_w = "900" if int(w) > 900 else w
                if int(w) > 900:
                    stats["clamp"] += 1
                expected.append(
                    make_font_norm(
                        {"weight": w, "style": "normal"},
                        fn,
                        [("wght", clamped_w)],
                    )
                )
                stats["syssans_cjk"] += 1
            continue

        if fn == "NotoSansCJK-Regular.ttc":
            idx = attrib.get("index", "")
            exp_idx = EXPECTED_TTC_INDEX.get(fam_lang)
            if exp_idx is None or idx != exp_idx:
                raise AssertionError(f"TTC index {idx!r} does not match locale {fam_lang!r} (expected {exp_idx!r})")
            w = attrib.get("weight", "400")
            clamped_w = "900" if int(w) > 900 else w
            if attrib.get("supportedAxes") == "wght":
                expected.append(
                    make_font_norm(
                        {"weight": w, "style": "normal", "index": idx, "supportedAxes": "wght"},
                        "NotoSansCJK-Regular.ttc",
                        [],
                    )
                )
            else:
                expected.append(
                    make_font_norm(
                        {"weight": w, "style": "normal", "index": idx},
                        "NotoSansCJK-Regular.ttc",
                        [("wght", clamped_w)],
                    )
                )
            stats["ttc"] += 1
            continue

        if fn == "NotoColorEmoji.ttf" and not fam_ignore:
            expected.append(
                make_font_norm(
                    {"weight": "400", "style": "normal", "postScriptName": "NotoColorEmoji"},
                    "KsuReserved-NotoColorEmoji.ttf",
                    [],
                )
            )
            stats["emoji"] += 1
            continue

        # Non-target font node: must remain 100% verbatim
        expected.append(normalize_elem(f))

    return expected


def verify_pair(orig_path: str, out_path: str, mode: str) -> None:
    with open(orig_path, "r", encoding="utf-8") as f:
        orig_raw = f.read()
    with open(out_path, "r", encoding="utf-8") as f:
        out_raw = f.read()

    if "EXCERPT FIXTURE ONLY" in orig_raw and "EXCERPT FIXTURE ONLY" not in out_raw:
        raise AssertionError(f"{out_path}: lost excerpt comment header")

    if mode in ("legacy", "base") and "Commented-out old CJK OTC families MUST remain untouched" in orig_raw:
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
    if mode in ("legacy", "base") and "version" not in out_root.attrib:
        raise AssertionError(f"{out_path}: {mode} familyset must have version attribute")

    orig_children = list(orig_root)
    out_children = list(out_root)

    for child in out_children:
        if child.tag not in ("family", "alias"):
            raise AssertionError(f"{out_path}: unexpected child tag <{child.tag}> under <familyset>")

    # Locate the unique active NotoColorEmoji.ttf family in orig_children
    emoji_indices = [
        i for i, c in enumerate(orig_children) if c.tag == "family" and is_active_main_emoji_family(c)
    ]
    if len(emoji_indices) != 1:
        raise AssertionError(f"{orig_path}: expected 1 active NotoColorEmoji.ttf family, found {len(emoji_indices)}")
    emoji_pos = emoji_indices[0]

    if len(out_children) != len(orig_children) + 1:
        raise AssertionError(
            f"{out_path}: expected exactly +1 top-level child (prepended Apple Emoji family), "
            f"got {len(orig_children)} -> {len(out_children)}"
        )

    # Check the prepended Apple Emoji family at emoji_pos in out_children
    apple_fam = out_children[emoji_pos]
    expected_apple_fam = (
        "family",
        (("lang", "und-Zsye"),),
        "",
        (
            make_font_norm(
                {"weight": "400", "style": "normal", "postScriptName": "KsuAppleColorEmoji"},
                "NotoColorEmoji.ttf",
                [],
            ),
        ),
    )
    if normalize_elem(apple_fam) != expected_apple_fam:
        raise AssertionError(
            f"{out_path}: prepended Apple Emoji family at index {emoji_pos} mismatch: {normalize_elem(apple_fam)}"
        )

    # Align all remaining top-level children 1-to-1 with orig_children
    aligned_out = out_children[:emoji_pos] + out_children[emoji_pos + 1 :]
    stats = {
        "roboto": 0,
        "sysfont": 0,
        "oplus_latin": 0,
        "syssans_cjk": 0,
        "serif_reserved": 0,
        "ttc": 0,
        "emoji": 0,
        "clamp": 0,
    }

    for idx, (orig_c, out_c) in enumerate(zip(orig_children, aligned_out)):
        if orig_c.tag != out_c.tag:
            raise AssertionError(f"{out_path}: top-level child[{idx}] tag changed {orig_c.tag} -> {out_c.tag}")
        if orig_c.tag == "alias":
            if normalize_elem(orig_c) != normalize_elem(out_c):
                raise AssertionError(f"{out_path}: <alias> at child[{idx}] was modified")
            continue

        # <family> element: attributes must be 100% preserved
        if orig_c.attrib != out_c.attrib:
            raise AssertionError(
                f"{out_path}: <family> attributes at child[{idx}] changed {orig_c.attrib} -> {out_c.attrib}"
            )

        exp_fonts = build_expected_family_fonts(orig_c, mode, stats)
        act_fonts = [normalize_elem(f) for f in out_c]
        if act_fonts != exp_fonts:
            fam_desc = orig_c.attrib.get("name") or orig_c.attrib.get("lang") or f"unnamed#{idx}"
            raise AssertionError(
                f"{out_path}: <family> ({fam_desc}) at child[{idx}] font diff mismatch:\n"
                f"  expected: {exp_fonts}\n"
                f"  actual:   {act_fonts}"
            )

    # Verify global invariants across all output families and fonts
    out_families = [c for c in out_children if c.tag == "family"]
    for fam_idx, fam in enumerate(out_families):
        fam_desc = fam.attrib.get("name") or fam.attrib.get("lang") or f"unnamed#{fam_idx}"
        assert_family_style_uniqueness(fam, f"{out_path}:family[{fam_idx}]({fam_desc})")
        for f in fam:
            fn = font_filename(f)
            if fn.startswith("KSU-"):
                raise AssertionError(f"{out_path}: forbidden legacy KSU-* font reference: {fn}")
            if fn in NOTO_REPLACED_FILES:
                if "postScriptName" in f.attrib:
                    raise AssertionError(f"{out_path}: Noto font {fn} must not retain postScriptName={f.attrib['postScriptName']!r}")
                if "ital" in f.attrib.get("supportedAxes", "").split(","):
                    raise AssertionError(f"{out_path}: Noto font {fn} must not retain ital in supportedAxes")
                for ax_tag, ax_val in font_axes_list(f):
                    if ax_tag == "ital":
                        raise AssertionError(f"{out_path}: Noto font {fn} must not have <axis tag='ital'>")
                    if ax_tag == "wght" and float(ax_val) > 900.0:
                        raise AssertionError(f"{out_path}: Noto font {fn} has unclamped wght={ax_val}")

    if mode == "fallback":
        if stats["roboto"] < 2 or stats["ttc"] != 4 or stats["emoji"] != 1 or stats["serif_reserved"] != 0:
            raise AssertionError(f"{out_path}: unexpected fallback stats: {stats}")
    elif mode == "legacy":
        if (
            stats["sysfont"] != 9
            or stats["roboto"] < 2
            or stats["oplus_latin"] != 19
            or stats["syssans_cjk"] != 20
            or stats["serif_reserved"] != 2
            or stats["ttc"] != 18
            or stats["emoji"] != 1
            or stats["clamp"] != 3
        ):
            raise AssertionError(f"{out_path}: unexpected legacy stats: {stats}")
    elif mode == "base":
        if (
            stats["sysfont"] != 0
            or stats["roboto"] < 2
            or stats["oplus_latin"] != 19
            or stats["syssans_cjk"] != 20
            or stats["serif_reserved"] != 2
            or stats["ttc"] != 18
            or stats["emoji"] != 1
            or stats["clamp"] != 3
        ):
            raise AssertionError(f"{out_path}: unexpected base stats: {stats}")


def self_test_style_uniqueness_helper() -> None:
    """Unit test for assert_family_style_uniqueness."""
    ok_fam = ET.fromstring(
        '<family lang="zh-Hans">'
        '<font weight="400" style="normal">SysSans-Hans-Regular.ttf</font>'
        '<font weight="400" style="normal" fallbackFor="serif">KsuReserved-SysSans-Hans-Regular.ttf</font>'
        "</family>"
    )
    assert_family_style_uniqueness(ok_fam, "self_test:different_fallbackFor")

    for label, xml_str in [
        (
            "self_test:dup_normal",
            '<family lang="zh-Hans">'
            '<font weight="400" style="normal">SysSans-Hans-Regular.ttf</font>'
            '<font weight="400" style="normal">NotoSansCJK-Regular.ttc</font>'
            "</family>",
        ),
        (
            "self_test:dup_serif",
            '<family lang="zh-Hans">'
            '<font weight="400" style="normal" fallbackFor="serif">A.ttc</font>'
            '<font weight="400" style="normal" fallbackFor="serif">B.ttc</font>'
            "</family>",
        ),
        (
            "self_test:dup_leading_zero_weight",
            '<family name="monospace">'
            '<font weight="400" style="normal">DroidSansMono.ttf</font>'
            '<font weight="0400" style="normal">DupZero.ttf</font>'
            "</family>",
        ),
        (
            "self_test:dup_bogus_style",
            '<family name="monospace">'
            '<font weight="400" style="normal">DroidSansMono.ttf</font>'
            '<font weight="400" style="bogus">DupBogus.ttf</font>'
            "</family>",
        ),
    ]:
        try:
            assert_family_style_uniqueness(ET.fromstring(xml_str), label)
        except AssertionError:
            pass
        else:
            raise AssertionError(f"self_test failed: {label} was not rejected")


def main() -> int:
    parser = argparse.ArgumentParser(description="Verify transformed font XML output.")
    parser.add_argument("orig_xml", help="Original input XML")
    parser.add_argument("out_xml", help="Transformed output XML")
    parser.add_argument("--mode", required=True, choices=["fallback", "legacy", "base"])
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
