# Noto Sans + Noto Sans CJK + Apple Emoji (KernelSU Module for OnePlus 13 / OxygenOS 16)

面向 **OnePlus 13 / Android 16 / OxygenOS 16** 的 KernelSU 字体模块（`v1.0.2` / `versionCode=102`，原系统文件名覆盖架构）：
- **原文件名覆盖 + 保持系统家族与回退链顺序**：
  - 不替换整目录 `/system/fonts`，不新增任何 CJK `<family>`，不重建或重排系统 fallback 链，完整保留原 `<family>` 顺序、全部 `<alias>`、TTC 索引 (`0..3`) 以及 `sys-serif` / `serif` / `monospace` / `roboto-flex` / `NotoSerifCJK-Regular.ttc` / `NotoSerifHentaigana.ttf` 等非目标家族。
- **西文无衬线正斜体 (`sans-serif` / `sans-serif-condensed` / `roboto` / `sys-sans-en` / `op-sans-en`)**：
  - 使用官方 `Noto Sans` 正体可变字体覆盖 `Roboto-Regular.ttf`、`SysFont-Regular.ttf`、`SysSans-En-Regular.ttf`、`OPSans-En-Regular.ttf`，并提供独立真斜体文件 `NotoSans-Italic.ttf`（保留 `wdth` `75`/`100` 宽度轴，移除假斜体 `ital` 轴与 OEM `postScriptName`，并将 `weight="1000"` 请求的 `wght` 轴安全钳制到 `900`）。
- **中日韩完整可变字体与真 TTC (`zh-Hans` / `zh-Hant,zh-Bopo` / `ja` / `ko`)**：
  - 主机端通过 `fontTools` ([`tools/make_fonts.py`](tools/make_fonts.py)) 由锁定的四地区 `NotoSansCJK{jp,kr,sc,tc}-VF.ttf` 生成真实 4-face OpenType Collection `NotoSansCJK-Regular.ttc`（`index 0=JP, 1=KR, 2=SC, 3=TC`，共享表结构约 `37.6 MB`），同时以 `NotoSansCJKsc-VF.ttf` / `NotoSansCJKtc-VF.ttf` 覆盖 `SysSans-Hans-Regular.ttf` / `SysSans-Hant-Regular.ttf`。
  - **CJK 衬线 (`fallbackFor="serif"`) 原字节保护**：由于 OxygenOS 的 `fonts.xml` 与 `fonts_base.xml` 中 `zh-Hans` / `zh-Hant,zh-Bopo` 的普通无衬线与 `fallbackFor="serif"` 共享 `SysSans-Hans/Hant-Regular.ttf` 文件名，安装器在安装时从可信系统原件复制生成 `KsuReserved-SysSans-Hans-Regular.ttf` 与 `KsuReserved-SysSans-Hant-Regular.ttf`（原字节不改、不进公开 ZIP），并将四处 `fallbackFor="serif"` 节点文件名指向保留副本，保持原 `weight`/`style`/`postScriptName`/`axis` 完全不变。
- **Apple Color Emoji 与原厂 Emoji 回退 (`und-Zsye`)**：
  - `samuelngs/apple-emoji-ttf` 的 `CBDT/CBLC` 彩色位图字体直接覆盖原名 `NotoColorEmoji.ttf`；安装时将原系统 `/system/fonts/NotoColorEmoji.ttf` 备份至 `KsuReserved-NotoColorEmoji.ttf`。
  - 在首个有效 `und-Zsye` 家族前仅新增一个 `<family lang="und-Zsye">`，指向 `NotoColorEmoji.ttf` 并显式声明 `postScriptName="KsuAppleColorEmoji"`，同时将紧随其后的原家族改为指向 `KsuReserved-NotoColorEmoji.ttf`（显式 `postScriptName="NotoColorEmoji"`），防止针对 `NotoColorEmoji` 身份的可下载字体更新覆盖主 Apple Emoji，同时保留原厂 Emoji 与 `NotoColorEmojiFlags.ttf` 缺字回退。

> [!IMPORTANT]
> **未真机验证说明**：当前 `v1.0.2` 候选包已完成主机端 `fontTools` + 原生 `FreeType` / `HarfBuzz` 字体与 TTC 索引校验、节选 Fixture 及本地三份完整 OEM XML（`font_fallback.xml` / `fonts.xml` / `fonts_base.xml`）的 BusyBox `awk` / `gawk` 转换与独立差异校验、以及 BusyBox `ash` 模拟安装/升级测试，但 **`v1.0.2` 尚未在 OnePlus 13 (Android 16 / OxygenOS 16) 真机上刷入与实机验证**。

