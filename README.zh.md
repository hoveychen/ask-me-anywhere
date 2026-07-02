# ask-me-anywhere

[![Release](https://github.com/hoveychen/ask-me-anywhere/actions/workflows/release.yml/badge.svg)](https://github.com/hoveychen/ask-me-anywhere/actions/workflows/release.yml)
[![Docs](https://github.com/hoveychen/ask-me-anywhere/actions/workflows/docs.yml/badge.svg)](https://github.com/hoveychen/ask-me-anywhere/actions/workflows/docs.yml)
[![Latest release](https://img.shields.io/github/v/release/hoveychen/ask-me-anywhere?sort=semver)](https://github.com/hoveychen/ask-me-anywhere/releases)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

[English](README.md) · **简体中文**

> 多设备 actionable 消息卡片网络 · 全局 dismiss / 状态同步 · 纯 P2P 零服务器 · A2UI 渲染

**ask-me-anywhere**（`ama`）把富交互的通知卡片推送到*你自己的*所有设备，并保持
同步——在手机上 dismiss 一张卡片，桌面端也随之消失；在一台设备上填了表单字段，
其他设备也能看到这个值。**没有任何中心服务器存储你的消息**：你的收件箱是一份
多写者 CRDT 文档，在你的设备之间点对点复制，消息内容从不落到任何第三方手里。

卡片是 [A2UI](https://github.com/google/A2UI) 消息树，所以一张卡片不局限于
「标题 + 按钮」——任意富 UI 都能正确渲染，其 data model 还会在所有副本间双向同步。

---

## 目录

- [工作原理](#工作原理)
- [特性](#特性)
- [仓库结构](#仓库结构)
- [快速上手（CLI）](#快速上手cli)
- [CLI 参考](#cli-参考)
- [从脚本 / webhook 推送卡片](#从脚本--webhook-推送卡片)
- [自建基础设施](#自建基础设施)
- [客户端 App](#客户端-app)
- [从源码构建](#从源码构建)
- [文档](#文档)
- [项目状态](#项目状态)
- [许可证](#许可证)

---

## 工作原理

你的收件箱被建模为**一份多写者 CRDT 文档**（[iroh-docs](https://docs.rs/iroh-docs)）。
你的每台设备都持有一份完整副本，既是读者也是写者。每个功能都收敛为对这份文档的
一次读 / 写：

| 操作 | 底层实现 |
|---|---|
| 推送一条消息 | 写 `msg/<id>`（payload = A2UI 消息树） |
| 全局 dismiss | 写 `state/<id>/status`（后写者胜，LWW） |
| 点击 action | 写 `state/<id>/action`（A2UI `userAction` 结果） |
| 协同表单输入 | 写 `data/<id>/<bindPath>`（A2UI data model 字段，LWW） |
| 多设备一致 | iroh-docs gossip（在线实时）+ sync（上线补齐），CRDT 自动收敛 |

设备之间通过 **iroh DHT** 互相发现（BitTorrent 风格，无中心目录），并以
**QUIC、端到端加密、直连优先**的方式连接。当两台设备处于对称 NAT 后无法打洞
直连时，流量经一个**只哑转发加密字节的自建 iroh relay 兜底——它从不读取也从不
存储任何消息内容**。

```
   ┌─────────────┐        ┌─────────────┐
   │  Desktop    │◄──────►│  Android    │   直连优先（QUIC，端到端加密）
   │ (Flutter)   │        │ (Flutter +  │
   └──────┬──────┘        └──────┬──────┘  前台 Service 跑 P2P
          │    NAT 打不通兜底     │
          └────────►┌──────────┐◄┘
                    │  relay   │   哑转发加密流量；
                    │ (自建)   │   不读、不存内容
                    └──────────┘
   发现：iroh DHT (mainline / pkarr) —— 无中心目录
```

完整设计与取舍见 **[ARCHITECTURE.md](ARCHITECTURE.md)**。

## 特性

- **纯 P2P、零常驻** —— 消息只存在于你的设备上，没有服务器「拥有」你的收件箱。
- **全局状态同步** —— dismiss / action / 表单输入经 CRDT 在所有设备收敛。
- **A2UI 卡片** —— 任意富 UI，不止标题 + 按钮，支持双向数据绑定。
- **端到端加密** —— iroh QUIC 传输；relay 永远只看到密文。
- **凭 ticket / 二维码配对** —— 新设备扫描配对 ticket 加入，随后同步全量收件箱。
- **HTTP 注入桥** —— webhook 服务（`ama serve`）让脚本、GitHub、Linear 等
  `POST` 卡片进你的收件箱。

## 仓库结构

```
crates/
  core/            ama-core —— Rust 核心：iroh-doc 收件箱、模型、网络（P2P 引擎）
  cli/             ama-cli  —— `ama` 二进制（create/join/send/serve）
flutter_app/       Flutter App（Desktop + Android；iOS 有脚手架但暂缓）
  rust/            经 flutter_rust_bridge 绑定 ama-core
deploy/
  relay/           独立 iroh-relay 方案（Docker Compose / systemd，任意 VPS）
  relay-muvee/     Muvee PaaS 上的 iroh-relay  ← 撑起 relay.muveeai.com
  webhook/         Muvee PaaS 上的 ama serve webhook 桥 ← 撑起 webhook.muveeai.com
docs/              MkDocs 站点（双语：用户 / 集成者 / 运维者指南）
scripts/           demo 脚本 + 示例 GitHub PR payload
ARCHITECTURE.md    完整设计文档（中文）
```

## 快速上手（CLI）

构建 `ama` 二进制，在一台机器上配对两个节点即可看到卡片同步：

```bash
# 构建
cargo build -p ama-cli --release   # 二进制在 target/release/ama

# 终端 A —— 创建收件箱，打印配对 ticket
ama create --name desktop
# → 打印一个 ticket 字符串（以及二维码）

# 终端 B —— 用 ticket 加入该收件箱
ama join --name laptop <TICKET>

# 往收件箱推一张卡片（一次性）—— 会出现在每个已配对节点上
echo '{"summary":"hello from a script"}' | ama send --ticket <TICKET> --card-file -
```

默认情况下节点使用项目 relay（`relay.muveeai.com`）。可用 `--relay <url>` 指向
你自己的 relay、`--relay n0` 用 n0 的公共池、或 `--relay disabled` 走直连 / 仅局域网。

## CLI 参考

| 命令 | 用途 |
|---|---|
| `ama create` | 创建新收件箱并打印配对 ticket。`--data-dir` 会持久化收件箱 + 身份，重跑即重开。 |
| `ama join <ticket>` | 用 ticket 加入已有收件箱。`--data-dir` 让加入状态跨重启保留。 |
| `ama send --ticket <t> --card-file <f\|->` | 一次性：加入、推一张卡片（JSON 文件或 stdin）、短暂保持等 gossip 送达、退出。 |
| `ama serve` | 常驻 webhook 桥：加入一次、监听 HTTP、把 `POST /push` 和 `POST /github/pr` 转成卡片。 |

常用参数：`--name <标签>`（写入 state 的设备标签）、`--relay <url\|n0\|disabled>`、`--data-dir <路径>`。

运行 `ama <命令> --help` 查看完整参数。

### 卡片 JSON 结构

```json
{
  "summary": "必填 —— A2UI 无法渲染时用它做系统通知",
  "a2ui":    { "...A2UI v0.9 消息树...": "可选；默认 {}" },
  "source":  "可选标签；默认取 CLI 的 --name"
}
```

## 从脚本 / webhook 推送卡片

`ama serve` 是一个单租户 HTTP 桥，挡在一个收件箱前面：

| 路由 | 鉴权 | 用途 |
|---|---|---|
| `GET /healthz` | 开放 | 存活探针 |
| `POST /push` | bearer token | 注入一张卡片（结构同 `ama send`） |
| `POST /github/pr` | bearer token | 接收 GitHub `pull_request` webhook 并渲染成卡片 |

```bash
# 本地跑这个桥
ama serve --ticket <TICKET> --bind 127.0.0.1:8080 --token "$(openssl rand -hex 32)"

# 经 HTTP 推一张卡片
curl -X POST http://127.0.0.1:8080/push \
  -H "Authorization: Bearer <TOKEN>" \
  -H "Content-Type: application/json" \
  --data '{"summary":"部署完成 ✅"}'
```

托管部署的配置从环境变量读取（`AMA_TICKET`、`AMA_TOKEN` / `AMA_TOKEN_FILE`、
`AMA_RELAY`、`AMA_NAME`、`AMA_BIND`）。详见
[deploy/webhook/README.md](deploy/webhook/README.md)。

## 自建基础设施

两个可选组件让你自己跑整个网络。**两者都读不到你的消息**——relay 只转发密文，
webhook 桥只往它被授予了 ticket 的收件箱里注入卡片。

| 组件 | 作用 | 方案 |
|---|---|---|
| **iroh relay** | NAT 兜底：两台设备无法直连时哑转发加密 QUIC。客户端里烧死的默认值是 `relay.muveeai.com`。 | [deploy/relay/](deploy/relay/)（独立 VPS：Docker Compose / systemd）· [deploy/relay-muvee/](deploy/relay-muvee/)（Muvee PaaS） |
| **webhook 桥** | 跑 `ama serve`，让外部源（脚本、GitHub…）经 HTTP `POST` 卡片进你的收件箱。 | [deploy/webhook/](deploy/webhook/)（Muvee PaaS） |

> `relay-muvee` 和 `webhook` 方案针对作者的 [Muvee](https://muveeai.com) PaaS
> （经 Traefik + 托管 git 撑起 `relay.muveeai.com` / `webhook.muveeai.com`）。
> 自己的主机用 `deploy/relay/` 这个通用、与平台无关的路径。

## 客户端 App

Flutter App 一套代码同时覆盖 Desktop 和 Android（iOS 有脚手架但暂缓——见
[ARCHITECTURE.md](ARCHITECTURE.md) §1）。它经
[flutter_rust_bridge](https://cjycode.com/flutter_rust_bridge/) 内嵌 `ama-core`，
用 A2UI Flutter renderer 渲染卡片，配合原生通知与二维码配对。Android 上由前台
Service 保持 P2P 节点常驻。

发布构建（签名的 Android APK、签名 + 公证的 macOS DMG）由
[`.github/workflows/release.yml`](.github/workflows/release.yml) 产出并附到
GitHub Releases。

## 从源码构建

**前置：** 较新的 [Rust 工具链](https://rustup.rs)（edition 2024），以及构建 App
需要的 [Flutter SDK](https://docs.flutter.dev/get-started/install)。

```bash
# Rust 核心 + CLI
cargo build --release
cargo test                       # 工作区测试（含两节点同步测试）

# Flutter App
cd flutter_app
flutter pub get
flutter run                      # 或：flutter build apk / flutter build macos
```

## 文档

完整指南在 [docs/](docs/) 下（MkDocs，中英双语）：

- **用户指南** —— 安装、配对、日常使用 —— [en](docs/user/index.en.md) · [zh](docs/user/index.zh.md)
- **集成者指南** —— `ama send`、HTTP `/push`、A2UI 卡片结构 —— [en](docs/integrator/index.en.md) · [zh](docs/integrator/index.zh.md)
- **运维者指南** —— relay / webhook 部署、密钥轮换、排错 —— [en](docs/ops/index.en.md) · [zh](docs/ops/index.zh.md)

本地预览：`pip install -r requirements-docs.txt && mkdocs serve`。

## 项目状态

早期 / 个人项目。核心 P2P 同步、CLI、webhook 桥、relay 部署、Desktop + Android
App 均已就位；iOS 后台推送暂不在范围内（它必须走 APNs，与零常驻 P2P 模型冲突）。

## 许可证

采用 [MIT 许可证](LICENSE) —— © 2026 hoveychen。
