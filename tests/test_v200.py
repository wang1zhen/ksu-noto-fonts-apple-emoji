#!/usr/bin/env python3
"""Unit and integration tests for ksu-noto-fonts-apple-emoji (v2.0.0).

Covers:
1. Synthetic XML fixtures: multi-line & multi-segment comments containing <family>,
   regional CJK routing (zh-Hans->SC, zh-Hant/Bopo/yue->TC, ja->JP, ko->KR),
   Hentaigana preservation, normal/italic Western slot selection without fabricating
   missing italic slots, modern supportedAxes="wght" retention without fixed <axis>,
   weight clamping (100..900), fallbackFor="serif" preservation, Emoji exact target
   replacement (skipping ignore="true" and Flags/Compat, replacing only first active
   und-Zsye family with single KSU-AppleColorEmoji.ttf slot without postScriptName),
   and fail-closed rejection (mixed CJK region, ambiguous zh, self-overlay, unknown/
   malformed structure, missing required role) with zero partial output committed.
2. BusyBox 1.36.1 ash/awk execution when KSU_TEST_BUSYBOX or /usr/lib/initcpio/busybox
   is available.
3. Local root 3-OEM XML regression (fonts.xml, font_fallback.xml, fonts_base.xml)
   executed without skipping.
4. Host role isolation (make_fonts.py / check_fonts.py) and format 14 UVS filtering.
"""

import os
import shutil
import subprocess
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET
from fontTools.ttLib import TTFont

ROOT_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FIXTURES_DIR = os.path.join(ROOT_DIR, "tests", "fixtures")
MODULE_DIR = os.path.join(ROOT_DIR, "module")
FONTCONFIG_SH = os.path.join(MODULE_DIR, "tools", "fontconfig.sh")
FONTS_AWK = os.path.join(MODULE_DIR, "tools", "fontxml.awk")
CUSTOMIZE_SH = os.path.join(MODULE_DIR, "customize.sh")

sys.path.insert(0, os.path.join(ROOT_DIR, "tools"))
import check_fonts as cf  # noqa: E402
import make_fonts as mf  # noqa: E402

PACKAGED_FONTS = list(mf.FONT_ROLE_MAP.keys())


def _busybox_bin() -> str:
    cand = os.environ.get("KSU_TEST_BUSYBOX", "/usr/lib/initcpio/busybox")
    if cand and os.path.isfile(cand) and os.access(cand, os.X_OK):
        return cand
    return ""


def _setup_module_tree(mod_dir: str) -> None:
    os.makedirs(os.path.join(mod_dir, "tools"), exist_ok=True)
    os.makedirs(os.path.join(mod_dir, "system", "fonts"), exist_ok=True)
    shutil.copyfile(CUSTOMIZE_SH, os.path.join(mod_dir, "customize.sh"))
    shutil.copyfile(FONTCONFIG_SH, os.path.join(mod_dir, "tools", "fontconfig.sh"))
    shutil.copyfile(FONTS_AWK, os.path.join(mod_dir, "tools", "fontxml.awk"))
    for fname in PACKAGED_FONTS:
        with open(os.path.join(mod_dir, "system", "fonts", fname), "wb") as fh:
            fh.write(b"placeholder")


def _run_prepare(mod_dir: str, sys_root: str, use_busybox: bool = True) -> subprocess.CompletedProcess:
    env = os.environ.copy()
    env["FONT_CONFIG_ROOT"] = sys_root
    bb = _busybox_bin() if use_busybox else ""
    if bb:
        bin_dir = os.path.join(mod_dir, ".bb_bin")
        os.makedirs(bin_dir, exist_ok=True)
        for applet in ("sh", "ash", "awk", "grep", "sed", "cp", "mv", "rm", "mkdir", "chmod", "cat"):
            link = os.path.join(bin_dir, applet)
            if not os.path.exists(link):
                os.symlink(bb, link)
        env["PATH"] = f"{bin_dir}:{env.get('PATH', '')}"
        cmd = [bb, "ash", os.path.join(mod_dir, "tools", "fontconfig.sh"), "prepare"]
    else:
        cmd = ["sh", os.path.join(mod_dir, "tools", "fontconfig.sh"), "prepare"]
    return subprocess.run(cmd, env=env, capture_output=True, text=True)


