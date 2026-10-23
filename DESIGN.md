---
name: Veer AI Editor
description: 用一句话修改 Mihomo 分流规则的原生 macOS 编辑器：安静、精确，状态一眼可读，绿色只留给下一步。
colors:
  veer-green: "#1F9E54"
  veer-green-dark: "#3DCC80"
  bubble-wash: "#E0F2E6"
  bubble-wash-dark: "#294533"
  selection-graphite: "#636366"
  selection-graphite-dark: "#66666B"
  status-warning: "#FF9500"
  status-failure: "#FF3B30"
  status-info: "#007AFF"
  window-surface: "#ECECEC"
  raised-surface: "#FFFFFF"
  raised-surface-dark: "#1E1E1E"
  hairline: "#0000001A"
  ink: "#000000D9"
  ink-secondary: "#00000080"
typography:
  display:
    fontFamily: "SF Pro (system), PingFang SC"
    fontSize: "17px"
    fontWeight: 600
  headline:
    fontFamily: "SF Pro (system), PingFang SC"
    fontSize: "15px"
    fontWeight: 600
  title:
    fontFamily: "SF Pro (system), PingFang SC"
    fontSize: "13px"
    fontWeight: 700
  body:
    fontFamily: "SF Pro (system), PingFang SC"
    fontSize: "13px"
    fontWeight: 400
  label:
    fontFamily: "SF Pro (system), PingFang SC"
    fontSize: "12px"
    fontWeight: 400
  caption:
    fontFamily: "SF Pro (system), PingFang SC"
    fontSize: "10px"
    fontWeight: 400
  code:
    fontFamily: "SF Mono (system monospaced)"
    fontSize: "12px"
    fontWeight: 400
rounded:
  tiny: "4px"
  small: "6px"
  medium: "10px"
  large: "16px"
  pill: "9999px"
spacing:
  xxs: "2px"
  xs: "4px"
  sm: "8px"
  md: "12px"
  lg: "16px"
  xl: "24px"
  xxl: "32px"
  xxxl: "48px"
components:
  button-primary:
    backgroundColor: "{colors.veer-green}"
    textColor: "#FFFFFF"
    rounded: "{rounded.pill}"
  pill-button:
    backgroundColor: "#0000000F"
    textColor: "{colors.ink}"
    rounded: "{rounded.pill}"
    padding: "4px 10px"
  pill-button-warning:
    backgroundColor: "#FF950024"
    textColor: "{colors.status-warning}"
    rounded: "{rounded.pill}"
    padding: "4px 10px"
  toggle-chip-on:
    backgroundColor: "#1F9E5424"
    textColor: "{colors.veer-green}"
    rounded: "{rounded.pill}"
    padding: "4px 10px"
  chip:
    backgroundColor: "{colors.raised-surface}"
    textColor: "{colors.ink}"
    rounded: "{rounded.pill}"
    padding: "6px 12px"
  tag:
    backgroundColor: "#0000001F"
    textColor: "{colors.ink-secondary}"
    typography: "{typography.caption}"
    rounded: "{rounded.pill}"
    padding: "2px 6px"
  keycap:
    backgroundColor: "#0000000F"
    textColor: "{colors.ink-secondary}"
    typography: "{typography.caption}"
    rounded: "{rounded.tiny}"
    padding: "1px 4px"
  panel:
    backgroundColor: "{colors.raised-surface}"
    rounded: "{rounded.large}"
    padding: "16px"
  choice-row-hover:
    backgroundColor: "#0000000F"
    rounded: "{rounded.small}"
    padding: "8px 8px"
  segmented-selected:
    backgroundColor: "{colors.selection-graphite}"
    textColor: "#FFFFFF"
---

# Design System: Veer AI Editor

## Overview

**Creative North Star: "The Precision Console"（精密仪表台）**

Veer AI Editor 是一台精密仪表台：用户用一句中文描述分流，界面把它变成可审阅、可校验、可撤销的修改。仪表台的价值在于读数准确、一眼可读，而不是外观华丽。所以界面安静，几乎全是中性的 macOS 系统表面；颜色只在两种地方出现：语义状态（通过、警告、失败，永远配图标和文字），以及当前视图里唯一的下一步操作（Veer 绿色）。

