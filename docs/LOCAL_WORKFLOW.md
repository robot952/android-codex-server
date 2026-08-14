# 本地高复用开发流程

本文是当前 Flutter/Android 工程的本地构建、测试、模拟器验收和 APK 发布唯一说明。它描述的是
仓库中的 `flutter_app/`，不是旧 `app/` Kotlin/Compose 工程。目标是复用依赖、构建输出、模拟器和
测试服务器，缩短反馈时间，同时不牺牲可重复性。

正式 Gitee 发布不信任本机成功缓存；本文只覆盖本机开发和本机 HTTP APK 发布。当前迁移任务在独立
分支 `flutter-refactor` 上进行；修改前应确认自己没有误在 `main` 或其他人的分支上工作。

每次开始工作以及任何新会话、任务恢复、上下文压缩或摘要恢复后，都必须从仓库磁盘重新完整阅读根目录
`AGENTS.md` 和 `docs/ARCHITECTURE.md`；涉及构建、测试或发布时还必须完整重读本文。聊天记录、记忆和
压缩摘要不能替代这些原始文档。

用户明确要求“推送到远端并出包”或同义指令时，表示本地验收已经由用户完成。该场景跳过本地单元测试、
全量测试、analyze、本地构建和模拟器门禁，直接提交并推送，只跟踪云端流水线与 Release 结果。

## 1. 每次代码修改的固定流程

### 1.1 执行顺序

1. **定位但不改动**：运行 `git status --short --branch`；仓库有 `.codegraph/` 时先用
   `codegraph explore` 查调用链、现有测试和影响范围。此阶段不计入“开始修改到完成”的耗时。
2. **开始修改计时**：第一次写文件前记录墙钟时间；明确本轮受影响文件、最近的定向测试和最终风险门禁。
3. **最小实现与最近测试**：同步修改源码和相邻测试，不顺带重构无关模块。优先执行：

   ```bash
   ./scripts/flutter-tool.sh dart format <相对 flutter_app/ 的本轮 Dart 文件>
   ./scripts/flutter-tool.sh test --no-pub <相对 flutter_app/ 的直接相关测试文件...>
   ```

   修改 Pubspec 后先执行一次 `./scripts/flutter-tool.sh pub get`。Shell 修改先运行
   `bash -n <修改的脚本...>`；工作流脚本还要运行 `./scripts/test-workflow.sh`。
4. **只运行一个主门禁**：定向测试通过后，按 1.2 的风险表选择 `quick`、`check`、`full` 或
   `publish`，不要为了“更完整”机械串行执行全部四种模式。
5. **失败就地恢复**：格式、lint 或单测失败时只修复并重跑失败的最小阶段；只有怀疑 stamp、工具链或
   产物损坏时才使用 `--force`，不得用 `flutter clean`、Gradle clean 或删除整个缓存处理普通失败。
6. **收尾与报告**：源码修改后 `codegraph sync`，再运行 `git diff --check`。报告功能结果、测试范围、
   APK 信息（如有）、从第一次写文件到最终检查的总耗时，以及工作流计时文件中的阶段耗时。
7. **提交与推送**：代码修改通过对应门禁后必须创建 Git 提交，提交信息必须使用中文；提交成功后必须
   立即推送当前分支到配置的远端。只有用户明确要求暂缓提交或推送时才例外。

### 1.2 风险与门禁

| 修改类型 | 必跑 | 主门禁 |
| --- | --- | --- |
| 纯文档 | `git diff --check`、链接/路径检查 | 不跑 Android 门禁 |
| Shell/工作流 | `bash -n`、`scripts/test-workflow.sh` | 普通脚本用 `quick`；构建/发布脚本真实跑一次 `check -> full` |
| 纯函数、局部 UI、文案 | 最近单元/Widget 测试、格式化 | `quick`；用户可见行为交付前用 `check` |
| 普通功能或跨多个 Dart 模块 | 最近测试、格式化 | `check` |
| SSH、Agent、状态恢复、持久化、依赖、Android 宿主、签名/更新 | 最近测试、格式化 | `full` |
| 要交付 APK | 上述对应测试 | 直接 `publish`；此前跑过 `check/full` 时自动复用 |

