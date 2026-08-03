# Codex Remote Android 架构与协作手册

本文是本仓库的架构、修改、测试和发布主文档，面向后续维护者和 AI 编码代理。README 介绍
产品和安装方式；本文回答“代码在哪里、状态如何流动、改动会影响什么、必须怎样验证”。

文档基线：

- Android 应用版本：1.7.52（versionCode 74）
- 固定 Codex CLI：0.146.0
- 固定 Node.js：22.17.0
- Android：minSdk 26、targetSdk/compileSdk 34
- 主要技术：Kotlin、Jetpack Compose、Coroutines/Flow、JSch、kotlinx.serialization
- 最后核对日期：2026-08-02

版本会变化。发布前必须以 app/build.gradle.kts、protocol/codex-version.txt 和
protocol/node-version.txt 为准，不要只相信本文顶部的快照。

## 1. AI 五分钟入口

1. 确认当前目录是 /home/yan/ygy/codex-remote-android。
2. 查看 git status，保留所有不属于当前任务的修改和未跟踪文件。
3. 仓库有 .codegraph/，理解源码前先运行：

   ~~~bash
   /root/.local/bin/codegraph explore "描述问题，并写出相关文件或符号"
   ~~~

   当前 shell 可能没有把 /root/.local/bin 加入 PATH，因此绝对路径最可靠。
4. 先看本文的“目录与职责”“核心数据流”“修改影响图”和“回归矩阵”，再动代码。
5. 手工编辑使用 apply_patch；不要顺手重构无关模块，不要运行 clean。
6. 最小验证通常是：

   ~~~bash
   ANDROID_HOME=/tmp/android-sdk ANDROID_SDK_ROOT=/tmp/android-sdk \
     ./scripts/build-android.sh debug
   ~~~

7. 源码变更后更新索引：

   ~~~bash
   /root/.local/bin/codegraph sync
   ~~~

8. Git 提交信息必须使用中文。发布任务还要完成 release 构建、验签、模拟器回归和 APK 部署。

## 2. 项目边界与目标

应用通过 SSH 登录一台或多台服务器，在非 PTY exec channel 中启动固定版本的
codex app-server，并把 JSON-RPC/JSONL 事件渲染成接近 VS Code Codex 插件的原生 Android
界面。它不是终端 ANSI 输出解析器，也不会把 app-server 暴露到公网 TCP/WebSocket。

项目必须保持独立：

- 只在 /home/yan/ygy/codex-remote-android 内开发。
- 不修改同级 ssh-client、lobe-android、mihomo-web 或其他人的工作区。
- .codegraph/ 是本机索引，codex-manual-markdown (8) 是本地资料；两者当前均不是提交内容，
  不要擅自删除、提交或覆盖。
- 真实服务器的密码、私钥、OpenAI 登录状态和 FRP token 不属于仓库内容。

## 3. 目录与职责

| 路径 | 职责 | 修改时首先检查 |
| --- | --- | --- |
| app/src/main/java/top/asdb/codexremote | Android 入口、主状态、后台服务和通知 | AppViewModel.kt、MainActivity.kt |
| app/src/main/java/top/asdb/codexremote/ui | Compose 页面、导航绑定和交互 | CodexRemoteApp.kt、对应 Screen |
| app/src/main/java/top/asdb/codexremote/data | 领域模型和加密持久化 | Models.kt、ProfileStore.kt |
| app/src/main/java/top/asdb/codexremote/codex | JSON-RPC 客户端、协议解析、缓存和多连接 | CodexAppServerClient.kt、CodexProtocol.kt |
| app/src/main/java/top/asdb/codexremote/ssh | SSH、安全指纹、远程安装、全局 Codex 设置和终端 | SshCodexTransport.kt、RemoteBootstrap.kt、RemoteCodexSettings.kt |
| app/src/main/assets/terminal | 本地 xterm.js 渲染资源 | terminal.html、terminal-bridge.js |
| app/src/test | JVM 单元测试 | 与改动模块对应的 Test 文件 |
| protocol | 固定版本和 app-server 契约 | codex-version.txt、node-version.txt |
| server | 独立服务器安装、限制入口和 smoke test | README.md、install-codex-pinned.sh |
| scripts | 本机构建和 Gitee Go 发布入口 | build-android.sh、publish-gitee-release.sh |
| docs | UI 契约、本文、模拟器截图和 XML 证据 | UI_SPEC.md、runtime-* |
| e2e | 由 App 内 Codex 完成的 WebUI 端到端样例 | webui-app-test-20260719 |
| keystore | 固定 APK 签名身份 | 严禁更换或重新生成 |

关键入口：

- CodexRemoteApplication.kt：初始化诊断日志和进程级设施。
- MainActivity.kt：Compose Activity、ViewModel 生命周期、通知权限和通知点击路由。
- ui/CodexRemoteApp.kt：收集 StateFlow，绑定三个主页面、全局弹窗、Snackbar 和终端覆盖层。
- AppViewModel.kt：当前的应用级编排中心。

## 4. 总体运行时架构

~~~text
┌──────────────────────────────── Android 进程 ────────────────────────────────┐
│ MainActivity / CodexRemoteApplication                                        │
│         │                                                                    │
│         v                                                                    │
│ CodexRemoteApp (Compose)                                                      │
│   ├─ ServerScreen       服务器列表、配置、安装进度、Debug 日志               │
│   ├─ ThreadListScreen   会话列表、工作区、服务器切换、SSH 终端入口            │
│   ├─ WorkScreen         时间线、审批、目标、模型、权限、输入和分页            │
│   ├─ SshTerminalScreen  独立交互式 shell 覆盖层                              │
│   └─ FileManagerScreen  当前服务器的 SFTP 文件浏览与传输                      │
│         │ callbacks / StateFlow                                              │
│         v                                                                    │
│ AppViewModel                                                                 │
│   ├─ ProfileStore                    加密持久化                               │
│   ├─ CodexConnectionManager          每个服务器一个独立 Codex 客户端          │
│   ├─ SshTerminalManager              每个服务器一个独立终端会话              │
│   ├─ SessionSnapshot / caches        切换服务器和重进会话的即时恢复           │
│   └─ operation/generation guards     防止超时、重连和并发结果串台             │
│         │                                                                    │
│         v                                                                    │
│ CodexAppServerClient ── CodexEventReducer ── ThreadSessionCache               │
│         │ JSON-RPC，每行一个 JSON                                             │
│         v                                                                    │
│ SshCodexTransport / PinnedSshSessionFactory                                  │
└─────────┼────────────────────────────────────────────────────────────────────┘
          │ SSH exec channel（无 PTY）
          v
~/.local/bin/codex-remote app-server --listen stdio://
          │
          v
固定 Codex CLI + 服务器用户的 CODEX_HOME + 所选工作目录
~~~

交互式终端是另一条 SSH shell channel，使用 xterm-256color 和本地 xterm.js。它与 Codex
JSON-RPC 通道相互独立，不能把终端 ANSI 数据送进协议解析器。

## 5. 页面和导航

AppScreen 包含 Servers、Threads、Work、AgentWork 和 FileManager。ui/CodexRemoteApp.kt 使用
AnimatedContent 做前进/返回的滑动淡入动画，并按页面绑定 AppViewModel 回调。

