# Gitee Go 线上构建优化与问题修复记录

本文记录当前 Gitee Go Android 发布流水线的线上构建方案、近期修复和 v1.8.174 →
v1.8.175 的实测结果。当前行为以 `.workflow/流水线-flutter-refactor-编译.yml` 和
`scripts/run-gitee-release.sh` 为准；操作入口和发布约束见
[GITEE_GO_RELEASE.md](GITEE_GO_RELEASE.md)，当前使用 `main` 自动发布入口。

## 当前线上方案

当前 Gitee Go 只保留一个 `main` 分支自动发布入口。工作流执行：

```text
main push
  -> bootstrap-regression       (最多 300 秒)
  -> android-sdk-regression     (最多 300 秒)
  -> gradle-regression          (最多 600 秒)
  -> gitee-release               (最多 5400 秒)
```

`gitee-release` 默认只构建 Release APK，不先构建 Debug APK；Release 阶段仍保留 Flutter
analyze、完整 Flutter 测试、稳定签名校验、APK 发布和公开下载回验。只有诊断双变体时才显式设置
`CODEX_RELEASE_BUILD_MODE=all`。

环境准备使用固定的 Java 17、Gradle 9.1、Flutter 3.44.8、Android Build Tools 36.0.0 和
NDK 28.2.13676358。Gradle 用户目录先隔离，再准备 Node 和托管 Maven 依赖；Flutter SDK 与
Android SDK 并行准备，Android 完成后在同一条 lane 准备 Gradle。所有环境阶段共享 3600 秒的
总预算，单阶段的上限不能相加理解为更长的窗口。

流水线设置 `caches: []`，不跨构建上传或恢复整个 SDK、Gradle、Pub 等目录；只归档 `dist/`。
作业内仍会复用本次运行的磁盘缓存和 Gitee 预装 SDK，完全新的 runner 可能需要重新准备依赖。
这一取舍是有意的，不能把关闭平台缓存传输误写成“关闭了所有缓存”。

## 主要优化

### 1. 移除会阻断产物的整目录缓存上传

此前整套 Flutter/Android/Gradle/Node/Pub 缓存压缩后触发 HTTP 413，APK 已经编译成功却无法完成
构件暂存。现在只上传 `dist/` 构件，保留作业内磁盘缓存和平台预装组件复用。恢复跨构建缓存前，
必须先验证有界缓存的体积和平台上限，不能重新加入整个 SDK 或 Gradle 目录。

### 2. Flutter 与 Android→Gradle 并行准备

`scripts/prepare-ci-sdk-pair.sh` 启动两个受同一外层监督器管理的 lane：

- Flutter lane：下载、校验并准备固定版本 Flutter SDK；
- Android lane：复用/补齐 Android SDK，完成后准备 Gradle 发行包。

两条 lane 都留在外层进程组中。任一 lane 失败会立即返回，由监督器清理仍在运行的同组子进程，
不使用 detached session，也不吞掉失败继续发布。完成文件只用于轮询两个很小的状态结果，避免
捕获输出管道被存活的 peer 阻塞。

### 3. 隔离 Gradle 用户目录并修复仓库解析冲突

`prepare-ci-gradle-home.sh` 只链接可复用的 `caches`/`wrapper`，不继承宿主机的 init 脚本、
`gradle.properties` 或凭据。私有 `init.d` 只安装当前 Flutter SDK 所需、经过审查的仓库策略，
不通过全局 init 修改 Flutter included build 的项目仓库，也不放宽 `FAIL_ON_PROJECT_REPOS`。

同时保留 Central 的完整 group 解析能力，避免过窄的 `exclusiveContent` 把 ASM、Guava、Gson 等
AGP 传递依赖排除在 Central 之外。Flutter、Kotlin、ASM、Android 和普通依赖分别使用明确的镜像
策略，并由离线 Gradle 仓库预检验证正例和负例。

### 4. 固定版本、哈希和有界下载

Node、Flutter、Gradle、Android Command-line Tools、CMake、托管 Maven/CI 依赖均使用固定版本和
SHA-256（或逐文件摘要）。下载支持有限重试、续传和源回退，但连接、读取、单次传输、阶段和总预算
均有上限。校验失败只保留原缓存，不把不完整文件交给后续编译。

Android SDK 先检查 Gitee 预装目录和已有可写缓存；预装目录只读时切换到
`~/.cache/codex/android-sdk`，只复制有效且兼容的组件。CMake 3.22.1 和随包 Ninja 单独校验，
缺失或版本不匹配在 APK 编译前修复，不把问题推迟到 Gradle 阶段。

