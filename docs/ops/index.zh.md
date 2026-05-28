# 运维指南

ask-me-anywhere 有两个可独立部署的服务端组件:

| 组件 | 作用 | 部署方式 |
|---|---|---|
| **iroh-relay** | NAT 兜底转发(只转发加密字节,不读不存) | VPS / Muvee |
| **ama-webhook** | HTTP 入口,把外部事件转 A2UI 卡片推进 inbox | Muvee(也能裸 Docker) |

两个都不是必需的:相对于公共 n0 relay 用自建 relay 是数据主权 + 可控性考量;不用 webhook 也可以用 [`ama send`](../integrator/index.md#1-ama-send-脚本一次性推送) 在本机直接推卡片。

---

## 1. relay 部署 {#relay-部署}

### 1.1 选哪一种

仓库里 `deploy/` 下面有两套 relay 部署模板:

| 路径 | 平台 | TLS | QUIC fastpath |
|---|---|---|---|
| [`deploy/relay/`](https://github.com/hoveychen/ask-me-anywhere/tree/main/deploy/relay) | 通用 VPS(Docker Compose / systemd) | iroh-relay 自己跑 Let's Encrypt | 走 UDP/7842 |
| [`deploy/relay-muvee/`](https://github.com/hoveychen/ask-me-anywhere/tree/main/deploy/relay-muvee) | Muvee PaaS | Traefik 终止 TLS,容器只跑 HTTP/8080 | **不可用** — Muvee 只过 HTTP/HTTPS,QUIC 走不通,降级用 HTTPS/WS fallback |

`ask-me-anywhere` 的负载特征(几个小通知卡片、间歇)用 HTTPS/WS fallback 完全够用 —— 选 Muvee 省心。如果你有专门 VPS 且关心 QUIC 直连,选通用 VPS 模板。

### 1.2 通用 VPS 步骤(摘要)

完整步骤看 `deploy/relay/README.md`,关键点:

1. 一个小 VPS(1 vCPU / 512 MB 够),域名 A/AAAA 指向它
2. 防火墙放行 `80/tcp`(ACME challenge)、`443/tcp`(HTTPS)、`7842/udp`(QUIC)
3. 编辑 `relay.toml` 填 `hostname` + `contact`(Let's Encrypt 邮箱)
4. `docker compose up -d --build` 或装 systemd unit
5. 客户端用 `--relay https://relay.your-domain` 指过来

### 1.3 Muvee 步骤(摘要)

完整步骤看 `deploy/relay-muvee/README.md`,关键命令:

```bash
muveectl projects create \
  --name iroh-relay \
  --git-source hosted \
  --domain relay \
  --dockerfile Dockerfile \
  --tags relay,iroh,p2p

# 跟着输出走:获得 PROJECT_ID + hosted-git push URL
# 把 deploy/relay-muvee/{Dockerfile,relay.toml} push 到那个 URL
# 然后 muveectl projects deploy PROJECT_ID
```

部署完后客户端用 `--relay https://relay.<your-muvee-base-domain>` 指过来。

### 1.4 为什么 relay 不开 auth

relay 必须**对所有持 URL 的设备开放** —— 它是 NAT 兜底通道,不是受保护应用。加 ForwardAuth 会阻塞合法客户端。访问控制在 iroh 层(只有拿到 doc 写票据的设备能 join inbox);relay 自身只转发加密字节(架构 §7)。

---

## 2. webhook 部署 {#webhook-部署}

### 2.1 概念

`ama serve` 长跑进程,作为一个加入了你 inbox 的"虚拟设备"。它暴露:

- `GET /healthz` — 公开,liveness probe 用
- `POST /push` + `POST /github/pr` — 都走 Bearer token 鉴权

完整 HTTP API 看[集成者指南](../integrator/index.md#2-ama-serve-长跑-webhook-服务)。

### 2.2 三个必备的环境变量

| 变量 | 作用 | 来源 |
|---|---|---|
| `AMA_TICKET` | 要 join 的 inbox 配对 ticket | 某台设备的 Flutter app QR 屏 / `ama create` 输出 |
| `AMA_TOKEN` | Bearer 鉴权密钥 | `openssl rand -hex 32` |
| `AMA_RELAY` | 自建 relay URL(可选,推荐用) | 自己的 relay 域名 |

`AMA_BIND` 由 Dockerfile 内置成 `0.0.0.0:8080` —— Traefik 在前面接 HTTPS 终止。

### 2.3 在 Muvee 上跑(完整步骤)

```bash
# 1. 本地先 sanity-check 镜像能编。构建上下文是仓库根目录,因为
#    Dockerfile 要 COPY Cargo.toml / Cargo.lock / crates/。
docker build -f deploy/webhook/Dockerfile -t ama-webhook .

# 2. 一台已经在用 inbox 的设备上拿 ticket。比如本机:
cargo run -p ama-cli -- create --name bootstrap \
  --relay https://relay.muveeai.com
# 把打印出来的 docaaa... 复制下来当 AMA_TICKET
# 这台 ama create 进程暂时保持运行,直到 webhook 第一次 join 成功

# 3. 准备一个 token。
openssl rand -hex 32 > token.txt   # AMA_TOKEN

# 4. 创建 Muvee 项目。
muveectl projects create \
  --name ama-webhook \
  --git-source hosted \
  --domain webhook \
  --dockerfile deploy/webhook/Dockerfile \
  --tags webhook,ama,m5
# 记下 PROJECT_ID

# 5. 把环境变量做成 Muvee secret + 绑到项目。Muvee 没有
#    "env set" 子命令 —— 走 secrets create + bind-secret --env-var。
muveectl secrets create --name AMA_TICKET --type password --value "docaaa..."
muveectl projects bind-secret PROJECT_ID --secret-id <AMA_TICKET_SECRET_ID> --env-var AMA_TICKET

muveectl secrets create --name AMA_TOKEN  --type password --value "$(cat token.txt)"
muveectl projects bind-secret PROJECT_ID --secret-id <AMA_TOKEN_SECRET_ID>  --env-var AMA_TOKEN

muveectl secrets create --name AMA_RELAY  --type password --value "https://relay.muveeai.com"
muveectl projects bind-secret PROJECT_ID --secret-id <AMA_RELAY_SECRET_ID>  --env-var AMA_RELAY

# 6. push 源码。需要项目级 token(mvt_...) 作为 HTTPS password,
#    session token(mvp_...) 在这里走不通。
PROJECT_TOKEN="$(muveectl tokens create PROJECT_ID --name git-push | awk '/^Token:/{print $2}')"
git push "https://x:${PROJECT_TOKEN}@muveeai.com/git/PROJECT_ID.git" main

# 7. 构建 + 部署。
muveectl projects deploy PROJECT_ID
muveectl projects logs PROJECT_ID            # 看构建
muveectl projects runtime-logs PROJECT_ID --follow  # 看容器起来
```

启动后会看到:

```
joined inbox <namespace-id>
listening on http://0.0.0.0:8080
```

### 2.4 验证端到端

```bash
HOST="https://webhook.<your-muvee-base-domain>"
TOKEN="$(cat token.txt)"

# /healthz 开放
curl -i "$HOST/healthz"
# → 200 ok

# /push 无 auth → 401
curl -i -X POST -H "Content-Type: application/json" \
  --data '{"summary":"ping"}' "$HOST/push"
# → 401

# /push 带 auth → 200 + id,所有已配对设备上弹通知
curl -i -X POST \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  --data '{"summary":"hello from prod webhook"}' "$HOST/push"
```

第一次成功的 `/push` 会触发各端设备上的系统通知。

---

## 3. 密钥轮换 {#密钥轮换}

Muvee 的 `secrets` 子命令只有 `create / delete / list`,**没有 update** —— 要换一个 secret 的值得走解绑 → 删 → 建新 → 重绑的流程,然后**必须 deploy(不是 restart)**才能让容器读到新值。

### 3.1 轮换 webhook 的 Bearer token

```bash
PROJECT_ID=<...>
OLD_TOKEN_SECRET_ID=<...>

# 1. 解绑、删除旧 secret
muveectl projects unbind-secret $PROJECT_ID $OLD_TOKEN_SECRET_ID
muveectl secrets delete $OLD_TOKEN_SECRET_ID

# 2. 生新 token,建新 secret
NEW_TOKEN="$(openssl rand -hex 32)"
NEW_SECRET_OUT=$(muveectl secrets create --name AMA_TOKEN --type password --value "$NEW_TOKEN")
NEW_SECRET_ID=$(echo "$NEW_SECRET_OUT" | grep -oE "ID: [a-f0-9-]+" | awk '{print $2}')

# 3. 重新绑定为 env var
muveectl projects bind-secret $PROJECT_ID --secret-id "$NEW_SECRET_ID" --env-var AMA_TOKEN

# 4. **重要:必须 deploy,不是 restart**
#    restart 只是重起容器进程,env vars 不变;deploy 会重新读 secret bindings。
muveectl projects deploy $PROJECT_ID
```

deploy 之后,旧 token 立刻失效。如果你有 webhook 客户端在用旧 token,先给他们换新 token 再 deploy。

### 3.2 轮换 inbox ticket

ticket 比 token 更敏感 —— 它授权"写入这个 doc"。在以下情况需要轮换:

- ticket 泄漏(同 token)
- 你想把 webhook 切到一个全新的 inbox(数据分割)

步骤同 §3.1,把 `AMA_TOKEN` 换成 `AMA_TICKET`。新 ticket 来自:

```bash
cargo run -p ama-cli -- create --name bootstrap --relay https://relay.muveeai.com
# 输出里抓 docaaa... 作为新 AMA_TICKET
```

注意:换 ticket = 换 doc namespace。**老 ticket 对应的 doc 上的卡片不会迁移到新 ticket** —— 端上的设备也要重新 join 新 ticket。

---

## 4. 监控 {#监控}

### 4.1 容器状态

```bash
muveectl projects describe PROJECT_ID
```

关键看:

| 字段 | 正常 | 不正常 |
|---|---|---|
| `Status` | `running` | `exited` / `restarting` |
| `Exit Code` | `0`(running 状态会显示上次正常退出码) | 非零 → 看 runtime-logs |
| `Restart Count` | 偶尔 1-2 没事 | 持续 +1 → 进程在崩 / OOM,看 events |

### 4.2 日志

```bash
muveectl projects logs PROJECT_ID            # 构建期 docker build / docker run 日志
muveectl projects runtime-logs PROJECT_ID --follow   # 容器 stdout/stderr
muveectl projects events PROJECT_ID --follow         # Muvee 平台事件流(deploy / restart / oom-kill)
```

runtime-logs 里典型正常输出:

```
joined inbox 162faaa…
listening on http://0.0.0.0:8080
/push -> [eee2fdfc-…] hello from remote curl
```

`failed closing path err=MultipathNotNegotiated` 是 quinn 关连接时的良性 WARN,可忽略。

### 4.3 健康探测

`GET /healthz` 是公开的、轻量、不走 inbox,适合给:

- Muvee Traefik 健康检查
- Cloudflare / 自家监控的 uptime probe
- k8s liveness/readiness probe

---

## 5. 故障排查 {#故障排查}

### 5.1 webhook 进程起不来

`muveectl projects logs PROJECT_ID` 看构建。Docker build 错误最常见的是 sed 把 `members = [...]` 整行 nuke 掉(参考仓库里那个 [chore commit 86bbf4b](https://github.com/hoveychen/ask-me-anywhere/commit/86bbf4b)),或者 cargo lock 状态不对。

### 5.2 curl `/push` 返 401

- token 拼错? 直接 `echo "Authorization: Bearer $TOKEN"` 对一下
- secret 真在容器里? `muveectl projects env PROJECT_ID --raw` 看(注意 `--raw` 显示明文)
- token 刚轮换过?用了 restart 而非 deploy → env 没刷,见 §3.1

### 5.3 curl `/push` 200 但端上没收到

最常见原因:**`AMA_TICKET` 里那个 ticket 不可达**。原现象是 webhook 自己日志里:

```
WARN gossip: dial failed: timed out peer=...
WARN sync: sync failed origin=Connect(DirectJoin) err=Failed to establish connection
```

根因:`ama create` 在 relay 注册完成之前就把 ticket 打印出来了,ticket 内嵌的可达性信息指向一个还没拿到 relay URL 的节点。修复方案是 [chore commit 86bbf4b](https://github.com/hoveychen/ask-me-anywhere/commit/86bbf4b)—— `ama create` 现在会等 relay 注册再打印 ticket。

> 如果你部署用的镜像在那个 commit 之前,重新 build + deploy 一次即可。

其它原因:

- inbox 那一端的"bootstrap peer"(原 `ama create` 进程)死了,而其它 alive peer 还没把自己注册进 swarm metadata → 新加入者只认死 peer 的地址,连不上。**至少要保证一个长期 alive peer**(可以让某台设备的 app 始终运行,或者起一个长期 `ama create` 在 VPS 上)。

### 5.4 设备之间不同步

- 两台都在线吗? 测一下:其中一台 dismiss 一张卡,另一台一会儿状态也会变
- relay 通吗? Mac 上 `flutter run` 日志会有 `home is now relay https://...`;Android 上 `adb logcat | grep relay`
- 防火墙? Android 关闭 VPN / 公司代理重试
- 老 ticket 配对的 doc 已被服务端 ticket 替换 → 设备得 join 新 ticket

### 5.5 通知没弹

参考[使用者指南 FAQ](../user/index.md#3-常见问题)。

### 5.6 SSE / `/ask` 长连接半路被砍 (M6)

`GET /events` 与 `POST /ask` 都是**长 HTTP 连接** —— 中间盒(Cloudflare / Traefik / k8s ingress)默认会在 ~100s 静止后 reap。表现:客户端突然 EOF / 504,但 `ama serve` 这边日志正常,卡片也写入了。

排查 + 规避:

- SSE 已经内置 15s `: keep-alive` 注释,Cloudflare 等都识别,正常不会被砍。被砍多半是更激进的代理。
- `/ask` 的 `timeout_secs` 把上限**设在 ≤ 90 秒**,在前置代理拍板之前自己先返。客户端拿到 `timed_out: true` 后跳 `GET /cards/{id}` 轮询继续等。
- 客户端工具如果加了自己的 idle timeout(reqwest 默认 30s、curl 没限制),要按业务调大或关。
- 如果代理是自己的,设 `proxy_read_timeout` / `read_timeout` 到 ≥ 期望最长 timeout_secs 的 1.5 倍。

---

## 6. 安全注意 {#安全}

- **relay 不需要 auth**(§1.4),但它的域名一旦泄漏给恶意方,他们能用它做 NAT 中继。流量都加密,他们看不到内容,但**会消耗你的带宽**。如果你不希望任意人用,可以加一层 IP 白名单或者迁移到只允许已知客户端的 VPN。
- **webhook token 是密钥级别的资产**。泄漏 = 任意人可以往你 inbox 推卡片。轮换流程见 §3.1。
- **inbox ticket 是更敏感的**。泄漏 = 任意人可以加入你的 inbox 并看到所有历史卡片(以及未来收到的)。目前**没有踢人功能** —— 唯一对策是新建 inbox(§3.2)。
- relay / webhook 容器不写持久数据。所有"状态"都在 doc 副本里(分布式的)。删除 Muvee 项目不会丢卡片 —— 只要还有一个设备的 app 在,数据就在。
