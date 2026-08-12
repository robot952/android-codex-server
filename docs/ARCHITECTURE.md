# Codex Remote Android 架构与协作手册

本文面向维护者和 AI 编码代理，回答四个问题：当前代码从哪里启动、状态如何流动、哪些能力真的
可用、修改后怎样验证。README 面向使用者；本文是迁移边界和协作规则的主文档。

## 0. 文档基线和真实性

当前 Android 运行入口已经从旧 Kotlin/Compose 工程迁到 Flutter：

| 项目 | 当前事实 |
| --- | --- |
| Flutter 入口 | flutter_app/lib/main.dart |
| 应用根组件 | flutter_app/lib/src/app/codex_remote_app.dart |
| Flutter | 3.44.8 stable |
| Dart | 3.12.2 |
| App 版本 | 1.8.33+160，来自 flutter_app/pubspec.yaml |
| Android | minSdk 26、targetSdk 34、compileSdk 36 |
| Java / Gradle / AGP / Kotlin | Java 17 / Gradle 9.1.0 / AGP 9.0.1 / Kotlin 2.3.20 |
| 当前交付目标 | Android Flutter APK |

app/ 是旧 Kotlin/Jetpack Compose 的完整实现，只能作为迁移参考和历史行为基线，不能写成当前
Flutter 应用的运行架构、构建入口或已验收能力。文中出现“迁移目标”或“历史参考”时，表示尚未
在当前 Flutter APK 中完成。

当前工作在独立的 flutter-refactor 分支进行。开始任何任务先执行：

~~~bash
git status --short --branch
git branch --show-current
~~~

保留共享工作区中不属于当前任务的改动和未跟踪文件；不要用 reset、checkout 或 clean 覆盖它们。

## 1. AI 五分钟入口

1. 只在本仓库目录工作，不修改同级 ssh-client、lobe-android、mihomo-web 或其他人的工作区。
2. 仓库存在 .codegraph/ 时，理解源码前先运行：

   ~~~bash
   codegraph explore "描述问题，并写出相关文件或符号"
   ~~~

   若 PATH 中没有命令，使用 /root/.local/bin/codegraph。先看本文的当前实现、迁移缺口和回归矩阵。
3. 第一次写文件前记录开始时间；手工编辑使用 apply_patch，不顺手重构无关模块，不运行 flutter clean
   或 Gradle clean。
4. 先通过 ./scripts/flutter-tool.sh 运行格式化和最接近改动的定向测试，再按风险只选择 quick、check、
   full 或 publish 中一个主门禁；不要机械串行重复全部门禁。具体风险表、缓存和模拟器规则见
   LOCAL_WORKFLOW.md。
5. 源码修改完成后运行 codegraph sync；纯文档修改不需要同步索引。最后运行 git diff --check，记录从
   第一次写文件到最终检查的总耗时和 .workflow-cache/latest-workflow-timing.tsv 中的阶段耗时。
6. Git 提交信息使用中文；本任务没有得到提交授权时不要提交或推送。

## 2. 项目边界

长期目标是：通过 SSH 连接一台或多台服务器，在无 PTY 的 exec channel 中启动固定版本的 Codex 或
OpenCode Agent，将事件渲染为接近 VS Code Codex 插件的移动端工作界面。当前 Flutter 已经形成可运行的
双 Agent 纵向链路：Codex 直接使用 app-server JSONL，OpenCode 由 App 自带 bridge 将本机 REST/SSE
转换成相同的 JSONL 契约；两条 lane 都完成 initialize、model/list、thread/list、thread/resume 和 turn
生命周期，并将事件投影到共享会话列表和 Work 页面。

当前已经接入并应按“已完成”理解的能力包括：

- 多服务器 Profile、严格 SSH 指纹确认、密码/私钥认证、连接状态和 CPU/内存/磁盘/网络指标；
- Codex JSONL 与 OpenCode bridge 的握手、模型列表、会话列表/搜索、新建、恢复、历史处理和有界事件解析；
- Work 页面发送/停止、审批和用户输入、权限模式、会话级模型/思考强度、草稿、上下文用量、压缩、
  回退、归档、重命名、代码审查和线程目标；
- 时间线 reducer（消息、思考、计划、命令、文件修改、工具、图片和协作活动）、图片预览/保存、
  generation 过滤以及按 lane 的会话缓存；
- 本地图片/文件选择、有界读取、SFTP 暂存、上传中状态、待发附件移除，以及随 `turn/start` 发送；
- Markdown 中的远程绝对文件链接、安全 SFTP 流式下载，以及 Android 系统文件选择器导出；
- 独立 SSH PTY 终端（每台服务器独立 channel、xterm-256color、bounded scrollback）和 SFTP 文件管理
  （浏览、上传、下载、重命名、删除、复制/移动）；
- Android 后台连接保护（前台 Service、partial wake lock）、回合完成通知/去重/点击直达，以及可选的
  Debug 日志采集、崩溃记录、脱敏、轮转、预览和系统分享；
- Android 应用内更新：启动自动检查与手动检查 Gitee 稳定 Release、SemVer 比较、更新日志、忽略版本、
  可恢复的 DownloadManager 下载进度、未知来源授权后的系统 APK 安装，以及包名/版本/稳定签名校验；
- Agent 首次成功连接时的一次性工作目录提示、SFTP 目录浏览、确认保存和设置菜单手动重开；
- Codex 与 OpenCode 固定版本运行时探测、当前 SSH 用户目录隔离安装、HTTP/HTTPS 下载代理、流式安装
  进度、最小化/失败重试、安装后复检和自动连接，以及只触碰当前用户托管路径的卸载脚本；
- Codex 与 OpenCode 全局配置读取/保存、真实 API 连通性测试、OpenCode 自定义模型同步，以及按服务器 +
  Agent 的本地默认值持久化。

仍未形成可交付端到端验收的部分必须明确标为“缺口”：本轮 Flutter test、新 debug APK 和高分辨率
模拟器启动回归已经通过，但尚未在授权真实服务器验证 OpenCode 固定版本下载/安装/卸载、真实
Provider/API、长时 turn/steer/interrupt、断线和后台行为，也未在真机完成应用内更新的下载、未知来源授权
与覆盖安装。Codex 子 Agent 独立 thread 导航/父子返回栈已经接入 Flutter，但仍需真实设备长时回归。
两种 Agent 的自动安装、终端、文件管理、后台保护、完成通知和 Debug 日志已经有 Flutter/Android 实现，
但仍需在目标设备上做权限、厂商后台限制和长时运行回归；不要因为代码、纯单元测试和启动 smoke 已通过，
就把真实服务器或系统安装流程写成已完成。

下列内容不属于仓库提交内容：真实服务器密码、私钥、Codex 登录缓存、OpenAI API key、FRP token、
本机 .workflow-cache/、.codegraph/ 索引和本地资料目录 codex-manual-markdown (8)。不要把它们
写进日志、截图、文档或 Git。

## 3. 当前目录与职责

| 路径 | 当前职责 | 状态 |
| --- | --- | --- |
| flutter_app/lib/main.dart | Flutter 进程入口、ProviderScope | 当前运行 |
| flutter_app/lib/src/app/codex_remote_app.dart | MaterialApp、全局错误 Snackbar、页面动画和 Back 行为 | 当前运行 |
| flutter_app/lib/src/app/app_controller.dart | Riverpod StateNotifier；Profile、SSH、Agent lane、会话恢复/缓存、模型目录、Work 状态和持久化编排 | 当前运行 |
| flutter_app/lib/src/domain/models.dart | Freezed/JSON 领域模型、Agent/线程/时间线/审批/上下文，以及安装/工作区/全局设置状态 | 当前与预留并存 |
| flutter_app/lib/src/domain/model_catalog.dart | 自定义模型 ID/名称/token 上限归一化、远端/自定义目录合并、隐藏、编辑恢复与 API 模型选项映射 | 当前运行；供控制器和展示层共用 |
| flutter_app/lib/src/persistence/profile_store.dart | 加密 Profile 存储、边界归一化、旧原生数据迁移 | 当前运行 |
| flutter_app/lib/src/ssh/server_connection_manager.dart | 每个 profileId 一个主机客户端、锁和 generation | 当前运行 |
| flutter_app/lib/src/ssh/ssh_server_client.dart | dartssh2 socket、认证、指纹、有界 exec、stdin 脚本、长任务逐行输出、SFTP/PTY 能力 | 当前运行；配置和安装脚本不会进入 SSH 命令参数 |
| flutter_app/lib/src/agent/remote_agent_client.dart | Agent 中立连接、事件、列表、回合、会话变更、全局设置和可选运行时契约 | 当前运行；Codex/OpenCode 共用 |
| flutter_app/lib/src/agent/remote_bootstrap.dart | Codex/Node 固定版本、Linux 探测、安装/卸载脚本、代理校验和进度解析 | 当前运行；仅管理当前 SSH 用户目录 |
| flutter_app/lib/src/agent/codex_agent_client.dart | Codex JSONL、pending RPC、独立 SSH exec channel、回合/审批/会话变更、运行时、全局配置和远端 API 模型列表 | 当前运行；脚本经 SSH stdin 执行 |
| flutter_app/lib/src/agent/codex_global_settings.dart | Codex `config.toml`/认证/代理脚本、解析、校验、真实 API 测试与兼容 `/models` 请求脚本 | 当前运行；仅修改远程用户全局文件 |
| flutter_app/lib/src/agent/opencode_agent_client.dart | OpenCode adapter；托管 bridge 命令、运行时、全局设置、Provider 模型映射和自定义模型同步 | 当前运行；复用 Codex JSONL 传输、reducer 和共享状态机 |
| flutter_app/lib/src/agent/open_code_bootstrap.dart | 固定 OpenCode/共享 Node 探测、两阶段安装、bridge hash 校验和范围受限的卸载 | 当前运行；仅管理当前 SSH 用户目录下的 OpenCode 内容 |
| flutter_app/lib/src/agent/open_code_bridge_asset.dart | 将打包的 OpenCode bridge 作为受校验安装输入加载 | 当前运行 |
| flutter_app/assets/opencode-bridge.cjs | OpenCode REST/SSE 到 Agent JSONL 的远端兼容 bridge | 当前运行；只监听远端 loopback 随机端口并启用随机 Basic Auth |
| flutter_app/lib/src/agent/agent_connection_manager.dart | `profileId + AgentKind` lane、锁、generation 和状态 | 当前运行 |
| flutter_app/lib/src/agent/codex_protocol.dart | JSONL 编解码、兼容 payload 解析和有界字段 | 当前运行 |
| flutter_app/lib/src/agent/thread_session_cache.dart | 每个 Agent lane 的有界会话/时间线/上下文内存缓存 | 当前运行；由 AppController 接入 Work 恢复 |
| flutter_app/lib/src/ssh/server_metrics.dart | Linux CPU、内存、磁盘和网络采样脚本及有界结果解析 | 当前运行 |
| flutter_app/lib/src/ui/server_screen.dart | 服务器列表、设置编辑、私钥导入、连接遮罩和外链 | 当前运行 |
| flutter_app/lib/src/ui/thread_list_screen.dart | Codex/OpenCode lane 切换、搜索/刷新、真实会话列表、新建入口、运行状态、工作目录、Agent 配置、终端和文件管理入口 | 当前运行；两种 Agent 均由真实 adapter 驱动 |
| flutter_app/lib/src/ui/agent_settings_dialog.dart | 服务器实际配置、模型/effort/URL/Key/HTTP(S) 代理、真实测试、回显和保存确认 | 当前运行；Codex/OpenCode 后端均已接入 |
| flutter_app/lib/src/ui/remote_setup_dialog.dart | 运行时信息、代理输入、总体/下载进度、失败重试和安装中最小化；代理聚焦时收起运行时信息 | 当前运行；IME 安全，与旧 Compose 聚焦行为一致 |
| flutter_app/lib/src/ui/workspace_picker_dialog.dart | 当前远端路径、父/子目录浏览、加载/错误显示和目录确认 | 当前运行 |
| flutter_app/lib/src/ui/work_screen.dart | 当前线程时间线、Composer、附件选择/上传、审批、模型/自定义模型管理/权限、会话操作、图片预览/保存、远程文件保存、上下文环和子 Agent 子会话入口 | 当前运行 |
| flutter_app/lib/src/ui/sub_agent_presentation.dart | 子 Agent 活动分组、稳定身份色、独立状态映射和终态保护 | 当前运行；由 WorkScreen 接线 |
| flutter_app/lib/src/ui/model_selection_presentation.dart | wire 模型名、当前模型匹配、思考强度和模型容量展示映射 | 当前运行；由 WorkScreen 接线 |
| flutter_app/lib/src/app/profile_scoped_back_stack.dart | 按 profile + Agent 隔离的父子会话返回栈、pending pop 幂等和清理 | 当前运行 |
| flutter_app/lib/src/ui/work_content.dart | Codex 图片结果识别、文件名和 MIME 辅助 | 当前运行 |
| flutter_app/lib/src/ui/markdown_links.dart | HTTP/HTTPS Markdown/裸链接和远程绝对文件路径的内部安全链接 | 当前运行 |
| flutter_app/lib/src/platform/local_file_exporter.dart | Android 文件导出 MethodChannel 抽象和分块会话 | 当前运行 |
| flutter_app/lib/src/platform/background_connection_bridge.dart | Flutter 到 Android 前台连接保护 Service 的启停桥接 | 当前运行；平台失败隔离 |
| flutter_app/lib/src/platform/turn_completion_notifications.dart | 回合完成通知、bounded 去重、子 Agent 过滤和点击深链 | 当前运行；通知权限/插件失败降级 |
| flutter_app/lib/src/platform/diagnostic_logger.dart | 持久化 Debug 日志、崩溃记录、脱敏、分段轮转、导出和分享 | 当前运行；普通日志需显式开启 |
| flutter_app/lib/src/platform/app_update_manager.dart | Gitee Release 检查、SemVer/资源筛选、忽略版本持久化、下载/安装状态机和 Android MethodChannel 抽象 | 当前运行；只在 Android 自动检查 |
| flutter_app/lib/src/ui/diagnostic_log_sheet.dart | Debug 日志预览、复制、清空、分享和关闭 Debug | 当前运行 |
| flutter_app/lib/src/ui/app_update_dialog.dart | 更新日志、下载进度、后台继续、忽略版本、失败重试和安装操作 | 当前运行 |
| flutter_app/lib/src/ssh/terminal_manager.dart | 每 profile 独立 SSH PTY、输出历史、resize、重试和 generation 隔离 | 当前运行 |
| flutter_app/lib/src/ui/terminal_screen.dart | xterm 终端显示、输入、重连、隐藏和显式关闭 | 当前运行 |
| flutter_app/lib/src/ui/file_manager_screen.dart | SFTP 文件浏览、上传/下载、重命名、删除、复制/移动和 SAF 保存 | 当前运行；尚需真机回归 |
| flutter_app/android/app/src/main/kotlin/top/asdb/agent/ConnectionForegroundService.kt | Android 前台连接保护通知、partial wake lock 和粘性进程恢复 | 当前运行；`START_STICKY`，强制停止/厂商限制除外 |
| flutter_app/android/app/src/main/kotlin/top/asdb/agent/DiagnosticLogBridge.kt | Java/Native/ANR 历史退出恢复、主线程 watchdog、原生日志轮转与脱敏 | 当前运行；Android 11+ 使用 `ApplicationExitInfo`，旧系统使用进程标记兜底 |
| flutter_app/lib/src/ui/server_metrics_strip.dart | 两个列表共用的紧凑资源指标和点击详情 | 当前运行 |
| flutter_app/lib/src/ui/theme.dart | Flutter 主题和产品色值 | 当前运行 |
| flutter_app/android/app/src/main/kotlin/.../MainActivity.kt | legacy Profile、file_export、background Service、app_update 和 local_linux MethodChannel | 当前运行；负责旧 Profile 导入、SAF 分块文件导出、服务启停、连接期 FlutterEngine 保留、系统下载/安装及本机 Linux 桥接 |
| flutter_app/android/app/src/main/kotlin/.../LocalLinuxManager.kt | ARM64 PRoot Debian 生命周期、下载校验、解压和回环 SSH | 当前实验能力；只支持 ARM64 Android |
| flutter_app/android/app/src/main/AndroidManifest.xml | Android 权限、Activity、前台 Service 和应用名 | 当前运行；包含联网、通知、wake lock、dataSync 和未知来源安装声明 |
| flutter_app/lib/src/domain/models.freezed.dart、models.g.dart | 生成代码 | 不要手工编辑 |
| flutter_app/test | Flutter 单元测试和 Widget 测试 | 当前门禁 |
| app/ | Kotlin/Compose、Codex 协议、终端、文件管理等旧实现 | 历史参考，不是入口 |
| server、protocol、scripts | 服务器辅助工具、版本资料、构建/测试/发布 | 独立辅助层 |
| keystore | 稳定签名身份 | 严禁替换 |
| docs/UI_SPEC.md | 视觉和交互契约 | 参考；当前实现边界以本文为准 |
| docs/LOCAL_WORKFLOW.md | 本地构建、模拟器和发布命令 | 当前流程 |

修改 models.dart 后，只有在需要更新生成文件时才运行：

~~~bash
cd flutter_app
dart run build_runner build --delete-conflicting-outputs
~~~

生成文件的变更必须和源模型同一任务审查；不要为了格式化而重新生成无关内容。

## 4. 当前运行时架构

~~~text
main.dart
  |
  +-- ProviderScope
        |
        +-- CodexRemoteApp / _AppRoot
              |
              +-- ServerScreen <------ AppUiState ------ AppController
              +-- ThreadListScreen                             |
              +-- WorkScreen                                   +-- SecureProfileStore
                                                               |     |
                                                               |     +-- flutter_secure_storage
                                                               |     +-- legacy MethodChannel (Android)
                                                               |
                                                               +-- ServerConnectionManager
                                                                     |
                                                                     +-- DartSshServerClient
                                                                           |
                                                                           +-- dartssh2 / SSH socket
                                                                           +-- bounded exec/metrics/SFTP/PTY
                                                                           +-- TerminalManager (profile PTY lanes)
                                                               +-- AgentConnectionManager
                                                                     |
                                                                     +-- CodexAgentClient
                                                                     |     +-- dedicated DartSshServerClient / SSH socket / JSONL exec
                                                                     +-- OpenCodeAgentClient
                                                                           +-- dedicated DartSshServerClient / SSH socket
                                                                           +-- bundled bridge -> loopback OpenCode serve
              +-- platform bridges: foreground service, local notifications,
                  diagnostic logger, Android SAF file export and app update
              +-- AppUpdateController -> Gitee Release API
                                      -> app_update MethodChannel -> DownloadManager/installer
~~~

AppController 是 SSH、Agent 和工作区业务的唯一编排点；独立的 `AppUpdateController` 只管理应用自身版本、
Release 检查和系统下载/安装，不进入 profile 或会话状态。Widget 可以保留弹窗、草稿编辑和焦点等短生命周期状态，
但不能自己复制一份长期 Profile 或连接状态。连接状态通过 ServerConnectionManager.stateChanges
流回控制器，再由 AppUiState.connectionStates 按 profile 更新页面；资源采样通过独立的
serverMetricChanges 流回 AppUiState.serverMetrics，不得把采样失败写成全局连接错误。

当前页面选择逻辑：

~~~text
AppScreen.servers  -> ServerScreen
AppScreen.threads  -> ThreadListScreen
AppScreen.work     -> WorkScreen
AppScreen.agentWork -> WorkScreen（与 Work 共用页面；标题、返回方向和会话状态按子 Agent 独立处理）
AppScreen.fileManager -> FileManagerScreen
AppScreen.terminal -> TerminalScreen
~~~

AnimatedSwitcher 提供前进/返回的淡入滑入动画。Work 顶部返回按钮调用 `backToThreadList`；文件管理和
终端分别由 `closeFileManager`/`closeTerminal` 返回会话列表。系统 Back 由根 `PopScope` 处理服务器 ->
会话列表 -> Work/文件/终端的页面层级；Work 内的子 Agent 使用独立 thread、父快照栈和嵌套返回。连接、指纹
确认和需要阻断交互的操作期间由遮罩或页面状态阻止重复操作。

## 5. 当前状态模型

AppUiState 是 Flutter 展示状态，字段分为：

| 类别 | 当前字段/含义 | 真实状态 |
| --- | --- | --- |
| 服务器 | profiles、selectedProfileId、connectionStates、serverMetrics | 已使用 |
| 连接流程 | pendingFingerprint、loading、error | 已使用 |
| 页面 | screen、subAgentBackNavigation、debugModeEnabled | `screen` 与子 Agent 返回动画方向已使用；Debug 开关已连接持久化日志 |
| Agent lane | agentConnectionStates、activeAgent、activeAgentCapabilities、agentThreadLists、agentModelLists、agentLoadingStates | Codex/OpenCode 均已使用并按 lane 隔离 |
| 当前会话 | threads、activeThread、timeline、olderTurnsCursor、activeTurnId、running、turnTiming、aggregateDiff | 两种 Agent 共用 Work 链路；具体操作按 capability 开关 |
| 会话控制 | models、selectedModel、selectedEffort、approvalMode、sandbox、approval、approvalQueue、activeGoal | 两种 Agent 共用；模型和 effort 可在当前会话独立选择，目标等能力按 Agent 隐藏 |
| 草稿/附件/上下文 | composerDraft、attachments、attachmentUploading、composerClearNonce、tokenUsage | 已使用；待发附件只属于当前活动会话，不长期持久化 |
| 工作区 | workspacePickerVisible、workspaceLoading、workspaceCurrentPath、workspaceParentPath、workspaceDirectories、workspaceError | 已接入首次提示和手动目录浏览 |
| 文件管理 | fileManagerProfileId、fileManagerLoading、fileManagerCurrentPath、fileManagerEntries、clipboard、operation、error | 控制器和 `FileManagerScreen` 已接入；按 profile/generation 校验 |
| 安装/全局设置 | remoteSetup*、agentSetupStates、agentSettings*、apiModelOptions* | Codex/OpenCode 探测、安装/卸载、进度弹窗、全局设置和 API 模型选项请求均已接入 |

