# Codex Remote for Android

Codex Remote 是一个通过 SSH 连接远程服务器、提供接近 VS Code Codex 插件体验的 Flutter 客户端。
当前 Android 构建入口是 `flutter_app/`；旧 Kotlin/Jetpack Compose 工程保留为行为基线，Flutter
版本已经覆盖服务器、Agent、会话和工作区的主要链路。

> 当前状态（2026-08-07）：Flutter Agent 核心迁移已提交到 `flutter-refactor` 分支，Codex/OpenCode
> 共用会话协议和 Work 页面。真实服务器长时运行、最终 APK 构建和高分辨率模拟器回归仍是验收项。

## 当前可用

- Flutter + Riverpod 应用壳、服务器列表、服务器设置页和页面切换动画。
- 多服务器 Profile 的新增、编辑、删除、选择和独立连接状态。
- `flutter_secure_storage` 加密持久化，并通过 Android MethodChannel 一次性导入旧原生 Profile。
- `dartssh2` 密码认证和 OpenSSH 私钥认证，包括带密码私钥。
- SSH 主机公钥 SHA-256 指纹探测、用户确认、保存和后续严格固定校验。
- 连接过程的全屏半透明阻塞层，以及连接成功后进入真实会话列表。
- 服务器 CPU、内存、磁盘和网络采样、紧凑指标和点击详情。
- Codex/OpenCode Agent 探测、固定版本安装、HTTP/HTTPS 下载代理、进度展示、卸载和自动连接。
- JSONL 会话列表、搜索、恢复、分页、流式消息、停止、审批、权限、会话级模型和思考强度。
- Work 页面中的上下文用量、压缩、草稿、附件、图片预览/保存、Markdown 链接和子 Agent。
- SSH 终端、SFTP 文件管理、工作目录选择、全局 Codex 配置和真实模型连通性测试。
- Android 前台连接保护、回合完成通知、Debug 日志导出分享和按会话缓存。
- 服务器页在竖屏、横屏和放大字体下的 Widget 回归。
- Android Debug 和 Release APK 使用同一把长期稳定签名，可覆盖安装历史同签名版本。

## 当前验收缺口

以下项目已经有实现和测试覆盖，但本轮环境无法完成最终运行验收：

- 在目标真实服务器上验证 OpenCode 固定版本的安装、卸载和真实 Provider/API 连通性。
- 长时间 turn、steer、interrupt、断线重连和 Android 厂商后台限制下的持续运行。
- 新代码对应的完整 Flutter test 和 Debug/Release APK 重编译。
- 约 1220x2712 高分辨率模拟器上的竖屏/横屏逐页截图对比。

当前沙箱禁止测试器和 Gradle 创建本地 socket；已有签名 APK 和所有 Flutter/Pub/Gradle/AVD 缓存均保留，
环境恢复后应优先运行 `./scripts/dev-workflow.sh full --force` 完成这些门禁。

完整的当前实现边界、迁移顺序和长期产品约束见
[架构与协作手册](docs/ARCHITECTURE.md)。

## 目录

| 路径 | 当前职责 |
| --- | --- |
| `flutter_app/lib` | 当前 Flutter 应用源码 |
| `flutter_app/test` | 当前 Flutter 单元测试和 Widget 测试 |
| `flutter_app/android` | 当前 Android 宿主、签名和旧 Profile 导入桥接 |
| `flutter_app/ios` | Flutter 自动生成的 iOS 工程骨架，尚未作为交付版本验收 |
| `app` | 旧 Kotlin/Compose 完整实现，仅作迁移参考和行为基线 |
| `server` | 固定 Agent 安装、受限入口和 app-server smoke test 辅助脚本 |
| `protocol` | Codex、OpenCode 和 Node.js 固定版本及协议资料 |
| `scripts` | 构建、测试、模拟器和 APK 发布入口 |
| `keystore` | 不得更换的 Android 稳定签名 |
| `docs/ARCHITECTURE.md` | 当前架构、迁移缺口、产品约束和测试地图 |
| `docs/LOCAL_WORKFLOW.md` | 本地构建、缓存、模拟器和发布流程 |
| `docs/UI_SPEC.md` | 视觉/交互契约和历史参考（实现状态以本文为准） |
| `docs/GITEE_RELEASE.md`、`docs/GITEE_GO_RELEASE.md` | Gitee 发布参考 |

当前入口是 `flutter_app/lib/main.dart`，应用根组件是
`flutter_app/lib/src/app/codex_remote_app.dart`。除非任务明确要求修复旧版，不要继续在 `app/` 实现
新功能；应把对应行为迁移到 Flutter。

## 工具链

当前工程版本以源码文件为准：

| 项目 | 当前值 |
| --- | --- |
| App | `1.8.6+126`，来源 `flutter_app/pubspec.yaml` |
| Flutter | `3.44.8 stable` |
| Dart | `3.12.2` |
| Java | 17 |
| Gradle wrapper | 9.1.0 |
| Android Gradle Plugin | 9.0.1 |
| Kotlin Android plugin | 2.3.20 |
| Android | minSdk 26、targetSdk 34、compileSdk 36 |

## 构建

日常开发使用统一入口；它会按输入内容复用服务器脚本、OpenCode、Flutter、APK 和模拟器门禁：

```bash
./scripts/dev-workflow.sh quick
./scripts/dev-workflow.sh check
./scripts/dev-workflow.sh full
./scripts/dev-workflow.sh publish
./scripts/dev-workflow.sh status
```

只运行 Android/Flutter 阶段时：