### 5.1 ServerScreen

职责：

- 默认首屏只显示多服务器列表。
- 服务器列表顶栏提供“低价中转站优选”外部链接；点击通过系统浏览器打开
  https://lowapi.asdb.top，无法处理链接时给出提示且不使应用崩溃。
- 保存服务器名、主机、端口、用户名、认证方式、凭据、固定指纹、远程命令和代理。
- 未连接时点击服务器先确认连接；已连接时点击直接进入会话列表。
- 每台服务器行在名称与用户/连接状态之间显示速度表、内存芯片、存储图标和百分比；未连接或采样失败显示 `--`，不阻塞连接和会话。
- 资源指标通过独立的只读 SSH exec 采样 `/proc/stat`、`/proc/cpuinfo`、`/proc/meminfo`、`df -P /` 和默认路由网卡的 `/proc/net/dev`，不安装远端 Agent；仅在服务器/会话列表前台轮询，进入后台暂停。会话列表中 CPU、内存、硬盘、网络任一指标均可点按，悬浮显示 CPU 占用/核心数、内存总量/已用量、根分区总量/已用量以及网络下载/上传速率。
- 设置只通过齿轮按钮进入；连接中显示半透明阻塞层和进度，禁止重复操作。
- 支持密码和私钥文件导入。私钥读取放在 Dispatchers.IO，并限制文件大小。
- 首次遇到未知 SSH 主机时显示 SHA-256 指纹确认。
- 缺失或版本不兼容的 Codex 由用户明确确认后安装，并显示阶段和百分比。
- 顶部 Codex 图标连续点击 10 次启用 Debug；Debug 页面可分享脱敏日志。开启后，会话右上角菜单
  可将最新日志作为受 512 KB 限制的文本附件加入输入区，超出时只附带日志末尾并标记截断。

ServerScreen 内部的未保存表单草稿只服务于页面切换。真正持久化仍由 AppViewModel 和
ProfileStore 完成。凭据不会写入 rememberSaveable Bundle；进程重建时从加密存储恢复。

### 5.2 ThreadListScreen

职责：

- 显示当前服务器名称、连接状态、搜索、刷新、新建会话和会话列表。
- 顶部 `CODEX` 标题可点击返回服务器列表；当前服务器名称下显示速度表、内存芯片、存储、网络图标及资源状态，点按任一指标可查看完整服务器资源详情。会话行本身不增加资源指标，保持原有高度和信息布局。
- 正在工作的会话使用固定尺寸的转圈状态，避免列表布局跳动。
- 从会话页返回时保留服务器级 SessionSnapshot，重复进入优先显示缓存后再远程校准。
- 提供服务器切换弹窗；切换只改变当前展示，不主动断开其他服务器。
- 顶部齿轮先显示“选择工作目录”和“配置 Codex”；另保留独立 SSH 终端入口。

工作目录自动弹窗只允许在某台服务器第一次成功连接时出现一次。ServerProfile 的
workspacePromptShown 和 workspace 负责记忆，之后只有用户主动选择时再打开。

### 5.3 WorkScreen

职责：

- 渲染用户消息、Agent Markdown、思考、计划、命令、文件改动、工具、子 Agent、审核和通知。
- 输入区固定在底部，适配系统栏和 IME；键盘出现时内容必须同步移动，不能等新消息才校准。
- 每个会话独立保存输入草稿、模型和推理强度。
- 正在运行时，主动作显示停止图标；空闲时显示发送图标。
- 输入区操作顺序维持“小型上下文圆环、模型、发送/停止”这一产品契约。圆环点击显示服务器返回的
  本轮上下文已用/剩余百分比和已用/总标记，不触发压缩确认；手动压缩保留在明确的会话操作菜单。
- 权限选择提供 VS Code 风格的请求批准、替我审批、完全访问三种模式。
- “会话操作”菜单提供目标、压缩、模型和权限入口，不依赖复杂的斜杠命令识别。
- 顶部历史使用下拉加载：只有用户拉动时显示提示，到阈值显示“松开加载更多”，内容跟随
  下移并在顶部留出清晰空间；释放后才请求更早内容。
- 用户阅读旧消息时显示回到最新位置的箭头，不应强制抢回滚动位置。
- Markdown 中带标题的 HTTP/HTTPS 链接必须显示完整蓝色 URL，不能只留下标题文字；点击标题或 URL
  都先显示确认打开弹窗，完整 URL 必须可通过长按文本选择复制。裸 URL 和 URL 本身作为标题的链接不应
  重复显示。相关纯字符串转换放在 `ui/components/MarkdownLinks.kt`，并由 `MarkdownTextTest` 覆盖。
- 子 Agent 只使用图标和状态表达，不额外显示“子agent”标签；状态由协议事件和父 turn
  终态共同收敛。同一智能体的图标身份色必须由 `threadId -> path -> name` 稳定派生，不能随
  运行、完成或失败状态改变；状态色只用于状态文字和运行指示。
- 同一 turn 的相邻子 Agent 活动在时间线保持紧凑、横向自动换行的 Agent 标签组。每个标签只为
  名称右侧的自身状态适度加宽：活动态用固定尺寸旋转指示器，终态显示各自状态文字；不得用组级
  “工作中/已完成”覆盖混合状态。输入区上方的“后台智能体”展开列表必须使用同一独立状态规则。
  点击任一项进入该智能体自己的工作页；返回时先恢复父页面快照，再通过
  `thread/resume` 恢复远端父线程上下文。加载中的子页也必须允许首次返回；同一层返回只能有一个
  pending resume，重复返回不得跳层或重复请求。导航栈按 profile 隔离，旧的异步恢复不得弹出较新的栈帧。
  恢复响应的 `thread.id` 必须等于请求的子 Agent id；不一致时仅重试一次，仍不一致则拒绝该响应，
  绝不能在子 Agent 标题下显示父会话。子 Agent 页也只接收有匹配 `threadId` 的流式项目。
  部分 app-server 会在子 Agent 的历史页中返回 fork 前继承的父回合；对 `threadSource=subagent`，必须以
  子线程 `createdAt` 为边界丢弃更早的 turn，并在首次遇到该边界后停止更早分页，不能只检查响应的
  `thread.id`。
  远端恢复失败时留在子页以便重试；已经断线时恢复父快照并提示重连。提交或审批期间不得切入子页。
- 支持目标的显示、编辑、暂停/继续和删除，目标是远程线程持久状态，不是本地假状态。

DiffViewer.kt 负责全屏 unified diff；ContextUsage.kt 负责上下文占用计算；components/
MarkdownText.kt 负责 Markwon 渲染。页面级修改不要把这些逻辑复制回 WorkScreen。ThreadSessionCache
会按服务器和会话独立保留最近一次**有效** `TokenUsage`，并与受大小限制的时间线缓存分开：即使长会话
时间线超过缓存上限，重进时圆环仍先恢复上次比例，等待远端 `thread/tokenUsage/updated` 覆盖。AppViewModel
还保留一层按服务器、会话隔离的轻量回退，用于 SSH 客户端重建后仍可立即恢复圆环。缺少
`modelContextWindow` 的不完整通知不得抹掉已有值；这些都是内存缓存，不在本地长期持久化。

