# 使用者指南

ask-me-anywhere 是一个**多设备私有收件箱**:你的几台设备(Mac、Android 手机)各自跑一份 Flutter app,它们之间通过 P2P(iroh-doc)同步;任何一台设备收到的卡片、点过的 dismiss、填过的表单,其他设备会立刻看见。**消息不经过任何第三方服务器**,只在你的设备之间流转,中间偶尔过 relay 也只转发加密字节、不解密。

## 1. 第一次跑起来

### 1.1 安装 app

> 当前 M3–M4 阶段:app 还没有正式发布到 App Store / Play Store,得从源码本地构建一次。Mac 和 Android 步骤如下。

**macOS:**
```bash
git clone https://github.com/hoveychen/ask-me-anywhere
cd ask-me-anywhere/flutter_app
flutter run -d macos
```

**Android(真机或模拟器):**
```bash
cd ask-me-anywhere/flutter_app
flutter devices   # 确认手机/模拟器被识别
flutter run -d <device-id>
```

构建第一次会比较慢 —— 因为里面跑了 cargokit 把 Rust 核心交叉编译到 4 个 Android ABI(armv7 / aarch64 / x86_64 / i686)。后续增量编译会快很多。

### 1.2 创建一个收件箱(或加入一个已有的)

App 启动后会展示一个空的收件箱页。右上角有两个图标:

- **QR 二维码**:展示当前设备的"配对 ticket",其他设备扫描后会加入这个收件箱。第一次使用就点这个。
- **加人图标**:加入别的设备已经创建好的收件箱(粘贴 ticket 或扫码)。

第一台设备的典型流程:
1. 启动 app,点右上角的 QR 图标。
2. 二维码会显示出来,旁边有一段长长的 `docaaa...` 字符串(同样的 ticket,粘贴用)。
3. 在第二台设备上,启动 app,点右上角的加人图标 → "Scan QR code"(Android 摄像头扫码)或者把 ticket 文本粘进去。
4. 两台设备同步几秒后,两边的收件箱都会显示对方推过的卡片。

!!! tip "ticket 一次有效,只用来配对"
    ticket 不是密码 —— 它把"加入这个文档"的能力授予出去。一旦两台设备配对了,后面就不需要再用同一个 ticket。把它当成"邀请码"用一次就行。如果泄漏出去,有其他设备拿到这个 ticket 也能加入你的收件箱 —— 这种情况下,目前的版本没有踢人功能,建议起一个新的收件箱。

## 2. 日常使用

### 2.1 看卡片

每张消息卡片在列表里显示**摘要 + 来源**;点进去看的是完整的 A2UI 卡片渲染(可能有标题、正文、按钮、可填表单)。卡片在所有设备上的渲染一致,因为 A2UI message tree 是不可变的。

### 2.2 dismiss 卡片

在卡片详情页右上角点关闭(或卡片里有自定义的"Dismiss"按钮),卡片状态会同步到所有副本 —— 另一台手机上原来一直亮着的"未读"小红点会消失。

底层语义是 LWW(last-writer-wins):时间戳大的那次操作赢。两台设备同时 dismiss 不会有冲突,都收敛到 `Dismissed`。

### 2.3 action / 表单

A2UI 卡片可以包含 action 按钮(`Button` 组件)和可填字段(`TextField` / `Slider` / `Checkbox` / `Select` / 日期 / 时间等)。

- 点 action 按钮:卡片状态翻到 `Actioned`,action 名字 + context 写入 doc。其他设备同步看到,有时按钮会消失或变成"Approved"等次态。
- 填字段:你打字时,字段内容实时同步;另一台设备的同一卡片字段会刷新出你打的字。两边同时改同一字段时 LWW 收敛。

### 2.4 通知

卡片到达后,系统层会弹原生通知 —— macOS 的通知中心 / Android 的下拉通知栏。通知的标题是卡片的 `summary` 字段。点进通知会跳回 app 的卡片详情页。

Android 后台有一个常驻"前台 Service"在保持 iroh 节点活跃,通知栏会显示一条"ama 正在同步"。把这条划掉会停掉前台 Service,后台同步就会失效;等下次回到前台 app 会再起。

### 2.5 离线 / 重连

- 设备离线时:本地写入(dismiss、action、字段)都正常,只是不会同步给其他副本。
- 设备回到在线:iroh 自动跟其他在线 peer 重新对齐,补齐离线时错过的所有更新(CRDT 自动收敛,顺序无关)。
- 中间夹了一个 [iroh-relay](../ops/index.md#relay-部署):大部分场景下 NAT 兜底走 relay,流量是加密的;relay 看不到内容、也不存储。

## 3. 常见问题 {#3-常见问题}

### 没收到卡片

1. 网络通不通? Android 关掉 VPN / 公司代理试试。
2. relay 通不通? 启动 app 时 iroh 会试着连默认 relay(`relay.muveeai.com` 在自建场景)。Mac 上看 Flutter run 日志;Android 上看 `adb logcat | grep -E "iroh|flutter"`。
3. 另一台设备真在线吗? iroh-doc 走 gossip + sync,两台设备至少一段时间内同时在线才能交换增量。

### 通知没弹

- macOS:第一次推送时系统会弹"是否允许 ask-me-anywhere 发送通知?",拒绝过的话去系统偏好设置 → 通知里改回来。
- Android:第一次推送时系统会问 `POST_NOTIFICATIONS` 权限,允许后再推就有了。再不行去系统设置 → app → 通知里检查。

### 我的二维码扫不上 / 粘贴的 ticket 报"failed"

- ticket 复制时是否漏掉前缀(`docaaa...`)或末尾几个字符?长度通常在 ~170 字符。
- 扫码:对准二维码,光线足够,稳住手 2-3 秒;扫码后会自动 join 并跳回收件箱。
- 报"Failed to establish connection":创建 ticket 那一端的 app 还在吗? 第一次配对时**创建端必须保持在线**,直到第二台设备成功 join 一次。之后两边都可以离线再回来。

### 数据丢了?

CRDT 的 entry 一旦同步进入所有副本就持久了 —— 桌面卸载重装、Android 应用数据清空都会丢本机副本。如果其他设备上还有副本,新装的 app 加入同一个 ticket 后会自动拉回来。**如果所有副本都被清掉了,数据就真没了**(零服务器的代价)。

## 4. 接下来

- 想给别人接入(脚本/CI/webhook)往这个收件箱推卡片? → [集成者指南](../integrator/index.md)
- 想自己跑 relay / webhook? → [运维指南](../ops/index.md)
