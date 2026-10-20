# Gitee Go Flutter Android 发布

> 线上编译优化、问题修复和 v1.8.174 → v1.8.175 实测数据，见
> [GITEE_BUILD_OPTIMIZATION.md](GITEE_BUILD_OPTIMIZATION.md)。本文保留发布入口、超时、触发和
> 凭据边界；两份文档中的现行脚本行为以仓库工作流和脚本为准。

当前只保留 `.workflow/流水线-flutter-refactor-编译.yml`，响应 **`v<versionName>` 版本标签推送**；旧
`.workflow/流水线-202608021802.yml` 已从当前分支移除。main 与功能分支推送只同步代码，不自动出包。
唯一入口调用 `bash scripts/run-gitee-release.sh`，不传 `main`，在同一个严格 Shell 中通过
`scripts/run-ci-stage.sh` 限时执行回归与 `bash scripts/publish-tag-release.sh`。任一阶段失败或超时
就退出，不依赖平台多条命令的失败处理。发布先核对已有版本标签、当前提交和 Pubspec 版本，再构建、验证
稳定签名并将 APK、发布元数据和诊断摘要归档到 `dist/`。

2026-10-20 起停止 main 自动发布；只有用户明确要求云端出包时才创建并推送版本标签，或手动重跑该标签。
本地出包与发布仍可按交付要求单独执行。当前云端默认只构建 Release APK；如需诊断双变体，
显式设置 `CODEX_RELEASE_BUILD_MODE=all`。

`publish-tag-release.sh` 要求 Pubspec 对应的 `v<versionName>` 标签指向当前提交；标签不在本地时，
最多用 60 秒从 origin 读取精确标签。缺失或指向别处都拒绝，不创建或移动标签。上传前再次核对远端目标。
`run-gitee-release.sh` 拒绝旧 `main` 参数与 `CODEX_RELEASE_BRANCH`，防止旧平台注册项继续创建标签并重复出包。
构建后，脚本先将
APK、`release-metadata.txt` 和诊断摘要整理到 `dist/` 目录，再创建/校验正式 Gitee
Release、上传同一个 APK，并下载公开附件核对大小与 SHA-256；流水线结束后平台才将 `dist/` 归档为构件。构件与 Gitee Release 附件是两个
独立交付位置；应用内更新读取的是正式 Release。

Gitee Go 的删除入口提示按对应分支删除 YAML；迁移时还要核对 `release` 等历史分支，从对应分支
移除旧“构建”配置。删除后刷新流水线列表，确认只保留“Flutter Refactor 发布”自动入口；不要同时
点击手动重跑。`test-gitee-pipeline.sh` 在云端检查 `.workflow/` 只有一个配置，防止重新引入重复入口。

流水线显式设置 `caches: []`，关闭跨构建缓存下载/压缩/上传，只归档 `dist/` 中的 APK、发布元数据、
构建诊断和发布回验结果。
2026-10-15 的 1.8.165 构建已完成测试、编译及构件归档，但整套 Flutter/Android/Gradle/Node/Pub
缓存压缩耗时 287 秒后，上传被 HTTP 413 拒绝，阻断后续产出暂存。不能只把该错误隐藏或继续重试大包。
本次作业内的磁盘缓存、Debug/Release 复用及 Gitee 预装 SDK 复用保持不变，不删除本机缓存；
全新 runner 可能需要重新获取未预装依赖。恢复跨构建缓存前需另行验证体积受控的缓存策略与平台限制，
不能直接重新加入整个 SDK 或 Gradle 目录。云端回归同时检查空缓存配置与 `dist/` 构件配置，
原有构建、验签和超时规则保留，当前触发器仅监听版本标签。

