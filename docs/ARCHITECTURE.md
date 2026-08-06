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
| App 版本 | 1.8.0+120，来自 flutter_app/pubspec.yaml |
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
3. 手工编辑使用 apply_patch；不要顺手重构无关模块，不要运行 flutter clean 或 Gradle clean。
4. Flutter 小改动先运行 ./scripts/dev-workflow.sh quick；功能完成运行 check；提交/发布前运行
   full 或 publish。具体缓存和模拟器规则见 LOCAL_WORKFLOW.md。
5. 源码修改完成后运行 codegraph sync；纯文档修改不需要同步索引。
6. Git 提交信息使用中文；本任务没有得到提交授权时不要提交或推送。

## 2. 项目边界

长期目标是：通过 SSH 连接一台或多台服务器，在无 PTY 的 exec channel 中启动固定版本的 Codex 或
OpenCode Agent，将事件渲染为接近 VS Code Codex 插件的移动端工作界面。当前 Flutter 阶段只实现
服务器 Profile 和 SSH 主机连接，目标中的 Agent 协议层尚未接入。

下列内容不属于仓库提交内容：真实服务器密码、私钥、Codex 登录缓存、OpenAI API key、FRP token、
本机 .workflow-cache/、.codegraph/ 索引和本地资料目录 codex-manual-markdown (8)。不要把它们
写进日志、截图、文档或 Git。

## 3. 当前目录与职责

| 路径 | 当前职责 | 状态 |
| --- | --- | --- |
| flutter_app/lib/main.dart | Flutter 进程入口、ProviderScope | 当前运行 |
| flutter_app/lib/src/app/codex_remote_app.dart | MaterialApp、全局错误 Snackbar、页面动画和 Back 行为 | 当前运行 |
| flutter_app/lib/src/app/app_controller.dart | Riverpod StateNotifier；Profile 初始化、保存、选择、删除、SSH 连接编排 | 当前运行 |
| flutter_app/lib/src/domain/models.dart | Freezed/JSON 领域模型、连接状态和未来 Agent 字段 | 部分当前，部分迁移预留 |
| flutter_app/lib/src/persistence/profile_store.dart | 加密 Profile 存储、边界归一化、旧原生数据迁移 | 当前运行 |
| flutter_app/lib/src/ssh/server_connection_manager.dart | 每个 profileId 一个主机客户端、锁和 generation | 当前运行 |
| flutter_app/lib/src/ssh/ssh_server_client.dart | dartssh2 socket、密码/私钥认证、指纹和有界远程命令 | 当前运行；Agent 未调用 |
| flutter_app/lib/src/ui/server_screen.dart | 服务器列表、设置编辑、私钥导入、连接遮罩和外链 | 当前运行 |
| flutter_app/lib/src/ui/thread_list_screen.dart | 会话页占位、服务器状态和未启用操作入口 | 当前运行但功能不完整 |
| flutter_app/lib/src/ui/theme.dart | Flutter 主题和产品色值 | 当前运行 |
| flutter_app/android/app/src/main/kotlin/.../MainActivity.kt | top.asdb.codexremote/legacy MethodChannel | 仅旧 Profile 导入 |
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
              |                                      |
              +-- ThreadListScreen (占位)            +-- SecureProfileStore
                                                     |     |
                                                     |     +-- flutter_secure_storage
                                                     |     +-- legacy MethodChannel (Android)
                                                     |
                                                     +-- ServerConnectionManager
                                                           |
                                                           +-- DartSshServerClient
                                                                 |
                                                                 +-- dartssh2 / SSH socket
~~~

AppController 是当前唯一业务编排点。Widget 可以保留弹窗、草稿编辑和焦点等短生命周期状态，
但不能自己复制一份长期 Profile 或连接状态。连接状态通过 ServerConnectionManager.stateChanges
流回控制器，再由 AppUiState.connectionStates 按 profile 更新页面。

当前页面选择逻辑：

~~~text
AppScreen.servers  -> ServerScreen
AppScreen.threads  -> ThreadListScreen
AppScreen.work / agentWork / fileManager -> ThreadListScreen（占位回退）
~~~

AnimatedSwitcher 提供前进/返回的淡入滑入动画；系统 Back 在服务器列表退出应用，在其他页面返回
服务器列表；连接或指纹确认期间由遮罩阻断 Back 和其他操作。

## 5. 当前状态模型

AppUiState 是 Flutter 展示状态，字段分为：

