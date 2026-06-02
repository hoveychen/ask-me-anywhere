// The red-dot "unread count" surface, abstracted so the controller can push the
// count without knowing which platform renders it. macOS sets the Dock tile
// badge (P3); Android draws it on the overlay bubble (P4); every other platform
// (and tests) gets the no-op.
abstract class BadgeSink {
  void setBadge(int count);
}

/// No badge surface — web / iOS / Windows / Linux, and unit tests.
class NoopBadgeSink implements BadgeSink {
  const NoopBadgeSink();

  @override
  void setBadge(int count) {}
}
