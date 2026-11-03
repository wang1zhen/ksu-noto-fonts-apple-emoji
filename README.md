# Noto Sans + Noto Sans CJK + Apple Emoji (KernelSU Module for OnePlus 13 / OxygenOS 16)

面向 **OnePlus 13 / Android 16 / OxygenOS 16** 的 KernelSU 字体模块：
- **西文默认无衬线 (`sans-serif` / `sys-sans-en` / `op-sans-en`)**：使用官方 `Noto Sans` 可变字体（独立正体 `KSU-NotoSans-Regular-VF.ttf` 与真斜体 `KSU-NotoSans-Italic-VF.ttf`，宽度轴 `wdth` 固定为 `100`，字重覆盖 `100..900`）。
- **中日韩按 Locale 路由 (`zh-Hans` / `zh-Hant,zh-Bopo` / `ja` / `ko`)**：保留原系统 CJK `<family>` 块完整不变，并在其前方插入独立的 `<family lang="...">`；新家族内放置完整版 `Noto Sans CJK SC / TC / JP / KR` 可变字体 (`KSU-NotoSansCJK{sc,tc,jp,kr}-VF.ttf`) 及原家族中全部带 `fallbackFor` 的完整 `<font>` 元素副本（含 `<axis>` 子标签）。该结构既避免在单个 `FontFamily.Builder` 实例内产生同 `(fallbackFor, weight, style)` 重复样式异常，又确保 `serif` 等专用回退链首选仍为原系统衬线字体、普通无衬线链首选切换为新 `Noto Sans CJK`，同时保留原系统 CJK 家族与第二个日文假名家族 (`NotoSerifHentaigana.ttf`) 作为后备。
- **Emoji (`und-Zsye`)**：在首个有效 Emoji 家族前插入 `samuelngs/apple-emoji-ttf` 的 Linux `CBDT/CBLC` 彩色位图字体 (`KSU-AppleColorEmoji.ttf`)，保留 `ignore="true"` 的 `NotoColorEmojiLegacy.ttf`、系统 `NotoColorEmoji.ttf` 与旗帜字体 `NotoColorEmojiFlags.ttf` 作为缺字回退。
- **最小安全与有限格式设计**：安装时在设备端基于真实 `/system/etc/font_fallback.xml` 与 `/system/etc/fonts.xml` 动态生成并通过 `validate_only` 状态机校验模块配置，不覆盖通用整份 XML；不包含 WebUI、后台常驻服务、自定义挂载脚本或 SELinux 放宽规则。

> [!IMPORTANT]
> **未真机验证说明**：当前仓库已完成主机端字体表结构校验（`fontTools`）、基于节选 Fixture 的 XML 转换与有限格式状态机测试、以及模拟 KernelSU 安装生命周期测试，但**尚未在 OnePlus 13 (Android 16 / OxygenOS 16) 真机上刷入与实机视觉验收**。

---

## 目录结构

- [`sources.lock`](sources.lock)：锁定的上游字体与许可证 URL、Commit/Tag 及 SHA-256 校验值。
- [`module/`](module/)：KernelSU 模块源码（[`module.prop`](module/module.prop)、[`customize.sh`](module/customize.sh)、[`tools/fontconfig.sh`](module/tools/fontconfig.sh)、[`tools/fontxml.awk`](module/tools/fontxml.awk)）。
- [`tools/check_fonts.py`](tools/check_fonts.py)：主机端 `fontTools` 校验器（检查字体族名、PostScript 名称、可变轴范围、代表字符覆盖率、完整 CJK 码表规模及 Emoji `CBDT/CBLC` 位图表）。
- [`scripts/build.sh`](scripts/build.sh)：拉取/校验锁定资产、运行字体校验并构建可安装模块 ZIP 与 `.sha256` 清单。
- [`scripts/verify_zip.sh`](scripts/verify_zip.sh)：校验产出的模块 ZIP 完整性、路径安全、必需文件与字体 SHA-256。
- [`tests/`](tests/)：回归测试套件（[`tests/run.sh`](tests/run.sh)、[`tests/verify_xml.py`](tests/verify_xml.py) 及明确标注为节选的 [`tests/fixtures/`](tests/fixtures/)）。
- [`NOTICE.md`](NOTICE.md) & [`licenses/`](licenses/)：上游许可证原文与真实版权/资产说明。

