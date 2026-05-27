// Shows this inbox's pairing ticket as a QR code (plus a copyable text form) so
// another device can scan it and join — the "display" half of M3c pairing.
//
// FFI-free: it takes the already-resolved ticket string, so the host (InboxView)
// fetches `InboxHandle.ticket()` and pushes this screen. QR codes are rendered
// dark-on-white regardless of app theme so scanners get the contrast they need.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

class PairingScreen extends StatelessWidget {
  const PairingScreen({super.key, required this.ticket});

  /// The serialized pairing ticket (`InboxHandle.ticket()`).
  final String ticket;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('配对 · pair a device')),
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
                  'Scan this code from another device to join this inbox.',
                  style: Theme.of(context).textTheme.bodyMedium,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 20),
                // White card behind the QR for scanner contrast on dark theme.
                Center(
                  child: Container(
                    padding: const EdgeInsets.all(16),
                    color: Colors.white,
                    child: QrImageView(
                      data: ticket,
                      version: QrVersions.auto,
                      size: 280,
                      backgroundColor: Colors.white,
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                Text(
                  'Or copy the ticket and paste it on the other device:',
                  style: Theme.of(context).textTheme.bodySmall,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                SelectableText(
                  ticket,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
                ),
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: ticket));
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Ticket copied')),
                      );
                    }
                  },
                  icon: const Icon(Icons.copy),
                  label: const Text('Copy ticket'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