class TestV200FontSettings(unittest.TestCase):
    def test_synthetic_excerpt_fixtures_and_All_paths(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            mod_dir = os.path.join(tmpdir, "mod")
            sys_root = os.path.join(tmpdir, "sysroot")
            _setup_module_tree(mod_dir)

            os.makedirs(os.path.join(sys_root, "system", "etc"))
            os.makedirs(os.path.join(sys_root, "system", "system_ext", "etc"))
            os.makedirs(os.path.join(sys_root, "product", "etc"))

            shutil.copyfile(
                os.path.join(FIXTURES_DIR, "fonts.excerpt.xml"),
                os.path.join(sys_root, "system", "etc", "fonts.xml"),
            )
            shutil.copyfile(
                os.path.join(FIXTURES_DIR, "font_fallback.excerpt.xml"),
                os.path.join(sys_root, "system", "etc", "font_fallback.xml"),
            )
            # Test SAR alias /system/system_ext/etc/fonts_base.xml -> system_ext/etc/fonts_base.xml
            shutil.copyfile(
                os.path.join(FIXTURES_DIR, "fonts_base.excerpt.xml"),
                os.path.join(sys_root, "system", "system_ext", "etc", "fonts_base.xml"),
            )
            # Test product customization with traditional Cantonese yue-Hant and multi-segment comment
            with open(os.path.join(sys_root, "product", "etc", "fonts_customization.xml"), "w", encoding="utf-8") as fh:
                fh.write(
                    '<?xml version="1.0" encoding="utf-8"?>\n'
                    "<familyset>\n"
                    '  <!-- <family lang="zh-Hans"><font>Fake1.ttf</font></family> --> <!-- <family name="sans-serif"><font>Fake2.ttf</font></family> -->\n'
                    '  <family lang="yue-Hant">\n'
                    '    <font weight="400" style="normal">Cantonese.ttf</font>\n'
                    "  </family>\n"
                    "</familyset>\n"
                )

            res = _run_prepare(mod_dir, sys_root, use_busybox=True)
            self.assertEqual(res.returncode, 0, msg=res.stdout + res.stderr)
            self.assertIn("ok=config files=4 western=8 cjk=13 sc=3 tc=4 jp=3 kr=3 emoji=3", res.stdout)

            out_fonts = os.path.join(mod_dir, "system", "etc", "fonts.xml")
            out_fb = os.path.join(mod_dir, "system", "etc", "font_fallback.xml")
            out_base = os.path.join(mod_dir, "system", "system_ext", "etc", "fonts_base.xml")
            out_prod = os.path.join(mod_dir, "system", "product", "etc", "fonts_customization.xml")

            for p in (out_fonts, out_fb, out_base, out_prod):
                self.assertTrue(os.path.isfile(p), f"Missing generated XML: {p}")
                ET.parse(p)

            # Verify comments containing <family> were preserved verbatim and not counted
            with open(out_prod, "r", encoding="utf-8") as fh:
                prod_text = fh.read()
            self.assertIn("Fake1.ttf", prod_text)
            self.assertIn("Fake2.ttf", prod_text)
            self.assertIn("KSU-NotoSansCJKtc-VF.ttf", prod_text)

            # Verify Hentaigana preserved untouched
            fb_root = ET.parse(out_fb).getroot()
            ja_fams = [c for c in fb_root if c.tag == "family" and c.attrib.get("lang") == "ja"]
            self.assertEqual(len(ja_fams), 2)
            self.assertEqual((ja_fams[0][0].text or "").strip(), "KSU-NotoSansCJKjp-VF.ttf")
            self.assertEqual(ja_fams[0][0].attrib.get("supportedAxes"), "wght")
            self.assertEqual(len(ja_fams[0][0]), 0)  # modern supportedAxes="wght" has no fixed <axis>
            self.assertEqual((ja_fams[0][1].text or "").strip(), "KSU-NotoSansCJKjp-VF.ttf")
            self.assertEqual(ja_fams[0][1].attrib.get("fallbackFor"), "serif")
            self.assertEqual((ja_fams[1][0].text or "").strip(), "NotoSerifHentaigana.ttf")

            # Verify fonts.xml unnamed Roboto family adapted, non-target unnamed Myanmar in fonts_base untouched
            fonts_root = ET.parse(out_fonts).getroot()
            unnamed_fonts = [c for c in fonts_root if c.tag == "family" and not c.attrib]
            self.assertGreaterEqual(len(unnamed_fonts), 1)
            self.assertEqual((unnamed_fonts[0][0].text or "").strip(), "KSU-NotoSans-Regular-VF.ttf")
            self.assertEqual(unnamed_fonts[0][0].attrib, {"supportedAxes": "wght"})

            base_root = ET.parse(out_base).getroot()
            unnamed_base = [c for c in base_root if c.tag == "family" and not c.attrib]
            self.assertEqual(len(unnamed_base), 1)
            self.assertEqual((unnamed_base[0][0].text or "").strip(), "SysFont-Myanmar.ttf")

            # Verify weight=1000 clamped to wght=900 and no index/postScriptName/ital leaked
            zh_hans = [c for c in fonts_root if c.tag == "family" and c.attrib.get("lang") == "zh-Hans"][0]
            for fnode in zh_hans:
                self.assertEqual((fnode.text or "").strip(), "KSU-NotoSansCJKsc-VF.ttf")
                self.assertNotIn("postScriptName", fnode.attrib)
                self.assertNotIn("index", fnode.attrib)
            w1000 = [f for f in zh_hans if f.attrib.get("weight") == "1000"][0]
            self.assertEqual(w1000[0].attrib, {"tag": "wght", "stylevalue": "900"})

            # Verify Emoji: ignore="true" untouched, first active und-Zsye replaced in-place with KSU-AppleColorEmoji.ttf, Flags untouched
            zsye_fams = [c for c in fonts_root if c.tag == "family" and c.attrib.get("lang") == "und-Zsye"]
            self.assertEqual(len(zsye_fams), 3)
            self.assertEqual(zsye_fams[0].attrib.get("ignore"), "true")
            self.assertEqual((zsye_fams[0][0].text or "").strip(), "NotoColorEmojiLegacy.ttf")
            self.assertEqual(len(zsye_fams[1]), 1)
            self.assertEqual((zsye_fams[1][0].text or "").strip(), "KSU-AppleColorEmoji.ttf")
            self.assertNotIn("postScriptName", zsye_fams[1][0].attrib)
            self.assertEqual((zsye_fams[2][0].text or "").strip(), "NotoColorEmojiFlags.ttf")

    def test_western_italic_slot_and_fail_closed_without_partial_output(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            mod_dir = os.path.join(tmpdir, "mod")
            sys_root = os.path.join(tmpdir, "sysroot")
            _setup_module_tree(mod_dir)
            os.makedirs(os.path.join(sys_root, "system", "etc"))

            # 1. Western normal + italic slots (including whitespace around '=') map to Regular-VF and Italic-VF without duplicating slots
            # Also verify ignore = "true" with spaces is respected and skips legacy emoji
            clean_xml = (
                '<?xml version="1.0" encoding="utf-8"?>\n'
                "<familyset>\n"
                '  <family name = "sans-serif">\n'
                '    <font weight = "400" style = "normal">Roboto-Regular.ttf</font>\n'
                '    <font weight = "400" style = "italic">Roboto-Italic.ttf</font>\n'
                "  </family>\n"
                '  <family lang="zh-Hans">\n'
                '    <font weight="400" style="normal">CJK.ttc</font>\n'
                "  </family>\n"
                '  <family lang="zh-Hant">\n'
                '    <font weight="400" style="normal">CJK.ttc</font>\n'
                "  </family>\n"
                '  <family lang="ja">\n'
                '    <font weight="400" style="normal">CJK.ttc</font>\n'
                "  </family>\n"
                '  <family lang="ko">\n'
                '    <font weight="400" style="normal">CJK.ttc</font>\n'
                "  </family>\n"
                '  <family lang="und-Zsye" ignore = "true">\n'
                '    <font weight="400" style="normal">NotoColorEmojiLegacy.ttf</font>\n'
                "  </family>\n"
                '  <family lang="und-Zsye">\n'
                '    <font weight="400" style="normal" postScriptName="NotoColorEmoji">SamsungColorEmoji.ttf</font>\n'
                "  </family>\n"
                "</familyset>\n"
            )
            fonts_xml_path = os.path.join(sys_root, "system", "etc", "fonts.xml")
            with open(fonts_xml_path, "w", encoding="utf-8") as fh:
                fh.write(clean_xml)

            res = _run_prepare(mod_dir, sys_root, use_busybox=True)
            self.assertEqual(res.returncode, 0, msg=res.stdout + res.stderr)
            root = ET.parse(os.path.join(mod_dir, "system", "etc", "fonts.xml")).getroot()
            sans_fonts = list(root[0])
            self.assertEqual(len(sans_fonts), 2)
            self.assertEqual((sans_fonts[0].text or "").strip(), "KSU-NotoSans-Regular-VF.ttf")
            self.assertEqual((sans_fonts[0].attrib.get("style")), "normal")
            self.assertEqual((sans_fonts[1].text or "").strip(), "KSU-NotoSans-Italic-VF.ttf")
            self.assertEqual((sans_fonts[1].attrib.get("style")), "italic")
            zsye_fams = [c for c in root if c.tag == "family" and c.attrib.get("lang") == "und-Zsye"]
            self.assertEqual(len(zsye_fams), 2)
            self.assertEqual((zsye_fams[0][0].text or "").strip(), "NotoColorEmojiLegacy.ttf")
            self.assertEqual((zsye_fams[1][0].text or "").strip(), "KSU-AppleColorEmoji.ttf")

            # Remove generated output to verify failure cases leave zero partial XMLs
            shutil.rmtree(os.path.join(mod_dir, "system", "etc"))

            # Authentic v1.0.2 excerpt produced by commit 8414623 module/tools/fontxml.awk (mode=legacy)
            v102_excerpt_xml = (
                '<?xml version="1.0" encoding="utf-8"?>\n'
                '<familyset version="23">\n'
                '  <family name="sans-serif">\n'
                '    <font weight="400" style="normal">SysFont-Regular.ttf\n'
                '      <axis tag="wdth" stylevalue="100" />\n'
                '      <axis tag="wght" stylevalue="400" />\n'
                "    </font>\n"
                '    <font weight="400" style="italic">NotoSans-Italic.ttf\n'
                '      <axis tag="wdth" stylevalue="100" />\n'
                '      <axis tag="wght" stylevalue="400" />\n'
                "    </font>\n"
                "  </family>\n"
                '  <family lang="zh-Hans">\n'
                '    <font weight="400" style="normal" fallbackFor="serif" postScriptName="OPPO_Sans_4.0_SC">KsuReserved-SysSans-Hans-Regular.ttf</font>\n'
                "  </family>\n"
                '  <family lang="zh-Hant,zh-Bopo">\n'
                '    <font weight="400" style="normal" fallbackFor="serif" postScriptName="OPPO_Sans_4.0_TC">KsuReserved-SysSans-Hant-Regular.ttf</font>\n'
                "  </family>\n"
                '  <family lang="ja">\n'
                '    <font weight="400" style="normal" index="0">NotoSansCJK-Regular.ttc</font>\n'
                "  </family>\n"
                '  <family lang="ko">\n'
                '    <font weight="400" style="normal" index="1">NotoSansCJK-Regular.ttc</font>\n'
                "  </family>\n"
                '  <family lang="und-Zsye">\n'
                '    <font weight="400" style="normal" postScriptName="KsuAppleColorEmoji">NotoColorEmoji.ttf</font>\n'
                "  </family>\n"
                '  <family lang="und-Zsye">\n'
                '    <font weight="400" style="normal" postScriptName="NotoColorEmoji">KsuReserved-NotoColorEmoji.ttf</font>\n'
                "  </family>\n"
                "</familyset>\n"
            )

            failure_cases = [
                # Mixed CJK regions in one family
                clean_xml.replace('lang="zh-Hans"', 'lang="zh-Hans,ja"'),
                # Ambiguous bare lang="zh"
                clean_xml.replace('lang="zh-Hans"', 'lang="zh"'),
                # Self-overlay already containing KSU-NotoSans
                clean_xml.replace("Roboto-Regular.ttf", "KSU-NotoSans-Regular-VF.ttf"),
                # Authentic v1.0.2 modified XML (commit 8414623 output with NotoSans-Italic.ttf + KsuReserved-*)
                v102_excerpt_xml,
                # Standalone v1 NotoSans-Italic.ttf marker
                clean_xml.replace("Roboto-Italic.ttf", "NotoSans-Italic.ttf"),
                # v1 KsuReserved-* marker
                clean_xml.replace("SamsungColorEmoji.ttf", "KsuReserved-NotoColorEmoji.ttf"),
                # Missing closing </familyset> root tag
                clean_xml.replace("</familyset>\n", ""),
                # Unclosed / unexpected element before <familyset>
                clean_xml.replace("<familyset>", "<unexpected>\n<familyset>"),
                # Unexpected element inside <familyset>
                clean_xml.replace("</familyset>", "  <unexpected/>\n</familyset>"),
                # Multiple <font> elements on the same physical line
                clean_xml.replace(
                    '    <font weight = "400" style = "normal">Roboto-Regular.ttf</font>\n'
                    '    <font weight = "400" style = "italic">Roboto-Italic.ttf</font>',
                    '    <font weight="400" style="normal">Roboto-Regular.ttf</font><font weight="400" style="italic">Roboto-Italic.ttf</font>',
                ),
                # Missing required role (no ko family)
                clean_xml.replace('lang="ko"', 'lang="de"'),
                # Unsupported font style attribute
                clean_xml.replace('style = "italic"', 'style="oblique"'),
                # Comment sharing line with family tag
                clean_xml.replace('<family name = "sans-serif">', '<!-- c --> <family name="sans-serif">'),
                # Unsupported single-line family tag + font + closing tag
                clean_xml.replace(
                    '  <family lang="ko">\n    <font weight="400" style="normal">CJK.ttc</font>\n  </family>',
                    '  <family lang="ko"><font weight="400" style="normal">CJK.ttc</font></family>',
                ),
            ]
            adb_dir = os.path.join(tmpdir, "adb_guard")
            os.makedirs(os.path.join(adb_dir, "modules"), exist_ok=True)
            install_env = os.environ.copy()
            install_env.update(
                {
                    "MODPATH": mod_dir,
                    "KSU": "true",
                    "KSU_SDK_VERSION": "36",
                    "KSU_ADB_ROOT": adb_dir,
                    "FONT_CONFIG_ROOT": sys_root,
                }
            )
            for bad_xml in failure_cases:
                with open(fonts_xml_path, "w", encoding="utf-8") as fh:
                    fh.write(bad_xml)
                bad_res = _run_prepare(mod_dir, sys_root, use_busybox=True)
                self.assertNotEqual(bad_res.returncode, 0, f"Expected prepare failure for:\n{bad_xml}")
                self.assertFalse(
                    os.path.exists(os.path.join(mod_dir, "system", "etc")),
                    "Failed prepare must not commit partial XML files into module/system/etc",
                )
                inst_res = subprocess.run(
                    ["sh", os.path.join(mod_dir, "customize.sh")],
                    env=install_env,
                    capture_output=True,
                    text=True,
                )
                self.assertNotEqual(inst_res.returncode, 0, f"Expected customize.sh failure for:\n{bad_xml}")
                self.assertFalse(
                    os.path.exists(os.path.join(mod_dir, "system", "etc")),
                    "Failed customize.sh install must not commit partial XML files into module/system/etc",
                )

    def test_customize_sh_install_guards(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            adb_root = os.path.join(tmpdir, "adb")
            sys_root = os.path.join(tmpdir, "sysroot")
            modpath = os.path.join(adb_root, "modules_update", "ksu_noto_fonts_apple_emoji")
            _setup_module_tree(modpath)

            os.makedirs(os.path.join(sys_root, "system", "etc"))
            shutil.copyfile(
                os.path.join(FIXTURES_DIR, "fonts.excerpt.xml"),
                os.path.join(sys_root, "system", "etc", "fonts.xml"),
            )

            base_env = os.environ.copy()
            base_env.update(
                {
                    "MODPATH": modpath,
                    "KSU": "true",
                    "KSU_SDK_VERSION": "36",
                    "KSU_ADB_ROOT": adb_root,
                    "FONT_CONFIG_ROOT": sys_root,
                }
            )

            # 1. Existing active module in /data/adb/modules/ksu_noto_fonts_apple_emoji must be rejected
            active_dir = os.path.join(adb_root, "modules", "ksu_noto_fonts_apple_emoji")
            os.makedirs(active_dir)
            res_old = subprocess.run(
                ["sh", os.path.join(modpath, "customize.sh")],
                env=base_env,
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(res_old.returncode, 0)
            self.assertIn("Existing module found", res_old.stdout)
            shutil.rmtree(active_dir)

            # 2. Clean install must succeed and set permissions
            res_ok = subprocess.run(
                ["sh", os.path.join(modpath, "customize.sh")],
                env=base_env,
                capture_output=True,
                text=True,
            )
            self.assertEqual(res_ok.returncode, 0, msg=res_ok.stdout + res_ok.stderr)
            self.assertIn("Installation complete", res_ok.stdout)
            self.assertTrue(os.path.isfile(os.path.join(modpath, "system", "etc", "fonts.xml")))

    def test_host_font_role_isolation_unit(self) -> None:
        cache_dir = os.path.join(ROOT_DIR, ".cache", "downloads")
        cjk_sample = os.path.join(cache_dir, "KSU-NotoSansCJKsc-VF.ttf")
        western_sample = os.path.join(cache_dir, "KSU-NotoSans-Regular-VF.ttf")

        with tempfile.TemporaryDirectory() as tmpdir:
            if os.path.isfile(cjk_sample) and os.path.isfile(western_sample):
                out_cjk = os.path.join(tmpdir, "KSU-NotoSansCJKsc-VF.ttf")
                out_west = os.path.join(tmpdir, "KSU-NotoSans-Regular-VF.ttf")
                mf.isolate_font_file(cjk_sample, out_west_cjk := out_cjk, "chinese")
                mf.isolate_font_file(western_sample, out_west, "western")

                errs_cjk = cf.check_single_ttf(
                    out_west_cjk, "KSU-NotoSansCJKsc-VF.ttf", cf.EXPECTED_TTF_SPECS["KSU-NotoSansCJKsc-VF.ttf"]
                )
                self.assertEqual(errs_cjk, [])

                errs_west = cf.check_single_ttf(
                    out_west, "KSU-NotoSans-Regular-VF.ttf", cf.EXPECTED_TTF_SPECS["KSU-NotoSans-Regular-VF.ttf"]
                )
                self.assertEqual(errs_west, [])

                # Also verify synthetic CJK injection into Western font is stripped by western isolation
                f_synth = TTFont(western_sample, recalcTimestamp=False)
                first_glyph = f_synth.getGlyphOrder()[1]
                for sub in f_synth["cmap"].tables:
                    if mf.is_unicode_subtable(sub) and sub.format in (4, 12):
                        sub.cmap[0x4E2D] = first_glyph
                        sub.cmap[0x3002] = first_glyph
                synth_in = os.path.join(tmpdir, "synth_mixed_west.ttf")
                synth_out = os.path.join(tmpdir, "synth_isolated_west.ttf")
                f_synth.save(synth_in)
                f_synth.close()

                mf.isolate_font_file(synth_in, synth_out, "western")
                errs_synth = cf.check_single_ttf(
                    synth_out, "KSU-NotoSans-Regular-VF.ttf", cf.EXPECTED_TTF_SPECS["KSU-NotoSans-Regular-VF.ttf"]
                )
                self.assertEqual(errs_synth, [])

            # Always verify range helpers on representative codepoints
            self.assertTrue(mf.should_remove("chinese", 0x0041))
            self.assertTrue(mf.should_remove("chinese", 0x0030))
            self.assertTrue(mf.should_remove("chinese", 0xFF01))
            self.assertFalse(mf.should_remove("chinese", 0x4E2D))
            self.assertFalse(mf.should_remove("chinese", 0x3002))
            self.assertTrue(mf.should_remove("western", 0x4E2D))
            self.assertTrue(mf.should_remove("western", 0x3002))
            self.assertFalse(mf.should_remove("western", 0x0041))
            self.assertFalse(mf.should_remove("western", 0x0030))


class TestV200LocalOEMRegression(unittest.TestCase):
    def test_real_3_oem_xmls_local_regression(self) -> None:
        oem_files = {
            "fonts.xml": ("system", "etc", "fonts.xml"),
            "font_fallback.xml": ("system", "etc", "font_fallback.xml"),
            "fonts_base.xml": ("system_ext", "etc", "fonts_base.xml"),
        }
        for root_name in oem_files:
            full_p = os.path.join(ROOT_DIR, root_name)
            self.assertTrue(
                os.path.isfile(full_p),
                f"Real OEM XML {full_p} must exist in repo root and this regression test must not be skipped",
            )

        with tempfile.TemporaryDirectory() as tmpdir:
            mod_dir = os.path.join(tmpdir, "mod")
            sys_root = os.path.join(tmpdir, "sysroot")
            _setup_module_tree(mod_dir)

            for root_name, rel_parts in oem_files.items():
                dst = os.path.join(sys_root, *rel_parts)
                os.makedirs(os.path.dirname(dst), exist_ok=True)
                shutil.copyfile(os.path.join(ROOT_DIR, root_name), dst)

            res = _run_prepare(mod_dir, sys_root, use_busybox=True)
            self.assertEqual(res.returncode, 0, msg=res.stdout + res.stderr)
            self.assertIn("ok=config files=3 western=8 cjk=12 sc=3 tc=3 jp=3 kr=3 emoji=3", res.stdout)

            for _root_name, rel_parts in oem_files.items():
                gen_path = (
                    os.path.join(mod_dir, "system", *rel_parts[1:])
                    if rel_parts[0] == "system"
                    else os.path.join(mod_dir, "system", *rel_parts)
                )
                self.assertTrue(os.path.isfile(gen_path), f"Missing generated OEM XML: {gen_path}")
                tree = ET.parse(gen_path)
                root = tree.getroot()
                self.assertEqual(root.tag, "familyset")
                with open(gen_path, "r", encoding="utf-8") as fh:
                    content = fh.read()
                self.assertIn("KSU-NotoSans-Regular-VF.ttf", content)
                self.assertIn("KSU-NotoSansCJKsc-VF.ttf", content)
                self.assertIn("KSU-NotoSansCJKtc-VF.ttf", content)
                self.assertIn("KSU-NotoSansCJKjp-VF.ttf", content)
                self.assertIn("KSU-NotoSansCJKkr-VF.ttf", content)
                self.assertIn("KSU-AppleColorEmoji.ttf", content)
                self.assertIn("NotoColorEmojiFlags.ttf", content)
                self.assertIn("NotoSerifHentaigana.ttf", content)

            # Also verify authentic v1.0.2 output generated from root fonts.xml by git commit 8414623 is rejected
            shutil.rmtree(os.path.join(mod_dir, "system", "etc"))
            shutil.rmtree(os.path.join(mod_dir, "system", "system_ext"))
            v102_awk = os.path.join(tmpdir, "v102_fontxml.awk")
            v102_show = subprocess.run(
                ["git", "-C", ROOT_DIR, "show", "8414623:module/tools/fontxml.awk"],
                capture_output=True,
                text=True,
            )
            if v102_show.returncode == 0 and v102_show.stdout:
                with open(v102_awk, "w", encoding="utf-8") as fh:
                    fh.write(v102_show.stdout)
                v102_out = subprocess.run(
                    ["awk", "-v", "mode=legacy", "-f", v102_awk, os.path.join(ROOT_DIR, "fonts.xml")],
                    capture_output=True,
                    text=True,
                    check=True,
                )
                with open(os.path.join(sys_root, "system", "etc", "fonts.xml"), "w", encoding="utf-8") as fh:
                    fh.write(v102_out.stdout)
                bad_v102 = _run_prepare(mod_dir, sys_root, use_busybox=True)
                self.assertNotEqual(bad_v102.returncode, 0)
                self.assertIn("self_overlay_detected", bad_v102.stdout)
                self.assertFalse(os.path.exists(os.path.join(mod_dir, "system", "etc")))


if __name__ == "__main__":
    unittest.main()