应用自身更新不属于 `AppUiState`：`appUpdateProvider` 持有独立 `AppUpdateState`，记录已安装版本、检查中、
可用 Release、是否自动提示和 DownloadManager 状态。不要把它混入某个服务器 profile，也不要把远程
Codex/OpenCode runtime 安装状态与手机 APK 更新状态混为一谈。

ServerProfile 当前保存名称、主机、端口、用户名、密码/私钥、指纹、工作目录、代理、权限模式、
`remoteCommand` 和 Agent 偏好。新增字段必须有默认值并保持旧 JSON 可解析。`AgentCapabilities` 描述
adapter 可以承载的协议能力，不代表所有 Agent 支持相同操作；默认 factory 当前分别创建
`CodexAgentClient` 和 `OpenCodeAgentClient`。Codex 的 `subAgents` 同时控制协作活动投影和独立 child
thread 导航；OpenCode 支持模型、两种 API 协议、effort、审批、重命名、停止、steer、压缩和全局设置，
但 rollback、review、thread goals、subagents 和 archive capability 当前关闭，UI 必须据此隐藏操作。

`StoredProfiles` 已持久化草稿、会话模型/思考强度偏好和回合计时，键统一为：

~~~text
profileId + NUL + stable Agent key + NUL + threadId
~~~

时间线正文、审批队列和 TokenUsage 不写入长期存储。任何新增会话级数据必须先确定隔离键，不能退化
成所有服务器和会话共用的全局单值。

## 6. Profile 持久化和迁移

SecureProfileStore 的关键行为：

1. 读取加密键 profiles_v2；解析失败降级为空配置并保留错误边界。
2. 若没有 v2，调用 Android MethodChannel top.asdb.agent/legacy 读取当前包内旧格式 profiles_v1。
3. 成功解析后写入 v2，并写迁移标记 profiles_v1_migration_complete=1，再清理旧值。
4. 每次读写都执行 normalizeStoredProfiles：去重 ID、补默认名称/用户名、限制端口、限制草稿和
   复合键数量，并保留有效的 selected profile。

Android 端只负责旧 EncryptedSharedPreferences 的读写桥接；Flutter 端负责 JSON 解码和新格式保存。
不要让新业务继续直接读取旧 Kotlin Preference 名称。

SSH 主机连接身份包括 host、port、username、认证方式、密码/私钥和指纹；这些字段变化时
`ServerConnectionManager` 替换客户端，`AppController` 清理该 profile 的缓存、草稿、会话偏好和完成
计时。Agent lane 在此基础上还把 `remoteCommand` 纳入身份，因此启动命令变化会替换对应的
`profileId + AgentKind` lane。名称、代理、workspace 等展示/运行参数不会单独替换 SSH 客户端；其中
workspace 会在启动命令和 turn 参数中使用；Profile 的 `proxyUrl` 用于安装/下载流程，Codex 全局配置页的
代理则写入远程 `codex-remote.env` 并由 managed wrapper 在启动前加载。
删除 Profile 必须同时删除其 SSH/Agent 连接和所有 profile 前缀数据，不能影响其他服务器。

## 7. SSH 连接生命周期

### 7.1 指纹和认证

连接分两步：

1. probeFingerprint 建立短暂 SSH socket，拒绝 host key 但捕获规范化的 SHA256: 指纹。
2. 用户在不可绕过的对话框核对后，保存指纹并执行正式连接；正式连接只接受完全匹配的指纹。

主机或端口改变会清空旧指纹。不能为了提高成功率自动接受未知主机，也不能在不同功能中复制一套
宽松的 SSH 配置。默认用户名归一化为 root，但生产环境仍推荐非 root 账户。

### 7.2 多服务器和 generation

ServerConnectionManager 为每个 profile 保存：

- 一个 RemoteServerClient；
- 一个 Lock，串行化该服务器的探测、连接和断开；
- 一个 generation，丢弃旧连接、旧关闭回调和配置替换后的异步结果。
- 至多一个进行中的资源采样请求；同一 profile 的重叠刷新复用该请求。

不同 profile 可以同时连接。选择 B 不会断开 A；断开 A 只改变 A 的状态。`ConnectionPhase` 枚举包含
disconnected、probing、connecting、installing、connected、failed；当前 SSH/Agent 连接使用除
installing 外的阶段，Agent 运行时安装和卸载使用 installing。

### 7.3 Dart SSH 客户端

DartSshServerClient 使用 dartssh2：

- 密码认证或 SSHKeyPair.fromPem 私钥认证；私钥密码只在连接调用内存中使用。
- Android 前台 Service 每 10 秒触发一次 SSH keepalive；握手/认证有超时，pending socket 可取消。
- host key 回调执行规范化的 SHA256 严格比较。
- run() 为独立 exec channel 收集 stdout/stderr，有最大输出字节数和超时，避免无界拼接导致 OOM。
- RemoteServerImageClient 用 SFTP 读取绝对路径图片，默认最大 20 MiB；读取前校验长度和完整性。
- RemoteServerAttachmentClient 将不超过 20 MiB 的附件分块写入 `$HOME/.codex-mobile/uploads`，失败时
  尽力删除半成品；`ServerConnectionManager` 在返回路径前再次检查 profile 身份和 generation。
- RemoteServerDirectoryClient 用 SFTP `realpath` 和 `stat` 确认目录，流式扫描最多 2000 个协议条目，
  过滤点目录、非目录和异常名称，稳定排序后返回绝对 current/parent/children；请求前后校验 profile
  身份、client 和 generation，断开或切换身份后的旧结果不得写回。
- RemoteServerFileClient 只接受最长 4096 字符的绝对路径；SFTP `stat(..., followLink: false)` 后拒绝目录、
  符号链接和特殊文件，默认最多 2 GiB，并以 64 KiB 分块顺序写给调用方。每个分块前后都检查 SSH
  profile 身份和 generation，断开、重连或配置替换会中止下载。
- disconnect/close 会同时清理已认证客户端、pending client 和 pending socket。

AppController 当前把 SSH 主机通道用于指纹、登录、资源采样、远程图片读取、附件上传、终端 PTY 和远程
文件管理；每个 Codex/OpenCode Agent lane 另建专用 `DartSshServerClient`。OpenCode 在该 transport 上打开
无 PTY bridge exec；Codex 优先转发远端私有 Unix socket，无法使用时回退到无 PTY stdio exec。这个边界与
旧版 JSch 实现一致，Host 指标、SFTP、PTY 和心跳异常不能直接关闭正在工作的 Agent turn。Composer 通过系统 picker
读取本地图片/文件，上传到当前 profile 的 SFTP 目录后形成待发项；控制器在每次结果写回前校验活动
`profileId + AgentKind + threadId`。远程文件下载不把完整文件载入 Dart 内存，而是通过
`top.asdb.agent/file_export` MethodChannel 逐块写入 Android `ACTION_CREATE_DOCUMENT` 返回的 URI；
取消、写入失败或未完成会尽力关闭并删除半成品。长时间安装通过独立流式 `sh -s` capability
逐行回传进度；脚本正文和代理不会进入 SSH 命令参数。

### 7.4 服务器资源采样

server_metrics.dart 通过一个最长 15 秒、最大输出 64 KiB 的 SSH exec 读取 Linux /proc 和 df：CPU 与
默认路由网卡连续采样 1 秒，内存使用 MemAvailable，磁盘读取根文件系统。协议行为固定为：

~~~text
CODEX_METRICS|cpu|memory|disk|memoryTotalKiB|memoryUsedKiB|cores|
diskTotalKiB|diskUsedKiB|downloadBytesPerSecond|uploadBytesPerSecond
~~~

AppRoot 仅在 App 位于前台且当前页面是服务器列表或会话列表时轮询：服务器列表立即刷新所有已连接
profile，随后每 10 秒刷新；会话列表只刷新当前 profile。进入 Work 页面或切到后台后停止计时器。
断开、删除、掉线、关闭或连接身份变化会清除对应指标；旧 client/generation 的迟到结果必须丢弃。
采样失败保留 SSH connected 状态，只在该 profile 的 ServerMetrics.error 中记录简短原因。

### 7.5 SSH 终端（当前实现）

`TerminalManager` 为每个 `profileId` 维护独立的交互式 PTY。它复用已认证的主机连接，但为终端打开独立
`SSHSession.shell`，设置 `xterm-256color`，并对列/行、输入块、输出历史和事件缓冲设上限。每个 session
带 generation 和连接身份校验；服务器断开、Profile 身份变化或显式关闭会使旧 channel 失效，迟到输出不得
写入新终端。隐藏终端只隐藏页面并保留 PTY，关闭终端才释放 channel；用户可在断开/失败状态重试。
`TerminalScreen` 使用 xterm widget 恢复 bounded scrollback，终端 channel 不与 Codex JSONL、metrics 或
SFTP stdout 混用。

### 7.6 SFTP 文件管理（当前实现）

`FileManagerScreen` 通过当前 SSH profile 的 SFTP 能力浏览目录和文件，并支持多选、上级目录、上传、下载、
重命名、删除确认、复制/剪切/粘贴（服务端复制/移动）。路径、文件名、大小和条目数量均有边界，目录/文件/
符号链接/特殊文件按类型处理；所有异步列表和操作按 profile、连接身份与 request id 校验，切换服务器或断开
不会把旧结果写回当前页面。下载经 Android `ACTION_CREATE_DOCUMENT` 和 `file_export` MethodChannel 分块
写入，失败/取消会清理半成品；文件管理是独立页面，不是 `ThreadListScreen` 的占位回退。

## 8. 当前 UI 行为

### 8.1 ServerScreen

- 首屏是服务器列表；没有 Profile 时显示添加入口。
- 每行显示钥匙图标、固定位置的连接状态点、服务器名、用户/连接状态和设置图标。
- 未连接点击行先询问，确认后探测指纹；已连接点击行进入真实会话列表；断开按钮需二次确认。
- 连接/探测时显示全屏半透明转圈，阻止其他操作；遮罩只绑定 SSH 主连接阶段，不会因 Agent
  加载或成功后的过渡状态残留，成功后直接切换页面。
- 设置编辑支持名称、host、port、用户名、密码/私钥、私钥密码、指纹和工作目录等表单；私钥文件
  读取限制为 1 MiB，输入页使用 imePadding/可滚动布局。
- Codex/Agent 标题连续点击 10 次开启 `debugModeEnabled` 并持久化 Debug 日志开关；Debug 日志入口支持
  预览、选择性复制、清空、脱敏导出和系统分享，关闭 Debug 会停止普通事件记录但仍保留崩溃记录。
- 顶部版本区域显示当前 `PackageInfo` 版本；启动后自动检查 Gitee 稳定 Release，检查中显示小转圈，发现
  更新显示绿色状态点。点击版本区域可手动检查或重开更新弹窗，网络/格式错误只显示短提示，不影响服务器连接。
- https://lowapi.asdb.top 通过 url_launcher 交给系统浏览器，不能改成内嵌 WebView。
- 每个已连接服务器显示 CPU、内存、磁盘和上下行合计网速；指标位置在无数据时保持稳定，-- 表示尚无
  有效采样，不代表服务器返回了零值。

### 8.2 ThreadListScreen（Agent 会话列表）

当前显示服务器标题、当前服务器的真实资源指标、Codex/OpenCode 分段控件、搜索、刷新和新建会话。
SSH 已连接后页面按需启动当前 Agent；Codex 或 OpenCode 完成握手后显示对应 adapter 的真实
`thread/list` 会话，搜索（350 ms 防抖）和刷新会请求远端，运行中的会话显示固定尺寸转圈。点击会话
进入共享 Work 页面；终端图标打开独立 SSH PTY，齿轮菜单在当前 Agent 已连接时提供“选择工作目录”、
全局配置和文件管理。两种 Agent 的连接、列表、模型和错误状态按 `profileId + AgentKind` 隔离。
顶部操作顺序与原版一致：终端、刷新、新建会话、设置、切换服务器；设置和切换服务器分别使用独立
弹窗，服务器弹窗显示连接状态、用户名/地址、当前选中标记和“管理服务器”入口。Agent 选择器使用
状态圆点和绿色选中边框，任务列表标题显示“最近任务/搜索结果”和当前数量；会话行显示终端图标、
相对时间、预览、工作目录和来源。
如果远程 Agent 正在首次安装，最小化安装弹窗不会停止任务；对应的 Codex/OpenCode 分段按钮显示独立
总体进度条和百分比，点击当前进度会恢复该 lane 的安装弹窗，不会重复启动下载。
点击 CPU、内存、磁盘或网络指标会显示同一个持久 Tooltip，包含 CPU 核心数和占比、内存/磁盘已用与
总量，以及上下行速度。

工作目录提示只在当前 Profile 的当前 Agent 首次成功连接后处理，单纯 SSH 登录或失败的 Agent 连接
不能消费提示标记。控制器在显示前立即持久化 `workspacePromptShown=true`；因此“稍后”、遮罩、系统
Back、目录读取失败或随后断线都不会在下次自动重弹，但齿轮菜单仍可手动打开。已保存 workspace 时
不弹窗但同样消费标记。同连接身份保存旧表单时必须保留已经为 true 的标记。浏览请求按递增 request
ID、profile、Agent、连接身份和 generation 校验；连续浏览只采用最后结果，切服务器/Agent、返回列表、
断开、删除和身份替换都会关闭弹窗并使旧结果失效。加载时只禁用确认，目录导航、“稍后”、遮罩和
Back 仍可操作；确认保存的是当前展示路径，不是某个目录行。

会话列表消费 `agentThreadLists[profileId + AgentKind]`，并通过 Agent 中立的可选分页契约消费远端
`nextCursor`。接近列表底部时自动加载下一页，控制器按 lane 保存游标、合并去重并丢弃刷新/搜索/断线后
的过期结果；Agent lane 意外断开时页面保留该 lane 的上次成功快照，但连接依赖的打开、刷新、新建等操作
保持禁用，避免回到前台时误显示“0 个任务”。`active/running/working/inProgress` 等运行态统一显示转圈；不支持分页的轻量适配器仍可只实现基础列表契约。不要在此页面临时实现一套只支持 Codex
的会话状态；新增状态必须复用 Agent 中立契约，并按 profileId + AgentKind + threadId 隔离。

从服务器列表返回已连接服务器时，如果当前 Agent lane 仍然连接且已有线程、模型快照，会直接复用缓存，
不会重复运行时探测、Agent 握手或 `thread/list`；断线恢复同样保留已有列表，只有没有任何快照的首次加载、
显式刷新和搜索变更才请求 `thread/list`。

齿轮菜单包含“选择工作目录”、“配置 Codex/OpenCode”和“文件管理”三项。配置项只在当前 Agent 已连接且声明
`globalSettings` capability 时可用；打开后先读取远程实际配置。保存会二次确认、更新该服务器该 Agent
的 `preferredModel/preferredEffort/testModel`，然后断开整台服务器；测试只发起真实最小模型请求，不会
保存或断线。

### 8.3 WorkScreen（Agent 对话）

Work 页面是 Codex/OpenCode 共用的实际对话切片，具体操作由当前 `AgentCapabilities` 控制：

- 当前 Flutter 展示以旧 Compose `WorkScreen.kt` 的实际工作布局为视觉基线：顶部为返回、会话标题、工作目录副标题和更多菜单；
  助手 Markdown 直接铺在背景上，用户输入使用克制的表面容器；普通思考/计划是带搜索图标和折叠箭头的单行，命令是带终端图标、
  完成状态和展开箭头的独立卡片，图片工具统一使用双眼睛图标、`查看了图片` 和单行远程路径。不要把所有时间线条目重新套成同一种消息卡片。
- Composer 保持固定底部的一体化边框区域：输入框上方可显示附件，底部顺序固定为加号、更多、权限、上下文圆环、模型/思考强度、
  发送或停止圆形按钮。输入框最小高度稳定在约 72 dp，只有 Composer 外层 1 dp 边框，内部编辑区不得继承全局输入框填充或焦点边框；
  加号和更多按钮均固定 36 dp，权限按钮高 36 dp、最宽 64 dp，不能由 Material 默认 48 dp 点击区挤压右侧模型文字。IME 通过
  viewInsets 与时间线同帧移动，不能让键盘盖住输入框或让正文滞后。顶部更多菜单使用旧版 48 dp 行高和填充图标；Debug 日志项仅在
  Debug 模式开启时显示，并与普通会话操作之间保留分隔线。
- 当用户滚离最新消息时，跳转按钮居中悬浮在时间线和 Composer 之间；只在确实存在更新内容时显示，不能固定在右下角遮住命令卡片。

- 打开会话先从 `ThreadSessionCache` 显示最近快照，再以 `thread/resume` 校准；请求按
  `profileId + AgentKind + threadId` 去重，超时可保留过期快照作为回退；
- Composer 发送时先插入 optimistic user row，`turn/start` 返回稳定 turn ID 后合并；活动回合中再次
  发送且 Agent 支持时走 `turn/steer`，运行中显示停止图标且停止需要确认；事件 reducer 会合并消息
  delta、命令输出、文件修改、思考/计划和完成状态；
- 审批面板支持命令、文件修改、权限和 user-input 问题，可选择答案或输入秘密字段；权限 sheet 提供
  请求批准、替我审批、完全访问，启用完全访问需要二次确认；审批队列按
  `profileId + AgentKind + threadId` 分桶，迟到的其他会话请求不会覆盖当前面板，旧适配器缺少
  `threadId` 时仅使用 lane 级兼容回退；
- 模型面板按 `model.model` 发送真实 wire 名称，并兼容用 catalog `id` 恢复选中项；选择模型后面板保持
  打开，当前模型声明 efforts 且 Agent 支持时显示独立思考强度 chips。模型和 effort 写入持久化的
  thread preference；模型管理页支持新增、编辑、删除自定义模型，以及隐藏/恢复远端模型。目录按
  profile + Agent 合并远端模型与本地定义，恢复仍标记为 custom 的远端条目以便继续编辑。草稿按同一
  复合键 260 ms 防抖保存并在离开或父子会话切换前 flush；
- 打开模型管理页时，已连接且支持全局设置的 Agent 会读取当前远端配置，并经该服务器请求兼容
  `/models`；结果按 profile + Agent + request id + connection generation 校验后写入 `apiModelOptions*`。
  编辑器可按 ID/显示名筛选有限选项，选择后只回填模型 ID、空显示名和正值 token 上限，不会改写用户
  已填字段或持久化 API key；
- 顶部历史分页复用旧 Compose 的释放触发状态机：只读取列表顶部的真实 overscroll，不累计重复通知；
  手势可以从列表中间开始并在到达顶部后继续下拉，回拉到阈值以内会取消 armed，只有抬手时仍越过阈值
  才调用 cursor 分页。时间线使用带固定尾部 center sliver 的 `CustomScrollView`，所有消息向上增长，
  底部原点固定为 `pixels=0`，不依赖懒列表的估算 extent 做首屏或分页位置补偿；“正在加载更多...”作为
  覆盖层显示，不参与滚动几何。不满一屏时按消息 sliver 的真实高度补足尾部空白，使内容从顶部开始；
  内容超过一屏后空白归零并继续保持最新消息位于底部。阅读旧消息时显示回到底部箭头；
- 上下文圆环只按服务器返回的 `last.total / modelContextWindow` 计算，中心显示已用百分比，点击显示已用/剩余 tokens；
  圆环和模型名称组成靠右的弹性区域，模型变长时向权限按钮方向扩展并单行缩放，不能因固定空白提前省略；有效
  TokenUsage 在 lane cache 中保留，返回同一会话可立即恢复；未知窗口显示 `?`，不猜比例；
- Markdown 可选择文本，解析出的 HTTP/HTTPS Markdown link 和紧邻中文标点的裸 URL 显示蓝色，点击先确认
  后交给系统浏览器；标准 Markdown link 只显示 label，不把目标 URL 复制到正文；
- `[名称](/absolute/server/path)` 会转换成仅 App 内部识别的安全链接；PNG/JPG/WebP/GIF/BMP 路径点击后
  直接使用 Work 页图片查看器预览，其他文件才通过系统保存位置选择器流式下载。内部链接不会交给浏览器；
  同一 Work 页面一次只允许一个远程文件下载；
  图片工具统一显示“查看了图片”，点击通过 SFTP 预览，长按确认后用系统保存入口写入手机；
- 对声明 `subAgents` 的 Agent，时间线把相邻同 turn 的子 Agent 活动合并为紧凑标签，逐个显示稳定身份
  图标、名称和状态；运行状态转圈，
  完成/中断/失败等终态不会被同 turn 的迟到 activity 恢复。存在有效 thread ID 时点击进入 `AppScreen.agentWork`，
  使用真实 `thread/resume`，而没有 thread ID 的活动只显示不可点击状态；父子会话使用独立缓存和设置。
