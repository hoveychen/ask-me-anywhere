# User Guide

ask-me-anywhere is a **multi-device private inbox**: every device you own (Mac, Android phone) runs a copy of the Flutter app, and they sync peer-to-peer over [iroh-docs](https://docs.rs/iroh-docs). Any card you receive, any dismiss you tap, any form field you fill — every other device sees it within seconds. **No third-party server holds your messages**, only your own devices, and the relay in the middle just forwards encrypted bytes.

## 1. First run

### 1.1 Install the app

> Until the M3–M4 phase ships in App Store / Play Store you build from source.

**macOS:**
```bash
git clone https://github.com/hoveychen/ask-me-anywhere
cd ask-me-anywhere/flutter_app
flutter run -d macos
```

**Android (device or emulator):**
```bash
cd ask-me-anywhere/flutter_app
flutter devices            # confirm the phone / emulator is detected
flutter run -d <device-id>
```

The first build is slow — cargokit cross-compiles the Rust core to four Android ABIs (armv7 / aarch64 / x86_64 / i686). Incremental builds are fast.

### 1.2 Create an inbox (or join an existing one)

The launch screen is an empty inbox list. Two icons sit in the top-right:

- **QR code icon** — shows the current device's *pairing ticket*. Another device can scan or paste it to join this inbox. Tap this on your first device.
- **Add-person icon** — joins an inbox that another device already created (paste the ticket or, on Android, scan its QR).

Typical first-device flow:
1. Launch the app, tap the QR icon.
2. A QR code appears, with the same `docaaa...` ticket printed below for copy/paste.
3. On the second device, launch the app, tap the add-person icon → "Scan QR code" (Android camera) or paste the ticket text.
4. After a few seconds of sync, both devices see the same inbox and any card pushed shows up on both.

!!! tip "The ticket is single-purpose and grants write access"
    The ticket isn't a password — it grants "write access to this document" to whoever holds it. Once two devices are paired, you don't need the same ticket again; treat it as an invite code used once. If it leaks, anyone holding it can join your inbox; there's no kick feature in the current version, so the workaround is to start a fresh inbox.

## 2. Daily use

### 2.1 Reading cards

Each card shows a summary + source in the list. Tapping opens the full A2UI rendering — title, body, buttons, fillable fields, whatever the sender encoded. The rendering is identical across devices because the A2UI message tree is immutable.

### 2.2 Dismissing a card

Tap the close icon on the detail page (or whichever "Dismiss" button the card itself ships). State propagates to every replica — the unread badge on your other phone clears on its own.

The underlying semantics are LWW (last-writer-wins): the larger timestamp wins. Two devices dismissing simultaneously converge cleanly to `Dismissed` either way.

### 2.3 Actions / forms

A2UI cards can carry action buttons (`Button` component) and live inputs (`TextField` / `Slider` / `Checkbox` / `Select` / date / time, …).

- Tapping an action button flips the card to `Actioned`, writes the action name + context to the doc, and the other replicas see it within seconds.
- Typing in a field syncs character-by-character; LWW handles the rare collision when two devices edit the same field at the same time.

### 2.4 Notifications

When a card arrives, the OS layer fires a native notification — macOS Notification Center, Android pull-down. The notification title is the card's `summary` field. Tapping it deeplinks back to the card detail.

On Android a *foreground service* keeps the iroh node alive while the app is backgrounded; you'll see a persistent "ama is syncing" tray entry. Swiping it away kills the service and stops background sync; reopening the app respawns it.

### 2.5 Offline / reconnect

- Offline: local writes (dismiss, action, fields) still work, they just don't propagate.
- Back online: iroh re-aligns with whichever peers are reachable and fills in the gaps. CRDTs converge irrespective of ordering.
- With a [self-hosted iroh-relay](../ops/index.md#relay-deploy) in the middle, NAT-traversal fallback runs over the relay. Traffic stays encrypted; the relay sees ciphertext only and doesn't store anything.

## 3. FAQ

### A card didn't arrive

1. Networking healthy? On Android, disable VPN / corporate proxy and retry.
2. Relay reachable? On launch, iroh tries to register with a relay (`relay.muveeai.com` in the self-hosted setup). On Mac, see the `flutter run` log; on Android, `adb logcat | grep -E "iroh|flutter"`.
3. Both devices online at the same time? iroh-docs uses gossip + sync — for an entry to propagate, the two devices need overlapping online windows.

### No notification popped

- macOS: the first push triggers a system prompt; if you denied it, fix it in System Settings → Notifications → ask-me-anywhere.
- Android: first push triggers the `POST_NOTIFICATIONS` runtime prompt; if denied, fix it in Settings → Apps → ask-me-anywhere → Notifications.

### QR doesn't scan / pasted ticket says "failed"

- Did you grab the full ticket including the `docaaa...` prefix? It's typically ~170 chars.
- Scanning: line up the QR squarely, give it 2–3 seconds, hold steady; on success the app joins and pops back to the inbox.
- "Failed to establish connection": is the *creating* device still online? On first pairing, **the creator must stay online until the second device successfully joins once**. After that, both can come and go.

### Did my data get lost?

A CRDT entry, once synced into every replica, persists per replica — uninstall on desktop or clearing app data on Android drops the local copy. If any other device still has the data, reinstalling the app and joining the same ticket pulls it back. **If you wipe every replica, the data is gone for good** — that's the cost of zero-server.

## 4. Next

- Want to push cards in from a script / CI / webhook? → [Integrator Guide](../integrator/index.md)
- Want to run your own relay or webhook? → [Operator Guide](../ops/index.md)