| 类别 | 当前字段/含义 | 真实状态 |
| --- | --- | --- |
| 服务器 | profiles、selectedProfileId、connectionStates | 已使用 |
| 连接流程 | pendingFingerprint、loading、error | 已使用 |
| 页面 | screen、debugModeEnabled | 页面使用；Debug 只打开标记 |
| Agent/会话 | agentConnectionStates、threads、timeline、models 等 | 模型预留，控制器未接入 |
| 工作区/文件 | workspace*、fileManager* | 模型预留，UI 未接入 |
| 设置/审批 | agentSettings*、approval*、tokenUsage | 模型预留，UI 未接入 |

ServerProfile 当前保存名称、主机、端口、用户名、密码/私钥、指纹、工作目录、代理字段和未来
Agent 偏好。新增字段必须有默认值并保持旧 JSON 可解析。任何会话级数据必须使用明确的复合键，
不能把模型、思考强度或草稿做成全局单值。

## 6. Profile 持久化和迁移

SecureProfileStore 的关键行为：

1. 读取加密键 profiles_v2；解析失败降级为空配置并保留错误边界。
2. 若没有 v2，调用 Android MethodChannel top.asdb.codexremote/legacy 读取旧原生 profiles_v1。
3. 成功解析后写入 v2，并写迁移标记 profiles_v1_migration_complete=1，再清理旧值。
4. 每次读写都执行 normalizeStoredProfiles：去重 ID、补默认名称/用户名、限制端口、限制草稿和
   复合键数量，并保留有效的 selected profile。

Android 端只负责旧 EncryptedSharedPreferences 的读写桥接；Flutter 端负责 JSON 解码和新格式保存。
不要让新业务继续直接读取旧 Kotlin Preference 名称。

当前实现认定的 Profile 连接身份包括 host、port、username、认证方式、密码/私钥和指纹；这些字段
变化时 AppController 会替换客户端并清理该 profile 的草稿、会话偏好和完成计时。workspace、proxyUrl、
remoteCommand 等字段当前不会被 SSH 主机客户端消费；Agent 接入时若让 remoteCommand 参与连接身份，
必须同时扩展 hasSameConnectionIdentity 和对应测试。只改名称或其他展示字段不应无故断线。删除
Profile 必须同时删除其连接和所有 profile 前缀数据，不能影响其他服务器。

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

不同 profile 可以同时连接。选择 B 不会断开 A；断开 A 只改变 A 的状态。连接状态阶段包括
disconnected、probing、connecting、installing、connected、failed。

### 7.3 Dart SSH 客户端

DartSshServerClient 使用 dartssh2：

- 密码认证或 SSHKeyPair.fromPem 私钥认证；私钥密码只在连接调用内存中使用。
- 15 秒 keepalive、握手/认证超时和可取消的 pending socket。
- host key 回调执行规范化的 SHA256 严格比较。
- run() 为独立 exec channel 收集 stdout/stderr，有最大输出字节数和超时，避免无界拼接导致 OOM。
- disconnect/close 会同时清理已认证客户端、pending client 和 pending socket。

当前 AppController 只把它用于指纹和 SSH 登录；没有启动 Codex、OpenCode 或远程安装命令。

## 8. 当前 UI 行为

### 8.1 ServerScreen

- 首屏是服务器列表；没有 Profile 时显示添加入口。
- 每行显示钥匙图标、固定位置的连接状态点、服务器名、用户/连接状态和设置图标。
- 未连接点击行先询问，确认后探测指纹；已连接点击行进入会话占位页；断开按钮需二次确认。
- 连接/探测时显示全屏半透明转圈，阻止其他操作，成功后直接切换页面。
- 设置编辑支持名称、host、port、用户名、密码/私钥、私钥密码、指纹和工作目录等表单；私钥文件
  读取限制为 1 MiB，输入页使用 imePadding/可滚动布局。
- Codex 标题连续点击 10 次只启用 debugModeEnabled 标记；真实日志采集和系统分享尚未实现。
- https://lowapi.asdb.top 通过 url_launcher 交给系统浏览器，不能改成内嵌 WebView。
- serverMetrics 目前只是预留显示值，未实现远程采样；-- 不是采样成功的证明。

### 8.2 ThreadListScreen（占位）

当前只显示服务器标题、连接状态、资源指标占位、Codex/OpenCode 分段控件和搜索/操作图标；刷新、
新建、终端、设置、Agent 切换和搜索均为 disabled。页面显示“Agent 尚未连接”，不会伪装成已有会话。