- Composer 的附件菜单支持调用系统相机拍照，以及多选图片或文件；最多保留 8 项、一次选择总计不超过 40 MiB；单个普通附件
  不超过 20 MiB，内联文本不超过 512 KiB。上传时显示无百分比的进度条，成功项显示可移除 chip，
  发送时可只有附件而没有正文。离开会话会清空待发项；`turn/start` 失败会恢复草稿和待发附件，并移除
  尚未得到服务器确认的 optimistic user row。

### 8.4 FileManagerScreen（远程文件）

文件管理从会话列表设置菜单进入，仅使用当前已连接 SSH profile。页面显示当前路径、目录条目、权限/大小/修改
时间，并支持上级目录、刷新、多选、上传、下载、重命名、删除确认和复制/剪切/粘贴。上传使用系统文件 picker
并顺序流式发送；下载使用 Android SAF 保存位置选择器和分块导出。操作期间显示进度并阻止冲突操作，切换服务器、
断开或返回会使进行中的请求失效。

### 8.5 TerminalScreen（远程终端）

会话列表的终端图标只在 SSH 已连接时启用。页面显示独立 xterm PTY，支持键盘输入、resize、输出历史、重试、
隐藏（保留连接）和显式关闭（释放连接）；Agent JSONL 通道不受终端输入输出影响。

## 9. 当前 Agent 层和验收边界

Agent 中立层、Codex/OpenCode adapter、两种托管运行时、共享回合状态机、Work UI 和 Codex 子 Agent
独立导航已经落地。本节同时记录当前代码事实和仍需真实服务器/设备验证的边界；全局设置、终端、文件
管理、后台保护和 Debug 日志不再属于代码迁移缺口，但仍需端到端回归。

### 9.1 连接和能力

~~~text
ServerConnectionManager (profileId, SSH host session)
          |
AgentConnectionManager (profileId + AgentKind)
          |
RemoteAgentClient
   +------+----------------+
   |                       |
Codex adapter         OpenCode adapter/bridge
   |                       |
shared session/event/cache contract
~~~

`RemoteAgentClient` 当前定义连接、能力、模型、会话列表/恢复/分页和关闭；回合、新建、审批和会话
变更通过可选 interface 扩展。`AgentCapabilities` 决定 UI 是否显示操作。OpenCode 特有逻辑只能留在
adapter/bridge，不能复制共享 UI 和状态机；当前默认 factory 对 Codex 返回 `CodexAgentClient`，对
OpenCode 返回 `OpenCodeAgentClient`。

每个 Agent lane 由 `AgentConnectionManager` 以 `profileId + AgentKind` 独立持有 client、锁、事件
subscription 和 generation。它只在 SSH 主机会话已连接后启动；生产 adapter 随后持有自己的 SSH
transport。Host 意外断开时独立 Agent 保持运行，Host 单独恢复；用户明确断开、Profile 身份改变或 lane
被替换时才使 Agent 请求失效并关闭专用 transport。OpenCode 使用独立无 PTY exec，Codex 使用独立 SSH
Unix-socket forward（不支持时回退 exec），均不与 metrics/SFTP 共用 transport 或 stdout。

### 9.2 Codex JSON-RPC/JSONL（当前实现）

Codex adapter 从 Profile 的 stdio `remoteCommand` 派生稳定 key，读取
`$HOME/.codex/codex-remote.env`、可选切换 workspace，并通过 `nohup`/`setsid` 启动仅监听远端用户私有
Unix socket 的 app-server。SSH 使用 `direct-streamlocal@openssh.com` 转发该 socket，客户端执行 RFC 6455
握手，把 JSONL 行映射为带 mask 的 WebSocket text frame，并处理分片、ping/pong 和 close。若 CLI 或 SSH
服务端不支持该路径，会清理已启动进程并回退 `buildCodexAppServerCommand` 的 stdio exec。连接顺序是
initialize -> initialized；普通请求默认 120 秒，会话请求默认 180 秒，单条消息最大 8 MiB，stderr
单行最大 8 KiB。

意外 SSH 断线只销毁 forward 和手机侧 transport，不执行远端 stop command；远端 app-server 与 turn 保留，
重连后复用同一 socket 并 `thread/resume`。用户显式断开时，`AgentConnectionManager` 先调用 durable cleanup，
再关闭 Agent 和 Host SSH。Unix socket、PID、启动锁和有界日志位于远端 `XDG_RUNTIME_DIR` 或用户专属 `/tmp`
目录，PID 清理会核对 `/proc/<pid>/cmdline` 中的 socket 路径，避免误杀复用 PID。

JSONL 写入只把完整行加入当前 SSH session 的 stdin，并由 `_writeTail` 串行化；不能在 channel 上传
循环并发运行时调用 `SSHSession.flush()`，因为 dartssh2 会暂时绑定底层 Socket sink，迟到的 channel
数据会触发 `StreamSink is bound to a stream`。Agent 断开先销毁自己的 exec channel，再关闭专用 SSH；
异常断线时销毁操作必须幂等并吞掉已关闭 transport 的 EOF/close 错误。

当前 RPC 覆盖：model/list、thread/list、thread/start、thread/resume、thread/turns/list、turn/start、
turn/interrupt、审批/用户输入响应、thread/compact/start、thread/rollback、thread/archive、
thread/name/set、review/start 和 thread/goal/get|set|clear。协议层保持 thread、turn、item 三层概念；
`codex_event_reducer.dart` 幂等合并 started/delta/completed、乐观用户消息、token usage、目标和状态更新；
用户消息的空 `item/started` 会先接管最近的本地乐观行，再由同 item id 的 completed 内容补全，不能短暂
显示两条相同输入。
未知通知保留但可忽略；未知 server request 回复 JSON-RPC -32601，避免远端永久等待。

固定 Codex 版本变化前必须核对官方 schema、本地 `codex-manual-markdown (8)` 资料和协议测试，不能靠
放宽动态 Map 或无限提高响应上限兼容未知格式。

### 9.3 OpenCode adapter/bridge（当前实现）

`OpenCodeAgentClient` 继承 `CodexAgentClient`，复用逐行 JSON、pending RPC、连接 generation、事件 reducer
和共享 Work 状态机，只把 OpenCode 的启动、运行时、配置及模型语义留在 adapter。连接时从 App asset
加载 bridge，以安全 shell quoting 传递 workspace，并启动托管的
`~/.local/bin/codex-remote-opencode-bridge`；默认 factory 已直接创建该客户端，不再经过占位实现。

bridge 在远端选择随机端口，只让固定版本 OpenCode `serve` 监听 `127.0.0.1`，并为内部 REST/SSE 请求
生成随机 Basic Auth。它把 OpenCode 的 Provider、Session、Message、Permission 和 Question 数据映射成
共享 JSONL，当前覆盖 model/list、thread/list/start/resume/read、turn/start/steer/interrupt、
thread/name/set、thread/compact/start、审批/用户输入、TokenUsage、agent/settings/read|write 和
agent/models/sync。`turn/start` 在异步 prompt 前立即返回稳定的 synthetic turn ID；同一活动回合的
`turn/steer` 复用该身份再次发起异步 prompt，后续 user message ID 不能覆盖活动 turn ID。
`thread/resume` 将恢复出的 turns 投影为 `initialTurnsPage`，遵守请求的 `limit`、`sortDirection` 和
`full/summary/notLoaded` items view，使客户端的大历史四级降级能够实际缩小 bridge 响应。

`AgentCapabilities.openCode` 当前支持模型、Chat Completions/Responses 两种 API 协议、思考强度、审批、
重命名、停止、steer、压缩和全局设置；rollback、review、thread goals、subagents 和 archive 关闭。
bridge 即使保留兼容 RPC，也不能绕过 capability 在 UI 暴露未承诺的功能。

### 9.4 会话缓存、分页和上下文（当前实现与缺口）

`AppController._openThread` 先显示 lane 内的缓存快照，再发起 `thread/resume`；同一复合 thread key 的
重复打开复用进行中的 Future。`ThreadSessionCache` 默认每 lane 最多 8 个 transcript、TTL 30 分钟、
约 2 MiB 字符权重，并额外保留有限的有效 TokenUsage。更早历史通过 cursor 获取，按
`(turnId, kind, id)` 复合身份去重后前插并更新缓存。

resume 期间同 generation 的实时通知会进入有界 `ResumeNotificationBuffer`；响应携带入站
`responseSequence`，控制器先用 `reconcileResumedTimeline` 合并已缓存旧页与服务器快照，再按 wire
sequence 重放快照之后的通知。缓冲区保留终态、合并相邻 delta，并在溢出时给出诊断。客户端对超大
resume/历史响应依次尝试 `full/4 -> full/1 -> summary/1 -> notLoaded/1`，避免只提高内存和 timeout。
子 Agent resume 仍会校验返回的 thread ID，错误 ID 连续重试一次后拒绝污染当前页面；导航 generation
也会丢弃切页后的迟到结果。流式 delta、缓冲溢出、降级响应和列表分页游标失效仍必须重点回归。

实时事件只有在 `profileId + AgentKind` 匹配、当前页面是 `work/agentWork` 且 threadId 匹配可见会话时
才写入前台状态；会话列表、其他会话、父子会话切换和其他 lane 的事件会以该 thread 的 stale cache 或
列表行为基线，在独立 `ThreadSessionCache` 中继续归并 timeline、状态、cursor 和 TokenUsage。嵌套在
`turn/thread` 对象中的 threadId 会先规范化再进入 reducer/resume buffer，当前 lane 的 `threads` 与
`agentThreadLists` 同步更新。这样返回列表后服务器继续输出，再进入同一会话时可立即显示最新缓存，且
不会把后台会话事件写进当前 Work 页面。

OpenCode bridge 已按上述稳定 turn 身份处理 `turn/start` 和 `turn/steer`；相关 Node/Flutter 回归测试是
代码门禁，但不能替代真实 OpenCode Provider、长时流式回合、审批和断线恢复验收。旧 Kotlin bridge
仍只作为历史参考，不能替代当前 Flutter asset 的测试。

模型、思考强度、输入草稿、活动 thread、TokenUsage 和缓存键必须至少包含：

~~~text
profileId + AgentKind + threadId
~~~

审批队列与其他会话级数据一致，按 `profileId + AgentKind + threadId` 分桶；Flutter 使用
`AppController._pendingApprovalsByThread`，Kotlin 使用对应的 `pendingApprovalsByThread`。回答时同时校验
requestId 和 threadId，切换会话、迟到事件、断线和归档只影响对应分桶。

### 9.5 Work UI、IME 和子 Agent（当前实现与缺口）

- Composer 用 viewInsets 驱动 170 ms `AnimatedPadding`，时间线在键盘视口缩小时直接 jump 到底部；
  FocusNode 没有 autofocus，Work 页面在生命周期进入 `inactive/paused/hidden/detached` 时主动 unfocus 并
  请求隐藏系统输入法，避免切回前台自动弹键盘。键盘动画与消息同帧移动仍需真机验证。
- 空闲发送、运行停止、停止确认、权限模式、审批、上下文详情、回到底部、Markdown 链接确认、图片保存、
  当前会话独立 effort 选择和自定义模型管理均已接入。
- 子 Agent 事件先由 `SubAgentPresentation` 合并为相邻同 turn 的渲染行，再以紧凑标签显示。标签状态按
  `pendingInit/running/completed/interrupted/failed/shutdown/notFound` 和 activity 映射；同 turn 终态具有
  单向保护，后续 turn 才允许重新激活。有效 thread ID 的标签调用 `openSubAgentThread`，无 ID 的活动不会
  伪造会话入口。
- `openSubAgentThread` 在按 `profileId + AgentKind` 隔离的 `ProfileScopedBackStack` 中保存有界
  `_SessionSnapshot`（时间线、草稿、模型/effort、上下文用量、附件和工作区状态），随后执行真实
  `thread/resume`。最多嵌套 8 层；返回先显示缓存父快照，再等 resume 成功后弹栈。重复返回在 pending 状态幂等，
  父 resume 失败会恢复子页并保留栈以便重试；断线时允许本地返回并提示重连。每次导航递增 generation，
  切服务器/Agent、断开、删除、普通打开或返回列表都会清理栈，迟到回调不能改写新页面。
- 父子切换前会 flush 260 ms 防抖草稿，模型、effort 和 TokenUsage 使用 `profileId + AgentKind + threadId`
  独立缓存，避免子会话覆盖父会话设置。
- 输入附件已串起系统 picker、有界本地读取、SFTP 上传、无百分比上传中状态、待发 chip、移除和协议
  编码。上传结果有 profile/thread guard，部分文件失败时保留已成功项并显示首个错误；发送失败会恢复
  草稿和附件，避免用户重新选择文件。

### 9.6 远程安装和全局设置

Codex 运行时已经形成完整链路：`RemoteBootstrap.probeScript` 在已认证 SSH 主机通道中探测 Linux、
架构、libc、HOME、managed/system Codex 版本和路径，以及 sh、tar、sha256sum、flock、`setsid --wait`
和 curl/wget。精确匹配 `codex-cli 0.146.0` 时优先复用 managed 路径，其次复用系统 Codex；Profile
使用自定义 `remoteCommand` 时尊重用户配置并跳过托管探测。

缺少兼容版本时，安装 `Node 22.17.0 + Codex 0.146.0` 到当前 SSH 用户的
`~/.local/share/codex-remote`，启动器为 `~/.local/bin/codex-remote`。脚本使用非阻塞 flock、300 MB
空间检查、Node SHA-256、临时 release、失败清理和原子 wrapper 替换；不使用 sudo，不修改系统
Node/Codex、VS Code、`~/.codex` 账户/配置或工作区。命令固定为
`CODEX_REMOTE_SSH_PID=$PPID setsid --wait sh -s`，脚本经 stdin 发送，超时 30 分钟，SSH 消失时远端
watchdog 终止安装进程组。

OpenCode 使用独立的 `OpenCodeBootstrap` 探测与安装链路，固定 `opencode-ai 1.18.11` 和
`jsonc-parser 3.3.1`，复用固定 Node `22.17.0`。安装先准备共享 Node，再通过国内 npm registry 安装
OpenCode 和 bridge；HTTP/HTTPS 下载代理只注入安装进程。安装脚本按远端架构明确选择唯一 glibc 平台包：
ARM64 使用 `opencode-linux-arm64`，x64 根据 AVX2 使用普通版或 baseline，并禁用 `opencode-ai`
postinstall 的自动 musl 兜底。这样 Debian PRoot 不会在首个下载失败后转而报告误导性的 musl 不兼容错误，
且所有 npm 元数据和平台二进制仍优先来自 `registry.npmmirror.com`。只有 CLI 版本和 App 打包 bridge source
的 SHA-256 同时匹配才复用已有运行时，防止新版 App 误连旧 bridge。托管路径为：

~~~text
$HOME/.local/share/codex-remote/opencode
$HOME/.local/bin/codex-remote-opencode-bridge
~~~

进度协议为 `::progress::<overall>|<download>|<message>|<detail>`；UI 分开显示总体与当前下载进度，
最小化后会将总体进度保留在会话页对应 Agent 按钮中，点击后恢复原弹窗。
同一服务器安装由 `AgentConnectionManager` 的 profile 级锁串行化，每个 `profileId + AgentKind` 独立
保存弹窗状态。安装中关闭只最小化，任务继续受前台 Service 保护；失败保留弹窗并允许用户修改代理
后重试。成功后必须再次探测，确认兼容命令，再自动连接和加载模型/会话。

Codex/OpenCode 全局设置的“测试连接”直接在已连接的远端 Linux 内通过 curl 请求模型 API，不读取 Android
网络栈。失败反馈使用高对比度文字，并区分缺少密钥/模型、DNS、端口连接、超时、TLS、鉴权和 HTTP 错误；
诊断日志只记录字段是否填写和归一化原因码，不记录 API 密钥、模型 URL、代理 URL 或模型名。
保存成功后只重启当前 Agent lane 以加载新配置，保留 SSH、本机 Linux 和同服务器的其他 Agent。

探测、安装和卸载的长时 SSH 等待不得持有 Agent lane 的连接锁；该锁只保护开始/收尾状态切换，运行中
用 generation 丢弃过期进度和结果。请求入队时同时绑定 Agent generation，以及包含 SSH 连接身份、
client 和 generation 的 connection lease；排队期间修改主机、断开或重连后不得再启动旧任务。profile
级运行时锁保留到 manager 销毁，删除后用相同 ID 重新注册也不能与旧脚本并发。显式断开先关闭主机
SSH，再清理 Agent lane；同一 Agent client 的重叠断开请求复用一个 Future，不能要求 adapter 支持并发
disconnect。远端 watchdog 随后终止安装进程；连接运行时操作中的 lane 必须失败返回，不能与安装脚本
并行启动 app-server。

每台服务器可保存 HTTP/HTTPS 下载代理，只注入该次远端安装进程；宿主机构建下载仍优先使用 7890。
服务器设置的“卸载托管 Codex”当前删除 `~/.local/bin/codex-remote`、整个
`~/.local/share/codex-remote` 和 `~/.codex-mobile`，因此会一并移除共享 Node 和其中的 OpenCode 托管
目录；它会保留系统 Codex、VS Code、`~/.codex` 和工作区。“卸载托管 OpenCode”会先断开该 adapter，
只删除上述 OpenCode 子目录和 wrapper，保留共享 Node、Codex、附件暂存、`~/.codex`、VS Code 和工作区。

Codex 全局配置入口已经在 Flutter 接入，修改当前远程 Unix 用户的：

~~~text
$HOME/.codex/config.toml
$HOME/.codex/auth.json（只通过 CLI 标准输入写入 API key）
$HOME/.codex/codex-remote.env（0600，代理环境）
$HOME/.local/bin/codex-remote（managed wrapper）
~~~

读取以服务器实际配置为准，识别自定义 Provider、模型 URL、默认模型、思考强度、代理、登录状态和
真实 API key。API key 只存在设置页内存，不写入手机持久化、日志、通知或截图；未修改的回显 key 保存
时传空值，避免重复登录。保存以临时文件 + 原子替换更新配置，目录/文件权限分别为 0700/0600；脚本
固定通过可选 `RemoteServerScriptClient` 执行 `sh -s`，密钥和脚本不出现在 SSH 命令参数。保存成功后
关闭设置页并断开整台服务器，重连后生效，不修改项目 `.codex`、shell profile、其他工作区或 VS Code
扩展文件。设置页“测试”从服务器发起最小真实模型请求并显示中文成功/失败结果；测试本身不保存、不改
登录、不主动断线。

OpenCode 全局设置通过 bridge 的 `agent/settings/read` 和 `agent/settings/write` 接入，读取/修改当前远程
用户的全局 OpenCode 配置、Provider 认证和代理文件，而不是工作区配置：

~~~text
$XDG_CONFIG_HOME/opencode/opencode.jsonc 或 opencode.json
$XDG_DATA_HOME/opencode/auth.json
$XDG_CONFIG_HOME/opencode/codex-remote-proxy
~~~

未设置 XDG 目录时分别落到 `$HOME/.config/opencode` 和 `$HOME/.local/share/opencode`。bridge 保留已有
Provider，管理的 Provider ID 为 `custom-api`，并把旧 `codex-remote/` 模型引用迁移到新前缀。自定义模型
通过 `agent/models/sync` 同步模型定义和删除 tombstone；adapter 对已同步定义做连接期缓存，删除、写设置、
断线或 generation 变化都会失效缓存，迟到同步结果不能污染新连接。API `/models` 结果按当前 Provider
补全前缀后再进入共享模型目录。

真实 API 测试必须遵循所选协议：`buildTestCodexGlobalSettingsScript` 收到显式 Responses 时只请求
`/responses`，收到显式 Chat Completions 时只请求 `/chat/completions`，失败均不得偷偷切换协议。只有
Codex 未指定协议的自动模式允许 Responses 失败后回退 Chat；OpenCode 根据自定义模型保存的
`apiProtocol` 传入显式协议，未知模型默认按 Chat Completions 测试。

模型管理页获取 API 模型时沿用同一远端配置：`AppController.fetchApiModelOptions` 先读取当前
profile + Agent 的全局设置，再通过 `AgentConnectionManager` 和支持 `RemoteAgentApiModelClient` 的
adapter 在已连接 SSH 主机上执行脚本。脚本规范化 base URL 与 HTTP/HTTPS 代理，清空继承的代理环境后
仅在本次 `curl` 显式传入 `--proxy`，以 GET 请求 `${baseUrl}/models`；网络请求有连接/总时限、一次重试、
响应大小上限和分块 base64 回传。结果解析为有界、去重的 `ApiModelOption`，401/403、网络、工具缺失、
临时文件和无效响应都映射为短错误，不能覆盖已切换 profile、Agent 或 generation 的页面状态。

API key 由当前读取结果仅在内存和远端脚本 stdin 中短暂传递，不作为 SSH 命令参数、`curl` 参数、诊断字段
或持久化数据。脚本用 `mktemp` 创建 header 与响应 body 临时文件，显式 `chmod 600`，把
`Authorization: Bearer` 写入 header 文件，并用 `curl --header @file` 引用；退出、HUP、INT 或 TERM 时
trap 删除所有临时文件。代理仅限规范化的 HTTP/HTTPS 地址并只作用于这次远端 API 请求；日志只记录
provider 与 URL、key、代理是否已配置，绝不记录其实际值。

当前只接受 HTTP/HTTPS 代理。`codex_global_settings.dart` 的模板使用单次 token 渲染，避免用户值
包含占位符时二次替换；Shell fixture 覆盖 `sh -n`、临时 HOME、Provider 保留、清空默认值、权限、
密钥泄漏和 Responses/Chat 错误映射。

## 10. Android 平台桥接、后台、文件、诊断和更新（当前实现）

