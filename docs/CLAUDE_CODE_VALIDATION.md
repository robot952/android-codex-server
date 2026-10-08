# Claude Code 接入与验证

当前目标版本：`1.8.135+267`。下方 `1.8.130` 的设备和发布记录是前一版本历史记录。

## 使用方式

1. 在 Linux 服务器的同一个 SSH 用户下安装并登录 Claude Code 2.1+（2.x），准备 Node.js 18+。
2. App 连接 SSH 后，在会话列表选择 **Claude Code**，按提示安装连接组件。
3. 在 Claude 配置中读取或填写 API URL、Key、默认模型和思考强度；可先测试草稿，再确认保存。
4. 选择工作目录和对话，在模型面板选择 Opus 5.5 等模型及该模型支持的思考强度；回复、工具授权、提问、图片和停止复用现有界面。

连接组件不下载或升级 Claude CLI，不修改登录或原生模型配置；只有用户在设置页确认保存时，才原子更新
当前 SSH 用户的 `~/.claude/settings.json` 中相关字段，空 Key 保持原有认证。会话级模型/effort 覆盖不会
改写服务器默认值。设置页的“上下文大小”同时写 `CLAUDE_CODE_AUTO_COMPACT_WINDOW`（真正决定自动压缩
时机）和 `CLAUDE_CODE_MAX_CONTEXT_TOKENS`，取值限制在 CLI 接受的 `100000–1000000`；只写后者时 CLI
仍按模型 auto 窗口判断压缩，用户填了数值也不会在预期阈值触发。读取时优先回显自动压缩窗口，老配置只有
`MAX_CONTEXT_TOKENS` 时退回读它。上下文占用使用 CLI 返回的真实用量，未知窗口不显示伪百分比，自定义模型容量只作独立参考，不用于重算占用圆环。历史列表仅包含 App 创建的 Claude 对话，不导入既有 CLI 对话。
Windows 原生 Host 暂不支持；Android 本机 Linux 走回环 SSH，但 ARM64 PRoot 运行需真机验证。

## 验证分层

| 层级 | 入口 | 验证内容 |
| --- | --- | --- |
| 安装与 adapter | `test/agent/claude_code_agent_client_test.dart` | 探测、版本/Node 前提、校验、安装失败保留旧版、卸载保留数据、真实 sh/Node、JSONL 接入和环境隔离 |
| 协议与异常 | `scripts/test-claude-code-bridge.cjs` | CLI control 握手、流式去重、工具/提问、停止、输入限额、历史分页与重启、无效记录 |
| 配置 | `scripts/test-claude-code-settings.cjs` | 原生设置读取/保存、空 Key 保留、代理及上下文上限只读、草稿 API 测试和错误脱敏 |
| 官方 CLI | `scripts/test-claude-code-cli.cjs` | 已安装 Claude 2.1.150，与隔离 localhost Anthropic SSE fixture 联调；真实 Write 允许/拒绝、图片、停止、EOF、历史及 CLI resume |
| 共享 UI/状态 | `test/ui/thread_list_and_lifecycle_test.dart`、`test/ui/claude_code_workflow_test.dart` 及 Flutter 全量门禁 | 三 Agent 切换、窄屏/大字体、安装进度；Claude 工作流使用生产 adapter/controller/WorkScreen 和受控 JSONL 对端，覆盖 capability 菜单、发送/流式回复、批准/拒绝、停止、重开及跨 Agent 历史隔离 |
| Android 交互 | `integration_test/claude_code_workflow_test.dart` | 在设备上复用 Claude UI 工作流，覆盖实际 IME 下发送、审批、停止和切换/重开；协议对端仍为受控 fixture，设备执行结果单独记录 |
| Android 交付 | `scripts/dev-workflow.sh publish --reuse` | analyze、完整 Flutter 测试、Debug/Release、稳定签名、原生库、保留数据安装启动、内外网下载哈希 |
| 真实服务器/模型 | 用户实际 SSH 服务器与 Claude Provider | 单独验证登录、真实模型响应、工具权限、长时回合、网络恢复和后台行为，不能以受控 fixture 代替 |

经用户授权可单独运行 `node scripts/test-claude-code-live.cjs --live`：隔离配置与工作区、禁用工具/MCP/技能、
最多两轮真实付费请求，检查指定模型和 effort、桥接重启续聊、实际 usage 与上下文窗口。不会升级 CLI、
覆盖服务器设置或自动纳入发布门禁。真实服务器的其他模型、真机操作和长时网络恢复仍须分别验收。

CLI 测试将 HOME 和认证配置指向一次性临时目录，模型响应来自本地受控服务器；不调用真实付费模型。
UI Widget 测试和 Android integration test 复用受控 JSONL 对端，不启动真实 Claude CLI；设备通过状态以
该入口的实际执行记录为准，不能从 Widget 测试或模拟器启动检查推定。
模拟器启动和受控交互检查不等于用户服务器认证、真实供应商 API、ARM64 本机 Linux 或厂商后台长时验收。
本轮不支持的操作通过 capability 隐藏，不伪造上下文用量。

## 重复回复修复与 1.8.135 交付（2026-10-06）

CLI 会按内容块分别发送 assistant 快照，重放快照可能丢弃前导 thinking 块，同一段文本的内容下标随之
位移；此前仅按内容下标查找已流式的条目，位移后命不中，同一回答被写成两个 agentMessage 条目，App 中
显示两次。现在先按文本与该消息已发出的条目比对，命中即复用原条目 ID，下标只作首选依据。

