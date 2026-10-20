# 本地高复用开发流程

本文是当前 Flutter/Android 工程的本地构建、测试、模拟器验收和 APK 发布唯一说明。它描述的是
仓库中的 `flutter_app/`，不是旧 `app/` Kotlin/Compose 工程。目标是复用依赖、构建输出、模拟器和
测试服务器，缩短反馈时间，同时不牺牲可重复性。

正式 Gitee 发布不信任本机成功缓存。Flutter 迁移已合并到 `main`；开发可在功能分支进行，
推送 `main` 到 GitHub 和 Gitee 会分别自动构建并发布，推送前必须递增 Pubspec 的版本和 build number。

Gitee 环境准备由 `scripts/publish-tag-release.sh` 执行，流水线只自动响应 `main` 分支推送，标签推送不再触发。
`.workflow/` 只保留 `流水线-flutter-refactor-编译.yml`。历史 `流水线-202608021802.yml` 必须从对应
分支删除，并在 Gitee Go 核对旧“构建”入口已关闭；不要对同一提交同时手动重跑和推送。
main 发布预检核对 origin/main 与 HEAD，并按 `pubspec.yaml` 创建缺失的 `v<version>` 标签；已有标签必须指向同一提交。
正式发布还要求对 main 构建可用的密文变量 `CODEX_RELEASE_TOKEN`，具备目标仓库写权限；不得在日志或聊天中提供令牌。
缺失时在环境下载前失败，编译前通过 Node 发布预检检查身份与仓库访问。构建并验签后，
`publish-gitee-artifact.cjs` 为已有标签创建非预览 Release、上传同一 `Agent-<version>.apk`，并公开下载核对
大小与 SHA-256。只有回验成功才输出 Published and verified；`dist/release-publication.json` 留存非敏感发布结果。
仅 main 预检允许创建缺失标签，任何入口都不移动已有标签。上传不再次编译，同名附件必须回验且不能覆盖。
`dist/` 暂存下载与正式 Release 同时保留。
发布回归/预检各限 120 秒，发布整体限 900 秒（API 单次 30 秒，上传/回验各 300 秒），继续受总发布预算约束。
`test-gitee-release.cjs` 仅使用 loopback 和假令牌，在云端检查幂等、失败、公开附件哈希、令牌隔离和超时。
YAML 只执行 `bash scripts/run-gitee-release.sh main`，通过严格 Shell 串行调用回归与发布，失败或超时
不能继续下一阶段。手动调用旧标签入口时，仍限时 60 秒获取 origin 的精确标签并校验提交；该模式不创建或移动标签。
Gitee YAML 使用 `caches: []` 关闭跨构建缓存传输，避免整个 SDK/Gradle 等目录上传 HTTP 413 后
阻断 APK 产出暂存；`dist/` 构件上传保持开启。作业内磁盘缓存、预装 SDK 复用及本机缓存不受影响，
但全新 runner 不再从平台恢复这些缓存。云端回归锁定空缓存配置和发布构件配置，恢复缓存前必须验证体积上限。
Gradle 回归只依赖已跟踪的根 Wrapper JAR，不依赖本机生成的 Flutter Android Wrapper 文件。
标签与旧分支入口共用 `scripts/prepare-ci-environment.sh`，不能跳过 Flutter/Android/Gradle 环境准备。
`1.8.175+307`：隔离 home、Node 与托管 Maven 后，最多两路并行准备 Flutter SDK 和 Android→Gradle；
两路完成才运行原有仓库预检和 Flutter Android precache。共享 Linux 单调时钟的 3600 秒预算，各阶段
仍取自身上限与剩余预算的较小值；任一路失败立即返回，外层监督器清理同组子进程，不允许吞掉错误继续。
CI 的 APK 阶段临时包装生成的 Gradle launcher，向原 launcher 增加 `--profile`，正常退出/失败后恢复；
首次构建使用已验证 Flutter SDK 中的 Wrapper 模板。原生 APK 模式仍为 Release，保留 `--pub` 与全部测试。
不用 init 动态开启 profile（Gradle 建立 profiling 服务后再设置已经太晚），不修改 SDK 或上传 Build Scan。
摘要位于 `dist/build-diagnostics/release.json`，诊断双变体时另有 `debug.json`，随原 dist 构件一起保留。
日志输出 Gradle 启动、settings、配置、依赖解析、变换、任务耗时与最慢任务；只收集本轮新报告中的白名单
字段，不复制含命令/URL 的原 HTML。采集最多 8 份、每份 4 MiB；普通失败保留构建退出码，KILL 可能无报告。
摘要同时记录六类缓存目录未压缩字节数（每类最多 2 秒，null 表示不可用），供下一轮评估有界缓存。
保持 `caches: []`，没有恢复曾造成 HTTP 413 的整目录上传。不能把未压缩目录大小当作上传限制或实际传输大小。
比较基线为用户提供的 v1.8.174：全程 924 秒，Flutter SDK 123 秒，Android 64 秒，Gradle 准备 7 秒，
Release 编译约 478 秒。v1.8.175 线上全程为 817 秒，SDK 并行准备 122 秒、Release 编译约 450 秒；
两轮全程缩短 107 秒（约 11.6%），不是受控性能实验，不能全归因于并行。完整修复、缓存策略和诊断解释见
[Gitee 线上编译优化记录](GITEE_BUILD_OPTIMIZATION.md)。当前方案先保持，暂不继续优化。
Gradle 的操作计时可能重叠，不可简单求和；依赖解析同时包括本地工作，不能全部归为下载。
新增并行与诊断 fixture 同时接入 GitHub Android job（300/120 秒上限）；Gitee 仍在原预检阶段执行，
真实 profile 格式由既有离线 Gradle 调用验证；v1.8.175 线上回归、770 项 Flutter 测试、Release 构建和公开下载校验已通过。
`prepare-ci-gradle.sh` 固定 Gradle 9.1.0-all 与官方 SHA-256，国内镜像失败可回退官方，最多六次限时
续传；校验后的 ZIP 预填原 URL 对应的 Wrapper 缓存，缓存挂载根目录与已解压发行版保持不变。
CI 通过 `prepare-ci-gradle-home.sh` 创建独立的 Gradle 用户目录（准备上限 60 秒），只链接原
`GRADLE_USER_HOME` 的 `caches`/`wrapper`。用户级 init 脚本和 `gradle.properties` 不继承，原文件
不删除；隔离目录在工作区忽略的 `.workflow-cache/gradle-user-homes/` 下，不作为全局配置缓存。
发行包准备后运行 `test-ci-gradle-repositories.sh`（上限 240 秒），使用真实 Gradle、离线临时
工程验证受污染目录和隔离后的严格 included-build 插件加载，失败时立即停止后续测试及出包。
不放宽 Flutter SDK 的 `FAIL_ON_PROJECT_REPOS`，不通过 init 向 included build 注入项目仓库。
CI 通过 `CODEX_CI_MAVEN_MIRRORS=1` 为应用插件解析、子项目 buildscript 和依赖启用阿里云镜像。
`1.8.174+306`：Gitee 同时启用 `CODEX_CI_HOSTED_DEPENDENCIES=1`。`ci-dependencies.tsv` 固定
每个小组件的标签、提交、路径、原包 SHA-256 和大小；`fetch-ci-package.sh` 共用有界 Git 下载器。
`ci-deps` 原包总计 344,937,827 字节，单文件最多 40 MB；不超过用户 400 MB 依赖预算，并遵守
免费仓库 500 MB / 单文件 50 MB 限制。40 MB 分片按序合并、校验原包，不另存完整重复包。
独立不可变标签只含一个组件，与 ci-deps 分支共享 Git blob；下载单个组件不拉整个分支。
托管 CMake、Node Linux x64、Android Platform 34/35/36、Build Tools 36.0.0、Platform Tools 和
AndroidX 测试依赖小包；保留全部上游许可证/来源摘要。NDK、Flutter SDK、Gradle 与命令行工具不纳入。
后续更新必须计算所有保留版本及历史对象的容量，达到预算即停止增加，不自动改写历史。
Gitee 预装和有效缓存仍优先，自定义 Android 仓库不会被托管下载覆盖。
Node 后新增最多 420 秒的 Maven 准备阶段，取剩余环境预算；重新从校验后的 ZIP 解压并验证逐文件摘要，
将私有目录通过 `CODEX_CI_MAVEN_REPOSITORY` 传给 Gradle。仅 `runner`、`rules`、`espresso-core`
独占本地模块元数据，覆盖 Flutter 的 `1.2+` / `3.3+` 声明及插件后来追加的 Google 仓库；
传递依赖只限定归档内具体版本，其他版本仍走普通镜像，不降低应用已有依赖版本。
离线 Gradle 仓库预检用较新的错误远端版本验证动态范围没有逃逸，并确认未托管版本仍可用。
Kotlin 和 `org.ow2.asm` 只使用 Central 镜像/官方源，Flutter `io.flutter` 只使用
`$FLUTTER_STORAGE_BASE_URL/download.flutter.io`，避免从 Google Maven 查找这些依赖导致长时间超时。
Central 仓库必须保留所有 group 的解析能力：不能把它放进仅匹配 Kotlin 的 `exclusiveContent`，
该 API 同时收窄目标仓库，会把 ASM、Guava、Gson 等 AGP 传递依赖排除在 Central 镜像之外。
Kotlin/ASM 改为在其他仓库上排除，规则也覆盖插件后续追加的 Google 仓库；Flutter 专用仓库仍可独占。
私有 home 的 `init.d` 仅安装仓库审核的 `ci-flutter-repositories.init.gradle`，匹配当前 SDK 精确路径，
仅在 Settings 层为 Flutter included build 补齐插件/依赖镜像；其他 included build 和本机构建不受影响。
离线仓库预检实际解析 Kotlin、Flutter 三 ABI/embedding、Android 和 Central 依赖，并覆盖
`gradle-api:8.11.1 -> asm:9.7.1`、ASM Commons、Guava、Gson 在 included-build compileClasspath、
app buildscript 和普通依赖中的传递解析。Google 错误包及官方回退对照包用于确保 Central 镜像没有被收窄，
不能只靠官方回退通过检查。继续验证原 init 隔离与严格仓库策略；私有目录清理最多重试 5 次。
已有 Gitee JDK、匹配 Android SDK 组件与 Gradle 依赖/Wrapper 缓存继续复用；不会为了镜像配置重新下载
全部 SDK，也不恢复已导致 HTTP 413 的整目录缓存上传。
Gitee 必须设置明确超时：环境、Android SDK 与 Gradle 隔离回归上限 300/300/600 秒，发布总任务上限 5400 秒；
环境准备总预算 3600 秒，各 SDK/Gradle/引擎阶段均取自身上限与剩余预算的较小值。
其中 Node 准备上限 900 秒，复用已有 Node 18+，否则固定下载并校验 Node 22.17.0，缓存于
`~/.cache/codex/node`。其 bin 路径必须导出给 Flutter 测试；Gitee Android 镜像不保证带 Node，
缺失时不得跳过 Claude 安装集成测试或对空路径创建符号链接。
统一由 `run-ci-stage.sh` 执行，超时 TERM 后最多 30 秒 KILL，保留阶段名和非零退出码，不无限重试。
嵌套阶段使用同一受校验的工作进程组；sdkmanager/Pub 的阶段超时终止任务，不继续叠加重试，
临时网络响应错误仍可有限回退。CI 显式禁用 Gradle 常驻 daemon。
Gradle HTTP 连接/读取各限 30 秒；Debug 和 Release 的整次 Flutter 编译各限 1200 秒，
包含 Flutter 内部 Gradle 重试，重试不重置预算。到期停止整组编译进程并报告失败。
强制 KILL 无法执行退出清理；失败重跑必须使用干净 checkout，不能直接发布残留临时锁文件映射的工作区。
下载连接上限 20 秒、单次传输最多 300 秒，准备锁与 Wrapper 锁分别最多等待 300/120 秒。
对应离线 fixture 为 `scripts/test-ci-environment.sh` 与 `scripts/test-ci-gradle.sh`，正式发布前在 Gitee 执行。
GitHub 的跨平台出包由 `.github/workflows/flutter-refactor-ios.yml` 响应 `main` 推送，也允许手动运行 main。
两个平台都只保留各自一个自动入口，发布创建的 `v<version>` 标签不触发第二轮构建。
GitHub 先核对版本标签没有被其他提交占用，各平台 job 限时 60 分钟，发布限时 15 分钟；
附件先上传到 draft 并下载比对，再转成正式 Release，不使用 prerelease，也不覆盖已有同名附件。
Android 的 Ubuntu job 和 iOS 的 macOS job 都执行完整 analyze/test；Claude Linux SSH 安装脚本的
集成测试只在 Linux 执行，由 Android job 把关，其他 adapter、协议及 API 测试仍在两端执行。
iOS 使用 macOS 15 并显式选择 Xcode 16.4，三个平台全部成功后才发布统一 Release。
Flutter 缓存路径为挂载点时保留根目录，从 `storage.flutter-io.cn` 下载固定版本 SDK 压缩包，验证固定
SHA-256 与 revision 后在子目录复用。下载有三次限时尝试，保留断点文件；不从 GitHub 克隆 Flutter。
`FLUTTER_STORAGE_BASE_URL` 和 `PUB_HOSTED_URL` 默认使用 Flutter 中国社区镜像，允许流水线变量覆盖。
Gitee 依赖阶段启用 `CODEX_CI_PUB=1`：`prepare-ci-pub.sh` 对国内默认 Pub 源的临时网络错误
最多重试两次，再回退 `pub.dev` 两次，每次上限 300 秒。全程强制锁定依赖版本和哈希；
只临时映射公共源 URL，退出后恢复原 `pubspec.lock`。自定义源不自动回退，版本/哈希/鉴权错误直接失败。
网络错误分类先排除 `[CI]` 监督器日志，避免把每次启动的 `timeout 300s` 误当下载错误；
超时、取消和终止退出码立即返回，不对哈希/版本冲突或鉴权错误重复四次请求。
首次安装、HTTP 中断/续传、错误哈希、失败重试及旧缓存兼容由 `bash scripts/test-ci-flutter.sh` 验证，
并纳入 `scripts/test-workflow.sh`。
Android SDK 由 `scripts/prepare-ci-android.sh` 在 Gitee 入口中准备。它先探测现有 `sdkmanager`，
缺少时从 `googledownloads.cn` 下载并校验固定 Android Command-line Tools 12.0，再用国内仓库
安装所需 platform、Build Tools 和 NDK；CMake 3.22.1 单独准备，完整 SDK 缓存位于 `~/.cache/codex/android-sdk`。
platform 清单包含 API 34/35/36：应用使用 36，锁定的 `jni`/`jni_flutter` 使用 35，
`package_info_plus`/`share_plus` 使用 34。每个版本核对 `android.jar` 与 API 元数据，优先复用有效缓存
或复制 Gitee 预装，只补缺失/损坏项，不能等 AGP 在 APK 编译阶段临时下载。插件升级时复核清单，
不靠修改插件 compileSdk 或延长 1200 秒编译超时解决缺包。
默认仓库的包安装失败后，剩余尝试回退 Google 官方仓库，总计最多三次；显式设置
`CODEX_ANDROID_REPOSITORY_URL` 时保持自定义源。超时或取消立即停止，不换源重试，
SDK 总阶段 1800 秒和共享环境剩余预算继续生效，下载校验仍由 sdkmanager 执行。
应用固定 CMake 3.22.1，准备阶段检查 CMake 与随包 Ninja 可执行，并将其 bin 目录放到 PATH 首位。
优先复用完整 SDK/预装包，也探测 PATH 中匹配的 CMake 和 Ninja；系统安装仅复制对应二进制及
`share/cmake-3.22`，不复制整个 `/usr`，不改变其他版本或系统安装。国内仓库的 CMake ZIP 返回 404，
且 Gitee runner 连接 Google 超时，因此默认缺包从本仓库 Gitee 的独立 `ci-deps` 分支托管归档获取。
`fetch-ci-dependency.sh` 浅取 `refs/tags/ci-deps-cmake-3.22.1-linux-x86_64`，严格核对提交
`598abbd92d9711f953613ee51987bd5c71b23b4f` 和归档 SHA-256
`9196644852a978012caf7a4067ba1898debf6cc204c3341562771e31080d6869`。
仅复制 22,308,647 字节的官方原样 ZIP，包含随包 Ninja、模块、版权和许可证，不包含完整 SDK。
通过无凭据公共 HTTPS 获取，不读取发布令牌，不 checkout、不执行 hooks，不改变应用 Git 工作区。
浅取最多两次、每次 180 秒、低速保护 30 秒；超时/取消立即终止、不重置阶段预算。
有效 ZIP 缓存不联网，失败保留原归档和安装；哈希/版本/工具校验通过才替换对应 CMake 目录。
该分支为独立历史，不合并 main、不移动标签、不使用 LFS、不包含工作流；两端仍只响应 main 推送一次。
其他 SDK 包仍走原国内仓库，不因 CMake 失败触发全仓库回退，也不依赖 GitHub 或 Google 下载。
自定义 `CODEX_ANDROID_CMAKE_URL` 必须同时提供 `CODEX_ANDROID_CMAKE_SHA256`；显式指定
`CODEX_ANDROID_REPOSITORY_URL` 时 CMake 仍完全交由该源的 sdkmanager 安装，不自动访问依赖分支。
自定义静态 URL 保留连接 20 秒、传输 180 秒、低速 30 秒、两次续传限制；HTTP 400/401/403/404 直接失败。
`test-ci-dependency.sh` 随 Android SDK 回归在云端执行，用本地 Git fixture 验证固定提交、哈希、离线缓存、
失败保留原文件和有界退出；SDK 回归同时锁定默认 Gitee 参数并确认获取失败后不继续安装。
工具缺失或 CMake 版本错误必须在编译前修复，不能仅检查 SDK 目录存在。
匹配完整版本首行，接受 `3.22.1` 和官方 Android 包的十六进制构建后缀（如
`3.22.1-g37088a8`）；其他补丁版本、预发布后缀和非零退出仍需修复，不把成功安装误判为缺包。
`scripts/test-ci-android.sh` 会隔离模拟无预装 SDK、旧命令行工具目录、损坏/缺失包、许可证和
并发缓存；本地工作流测试由 `scripts/test-workflow.sh` 一并调用。Gitee 预装目录只读时，
通过实际写入探测自动切换到独立缓存；后续 Flutter/Gradle 使用回传的可写 SDK 路径。
切换后优先保留有效缓存，并按包元数据与必要工具检查预装版本，将匹配的 platform、Build Tools、
NDK、CMake/Ninja 复制到缓存；只补装缺失或不兼容的组件。预装命令行工具经限时检查后连目录复用，
许可证复制后保持可写。复制支持 reflink、单次限时 300 秒，不链接回只读挂载、不修改原 SDK。
普通 Gitee 回归无需挂载权限即可覆盖完整/部分预装复用、错误版本拒绝和独立缓存；完整预装不联网下载。
SDK 回归使用构建已有的 JDK 17 生成保留 Unix 可执行权限的测试 ZIP，文本断言使用 grep，
无需额外安装 Python 或 ripgrep；脚本入口明确检查依赖，300 秒阶段上限保持不变。
定向修复会先确认许可证再安装单个包；默认源的 CMake 修复仅用 sdkmanager 确认许可证，随后复用
经过校验的 ZIP。回归覆盖系统工具复用、独立下载、错误哈希、不完整包、有界失败和自定义源隔离；完整缓存不触发安装。
断言失败会输出失败行号和隔离 SDK/入口日志的最后 60 行，保留原退出码并清理临时目录。
有挂载权限的 Linux 会额外自动执行真实只读挂载测试，也可显式运行：