### 5.4 TerminalScreen

SshTerminalManager 为每个 profile 维护独立 generation、输入队列、resize 队列和有界输出
历史。隐藏终端不等于断开；显式关闭、删除服务器或身份改变才释放对应 channel。工作目录存在
时，终端连接后发送安全 shell-quote 的 cd 命令。

### 5.5 FileManagerScreen

会话列表的设置菜单提供“文件管理”入口，仅对当前已连接服务器可用。它默认打开该 profile
的工作目录；未配置工作目录时打开当前 Unix 用户的 home，并可逐级进入根目录。目录列举、上传、
下载、重命名、删除、复制和移动均通过当前已验证 SSH Session 的独立 SFTP channel 完成，绝不拼接
远程 shell 命令。

- 普通点击目录进入，长按文件或目录弹出下载、重命名、复制、剪切和删除操作；删除目录必须二次确认。
- 右下角“更多”菜单始终提供多选上传和下载所选文件，剪切/复制后的内存剪贴板通过同一菜单粘贴到
 目前目录。剪贴板只在当前文件管理页、当前服务器中有效，不持久化也不跨服务器。
- 上传和下载使用 Android Storage Access Framework：上传可选择多个文档，下载由用户指定手机上的
 目标文件。上传不把完整文件读入内存；下载只允许普通文件，不跟随符号链接。
- 远程路径必须是绝对、无换行和无 `..` 段的 SFTP 路径；文件名只能是单个叶子名。目标已存在时拒绝
  覆盖，避免误覆盖服务器文件。列表最多显示 2,000 项，目录优先排序。

## 6. 状态、持久化和隔离

### 6.1 主状态

data/Models.kt 的 AppUiState 是 Compose 唯一展示状态，主要分为：

- 全局/服务器：profiles、selectedProfileId、connectionStates、debugModeEnabled。
- 连接流程：pendingFingerprint、remoteSetup、setupProgress。
- 会话列表：threads、threadSearch、loading。
- 当前会话：activeThread、timeline、activeTurnId、running、submitting。
- 分页：olderTurnsCursor、olderTurnsLoading。
- 会话配置：selectedModel、selectedEffort、approvalMode、sandbox。
- 交互：approvalQueue、attachments、composerDraft、tokenUsage、activeGoal。
- 瞬时 UI：error、diagnostic、workspace picker。

界面不应自己持有一份长期业务状态。新功能先扩展 Models/AppUiState，再由 AppViewModel 统一
更新，Composable 只保留弹窗展开、局部焦点等短生命周期状态。

### 6.2 多服务器隔离

隔离键必须遵循以下规则：

| 数据 | 隔离维度 | 当前位置 |
| --- | --- | --- |
| SSH/Codex 客户端 | profileId | CodexConnectionManager.Entry |
| 连接状态 | profileId | connectionStates |
| 页面会话快照 | profileId | AppViewModel.sessionSnapshots |
| 待审批队列 | profileId | pendingApprovalsByProfile |
| 恢复期通知缓冲 | profileId + threadId + generation | ResumeNotificationBuffer |
| 输入草稿 | profileId + threadId | composerDrafts |
| 模型/推理强度 | profileId + threadId | threadModelPreferences |
| 线程缓存 | profileId + threadId | CodexAppServerClient/ThreadSessionCache |
| 上下文用量回退 | profileId + threadId | ProfileScopedContextUsageCache |
| 终端会话 | profileId | SshTerminalManager |

任何新增会话设置都不能只做成全局字段。用户已明确要求不同服务器、不同会话互不串用。
修改 profile 的 host、port、username、认证信息、指纹或 remoteCommand 时视为连接身份变化：
必须关闭旧客户端、终端、缓存、审批和操作；只改名称、工作区等展示字段不应无故断线。

CodexConnectionManager 保持每个 profile 一个稳定 client 和独立 CoroutineScope。select 只切换
展示，connect/disconnect 只影响目标 profile，因此多台服务器可以同时保持连接。

### 6.3 加密持久化

ProfileStore 使用 AndroidX Security：

- MasterKey：AES256_GCM。
- EncryptedSharedPreferences key：AES256_SIV。
- value：AES256_GCM。
- JSON：StoredProfiles，ignoreUnknownKeys 便于向前兼容。

持久化内容包括服务器配置、最后选择的 profile、输入草稿和每线程模型偏好。不要把凭据再写入
普通 SharedPreferences、SavedState、日志、通知或截图。新增 StoredProfiles 字段必须有默认值，
并补充兼容旧 JSON 的测试。

输入草稿有长度和条目上限，并做延迟保存，避免每次按键同步写磁盘。发送成功后才清除对应草稿；
离开会话、切后台或重启应用后仍应恢复。

## 7. SSH 和连接生命周期

### 7.1 主机验证

连接分两步：

1. FingerprintCaptureHostKeyRepository 只探测公钥并生成 SHA-256 指纹。
2. 用户确认后把指纹写入 ServerProfile，正式连接使用 PinnedHostKeyRepository 严格匹配。

不得为了“连接方便”改成自动接受未知主机。host 或 port 改变后必须重新确认。

PinnedSshSessionFactory 统一密码/私钥认证、连接参数、15 秒 keepalive 和断线阈值。不要在不同
功能里各自创建一套宽松的 JSch 配置。

### 7.2 Codex 通道

SshCodexTransport 的正式连接过程：

1. 创建带固定指纹的 SSH Session。
2. 打开 exec channel，不申请 PTY。
3. 执行解析后的 remoteCommand。
4. stdout 按换行切成 JSON-RPC 消息，stdin 每次写一条 JSON。
5. stderr 作为远程诊断，不进入 JSON parser。
6. generation 标识一次连接；旧 reader、旧响应和旧 close 事件不能修改新连接。

所有 connect、channel connect、读取和写入都必须可取消。SshCodexTransport 对单行 JSON、
输出、diff 和时间线都有上限；维护这些边界是防 OOM/闪退要求，不要无上限拼接远程内容。

### 7.3 App-server 握手

CodexAppServerClient 连接后执行：

1. initialize。
2. 收到响应后发送 initialized notification。
3. model/list。
4. AppViewModel 加载 thread/list，并在页面可用后完成连接交接。

每个 request 有递增 id、CompletableDeferred 和超时。断线会一次性移除并失败所有 pending
请求。不要只增加 UI 超时时间而留下 pending；会话恢复较慢时应优先使用缓存即时展示，再由后台
resume 校准。

## 8. Codex 协议和事件归并

协议单一版本源是 protocol/codex-version.txt。Android 构建把它注入
BuildConfig.PINNED_CODEX_VERSION；服务器安装脚本也读取同一文件。

主要请求：

| 领域 | 方法 |
| --- | --- |
| 初始化/模型 | initialize、model/list |
| 会话 | thread/list、thread/read、thread/start、thread/resume、thread/archive |
| 会话维护 | thread/name/set、thread/rollback、thread/compact/start |
| 历史分页 | thread/turns/list |
| 执行 | turn/start、turn/steer、turn/interrupt |
| 审核 | review/start |
| 目标 | thread/goal/get、thread/goal/set、thread/goal/clear |

