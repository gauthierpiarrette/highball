# 简体中文本地化维护说明

## 基线与来源

- 官方仓库：https://github.com/gauthierpiarrette/highball
- 本次基线：`01743aeb18f64e4386f0ecc4737bb04df7a55737`（获取时官方 main）。
- 翻译来源：https://github.com/Usagi53Q/highball-zh ，提交 `15cb7503ce04da5ede9e4785b553fdcc5952bb82`，沿用 GPL-3.0 授权。
- `origin`：https://github.com/digi-TSink/highball ；`upstream`：官方仓库。
- 本地分支：`feat/zh-hans-localization`。未推送、未发布、未创建 PR。

## 架构

继续使用上游的 `L()` / 英文键词典架构。将共用的 `L10n` 放入 HighballKit，供 SwiftUI 和游戏页面、恢复提示、下载进度等展示辅助函数使用。HighballApp 的 `L()` 只是同一实现的薄包装，没有引入另一套本地化框架。

- `Sources/HighballKit/L10n.swift`：语言选择、精确查表和英文回退。
- `L10nChinese.swift`：独立简体中文词典。
- `L10nFrench.swift`：原法语词典，808 条键值及顺序逐项保持不变。
- `L10nActivity.swift`：仅在界面显示时转换已知进度文本；状态和日志继续保留原始格式，避免破坏步骤解析。
- `L10n.format()`：先翻译模板，再插入参数；游戏名称、路径、运行参数不会被当作翻译键。

`HighballLanguage` 支持 `zh-Hans`、`en`、`fr`。有效手动设置优先；否则按系统偏好顺序选择支持的语言。识别 `zh-Hans-*`、`zh-CN`、`zh-SG`；不会把繁体地区自动当作简体中文。无支持语言时回退英文。任意缺失键直接显示原英文。

没有新增设置界面。没有修改 Wine 引擎、运行配置、兼容性判定、下载器或存档操作逻辑。对这些功能的改动仅涉及其现有显示文案。

## 翻译审计

当前共 **936 条简体中文条目**：旧词典 533 条、旧内联文案迁移增加 69 个唯一键、其余 334 条为新补充文案。包含旧键是为了保留后续迁移价值；不会以旧源文件覆盖新上游实现。

静态审计识别 **826 个显式本地化键，中文缺失 0 个**。这不代表整个应用的所有可能输出都是中文：外部数据库描述、游戏信息、原始工具错误、日志和部分底层诊断仍可显示英文。

- 重复键：0。
- 中文占位符不匹配：0；换行数量不匹配：0。
- 法语原词典：完整保留。审计中新增共用展示键有 109 个未配法语，按既有规则回退英文。
- 110 个键未被静态字面量调用直接引用，可能是运行时键或旧版本键；详见 JSON，不自动删除。
- 146 行潜在未本地化候选、97 行动态文案候选，均带源码位置。候选包含数字、产品名、路径、命令标识符、已在外层翻译的值与日志，不能当成“缺译条数”。
- 已人工区分出 34 行底层返回文本候选，主要在 `Bottle.swift`、`EpicSaves.swift`、`EpicStore.swift`、`GOGLibrary.swift`、`Paths.swift`、`SteamGameAction.swift`、`EngineIntegrity.swift`。其中部分已有显示层精确翻译，动态异常和第三方原因仍需后续按显示边界逐项处理，不能对任意日志做模糊替换。

机器可读全量清单由审计脚本在本地生成到 `docs/localization-audit.json`，不纳入版本控制，避免字符串变更后报告过期。手工复核清单：[`localization-review.json`](localization-review.json)。

重新生成：

```sh
python3 Scripts/audit-localization.py --output docs/localization-audit.json
```

构建脚本会逐语言检查重复键、中文占位符和换行，错误时拒绝打包。缺译仍是警告，以便新增上游功能正常回退英文。占位符校验支持 `%2$@` 等位置参数；保留旧译文的合法语序调整，并修正迁移过程中“缺失文件 / 引擎名称”的参数顺序。

## 构建与测试

常规环境沿用官方流程：

```sh
swift build
swift test
Scripts/make-app.sh debug
```

本次受限环境将编译缓存放在仓库 `.build/local-cache` 下，并使用 `--disable-sandbox` 避免 SwiftPM 再嵌套一层沙箱。宿主权限沙箱仍生效。后续测试及打包使用 `--build-system native`。构建脚本现在通过 `swift build --show-bin-path` 获取产物位置，兼容不同 SwiftPM 后端，不再假定二进制固定在 `.build/debug`。

测试使用进程内的 UserDefaults argument domain，不写用户偏好文件。原有英文断言的测试类固定英文，并在结束时恢复进程内偏好；新增本地化测试覆盖中英法选择、英文回退、位置参数、百分号、动态参数、恢复动作、GB 下载进度、进度解析与卸载存档说明。

本次执行结果另见 [`Validation.md`](Validation.md)。

## 启动与切换语言

已核实打包标识符为 **`app.highball.Highball`**，可在 `Scripts/make-app.sh` 和构建后的 `Contents/Info.plist` 中确认。

退出应用后，在终端执行以下命令之一，再重新打开本地构建的应用：

```sh
# 简体中文
 defaults write app.highball.Highball HighballLanguage -string zh-Hans
# 英文
 defaults write app.highball.Highball HighballLanguage -string en
# 法语
 defaults write app.highball.Highball HighballLanguage -string fr
# 恢复跟随系统（已有该设置时）
 defaults delete app.highball.Highball HighballLanguage
```

这些是供用户自行执行的命令，本次没有执行。因为 bundle ID 与正式版相同，它们会影响该 ID 下的应用偏好。

仅测试这一次、且不写语言偏好时，可以从仓库目录直接运行：

```sh
HIGHBALL_HOME="$PWD/.build/localization-preview" HB_DEBUG_NO_ENGINE_UPDATE=1 \
  dist/Highball.app/Contents/MacOS/Highball -HighballLanguage zh-Hans
```

把最后的值换成 `en` 或 `fr` 即可。`HIGHBALL_HOME` 是上游已有的数据目录覆盖机制，用于隔离测试；不要点击首次配置、安装引擎或运行游戏，除非你确实需要执行那些操作。

应用输出位置：`dist/Highball.app`。没有复制到 `/Applications`，没有替换现有 Highball 安装。GUI 检查存在一次未继承隔离变量的启动例外，不能保证没有自动刷新现有缓存；详见验证报告。

## 更新与后续工作

更新时合并官方代码，保留独立词典；在当前上游显示位置添加 `L("English")` 或模板格式化调用。不要把旧汉化的整份界面或核心源文件覆盖进来。新增英文键缺译时会直接回退英文。

后续可逐项补充底层动态诊断与外部数据库文案，并在实际游戏环境中人工检查长中文的换行、截断、辅助功能标签和三种语言下的完整操作流程。测试不会自动安装游戏或引擎来宣称完整功能验证。