### 5. Release-only 构建和 Gradle 性能诊断

线上默认跳过未交付的 Debug APK，避免冷 runner 重复编译。Release APK 调用临时 launcher 包装器，
只增加 Gradle `--profile`，结束后恢复原 launcher、文件权限和工作区状态。诊断采集器只读取本轮
新生成报告中的白名单数字字段，限制报告数量和单文件大小，不复制命令、URL、参数或凭据；采集失败
不会改写构建退出码。

报告输出为：

```text
dist/build-diagnostics/release.json
dist/build-diagnostics/debug.json   # 仅 CODEX_RELEASE_BUILD_MODE=all 时可能出现
```

### 6. 发布链路的失败边界和可验证产物

Gitee 命令通过同一个严格 Shell 串行执行回归和发布；每个阶段由
`run-ci-stage.sh` 以进程组设置超时，TERM 后最多 30 秒再 KILL。回归失败、超时、标签/版本不匹配、
稳定签名不匹配、上传失败或公开下载大小/SHA-256 不一致，都会阻止“发布成功”结论。

## 修复的问题清单

| 问题 | 修复 | 当前结果 |
| --- | --- | --- |
| 整目录缓存上传 HTTP 413，阻断成功构建后的构件暂存 | `caches: []`，只保留 `dist/` 归档；作业内缓存和预装 SDK 仍可复用 | 不再依赖大缓存上传 |
| Gitee 全局 Gradle 配置污染 Flutter included build | 隔离 `GRADLE_USER_HOME`，不继承 init/属性/凭据，只安装受控仓库策略 | Gradle 用户目录隔离回归通过 |
| Central 仓库过滤过窄导致 ASM/传递依赖下载超时 | 保留 Central 完整 group 能力，Flutter 仓库单独限定，加入离线正负例 | 仓库回归通过 |
| CMake 下载 404、Google 源超时、预装目录只读或版本不符 | 托管并校验 CMake 归档；优先复用匹配预装组件，必要时复制到可写缓存 | Android SDK 回归通过 |
| Gradle/依赖动态下载中断、错误哈希或无限等待 | 固定版本和哈希，有限续传/回退，连接/传输/阶段超时 | Gradle 回归通过；curl 18/22 仅出现在负例 |
| Node、Maven、Pub 和 Android 依赖在冷 runner 上不稳定 | 托管小型依赖包、固定提交和摘要，复用预装项，失败时有界重试 | 环境准备回归通过 |
| 多条 Gitee 命令失败后仍可能继续下一阶段 | 统一由 `run-gitee-release.sh` 和 `run-ci-stage.sh` 严格串行执行 | 失败退出码可透传 |
| 线上先构建 Debug 再构建 Release，浪费冷启动和 Gradle 时间 | 默认 `CODEX_RELEASE_BUILD_MODE=release`，保留 analyze、全量测试和签名校验 | 正式发布只产出 Release APK |
| 无法判断 Gradle 慢在哪里，且采集可能泄露命令/URL | 临时 `--profile` 包装器 + 有界白名单 JSON 摘要 | v1.8.175 产生 release 诊断报告 |
| 并行任务失败后残留下载/编译子进程 | 两条 SDK lane 共用外层进程组和失败快速清理 | 并行与取消回归通过 |
| APK 发布成功但公网附件可能损坏或不是本次构建 | 上传后重新核对公开大小和 SHA-256 | v1.8.175 公开回验通过 |

## v1.8.174 → v1.8.175 实测

### 总体结果

| 指标 | v1.8.174 | v1.8.175 | 变化 |
| --- | ---: | ---: | ---: |
| 从任务开始到公开验证完成 | 924 秒（15 分 24 秒） | 817 秒（13 分 37 秒） | **减少 107 秒，约 11.6%** |
| Flutter/Android/Gradle 准备 | 194 秒 | 122 秒 | 减少 72 秒 |
| Release APK 阶段 | 478.237 秒 | 449.749 秒 | 减少 28.488 秒 |
| Flutter 全量测试（770 项） | 91.309 秒 | 86.025 秒 | 减少 5.284 秒 |

准备阶段的直接并行重叠约 67 秒（Android 61 秒、Gradle 6 秒均在 Flutter 122 秒期间完成）。
两次运行的网络、解压和 runner 状态不同，因此 107 秒的总减少量不能全部归因于并行修改；APK
阶段约 28.5 秒的变化也应继续作为观测值，而不是承诺的固定收益。