不要在此页面临时实现一套只支持 Codex 的会话状态。迁移时必须复用下面的 Agent 中立契约，并按
profileId + AgentKind + threadId 隔离。

## 9. 迁移目标：Agent 中立层（尚未实现）

本节是后续实现的架构契约，不是当前 Flutter 功能清单。新代码应逐步填入这些边界，而不是
把目标状态直接写进 README 作为已完成事实。

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

RemoteAgentClient 应提供初始化、能力声明、模型、会话列表/恢复、回合、审批、目标、工作区和关闭
等中立操作；AgentCapabilities 决定 UI 是否显示某项能力。OpenCode 特有逻辑只能留在 adapter/bridge，
不能复制一套共享 UI 和状态机。

每个 Agent lane 使用独立 SSH exec channel、取消 scope、pending request 表和 generation。SSH 主机会话
应先成功，用户点击 Codex/OpenCode 后才按需探测或安装；没有 Agent 时终端和文件管理仍可使用。

### 9.2 Codex JSON-RPC/JSONL（迁移目标）

Codex adapter 预期通过无 PTY SSH channel 启动固定命令，stdin/stdout 每行一个 JSON，stderr 只作为
诊断。连接顺序为 initialize、initialized，随后异步加载 model/list、thread/list 和工作目录；
慢的列表读取不能阻塞页面显示。

协议实现必须保持 thread、turn、item 三层概念，事件 reducer 幂等处理 started/delta/completed，
并保存 server request id 直到批准、拒绝或回答。未知通知可忽略；未知 server request 必须返回
JSON-RPC -32601，不能让远端回合永久等待。固定版本变更前先核对官方 schema 和本地协议资料。

### 9.3 会话缓存、分页和上下文（迁移目标）

目标流程：先显示按 profile/Agent/thread 隔离的缓存，同时后台 thread/resume 校准；resume 期间缓冲
同一 generation 的通知，再合并快照，避免旧响应覆盖新 delta。更早历史通过 cursor 分页、去重并保持
时间顺序；超大响应要降低页大小或 itemsView 后重试，而不是无限提高内存。

上下文圆环只显示服务器返回的有效 used/total；缺少模型上下文上限时不猜测比例。最近一次有效
TokenUsage 可放在有界内存缓存中，供返回列表后立即恢复；不应把会话正文或 token usage 无限持久化。

模型、思考强度、输入草稿、审批队列、运行态和缓存键必须至少包含：

~~~text
profileId + AgentKind + threadId
~~~

### 9.4 Work UI、IME 和子 Agent（迁移目标）

- 对话页输入框使用系统 inset/IME 监听，与消息列表同帧上移；从后台回来不得自动 requestFocus。
- 空闲显示发送图标，运行中显示停止图标；停止必须确认且不能重复发送。
- 权限入口采用 VS Code 风格的请求批准、替我审批、完全访问三种模式；图标表达当前模式。
- 历史通过顶部下拉，用户拉动时才显示“松开加载更多”，释放后才请求。
- 阅读旧消息时显示回到底部箭头，不抢回滚动位置。
- Markdown HTTP/HTTPS 链接显示完整蓝色 URL，可长按复制，点击先确认打开。
- 图片结果显示中文“查看了图片”状态；点击打开预览，长按通过系统能力保存到手机，不把图片缩成
  只能查看的装饰缩略图。
- 子 Agent 只显示稳定身份图标/颜色和各自状态，不额外写“子agent”；点击进入真实独立 thread，
  返回先恢复父快照再校准父 thread。旧异步回调不能跳层或覆盖新页面。

### 9.5 远程安装和全局设置（迁移目标）

安装只在 SSH 已连接且用户点击对应 Agent 后发生。必须探测系统/managed 版本、平台、磁盘和下载
工具；安装位置限定为用户目录，不使用 sudo，不覆盖系统 Node.js、VS Code 扩展或用户 ~/.codex。
安装进度要区分总体、下载、当前阶段和详情；可取消、可重试，并按 profileId + AgentKind 隔离。

每台服务器可配置 HTTP/HTTPS 下载代理，只用于该服务器安装；宿主机构建下载仍优先使用 7890。

Codex 全局配置入口目标是修改当前远程 Unix 用户的：

~~~text
$HOME/.codex/config.toml
$HOME/.codex/auth.json（只通过 CLI 标准输入写入 API key）
$HOME/.codex/codex-remote.env（0600，代理环境）
$HOME/.local/bin/codex-remote（managed wrapper）
~~~