这是一个原生 macOS 应用，不是网页。字体、表面色、分隔线、焦点环、控件都用系统提供的，自动适配浅色和深色、提高对比度、减弱透明度和用户的字号设置。Liquid Glass 只用于浮在内容之上的操作层（输入框、发送按钮、提示条）；内容本身放在实色面板上。

密度偏紧凑：这是长时间使用的工具，信息密度高于营销页面，但组内间距始终小于组间距，状态永远靠文字和图标表达，不只靠颜色。

**Key Characteristics:**
- 一个强调色（Veer 绿），只用于主操作、选中勾、已写入状态和开启的开关。
- 深度靠表面层级和细分隔线，不靠阴影；唯一的阴影属于浮层补全列表。
- 选中和悬停都是“表面提升一级”，不是换成强调色。
- 快捷键显示为键帽，菜单项带数字键帽，提示行用键帽加动作名。
- 所有文字用系统文字样式，跟随系统字号；状态 = 图标 + 文字 + 颜色。
- 对齐 macOS Human Interface Guidelines：系统控件优先，自绘只在系统没有对应控件时。

## Colors

一个品牌绿加系统中性色和系统语义色；几乎所有颜色都是随外观变化的动态色，前置元数据里的十六进制是浅色（和标注的深色）参考值。

### Primary
- **Veer Green**（浅色 `veer-green`，深色 `veer-green-dark`）：主操作（发送、写入草稿）、选中勾、开启状态的开关、“已写入”状态、链接式次要操作的文字。代码里是 `Color.veerAccent`，也是 `statusSuccess`。
- **Bubble Wash**（`bubble-wash` / `bubble-wash-dark`）：用户消息气泡的淡绿底色，文字保持正常墨色，让实心绿只留给主操作。代码里是 `Color.userBubble`。

### Neutral
- **Window Surface**（`window-surface`，系统 `windowBackgroundColor`）：窗口和侧栏底色。
- **Raised Surface**（`raised-surface` / `raised-surface-dark`，系统 `controlBackgroundColor`）：面板、卡片、补全列表、建议标签的底色。代码里是 `Color.surfaceRaised`。
- **Sunken Surface**（系统 `underPageBackgroundColor`）：比窗口更低一级的底，`Color.surfaceSunken`。
- **Hairline**（`hairline`，系统 `separatorColor`）：面板边线、键帽边线、分隔线。代码里是 `Color.separatorLine`。
- **Ink / Ink Secondary**（系统 `labelColor` / `secondaryLabelColor`）：正文与说明文字。说明、提示、键帽文字用二级灰，不用三级灰（对比度不足）。
- **Selection Graphite**（`selection-graphite` / `selection-graphite-dark`）：分段控件的选中段。中性灰，白字保持 4.5:1 以上。代码里是 `Color.selectionNeutral`。
- **Subtle Fill**（`Color.primary` 5–6% 透明度）：思考过程等次要内容的底色，以及中性药丸按钮、键帽的底色。

### Semantic
- **Warning**（`status-warning`，系统橙）：警告、未验证、完整权限模式、缺少 API Key 的小圆点。
- **Failure**（`status-failure`，系统红）：校验失败、删除差异。
- **Info**（`status-info`，系统蓝）：说明性提示。

### Named Rules
**The One Voice Rule.** 一个视图里实心绿只出现在一个主操作上。选择控件、分段控件、次要按钮保持系统原生的中性外观（`neutralControl()`）。

**The Never-Alone Rule.** 颜色从不单独表达状态：`StatusBadge` 总是图标 + 文字；开关开启时同时有底色、边线和文字颜色变化，并标记为“已选中”。

**The System-Color Rule.** 功能页面不写十六进制颜色。新颜色先进入 `Tokens.swift`，并同时给出浅色和深色值。

## Typography

**Body Font:** SF Pro（系统字体），中文回退为苹方
**Mono Font:** SF Mono（系统等宽），用于规则、域名、YAML 和 IP

**Character:** 完全使用 macOS 文字样式，不手写字号。层级靠字号台阶和 600 字重，不靠更粗的字重或彩色文字。