目标通知包括 thread/goal/updated 和 thread/goal/cleared。目标读取放在 resume 之后异步执行，
使用短超时；notification revision 防止晚到的 get 响应覆盖刚收到的新目标。

CodexProtocol.kt 的 CodexPayloadParser 把 wire JSON 映射成模型，CodexEventReducer 把
item started/completed、delta、turn 状态、diff、token usage 和子 Agent 事件幂等归并到
AppUiState。TimelineKind 与 UI 渲染是一一对应的扩展点。

协议修改规则：

1. 先检查官方 app-server schema 和 protocol/app-server-contract.md。
2. 保留 thread、turn、item 三层概念，不要用字符串标题猜状态。
3. 新通知必须可重复处理；同一 item 的 started、delta、completed 不得生成重复卡片。
4. server request 的原始 request id 必须保留到用户批准、拒绝或回答。
5. 未支持的 notification 可以忽略；未支持的 server request 必须返回 JSON-RPC -32601，
   避免远程 turn 永久等待。
6. 更新固定 CLI 版本时重新生成 schema，审核差异并跑完整回归。

### 8.1 会话缓存与分页

ThreadSessionCache 负责快速重进会话。openThread 的策略是：

1. 若有新鲜或陈旧缓存，先立即呈现时间线和运行状态。
2. 同时请求 thread/resume 获取权威快照。
3. ResumeNotificationBuffer 暂存 resume 期间属于同一 thread/generation 的流式通知。
4. 合并快照与缓冲事件，防止“旧响应覆盖连接期间新消息”。
5. 缓存更新时间线、turn ids、itemsView、older cursor，以及独立于时间线大小限制的最后有效上下文用量。

历史只按 turn 分页。首次 resume 使用倒序小页并排除完整 turns 主体；更早历史使用
thread/turns/list，遇到响应过大时降低 page limit/itemsView 后重试。UI 将新页 prepend，
必须去重并维持时间顺序。

子 Agent 是 fork 的独立线程，但某些 app-server 版本会把 fork 前的父 turn 一并放入它的
`initialTurnsPage` 或 `thread/turns/list`。解析 resume 时根据 `threadSource=subagent` 与子线程
`createdAt` 过滤 `startedAt` 更早的 turn；分页使用同一 cutoff，任何一页跨过该边界都必须将
`nextCursor` 置空。缺失 `startedAt` 的 turn 暂时保留以兼容旧服务器，当前固定版本会提供时间戳。

ProfileOperationTracker 把异步任务按 profile、lane、generation 标记。连接、会话导航、
历史、会话修改等 lane 的旧结果不能落到新选择的服务器或会话。

## 9. 远程环境探测、安装和卸载

仅当 profile 使用默认 managed command 时自动探测。RemoteBootstrap.probeScript 检查：

- Linux、glibc、x86_64/amd64 或 aarch64/arm64。
- /bin/sh、tar、sha256sum、flock、setsid --wait。
- curl 或 wget。
- ~/.local/bin/codex-remote 和系统 codex 的路径/版本。

选择顺序：

1. 已安装且版本完全匹配的 managed codex-remote。
2. 版本完全匹配的系统 codex。
3. 都不匹配时显示安装说明，由用户确认后安装。

自动安装位置：

~~~text
~/.local/share/codex-remote/runtime/
~/.local/share/codex-remote/releases/
~/.local/bin/codex-remote
~~~

安装行为：

- 不使用 sudo，不覆盖系统 Node.js，不改 VS Code 扩展内置 Codex。
- 下载固定 Node.js 并校验 SHA-256。
- npm 先锁定精确的 @openai/codex 依赖清单，再按该清单安装，避免依赖解析期间长期无反馈。
- 验证 codex --version 和 app-server --help 后才原子替换 wrapper。
- 使用 flock 防并发安装，用 SSH 父进程 watchdog 清理断线安装。
- 安装前要求用户 home 至少 300 MB 可用空间。
- 通过 ::progress::总体百分比|当前下载百分比|说明|详情 回传可见进度；旧的
  ::progress::百分比|说明 格式仍可解析。Node.js 下载显示真实字节进度，Codex CLI 下载显示
  已处理组件数和安装目录大小；安装总超时为 30 分钟。

下载代理由每台 ServerProfile.proxyUrl 单独保存，只用于这次远程 Node/Codex 下载。允许
http、https、socks5、socks5h；输入必须经过 RemoteBootstrap.validateProxyUrl，禁止直接拼接
未经验证的 shell 文本。国内网络下载慢时允许填写服务器能访问的代理；本机构建需要下载依赖时
优先探测 127.0.0.1:7890。

卸载只删除本应用管理的 runtime、release、wrapper 和 ~/.codex-mobile 附件暂存目录，不得删除：

- 系统 codex。
- VS Code Server/扩展。
- ~/.codex 中的账号、配置和会话。
- 用户工作目录。

服务器已有 Codex 或 VS Code 插件时，登录缓存通常由同一 Unix 用户的 CODEX_HOME 复用；
CLI 二进制不必共用。新账户仍需在服务器上完成 Codex 登录，应用安装器不会创建 OpenAI 凭据。

### 9.1 用户级 Codex 设置

会话列表的齿轮入口可读取和写入**当前已连接服务器、当前 Unix 用户**的全局 Codex 设置。该入口
与“选择工作目录”并列；它不是 ServerProfile 的本地字段，也不能按会话保存。读取时必须显示远端
`model_provider`、默认 `model`、默认 `model_reasoning_effort`、实际生效的模型 URL、代理和登录是否存在，不能只显示本应用曾写入的
`openai_base_url`。对于自定义 provider，模型 URL 来自对应 `[model_providers.<name>].base_url`；API
密钥默认只显示是否存在；用户在设置弹窗中明确点击显示后，可查看 `OPENAI_API_KEY` 的完整内容。它只在
当前弹窗和测试请求的内存中存在，关闭弹窗、切换服务器或断线时立即清除，绝不写入 ProfileStore、SavedState、
日志、通知或截图。

远端文件边界固定如下：

| 文件 | 写入方式和用途 |
| --- | --- |
| `$HOME/.codex/config.toml` | 原子保留无关根键和表。默认模型和思考强度更新根级 `model`、`model_reasoning_effort`；用户修改模型 URL 时更新 `model_provider = "openai"` 与可选 `openai_base_url`，仅修改默认值时保留现有自定义 Provider。 |
| `$HOME/.codex/auth.json` | 只有用户填写 API 密钥时，才通过 `codex login --with-api-key` 的标准输入由 CLI 写入；绝不由 App 伪造 JSON。用户打开设置时，可通过既有 SSH 通道仅读取 `OPENAI_API_KEY` 供掩码显示和连通性测试，绝不持久化到手机。 |
| `$HOME/.codex/codex-remote.env` | App 管理的 `0600` 私有代理环境文件，含 HTTP/HTTPS/ALL_PROXY 的大小写变量；代理留空时删除该文件。 |
| `$HOME/.local/bin/codex-remote` | managed wrapper 在启动前 source 代理环境文件；SshCodexTransport 启动 app-server 时也 source 一次，兼容既有 wrapper 和自定义 remoteCommand。 |

