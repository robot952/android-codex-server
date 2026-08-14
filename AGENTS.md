# AI 协作入口

每次开始工作前，必须先从仓库磁盘重新完整阅读本文件和
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)。新会话、任务恢复、上下文压缩或摘要恢复后也必须重读，
不得用聊天记录、记忆或压缩摘要代替原文。它是项目架构、运行时数据流、测试环境、发布流程和产品
约束的主文档；涉及构建、测试或发布时还必须完整阅读
[docs/LOCAL_WORKFLOW.md](docs/LOCAL_WORKFLOW.md)。

## 强制规则

1. 仓库存在 .codegraph/ 时，定位或理解源码前先运行：

   ~~~bash
   /root/.local/bin/codegraph explore "要查的问题、文件或符号"
   ~~~

   若 codegraph 已加入 PATH，可省略绝对路径。源码变更后运行
   /root/.local/bin/codegraph sync。
2. 只修改本仓库；不要碰同级的 ssh-client、lobe-android、mihomo-web 或其他工作区，也不要删除
   未跟踪的用户文件。
3. APK 签名文件 keystore/codex-remote-stable.keystore 和签名配置不得更换。发布 APK
   必须增加 versionCode，确保手机可以覆盖安装。
4. Git 提交信息使用中文。完成实现后按任务风险执行测试；每次向用户交付 APK 或下载链接时，
   无需用户再次提醒，最终答复必须同时给出完整的内网和外网下载地址，并完成构建、验签和下载回验。
5. 不得把密码、私钥、OpenAI 凭据、FRP token 或真实敏感日志写进源码、文档、测试输出和提交。

## 本地工作流

默认使用 [docs/LOCAL_WORKFLOW.md](docs/LOCAL_WORKFLOW.md) 的高复用入口。不要运行 `clean`、删除 AVD、
清空 App 数据、重装固定 OpenCode 或重建 SSH 测试账号；需要绕过内容指纹缓存时使用
`./scripts/dev-workflow.sh <mode> --force`。本地发布只执行 `publish`，未获用户明确允许不得推送或
触发 `release`。

当用户明确要求“推送到远端并出包”或同义指令时，视为用户已经完成本地验收；不要再运行单元测试、
全量测试、analyze、本地构建或模拟器门禁，直接提交并推送，然后只跟踪云端流水线和 Release。
