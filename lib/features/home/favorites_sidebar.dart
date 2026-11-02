import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../core/ok_long_press.dart';
import '../../core/retrying_network_image.dart';
import '../../core/theme.dart';
import '../../data/db/database.dart' show DabStation, FmStation;
import '../../data/models/favorite_channel.dart';
import '../../data/repositories/dab_stations_repository.dart' show DabStationDisplay, dabEnsembleHeading;
import '../../data/repositories/fm_stations_repository.dart' show FmStationDisplay, sameProgrammeHint;
import '../../data/repositories/settings_repository.dart' show DabSortMode, ReceiverMode;
import '../shared/station_edit_dialog.dart';

/// Categorized, scrollable list of stations shown on the right edge of the
/// home screen: "Favoriten" (favorites sorted by program number) and
/// "DAB-Sender" (every DAB+ station ever found by a scan - see
/// DabStationsRepository - playable directly without being a favorite).
/// Navigable with D-Pad up/down; OK/Enter tunes the station.
class FavoritesSidebar extends ConsumerStatefulWidget {
  final void Function(FavoriteChannel channel) onSelect;
  final void Function(DabStation station) onSelectDabStation;
  final void Function(FmStation station) onSelectFmStation;

  /// After "Sender bearbeiten" closed - it may have tuned the receiver
  /// away (fetching a DAB+ logo), see HomeScreen._afterReceiverScreen.
  final VoidCallback? onEditDone;

  const FavoritesSidebar({
    super.key,
    required this.onSelect,
    required this.onSelectDabStation,
    required this.onSelectFmStation,
    this.onEditDone,
  });

  @override
  ConsumerState<FavoritesSidebar> createState() => _FavoritesSidebarState();
}

class _FavoritesSidebarState extends ConsumerState<FavoritesSidebar> {
  /// Favorites edit mode: rows get move/rename/remove buttons instead of
  /// playing on OK - replaces the former "Favoriten verwalten" settings list.
  bool _editing = false;

  @override
  Widget build(BuildContext context) {
    final currentProgramNumber = ref.watch(currentProgramNumberProvider);
    final currentDabStation = ref.watch(currentDabStationProvider);
    // Shared with HomeScreen's remote-control channel-up/down handling - see
    // that provider's own doc comment for why the category lives there
    // instead of as this widget's own private State.
    final category = ref.watch(effectiveSidebarCategoryProvider);
    final hasDab = ref.watch(receiverModeProvider) != ReceiverMode.none;
    final editing = _editing && category == SidebarCategory.favorites;

    return Container(
      width: 380,
      color: Colors.black,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
            child: Row(
              children: [
                // The heart and, while it's the open tab, its pencil share one
                // outline - so the pencil clearly edits the favorites.
                Expanded(
                  child: Container(
                    decoration: category == SidebarCategory.favorites
                        ? BoxDecoration(
                            border: Border.all(color: Colors.white24),
                            borderRadius: BorderRadius.circular(12),
                          )
                        : null,
                    child: Row(
                      children: [
                        Expanded(
                          child: _CategoryTab(
                            icon: Icons.favorite,
                            label: 'Favoriten',
                            selected: category == SidebarCategory.favorites,
                            onTap: () => ref.read(sidebarCategoryProvider.notifier).set(SidebarCategory.favorites),
                          ),
                        ),
                        if (category == SidebarCategory.favorites)
                          _SmallIconButton(
                            icon: editing ? Icons.check : Icons.edit_outlined,
                            tooltip: editing ? 'Fertig' : 'Favoriten bearbeiten',
                            highlighted: editing,
                            onTap: () => setState(() => _editing = !_editing),
                          ),
                      ],
                    ),
                  ),
                ),
                if (hasDab)
                  for (final (tab, label) in const [
                    (SidebarCategory.dabStations, 'DAB+'),
                    (SidebarCategory.fmStations, 'FM'),
                  ]) ...[
                    const SizedBox(width: 8),
                    Expanded(
                      child: _CategoryTab(
                        label: label,
                        selected: category == tab,
                        onTap: () {
                          setState(() => _editing = false);
                          ref.read(sidebarCategoryProvider.notifier).set(tab);
                        },
                      ),
                    ),
                  ],
              ],
            ),
          ),
          if (editing)
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 4, 16, 0),
              child: Text(
                'Reihenfolge ändern, umbenennen oder entfernen - mit ✓ fertig.',
                style: TextStyle(color: Colors.white54, fontSize: 12),
              ),
            ),
          Expanded(
            child: switch (category) {
              SidebarCategory.favorites => _FavoritesList(
                onEditDone: widget.onEditDone,
                currentProgramNumber: currentProgramNumber,
                onSelect: widget.onSelect,
                editing: editing,
              ),
              SidebarCategory.dabStations => _DabStationsList(
                onEditDone: widget.onEditDone,
                currentDabStation: currentDabStation,
                onSelect: widget.onSelectDabStation,
              ),
              SidebarCategory.fmStations => _FmStationsList(
                onEditDone: widget.onEditDone,
                currentFreqKhz: ref.watch(currentFmStationProvider),
                onSelect: widget.onSelectFmStation,
              ),
            },
          ),
        ],
      ),
    );
  }
}