- `scripts/test-claude-code-bridge.cjs` 增至 26 个场景，新增场景复现上述位移序列；该场景在修复前
  的提交上稳定失败（回答被列出两次），修复后通过。真实 CLI 2.1.150 与本地 Anthropic fixture 联调、
  Claude 设置测试同样通过。
- `./scripts/dev-workflow.sh publish` 全绿，主门禁耗时 `389.338s`；Release APK 在 Android 14
  `emulator-5554` 冒烟通过，模拟器截图 `.workflow-cache/emulator/latest-release.png`。
- 产物 `dist/Agent-1.8.135.apk`，大小 `31,671,302` 字节，`versionName=1.8.135`、
  `versionCode=267`，稳定签名证书 SHA-256 仍为
  `72722218709a6d7fd0e80b944903ae2961b4cfa8abe03586f602acdc1ea0f52a`。
- 内网 `http://192.168.8.107/codex.apk` 整包直下与外网 `http://frp.asdb.top:18080/codex.apk`
  有界 Range 分段回取均通过大小与 SHA-256 校验；APK SHA-256 为
  `07d88ccde0e8e9e292c98df582e636b71958118d85be7653cbb769f5087a2b4c`。

## Opus 5.5 增量验证（2026-10-06）

- Claude bridge 精确发送 `claude-opus-5-5` 与 per-turn `medium` effort，默认模型和思考强度仍可从服务器读取；
  模型目录包含 Opus 5.5，任意已配置的自定义 wire ID 仍可保留。
- 18 个 bridge 协议场景、真实 CLI + 本地 Anthropic fixture、Claude 设置测试通过；控制器模型/effort
  定向回归通过，UI、全量 Flutter、Android 发布门禁结果以本轮最终执行记录为准。
- 授权服务器上完成两轮真实 Opus 5.5 请求，分别约 11.76 秒和 4.14 秒；两轮间重启 bridge，续聊及
  tokenUsage 持久化正常。服务端这次报告实际窗口 200000 tokens，不能推广到其他模型或网关配置。

## 上版设备记录（1.8.130，2026-10-06）

`integration_test/claude_code_workflow_test.dart` 已在 Android 14 `emulator-5554` 通过，验证真实 IME
下发送、工具批准与拒绝、停止、历史重开和跨 Agent lane 隔离。测试使用生产 adapter/controller/WorkScreen
与受控 JSONL 对端，不调用 Claude CLI 或真实模型。构建耗时 `52.5s`，设备执行耗时 `28s`。
随后已覆盖安装正常 Release APK，保留应用数据并通过启动检查；截图为 `1220x2712`，已核对首页
`Agent` 标题、紧凑推广框和 `v1.8.130` 版本显示。

## 上版自动门禁（1.8.130）

- Claude 协议 `16` 个场景、真实 CLI `2.1.150` 与本地 Anthropic fixture 联调通过。
- Claude/控制器/模型/通知/UI 定向 `141` 项回归通过；全量 Flutter `738` 项及 analyze 通过。
- Debug/Release 构建、稳定签名和 APK 原生运行库检查通过；APK 内 Claude bridge 与已测试源码
  的 SHA-256 相同。没有替换签名文件、清理应用数据或触发云端发布。
- 工作流脚本自测通过；原服务器脚本和 OpenCode 门禁复用各自内容指纹缓存。

| 阶段 | 实测耗时 |
| --- | --- |
| 工作流脚本自测 | 6.010 秒 |
| Claude 定向回归 | 12.540 秒 |
| Android 设备回归（含构建、安装及执行） | 87.290 秒 |
| 发布内 Claude 协议及真实 CLI 联调 | 4.808 秒 |
| Flutter 依赖解析 | 1.635 秒 |
| Flutter analyze | 6.195 秒 |
| 全量 Flutter 测试 | 73.262 秒 |
| Debug 编译 | 24.368 秒 |
| Release 编译 | 148.525 秒 |
| 正常 Release 安装启动检查 | 25.919 秒 |
| 本机发布、验签与内外网下载回验 | 291.761 秒 |
| publish 主门禁总计（包含上述门禁子阶段） | 598.543 秒 |

正式产物 `dist/Agent-1.8.130.apk`，大小 `31,637,639` 字节。内网整包直下、外网有界 Range
分段取回后均通过完整大小、SHA-256、包名、版本与证书校验；外网下载实际耗时 `262.421s`。
APK SHA-256：`d906efaef757d0026ab9d64e4644007fab67a4ec8257169983809c9ba3bd4cf6`。
稳定证书 SHA-256：`72722218709a6d7fd0e80b944903ae2961b4cfa8abe03586f602acdc1ea0f52a`。
内网地址为 `http://192.168.8.107/codex.apk`，外网地址为 `http://frp.asdb.top:18080/codex.apk`。

早期定向用例有失败返工，后续完成修正并由上述定向及完整门禁复验，失败记录保留。
任务总时长以及长时间打开的人工阶段包含中断、等待和文档核对，不能当作净编码或 CLI 执行耗时；
自动门禁与设备用例的独立计时用于衡量实际执行速度。

阶段实测耗时记录在 `.workflow-cache/task-timings/.active/claude-code-20261006.tsv`，任务完成后归档为
`.workflow-cache/task-timings/claude-code-20261006.tsv`；工作流分段在
`.workflow-cache/latest-workflow-timing.tsv`；重试保留原失败记录，最终产物以
`dist/local-release-metadata.txt` 为准。
