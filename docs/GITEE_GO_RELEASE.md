# Gitee Go Flutter Android 标签构建

当前只保留 `.workflow/流水线-flutter-refactor-编译.yml`，响应 **`v` 前缀的 Git 标签推送**；
旧 `.workflow/流水线-202608021802.yml` 已从当前分支移除。普通分支提交不会触发这条发布流水线。
唯一入口只调用
`bash scripts/run-gitee-release.sh`，在同一个严格 Shell 中通过 `scripts/run-ci-stage.sh` 限时执行回归
与 `bash scripts/publish-tag-release.sh`。任一阶段失败或超时就退出，不依赖平台多条命令的失败处理。
发布先核对 `v<versionName>` 指向当前 HEAD，
再构建、验证稳定签名并将 `Agent-<version>.apk` 和 `release-metadata.txt` 归档到 `dist/`。

该入口不创建或移动标签，也不自动创建 Gitee Release 或上传 Release 附件。构建成功后，
APK 可从 Gitee Go 对应运行记录的 `dist/` 构件获取；不能把构件归档等同于应用内更新发布。
平台只检出提交、没有取回标签时，入口限时 60 秒从 origin 获取精确的 `refs/tags/v<versionName>`，
再解析其提交与 HEAD 比较；已有错误标签不会被覆盖，缺失远端标签、网络失败或提交不匹配均停止。
Gitee Go 的删除入口提示按对应分支删除 YAML；迁移时还要核对 `release` 等历史分支，
从对应分支移除旧“构建”配置。删除后刷新流水线列表，确认只保留“Flutter Refactor 发布”自动入口，
再推送新版本标签；没有确认前不要用新标签试触发，也不要同时点击手动重跑。
`test-gitee-pipeline.sh` 在云端检查 `.workflow/` 只有一个配置，防止重新引入重复入口。

当前标签入口与旧 `scripts/build-gitee-release.sh` 共用
`scripts/prepare-ci-environment.sh` 准备 Flutter、Android SDK 和 Gradle，统一传递在线依赖、
Pub 镜像和工具缓存环境。平台导出的
`ANDROID_HOME`/`ANDROID_SDK_ROOT` 可能指向只读工具挂载；脚本先验证可写性，不能写入时
改用 `~/.cache/codex/android-sdk`，并将最终路径传给 Flutter/Gradle。无需修改系统挂载权限。
缓存目录也必须可写；若缓存同样只读，脚本会明确指出缓存路径并停止。

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
`test-gitee-pipeline.sh` 覆盖阶段顺序、非零退出码透传及失败后不再运行发布，由环境回归一并执行。

## 超时与重试上限

`scripts/run-ci-stage.sh <阶段名称> <秒数> <命令及参数...>` 使用 GNU
`timeout --kill-after=30s` 为整个命令进程组设置硬边界。到期先终止该阶段及其子进程，
30 秒内未退出则强制结束；输出明确的阶段名称和超时状态，并以 `124` 或 `137` 失败退出。
流水线不忽略超时失败，也不会无限重试。

唯一 Gitee 发布入口采用以下阶段上限：

| 阶段 | 上限 | 范围 |
| --- | --- | --- |
| `test-ci-environment.sh` | 300 秒（5 分钟） | 环境准备脚本回归 |
| `test-ci-gradle.sh` | 600 秒（10 分钟） | Gradle 缓存与下载脚本回归 |
| `publish-tag-release.sh` | 5400 秒（90 分钟） | 包含环境准备、Flutter 门禁、编译、验签与构件归档的整次发布 |

共享 `prepare_ci_environment` 另设 **3600 秒（60 分钟）的总准备预算**，
下列各阶段实际可用时间均取“本阶段上限”和“总准备预算剩余时间”的较小值：

| 工具准备阶段 | 单阶段上限 |
| --- | --- |
| Node | 900 秒（15 分钟） |
| Flutter SDK | 1200 秒（20 分钟） |
| Android SDK | 1800 秒（30 分钟） |
| Gradle | 2400 秒（40 分钟） |
| Flutter precache | 600 秒（10 分钟） |

这些时间不能相加理解为更长的准备窗口；阶段切换、镜像回退和重试都不重置总预算。
下载重试次数与超时均有界，超时后需依据日志修复或重新触发，不能在后台留下持续下载或编译的子进程。

Gitee Android 镜像可能没有 Node。`prepare-ci-node.sh` 复用已有 Node 18+，否则准备固定 22.17.0，
下载后先核对官方 SHA-256，再启用 `~/.cache/codex/node` 中的独立缓存，不修改系统工具。
共享环境入口导出 Node 的 bin 路径后才运行 Flutter 测试。缺依赖不能跳过 Claude 安装回归；
fixture 必须明确报告 Node 缺失，而不是创建目标为空的符号链接。

## 触发规则

流水线使用 **Push → Tags → Prefix `v`**：

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

重试同一个提交时可在 Gitee Go 的运行记录中重新执行同一个标签。代码已经修复时，不应重跑
仍指向旧提交的标签，也不能强制移动旧标签；为修复提交创建与 Pubspec 一致的新版本标签。
GitHub 跨平台构建使用独立的 `flutter-refactor-v*` 标签，仅要求 Gitee 构建时不要同时推送该类标签。

## 修复后重新出包

1. 在 `flutter-refactor` 修改源码，将 Pubspec 的可见版本和 build number 一起递增。
2. 创建中文提交，分别推送当前分支到 Gitee `origin` 和 GitHub `github`。
3. 确认 Gitee Go 旧“构建”入口已移除、只保留唯一自动发布入口，再确认 `v<versionName>` 在本地与
   origin 均不存在，为修复提交创建新标签并只推送到 `origin`。
4. 在 Gitee Go 查看新标签对应的提交、运行记录和最终结论；不能仅凭 Git 推送成功报告出包成功。
5. 构建成功后下载 `dist/` 构件，核对 APK 版本、稳定证书和 `release-metadata.txt` 的 SHA-256。

用户明确要求推送并云端出包时，按 `AGENTS.md` 跳过本地单元测试、全量测试、analyze、
本地 APK 构建和模拟器门禁。流水线仍执行构建脚本回归和 Flutter analyze/test，不能为了出包
屏蔽失败的测试。常规修改的本地门禁仍以 `docs/LOCAL_WORKFLOW.md` 为准。

## 状态与凭据边界

运行入口是仓库的 **流水线 / Gitee Go** 页面。查询时匹配标签和 Git SHA，不把历史失败记录
当作当前提交的结果；日志至少应包含失败阶段、最后一次重试及最终退出状态。
SSH Git 凭据只证明可以推送标签，不能替代 Gitee Go 页面或 API 所需的登录与访问权限。

旧 `scripts/publish-gitee-release.sh` 是另一个分支发布入口，仍要求受保护的
`CODEX_RELEASE_TOKEN`，会验证远端分支头并调用 Gitee Release API。它不属于当前标签
流水线的默认路径，不能为了上传附件直接再次调用它而重复构建。需要恢复自动 Release 发布时，
应单独接入标签安全的上传步骤。Token 只放平台掩码变量，不得写入 YAML 命令、源码、日志或提交。