当前标签入口与旧 `scripts/build-gitee-release.sh` 共用
`scripts/prepare-ci-environment.sh` 准备 Flutter、Android SDK 和 Gradle，统一传递在线依赖、
Pub 镜像和工具缓存环境。平台导出的
`ANDROID_HOME`/`ANDROID_SDK_ROOT` 可能指向只读工具挂载；脚本先验证可写性，不能写入时
改用 `~/.cache/codex/android-sdk`，并将最终路径传给 Flutter/Gradle。无需修改系统挂载权限。
缓存目录也必须可写；若缓存同样只读，脚本会明确指出缓存路径并停止。
不会因只读就重新下载整套 SDK：先保留已有有效缓存，再逐包核对预装 `source.properties` 和必要文件，
将兼容组件复制到可写缓存（支持 reflink），预装 sdkmanager 经限时检查后连工具目录一起复用。
许可证复制后可写，不把可安装目录软链接回平台只读挂载；后续缓存复用不依赖原挂载仍然存在。
日志分别列出“复用缓存”“复用预装组件”和“预装缺失或版本不匹配”，最后仅安装仍缺少的固定版本包。
完全匹配的预装 SDK 不需要下载；平台未提供的版本仍需联网补齐，不降级项目要求来迁就旧工具。
复制每个组件上限 300 秒，原 SDK 1800 秒和准备总预算继续生效。普通云端回归无需 mount 权限，
也覆盖完整/部分预装、版本不符、损坏缓存修复、许可证、下游路径及原 SDK 内容不变。

Pub 依赖优先使用 `pub.flutter-io.cn`。遇到 424/429/5xx 等临时网络错误时有限重试，
仍失败则回退官方 `pub.dev`；每次都通过 `--enforce-lockfile` 保留依赖版本和哈希。
镜像 URL 映射仅作用于本次获取依赖，原锁文件退出时恢复；不会执行依赖升级或从 GitHub 克隆。
如果显式配置自定义 `PUB_HOSTED_URL`，只重试该源，不自动将私有包请求转向公共源。

`scripts/prepare-ci-gradle.sh` 读取项目 Wrapper 的固定发行包，使用固定的官方 SHA-256
校验下载内容，并预热标准 `GRADLE_USER_HOME/wrapper/dists` 缓存。下载对镜像和官方源执行
有界重试及回退；只有完整校验成功的压缩包才可供 Wrapper 使用，不删除已有有效缓存。
Gitee 插件中的 `gradleVersion` 不能替代项目 Wrapper 所需的发行包。
缓存目录回归使用已提交的根 `gradle/wrapper/gradle-wrapper.jar` 独立核对 PathAssembler 结果；
不能引用 Flutter 准备后才生成、Git 忽略的 `flutter_app/android/gradle/wrapper/gradle-wrapper.jar`。
`prepare-ci-gradle-home.sh` 为本次运行建立独立 `GRADLE_USER_HOME`，只链接旧目录的
`caches`/`wrapper`，保留缓存挂载与原文件，不读取或继承用户级 init 脚本、`gradle.properties`。
隔离目录位于工作区 `.workflow-cache/gradle-user-homes/`，不会被流水线作为全局配置缓存。
这避免平台全局 init 向 Flutter included build 添加项目仓库，与其 `FAIL_ON_PROJECT_REPOS`
冲突；不能直接修改 Flutter SDK 或改为宽松策略掩盖问题。
发行包准备后先执行 `test-ci-gradle-repositories.sh`：真实离线 Gradle 负例确认合成 init 生效，
正例确认隔离后严格 included-build 插件能加载，且 Gradle 实际使用隔离目录。
CI 用 `CODEX_CI_MAVEN_MIRRORS=1` 在应用 Android 工程内启用阿里云 Maven 镜像优先、官方源兜底。
策略覆盖 settings 插件解析，以及 Flutter 插件子项目的 legacy buildscript classpath 和普通依赖，
不通过全局 init 注入 Flutter SDK included build。离线预检同时验证镜像顺序与严格仓库策略兼容。
预检还检查被复用发行版的 init 脚本；若发行版自身受污染则停止，不修改共享目录。
`test-gitee-pipeline.sh` 覆盖阶段顺序、非零退出码透传及失败后不再运行发布，由环境回归一并执行。