v1.8.175 的发布验证结果：

- Flutter analyze 通过，770 项 Flutter 测试全部通过；
- Release APK 构建成功，大小为 31,702,366 bytes；
- Gitee Release 上传、公开下载大小和 SHA-256 回验均通过；
- `dist/` 构件归档大小为 31,335,732 bytes，共 4 个文件：APK、`release-metadata.txt`、
  `build-diagnostics/release.json` 和 `release-publication.json`。

本轮主要阶段实测如下。`gitee-release` 的 778 秒内含约 450 秒 APK 构建，属于 817 秒总时长，
不能重复相加；其他阶段也有嵌套和并行关系。817 秒截至 23:41:35 公开验证完成，平台 tar 构件
归档于 23:41:36 完成，另晚 1 秒。

| 阶段 | 用时 |
| --- | ---: |
| Bootstrap / Android SDK / Gradle 回归 | 10 / 11 / 18 秒 |
| `gitee-release`（含 APK 构建与发布） | 778 秒 |
| Node SDK / 托管 Maven | 13 / 1 秒 |
| Flutter + Android→Gradle 准备 | 122 秒 |
| Gradle 仓库预检 / Flutter precache | 51 / 3 秒 |
| Analyze | 21.205 秒 |
| Flutter 测试（770 项） | 86.025 秒 |
| Release APK 阶段 | 449.749 秒（日志显示约 450 秒） |
| Gitee Release 发布与公开回验 | 20 秒 |

### Gradle 诊断摘要

v1.8.175 的 `release.json` 记录了以下 Gradle 计时摘要：

| 项目 | 秒数 |
| --- | ---: |
| Total Build Time | 446.890 |
| Startup | 17.751 |
| Settings and buildSrc | 68.500 |
| Configuring Projects | 95.790 |
| Artifact Transforms | 42.315 |
| All dependencies | 12.119 |
| Task Execution | 592.120 |

`Task Execution` 是任务的累计计时，任务之间可以重叠，因此它大于 446.890 秒是正常的，不能把
这些行简单相加。`All dependencies` 也不是完整网络下载时间，包含 Gradle 的依赖相关工作，不能
据此断言所有下载只用了 12.119 秒。

最慢任务包括：R8 压缩 77.470 秒、Flutter Release 编译 62.230 秒，以及多个插件的
`lintVitalAnalyzeRelease`（约 22.872～38.685 秒）。这些数据用于下一轮是否需要优化的证据，
不代表可以直接关闭 R8、Lint 或安全检查。

### 缓存体积解释

本轮报告测得的缓存目录是未压缩的 apparent bytes：

| 目录 | 字节数 |
| --- | ---: |
| Gradle modules | 1,167,176,734 |
| Gradle build cache | `null` |
| Gradle wrapper | 741,074,327 |
| Pub | 320,800,327 |
| Flutter SDK | 2,549,785,592 |
| Android SDK | 3,264,072,461 |

已测五类目录合计约 8.04 GB。这个数不是压缩后的上传量，也不是平台缓存限额；`null` 只表示该
目录缺失或本轮无法测量，不能解释为“Gradle build cache 已关闭”。因此当前继续保持 `caches: []`，
不恢复整目录上传。

## 当前暂停的优化项

v1.8.175 的并行准备和诊断已作为当前线上基线，暂不继续修改构建策略。后续若重新评估，应先用
多次成功构建确认真实缓存命中率和收益，再考虑有界的 Gradle 任务输出缓存；不能仅凭目录体积或一次
profile 报告承诺固定节省时间。除非有新的失败证据或明确的收益测量，不应：

1. 恢复整套 SDK/Gradle/Pub 缓存的跨构建上传；
2. 为缩短时间关闭 R8、Lint、签名校验、完整 Flutter 测试或公开下载回验；
3. 把 `Task Execution`、依赖计时或缓存 apparent bytes 当作可直接相加的流水线耗时；
4. 把负例回归中的 curl 18/22、超时 KILL 或 root/KGP 警告误报为本轮发布失败。

## 关联入口

- [Gitee Go 发布流程](GITEE_GO_RELEASE.md)
- [本地与云端工作流](LOCAL_WORKFLOW.md)
- `.workflow/流水线-flutter-refactor-编译.yml`
- `scripts/run-gitee-release.sh`
- `scripts/prepare-ci-environment.sh`
- `scripts/prepare-ci-sdk-pair.sh`
- `scripts/collect-ci-build-diagnostics.cjs`