```bash
./scripts/build-android.sh fast     # flutter analyze
./scripts/build-android.sh debug    # analyze + test + Debug APK
./scripts/build-android.sh release  # analyze + test + Release APK
./scripts/build-android.sh all      # analyze + test + Debug/Release APK
```

脚本不会执行 `flutter clean`。依赖默认先通过持久 `PUB_CACHE` 离线解析；缺失依赖且本机
`127.0.0.1:7890` 可用时会使用该代理下载，也可显式联网：

```bash
CODEX_BUILD_ONLINE=1 ./scripts/build-android.sh debug
# 或
./scripts/dev-workflow.sh check --online
```

默认缓存位于仓库同级目录：

```text
../.pub-cache
../.gradle-cache
```

不要为普通构建删除 Pub/Gradle 缓存、`.workflow-cache/`、AVD、App 数据或远端 Agent。需要绕过
内容成功缓存时使用 `--force`。完整规则见
[本地高复用开发流程](docs/LOCAL_WORKFLOW.md)。

## APK

构建产物：

```text
flutter_app/build/app/outputs/flutter-apk/app-debug.apk
flutter_app/build/app/outputs/flutter-apk/app-release.apk
```

安装 Debug APK：

```bash
adb install -r flutter_app/build/app/outputs/flutter-apk/app-debug.apk
```

Debug 和 Release 都使用：

```text
keystore/codex-remote-stable.keystore
```

不得删除、重新生成或替换该文件，也不得更换 alias。稳定证书 SHA-256：

```text
72:72:22:18:70:9A:6D:7F:D0:E8:0B:94:49:03:AE:29:61:B4:CF:A8:AB:E0:35:86:F6:02:AC:DC:1E:A0:F5:2A
```

版本名和 Android `versionCode` 分别来自 `flutter_app/pubspec.yaml` 的 `version` 与 `+build`；每次
发布可安装更新的 APK 前必须增加 build number。

## 本机发布

生成 Release APK、验签、复制到本机 HTTP 目录并实际下载校验：

```bash
./scripts/publish-local-apk.sh
./scripts/publish-local-apk.sh --force
```

脚本把产物归档为 `dist/Agent-<version>.apk`，原子更新
`/var/www/html/codex.apk`（同时保留 `agent.apk` 兼容别名），并绕过代理校验以下两个地址的 SHA-256：

- 内网：<http://192.168.8.107/codex.apk>
- 外网：<http://frp.asdb.top:18080/codex.apk>

交付 APK 时必须同时给出内网和外网完整地址。地址属于部署环境，不要写入 App 业务逻辑，也不要在
文档、命令或 Git 中记录 FRP token。

## 当前架构

```text
Flutter Widgets
      |
AppController (Riverpod StateNotifier)
      |-------------------------|
SecureProfileStore              ServerConnectionManager
      |                         |
flutter_secure_storage          DartSshServerClient
      |                         |
Android legacy MethodChannel    dartssh2 + pinned SHA-256 host key
```

`ServerConnectionManager` 以 `profileId` 隔离客户端、锁、连接代次和展示状态。修改主机、端口、用户、
认证材料或固定指纹会替换旧客户端；只修改服务器名称等展示字段则复用连接。

下一阶段的预期数据流是：

```text
Flutter Work UI
      |
profileId + AgentKind + threadId 隔离的状态/缓存
      |
Agent adapter (Codex / OpenCode)
      |
SSH exec channel (JSONL, no PTY)
      |
remote Agent runtime + workspace
```

这条 Agent 数据流目前只是迁移目标，不能据此判断 Flutter 版已支持会话。

## 服务器辅助脚本

`server/` 仍保留独立安装和 app-server smoke test：

```bash
cd server
./install-codex-pinned.sh
~/.local/bin/codex-remote login
CODEX_REMOTE_BIN="$HOME/.local/bin/codex-remote" node ./smoke-test.mjs
```

这些脚本不会让当前 Flutter APK 自动获得 Agent 能力。自动探测、用户确认、安装进度和 app-server
连接必须在 Flutter 迁移完成后才能从 App 使用。脚本默认安装到服务器用户目录，不应使用 `sudo`、
覆盖系统 Node.js、覆盖 VS Code 扩展内置 CLI，或删除该用户的 `~/.codex` 登录和会话。

## 安全约束

- 未知 SSH 主机必须先显示 SHA-256 指纹，由用户确认后才能正式认证连接。
- 已保存指纹必须严格匹配；主机或端口变化后重新确认。
- 密码和私钥只存入系统安全存储，不写日志、通知、普通首选项或截图。
- Codex/OpenCode 凭据留在远程服务器；App 不把它们打包进 APK。
- Agent 协议最终只通过 SSH 通道传输，不公开监听 app-server TCP/WebSocket。
- 生产环境推荐非 root 专用账户和每台设备独立 SSH key；界面默认用户为 `root` 只是产品默认值。

## 协作规则

- 仓库存在 `.codegraph/` 时，理解源码前先运行 `codegraph explore`；源码修改完成后运行
  `codegraph sync`。纯文档修改无需同步索引。
- 保留共享工作区里不属于当前任务的修改，不修改同级其他项目。
- 手工编辑使用 `apply_patch`；普通开发不运行 `clean`。
- 测试范围按风险扩大，不能只以“编译通过”代替 Widget、模拟器或真实 SSH 流程验证。
- Git 提交信息使用中文；不要强推或改写他人历史。
- 长期产品注意事项有变化时，同步更新
  [架构与协作手册](docs/ARCHITECTURE.md)。