class _CategoryTab extends StatefulWidget {
  /// With an [icon], [label] is only its tooltip (e.g. the heart for
  /// "Favoriten" - keeps the tabs narrow enough for three).
  final IconData? icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _CategoryTab({this.icon, required this.label, required this.selected, required this.onTap});

  @override
  State<_CategoryTab> createState() => _CategoryTabState();
}

class _CategoryTabState extends State<_CategoryTab> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    return TvFocusHighlight(
      focused: _focused,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        focusColor: Colors.transparent,
        onFocusChange: (v) => setState(() => _focused = v),
        onTap: widget.onTap,
        child: Container(
          decoration: BoxDecoration(
            color: widget.selected
                ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.25)
                : Colors.white.withValues(alpha: 0.04),
            borderRadius: BorderRadius.circular(10),
          ),
          padding: const EdgeInsets.symmetric(vertical: 10),
          alignment: Alignment.center,
          child: widget.icon != null
              ? Tooltip(
                  message: widget.label,
                  child: Icon(
                    widget.icon,
                    size: 18,
                    color: widget.selected ? Colors.redAccent.shade100 : Colors.white70,
                  ),
                )
              : Text(
                  widget.label,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: widget.selected ? FontWeight.bold : FontWeight.normal,
                  ),
                ),
        ),
      ),
    );
  }
}

class _FavoritesList extends ConsumerWidget {
  final VoidCallback? onEditDone;
  final int? currentProgramNumber;
  final void Function(FavoriteChannel channel) onSelect;
  final bool editing;

  const _FavoritesList({
    this.onEditDone,
    required this.currentProgramNumber,
    required this.onSelect,
    this.editing = false,
  });

