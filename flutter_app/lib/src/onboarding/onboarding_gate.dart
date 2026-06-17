// First-run gate: a marker file under the app-support dir records that the user
// has seen the onboarding flow, so it shows exactly once. We use a plain file
// (via path_provider, already a dependency) rather than adding
// shared_preferences — the inbox store already lives in app-support, so a
// sibling marker is the natural, dependency-free signal.
//
// The marker directory is injectable so the gating logic is unit-testable
// without a real app-support dir.
import 'dart:io';

import 'package:path_provider/path_provider.dart';

class OnboardingGate {
  OnboardingGate({Future<String> Function()? markerDir})
      : _resolveDir = markerDir ?? _defaultDir;

  final Future<String> Function() _resolveDir;

  static Future<String> _defaultDir() async =>
      (await getApplicationSupportDirectory()).path;

  Future<File> _markerFile() async =>
      File('${await _resolveDir()}/onboarding-complete');

  /// True once the user has finished (or skipped) onboarding.
  Future<bool> isComplete() async => (await _markerFile()).exists();

  /// Record that onboarding is done, so it never shows again. Idempotent.
  Future<void> markComplete() async {
    final File marker = await _markerFile();
    await marker.create(recursive: true);
  }
}
