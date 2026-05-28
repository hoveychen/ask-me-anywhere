// Join an existing inbox by pasting its pairing ticket, or — on Android — by
// scanning another device's PairingScreen QR (M4 P4). On desktop the natural
// flow is paste; the QR scanner uses the device camera.
//
// FFI-free: it takes an [onJoin] callback the host binds to `InboxHandle.join`.
// While the join runs it shows a spinner; a failure (bad ticket, no peers)
// surfaces inline instead of throwing, and a success pops back to the inbox.
import 'dart:io';

import 'package:flutter/material.dart';

import 'package:flutter_app/src/ui/scan_screen.dart';

class JoinScreen extends StatefulWidget {
  const JoinScreen({super.key, required this.onJoin});

  /// Joins the inbox identified by [ticket]; throws on an invalid ticket or a
  /// failed join.
  final Future<void> Function(String ticket) onJoin;

  @override
  State<JoinScreen> createState() => _JoinScreenState();
}

class _JoinScreenState extends State<JoinScreen> {
  final TextEditingController _controller = TextEditingController();
  bool _joining = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// Open the camera scanner; a scanned ticket fills the field and joins.
  Future<void> _scan() async {
    final String? ticket = await Navigator.of(context).push<String>(
      MaterialPageRoute<String>(builder: (_) => const ScanScreen()),
    );
    if (ticket == null || !mounted) return;
    _controller.text = ticket;
    await _join();
  }

  Future<void> _join() async {
    final String ticket = _controller.text.trim();
    if (ticket.isEmpty || _joining) return;
    setState(() {
      _joining = true;
      _error = null;
    });
    try {
      await widget.onJoin(ticket);
      if (mounted) Navigator.of(context).maybePop();
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _joining = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('加入收件箱 · join an inbox')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Paste a pairing ticket from another device to join its inbox.',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _controller,
                  maxLines: 4,
                  minLines: 2,
                  enabled: !_joining,
                  decoration: InputDecoration(
                    labelText: 'Ticket',
                    border: const OutlineInputBorder(),
                    errorText: _error,
                  ),
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: _joining ? null : _join,
                  icon: _joining
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.login),
                  label: Text(_joining ? 'Joining…' : 'Join'),
                ),
                if (Platform.isAndroid) ...[
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: _joining ? null : _scan,
                    icon: const Icon(Icons.qr_code_scanner),
                    label: const Text('Scan QR code'),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