## 超时与重试上限

`scripts/run-ci-stage.sh <阶段名称> <秒数> <命令及参数...>` 使用 GNU
`timeout --kill-after=30s` 为整个命令进程组设置硬边界。到期先终止该阶段及其子进程，
30 秒内未退出则强制结束；输出明确的阶段名称和超时状态，并以 `124` 或 `137` 失败退出。
流水线不忽略超时失败，也不会无限重试。

唯一 Gitee 发布入口采用以下阶段上限：

| 阶段 | 上限 | 范围 |
| --- | --- | --- |
| `test-ci-environment.sh` | 300 秒（5 分钟） | Bootstrap 回归，含环境准备和发布策略 fixture |
| `test-ci-android.sh` | 300 秒（5 分钟） | SDK 缓存、缺失 CMake/Ninja、版本检查与环境传递回归 |
| `test-ci-gradle.sh` | 600 秒（10 分钟） | Gradle 缓存与下载脚本回归 |
| `gitee-release` | 5400 秒（90 分钟） | `publish-tag-release.sh` 整次发布：环境准备、测试、编译、验签、归档与 Gitee Release 发布 |
| Release APK 编译 | 1200 秒（20 分钟） | 默认发布模式；整次 Flutter 调用及内部 Gradle 重试，包含在发布总预算内 |
| Debug APK 编译 | 1200 秒（20 分钟） | 仅 `CODEX_RELEASE_BUILD_MODE=all` 诊断双变体时运行 |
| Release 发布 API | 900 秒（15 分钟） | Gitee Release 创建/上传及公开下载大小、SHA-256 回验 |

共享 `prepare_ci_environment` 另设 **3600 秒（60 分钟）的总准备预算**，
下列各阶段实际可用时间均取“本阶段上限”和“总准备预算剩余时间”的较小值：

| 工具准备阶段 | 单阶段上限 |
| --- | --- |
| Gradle 用户目录隔离 | 60 秒（1 分钟） |
| Node | 900 秒（15 分钟） |
| 托管 Maven 依赖 | 420 秒（7 分钟） |
| Flutter SDK | 1200 秒（20 分钟） |
| Android SDK | 1800 秒（30 分钟） |
| Gradle | 2400 秒（40 分钟） |
| Gradle 仓库预检 | 240 秒（4 分钟） |
| Flutter Android precache | 600 秒（10 分钟） |

Flutter SDK 和 Android SDK 在两个 lane 并行准备；Android 完成后同 lane 准备 Gradle。两者完成后
才运行 Gradle 仓库预检与 Flutter Android precache。准备阶段共享 Linux 单调时钟截止时间；任一 lane
失败都由最外层进程组监督器立即清理同组子进程。

这些时间不能相加理解为更长的准备窗口；阶段切换、镜像回退和重试都不重置总预算。
下载重试次数与超时均有界，超时后需依据日志修复或重新触发，不能在后台留下持续下载或编译的子进程。
Gradle 的 HTTP 连接与读取各限 30 秒；Flutter 内部重试不重置 APK 编译的 20 分钟预算。

Android SDK 准备明确包含 `platform-tools`、`platforms;android-36`、`build-tools;36.0.0`、
`ndk;28.2.13676358` 和 `cmake;3.22.1`。应用固定 CMake 3.22.1，准备阶段实际执行 CMake/Ninja
检查，将 SDK CMake 的 bin 目录加入 PATH；缺 Ninja 或 CMake 版本不匹配时补齐包后再次校验。
版本首行接受准确的 `3.22.1` 及官方 Android 构建后缀（如 `3.22.1-g37088a8`），
仍拒绝其他补丁版本、预发布后缀和工具运行失败，避免安装成功后因后缀误报不完整。
默认国内仓库可能有元数据但缺少对应压缩包；首次包安装失败后，余下尝试切换 Google 官方仓库，
总计最多三次，并保留 sdkmanager 校验。显式配置 `CODEX_ANDROID_REPOSITORY_URL` 不自动换源。
超时或取消立即停止，不进入重试，SDK 1800 秒总阶段和共享环境剩余预算保持不变。
SDK 回归的测试 ZIP 由构建已有的 JDK 17 生成，保留 sdkmanager 的 Unix 可执行权限；
文本断言使用基础 grep，不依赖容器预装 Python 或 ripgrep。入口缺依赖明确报错，
原有 SDK 回归项目与 300 秒超时均保留。
定向修复回归核对“确认许可证、安装单包”两次调用，完整缓存不调用 sdkmanager。
回归断言失败时输出脚本行号和隔离日志末尾（每份最多 60 行），保留原退出码及临时目录清理。

