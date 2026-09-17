import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../data/models/favorite_channel.dart';
import '../../data/repositories/settings_repository.dart';
import '../rtlsdr/rtl_sdr_test_screen.dart';
import '../shared/rename_dialog.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  AutostartMode _mode = AutostartMode.lastStation;
  int? _fixedProgramNumber;
  bool _weatherEnabled = true;
  bool _radarEnabled = true;
  double _uiScale = 1.0;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final repo = ref.read(settingsRepositoryProvider);
    final mode = await repo.getAutostartMode();
    final fixed = await repo.getFixedProgramNumber();
    final weather = await repo.getWeatherEnabled();
    final radar = await repo.getRadarEnabled();
    final scale = ref.read(uiScaleProvider);
    if (!mounted) return;
    setState(() {
      _mode = mode;
      _fixedProgramNumber = fixed;
      _weatherEnabled = weather;
      _radarEnabled = radar;
      _uiScale = scale;
      _loaded = true;
    });
  }

  Future<void> _changeUiScale(double delta) async {
    final next = (_uiScale + delta).clamp(0.4, 1.4);
    setState(() => _uiScale = next);
    await ref.read(uiScaleProvider.notifier).set(next);
  }

  Future<void> _renameFavorite(FavoriteChannel channel) async {
    final newName = await showDialog<String>(
      context: context,
      builder: (context) => RenameDialog(
        title: 'Favorit umbenennen',
        initialValue: channel.displayName,
      ),
    );
    if (newName == null || newName.isEmpty) return;
    await ref.read(favoritesRepositoryProvider).rename(channel.programNumber, newName);
  }

  @override
  Widget build(BuildContext context) {
    final favorites = ref.watch(favoritesStreamProvider).value ?? const <FavoriteChannel>[];
    final repo = ref.read(settingsRepositoryProvider);

    if (!_loaded) {
      return Scaffold(
        appBar: AppBar(title: const Text('Einstellungen')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    // Explicit traversal order: D-Pad down must reliably move through every
    // control top-to-bottom, regardless of how Flutter would otherwise guess
    // the geometric "nearest" focusable widget.
    var order = 0.0;
    double nextOrder() => order += 1;

    return Scaffold(
      appBar: AppBar(title: const Text('Einstellungen')),
      body: FocusTraversalGroup(
        policy: OrderedTraversalPolicy(),
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text('Autostart', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            FocusTraversalOrder(
              order: NumericFocusOrder(nextOrder()),
              child: _TvChoiceTile(
                label: 'Zuletzt gehörten Sender starten',
                selected: _mode == AutostartMode.lastStation,
                onTap: () async {
                  setState(() => _mode = AutostartMode.lastStation);
                  await repo.setAutostartMode(AutostartMode.lastStation);
                },
              ),
            ),
            FocusTraversalOrder(
              order: NumericFocusOrder(nextOrder()),
              child: _TvChoiceTile(
                label: 'Festen Sender starten',
                selected: _mode == AutostartMode.fixedStation,
                onTap: () async {
                  setState(() => _mode = AutostartMode.fixedStation);
                  await repo.setAutostartMode(AutostartMode.fixedStation);
                },
              ),
            ),
            if (_mode == AutostartMode.fixedStation && favorites.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(left: 16, top: 8),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: favorites.map((c) {
                    return FocusTraversalOrder(
                      order: NumericFocusOrder(nextOrder()),
                      child: _TvChoiceTile(
                        compact: true,
                        label: '${c.programNumber} · ${c.displayName}',
                        selected: _fixedProgramNumber == c.programNumber,
                        onTap: () async {
                          setState(() => _fixedProgramNumber = c.programNumber);
                          await repo.setFixedProgramNumber(c.programNumber);
                        },
                      ),
                    );
                  }).toList(),
                ),
              ),
            const Divider(height: 32),
            Text('Anzeige', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            FocusTraversalOrder(
              order: NumericFocusOrder(nextOrder()),
              child: _TvChoiceTile(
                label: 'Wetterprognose anzeigen',
                selected: _weatherEnabled,
                asToggle: true,
                onTap: () async {
                  final v = !_weatherEnabled;
                  setState(() => _weatherEnabled = v);
                  await repo.setWeatherEnabled(v);
                },
              ),
            ),
            FocusTraversalOrder(
              order: NumericFocusOrder(nextOrder()),
              child: _TvChoiceTile(
                label: 'Regenradar anzeigen',
                selected: _radarEnabled,
                asToggle: true,
                onTap: () async {
                  final v = !_radarEnabled;
                  setState(() => _radarEnabled = v);
                  await repo.setRadarEnabled(v);
                },
              ),
            ),
            const SizedBox(height: 12),
            Text('Größe der Oberfläche', style: Theme.of(context).textTheme.bodyLarge),
            const SizedBox(height: 8),
            Row(
              children: [
                FocusTraversalOrder(
                  order: NumericFocusOrder(nextOrder()),
                  child: _TvIconButton(
                    icon: Icons.remove,
                    onTap: () => _changeUiScale(-0.1),
                  ),
                ),
                SizedBox(
                  width: 90,
                  child: Text(
                    '${(_uiScale * 100).round()} %',
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 18),
                  ),
                ),
                FocusTraversalOrder(
                  order: NumericFocusOrder(nextOrder()),
                  child: _TvIconButton(
                    icon: Icons.add,
                    onTap: () => _changeUiScale(0.1),
                  ),
                ),
              ],
            ),
            const Divider(height: 32),
            Text('Favoriten verwalten', style: Theme.of(context).textTheme.titleLarge),
            const Padding(
              padding: EdgeInsets.only(top: 4, bottom: 4),
              child: Text(
                'Mit den Pfeilen die Reihenfolge (Sendernummer) ändern.',
                style: TextStyle(color: Colors.white54, fontSize: 13),
              ),
            ),
            for (final (index, c) in favorites.indexed)
              FocusTraversalOrder(
                order: NumericFocusOrder(nextOrder()),
                child: ListTile(
                  leading: CircleAvatar(child: Text('${c.programNumber}')),
                  title: Text(c.displayName),
                  subtitle:
                      Text(c.sourceType == FavoriteSourceType.dab ? 'DAB+' : 'Internetradio'),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _TvIconButton(
                        icon: Icons.keyboard_arrow_up,
                        onTap: index == 0
                            ? null
                            : () => ref
                                .read(favoritesRepositoryProvider)
                                .swapProgramNumbers(c.programNumber, favorites[index - 1].programNumber),
                      ),
                      _TvIconButton(
                        icon: Icons.keyboard_arrow_down,
                        onTap: index == favorites.length - 1
                            ? null
                            : () => ref
                                .read(favoritesRepositoryProvider)
                                .swapProgramNumbers(c.programNumber, favorites[index + 1].programNumber),
                      ),
                      _TvIconButton(
                        icon: Icons.edit_outlined,
                        onTap: () => _renameFavorite(c),
                      ),
                      _TvIconButton(
                        icon: Icons.delete_outline,
                        onTap: () => ref.read(favoritesRepositoryProvider).remove(c.programNumber),
                      ),
                    ],
                  ),
                ),
              ),
            const Divider(height: 32),
            Text('Technik', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            FocusTraversalOrder(
              order: NumericFocusOrder(nextOrder()),
              child: _TvChoiceTile(
                label: 'RTL-SDR Test',
                selected: false,
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const RtlSdrTestScreen()),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A plain, fully custom focusable row (no built-in Radio/Switch keyboard
/// handling that would otherwise intercept D-Pad up/down for its own
/// selection logic and block traversal to the next setting).
class _TvChoiceTile extends StatefulWidget {
  final String label;
  final bool selected;
  final bool asToggle;
  final bool compact;
  final VoidCallback onTap;

  const _TvChoiceTile({
    required this.label,
    required this.selected,
    required this.onTap,
    this.asToggle = false,
    this.compact = false,
  });

  @override
  State<_TvChoiceTile> createState() => _TvChoiceTileState();
}

class _TvChoiceTileState extends State<_TvChoiceTile> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final icon = widget.asToggle
        ? (widget.selected ? Icons.toggle_on : Icons.toggle_off)
        : (widget.selected ? Icons.radio_button_checked : Icons.radio_button_off);
    return TvFocusHighlight(
      focused: _focused,
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        // We draw our own focus indicator (TvFocusHighlight's border) below;
        // without this, Material's default focus/hover overlay stacks a
        // second, much brighter wash on top that washes out the text.
        focusColor: Colors.transparent,
        hoverColor: Colors.white.withValues(alpha: 0.04),
        onFocusChange: (v) => setState(() => _focused = v),
        onTap: widget.onTap,
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 12, vertical: widget.compact ? 8 : 12),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                color: widget.selected
                    ? Theme.of(context).colorScheme.primary
                    : Colors.white54,
              ),
              const SizedBox(width: 10),
              Text(
                widget.label,
                style: const TextStyle(fontSize: 16, color: Colors.white),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TvIconButton extends StatefulWidget {
  final IconData icon;
  final VoidCallback? onTap;

  const _TvIconButton({required this.icon, required this.onTap});

  @override
  State<_TvIconButton> createState() => _TvIconButtonState();
}

class _TvIconButtonState extends State<_TvIconButton> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    return TvFocusHighlight(
      focused: _focused,
      borderRadius: BorderRadius.circular(24),
      child: InkWell(
        borderRadius: BorderRadius.circular(24),
        focusColor: Colors.transparent,
        hoverColor: Colors.white.withValues(alpha: 0.04),
        onFocusChange: (v) => setState(() => _focused = v),
        onTap: widget.onTap,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Icon(widget.icon, color: widget.onTap == null ? Colors.white24 : null),
        ),
      ),
    );
  }
}
