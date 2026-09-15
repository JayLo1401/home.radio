import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../data/models/favorite_channel.dart';

/// Scrollable list of favorite stations, shown on the right edge of the
/// home screen. Navigable with D-Pad up/down; OK/Enter tunes the station.
class FavoritesSidebar extends ConsumerWidget {
  final void Function(FavoriteChannel channel) onSelect;

  const FavoritesSidebar({super.key, required this.onSelect});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final favoritesAsync = ref.watch(favoritesStreamProvider);
    final current = ref.watch(currentProgramNumberProvider);

    return Container(
      width: 320,
      color: Colors.black.withValues(alpha: 0.55),
      child: favoritesAsync.when(
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
          return ListView.builder(
            padding: const EdgeInsets.symmetric(vertical: 12),
            itemCount: favorites.length,
            itemBuilder: (context, index) {
              final channel = favorites[index];
              final isCurrent = channel.programNumber == current;
              return _FavoriteRow(
                channel: channel,
                isCurrent: isCurrent,
                onSelect: () => onSelect(channel),
              );
            },
          );
        },
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

  @override
  Widget build(BuildContext context) {
    final channel = widget.channel;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      child: TvFocusHighlight(
        focused: _focused,
        child: InkWell(
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
                _Logo(channel: channel),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    channel.displayName,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight:
                          widget.isCurrent ? FontWeight.bold : FontWeight.normal,
                    ),
                  ),
                ),
                if (channel.sourceType == FavoriteSourceType.dab)
                  const Padding(
                    padding: EdgeInsets.only(left: 4),
                    child: Icon(Icons.radio, size: 16, color: Colors.white38),
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
  final FavoriteChannel channel;
  const _Logo({required this.channel});

  @override
  Widget build(BuildContext context) {
    const size = 40.0;
    final localPath = channel.logoLocalPath;
    final url = channel.logoUrl;
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