---

## 目录结构

- [`sources.lock`](sources.lock)：锁定的上游字体与许可证 URL、Commit/Tag 及 SHA-256 校验值。
- [`module/`](module/)：KernelSU 模块源码（[`module.prop`](module/module.prop)、[`customize.sh`](module/customize.sh)、[`tools/fontconfig.sh`](module/tools/fontconfig.sh)、[`tools/fontxml.awk`](module/tools/fontxml.awk)）。
- [`tools/make_fonts.py`](tools/make_fonts.py)：主机端字体构建器（生成 8 个原文件名覆盖 `.ttf`、确定性 4-face `NotoSansCJK-Regular.ttc`，以及区分上游源哈希与产物哈希的确定性清单 `font-manifest.txt`）。
- [`tools/check_fonts.py`](tools/check_fonts.py)：主机端 `fontTools` + `FreeType` + `HarfBuzz` 校验器（校验 9 个构建字体及 `font-manifest.txt`、SHA-256、TTC 4 个 face 的地区名/源表字节对应关系与 `U+9AA8` `骨` 字形差异、`wght`/`wdth` 轴与 `CBDT/CBLC` 位图表）。
- [`scripts/build.sh`](scripts/build.sh)：拉取/校验锁定资产、生成构建字体与 `font-manifest.txt`、运行字体校验并构建模块 ZIP 与 `.sha256` 清单。
- [`scripts/verify_zip.sh`](scripts/verify_zip.sh)：校验产出的模块 ZIP 完整性、路径安全、必需文件与白名单（含 `font-manifest.txt`）、`module.prop` 元数据、禁止项（无 OEM XML、无 `KsuReserved-*`、无旧 `KSU-*`）、与已校验 `build/fonts` 产物的字节一致性，并用 `fontTools` 解析校验包内 `NotoSansCJK-Regular.ttc` 的 4 个 face、关键表/轴及上游源 TTF 表字节一致性。
- [`tests/`](tests/)：回归测试套件（[`tests/run.sh`](tests/run.sh)、[`tests/verify_xml.py`](tests/verify_xml.py) 及明确标注为节选的 [`tests/fixtures/`](tests/fixtures/)）。
- [`NOTICE.md`](NOTICE.md) & [`licenses/`](licenses/)：上游许可证原文与真实版权/资产说明。

---

## 本地构建与验证

### 依赖要求
- POSIX `sh`、`awk`（推荐同时安装 `busybox` 以执行 BusyBox `awk`/`ash` 兼容测试）、`curl`（或 `wget`）、`sha256sum`
- `python3`、`fontTools` 库，以及系统原生 `libfreetype` (`libfreetype.so.6`) 与 `libharfbuzz` (`libharfbuzz.so.0`)（仅主机端构建与校验使用，设备端安装不依赖 Python）
- `shellcheck`（用于静态检查脚本）

### 构建步骤

```sh
# 1. 下载锁定字体、生成覆盖字体与 TTC、校验字体并构建 ZIP
sh scripts/build.sh

# 2. 单独校验构建目录字体（fontTools + FreeType + HarfBuzz）
python3 -I tools/check_fonts.py build/fonts

# 3. 运行静态与全量回归测试（含 BusyBox 与三份 OEM XML 测试）
KSU_TEST_BUSYBOX=/usr/lib/initcpio/busybox TMPDIR=/tmp/opencode sh tests/run.sh

# 4. 校验打包产物 ZIP
sh scripts/verify_zip.sh dist/ksu-noto-fonts-apple-emoji-v1.0.2.zip
```

构建完成后，候选模块包位于：
- `dist/ksu-noto-fonts-apple-emoji-v1.0.2.zip`
- `dist/ksu-noto-fonts-apple-emoji-v1.0.2.zip.sha256`

---

## 设备安装要求与升级规则

### 前置条件
1. **KernelSU 与挂载提供者 (Metamodule)**：
   - 本模块不包含自定义挂载脚本，也不自行执行 `mount`，依赖 KernelSU 的 metamodule 机制（如 `mmrs` / `meta-overlayfs`）挂载 `$MODDIR/system`（入口脚本为 `metamount.sh`）。
   - 安装阶段对 `metamount.sh` 的检查仅代表静态入口文件存在，**不代表重启后实际运行时挂载一定成功**。
