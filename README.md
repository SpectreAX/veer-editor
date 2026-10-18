# Veer AI Editor（macOS 原生重建）

用一句话修改 Mihomo 分流规则，每一处改动先审阅，再决定是否写入草稿，最后导出完整配置副本。

- 规格：[`docs/VEER_AI_EDITOR_SPEC_2026-10-17.md`](../../docs/VEER_AI_EDITOR_SPEC_2026-10-17.md)
- UI 蓝图：Open Design 项目 `veer-ai-editor-rebuild-20261017`，副本在 [`prototype/editor-rebuild/`](../../prototype/editor-rebuild/)
- 与旧版 `native/macos` 的区别：一个进程、纯 Swift。没有 Node 运行时，不监听任何端口；唯一的外部可执行文件是内置的 Mihomo 校验器（`mihomo -t`）。

## 构建与运行

需要 macOS 26+ 与 Swift 6.2+（Command Line Tools 即可）。

```bash
zsh scripts/build-app.sh
```

```bash
open "dist/Veer AI Editor.app"
```

脚本默认使用 `MacOSX26.5.sdk`：macOS 27 SDK 把 SwiftUI 的 `@State` 改成了宏，宏插件只随完整 Xcode 提供，只装 Command Line Tools 时无法编译。装有 Xcode 时可用 `SDKROOT=… zsh scripts/build-app.sh` 覆盖。

校验器默认取 `prototype/ai-editor/.cache/mihomo`（由 `go_core/third_party/mihomo` 构建的 Veer mirror），可用 `VEER_MIHOMO_BIN` 指定。

## 测试

```bash
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk swift test
```

用真实 Mihomo 二进制跑内核校验测试：

```bash
VEER_MIHOMO_BIN="$PWD/../../prototype/ai-editor/.cache/mihomo" SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk swift test --filter RealValidatorTests
```

## 截图验证

应用自带开发用的截图脚本：在隔离的内存会话里走完主流程与关键状态，浅色、深色各一遍，然后退出。不读取、不改动你的真实会话。

```bash
open -n --env VEER_SNAPSHOT_DIR="$PWD/artifacts/snapshots-tmp" "dist/Veer AI Editor.app"
```

用 `open` 启动是为了让窗口处于激活状态（从 shell 直接运行时窗口不是 key window，强调色会显示为灰色）。本轮截图见 `artifacts/2026-10-17/`。

## 结构

```text
Sources/VeerCore/        纯逻辑，可单测
  ConfigDocument         解析、出口提取、结构检查
  EditPlan / PlanApplier 计划格式 v1；只改 rules 与新增 rule-providers，源码区间拼接并复核
  RuleSetCatalog         规则集来源、URL 构建、复用、HEAD 验证
  LocalIntentParser      不用 AI 时的本地解析
  Anonymizer / AIClient  匿名出口表；OpenAI 兼容客户端
  LineDiff / RuleMatcher patience 行差异；域名首条命中
  Validator              mihomo -t（临时目录、超时、输出脱敏）
  Session / Storage      会话、API Key 文件、订阅下载
Sources/VeerEditorApp/   SwiftUI 应用
  Model/EditorStore      状态机：生成、逐项接受、写入、撤销/重做、导出
  DesignSystem/          Token（4pt 间距、圆角、颜色）与通用组件
  Features/              开始页、出口确认、对话、输入框、检查器、设置
```
