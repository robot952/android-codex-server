# Claude Code 接入与验证

本文保留 `1.8.135+267` 及 `1.8.130` 的历史验收与交付记录，不代表本轮版本切换功能已在真实服务器或设备验收。
当前实现新增 Claude Code 版本配置，可直接升级或降级服务器现有 CLI；本轮自动检查和真实环境验收边界见下文。

## 使用方式

1. 在 Linux 服务器的同一个 SSH 用户下安装并登录 Claude Code 2.1+（2.x），准备 Node.js 18+。
2. App 连接 SSH 后，在会话列表选择 **Claude Code**。可在设置的 **Claude Code 版本** 中刷新稳定版本列表，选择升级或降级；版本按服务器 Profile 独立保存，默认 `2.1.293`，仅接受稳定的 2.1 及更新 2.x 精确版本。
3. 连接时检查 CLI 是否与所选版本精确一致；不一致时，按提示确认修改现有 CLI 并安装连接组件。已有目标版本则跳过 CLI 下载，只补齐或更新 App 自有 bridge。
4. 在 Claude 配置中读取或填写 API URL、Key、默认模型和思考强度；可先测试草稿，再确认保存。
5. 选择工作目录和对话，在模型面板选择 Opus 5.5 等模型及该模型支持的思考强度；回复、工具授权、提问、图片和停止复用现有界面。

版本切换直接作用于当前 SSH 用户正在使用的 Claude CLI：先采用 PATH 中的 `claude`，再查找
`~/.local/bin/claude`、`~/.npm-global/bin/claude`、`~/.npm/bin/claude`、nvm 和 Claude 原生安装目录。
检测为 npm 全局安装时，沿用该 npm 全局路径安装固定版本，避免迁移到另一份原生 CLI；
其他安装调用现有 CLI 的原生安装器，必要时仅对用户目录的原生安装使用官方安装脚本回退。
不使用 sudo；缺少写入权限或安装后的原 CLI 路径与目标版本不符时，停止连接组件替换并报告失败。
App 启动 Claude 会话时禁用自动更新，以尊重所选版本。

探测使用 SSH 的非登录 `sh -s`，不会读取用户的 `.bashrc` 或 nvm 初始化脚本。若交互终端能运行
`claude` 而 App 提示“当前 SSH 用户未找到 Claude Code CLI”，应把 CLI 和 Node 18+ 放进上述用户目录或
该 SSH 用户的非交互 `PATH`，然后重新连接。该提示只表示 CLI 路径不可见；登录状态会在 bridge 连接和设置
读取阶段单独验证。切换服务器或 Agent 时会清除旧 lane 的错误提示，避免把前一台服务器的探测失败显示在当前页面。

版本安装与连接组件安装保留服务器 `~/.claude` 登录、设置和历史；只有用户在配置页确认保存时，才原子更新
当前 SSH 用户的 `~/.claude/settings.json` 中相关字段，空 Key 保持原有认证。会话级模型/effort 覆盖不会
改写服务器默认值。设置页的“上下文大小”同时写 `CLAUDE_CODE_AUTO_COMPACT_WINDOW`（真正决定自动压缩
时机）和 `CLAUDE_CODE_MAX_CONTEXT_TOKENS`，取值限制在 CLI 接受的 `100000–1000000`；只写后者时 CLI
仍按模型 auto 窗口判断压缩，用户填了数值也不会在预期阈值触发。读取时优先回显自动压缩窗口，老配置只有
`MAX_CONTEXT_TOKENS` 时退回读它。上下文占用使用 CLI 返回的真实用量，未知窗口不显示伪百分比，自定义模型容量只作独立参考，不用于重算占用圆环。历史列表仅包含 App 创建的 Claude 对话，不导入既有 CLI 对话。
Windows 原生 Host 暂不支持；Android 本机 Linux 走回环 SSH，但 ARM64 PRoot 运行需真机验证。

## 后台子代理与等待状态

