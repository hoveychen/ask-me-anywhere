// P1 — the shared surface state machine that drives both platforms' click
// behaviour. Pure transitions, so the rules are pinned here.
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_app/src/state/assistant_surface.dart';

void main() {
  group('onTapIcon', () {
    test('no pending → expand the full inbox list', () {
      expect(AssistantSurface.onTapIcon([]), AssistantSurfaceState.list);
    });

    test('one pending → open that card centred', () {
      final s = AssistantSurface.onTapIcon(['a']);
      expect(s.kind, AssistantSurfaceKind.card);
      expect(s.cardId, 'a');
    });

    test('two or more pending → the picker', () {
      expect(AssistantSurface.onTapIcon(['a', 'b']), AssistantSurfaceState.picker);
      expect(
          AssistantSurface.onTapIcon(['a', 'b', 'c']), AssistantSurfaceState.picker);
    });
  });

  test('onPick opens the chosen card', () {
    final s = AssistantSurface.onPick('b');
    expect(s.kind, AssistantSurfaceKind.card);
    expect(s.cardId, 'b');
  });

  group('onResolveCard works through the queue then collapses', () {
    test('nothing left → icon', () {
      expect(AssistantSurface.onResolveCard([]), AssistantSurfaceState.icon);
    });

    test('one left → open it', () {
      expect(AssistantSurface.onResolveCard(['c']), AssistantSurfaceState.card('c'));
    });

    test('several left → back to picker', () {
      expect(
          AssistantSurface.onResolveCard(['c', 'd']), AssistantSurfaceState.picker);
    });
  });

  test('collapse and open-inbox are fixed targets', () {
    expect(AssistantSurface.onCollapse, AssistantSurfaceState.icon);
    expect(AssistantSurface.onOpenInbox, AssistantSurfaceState.list);
  });

  test('state equality + isExpanded', () {
    expect(AssistantSurfaceState.card('a'), AssistantSurfaceState.card('a'));
    expect(AssistantSurfaceState.card('a') == AssistantSurfaceState.card('b'),
        isFalse);
    expect(AssistantSurfaceState.icon.isExpanded, isFalse);
    expect(AssistantSurfaceState.list.isExpanded, isTrue);
    expect(AssistantSurfaceState.card('a').isExpanded, isTrue);
  });
}