### Hierarchy
- **Display**（600，title2，约 17pt）：每个窗口或空状态的唯一大标题，如“想怎么分流？”“确认出口”，以及概览里的关键数字。
- **Headline**（600，title3，约 15pt）：表单、弹窗和查询页的标题，如“导入配置”“DNS 查询”。
- **Title**（headline，约 13pt 粗体）：卡片标题、状态视图标题、查询结果标题。
- **Body**（400，body，约 13pt）：对话正文、菜单项标题。
- **Label**（400，callout，约 12pt）：控件、建议标签、状态徽章、修改项说明。
- **Caption**（400，caption / caption2，约 10pt）：次要细节、时间、标签、键帽和快捷键提示。
- **Code**（SF Mono，callout / caption）：规则、规则集名、YAML、地址（`Typography.code`、`Typography.codeSmall`）。

### Named Rules
**The Text-Style Rule.** 只用系统文字样式（`.title2`、`.callout`、`.caption` …），不写 `.system(size:)`，这样系统字号设置能生效。

**The Mono-For-Data Rule.** 等宽字体只给代码和数据（规则、域名、IP、YAML），不作为“技术感”装饰。

## Layout

三栏 `NavigationSplitView`：侧栏（会话，约 240pt）、对话、检查器（约 360pt）。对话正文最大阅读宽度 760pt；窗口最小 960×640，默认 1320×860；窗口窄于 1100pt 时进入紧凑布局。

间距是 4pt 网格（`Spacing`：2 / 4 / 8 / 12 / 16 / 24 / 32 / 48）。面板内边距 16，相邻卡片 8–12，区块之间 24，大型状态区 32 以上。组合值（如 `Spacing.sm + Spacing.xxs`）只用于把控件高度对齐到系统控件。

窄窗口时先去掉次要文字，再收起图标以外的内容：输入框底栏先隐藏“请勿粘贴密钥或订阅链接”；新建策略组卡片先截断标签，保留组名。

### Named Rules
**The Grid Rule.** 不出现网格外的间距值；需要新值时先加到 `Spacing`。

## Elevation & Depth

这是一个平的系统：深度来自表面层级（窗口 → 下沉 → 抬升）和 1px 系统分隔线，不来自阴影。Liquid Glass 是唯一的“材质”，只用于浮在内容上的操作层：输入框、发送 / 停止按钮、提示条、工具栏；系统在“减弱透明度”打开时自动改为不透明。

### Shadow Vocabulary
- **Floating list**（12% 黑，模糊半径 12，向下 4）：只用于输入框上方弹出的 @ 补全列表，它真正浮在内容之上。

### Named Rules
**The Ladder-Not-Shadow Rule.** 要让一个元素“高一级”，就换到下一级表面色并加细分隔线，不加阴影。卡片、按钮和文字永远没有阴影。

**The Selection-Is-Lift Rule.** 悬停和选中都表现为表面提升一级：中性按钮悬停时底色从 6% 加深到 10%，按下到 14%；菜单行悬停时出现 6% 底色；分段控件选中段是石墨灰。强调色不是选中的默认表现，只有“开启”类开关和当前项的勾用绿色。

**The Glass-For-Controls Rule.** Glass 只给浮在内容之上的控件，内容区（卡片、面板、修改项）永远是实色表面。

## Shapes

连续圆角（`.continuous`），四级半径：键帽 4、菜单行与小控件 6、补全列表与卡片 10、面板与气泡 16；所有药丸形控件（输入框底栏按钮、建议标签、开关、提示条、标签）用胶囊形。同一类组件只用一种半径。

边线只有一种：1px 系统分隔线（面板边线降到 60% 透明度）。开启的开关有 40% 强调色描边。没有彩色粗边、左侧色条或渐变边框。

## Components

### Buttons
- **Primary**（`primaryAction()`）：系统 `.glassProminent`，Veer 绿，大号控件。每个视图一个，如“写入草稿”、发送。
- **Pill button**（`PillButtonStyle`）：输入框底栏的图标按钮（执行模式、解析方式、模型）。中性 6% 底色胶囊；悬停 +4%，按下 +8%，Motion.quick 过渡。完整权限模式改为橙色 14% 底色和橙色图标。
- **Secondary**：系统 `.bordered` 或无边框按钮，保持原生外观；链接式操作（撤销、查看差异、设置…）用 `.link` 加 Veer 绿文字。

