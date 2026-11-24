import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../data/services/enigma2_discovery.dart';
import '../../l10n/l10n.dart';

/// "Receiver suchen": scans the home network for Enigma2 receivers
/// (OpenWebif) and lists them as they turn up - OK picks one.
Future<FoundReceiver?> showReceiverSearch(BuildContext context) =>
    showDialog<FoundReceiver>(context: context, builder: (_) => const _ReceiverSearchDialog());

class _ReceiverSearchDialog extends StatefulWidget {
  const _ReceiverSearchDialog();

  @override
  State<_ReceiverSearchDialog> createState() => _ReceiverSearchDialogState();
}

class _ReceiverSearchDialogState extends State<_ReceiverSearchDialog> {
  final _discovery = Enigma2Discovery();
  final _found = <FoundReceiver>[];
  StreamSubscription<FoundReceiver>? _sub;
  List<String> _networks = const [];
  int _done = 0, _total = 0;
  bool _finished = false;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    final networks = await Enigma2Discovery.localNetworks();
    if (!mounted) return;
    setState(() => _networks = networks);
    _sub = _discovery
        .scan(
          networks: networks,
          onProgress: (done, total) {
            // Not every address - the bar only needs a few steps.
            if (mounted && (done == total || done % 16 == 0)) {
              setState(() {
                _done = done;
                _total = total;
              });
            }
          },
        )
        .listen(
          (r) => setState(() => _found.add(r)),
          onDone: () {
            if (mounted) setState(() => _finished = true);
          },
        );
  }

  @override
  void dispose() {
    _sub?.cancel();
    _discovery.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final searching = !_finished;
    return AlertDialog(
      title: Text(context.l10n.tvSearchReceiver),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              searching
                  ? _networks.isEmpty
                      ? context.l10n.tvSearchScanning
                      : context.l10n.tvSearchScanningNetworks(_networks.map((n) => '$n.x').join(', '))
                  : _found.isEmpty
                      ? context.l10n.tvSearchNoneFound
                      : context.l10n.tvSearchFound(_found.length),
              style: const TextStyle(color: Colors.white70),
            ),
            if (searching) ...[
              const SizedBox(height: 12),
              LinearProgressIndicator(value: _total == 0 ? null : _done / _total),
            ],
            const SizedBox(height: 12),
            for (final (i, r) in _found.indexed)
              _ReceiverRow(receiver: r, autofocus: i == 0, onTap: () => Navigator.of(context).pop(r)),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(searching ? context.l10n.commonCancel : context.l10n.commonClose),
        ),
      ],
    );
  }
}

class _ReceiverRow extends StatefulWidget {
  const _ReceiverRow({required this.receiver, required this.onTap, this.autofocus = false});

  final FoundReceiver receiver;
  final VoidCallback onTap;
  final bool autofocus;

  @override
  State<_ReceiverRow> createState() => _ReceiverRowState();
}

class _ReceiverRowState extends State<_ReceiverRow> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final r = widget.receiver;
    final name = r.needsLogin
        ? context.l10n.tvReceiverNeedsLogin
        : (r.model.isEmpty ? context.l10n.tvEnigma2Receiver : r.model);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: TvFocusHighlight(
        focused: _focused,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          autofocus: widget.autofocus,
          borderRadius: BorderRadius.circular(8),
          focusColor: Colors.transparent,
          onFocusChange: (v) => setState(() => _focused = v),
          onTap: widget.onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                const Icon(Icons.satellite_alt_outlined),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(name),
                      Text(
                        [r.host, if (r.image.isNotEmpty) r.image].join(' · '),
                        style: const TextStyle(color: Colors.white54, fontSize: 13),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
