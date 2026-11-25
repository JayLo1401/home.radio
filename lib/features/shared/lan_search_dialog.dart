import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../data/services/lan_scan.dart';
import '../../l10n/l10n.dart';

/// One hit of a network search, as the list shows it.
typedef LanSearchRow = ({String title, String subtitle});

/// Searches the home network with [search] and lists what turns up as it
/// is found - OK takes one (returned), Back/"Abbrechen" none. [row] says
/// how a hit reads, [noneFound] what to say if there was nothing.
Future<T?> showLanSearch<T>(
  BuildContext context, {
  required String title,
  required String noneFound,
  required Stream<T> Function(void Function(int done, int total) onProgress) search,
  required LanSearchRow Function(T found) row,
}) =>
    showDialog<T>(
      context: context,
      builder: (_) => _LanSearchDialog<T>(title: title, noneFound: noneFound, search: search, row: row),
    );

class _LanSearchDialog<T> extends StatefulWidget {
  const _LanSearchDialog({required this.title, required this.noneFound, required this.search, required this.row});

  final String title;
  final String noneFound;
  final Stream<T> Function(void Function(int done, int total) onProgress) search;
  final LanSearchRow Function(T found) row;

  @override
  State<_LanSearchDialog<T>> createState() => _LanSearchDialogState<T>();
}

class _LanSearchDialogState<T> extends State<_LanSearchDialog<T>> {
  final _found = <T>[];
  StreamSubscription<T>? _sub;
  List<String> _networks = const [];
  int _done = 0, _total = 0;
  bool _finished = false;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    List<String> networks;
    try {
      networks = await LanScan.localNetworks();
    } catch (_) {
      networks = const [];
    }
    if (!mounted) return;
    setState(() => _networks = networks);
    _sub = widget
        .search((done, total) {
          // Not every address - the bar only needs a few steps.
          if (mounted && (done == total || done % 16 == 0)) {
            setState(() {
              _done = done;
              _total = total;
            });
          }
        })
        .listen(
          (found) {
            if (mounted) setState(() => _found.add(found));
          },
          onError: (Object _) {},
          onDone: () {
            if (mounted) setState(() => _finished = true);
          },
        );
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final searching = !_finished;
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 560,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              searching
                  ? _networks.isEmpty
                      ? l.tvSearchScanning
                      : l.tvSearchScanningNetworks(_networks.map((n) => '$n.x').join(', '))
                  : _found.isEmpty
                      ? widget.noneFound
                      : l.lanSearchFound(_found.length),
              style: const TextStyle(color: Colors.white70),
            ),
            if (searching) ...[
              const SizedBox(height: 12),
              LinearProgressIndicator(value: _total == 0 ? null : _done / _total),
            ],
            const SizedBox(height: 12),
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  children: [
                    for (final (i, found) in _found.indexed)
                      _Row(
                        row: widget.row(found),
                        autofocus: i == 0,
                        onTap: () => Navigator.of(context).pop(found),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          autofocus: true,
          onPressed: () => Navigator.of(context).pop(),
          child: Text(searching ? l.commonCancel : l.commonClose),
        ),
      ],
    );
  }
}

class _Row extends StatefulWidget {
  const _Row({required this.row, required this.onTap, this.autofocus = false});

  final LanSearchRow row;
  final VoidCallback onTap;
  final bool autofocus;

  @override
  State<_Row> createState() => _RowState();
}

class _RowState extends State<_Row> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
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
                const Icon(Icons.lan_outlined, color: brandGreen),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(widget.row.title, style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600)),
                      if (widget.row.subtitle.isNotEmpty)
                        Text(widget.row.subtitle, style: const TextStyle(color: Colors.white60, fontSize: 14)),
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