```bash
unshare --mount --propagation private bash scripts/test-ci-android.sh --read-only-mounts
```

每次开始工作以及任何新会话、任务恢复、上下文压缩或摘要恢复后，都必须从仓库磁盘重新完整阅读根目录
`AGENTS.md` 和 `docs/ARCHITECTURE.md`；涉及构建、测试或发布时还必须完整重读本文。聊天记录、记忆和
压缩摘要不能替代这些原始文档。

用户明确要求“推送到远端并出包”或同义指令时，表示本地验收已经由用户完成。该场景跳过本地单元测试、
全量测试、analyze、本地构建和模拟器门禁，直接提交并推送，只跟踪云端流水线与 Release 结果。

## 1. 每次代码修改的固定流程

### 1.1 执行顺序

1. **定位但不改动**：运行 `git status --short --branch`；仓库有 `.codegraph/` 时先用
   `codegraph explore` 查调用链、现有测试和影响范围。此阶段不计入“开始修改到完成”的耗时。
2. **开始修改计时**：第一次写文件前用 `task-timing.sh start` 建立任务，`begin/end` 记录人工修改阶段，
   `run` 自动记录测试、构建及提交推送（示例见第 3 节）；明确本轮受影响文件、最近的定向测试和最终风险门禁。
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
   立即将当前分支分别推送到 Gitee `origin` 和 GitHub `github`，两个远端均成功才算完成，不能只执行
   不带远端名的 `git push`。只有用户明确要求暂缓提交或推送时才例外。

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
| `quick` | 频繁编码反馈 | 服务器脚本门禁、OpenCode bridge quick 门禁、Claude bridge 门禁、Flutter `analyze` |
| `check` | 一个功能完成 | 服务器脚本门禁、OpenCode bridge full 门禁、Claude bridge 门禁、Flutter analyze/test、Debug APK、Debug 模拟器冒烟 |
| `full` | 提交前或高风险改动 | 上述门禁、Debug/Release APK、Release 模拟器冒烟 |
| `publish` | 交付本机下载包 | `full` 的缓存结果、稳定签名校验、本机 HTTP 部署、内网下载哈希校验；外网地址只发布，不默认回验 |
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