Claude Code 的 `Task` 默认按后台任务启动。父回合收到异步启动结果后可以结束或被用户停止，App 会在原父
回合留下“等待后台智能体完成”的活动行，并在后台智能体面板中继续显示等待数量；这段等待不是 AI
停止，也不会取消后台任务。桥接层保留同一 Claude CLI 会话，下一条用户消息直接复用该会话，避免同一
原生会话被两个 `--resume` 进程并行占用。

完成通知按 Claude CLI 的 `system/task_started`、`system/task_updated` 和
`system/task_notification` 帧归并；旧版网关发来的直接帧以及下一轮请求中注入的
`<task-notification>` 文本也兼容。终端通知会把后台结果写回启动它的原父回合，关闭开始/等待活动行，
并更新子代理会话；如果用户已经发送下一条消息，完成事件仍按原父回合归档，不会误归到新回合。

后台行为的受控回归应覆盖父回合正常完成、用户停止、下一回合复用同一 CLI 进程、迟到完成通知、重复
等待行和子代理页面终态。受控 fixture 只能验证协议与状态归并；真实服务器仍需单独确认长时后台任务、
网络断开重连和 Claude 版本差异。

## 附件消息去重修复

发送带图片和 Debug 日志时，App 会先显示本地乐观消息，服务器随后回显图片路径并把文本日志改成内联
文本。两种回显的附件路径不同，旧逻辑会把同一条消息拆成两个用户气泡。现在文本附件按文件名匹配，图片
仍按远程路径匹配；远程路径相同的二进制附件即使 MIME 被服务器归一化也继续视为同一附件。这样保留了
同名但不同图片上传的区分，同时消除了截图中的重复消息。

## 验证分层

| 层级 | 入口 | 验证内容 |
| --- | --- | --- |
| 安装与 adapter | `test/agent/claude_code_agent_client_test.dart` | 探测、版本/Node 前提、校验、安装失败保留旧版、卸载保留数据、真实 sh/Node、JSONL 接入和环境隔离 |
| 协议与异常 | `scripts/test-claude-code-bridge.cjs` | CLI control 握手、流式去重、工具/提问、停止、后台子代理等待/通知与同进程续聊、输入限额、历史分页与重启、无效记录 |
| 配置 | `scripts/test-claude-code-settings.cjs` | 原生设置读取/保存、空 Key 保留、代理及上下文上限只读、草稿 API 测试和错误脱敏 |
| 官方 CLI | `scripts/test-claude-code-cli.cjs` | 已安装 Claude 2.1.150，与隔离 localhost Anthropic SSE fixture 联调；真实 Write 允许/拒绝、图片、停止、EOF、历史及 CLI resume |
| 共享 UI/状态 | `test/ui/thread_list_and_lifecycle_test.dart`、`test/ui/claude_code_workflow_test.dart` 及 Flutter 全量门禁 | 三 Agent 切换、窄屏/大字体、安装进度；Claude 工作流使用生产 adapter/controller/WorkScreen 和受控 JSONL 对端，覆盖 capability 菜单、发送/流式回复、批准/拒绝、停止、重开及跨 Agent 历史隔离 |
| Android 交互 | `integration_test/claude_code_workflow_test.dart` | 在设备上复用 Claude UI 工作流，覆盖实际 IME 下发送、审批、停止和切换/重开；协议对端仍为受控 fixture，设备执行结果单独记录 |
| Android 交付 | `scripts/dev-workflow.sh publish --reuse` | analyze、完整 Flutter 测试、Debug/Release、稳定签名、原生库、保留数据安装启动、内外网下载哈希 |
| 真实服务器/模型 | 用户实际 SSH 服务器与 Claude Provider | 单独验证登录、真实模型响应、工具权限、长时回合、网络恢复和后台行为，不能以受控 fixture 代替 |

版本切换自动回归覆盖精确版本与 Node 前提、已有目标版本跳过安装、PATH 与旧 home 副本选择、
原生精确降级、npm 原路径升级且不迁移、安装结果不符时保留旧 bridge，以及登录配置保留。
这些受控安装夹具不等于真实服务器的 CLI 下载、升级/降级或权限验收；仍需分别验证真实 npm/原生安装、
升级与降级、已有登录配置和实际模型回合。

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
