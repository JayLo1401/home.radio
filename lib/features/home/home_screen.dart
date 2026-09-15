import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';

import '../../core/providers.dart';
import '../../data/models/favorite_channel.dart';
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
    // If the app already tried (and failed, since the adapter wasn't open
    // yet) to autostart into a DAB+ favorite, retry now that it's ready.
    final current = ref.read(currentProgramNumberProvider);
    if (current != null) return; // something already playing/tuned
    await _autostart();
  }

  Future<void> _autostart() async {
    final settings = ref.read(settingsRepositoryProvider);
    final mode = await settings.getAutostartMode();
    final favorites = await ref.read(favoritesRepositoryProvider).watchFavorites().first;
    if (favorites.isEmpty) return;

    int? programNumber;
    if (mode.name == 'fixedStation') {
      programNumber = await settings.getFixedProgramNumber();
    } else {
      programNumber = await settings.getLastProgramNumber();
    }
    final channel = favorites.firstWhere(
      (c) => c.programNumber == programNumber,
      orElse: () => favorites.first,
    );
    if (mounted) _play(channel);
  }

  Future<void> _play(FavoriteChannel channel) async {
    setState(() {
      _playbackError = null;
      _icyTitle = null;
      _dabStatusText = null;
      _dabTuned = false;
    });
    ref.read(currentProgramNumberProvider.notifier).set(channel.programNumber);
    ref.read(settingsRepositoryProvider).setLastProgramNumber(channel.programNumber);

    final url = channel.internetStreamUrl;
    if (url != null) {
      await ref.read(audioPlayerServiceProvider).stop();
      ref.read(radioAudioHandlerProvider).setChannel(channel, playing: true);
      await ref.read(audioPlayerServiceProvider).playStream(url);
      return;
    }

    final freqKhz = channel.dabFreqKhz;
    if (freqKhz == null) return;
    if (!_dabDeviceOpen) {
      setState(() => _dabStatusText = 'DAB+-Adapter ist noch nicht bereit (Berechtigung/USB prüfen).');
      return;
    }
    // Only RF tuning + lock is implemented so far - actual DAB+ audio needs
    // MSC subchannel demuxing + AAC decoding, not done yet (see the DAB+
    // phase of the project plan). This still lets the tune itself be
    // verified end-to-end even without audio output, and it's already
    // reported as "playing" to the MediaSession (Home Assistant/TV
    // launcher) since RF lock is the closest equivalent state available.
    final ok = await ref.read(dabUsbServiceProvider).dabTuneFrequency(freqKhz);
    if (!mounted) return;
    if (ok) {
      ref.read(radioAudioHandlerProvider).setChannel(channel, playing: true);
      setState(() {
        _dabTuned = true;
        _dabStatusText = 'Getunt – DAB+-Audiowiedergabe ist noch nicht implementiert.';
      });
    } else {
      setState(() => _dabStatusText = 'Tuning auf "${channel.displayName}" fehlgeschlagen.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final favorites = ref.watch(favoritesStreamProvider).value ?? const [];
    final currentProgram = ref.watch(currentProgramNumberProvider);
    final currentChannel = currentProgram == null
        ? null
        : favorites.where((c) => c.programNumber == currentProgram).firstOrNull;

    final isDab = currentChannel?.sourceType == FavoriteSourceType.dab;
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
                      FavoritesSidebar(onSelect: _play),
                    ],
                  ),
                ),
                NowPlayingBanner(
                  channel: currentChannel,
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
  final VoidCallback onOpenInternetSearch;
  final VoidCallback onOpenSettings;

  const _MenuBar({
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
          TextButton.icon(
            onPressed: onOpenInternetSearch,
            icon: const Icon(Icons.public, color: Colors.white),
            label: const Text('Internetradio suchen', style: TextStyle(color: Colors.white)),
          ),
          const SizedBox(width: 8),
          TextButton.icon(
            onPressed: onOpenSettings,
            icon: const Icon(Icons.settings, color: Colors.white),
            label: const Text('Einstellungen', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }
}