跨越编码、评审、定向测试、门禁、打包、验签、下载回验和提交推送的任务级耗时使用
`scripts/task-timing.sh`。它只记录阶段标签、状态、UTC 时间和毫秒数，不保存被执行命令的参数或输出；
标签使用固定阶段名，不放入 URL、密钥、对话正文。失败返工会追加记录，不覆盖原失败：

```bash
task_id="mcp-collapse-$(date -u +%Y%m%dT%H%M%SZ)"
task_id="$(./scripts/task-timing.sh start "$task_id")"
edit_phase="$(./scripts/task-timing.sh begin "$task_id" 修改与评审)"
# 完成当前源码修改和评审后结束这个阶段；暂停工作前也应结束，恢复后另开阶段。
./scripts/task-timing.sh end "$task_id" "$edit_phase" 0
./scripts/task-timing.sh run "$task_id" 定向测试 -- \
  ./scripts/flutter-tool.sh test --no-pub test/ui/mcp_tool_card_test.dart
CODEX_TASK_TIMING_ID="$task_id" ./scripts/dev-workflow.sh publish --reuse
# 通过验证后，提交和两个远端推送也分别用 run 包装，保留实际退出码。
./scripts/task-timing.sh finish "$task_id"
```

记录写入 `.workflow-cache/task-timings/`，活动任务可用 `./scripts/task-timing.sh status` 查看。自动门禁的
`.workflow-cache/latest-workflow-timing.tsv` 仍是工作流分段记录。设置 `CODEX_TASK_TIMING_ID` 后，各工作流
阶段自动追加到同一任务；Android 缓存命中单列并记录实际查询耗时，不重复运行已有成功 stamp。
`run` 自动保留命令退出码，`begin/end` 用于跨工具的人工阶段；存在未结束阶段时禁止 `finish`。
`phase TASK LABEL ELAPSED_MS STATUS` 仅导入已有日志的实测数值，标为 `imported`，起止时间标为
`unknown`；没有证据的时长必须注明未测量，不填估计数或用零代替。重试分别保留，不把嵌套阶段重复相加。
任务总时长含暂停和等待，阶段可并行，因此总时长与阶段求和不同。自测使用独立临时目录，不能清理活动任务。

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