`MainActivity` 当前注册四个 MethodChannel。新增原生能力必须沿用有界参数、中文错误边界和主线程回调，
不能让 Widget 直接调用 Android API：

| Channel | Flutter -> Android 方法 | 职责 |
| --- | --- | --- |
| `top.asdb.agent/legacy` | `readLegacyProfiles`、`clearLegacyProfiles` | 一次性读取/清理当前包内旧加密 Profile |
| `top.asdb.agent/file_export` | `beginExport`、`writeExportChunk`、`finishExport` | 通过 SAF 选择目标并按最多 256 KiB 分块写入，失败清理半成品 |
| `top.asdb.agent/background` | `start`、`stop`、`moveToBackground` | 启停连接保护前台 Service；有连接时将根页面系统返回转换为移到后台 |
| `top.asdb.agent/app_update` | `enqueueDownload`、`queryDownload`、`installDownload` | 提交系统 APK 下载、查询字节/状态，以及申请权限或打开系统安装页 |

Android Manifest 声明网络、通知、wake lock 和 `foreground-service:dataSync` 权限。Flutter 的
`BackgroundConnectionBridge` 在任一 SSH/Agent lane 连接或回合运行时启停
`ConnectionForegroundService`；Service 创建低重要度 ongoing notification，并以有界 partial wake lock
和 Wi-Fi lock 提高进程及网络在后台的存活机会，并每 10 秒分别保活 retained Host 与 Agent transport。
Host 与 Agent 使用独立 socket，心跳请求通过各自 transport 发送，不能借 Host 指标连接写入 Agent exec。
Service 的 MethodChannel 心跳同一时刻最多允许一个请求在途；Flutter isolate 被系统暂停时只累计跳过次数，
不会排队堆积调用。Agent transport 同样合并尚未完成的 keepalive，避免回到前台时集中回放 SSH global request。
前台服务和回合完成通知都使用专用白色连接图标并声明 private 锁屏可见性，
不使用彩色启动图标作为 Android small icon。有活动连接时，服务器根页面的系统返回调用
`moveTaskToBack(true)`，不能 finish Activity；若最近任务移除等场景仍销毁 Activity，`MainActivity` 通过
`FlutterEngineCache` 保留并在下次打开时复用同一 Dart 引擎，SSH/Agent socket 因此前台服务进程存活期间
不会跟随 Activity 关闭。

为覆盖整个 App 进程被系统回收的情况，Service 使用 `START_STICKY`。Flutter 在成功连接后只把需要恢复的
Profile ID 和 Agent lane 写入原生 `SharedPreferences`，不保存密码、私钥或 Token；Service 被重建时读取这份
意图，创建无界面 FlutterEngine，并通过 `--agent-background-*` 启动参数交给 `AppController`。Dart 会在
Activity 尚未回到前台时直接执行 SSH 和 Agent 恢复，日志顺序应为
`service_start -> sticky_service_restored_flutter_engine -> background_restore_requested -> reconnect_success`。
显式断开、删除服务器、修改 SSH 连接身份或 Controller dispose 会清空恢复意图并停止 Service，避免偷偷重连。
这条机制只覆盖系统普通回收和 Service 的粘性重启；用户“强制停止”应用、设备重启、厂商禁止后台启动或系统
撤销前台服务权限时，Android 不保证重新启动 Service，SSH 仍会断开。进程死亡后不会自动恢复原 Work 页面，
但连接和 Agent 会在后台恢复，重新打开 App 后会显示已连接并可进入会话。

进程仍存活时，`AppController` 会区分“用户明确断开”和 SSH/Agent 意外关闭。成功连接后保留每台服务器及
已连接 Agent lane 的连接意图；意外关闭按 `0/1/2/5/10/30/60` 秒退避（之后每 60 秒）持续恢复，等待期
仍向 UI 投影 `connecting`，使前台 Service 和 wake lock 保持。Host 恢复时，仍存活的独立 Agent 不重启；
Agent 自己断线时才重建其专用 SSH 并恢复 lane。Codex Unix listener 使 turn 不再依赖手机 SSH channel；
恢复 Work/AgentWork 时重新 resume 可见会话以补齐断线期间状态，会话列表已有缓存时不重新加载。用户明确断开、删除服务器、修改 SSH
连接身份或 Controller dispose 会使恢复代次失效，旧异步任务不能重新建立连接。SSH transport 的异常文本
会写入状态日志；仅进程标记未清理但 `ApplicationExitInfo` 没有 crash/native crash/ANR 证据时记录为 WARN，
不能再标成 FATAL 崩溃。

`TurnCompletionNotifier` 监听非当前 lane 的回合终态，在 App 不处于前台时发送本地通知。通知 payload 携带
`profileId + AgentKind + threadId`，由稳定哈希生成 id；`TurnCompletionDeduplicator` 按
`profileId + AgentKind + threadId + turnId` 有界去重，子 Agent thread 会被 registry 过滤。点击通知时通过
`getNotificationAppLaunchDetails` 或 response callback 恢复目标并打开对应会话，随后取消该通知；通知权限、
插件初始化或厂商限制失败时只降级提醒，不影响 SSH/Agent lane。

终端入口在会话列表启用，`TerminalManager` 为每 profile 打开独立 PTY，`TerminalScreen` 负责 xterm 渲染、
输入、resize、bounded scrollback、隐藏、重试和显式关闭。文件管理入口打开独立 `FileManagerScreen`，通过
当前 SSH 的 SFTP channel 完成目录浏览、上传、下载、重命名、删除确认、复制/移动；下载经 Android SAF
分块写入并清理失败半成品。终端和文件操作不共享 Codex JSONL stdout，也不拼接 shell 路径执行文件动作。

Debug 模式由 Agent 图标连续十次点击开启。`DiagnosticLogger` 将普通运行事件按开关持久化到应用支持目录，
单文件最多约 100 KiB、最多保留 100 个文件且总量最多约 10 MiB；超限按时间删除最旧文件。FlutterError、
PlatformDispatcher 和 Zone 未捕获异常始终以 FATAL 级别记录。`DiagnosticLogBridge` 在 Android 侧捕获
Java 未捕获异常、进程异常退出线索和主线程长时间卡死（ANR 线索），并写入同一目录，所以下次启动可统一查看。
写入前会移除 ANSI、私钥、URL 凭据、Bearer/API key、password/token/secret 等敏感值，分享和附件读取时再脱敏。
诊断日志弹窗只读取当前进程正在写入的单个活动分段，不扫描或拼接历史 100 KiB 文件；历史日志仅在分享或作为附件时按需列出。
日志 sheet 和选择器支持按文件多选、预览、复制、清空和系统分享；分享只生成临时副本，不删除原日志，清空
同时删除本工具生成的临时分享文件。工作页菜单“添加崩溃 / Debug 日志”默认选中最新崩溃日志，确认后只加入
输入框附件，不会自动发送。此前为定位会话滚动问题临时加入的 `TranscriptScroll` 高频事件及其几何采样
已经撤除；当前诊断日志不再记录滚动手势、滚动范围、分页布局或加载头动画。后台连接每 10 秒执行的正常
心跳也保持静默，只记录超过 5 秒的慢心跳、超过 15 秒的投递延迟、调度跳过和连接失败。

`AppUpdateController` 从 `PackageInfo` 读取已安装版本，Android 启动时以 5 秒超时查询 Gitee Release API；
只接受非 prerelease、合法 SemVer 且包含 `Agent-<version>.apk` 或历史兼容
`CodexRemote-<version>.apk` 的 Release。响应、标签、资源名和更新日志都有大小/条数上限；Build metadata
不参与版本先后。自动提示受 SharedPreferences 中的忽略版本约束，手动点击版本区域仍可再次查看已发现更新。

下载交给 Android `DownloadManager`，目标文件名附加时间戳避免同名覆盖；Flutter 以约 1 秒节流轮询下载
字节数并展示下载中、完成、等待未知来源权限、等待系统安装和失败状态。“后台继续”只关闭弹窗，不取消
系统下载。下载版本、资源名和 `downloadId` 以受校验的 JSON 持久化；启动时会重绑仍存在的任务，已完成的
任务继续显示安装入口，失败或已安装版本会清理记录。回到前台时会重新查询处于安装/授权状态的任务；
用户取消系统安装后可重新打开安装，不会永久卡在禁用状态。查询和 APK 元数据读取在独立后台 executor，
MethodChannel 结果统一回主线程。安装前检查下载文件位于应用专属目录，并验证 `applicationId`、版本号递增
和当前 APK 的签名证书一致；随后由系统未知来源设置页授权，再使用下载任务返回的 content URI 打开系统
安装器。Manifest 的 `REQUEST_INSTALL_PACKAGES` 只允许发起该流程，不会绕过 Android 安装确认。

远端 stderr 会去除 ANSI/控制字符并写入有界 Debug 诊断日志，不能用原始 JSON/Rust 日志或环境警告遮挡
仍可用的会话；真正断线、认证失败和不可恢复错误仍明确显示。上述后台、通知、终端、文件和日志实现仍需在目标
Android 设备上验证通知权限、文件选择器、键盘、厂商后台限制和长时运行行为。

### 10.1 本机 Linux 实验模式

服务器页的“本机 Linux”入口在 ARM64 Android 上提供可选 Debian 环境。APK 内置由固定 Termux 包复现的
PRoot、loader、libandroid-shmem 和 talloc；首次启用下载固定版本 Debian Trixie ARM64 rootfs，下载上限、
预期大小和 SHA-256 均在原生层校验，归档解压拒绝越界路径、硬链接、符号链接父目录写入和超过 256 MiB 的
展开内容。基础 rootfs 下载约 35 MB、展开约 173 MB，安装 SSH、Git、下载工具和后续 Codex 后占用继续增加。
首次安装的 APT 阶段优先使用阿里云 Debian 镜像，失败后才回退 Debian 官方源；DNS 优先继承 Android 当前
活动网络（包括 VPN），并以阿里云和腾讯公共 DNS 兜底。软件源更新、工具安装和缓存清理分别限时并显示阶段
进度，APT 禁止自动启动服务；已通过 SHA-256 校验的 rootfs 压缩包会在失败重试时复用，避免重复下载。

PRoot 从 APK 的 `nativeLibraryDir` 执行，Manifest 必须保持 `extractNativeLibs=true`；对应 Gradle 配置为
`packaging.jniLibs.useLegacyPackaging = true`。该模式会压缩 APK 中的原生 `.so`，再由 Android 在安装时
解压：Release APK 约 29 MB、包内未压缩内容约 66 MB 是预期结果。它会略微增加打包和安装时间，但显著降低
下载体积，不能为了恢复旧版约 64 MB 的 APK 或缩短少量构建时间而关闭。Android 禁止从可写 App 数据目录
执行下载文件，所以 PRoot 不允许运行时替换。生成脚本固定上游包和哈希，
`scripts/test-local-linux-runtime.sh [apk]` 离线校验 ARM64 ELF、依赖修补、文件哈希及 APK 内容。

Debian 位于 App 私有目录，只向外提供 `/root/workspace`，不主动绑定 Android 共享存储、应用凭据目录或宿主
Home。sshd 使用随机端口和随机密码，只监听 `127.0.0.1`，密码与端口通过 Android Keystore 支持的加密
SharedPreferences 保存；Flutter 将它注册为固定 `agent-local-linux` Profile，然后复用现有 SSH、Agent、终端
和文件管理链路。断开该 Profile 会停止 PRoot sshd，意外断线和进程恢复前会先重启本机 Linux；卸载会删除
Debian、Codex、工作区和本机 Profile。

这不是虚拟机或内核级沙箱：PRoot 只做用户态路径和身份转换，Linux 进程仍受 Android App UID 与系统限制。
当前只有 PRoot 本机 Linux 运行时限 `arm64-v8a`；APK 的 Flutter 运行时仍包含 `armeabi-v7a`、
`arm64-v8a` 和 `x86_64`。x86_64 模拟器只能验证本机 Linux 的 UI、状态机和 APK 内容，首次安装、apt、回环 SSH、Codex
安装/登录、后台恢复和长时运行必须在 ARM64 Android 真机验证。PRoot 环境无法提供 Codex Linux sandbox 所需
的 bubblewrap，因此固定使用 full-access 审批模式；模型推理和 Codex 安装仍需要网络，不是离线模型。

## 11. 隔离规则

| 数据/资源 | 必须的隔离键 | 当前/目标存放 |
| --- | --- | --- |
| SSH 主机客户端、连接状态、metrics request | profileId | 当前 ServerConnectionManager |
| Agent 客户端和连接状态 | profileId + AgentKind | 当前 AgentConnectionManager |
| 会话/模型列表和 loading | profileId + AgentKind | 当前 AppUiState lane maps |
| 活动时间线、运行态、目标 | profileId + AgentKind + threadId | 当前控制器用 active-key/thread guard；目标对象不长期持久化 |
| transcript/TokenUsage cache | profileId + AgentKind，cache 内再按 threadId | 当前 ThreadSessionCache |
| 草稿、模型、思考强度、完成计时 | profileId + AgentKind + threadId | 当前 StoredProfiles 复合键 |
| 审批队列 | profileId + AgentKind + threadId（请求 generation 由 Agent 客户端校验） | Flutter/Kotlin 控制器分桶；无 threadId 的旧协议使用 lane 兼容桶 |
| 待发附件 | 当前活动 AppUiState；写回用 profileId + AgentKind + threadId guard | 不持久化；离开会话清空 |
| Agent 安装 job | profileId + AgentKind；同 profile 共享串行锁 | 当前 AppController + AgentConnectionManager；generation 拒绝断开后的旧结果 |
| Agent 全局配置请求/状态 | profileId + AgentKind + requestId + connection generation | 当前 AppController + AgentConnectionManager；远程落盘在服务器用户全局文件 |
| 终端 | profileId | 当前 `TerminalManager` 的独立 PTY session；隐藏可保活，关闭/断开清理 |
| 文件管理列表/操作/剪贴板 | profileId + connection identity + requestId | 当前 `AppController` + `FileManagerScreen`；剪贴板仅内存，不跨服务器持久化 |

任何新增状态先确定隔离键，再决定放入 AppUiState、内存 cache 还是 StoredProfiles。旧 profile、
旧 generation 或旧服务器的异步结果不能写入当前选择。

## 12. 构建、版本、签名和发布

当前唯一 Android 构建入口是 scripts/build-android.sh 调用 Flutter：

~~~bash
./scripts/build-android.sh fast
./scripts/build-android.sh debug
./scripts/build-android.sh release
./scripts/build-android.sh all
~~~

它执行 flutter analyze、Flutter tests 和 flutter build apk，不执行旧 Kotlin app 模块的 Gradle task。APK：

~~~text
flutter_app/build/app/outputs/flutter-apk/app-debug.apk
flutter_app/build/app/outputs/flutter-apk/app-release.apk
~~~

构建必须保持 `packaging.jniLibs.useLegacyPackaging = true` 和最终 Manifest 的
`extractNativeLibs=true`。这是原生库压缩交付及 PRoot 从 `nativeLibraryDir` 执行的共同契约；发布门禁使用
`scripts/test-local-linux-runtime.sh <release-apk>` 检查，不得仅依据 APK 文件大小判断 ABI 是否完整。

签名是不可破坏的升级契约：

- keystore/codex-remote-stable.keystore；Debug/Release 共用 stable signing config；
- 证书 SHA-256 为 72:72:22:18:70:9A:6D:7F:D0:E8:0B:94:49:03:AE:29:61:B4:CF:A8:AB:E0:35:86:F6:02:AC:DC:1E:A0:F5:2A；
- 不删除、重生成、替换 keystore 或 alias；每次交付包含代码修改的新 APK，都将 Pubspec 可见语义版本
  至少递增一个 patch 版本，并同时增加 build number，不能只增加 build number。

本机发布脚本会验签、原子替换 `/var/www/html/codex.apk`，同时更新兼容别名
`/var/www/html/agent.apk`，并绕过代理校验：

~~~text
内网：http://192.168.8.107/codex.apk
外网：http://frp.asdb.top:18080/codex.apk
~~~

交付时必须同时给出两个完整地址和 APK SHA-256。不要在文档、提交或回复中写访问 token。

## 13. 本地测试环境与门禁

当前本机环境：

~~~text
Android SDK：由 scripts/android-sdk.sh 解析（当前容器为 /var/lib/docker/volumes/android-sdk/_data）
adb：$ANDROID_HOME/platform-tools/adb
AVD：asdb_api34（通常 emulator-5554，以 adb devices -l 为准）
推荐竖屏：1220x2712；后续 UI 验收不再覆盖横屏
自动门禁最低：短边 1080、长边 2400
~~~

推荐启动：

~~~bash
./scripts/android-emulator.sh start
./scripts/emulator-smoke.sh debug
~~~

emulator-smoke.sh 默认保留 App 数据、服务器 Profile 和 Keystore；仅 --reset-data 才清除当前
应用数据。脚本会验证竖屏截图、最小尺寸、前台包名、Crash/ANR 和系统错误弹窗。推荐尺寸不是
精确硬限制；截图验收应记录实际 PNG 宽高。

### 13.1 当前 Flutter 自动测试

~~~bash
./scripts/flutter-tool.sh analyze --no-pub
./scripts/flutter-tool.sh test --no-pub
~~~

每次修改先运行最近的定向测试，再按风险只选择一个主门禁：纯函数和局部 UI 用 `quick`，普通功能用
`check`，SSH/Agent/持久化/Android 宿主等高风险修改用 `full`，交付 APK 直接用 `publish`。工作流或构建
脚本自身的修改需要先通过 `bash -n` 与 `scripts/test-workflow.sh`，并真实跑一次 `check -> full` 验证缓存
衔接。风险矩阵和完整命令以 `docs/LOCAL_WORKFLOW.md` 为准。

同一源码指纹下，成功的 Debug 或 Release stamp 都证明 analyze 和完整 Flutter 测试已经通过；后续门禁
只补构建缺失的另一种 APK，不重复验证或重建已有 APK。执行前可用
`./scripts/build-android.sh all --reuse --plan` 查看只读计划。`dev-workflow.sh` 每次退出都会输出阶段与总耗时，
并写入 `.workflow-cache/latest-workflow-timing.tsv` 及最多 100 份历史记录。

当前测试文件：

| 文件 | 覆盖 |
| --- | --- |
| test/widget_test.dart | 空服务器首屏、1220x2712 连接阻塞遮罩、Back 阻断、2x 字体、私钥密码入口、未保存编辑确认 |
| test/app/app_controller_test.dart | 初始化/持久化、Profile/指纹/资源/目录、附件与全局配置/API 模型获取/自定义模型目录和同步 generation、运行时安装，以及子 Agent 多层导航、加载中/重复返回、失败重试、错误 thread 防污染、会话设置隔离、审批按 thread 隔离/精确回答和迟到回调保护 |
| test/app/profile_scoped_back_stack_test.dart | profile + Agent 栈隔离、pending pop 幂等、取消/迟到回调保护和清理 |
| test/domain/models_test.dart | Profile 默认值、Agent 模型字段、复合偏好键、上下文/差异辅助模型 |
| test/domain/model_catalog_test.dart | 空远端目录下保留会话模型/effort、自定义模型 ID/名称/token 上限、远端/自定义合并、隐藏、编辑恢复、API 选项筛选/应用，以及 OpenCode `custom-api/`、旧 `codex-remote/` 迁移、effort 和 managed ID |
| test/persistence/profile_store_test.dart | 归一化、条目/草稿边界、旧 Agent 键迁移、OpenCode ID 归一化/去重/持久化迁移、旧加密 Profile 一次性导入和损坏数据降级 |
| test/ssh/server_connection_manager_test.dart | 指纹规范化、多服务器隔离、客户端复用、旧结果防护、资源请求去重/断线清理、目录 capability/排序/扫描上限，以及附件上传和远程下载的身份、generation、类型与大小边界 |
| test/ssh/server_metrics_test.dart | 采样协议解析、兼容短格式、非法/哨兵值和大小边界 |
| test/agent/codex_protocol_test.dart | JSONL 编解码、generation、模型/会话/时间线/回合/附件兼容解析和字段边界 |
| test/agent/codex_agent_client_test.dart | app-server 命令的环境加载/workspace shell quoting，以及空 `remoteCommand` 拒绝 |
| test/agent/codex_global_settings_test.dart | Shell 语法、临时 HOME 配置读写、Provider/Key 保留、权限、`/models` 解析/去重、0600 header 文件和密钥不泄漏、自动 Responses/Chat 回退、显式 API 协议严格不回退和 HTTP/网络错误映射 |
| test/agent/opencode_agent_client_test.dart | capability、workspace quoting、运行时生命周期、全局设置、真实 Key、Provider 前缀、模型同步/tombstone/缓存和显式 API 协议 |
| test/agent/open_code_bootstrap_test.dart | 打包 bridge hash、固定版本探测、安装/卸载脚本语法、HTTP/HTTPS 代理防注入和托管卸载边界 |
| test/ssh/ssh_server_client_test.dart | `sh -s`/长任务脚本只走 stdin、EOF、非零退出、输出上限、超时，以及跨 chunk UTF-8/CRLF/末行进度回调 |
| test/agent/remote_bootstrap_test.dart | runtime 探测、兼容命令、依赖错误、固定版本、HTTP/HTTPS 代理防注入、进度解析和安装/卸载边界 |
| test/agent/codex_event_reducer_test.dart | turn/delta 生命周期、后台 thread 隔离、TokenUsage 窗口保护、旧 turn 完成防护，以及空 started/完整 completed 的乐观用户消息与图片附件合并 |
| test/agent/agent_connection_manager_test.dart | profile + Agent lane、host 断开、generation/旧请求防护、连接前不提前暴露 capability、steer 转发和自定义模型同步迟到结果隔离 |
| test/agent/thread_session_cache_test.dart | 会话缓存 TTL、LRU、权重上限和上下文用量隔离 |
| test/app/resume_lifecycle_test.dart | resume 通知缓冲/顺序、迟到响应保护，以及返回列表后后台 timeline/TokenUsage 写回缓存并在重进时恢复 |
| test/ui/sub_agent_presentation_test.dart | 子 Agent 状态映射、同 turn 终态保护、跨 turn 重启、相邻活动分组和稳定身份色 |
| test/ui/model_selection_presentation_test.dart | catalog id/wire model 匹配、模型/effort 标签和容量格式 |
| test/platform/local_file_exporter_test.dart | Android 导出会话 begin/write/complete/abort、分块上限和关闭后拒绝写入 |
| test/platform/turn_completion_notifications_test.dart | 完成通知 payload、稳定通知 id、bounded 去重、子 Agent 过滤和点击导航解析 |
| test/platform/diagnostic_logger_test.dart | 十次点击计数、日志开关、100 文件/10 MiB 轮转、脱敏、崩溃记录、清空、附件、预览、导出和分享 |
| test/ui/diagnostic_log_sheet_test.dart | 崩溃日志默认选择、多选确认和附件数量上限 |
| test/platform/app_update_manager_test.dart | Gitee Release/资源筛选、SemVer 与 prerelease 排序、忽略提示、进度/容量辅助函数，以及下载到安装的状态机 |
| test/ssh/terminal_manager_test.dart | 每 profile PTY session、generation/身份失效、输入/输出上限、历史恢复、断开和重试 |
| test/ui/markdown_links_test.dart | HTTP Markdown/裸链接识别、label 后中文说明边界、目标 URL 不重复显示、远程路径安全编码/解码、非法路径和保存文件名清理 |
| test/ui/work_content_test.dart | 图片工具路径提取、非图片工具拒绝、图片 MIME 映射、保存文件名清理和附件 MIME/文本分类 |
| test/ui/workspace_picker_dialog_test.dart | 父/子目录、确认、加载和关闭、错误显示，以及窄屏/放大字体边界 |
| test/ui/agent_settings_dialog_test.dart | Codex/OpenCode 字段顺序、真实 Key 回显/隐藏、测试草稿、保存二次确认、Provider 保留、IME 尺寸和忙碌状态 |
| test/ui/remote_setup_dialog_test.dart | 运行时信息、固定版本/路径、代理输入、总体/下载进度、失败重试、最小化，以及先聚焦再注入 IME inset 的键盘避让与信息收起 |
| test/ui/app_update_dialog_test.dart | 更新日志、下载完成、安装等待和后台继续的 Widget 状态切换 |
| test/ui/thread_list_and_lifecycle_test.dart | Agent 断线隐藏缓存列表、搜索过滤、`working` 运行态和 Work 生命周期键盘收起判定 |
| test/ui/server_metrics_strip_test.dart | 资源指标在目标竖屏中保持自然宽度、紧凑间距和左对齐 |
| test/ui/work_screen_layout_test.dart | Work 页面原版时间线布局、思考/命令折叠、图片卡片、Composer 控件顺序和目标竖屏无溢出 |

