# ask-me-anywhere — 架构方案

> 多设备 actionable 消息卡片网络 · 全局 dismiss/状态同步 · 纯 P2P 零常驻 · A2UI 渲染

## 0. 决策快照

| 维度 | 选择 |
|---|---|
| 存储模型 | 纯 DHT 零常驻(消息只存在于我的设备) |
| 设备覆盖 | Desktop + Android(iOS 暂缓,但端栈为其铺路) |
| P2P 核心 | Iroh + iroh-docs(Rust) |
| NAT 兜底 | 自建一个 iroh relay(只哑转发,不读不存) |
| 端技术栈 | Flutter 全端,Rust 核心经 flutter_rust_bridge |
| 消息 UI | A2UI v0.9,官方 Flutter renderer |
| 卡片状态 | 完整双向协同(A2UI data model ⟷ CRDT) |

## 1. 目标与非目标

**目标**
- 向我的多台设备推送 **A2UI** actionable 消息卡片(任意富 UI,不止标题+按钮)。
- 全局状态同步:一台设备的 dismiss / action / 表单输入,其他设备同步可见(多设备协同)。
- 消息不存储在任何第三方服务器上 —— 数据只存在于我自己的设备里。
- 端覆盖 Desktop + Android,Flutter 一套 UI 为未来 iOS 铺路。

**非目标(本阶段)**
- **iOS 后台推送**:必须经 APNs,与"纯 P2P 零常驻"冲突,本阶段不做(Flutter 端栈保留未来接入可能)。
- 多用户 / 群发:这是单人多设备私有网络,不是 IM。
- 长期归档:消息是瞬时通知流,不承诺无限历史。

## 2. 核心模型

把"我的收件箱"建模为**一个多写者 CRDT 文档**(`iroh-doc`)。我的每台设备都是这个文档的**副本持有者 + 读写者**。所有需求收敛到对这个文档的读写:

| 需求 | 实现 |
|---|---|
| 推送一条消息 | 写一条 `msg/<id>` entry(payload = A2UI message tree) |
| 全局 dismiss | 写 `state/<id>/status`(LWW 收敛) |
| 点击 action | 写 `state/<id>/action`(A2UI userAction 结果) |
| 表单/输入协同 | 写 `data/<id>/<bindPath>`(A2UI data model 字段,LWW) |
| 多设备一致 | iroh-docs gossip(在线实时)+ sync(上线补齐),CRDT 自动收敛 |
| 零服务器 | doc 副本只存在于我的设备上,没有节点"拥有"它 |

## 3. A2UI 集成 — 双向协同闭环

这是本方案的核心机制,也是技术风险最高处。

```
                 ┌──────────────────────────────────────┐
                 │              iroh-doc                  │
                 │  msg/<id>   = A2UI message tree (不变) │
                 │  state/<id> = status / userAction      │
                 │  data/<id>/<bindPath> = 协同字段值      │
                 └───────▲───────────────────┬────────────┘
   设备 A renderer        │ 写变更            │ sync 通知变更
   ┌──────────────┐       │                   │      ┌──────────────┐
   │ A2UI Flutter │───────┘                   └─────►│ A2UI Flutter │
   │ renderer     │  data model 变更回调             │ renderer     │
   │ (设备 A)     │◄─────── 监听 CRDT 刷新 ──────────│ (设备 B)     │
   └──────────────┘                                  └──────────────┘
```

- **`msg/<id>` 不可变**:A2UI message tree(结构 + 静态内容)创建后不改。
- **`data/<id>/*` 可变协同**:A2UI v0.9 的 data model 绑定路径,每个 bindPath 一个 CRDT key,LWW 收敛。renderer 把用户输入回调出来 → 写入对应 key → sync 到其他设备 → 各端 renderer 监听 CRDT 变更刷新 UI。
- **userAction**:用户点 Action 组件 → `{actionName, actionContext}` 写入 `state/<id>`;dismiss 约定为 `actionName == "dismiss"`。

**✅ M0 源码级验证已通过**(`flutter/genui` 仓库,包 `a2ui_core`):
- **外部写入(CRDT → UI)**:processor 处理一条 `UpdateDataModelMessage` → `surface.dataModel.set(path, value)` → 内部 `_notifyPathAndRelated` 通知 preact_signals → 绑定 widget 自动重渲染。**官方通道,无需 hack 私有字段。**
- **读取用户变更(UI → CRDT)**:`A2uiMessageProcessor.getClientDataModel()` 取 data model 快照;细粒度可用 `DataModel.watch(path)`(返回 `ReadonlySignal`)+ `Effect` 订阅。
- **响应式底座**:preact_signals(`Signal`/`Computed`/`Effect`),`set` 即触发重渲染。

> 注:以上为**官方源码确认**(读了 `data_model.dart` 的 `get/set/watch/_notifyPathAndRelated` 实现与 `processor.dart` 的 `UpdateDataModelMessage` 分支),机制成立;**最小 Flutter demo 实跑**作为最终落地确认仍建议在 M1 前补一次。

