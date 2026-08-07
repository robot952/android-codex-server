# Agent Flutter 应用

这是 Codex Remote 的 Flutter Android 客户端，应用名为 `Agent`，包名为
`top.asdb.agent`。旧 Kotlin/Compose 工程仍保留在仓库的 `app/` 目录，作为行为基线；当前
Flutter 入口是 `lib/main.dart`。

## 开发入口

在仓库根目录执行统一流程：

```bash
./scripts/dev-workflow.sh quick
./scripts/dev-workflow.sh check
./scripts/dev-workflow.sh full
```

本地依赖优先复用仓库同级的 `../.pub-cache` 和 `../.gradle-cache`，下载缺失依赖时使用
`127.0.0.1:7890` 代理。不要执行 `flutter clean` 或删除这些缓存。

架构、状态流转、测试地图和当前验收缺口以
[`docs/ARCHITECTURE.md`](../docs/ARCHITECTURE.md) 为准。
