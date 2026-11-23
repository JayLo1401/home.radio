import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/remote_keys.dart';

/// Einstellungen → Tasten der Fernbedienung: which key does what - e.g. when
/// ☰ does something else on the remote (a key mapper app).
class RemoteKeysSettingsScreen extends ConsumerWidget {
  const RemoteKeysSettingsScreen({super.key});

  Future<void> _assign(BuildContext context, WidgetRef ref, RemoteAction action) async {
    final key = await showDialog<LogicalKeyboardKey>(context: context, builder: (_) => _KeyCatcher(action: action));
    if (key == null) return;
    await ref.read(remoteKeysProvider.notifier).assign(action, key);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final keys = ref.watch(remoteKeysProvider);
    const help = TextStyle(color: Colors.white60, fontSize: 14);
    return Scaffold(
      appBar: AppBar(title: const Text('Tasten der Fernbedienung')),
      body: FocusTraversalGroup(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const Text(
              'Eine Aktion wählen und dann die Taste drücken, die sie auslösen soll - sie ersetzt die bisherigen '
              'Tasten der Aktion. So bleibt z. B. ☰ frei, wenn sie auf der Fernbedienung etwas anderes tut. '
              'Pfeiltasten, Zurück und Home lassen sich nicht belegen.',
              style: help,
            ),
            const SizedBox(height: 12),
            for (final (i, action) in RemoteAction.values.indexed)
              ListTile(
                autofocus: i == 0,
                leading: const Icon(Icons.keyboard_outlined),
                title: Text(action.label),
                subtitle: Text(
                  keys.keysOf(action).isEmpty
                      ? 'keine Taste'
                      : keys.keysOf(action).map(remoteKeyLabel).join(', ') + (keys.isCustom(action) ? '' : '  (Standard)'),
                ),
                focusColor: Theme.of(context).colorScheme.primary.withValues(alpha: 0.35),
                trailing: keys.isCustom(action)
                    ? IconButton(
                        tooltip: 'Standard',
                        icon: const Icon(Icons.restart_alt),
                        onPressed: () => ref.read(remoteKeysProvider.notifier).reset(action),
                      )
                    : null,
                onTap: () => _assign(context, ref, action),
                onLongPress: () => ref.read(remoteKeysProvider.notifier).reset(action),
              ),
            const SizedBox(height: 8),
            const Text('Langer Druck auf OK bei einer Aktion: wieder die Standard-Tasten.', style: help),
          ],
        ),
      ),
    );
  }
}

/// "Taste drücken …": takes the next key (Back/Esc cancels).
class _KeyCatcher extends StatefulWidget {
  const _KeyCatcher({required this.action});

  final RemoteAction action;

  @override
  State<_KeyCatcher> createState() => _KeyCatcherState();
}

class _KeyCatcherState extends State<_KeyCatcher> {
  String? _refused;

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.handled;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape || key == LogicalKeyboardKey.goBack || key == LogicalKeyboardKey.browserBack) {
      Navigator.of(context).pop();
      return KeyEventResult.handled;
    }
    if (unassignableKeys.contains(key)) {
      setState(() => _refused = '${remoteKeyLabel(key)} lässt sich nicht belegen.');
      return KeyEventResult.handled;
    }
    Navigator.of(context).pop(key);
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      autofocus: true,
      onKeyEvent: _onKey,
      child: AlertDialog(
        title: Text(widget.action.label),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.keyboard, size: 48),
            const SizedBox(height: 12),
            const Text('Jetzt die Taste drücken …', style: TextStyle(fontSize: 18)),
            const SizedBox(height: 6),
            Text(_refused ?? 'Zurück bricht ab.', style: const TextStyle(color: Colors.white60)),
          ],
        ),
      ),
    );
  }
}
