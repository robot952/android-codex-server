# 自建 Runner 的 Tag 发布（可选）

当前标准发布流程是 Gitee Go 的 `release` 分支自动发布，见
[GITEE_GO_RELEASE.md](GITEE_GO_RELEASE.md)。本文件仅保留给已部署自建 Runner、且需要同时把 APK
发布到内网 HTTP 地址的旧流程。两套流程不要在同一个版本上同时启用，以免重复创建 Release。

在这套可选方案中，日常开发仍在本机执行 `./scripts/build-android.sh debug`；只有受保护的
`v<versionName>` 标签才会在自建 Runner 上构建、验签和部署。APK 不提交进 Git 历史。

自建 Runner 优先于云端 Runner，原因是 Android SDK 和 Gradle 缓存都留在本机，构建快且发布目录可由
Runner 最小权限写入。当前测试签名 keystore 已按本项目约定版本化；不要将其复用于生产应用。

## 1. 一次性准备 Runner 主机

以下以独立 Linux 用户 `codexci` 为例。不要使用 root 运行来自 Git 仓库的 CI 任务。

~~~bash
sudo useradd --create-home --shell /bin/bash codexci
sudo install -d -o codexci -g codexci -m 700 /opt/codex-remote-ci
sudo install -d -o codexci -g codexci -m 700 /opt/codex-remote-ci/gradle
sudo install -o codexci -g codexci -m 600 \
  /home/yan/ygy/codex-remote-android/keystore/codex-remote-stable.keystore \
  /opt/codex-remote-ci/codex-remote-stable.keystore
~~~

Runner 还必须能读取 Android SDK。构建脚本会优先识别仓库同级的 `../android-sdk`；当前机器使用
`/home/ygy/android-sdk`。如果新机器不同，安装 SDK 34、build-tools 34.0.0 和 JDK 17，并通过
`ANDROID_HOME` 或 `ANDROID_SDK_ROOT` 指向实际路径。

为让 Runner 只拥有 APK 发布权限，而不是整个 Web 根目录的写权限，创建一个专用目录并把既有下载文件改为
软链接：

~~~bash
sudo groupadd --force codexci
sudo usermod -aG codexci codexci
sudo install -d -o root -g codexci -m 2775 /var/www/html/codex-releases
sudo mv /var/www/html/codex.apk /var/www/html/codex-releases/codex.apk
sudo ln -s codex-releases/codex.apk /var/www/html/codex.apk
~~~

`codexci` 重新登录后才会获得新组。Nginx 保持原有 `/codex.apk` URL；发布脚本只会原子替换
`/var/www/html/codex-releases/codex.apk`。

## 2. 在 Gitee 注册自建 Runner

在仓库页面打开 **DevOps -> Gitee Go -> Runner**，新建 Linux x86_64 自建 Runner，标签建议为
`codex-android-release`。Gitee 页面会生成一次性注册命令；使用 `codexci` 用户在这台构建机执行该命令并按
页面提示将 Runner 注册为服务。

Runner 只应允许受保护分支和受保护标签使用。不要把注册 token 或 SSH 私钥提交进仓库或粘贴到 Issue。

## 3. 创建 Gitee Go 流水线

在 Gitee Go 新建流水线，选择刚注册的 `codex-android-release` Runner。不同 Gitee Go 套餐的 YAML/可视化
编辑器字段略有差异，使用可视化编辑器配置下列等价步骤最稳定：

1. 触发器：**推送标签**，规则 `v*`。
2. 检出：检出触发标签的提交，不要检出浮动的 `main`。
3. Shell 步骤：执行下列命令。
4. 构件归档：归档 `dist/**`，这样 Gitee 的流水线页面可下载对应版本 APK 和元数据。

~~~bash
export GRADLE_USER_HOME=/opt/codex-remote-ci/gradle
export CODEX_SIGNING_KEYSTORE=/opt/codex-remote-ci/codex-remote-stable.keystore
export CODEX_RELEASE_PUBLISH_DIR=/var/www/html/codex-releases
export CODEX_RELEASE_VERIFY_URLS=http://210.16.163.118:18080/codex.apk
./scripts/publish-tag-release.sh
~~~

若 Runner 主机上首次下载 Gradle/SDK 依赖，可额外设置 `CODEX_BUILD_ONLINE=1`；脚本会在本机可用时使用
`127.0.0.1:7890` 代理。缓存就绪后删掉该变量，继续离线增量构建。

`CODEX_SIGNING_KEYSTORE` 也可在 Gitee Go 的受保护变量中定义，但值应是 Runner 本机的绝对路径。当前 keystore
密码、alias 和 key password 可以继续用本地默认值；若将来替换为不同凭据，只能通过以下受保护变量提供，不能
写回 Git：

~~~text
CODEX_SIGNING_STORE_PASSWORD
CODEX_SIGNING_KEY_ALIAS
CODEX_SIGNING_KEY_PASSWORD
~~~

## 4. 日常发布步骤

先在本地完成版本调整和调试验证，再提交源码。`versionCode` 必须比上一个发布版本大，`versionName` 与 tag
必须严格对应。

~~~bash
./scripts/build-android.sh debug
git add app/build.gradle.kts <本次源码和文档>
git commit -m "发布 1.7.19"
git push origin main
git tag -a v1.7.19 -m "发布 v1.7.19"
git push origin v1.7.19
~~~

最后一条命令触发流水线。`scripts/publish-tag-release.sh` 会依次：

1. 确认 `v1.7.19` 正好指向当前检出提交，且没有未提交的已跟踪文件。
2. 执行 `all` 门禁：debug/release 单测、Lint、debug/release APK 和 R8。
3. 验证 release APK 证书 SHA-256 必须为
   `72722218709a6d7fd0e80b944903ae2961b4cfa8abe03586f602acdc1ea0f52a`。
4. 生成 `dist/CodexRemote-1.7.19.apk` 和 `dist/release-metadata.txt`。
5. 原子替换下载文件，并检查 `http://210.16.163.118:18080/codex.apk` 返回成功。

失败时不要移动或复用标签，也不要重复发布同一 `versionCode`。修复后增加版本号，重新提交并创建新标签，例如
`v1.7.20`。Gitee 流水线重跑只适用于同一提交的构建环境故障，不应用于内容变更。

## 5. 本地模拟 CI

正式打 tag 前可在本机验证同一入口。必须先创建与 `versionName` 匹配、且指向当前提交的本地标签；该命令会生成
`dist/`，但未设置发布目录时不会修改下载站。

~~~bash
git tag -a v1.7.19 -m "本地发布验证"
./scripts/publish-tag-release.sh
git tag -d v1.7.19
~~~

已推送的正式标签不能用上面的删除步骤。首次启用流水线时，应先在一个尚未发布的新版本完成完整流程。
