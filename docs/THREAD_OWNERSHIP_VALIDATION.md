# 跨端对话占用只读

## 行为

版本 `1.8.117+248`。同一个 Codex HOME 内的同一线程已由另一 app-server 持有 writer 时，
第二个客户端通过原生冲突错误进入只读，不抢占。适用于两台手机 App，以及手机 App 与 VS Code；
不同服务器/Unix 用户/Codex HOME 的独立会话不合并。

- 主会话保留标题、历史、分页、复制、图片、差异和子 Agent 浏览，底部为锁定提示及重试。
- 隐藏输入、停止、审批、模型、权限与线程修改；控制器同步拦截写操作。
- 草稿保留；重试期间继续只读，恢复成功后解除，仍占用则重新读取历史。
- 主 Codex 会话额外提供二次确认后的“强制接管”：只匹配当前 SSH 用户的 Codex app-server，可能中断该用户
  的其他 Codex 回合；不会终止 OpenCode、SSH 或其他 Unix 用户进程。没有匹配进程或脚本标记不完整时仍保持只读。
- 读取失败仍保持只读和已有缓存；离开页面、切换线程的迟到回复不能污染新页面。
- 子 Agent 页面原有只读和空底部语义不变。其他错误不按占用吞掉；OpenCode 不使用 Codex 的错误转换。

## 原生协议实测

在隔离临时 HOME 中启动两个真实 app-server，使用 `thread/shellCommand` 生成本地测试历史，
不读取用户认证、不调用模型 API、不触碰用户会话。Codex `0.154.0` 与插件版
`0.154.0-alpha.6.2` 均返回：

```json
{"code":-32600,"message":"thread <threadId> already has an active writer"}
```

第二端仍能读取 metadata 和历史页。另一端持有线程时，当前进程的 metadata 可能显示 `notLoaded`，
因此不能把它当成“另一端空闲”或“允许写入”的依据。结束测试 owner 后 resume 成功。

只读历史方法由[官方 App Server 文档](https://learn.chatgpt.com/docs/app-server)确认。
错误文案来自上述版本实测，不假定所有历史版本都有相同互斥能力。官方 `thread/unsubscribe` 只有退订语义，
最后订阅者离开后仍有无活动卸载宽限期；实测退订后第二端仍被拒绝。默认重试不会强制结束服务进程；只有用户
明确确认接管时，才执行当前 SSH 用户范围的 Codex 进程清理，且这种粗粒度操作可能中断其他 Codex 任务。

## 验证范围

- 协议与 adapter：两种原生错误文案、精确线程 ID、普通错误隔离、有界只读读取、失败锁定、重试恢复。
- 控制器：只读操作拦截、草稿/历史保留、重复重试、缓存恢复、切页迟到结果隔离。
- Widget：窄屏/大字体、重试忙碌状态、修改弹层及问题弹窗关闭、图片/差异保留、子页空底部。
- 设备流程使用生产 JSONL adapter/controller 与受控对端，不能替代用户两台手机和 VS Code 的实际网络验收。

## 本轮交付

- 全量 Flutter `597` 项、analyze、Debug/Release 构建通过；Android 14 的两组占用/恢复设备流程通过，
  `1220x2712` 只读截图已核对，正常 Release 已重新覆盖安装并启动。
- 本地 publish 一次通过，共 `5m30.471s`：测试 `56.617s`、Debug `45.159s`、Release `148.606s`、
  安装检查 `22.039s`、发布回验 `35.577s`；Server/OpenCode 门禁和发布前校验命中缓存，没有云端构建或真实模型调用。
- 本轮发布回验完成于 `2026-09-21T04:33:01Z`；包含全量测试、模拟器安装启动和 APK 下载校验，不是云端编译耗时。
- APK `dist/Agent-1.8.117.apk`，SHA-256：
  `409a11ab3abbb4f37c3e16406918343d20434060a25790cac4ea7e35cc32c633`。
- 稳定签名证书 SHA-256：`72722218709a6d7fd0e80b944903ae2961b4cfa8abe03586f602acdc1ea0f52a`。
- 内外网完整下载与构建包一致：`http://192.168.8.107/codex.apk`、`http://frp.asdb.top:18080/codex.apk`。
