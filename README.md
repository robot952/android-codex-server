# CI 依赖归档

此独立 `ci-deps` 分支只保存经过校验的构建依赖，不包含应用源码或流水线配置，不合并到 `main`。
构建通过固定标签和完整提交 ID 读取文件，再验证 SHA-256；不要移动已发布标签或覆盖已有归档。

## Android CMake 3.22.1 · Linux x86_64

- 文件：`cmake/cmake-3.22.1-linux.zip`
- 来源：`https://dl.google.com/android/repository/cmake-3.22.1-linux.zip`
- 官方元数据：`https://dl.google.com/android/repository/repository2-1.xml` 的 `cmake;3.22.1` Linux 归档。
- 大小：22,308,647 字节。
- 官方元数据 SHA-1：`fd0a48b4a758310df8c7aa51f59840ed48fe7ed8`。
- SHA-256：`9196644852a978012caf7a4067ba1898debf6cc204c3341562771e31080d6869`。
- 标签：`ci-deps-cmake-3.22.1-linux-x86_64`。
- 包内版本：CMake `3.22.1-g37088a8`，Ninja `1.10.2`。
- 归档原样保留，未重压缩、修改或移除文件；不包含完整 Android SDK、NDK 或 Flutter。

## 版权和许可证

本仓库不改变归档内组件的版权或许可证。CMake 的版权及再分发条款位于
`doc/cmake-3.22/Copyright.txt`，Ninja 的许可证位于 `doc/ninja/LICENSE`。
其他随包组件的版权与许可证保留在 `doc/cmake-3.22/` 对应子目录及
`doc/openssl-1.1.1l/LICENSE`，以归档原文为准。请随原包保留全部声明。

本归档仅供本项目 CI 获取同一份上游依赖；不代表上游对本项目的认可。

## 校验与更新

在本分支根目录执行 `sha256sum -c SHA256SUMS`。
升级时新增版本文件、校验信息和新标签，由 `main` 的独立提交更新固定提交 ID 与哈希。
不要使用浮动分支头作为构建信任依据，不使用 Git LFS，避免构建需要额外下载服务。