OpenCode bridge 另有 Node 门禁：`scripts/test-opencode-bridge.cjs`、
`scripts/test-opencode-bridge-scheduling.cjs`、`scripts/test-opencode-bridge-question.cjs` 和
`scripts/test-opencode-bridge-integration.cjs`，统一由 `scripts/test-opencode.sh` 执行，覆盖协议映射、
调度、question/审批和固定 OpenCode runtime 集成。已有 `quick --force` 通过记录只能证明这些 bridge
fixture，当次真实服务器和 Android 端到端仍需单独验证。

没有 integration test、golden test 或完整 Work/会话/文件/终端 UI 测试；附件 picker、IME、真实远端
app-server、Android 前台 Service 和系统通知展示仍没有自动化覆盖（通知协议/去重逻辑已有纯 Dart 测试）。
当前 `codex_agent_client_test.dart` 也未覆盖握手、请求超时、事件、审批或断线。新增共享状态、持久化、
连接生命周期或跨页面行为时，必须补测试，不能只运行一个 Widget 用例。

最近一次本机验收记录（2026-08-08，当前工作树）：`flutter analyze --no-pub` 为 0 问题，完整
`flutter test --no-pub` 共 338 项全部通过；最终 release APK 位于
`flutter_app/build/app/outputs/flutter-apk/app-release.apk`，大小 66,240,919 bytes，SHA-256 为
`c208a45ce9a1225b7d9469ee1471c4d98e47067e6be38e2540669132125781d5`。产物核验结果为
`applicationId=top.asdb.agent`、应用名 `Agent`、`versionName=1.8.5`、`versionCode=125`，签名证书
SHA-256 为 `72722218709a6d7fd0e80b944903ae2961b4cfa8abe03586f602acdc1ea0f52a`。

本轮对话页视觉迁移（2026-08-08）将 Flutter Work 时间线恢复为原版结构：助手 Markdown 直接铺底、思考/计划
折叠行、命令状态卡、图片查看卡、居中回到底部按钮和一体化 Composer；新增 `work_screen_layout_test.dart`
覆盖 1.5K 竖横屏和展开交互。完整 Flutter test 已增至 340 项，Analyze、Debug/Release 编译和 Android 14
模拟器 smoke 均通过。Release 产物为 `versionName=1.8.6`、`versionCode=126`，SHA-256 为
`65b6d36ce8f78d8226ad54c93597ece9d6c0f0c194f6c40cac937272a85294cb`，继续使用原稳定签名。

2026-08-09 再次以旧版 Compose Work 页面和真机截图逐项核对：Flutter 工作页使用原版局部颜色、6 dp
思考/命令/图片表面、17 dp 主图标和 36 dp 浅色发送/停止按钮；补齐运行中、完成和已停止耗时尾行，
并恢复文件修改、工作区差异卡和全屏差异查看。模型、思考强度、权限和上下文仍按会话实际状态显示，
不为截图写死。主动停止成功后本地停止标记优先于 app-server 随后的 `completed` 状态；最近一次完成或
停止耗时会按服务器、Agent 和会话持久化，返回重进及冷启动均恢复。`work_screen_layout_test.dart` 同步
覆盖停止耗时和文件差异入口。

同一产物经 `./scripts/emulator-smoke.sh release --force-install` 验收：Android 14 模拟器竖屏
1220x2712、横屏 2712x1220 均启动成功，进程存活，最近 1200 行该包 logcat 无 FATAL/ANR。截图位于
`.workflow-cache/emulator/latest-release.png` 和 `.workflow-cache/emulator/latest-release-landscape.png`。
该 smoke 只证明安装、启动、方向、包名和基础页面稳定，不代表真实 Gitee 下载、未知来源授权、覆盖安装、
SSH 或 Agent 端到端已经验收；应用内更新的 Android 系统流程仍按下方手工清单真机验证。

### 13.2 当前手工回归清单

下表是每次相关改动必须执行的场景，不代表本次工作树已经全部通过：

| 场景 | 预期 |
| --- | --- |
| 首次启动 | 只显示服务器列表，不出现异常白框或 Flutter Demo 页面 |
| Profile 编辑 | 默认用户 root；表单可滚动；输入框和键盘不重叠；返回未保存时询问 |
| 密码/私钥连接 | 首次显示 SHA-256 指纹；取消不保存；信任后严格连接 |
| 多服务器 | 同时连接 A/B，切换和断开不串状态 |
| 资源指标 | 列表进入时立即采样，前台周期刷新；详情单位正确；断开和切后台后停止更新且不串服务器 |
| 连接中 | 半透明转圈遮罩覆盖全屏，Back 和重复点击被阻断；成功后无额外空白等待 |
| Agent lane | SSH 已连接后 Codex/OpenCode 各自 initialize 成功；model/list 与 thread/list 独立失败不让页面崩溃；切换 lane 不串状态 |
| Codex 安装 | 无/旧版本时显示环境与路径；HTTP/HTTPS 代理、总体/下载进度、最小化后按钮进度、点击恢复、失败重试、复检和自动进入列表；系统同版本直接复用 |
| Codex 卸载 | 删除整个 Codex Remote 托管 root、wrapper 和附件暂存；运行中的托管 app-server 被关闭；若曾安装 OpenCode 则需重新安装；系统 Codex、VS Code、~/.codex 和工作区保留 |
| OpenCode 安装 | 缺失、版本不符或 bridge hash 不符时显示两阶段进度；代理、最小化后按钮进度、点击恢复、失败重试、复检和自动进入列表正确；固定 1.18.11 与打包 bridge 同时匹配才复用 |
| OpenCode 卸载 | 只删除 OpenCode 托管子目录和 wrapper；共享 Node、Codex、附件暂存、~/.codex、VS Code 和工作区保留 |
| Agent 全局配置 | Codex/OpenCode 都从服务器读取实际 URL/Provider/模型/effort/代理/Key；保存后二次确认和断线；测试按显式协议发真实最小请求且不保存 |
| 工作目录 | 纯 SSH 不弹；当前 Agent 首次成功只弹一次并立即记忆；浏览/上一级/错误/稍后/确认正确；连续请求、切服务器/Agent和断线不串结果 |
| 会话 | 新建、搜索、刷新、重进缓存、180 秒恢复、历史下拉分页和运行转圈不串服务器/Agent |
| Work | 发送/流式输出/停止、审批和 user-input、权限切换、模型/草稿恢复、上下文缓存、压缩/回退/归档/重命名/审查/目标 |
| 附件 | 图片/文件多选、大小/数量限制、上传中状态、部分失败、移除、纯附件发送、发送失败恢复和切换会话隔离 |
| 图片/Markdown/文件 | “查看了图片”和远程图片链接可直接预览；HTTP/HTTPS Markdown/裸链接蓝色、可复制且点击先确认；其他远程文件链接使用 SAF 流式保存，取消/失败不留半成品 |
| 文件管理 | 目录浏览、上级目录、刷新、多选、上传、下载、重命名、删除确认、复制/剪切/粘贴；切服务器/断开不串结果 |
| 终端 | 会话列表进入 PTY；键盘输入、resize、输出历史、隐藏/重试/显式关闭；Codex JSONL 不被污染 |
| 后台与通知 | 切后台保持服务和 SSH；回合完成只发一次通知；点击通知恢复正确服务器/会话；拒绝通知权限不崩溃 |
| Debug | 连点十次开启；日志持续写入并轮转；预览、复制、清空、系统分享；敏感值不出现在导出文本 |
| 应用内更新 | 自动/手动检查、无更新和失败提示、绿点与更新日志、忽略版本、下载进度、弹窗后台继续、失败重试、未知来源授权、系统安装页；升级后确认 Profile 仍在且签名未变 |
| 并发与返回 | resume 同时收到 delta、列表与 Work 来回、系统 Back、SSH 断开、切后台再回来不会覆盖错误 thread |
| 竖屏/字体 | 推荐 1220x2712 竖屏、放大字体无截断；同时核对实际截图尺寸 |
| 进程重建 | 加密 Profile 可恢复，断线不会伪装成已连接 |

### 13.3 能力状态矩阵

| 领域 | 当前实现 | 仍需完成/验收 |
| --- | --- | --- |
| Agent 连接 | Codex 按需独立 app-server；OpenCode 使用打包 bridge + loopback `serve`；两者均有固定版本探测/复用、用户目录安装/卸载、进度/重试/自动连接 | 真实服务器 OpenCode 下载/安装/卸载、长时 turn/steer/interrupt、断线和后台回归 |
| 工作目录 | 首次 Agent 成功只提示一次；SFTP 浏览、错误显示、确认/记忆和手动重开；thread/start/turn/start 传递 workspace | 真机大目录、权限拒绝、连续切换与断线回归 |
| 会话 | 搜索/刷新/新建/恢复、turn 历史分页、缓存优先、resume 通知缓冲/快照协调/顺序重放、运行转圈 | thread/list 下一页；真实长时 resume/delta 竞态、缓冲溢出和大历史降级压测 |
| 会话设置 | wire 模型和 effort 可独立选择并按 profile + Agent + thread 持久化；自定义模型新增/编辑/删除、远端隐藏/恢复、API `/models` 筛选回填已接入 | 真实服务器 Provider 差异、权限和模型目录回归 |
| 输入 | 草稿按复合键恢复；Composer 有 IME inset 和 viewport 同步；切后台主动 unfocus/隐藏输入法；本地附件 picker/上传/移除/发送及失败恢复 | 真机同帧验证、picker/Widget 自动化测试 |
| 对话动作 | 发送/停止、权限、审批、上下文、压缩、回退、归档、重命名、审查、目标 | 真实固定 Codex 版本全场景回归 |
| 历史滚动 | Cupertino sliver 分页、三态提示、正文下移留白、位置补偿和回底部箭头 | 真实超长历史与连续分页回归 |
| Markdown/图片/文件 | Markdown/裸 HTTP 链接确认；图片识别、SFTP 预览/保存；非图片远程文件链接经 SAF 流式保存 | 大文件、断线和厂商文件选择器异常路径回归 |
| 子 Agent | 紧凑图标/名称/逐个状态、同 turn 终态保护、真实 child `thread/resume`、父快照栈、最多 8 层返回、失败重试和迟到回调过滤 | 真机长时导航、真实服务器连续协作事件和大历史回归 |
| 后台 | Flutter bridge + Android foreground Service、partial wake lock；根 Back 移到后台；Activity 销毁/重建复用连接期 FlutterEngine，进程存活时 Dart stream 和 SSH 继续 | 真机权限/厂商后台限制、进程被杀后的恢复不保证 |
| 完成通知 | 后台回合通知、稳定 id、bounded 去重、子 Agent 过滤、点击直达 | 真机通知权限、锁屏/厂商通知策略和完整端到端回归 |
| Debug | 十次点击开启；100 KiB/100 文件/10 MiB 轮转、FATAL/Java/ANR 线索、二次脱敏、多选分享、清空临时副本、日志附件待发送 | 真机崩溃复现、Native 信号和分享目标兼容 |
| 应用内更新 | Gitee 稳定 Release 自动/手动检查、两种 APK 资源名兼容、忽略版本、DownloadManager 进度、后台继续、任务持久化/重绑、未知来源授权、取消后重试、包名/版本/证书校验和系统安装 | 真机弱网/断网、权限拒绝、下载失败、覆盖升级、真实安装器行为和进程重建回归 |
| 终端/文件 | 每 profile 独立 SSH PTY；SFTP 浏览/上传/下载/重命名/删除/复制移动；SAF 分块导出 | 真机键盘、超大文件、断线和厂商文件选择器回归 |
| 全局配置 | Codex/OpenCode 远程用户全局 Provider、认证、代理读取/保存和真实 API 测试；OpenCode 自定义模型同步/tombstone、Provider 前缀和显式协议已接入 | 真实服务器 Provider 差异、权限/登录/协议和模型缓存刷新回归；不得把 API key 放入命令参数或手机持久化 |

## 14. 产品长期约束

以下约束来自持续使用反馈，除非用户明确确认，不得删除或弱化；“目标”表示尚未在 Flutter 完成，
不是允许伪造已实现状态：

1. 首页是服务器列表，设置按需展开；默认 SSH 用户为 root。
2. 多台服务器可保存、同时连接和切换，状态、审批、会话和资源不得串台。
3. 工作目录第一次连接 Agent 后选择一次并记住；仅 SSH 登录不弹，之后不重复打扰。
4. 输入草稿、模型、思考强度按服务器 + Agent + 会话独立并持久保存；自定义模型管理和远端模型隐藏也按服务器 + Agent 隔离（当前已接入）。
5. 后台返回不得自动弹键盘；IME 出现时输入区和消息同步移动（已有 inset/viewport 处理，仍需真机验收）。
   有 SSH/Agent 连接或活动回合时，根页面系统返回只能将任务移到后台；Activity 重建不得销毁 FlutterEngine
   或关闭 SSH。只有用户明确断开、强制停止或系统杀死整个进程时才允许连接结束。
6. 会话重进优先显示缓存，较大历史允许更长的后台恢复，不长期白屏（当前缓存 + 180 秒 thread timeout）。
7. 更早历史通过下拉释放加载，提示随手势出现，内容向下留白（当前已接入）。
8. 运行会话显示停止图标，列表显示转圈；上下文小圆环点击只看占用，不弹压缩确认（当前已接入）。
9. 子 Agent 使用稳定身份色图标和逐个状态，不显示多余“子agent”文字；点击有效 thread ID 进入真实独立会话，父子返回可安全重试（当前已接入；真机长时回归仍需执行）。
10. 目标和操作菜单使用原生 app-server 能力，不依赖复杂斜杠解析（当前 Codex 已接入）。
11. App 在后台时 turn 完成发通知，点击进入正确服务器和会话（当前已接入；通知权限、厂商策略和进程被杀后的恢复仍需真机验收）。
12. Agent 图标连续点击 10 次开启 Debug；最多 100 个日志文件/约 10 MiB，单文件约 100 KiB；日志可多选系统分享且脱敏，
    工作页可多选并作为输入框文本附件（不会自动发送）；Java/Native/ANR 线索尽量在下次启动恢复。
13. 所有输入页面适配键盘、目标竖屏和大字体，不允许控件重叠；横屏不作为 UI 验收范围。
14. Codex/OpenCode 自动安装有可见总体/下载进度，按服务器保存 HTTP/HTTPS 下载代理；安装中可最小化，失败可重试，卸载不得触碰系统 Codex、VS Code、~/.codex 或工作区（两种 Agent 当前均已接入，仍需真实服务器/真机长时验收）。
15. 视觉接近 VS Code Codex：安静、紧凑、工作导向，不使用营销式大卡片、渐变或装饰背景。服务器列表
    和任务列表以旧 Compose 页面为明确视觉基线，保留其 64 dp 顶栏、品牌/推广块、单个服务器整卡、
    无外框 Debug 行、资源行、Agent 分段控件、无描边搜索框和紧凑任务行；可配置模型等新增内容除外。
16. APK 签名永不变化，每次修改版 APK 的可见语义版本至少递增一个 patch 且 build number 必增，交付同时给内网和外网地址；应用内更新只能安装同包名、
    同稳定证书且版本递增的正式 APK，不能用换签名绕过覆盖升级问题。
17. 本机构建下载优先使用 127.0.0.1:7890；已有依赖保持离线增量构建。
18. 每次修改按风险执行最近的定向测试并只选择一个主门禁；不能只以“编译通过”代替模拟器和真实流程
    验证，也不要重复执行已经由同指纹成功 stamp 证明的 analyze、全量测试或 APK 构建。第一次写文件前
    开始计时，收尾必须报告总耗时、各阶段耗时、缓存命中和失败返工。
19. Git 提交信息使用中文；得到授权后才同步配置好的 Gitee origin。
20. “低价中转站优选”必须由系统浏览器打开 https://lowapi.asdb.top，不可内嵌 WebView。
21. 非致命远端 stderr 去除 ANSI/控制字符后写入有界 Debug 日志，不覆盖会话页状态；真正断线、认证失败和不可恢复错误仍明确显示。
22. Codex 配置修改当前远程 Unix 用户的全局模型 URL、密钥和 HTTP/HTTPS 代理，不改项目工作区（当前 Codex 已接入）。
23. 配置页先读取服务器实际 Provider、默认模型、URL、代理、登录状态和 Key；自定义 Provider 不得误报未配置（当前 Codex 已接入）。
24. HTTP/HTTPS Markdown 链接和裸 URL 必须完整、可点击、可长按复制（当前均已接入并有回归测试）。
25. Agent 接入必须通过 RemoteAgentClient/AgentCapabilities，所有异步结果、缓存和审批队列按 profile + Agent + thread 隔离。
26. SSH 登录是前置条件；无 Agent 时终端/文件仍可用，Agent 设置和工作目录灰显不可操作（终端/文件当前已接入；无 Agent 的真机行为仍需回归）。
27. 图片消息使用“查看了图片”中文状态；点击打开图片预览，长按可调用系统保存到手机（当前已接入）。
28. 本地图片/文件附件必须有选择、受限上传、待发列表、移除和失败恢复；当前端到端发送及
    `turn/start` 失败恢复已接入，仍需真机 picker 和 Widget 自动化回归。
29. Markdown 远程绝对文件链接只能在当前 SSH profile 内通过 SFTP 下载；必须使用系统保存位置选择器、
    分块写入并清理失败半成品，内部链接不得泄露给外部浏览器（当前已接入，仍需真机回归）。

## 15. 修改影响图和顺序

### 修改 Profile 或持久化

~~~text
models.dart
  -> models.g.dart/freezed.dart（生成）
  -> SecureProfileStore normalize/migration
  -> AppController persistence lock
  -> profile_store_test + app_controller_test
  -> force-stop / upgrade / stable-signature smoke
~~~

新增字段必须给默认值，处理旧 JSON、重复 ID、过长草稿和删除 profile 的前缀清理。凭据不得进入普通
首选项、SavedState、日志、通知或截图。

### 修改 SSH 或连接状态

~~~text
ServerProfile / ServerScreen
  -> ServerConnectionManager lock + generation
  -> DartSshServerClient / dartssh2
  -> fingerprint + multi-profile tests
  -> widget connection overlay + emulator smoke
~~~

不要在 Widget 中直接创建 SSH 客户端；不要把主机连接和 Agent app-server channel 混成一个生命周期。