---

## 本地构建与验证

### 依赖要求
- POSIX `sh`、`awk`、`curl`（或 `wget`）、`sha256sum`
- `python3` 及 `fontTools` 库（仅主机端构建与校验使用，设备端安装不依赖 Python）
- `shellcheck`（用于静态检查脚本）

### 构建步骤

```sh
# 1. 运行静态与回归测试
sh tests/run.sh

# 2. 下载锁定字体、校验字体表结构并构建可刷入 ZIP
sh scripts/build.sh

# 3. 单独校验构建目录字体与打包产物
python3 -I tools/check_fonts.py build/fonts
sh scripts/verify_zip.sh dist/*.zip
```

构建完成后，可安装模块包位于：
- `dist/ksu-noto-fonts-apple-emoji-v1.0.0.zip`
- `dist/ksu-noto-fonts-apple-emoji-v1.0.0.zip.sha256`

---

## 设备安装要求与步骤

### 前置条件
1. **KernelSU 与挂载提供者 (Metamodule)**：
   - 本模块本身不包含挂载脚本，也不自行执行 `mount`，完全依赖 KernelSU 的 metamodule 机制挂载 `$MODDIR/system`（入口脚本为 `metamount.sh`）。
   - 安装时 [`fontconfig.sh`](module/tools/fontconfig.sh) 会严格检查静态 metamodule 入口：
     - 校验目标目录未被标记 `disable` 或 `remove`，具备包含非空 `id=` 与 `metamodule=1`（或 `true`）的普通文件 `module.prop`，且存在**非空普通文件 `metamount.sh`**；
     - 若存在 `/data/adb/metamodule` 符号链接则解析其真实目标，断链、缺少 `metamount.sh` 的空壳目录或多个冲突 metamodule 候选均会被拒绝；
     - 当 `/data/adb/metamodule` 链接不存在时，仅在 `/data/adb/modules/*` 中扫描到**唯一**有效 metamodule 候选时才允许通过；
     - `/data/adb/modules_update/<id>` 中的暂存 metamodule 仅在满足 KernelSU 官方暂存契约（对应 `/data/adb/modules/<id>` 存在同 `id` 的 `metamodule=1` `module.prop` 及普通文件 `update` 标记）时才被接受；
     - 不使用任何基于 `KSU_VER_CODE` 版本号的旧版挂载推断或 `KSU_LEGACY_MOUNT_OK` 环境变量绕过。
   - **重要说明**：安装阶段对 `metamount.sh` 的检查仅代表静态入口文件存在，**不代表重启后实际运行时挂载一定成功**；重启后需按下方步骤确认 `/system/fonts/KSU-*` 是否实际生效。
2. **无冲突字体模块**：
   - 请先禁用或卸载其他修改 `/system/fonts` 或 `/system/etc/fonts*.xml` 的模块，否则安装脚本会检测到冲突并拒绝安装。

### 安装步骤
1. 将 `dist/ksu-noto-fonts-apple-emoji-v1.0.0.zip` 传输至手机。
2. 打开 KernelSU 管理器 -> 模块 -> 从本地安装，选择该 ZIP 包。
3. 确认安装日志输出：
   - `- Adapted /system/etc/font_fallback.xml and /system/etc/fonts.xml`
   - `- Fallback stats: OK mode=fallback ...`
   - `- Legacy stats:   OK mode=legacy ...`
   - `- Static metamodule entrypoint (metamount.sh) verified; actual mount occurs on reboot.`
4. 重启设备使字体挂载生效。

---

## 设备端诊断与验证