## 4. 服务器脚本与 Agent bridge 门禁

它们是仓库辅助工具的静态/本地验证，不代表 Flutter APK 已接入 Agent：

```bash
./scripts/test-server.sh
./scripts/test-server.sh --force
./scripts/test-opencode.sh quick
./scripts/test-opencode.sh full
./scripts/test-claude-code.sh
```

`test-server.sh` 检查 Bash 语法和 `server/smoke-test.mjs` 的 Node 语法，不登录或修改真实服务器。
`test-opencode.sh` 验证本地 bridge、调度和隔离的假 OpenAI 兼容服务；需要安装固定 npm 运行时时才下载。
两类脚本都使用内容 stamp，`--force` 才无条件重跑。

`test-claude-code.sh` 检查打包 bridge/settings 语法、隔离的配置读写/测试和 CLI 协议 fixture；本机安装了 Claude 时还执行
真实 CLI 集成，可用 `CLAUDE_CODE_TEST_BIN=/absolute/path/to/claude` 指定。真实 CLI 测试使用临时
HOME/配置和 loopback Anthropic fixture，覆盖工具授权/拒绝、停止、图片、去重、重启与恢复，不读取真实
认证、不调用付费 API。没有 CLI 时会明确报告该部分跳过，不得称为真实 CLI 验证通过。该门禁在
quick/check/full/publish 中执行，当前不复用其结果缓存。新增 Claude 能力还应运行 adapter、控制器和
UI 回归；Linux fixture 不替代用户手机与已认证服务器的端到端验收。