  /// Identifies a favorite independently of its program number, which
  /// changes when it's moved - so a row (and the focused button in it)
  /// moves along with its favorite instead of staying at the old position.
  static String _stableKey(FavoriteChannel c) =>
      '${c.sourceTypeKey}:${c.internetStreamUrl ?? '${c.dabFreqKhz}/${c.dabServiceId}'}';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final favoritesAsync = ref.watch(favoritesStreamProvider);
    return favoritesAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(
        child: Text('Fehler beim Laden der Favoriten:\n$e', style: const TextStyle(color: Colors.white70)),
      ),
      data: (favorites) {
        if (favorites.isEmpty) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'Noch keine Favoriten.\nSuche Sender über das Menü.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white70, fontSize: 18),
              ),
            ),
          );
        }
        if (editing) {
          final repo = ref.read(favoritesRepositoryProvider);
          return Scrollbar(
            thumbVisibility: true,
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(vertical: 12),
              itemCount: favorites.length,
              findChildIndexCallback: (key) {
                final i = favorites.indexWhere((c) => ValueKey(_stableKey(c)) == key);
                return i < 0 ? null : i;
              },
              itemBuilder: (context, index) {
                final channel = favorites[index];
                return _EditableFavoriteRow(
                  key: ValueKey(_stableKey(channel)),
                  channel: channel,
                  onMoveUp: index == 0
                      ? null
                      : () => repo.swapProgramNumbers(channel.programNumber, favorites[index - 1].programNumber),
                  onMoveDown: index == favorites.length - 1
                      ? null
                      : () => repo.swapProgramNumbers(channel.programNumber, favorites[index + 1].programNumber),
                  onRename: () => _thenDone(onEditDone, editFavorite(context, ref, channel)),
                  onRemove: () async {
                    final confirmed = await showDialog<bool>(
                      context: context,
                      builder: (context) => AlertDialog(
                        title: const Text('Favorit entfernen?'),
                        content: Text('„${channel.displayName}“ aus den Favoriten entfernen?'),
                        actions: [
                          TextButton(
                            autofocus: true,
                            onPressed: () => Navigator.of(context).pop(false),
                            child: const Text('Abbrechen'),
                          ),
                          TextButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Entfernen')),
                        ],
                      ),
                    );
                    if (confirmed == true) await repo.remove(channel.programNumber);
                  },
                );
              },
            ),
          );
        }
        return Scrollbar(
          thumbVisibility: true,
          child: ListView.builder(
            padding: const EdgeInsets.symmetric(vertical: 12),
            itemCount: favorites.length,
            itemBuilder: (context, index) {
              final channel = favorites[index];
              final isCurrent = channel.programNumber == currentProgramNumber;
              return _FavoriteRow(
                channel: channel,
                isCurrent: isCurrent,
                onSelect: () => onSelect(channel),
                // The playing station also offers its current broadcast image.
                onLongPress: () => _thenDone(
                  onEditDone,
                  editFavorite(
                    context,
                    ref,
                    channel,
                    liveImagePath: isCurrent ? ref.read(liveStationImageProvider) : null,
                  ),
                ),
              );
            },
          ),
        );
      },
    );
  }
}

class _SourceBadge extends StatelessWidget {
  final String text;
  const _SourceBadge(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(color: Colors.white38, fontSize: 11, fontWeight: FontWeight.bold),
    );
  }
}

/// The sidebar's FM tab: every saved FM station, by frequency.
class _FmStationsList extends ConsumerWidget {
  final VoidCallback? onEditDone;
  final int? currentFreqKhz;
  final void Function(FmStation station) onSelect;

  const _FmStationsList({this.onEditDone, required this.currentFreqKhz, required this.onSelect});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // By frequency; a programme also on another frequency says so.
    final stations = ref.watch(fmStationsStreamProvider).value ?? const <FmStation>[];
    if (stations.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Noch keine UKW-Sender.\nSuchlauf oder manuelles Einstellen über das UKW-Menü oben.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white70, fontSize: 18),
          ),
        ),
      );
    }
    return Scrollbar(
      thumbVisibility: true,
      child: ListView.builder(
        padding: const EdgeInsets.symmetric(vertical: 12),
        itemCount: stations.length,
        itemBuilder: (context, index) {
          final s = stations[index];
          return _StationRow(
            title: s.displayLabel,
            // The frequency (unless that's already the title), and whether
            // the programme is on another frequency too (see the FM screen).
            subtitle: [
              if (s.displayLabel != s.frequencyLabel) s.frequencyLabel,
              ?sameProgrammeHint(s, stations),
            ].join(' · ').ifNotEmpty,
            logoLocalPath: s.logoLocalPath,
            logoUrl: s.logoUrl,
            isCurrent: s.freqKhz == currentFreqKhz,
            onSelect: () => onSelect(s),
            onLongPress: () => _thenDone(onEditDone, editFmStation(context, ref, s)),
          );
        },
      ),
    );
  }
}