读取时必须以服务器实际配置为准，识别自定义 Provider、模型 URL、默认模型、思考强度、代理和登录
状态；API key 不保存到手机、日志、通知或截图。保存后断开并重连才生效，不修改项目 .codex、shell
profile、其他工作区或 VS Code 扩展文件。设置页的“测试”应从服务器向兼容 /responses 发起最小真实
请求，并显示成功/失败。

## 10. 迁移目标：后台、终端、文件和诊断

这些是产品验收目标，不是当前 Flutter APK 的可用承诺：

- 前台服务尽量维持后台 SSH；回合终态在后台发送带 profileId/threadId 的通知，点击进入正确会话。
- SSH 终端使用独立 shell channel、有界输出和 resize 队列，不污染 Agent JSONL channel。
- 文件管理使用当前 SSH 的 SFTP channel 和 Android Storage Access Framework，不拼接 shell 路径；删除有确认。
- Debug 通过 Codex 图标十次点击开启，日志脱敏、轮转、预览并用系统分享；崩溃记录可作为附件加入对话。
- 远端 stderr 的非致命 HTTP 403/MCP 错误显示简短中文提示并写入诊断，不能用原始 JSON/Rust 日志遮挡
  仍可用的会话；真正断线、认证失败和不可恢复错误仍明确显示。

## 11. 隔离规则

| 数据/资源 | 必须的隔离键 | 当前/目标存放 |
| --- | --- | --- |
| SSH 主机客户端和连接状态 | profileId | 当前 ServerConnectionManager |
| Agent 客户端、安装 job | profileId + AgentKind | 迁移目标 |
| 会话列表、时间线、运行态 | profileId + AgentKind + threadId | 迁移目标 |
| 草稿、模型、思考强度 | profileId + AgentKind + threadId | 持久化模型已预留，行为待迁移 |
| 审批和恢复缓冲 | profileId + AgentKind + threadId + generation | 迁移目标 |
| 终端 | profileId | 迁移目标 |
| 文件管理剪贴板 | profileId，不跨服务器持久化 | 迁移目标 |

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

签名是不可破坏的升级契约：

- keystore/codex-remote-stable.keystore；Debug/Release 共用 stable signing config；
- 证书 SHA-256 为 72:72:22:18:70:9A:6D:7F:D0:E8:0B:94:49:03:AE:29:61:B4:CF:A8:AB:E0:35:86:F6:02:AC:DC:1E:A0:F5:2A；
- 不删除、重生成、替换 keystore 或 alias；每个可覆盖安装发布都增加 Pubspec build number。

本机发布脚本会验签、原子替换 /var/www/html/codex.apk，并绕过代理校验：

~~~text
内网：http://192.168.8.109:18080/codex.apk
外网：http://frp.asdb.top:18080/codex.apk
~~~

交付时必须同时给出两个完整地址和 APK SHA-256。不要在文档、提交或回复中写访问 token。

## 13. 本地测试环境与门禁

当前本机环境：

~~~text
Android SDK：/home/ygy/android-sdk
adb：/home/ygy/android-sdk/platform-tools/adb
AVD：asdb_api34（通常 emulator-5554，以 adb devices -l 为准）
推荐竖屏：1220x2712；推荐横屏：2712x1220
自动门禁最低：短边 1080、长边 2400
~~~

推荐启动：

~~~bash
./scripts/android-emulator.sh start
./scripts/emulator-smoke.sh debug
~~~

emulator-smoke.sh 默认保留 App 数据、服务器 Profile 和 Keystore；仅 --reset-data 才清除当前
应用数据。脚本会验证竖屏/横屏截图、最小尺寸、前台包名、Crash/ANR 和系统错误弹窗。推荐尺寸不是
精确硬限制；截图验收应记录实际 PNG 宽高。

### 13.1 当前 Flutter 自动测试

~~~bash
cd flutter_app
flutter analyze --no-pub
flutter test --no-pub
~~~

当前测试文件：

| 文件 | 覆盖 |
| --- | --- |
| test/widget_test.dart | 空服务器首屏、1220x2712 连接阻塞遮罩、Back 阻断、旋转到 2712x1220、2x 字体、私钥密码入口、未保存编辑确认 |
| test/app/app_controller_test.dart | 初始化等待、串行保存、Profile 删除清理、连接身份变化、指纹确认竞态 |
| test/domain/models_test.dart | Profile 默认值、Agent 模型字段、复合偏好键、上下文/差异辅助模型 |
| test/persistence/profile_store_test.dart | 归一化、条目/草稿边界、旧 Agent 键迁移、旧加密 Profile 一次性导入、损坏数据降级 |
| test/ssh/server_connection_manager_test.dart | 指纹规范化、多服务器隔离、客户端复用、旧连接关闭和旧探测结果防护 |