`check` 后执行 `full/publish` 时，同一源码指纹的 Debug stamp 同时作为 analyze 和全量测试已通过的
证明；后续只构建缺失的 Release APK。反向也相同。可在执行前只读查看计划：

```bash
./scripts/build-android.sh all --reuse --plan
```

### 1.3 常用入口

```bash
./scripts/dev-workflow.sh quick
./scripts/dev-workflow.sh check
./scripts/dev-workflow.sh full
./scripts/dev-workflow.sh publish
./scripts/dev-workflow.sh status
```

| 模式 | 适用场景 | 实际执行 |
| --- | --- | --- |
| `quick` | 频繁编码反馈 | 服务器脚本门禁、OpenCode bridge quick 门禁、Flutter `analyze` |
| `check` | 一个功能完成 | 服务器脚本门禁、OpenCode bridge full 门禁、Flutter analyze/test、Debug APK、Debug 模拟器冒烟 |
| `full` | 提交前或高风险改动 | 上述门禁、Debug/Release APK、Release 模拟器冒烟 |
| `publish` | 交付本机下载包 | `full` 的缓存结果、稳定签名校验、本机 HTTP 部署、内外网下载哈希校验 |
| `status` | 查看环境 | Git、AVD、OpenCode 运行时、门禁 stamp 和 APK SHA-256 |

`quick` 不构建可安装 APK；需要 APK 时至少执行 `check`。`full/publish` 会复用同一输入下已经通过的
Debug 或 Release 门禁。只有明确要求从头验证或怀疑缓存时才强制重跑：

```bash
./scripts/dev-workflow.sh full --force
```

可用 `--no-emulator` 只跳过模拟器阶段；它不跳过 analyze、test 或 APK 构建。依赖下载确实需要联网
时追加 `--online`。

## 2. Flutter 构建入口

底层脚本支持：

```bash
./scripts/build-android.sh fast --reuse
./scripts/build-android.sh debug --reuse
./scripts/build-android.sh release --reuse
./scripts/build-android.sh all --force
./scripts/build-android.sh all --cache-status
./scripts/build-android.sh all --reuse --plan
```

执行顺序如下：

1. 解析 Android SDK、Flutter CLI、Gradle cache 和 Pub cache。
2. 在 `flutter_app/` 执行离线 `flutter pub get --offline`；离线缺包且 `127.0.0.1:7890` 正在监听时，
   自动切换到在线下载并设置该代理。
3. 没有同指纹 Debug/Release 成功 stamp 时，执行 `flutter analyze --no-pub` 和全量
   `flutter test --no-pub`。
4. 已有同指纹 Debug 或 Release stamp 时复用该验证结果，不重复 analyze/test。
5. 只构建当前缺失的 Debug/Release APK；`all` 不再无条件重建两种 APK。

定向格式化和测试统一通过 `scripts/flutter-tool.sh` 调用。它与 Android 门禁使用完全相同的 Flutter
探测顺序和 Pub cache，不要再硬编码 `.toolchains` 相对路径：

```bash
./scripts/flutter-tool.sh dart format lib/src/ui/example.dart
./scripts/flutter-tool.sh test --no-pub test/ui/example_test.dart
```

当前没有独立的 Kotlin `compileDebugKotlin`、`testDebugUnitTest` 或 Compose Lint 门禁；Flutter 的
`analyze` 是当前静态检查入口，文档和脚本不得把旧 Gradle task 写成当前构建步骤。

默认目录：

```text
Flutter 工程：flutter_app/
Pub cache：    ../.pub-cache（不可写时回退到 $HOME/.pub-cache）
Gradle cache： ../.gradle-cache（不可写时回退到 $HOME/.gradle）
```

Flutter CLI 的探测顺序是 `CODEX_FLUTTER_BIN`、`PATH`、仓库同级
`.toolchains/flutter-root/bin/flutter`、仓库内 `.toolchains/flutter-root/bin/flutter`，最后才回退到旧的
`.toolchains/flutter/bin/flutter`。同级目录可能由其他用户创建，若出现 Git `dubious ownership`，应优先使用
`flutter-root` 或显式设置 `CODEX_FLUTTER_BIN`，不要修改工具链目录归属。