### 修改 Agent 协议或 Work 行为

~~~text
Codex schema / AgentKind / AgentCapabilities / RemoteAgentClient
  -> AgentConnectionManager(profileId + AgentKind)
  -> adapter parser/reducer/cache
  -> AppController active-key/thread guards
  -> AppUiState + Work/Thread UI + StoredProfiles preferences
  -> protocol, cache, cancellation, multi-server tests
  -> real authorized SSH/app-server integration
~~~

先定义 wire 模型、字段上限和 generation 过滤，再接 reducer/控制器/UI；不能把服务器响应直接塞入
全局字符串。新增审批、附件或子 Agent 行为必须同时验证 thread 隔离、返回栈和 resume/delta 竞态。

### 修改应用内更新

~~~text
app_update_manager.dart（Release 解析和状态机）
  -> server_screen.dart + app_update_dialog.dart
  -> top.asdb.agent/app_update MethodChannel
  -> MainActivity DownloadManager/系统安装器 + AndroidManifest 权限
  -> app_update_manager_test + app_update_dialog_test
  -> analyze/test -> APK 包名/版本/签名校验 -> 模拟器 smoke -> 真机更新安装
~~~

Release 资源命名、仓库地址、版本比较或原生状态字符串变化时必须同时更新 Dart 和 Kotlin 两端；自动测试
不覆盖系统未知来源设置和安装确认，最终仍要用上一稳定版真机执行一次真实覆盖升级。

## 16. 故障定位

### 16.1 Flutter 构建/分析失败

先运行 ./scripts/build-android.sh fast --force 查看完整错误。检查 Flutter 版本、PUB_CACHE、
flutter_app/pubspec.lock 和 7890 代理；不要先 clean。模型改动后确认生成文件是否同步。

### 16.2 Profile 读取或迁移失败

检查 profiles_v2 是否是有效 JSON、Android legacy MethodChannel 是否返回字符串、迁移标记是否在
清理成功后写入。损坏数据应安全降级为空配置并显示简短错误，不能崩溃或覆盖其他 profile。

### 16.3 SSH 指纹/连接失败

确认 host、port、用户名、认证材料和服务器实际 SHA-256；主机/端口变化必须重新探测。检查是否有
旧 generation 的连接仍在返回，不要通过自动接受 host key 或无限延长 timeout 掩盖错误。

### 16.4 Agent 连接、恢复或回合失败

排查顺序是“SSH connected -> 当前 Agent lane generation -> runtime/command -> initialize ->
model/list/thread/list -> thread/resume -> turn/start|turn/steer -> notification”。Codex 检查 Profile 的
`remoteCommand`、workspace、`$HOME/.codex/codex-remote.env` 和固定 app-server 版本；OpenCode 检查固定
1.18.11、bridge hash、`codex-remote-opencode-bridge`、loopback `serve` 日志、全局 Provider/认证和代理。
重进异常先比较 cache、active key、threadId 和 generation，再看是否有 resume 响应覆盖实时 delta；stderr
只进入诊断，不能把辅助错误误报成 SSH 断线。

### 16.5 模拟器、键盘和闪退

检查 AVD service、adb devices -l、推荐两方向截图、UI XML 和
.workflow-cache/emulator/latest-logcat.txt。表单页面使用 resizeToAvoidBottomInset/滚动布局；Work
页面刻意关闭 Scaffold 自动 resize，改由 Composer viewInsets 和 transcript viewport 联动，两套机制
不要叠加。切后台/回来、键盘开合、流式 delta 和阅读旧消息都要回归；不要吞异常来“修复”闪退。

### 16.6 APK 无法覆盖安装

依次检查 applicationId=top.asdb.agent、build number 是否增加、APK 是否由稳定 keystore
签名、证书 SHA-256 是否一致。旧版 top.asdb.codexremote 与 Agent 独立安装、数据互不共享；绝不能换签名、
卸载用户数据或删除 keystore 解决升级问题。

### 16.7 应用内更新失败

先检查 Gitee API 是否返回非 prerelease Release、tag 是否为合法 SemVer、assets 是否包含精确的
`Agent-<version>.apk` 或 `CodexRemote-<version>.apk`，再看 Debug 日志中的 `Update` 分类。下载失败检查
DownloadManager 错误、网络和存储空间；安装失败检查未知来源授权、`top.asdb.agent` 包名、versionCode 和
稳定签名。不要关闭 `usesCleartextTraffic=false` 来兼容 HTTP 更新源，也不要替换 keystore。

### 16.8 远端 403/503

若 Agent 出现 MCP/上游 HTTP 403，普通页面只应显示简短中文说明，详情写入当前的脱敏 Debug 日志；
主 app-server 仍连接时不要把辅助 worker 错误显示成 SSH 断线。503、resume 超时应使用缓存和可取消
request，不能只把全局 timeout 调到很大而留下 pending 请求。

## 17. 已知限制

- OpenCode adapter、bridge、真实会话/回合协议、固定版本安装/卸载、全局配置和模型同步代码均已接入，
  但尚未在授权真实服务器验证固定版本下载、实际 Provider/API、长时 turn/steer/interrupt、断线和后台
  行为；rollback、review、thread goals、subagents、archive 和独立历史 cursor capability 当前关闭。
- Codex/OpenCode runtime 探测、安装/卸载和进度 UI 已实现，但尚未在本轮完成真实远端下载、
  断线中止、重装空间累积和 Android 后台长时安装回归。Codex 卸载当前会删除共享托管 root，因此也会
  移除其中的 OpenCode 和共享 Node；OpenCode 独立卸载没有这个范围问题。
- 终端、SFTP 文件管理、后台前台服务、完成通知和 Debug 日志分享已有实现，但缺少 Android integration
  测试；通知权限、进程被杀、厂商省电、长时 PTY 和大文件行为仍需真机回归。
- Markdown 远程绝对文件链接和独立文件管理都已有受限 SFTP/Android SAF 链路，但尚未完成真机大文件、
  断线和不同厂商文件选择器回归。
- 附件已完成选择、上传中状态、移除、待发、发送和失败恢复链路，但缺少 picker/Widget 自动化覆盖；
  子 Agent 已有真实 child thread 导航和父子返回栈，但尚未完成真实服务器长时间嵌套与大历史回归。
- thread/list 下一页入口已接入 Flutter 列表，按 lane 游标分页并自动去重；resume 已有有界通知缓冲、
  快照协调和顺序重放，OpenCode bridge 也会投影 `initialTurnsPage` 并遵守 `itemsView`，但超大活动
  会话、分页游标失效、缓冲溢出和降级链仍需真实服务器压测。
- 应用内更新已接入 Gitee 检查、DownloadManager 和系统安装器；下载任务以受校验记录跨进程持久化并在
  启动时重绑，返回/取消安装可再次打开。真实网络、未知来源权限拒绝/返回、包签名校验和稳定证书覆盖安装
  仍需真机回归。
- 没有 Android integration/golden/完整 Work、文件管理或终端 Widget 测试；模拟器 smoke 只验证启动、
  方向、包名和 Crash/ANR，不代表真实 Agent 或应用内更新系统流程。本轮 358 项 Flutter test、release APK
  和 1220x2712/2712x1220 模拟器 smoke 已通过，仍不能替代真实服务器和 Android 真机端到端验收。
- 当前 Flutter OpenCode adapter 和打包 bridge 已接线，Node quick gate 也有通过记录；这些自动 fixture、
  server/ 或旧 app/ smoke test 都不能替代授权真实服务器与 Android 端到端验收。
- Flutter iOS 目录是生成骨架，未作为可发布 iOS 版本验收。
- 远程 app-server、OpenCode bridge 和 Codex CLI 协议仍可能变化，必须固定版本并审核 schema 差异。
- Android 厂商省电、强停、网络切换仍可能中断后台 SSH；不得承诺绝对不掉线。

### 17.1 本轮验收记录（2026-08-09）

- 应用版本：`1.8.13+134`。
- Flutter 测试：358 项通过；`flutter analyze` 无问题；Android Kotlin 编译和 release APK 构建通过。
- 模拟器：Android 14，竖屏 `1220x2712`、横屏 `2712x1220` smoke 通过，未发现 FATAL 或 ANR。
- 后台 SSH 实测：Debug 版 Home 后台 65 秒、正式版根页面系统 Back 后台 35 秒，以及 Android 14
  `removeTask` 销毁任务后，前台 Service、partial wake lock、App 进程和同一组服务端 sshd PID 均保持；
  重新打开后复用连接并显示已连接，未发现 `StreamSink is bound to a stream`、FATAL、ANR 或
  `MissingPluginException`。强制停止或系统杀死整个进程仍会断开，这是 Android 进程边界内的预期行为。
- SSH 意外断线恢复实测：在真实 Codex Work 页面从服务端终止 sshd 子进程，前台约 `1.03` 秒恢复；Home
  后台两轮分别约 `2.06` 秒和 `1.33` 秒恢复，正式包同场景约 `0.44` 秒恢复。最新 Debug 构建恢复后继续
  后台 65 秒，App 进程、前台 Service、partial wake lock 和新 sshd PID 均保持，重新打开仍为原 Work
  会话；诊断日志完整记录
  `reconnect_scheduled -> reconnect_attempt -> SSH/Agent connected -> reconnect_success`，未发现 Zone mismatch、
  `StreamSink is bound to a stream`、FATAL、ANR 或二次断线。
- 本机 `codexemu` 端到端：进入 Work、发送、运行中白色耗时圈、停止、返回列表、重新进入和保留数据的
  冷启动均通过；未发现 `StreamSink` 或 SSH 状态异常。
- 本轮再次连接本机 `codexemu`，进入真实 Codex 历史会话并截图核对顶部菜单和 Composer：顶部菜单宽
  196 dp、行高 48 dp；底部加号/更多为 36 dp，权限高 36 dp，输入区只有一层外框；约
  `873x2048` 的窄屏 Widget 画布也无布局溢出。
- `1.8.13` 再次在真实 `1220x2712` Work 页面核对 Composer：上下文圆环和模型靠右，权限文字完整，
  `5.6-Sol 低` 全量显示；运行态切换停止按钮不改变布局。约 `873x2048` 的 Widget 画布使用更长的
  `5.6-Terra-Preview 极高` 验证圆环不会越过权限、模型不会侵入发送按钮且单行不溢出；圆环中心显示
  服务器返回的真实已用百分比，未知用量显示 `?`。
- APK：本轮发布后以 `dist/Agent-1.8.13.apk` 为准；SHA-256 记录在
  `dist/local-release-metadata.txt`，交付时必须同时核对内网和外网下载结果。

### 17.2 页面对齐验收（2026-08-10）

- 应用版本：`1.8.14+137`。
- 服务器列表和任务列表逐项对照旧 Compose 源码与用户提供的 `1172x2748` 截图；服务器品牌栏、推广块、
  服务器整卡、Debug 行，以及任务页顶栏、资源行、Agent 分段控件、搜索框和任务行均恢复旧版布局。
- Android 14 模拟器使用 `1172x2748`、480 dpi（约 390 dp 宽）连接本机 `codexemu`，逐页截图确认无重叠、
  截断、双层输入框或过亮分隔线；标准竖屏与横屏 smoke 同时通过。
- Flutter 362 项测试通过，`flutter analyze` 无问题；新增“返回服务器后复用 Agent 快照”回归测试，
  Release APK 构建、稳定签名和下载哈希由本机发布流程验证。
- APK 以 `dist/Agent-1.8.14.apk` 为准；SHA-256 记录在 `dist/local-release-metadata.txt`。

### 17.3 后台对话链路验收（2026-08-10）

- 应用版本：`1.8.15+138`。
- Flutter 生产 Agent lane 改为持有独立 SSH transport，与旧版 JSch 的 Host/Agent 双连接边界一致；Host
  指标、SFTP 或终端连接意外断开时不再关闭正在工作的 Agent turn，显式断开仍会同时清理两条连接。
- Android 前台 Service 分别保活 retained Host 与 Agent transport；Agent 心跳与 JSONL 写入串行化，避免
  心跳写入和 app-server 请求竞争同一个 SSH channel。
- Android 14 模拟器连接本机 `codexemu`，真实 Codex turn 运行期间先后置于后台约 4 分钟和 2 分钟；恢复
  前台后 turn 仍保持运行，诊断日志无 Agent/SSH 断开、重连、进程重启、FATAL 或 ANR。
- Flutter 365 项测试、`flutter analyze`、Android Debug APK、竖屏/横屏 smoke 和本地发布门禁均通过；APK
  以 `dist/Agent-1.8.15.apk` 为准，SHA-256 记录在 `dist/local-release-metadata.txt`。

### 17.4 后台心跳背压验收（2026-08-10）

- 应用版本：`1.8.16+139`。
- Android Service 的 MethodChannel 心跳改为单请求在途，Flutter isolate 暂停期间不再积压调用；Agent
  keepalive 也会合并尚未完成的请求，防止 App 回到前台时批量 SSH 心跳导致 Agent transport 断开。
- Codex app-server 的 stderr 会去除 ANSI/控制字符并写入 `AgentStderr` Debug 日志，不再用红色诊断覆盖
  仍可工作的对话页；真正的连接中断仍进入恢复状态机。
- Android 14 模拟器连接本机 `codexemu`，后台约 8 分钟后热恢复；App PID 与前台 Service 未变化，Host
  和 Agent 全程保持连接，日志无断开、重连、心跳失败、FATAL 或 ANR。
- Flutter 368 项测试、`flutter analyze`、Android Debug/Release APK 和竖屏/横屏 smoke 均通过；发布产物
  为 `dist/Agent-1.8.16.apk`，SHA-256 是
  `7262f882ffb0ebb45634787bfe84549e19e9796550232341237c859680336828`，稳定签名及内外网下载回验通过。

### 17.5 后台连接关联诊断（2026-08-10）

- 应用版本：`1.8.17+140`。
- Android Service 为每次心跳分配递增 sequence，记录原生 dispatch、在途跳过次数、MethodChannel 完成结果
  和耗时；Flutter 同一 sequence 记录接收延迟、生命周期以及 retained Host/Agent 每条 lane 的开始、成功、
  失败和耗时，可以区分原生调度暂停、Dart isolate 延迟与具体 SSH transport 失败。
- Host/Agent keepalive 异常不再在 manager 内吞掉，而是向心跳调用者传播并写入诊断日志；既有 transport watcher
  仍负责状态转换和自动恢复，不把心跳异常投影为页面错误。
- Agent 专用 SSH socket 的 `done` 结果单独写入 `AgentTransport transport_closed/transport_error`，保留底层
  关闭原因并与 `Agent connection_lost`、SSH 状态和心跳 sequence 对齐。
- Flutter 371 项测试、`flutter analyze`、Android Debug/Release 构建、Android 14 模拟器竖屏/横屏 smoke 和
  内外网 HTTP 200 回验均通过。APK 为 `dist/Agent-1.8.17.apk`，SHA-256 为
  `d2e423401fce929faa353d4c49511739e6ecb03c8723f6d39831a2c59e15e8f1`；稳定证书 SHA-256 为
  `72722218709a6d7fd0e80b944903ae2961b4cfa8abe03586f602acdc1ea0f52a`。

### 17.6 Android TCP 内核保活（2026-08-10）

- 应用版本：`1.8.18+141`。
- `DartSshServerClient` 不再直接使用 dartssh2 的裸 `Socket.connect`，而是在 SSH 握手前为底层
  Linux/Android socket 设置 `SO_KEEPALIVE`、`TCP_KEEPIDLE=30s`、`TCP_KEEPINTVL=10s`、
  `TCP_KEEPCNT=3` 和 `TCP_NODELAY`。这条保活链路不依赖 Dart Timer 或 Flutter Activity 是否处于 paused。
- 若厂商内核拒绝某个 TCP 调优选项，会保留 SSH 连接并回退到 SSH global-request 心跳，不影响前台连接。
- 本轮 UI 不变；定向 SSH/Agent/Controller 测试 106 项以及 Flutter 全量 371 项测试均通过，
  `flutter analyze`、Android Debug/Release 构建、Android 14 模拟器竖屏/横屏 smoke 和内外网 HTTP 200
  回验均通过。APK 为 `dist/Agent-1.8.18.apk`，SHA-256 为
  `5b8b1700d8f1ff1a12f9ebb03bcc0a0cb253186d632a8e2e4b97376ca9f9f4d4`；稳定证书 SHA-256 为
  `72722218709a6d7fd0e80b944903ae2961b4cfa8abe03586f602acdc1ea0f52a`。

### 17.7 Codex turn 持久化与列表恢复（2026-08-10）

- 应用版本：`1.8.19+142`。
- 真机日志确认厂商锁屏会同时中止 Host/Agent 两条 SSH socket（`errno=103`），Android 心跳正常送达也无法
  阻止；因此 Codex app-server 改为远端私有 Unix listener，SSH 仅承载可重建的 WebSocket forward。
- 意外断线保留远端 app-server/turn，重连后复用 socket 并 resume；显式断开清理远端进程，不支持 Unix
  forwarding 时有界回退 stdio。
- 会话列表恢复不再清空或自动刷新已有 lane 缓存；截图所示断线状态下保留最近任务，连接操作仍禁用。
- WebSocket 握手/掩码/JSONL 桥接、durable 命令与清理、自动恢复缓存策略已有定向测试；Flutter 全量
  374 项测试、`flutter analyze`、Debug/Release 构建、Android 14 模拟器竖横屏 smoke 和内外网发布回验
  通过。APK 为 `dist/Agent-1.8.19.apk`，SHA-256 为
  `e362d416cd0f36946cee5d844b189850407eb2df1def4628d663f1755fc7cc56`，证书 SHA-256 为
  `72722218709a6d7fd0e80b944903ae2961b4cfa8abe03586f602acdc1ea0f52a`。目标服务器上的真实 Unix listener、
  60 秒 turn 锁屏与断线重连仍须通过 `durable_transport=unix_socket` 日志真机验收。

### 17.8 服务器资源行紧凑布局（2026-08-10）

- 应用版本：`1.8.20+143`。
- 服务器卡片的 CPU、内存、磁盘和网络指标改为按内容宽度紧凑排列并整体左对齐，不再由四个等宽区域
  拉伸到整行；新增竖屏 Widget 回归，约束相邻指标间距和网络指标的左侧位置。
- 后续模拟器 UI 验收只覆盖目标竖屏，脚本、Widget 测试和工作流文档均移除横屏门禁；历史版本中已完成的
  横屏记录保留为当时事实。
- 定向 8 项测试和 Flutter 全量 375 项测试通过，`flutter analyze`、Android Debug/Release 构建及 Release
  竖屏模拟器 smoke 通过。APK 为 `dist/Agent-1.8.20.apk`，SHA-256 为
  `d6c620d74dae601a4f9b63a65d68c5284d64d8f089358db010cc7fd3663c2b74`；稳定签名及内外网下载回验通过。

### 17.9 对话链接与远程图片预览（2026-08-10）

- 应用版本：`1.8.21+144`。
- GFM 裸链接扩展允许 HTTP/HTTPS URL 紧邻中文标点，`内网：http://...` 等文本可点击并继续使用既有外部
  浏览器确认框；显式 Markdown 链接行为不变。
- 远程绝对路径链接按保守图片扩展名分流：PNG/JPG/WebP/GIF/BMP 直接加载到 Work 页缩放预览，其他文件
  继续使用系统文件导出。交互测试确认图片链接不会启动文件保存器。
- 定向 15 项测试和 Flutter 全量 377 项测试通过，`flutter analyze`、Android Debug/Release 构建及 Debug/
  Release 竖屏模拟器 smoke 通过。APK 为 `dist/Agent-1.8.21.apk`，SHA-256 为
  `1da16324fb4950dd770ce2dc2b8b06044e7b9d04e05f5c12db56013e4a7eda0f`；稳定签名及内外网下载回验通过。
- 本轮修改后计时：格式化与依赖解析 `15.328s`，定向测试 `19.751s`，Debug 全门禁成功轮 `112.004s`，
  Release 发布 `292.379s`。返工包括错误工具路径 `0.003s`、首轮 lint 失败 `26.656s` 和 lint 复核
  `4.068s`；`check` 与 `publish` 仍重复运行 analyze、全量测试和 Debug 构建，是后续主要优化点。

### 17.10 本地修改流程优化验收（2026-08-10）

- 应用版本保持 `1.8.21+144`；本轮只修改工作流脚本和文档，没有发布 APK，也没有更新本机 HTTP 下载包。
- `check` 首次完整验证耗时 `107.346s`：OpenCode full `14.418s`、Android Debug 门禁 `65.021s`
  （依赖 `1.267s`、analyze `3.844s`、377 项测试 `32.052s`、Debug 构建 `26.855s`）、Debug 竖屏
  smoke `22.110s`，其余暂停模拟器、释放 Gradle、CodeGraph 和调度合计 `5.797s`。
- `check` 后的只读计划为 `validation=reuse:debug debug=skip release=build`。随后 `full` 只解析依赖
  `1.274s` 并构建 Release `26.737s`，没有重复 analyze、377 项测试或 Debug 构建；含 Release 竖屏
  smoke 的总耗时为 `52.220s`。
- `full` 后计划为 `validation=cached debug=skip release=skip cacheHit=1`。工作流语法和自测通过，阶段记录
  写入 `.workflow-cache/latest-workflow-timing.tsv` 与 `.workflow-cache/workflow-timings/`。

### 17.11 Work 对话首屏与历史分页定位（2026-08-11）

