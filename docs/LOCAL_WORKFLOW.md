# 本地高复用开发流程

本文是本仓库本地开发、测试、模拟器验证和 APK 发布的唯一流程说明。目标是让源码、Gradle、
OpenCode、模拟器、SSH 测试主机和发布产物按内容变化自动复用，不再为每次小改动重复准备环境。

正式 Gitee `release` 流程不读取本地成功缓存，仍然每次执行完整门禁。本文只优化本地 `main`
开发和本机 HTTP 下载包，不会推送或触发 `release`。

## 1. 日常只记一个命令

~~~bash
./scripts/dev-workflow.sh quick
./scripts/dev-workflow.sh check
./scripts/dev-workflow.sh full
./scripts/dev-workflow.sh publish
./scripts/dev-workflow.sh status
~~~

| 模式 | 用途 | 执行内容 |
| --- | --- | --- |
| `quick` | 编码中的频繁反馈 | 服务器脚本静态门禁 + OpenCode 快速桥接测试 + 增量 Kotlin 编译 |
| `check` | 一项功能完成 | 服务器脚本静态门禁 + OpenCode 真实本地集成测试 + Debug 单测/APK + 模拟器启动冒烟 |
| `full` | 提交前或高风险改动 | 服务器脚本静态门禁 + OpenCode 完整测试 + Debug/Release 测试、Lint、APK + Release 模拟器冒烟 |
| `publish` | 给用户本地下载包 | `full` 的缓存结果 + 验签 + 本地 HTTP 部署和下载哈希校验 |
| `status` | 查看当前环境 | Git、模拟器、OpenCode、门禁缓存和 APK 哈希 |

默认使用内容指纹缓存。只有调查缓存、工具链升级或明确要求从头验证时才执行：

~~~bash
./scripts/dev-workflow.sh full --force
~~~

依赖缺失时加 `--online`，Gradle 会优先使用 `127.0.0.1:7890`；已有依赖时保持离线：

~~~bash
./scripts/dev-workflow.sh check --online
~~~

## 2. 缓存如何保证不会复用旧代码

缓存位于被 Git 忽略的 `.workflow-cache/`。缓存键不是提交号或文件时间，而是以下内容的 SHA-256：

- 当前所有相关 Git 已跟踪文件；
- 相关目录下未被忽略的未跟踪文件；
- 文件路径、权限和文件内容；
- Java、Android SDK、Build Tools 或 OpenCode 固定版本等工具链身份；
- OpenCode 可执行文件的 SHA-256；文件元数据未变时复用已计算的哈希；
- 门禁模式，例如 `debug` 和 `release` 分开记录。

因此未提交修改也会立刻使缓存失效。Android APK 还会再次比对成功记录中的 APK SHA-256；APK
不存在或被替换时不会命中。以下变化会自动只重做受影响阶段：

~~~text
OpenCode bridge/tests/version changed -> OpenCode gate invalidated
Server entry scripts/version changed -> server script gate invalidated
Android source/resources/build config changed -> Android gate invalidated
Only docs changed -> existing Android/OpenCode gates reused
Same release APK republished -> build and Web file copy skipped; HTTP hash still verified
Different APK -> install -r; same APK -> emulator install skipped
~~~

所有门禁使用 `flock` 串行化同类任务，避免两个会话同时写 APK 或 stamp。不要运行 `clean`，也不要
删除 `.gradle-cache`、AVD 或已安装的 Agent 来获得“干净测试”；需要绕过成功缓存时使用 `--force`。

## 3. Android 构建复用

底层入口仍可单独使用：

~~~bash
./scripts/build-android.sh fast --reuse
./scripts/build-android.sh debug --reuse
./scripts/build-android.sh release --reuse
./scripts/build-android.sh all --force
./scripts/build-android.sh all --cache-status  # 只判断门禁是否可复用，不启动 Gradle
~~~

所有本地入口默认使用仓库同级的 `/home/ygy/.gradle-cache`，共享 Gradle wrapper、依赖、daemon、
configuration cache、task cache 和 Kotlin 增量输出。不要再直接使用 `/root/.gradle` 启动第二套 daemon；
8 GB 主机同时保留两套 4 GB Gradle daemon 会显著拖慢 R8 和模拟器。