extension on String {
  String? get ifNotEmpty => isEmpty ? null : this;
}

class _DabStationsList extends ConsumerWidget {
  final VoidCallback? onEditDone;
  final ({int freqKhz, int serviceId})? currentDabStation;
  final void Function(DabStation station) onSelect;

  const _DabStationsList({this.onEditDone, required this.currentDabStation, required this.onSelect});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final stationsAsync = ref.watch(sortedDabStationsProvider);
    return stationsAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(
        child: Text('Fehler beim Laden der DAB+ Sender:\n$e', style: const TextStyle(color: Colors.white70)),
      ),
      data: (stations) {
        if (stations.isEmpty) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'Noch keine DAB+ Sender gefunden.\nSendersuchlauf über das DAB-Menü starten.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white70, fontSize: 18),
              ),
            ),
          );
        }
        final current = currentDabStation;
        // Grouped: a (non-focusable) heading before each ensemble's stations.
        final grouped = ref.watch(dabSortModeProvider) == DabSortMode.groupedByEnsemble;
        final entries = <Object>[];
        String? lastHeading;
        for (final s in stations) {
          final heading = dabEnsembleHeading(s);
          if (grouped && heading != lastHeading) entries.add(heading);
          lastHeading = heading;
          entries.add(s);
        }
        return Scrollbar(
          thumbVisibility: true,
          child: ListView.builder(
            padding: const EdgeInsets.symmetric(vertical: 12),
            itemCount: entries.length,
            itemBuilder: (context, index) {
              final entry = entries[index];
              if (entry is String) {
                return Padding(
                  padding: EdgeInsets.fromLTRB(16, index == 0 ? 4 : 16, 16, 4),
                  child: Text(
                    entry,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white54, fontSize: 13, fontWeight: FontWeight.bold),
                  ),
                );
              }
              final station = entry as DabStation;
              final isCurrent =
                  current != null && current.freqKhz == station.freqKhz && current.serviceId == station.serviceId;
              return _StationRow(
                title: station.displayLabel,
                // The heading already names the ensemble.
                subtitle: grouped ? null : dabEnsembleHeading(station),
                logoLocalPath: station.logoLocalPath,
                logoUrl: station.logoUrl,
                isCurrent: isCurrent,
                onSelect: () => onSelect(station),
                onLongPress: () => _thenDone(
                  onEditDone,
                  editDabStation(
                    context,
                    ref,
                    station,
                    liveImagePath: isCurrent ? ref.read(liveStationImageProvider) : null,
                  ),
                ),
              );
            },
          ),
        );
      },
    );
  }
}

/// A station in the DAB+ or FM tab: logo, name and a small second line
/// (ensemble or frequency), playing on OK.
class _StationRow extends StatefulWidget {
  final String title;
  final String? subtitle;
  final String? logoLocalPath;
  final String? logoUrl;
  final bool isCurrent;
  final VoidCallback onSelect;

  /// Long press / OK held: "Sender bearbeiten".
  final VoidCallback? onLongPress;

  const _StationRow({
    required this.title,
    this.subtitle,
    this.logoLocalPath,
    this.logoUrl,
    required this.isCurrent,
    required this.onSelect,
    this.onLongPress,
  });

  @override
  State<_StationRow> createState() => _StationRowState();
}