- 应用版本保持 `1.8.21+144`，本轮不发布 APK、不修改连接恢复逻辑。
- 会话切换或恢复时，时间线先保持不可见并等待内容尺寸建立，再直接跳到 `maxScrollExtent`；首屏锚定完成后才显示列表，
  不再出现先停在顶部、随后内容整体向下掉落的首帧闪动。用户滚动状态由 `UserScrollNotification` 单独记录，布局变化和
  程序化补偿不会误判为用户离开底部。
- 顶部历史分页记录请求前的 `pixels` 与 `maxScrollExtent`，加载后只按新增 extent 补偿原位置；Sliver 子项和尾部 spacer
  提供稳定 key/index 映射，分页后原可见消息保持原屏幕位置，不会自动回到底部。刷新控件在收起动画完成前保持挂载，避免
  cursor 用尽时重建 sliver 造成几何跳变。
- 新增 loading -> 已加载首屏回归和受控竖屏下拉分页回归；WorkScreen 定向 7 项、Flutter 全量 379 项测试、`flutter analyze`、
  Android Debug 构建及 Android 14 模拟器竖屏 smoke 全部通过。横屏本轮按产品约束不验收。
- 本轮从 `2026-08-11T01:00:27.847Z` 首次修改计时至 `2026-08-11T01:18:xxZ` 完成，约 `18m`：问题定位与方案约 `4m`，首轮实现
  与测试约 `8m`，分页测试手势返工约 `2m`，定向验证约 `1m`，`check`（含全量测试、Debug 构建、竖屏 smoke、CodeGraph）约 `1m43s`。
  后续同类 UI 修改应先跑相邻 Widget 测试，再按 `docs/LOCAL_WORKFLOW.md` 只执行一个主门禁。

### 17.12 Work 历史下拉状态机对齐（2026-08-11）

- 应用版本：`1.8.21+148`。Flutter 历史下拉不再依赖越过阈值便立即回调的
  `CupertinoSliverRefreshControl`，改为复用旧 Compose 的释放触发语义：真实顶部 overscroll 达到阈值后
  显示“松开加载更多”，抬手前不请求；回拉到阈值以内会取消；手势从列表中间开始也能在到达顶部后继续下拉。
- 会话首屏恢复不可见锚定后一次性跳到最新消息，移除布局尺寸每次变化都强制纠正到底部的自定义
  `ScrollPosition`。分页加载期间首部 sliver 保留指示区，完成后按新增 extent 补偿，原可见消息保持位置。
- WorkScreen 定向 12 项和 Flutter 全量 384 项测试通过，`flutter analyze` 无问题；Debug/Release APK、
  Android 14 Release 竖屏 smoke、稳定发布与 `agent.apk` 内外网 HTTP 200 回验通过。横屏按产品约束未测试。
  APK SHA-256 为 `175eb13a07207b0aca0ade6e0e2366e03837c13c6f6023fef0bc80f92e6a4821`。
- 从第一次写文件到下载回验约 `39m34s`：实现、返工与定向验证约 `31m19s`，唯一一次 publish 主门禁
  `6m26.013s`，最终 `agent.apk` HTTP/哈希回验约 `1m49s`。publish 内部阶段为 OpenCode `14.758s`、
  暂停模拟器 `21.284s`、Android 全门禁 `147.316s`、Release 竖屏 smoke `43.366s`、本地发布及下载回验
  `158.221s`；本轮主要返工是先采用内置刷新控件，随后从 Flutter 源码确认其越阈值立即触发而改写状态机。

### 17.13 Markdown URL 边界修复（2026-08-11）

- 应用版本：`1.8.23+150`。修复自定义中文标点自动链接语法取消上游前置字符边界的问题；此前
  `[URL](URL)` 会被拆成普通文本和链接节点，导致对话里显示方括号、括号和重复 URL。
- 自动链接现在恢复 GFM 的空白/分隔符边界，仅额外允许常用中文标点；标准 Markdown 链接和
  `内网：http://...` 裸链接均保持单一可点击节点。
- 新增 URL 标签回归测试；Flutter 全量 `385` 项、`flutter analyze`、Release 构建、竖屏模拟器安装验收及
  Agent 内外网 HTTP `200` 回验通过。APK SHA-256 为
  `e821e678ba40a5122892fc183f72f1e5cf121b3f2d7cb9184c07d47baefd71d1`。
- 从 `2026-08-11T08:58:02.113Z` 开始计时至 `2026-08-11T09:07:09.059Z` 完成，共 `9m06.946s`；
  定向复现与修复约 `1m`，主门禁 `302.10s`，安装、元数据和地址回验约 `7s`。

### 17.14 Work 连续历史分页锚点（2026-08-11）

- 应用版本：`1.8.24+151`。历史分页在手势抬起、加载 sliver 出现前记录当前第一页的稳定 row key；
  锚点基准取滚动视口顶部和固定内容边距，不再读取正处于 overscroll 拉伸中的消息坐标。触发分页时先
  结束顶部回弹，分页插入和加载指示区移除后各校正一次锚点，避免快速返回的第二页把回弹位移误算成
  新增历史高度并把列表夹到最底部。
- 滚动范围因变高历史项而在布局阶段重算时，滚动状态延后到当前 frame 结束后提交，避免布局期间
  `setState` 打断锚点校正。连续分页回归使用两页不同高度消息和真实下拉手势，并同时覆盖加载中重复
  下拉不并发、第二页游标耗尽后不发第三次请求、原可见首行坐标保持以及最新消息不进入视口。
- WorkScreen 定向 `13` 项、Flutter 全量 `386` 项测试和 `flutter analyze` 通过；Android 14 竖屏模拟器
  完成 Debug 安装、启动、连接本地 Codex、进入会话和最新消息落点检查，按产品约束未测试横屏。模拟器
  测试会话只有 4 条消息且没有历史游标，因此真实两页数据由受控 Widget 测试覆盖，不把启动 smoke
  记作分页实机验证。
- Debug `check` 用时 `1m30.698s`；强制 Release 门禁用时 `3m23.446s`，其中依赖解析 `1.397s`、
  analyze `4.067s`、全量测试 `34.330s`、Release 构建 `2m43.637s`。内网完整下载一次通过；外网 FRP
  约 `240KB/s`，两次受脚本 `180s` 超时/连接中断后以 `900s` 可续传校验完成，最终完整下载约
  `4m30s`。APK 为 `dist/Agent-1.8.24.apk`，内网、外网和构建产物 SHA-256 均为
  `5e3470a07ee05bc5c6655bb18a847d0d0cb4951b198ba6b7b0ccce5dc85196d0`。
- 本轮从 `2026-08-11T09:21:24.046Z` 第一次写文件开始计时，到
  `2026-08-11T10:42:10.924Z` 最终地址与差异检查完成，共 `1h20m46.878s`。实现、变高分页压力测试
  与定向返工到主门禁开始约 `52m50s`；其余时间用于 Debug/Release 门禁、竖屏模拟器真实连接与进入会话、
  两次外网超时诊断、最终完整下载哈希回验和文档收尾。

### 17.15 Work 对话滚动位置指示（2026-08-11）

- 应用版本：`1.8.25+152`。Work 对话时间线使用 Flutter `Scrollbar`，与消息列表共用同一个
  `ScrollController`；滑动时在右侧显示 4px 滑块，停止后淡出，不常驻显示轨道，并支持直接拖动滑块定位。
  本轮不修改历史分页锚点或连接恢复逻辑。
- Widget 回归验证滚动条和列表共用控制器、参数配置和真实滑动后的可见性。WorkScreen 定向 `13`
  项、Flutter 全量 `386` 项测试和 `flutter analyze` 通过；Android 14 竖屏模拟器完成 Debug 安装、启动和
  `v1.8.25` 版本显示验收，按产品约束未测试横屏。
- 从 `2026-08-11T10:59:57.312Z` 开始修改到 `2026-08-11T11:16:52.864Z` 发布与完整下载回验完成，
  共 `16m55.552s`：实现、定向验证、竖屏验收与收尾约 `8m02s`，Debug 主门禁 `1m42.356s`，
  Release 依赖解析与构建 `2m43.358s`，外网完整回下载 `4m28s`。
- APK 为 `dist/Agent-1.8.25.apk`，包内应用名为 `Agent`，`versionName=1.8.25`、`versionCode=152`；
  构建产物、内网发布文件和外网完整下载的 SHA-256 均为
  `cf91751b5678cf4740d942283e2965b84cae8babc31db6bad10a584cefb283f7`。

### 17.16 Work 历史加载区无跳帧收起（2026-08-11）

- 应用版本：`1.8.26+153`。历史页插入后的最终锚点坐标虽然正确，但旧 Flutter 实现会在加载完成时
  用一帧移除 108px 顶部加载区，肉眼会看到整段内容突然上跳。现在保持现有稳定 key 和分页锚点补偿，
  仅将加载区改为 `220ms` `easeOutCubic` 连续收起，并在这个收尾窗口内禁止第二个分页手势。
- 新增逐帧回归：数据返回的首帧仍保留加载区，接下来 16ms 帧的位移不得等于整段高度，动画结束后
  原消息回到原锚点。同时保留两页连续下拉、不同高度消息、加载中不重复请求和游标耗尽回归。
- WorkScreen 定向 `14` 项、Flutter 全量 `387` 项测试、`flutter analyze`、Debug/Release 构建和
  Android 14 竖屏模拟器安装启动通过；按产品约束未测试横屏。
- 从 `2026-08-11T11:29:40.531Z` 开始修改到 `2026-08-11T11:41:14.076Z` 发布与完整下载回验完成，
  共 `11m33.545s`：实现、定向测试、竖屏截图和元数据收尾约 `4m49s`，Debug 主门禁 `1m48.461s`，
  Release 依赖解析与构建 `2m48.711s`，外网完整回下载 `2m07s`。
- APK 为 `dist/Agent-1.8.26.apk`，包内应用名为 `Agent`，`versionName=1.8.26`、`versionCode=153`；
  构建产物、内网发布文件和外网完整下载的 SHA-256 均为
  `8634a0b16ae9e32cecdcb8d4362e79a061922c733979c92358010e6be9188bbc`。

### 17.17 Work 滚动诊断日志（2026-08-11）

- 应用版本：`1.8.27+154`。此前导出的诊断日志只包含生命周期、连接、心跳和页面导航，无法判断历史
  分页后的跳动发生在请求、布局、锚点选择还是位置补偿阶段。Debug 模式现在增加 `TranscriptScroll`
  日志；日志只记录状态和数字，不记录任何对话正文，关闭 Debug 后不写入。
- 诊断事件覆盖会话视口重置、首次定位到底部、用户/程序滚动起止、跟随输出状态变化、下拉阈值达到、
  释放、取消、分页锚点准备、顶部回弹归零、分页请求开始/结束/失败、分页前后布局、加载区收起和手动
  回到底部。关键事件同时记录 thread、`pixels/min/max`、`extentBefore/extentAfter`、viewport、分页前后
  条数和 cursor、锚点屏幕坐标、补偿策略与补偿量；不逐像素写日志，避免日志本身影响滚动性能。
- WorkScreen 定向 `16` 项、Flutter 全量 `389` 项测试和 `flutter analyze` 通过；Debug 构建及 Android 14
  竖屏模拟器安装、启动和 `v1.8.27` 版本显示通过，按产品约束未测试横屏。Release APK 通过内外网完整
  回下载和元数据核验，应用名为 `Agent`，`versionName=1.8.27`、`versionCode=154`。
- 本轮从 `2026-08-11T11:53:21.530Z` 第一次修改开始，到
  `2026-08-11T12:24:50.740Z` 最终回验和文档收尾完成，共 `31m29.210s`。实现、定向测试和首次门禁
  返工 `18m17.470s`；成功的 Debug 主门禁 `1m33.145s`，其中 Android Debug 门禁 `62.284s`、竖屏
  模拟器 smoke `28.271s`、CodeGraph 同步 `0.961s`；Release 构建 `2m43.371s`；外网完整回下载
  `2m15s`；本地发布、元数据核验、文档和最终差异检查约 `6m40s`。
- APK 为 `dist/Agent-1.8.27.apk`；构建产物、内网发布文件和外网完整下载的 SHA-256 均为
  `c7e36ccf8acc4bcb03fa9e5ddf7543cc00e2225364c60d681cb2bc3596251818`。

### 17.18 Work 滚动范围异常追踪（2026-08-11）

- 应用版本：`1.8.28+155`。`1.8.27` 实机日志已经确认历史分页时稳定锚点经常未挂载，代码退回
  extent 补偿；其中一次 `maxScrollExtent` 从约 `51,903` 瞬时变为约 `19,317,910`，补偿量也被算成
  `19,266,007`，布局恢复后当前位置被夹到底部并重新启用 follow。本轮只增强证据采集，不修改现有
  滚动或分页行为。
- `TranscriptScroll` 新增 `extent_sample` 和 `extent_anomaly`：记录每次 `ScrollMetricsNotification` 以及
  max extent 变化至少 `256px`、达到 `1,000,000px` 或 pixels 越界的滚动通知；字段包括前后 pixels、
  max、viewport 及其 delta、通知类型、outOfRange、分页/加载/首屏/follow 状态。刷新控件同时记录
  idle、refreshing、retracting、pointer、pulled 和 armed，区分异常发生在列表层还是加载控件层。
- 分页事件补充补偿前后 pixels、分页前后 max、deltaMax、越界状态以及锚点和 viewport RenderBox 的
  mounted、attached、hasSize、宽高和屏幕 dy；RenderBox 在布局阶段不可安全读取时只记录
  `unavailable`，诊断代码不会抛错或干扰布局。顶部加载区另外记录 visibility 切换和收起动画的
  controller、factor、高度及状态。日志仍不记录对话正文。
- WorkScreen 定向 `16` 项、Flutter 全量 `389` 项和 `flutter analyze` 通过；发布门禁完成 Debug/Release
  构建、稳定签名、Android 14 Release 竖屏安装启动和 `v1.8.28` 显示验收，按产品约束未测试横屏。
  内外网 `agent.apk`、构建产物、发布文件和 `dist/Agent-1.8.28.apk` 完整 SHA-256 一致，均为
  `c01df2781723a95bdb85318bbf7ee0bec46e1ababdca139d025d6cc671a56f1a`。
- 本轮从 `2026-08-11T12:36:21.843Z` 第一次修改开始，到
  `2026-08-11T13:09:54.647Z` 完成完整回验和文档收尾，共 `33m32.804s`。实现、诊断安全性返工、
  定向测试、analyze 和首次全量测试到发布门禁开始约 `19m04s`；唯一一次 publish 主门禁
  `6m17.232s`，其中暂停模拟器
  `16.221s`、Android full `3m00.258s`、Release 竖屏 smoke `22.040s`、CodeGraph `1.164s`、本地发布
  及其下载回验 `2m35.621s`；其余 `8m11s` 用于内外网 `agent.apk` 额外完整回下载、哈希和元数据
  复核、新事件定向断言、文档及最终差异检查，其中外网完整回下载约 `2m05s`。

### 17.19 Work 滚动日志降噪与位置标记（2026-08-11）

- 应用版本：`1.8.29+156`。`1.8.28` 实机日志确认 `pixels=82201.4`、`max=82197.7` 的约 `3.7px`
  底部回弹属于正常边界收敛，但父列表、刷新控件和 metrics 通知会在同一帧重复记录，使诊断日志快速
  轮转并挤掉分页事件。
- 刷新控件不再重复采样父列表已经接收的滚动 metrics。父列表只记录首个样本、显著的相对 extent 变化、
  `1,000,000px` 大范围状态切换和至少 `24px` 的越界状态切换；连续异常样本至少间隔 `500ms`，普通
  底部弹性回弹不再逐帧写日志。分页、锚点、加载区和 follow 状态事件保持完整。
- 每条 `TranscriptScroll` 关键事件新增 `location=top|middle|bottom`、归一化 `progress` 和 `overscroll`，
  可以直接判断当前滚动到列表顶部、中部还是底部；仍只记录状态与几何数字，不记录会话正文。
- WorkScreen 定向 `17` 项、Flutter 全量 `390` 项和 `flutter analyze` 通过；Debug/Release APK 构建、
  Android 14 Release 竖屏安装启动和 `v1.8.29` 显示验收通过，按产品约束未测试横屏。唯一一次
  `publish` 主门禁用时 `6m40.963s`：服务器/OpenCode 门禁均命中缓存，Android full `3m37.452s`、
  Release 竖屏 smoke `18.426s`、CodeGraph `0.889s`、本地发布和内外网回验 `2m39.437s`。
- APK 为 `dist/Agent-1.8.29.apk`，应用名 `Agent`，`versionName=1.8.29`、`versionCode=156`；构建产物、
  本地发布文件及内外网 `agent.apk` 完整回下载 SHA-256 均为
  `98397ec1a401c2533a22e6ce83e6d65e0a35e6ff41003ac375a1c2a1443a560b`。从第一次写文件到发布、
  别名完整回下载和最终检查约 `17m`，没有失败返工。

### 17.20 Work 历史分页固定中心（2026-08-11）

- 应用版本：`1.8.30+157`。`1.8.29` 实机日志确认分页跳底不是普通回弹：分页时旧锚点已经离开
  lazy sliver 的挂载范围，代码退回 `maxScrollExtent` 差值补偿；最后一页插入 36 条记录时估算范围从
  `13,451.1px` 瞬时增至 `36,770.8px`，错误补偿 `23,319.7px`，加载区收起后范围又降至
  `22,142.7px`，当前位置越界并把 follow 重新切到底部。
- 时间线改为两个 sliver，并以首批数据的第一条稳定 row 作为 `CustomScrollView.center`：现有消息从
  center 向下布局，后续加载的更早消息按反序增长在 center 上方。Flutter 直接保持中心坐标，不再读取
  lazy `SliverList` 的估算 extent，也不要求分页前的 GlobalKey 锚点仍挂载；诊断明确记录
  `strategy=center appliedDelta=0.0`。
- 顶部加载提示改为不参与滚动范围的覆盖层，避免提示收起改变 center 周围的内容间距；加载期间只拦截
  正文滚动，提示收起阶段即可继续下一次分页。回归覆盖连续两页、五页不同批量和不同高度消息、加载中
  重复手势、游标耗尽、加载提示收起及完整诊断链，并断言旧可见行保持坐标且列表不会落到底部。
- WorkScreen 定向 `18` 项、Flutter 全量 `391` 项和 `flutter analyze` 通过；Debug/Release APK 构建、
  Android 14 Release 竖屏安装启动和 `v1.8.30` 显示验收通过，按产品约束未测试横屏。唯一一次
  `publish` 主门禁用时 `6m47.768s`，其中 Android full `3m38.861s`、Release 竖屏 smoke
  `20.173s`、CodeGraph `0.880s`、本地发布和默认下载回验 `2m41.057s`。内外网 `agent.apk` 又分别
  完整回下载并核对哈希；应用名 `Agent`、包名 `top.asdb.agent`、`versionName=1.8.30`、
  `versionCode=157`，稳定签名证书未变化。
- APK 为 `dist/Agent-1.8.30.apk`；构建产物、本地发布文件及内外网 `agent.apk` 完整回下载 SHA-256
  均为 `e3203d611e19932ed260440eafb02454d3421504c828ef6788fbf27dd1c0e948`。

### 17.21 Work 首屏底部原点（2026-08-11）

- 应用版本：`1.8.31+158`。`1.8.30` 修复分页跳底后，实机日志又发现从会话列表打开拥有大量缓存消息的
  会话时，首帧先按懒列表估算的 `maxScrollExtent` 跳到底部；`max` 随后从 `27,570.1px` 膨胀到
  `3,114,064.0px`，再回落到 `113,845.5px`，同时视口因输入框 inset 缩小，造成内容从上方连续冒出。
- 时间线改为尾部空 center sliver，设置 `anchor=1.0`，所有消息反向布局在 center 上方。进入会话时
  `pixels=0/max=0` 已经是底部，首屏不再依赖 `jumpTo(maxScrollExtent)`；跟随输出和回到底部按钮统一
  使用固定的 `0.0` 原点，只有用户确实离开底部时才发生滚动。
- 新增 253 条异高缓存消息的逐帧回归，覆盖缓存加载、数据完成和 `300px` 输入框 inset 动画；每一帧
  均保持 `pixels=0/max=0`，同时保留连续历史分页、异高分页锚点和滚动条测试。
- WorkScreen 定向 `19` 项、Flutter 全量 `392` 项和 `flutter analyze` 通过；Debug/Release APK 构建、
  Android 14 Release 竖屏安装启动和 `v1.8.31` 显示验收通过，按产品约束未测试横屏。唯一一次
  `publish` 主门禁用时 `6m48.154s`，其中 Android full `3m41.211s`、Release 竖屏 smoke
  `20.273s`、CodeGraph `0.911s`、本地发布和默认下载回验 `2m39.005s`。
- 内外网 `agent.apk` 均完成整包回下载，且与 `dist/Agent-1.8.31.apk` 一致：文件大小
  `67,190,311` 字节，SHA-256 为 `c78b676e149d871bf552467019dfbd57de69df58caca729e39f5d7c2fb42f84d`。
  应用名为 `Agent`、包名 `top.asdb.agent`、`versionName=1.8.31`、`versionCode=158`；稳定签名证书
  SHA-256 为 `72722218709a6d7fd0e80b944903ae2961b4cfa8abe03586f602acdc1ea0f52a`，未发生变化。
- 本轮从第一次写文件到发布、双地址整包下载和最终检查约 `44m27s`；没有失败门禁或重复发布。

### 17.22 Work 链接、短会话与发送回显（2026-08-11）