Gitee Android 镜像可能没有 Node。`prepare-ci-node.sh` 复用已有 Node 18+，否则准备固定 22.17.0，
下载后先核对官方 SHA-256，再启用 `~/.cache/codex/node` 中的独立缓存，不修改系统工具。
共享环境入口导出 Node 的 bin 路径后才运行 Flutter 测试。缺依赖不能跳过 Claude 安装回归；
fixture 必须明确报告 Node 缺失，而不是创建目标为空的符号链接。

## 触发规则

当前唯一 Gitee Go 流水线使用 **Push → Tags → 前缀 `v`**：

```yaml
triggers:
  trigger: auto
  push:
    tags:
      prefix:
      - v
      precise: []
      include: []
```

main 推送不自动创建标签或构建。需要云端发布时先递增 `versionName` 与 build number，提交并同步两端 main，
再显式创建对应 `v<versionName>` 标签并推送到两端；同一版本不要同时手动运行。
相同提交重试可在 Gitee Go 运行记录重跑。手动启动也须检出已有匹配标签的提交，不能移动已有标签或用旧版本重发。
若 Release 创建/上传结果不确定，应查看该次 Gitee
Release 与公开附件状态后再决定是否只读重跑，不能盲目重复构建/上传。

## 修复后重新出包

1. 修改源码，将 Pubspec 的可见版本和 build number 一起递增。
2. 创建中文提交，按仓库协作约定将当前分支推送到 Gitee `origin` 和 GitHub `github`。
3. 确认两端 `main` 已更新到本次提交；只有用户要求云端出包时，才创建并推送匹配的版本标签到两端。
4. 在 Gitee Go 检查版本标签对应提交、回归、analyze/test、Release 构建、稳定签名与发布回验结论；
   不能仅凭 Git 推送成功报告出包成功。
5. 构建成功后从 `dist/` 构件下载归档，核对 APK 版本、稳定证书和 `release-metadata.txt` 的 SHA-256；
   另外确认正式 Gitee Release 的公开 APK 大小和 SHA-256 回验成功。

用户明确要求推送并云端出包时，按 `AGENTS.md` 跳过本地单元测试、全量测试、analyze、
本地 APK 构建和模拟器门禁。流水线仍执行构建脚本回归和 Flutter analyze/test，不能为了出包
屏蔽失败的测试。常规修改的本地门禁仍以 `docs/LOCAL_WORKFLOW.md` 为准。

## 状态与凭据边界

运行入口是仓库的 **流水线 / Gitee Go** 页面。查询时匹配版本标签和 Git SHA，不把历史失败记录
当作当前提交的结果；日志至少应包含失败阶段、最后一次重试及最终退出状态。
Gitee Go 还必须在版本标签构建环境中配置受保护的 `CODEX_RELEASE_TOKEN`，并具备仓库写权限；缺失时
会在 SDK/依赖准备前失败。Git 推送凭据不能替代 Release API 权限。

旧自建 Runner 的入口与当前云端标签入口不能在同一版本重复启用。Token 只放平台掩码
变量，不得写入 YAML 命令、源码、日志或提交；发布脚本不会将令牌传给公开 APK 下载请求。
