#!/usr/bin/env python3
"""Host-side fixed XML config builder for ksu-noto-fonts-apple-emoji (v1.0.3).

Reads the three OnePlus 13 (Android 16 / OxygenOS 16) root XML inputs
(font_fallback.xml, fonts.xml, fonts_base.xml), enforces their exact known
SHA-256 digests unless --allow-custom-hashes is set for synthetic unit tests,
transforms only the approved target nodes using standard xml.etree.ElementTree,
and writes:
  - <out_dir>/system/etc/font_fallback.xml
  - <out_dir>/system/etc/fonts.xml
  - <out_dir>/system/system_ext/etc/fonts_base.xml
  - <out_dir>/device-sources.sha256
"""

import argparse
import hashlib
import os
import sys
import xml.etree.ElementTree as ET


EXPECTED_DEVICE_SOURCE_HASHES = {
    "system/etc/font_fallback.xml": "7097f4da6a862fc08655a6db74d061820cb1b2c3890ab4474bad62bd734e21c2",
    "system/etc/fonts.xml": "d15b64cddf7260be242b9fc23fb84ce50838ba2c2359a4fe5ce1c484e379c4c1",
    "system/system_ext/etc/fonts_base.xml": "8119a2379b78ebd7b3aab75c368b2cda1d9b219390dbf22701959d415dde0aad",
}

INPUT_FILENAMES = {
    "system/etc/font_fallback.xml": ("font_fallback.xml", "fallback"),
    "system/etc/fonts.xml": ("fonts.xml", "legacy"),
    "system/system_ext/etc/fonts_base.xml": ("fonts_base.xml", "base"),
}

EXPECTED_TTC_INDEX = {
    "ja": "0",
    "ko": "1",
    "zh-Hans": "2",
    "zh-Hant,zh-Bopo": "3",
    "zh-Bopo,zh-Hant": "3",
}


