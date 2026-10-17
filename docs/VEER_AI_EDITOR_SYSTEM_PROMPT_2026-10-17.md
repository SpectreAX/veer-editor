# Veer AI Editor 系统提示（由 OpenClash 提示改写）

日期：2026-10-17  
代码：[`native/macos-editor/Sources/VeerCore/SystemPrompt.swift`](../native/macos-editor/Sources/VeerCore/SystemPrompt.swift)  
测试：[`SystemPromptTests.swift`](../native/macos-editor/Tests/VeerCoreTests/SystemPromptTests.swift)

来源是一份给 OpenClash 覆写脚本用的提示（生成 `ruby_merge_hash` 规则集定义 + 自定义规则，分两处粘贴）。Veer 是跨平台 Mihomo 客户端，自己修改配置，所以只保留它的规则集知识和安全纪律，换掉输出方式。

## 怎么改写的

| OpenClash 提示 | Veer 系统提示 | 原因 |
|---|---|---|
| 输出两个代码块：`ruby_merge_hash` 覆写脚本 + `- RULE-SET,…` 自定义规则 | 只输出一个 JSON 计划（`rule_set` / `route` / `remove_rule`）或一个澄清问题 | Veer 用确定性代码生成 rule-provider 与 RULE-SET 规则，名称一致、插入位置、去重都由代码保证 |
| 模型自己写 type / behavior / format / url / path / interval | 模型只给 `source` + `name`；Veer 构建地址并按来源填写 format、behavior、`./rule_provider/` 路径（扩展名与 format 对应）和 `interval: 86400` | 模型无法注入任意地址，也不会写错扩展名 |
| 用户粘贴地址时按扩展名、目录推断 format 与 behavior | 同样的推断规则写进提示；Veer 的 `RuleSetCatalog.fromURL` 再独立推断一次，只接受 raw.githubusercontent.com / cdn.jsdelivr.net 的 HTTPS 文件 | 规则保留，执行交给代码 |
| `mrs` 只支持 domain / ipcidr | 保留，并由代码拒绝 mrs + classical | 同左 |
| 本地自建规则集（`type: file`）+ 输出文件内容 | 用户给出的域名 / IP 逐条写成 DOMAIN-SUFFIX / IP-CIDR 规则，超过 32 项分批 | Veer 导出单个完整配置，不附带额外文件 |
| 策略组名必须与配置一字不差，让用户去“配置管理”复制 | 模型只能用匿名出口的 `targetId`；缺出口时提示“输入 @ 选择策略组或节点” | 名称由 Veer 映射，AI 看不到真实出口名 |
| REJECT / DIRECT 不需要用户提供 | 保留 | — |
| 地址不确定时不要编造，给出三个仓库的查找步骤 | 保留，查找步骤改为 Veer 文案（`SystemPrompt.findRuleSetHelp`），404 报错时也复用 | — |
| 能联网就验证地址返回 200，否则提醒用户手动检查 | Veer 在展示前对每个新地址发 HEAD：404 拒绝整个计划，网络失败标记“未验证” | 验证由应用完成，不依赖模型是否联网 |
| 必须先读 OpenClash 用户指南 | 删除 | 与 OpenWrt / LuCI 相关，不适用于 Veer |

## 改正的事实错误

原提示把 ACL4SSR 的 Google、YouTube、OpenAi 写成 `Clash/{名称}.list`。2026-10-17 实测这三个地址返回 404，正确位置是 `Clash/Ruleset/{名称}.list`。Netflix、Telegram 在两处都存在。Veer 提示要求 `acl4ssr` 的这几个名称带 `Ruleset/` 前缀。

提示里列出的所有规则集名称（MetaCubeX geosite 22 个、geoip 8 个、ACL4SSR 14 个、blackmatrix7 12 个）都通过了 HEAD 检查。可以用 `VEER_NETWORK_TESTS=1 swift test --filter RealRuleSetCatalogTests` 复查。

## 原提示的示例在 Veer 中的表现

“我想让 YouTube 走代理”：

1. 没有指定出口，模型应返回澄清：“请告诉我这些流量走哪个出口。可以在输入框输入 @ 选择策略组或节点；直连和拦截不需要选择。”界面同时给出策略组快捷回复。
2. 用户选择出口（例如 @美国出口）后，计划是 `{"kind":"rule_set","source":"metacubex-geosite","name":"youtube","targetId":…}`。
3. Veer 生成：

```yaml
rule-providers:
  youtube:
    type: http
    behavior: domain
    format: mrs
    url: https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/meta/geo/geosite/youtube.mrs
    path: ./rule_provider/youtube.mrs
    interval: 86400
rules:
  - RULE-SET,youtube,美国出口
  # …原有规则
```

在写入草稿前，这些内容会作为待审阅修改展示，附带差异和 Mihomo 校验结果。

## 透明度

每轮 AI 请求的“查看发送给 AI 的内容”里新增了可展开的“系统说明”，显示这一轮实际发送的完整系统提示（只含匿名出口）。

## 未验证

没有用真实 AI 服务测试模型是否遵守这份提示。测试只覆盖：提示内容与隐私、提示中的示例能被 Veer 解码并应用、模拟模型回复的端到端流程，以及规则集名称是否真实存在。
