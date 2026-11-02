import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../core/popup_text_field.dart';
import '../../core/providers.dart';
import '../../data/db/database.dart' show DabStation, FmStation;
import '../../data/models/favorite_channel.dart';
import '../../data/repositories/dab_stations_repository.dart' show DabStationDisplay;
import '../../data/repositories/fm_stations_repository.dart' show FmStationDisplay;
import 'logo_picker_dialog.dart';

/// The result of [showStationEditDialog]: the (possibly unchanged) name and,
/// if one was chosen, the new logo.
typedef StationEdit = ({String name, LogoChoice? logo});

/// "Sender bearbeiten": name and logo of a favorite or station in one place.
/// [liveImagePath] - the image the station is broadcasting right now - is
/// only passed when opened from the home screen by long-pressing the
/// station that's playing, and adds "Aktuelles Senderbild übernehmen".
Future<StationEdit?> showStationEditDialog(
  BuildContext context, {
  required String name,
  String? logoUrl,
  String? logoLocalPath,
  ({int freqKhz, int serviceId})? dabStation,
  String? liveImagePath,
}) {
  return showDialog<StationEdit>(
    context: context,
    builder: (_) => _StationEditDialog(
      name: name,
      logoUrl: logoUrl,
      logoLocalPath: logoLocalPath,
      dabStation: dabStation,
      liveImagePath: liveImagePath,
    ),
  );
}

class _StationEditDialog extends StatefulWidget {
  final String name;
  final String? logoUrl;
  final String? logoLocalPath;
  final ({int freqKhz, int serviceId})? dabStation;
  final String? liveImagePath;

  const _StationEditDialog({
    required this.name,
    this.logoUrl,
    this.logoLocalPath,
    this.dabStation,
    this.liveImagePath,
  });

  @override
  State<_StationEditDialog> createState() => _StationEditDialogState();
}

class _StationEditDialogState extends State<_StationEditDialog> {
  late final _nameController = TextEditingController(text: widget.name);
  LogoChoice? _logo;

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _searchLogo() async {
    final choice = await showLogoPicker(context, stationName: _nameController.text, dabStation: widget.dabStation);
    if (choice != null) setState(() => _logo = choice);
  }

  /// The live image is a temporary slideshow file that the next slide may
  /// replace - copied to the app's own storage so the logo stays.
  Future<void> _takeLiveImage() async {
    final source = File(widget.liveImagePath!);
    if (!source.existsSync()) return;
    final dir = Directory(p.join((await getApplicationSupportDirectory()).path, 'logos'));
    await dir.create(recursive: true);
    final target = p.join(dir.path, 'logo_${DateTime.now().millisecondsSinceEpoch}${p.extension(source.path)}');
    await source.copy(target);
    if (mounted) setState(() => _logo = (url: null, localPath: target));
  }