可用环境变量覆盖：`CODEX_FLUTTER_BIN`、`PUB_CACHE`、`GRADLE_USER_HOME`、`ANDROID_HOME` 或
`ANDROID_SDK_ROOT`。Android SDK 会按 `ANDROID_HOME`、`ANDROID_SDK_ROOT`、仓库同级 `android-sdk`、
`/tmp/android-sdk`、`/var/lib/docker/volumes/android-sdk/_data` 的顺序自动发现。

## 3. 缓存和资源策略

缓存目录是被 Git 忽略的 `.workflow-cache/`。Android stamp 的指纹包含：

- `flutter_app/lib`、`flutter_app/test`、`flutter_app/android`、Pubspec 和分析配置；
- `keystore` 与相关构建脚本；
- 文件内容、路径和权限（未提交但未被忽略的相关文件也会参与）；
- Java、Flutter、Android SDK 和 Build Tools 身份；
- 门禁模式及 APK SHA-256。

所以未提交源码也会使对应阶段失效；只修改文档通常不会使 Android stamp 失效。命中缓存时不会
再次执行 Flutter、Gradle 或 APK 安装。`--cache-status` 只判断命中与否，不启动构建。

`dev-workflow.sh` 每次结束都会打印毫秒级阶段汇总，并保存：

```text
.workflow-cache/latest-workflow-timing.tsv
.workflow-cache/workflow-timings/<UTC时间>-<模式>-<PID>.tsv
```

历史记录最多保留 100 份。`orchestrationMs` 是缓存查询、状态判断和脚本调度耗时；具体 Flutter
依赖解析、analyze、测试及 Debug/Release 构建耗时会由 `build-android.sh` 单独打印。

保持以下内容长期存在以换空间换时间：

- `../.pub-cache` 和 `../.gradle-cache`；
- Flutter 的 `.dart_tool/`、`flutter_app/build/`；
- `asdb_api34` AVD、Quick Boot 状态和 App 数据；
- 已准备的 SSH 测试账号及远端 Agent 依赖。

不要运行 `flutter clean`、`./gradlew clean`，不要删除上述缓存、AVD、App 数据或远端 Agent 来追求
“干净测试”。要绕过错误 stamp 用 `--force`；只有明确验证首次安装/数据迁移才使用
`emulator-smoke.sh --reset-data`。

构建和模拟器共用 8 GB 主机时，`dev-workflow.sh` 会在确有构建任务时停止 AVD，并在模拟器验收前
释放本轮 Gradle daemon；缓存命中则尽量保持 AVD 和进程不动。不要同时用 `/root/.gradle` 和共享
cache 启动两套大型 daemon。

## 4. 服务器脚本和 OpenCode 门禁

它们是仓库辅助工具的静态/本地验证，不代表 Flutter APK 已接入 Agent：

```bash
./scripts/test-server.sh
./scripts/test-server.sh --force
./scripts/test-opencode.sh quick
./scripts/test-opencode.sh full
```

`test-server.sh` 检查 Bash 语法和 `server/smoke-test.mjs` 的 Node 语法，不登录或修改真实服务器。
`test-opencode.sh` 验证本地 bridge、调度和隔离的假 OpenAI 兼容服务；需要安装固定 npm 运行时时才下载。
两类脚本都使用内容 stamp，`--force` 才无条件重跑。

下载 OpenCode/npm 依赖时优先使用 `127.0.0.1:7890`。这是宿主机构建代理；将来远程服务器上的
Codex/OpenCode 安装代理必须由用户按服务器单独配置，不能把 7890 写死进 App 业务网络。

## 5. 长期模拟器

```bash
./scripts/android-emulator.sh start
./scripts/android-emulator.sh status
./scripts/android-emulator.sh stop
./scripts/android-emulator.sh log

./scripts/emulator-smoke.sh debug
./scripts/emulator-smoke.sh release
```

