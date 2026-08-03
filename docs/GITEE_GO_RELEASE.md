# Gitee Go Release 分支自动发布

推送 `release` 分支会触发 Gitee Go。流水线构建并验签 APK，随后自动创建与
`versionName` 对应的不可移动 Git 标签、Gitee Release 和
`CodexRemote-<version>.apk` 附件。Tag 推送不会触发 Android 构建，因此不同版本的
发布不会因 Tag 触发而重新建立一套 Gradle 缓存。

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

In the code source's automatic trigger settings, choose **Push** and an exact branch match for
`release`. This is the workflow configuration tracked in the repository:

```yaml
branches:
  precise:
    - release
```

The script verifies that the checked-out commit is the current remote `release` head. Once its
build and signature verification pass, it creates `v<versionName>`. An existing tag is reused
only when it already points to the same commit; the script never moves a tag. A failed build
therefore cannot create a release tag.

## Release Sequence

1. Increase `versionCode` and `versionName`, then commit and push the source changes to `main`.
2. When the commit is ready to publish, run `git push origin main:release`.
3. Gitee Go builds the Release APK, creates `v<versionName>`, and attaches it to the Gitee
   Release page.

The single `main:release` push is the only manual publishing action. Re-running the same
pipeline is safe: it reuses the matching tag and Release, and only uploads the APK when the
attachment is missing.

The release body contains up to the latest 12 Git commit subjects and the APK SHA-256 checksum.
The Android client checks the public Gitee Release list on startup, verifies that the expected APK
attachment exists, and displays these Git subjects as its update log. A retry reuses the existing
Release and only uploads the APK when that attachment is absent.