def sha256_file(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        while True:
            chunk = f.read(1024 * 1024)
            if not chunk:
                break
            h.update(chunk)
    return h.hexdigest().lower()


def _font_filename(elem: ET.Element) -> str:
    return (elem.text or "").strip()


def _font_axes(elem: ET.Element) -> list[tuple[str, str]]:
    axes: list[tuple[str, str]] = []
    for child in elem:
        if child.tag != "axis":
            raise ValueError(f"Unexpected child <{child.tag}> inside <font>")
        axes.append((child.attrib.get("tag", ""), child.attrib.get("stylevalue", "")))
    return axes


def _make_font_elem(attrib: dict[str, str], filename: str, axes: list[tuple[str, str]]) -> ET.Element:
    elem = ET.Element("font", dict(attrib))
    if axes:
        elem.text = filename + "\n"
        for tag, val in axes:
            ET.SubElement(elem, "axis", {"tag": tag, "stylevalue": val})
    else:
        elem.text = filename
    return elem


def _is_active_main_emoji_family(fam: ET.Element) -> bool:
    if fam.attrib.get("lang", "").lower() != "und-zsye":
        return False
    if fam.attrib.get("ignore", "").lower() == "true":
        return False
    fonts = [c for c in fam if c.tag == "font"]
    return len(fonts) == 1 and _font_filename(fonts[0]) == "NotoColorEmoji.ttf"


def transform_familyset_tree(tree: ET.ElementTree, mode: str) -> dict[str, int]:
    if mode not in ("fallback", "legacy", "base"):
        raise ValueError(f"Unsupported mode: {mode}")

    root = tree.getroot()
    if root.tag != "familyset":
        raise ValueError(f"Expected <familyset> root, got <{root.tag}>")
    if mode == "fallback" and "version" in root.attrib:
        raise ValueError("fallback mode <familyset> must not have a version attribute")
    if mode in ("legacy", "base") and not root.attrib.get("version", "").isdigit():
        raise ValueError(f"{mode} mode <familyset> must have numeric version attribute")

    stats = {
        "roboto": 0,
        "sysfont": 0,
        "syssans_en": 0,
        "opsans_en": 0,
        "cjk_sc": 0,
        "cjk_tc": 0,
        "serif_preserved": 0,
        "ttc": 0,
        "emoji": 0,
        "clamped_1000": 0,
    }

    children = list(root)
    new_root_children: list[ET.Element] = []
    emoji_inserted = False

    for child in children:
        if child.tag == "alias":
            new_root_children.append(child)
            continue
        if child.tag != "family":
            raise ValueError(f"Unexpected child <{child.tag}> under <familyset>")

        if _is_active_main_emoji_family(child):
            if emoji_inserted:
                raise ValueError("Multiple active NotoColorEmoji.ttf families found")
            orig_font = child[0]
            if (
                orig_font.attrib.get("weight") != "400"
                or orig_font.attrib.get("style") != "normal"
                or len(orig_font) != 0
            ):
                raise ValueError(f"Unexpected NotoColorEmoji.ttf attributes: {orig_font.attrib}")

            apple_fam = ET.Element("family", {"lang": "und-Zsye"})
            apple_fam.append(
                _make_font_elem(
                    {
                        "weight": "400",
                        "style": "normal",
                        "postScriptName": "KsuAppleColorEmoji",
                    },
                    "KSU-AppleColorEmoji.ttf",
                    [],
                )
            )
            new_root_children.append(apple_fam)
            new_root_children.append(child)
            emoji_inserted = True
            stats["emoji"] += 1
            continue

        fam_name = child.attrib.get("name", "").lower()
        fam_lang = child.attrib.get("lang", "")
        new_fonts: list[ET.Element] = []
        modified_family = False

        for font_elem in child:
            if font_elem.tag != "font":
                raise ValueError(f"Unexpected child <{font_elem.tag}> in <family>")
            fn = _font_filename(font_elem)
            attrib = dict(font_elem.attrib)
            axes = _font_axes(font_elem)

            # 1. Roboto-Regular.ttf (modern VF in sans-serif / sans-serif-condensed / roboto / unnamed)
            if fn == "Roboto-Regular.ttf":
                if attrib.get("supportedAxes") != "wght,ital" or len(axes) != 1 or axes[0][0] != "wdth":
                    raise ValueError(f"Unexpected Roboto-Regular.ttf node: attrib={attrib}, axes={axes}")
                wdth_val = axes[0][1]
                if float(wdth_val) not in (75.0, 100.0):
                    raise ValueError(f"Unexpected wdth={wdth_val} on Roboto-Regular.ttf")
                new_fonts.append(
                    _make_font_elem({"supportedAxes": "wght"}, "Roboto-Regular.ttf", [("wdth", wdth_val)])
                )
                new_fonts.append(
                    _make_font_elem(
                        {"style": "italic", "supportedAxes": "wght"},
                        "NotoSans-Italic.ttf",
                        [("wdth", wdth_val)],
                    )
                )
                modified_family = True
                stats["roboto"] += 1
                continue

            # 2. SysFont-Regular.ttf (legacy sans-serif weights 100..900)
            if fn == "SysFont-Regular.ttf":
                w = attrib.get("weight", "")
                axes_dict = dict(axes)
                if (
                    mode != "legacy"
                    or fam_name != "sans-serif"
                    or attrib != {"weight": w, "style": "normal"}
                    or axes_dict != {"ital": "0", "wdth": "100", "wght": w}
                ):
                    raise ValueError(f"Unexpected SysFont-Regular.ttf node: attrib={attrib}, axes={axes}")
                new_fonts.append(
                    _make_font_elem(
                        {"weight": w, "style": "normal"},
                        "SysFont-Regular.ttf",
                        [("wdth", "100"), ("wght", w)],
                    )
                )
                new_fonts.append(
                    _make_font_elem(
                        {"weight": w, "style": "italic"},
                        "NotoSans-Italic.ttf",
                        [("wdth", "100"), ("wght", w)],
                    )
                )
                modified_family = True
                stats["sysfont"] += 1
                continue

            # 3. SysSans-En-Regular.ttf / OPSans-En-Regular.ttf
            if fn in ("SysSans-En-Regular.ttf", "OPSans-En-Regular.ttf"):
                w = attrib.get("weight", "")
                if (
                    attrib.get("style") != "normal"
                    or not w.isdigit()
                    or len(axes) != 1
                    or axes[0] != ("wght", w)
                ):
                    raise ValueError(f"Unexpected {fn} node: attrib={attrib}, axes={axes}")
                w_int = int(w)
                clamped_w = "900" if w_int > 900 else w
                if w_int > 900:
                    stats["clamped_1000"] += 1
                new_fonts.append(
                    _make_font_elem(
                        {"weight": w, "style": "normal"},
                        fn,
                        [("wght", clamped_w)],
                    )
                )
                new_fonts.append(
                    _make_font_elem(
                        {"weight": w, "style": "italic"},
                        "NotoSans-Italic.ttf",
                        [("wght", clamped_w)],
                    )
                )
                modified_family = True
                if fn == "SysSans-En-Regular.ttf":
                    stats["syssans_en"] += 1
                else:
                    stats["opsans_en"] += 1
                continue

            # 4. SysSans-Hans-Regular.ttf / SysSans-Hant-Regular.ttf
            if fn in ("SysSans-Hans-Regular.ttf", "SysSans-Hant-Regular.ttf"):
                if attrib.get("fallbackFor") == "serif":
                    # Preserve fallbackFor="serif" reference to original SysSans-Hans/Hant-Regular.ttf untouched
                    new_fonts.append(font_elem)
                    stats["serif_preserved"] += 1
                    continue
                w = attrib.get("weight", "")
                if (
                    attrib.get("style") != "normal"
                    or "fallbackFor" in attrib
                    or not w.isdigit()
                    or len(axes) != 1
                    or axes[0] != ("wght", w)
                ):
                    raise ValueError(f"Unexpected normal {fn} node: attrib={attrib}, axes={axes}")
                w_int = int(w)
                clamped_w = "900" if w_int > 900 else w
                if w_int > 900:
                    stats["clamped_1000"] += 1
                target_cjk_fn = (
                    "KSU-NotoSansCJKsc-VF.ttf"
                    if fn == "SysSans-Hans-Regular.ttf"
                    else "KSU-NotoSansCJKtc-VF.ttf"
                )
                new_fonts.append(
                    _make_font_elem(
                        {"weight": w, "style": "normal"},
                        target_cjk_fn,
                        [("wght", clamped_w)],
                    )
                )
                modified_family = True
                if fn == "SysSans-Hans-Regular.ttf":
                    stats["cjk_sc"] += 1
                else:
                    stats["cjk_tc"] += 1
                continue

            # 5. NotoSansCJK-Regular.ttc
            if fn == "NotoSansCJK-Regular.ttc":
                if attrib.get("fallbackFor"):
                    new_fonts.append(font_elem)
                    continue
                idx = attrib.get("index", "")
                exp_idx = EXPECTED_TTC_INDEX.get(fam_lang)
                if exp_idx is None or idx != exp_idx:
                    raise ValueError(f"TTC index {idx!r} mismatch for lang={fam_lang!r} (expected {exp_idx!r})")
                w = attrib.get("weight", "400")
                w_int = int(w)
                clamped_w = "900" if w_int > 900 else w
                if attrib.get("supportedAxes") == "wght":
                    if mode != "fallback" or w != "400" or axes != []:
                        raise ValueError(f"Unexpected modern TTC node: attrib={attrib}, axes={axes}")
                    new_fonts.append(
                        _make_font_elem(
                            {"weight": "400", "style": "normal", "index": idx, "supportedAxes": "wght"},
                            "NotoSansCJK-Regular.ttc",
                            [],
                        )
                    )
                else:
                    if axes not in ([], [("wght", w)]):
                        raise ValueError(f"Unexpected static TTC node axes: attrib={attrib}, axes={axes}")
                    if w_int > 900:
                        stats["clamped_1000"] += 1
                    new_fonts.append(
                        _make_font_elem(
                            {"weight": w, "style": "normal", "index": idx},
                            "NotoSansCJK-Regular.ttc",
                            [("wght", clamped_w)],
                        )
                    )
                modified_family = True
                stats["ttc"] += 1
                continue

            new_fonts.append(font_elem)

        if modified_family:
            child[:] = new_fonts
        new_root_children.append(child)

    if not emoji_inserted or stats["emoji"] != 1:
        raise ValueError("Expected exactly 1 active NotoColorEmoji.ttf family")

    root[:] = new_root_children
    ET.indent(tree, space="    ")
    return stats


def build_fixed_xmls(
    input_dir: str,
    out_dir: str,
    allow_custom_hashes: bool = False,
) -> dict[str, str]:
    source_hashes: dict[str, str] = {}
    for target_rel, (src_name, _mode) in sorted(INPUT_FILENAMES.items()):
        src_path = os.path.join(input_dir, src_name)
        if not os.path.isfile(src_path):
            raise FileNotFoundError(f"Missing required root XML input: {src_path}")
        act_sha = sha256_file(src_path)
        exp_sha = EXPECTED_DEVICE_SOURCE_HASHES[target_rel]
        if not allow_custom_hashes and act_sha != exp_sha:
            raise ValueError(
                f"SHA-256 mismatch for input {src_name}: expected {exp_sha}, got {act_sha}"
            )
        source_hashes[target_rel] = act_sha

    for target_rel, (src_name, mode) in sorted(INPUT_FILENAMES.items()):
        src_path = os.path.join(input_dir, src_name)
        dst_path = os.path.join(out_dir, target_rel)
        os.makedirs(os.path.dirname(dst_path), exist_ok=True)
        tree = ET.parse(src_path)
        transform_familyset_tree(tree, mode)
        with open(dst_path, "wb") as f:
            tree.write(f, encoding="utf-8", xml_declaration=True)
            f.write(b"\n")

    manifest_path = os.path.join(out_dir, "device-sources.sha256")
    with open(manifest_path, "w", encoding="utf-8", newline="\n") as mf:
        for target_rel in sorted(source_hashes.keys()):
            mf.write(f"{source_hashes[target_rel]}  {target_rel}\n")

    return source_hashes


def main() -> int:
    parser = argparse.ArgumentParser(description="Build fixed OnePlus 13 / OxygenOS 16 XML configs.")
    parser.add_argument("input_dir", help="Directory containing font_fallback.xml, fonts.xml, fonts_base.xml")
    parser.add_argument("out_dir", help="Module staging directory where system/etc and device-sources.sha256 are written")
    parser.add_argument(
        "--allow-custom-hashes",
        action="store_true",
        help="Allow synthetic test fixtures whose SHA-256 differs from the locked OP13 device XMLs",
    )
    args = parser.parse_args()

    try:
        hashes = build_fixed_xmls(
            args.input_dir,
            args.out_dir,
            allow_custom_hashes=args.allow_custom_hashes,
        )
    except Exception as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1

    for rel_path, digest in sorted(hashes.items()):
        print(f"Built {rel_path} (source sha256={digest})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
