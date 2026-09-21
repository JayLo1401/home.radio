import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../data/db/database.dart' show DabStation;
import '../../data/models/favorite_channel.dart';
import '../../data/repositories/dab_stations_repository.dart' show DabStationDisplay;

/// Categorized, scrollable list of stations shown on the right edge of the
/// home screen: "Favoriten" (favorites sorted by program number) and
/// "DAB-Sender" (every DAB+ station ever found by a scan - see
/// DabStationsRepository - playable directly without being a favorite).
/// Navigable with D-Pad up/down; OK/Enter tunes the station.
class FavoritesSidebar extends ConsumerStatefulWidget {
  final void Function(FavoriteChannel channel) onSelect;
  final void Function(DabStation station) onSelectDabStation;

  const FavoritesSidebar({
    super.key,
    required this.onSelect,
    required this.onSelectDabStation,
  });

  @override
  ConsumerState<FavoritesSidebar> createState() => _FavoritesSidebarState();
}

class _FavoritesSidebarState extends ConsumerState<FavoritesSidebar> {
  @override
  Widget build(BuildContext context) {
    final currentProgramNumber = ref.watch(currentProgramNumberProvider);
    final currentDabStation = ref.watch(currentDabStationProvider);
    // Shared with HomeScreen's remote-control channel-up/down handling - see
    // that provider's own doc comment for why the category lives there
    // instead of as this widget's own private State.
    final category = ref.watch(effectiveSidebarCategoryProvider);

    return Container(
      width: 380,
      color: Colors.black,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
            child: Row(
              children: [
                Expanded(
                  child: _CategoryTab(
                    label: 'Favoriten',
                    selected: category == SidebarCategory.favorites,
                    onTap: () => ref.read(sidebarCategoryProvider.notifier).set(SidebarCategory.favorites),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _CategoryTab(
                    label: 'DAB-Sender',
                    selected: category == SidebarCategory.dabStations,
                    onTap: () => ref.read(sidebarCategoryProvider.notifier).set(SidebarCategory.dabStations),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: category == SidebarCategory.favorites
                ? _FavoritesList(currentProgramNumber: currentProgramNumber, onSelect: widget.onSelect)
                : _DabStationsList(
                    currentDabStation: currentDabStation,
                    onSelect: widget.onSelectDabStation,
                  ),
          ),
        ],
      ),
    );
  }
}

class _CategoryTab extends StatefulWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _CategoryTab({required this.label, required this.selected, required this.onTap});

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
          child: Text(
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
  final int? currentProgramNumber;
  final void Function(FavoriteChannel channel) onSelect;

  const _FavoritesList({required this.currentProgramNumber, required this.onSelect});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final favoritesAsync = ref.watch(favoritesStreamProvider);
    return favoritesAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(
        child: Text('Fehler beim Laden der Favoriten:\n$e',
            style: const TextStyle(color: Colors.white70)),
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
              );
            },
          ),
        );
      },
    );
  }
}

class _DabStationsList extends ConsumerWidget {
  final ({int freqKhz, int serviceId})? currentDabStation;
  final void Function(DabStation station) onSelect;

  const _DabStationsList({required this.currentDabStation, required this.onSelect});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final stationsAsync = ref.watch(sortedDabStationsProvider);
    return stationsAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(
        child: Text('Fehler beim Laden der DAB+ Sender:\n$e',
            style: const TextStyle(color: Colors.white70)),
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
        return Scrollbar(
          thumbVisibility: true,
          child: ListView.builder(
            padding: const EdgeInsets.symmetric(vertical: 12),
            itemCount: stations.length,
            itemBuilder: (context, index) {
              final station = stations[index];
              final isCurrent =
                  current != null && current.freqKhz == station.freqKhz && current.serviceId == station.serviceId;
              return _DabStationRow(
                station: station,
                isCurrent: isCurrent,
                onSelect: () => onSelect(station),
              );
            },
          ),
        );
      },
    );
  }
}

class _DabStationRow extends StatefulWidget {
  final DabStation station;
  final bool isCurrent;
  final VoidCallback onSelect;

  const _DabStationRow({
    required this.station,
    required this.isCurrent,
    required this.onSelect,
  });

  @override
  State<_DabStationRow> createState() => _DabStationRowState();
}

class _DabStationRowState extends State<_DabStationRow> {
  bool _focused = false;
  final _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    if (widget.isCurrent) _claimFocus();
  }

  @override
  void didUpdateWidget(covariant _DabStationRow oldWidget) {
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
    final station = widget.station;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      child: TvFocusHighlight(
        focused: _focused,
        child: InkWell(
          focusNode: _focusNode,
          borderRadius: BorderRadius.circular(12),
          focusColor: Colors.transparent,
          onFocusChange: (v) => setState(() => _focused = v),
          onTap: widget.onSelect,
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
                  child: _Logo(logoLocalPath: station.logoLocalPath, logoUrl: station.logoUrl),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        station.displayLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 17,
                          fontWeight: widget.isCurrent ? FontWeight.bold : FontWeight.normal,
                        ),
                      ),
                      Text(
                        '${station.ensembleLabel ?? "Ensemble unbekannt"} · ${station.channelLabel}',
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
    );
  }
}

class _FavoriteRow extends StatefulWidget {
  final FavoriteChannel channel;
  final bool isCurrent;
  final VoidCallback onSelect;

  const _FavoriteRow({
    required this.channel,
    required this.isCurrent,
    required this.onSelect,
  });

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
        child: InkWell(
          focusNode: _focusNode,
          borderRadius: BorderRadius.circular(12),
          focusColor: Colors.transparent,
          onFocusChange: (v) => setState(() => _focused = v),
          onTap: widget.onSelect,
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
                    style: const TextStyle(
                        color: Colors.white54, fontWeight: FontWeight.bold),
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
                      fontWeight:
                          widget.isCurrent ? FontWeight.bold : FontWeight.normal,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  // Same plain-icon treatment for both, just the icon
                  // differs - matches the globe used for internet radio
                  // instead of standing out as its own filled colour badge.
                  child: Icon(
                    channel.sourceType == FavoriteSourceType.dab ? Icons.radio : Icons.public,
                    size: 18,
                    color: Colors.white38,
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
      decoration: BoxDecoration(
        color: Colors.white10,
        borderRadius: BorderRadius.circular(8),
      ),
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
        child: CachedNetworkImage(
          imageUrl: url,
          width: size,
          height: size,
          fit: BoxFit.cover,
          placeholder: (_, _) => placeholder,
          errorWidget: (_, _, _) => placeholder,
        ),
      );
    }
    return placeholder;
  }
}
