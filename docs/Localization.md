# 简体中文本地化维护说明

## 基线与来源

- 官方仓库：https://github.com/gauthierpiarrette/highball
- 翻译来源：https://github.com/Usagi53Q/highball-zh ，提交 `15cb7503ce04da5ede9e4785b553fdcc5952bb82`，沿用 GPL-3.0 授权。

## 架构

继续使用上游的 `L()` / 英文键词典架构。将共用的 `L10n` 放入 HighballKit，供 SwiftUI 和游戏页面、恢复提示、下载进度等展示辅助函数使用。HighballApp 的 `L()` 只是同一实现的薄包装，没有引入另一套本地化框架。

- `Sources/HighballKit/L10n.swift`：语言选择、精确查表和英文回退。
- `L10nChinese.swift`：独立简体中文词典。
- `L10nFrench.swift`：保留上游法语译文；同步上游新增词条时也要更新此文件。
- `L10nActivity.swift`：仅在界面显示时转换已知进度文本；状态和日志继续保留原始格式，避免破坏步骤解析。
- `L10n.format()`：先翻译模板，再插入参数；游戏名称、路径、运行参数不会被当作翻译键。

`HighballLanguage` 支持 `zh-Hans`、`en`、`fr`。有效手动设置优先；否则按系统偏好顺序选择支持的语言。识别 `zh-Hans-*`、`zh-CN`、`zh-SG`；不会把繁体地区自动当作简体中文。无支持语言时回退英文。任意缺失键直接显示原英文。

没有新增设置界面。没有修改 Wine 引擎、运行配置、兼容性判定、下载器或存档操作逻辑。对这些功能的改动仅涉及其现有显示文案。

## 翻译审计

审计脚本按当前源码检查重复键、占位符、换行及缺失译文，并列出需要人工复核的静态和动态文案候选。候选包含技术标识符、路径、数字、外部数据和已由外层翻译的值，不能直接视为缺译条目；未直接引用的键也可能用于运行时文案，不应自动删除。

外部数据库描述、游戏信息、原始工具错误、日志和部分底层诊断仍可显示英文。新增上游词条尚未翻译时直接回退英文。

审计报告、候选清单和本机验证记录会随源码和环境变化，不纳入版本控制。使用下列命令按需生成 `docs/localization-audit.json`；该路径及 `docs/localization-review.json` 均已忽略。

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

构建脚本通过 `swift build --show-bin-path` 获取产物位置，兼容不同 SwiftPM 后端，不再假定二进制固定在 `.build/debug`。

测试使用进程内的 UserDefaults argument domain，不写用户偏好文件。原有英文断言的测试类固定英文，并在结束时恢复进程内偏好；新增本地化测试覆盖中英法选择、英文回退、位置参数、百分号、动态参数、恢复动作、GB 下载进度、进度解析与卸载存档说明。

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

这些命令会影响该 bundle ID 下的应用偏好，包括同 ID 的正式版和本地构建版本。

仅测试这一次、且不写语言偏好时，可以从仓库目录直接运行：

```sh
HIGHBALL_HOME="$PWD/.build/localization-preview" HB_DEBUG_NO_ENGINE_UPDATE=1 \
  dist/Highball.app/Contents/MacOS/Highball -HighballLanguage zh-Hans
```

把最后的值换成 `en` 或 `fr` 即可。`HIGHBALL_HOME` 是上游已有的数据目录覆盖机制，用于隔离测试；不要点击首次配置、安装引擎或运行游戏，除非你确实需要执行那些操作。

应用输出位置：`dist/Highball.app`。`HIGHBALL_HOME` 只隔离环境和游戏数据，不隔离同一 bundle ID 的偏好设置；需要完整隔离时使用独立的 macOS 测试账户。

## 更新与后续工作

更新时合并官方代码，保留独立词典；在当前上游显示位置添加 `L("English")` 或模板格式化调用。不要把旧汉化的整份界面或核心源文件覆盖进来。新增英文键缺译时会直接回退英文。

后续可逐项补充底层动态诊断与外部数据库文案，并在实际游戏环境中人工检查长中文的换行、截断、辅助功能标签和三种语言下的完整操作流程。测试不会自动安装游戏或引擎来宣称完整功能验证。