`dev-workflow.sh` 会自动协调内存：先用 `--cache-status` 判断 Android 阶段；命中时不再重复调用构建
脚本，也保留正在运行的模拟器和 Gradle daemon。只有确实需要 Gradle 构建时才暂停模拟器，并在随后
的模拟器验证前停止本轮启动的 Gradle daemon；若 AVD 被手动停止，则在重新启动前也先释放已有 Gradle
daemon，避免两者争用内存。缓存文件和编译输出始终保留。

## 4. 服务器脚本门禁复用

~~~bash
./scripts/test-server.sh
./scripts/test-server.sh --force
~~~

该门禁对 `bootstrap-daemon.sh`、`install-codex-pinned.sh`、`codex-app-server-ssh` 执行 Bash 语法
检查，对 `smoke-test.mjs` 执行 Node 语法检查，并把固定 Codex 版本与 Bash/Node 工具链纳入指纹。
它不会安装 Codex、读取登录状态或修改远程服务器。需要真实 app-server 验证时，仍按架构文档的
“真实 SSH/app-server 回归”使用已经准备好的长期测试账号和运行时。

## 5. OpenCode 测试运行时复用

统一入口：

~~~bash
./scripts/test-opencode.sh quick
./scripts/test-opencode.sh full
~~~

`ensure-opencode-runtime.sh` 按 `protocol/opencode-version.txt` 查找可复用运行时，依次使用：

1. 显式 `OPENCODE_BIN`；
2. PATH 中版本完全匹配的 `opencode`；
3. 当前用户或 root 已由 App 安装的固定 OpenCode；
4. `.workflow-cache/opencode/<version>` 中的一次性本地安装。

找不到时才通过 `registry.npmmirror.com` 安装固定 `opencode-ai` 和 `jsonc-parser`；7890 可用时自动
使用代理。临时目录不再保存一套 100 MB 以上的 OpenCode，真实集成测试也不访问生产模型 API：它使用
隔离配置和本地假 OpenAI 兼容服务。

## 6. 模拟器长期复用

~~~bash
./scripts/android-emulator.sh start
./scripts/android-emulator.sh status
./scripts/android-emulator.sh stop
./scripts/android-emulator.sh log

./scripts/emulator-smoke.sh debug
./scripts/emulator-smoke.sh release
~~~

默认复用 API 34 的 `Codex_API_34` AVD 和 `emulator-5554`。root 环境使用临时 systemd service 托管，
不会因当前终端或编码任务结束而被回收。主动停止时保存 Quick Boot 状态；下一次启动继续使用原 AVD。

`emulator-smoke.sh`：

- 保留 App 数据、服务器配置、导入密钥和 Android Keystore；
- 按 APK SHA-256 判断是否需要 `adb install -r -d`；
- 直接启动 `MainActivity`，等待进程和 UI 稳定；
- 保存最新截图、UI XML 和 logcat 到 `.workflow-cache/emulator/`；
- 检查本应用崩溃/ANR，也检查覆盖页面的 Android 无响应/崩溃弹窗；
- 默认不关闭模拟器，便于接着做手工回归。
- 统一工作流按 APK、测试脚本、宿主机启动、模拟器进程和 Android 启动身份缓存成功冒烟；同一 APK
  在同一持续运行的 AVD 上不会重复启动 App，`full --force` 则始终真实重跑。

只有需要验证首次启动/迁移时才清除 App 数据：

~~~bash
./scripts/emulator-smoke.sh release --reset-data
~~~

不要在普通流程使用 `-wipe-data`、删除 AVD 或卸载 App；这些操作会丢失最有价值的复用状态。

## 7. SSH 和 Agent 测试主机复用

本机只需准备一次：

~~~bash
./scripts/reusable-test-host.sh prepare
./scripts/reusable-test-host.sh status
~~~

默认创建并长期保留 `codexemu`、固定密码、`/home/codexemu/workspace` 和 profile 信息。模拟器访问
宿主机地址为 `10.0.2.2:22`。首次在 App 添加这个服务器后，不要清除 App 数据；Codex/OpenCode 由
App 安装到该用户目录后也长期保留。后续任务只更新 APK，以下内容都无需重做：