子 Agent 模型相关的改动必须用真实 CLI 手工复核，fixture 只能证明 bridge 传了什么，不能证明 CLI
采用了它。复核方式：用独立 `CLAUDE_CONFIG_DIR` 复制当前配置，分别以「会话级指定具体模型」「会话级
跟随主模型」「未设而跟随设置页默认」三种输入各派一个子代理，再读
`$CLAUDE_CONFIG_DIR/projects/*/<session-id>/subagents/*.jsonl` 里 `message.model` 的实际取值。
子 Agent 模型在 CLI 2.1.293 上依赖 `CLAUDE_CODE_SUBAGENT_MODEL_FORCE=1`，且 settings.json 的 env
优先于进程环境变量、命令行 `--settings` 优先于 settings.json；改动前先按上述三种输入重新确认优先级，
不要依据旧版本或文档推断。复核使用的临时目录和会话文件必须删除，不得留下探针会话。

只有获得用户明确授权且服务器已有 Claude 配置时，才可单独运行
`node scripts/test-claude-code-live.cjs --live`。它使用一次性 HOME、配置目录和工作区，最多两轮
真实付费请求，测试 Opus 5.5/effort/用量、bridge 重启和续聊；拒绝工具并禁用 MCP、技能与自动更新。
该脚本不属于 quick/check/full/publish 自动门禁，不能把真实请求当作默认回归；不要输出配置中的 URL、Key、
响应正文或临时文件。真实 Provider 的上下文窗口只按返回的 usage/元数据展示，不从环境上限推断。

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

