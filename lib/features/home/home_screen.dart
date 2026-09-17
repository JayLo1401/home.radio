import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';

import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../data/db/database.dart' show DabStation;
import '../../data/models/favorite_channel.dart';
import '../../data/repositories/dab_stations_repository.dart' show DabStationDisplay;
import '../../data/repositories/settings_repository.dart' show AutostartMode;
import '../dab_stations/dab_stations_screen.dart';
import '../search_internet/internet_radio_search_screen.dart';
import '../settings/settings_screen.dart';
import 'background_layer.dart';
import 'favorites_sidebar.dart';
import 'now_playing_banner.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  PlayerState? _playerState;
  String? _icyTitle;
  String? _playbackError;
  String? _dabStatusText;
  bool _dabTuned = false;
  bool _dabDeviceOpen = false;
  Future<void> Function()? _pendingDabResume;

  @override
  void initState() {
    super.initState();
    final audio = ref.read(audioPlayerServiceProvider);
    audio.playerStateStream.listen((s) {
      if (mounted) setState(() => _playerState = s);
    });
    audio.icyTitleStream.listen((t) {
      if (mounted) setState(() => _icyTitle = t);
    });
    audio.errorStream.listen((e) {
      if (mounted) setState(() => _playbackError = e);
    });
    final dab = ref.read(dabUsbServiceProvider);
    // Ask for USB permission for the DAB+ adapter right away if it's
    // attached, instead of waiting for the user to open the DAB+ screen -
    // never targets any other USB device (e.g. the TV's own Wi-Fi adapter).
    // The system permission dialog itself can't be skipped (confirmed not
    // possible, same as with the previous DAB app) - Home Assistant already
    // auto-dismisses it, everything after that must happen on its own.
    dab.autoRequestPermissionForAdapter();
    dab.permissionEvents.listen((event) {
      if (event['granted'] == true) _onDabPermissionGranted();
    });
    dab.playbackStatusEvents.listen(_onDabPlaybackStatus);
    // If permission was already granted in an earlier session, no dialog
    // (and thus no permissionEvents callback) fires this time - open the
    // adapter directly if it's already attached+permitted.
    _tryOpenAlreadyPermittedAdapter();
    WidgetsBinding.instance.addPostFrameCallback((_) => _autostart());
  }

  Future<void> _tryOpenAlreadyPermittedAdapter() async {
    final devices = await ref.read(dabUsbServiceProvider).listDevices();
    if (devices.any((d) => d.hasPermission)) {
      await _onDabPermissionGranted();
    }
  }

  /// Fires once the OS USB permission dialog for the DAB+ adapter has been
  /// answered "yes" (see [dabUsbServiceProvider].permissionEvents) - opens
  /// the adapter immediately so a DAB+ autostart favorite can actually tune
  /// without any further user interaction.
  Future<void> _onDabPermissionGranted() async {
    final devices = await ref.read(dabUsbServiceProvider).listDevices();
    final device = devices.where((d) => d.hasPermission).firstOrNull;
    if (device == null) return;
    await ref.read(dabUsbServiceProvider).openDevice(device.deviceName);
    if (!mounted) return;
    _dabDeviceOpen = true;
    // Whatever the user was actually trying to switch to (see
    // _ensureDabAdapterReady) takes priority over autostart.
    final pending = _pendingDabResume;
    _pendingDabResume = null;
    if (pending != null) {
      await pending();
      return;
    }
    // Otherwise, if the app already tried (and failed, since the adapter
    // wasn't open yet) to autostart into a DAB+ favorite/station, retry now.
    if (ref.read(currentProgramNumberProvider) != null) return;
    if (ref.read(currentDabStationProvider) != null) return;
    await _autostart();
  }

  /// Called when the user picks a DAB+ favorite/station but the adapter
  /// isn't open yet - (re-)requests USB permission if needed and opens the
  /// adapter, so switching to a DAB+ station always tries to get ready
  /// rather than just reporting "not ready" once and giving up. [resume] is
  /// called automatically via [_onDabPermissionGranted] once
  /// permission/opening succeeds - it's whichever of [_play]/[_playDabStation]
  /// the caller was in the middle of, retried from the top.
  Future<void> _ensureDabAdapterReady(Future<void> Function() resume) async {
    _pendingDabResume = resume;
    final dab = ref.read(dabUsbServiceProvider);
    final devices = await dab.listDevices();
    if (devices.isEmpty) {
      if (mounted) setState(() => _dabStatusText = 'Kein DAB+-USB-Adapter angeschlossen.');
      return;
    }
    final permitted = devices.where((d) => d.hasPermission).firstOrNull;
    if (permitted != null) {
      await dab.openDevice(permitted.deviceName);
      if (!mounted) return;
      _dabDeviceOpen = true;
      final pending = _pendingDabResume;
      _pendingDabResume = null;
      if (pending != null) await pending();
      return;
    }
    // No permission yet - (re-)request it. The permissionEvents listener
    // opens the device and retries _pendingDabResume once answered.
    if (mounted) setState(() => _dabStatusText = 'Warte auf USB-Berechtigung für den DAB+-Adapter…');
    await dab.autoRequestPermissionForAdapter();
  }

  Future<void> _autostart() async {
    final settings = ref.read(settingsRepositoryProvider);
    final mode = await settings.getAutostartMode();

    if (mode == AutostartMode.fixedStation) {
      final favorites = await ref.read(favoritesRepositoryProvider).watchFavorites().first;
      if (favorites.isEmpty) return;
      final programNumber = await settings.getFixedProgramNumber();
      final channel = favorites.firstWhere(
        (c) => c.programNumber == programNumber,
        orElse: () => favorites.first,
      );
      if (mounted) await _play(channel);
      return;
    }

    // "Zuletzt gehörten Sender starten": whatever was last played, whether
    // it's a favorite or a DAB+ station played directly from "Alle DAB+
    // Sender" without being one (see FavoritesSidebar/LastPlayed).
    final lastPlayed = await settings.getLastPlayed();
    final lastDabFreq = lastPlayed?.dabFreqKhz;
    final lastDabServiceId = lastPlayed?.dabServiceId;
    if (lastDabFreq != null && lastDabServiceId != null) {
      final stations = await ref.read(dabStationsRepositoryProvider).watchAll().first;
      final station = stations
          .where((s) => s.freqKhz == lastDabFreq && s.serviceId == lastDabServiceId)
          .firstOrNull;
      if (station != null) {
        if (mounted) await _playDabStation(station);
        return;
      }
    }

    final favorites = await ref.read(favoritesRepositoryProvider).watchFavorites().first;
    if (favorites.isEmpty) return;
    final channel = favorites.firstWhere(
      (c) => c.programNumber == lastPlayed?.favoriteProgramNumber,
      orElse: () => favorites.first,
    );
    if (mounted) await _play(channel);
  }

  /// Mirrors the channel/station into the Android MediaSession (see
  /// radioAudioHandlerProvider) - best-effort: the handler initializes
  /// lazily (not blocking app startup on it, see that provider's doc
  /// comment), so this silently does nothing if it isn't ready yet or fails,
  /// rather than holding up actual playback for it.
  void _setNowPlayingFavorite(FavoriteChannel channel, {required bool playing}) {
    ref.read(radioAudioHandlerProvider.future).then(
          (handler) => handler.setChannel(channel, playing: playing),
          onError: (_) {},
        );
  }

  void _setNowPlayingDabStation(DabStation station, {required bool playing}) {
    ref.read(radioAudioHandlerProvider.future).then(
          (handler) => handler.setDabStation(station, playing: playing),
          onError: (_) {},
        );
  }

  Future<void> _play(FavoriteChannel channel) async {
    setState(() {
      _playbackError = null;
      _icyTitle = null;
      _dabStatusText = null;
      _dabTuned = false;
    });
    ref.read(currentDabStationProvider.notifier).set(null);
    ref.read(currentProgramNumberProvider.notifier).set(channel.programNumber);
    ref.read(settingsRepositoryProvider).setLastPlayedFavorite(channel.programNumber);

    final url = channel.internetStreamUrl;
    if (url != null) {
      await ref.read(dabUsbServiceProvider).dabStopPlayback();
      await ref.read(audioPlayerServiceProvider).stop();
      _setNowPlayingFavorite(channel, playing: true);
      await ref.read(audioPlayerServiceProvider).playStream(url);
      return;
    }

    await ref.read(audioPlayerServiceProvider).stop();
    final freqKhz = channel.dabFreqKhz;
    final serviceId = channel.dabServiceId;
    if (freqKhz == null || serviceId == null) return;
    if (!_dabDeviceOpen) {
      await _ensureDabAdapterReady(() => _play(channel));
      return;
    }
    await ref.read(dabUsbServiceProvider).dabPlayService(freqKhz: freqKhz, serviceId: serviceId);
  }

  /// Plays a DAB+ station directly from the sidebar's "DAB-Sender" category
  /// (see FavoritesSidebar), without it being a saved favorite - the
  /// counterpart to [_play] for that case. [currentDabStationProvider] tracks
  /// its identity the way [currentProgramNumberProvider] does for favorites,
  /// since it has no program number of its own.
  Future<void> _playDabStation(DabStation station) async {
    setState(() {
      _playbackError = null;
      _icyTitle = null;
      _dabStatusText = null;
      _dabTuned = false;
    });
    ref.read(currentProgramNumberProvider.notifier).set(null);
    ref.read(currentDabStationProvider.notifier).set((freqKhz: station.freqKhz, serviceId: station.serviceId));
    ref.read(settingsRepositoryProvider).setLastPlayedDabStation(station.freqKhz, station.serviceId);

    await ref.read(audioPlayerServiceProvider).stop();
    if (!_dabDeviceOpen) {
      await _ensureDabAdapterReady(() => _playDabStation(station));
      return;
    }
    await ref
        .read(dabUsbServiceProvider)
        .dabPlayService(freqKhz: station.freqKhz, serviceId: station.serviceId);
  }

  /// Reflects native DAB+ playback progress (see DabUsbPlugin.runDabPlayback)
  /// into the Now Playing banner and MediaSession - the actual audio
  /// decode/output happens entirely natively (DabAudioPlayer), this is only
  /// status/UI plumbing.
  void _onDabPlaybackStatus(Map<String, dynamic> event) {
    if (!mounted) return;
    final status = event['status'] as String?;
    setState(() {
      switch (status) {
        case 'tuning':
          _dabTuned = false;
          _dabStatusText = 'Wird getunt…';
        case 'resolvingSubchannel':
          _dabStatusText = 'Sender wird gesucht…';
        case 'playing':
          _dabTuned = true;
          _dabStatusText = null;
          final current = ref.read(currentProgramNumberProvider);
          if (current != null) {
            final channel = ref
                .read(favoritesStreamProvider)
                .value
                ?.where((c) => c.programNumber == current)
                .firstOrNull;
            if (channel != null) _setNowPlayingFavorite(channel, playing: true);
          } else {
            final currentDab = ref.read(currentDabStationProvider);
            final station = currentDab == null
                ? null
                : ref
                    .read(dabStationsStreamProvider)
                    .value
                    ?.where((s) => s.freqKhz == currentDab.freqKhz && s.serviceId == currentDab.serviceId)
                    .firstOrNull;
            if (station != null) _setNowPlayingDabStation(station, playing: true);
          }
        case 'busy':
          _dabTuned = false;
          _dabStatusText = 'DAB+-Adapter ist gerade anderweitig beschäftigt.';
        case 'error':
          _dabTuned = false;
          _dabStatusText = switch (event['message']) {
            'no_lock' => 'Kein Empfang auf dieser Frequenz.',
            'subchannel_not_found' => 'Sender im Ensemble nicht gefunden.',
            'device_not_open' => 'DAB+-Adapter ist nicht bereit.',
            _ => 'DAB+-Wiedergabe fehlgeschlagen.',
          };
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final favorites = ref.watch(favoritesStreamProvider).value ?? const [];
    final currentProgram = ref.watch(currentProgramNumberProvider);
    final currentChannel = currentProgram == null
        ? null
        : favorites.where((c) => c.programNumber == currentProgram).firstOrNull;

    final currentDabStation = ref.watch(currentDabStationProvider);
    final currentRawDabStation = currentChannel != null || currentDabStation == null
        ? null
        : (ref.watch(dabStationsStreamProvider).value ?? const <DabStation>[])
            .where((s) => s.freqKhz == currentDabStation.freqKhz && s.serviceId == currentDabStation.serviceId)
            .firstOrNull;

    final isDab = currentChannel?.sourceType == FavoriteSourceType.dab || currentRawDabStation != null;
    final isPlaying = isDab ? _dabTuned : (_playerState?.playing ?? false);
    final isBuffering = !isDab &&
        (_playerState?.processingState == ProcessingState.buffering ||
            _playerState?.processingState == ProcessingState.loading);
    final subtitle = isDab ? _dabStatusText : _icyTitle;
    final errorMessage = isDab ? null : _playbackError;

    return Scaffold(
      body: Stack(
        fit: StackFit.expand,
        children: [
          BackgroundLayer(currentChannel: currentChannel),
          SafeArea(
            child: Column(
              children: [
                _MenuBar(
                  onOpenDabStations: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const DabStationsScreen()),
                  ),
                  onOpenInternetSearch: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const InternetRadioSearchScreen()),
                  ),
                  onOpenSettings: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const SettingsScreen()),
                  ),
                ),
                Expanded(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Expanded(child: _WeatherRadarColumn()),
                      FavoritesSidebar(onSelect: _play, onSelectDabStation: _playDabStation),
                    ],
                  ),
                ),
                NowPlayingBanner(
                  programNumber: currentChannel?.programNumber,
                  displayName: currentChannel?.displayName ?? currentRawDabStation?.displayLabel,
                  logoUrl: currentChannel?.logoUrl,
                  logoLocalPath: currentChannel?.logoLocalPath,
                  isPlaying: isPlaying,
                  isBuffering: isBuffering,
                  subtitle: (subtitle?.isEmpty ?? true) ? null : subtitle,
                  errorMessage: errorMessage,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Placeholder column for weather/radar panels (Phase 2).
class _WeatherRadarColumn extends StatelessWidget {
  const _WeatherRadarColumn();

  @override
  Widget build(BuildContext context) {
    return const SizedBox.shrink();
  }
}

class _MenuBar extends StatelessWidget {
  final VoidCallback onOpenDabStations;
  final VoidCallback onOpenInternetSearch;
  final VoidCallback onOpenSettings;

  const _MenuBar({
    required this.onOpenDabStations,
    required this.onOpenInternetSearch,
    required this.onOpenSettings,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.asset('assets/icon/applogo1.png', width: 36, height: 36),
          ),
          const SizedBox(width: 10),
          const Text(
            'Home Radio',
            style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const Spacer(),
          _MenuBarButton(
            icon: Icons.radio,
            label: 'DAB Sender suchen',
            onPressed: onOpenDabStations,
          ),
          const SizedBox(width: 4),
          _MenuBarButton(
            icon: Icons.public,
            label: 'Internetradio suchen',
            onPressed: onOpenInternetSearch,
          ),
          const SizedBox(width: 4),
          _MenuBarButton(
            icon: Icons.settings,
            label: 'Einstellungen',
            onPressed: onOpenSettings,
          ),
        ],
      ),
    );
  }
}

/// Top-bar button that only shows its icon by default and reveals the label
/// next to it once focused (D-Pad navigation) - keeps the bar compact with
/// three entries instead of always showing full text buttons.
class _MenuBarButton extends StatefulWidget {
  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  const _MenuBarButton({
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  @override
  State<_MenuBarButton> createState() => _MenuBarButtonState();
}

class _MenuBarButtonState extends State<_MenuBarButton> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    return TvFocusHighlight(
      focused: _focused,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        focusColor: Colors.transparent,
        hoverColor: Colors.white.withValues(alpha: 0.08),
        onFocusChange: (v) => setState(() => _focused = v),
        onTap: widget.onPressed,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(widget.icon, color: Colors.white),
              AnimatedSize(
                duration: const Duration(milliseconds: 150),
                child: _focused
                    ? Padding(
                        padding: const EdgeInsets.only(left: 8),
                        child: Text(widget.label, style: const TextStyle(color: Colors.white)),
                      )
                    : const SizedBox(height: 24),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
