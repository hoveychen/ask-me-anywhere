// P2 — PairingScreen renders the inbox's ticket as a QR code plus a copyable
// text form.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'package:flutter_app/src/ui/pairing_screen.dart';

const _ticket =
    'docabc123def456ghi789jklmnopqrstuvwxyz0123456789abcdef0123456789';

void main() {
  testWidgets('renders a QR code and the copyable ticket text', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: PairingScreen(ticket: _ticket)),
    );
    await tester.pumpAndSettle();

    expect(find.byType(QrImageView), findsOneWidget); // QR rendered
    expect(find.text(_ticket), findsOneWidget); // copyable text form
    expect(find.text('Copy ticket'), findsOneWidget); // copy button label
    expect(find.byIcon(Icons.copy), findsOneWidget);
  });

  testWidgets('copy button writes the ticket to the clipboard', (tester) async {
    String? copied;
    // Intercept the platform clipboard channel.
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
        }
        return null;
      },
    );
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));

    await tester.pumpWidget(
      const MaterialApp(home: PairingScreen(ticket: _ticket)),
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Copy ticket')); // tall screen scrolls
    await tester.tap(find.text('Copy ticket'));
    await tester.pumpAndSettle();

    expect(copied, _ticket);
    expect(find.text('Ticket copied'), findsOneWidget); // confirmation snackbar
  });
}