默认 AVD 为 `asdb_api34`，设备通常是 `emulator-5554`；实际序列号以 `adb devices -l` 为准。
root 环境下脚本可用临时 systemd service 托管模拟器，任务终端退出后仍可复用。

UI 验收推荐使用约 1.5K 画布：

- 推荐竖屏：`1220x2712`；
- 后续 UI 验收只覆盖竖屏，横屏不再作为门禁；
- 推荐尺寸不是必须精确匹配的硬限制；
- 自动冒烟最低要求：短边 `1080`、长边 `2400`。可用 `CODEX_EMULATOR_MIN_SHORT_EDGE` 和
  `CODEX_EMULATOR_MIN_LONG_EDGE` 调整门禁阈值。

`android-emulator.sh` 默认用 `wm size 1220x2712` 设置逻辑画布。`emulator-smoke.sh` 会：

1. 保留 App 数据和 Keystore，按 APK SHA-256 决定是否 `adb install -r`；
2. 启动 `top.asdb.agent/.MainActivity`，等待进程稳定；
3. 采集竖屏截图、UIAutomator XML 与 logcat；
4. 核对竖屏最低画布尺寸和前台包名；
5. 检查本应用崩溃、ANR 及覆盖页面的系统错误弹窗；
6. 默认保留模拟器运行，便于继续手工回归。

首次启动或迁移专项才清理数据：

```bash
./scripts/emulator-smoke.sh release --reset-data
```

每次做响应式或键盘回归至少覆盖一次推荐竖屏和软键盘弹出场景，并核对截图实际 PNG 尺寸；
不要把推荐尺寸误写成“必须精确 1220x2712”。

## 6. SSH 测试主机

长期测试主机只准备一次：

```bash
./scripts/reusable-test-host.sh prepare
./scripts/reusable-test-host.sh status
```

默认用户 `codexemu`、工作目录 `/home/codexemu/workspace`，模拟器访问宿主机使用 `10.0.2.2:22`。
 profile、指纹、工作目录和远端依赖应保留，以便后续 APK 更新后继续测试。需要改账号或密码时用
`CODEX_TEST_HOST_USER`、`CODEX_TEST_HOST_PASSWORD` 覆盖并重新执行 `prepare`。

当前 Flutter 版只实现 SSH 主机连接；不要把测试主机已安装的 Codex/OpenCode 误当作 App 已接入。
真实 Agent 回归必须明确授权，避免删除用户会话、工作目录或登录状态。

后台驻留专项回归应验证“回到前台之前”已经恢复，而不是只看打开 App 后的状态：连接服务器后将
Activity 放到 Home，记录当前 PID 和 `dumpsys activity services` 中的
`ConnectionForegroundService`，再用 `adb shell am kill top.asdb.agent` 模拟系统回收（不要用
`am force-stop`，后者按 Android 规则会阻止粘性 Service 重启）。Service 重建后应在日志中先看到
`service_start`、`sticky_service_restored_flutter_engine`、`background_restore_requested`，随后看到
`SSH reconnect_success`；整个过程 Launcher 保持前台即可。用户主动断开后应看到 Service 停止且不再重连。

## 7. APK 发布和验签

产物路径：

```text
Debug:   flutter_app/build/app/outputs/flutter-apk/app-debug.apk
Release: flutter_app/build/app/outputs/flutter-apk/app-release.apk
```

原生库打包契约：

- `flutter_app/android/app/build.gradle.kts` 必须保持
  `packaging.jniLibs.useLegacyPackaging = true`，从而设置 `extractNativeLibs=true`；
- Flutter 和 App 的 `.so` 在 APK 中压缩，Android 安装时再解压到 `nativeLibraryDir`。因此当前 Release
  APK 约 29 MB、未压缩内容约 66 MB 是正常结果，不应用旧版约 64 MB 的 APK 文件大小判断漏包；
- 该模式会略微增加 Release 打包和安装耗时，但减少下载与传输体积，并且是从 `nativeLibraryDir` 执行
  PRoot 的前提；
- APK 继续交付 `armeabi-v7a`、`arm64-v8a`、`x86_64` 三种 Flutter ABI；仅 PRoot 本机 Linux 运行时只
  提供 `arm64-v8a`。发布前用 `scripts/test-local-linux-runtime.sh <release-apk>` 校验 PRoot 文件和
  `extractNativeLibs`，不得为追求构建速度改回未压缩 native library。