因此这些设置会作用于同一用户的 Codex CLI、VS Code Codex 插件和本应用。保存时 API 密钥仅在
内存和 SSH 标准输入中出现，不能写入 Android ProfileStore、诊断日志、通知或截图；API 密钥留空
必须保留现有登录，代理留空必须清除 Codex 代理。保存成功后 App 主动断开该 profile，下一次连接
才会以新的全局设置创建 app-server。

不得修改 `$HOME/.bashrc`、`$HOME/.profile`、任意项目 `.codex/config.toml`、其他工作目录或 VS Code
扩展文件。项目级配置不能安全覆盖 provider/auth，且这会破坏用户要求的全局行为。

`RemoteCodexSettingsTest` 必须覆盖 URL 校验、读写 POSIX shell 语法、内置和自定义 provider 的模型
URL 解析、保留 `[features]` 等无关 TOML 表、代理文件 `0600` 权限，以及 fake CLI 接收 API 密钥但不
回显。`RemoteBootstrapTest` 必须覆盖新 wrapper 仍 source 该环境文件。

## 10. 后台运行、完成通知和诊断

当任一 Codex 连接需要保持时，ConnectionForegroundService 以 dataSync 前台服务运行，显示低
优先级常驻通知并持有定时续期的 PARTIAL_WAKE_LOCK。它降低进后台后 SSH 被立即挂起的概率，
但 Android 厂商的强制省电、用户强停、网络切换和服务器断线仍可能终止连接。

“退出页面”不会中断服务器 turn；“进后台”通过前台服务尽量维持 SSH。若进程或网络真的断开，
直接 stdio app-server 会退出，但服务器已持久化的 thread 仍可重连恢复。不要向用户承诺在任何
系统策略下都绝对不断线。

TurnCompletionNotifier 监听 AppViewModel.turnCompletions：

- 仅在 turn 从运行状态进入终态时通知。
- 应用位于后台时显示状态栏通知。
- PendingIntent 带 profileId/threadId；点击后选择对应服务器并打开完成会话。
- 多服务器通知必须携带正确 profile，不能跳到当前恰好选中的另一台服务器。

DiagnosticLogger：

- 默认关闭；主页 Codex 图标连续点击 10 次打开。
- 记录应用生命周期、连接、操作和崩溃，不记录消息正文、密码、私钥或 token。
- 对主机、路径、URL、Bearer/API key 等内容进行脱敏。
- 文件有大小上限和轮转；分享时通过 FileProvider 导出文本并调起系统分享面板。
- 正常 UI 先显示简短中文错误，详细技术信息进入可导出的诊断日志。
- 远端 stderr 不是一律致命：rmcp/MCP 辅助工具的 HTTP 403 可能只关闭该工具 worker，主
  app-server 会话仍可继续。页面使用简短说明和紧凑深色 Snackbar，不显示嵌套 JSON、request id
  或原始 Rust 日志；连接真正关闭时仍明确显示失败状态。

修改日志格式或新增埋点时，必须补 DiagnosticLoggerTest 并人工检查导出文件无敏感信息。

## 11. 安全边界

- AndroidManifest 禁止备份和 cleartext traffic。
- SSH 未知主机永不静默接受。
- 密码和导入私钥只放加密存储。
- OpenAI auth.json 永远留在服务器，不打包；设置弹窗仅在用户主动打开时通过 SSH 临时读取 API-key
  登录值，默认掩码显示，绝不持久化到手机或日志。
- 默认权限为“请求批准”加 workspace-write；完全访问必须由用户显式选择。
- app-server 仅走 SSH stdio，不监听公网端口。
- SFTP 附件依赖服务器 subsystem；远程路径位于应用专用暂存区。图片以 `localImage` 发送；文本附件
  最大 512 KB，并将内容作为 `text` 输入发送给会话。
- 文件管理使用同一 SSH 账户的 SFTP 权限，产品界面不是文件系统沙箱；用户能看到和操作的范围仍由
  服务器账户、Unix 权限、chroot 或容器决定。

生产部署推荐非 root 专用账户、每台手机独立 SSH key、forced command、禁用 PTY/forwarding，
并用 Unix 权限或容器限制工作区。当前产品默认用户名按用户要求是 root，这是便利默认值，不代表
安全推荐。

server/codex-app-server-ssh 是受限入口样例，不是文件系统沙箱。cwd 仍可指向 Unix 账户有权访问
的位置；真正隔离必须靠专用账户、权限、chroot 或容器。

## 12. 构建系统和性能

固定工具链：

| 项目 | 版本/来源 |
| --- | --- |
| Gradle wrapper | 8.2 |
| Android Gradle Plugin | 8.2.2 |
| Kotlin | 1.9.22 |
| Compose BOM | 2024.02.02 |
| Java | 17 |
| SDK | 34 |
| Codex CLI | protocol/codex-version.txt |
| Node.js | protocol/node-version.txt |

gradle.properties 已启用 4 GB JVM heap、daemon、parallel、build cache、configuration cache、
VFS watch 和增量 Kotlin。空间换时间的设计依赖持久 Gradle cache，因此日常修改：

- 不运行 ./gradlew clean。
- 使用 ../.gradle-cache 或显式 GRADLE_USER_HOME。
- 先 fast/debug，只有发布门禁才跑 release/all。

统一入口：

~~~bash
./scripts/build-android.sh fast     # 仅编译 debug Kotlin
./scripts/build-android.sh debug    # debug 单测 + debug APK
./scripts/build-android.sh release  # release 单测 + release Lint + 签名 APK
./scripts/build-android.sh all      # 两个变体的测试、Lint 和 APK
~~~

脚本在依赖已缓存时默认离线。确需下载时：

~~~bash
CODEX_BUILD_ONLINE=1 ./scripts/build-android.sh debug
~~~

若 127.0.0.1:7890 正在监听，脚本会自动为 Gradle 和下载环境设置代理。不要把代理硬编码进 APK
业务网络；远程服务器下载代理由用户在安装弹窗中单独填写。

本机 Android SDK 没有全局配置时使用：

~~~bash
export ANDROID_HOME=/tmp/android-sdk
export ANDROID_SDK_ROOT=/tmp/android-sdk
~~~

## 13. 固定签名、版本和发布

签名身份是不可破坏的升级契约：

- keystore：keystore/codex-remote-stable.keystore
- debug 和 release 都使用同一 stable signingConfig。
- 不得删除、重新生成、替换 keystore，不得更换 alias。
- 发布前必须增加 app/build.gradle.kts 中的 versionCode；versionName 按发布语义增加。
- 同一 versionCode 即使 APK 内容变化，也可能无法覆盖安装；不要重复发布旧版本号。

Release APK：

~~~text
/home/yan/ygy/codex-remote-android/app/build/outputs/apk/release/app-release.apk
~~~

构建与验签：

~~~bash
ANDROID_HOME=/tmp/android-sdk ANDROID_SDK_ROOT=/tmp/android-sdk \
  ./scripts/build-android.sh release