- 应用版本：`1.8.32+159`。普通 HTTP/HTTPS Markdown link 不再把目标 URL 复制到下一行；label 后面的
  中文说明保持普通文本和标准链接边界，远程绝对文件路径的 App 内安全链接转换不变。
- 固定尾部 center sliver 继续为长会话提供 `pixels=0/max=0` 的稳定底部原点；短会话在隐藏首帧读取消息
  sliver 的真实高度，用精确尾部 gap 补满剩余视口，因此首条消息从顶部开始。gap 会随消息和键盘 inset
  增减，不满一屏时保持顶部，超过一屏后归零并显示最新消息。
- Codex 用户消息的 `item/started` 允许空 content。Reducer 现在把这个带服务器 item id 的 started 事件
  合并进最近的 `local-user-*` 乐观行，随后同 id 的 completed 补全正文，避免发送后临时出现两条相同输入；
  重新进入会话时的服务器快照行为不变。
- Markdown、Reducer 和 WorkScreen 定向 `38` 项、Flutter 全量 `395` 项、`flutter analyze`、Debug/Release
  构建和 Android 14 Release 竖屏 smoke 全部通过。唯一一次 `publish` 主门禁用时 `6m45.368s`，其中
  Android full `3m43.983s`、Release smoke `20.164s`、CodeGraph `0.994s`、本地发布和默认下载回验
  `2m34.500s`。
- `dist/Agent-1.8.32.apk`、内网和公网 `agent.apk` 整包回下载一致，大小 `67,190,307` 字节，SHA-256
  为 `2d93965316ff872b485a2670f84ebfb8430f5ee9187c52f830b68ef90d4a5816`。应用名 `Agent`、包名
  `top.asdb.agent`、`versionName=1.8.32`、`versionCode=159`，稳定签名证书未变化。
- 本轮从第一次写文件到发布、双地址整包回下载、元数据和最终差异检查约 `29m34s`；主门禁一次通过。

### 17.23 诊断日志分享选择器（2026-08-12）

- 应用版本：`1.8.33+160`。Flutter 诊断日志分享选择器对齐原生参考布局：宽版圆角弹窗、时间与人类可读大小两行展示、活动日志显示“当前记录中”，不再展示内部 `session-...` 文件名。
- 分享入口默认不预选日志，底部仅提供“取消 / 分享”，未选择时分享按钮禁用；工作页附件入口继续预选最近崩溃日志并保留附件数量上限。
- 列表使用固定行高和受限可滚动区域，覆盖窄屏与长列表；Widget 回归验证 B/KB 大小、当前记录颜色、选择状态、附件限制和无溢出滚动。
- 定向 `4` 项、Flutter 全量 `397` 项、`flutter analyze`、Debug/Release 构建和 Android 14 Release 竖屏 smoke 全部通过。唯一一次 `publish` 主门禁用时 `6m46.205s`，其中 Android full `3m41.154s`、Release smoke `22.447s`、CodeGraph `0.265s`、本地发布和默认下载回验 `2m33.558s`。
- `dist/Agent-1.8.33.apk`、内网和公网 `agent.apk` 整包回下载一致，大小 `67,223,079` 字节，SHA-256 为 `440ce2ee7f273641ddd8169a54f9596a2b732df34ae35f9b6876cd918f001df8`。应用名 `Agent`、包名 `top.asdb.agent`、`versionName=1.8.33`、`versionCode=160`，稳定签名证书未变化。

### 17.24 Work 弹窗锚定对齐（2026-08-12）

- 应用版本：`1.8.34+161`。Work 页右上角会话菜单改为明确锚定在按钮下方，保留 `8dp`
  间距并关闭弹出动画，点击后在同一帧直接显示；菜单宽度、图标和行高保持旧 Compose 页面的
  视觉层级。
- 输入区会话操作菜单固定为 `144dp` 窄菜单并在三点按钮上方展开；恢复与旧版一致的目标、
  压缩会话、选择模型和权限项及图标，并按当前 capability/目标状态动态计算向上偏移。上下文
  用量弹窗恢复约 `232dp` 宽度、相对圆环向左 `200dp` 且向上展开的旧版位置。
- 新增 `420x840` Widget 几何回归，精确断言三个弹窗相对触发按钮的上下方向、左右对齐、
  宽度和间距，并验证右上角菜单无动画。WorkScreen 定向 `21` 项、Flutter 全量 `398` 项、
  `flutter analyze`、Debug/Release 构建和 Android 14 Release 竖屏 smoke 全部通过。唯一一次
  `publish` 主门禁用时 `7m03.643s`，其中 Android full `3m38.995s`、Release smoke `26.096s`、
  CodeGraph `1.216s`、本地发布和默认下载回验 `2m39.334s`。
- `dist/Agent-1.8.34.apk`、构建产物、本地发布文件及内外网 `agent.apk` 独立整包回下载一致，
  大小 `67,305,083` 字节，SHA-256 为
  `5182daff845802d95a7be79116b92cd7fde268d4ce873a436cfa5a0db9581773`。应用名 `Agent`、包名
  `top.asdb.agent`、`versionName=1.8.34`、`versionCode=161`，稳定签名证书未变化。

### 17.25 Work 用量弹窗与链接展示修正（2026-08-12）

- 应用版本：`1.8.35+162`。上下文用量弹窗固定为 `196dp` 宽，在圆环正上方展开；弹窗与圆环的
  水平中心误差不超过 `1dp`，不再偏向圆环左侧。输入区“权限”左侧的三点菜单关闭弹出动画，
  点击后同一帧直接显示。
- 普通 HTTP/HTTPS Markdown 命名链接同时展示链接名称和完整目标地址，名称与地址都可点击，且地址
  链接边界不会吞入后续中文标点；名称本身已经是目标 URL 时不重复显示，App 内远程文件链接仍保持
  原有隐藏目标地址的安全行为。
- Markdown 与 WorkScreen 定向 `28` 项、Flutter 全量 `398` 项、`flutter analyze`、Debug/Release
  构建和 Android 14 Release 竖屏 smoke 全部通过。唯一一次 `publish` 主门禁用时 `6m54.704s`，
  其中 Android full `3m36.040s`、Release smoke `22.391s`、CodeGraph `0.913s`、本地发布和默认
  下载回验 `2m40.500s`。
- `dist/Agent-1.8.35.apk`、构建产物、本地发布文件及内外网 `agent.apk` 独立整包回下载逐字节一致，
  大小 `67,305,083` 字节，SHA-256 为
  `22246806e28d9e2a3c006f5a973e608fb5b533ba031c5c8c10d52b87fdad0d9f`。应用名 `Agent`、包名
  `top.asdb.agent`、`versionName=1.8.35`、`versionCode=162`；稳定签名证书 SHA-256 为
  `72722218709a6d7fd0e80b944903ae2961b4cfa8abe03586f602acdc1ea0f52a`。

### 17.26 会话列表相对时间与返回刷新（2026-08-12）

- 应用版本：`1.8.36+163`。会话列表右侧更新时间不再显示当天时刻或月/日，统一按当前时间显示
  “刚刚 / N 分钟 / N 小时 / N 天 / N 周 / N 个月”；兼容秒和毫秒时间戳，未来时间按“刚刚”
  处理，列表保持打开时每分钟自动重算可见文案。
- 从普通对话返回会话列表时，先立即展示保留的列表快照，再在后台静默请求当前搜索条件的第一页；
  成功后同步会话的更新时间、摘要、状态及服务端排序，失败时保留原列表且不显示全屏加载动画。
  若用户在静默刷新期间立即滚到底部，分页会先等待第一页完成，再使用新的 cursor，避免旧游标丢页。
- 相对时间单元测试覆盖秒/毫秒输入和全部显示档位，Widget 回归覆盖页面保持打开时的分钟更新；控制器
  回归验证返回列表不闪空并采用服务端的新更新时间，同时保留返回后立即分页的并发测试。
- Flutter 全量 `401` 项、`flutter analyze`、Debug/Release 构建和 Android 14 Release 竖屏 smoke
  全部通过。唯一一次 `publish` 主门禁用时 `6m40.845s`，其中 Android full `3m36.115s`、
  Release smoke `22.164s`、CodeGraph `1.093s`、本地发布和默认下载回验 `2m35.722s`。
- `dist/Agent-1.8.36.apk`、构建产物、本地发布文件及内外网 `agent.apk` 独立整包回下载逐字节一致，
  大小 `67,370,619` 字节，SHA-256 为
  `d0d735e68c47c91ad214ff2723d7e7ef3483953a087d0e5b803597ab028f26f5`。应用名 `Agent`、包名
  `top.asdb.agent`、`versionName=1.8.36`、`versionCode=163`；稳定签名证书 SHA-256 为
  `72722218709a6d7fd0e80b944903ae2961b4cfa8abe03586f602acdc1ea0f52a`。

### 17.27 会话列表下拉刷新（2026-08-12）

- 应用版本：`1.8.37+164`。已连接 Agent 的会话列表支持从顶部下拉刷新；长列表、短列表及空结果
  都使用可下拉滚动物理效果，松手后复用第一页静默刷新，因此当前会话内容保持可见，不切换到全屏
  加载状态。
- 下拉方向与到底分页明确隔离：只有朝列表底部滚动且剩余范围不足 `240dp` 时才加载下一页，顶部
  下拉不会误触发分页；顶部刷新按钮继续保留并与手势刷新共享请求去重逻辑。Widget 回归直接对短
  列表执行下拉手势，验证只触发一次静默刷新且原会话仍然显示。
- Flutter 全量 `402` 项、`flutter analyze`、Debug/Release 构建和 Android 14 Release 竖屏 smoke
  全部通过。唯一一次 `publish` 主门禁用时 `6m56.777s`，其中 Android full `3m39.121s`、
  Release smoke `26.276s`、CodeGraph `0.624s`、本地发布和默认下载回验 `2m34.840s`。
- `dist/Agent-1.8.37.apk`、构建产物、本地发布文件及内外网 `agent.apk` 独立整包回下载逐字节一致，
  大小 `67,387,007` 字节，SHA-256 为
  `851cb679bea832ed41204d3432c330b62211aadaff7856cbc00328f5a0284bd0`。应用名 `Agent`、包名
  `top.asdb.agent`、`versionName=1.8.37`、`versionCode=164`；稳定签名证书 SHA-256 为
  `72722218709a6d7fd0e80b944903ae2961b4cfa8abe03586f602acdc1ea0f52a`。

### 17.28 下载链接样式与刷新入口收敛（2026-08-12）

- 应用版本：`1.8.38+165`。普通 HTTP/HTTPS 命名链接改为“普通正文标题 + 下一行完整 URL 链接”，
  不再把“内网下载 / 公网下载”等标题误渲染为蓝色链接；完整 URL 仍可点击和复制。App 内远程
  文件链接继续使用内部安全链接和原有预览/下载处理。
- 会话列表顶部刷新图标已移除，刷新入口统一为列表下拉手势；搜索提交、返回列表静默刷新和底部
  分页逻辑不变。
- Markdown、WorkScreen 与会话列表定向 `38` 项、Flutter 全量 `402` 项、`flutter analyze`、
  Debug/Release 构建和 Android 14 Release 竖屏 smoke 全部通过。成功的 `publish` 主门禁用时
  `6m41.222s`，其中 Android full `3m30.291s`、Release smoke `26.328s`、CodeGraph `0.727s`、
  本地发布和默认下载回验 `2m42.179s`。
- `dist/Agent-1.8.38.apk`、构建产物、本地发布文件及内外网 `agent.apk` 独立整包回下载逐字节一致，
  大小 `67,387,003` 字节，SHA-256 为
  `a1b195351d26edf26b0225638ffab2c1a95f7f7b798607eea705f719731c4cfd`。应用名 `Agent`、包名
  `top.asdb.agent`、`versionName=1.8.38`、`versionCode=165`；稳定签名证书 SHA-256 为
  `72722218709a6d7fd0e80b944903ae2961b4cfa8abe03586f602acdc1ea0f52a`。

### 17.29 会话区域跟手下拉刷新（2026-08-12）

- 应用版本：`1.8.39+166`。下拉刷新由列表内部的小型 `RefreshIndicator` 改为会话区域级跟手容器；
  搜索框及其上方区域保持固定，搜索框下方的“最近任务 / 数量”、诊断信息和整个会话列表随手势一起
  下移。
- 刷新头按拖动状态显示“下拉刷新 / 松开刷新 / 正在刷新”，越过 `72dp` 阈值后松手触发静默刷新；
  请求期间会话区域固定保留 `52dp` 刷新头，完成后用 `220ms` 动画回位。列表使用 Clamping 物理
  效果，避免系统 overscroll 与自定义位移叠加；底部分页规则保持不变。
- Widget 回归使用可控刷新请求，验证搜索框坐标不变、会话标题跟手下移、三段刷新文案、静默请求和
  完成回位。
- 会话列表定向 Widget `10` 项、Flutter 全量 `402` 项、`flutter analyze`、Debug/Release 构建和
  Android 14 Release 竖屏 smoke 全部通过。成功的 `publish` 主门禁用时 `7m04.190s`，其中
  Android full `3m51.207s`、Release smoke `26.190s`、CodeGraph `0.636s`、本地发布和下载回验
  `2m36.444s`。
- `dist/Agent-1.8.39.apk`、构建产物、本地发布文件及内外网 `agent.apk` 独立整包回下载逐字节一致，
  大小 `67,387,055` 字节，SHA-256 为
  `c9620554cb924fbac74797841976021bc0f7d4d934257d4b98158a0f7a934443`。应用名 `Agent`、包名
  `top.asdb.agent`、`versionName=1.8.39`、`versionCode=166`；稳定签名证书 SHA-256 为
  `72722218709a6d7fd0e80b944903ae2961b4cfa8abe03586f602acdc1ea0f52a`。

### 17.30 图片预览保持原始比例（2026-08-12）

- 应用版本：`1.8.40+167`。远程图片预览仍将解码尺寸限制在 `2048x2048` 以内以控制内存，但解码
  策略由分别强制宽高的 `exact` 改为保持原始宽高比的 `fit`；显示层继续使用 `BoxFit.contain`，
  因此横图、竖图都只会等比例缩放，不会再被压扁或拉长。保存图片继续写入原始字节，不受预览缩放
  影响。
- WorkScreen Widget 回归同时断言预览解码使用 `ResizeImagePolicy.fit`、显示使用
  `BoxFit.contain`，防止后续重新引入非方形图片变形。
- WorkScreen 定向 `21` 项、Flutter 全量 `402` 项、`flutter analyze`、Debug/Release 构建和
  Android 14 Release 竖屏 smoke 全部通过。成功的 `publish` 主门禁用时 `6m46.019s`，其中
  Android full `3m35.727s`、Release smoke `24.480s`、CodeGraph `0.927s`、本地发布和下载回验
  `2m38.131s`。
- `dist/Agent-1.8.40.apk`、构建产物、本地发布文件及内外网 `agent.apk` 独立整包回下载逐字节一致，
  大小 `67,387,055` 字节，SHA-256 为
  `993872cacef584027d1ded78e746e4de2c4aff15727a0fbc38e3d7d333c38ac9`。应用名 `Agent`、包名
  `top.asdb.agent`、`versionName=1.8.40`、`versionCode=167`；稳定签名证书 SHA-256 为
  `72722218709a6d7fd0e80b944903ae2961b4cfa8abe03586f602acdc1ea0f52a`。

### 17.31 历史文本附件折叠兼容（2026-08-12）

- 应用版本：`1.8.41+168`。Codex 历史记录可能把用户正文和随后发送的文本附件合并成一个 text
  content，并且不在 `文本附件 <文件名>:` 前补换行。历史解析现在也识别这种直接拼接的传输标记，
  只保留用户正文，将 `.txt`、`.log.txt` 等附件恢复为紧凑附件条目，不再把附件全文展开在用户消息
  气泡中。
- 保留原有分离 content、换行合并 content、图片和普通文件附件兼容；新增与诊断日志历史负载一致的
  无换行拼接回归，断言日志正文被移出可见消息且文件名被恢复。
- Codex 协议定向 `27` 项、Flutter 全量 `403` 项、`flutter analyze`、Debug/Release 构建和
  Android 14 Release 竖屏 smoke 全部通过。成功的 `publish` 主门禁用时 `6m58.800s`，其中
  Android full `3m47.699s`、Release smoke `22.217s`、CodeGraph `0.920s`、本地发布和下载回验
  `2m37.152s`。
- `dist/Agent-1.8.41.apk`、构建产物、本地发布文件及内外网 `agent.apk` 独立整包回下载逐字节一致，
  大小 `67,387,051` 字节，SHA-256 为
  `5a48b1fad1005761ee03c86ec4174d6c322e716b917be9d996ed6dcf2eaba211`。应用名 `Agent`、包名
  `top.asdb.agent`、`versionName=1.8.41`、`versionCode=168`；稳定签名证书 SHA-256 为
  `72722218709a6d7fd0e80b944903ae2961b4cfa8abe03586f602acdc1ea0f52a`。

### 17.32 Git 风格文件差异（2026-08-12）

- 应用版本：`1.8.42+169`。文件差异页由整块白色纯文本改为按 unified diff 语义逐行渲染：新增行
  使用绿色文字和浅绿色背景，删除行使用红色文字和浅红色背景，`@@` 区块头使用蓝色；`diff --git`、
  `index`、`+++`、`---` 等文件元数据保持中性，避免误判为内容增删。
- 差异仍支持纵向和横向滚动，并通过 `SelectionArea` 保留跨行选择复制。Widget 回归验证增删行的
  前景色与背景色、区块头颜色、文件头例外和可选择性。
- WorkScreen 定向 `21` 项、Flutter 全量 `403` 项、`flutter analyze`、Debug/Release 构建和
  Android 14 Release 竖屏 smoke 全部通过。`publish` 主门禁用时 `6m59.007s`，其中 Android full
  `3m40.881s`、Release smoke `26.171s`、CodeGraph `0.893s`；自动公网下载回验期间连接提前关闭，
  随后独立重试内外网 `agent.apk` 均完整下载并通过逐字节比对。
- `dist/Agent-1.8.42.apk`、构建产物、本地发布文件及内外网 `agent.apk` 大小均为
  `67,387,051` 字节，SHA-256 为
  `70094d09f03b9695af0c5d17998e5add4a9f1cfce3bddba4b8db482d511314a1`。应用名 `Agent`、包名
  `top.asdb.agent`、`versionName=1.8.42`、`versionCode=169`；稳定签名证书 SHA-256 为
  `72722218709a6d7fd0e80b944903ae2961b4cfa8abe03586f602acdc1ea0f52a`。

### 17.33 ARM64 本机 Linux 实验模式（2026-08-12）

- 应用版本：`1.8.43+170`。服务器页新增独立“本机 Linux”实验入口，在 ARM64 Android App 私有目录安装
  Debian Trixie，通过 APK 内置 PRoot 启动仅监听 `127.0.0.1` 的 SSH，再复用现有 Flutter SSH、Agent、
  会话、终端和文件管理实现。
- rootfs 和四个原生运行库均固定版本与 SHA-256；解压、路径、大小和进程输出有界。回环 SSH 凭据加密保存，
  本机 Profile 固定 workspace、Codex 启动命令和 full-access 模式，不在普通服务器列表重复展示。
- 本机启动覆盖前台连接、指纹确认和后台恢复，主动断开会停止 sshd，删除会清理 Debian、Codex、工作区和
  Profile；UI 显示首次下载进度、ARM64 限制、磁盘增长、联网需求和删除确认。
- 新增本机运行状态、并发启动去重、失败恢复、Profile 安全边界及 AppController 启停回归。Flutter 全量
  `412` 项测试和 `flutter analyze` 通过，Debug/Release APK 构建通过；APK 的四个 ARM64 ELF、哈希、依赖及
  `extractNativeLibs=true` 已校验。当前 x86_64 模拟器不能执行 ARM64 PRoot，完整安装和 Codex E2E 留待
  ARM64 Android 真机验收。

### 17.34 当前诊断记录与拍照附件（2026-08-12）

- 应用版本：`1.8.51+178`。诊断日志弹窗只读取当前进程正在写入的单个活动分段，不再扫描、拼接或渲染
  历史 100 KiB 轮转文件；历史记录仍保留，并且只在选择分享或添加日志附件时按需列出。
- Work Composer 左下角附件菜单新增“拍照”，通过系统相机取得照片后复用既有附件大小、数量、MIME、
  上传中状态和 SFTP 暂存链路；取消拍照不会产生错误，单张照片仍受 20 MiB 上限约束。
- 新增当前日志分段隔离、拍照文件名/MIME/字节和菜单布局回归；`image_picker` 及其平台实现通过
  `pub.flutter-io.cn` 解析并锁定，iOS 同步声明相机用途。

## 18. 文档维护规则

以下变化必须同一任务更新本文，并在合适处标明当前实现或迁移目标：

- Flutter 入口、模块、页面、状态字段、持久化格式或 MethodChannel 变化；
- Agent 协议、缓存、后台、通知、安装、终端或文件管理落地；
- Flutter/Android/Java/Gradle/AGP/Kotlin/SDK、版本源、签名或 APK 路径变化；
- 模拟器推荐画布、自动门禁、测试文件或发布地址变化；
- 用户确认新的长期产品约束或故障处理方式。

不要把旧 Compose 页面、Kotlin 测试名、旧 Gradle task 或旧 APK 路径复制为当前事实。README 保持简短，
本文件保留边界和决策，LOCAL_WORKFLOW 保留命令和缓存细节。源码修改时用 CodeGraph 先 explore、后
sync；纯文档修改只需 git diff --check 和链接/路径检查。