提问弹窗的设备回归：在 SDK/Gradle 缓存环境已设置后执行
`./scripts/flutter-tool.sh --no-version-check test integration_test/user_input_dialog_test.dart -d emulator-5554`。
非阻塞提问另由 `test/ui/async_question_dialog_test.dart` 覆盖折叠入口、首次弹出、关闭/跳过、历史恢复、
只读和切换会话；回答需保留主输入草稿及附件，关闭和跳过不得发起请求或停止回合。
设备入口为 `integration_test/async_question_dialog_test.dart`，覆盖自动弹出、收起后点击重开、
真实软键盘避让和跳过不发请求；同样使用内存协议 fixture，结束后覆盖安装正常 APK。
它使用真实 JSONL adapter、AppController 和 WorkScreen，但协议对端与 Profile 存储均为内存 fixture，
不登录真实 SSH、不调用模型、不消耗云端额度。测试包会替换模拟器 APK；结束后必须安装正常发布包，
保留既有 App 数据，不把测试包交付给用户。功能分支推送不触发发布；main 推送自动触发两端出包。
Flutter 3.44 的 Android Release 构建须保留 `--pub`，以按 Release 模式重新生成原生插件注册表，
剔除仅测试使用的 `integration_test`；直接沿用 Debug 注册表并使用 `--no-pub` 会编译失败。
已解析依赖仍由 Pub 的 up-to-date 检查复用，不清理缓存。
CI 的 `prepare-ci-pub.sh` 成功后恢复锁文件原内容和权限，但刷新时间戳，避免 checkout 时锁文件早于
`pubspec.yaml` 触发第二次无锁解析；失败恢复原时间戳。版本和包哈希仍由 `--enforce-lockfile` 校验。
Gitee 的 `run-gitee-release.sh` 默认只构建 Release APK，保留 analyze、全量 Flutter tests、验签和超时；
不再编未交付的 Debug APK。仅需要诊断双变体时设置 `CODEX_RELEASE_BUILD_MODE=all`；本机入口不变。
该优化不会消除首次 Release 的依赖下载/Gradle 冷启动成本，不能把旧日志整段 Debug 耗时当作确定节省量。
设备测试入口同样保留默认 Pub 步骤，以在 Release 后重新生成含测试插件的 Debug 注册表。