/tmp/android-sdk/build-tools/34.0.0/apksigner verify \
  --verbose --print-certs app/build/outputs/apk/release/app-release.apk
~~~

当前稳定证书 SHA-256 记录在 README.md。验签输出必须与其一致。正式发布复制到：

~~~text
/var/www/html/codex.apk
~~~

发布后必须实际请求下载地址，并给用户：

~~~text
http://210.16.163.118:18080/codex.apk
~~~

下载端口是 18080。地址是部署环境，不是代码常量；报告前需绕过不合适的代理实际验证。不得在文档或提交中写
访问 token。

### 13.1 Gitee release 分支自动发布

正式发布由 Gitee Go 在受保护的 `release` 分支推送触发。该分支使用相同的流水线配置，因此 Gradle
缓存可以持续复用；Tag 推送不执行 Android 构建。Runner 使用外置 keystore 路径
`CODEX_SIGNING_KEYSTORE`，不能把 key 放进 Git；Gradle 还支持受保护变量
`CODEX_SIGNING_STORE_PASSWORD`、`CODEX_SIGNING_KEY_ALIAS` 和 `CODEX_SIGNING_KEY_PASSWORD`。本地未设置
这些变量时继续使用 `keystore/codex-remote-stable.keystore` 和既有签名身份。

流水线执行 `scripts/publish-gitee-release.sh`：仅当检出提交就是远端 `release` 的当前提交时才运行 release
门禁，随后验签、生成 `dist/` 构件，通过 Gitee API 创建 `v<versionName>`、Release 和 APK 附件。重跑时仅
复用指向同一提交的标签，绝不改写历史标签。完整的 Gitee Go 设置和发布步骤见
[GITEE_GO_RELEASE.md](GITEE_GO_RELEASE.md)。

Git 流程：

1. git diff 和 git diff --check。
2. 完成与风险匹配的测试。
3. /root/.local/bin/codegraph sync。
4. 提交信息使用中文，例如“补充项目架构与测试手册”。
5. 推送到已配置的 Gitee origin。不要强推，不要改写他人的历史。

## 14. 本地测试环境

### 14.1 已有环境

~~~text
Android SDK：/tmp/android-sdk
adb：/tmp/android-sdk/platform-tools/adb
build-tools：/tmp/android-sdk/build-tools/34.0.0
模拟器：emulator-5554，Android API 34（运行时以 adb devices -l 为准）
~~~

检查设备：

~~~bash
/tmp/android-sdk/platform-tools/adb devices -l
~~~

安装并冷启动：

~~~bash
/tmp/android-sdk/platform-tools/adb install -r \
  app/build/outputs/apk/debug/app-debug.apk

/tmp/android-sdk/platform-tools/adb shell am force-stop top.asdb.codexremote
/tmp/android-sdk/platform-tools/adb shell monkey \
  -p top.asdb.codexremote -c android.intent.category.LAUNCHER 1
~~~

抓取崩溃/ANR：

~~~bash
/tmp/android-sdk/platform-tools/adb logcat -c
# 复现后：
/tmp/android-sdk/platform-tools/adb logcat -d \
  'AndroidRuntime:E ActivityManager:E CodexRemote:* *:S'
~~~

测试键盘可结合 adb shell dumpsys window、UIAutomator XML 和截图。现有证据位于 docs 下的
runtime-keyboard-*、runtime-window*.xml、runtime-rotation-stress.png 等文件。

### 14.2 自动化门禁

快速编译：

~~~bash
ANDROID_HOME=/tmp/android-sdk ANDROID_SDK_ROOT=/tmp/android-sdk \
  ./gradlew :app:compileDebugKotlin
~~~

JVM 单测：

~~~bash
ANDROID_HOME=/tmp/android-sdk ANDROID_SDK_ROOT=/tmp/android-sdk \
  ./gradlew :app:testDebugUnitTest
~~~

Lint：

~~~bash
ANDROID_HOME=/tmp/android-sdk ANDROID_SDK_ROOT=/tmp/android-sdk \
  ./gradlew :app:lintDebug
~~~

发布编译：

~~~bash
ANDROID_HOME=/tmp/android-sdk ANDROID_SDK_ROOT=/tmp/android-sdk \
  ./gradlew :app:assembleRelease
~~~

当前已知 Lint 基线有两个非错误警告：Compose custom lint API 兼容性提示，以及
TurnCompletionNotifier.kt 的 ObsoleteSdkInt。新增错误或警告不能简单归咎于基线。

### 14.3 单元测试地图

| 测试 | 覆盖重点 |
| --- | --- |
| ApprovalModeTest | 权限模式到 approvalPolicy/sandbox 的映射 |
| CodexConnectionManagerTest | 多 profile 客户端和状态隔离 |
| CodexPayloadParserTest | thread/item/通知/审批/子 Agent/目标解析，以及父子会话事件隔离 |
| ConnectionHandoffTest | 连接遮罩到会话页的无空档交接 |
| ContextUsageTest | 上下文圆环占用计算 |
| ProfileScopedContextUsageCacheTest | 客户端重建后的上下文圆环回退、LRU 与 profile 隔离 |
| ProfileScopedBackStackTest | 子智能体嵌套逐层返回、pending 返回幂等、失败重试、profile 隔离和过期回调保护 |
| PersistedUiPreferenceTest | 草稿、模型、推理强度持久化和键空间 |
| ProfileOperationTrackerTest | 并发 lane、失效和竞态 |
| RemoteBootstrapTest | 探测、安装脚本、固定版本和清理 |
| RemoteProxyTest | 代理校验及 shell 注入防护 |
| ResumeNotificationBufferTest | resume 期间通知缓冲和合并 |
| SshFingerprintTest | SHA-256 指纹和严格匹配 |
| SshTerminalHelpersTest | 终端队列、resize、输出和 shell quote |
| ssh/SshCodexTransportTest | JSONL 边界、超大响应、取消和进度 |
| ThreadPagingTest | cursor、分页、去重、顺序、降级重试，以及子 Agent 继承父历史的边界过滤 |
| ThreadSessionCacheTest | 缓存有效期、LRU 和 profile 隔离 |
| SubAgentPresentationTest | 子智能体标签聚合、状态收敛、显示文案、可打开性和稳定身份色 |
| TurnCompletionNotifierTest | 后台完成判定和通知去重 |
| diagnostics/DiagnosticLoggerTest | 脱敏、轮转、点击计数 |

改共享协议、Models、AppViewModel 或连接生命周期时，不能只跑一个测试类，应至少跑完整
testDebugUnitTest。

### 14.4 模拟器手工回归矩阵

每个发布版本至少执行：

