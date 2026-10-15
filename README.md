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

## 小型构建组件（2026-10-15）

依赖归档总量为 **344,937,827 字节（344.94 MB）**，每个文件最多 **40,000,000 字节**。
用户要求依赖总容量不超过 400 MB，并为免费仓库 500 MB 总上限、50 MB 单文件上限预留空间。
不额外提交分片合并后的整包，也不把 SDK、Gradle 缓存和构建输出加入本分支。

| 组件 | 原始压缩包大小 | 路径 |
| --- | ---: | --- |
| CMake 3.22.1 / Ninja | 22.31 MB | `cmake/cmake-3.22.1-linux.zip` |
| AndroidX 测试依赖及传递依赖 | 1.58 MB | `maven/android-test-maven-v1.zip` |
| Node 22.17.0 Linux x64 | 54.93 MB | `packages/node-22.17.0-linux-x64/` |
| Android Platform 34 | 63.18 MB | `packages/android-platform-34/` |
| Android Platform 35 | 64.27 MB | `packages/android-platform-35/` |
| Android Platform 36 | 65.88 MB | `packages/android-platform-36/` |
| Android Build Tools 36.0.0 | 63.74 MB | `packages/android-build-tools-36/` |
| Android Platform Tools 37.0.1 | 9.05 MB | `packages/android-platform-tools/` |

`PROVENANCE.json` 记录原始 URL、官方摘要、完整包 SHA-256/大小、分片 SHA-256/大小，以及每个组件的
不可变标签和完整提交 ID。Android ZIP 的 SHA-1 来自 Google `repository2-1.xml`；Node SHA-256
来自官方 `SHASUMS256.txt`。所有上游归档保持原样，包括原包内版权、NOTICE 和许可证。
AndroidX ZIP 保留原样 POM/AAR/JAR、Apache-2.0 许可证、逐文件 SHA256SUMS 和上游来源清单；
仅三个动态模块的 Maven 版本列表由本项目生成，限制为包内已验证的版本。

每个组件的标签是只包含该组件文件的独立快照，与分支复用相同 Git blob，不重复存储归档。
构建浅取对应标签一次，读取原包或按 `part-000`、`part-001` 顺序合并，再校验完整原包的大小和 SHA-256。
不要浅取整个 `ci-deps` 分支下载单一组件，不要移动已有标签。下载与安装保留超时和失败退出。
Gitee 预装组件及有效缓存优先，仅缺包时下载。自定义 SDK 源继续由调用者控制。

手动合并示例：

```bash
cat packages/node-22.17.0-linux-x64/part-* > /tmp/node-v22.17.0-linux-x64.tar.gz
sha256sum /tmp/node-v22.17.0-linux-x64.tar.gz
```

二次压缩不能保证节省容量，预算按实际原包及所有保留版本计算。新增版本前必须检查历史 Git 对象的
存储增长；删除分支中的旧文件不会自动回收 Git 历史。超过预算时停止新增，不绕过文件上限或擅自改写历史。
