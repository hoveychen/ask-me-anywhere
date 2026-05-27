// ask-me-anywhere — Flutter macOS shell (M3a).
//
// Boots an in-memory inbox via the FRB bridge to ama-core, renders the local
// cards in a list, and exposes a debug "Push test card" FAB so we can see
// cards appear without wiring a real source yet. M3b/c will replace the FAB
// with real A2UI rendering, dismiss/action, QR pairing, and native notifs.
import 'package:flutter/material.dart';

import 'package:flutter_app/src/rust/api/inbox.dart';
import 'package:flutter_app/src/rust/frb_generated.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await RustLib.init();
  runApp(const AmaApp());
}

class AmaApp extends StatelessWidget {
  const AmaApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ask-me-anywhere',
      theme: ThemeData(brightness: Brightness.dark, useMaterial3: true),
      home: const InboxView(),
    );
  }
}

class InboxView extends StatefulWidget {
  const InboxView({super.key});

  @override
  State<InboxView> createState() => _InboxViewState();
}

class _InboxViewState extends State<InboxView> {
  InboxHandle? _inbox;
  List<CardView> _cards = const [];
  Object? _error;
  bool _booting = true;
  // Cycle a few representative summaries for the debug FAB.
  static const _samples = [
    'Deploy production?',
    'Approve PR #42',
    'Lunch time',
    'Run the migration?',
  ];

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    try {
      final inbox = await InboxHandle.create(device: 'desktop');
      _inbox = inbox;
      await _refresh();
    } catch (e) {
      setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _booting = false);
    }
  }

  Future<void> _refresh() async {
    final inbox = _inbox;
    if (inbox == null) return;
    final cards = await inbox.listMessages();
    if (!mounted) return;
    setState(() => _cards = cards);
  }

  Future<void> _pushDebugCard() async {
    final inbox = _inbox;
    if (inbox == null) return;
    final summary = _samples[_cards.length % _samples.length];
    await inbox.push(summary: summary, a2UiJson: '{}');
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('ask-me-anywhere · inbox'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
            onPressed: _inbox != null ? _refresh : null,
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _inbox != null ? _pushDebugCard : null,
        icon: const Icon(Icons.add),
        label: const Text('Push test card'),
      ),
      body: _booting
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(child: Text('boot failed: $_error'))
              : _cards.isEmpty
                  ? const Center(
                      child: Text(
                        '(no cards yet — press the button)',
                        style: TextStyle(fontStyle: FontStyle.italic),
                      ),
                    )
                  : ListView.builder(
                      itemCount: _cards.length,
                      itemBuilder: (_, i) => _CardTile(_cards[i]),
                    ),
    );
  }
}

class _CardTile extends StatelessWidget {
  final CardView card;
  const _CardTile(this.card);

  @override
  Widget build(BuildContext context) {
    final created =
        DateTime.fromMillisecondsSinceEpoch(card.createdAt.toInt()).toLocal();
    return ListTile(
      leading: CircleAvatar(child: Icon(_iconForStatus(card.status))),
      title: Text(card.summary),
      subtitle: Text(
        '${_formatTime(created)} · ${card.source} · ${card.status.name}',
      ),
      trailing: Text(
        card.id.length > 8 ? card.id.substring(0, 8) : card.id,
        style: const TextStyle(fontFamily: 'monospace'),
      ),
    );
  }

  IconData _iconForStatus(CardStatus s) {
    switch (s) {
      case CardStatus.unread:
        return Icons.mark_email_unread;
      case CardStatus.dismissed:
        return Icons.done;
      case CardStatus.actioned:
        return Icons.check_circle;
    }
  }

  String _formatTime(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
}
