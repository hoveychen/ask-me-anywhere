# 集成者指南

集成 = 把外部事件源(脚本、CI、cron、webhook、Slack/GitHub/Linear bot)接到一个已存在的 ask-me-anywhere 收件箱里。本节是给写代码的人的参考。

有两条路:

| 路径 | 用 | 适合 |
|---|---|---|
| **A. `ama send` 一次性命令** | `ama send --ticket … --card-file …` | 脚本 / cron / CI 步骤,推一次就退 |
| **B. `ama serve` 长跑 webhook** | `POST /push` + `POST /github/pr` | 多个外部源、有重试需求、需要 token 鉴权 |

A 是脚本胶,B 是常驻服务。两者都用同一个 [CardInput JSON 结构](#cardinput-json),所以你写一次"事件 → A2UI 卡片"的转换就能在两个面都用。

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

`ama send` 是一次性进程,它的 inbox 副本是内存里的(`MemStore`)。进程退出后这份副本就没了。因此 push 必须在退出前 **gossip 到至少一个 alive peer**(`--wait-secs` 控制这个窗口)。如果窗口太短而对端没在线,卡片丢失。要长期可靠,使用 `ama serve` 而不是 `ama send`。

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
    "a2ui": { "root": { "Text": { "text": "main → red" } } },
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
a2ui    = Card { Text(summary), Text(body 截断 280 字), Button(label="Open PR", action.name="open_url", context={url: html_url}) }
source  = "<--name>/github"  # 比如 "webhook/github"
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

要带历史回放(从某个时间点开始的所有事件)目前没实现,典型用法是:`GET /cards/{id}` 一次拿当前快照,然后挂上 SSE 接续。中间的微秒级竞争窗对人类驱动的审批不影响。

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
  "a2ui":   { ... A2UI message tree, optional ... },
  "source": "where this card came from (optional)"
}
```

| 字段 | 类型 | 必填 | 默认 | 说明 |
|---|---|---|---|---|
| `summary` | string | 是 | — | 用于系统通知 + 列表摘要。短一点,~60 字符以内最佳 |
| `a2ui` | object | 否 | `{}` | A2UI message tree。空对象时 Flutter 端就显示一个纯摘要卡片。详见 §5 |
| `source` | string | 否 | `--name` 的值(`script`/`webhook`) | 标记这张卡片的来源。可以放 `"github"`、`"linear"`、`"ci"` 等;同步进所有副本 |

`id` 和 `created_at` 由 `ama` 这边铸,不要在 JSON 里给(给了也会被忽略 —— `id` 用 UUIDv4,`created_at` 是 ms 时间戳)。

### 验证规则

`summary` 缺失 → axum 解析失败 → `422`(返回的 body 里会指出哪个字段缺失)。其他字段都可选。`a2ui` 字段不做内部 schema 校验 —— 写错了 Flutter 端渲染时会显示一个 fallback。

## 5. A2UI 卡片模板

A2UI v0.9 message tree 是 Google 开源的协议;ask-me-anywhere 用 `genui` Flutter SDK 渲染。完整组件目录看 [A2UI 规格](https://github.com/google/A2UI/tree/main/specification/v0_9)。下面是几个常用模板。

### 5.1 纯文本通知

```json
{
  "summary": "deploy succeeded",
  "a2ui": {
    "root": {
      "Card": {
        "id": "root",
        "children": [
          { "Text": { "id": "msg", "text": "main → production · build #142" } }
        ]
      }
    }
  }
}
```

### 5.2 带链接按钮

```json
{
  "summary": "PR review requested",
  "a2ui": {
    "root": {
      "Card": {
        "id": "root",
        "children": [
          { "Text": { "id": "title", "text": "Review needed: foo refactor" } },
          { "Text": { "id": "body",  "text": "Updates the BarService trait to async; ~200 LOC." } },
          { "Button": {
              "id": "open",
              "label": "Open PR",
              "action": {
                "name": "open_url",
                "context": { "url": "https://github.com/acme/widget/pull/42" }
              }
          }}
        ]
      }
    }
  }
}
```

### 5.3 带确认 / 拒绝两按钮

`action.name == "dismiss"` 是约定的"关闭这张卡"(状态变 `Dismissed`),其它 action 名状态变 `Actioned`,`name + context` 写入 doc 同步给所有副本。

```json
{
  "summary": "approve 500 USD expense?",
  "a2ui": {
    "root": {
      "Card": {
        "id": "root",
        "children": [
          { "Text": { "id": "q", "text": "Vendor: WidgetCo · Amount: $500" } },
          { "Row": {
              "id": "actions",
              "children": [
                { "Button": { "id": "ok",    "label": "Approve", "action": { "name": "approve" } } },
                { "Button": { "id": "deny",  "label": "Deny",    "action": { "name": "dismiss" } } }
              ]
          }}
        ]
      }
    }
  }
}
```

### 5.4 带输入字段(data model 双向同步)

字段的值绑到 doc 的 `data/<msgId>/<bindPath>` key,所有副本编辑同一字段时 LWW 收敛。`bindPath` 是 RFC 6901 JSON Pointer。

```json
{
  "summary": "rate the build",
  "a2ui": {
    "root": {
      "Card": {
        "id": "root",
        "children": [
          { "Text":   { "id": "q",     "text": "How was deployment #142?" } },
          { "Slider": { "id": "score", "value": 7, "min": 0, "max": 10, "step": 1, "bindPath": "/score" } },
          { "TextField": { "id": "note", "label": "Any notes?", "bindPath": "/note" } },
          { "Button": { "id": "submit", "label": "Submit", "action": { "name": "submit" } } }
        ]
      }
    }
  }
}
```

提交时,A2UI renderer 调 action 写 `state/<msgId>` + `data/<msgId>/score` + `data/<msgId>/note`。所有副本几秒内都看到收敛后的值。

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
        "a2ui": {
            "root": {
                "Card": {
                    "id": "root",
                    "children": [
                        {"Text": {"id": "q", "text": "Approve deploy?"}},
                        {"Button": {"id": "ok", "label": "Approve",
                                    "action": {"name": "approve"}}},
                        {"Button": {"id": "no", "label": "Dismiss",
                                    "action": {"name": "dismiss"}}},
                    ],
                }
            }
        },
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
        "a2ui": map[string]any{
            "root": map[string]any{
                "Card": map[string]any{
                    "id": "root",
                    "children": []any{
                        map[string]any{"Text": map[string]any{"id": "msg", "text": "build #142 green"}},
                    },
                },
            },
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
