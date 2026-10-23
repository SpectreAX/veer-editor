# AI 解析回归测试集

`Tests/VeerCoreTests/AIEvalTests.swift` 把约 40 条真实指令（来自 2026-10-19 测试报告的 45 种说法，以及之后发现的问题，如“所有 .jp 域名走日本”“日本航空相关域名走直连”、地区排除、多地区新策略组、删除规则）发给真实的 AI 服务，用示例配置检查结果。

**会产生费用**：每条指令至少 1 次请求，回答无法使用时自动重试 1 次。平常的 `swift test` 会跳过它，只有设置 `VEER_AI_EVAL=1` 时才运行。

## 运行

Key 不会写进仓库：优先使用 `VEER_AI_KEY`，没有时读取 Veer 在本机保存的该服务的 Key（设置 → AI 中保存的那个）。

```bash
VEER_AI_EVAL=1 DEVELOPER_DIR=/Library/Developer/CommandLineTools swift test --sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk --filter AIEvalTests
```

可选环境变量：

| 变量 | 作用 | 默认 |
|---|---|---|
| `VEER_AI_PROVIDER` | 服务（`AIProvider` 的值，如 `deepSeek`、`openAI`、`zhipu`） | `deepSeek` |
| `VEER_AI_MODEL` | 模型 | 该服务的默认模型 |
| `VEER_AI_THINKING` | 深度思考：`off`、`low`、`medium`、`high`、`max` | `off` |
| `VEER_AI_BASE_URL` | 服务地址 | 该服务的默认地址 |
| `VEER_AI_KEY` | API Key | 本机保存的 Key |
| `VEER_AI_EVAL_FILTER` | 只运行指令中包含这段文字的条目；用 `\|` 分隔多段，如 `走日本\|google 的规则` | 全部 |
| `VEER_AI_EVAL_PARALLEL` | 同时发出的请求数 | 4 |
| `VEER_AI_EVAL_SEARCH` | 允许 AI 联网搜索，值为搜索服务（`wikidata`、`catalogOnly`、`deepSeek`） | 关闭 |
| `VEER_AI_EVAL_GEODATA` | 含 `geosite.dat` 等文件的文件夹，启用本机查询 | 关闭 |
| `VEER_MIHOMO_BIN` | Mihomo 可执行文件，用于校验生成的配置 | 不校验 |
| `VEER_AI_EVAL_MIN` | 通过率低于这个百分比时测试失败 | 只报告 |

## 结果

每条指令完成时打印一行（✓/✗、耗时、请求次数），最后打印通过率、总请求次数和服务报告的 token 数，并列出每条失败：期望什么、缺了什么、模型实际给出的计划或回答，以及模型写的 understanding（用来区分是提示的问题还是解码的问题）。

期望写得比较宽松：
- 服务可以用规则集（RULE-SET 或 GEOSITE）或它的域名命中。
- 出口按地区判断：该地区的任何策略组或节点都算；新建策略组时检查它覆盖的地区和排除的地区。
- 有些指令接受两种结果，例如“192.168.1.1 直连”可以写规则，也可以说明已有规则覆盖。
- `choices`：必须是带 2 个以上可执行方案（有 prompt）的追问，只有出口按钮不算。
- `diagnosed(…)`：模型必须先请求本机检查域名，再给出后面的结果。

新增用例：在 `AIEvalTests.cases` 里加一行 `Case`，写清指令和期望。