- SSH 服务器表单和已信任指纹；
- 工作目录；
- 模型 URL、Key、模型列表和 Agent 设置；
- 远端 Node、Codex、OpenCode、bridge 和 npm 依赖；
- 测试会话和 Agent 登录状态。

当前 profile 内容写在 `.workflow-cache/test-host/profile.txt`。该目录不提交 Git，也不在普通任务结束时
清理。需要不同账号或密码时通过 `CODEX_TEST_HOST_USER`、`CODEX_TEST_HOST_PASSWORD` 覆盖后再次
执行 `prepare`。

## 8. 本地 APK 发布

~~~bash
./scripts/publish-local-apk.sh          # 默认复用相同内容的 release 门禁
./scripts/publish-local-apk.sh --force  # 明确重跑 release 门禁
~~~

脚本始终执行签名校验并实际下载验证：

~~~text
构建 APK：app/build/outputs/apk/release/app-release.apk
归档 APK：dist/CodexRemote-<version>.apk
Web APK：/var/www/html/codex.apk
下载地址：http://210.16.163.118:18080/codex.apk
~~~

三者 SHA-256 必须相同。若 Web 文件已经是同一哈希，则不再复制，但 HTTP 下载校验不会跳过。
`publish-gitee-release.sh` 和 `publish-tag-release.sh` 显式使用 `--force`，因此线上流程永远不会信任
本机 stamp。

## 9. 推荐节奏和预期收益

一次典型功能修改建议按以下节奏：

1. 编码过程中反复执行 `quick`。
2. 功能完成执行一次 `check`，继续在已启动模拟器中做针对性操作。
3. 提交前执行 `full`；只有相关输入变化才付出完整门禁成本。
4. 用户要 APK 时执行 `publish`；同一源码不会再跑第二次 Release。

在当前机器上，实际收益主要来自：

| 原重复工作 | 优化后 |
| --- | --- |
| 每次重新下载/解压 OpenCode 约 100-160 MB | 固定运行时只保留一份，直接发现复用 |
| 本地发布再次跑 Release 测试、Lint、R8 | 同一内容命中门禁，通常只剩验签和 HTTP 校验 |
| 每次冷启动 AVD、安装同一 APK | AVD/App 数据保留，相同 APK 跳过安装 |
| 每次创建 SSH 用户、密钥、工作目录、安装 Agent | 固定测试用户和远端依赖长期保留 |
| `/root/.gradle` 与 `/home/ygy/.gradle-cache` 两套 daemon 抢 8 GB 内存 | 所有本地构建统一到一套 cache，构建/模拟器错峰运行 |
| 每次任务结束清除临时测试状态 | 普通流程不清理；需要首次状态时显式 `--reset-data` |

OpenCode 的固定版本优先从已安装 npm 包元数据读取，不为版本探测启动约 2 秒的二进制；实际二进制
SHA-256 只在文件元数据变化时重算。缓存命中时 `quick/full` 通常只需秒级；相同源码再次本地发布
通常只需验签、复制/复用和下载校验。首次
改动后的完整编译和首次 AVD 冷启动仍有真实成本，但之后不会因流程设计重复支付。

当前 8 GB 主机在 Gradle、OpenCode 和 AVD 均已准备好的实测结果（2026-08-04）：

| 命令 | 实测耗时 | 说明 |
| --- | ---: | --- |
| `full --force` | 约 2 分钟 | 真实 OpenCode 集成、Gradle 全门禁、模拟器重启和 App 冒烟 |
| 相同内容再次 `full` | 3 秒 | 四层门禁命中，模拟器 PID 不变，不启动 Gradle |
| 相同内容再次 `publish` | 以验签和 HTTP 下载校验为主 | 不重复构建、安装 APK 或启动 App |

## 10. 故障定位

~~~bash
./scripts/dev-workflow.sh status
./scripts/android-emulator.sh log
sed -n '1,120p' .workflow-cache/emulator/latest-logcat.txt
cat .workflow-cache/emulator/latest-smoke.txt
cat dist/local-release-metadata.txt
~~~

缓存行为可疑时先运行对应阶段 `--force`，不要删除全部缓存。只有特定缓存确实损坏时才处理该目录；
保留其他阶段的成功结果、AVD、App 数据和 Agent 安装。