## 4. 数据模型

```
msg/<msgId>              -> A2UI message tree (JSON, 不可变)
msg/<msgId>/meta         -> { source, created_at, summary }   # summary 供系统通知用
state/<msgId>            -> { status, action_name, action_context, device, ts }
data/<msgId>/<bindPath>  -> 标量值 (LWW: ts + authorId 决胜)
```

`summary` 字段必备:系统级通知(Android 通知栏 / Desktop 原生通知)渲染不了完整 A2UI,只显示 summary 做"敲门",点开进 App 看完整 A2UI 卡片。

## 5. 拓扑

```
   ┌─────────────┐        ┌─────────────┐
   │  Desktop    │◄──────►│  Android    │     直连优先(QUIC, E2E)
   │ (Flutter)   │        │ (Flutter +  │
   │             │        │  前台 Svc)  │
   └──────┬──────┘        └──────┬──────┘
          │   NAT 打不通时兜底    │
          └────────►┌──────────┐◄┘
                    │ 自建 relay│   只哑转发加密流量,不读不存内容
                    │ (小 VPS) │
                    └──────────┘
       发现:iroh DHT discovery (mainline / pkarr) — BT 风格,无中心目录
```

- **发现**:iroh DHT discovery,设备靠 DHT 找到彼此,无中心目录。
- **传输**:iroh QUIC,端到端加密,直连优先。
- **中继兜底**:对称 NAT 双方直连失败时经**自建 iroh relay** 哑转发,relay 读不到也不存任何消息内容。

## 6. 同步与离线语义

- **在线**:gossip 实时扩散,新 entry 秒级到达其他在线设备。
- **离线 → 上线**:与任一在线 peer 做 doc sync,补齐缺失 entry,CRDT 收敛。
- **全设备同时离线**:消息停在发送设备上,任一其他设备上线即扩散 —— 纯零常驻固有特性,relay 不暂存内容。

## 7. 安全与配对

- 文档访问靠 iroh **read+write ticket**;传输层 iroh QUIC 端到端加密。
- **设备配对**:新设备扫二维码获取 doc ticket → 加入文档 → 自动 sync 全量。
- relay 即使被攻陷也只能看到加密流量。

## 8. 端实现

| 端 | 形态 | 通知 |
|---|---|---|
| Desktop | Flutter,Rust 核心经 flutter_rust_bridge | 系统原生通知(显示 summary) |
| Android | Flutter + 前台 Service 跑 P2P,核心经 flutter_rust_bridge | 系统通知;持续前台通知图标(代价) |
| 渲染 | GenUI SDK(`genui` + `a2ui_core`,catalog 机制),本地打包离线渲染 P2P 收到的 tree | — |
| 核心 | 一个 Rust crate,flutter_rust_bridge 导出绑定 | — |

**Android 取舍**:跑真 P2P 需常驻前台 Service,有持续通知图标 + 耗电,部分国产 ROM 可能杀进程。

## 9. 已知取舍汇总

1. **协同粒度**:iroh-docs 是 **字段级 LWW**,不是字符级序列 CRDT。多设备同时编辑同一卡片同一字段会"后写覆盖先写"(不丢卡片,丢的是并发编辑的中间字符)。对通知/表单场景足够;若将来要真正的协同文本编辑,需在 `data` 层换用序列 CRDT(如 Automerge)。
2. ✅ A2UI 双向 data sync 能力 M0 源码级已确认(见 §3);最小 demo 实跑待 M1 前补。
3. NAT 兜底依赖一个自建 relay(只哑转发,不读不存)。
4. 全设备同时离线时消息不传播,等任一设备上线。
5. Android 前台 Service 耗电 / 可能被 ROM 杀。
6. 放弃 iOS 后台推送(平台硬约束)。

## 10. 实现里程碑

- **M0 — A2UI 双向验证 ✅(源码级已通过)**:`a2ui_core` 的 `DataModel.set/watch` + `UpdateDataModelMessage` 提供官方双向通道(见 §3)。剩一个最小 Flutter demo 实跑做最终确认,建议并入 M1 前。
- **M1 — Rust 核心 + 双节点跑通**:`core` crate 封装 iroh-doc inbox,CLI 节点跑通两节点间 `msg` + `state` + `data` 的 CRDT 同步(含 dismiss 收敛)。
- **M2 — 自建 relay**:部署 iroh relay,验证对称 NAT 下兜底连通。
- **M3 — Flutter Desktop App**:flutter_rust_bridge 接入核心 + A2UI renderer,卡片渲染 + 原生通知 + 二维码配对 + data 双向闭环。
- **M4 — Android**:同一 Flutter App + 前台 Service + 系统通知。
- **M5 — 消息注入接口**:外部源(脚本 / webhook 适配器)往网络发 A2UI 卡片。
