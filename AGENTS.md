# AI 协作入口

修改本仓库前，必须先完整阅读 [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)。它是项目架构、
运行时数据流、测试环境、发布流程和产品约束的主文档。

## 强制规则

1. 仓库存在 .codegraph/ 时，定位或理解源码前先运行：

   ~~~bash
   /root/.local/bin/codegraph explore "要查的问题、文件或符号"
   ~~~

   若 codegraph 已加入 PATH，可省略绝对路径。源码变更后运行
   /root/.local/bin/codegraph sync。
2. 只修改 /home/yan/ygy/codex-remote-android；不要碰同级的 ssh-client、lobe-android、
   mihomo-web 或其他工作区，也不要删除未跟踪的用户文件。
3. APK 签名文件 keystore/codex-remote-stable.keystore 和签名配置不得更换。发布 APK
   必须增加 versionCode，确保手机可以覆盖安装。
4. Git 提交信息使用中文。完成实现后按任务风险执行测试；发布时必须构建、验签，并同时给出
   内网和外网下载地址。
5. 不得把密码、私钥、OpenAI 凭据、FRP token 或真实敏感日志写进源码、文档、测试输出和提交。