  @override
  Widget build(BuildContext context) {
    final logo = _logo;
    final path = logo != null ? logo.localPath : widget.logoLocalPath;
    final url = logo != null ? logo.url : widget.logoUrl;
    final ImageProvider? image =
        path != null ? FileImage(File(path)) : (url != null ? CachedNetworkImageProvider(url) : null);
    return AlertDialog(
      title: const Text('Sender bearbeiten'),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            PopupTextField(controller: _nameController, label: 'Name', autofocus: true),
            const SizedBox(height: 20),
            Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: Container(
                    width: 84,
                    height: 84,
                    color: Colors.white10,
                    child: image == null
                        ? const Icon(Icons.radio, color: Colors.white38, size: 36)
                        : Image(image: image, fit: BoxFit.cover),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      OutlinedButton.icon(
                        onPressed: _searchLogo,
                        icon: const Icon(Icons.image_search),
                        label: const Text('Logo suchen'),
                      ),
                      if (widget.liveImagePath != null) ...[
                        const SizedBox(height: 8),
                        OutlinedButton.icon(
                          onPressed: _takeLiveImage,
                          icon: const Icon(Icons.photo_camera_back_outlined),
                          label: const Text('Aktuelles Senderbild übernehmen'),
                        ),
                      ],
                      if (logo != null)
                        const Padding(
                          padding: EdgeInsets.only(top: 8),
                          child: Text('Neues Logo - wird mit „Speichern“ übernommen.',
                              style: TextStyle(color: Colors.white54, fontSize: 12)),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Abbrechen')),
        FilledButton(
          onPressed: () => Navigator.of(context).pop((name: _nameController.text.trim(), logo: _logo)),
          child: const Text('Speichern'),
        ),
      ],
    );
  }
}

// Applying an edit: a favorite and the station it refers to share the logo
// (whichever is edited, both show the new one), names stay separate.

Future<void> applyFavoriteEdit(WidgetRef ref, FavoriteChannel channel, StationEdit edit) async {
  if (edit.name.isNotEmpty && edit.name != channel.displayName) {
    await ref.read(favoritesRepositoryProvider).rename(channel.programNumber, edit.name);
  }
  final logo = edit.logo;
  if (logo == null) return;
  await ref.read(favoritesRepositoryProvider).setLogo(channel.programNumber, logoUrl: logo.url, logoLocalPath: logo.localPath);
  final dabFreq = channel.dabFreqKhz, dabSid = channel.dabServiceId, fmFreq = channel.fmFreqKhz;
  if (dabFreq != null && dabSid != null) {
    await ref
        .read(dabStationsRepositoryProvider)
        .setLogo(freqKhz: dabFreq, serviceId: dabSid, logoUrl: logo.url, logoLocalPath: logo.localPath);
  }
  if (fmFreq != null) {
    await ref.read(fmStationsRepositoryProvider).setLogo(fmFreq, logoUrl: logo.url, logoLocalPath: logo.localPath);
  }
}

Future<void> applyDabStationEdit(WidgetRef ref, DabStation station, StationEdit edit) async {
  if (edit.name != station.displayLabel) {
    await ref
        .read(dabStationsRepositoryProvider)
        .setCustomLabel(freqKhz: station.freqKhz, serviceId: station.serviceId, customLabel: edit.name);
  }
  final logo = edit.logo;
  if (logo == null) return;
  await ref.read(dabStationsRepositoryProvider).setLogo(
        freqKhz: station.freqKhz,
        serviceId: station.serviceId,
        logoUrl: logo.url,
        logoLocalPath: logo.localPath,
      );
  for (final c in _favorites(ref).where((c) => c.dabFreqKhz == station.freqKhz && c.dabServiceId == station.serviceId)) {
    await ref.read(favoritesRepositoryProvider).setLogo(c.programNumber, logoUrl: logo.url, logoLocalPath: logo.localPath);
  }
}

Future<void> applyFmStationEdit(WidgetRef ref, FmStation station, StationEdit edit) async {
  if (edit.name != station.displayLabel) {
    await ref.read(fmStationsRepositoryProvider).setCustomLabel(station.freqKhz, edit.name);
  }
  final logo = edit.logo;
  if (logo == null) return;
  await ref.read(fmStationsRepositoryProvider).setLogo(station.freqKhz, logoUrl: logo.url, logoLocalPath: logo.localPath);
  for (final c in _favorites(ref).where((c) => c.fmFreqKhz == station.freqKhz)) {
    await ref.read(favoritesRepositoryProvider).setLogo(c.programNumber, logoUrl: logo.url, logoLocalPath: logo.localPath);
  }
}

List<FavoriteChannel> _favorites(WidgetRef ref) => ref.read(favoritesStreamProvider).value ?? const [];

/// Opens [showStationEditDialog] for a favorite and applies the result.
Future<void> editFavorite(BuildContext context, WidgetRef ref, FavoriteChannel channel, {String? liveImagePath}) async {
  final freq = channel.dabFreqKhz, sid = channel.dabServiceId;
  final edit = await showStationEditDialog(
    context,
    name: channel.displayName,
    logoUrl: channel.logoUrl,
    logoLocalPath: channel.logoLocalPath,
    dabStation: freq != null && sid != null ? (freqKhz: freq, serviceId: sid) : null,
    liveImagePath: liveImagePath,
  );
  if (edit != null) await applyFavoriteEdit(ref, channel, edit);
}

Future<void> editDabStation(BuildContext context, WidgetRef ref, DabStation station, {String? liveImagePath}) async {
  final edit = await showStationEditDialog(
    context,
    name: station.displayLabel,
    logoUrl: station.logoUrl,
    logoLocalPath: station.logoLocalPath,
    dabStation: (freqKhz: station.freqKhz, serviceId: station.serviceId),
    liveImagePath: liveImagePath,
  );
  if (edit != null) await applyDabStationEdit(ref, station, edit);
}

Future<void> editFmStation(BuildContext context, WidgetRef ref, FmStation station) async {
  final edit = await showStationEditDialog(
    context,
    name: station.displayLabel,
    logoUrl: station.logoUrl,
    logoLocalPath: station.logoLocalPath,
  );
  if (edit != null) await applyFmStationEdit(ref, station, edit);
}
