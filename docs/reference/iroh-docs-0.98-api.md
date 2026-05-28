# iroh-docs 0.98 API → inbox 映射(P2 实现蓝本)

照官方源码(`n0-computer/iroh-docs` tag v0.98.0)侦察,非凭记忆。

## 构造(持久化)

```rust
let endpoint = Endpoint::bind(presets::N0).await?;
let blobs = /* MemStore::default() 或持久化 FsStore —— 见下方待决 */;
let gossip = Gossip::builder().spawn(endpoint.clone());
let docs = Docs::persistent(path)        // 需要 iroh-docs feature = "fs-store"
    .spawn(endpoint.clone(), (*blobs).clone(), gossip.clone())
    .await?;
let _router = Router::builder(endpoint.clone())
    .accept(BLOBS_ALPN, BlobsProtocol::new(&blobs, None))
    .accept(GOSSIP_ALPN, gossip)
    .accept(DOCS_ALPN, docs)
    .spawn();
```

- `Docs::persistent(path)` 把 replica 存到 `path/docs.redb`,author 存到 `path/default-author`。**需开启 `fs-store` feature。**
- `Docs` Deref 到 `DocsApi`,文档级操作在返回的 `Doc` 上。

## DocsApi(crate::api)

| 方法 | 签名 | 用途 |
|---|---|---|
| `author_create()` | `-> Result<AuthorId>` | 本设备签名身份 |
| `create()` | `-> Result<Doc>` | 新建收件箱文档 |
| `import(ticket)` | `(DocTicket) -> Result<Doc>` | 新设备凭 ticket 加入 |
| `import_and_subscribe(...)` | | 加入并直接订阅 |

## Doc(单文档操作)

| 方法 | 签名 | 映射到 inbox |
|---|---|---|
| `set_bytes` | `(AuthorId, key: impl Into<Bytes>, value: impl Into<Bytes>) -> Result<Hash>` | 写 `msg/<id>` / `state/<id>` / `data/<id>/<path>` |
| `get_exact` | `(AuthorId, key, include_empty) -> Result<Option<Entry>>` | 按 author+key 精确读 |
| `get_one` | `(query: impl Into<Query>) -> Result<Option<Entry>>` | 读单条 |
| `get_many` | `(query) -> Result<impl Stream<Item=Result<Entry>>>` | 列出 `state/*` 等前缀 |
| `del` | `(AuthorId, prefix) -> Result<usize>` | 删除(写空 entry) |
| `subscribe` | `() -> Result<impl Stream<Item=Result<LiveEvent>>>` | 实时监听变更 → 推通知 |
| `share` | `(ShareMode, AddrInfoOptions) -> Result<DocTicket>` | 生成配对 ticket(二维码) |
| `start_sync` | `(Vec<EndpointAddr>) -> Result<()>` | 与 peers 同步 |
| `leave` | `() -> Result<()>` | 停止 live sync |

## 关键约束:内容在 blobs,不在 replica

`set_bytes` 把 value 存进 **iroh-blobs**,replica 只记 `key → content_hash`。
读卡片 = `Entry.content_hash()` → 从 blobs store 取 bytes → 反序列化。
**所以 docs 持久化(replica/author)与 blobs 内容持久化是两层独立选择**(P2 待决)。

`LiveEvent` 携带变更类型(insert/远端 entry 等);收到 `msg/*` 新 entry → 取内容 → 反序列化 `MessageCard` → 触发系统通知。