class _StationRowState extends State<_StationRow> {
  bool _focused = false;
  final _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    if (widget.isCurrent) _claimFocus();
  }

  @override
  void didUpdateWidget(covariant _StationRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Not just the initial-mount case (e.g. right after autostart, or after
    // this tab was just opened for it - see _FavoritesSidebarState): a
    // remote's next/previous-station keys (see HomeScreen's key handling)
    // change which station is playing while this same row stays mounted,
    // so isCurrent flips on an *existing* widget - a mount-time-only
    // mechanism like `autofocus` never sees that. Guarded on the actual
    // false->true transition so an unrelated rebuild (isCurrent already
    // true, e.g. a station-list refresh) doesn't keep re-stealing focus.
    if (widget.isCurrent && !oldWidget.isCurrent) _claimFocus();
  }

  void _claimFocus() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _focusNode.requestFocus();
      Scrollable.ensureVisible(context, alignment: 0.5);
    });
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      child: TvFocusHighlight(
        focused: _focused,
        child: OkLongPress(
          onTap: widget.onSelect,
          onLongPress: widget.onLongPress,
          child: InkWell(
            focusNode: _focusNode,
            borderRadius: BorderRadius.circular(12),
            focusColor: Colors.transparent,
            onFocusChange: (v) => setState(() => _focused = v),
            onTap: widget.onSelect,
            onLongPress: widget.onLongPress,
            child: Container(
              decoration: BoxDecoration(
                color: widget.isCurrent
                    ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.25)
                    : Colors.white.withValues(alpha: 0.04),
                borderRadius: BorderRadius.circular(12),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(
                children: [
                  Padding(
                    padding: const EdgeInsets.only(right: 10),
                    child: _Logo(logoLocalPath: widget.logoLocalPath, logoUrl: widget.logoUrl),
                  ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 17,
                            fontWeight: widget.isCurrent ? FontWeight.bold : FontWeight.normal,
                          ),
                        ),
                        if (widget.subtitle case final subtitle?)
                          Text(
                            subtitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
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
      ),
    );
  }
}

class _FavoriteRow extends StatefulWidget {
  final FavoriteChannel channel;
  final bool isCurrent;
  final VoidCallback onSelect;

  /// Long press / OK held: "Sender bearbeiten".
  final VoidCallback? onLongPress;

  const _FavoriteRow({required this.channel, required this.isCurrent, required this.onSelect, this.onLongPress});

  @override
  State<_FavoriteRow> createState() => _FavoriteRowState();
}

class _FavoriteRowState extends State<_FavoriteRow> {
  bool _focused = false;
  final _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    if (widget.isCurrent) _claimFocus();
  }

  @override
  void didUpdateWidget(covariant _FavoriteRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    // See _DabStationRowState.didUpdateWidget for why this - not just
    // initState - is needed.
    if (widget.isCurrent && !oldWidget.isCurrent) _claimFocus();
  }

  void _claimFocus() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _focusNode.requestFocus();
      Scrollable.ensureVisible(context, alignment: 0.5);
    });
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final channel = widget.channel;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      child: TvFocusHighlight(
        focused: _focused,
        child: OkLongPress(
          onTap: widget.onSelect,
          onLongPress: widget.onLongPress,
          child: InkWell(
            focusNode: _focusNode,
            borderRadius: BorderRadius.circular(12),
            focusColor: Colors.transparent,
            onFocusChange: (v) => setState(() => _focused = v),
            onTap: widget.onSelect,
            onLongPress: widget.onLongPress,
            child: Container(
              decoration: BoxDecoration(
                color: widget.isCurrent
                    ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.25)
                    : Colors.white.withValues(alpha: 0.04),
                borderRadius: BorderRadius.circular(12),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(
                children: [
                  SizedBox(
                    width: 32,
                    child: Text(
                      '${channel.programNumber}',
                      style: const TextStyle(color: Colors.white54, fontWeight: FontWeight.bold),
                    ),
                  ),
                  const SizedBox(width: 8),
                  _Logo(logoLocalPath: channel.logoLocalPath, logoUrl: channel.logoUrl),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      channel.displayName,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 17,
                        fontWeight: widget.isCurrent ? FontWeight.bold : FontWeight.normal,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    // Plain and understated: the globe for internet radio, and
                    // the same "DAB+"/"FM" wording as the sidebar tabs.
                    child: switch (channel.sourceType) {
                      FavoriteSourceType.internet => const Icon(Icons.public, size: 18, color: Colors.white38),
                      FavoriteSourceType.dab => const _SourceBadge('DAB+'),
                      FavoriteSourceType.fm => const _SourceBadge('FM'),
                    },
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A favorite in edit mode: program number, logo and name plus buttons to
/// move it up/down (changes its program number), rename or remove it.
/// D-Pad: left/right between the buttons, up/down between rows.
class _EditableFavoriteRow extends StatelessWidget {
  final FavoriteChannel channel;
  final VoidCallback? onMoveUp;
  final VoidCallback? onMoveDown;
  final VoidCallback onRename;
  final VoidCallback onRemove;

  const _EditableFavoriteRow({
    super.key,
    required this.channel,
    required this.onMoveUp,
    required this.onMoveDown,
    required this.onRename,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      child: Container(
        decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.04), borderRadius: BorderRadius.circular(12)),
        padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
        child: Row(
          children: [
            SizedBox(
              width: 26,
              child: Text(
                '${channel.programNumber}',
                style: const TextStyle(color: Colors.white54, fontWeight: FontWeight.bold),
              ),
            ),
            _Logo(logoLocalPath: channel.logoLocalPath, logoUrl: channel.logoUrl),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                channel.displayName,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white, fontSize: 15),
              ),
            ),
            _SmallIconButton(icon: Icons.keyboard_arrow_up, tooltip: 'Nach oben', onTap: onMoveUp),
            _SmallIconButton(icon: Icons.keyboard_arrow_down, tooltip: 'Nach unten', onTap: onMoveDown),
            _SmallIconButton(icon: Icons.edit_outlined, tooltip: 'Bearbeiten (Name, Logo)', onTap: onRename),
            _SmallIconButton(icon: Icons.delete_outline, tooltip: 'Entfernen', onTap: onRemove),
          ],
        ),
      ),
    );
  }
}

/// Compact focusable icon button with the app's TV focus highlight.
class _SmallIconButton extends StatefulWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;
  final bool highlighted;

  const _SmallIconButton({required this.icon, required this.tooltip, required this.onTap, this.highlighted = false});

  @override
  State<_SmallIconButton> createState() => _SmallIconButtonState();
}