重启后可通过 ADB 或终端检查模块状态与实际挂载结果：

```sh
# 1. 检查模块生成的配置文件与原始备份是否存在
ls -l /data/adb/modules/ksu_noto_fonts_apple_emoji/system/etc/
ls -l /data/adb/modules/ksu_noto_fonts_apple_emoji/config/original/etc/

# 2. 检查系统分区是否已由 metamodule 在运行时成功挂载模块字体与配置
ls -l /system/fonts/KSU-*
grep -n "KSU-" /system/etc/font_fallback.xml /system/etc/fonts.xml
```

**真机视觉验收建议**：
- 检查西文常规/粗体/斜体 (`100..900` 字重与真斜体) 显示。
- 切换文本语言标注 (`zh-Hans`、`zh-Hant`、`ja`、`ko`) 检查异体字形（如 `骨`、`直`、`曜`、`国/國`、假名与谚文）是否随 locale 正确切换，同时确认衬线 (`serif`) 文本仍保持衬线字形。
- 检查常用 Emoji、肤色修饰符、ZWJ 组合序列及旗帜回退是否正常渲染。

---

## 禁用、卸载与故障恢复

- **正常禁用/卸载**：在 KernelSU 管理器中禁用或卸载 `Noto Sans + Noto Sans CJK + Apple Emoji (OOS16)` 模块并重启，系统即恢复原始字体。
- **救砖/安全模式恢复**：
  - 本模块绝不直接写入真实 `/system` 分区，所有更改均位于 `/data/adb/modules/ksu_noto_fonts_apple_emoji`。
  - 若遇到无法进入桌面或显示异常，可在开机时触发 KernelSU 安全模式（如连续按音量下键），或在恢复模式 / ADB root shell 下执行：
    ```sh
    touch /data/adb/modules/ksu_noto_fonts_apple_emoji/disable
    reboot
    ```

---

## 系统 OTA 升级注意事项

1. **OTA 更新前**：
   - 请在 KernelSU 管理器中**禁用或卸载**本模块并重启，确保系统处于未挂载字体覆盖状态后再下载并安装 OxygenOS 系统 OTA。
2. **OTA 更新后**：
   - 由于新系统版本的 `/system/etc/font_fallback.xml` 或 `/system/etc/fonts.xml` 可能发生变动，请勿直接重新启用旧模块缓存的备份；建议**先卸载旧模块（或删除 `/data/adb/modules/ksu_noto_fonts_apple_emoji/config/original`）后重新刷入本模块 ZIP**，以便基于 OTA 后的新系统原件重新生成适配配置。

---

## 已知边界与限制

- **有限 XML 格式约束**：[`fontxml.awk`](module/tools/fontxml.awk) 采用白名单状态机校验单 `<familyset>` 根、`family -> font -> axis` 嵌套及顶层 `<alias .../>`；要求 `<family ...>` 开标签与 `</family>` 闭标签各自独占逻辑行，且同一 `<family>` 内按 `(fallbackFor, weight, style)` 分组的字体样式必须唯一。若设备 XML 含未知标签、同逻辑行多 `<family>`、未闭合标签/注释、根闭合后额外内容、目标 CJK `<family>` 含 `lang` 以外的未知属性或缺少 `fallbackFor` 回退项，转换器将显式拒绝并中止安装。
- **未标注语言文本 (Unannotated Han Text)**：Android 根据视图/文本的 Locale 顺序路由 CJK 字体；未显式标注语言标签的纯汉字文本会优先跟随系统当前首选语言。
- **应用自带字体**：硬编码自带字体或绕过系统 `fonts.xml` / `font_fallback.xml` 的应用（如部分游戏或自定义渲染引擎）不受系统字体模块影响。
- **不支持的分区覆盖**：若 ROM 在 `/my_product`、`/odm`、`/product`、`/system_ext` 或 `/vendor` 下存在额外的 `fonts.xml` / `font_fallback.xml` 覆盖文件，本模块为避免静默错配会显式报错并中止安装。
