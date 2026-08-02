# Gitee Go Automatic Releases

Pushing a release tag triggers Gitee Go. The pipeline builds and signs the APK, creates the
corresponding Gitee Release, and uploads `CodexRemote-<version>.apk` as its attachment.

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

In the code source's automatic trigger settings, choose **Tag Push** and **Prefix Match**. The
prefix input must be `v`, without an asterisk. This produces the workflow configuration below:

```yaml
tags:
  prefix:
    - v
```

The release script only accepts a tag exactly matching the Android `versionName`, such as
`v1.7.55` for `versionName = "1.7.55"`. Test tags and tags pointing to another commit cannot
publish a Release.

## Release Sequence

1. Increase `versionCode` and `versionName`, then commit and push the source changes.
2. Create and push the matching annotated tag, for example `v1.7.55`.
3. Gitee Go builds the Release APK and attaches it to the Gitee Release page.

The release body contains up to the latest 12 Git commit subjects and the APK SHA-256 checksum.
The Android client checks the public Gitee Release list on startup, verifies that the expected APK
attachment exists, and displays these Git subjects as its update log. A retry reuses the existing
Release and only uploads the APK when that attachment is absent.
