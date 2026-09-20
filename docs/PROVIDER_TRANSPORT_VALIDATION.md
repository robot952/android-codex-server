# 模型 API 传输诊断（2026-09-20）

## 问题边界

用户截图中的 `Falling back from WebSockets to HTTPS transport` 来自 Codex 到模型 API 的 Responses
连接，不是手机到 SSH/app-server 的连接。握手成功也不代表响应完整；流在 `response.completed` 前
关闭时，Codex 会尝试 HTTP 回退。不得仅凭该提示判定网站不支持 WebSocket。

## 真实探测

在用户此前授权下，使用当前服务器配置和相同模型进行有限探测；URL、Key、响应正文均不留存。
只发送一次 WebSocket 模型请求、两次 HTTP 模型请求，另有一次不发送模型请求的握手检查：

- WebSocket 成功升级，随后关闭码 `1013`，原因 `no available account`，没有响应事件。
- HTTP 首次返回 `200` 并产生文本和 `response.output_item.done`，随后 EOF，未见
  `response.completed`、`response.failed` 或 `response.incomplete`。
- 第二次握手保持打开至主动结束；第二次 HTTP 请求在 40 秒内未取得响应头。

这些是特定时间点的观察，不是网站永久状态或所有模型的结论。关闭原因指向网关上游账号分配，
但余额、并发限制、账号健康、模型路由或 WebSocket 专用账号资格仍须由网关服务端日志确认。
本轮没有修改网站、账号池、用户全局 Codex 配置或 Provider 身份，也不把 App 的提示修复称为服务端修复。

## 离线 Codex 对照

`scripts/test-codex-provider-transport.cjs` 使用已安装 Codex `0.154.0`、私有临时 HOME、虚假认证和
仅监听 loopback 的 Responses fixture，外部代理指向不可用的 loopback 端口；不调用真实 API。

| 配置 | WebSocket 尝试 | HTTP 完成 |
| --- | --- | --- |
| 内置 openai + 自定义 openai_base_url | 1 | 是 |
| responses_websockets_v2=false | 1 | 是 |
| responses_websockets=false 且 v2=false | 1 | 是 |
| 覆盖 model_providers.openai.supports_websockets=false | 配置拒绝 | 否 |
| 同时指定内置 Provider 名称 | 配置拒绝 | 否 |
| thread/start.config 覆盖内置 Provider | 配置拒绝 | 否 |
| 自定义 Provider + supports_websockets=false | 0 | 是 |

旧 feature 开关不能作为该版本内置 openai 的禁用方案；强行写入保留 Provider 会使启动失败。
App 保持现有自定义 Provider 传输选项，不自动迁移 Provider，避免改变用户会话命名空间。

## 客户端修正

- 已识别的 WebSocket 回退仅进入有界诊断日志，不再把内部传输细节插入对话时间线；回退不会结束或重启回合。
- 提示不会被解释为 SSH 断线、回合完成或自动重发用户任务；其他错误保留，嵌套 error.message 正确读取。
- 设置按钮明确标为 HTTP API 测试；HTTP 成功不代表 WebSocket 通过。
- 连接测试检查响应正文及结束状态，防止 HTTP 200 的错误页、未完成 JSON 或提前断开的 SSE 假报成功。

官方依据：[Codex 配置参考](https://learn.chatgpt.com/docs/config-file/config-reference)、
[Responses WebSocket 模式](https://developers.openai.com/api/docs/guides/websocket-mode)。

## 验收与交付

- App `1.8.114+244`，Flutter 全量和 analyze 通过；HTTP 完整性定向 `22` 项通过。
- 真实 Codex + 本地模型 fixture 的七组配置对照通过。Android 14、`1220x2712` 上的生产
  adapter/controller/WorkScreen 测试验证回退去重、后台线程隔离、不会重发任务和回退后正常完成；
  该设备测试使用受控 JSONL 对端，不代表真实网关已经恢复。Windows 共享校验器已编译检查，未运行 Windows 实机。
- 正常 Release 覆盖安装及启动检查通过，稳定证书未变化；内外网下载内容与构建包一致。
- 本轮从首次写文件 `2026-09-20T06:25:14Z` 至发布回验 `07:13:13Z` 为 `47m59s`，包括探测、
  版本对照、实现及验证，不是编译耗时。唯一一次 publish 主门禁 `5m22.373s`：依赖 `1.436s`、
  analyze `8.399s`、全量测试 `58.382s`、Debug `22.165s`、Release `153.826s`、安装检查 `28.080s`、
  发布及下载回验 `40.708s`。服务器脚本/OpenCode/发布前 APK 校验命中缓存，无云端构建和发布门禁返工。
- 设备流程首轮通过；手工截图错过测试窗口，不能把桌面/启动页截图算作回退提示视觉验收。
  正常 Release 启动页截图已核对。其余截图对应的布局与文案由 Widget/设备断言验证。

APK SHA-256：`c2aef747775ee76ea5d8d1ceb3e20765bc5a8532035839d40c3dbfdddebb09f9`

证书 SHA-256：`72722218709a6d7fd0e80b944903ae2961b4cfa8abe03586f602acdc1ea0f52a`

内网：http://192.168.8.107/codex.apk

外网：http://frp.asdb.top:18080/codex.apk