本机发布：

```bash
./scripts/publish-local-apk.sh
./scripts/publish-local-apk.sh --force
```

脚本读取 `flutter_app/pubspec.yaml` 的版本，使用
`keystore/codex-remote-stable.keystore` 验签，复制到 `/var/www/html/codex.apk`（同时保留
`agent.apk` 兼容别名），然后用
`curl --noproxy '*'` 校验：

```text
内网：http://192.168.8.107/codex.apk
外网：http://frp.asdb.top:18080/codex.apk
```

两个地址返回的 SHA-256 必须与 Release APK 相同。发布报告必须同时给出这两个完整地址；网络代理
不通时先说明验证失败，不要给不完整或未经请求验证的 URL。

稳定签名契约：

- Debug/Release 共用 `keystore/codex-remote-stable.keystore`；
- 不删除、重生成、替换 keystore 或 alias；
- 每次交付包含代码修改的新 APK，都必须将 `flutter_app/pubspec.yaml` 的可见语义版本至少递增一个
  patch 版本，并同时增加 build number；不得只增加 build number，导致安装后页面版本文字不变；
- 覆盖安装失败先检查 applicationId、build number 和证书，不得通过换签名或卸载数据解决。

## 8. 手工回归最小集

当前 Flutter 功能的最低回归范围：

| 场景 | 预期 |
| --- | --- |
| 空配置冷启动 | 进入服务器列表，无异常白框或崩溃 |
| 新建/编辑/删除 Profile | 默认用户 `root`；校验地址/端口；删除只删本地配置 |
| 密码/私钥连接 | 指纹首次确认；固定指纹匹配；失败不会影响其他服务器 |
| 多服务器 | A、B 可同时保持独立连接，切换不串状态 |
| 连接遮罩 | 连接/指纹阶段半透明阻塞，完成后直接进入占位会话页 |
| 返回和竖屏适配 | 页面动画可用；目标竖屏、大字体无溢出；IME 不遮挡表单 |
| 进程重建 | 加密 Profile 可恢复；断线状态不伪装成已连接 |

Agent、会话、后台通知、终端、文件管理等产品回归必须等对应 Flutter 模块落地后补 integration
测试；在此之前只能把旧 `app/` 或服务器 smoke test 当作历史参考。

## 9. 故障定位

```bash
./scripts/dev-workflow.sh status
./scripts/android-emulator.sh log
sed -n '1,120p' .workflow-cache/emulator/latest-logcat.txt
cat .workflow-cache/emulator/latest-smoke.txt
```

处理顺序：先看对应阶段的 stamp 和输入哈希，再用该阶段 `--force` 重跑；不要一开始删除全部缓存。
Flutter 依赖错误先检查 `PUB_CACHE` 和 7890 代理，APK 安装错误检查稳定证书和 build number，模拟器
问题检查 `adb devices -l`、服务状态和竖屏截图。

## 10. 每次修改的收尾

1. 确认最近的定向测试与 1.2 指定的单个主门禁都通过，不补跑低价值的重复门禁。
2. 源码修改且存在 `.codegraph/` 时运行 `codegraph sync`；纯文档修改不必重建索引。
3. `git diff --check` 并再次检查 `git status --short --branch`，不得覆盖共享工作区里的其他改动。
4. 从第一次写文件到最终检查停止总计时；同时读取 `.workflow-cache/latest-workflow-timing.tsv`，报告
   主门禁各阶段耗时、缓存命中和失败返工。
5. 每次交付 APK 或下载链接时，无需用户再次提醒，必须同时给出完整的内网和外网下载地址、版本、
   SHA-256 和签名证书信息。
6. 代码修改必须创建中文 Git 提交，并在提交成功后立即推送当前分支到配置的远端；只有用户明确要求暂缓
   时才不推送。

用户新增或变更长期注意事项时，必须同步写入 `docs/ARCHITECTURE.md` 的产品约束和本文对应流程，
避免只留在聊天记录中。
