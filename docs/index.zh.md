# ask-me-anywhere

> 多设备 actionable 消息卡片网络 · 全局 dismiss/状态同步 · 纯 P2P 零常驻 · A2UI 渲染

ask-me-anywhere 把"我的收件箱"建模为一个多写者 CRDT 文档([iroh-docs](https://docs.rs/iroh-docs)),我的每台设备都是这个文档的副本持有者。推送一条消息 = 写一条 entry;dismiss = 翻转状态;表单输入 = 协同字段写。所有需求都收敛到对这个文档的读写,iroh-docs gossip + sync 自动让多设备一致。

消息体是 [A2UI](https://github.com/google/A2UI) message tree —— 不止"标题 + 按钮",任意富 UI 都可以渲染,且 data model 双向 sync 到所有副本。

## 谁应该读哪部分

| 你是 | 看哪里 | 目标 |
|---|---|---|
| 把 app 装上设备、收卡片、点 action | [使用者](user/index.md) | 安装、配对、日常使用 |
| 用脚本/webhook 往这个收件箱推卡片 | [集成者](integrator/index.md) | CLI `ama send`、HTTP `/push`、A2UI 卡片 schema |
| 维护自建 relay / webhook 服务 | [运维](ops/index.md) | 自建 relay 部署、webhook 部署、密钥轮换、故障排查 |

底层架构请参考仓库根目录的 [ARCHITECTURE.md](https://github.com/hoveychen/ask-me-anywhere/blob/main/ARCHITECTURE.md)。