没有 integration test、golden test 或完整 Agent/会话 UI 测试。新增共享状态、持久化、连接生命周期或
跨页面行为时，必须补测试，不能只运行一个 Widget 用例。

### 13.2 当前手工回归

| 场景 | 预期 |
| --- | --- |
| 首次启动 | 只显示服务器列表，不出现异常白框或 Flutter Demo 页面 |
| Profile 编辑 | 默认用户 root；表单可滚动；输入框和键盘不重叠；返回未保存时询问 |
| 密码/私钥连接 | 首次显示 SHA-256 指纹；取消不保存；信任后严格连接 |
| 多服务器 | 同时连接 A/B，切换和断开不串状态 |
| 连接中 | 半透明转圈遮罩覆盖全屏，Back 和重复点击被阻断；成功后无额外空白等待 |
| 旋转/字体 | 推荐 1220x2712 与 2712x1220、放大字体无截断；同时核对实际截图尺寸 |
| 进程重建 | 加密 Profile 可恢复，断线不会伪装成已连接 |

### 13.3 迁移后的验收矩阵（目标）

下表保留产品验收契约，但在 Agent/Work UI 完成前不得标记为通过：

| 领域 | 必须验证 |
| --- | --- |
| Agent 连接 | SSH 先连接；Codex/OpenCode 按需探测、安装、显示进度；已有版本复用而不覆盖 VS Code |
| 工作目录 | 第一次成功连接 Agent 只弹一次，选择后按服务器记住，之后不重复打扰 |
| 会话 | 列表搜索/刷新/新建/恢复/分页；重进先缓存再校准；运行会话显示固定尺寸转圈 |
| 会话设置 | 每个服务器、Agent、thread 独立模型和思考强度，返回主页后仍恢复 |
| 输入 | 草稿按复合键恢复；IME 与消息同帧上移；切后台回来不自动弹键盘 |
| 对话动作 | 发送/停止、权限模式、审批、模型、上下文圆环、压缩和目标均可用 |
| 历史滚动 | 顶部拉动才出现提示，阈值显示“松开加载更多”，释放才加载；阅读旧消息显示回底部箭头 |
| Markdown | 蓝色完整 HTTP/HTTPS 链接可点击，点击先确认，长按可复制 |
| 图片 | 显示“查看了图片”；点击可预览，长按可保存到手机 |
| 子 Agent | 只显示图标和自身状态；父子 thread 不串，嵌套返回不跳层，恢复失败可重试 |
| 后台 | turn 尽力继续；后台完成通知携带正确 profile/thread，点击直达会话 |
| Debug | 十次点击开启；日志脱敏、预览、系统分享和崩溃附件可用 |
| 终端/文件 | 独立 SSH channel；SFTP 长按、上传、下载、重命名、删除确认和多服务器隔离 |
| 全局配置 | 读取服务器真实 Codex Provider/URL/Key/代理；保存指定全局文件；真实最小请求测试 |

## 14. 产品长期约束

以下约束来自持续使用反馈，除非用户明确确认，不得删除或弱化；“目标”表示尚未在 Flutter 完成，
不是允许伪造已实现状态：

