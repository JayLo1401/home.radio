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
import 'radar_panel.dart';
import 'weather_panel.dart';

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
  bool _dabServerReady = false;
  double? _dabSnrDb;

  // A real DAB+ MOT slideshow image for whatever's currently playing (see
  // _onDabEvent's 'motLogo' case) - shown live in the Now Playing banner
  // only, never persisted as *the* station logo (see DabStation.logoUrl's
  // own doc comment for why: it's usually just "now playing" cover art,
  // not a stable logo). Reset whenever playback target changes so a stale
  // image from a previous station never lingers.
  String? _liveMotLogoPath;

  // Shown (in place of the normal DAB subtitle, styled as an error) when
  // the rtl_tcp source connection drops mid-playback (see
  // DabRtlSdrPlugin.nativeOnConnectionMessage/CRTL_TCP_Client's own
  // handleDisconnect()/receiveAndReconnect(), which now keeps retrying on
  // its own) - cleared again once a reconnect succeeds.
  String? _dabConnectionWarning;

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
    ref.read(dabRtlSdrServiceProvider).events.listen(_onDabEvent);
    ref.read(rtlSdrUsbServiceProvider).events.listen(_onUsbDeviceEvent);
    // _autostart() must wait for _initDabServer() to actually finish (USB
    // permission request + native rtl_tcp service startup can take a
    // couple of seconds, or longer the very first time) rather than racing
    // it - a DAB+ autostart attempted before any samples are flowing yet
    // has no real chance of succeeding, and there was no retry afterwards.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _initDabServer();
      await _autostart();
    });
  }

  /// Live DAB+ radiotext (DLS/dynamic label - the "now playing" style text
  /// some stations send, e.g. artist/title) shown in place of the static
  /// "wird gesucht"/error text once actual playback is underway. Empty/
  /// blank labels are common (many stations send nothing, or clear it
  /// between songs) and fall back to no subtitle rather than an empty one.
  void _onDabEvent(Map<String, dynamic> event) {
    if (!mounted) return;
    switch (event['type']) {
      case 'dynamicLabel' when _dabTuned:
        final label = event['label'] as String? ?? '';
        setState(() => _dabStatusText = label.isEmpty ? null : label);
      case 'snr' when _dabTuned:
        setState(() => _dabSnrDb = (event['snrDb'] as num).toDouble());
      case 'motLogo' when _dabTuned:
        // A real DAB+ MOT slideshow image just arrived for whatever's
        // currently playing (see DabRtlSdrPlugin.nativeOnMot) - shown live
        // in the Now Playing banner only (see [_liveMotLogoPath]'s own doc
        // comment for why this deliberately does NOT touch the station's
        // persistent logo/DB row).
        setState(() => _liveMotLogoPath = event['path'] as String);
      case 'connectionMessage':
        // Deliberately not guarded on _dabTuned (unlike the cases above):
        // a manual retry after a drop resets _dabTuned to false *before*
        // calling playService() again (see _play()/_playDabStation()'s own
        // reset block), so a guard here would silently swallow exactly the
        // events that explain why that retry is failing - _playDab() below
        // prefers this message over its own generic "Kein Empfang"/
        // "Quelle nicht erreichbar" text once it's set.
        final isError = event['isError'] as bool? ?? false;
        setState(() {
          _dabConnectionWarning =
              isError ? 'Verbindung zur RTL-SDR-Quelle verloren - versuche erneut zu verbinden…' : null;
        });
    }
  }

  /// Recovers from the known RTL-SDR dongle being unplugged/replugged while
  /// this app has it open in direct-USB mode (see RtlSdrUsbService.events
  /// and DabRtlSdrService.resetSession()'s own doc comment for why the
  /// native session can't just fix itself). Previously nothing listened for
  /// this at all - a mid-playback unplug left the app stuck needing a force-
  /// stop to ever play DAB+ again, exactly the failure this closes.
  void _onUsbDeviceEvent(Map<String, dynamic> event) {
    final type = event['type'];
    if (type != 'deviceDetached' && type != 'deviceAttached') return;
    () async {
      if (!mounted) return;
      if (!await ref.read(settingsRepositoryProvider).getRtlSdrAutoStartOwnService()) {
        return; // only direct-USB mode actually owns the dongle itself
      }
      if (type == 'deviceDetached') {
        final wasDabPlaying = _dabTuned;
        await ref.read(dabRtlSdrServiceProvider).resetSession();
        if (!mounted) return;
        setState(() {
          _dabServerReady = false;
          _dabTuned = false;
          if (wasDabPlaying) _dabStatusText = 'USB-Stick getrennt - warte auf Wiederanschluss…';
        });
      } else {
        if (_dabServerReady) return; // was never actually interrupted
        await _initDabServer();
        await _resumeDabAfterReconnect();
      }
    }();
  }

  /// Re-plays whatever DAB+ source was current when the dongle got pulled
  /// (see [_onUsbDeviceEvent]) - [currentDabStationProvider]/
  /// [currentProgramNumberProvider] still hold that identity even while
  /// disconnected, since nothing resets them on a mere playback failure.
  Future<void> _resumeDabAfterReconnect() async {
    if (!mounted || !_dabServerReady) return;
    final currentDabStation = ref.read(currentDabStationProvider);
    if (currentDabStation != null) {
      final stations = await ref.read(dabStationsRepositoryProvider).watchAll().first;
      final station = stations
          .where((s) => s.freqKhz == currentDabStation.freqKhz && s.serviceId == currentDabStation.serviceId)
          .firstOrNull;
      if (station != null && mounted) await _playDabStation(station);
      return;
    }
    final currentProgram = ref.read(currentProgramNumberProvider);
    if (currentProgram == null) return;
    final favorites = await ref.read(favoritesRepositoryProvider).watchFavorites().first;
    final channel = favorites.where((c) => c.programNumber == currentProgram).firstOrNull;
    if (channel != null && channel.dabFreqKhz != null && channel.dabServiceId != null && mounted) {
      await _play(channel);
    }
  }

  /// Points the DAB+ decoder (see DabRtlSdrService) at whichever RTL-SDR
  /// source was configured in Settings/RtlSdrTestScreen. "Own USB service"
  /// mode goes straight over USB (see [DabRtlSdrService.useDirectUsb] /
  /// direct_rtlsdr_input.h) instead of through RtlSdrUsbService's rtl_tcp
  /// TCP server - that server is now only started from RtlSdrTestScreen
  /// itself for standalone testing, not auto-started here, since direct
  /// mode and that server are mutually exclusive consumers of the same
  /// dongle. An external app or network service still just gets a plain
  /// rtl_tcp client connection, same as before.
  Future<void> _initDabServer() async {
    final settings = ref.read(settingsRepositoryProvider);
    final dab = ref.read(dabRtlSdrServiceProvider);
    final ok = await settings.getRtlSdrAutoStartOwnService()
        ? await dab.useDirectUsb()
        : await dab.setServer(host: await settings.getRtlSdrHost(), port: await settings.getRtlSdrPort());
    if (mounted) setState(() => _dabServerReady = ok);
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
      _dabSnrDb = null;
      _liveMotLogoPath = null;
      _dabConnectionWarning = null;
    });
    ref.read(currentDabStationProvider.notifier).set(null);
    ref.read(currentProgramNumberProvider.notifier).set(channel.programNumber);
    ref.read(settingsRepositoryProvider).setLastPlayedFavorite(channel.programNumber);

    final url = channel.internetStreamUrl;
    if (url != null) {
      await ref.read(dabRtlSdrServiceProvider).stopPlayback();
      await ref.read(audioPlayerServiceProvider).stop();
      _setNowPlayingFavorite(channel, playing: true);
      await ref.read(audioPlayerServiceProvider).playStream(url);
      return;
    }

    await ref.read(audioPlayerServiceProvider).stop();
    final freqKhz = channel.dabFreqKhz;
    final serviceId = channel.dabServiceId;
    if (freqKhz == null || serviceId == null) return;
    await _playDab(freqKhz: freqKhz, serviceId: serviceId, onPlaying: () => _setNowPlayingFavorite(channel, playing: true));
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
      _dabSnrDb = null;
      _liveMotLogoPath = null;
      _dabConnectionWarning = null;
    });
    ref.read(currentProgramNumberProvider.notifier).set(null);
    ref.read(currentDabStationProvider.notifier).set((freqKhz: station.freqKhz, serviceId: station.serviceId));
    ref.read(settingsRepositoryProvider).setLastPlayedDabStation(station.freqKhz, station.serviceId);

    await ref.read(audioPlayerServiceProvider).stop();
    await _playDab(
      freqKhz: station.freqKhz,
      serviceId: station.serviceId,
      onPlaying: () => _setNowPlayingDabStation(station, playing: true),
    );
  }

  /// Shared DAB+ playback path for both [_play] (favorites) and
  /// [_playDabStation]: tunes+decodes via the RTL-SDR/welle.io pipeline
  /// (DabRtlSdrService) and waits for the result - unlike the old
  /// Raontech-chip pipeline, this is a single await rather than a
  /// multi-stage event stream (tuning/resolvingSubchannel/playing/...), so
  /// there's no USB permission/adapter-open dance to manage here either.
  Future<void> _playDab({
    required int freqKhz,
    required int serviceId,
    required VoidCallback onPlaying,
  }) async {
    if (mounted) setState(() => _dabStatusText = 'Sender wird gesucht…');
    final ok = await ref.read(dabRtlSdrServiceProvider).playService(freqKhz: freqKhz, serviceId: serviceId);
    if (!mounted) return;
    setState(() {
      _dabTuned = ok;
      _dabStatusText = ok
          ? null
          : (_dabConnectionWarning ??
              (_dabServerReady ? 'Kein Empfang auf dieser Frequenz.' : 'RTL-SDR-Quelle nicht erreichbar.'));
    });
    if (ok) onPlaying();
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
    final errorMessage = isDab ? _dabConnectionWarning : _playbackError;

    return Scaffold(
      body: Stack(
        fit: StackFit.expand,
        children: [
          BackgroundLayer(
            logoLocalPath: currentChannel?.logoLocalPath ?? currentRawDabStation?.logoLocalPath,
            logoUrl: currentChannel?.logoUrl ?? currentRawDabStation?.logoUrl,
          ),
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
                  logoUrl: currentChannel?.logoUrl ?? currentRawDabStation?.logoUrl,
                  logoLocalPath: _liveMotLogoPath ?? currentChannel?.logoLocalPath ?? currentRawDabStation?.logoLocalPath,
                  isPlaying: isPlaying,
                  isBuffering: isBuffering,
                  subtitle: (subtitle?.isEmpty ?? true) ? null : subtitle,
                  errorMessage: errorMessage,
                  snrDb: (isDab && isPlaying) ? _dabSnrDb : null,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Hourly forecast and rain radar as compact tiles, centered in the
/// available area (both axes) - deliberately *not* filling the whole space
/// (there's no need for either to be that big). Sized from a base size
/// scaled by the user's per-tile size setting (see WeatherDisplaySettings'
/// doc comment). Uses [Wrap] rather than a fixed [Row] specifically so more
/// tiles can be added later (e.g. a second radar layer, a webcam) without
/// redoing the layout - it wraps to a new centered row by itself once tiles
/// no longer fit side by side, instead of overflowing or needing a scrollbar.
class _WeatherRadarColumn extends ConsumerWidget {
  const _WeatherRadarColumn();

  // Both tiles share the same base size (widescreen, not square) so that at
  // 100% they line up as one visually consistent group.
  static const _tileBaseWidth = 420.0;
  static const _tileBaseHeight = 260.0;
  static const _tileRadius = 16.0;
  static const _tileGap = 16.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(weatherDisplaySettingsProvider);
    if (!settings.weatherEnabled && !settings.radarEnabled) {
      return const SizedBox.shrink();
    }
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Wrap(
          alignment: WrapAlignment.center,
          runAlignment: WrapAlignment.center,
          spacing: _tileGap,
          runSpacing: _tileGap,
          children: [
            if (settings.weatherEnabled)
              _Tile(
                width: _tileBaseWidth * settings.weatherScale,
                height: _tileBaseHeight * settings.weatherScale,
                radius: _tileRadius,
                child: WeatherPanel(
                  locationName: settings.locationName,
                  lat: settings.lat,
                  lon: settings.lon,
                ),
              ),
            if (settings.radarEnabled)
              _Tile(
                width: _tileBaseWidth * settings.radarScale,
                height: _tileBaseHeight * settings.radarScale,
                radius: _tileRadius,
                child: RadarPanel(lat: settings.lat, lon: settings.lon, dimming: settings.radarDimming),
              ),
          ],
        ),
      ),
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({required this.width, required this.height, required this.radius, required this.child});

  final double width;
  final double height;
  final double radius;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      height: height,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: DecoratedBox(
          decoration: BoxDecoration(
            border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
            boxShadow: [
              BoxShadow(color: Colors.black.withValues(alpha: 0.4), blurRadius: 12, offset: const Offset(0, 4)),
            ],
          ),
          child: child,
        ),
      ),
    );
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
