# 集成者指南

集成 = 把外部事件源(脚本、CI、cron、webhook、Slack/GitHub/Linear bot)接到一个已存在的 ask-me-anywhere 收件箱里。本节是给写代码的人的参考。

有两条路:

| 路径 | 用 | 适合 |
|---|---|---|
| **A. `ama send` 一次性命令** | `ama send --ticket … --card-file …` | 脚本 / cron / CI 步骤,推一次就退 |
| **B. `ama serve` 长跑 webhook** | `POST /push` + `POST /github/pr` | 多个外部源、有重试需求、需要 token 鉴权 |

A 是脚本胶,B 是常驻服务。两者都用同一个 [CardInput JSON 结构](#cardinput-json),所以你写一次"事件 → A2UI 卡片"的转换就能在两个面都用。

## 0. 快速上手 — 一条命令看到真卡 {#0-快速上手}

想端到端验证真实链路(而不是 App 里的调试"Push test card"):拿到收件箱的配对 ticket —— Flutter App 空收件箱有个 **Connect a source** 按钮能打开它,或者直接 `ama create` —— 然后喂它一张真的 GitHub PR 卡:

```bash
scripts/connect-source-demo.sh --ticket docaaa…   # 桥用了 token 就加 --token <BEARER>
```

脚本会构建 `ama`、对着该 ticket 起 `ama serve`、把 `scripts/sample-github-pr.json` 经 GitHub 适配器 POST 进去,然后保持桥常驻,让卡片 sync 到你的设备。打开 App,这张 PR 卡就落进收件箱了。本指南余下部分就是这个脚本背后的参考。

> **持久化(`--data-dir`)。** `ama create`/`join`/`send`/`serve` 都接受可选的 `--data-dir <path>`。带上它,节点会把收件箱(及身份)落盘,消息重启不丢、node-id / ticket 跨重启稳定;不带则是内存态、退出即丢(历史默认)。Flutter App 始终持久化,落在它的 app-support 目录下。

## 1. `ama send` — 脚本一次性推送 {#1-ama-send-脚本一次性推送}

```bash
ama send \
  --ticket docaaa… \
  --card-file ./card.json \
  [--name script-name] \
  [--relay https://relay.example.com] \
  [--wait-secs 5]
```

| 参数 | 默认 | 说明 |
|---|---|---|
| `--ticket` | (必填) | 目标 inbox 的配对 ticket。从某台设备的 Flutter app 拿,或从 `ama create` 输出拷过来。 |
| `--card-file` | (必填) | 卡片 JSON 文件路径,`-` 表示从 stdin 读 |
| `--name` | `script` | 进入卡片 `source` 字段的兜底值(若 JSON 没显式给 source) |
| `--relay` | n0 公共 relay | 自建 relay URL |
| `--wait-secs` | 5 | 本地 push 后最多挂多久,等 gossip 把 entry 推到至少一个 peer 后再退出。看到 `SyncFinished` 事件就提前退 |

退出码:`0` = 本地 push 成功(即使最终 gossip 超时,本地 entry 是写好的、下次再连上就同步);非零 = 入参不对或者节点起不来。

### stdin 模式

适合管道:

```bash
curl -s https://api.example.com/event | jq '...' | \
  ama send --ticket "$TICKET" --card-file - --name api-bridge
```

### 风险:in-memory replica

默认下 `ama send` 是一次性进程,inbox 副本在内存里。进程退出后这份副本就没了,因此 push 必须在退出前 **gossip 到至少一个 alive peer**(`--wait-secs` 控制这个窗口)。如果窗口太短而对端没在线,卡片丢失。加 `--data-dir <path>` 可让副本落盘、退出后仍在并下次重发;但无人值守的可靠投递,仍推荐用 `ama serve`。

## 2. `ama serve` — 长跑 webhook 服务 {#2-ama-serve-长跑-webhook-服务}

```bash
ama serve \
  --ticket docaaa… \
  --bind 0.0.0.0:8080 \
  [--name webhook] \
  [--relay https://relay.example.com] \
  [--token <BEARER>] \
  [--token-file ./token.txt]
```

| 参数 | 默认 | 说明 |
|---|---|---|
| `--ticket` | (必填) | 目标 inbox 的 ticket;服务启动时 join 一次,整个进程生命周期复用同一个 iroh 节点 |
| `--bind` | `127.0.0.1:8080` | TCP 监听地址。生产环境(Docker)用 `0.0.0.0:8080` |
| `--name` | `webhook` | 卡片 `source` 兜底值 |
| `--relay` | n0 公共 relay | 自建 relay URL |
| `--token` | (无) | 内联 Bearer token。POST 路由强制校验。和 `--token-file` 互斥 |
| `--token-file` | (无) | 从文件读 token(首行,自动 trim 空白) |

不设 token = 服务**开放**;启动时会打 WARNING。生产环境**强烈建议**设 token。

每个参数都有对应环境变量(`AMA_TICKET` / `AMA_BIND` / `AMA_NAME` / `AMA_RELAY` / `AMA_TOKEN` / `AMA_TOKEN_FILE`),Dockerfile 里用 env 比 flag 更方便。

### 2.1 路由表

| 方法 | 路径 | Auth | 用途 | 返回 |
|---|---|---|---|---|
| GET | `/healthz` | 公开 | liveness probe | `200 ok` |
| POST | `/push` | Bearer | 推卡片(fire and forget) | `200 {"id":"<uuid>"}` |
| POST | `/github/pr` | Bearer | GitHub PR webhook 适配器 | `200 {"id":"<uuid>","ignored":bool}` |
| POST | `/ask` | Bearer | 推卡片 **+ 阻塞等答案**(见 §3) | `200 {"id","timed_out","state","data"}` |
| GET | `/cards/{id}` | Bearer | 读卡片全快照(见 §3) | `200 {"card","state","data"}` 或 `404` |
| GET | `/cards/{id}/state` | Bearer | 读 MessageState | `200 {...}` 或 `404` |
| GET | `/cards/{id}/data/{*path}` | Bearer | 读单个 A2UI bindPath 值 | `200 <value>` 或 `404` |
| GET | `/events?card_id=<id>` | Bearer | **SSE 实时流**(见 §3) | `text/event-stream` |

`/healthz` 不走 auth,给 Traefik / Muvee / k8s liveness probe 用。其他路由走中间件:无 token → `401 unauthorized`,token 不匹配 → 同样 401。JSON body 解析失败 → `422 Unprocessable Entity`(axum 默认行为)。读路由对未写过的 id / state / bindPath 返 `404 not found`。

### 2.2 `POST /push` — 通用路径

请求体直接是 CardInput JSON:

```bash
curl -X POST https://webhook.example.com/push \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  --data '{
    "summary": "build #142 failed",
    "a2ui": [
      {"version":"v0.9","createSurface":{"surfaceId":"card","catalogId":"https://a2ui.org/specification/v0_9/basic_catalog.json"}},
      {"version":"v0.9","updateComponents":{"surfaceId":"card","components":[
        {"id":"root","component":"Column","children":["msg"]},
        {"id":"msg","component":"Text","text":"main → red"}
      ]}}
    ],
    "source": "ci"
  }'
```

返回:

```json
{ "id": "8e33d6f1-c5ed-492b-9262-6bfc82ecf692" }
```

`id` 是新铸的 UUID,后续可以用来在端 app 里对应这条卡片(`/get` REPL 命令、Flutter 详情页路由)。

### 2.3 `POST /github/pr` — GitHub 适配器

直接接 GitHub Webhook 的 `pull_request` payload。GitHub 通常发一个大 JSON,适配器只读 `action / number / pull_request.{title, body, html_url, user.login} / repository.full_name`,其余字段忽略(`serde` 默认 `deny_unknown_fields = false`)。

actionable action:`opened` / `reopened` / `ready_for_review`。其它(`closed`、`synchronize`、`labeled` 等)直接 `200 {"ignored":true}` 不写 inbox,避免 webhook 多次 deliver 同一 PR 产生噪音。

actionable 时构造的卡片:

```text
summary = "[org/repo#42] Title (by @login)"
a2ui    = 一个 message 数组:createSurface + updateComponents,其中 root 是一个 Column,子组件为 Text(summary)、Text(body 截断 280 字)、以及一个 Button(其 child 指向一个 Text("Open PR")、action.event.name="open_url"、context={url: html_url})
source  = "<--name>/github"  # 比如 "webhook/github"
```

具体形如:

```json
[
  {"version":"v0.9","createSurface":{"surfaceId":"card","catalogId":"https://a2ui.org/specification/v0_9/basic_catalog.json"}},
  {"version":"v0.9","updateComponents":{"surfaceId":"card","components":[
    {"id":"root","component":"Column","children":["title","body","open"]},
    {"id":"title","component":"Text","text":"[org/repo#42] Title (by @login)","variant":"h4"},
    {"id":"body","component":"Text","text":"<body 截断 280 字>"},
    {"id":"open","component":"Button","variant":"primary","child":"openText","action":{"event":{"name":"open_url","context":{"url":"<html_url>"}}}},
    {"id":"openText","component":"Text","text":"Open PR"}
  ]}}
]
```

#### GitHub 端配置

在 Repo Settings → Webhooks → Add webhook:

- Payload URL: `https://webhook.example.com/github/pr`
- Content type: `application/json`
- Events: 只勾 *Pull requests*
- Secret: 留空(我们用 Bearer token 不是 HMAC)

GitHub 原生**不支持自定义 Authorization 头**,所以直接对接需要前置一个 proxy(Cloudflare Worker 等)在中间加 `Authorization: Bearer $TOKEN`。或者改造 `auth_middleware` 改用 HMAC 校验 `X-Hub-Signature-256`(留给以后)。

## 3. 读回答案 (answer-back) {#answer-back}

A2UI 的关键不只是推问题进来,还要让外部能拿到用户的答复 —— 点哪个按钮、填什么字段。底层 CRDT 里这些数据都写到了 `state/<id>` 和 `data/<id>/<bindPath>`,M6 在 `ama serve` 上把它们接到了 HTTP。三种形态:

| 形态 | 路由 | 何时用 |
|---|---|---|
| **A 轮询** | `GET /cards/{id}` 系列 | cron / GH Action / 一次性脚本,不介意秒级延迟 |
| **B SSE 实时流** | `GET /events?card_id=<id>` | 长跑集成,要立即响应 |
| **D 一口气阻塞** | `POST /ask` | 单步"问完就拿"语义,集成代码最简 |

(C 出口 webhook callback 故意不实现 —— 集成者通常是端侧脚本,没自己的 HTTP 接收端。)

### 3.1 A:轮询

```bash
TOKEN="$(cat .ama-token)"
HOST="https://webhook.example.com"

# 1. 推卡片,拿 id
ID=$(curl -fsSL -X POST "$HOST/push" \
       -H "Authorization: Bearer $TOKEN" \
       -H "Content-Type: application/json" \
       --data '{"summary":"approve PR #42?"}' | jq -r .id)

# 2. 轮询直到 status != unread
while :; do
  RESP=$(curl -fsSL "$HOST/cards/$ID/state" \
           -H "Authorization: Bearer $TOKEN" -w '\n%{http_code}')
  STATUS=$(echo "$RESP" | head -1 | jq -r .status)
  [ "$STATUS" = "actioned" ] || [ "$STATUS" = "dismissed" ] && break
  sleep 2
done

# 3. 拿完整快照(状态 + 所有 bound data)
curl -fsSL "$HOST/cards/$ID" -H "Authorization: Bearer $TOKEN"
```

`GET /cards/{id}` 返回:
```json
{
  "card":  { "id", "summary", "a2ui", "source", "created_at" },
  "state": { "status", "action_name", "action_context", "device", "ts" } | null,
  "data":  { "/note": "...", "/score": 7, "/contact/email": "..." }
}
```

未写过 state 时 `state == null`(用户没动过);从未推过的 id → 整路由 404。

### 3.2 B:SSE 实时流

```bash
# curl -N 不缓冲,逐事件输出
curl -N "$HOST/events?card_id=$ID" \
  -H "Authorization: Bearer $TOKEN"
```

事件流:
```text
event: state
data: {"msg_id":"<id>","status":"actioned","action_name":"approve","action_context":{"by":"alice"},"device":"phone","ts":1730...}

event: data
data: {"bind_path":"/note","value":"looks good"}

: keep-alive   # 每 15s 一行注释,防中间盒断连
```

`card_id` 是 query **必填** —— 不填就拒绝(避免广播无关卡片)。connection drop → 服务端的订阅自动清理。

连上 SSE 时会先**回放快照**:把卡片当前的 state(若有)+ 所有 data 字段作为头几个 `state` / `data` 事件发出来,然后才转 live 增量。订阅在读快照**之前**就建立,所以两者之间的写入也会进 live 流(state/data 是 LWW,重复发一次幂等无害)。因此**不需要**"先 `GET /cards/{id}` 再挂 SSE"那条带竞争窗的老路径 —— 直接挂 SSE 就拿到当前值 + 后续变更。(从任意历史时间点回放,即 `?since=<ts>`,目前未实现。)

### 3.3 D:阻塞 /ask(单步)

```bash
curl -fsSL -X POST "$HOST/ask" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  --data '{
    "summary":"approve PR #42?",
    "a2ui": { ... },
    "timeout_secs": 30
  }'
```

返回(用户点了 approve):
```json
{
  "id": "8e33...",
  "timed_out": false,
  "state": { "status":"actioned", "action_name":"approve", "action_context":{...}, "device":"phone", "ts":... },
  "data": { "/note":"..." }
}
```

返回(等到 timeout):
```json
{ "id": "8e33...", "timed_out": true }
```

`timeout_secs` 默认 60,服务端硬封 600。**实践中云端部署的上限**主要由前置反向代理决定:Cloudflare/Traefik/k8s ingress 通常会在 ~100s 砍掉静止 HTTP 连接 → 把 `timeout_secs` 设到 ~90 以下比较安全。超了就 fallback 到 A(用返回的 `id` 后续 GET /cards/{id})。

阻塞期间 connection drop 怎么办? 卡片已经 push 到 inbox 副本里;客户端**可以拿不到那个 id**(响应还没回),所以这条路径不适合极不可靠的网络。要重试,用 `/push` + 轮询 / SSE 的组合。

## 4. CardInput JSON {#cardinput-json}

`/push` 和 `ama send --card-file` 用同一个结构:

```json
{
  "summary": "Title shown in the notification (REQUIRED)",
  "a2ui":   [ ... A2UI message array, optional ... ],
  "source": "where this card came from (optional)"
}
```

| 字段 | 类型 | 必填 | 默认 | 说明 |
|---|---|---|---|---|
| `summary` | string | 是 | — | 用于系统通知 + 列表摘要。短一点,~60 字符以内最佳 |
| `a2ui` | array | 否 | `[]` | A2UI message 数组(见 §5 的 wire 格式)。空数组时 Flutter 端就显示一个纯摘要卡片。详见 §5 |
| `source` | string | 否 | `--name` 的值(`script`/`webhook`) | 标记这张卡片的来源。可以放 `"github"`、`"linear"`、`"ci"` 等;同步进所有副本 |

`id` 和 `created_at` 由 `ama` 这边铸,不要在 JSON 里给(给了也会被忽略 —— `id` 用 UUIDv4,`created_at` 是 ms 时间戳)。

### 验证规则

`summary` 缺失 → axum 解析失败 → `422`(返回的 body 里会指出哪个字段缺失)。其他字段都可选。`a2ui` 字段不做内部 schema 校验 —— 写错了 Flutter 端渲染时会显示一个 fallback。

## 5. A2UI 卡片模板

A2UI v0.9 是 Google 开源的协议;ask-me-anywhere 用 `genui` Flutter SDK 渲染。`genui` 只接受 **message 数组**这种 wire 格式:`a2ui` 是一个 JSON 数组,数组元素是一条条 message(`createSurface` / `updateDataModel` / `updateComponents`)。组件是**扁平对象**,带 `id` + `component` 字符串字段,父组件通过 `children` 数组里的 id 引用子组件。绑定用 `value:{path}`(`path` 是 JSON Pointer 字符串);按钮用一个 `child` Text 引用 + `action.event.name`。完整组件目录看 [A2UI 规格](https://github.com/google/A2UI/tree/main/specification/v0_9)。下面是几个常用模板。

### 5.1 纯文本通知

```json
{
  "summary": "deploy succeeded",
  "a2ui": [
    {"version":"v0.9","createSurface":{"surfaceId":"card","catalogId":"https://a2ui.org/specification/v0_9/basic_catalog.json"}},
    {"version":"v0.9","updateComponents":{"surfaceId":"card","components":[
      {"id":"root","component":"Column","children":["msg"]},
      {"id":"msg","component":"Text","text":"main → production · build #142"}
    ]}}
  ]
}
```

### 5.2 带链接按钮

```json
{
  "summary": "PR review requested",
  "a2ui": [
    {"version":"v0.9","createSurface":{"surfaceId":"card","catalogId":"https://a2ui.org/specification/v0_9/basic_catalog.json"}},
    {"version":"v0.9","updateComponents":{"surfaceId":"card","components":[
      {"id":"root","component":"Column","children":["title","body","open"]},
      {"id":"title","component":"Text","text":"Review needed: foo refactor"},
      {"id":"body","component":"Text","text":"Updates the BarService trait to async; ~200 LOC."},
      {"id":"open","component":"Button","variant":"primary","child":"openText","action":{"event":{"name":"open_url","context":{"url":"https://github.com/acme/widget/pull/42"}}}},
      {"id":"openText","component":"Text","text":"Open PR"}
    ]}}
  ]
}
```

### 5.3 带确认 / 拒绝两按钮

`action.event.name == "dismiss"` 是约定的"关闭这张卡"(状态变 `Dismissed`),其它 action 名状态变 `Actioned`,`name + context` 写入 doc 同步给所有副本。

```json
{
  "summary": "approve 500 USD expense?",
  "a2ui": [
    {"version":"v0.9","createSurface":{"surfaceId":"card","catalogId":"https://a2ui.org/specification/v0_9/basic_catalog.json"}},
    {"version":"v0.9","updateComponents":{"surfaceId":"card","components":[
      {"id":"root","component":"Column","children":["q","actions"]},
      {"id":"q","component":"Text","text":"Vendor: WidgetCo · Amount: $500"},
      {"id":"actions","component":"Row","children":["ok","deny"]},
      {"id":"ok","component":"Button","variant":"primary","child":"okText","action":{"event":{"name":"approve"}}},
      {"id":"okText","component":"Text","text":"Approve"},
      {"id":"deny","component":"Button","child":"denyText","action":{"event":{"name":"dismiss"}}},
      {"id":"denyText","component":"Text","text":"Deny"}
    ]}}
  ]
}
```

### 5.4 带输入字段(data model 双向同步)

字段的值绑到 doc 的 `data/<msgId>/<bindPath>` key,所有副本编辑同一字段时 LWW 收敛。组件上用 `value:{path}` 声明绑定,`path` 是 RFC 6901 JSON Pointer 字符串(如 `/note`);每个有绑定的字段都要在 `updateDataModel` 里给出一个初始 seed。

```json
{
  "summary": "rate the build",
  "a2ui": [
    {"version":"v0.9","createSurface":{"surfaceId":"card","catalogId":"https://a2ui.org/specification/v0_9/basic_catalog.json"}},
    {"version":"v0.9","updateDataModel":{"surfaceId":"card","path":"/score","value":7}},
    {"version":"v0.9","updateDataModel":{"surfaceId":"card","path":"/note","value":""}},
    {"version":"v0.9","updateComponents":{"surfaceId":"card","components":[
      {"id":"root","component":"Column","children":["q","score","note","submit"]},
      {"id":"q","component":"Text","text":"How was deployment #142?"},
      {"id":"score","component":"Slider","min":0,"max":10,"value":{"path":"/score"}},
      {"id":"note","component":"TextField","label":"Any notes?","value":{"path":"/note"}},
      {"id":"submit","component":"Button","variant":"primary","child":"submitText","action":{"event":{"name":"submit"}}},
      {"id":"submitText","component":"Text","text":"Submit"}
    ]}}
  ]
}
```

提交时,A2UI renderer 调 action 写 `state/<msgId>` + `data/<msgId>/score` + `data/<msgId>/note`。所有副本几秒内都看到收敛后的值。

### 5.5 AmaChoice — AMA 自定义组件(选项描述 / preview / Other)

基础 catalog 的 `ChoicePicker` 选项只有 `{label, value}`。AMA 在 catalog 上扩了一个自定义组件 **`AmaChoice`**(仍是 A2UI —— agent 按组件名引用,只是 catalog 长大了),补齐 Claude Code AskUserQuestion 的保真度。字段:

| 字段 | 类型 | 说明 |
|---|---|---|
| `label` | string | 选项组标题 |
| `multiple` | bool | `true`=多选(checkbox),`false`/省略=单选(radio) |
| `value` | `{path}` | 选中值绑定路径(始终是列表;单选即单元素列表) |
| `other` | `{path}` | 可选。给了就显示一个 Other 文本框,与选项**互斥**(选了选项清空 Other,填了 Other 清空选项) |
| `options` | 数组 | `[{label, value, description?, preview?}]`。单选选中带 `preview` 的项时,下方显示该 preview 面板 |

```json
{
  "summary": "deploy target?",
  "a2ui": [
    {"version":"v0.9","createSurface":{"surfaceId":"card","catalogId":"https://a2ui.org/specification/v0_9/basic_catalog.json"}},
    {"version":"v0.9","updateDataModel":{"surfaceId":"card","path":"/env","value":[]}},
    {"version":"v0.9","updateDataModel":{"surfaceId":"card","path":"/envOther","value":""}},
    {"version":"v0.9","updateComponents":{"surfaceId":"card","components":[
      {"id":"root","component":"Column","children":["pick","ok"]},
      {"id":"pick","component":"AmaChoice","label":"Target","value":{"path":"/env"},"other":{"path":"/envOther"},
       "options":[
         {"label":"Production","value":"prod","description":"Live traffic","preview":"prod.example.com · 不可撤销"},
         {"label":"Staging","value":"staging","description":"Pre-prod mirror"}
       ]},
      {"id":"ok","component":"Button","variant":"primary","child":"okt","action":{"event":{"name":"confirm"}}},
      {"id":"okt","component":"Text","text":"Confirm"}
    ]}}
  ]
}
```

答复落在 `data/<id>/env`(选项,列表)和 `data/<id>/envOther`(Other 文本)—— 二者互斥,只有一个非空。

### 5.6 客户端函数:门控与动作

A2UI 的 `checks`(组件启用条件)和 `action.functionCall`(按钮调用)可引用宿主注册的客户端函数。AMA 注册了三个:

| 函数 | 用在 | 作用 |
|---|---|---|
| `allAnswered` | `checks.condition` | 所有参数都"已答"(非空列表 / 非空白串 / 非 null)才 true |
| `anyAnswered` | `checks.condition` | 任一参数已答即 true(用于"选项 OR Other") |
| `setData` | `action.functionCall` | 把 `args.value` 写进 `args.path` 数据路径(按钮驱动状态,如切 tab) |

```json
"checks":[{"message":"先答完","condition":{"call":"allAnswered","args":{"a":{"path":"/env"},"b":{"path":"/note"}}}}]
```

`checks.condition` 为真 → 组件启用;任一 check 为假 → 禁用。**注意**:genui 把"非 null"当真(空列表 `[]` 也算),所以判"未答"必须用 `allAnswered`/`anyAnswered`,不能直接 `{path}`。`setData` 动作:`"action":{"functionCall":{"call":"setData","args":{"path":"/step","value":1}}}`。

### 5.7 多问题向导(Tabs 渐进式 Next/Confirm)

一卡多问的做法:`Tabs` 的 `activeTab` 绑 `/step`,每 tab 一个问题。每个非末 tab 放一个 **Next** 按钮 —— `action` 用 `setData` 把 `/step` 写成下一个索引来切 tab,`checks` 用 `anyAnswered` 门控(当前题答了才能点);末 tab 放 **Confirm**(`event` 动作,`checks` 用 `allAnswered` 嵌 `anyAnswered`,要求每题都答)。tab 头本身也能点着导航。整套纯 A2UI,远端可推。

要点:Next/Back 是 `setData`(只写 data,`status` 仍 `Unread`),所以**不会结束 `/ask` 的阻塞等待**;只有 Confirm 的 `event`→`recordAction` 把状态置 `Actioned`、`/ask` 才返回。多步向导与同步问答天然契合。

## 6. 各语言示例

### 6.1 Bash / curl

```bash
TOKEN="$(cat .ama-token)"
HOST="https://webhook.example.com"
curl -fsSL -X POST "$HOST/push" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  --data @./card.json
```

### 6.2 Python

推一张然后阻塞等答案 —— "ask, get answer" 的最简版:

```python
import os, requests

TOKEN = os.environ["AMA_TOKEN"]
HOST  = os.environ["AMA_HOST"]   # https://webhook.example.com

r = requests.post(
    f"{HOST}/ask",
    headers={"Authorization": f"Bearer {TOKEN}"},
    json={
        "summary": "deploy build #142?",
        "a2ui": [
            {"version": "v0.9", "createSurface": {
                "surfaceId": "card",
                "catalogId": "https://a2ui.org/specification/v0_9/basic_catalog.json"}},
            {"version": "v0.9", "updateComponents": {"surfaceId": "card", "components": [
                {"id": "root", "component": "Column", "children": ["q", "ok", "no"]},
                {"id": "q", "component": "Text", "text": "Approve deploy?"},
                {"id": "ok", "component": "Button", "variant": "primary",
                 "child": "okText", "action": {"event": {"name": "approve"}}},
                {"id": "okText", "component": "Text", "text": "Approve"},
                {"id": "no", "component": "Button",
                 "child": "noText", "action": {"event": {"name": "dismiss"}}},
                {"id": "noText", "component": "Text", "text": "Dismiss"},
            ]}},
        ],
        "timeout_secs": 90,
    },
    timeout=120,
)
r.raise_for_status()
ans = r.json()
if ans["timed_out"]:
    print(f"no one answered card {ans['id']} in 90s")
else:
    print(f"answer: {ans['state']['action_name']}  data: {ans['data']}")
```

只推不等 —— `POST /push`:

```python
r = requests.post(f"{HOST}/push",
                  headers={"Authorization": f"Bearer {TOKEN}"},
                  json={"summary": "DB backup completed",
                        "source": "ops-cron"}, timeout=10)
r.raise_for_status()
print(r.json()["id"])
```

### 6.3 Go

```go
package main

import (
    "bytes"
    "encoding/json"
    "fmt"
    "net/http"
    "os"
)

func main() {
    body, _ := json.Marshal(map[string]any{
        "summary": "build finished",
        "a2ui": []any{
            map[string]any{"version": "v0.9", "createSurface": map[string]any{
                "surfaceId": "card",
                "catalogId": "https://a2ui.org/specification/v0_9/basic_catalog.json",
            }},
            map[string]any{"version": "v0.9", "updateComponents": map[string]any{
                "surfaceId": "card",
                "components": []any{
                    map[string]any{"id": "root", "component": "Column", "children": []any{"msg"}},
                    map[string]any{"id": "msg", "component": "Text", "text": "build #142 green"},
                },
            }},
        },
        "source": "ci",
    })
    req, _ := http.NewRequest("POST", os.Getenv("AMA_HOST")+"/push", bytes.NewReader(body))
    req.Header.Set("Authorization", "Bearer "+os.Getenv("AMA_TOKEN"))
    req.Header.Set("Content-Type", "application/json")
    resp, err := http.DefaultClient.Do(req)
    if err != nil {
        panic(err)
    }
    defer resp.Body.Close()
    if resp.StatusCode != 200 {
        panic(fmt.Sprintf("status %d", resp.StatusCode))
    }
}
```

## 7. 调试 & 限制

### 限制

- **没有重试 / 队列**:`/push` 返回 200 = 本地写入 + push 成功提交给 gossip。如果 gossip 暂时连不到 peer,卡片会留在 webhook 副本里直到下次 peer 上线;不会"投递失败 → 重试"。生产场景可以靠 webhook 长跑保证。
- **没有速率限制**:适配器没有 in-process rate limit;外部源(GitHub 等)的至少一次投递是你自己的问题。`/github/pr` 适配器靠"action 在 whitelist 才写入"避免 noise。
- **没有 HMAC**:GitHub webhook 的 `X-Hub-Signature-256` 现在不验。如果担心被伪造,前置 proxy + Bearer 是当前唯一兜底。

### 调试

服务侧打开 trace:`RUST_LOG="warn,iroh_docs=debug,iroh_gossip=debug,ama=trace"`;Docker 里通过 `muveectl projects env … set RUST_LOG=…`(其实是 secrets create + bind-secret,见 [运维](../ops/index.md))。

客户端推送失败:
- `curl -i` 看返回头 + 状态码
- `401`:token 不对 / 没带 `Authorization: Bearer …` / Header 名拼错
- `422`:body JSON 不合法 / `summary` 字段缺失 → axum 返回的 body 会指明缺哪个字段
- 网络超时:确认 webhook 容器还活着(`muveectl projects describe`),`/healthz` 走得通
