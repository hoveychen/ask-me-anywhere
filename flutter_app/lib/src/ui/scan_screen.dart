// Camera QR scanner for pairing: point it at another device's PairingScreen QR,
// it reads the ticket string and pops it back to the JoinScreen, which joins.
// The "scan" half of M3c pairing, landed on Android in M4 P4. mobile_scanner
// handles the camera + runtime permission.
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

/// The first non-empty barcode raw value, trimmed — the scanned ticket. Pure so
/// it can be unit-tested without a camera.
String? firstTicket(Iterable<String?> rawValues) {
  for (final String? value in rawValues) {
    if (value != null && value.trim().isNotEmpty) return value.trim();
  }
  return null;
}

class ScanScreen extends StatefulWidget {
  const ScanScreen({super.key});

  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> {
  final MobileScannerController _controller = MobileScannerController();
  bool _handled = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_handled) return;
    final String? ticket = firstTicket(capture.barcodes.map((b) => b.rawValue));
    if (ticket == null) return;
    _handled = true; // ignore further frames; pop the ticket back to JoinScreen
    Navigator.of(context).pop(ticket);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('扫码加入 · scan to join')),
      body: MobileScanner(controller: _controller, onDetect: _onDetect),
    );
  }
}
