# Gitee Go Flutter Android 自动发布

推送 `flutter-refactor` 分支会触发 `.workflow/流水线-flutter-refactor-编译.yml`。
流水线使用 Flutter `3.44.8` 构建并验证稳定签名 APK，随后自动创建与
`versionName` 对应的不可移动 `v<versionName>` Git 标签、Gitee Release 和
`Agent-<version>.apk` 附件。流水线页面同时保留 `dist/` 构件。

历史 `release` 分支仍可触发 `.workflow/流水线-202608021802.yml`，两条流水线共用
`scripts/publish-gitee-release.sh`。日常 Flutter 重构发布只使用 `flutter-refactor` 流水线，
不要在同一版本再推送 `release` 分支。Tag 推送本身不触发 Android 构建，避免发布
脚本创建标签后重复跑流水线。

## One-Time Variable Setup

Create a Gitee personal access token with repository project access. Create the following masked
common variable in Gitee Go, then reference it from the pipeline's **Variable Settings**:

```text
CODEX_RELEASE_TOKEN
```

Put only the token value in this variable. Never add it to the workflow YAML, source code, logs,
or Git commits.

The workflow records that reference under `variables.global`; Gitee Go then exposes it to the
release script as an environment variable. Do not interpolate the token in `commands`, because
Gitee Go prints the resolved command in the build log.

The defaults publish to `YanGanYuan/android-codex-server`. A fork can override the target with
optional protected variables `CODEX_RELEASE_OWNER` and `CODEX_RELEASE_REPOSITORY`.

## Trigger Rule

Flutter 流水线的代码源自动触发器使用 **Push** 和精确分支 `flutter-refactor`：

```yaml
branches:
  precise:
    - flutter-refactor
```

流水线显式设置 `CODEX_RELEASE_BRANCH=flutter-refactor`。脚本会验证当前检出提交就是
远端 `flutter-refactor` 分支头。只有构建和稳定签名验证通过后才创建
`v<versionName>`；已存在标签只能在指向同一提交时复用，脚本永不移动标签。

## Release Sequence

1. Increase `versionCode` and `versionName`, then commit the source changes on `flutter-refactor`.
2. Push `flutter-refactor` to Gitee `origin`; separately push the same commit to GitHub `github`.
3. Gitee Go builds the Flutter Release APK, verifies its stable certificate, creates
   `v<versionName>`, and attaches `Agent-<version>.apk` to the Gitee Release page.

The `flutter-refactor` push is the only Gitee publishing action. Re-running the same pipeline is
safe: it reuses the matching tag and Release, and only uploads the APK when the attachment is
missing. The tracked workflow must bind the masked `CODEX_RELEASE_TOKEN` common variable; a
missing variable intentionally fails before building or publishing.

The release body contains up to the latest 12 Git commit subjects and the APK SHA-256 checksum.
The Android client checks the public Gitee Release list on startup, verifies that the expected APK
attachment exists, and displays these Git subjects as its update log. A retry reuses the existing
Release and only uploads the APK when that attachment is absent.