普通 Agent 模式的真实 Codex 工具路由回归使用已安装二进制，不下载/升级、不读取真实认证：

```bash
CODEX_USER_INPUT_TEST_BIN=/absolute/path/to/codex node scripts/test-codex-user-input.cjs
```

脚本以临时 HOME 和本地 Responses 服务测试开关关闭、新建开启和恢复开启，并对比开发提示的显示/关闭。设备测试先使用
同一命令追加 `--serve`，读取输出端口，执行 `adb -s emulator-5554 reverse tcp:<port> tcp:<port>`，再运行
`./scripts/flutter-tool.sh --no-version-check test integration_test/codex_default_question_test.dart --dart-define=CODEX_QUESTION_WS_PORT=<port> -d emulator-5554`。
必须设置正确的 `ANDROID_HOME` / `ANDROID_SDK_ROOT` 和共享 `GRADLE_USER_HOME`；结束后终止本轮 fixture、
移除本轮 adb reverse 并覆盖安装正常 Release 包。fixture 最长运行 15 分钟，仅绑定 loopback。

子 Agent 专项使用 `test/agent/sub_agent_protocol_lifecycle_test.dart`、
`test/agent/sub_agent_live_replay_test.dart`、`test/ui/sub_agent_workflow_test.dart`，以及控制器的导航/恢复测试。
设备入口为 `integration_test/sub_agent_workflow_test.dart`，复用生产 JSONL adapter/controller，协议对端是
受控模拟数据；完成后仍须覆盖安装正常 Release。已捕获的真实协作事件使用归一化 ID 的 fixture 回放，
不含 API 地址或凭据。

子 Agent 详情现在只读：设备测试验证底部无输入/停止/模型/审批入口、名称和身份图标、父向消息仅作记录，
以及子历史排除父回合、返回重进和多层导航。子页使用 `thread/read` + 有界分页，不能用直接恢复子线程替代读取。

跨端主会话占用回归使用 `test/ui/thread_ownership_workflow_test.dart` 及
`integration_test/thread_ownership_workflow_test.dart`。覆盖手机与 VS Code/另一手机使用的同一原生 writer
冲突协议、只读读取、历史失败仍锁定、重试解锁和草稿恢复。设备对端为受控 JSONL，不消耗模型额度；
真正的 writer 互斥通过两个独立 Codex app-server 共享临时 HOME 验证，不能用普通 active 状态伪造占用。
默认回归不得为了释放占用终止用户的 app-server、调用 interrupt 或清理会话文件；产品中的“强制接管”是
单独的破坏性用户操作，仅允许在二次确认后按当前 SSH 用户匹配 Codex app-server，且必须验证脚本完成标记，
不能声称只终止某一个线程。返回列表不保证立即释放 writer。

只有用户授权真实 API 消耗后才运行：

```bash
CODEX_SUBAGENT_TEST_BIN=/absolute/path/to/codex \
CODEX_SUBAGENT_CONFIG_DIR=/path/to/existing/codex-home \
node scripts/test-codex-subagents-live.cjs --live
```

追加 `--interrupt` 验证子任务停止与继续、父任务独立性，以及测试 app-server 重启后的历史恢复。
追加 `--history` 只创建一个带上下文的子任务，在四分钟上限内验证重启前后只读历史；同样需要真实 API 授权。
已有脱敏样本足以回归解析时应优先回放 `subagent_child_history_live.json`，避免重复消耗模型额度。
脚本使用独立私有目录、低思考强度和短任务，最长 8 分钟，不修改原用户配置，不读取或操作用户现有会话。
只复制 Provider 配置和认证到临时目录，禁止把 URL/Key 加进命令参数或测试 APK。测试结束销毁临时目录，
只在 `.workflow-cache/subagent-live-*.json` 留存脱敏的测试事件与可用 token 统计；该统计不等于账单金额。

模型 API 传输配置的离线对照（已安装 Codex `0.154.0`，不调用真实模型）：

```bash
CODEX_PROVIDER_TRANSPORT_TEST_BIN=/absolute/path/to/codex \
node scripts/test-codex-provider-transport.cjs
```

脚本隔离 HOME/认证，验证内置 Provider、旧 feature 开关、被拒绝的内置 Provider 覆盖和自定义 Provider
的 HTTP-only 路径。真实接口探测不能只看 HTTP 200 或 WebSocket 握手，必须确认完整响应；失败重试
会消耗模型额度，优先使用本地 fixture。已知诊断与未解决的服务端边界见 `PROVIDER_TRANSPORT_VALIDATION.md`。

## 6. SSH 测试主机

历史恢复专项：`test/app/resumed_timeline_reconciliation_test.dart`、
`test/app/older_timeline_merge_test.dart` 和 `test/app/resume_lifecycle_test.dart` 覆盖有界页重叠、
回退、重复分页顺序、自动补读一页、失败重试及快速重进的迟到结果；
`integration_test/history_reopen_workflow_test.dart` 使用生产 JSONL adapter/controller/WorkScreen
与受控分页对端验证旧回答不会被最新提问覆盖，不调用真实模型或操作用户会话。
终端专项 `integration_test/terminal_selection_test.dart` 使用受控 PTY、真实 Android 软键盘和剪贴板，
验证长按、跨行手柄拖动、显式复制及取消后继续输入；与历史专项可通过
`integration_test/terminal_and_history_test.dart` 一次设备构建执行。测试结束须覆盖安装正常 Release，
不能将测试包交付为正式安装包。

