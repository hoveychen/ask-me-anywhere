// P3 — JoinScreen: paste a ticket, hit Join, and the host's onJoin runs with the
// trimmed ticket; a failed join surfaces inline instead of throwing.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_app/src/ui/join_screen.dart';

Future<void> _push(WidgetTester tester, JoinScreen screen) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () => Navigator.of(context)
                .push(MaterialPageRoute<void>(builder: (_) => screen)),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('Join passes the trimmed ticket to onJoin and pops', (tester) async {
    String? joined;
    await _push(
      tester,
      JoinScreen(onJoin: (t) async => joined = t),
    );

    await tester.enterText(find.byType(TextField), '  docTICKET123  ');
    await tester.tap(find.text('Join'));
    await tester.pumpAndSettle();

    expect(joined, 'docTICKET123'); // trimmed
    expect(find.byType(JoinScreen), findsNothing); // popped on success
  });

  testWidgets('an empty ticket does not call onJoin', (tester) async {
    var calls = 0;
    await _push(
      tester,
      JoinScreen(onJoin: (t) async => calls++),
    );

    await tester.tap(find.text('Join'));
    await tester.pumpAndSettle();

    expect(calls, 0);
    expect(find.byType(JoinScreen), findsOneWidget); // stays put
  });

  testWidgets('a failed join surfaces the error inline', (tester) async {
    await _push(
      tester,
      JoinScreen(onJoin: (t) async => throw Exception('bad ticket')),
    );

    await tester.enterText(find.byType(TextField), 'garbage');
    await tester.tap(find.text('Join'));
    await tester.pumpAndSettle();

    expect(find.byType(JoinScreen), findsOneWidget); // not popped
    expect(find.textContaining('bad ticket'), findsOneWidget);
  });
}
