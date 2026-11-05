# Noto Sans + Noto Sans CJK + Apple Emoji (`v1.0.3`, OnePlus 13 / OxygenOS 16 Fixed Package)

面向当前 **OnePlus 13 / Android 16 (API 36) / OxygenOS 16** 特定 ROM 配置的本地固定 KernelSU 字体模块（`v1.0.3` / `versionCode=103`，`author=wang1zhen`）：

- **主机预生成固定三份 XML 配置**：
  - 构建阶段由 [`tools/make_xml.py`](tools/make_xml.py) 读取本地根目录三份未跟踪系统原始配置（`font_fallback.xml`、`fonts.xml`、`fonts_base.xml`），严格校验其已知 SHA-256，生成固定 `system/etc/font_fallback.xml`、`system/etc/fonts.xml` 与 `system/system_ext/etc/fonts_base.xml` 并写入 `device-sources.sha256` 及 `payload.sha256`。
  - 手机端 [`module/customize.sh`](module/customize.sh) 不做任何运行时 XML 解析、不备份或复制原厂字体、不读取构建指纹；仅检查 KernelSU + Android 16 (API 36)、确认 `/data/adb/modules/ksu_noto_fonts_apple_emoji` 旧版已卸载移除、比对当前设备三份原系统 XML 的 SHA-256 与 `device-sources.sha256` 一致，并校验 `payload.sha256`。
- **字体与节点映射**：
  - **西文 (`sans-serif` / `sans-serif-condensed` / `roboto` / `sys-sans-en` / `op-sans-en`)**：以 `Noto Sans` 正体可变字体覆盖 `Roboto-Regular.ttf`、`SysFont-Regular.ttf`、`SysSans-En-Regular.ttf`、`OPSans-En-Regular.ttf`，配对独立真斜体 `NotoSans-Italic.ttf`（保留 `wdth` `75`/`100` 与合法 `wght`，移除假斜体 `ital` 轴与 OEM `postScriptName`，`weight="1000"` 对应 `wght` 轴钳制为 `900`）。`sys-serif`、`serif`、`monospace`、`roboto-flex` 等非目标家族保持原样。
  - **中日韩 (`zh-Hans` / `zh-Hant,zh-Bopo` / `ja` / `ko`)**：保留 4-face `NotoSansCJK-Regular.ttc`（`index 0=JP, 1=KR, 2=SC, 3=TC`）覆盖；`fonts.xml` 与 `fonts_base.xml` 中普通无衬线节点改为专用 `KSU-NotoSansCJKsc-VF.ttf` / `KSU-NotoSansCJKtc-VF.ttf`，绝不覆盖系统原 `SysSans-Hans-Regular.ttf` / `SysSans-Hant-Regular.ttf`，使其 `fallbackFor="serif"` 节点与原文件引用、属性完全不动。
  - **Apple Color Emoji (`und-Zsye`)**：打包专用 `KSU-AppleColorEmoji.ttf`，在首个有效 `und-Zsye` 家族前前置唯一 `<family lang="und-Zsye">`（`postScriptName="KsuAppleColorEmoji"`），不覆盖原厂 `NotoColorEmoji.ttf`，不触碰 `/data/fonts` 或 GMS。

> [!IMPORTANT]
> **未实机验证说明**：`v1.0.3` 已完成主机端构建、字体校验与合成单元测试，但**尚未在 OnePlus 13 真机上刷入验证**。

## 严格绑定的三份设备原 XML SHA-256

| 系统路径 | 期望原始 SHA-256 |
| --- | --- |
| `/system/etc/font_fallback.xml` | `7097f4da6a862fc08655a6db74d061820cb1b2c3890ab4474bad62bd734e21c2` |
| `/system/etc/fonts.xml` | `d15b64cddf7260be242b9fc23fb84ce50838ba2c2359a4fe5ce1c484e379c4c1` |
| `/system/system_ext/etc/fonts_base.xml` | `8119a2379b78ebd7b3aab75c368b2cda1d9b219390dbf22701959d415dde0aad` |

## 安装、升级与系统 OTA 要求（无 OTA Hooks）

1. **旧版模块必须先卸载并重启**：若设备已安装旧版 `ksu_noto_fonts_apple_emoji`，必须先在 KernelSU 管理器中**卸载旧模块并重启手机**，使 `/system/etc` 恢复为上表原始 XML 后再安装 `v1.0.3`。
2. **系统 OTA 流程**：本模块不包含任何 OTA hook。**系统 OTA 更新前必须先卸载本模块并重启**；OTA 完成后若系统三份 XML 哈希变化，需提取新系统三份 XML 更新构建后再刷入。

## 本地构建与验证命令

```sh
# 1. 静态检查脚本
.cache/shellcheck-v0.10.0/shellcheck -s sh module/customize.sh scripts/*.sh

# 2. 运行合成 Fixture 单元测试（CI 同款，无需根目录 OEM XML）
python3 -I -m unittest discover tests

# 3. 本地构建固定包 ZIP（需根目录存在三份匹配哈希的设备原 XML）
sh scripts/build.sh

# 4. 校验生成的字体与打包产物
python3 -I tools/check_fonts.py build/fonts
sh scripts/verify_zip.sh dist/ksu-noto-fonts-apple-emoji-v1.0.3.zip
```
