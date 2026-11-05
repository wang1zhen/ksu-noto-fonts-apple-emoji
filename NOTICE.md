# Third-Party Notices and Font Licensing

This module (`v2.0.0`) packages upstream open-source fonts, Apple Color Emoji (Linux CBDT/CBLC build), and install-time Android font configuration adaptation scripts (`module/tools/fontconfig.sh`, `module/tools/fontxml.awk`, and host role-isolation logic derived from [`font-settings`](https://github.com/yuzlyn/font-settings) commit `09d9e30943206c183ce50dce9611398091b1c142`). All license texts are preserved in [`LICENSE`](LICENSE) and [`licenses/`](licenses/).

---

## 1. `font-settings` Base Scripts & Role Isolation Logic

- **Derived Components**:
  - `module/customize.sh`, `module/tools/fontconfig.sh`, `module/tools/fontxml.awk` (install-time XML capture & targeted family adaptation)
  - `tools/make_fonts.py` (host-side Unicode `cmap` role isolation rules adapted from `font-settings/webroot/font-isolation.js`)
- **Upstream Reference**: `font-settings` by `yuzlyn` (`09d9e30943206c183ce50dce9611398091b1c142`)
- **License**: MIT License ([`LICENSE`](LICENSE))

---

## 2. Noto Sans (Western Variable Fonts)

- **Packaged Files**:
  - `system/fonts/KSU-NotoSans-Regular-VF.ttf` (derived from upstream `ofl/notosans/NotoSans[wdth,wght].ttf` via host-side `cmap` role isolation; internal font names unchanged)
  - `system/fonts/KSU-NotoSans-Italic-VF.ttf` (derived from upstream `ofl/notosans/NotoSans-Italic[wdth,wght].ttf` via host-side `cmap` role isolation; internal font names unchanged)
- **Upstream Repository**: `https://github.com/google/fonts`
- **Pinned Revision**: `8b0a1d0f5983c89bc2b93f1b5fb55f9e252744b5`
- **License**: SIL Open Font License 1.1 ([`licenses/OFL-NotoSans.txt`](licenses/OFL-NotoSans.txt))

---

## 3. Noto Sans CJK (SC / TC / JP / KR Full Variable Fonts)

- **Packaged Files**:
  - `system/fonts/KSU-NotoSansCJKsc-VF.ttf` (derived from upstream `Sans/Variable/TTF/NotoSansCJKsc-VF.ttf` via host-side `cmap` role isolation; internal font names unchanged)
  - `system/fonts/KSU-NotoSansCJKtc-VF.ttf` (derived from upstream `Sans/Variable/TTF/NotoSansCJKtc-VF.ttf` via host-side `cmap` role isolation; internal font names unchanged)
  - `system/fonts/KSU-NotoSansCJKjp-VF.ttf` (derived from upstream `Sans/Variable/TTF/NotoSansCJKjp-VF.ttf` via host-side `cmap` role isolation; internal font names unchanged)
  - `system/fonts/KSU-NotoSansCJKkr-VF.ttf` (derived from upstream `Sans/Variable/TTF/NotoSansCJKkr-VF.ttf` via host-side `cmap` role isolation; internal font names unchanged)
- **Upstream Repository**: `https://github.com/notofonts/noto-cjk`
- **Pinned Revision**: `165c01b46ea533872e002e0785ff17e44f6d97d8`
- **License & Reserved Font Name Notice**:
  - Licensed under SIL Open Font License 1.1 ([`licenses/OFL-NotoSansCJK.txt`](licenses/OFL-NotoSansCJK.txt), copyright Adobe / Google with Reserved Font Name `"Source"`).
  - Upstream `nameID=0` and `nameID=7` contain Adobe's copyright/trademark notice referencing Reserved Font Name `"Source"`; the font family and PostScript names (`Noto Sans CJK {SC,TC,JP,KR}`, `NotoSansCJK{sc,tc,jp,kr}-Thin`) are preserved verbatim without renaming or using `"Source"` as a font name.

---

## 4. Apple Color Emoji (Linux CBDT/CBLC Build)

- **Packaged File**:
  - `system/fonts/KSU-AppleColorEmoji.ttf` (exact byte-for-byte copy of upstream `AppleColorEmoji-Linux.ttf`)
- **Upstream Repository**: `https://github.com/samuelngs/apple-emoji-ttf`
- **Pinned Release / Revision**: `macos-26-20260722-484daf4e` (`484daf4e13942437e083d881cae39fbc92d837e1`)
- **Upstream License & Asset Exclusion Notice**:
  - The build scripts and repository code in `samuelngs/apple-emoji-ttf` are licensed under the MIT License ([`licenses/LICENSE-apple-emoji-ttf.txt`](licenses/LICENSE-apple-emoji-ttf.txt)).
  - Per the upstream `samuelngs/apple-emoji-ttf` README statement:
    > "The code in this repository is licensed under the MIT License. Apple Color Emoji assets are not included in this license."
  - The MIT License applies only to the upstream repository software/tooling and does **not** grant a license or redistribute rights to Apple Inc.'s proprietary Apple Color Emoji glyph assets.
