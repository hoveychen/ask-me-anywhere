import 'dart:io';

import 'package:flutter_app/src/onboarding/onboarding_gate.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory dir;
  late OnboardingGate gate;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('ama-onboarding-test');
    gate = OnboardingGate(markerDir: () async => dir.path);
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  test('isComplete is false before onboarding, true after markComplete', () async {
    expect(await gate.isComplete(), isFalse);
    await gate.markComplete();
    expect(await gate.isComplete(), isTrue);
  });

  test('markComplete is idempotent', () async {
    await gate.markComplete();
    await gate.markComplete(); // must not throw on an existing marker
    expect(await gate.isComplete(), isTrue);
  });

  test('a fresh dir (different marker path) reads as not complete', () async {
    await gate.markComplete();
    final Directory other =
        Directory.systemTemp.createTempSync('ama-onboarding-test2');
    final OnboardingGate freshGate =
        OnboardingGate(markerDir: () async => other.path);
    expect(await freshGate.isComplete(), isFalse);
    other.deleteSync(recursive: true);
  });
}