| 场景 | 操作 | 预期 |
| --- | --- | --- |
| 首次启动 | 冷启动，无配置 | 只显示服务器列表，无异常白框 |
| 新服务器 | 添加，默认值不改 | 默认用户 root，私钥模式可选，表单可滚动 |
| 指纹 | 第一次连接 | 显示 SHA-256 指纹；取消不保存，信任后固定 |
| 自动安装 | 远端缺 Codex | 显示代理输入、阶段、百分比和阻塞遮罩 |
| 已有 Codex | 版本匹配 | 复用可执行文件，不覆盖 VS Code/系统安装 |
| 工作目录 | 第一次成功连接 | 自动弹一次，确认后记住；后续连接不再自动弹 |
| 多服务器 | A、B 同时连接并切换 | A 不因选择 B 断开；状态、审批、线程不串台 |
| 连接动画 | 从服务器列表连接 | 全屏半透明转圈，结束后直接进入会话列表，无空白等待 |
| 会话缓存 | 重复进入较大历史会话 | 先显示缓存，后台校准；不轻易超时或闪白 |
| 会话运行态 | 会话仍生成时返回列表 | 列表固定尺寸转圈，返回会话继续流式更新 |
| 输入草稿 | 输入后返回、切服务器、杀进程再进 | 按 profile+thread 恢复，其他会话不出现 |
| 模型偏好 | 两个会话选不同模型/强度 | 各自永久恢复，不因返回主页被全局值覆盖 |
| IME | 点击输入框、输入多行、隐藏/再开键盘 | 输入框不被盖，上方消息与键盘同帧移动，不自动抢焦点 |
| 历史分页 | 顶部下拉未到/到阈值/释放 | 提示只在拉动时出现，显示“松开加载更多”，释放才加载 |
| 滚动 | 阅读旧消息时新 delta 到达 | 保持阅读位置并显示回到底部箭头 |
| 发送/停止 | 空闲发送、运行中点击停止 | 图标和状态正确，无重复 turn |
| 权限 | 三种模式及命令/文件审批 | 左下权限入口存在，审批关联正确 request id |
| 会话菜单 | 打开操作菜单 | 目标、压缩、模型、权限均可用，不依赖斜杠 |
| 目标 | 新建、编辑、暂停、重连、删除 | 与远程 thread 同步，重连后不被陈旧读取覆盖 |
| 子 Agent | 启动、工作、完成/失败 | 图标身份色稳定；每个 Agent 的运行圈或终态文字独立显示，互不覆盖 |
| 子 Agent 导航 | 点击时间线标签、输入区展开列表，随后返回/系统 Back | 进入对应子会话；先恢复父页面快照，再恢复远端父线程，草稿、模型、权限和上下文不串台 |
| 子 Agent 返回边界 | 加载中返回、连续返回、P→A→B 逐层返回、恢复失败、断线、切换服务器 | 首次返回立即切换到父快照且只请求一次；不跳层、不串状态；失败回子页可重试，断线返回父快照并提示重连，旧回调不能覆盖新页面 |
| 上下文 | 长会话点击圆环、返回列表后重进 | 小圆环稳定、不挤压模型和发送/停止按钮；立即恢复最近有效的本轮已用/总标记和百分比，不弹压缩确认 |
| 后台 | turn 运行时 Home/锁屏 | 尽量继续；完成后通知，点击跳到正确服务器和会话 |
| 进程重建 | force-stop/系统回收后重开 | 无闪退；持久状态恢复，连接状态不伪装成已连接 |
| 旋转/大字体 | 横竖屏和放大字体 | 无重叠、截断或不可达按钮，表单可滚动 |
| Debug | Codex 图标连点 10 次并分享 | 日志启用、可预览/分享、敏感值已脱敏 |
| 终端 | 打开、隐藏、恢复、resize、关闭 | 输出保留且有界，不影响 Codex channel |
| 文件管理 | 进入目录、长按文件、上传多文件、下载、重命名、删除、复制/剪切再粘贴 | 只操作当前服务器；系统文件选择器可返回；删除有确认；目录、路径和连接状态不串台 |

相关历史截图包括：

- 服务器/UI：runtime-server-screen*、runtime-vscode-list-redesign.png。
- 会话/UI：runtime-vscode-work-redesign.png、runtime-composer-1.5.1-*。
- 键盘：runtime-keyboard-*。
- 目录：runtime-workspace-*、runtime-directory-picker-stress.png。
- 安装：runtime-auto-setup-*。
- 恢复：runtime-process-restore.png、runtime-reconnect-after-process-kill.png。
- 审批：runtime-permission-menu*、runtime-approval-deny.png。

这些图片是回归参考，不是像素级绝对规范；交互契约以本文和 docs/UI_SPEC.md 为准。

### 14.5 真实 SSH/app-server 回归

模拟器无法替代真实网络。获得明确授权和临时凭据后，可在测试服务器验证：

1. server/install-codex-pinned.sh 安装固定版本，或让 App 执行受控自动安装。
2. 服务器用户完成 codex login status。
3. 运行：

   ~~~bash
   CODEX_REMOTE_BIN="$HOME/.local/bin/codex-remote" \
     node server/smoke-test.mjs
   ~~~

4. App 验证 thread/list、resume、turn、审批、目标、分页、后台完成通知和重连。
5. 测试产生的临时 thread、goal、文件和附件要清理；不要删除用户原有会话或工作区。

server/smoke-test.mjs 只校验 initialize、thread/list 和 model/list，不代表完整 App 回归。
远程测试不得把密码放进命令历史、文档、截图或 Git。

## 15. 修改影响图

### 新增/修改协议事件

~~~text
Codex schema
  -> CodexAppServerClient（request/notification）
  -> CodexPayloadParser / CodexEventReducer
  -> Models/AppUiState
  -> AppViewModel（profile/generation 过滤）
  -> WorkScreen/ThreadListScreen
  -> parser + reducer + paging/cache 测试
~~~

### 修改服务器连接

~~~text
ServerProfile / ServerScreen
  -> ProfileStore migration
  -> PinnedSshSessionFactory
  -> SshCodexTransport
  -> CodexConnectionManager
  -> AppViewModel operation guards
  -> 指纹、多服务器、后台、重连、安装回归
~~~

### 修改会话 UI

~~~text
Models/TimelineKind
  -> CodexProtocol reducer
  -> AppViewModel cache/snapshot
  -> WorkScreen + Markdown/Diff/Context helpers
  -> IME、滚动、分页、旋转、大字体、进程重建回归
~~~

### 修改持久化字段

~~~text
Serializable data class（必须给默认值）
  -> ProfileStore
  -> normalize/restore/persist helpers
  -> 旧数据兼容测试
  -> force-stop 和升级安装测试
~~~

## 16. 已确认的产品约束

以下内容来自持续使用反馈，应视为回归契约，而不是可随意清理的旧需求：