2. **可信系统原件与升级校验 (`KsuReserved-*.ttf` + `fingerprint` + `sha256sums`)**：
   - 首次安装时，`/system/etc` 下的目标 XML 与 `/system/fonts/{SysSans-Hans-Regular.ttf,SysSans-Hant-Regular.ttf,NotoColorEmoji.ttf}` 必须为未受污染的系统原件，且系统构建指纹（`build.prop` 或 `getprop`）必须可真实读取（缺失或无法读取时直接 fail closed 拒绝安装，不回退固定占位值）；安装器会生成三份 `KsuReserved-*.ttf` 副本并记录系统构建指纹 (`config/original/fingerprint`) 与 SHA-256 清单 (`config/original/sha256sums`)。
   - 模块覆盖升级时，仅当系统构建指纹可读取且与备份一致、全部原始 XML 备份与三份 `KsuReserved-*.ttf` 副本通过 SHA-256 与防污染校验时才会安全复用；**若系统构建指纹缺失/无法获取、缺少可信原件、备份损坏或系统经历 OTA 导致 fingerprint 变化，安装器会显式拒绝安装，要求先禁用模块并重启以重新获取干净系统原件**。
3. **无冲突字体模块**：
   - 请先禁用或卸载其他修改 `/system/fonts`、`/system/etc/fonts*.xml` 或 `/system/system_ext/etc/fonts*.xml` 的模块。

### 安装步骤
1. 将 `dist/ksu-noto-fonts-apple-emoji-v1.0.2.zip` 传输至手机。
2. 打开 KernelSU 管理器 -> 模块 -> 从本地安装，选择该 ZIP 包。
3. 确认安装日志输出：
   - `- Preserved original system fonts as KsuReserved-*.ttf for serif & emoji fallback`
   - `- Adapted /system/etc/font_fallback.xml and /system/etc/fonts.xml`
   - `- Adapted /system_ext/etc/fonts_base.xml`（当设备存在受支持的 `fonts_base.xml` 时）
   - `- Fallback stats: OK mode=fallback ...`
   - `- Legacy stats:   OK mode=legacy ...`
   - `- Base stats:     OK mode=base ...`
4. 重启设备使字体覆盖生效。

---

## 设备端诊断与故障恢复

```sh
# 检查模块生成的配置文件、保留原厂字体副本与备份校验清单
ls -l /data/adb/modules/ksu_noto_fonts_apple_emoji/system/etc/
ls -l /data/adb/modules/ksu_noto_fonts_apple_emoji/system/system_ext/etc/
ls -l /data/adb/modules/ksu_noto_fonts_apple_emoji/system/fonts/KsuReserved-*
cat /data/adb/modules/ksu_noto_fonts_apple_emoji/config/original/fingerprint
cat /data/adb/modules/ksu_noto_fonts_apple_emoji/config/original/sha256sums

# 检查重启后 /system/fonts 挂载状态
ls -l /system/fonts/NotoSans-Italic.ttf /system/fonts/KsuReserved-*
```

- **正常禁用/卸载**：在 KernelSU 管理器中禁用或卸载模块并重启，系统即恢复原始字体。
- **安全模式/命令行恢复**：
  ```sh
  touch /data/adb/modules/ksu_noto_fonts_apple_emoji/disable
  reboot
  ```

---

## 已知边界与限制

- **不扫描/不删除 `/data/fonts`、不禁用 GMS 服务、不伪造字体内部表名**：本模块绝不触碰 `/data/fonts`、不禁用任何系统或 GMS 组件，也不修改字体内部 `name` / `head.fontRevision` 表。通过 XML 显式区分 `postScriptName="KsuAppleColorEmoji"` 与 `postScriptName="NotoColorEmoji"` 可防止针对 `NotoColorEmoji` 的已知更新覆盖 Apple Emoji，但若未来系统或 Play 服务下发针对 `KsuAppleColorEmoji` 或同名路径的特殊更新机制，则不在保证范围内。
- **OTA 升级要求**：系统 OTA 后构建指纹 (`ro.system.build.fingerprint`) 发生变化，直接升级刷入会被安装器拒绝；请先在 KernelSU 管理器中禁用或卸载本模块并重启，再重新刷入模块以从新系统提取匹配的 XML 与 `KsuReserved-*.ttf` 原件。
- **有限 XML 格式与分区覆盖约束**：若设备存在未知 XML 结构或 `/my_product`、`/odm`、`/product`、`/vendor` 等不支持的分区字体配置覆盖，安装器将 fail closed 拒绝安装并清理全部暂存文件。