缓存专项：`test/persistence/thread_snapshot_store_test.dart` 验证压缩加密、限额、损坏及删除竞态；
`test/app/resume_lifecycle_test.dart` 验证快速重进、磁盘预览与网络响应竞争、只读及连接失效。
`integration_test/thread_snapshot_store_test.dart` 在 Android 使用真实安全存储插件和缓存目录，
以 140 条合成历史做跨实例读写；结束仅删除该测试作用域，再按发布流程覆盖安装正常 APK。
原生 Codex 无模型消耗回归可运行
`CODEX_CACHED_RESUME_TEST_BIN=/absolute/path/to/codex node scripts/test-codex-cached-resume.cjs`，
它用临时 HOME 验证 `excludeTurns` 响应大小和另一 app-server 的 writer 冲突，不读取真实认证。

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
`agent.apk` 兼容别名），然后用独立的 Node HTTP(S) 下载器直接连接（不经过环境代理）校验内网地址：

```text
内网：http://192.168.8.107/codex.apk
外网：http://frp.asdb.top:18080/codex.apk
```

内网地址返回的 SHA-256 必须与 Release APK 相同。外网地址是同一份本机文件的 FRP 映射，仍须随发布报告
提供，但按当前约束不作为本地出包门禁，默认不发起外网下载；报告应明确外网未回验。需要单独检查外网时，
显式设置 `CODEX_LOCAL_VERIFY_URLS`（或兼容的 `CODEX_LOCAL_VERIFY_URL`）覆盖默认地址列表。

若显式启用外网回验，下载器先完整下载，默认 30 秒超时；仅临时网络错误或连接中断才改用最多 4 个并行
Range 分段。
分段探测及每段必须返回准确的 `206`、范围、总大小和一致的强 ETag（若服务端提供）；最终拼接后仍核对
整包大小、SHA-256、包名、版本和稳定证书。错误哈希、错误范围、鉴权失败或不支持 Range 会直接失败。
Range 阶段默认共用 300 秒总时限，每段最多重试一次；不会按每段重置总时限。超时配置
`CODEX_LOCAL_VERIFY_TIMEOUT` / `CODEX_LOCAL_RANGE_TIMEOUT` 的单位是秒，单项上限 900；
`CODEX_LOCAL_RANGE_FALLBACK=0` 可关闭分段恢复。下载器输出模式及实际耗时，失败不留下未校验的输出文件。
下载失败后的重试使用 `publish --reuse`，保留已验证 APK 和失败计时，不重新编译。下载器本地 HTTP
fixture 随 `scripts/test-workflow.sh` 检查中断、超时、坏段、错误响应和取消，不依赖外网。

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
| 首页推广入口 | 紧凑框显示 ai2api.vip 并由系统浏览器打开；窄屏或大字体改为图标，Agent 标题完整；版本长短、检查中和有更新状态切换不改变按钮位置，无溢出 |
| 更新弹窗手动下载 | 弹窗打开、下载中和下载失败时均可由“手动下载”直接用系统浏览器打开当前版本 APK；不创建或取消应用内下载，浏览器失败可重试；窄屏和大字体无溢出 |
| 新建/编辑/删除 Profile | 默认用户 `root`；校验地址/端口；删除只删本地配置 |
| 密码/私钥连接 | 指纹首次确认；变化时显示旧/新指纹；取消保留旧值；确认替换后重连；失败不影响其他服务器 |
| 多服务器 | A、B 可同时保持独立连接，切换不串状态 |
| 会话打开 | 列表刷新期间可打开已显示的会话；重复点击去重，快速切换只显示最后目标，旧列表加载不解锁正在恢复的输入框；首屏只取最近完整回合，旧历史游标可连续下拉 |
| 会话缓存 | 快速重进共享在途恢复；同代有效订阅以小型 metadata 请求校验 writer 后使用内存历史；冷启动压缩加密预览保持输入锁定；过期、损坏、断线、占用、Provider/身份变化和子会话不能误用授权 |
| 连接遮罩 | 连接/指纹阶段半透明阻塞；连接弹窗只有圆环和下方“取消连接”按钮，无服务器名或状态文字；取消可退出，完成后直接进入占位会话页 |
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
6. 代码修改必须创建中文 Git 提交，并在提交成功后立即分别执行当前分支到 Gitee `origin` 和 GitHub
   `github` 的推送；两个远端均成功才算完成，只有用户明确要求暂缓时才不推送。

用户新增或变更长期注意事项时，必须同步写入 `docs/ARCHITECTURE.md` 的产品约束和本文对应流程，
避免只留在聊天记录中。
