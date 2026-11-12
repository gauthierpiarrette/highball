# 本地验证报告

验证日期：2026-11-11（America/Los_Angeles）。Swift 6.4.2，Apple Silicon。

## 本轮最终结论

当前构建通过；未排除任何用例的完整测试执行 871 项、跳过 10 项，7 个用例失败（8 条失败记录：超深目录删除 2 条、Discord 6 条），耗时约 335 秒，退出码 1。失败在未修改上游源码中同样复现；不能写作 `swift test` 全部通过。随后补充的语言切换测试已执行，8 项 L10nTests 全部通过。没有修改应用实现来规避失败。

## 早先验证记录

| 检查 | 结果 |
| --- | --- |
| 源码构建 | 通过，包含 HighballKit、CLI 和 HighballApp |
| 最终应用打包 | `Scripts/make-app.sh debug` 成功，版本 `0.0.0-dev` |
| 签名完整性 | `codesign --verify --deep --strict dist/Highball.app` 通过 |
| bundle ID | 构建产物确认 `app.highball.Highball` |
| 主要回归 | 869 项，17 项跳过，0 失败；明确排除下面已复现的上游目录清理测试 |
| 最终针对性回归 | 47 项全部通过；含新增 7 项本地化测试、卸载说明和完整 RecipeDBTests |
| 中文词典审计 | 936 条；826 个显式调用键缺译 0；重复键、占位符错误、换行数量错误均为 0 |
| 法语原词典 | 808 条键值及顺序与官方基线完全一致 |
| 图形界面 | 未完成视觉验证，不能声明界面已实测通过 |
| 实际游戏运行 | 未执行；未安装游戏、Wine 引擎或修改运行配置 |

主要回归运行时尚未打包数据库，因此跳过了 7 项数据库测试；打包取得数据库后，最终针对性回归中的 8 项 RecipeDBTests 全部通过。其他跳过项需要特定磁盘、真实游戏环境、额外 fixture，或同级 highball-db 仓库。

## 已复现的上游失败

`BottleDeleteTests.testDeleteHandlesATreeDeeperThanTheStack` 在超深临时目录清理时产生两条断言失败，提示 `.trash` 中存在残留。在**未经任何修改的官方基线**单独运行同一测试，也得到相同的两条失败。因此没有为汉化修改文件删除算法；后续主要回归使用 `--skip BottleDeleteTests/testDeleteHandlesATreeDeeperThanTheStack`。

首次完整运行曾在长时间无输出时中断。继续定位后，耗时来自未改动的引擎组合测试：对 59 个清单的组合重复调用 `sw_vers`。后续主要回归等待其完成并通过，总计约 342 秒。不能将早先的等待误认为本地化导致死锁或 Swift 后端故障。

## 构建环境与命令

最初直接 `swift build` 遇到系统编译缓存目录写入权限限制。随后将 `CLANG_MODULE_CACHE_PATH`、`SWIFTPM_MODULECACHE_OVERRIDE`、`XDG_CACHE_HOME` 指向仓库 `.build/local-cache`，使用 `--disable-sandbox`。这仅关闭 SwiftPM 的嵌套沙箱，不改变宿主权限。

主要回归：

```sh
swift test --disable-sandbox --build-system native \
  --skip BottleDeleteTests/testDeleteHandlesATreeDeeperThanTheStack
```

最终针对性回归：

```sh
swift test --disable-sandbox --build-system native \
  --scratch-path .build/localization-package \
  --filter 'L10nTests|GamePageCopyTests|ActivityTextTests|EngineIntegrityTests|UninstallTests|RecipeDBTests'
```

打包调用官方脚本，使用工作目录中的临时 `swift` 包装器追加上述缓存/后端参数，并将 SwiftPM 产物放入 `.build/localization-package`，避免与长测试争用构建锁。包装器未加入仓库。构建脚本自身通过 `--show-bin-path` 读取二进制路径。

数据库快照：`16c0b03`（2026-11-11）。

## 调试版限制

- 本地 ad-hoc 签名，未公证。
- 没有上游私有 WineLoader provisioning profile，辅助加载器不带受限跨架构 entitlement。
- 本机缺少 mingw-w64，按官方 debug 规则未打包 Epic stand-in 和 Discord pipe bridge。
- 本机 actool 未能编译当前图标资源，按上游 debug 规则使用 icns 图标。
- 因此这个调试包不能当作与官方发行版完全等价的运行环境；源代码层面的相关功能与兼容性分支没有删除。

## GUI 检查及隔离例外

最初从受限终端启动时设置了独立 `HIGHBALL_HOME` 和 `HB_DEBUG_NO_ENGINE_UPDATE=1`，但应用在 macOS `_RegisterApplication` / `NSApplication` 初始化阶段退出（SIGABRT），未取得窗口。随后界面工具读取窗口超时，并额外启动了一个**未继承隔离环境变量**的本地构建实例。

该额外实例已按已核实的进程编号关闭；原有 Highball 进程未被关闭。没有点击安装、游玩、更新、删除、语言切换或其他设置。但不能保证该次启动没有自动刷新现有数据缓存。只读检查发现 `steam-accounts.json` 在该时段有更新时间；因原有 Highball 同时运行，无法确定由哪个实例写入。没有进行推测性回滚或覆盖用户数据。

没有将应用安装到 `/Applications`，也没有替换现有安装。完整的中文布局、中英法 UI 切换与真实游戏运行仍需用户在受控环境下人工验收。

## 交付物

- 源码：本目录上级的整个仓库，分支 `feat/zh-hans-localization`。
- 应用：`../dist/Highball.app`。
- 维护、语言切换、审计说明：[`Localization.md`](Localization.md)。
- 机器审计：[`localization-audit.json`](localization-audit.json)。
- 后续文本候选：[`localization-review.json`](localization-review.json)。
- 关键验证输出：[`validation-results.txt`](validation-results.txt)。
- 完整修改清单：[`modified-files.txt`](modified-files.txt)。

未提交、未推送、未创建 PR、未发布 release。修改保留在本地分支工作区，供检查。

## 本轮四项验收复核

- 最终源码重新构建成功（含删除 Done 和“社区反馈”修改），应用签名验证及 `git diff --check` 通过。
- 语言选择与缺译回退属于自动测试范围；实际窗口中英切换、长文本布局和三个标签居中尚未完成视觉验收。新增进程内偏好 `zh-Hans → en → zh-Hans` 测试，同时检查未知模板保留英文及动态参数。
- Done 删除范围仅为 BottleView 的 confirmationAction 工具栏项，Back 和 Esc 保留；该按钮原有的 Return 默认快捷键也随之移除。Settings 的三个 TabView 标签及布局未改。
- 核心 Wine 运行器、环境存储和启动参数实现没有改动；本次对 AppState 的修改是显示文案。实际游戏启动及真实环境管理没有执行，不能声明全部原有功能已经实机通过。
- 本轮未排除测试项。DiscordPresenceTests 有 6 项本地 socket/bridge 测试失败；在未修改官方基线上复跑同一组，也有相同的 6 项失败（其中 5 项 fake bind、1 项 Could not start Discord bridge）。尚不能仅凭报错断定底层原因，但没有证据将其归因于汉化。

本轮精简日志见 [`verification-latest.txt`](verification-latest.txt)。完整测试开始后仅新增了 1 项测试，随后单独运行全部 8 项 L10nTests；应用源码没有再次变更，不需重新打包。