1. 首页是服务器列表，设置按需展开；默认 SSH 用户是 root。
2. 多台服务器可保存、同时连接和快速切换，任何状态不得串台。
3. 工作目录第一次连接自动选择一次并记住，之后不重复打扰。
4. 输入草稿、模型、思考强度按服务器+会话独立、持久保存。
5. App 从后台回来不能自动弹键盘；IME 出现时输入框和消息内容同步上移。
6. 会话重进优先用缓存，较大历史允许更长的后台恢复，不让页面长期空白。
7. 更早历史通过顶部下拉释放加载，提示和顶部留白跟随手势。
8. 会话运行中显示停止图标，列表显示运行转圈；上下文用小圆环，不挤占动作区，点击只查看当前上下文占用。
9. 子 Agent 用稳定身份色的图标表达，状态必须准确且逐个独立显示：保留横向自动换行的紧凑 Agent 框，只在名称右侧增加活动态旋转指示器或终态文字，不显示多余“子agent”标签；点击其 Agent 框或列表项必须进入其真实独立会话，绝不显示父会话内容，并能安全返回父会话。加载中允许首次返回、重复返回不跳层，提交或审批期间禁止切换会话。
10. 会话目标和操作菜单使用原生 app-server 能力，不依赖难维护的斜杠解析。
11. App 后台时 turn 完成要发通知，点击进入正确的服务器和会话。
12. Debug 通过 Codex 图标连点 10 次开启，日志可用系统分享并且必须脱敏。
13. 所有输入页面必须适配键盘、横竖屏和大字体，不允许控件重叠。
14. 远程安装必须有可见进度，允许用户为该服务器填写下载代理。
15. 页面视觉保持接近 VS Code Codex：安静、紧凑、工作导向；不使用营销式大卡片、渐变或
    装饰背景。
16. APK 签名永不变化，发布 versionCode 必增；交付同时给内网和外网地址。
17. 本机构建需要下载时优先使用 7890 代理；已经缓存时保持离线增量构建。
18. 每次修改要自己测试，不能只以“编译通过”代替模拟器和真实流程验证。
19. Git 提交信息使用中文，并同步到配置好的 Gitee 仓库。
20. 服务器列表中的“低价中转站优选”必须是系统浏览器外链，不在应用内嵌 WebView；目标为
    https://lowapi.asdb.top。
21. 远端工具/MCP 的非致命 stderr 必须转成简短中文提示，不能用原始 HTTP/JSON/Rust 日志遮挡
    会话；真正断线、认证失败和不可恢复错误仍需明确提示。
22. Codex 配置入口修改的是当前远程 Unix 用户的全局设置：模型 URL、API 密钥和 HTTP/HTTPS
    代理。API 密钥不能保存到手机；设置弹窗可临时读取、默认掩码显示。测试模型按服务器保存在本地，测试时
    使用当前输入值从服务器向 OpenAI 兼容 `/responses` 发送最小请求。保存后必须断开并在重连时生效，不能改
    项目级 `.codex`、shell profile 或其他工作区。
23. Codex 配置弹窗必须优先从服务器读取并显示 Provider、默认模型、模型 URL、代理、登录状态和可用的
    API 密钥。现有自定义 Provider 不能被误显示为“未配置”；若保存会切换到内置 OpenAI Provider，必须在操作前
    现有自定义 Provider 不能被误显示为“未配置”；若保存会切换到内置 OpenAI Provider，必须在操作前
    明确提示用户。
24. 任何回复中的 HTTP/HTTPS Markdown 链接都必须既可点击又可复制，并显示完整目标 URL；不得只
    渲染无法辨认或复制的链接标题。

若实现与上述约束冲突，先修实现；如确需改变产品契约，必须得到用户明确确认并同步更新本文。

## 17. 故障定位

### 17.1 HTTP 403 / UnexpectedServerResponse

远程日志出现 rmcp::transport::worker、UnexpectedServerResponse("HTTP 403 ... Forbidden")
通常是 Codex/MCP/API 上游拒绝，而不是 Android Compose 崩溃。依次检查：

- 服务器用户的 Codex 登录是否有效或过期。
- API key/订阅/模型权限是否满足。
- 服务器代理、出口 IP、区域或企业网关策略。
- MCP 服务是否需要额外授权。
- 错误时间和 request id 对应的网关日志。

App 应把原始技术细节写入脱敏日志，普通页面只显示简短说明。不要把 403 错误误诊为 SSH
指纹失败，也不要在没有证据时自动重装 Codex。若来源是 rmcp/MCP 辅助 worker 且主连接仍为
Connected，提示“远端工具服务返回 403，但当前会话仍正常；相关工具可能暂时不可用”；不要把
嵌套 JSON、网关 request id 或 Rust transport 原文展示给用户。

### 17.2 HTTP 503、超时和会话空白

503 多为上游暂时不可用；request timeout 可能是网络、超大历史或服务无响应。先查看 Debug
日志中的 profile、method、generation 和耗时，再判断：

- SSH keepalive 是否仍存活。
- app-server 是否退出。
- 同一 profile 是否发生重连并产生新 generation。
- resume 是否命中大响应降级。
- UI 是否已先展示缓存，只是后台校准失败。

盲目把所有超时改得很大，会让 stale pending 长期占用资源。应针对 thread/resume、历史分页等
具体方法调整，并保留可取消与旧 generation 防护。

### 17.3 闪退和 ANR

先收集：

- Debug 导出日志。
- adb logcat 中 AndroidRuntime、ANR 和本应用条目。
- 设备型号、Android 版本、应用版本、页面和复现步骤。
- 是否伴随大历史、超长命令输出、旋转、键盘或后台恢复。

常见防线是协议内容上限、有界 terminal queue、IO 不在主线程、可取消连接、Compose 稳定 key。
不要通过吞掉 Throwable 隐藏真正崩溃；保留脱敏诊断并把 UI 退回可恢复状态。

### 17.4 键盘与滚动

确认 Manifest 的 windowSoftInputMode=adjustResize，页面使用 imePadding/系统栏 inset，并检查
LazyList 自动滚动触发时机。键盘上移慢通常是两个独立动画或等待新 timeline state 导致；修复后
需录制/截图验证同帧移动，同时确认从后台恢复不会自动 requestFocus。

### 17.5 APK 无法覆盖安装

检查顺序：

1. applicationId 是否仍是 top.asdb.codexremote。
2. versionCode 是否高于已安装版本。
3. apksigner 的证书 SHA-256 是否与 README 记录一致。
4. 是否误装了用其他 keystore 签名的 debug/release 包。

绝不能通过更换签名或卸载用户数据来“解决”正式升级问题。

## 18. 已知限制

- Codex app-server API 仍是实验接口，升级 CLI 可能破坏字段或方法。
- direct stdio 模式随 SSH 断开而退出；会话持久，进程不持久。
- 可选 daemon bootstrap 会启动官方 standalone updater，可能自动升级，因此不属于严格固定版本
  方案。严格 pin 使用本仓库 npm direct 模式。
- Android 前台服务不能绕过厂商的强制省电或用户强停。
- SFTP 上传是否可用取决于服务器 SSH subsystem 和权限。
- request_user_input 在固定 Codex 版本中是实验能力，服务器可能默认关闭。
- 目前以 JVM 单测和模拟器手工回归为主，UI instrumentation 覆盖仍有限。

## 19. 文档维护规则

以下变化必须在同一提交更新本文：

- 新增主模块、页面、协议方法或持久化字段。
- 修改版本源、签名、构建命令、SDK 或模拟器路径。
- 修改连接、缓存、后台、通知或远程安装流程。
- 用户确认新的长期产品约束。
- 新增关键回归用例或已知故障。

README 保持面向使用者，docs/UI_SPEC.md 保持视觉行为契约，本文保持面向维护者。不要在三个文件
复制大段易过期内容；本文可链接它们，并明确唯一事实来源。