### Chips
- **Chip**（建议指令）：抬升表面底色，25–35% 强调色细边，悬停时 12% 绿色底；不可用时 60% 透明度。
- **ToggleChip**（联网搜索等开关）：关闭时与旁边的药丸按钮一致；开启时绿色 14% 底、40% 绿色描边、绿色文字，并标记为已选中。可只显示图标，标题作为读屏标签和悬停提示。
- **Tag**（策略组、新增、宽泛）：caption2 中等字重，12% 同色底的胶囊。

### Cards / Containers
- **Panel**（`.panel()`）：抬升表面、16 圆角、60% 分隔线描边、16 内边距，无阴影。
- **修改项卡片**：标题行（图标、名称、类型标签、编辑、勾选框）加一行说明；名称优先保留宽度。
- **StateView**：空状态、错误、说明的统一视图：tertiary 大图标、Title、说明和一个 `.bordered` 操作，最大宽度 320。

### Inputs / Fields
- **Composer**：多行 `NSTextView`，Glass 胶囊容器（20 圆角），占位文字用三级灰；底栏是药丸按钮和发送按钮；下方是快捷键提示行。
- **表单字段**：系统 `TextField` / `SecureField`，标签在字段上方，错误紧贴字段显示，不只用边框颜色表示。

### Navigation
- **SegmentedControl**：系统分段控件，选中段为石墨灰（不是绿色），可以只显示图标（附提示和读屏标签）。
- **侧栏**：系统 `List` 选中样式，会话标题加一行“来源 · 时间”。
- **工具栏**：系统工具栏图标按钮，常驻；暂不可用时禁用并在悬停提示里说明原因。

### Menus
- **ChoiceRow**：菜单里的一种选择：图标、标题、说明、当前项的绿色勾、右侧数字键帽；菜单打开时按数字键直接选择。悬停时 6% 底色、6 圆角。

### KeyCap（signature）
- **KeyCap**：一个按键或组合（↩、⇧↩、@、1）显示为键帽：caption2 中等字重、二级灰文字、6% 底色、1px 分隔线描边、4 圆角，最小宽度 16。没有渐变和阴影；对读屏隐藏，由所属控件的标签说明。
- **ShortcutHint**：键帽 + 动作名，用于输入框下方的提示行（↩ 发送、⇧↩ 换行、@ 选择出口、/ 命令），整体作为一个读屏元素。

### Status
- **StatusBadge**：系统 SF Symbol 实心图标（对勾圆、三角感叹号、八角叉、信息圆、虚线圆）加文字；紧凑版用 caption 和二级灰文字。
- **Toast**：Glass 胶囊，绿色对勾 + 消息 + 可选“撤销”。

## Do's and Don'ts

### Do:
- **Do** 用系统颜色、系统文字样式和系统控件；自绘组件放进 `DesignSystem/`，功能页面只组合它们。
- **Do** 每个视图只放一个实心绿色主操作（One Voice Rule）。
- **Do** 用表面层级和 1px 分隔线表达深度；悬停和选中都是表面提升一级（Selection-Is-Lift Rule）。
- **Do** 把快捷键显示为 `KeyCap`，菜单选项带数字键帽并支持数字键选择。
- **Do** 状态同时用图标、文字和颜色表达；仅图标的按钮必须有悬停提示和读屏标签。
- **Do** 每次改界面都检查浅色、深色、窄窗口和长名称（中文和英文），并更新 `artifacts/` 截图。
- **Do** 说明、提示和键帽文字用二级灰，保证 4.5:1 对比度。

### Don't:
- **Don't** 给卡片、按钮或文字加阴影；唯一的阴影属于浮层补全列表。
- **Don't** 在内容区使用 Glass，或把 Glass 当装饰。
- **Don't** 使用渐变（包括键帽），也不使用发光、多层阴影或彩色粗边。
- **Don't** 引入第二个品牌强调色，或把绿色用于导航和分段控件的选中状态。
- **Don't** 在功能页面写十六进制颜色、网格外的间距或 `.system(size:)` 字号。
- **Don't** 用三级灰写需要阅读的文字（说明、警告、提示）。
- **Don't** 用 emoji 或 Unicode 符号代替图标；图标来自 SF Symbols，同一层级使用同一种填充风格。