1. 首页是服务器列表，设置按需展开；默认 SSH 用户为 root。
2. 多台服务器可保存、同时连接和切换，状态、审批、会话和资源不得串台。
3. 工作目录第一次连接 Agent 后选择一次并记住；仅 SSH 登录不弹，之后不重复打扰。
4. 输入草稿、模型、思考强度按服务器 + Agent + 会话独立并持久保存（目标）。
5. 后台返回不得自动弹键盘；IME 出现时输入区和消息同步移动（目标）。
6. 会话重进优先显示缓存，较大历史允许更长的后台恢复，不长期白屏（目标）。
7. 更早历史通过下拉释放加载，提示随手势出现，内容向下留白（目标）。
8. 运行会话显示停止图标，列表显示转圈；上下文小圆环点击只看占用，不弹压缩确认（目标）。
9. 子 Agent 使用稳定身份色图标和逐个状态，不显示多余“子agent”文字；真实独立 thread 可安全返回（目标）。
10. 目标和操作菜单使用原生 app-server 能力，不依赖复杂斜杠解析（目标）。
11. App 在后台时 turn 完成发通知，点击进入正确服务器和会话（目标）。
12. Codex 图标连续点击 10 次开启 Debug；日志可系统分享且脱敏（当前仅有开关标记）。
13. 所有输入页面适配键盘、横竖屏和大字体，不允许控件重叠。
14. 远程 Agent 安装有可见进度，按服务器可填写 HTTP/HTTPS 下载代理（目标）。
15. 视觉接近 VS Code Codex：安静、紧凑、工作导向，不使用营销式大卡片、渐变或装饰背景。
16. APK 签名永不变化，发布 build number 必增，交付同时给内网和外网地址。
17. 本机构建下载优先使用 127.0.0.1:7890；已有依赖保持离线增量构建。
18. 每次修改按风险自行测试，不能只以“编译通过”代替模拟器和真实流程验证。
19. Git 提交信息使用中文；得到授权后才同步配置好的 Gitee origin。
20. “低价中转站优选”必须由系统浏览器打开 https://lowapi.asdb.top，不可内嵌 WebView。
21. 非致命远端 stderr 转成简短中文提示；真正断线、认证失败和不可恢复错误仍明确显示（目标）。
22. Codex 配置修改当前远程 Unix 用户的全局模型 URL、密钥和 HTTP/HTTPS 代理，不改项目工作区（目标）。
23. 配置页先读取服务器实际 Provider、默认模型、URL、代理、登录状态和 Key；自定义 Provider 不得误报未配置（目标）。
24. HTTP/HTTPS Markdown 链接必须完整、可点击、可长按复制（目标）。
25. Agent 接入必须通过 RemoteAgentClient/AgentCapabilities，所有异步结果和缓存按 profile + Agent + thread 隔离（目标）。
26. SSH 登录是前置条件；无 Agent 时终端/文件仍可用，Agent 设置和工作目录灰显不可操作（目标）。
27. 图片消息使用“查看了图片”中文状态；点击打开图片预览，长按可调用系统保存到手机（目标）。

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

不要在 Widget 中直接创建 SSH 客户端；不要把主机连接和未来 Agent channel 混成一个生命周期。

### 新增 Agent 协议（迁移目标）

~~~text
AgentKind / AgentCapabilities / RemoteAgentClient
  -> AgentConnectionManager(profileId + AgentKind)
  -> adapter parser/reducer/cache
  -> AppUiState + Work/Thread UI
  -> protocol, cache, cancellation, multi-server tests
  -> real authorized SSH/app-server integration
~~~

先定义 wire 模型和 generation 过滤，再接 UI；不能先把服务器响应塞入全局字符串。

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

### 16.4 Agent 尚未连接

当前 Flutter 版显示该状态是预期行为，不是提示用户重装 Codex。只有 Agent adapter 迁移完成后，才
按“SSH 已连接 -> 用户点击 Agent -> 探测/安装 -> handshake”排查。

### 16.5 模拟器、键盘和闪退

检查 AVD service、adb devices -l、推荐两方向截图、UI XML 和
.workflow-cache/emulator/latest-logcat.txt。Flutter 页面要用 resizeToAvoidBottomInset、
SafeArea/viewInsets 和可滚动表单；不要用吞掉异常的方式“修复”闪退。

### 16.6 APK 无法覆盖安装

依次检查 applicationId=top.asdb.codexremote、build number 是否增加、APK 是否由稳定 keystore
签名、证书 SHA-256 是否一致。绝不能换签名、卸载用户数据或删除 keystore 解决升级问题。

### 16.7 未来远端 403/503

若 Agent 接入后出现 MCP/上游 HTTP 403，普通页面只显示简短中文说明，详情放入脱敏 Debug 日志；
主 app-server 仍连接时不要把辅助 worker 错误显示成 SSH 断线。503、resume 超时应使用缓存和可取消
request，不能只把全局 timeout 调到很大而留下 pending 请求。

## 17. 已知限制

- 当前 Flutter APK 没有 Codex/OpenCode 会话功能；ThreadListScreen 是占位页。
- 没有 integration/golden 测试；模拟器 smoke 只验证启动、方向、包名、Crash/ANR，不代表真实 Agent 流程。
- server/ 的固定 CLI 和 app-server smoke test 不等于 App 已接入。
- Flutter iOS 目录是生成骨架，未作为可发布 iOS 版本验收。
- 远程 app-server、OpenCode bridge 和 Codex CLI 协议未来仍可能变化，接入后必须固定版本并审核 schema 差异。
- Android 厂商省电、强停、网络切换仍可能中断后台 SSH；不得承诺绝对不掉线。

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