class _SmallIconButtonState extends State<_SmallIconButton> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null;
    return Tooltip(
      message: widget.tooltip,
      child: TvFocusHighlight(
        focused: _focused,
        borderRadius: BorderRadius.circular(20),
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          focusColor: Colors.transparent,
          canRequestFocus: enabled,
          onFocusChange: (v) => setState(() => _focused = v),
          onTap: widget.onTap,
          child: Container(
            padding: const EdgeInsets.all(7),
            decoration: widget.highlighted
                ? BoxDecoration(
                    color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.35),
                    borderRadius: BorderRadius.circular(20),
                  )
                : null,
            child: Icon(widget.icon, size: 22, color: enabled ? Colors.white : Colors.white24),
          ),
        ),
      ),
    );
  }
}

class _Logo extends StatelessWidget {
  final String? logoLocalPath;
  final String? logoUrl;
  const _Logo({required this.logoLocalPath, required this.logoUrl});

  @override
  Widget build(BuildContext context) {
    const size = 40.0;
    final localPath = logoLocalPath;
    final url = logoUrl;
    Widget placeholder = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: Colors.white10, borderRadius: BorderRadius.circular(8)),
      child: const Icon(Icons.radio, color: Colors.white38, size: 20),
    );
    if (localPath != null) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Image.file(
          File(localPath),
          width: size,
          height: size,
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) => placeholder,
        ),
      );
    }
    if (url != null) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: RetryingNetworkImage(
          imageUrl: url,
          width: size,
          height: size,
          fit: BoxFit.cover,
          placeholder: (_) => placeholder,
          errorWidget: (_) => placeholder,
        ),
      );
    }
    return placeholder;
  }
}

/// Runs [onDone] once [edit] (a "Sender bearbeiten" dialog) has finished.
Future<void> _thenDone(VoidCallback? onDone, Future<void> edit) async {
  await edit;
  onDone?.call();
}
