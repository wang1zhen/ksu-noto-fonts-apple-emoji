#!/usr/bin/env python3
"""Unit tests for ksu-noto-fonts-apple-emoji (v1.0.3 fixed OP13 OOS16 package).

Runs with standard library unittest:
    python3 -I -m unittest discover tests
"""

import hashlib
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET

ROOT_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FIXTURES_DIR = os.path.join(ROOT_DIR, "tests", "fixtures")
CUSTOMIZE_SH = os.path.join(ROOT_DIR, "module", "customize.sh")

sys.path.insert(0, os.path.join(ROOT_DIR, "tools"))
import make_xml as mx  # noqa: E402


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest().lower()


class TestFixedPackageV103(unittest.TestCase):
    def test_xml_transform_on_synthetic_fixtures(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            in_dir = os.path.join(tmpdir, "in")
            out_dir = os.path.join(tmpdir, "out")
            os.makedirs(in_dir)
            shutil.copyfile(
                os.path.join(FIXTURES_DIR, "font_fallback.excerpt.xml"),
                os.path.join(in_dir, "font_fallback.xml"),
            )
            shutil.copyfile(
                os.path.join(FIXTURES_DIR, "fonts.excerpt.xml"),
                os.path.join(in_dir, "fonts.xml"),
            )
            shutil.copyfile(
                os.path.join(FIXTURES_DIR, "fonts_base.excerpt.xml"),
                os.path.join(in_dir, "fonts_base.xml"),
            )

            # Without --allow-custom-hashes, synthetic fixtures must fail closed
            with self.assertRaises(ValueError):
                mx.build_fixed_xmls(in_dir, out_dir, allow_custom_hashes=False)

            hashes = mx.build_fixed_xmls(in_dir, out_dir, allow_custom_hashes=True)
            self.assertEqual(set(hashes.keys()), set(mx.EXPECTED_DEVICE_SOURCE_HASHES.keys()))

            # Check fallback output
            fb_tree = ET.parse(os.path.join(out_dir, "system/etc/font_fallback.xml"))
            fb_root = fb_tree.getroot()
            self.assertEqual(fb_root.tag, "familyset")
            self.assertNotIn("version", fb_root.attrib)

            # Check legacy fonts.xml output
            leg_path = os.path.join(out_dir, "system/etc/fonts.xml")
            with open(leg_path, "r", encoding="utf-8") as fh:
                leg_text = fh.read()
            self.assertNotIn("KsuReserved-", leg_text)
            self.assertIn("KSU-NotoSansCJKsc-VF.ttf", leg_text)
            self.assertIn("KSU-NotoSansCJKtc-VF.ttf", leg_text)
            self.assertIn("KSU-AppleColorEmoji.ttf", leg_text)
            self.assertIn("KsuAppleColorEmoji", leg_text)
            self.assertIn("NotoSans-Italic.ttf", leg_text)
            # Original serif fallback SysSans-Hans/Hant-Regular.ttf and NotoColorEmoji.ttf preserved
            self.assertIn("SysSans-Hans-Regular.ttf", leg_text)
            self.assertIn("SysSans-Hant-Regular.ttf", leg_text)
            self.assertIn("NotoColorEmoji.ttf", leg_text)

            leg_root = ET.fromstring(leg_text)
            zh_hans_fams = [c for c in leg_root if c.tag == "family" and c.attrib.get("lang") == "zh-Hans"]
            self.assertEqual(len(zh_hans_fams), 1)
            zh_hans_fonts = list(zh_hans_fams[0])
            self.assertEqual(len(zh_hans_fonts), 11)
            normal_files = {(f.text or "").strip() for f in zh_hans_fonts if "fallbackFor" not in f.attrib}
            serif_files = {(f.text or "").strip() for f in zh_hans_fonts if f.attrib.get("fallbackFor") == "serif"}
            self.assertEqual(normal_files, {"KSU-NotoSansCJKsc-VF.ttf"})
            self.assertEqual(serif_files, {"SysSans-Hans-Regular.ttf"})

            # Check weight=1000 clamped to wght=900
            w1000_nodes = [f for f in zh_hans_fonts if f.attrib.get("weight") == "1000"]
            self.assertEqual(len(w1000_nodes), 1)
            self.assertEqual(w1000_nodes[0][0].attrib, {"tag": "wght", "stylevalue": "900"})

            # Check active emoji families: first is KSU-AppleColorEmoji.ttf, second is NotoColorEmoji.ttf
            active_emoji = [
                c
                for c in leg_root
                if c.tag == "family"
                and c.attrib.get("lang", "").lower() == "und-zsye"
                and c.attrib.get("ignore", "").lower() != "true"
            ]
            self.assertGreaterEqual(len(active_emoji), 2)
            self.assertEqual((active_emoji[0][0].text or "").strip(), "KSU-AppleColorEmoji.ttf")
            self.assertEqual(active_emoji[0][0].attrib.get("postScriptName"), "KsuAppleColorEmoji")
            self.assertEqual((active_emoji[1][0].text or "").strip(), "NotoColorEmoji.ttf")

    def test_customize_sh_install_checks(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            adb_root = os.path.join(tmpdir, "adb")
            sys_root = os.path.join(tmpdir, "sysroot")
            modpath = os.path.join(adb_root, "modules_update", "ksu_noto_fonts_apple_emoji")
            os.makedirs(modpath)
            shutil.copyfile(CUSTOMIZE_SH, os.path.join(modpath, "customize.sh"))

            dev_rels = [
                "system/etc/font_fallback.xml",
                "system/etc/fonts.xml",
                "system/system_ext/etc/fonts_base.xml",
            ]
            dev_manifest_lines = []
            for rel in dev_rels:
                p = os.path.join(sys_root, rel)
                os.makedirs(os.path.dirname(p), exist_ok=True)
                content = f"<familyset><!-- {rel} --></familyset>\n".encode("utf-8")
                with open(p, "wb") as fh:
                    fh.write(content)
                dev_manifest_lines.append(f"{sha256_bytes(content)}  {rel}\n")

            with open(os.path.join(modpath, "device-sources.sha256"), "w", encoding="utf-8") as fh:
                fh.writelines(dev_manifest_lines)

            # Create 11 dummy payload files to satisfy payload.sha256 check
            payload_lines = []
            for i in range(11):
                rel = f"system/fonts/dummy-{i}.ttf"
                full = os.path.join(modpath, rel)
                os.makedirs(os.path.dirname(full), exist_ok=True)
                data = f"dummy-font-{i}".encode("utf-8")
                with open(full, "wb") as fh:
                    fh.write(data)
                payload_lines.append(f"{sha256_bytes(data)}  {rel}\n")

            with open(os.path.join(modpath, "payload.sha256"), "w", encoding="utf-8") as fh:
                fh.writelines(payload_lines)

            base_env = os.environ.copy()
            base_env.update(
                {
                    "MODPATH": modpath,
                    "KSU": "true",
                    "KSU_SDK_VERSION": "36",
                    "KSU_ADB_ROOT": adb_root,
                    "KSU_SYSTEM_ROOT": sys_root,
                }
            )

            # 1. Clean install in modules_update must succeed (must not self-flag MODPATH)
            res = subprocess.run(
                ["sh", os.path.join(modpath, "customize.sh")],
                env=base_env,
                capture_output=True,
                text=True,
            )
            self.assertEqual(res.returncode, 0, msg=res.stdout + res.stderr)
            self.assertIn("Installation complete", res.stdout)

            # 2. Wrong Android SDK (e.g. 35) must fail
            env_sdk35 = dict(base_env, KSU_SDK_VERSION="35")
            res_sdk = subprocess.run(
                ["sh", os.path.join(modpath, "customize.sh")],
                env=env_sdk35,
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(res_sdk.returncode, 0)
            self.assertIn("requires Android 16 / API 36", res_sdk.stdout)

            # 3. Existing active module in /data/adb/modules/ksu_noto_fonts_apple_emoji must fail
            old_active = os.path.join(adb_root, "modules", "ksu_noto_fonts_apple_emoji")
            os.makedirs(old_active)
            res_old = subprocess.run(
                ["sh", os.path.join(modpath, "customize.sh")],
                env=base_env,
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(res_old.returncode, 0)
            self.assertIn("Existing module found", res_old.stdout)
            shutil.rmtree(old_active)

            # 4. Device XML hash mismatch must fail
            with open(os.path.join(sys_root, "system/etc/fonts.xml"), "wb") as fh:
                fh.write(b"<familyset>tampered</familyset>\n")
            res_hash = subprocess.run(
                ["sh", os.path.join(modpath, "customize.sh")],
                env=base_env,
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(res_hash.returncode, 0)
            self.assertIn("Device XML hash mismatch", res_hash.stdout)


if __name__ == "__main__":
    unittest.main()
