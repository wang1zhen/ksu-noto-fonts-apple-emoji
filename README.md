# Noto Sans + Noto Sans CJK + Apple Emoji (`v2.0.0`)

面向 **KernelSU (Android 8.0+ / API 26+)** 的本地安装期字体配置适配模块（`v2.0.0` / `versionCode=200`，`author=wang1zhen`）。以本地 [`font-settings`](https://github.com/yuzlyn/font-settings)（commit `09d9e30943206c183ce50dce9611398091b1c142`）的 `tools/fontconfig.sh` + `tools/fontxml.awk` 与角色隔离策略为基础简化构建，不沿用 `v1.x` 体系。

> [!WARNING]
> **真机验证与更新兼容真实性说明**：
> - `v1.0.3` 固定包在真机上仍出现汉字全部方框（tofu），禁用模块重启可恢复。
> - 参考项目 `font-settings` 尚未在本机做过真机实测，**不能称为 known-good**。
> - 本 `v2.0.0` 已在主机端通过 BusyBox `1.36.1` `ash`/`awk`、真实 3 份 OEM XML 本地回归、合成边界测试与 `fontTools` 角色隔离校验，但**尚未在真机刷入验证**；跨版本原位升级与系统 OTA 兼容性**未经证实**，请始终按下方“先卸载旧模块并重启”流程操作。

---

## 核心设计（`v2.0.0`）

1. **安装期小脚本捕获与生成（无预置固定 XML、无后台服务、无 WebUI）**
   - [`module/customize.sh`](module/customize.sh) 在安装时调用 [`module/tools/fontconfig.sh`](module/tools/fontconfig.sh) 与 [`module/tools/fontxml.awk`](module/tools/fontxml.awk)。
   - 按路径白名单捕获实际系统存在的配置：
     - `/system/etc/fonts.xml`（必需）
     - `/system/etc/font_fallback.xml`
     - `/system_ext/etc/fonts.xml`（及 `/system/system_ext/etc/fonts.xml` SAR 别名）
     - `/system_ext/etc/fonts_base.xml`（及 `/system/system_ext/etc/fonts_base.xml` SAR 别名）
     - `/product/etc/fonts.xml`、`/product/etc/fonts_customization.xml`
     - `/vendor/etc/fonts.xml`
   - 先在临时目录完成全部生成并校验必需角色（`western`、`cjk_sc`、`cjk_tc`、`cjk_jp`、`cjk_kr`、`emoji`）均命中后，再提交到 `$MODPATH/system/...` 并统一设置目录 `0755`、文件 `0644`。任一步骤失败均立即中止且不残留半成品。
2. **7 个独立 TTF 字体负载与主机端 `cmap` 角色隔离（无 TTC 合成）**
   - 打包文件：
     - `KSU-NotoSans-Regular-VF.ttf`、`KSU-NotoSans-Italic-VF.ttf`（官方 Noto Sans 正斜体可变字体）
     - `KSU-NotoSansCJKsc-VF.ttf`、`KSU-NotoSansCJKtc-VF.ttf`、`KSU-NotoSansCJKjp-VF.ttf`、`KSU-NotoSansCJKkr-VF.ttf`（官方完整 Noto Sans CJK 四区域独立可变 TTF，不合成 TTC）
     - `KSU-AppleColorEmoji.ttf`（`samuelngs/apple-emoji-ttf` Linux CBDT/CBLC 构建，原样复制）
   - 构建期 [`tools/make_fonts.py`](tools/make_fonts.py) 按参考项目 `font-settings/webroot/font-isolation.js` 的完全一致码位区间执行主机端 `cmap` 角色隔离：
     - **CJK 字体**移除 Latin / 数字 / 西文标点及半角全角 ASCII 映射（保留汉字与 CJK 标点如 `U+3002`），使中文家族不会抢占西文字符。
     - **Western 字体**移除 CJK / 假名 / 谚文映射。
     - 同步清理所有 Unicode `cmap` 子表及 `format 14` UVS 变体序列（仅保留仍存在合法映射的基底码位与字形），不修改字体内部 `name` 表，保留源 hash 与产物 hash 双重清单 [`font-manifest.txt`](build/fonts/font-manifest.txt)。
3. **AWK 原位角色替换规则**
   - **西文 (`sans-serif` / `sys-sans-en` / `op-sans-en` 及 `etc/fonts.xml` 首默认无名家族)**：按原 `<font>` 槽位的 `normal`/`italic` 选择 `KSU-NotoSans-Regular-VF.ttf` 或 `KSU-NotoSans-Italic-VF.ttf`；原家族无斜体槽时不批量伪造斜体槽。
   - **中日韩分区域路由**：`zh-Hans` -> `SC`，`zh-Hant` / `zh-Bopo` / 传统粤语 (`yue`) -> `TC`，`ja` -> `JP`，`ko` -> `KR`；绝不把所有中文塞进同一列表，不新增额外 CJK `<family>`，完整保留 `NotoSerifHentaigana` 假名专用家族。
   - **槽位属性与衬线回退说明**：重建目标 `<font>` 槽时仅保留原槽 `weight`、`style`、`fallbackFor`，不继承原字体的 `index`、`postScriptName` 或非 `wght` 轴（如 `ital`）。现代 `supportedAxes="wght"` 槽保留 `supportedAxes="wght"` 且不叠加固定 `<axis tag="wght">`；传统槽输出钳制在 `100..900` 的 `<axis tag="wght">`（如 `weight="1000"` 钳制为 `900`）。依照批准的 `font-settings` 策略，目标 CJK 家族内的 `fallbackFor="serif"` 槽位同样映射为对应的地域 `NotoSansCJK*-VF.ttf` 无衬线新字体，不保留或复制原厂衬线/OEM 字体文件。
   - **Emoji (`und-Zsye`)**：仅替换每个配置文件中第一个有效（非 `ignore="true"`、非 `Flags`/`Compat`）的 `und-Zsye` 家族，将其 `<font>` 原位替换为单一 `KSU-AppleColorEmoji.ttf` 槽位（去除原 `postScriptName`，不使用 `NotoColorEmoji.ttf` 身份），不新增 `<family>`、不重复槽位，原样保留 `NotoColorEmojiLegacy.ttf` (`ignore="true"`) 与 `NotoColorEmojiFlags.ttf`。不覆盖系统其他 `Noto*.ttf`，不触碰 `/data/fonts` 或 GMS。

---

## 安装、卸载与更新要求

- **安装前必须卸载旧版并重启**：若 `/data/adb/modules/ksu_noto_fonts_apple_emoji` 已存在（非当前安装暂存目录），或 `/system` 生效配置中已包含本模块 `KSU-*` 字体引用，安装脚本将直接拒绝。请先在 KernelSU 管理器中卸载旧模块并重启，恢复原厂 `/system/etc` 配置后再刷入。
- **系统 OTA 前请先卸载并重启**：本模块不含 `post-fs-data.sh` / `service.sh` / `action.sh` 或持久迁移目录。

---

## 本地测试与构建命令

```sh
# 1. 运行 Python 单元与集成测试
python3 -I -m unittest discover -s tests -v

# 2. 使用主机 BusyBox 1.36.1 实跑 ash/awk 与本地 3 份真实 OEM XML 回归
KSU_TEST_BUSYBOX=/usr/lib/initcpio/busybox TMPDIR=/tmp/opencode sh tests/run.sh

# 3. ShellCheck 静态检查交付脚本
.cache/shellcheck-v0.10.0/shellcheck -s sh module/customize.sh module/tools/fontconfig.sh scripts/*.sh tests/run.sh

# 4. 构建并校验 v2.0.0 模块 ZIP
sh scripts/build.sh
```
