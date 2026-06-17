// First-run onboarding: a short, swipeable intro that explains the mental model
// (a private, server-less inbox that lives on your devices) and how cards get
// in (a connected source pushes over P2P) — then drops the user into the inbox,
// where the empty-state "Connect a source" prompt picks up the thread.
//
// Pure presentation + a single [onDone] callback; the host ([AppGate]) owns the
// marker write and the transition to the real shell.
import 'package:flutter/material.dart';

class _Page {
  const _Page({required this.icon, required this.title, required this.body});
  final IconData icon;
  final String title;
  final String body;
}

const List<_Page> _pages = [
  _Page(
    icon: Icons.lock_outline,
    title: 'Your private inbox',
    body:
        'ask-me-anywhere is a server-less inbox that lives only on your own '
        'devices. There is no account and no cloud — messages are never stored '
        'on anyone else\'s server.',
  ),
  _Page(
    icon: Icons.sync_alt,
    title: 'Cards sync over P2P',
    body:
        'Pair your devices and they share one inbox: a card you act on or '
        'dismiss on one device updates everywhere, peer-to-peer and end-to-end '
        'encrypted, even across networks.',
  ),
  _Page(
    icon: Icons.cable,
    title: 'Connect a source',
    body:
        'Cards arrive from a source you connect — another device, or a webhook '
        'bridge (ama serve) wired to your scripts, CI, or GitHub. Next you\'ll '
        'see your inbox; use "Connect a source" there to get started.',
  ),
];

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key, required this.onDone});

  /// Called when the user finishes the last page or taps Skip.
  final VoidCallback onDone;

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final PageController _controller = PageController();
  int _index = 0;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  bool get _isLast => _index == _pages.length - 1;

  void _next() {
    if (_isLast) {
      widget.onDone();
    } else {
      _controller.nextPage(
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOut,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: widget.onDone,
                child: const Text('Skip'),
              ),
            ),
            Expanded(
              child: PageView.builder(
                controller: _controller,
                itemCount: _pages.length,
                onPageChanged: (i) => setState(() => _index = i),
                itemBuilder: (context, i) {
                  final _Page page = _pages[i];
                  return Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 420),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 32),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(page.icon,
                                size: 72, color: theme.colorScheme.primary),
                            const SizedBox(height: 28),
                            Text(page.title,
                                textAlign: TextAlign.center,
                                style: theme.textTheme.headlineSmall),
                            const SizedBox(height: 16),
                            Text(page.body,
                                textAlign: TextAlign.center,
                                style: theme.textTheme.bodyLarge?.copyWith(
                                    color: theme.colorScheme.onSurfaceVariant)),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(24),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: List.generate(_pages.length, (i) {
                      final bool active = i == _index;
                      return AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        margin: const EdgeInsets.only(right: 8),
                        width: active ? 22 : 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: active
                              ? theme.colorScheme.primary
                              : theme.colorScheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(4),
                        ),
                      );
                    }),
                  ),
                  FilledButton(
                    onPressed: _next,
                    child: Text(_isLast ? 'Get started' : 'Next'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
