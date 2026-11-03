# Third-Party Notices and Font Licensing

This module packages upstream fonts and build/configuration scripts for KernelSU on OnePlus 13 (Android 16 / OxygenOS 16). All upstream license texts are preserved in [`licenses/`](licenses/).

---

## 1. Noto Sans (Western Variable Fonts)

- **Packaged Files**:
  - `system/fonts/KSU-NotoSans-Regular-VF.ttf` (from `ofl/notosans/NotoSans[wdth,wght].ttf`)
  - `system/fonts/KSU-NotoSans-Italic-VF.ttf` (from `ofl/notosans/NotoSans-Italic[wdth,wght].ttf`)
- **Upstream Repository**: `https://github.com/google/fonts`
- **Pinned Revision**: `8b0a1d0f5983c89bc2b93f1b5fb55f9e252744b5`
- **License**: SIL Open Font License 1.1 (`licenses/OFL-NotoSans.txt`)

---

## 2. Noto Sans CJK (SC / TC / JP / KR Full Variable Fonts)

- **Packaged Files**:
  - `system/fonts/KSU-NotoSansCJKsc-VF.ttf` (from `Sans/Variable/TTF/NotoSansCJKsc-VF.ttf`)
  - `system/fonts/KSU-NotoSansCJKtc-VF.ttf` (from `Sans/Variable/TTF/NotoSansCJKtc-VF.ttf`)
  - `system/fonts/KSU-NotoSansCJKjp-VF.ttf` (from `Sans/Variable/TTF/NotoSansCJKjp-VF.ttf`)
  - `system/fonts/KSU-NotoSansCJKkr-VF.ttf` (from `Sans/Variable/TTF/NotoSansCJKkr-VF.ttf`)
- **Upstream Repository**: `https://github.com/notofonts/noto-cjk`
- **Pinned Revision**: `165c01b46ea533872e002e0785ff17e44f6d97d8`
- **License**: SIL Open Font License 1.1 (`licenses/OFL-NotoSansCJK.txt`)

---

## 3. Apple Color Emoji (Linux CBDT/CBLC Build)

- **Packaged File**:
  - `system/fonts/KSU-AppleColorEmoji.ttf` (from `AppleColorEmoji-Linux.ttf`)
- **Upstream Repository**: `https://github.com/samuelngs/apple-emoji-ttf`
- **Pinned Release / Revision**: `macos-26-20260722-484daf4e` (`484daf4e13942437e083d881cae39fbc92d837e1`)
- **Upstream License & Asset Exclusion Notice**:
  - The build scripts and repository code in `samuelngs/apple-emoji-ttf` are licensed under the MIT License (`licenses/LICENSE-apple-emoji-ttf.txt`).
  - Per the upstream `samuelngs/apple-emoji-ttf` README statement:
    > "The code in this repository is licensed under the MIT License. Apple Color Emoji assets are not included in this license."
  - The MIT License applies only to the upstream repository software/tooling and does **not** grant a license or redistribute rights to Apple Inc.'s proprietary Apple Color Emoji glyph assets.
