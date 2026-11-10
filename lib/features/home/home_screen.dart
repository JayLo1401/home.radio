import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';

import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../data/db/database.dart' show DabStation, FmStation;
import '../../data/models/audio_quality.dart';
import '../../data/models/band_plan.dart';
import '../../data/models/favorite_channel.dart';
import '../../data/repositories/dab_stations_repository.dart'
    show DabStationDisplay;
import '../../data/repositories/fm_stations_repository.dart' show FmStationDisplay;
import '../../data/repositories/settings_repository.dart' show AutostartMode, ReceiverMode;
import '../dab_stations/dab_stations_screen.dart';
import '../fm_stations/fm_stations_screen.dart';
import '../scanner/scanner_screen.dart';
import '../search_internet/internet_radio_search_screen.dart';
import '../../data/services/update_service.dart';
import '../settings/settings_screen.dart';
import '../settings/update_settings_screen.dart';
import 'background_layer.dart';
import 'favorites_sidebar.dart';
import 'now_playing_banner.dart';
import 'radar_panel.dart';
import 'sun_moon_panel.dart';
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

  // Bitrate/codec of what's playing, for the banner's quality label -
  // internet radio from AudioPlayerService.qualityStream, DAB+ from the
  // decoder's 'audioFormat' events (see _onDabEvent).
  AudioQuality? _netQuality;
  AudioQuality? _dabQuality;

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

  // FM (UKW) playback - shares _dabTuned/_dabStatusText/_dabSnrDb with
  // DAB+ (both are "the receiver"), plus what only FM has: the tuned
  // frequency (null = not in FM mode), stereo and RDS name/radiotext.
  int? _fmFreqKhz;
  bool _fmStereo = false;
  String? _fmPs;
  String? _fmRt;

  /// Clears everything describing the previous station, before a new one
  /// starts - so nothing stale (radiotext, slideshow, signal) lingers.
  void _resetPlaybackState() {
    setState(() {
      _playbackError = null;
      _icyTitle = null;
      _dabStatusText = null;
      _dabTuned = false;
      _dabSnrDb = null;
      _dabQuality = null;
      _liveMotLogoPath = null;
      _dabConnectionWarning = null;
      _fmFreqKhz = null;
      _fmStereo = false;
      _fmPs = null;
      _fmRt = null;
    });
    ref.read(liveStationImageProvider.notifier).set(null);
  }

  /// A newer version on the update server is installed right after start
  /// (Settings → Updates can turn this off) - a little later, so the radio
  /// gets going first.
  Future<void> _autoUpdate() async {
    if (!UpdateService.supported) return;
    await Future<void>.delayed(const Duration(seconds: 5));
    if (!mounted || !await ref.read(settingsRepositoryProvider).getAutoUpdate()) return;
    final update = await ref.read(updateServiceProvider).check();
    if (update == null || !mounted) return;
    await installUpdate(context, ref, update);
  }

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
    audio.qualityStream.listen((q) {
      if (mounted) setState(() => _netQuality = q);
    });
    _autoUpdate();
    ref.read(dabRtlSdrServiceProvider).events.listen(_onDabEvent);
    ref.read(rtlSdrUsbServiceProvider).events.listen(_onUsbDeviceEvent);
    // Lets Android's own MediaSession (hardware media buttons, Bluetooth
    // headset controls, the notification's own buttons, Assistant "pause
    // music") actually control playback, including while backgrounded - see
    // RadioAudioHandler.bindControls's own doc comment for why this can't
    // just reuse HomeScreen's in-app remote-key handling.
    ref.read(radioAudioHandlerProvider.future).then(
          (handler) => handler.bindControls(
            onPlay: _resumeCurrentPlayback,
            onPause: _pauseCurrentPlayback,
            onSkipNext: () => _stepStation(1),
            onSkipPrevious: () => _stepStation(-1),
          ),
          onError: (_) {},
        );
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
      case 'audioFormat' when _dabTuned:
        final quality = AudioQuality.fromDabFormat(event['format'] as String? ?? '');
        if (quality != _dabQuality) setState(() => _dabQuality = quality);
      case 'fmStatus' when _dabTuned && _fmFreqKhz != null:
        setState(() {
          _dabSnrDb = (event['snrDb'] as num?)?.toDouble();
          _fmStereo = event['stereo'] as bool? ?? false;
        });
      case 'fmRds' when _fmFreqKhz != null && event['freqKhz'] == _fmFreqKhz:
        final ps = (event['ps'] as String?)?.trim();
        final rt = (event['rt'] as String?)?.trim();
        setState(() {
          _fmPs = ps == null || ps.isEmpty ? null : ps;
          _fmRt = rt == null || rt.isEmpty ? null : rt;
        });
        // A saved station learns its RDS name/PI as soon as it's heard.
        final freqKhz = _fmFreqKhz!;
        if (_fmPs != null &&
            (ref.read(fmStationsStreamProvider).value ?? const <FmStation>[]).any((s) => s.freqKhz == freqKhz)) {
          ref.read(fmStationsRepositoryProvider).upsert(
                freqKhz: freqKhz,
                pi: event['pi'] as int?,
                psName: _fmPs,
                stereo: _fmStereo,
              );
        }
      case 'motLogo' when _dabTuned:
        // A real DAB+ MOT slideshow image just arrived for whatever's
        // currently playing (see DabRtlSdrPlugin.nativeOnMot) - shown live
        // in the Now Playing banner only (see [_liveMotLogoPath]'s own doc
        // comment for why this deliberately does NOT touch the station's
        // persistent logo/DB row).
        setState(() => _liveMotLogoPath = event['path'] as String);
        ref.read(liveStationImageProvider.notifier).set(_liveMotLogoPath);
      case 'audioFocusLost':
        // Another app (e.g. Spotify) started playing and took over audio
        // focus - the native side already stopped the tuner/decoder itself
        // (see DabRtlSdrPlugin's DabAacPlayer focus callback), this just
        // brings the UI in line with that so it doesn't keep claiming
        // "playing" while nothing is actually coming out of the speaker.
        setState(() {
          _dabTuned = false;
          _dabStatusText = 'Pausiert - eine andere App spielt Audio ab.';
        });
      case 'connectionMessage':
        // Deliberately not guarded on _dabTuned (unlike the cases above):
        // a manual retry after a drop resets _dabTuned to false *before*
        // calling playService() again (see _play()/_playDabStation()'s own
        // reset block), so a guard here would silently swallow exactly the
        // events that explain why that retry is failing - _playDab() below
        // prefers this message over its own generic "Kein Empfang"/
        // "Quelle nicht erreichbar" text once it's set.
        // The message says what's wrong - with rtl_tcp Jay extended e.g.
        // "„Standort1 Stick 1“ nicht bereit", "… wird bereits von
        // 192.168.1.20 verwendet".
        final isError = event['isError'] as bool? ?? false;
        final message = (event['message'] as String?)?.trim() ?? '';
        setState(() {
          _dabConnectionWarning = !isError
              ? null
              : (message.isEmpty || message.startsWith('Verbindung zur rtl_tcp-Quelle verloren'))
                  ? 'Verbindung zur RTL-SDR-Quelle verloren - versuche erneut zu verbinden…'
                  : message;
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
      if (!await ref
          .read(settingsRepositoryProvider)
          .getRtlSdrAutoStartOwnService()) {
        return; // only direct-USB mode actually owns the dongle itself
      }
      if (type == 'deviceDetached') {
        final wasDabPlaying = _dabTuned;
        await ref.read(dabRtlSdrServiceProvider).resetSession();
        if (!mounted) return;
        setState(() {
          _dabServerReady = false;
          _dabTuned = false;
          if (wasDabPlaying) {
            _dabStatusText = 'USB-Stick getrennt - warte auf Wiederanschluss…';
          }
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
    final currentFm = ref.read(currentFmStationProvider);
    if (currentFm != null) {
      final station = (ref.read(fmStationsStreamProvider).value ?? const <FmStation>[])
          .where((s) => s.freqKhz == currentFm)
          .firstOrNull;
      if (station != null) await _playFmStation(station);
      return;
    }
    final currentDabStation = ref.read(currentDabStationProvider);
    if (currentDabStation != null) {
      final stations = await ref
          .read(dabStationsRepositoryProvider)
          .watchAll()
          .first;
      final station = stations
          .where(
            (s) =>
                s.freqKhz == currentDabStation.freqKhz &&
                s.serviceId == currentDabStation.serviceId,
          )
          .firstOrNull;
      if (station != null && mounted) await _playDabStation(station);
      return;
    }
    final currentProgram = ref.read(currentProgramNumberProvider);
    if (currentProgram == null) return;
    final favorites = await ref
        .read(favoritesRepositoryProvider)
        .watchFavorites()
        .first;
    final channel = favorites
        .where((c) => c.programNumber == currentProgram)
        .firstOrNull;
    if (channel != null && channel.needsReceiver && mounted) {
      await _play(channel);
    }
  }

  /// Points the DAB+ decoder (see DabRtlSdrService) at whichever RTL-SDR
  /// source was configured in Settings/RtlSdrTestScreen: "RTL-SDR-USB" mode
  /// opens the stick directly ([DabRtlSdrService.useDirectUsb]), otherwise
  /// the receiver connects to the configured rtl_tcp server.
  Future<void> _initDabServer() async {
    final settings = ref.read(settingsRepositoryProvider);
    final dab = ref.read(dabRtlSdrServiceProvider);
    if (await settings.getReceiverMode() == ReceiverMode.none) {
      if (mounted) setState(() => _dabServerReady = false);
      return;
    }
    final ok = await settings.getRtlSdrAutoStartOwnService()
        ? await dab.useDirectUsb()
        : await dab.setServer(
            host: await settings.getRtlSdrHost(),
            port: await settings.getRtlSdrPort(),
          );
    if (mounted) setState(() => _dabServerReady = ok);
  }

  Future<void> _autostart() async {
    final settings = ref.read(settingsRepositoryProvider);
    final mode = await settings.getAutostartMode();

    if (mode == AutostartMode.fixedStation) {
      final favorites = await ref
          .read(favoritesRepositoryProvider)
          .watchFavorites()
          .first;
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
    final lastFmFreq = lastPlayed?.fmFreqKhz;
    if (lastFmFreq != null) {
      final stations = await ref.read(fmStationsRepositoryProvider).watchAll().first;
      final station = stations.where((s) => s.freqKhz == lastFmFreq).firstOrNull;
      if (station != null) {
        if (mounted) await _playFmStation(station);
        return;
      }
    }
    final lastDabFreq = lastPlayed?.dabFreqKhz;
    final lastDabServiceId = lastPlayed?.dabServiceId;
    if (lastDabFreq != null && lastDabServiceId != null) {
      final stations = await ref
          .read(dabStationsRepositoryProvider)
          .watchAll()
          .first;
      final station = stations
          .where(
            (s) => s.freqKhz == lastDabFreq && s.serviceId == lastDabServiceId,
          )
          .firstOrNull;
      if (station != null) {
        if (mounted) await _playDabStation(station);
        return;
      }
    }

    final favorites = await ref
        .read(favoritesRepositoryProvider)
        .watchFavorites()
        .first;
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
  void _setNowPlayingFavorite(
    FavoriteChannel channel, {
    required bool playing,
  }) {
    ref
        .read(radioAudioHandlerProvider.future)
        .then(
          (handler) => handler.setChannel(channel, playing: playing),
          onError: (_) {},
        );
  }

  void _setNowPlayingDabStation(DabStation station, {required bool playing}) {
    ref
        .read(radioAudioHandlerProvider.future)
        .then(
          (handler) => handler.setDabStation(station, playing: playing),
          onError: (_) {},
        );
  }

  Future<void> _play(FavoriteChannel channel) async {
    _resetPlaybackState();
    ref.read(currentDabStationProvider.notifier).set(null);
    ref.read(currentFmStationProvider.notifier).set(null);
    ref.read(currentProgramNumberProvider.notifier).set(channel.programNumber);
    ref
        .read(settingsRepositoryProvider)
        .setLastPlayedFavorite(channel.programNumber);

    final url = channel.internetStreamUrl;
    if (url != null) {
      // Supersedes a DAB+/FM tune still in progress (see _receiverWanted).
      _dabPlayGeneration++;
      _receiverWanted = false;
      await _stopReceiver();
      await ref.read(audioPlayerServiceProvider).stop();
      _setNowPlayingFavorite(channel, playing: true);
      await ref.read(audioPlayerServiceProvider).playStream(url);
      return;
    }

    await ref.read(audioPlayerServiceProvider).stop();
    final fmFreqKhz = channel.fmFreqKhz;
    if (fmFreqKhz != null) {
      await _playFm(fmFreqKhz, onPlaying: () => _setNowPlayingFavorite(channel, playing: true));
      return;
    }
    final freqKhz = channel.dabFreqKhz;
    final serviceId = channel.dabServiceId;
    if (freqKhz == null || serviceId == null) return;
    await _playDab(
      freqKhz: freqKhz,
      serviceId: serviceId,
      onPlaying: () => _setNowPlayingFavorite(channel, playing: true),
    );
  }

  /// Plays a DAB+ station directly from the sidebar's "DAB-Sender" category
  /// (see FavoritesSidebar), without it being a saved favorite - the
  /// counterpart to [_play] for that case. [currentDabStationProvider] tracks
  /// its identity the way [currentProgramNumberProvider] does for favorites,
  /// since it has no program number of its own.
  Future<void> _playDabStation(DabStation station) async {
    _resetPlaybackState();
    ref.read(currentProgramNumberProvider.notifier).set(null);
    ref.read(currentFmStationProvider.notifier).set(null);
    ref.read(currentDabStationProvider.notifier).set((
      freqKhz: station.freqKhz,
      serviceId: station.serviceId,
    ));
    ref
        .read(settingsRepositoryProvider)
        .setLastPlayedDabStation(station.freqKhz, station.serviceId);

    await ref.read(audioPlayerServiceProvider).stop();
    await _playDab(
      freqKhz: station.freqKhz,
      serviceId: station.serviceId,
      onPlaying: () => _setNowPlayingDabStation(station, playing: true),
    );
  }

  /// Plays an FM station straight from the sidebar's FM tab - the FM
  /// counterpart of [_playDabStation].
  Future<void> _playFmStation(FmStation station) async {
    _resetPlaybackState();
    ref.read(currentProgramNumberProvider.notifier).set(null);
    ref.read(currentDabStationProvider.notifier).set(null);
    ref.read(currentFmStationProvider.notifier).set(station.freqKhz);
    ref.read(settingsRepositoryProvider).setLastPlayedFmStation(station.freqKhz);
    await ref.read(audioPlayerServiceProvider).stop();
    await _playFm(station.freqKhz, onPlaying: () => _setNowPlayingFmStation(station, playing: true));
  }

  void _setNowPlayingFmStation(FmStation station, {required bool playing}) {
    ref.read(radioAudioHandlerProvider.future).then(
          (handler) => handler.setFmStation(station, playing: playing),
          onError: (_) {},
        );
  }

  /// Stops whatever the receiver is doing (DAB+ or FM) - before internet
  /// radio, or on pause.
  Future<void> _stopReceiver() async {
    final dab = ref.read(dabRtlSdrServiceProvider);
    await dab.stopPlayback();
    // Unconditionally: callers may already have reset _fmFreqKhz.
    await dab.fmStop();
  }

  /// Back from a screen that tunes the receiver on its own (scans, manual
  /// FM tuning): whatever DAB+/FM station was playing here is silent now,
  /// so it's tuned in again.
  Future<void> _afterReceiverScreen() async {
    if (!mounted || !ref.read(receiverInterruptedProvider)) return;
    ref.read(receiverInterruptedProvider.notifier).set(false);
    if (_isDabSelected) await _resumeCurrentPlayback();
  }

  /// Back from the settings: the receiver follows the (possibly new) default
  /// source, and a station interrupted there plays again.
  Future<void> _afterSettings() async {
    if (!mounted || !ref.read(receiverInterruptedProvider)) return;
    await _initDabServer();
    await _afterReceiverScreen();
  }

  /// Plays what another screen asked for (see [playRequestProvider]).
  void _onPlayRequest(PlayRequest? request) {
    if (request == null) return;
    ref.read(playRequestProvider.notifier).clear();
    // Playing something new is a fresh start, nothing to resume later.
    ref.read(receiverInterruptedProvider.notifier).set(false);
    if (request.dab case final station?) _playDabStation(station);
    if (request.fm case final station?) _playFmStation(station);
    if (request.favorite case final channel?) _play(channel);
  }

  /// Shared FM playback path for favorites and the FM tab. Uses the same
  /// generation counter as [_playDab] - both drive the one tuner, so any
  /// newer request supersedes an older retry of either kind.
  Future<void> _playFm(int freqKhz, {required VoidCallback onPlaying}) async {
    final myGeneration = ++_dabPlayGeneration;
    _receiverWanted = true;
    if (ref.read(receiverModeProvider) == ReceiverMode.none) {
      if (mounted) setState(() => _dabStatusText = 'Kein Radio-Empfänger eingerichtet (Einstellungen)');
      return;
    }
    if (mounted) {
      setState(() {
        _fmFreqKhz = freqKhz;
        _dabStatusText = 'Sender wird eingestellt…';
      });
    }
    final ok = await ref.read(dabRtlSdrServiceProvider).fmPlay(freqKhz);
    if (!mounted) return;
    if (myGeneration != _dabPlayGeneration) return _dropSupersededTune();
    setState(() {
      _dabTuned = ok;
      _dabStatusText = ok
          ? null
          : (_dabConnectionWarning ??
              (_dabServerReady ? 'UKW-Empfang fehlgeschlagen.' : 'RTL-SDR-Quelle nicht erreichbar - versuche erneut…'));
    });
    if (ok) {
      onPlaying();
    } else if (!_dabServerReady) {
      // Most commonly right after boot, before the source is up - same
      // retry as DAB+.
      Future.delayed(const Duration(seconds: 5), () async {
        if (!mounted || myGeneration != _dabPlayGeneration) return;
        await _initDabServer();
        if (!mounted || myGeneration != _dabPlayGeneration) return;
        _playFm(freqKhz, onPlaying: onPlaying);
      });
    }
  }

  /// Bumped on every [_playDab] call (whether from the user picking a
  /// station or an auto-retry firing below) so a retry scheduled for one
  /// attempt can tell whether it's since been superseded - by the user
  /// switching stations, or by another retry already having fired - and
  /// bail out instead of fighting over the tuner with whatever's current.
  int _dabPlayGeneration = 0;

  /// Whether the newest selection uses the receiver (DAB+/FM). False after
  /// switching to internet radio or pausing - then a tune that was still
  /// running when the user switched must not leave its audio playing
  /// (issue #1: the previous DAB+ station came through over internet radio).
  bool _receiverWanted = false;

  /// A DAB+/FM tune finished after the user had already picked something
  /// else. Another receiver station takes the tuner over on its own; for
  /// internet radio / pause the receiver is stopped here, because the native
  /// side started the superseded station's audio.
  Future<void> _dropSupersededTune() async {
    if (!_receiverWanted) await _stopReceiver();
  }

  /// Shared DAB+ playback path for both [_play] (favorites) and
  /// [_playDabStation]: tunes+decodes via the DAB+ receiver
  /// (DabRtlSdrService) and waits for the result in a single await.
  Future<void> _playDab({
    required int freqKhz,
    required int serviceId,
    required VoidCallback onPlaying,
  }) async {
    final myGeneration = ++_dabPlayGeneration;
    _receiverWanted = true;
    // E.g. a DAB+ favorite left over from before "Kein Empfänger" was chosen.
    if (ref.read(receiverModeProvider) == ReceiverMode.none) {
      if (mounted) setState(() => _dabStatusText = 'Kein Radio-Empfänger eingerichtet (Einstellungen)');
      return;
    }
    if (mounted) setState(() => _dabStatusText = 'Sender wird getunt…');
    final ok = await ref
        .read(dabRtlSdrServiceProvider)
        .playService(freqKhz: freqKhz, serviceId: serviceId);
    if (!mounted) return;
    if (myGeneration != _dabPlayGeneration) return _dropSupersededTune();
    // Weak/absent reception ("Kein Signal!", server up but no usable
    // signal on this frequency) is often transient - a brief fade, or the
    // tuner needing another cycle - so keep retrying every second,
    // indefinitely, rather than leaving the user stuck on a dead station
    // until they manually reselect it. Not applied to the other two
    // failure cases:
    // "_dabConnectionWarning" already has its own auto-reconnect loop (see
    // 'connectionMessage' in _onDabEvent), and "server not reachable" means
    // there's no DAB+ source at all to retry against.
    final noSignal = !ok && _dabConnectionWarning == null && _dabServerReady;
    // An rtl_tcp source over the network that couldn't be reached at all -
    // most commonly an autostart right after boot, before the network is
    // up, which used to leave this stuck on "nicht erreichbar" for good.
    // Direct-USB mode is excluded: it has no network dependency, and a
    // replugged dongle already re-inits via _onUsbDeviceEvent.
    final sourceUnreachable =
        !ok &&
        _dabConnectionWarning == null &&
        !_dabServerReady &&
        !await ref.read(settingsRepositoryProvider).getRtlSdrAutoStartOwnService();
    if (!mounted || myGeneration != _dabPlayGeneration) return;
    setState(() {
      _dabTuned = ok;
      _dabStatusText = ok
          ? null
          : (_dabConnectionWarning ??
                (_dabServerReady
                    ? (noSignal ? 'Kein Signal! - Versuche erneut…' : 'Kein Signal!')
                    : (sourceUnreachable
                          ? 'RTL-SDR-Quelle nicht erreichbar - versuche erneut…'
                          : 'RTL-SDR-Quelle nicht erreichbar.')));
    });
    if (noSignal) {
      Future.delayed(const Duration(seconds: 1), () {
        if (!mounted || myGeneration != _dabPlayGeneration) return;
        _playDab(freqKhz: freqKhz, serviceId: serviceId, onPlaying: onPlaying);
      });
    }
    if (sourceUnreachable) {
      Future.delayed(const Duration(seconds: 5), () async {
        if (!mounted || myGeneration != _dabPlayGeneration) return;
        await _initDabServer();
        if (!mounted || myGeneration != _dabPlayGeneration) return;
        _playDab(freqKhz: freqKhz, serviceId: serviceId, onPlaying: onPlaying);
      });
    }
    if (ok) onPlaying();
  }

  /// Whether the currently selected station (favorite or a raw DAB+ station
  /// - see [_play]/[_playDabStation]) is a DAB+ one, for the remote-control
  /// Play/Pause/Stop handling below, which needs different actions for DAB+
  /// (tune/detune) vs. internet radio (actual audio pause/resume).
  bool get _isDabSelected {
    final programNumber = ref.read(currentProgramNumberProvider);
    if (programNumber != null) {
      final favorites =
          ref.read(favoritesStreamProvider).value ?? const <FavoriteChannel>[];
      final channel = favorites
          .where((c) => c.programNumber == programNumber)
          .firstOrNull;
      if (channel != null) return channel.needsReceiver;
    }
    return ref.read(currentDabStationProvider) != null || ref.read(currentFmStationProvider) != null;
  }

  /// DAB+ has no real "pause" (it's a live broadcast) - stopping the
  /// tune/decode pipeline is the closest equivalent, and resuming re-tunes
  /// (see [_resumeDabAfterReconnect], reused here since it already does
  /// exactly that for whatever's currently selected).
  Future<void> _pauseCurrentPlayback() async {
    if (_isDabSelected) {
      // Also cancels a tune still in progress.
      _dabPlayGeneration++;
      _receiverWanted = false;
      await _stopReceiver();
      if (mounted) setState(() => _dabTuned = false);
    } else {
      await ref.read(audioPlayerServiceProvider).pause();
    }
  }

  Future<void> _resumeCurrentPlayback() async {
    if (_isDabSelected) {
      await _resumeDabAfterReconnect();
    } else {
      await ref.read(audioPlayerServiceProvider).resume();
    }
  }

  Future<void> _togglePlayPause() async {
    final playing = _isDabSelected
        ? _dabTuned
        : (_playerState?.playing ?? false);
    await (playing ? _pauseCurrentPlayback() : _resumeCurrentPlayback());
  }

  /// Moves to the previous/next station in whichever list the sidebar is
  /// currently showing (see [effectiveSidebarCategoryProvider]) - the
  /// remote's channel-up/down-style keys step through that list the same
  /// way tapping/D-Pad-selecting a row in it would, wrapping around at
  /// either end.
  Future<void> _stepStation(int direction) async {
    // A listening band is open - its channels, not the radio stations.
    if (ref.read(remoteStepOverrideProvider) case final step?) {
      step(direction);
      return;
    }
    final category = ref.read(effectiveSidebarCategoryProvider);
    if (category == SidebarCategory.fmStations) {
      final stations = ref.read(fmStationsStreamProvider).value ?? const <FmStation>[];
      if (stations.isEmpty) return;
      final index = stations.indexWhere((s) => s.freqKhz == ref.read(currentFmStationProvider));
      final nextIndex = ((index == -1 ? 0 : index + direction) % stations.length + stations.length) % stations.length;
      await _playFmStation(stations[nextIndex]);
      return;
    }
    if (category == SidebarCategory.dabStations) {
      final stations =
          ref.read(sortedDabStationsProvider).value ?? const <DabStation>[];
      if (stations.isEmpty) return;
      final current = ref.read(currentDabStationProvider);
      final index = current == null
          ? -1
          : stations.indexWhere(
              (s) =>
                  s.freqKhz == current.freqKhz &&
                  s.serviceId == current.serviceId,
            );
      final nextIndex =
          ((index == -1 ? 0 : index + direction) % stations.length +
              stations.length) %
          stations.length;
      await _playDabStation(stations[nextIndex]);
    } else {
      final favorites =
          ref.read(favoritesStreamProvider).value ?? const <FavoriteChannel>[];
      if (favorites.isEmpty) return;
      final current = ref.read(currentProgramNumberProvider);
      final index = current == null
          ? -1
          : favorites.indexWhere((c) => c.programNumber == current);
      final nextIndex =
          ((index == -1 ? 0 : index + direction) % favorites.length +
              favorites.length) %
          favorites.length;
      await _play(favorites[nextIndex]);
    }
  }

  /// Physical remote-control keys - previous/next track and page/channel
  /// up/down both step through the currently shown station list (whichever
  /// of the two really arrives depends on the remote/Android TV box, so both
  /// are mapped to the same action rather than guessing one); play/pause and
  /// stop control playback, including for internet radio. Attached to a
  /// plain (non-autofocus) [Focus] wrapping the whole screen - unhandled key
  /// events bubble up the Focus tree to it regardless of which row/button
  /// currently has D-Pad focus, but *only* while this screen's own Focus
  /// subtree is actually part of the focused chain, i.e. not while Settings/
  /// DAB-Sender-Suche/etc. are pushed on top (Navigator gives each route its
  /// own FocusScope), which is exactly the "not in Einstellungen etc."
  /// restriction that was asked for - no manual route-tracking needed.
  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.mediaTrackPrevious ||
        key == LogicalKeyboardKey.pageDown ||
        key == LogicalKeyboardKey.channelDown) {
      _stepStation(-1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.mediaTrackNext ||
        key == LogicalKeyboardKey.pageUp ||
        key == LogicalKeyboardKey.channelUp) {
      _stepStation(1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.mediaPlayPause) {
      _togglePlayPause();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.mediaPlay) {
      _resumeCurrentPlayback();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.mediaPause ||
        key == LogicalKeyboardKey.mediaStop) {
      _pauseCurrentPlayback();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(playRequestProvider, (_, request) => _onPlayRequest(request));
    final bands = ref.watch(listeningBandsProvider);
    final favorites = ref.watch(favoritesStreamProvider).value ?? const [];
    final currentProgram = ref.watch(currentProgramNumberProvider);
    final currentChannel = currentProgram == null
        ? null
        : favorites.where((c) => c.programNumber == currentProgram).firstOrNull;

    final currentDabStation = ref.watch(currentDabStationProvider);
    final currentRawDabStation =
        currentChannel != null || currentDabStation == null
        ? null
        : (ref.watch(dabStationsStreamProvider).value ?? const <DabStation>[])
              .where(
                (s) =>
                    s.freqKhz == currentDabStation.freqKhz &&
                    s.serviceId == currentDabStation.serviceId,
              )
              .firstOrNull;

    final currentFmFreq = ref.watch(currentFmStationProvider);
    final currentRawFmStation = currentChannel != null || currentFmFreq == null
        ? null
        : (ref.watch(fmStationsStreamProvider).value ?? const <FmStation>[])
            .where((s) => s.freqKhz == currentFmFreq)
            .firstOrNull;

    // DAB+ or FM - the receiver, not the internet player.
    final isDab = (currentChannel?.needsReceiver ?? false) ||
        currentRawDabStation != null ||
        currentRawFmStation != null;
    final isPlaying = isDab ? _dabTuned : (_playerState?.playing ?? false);
    final isBuffering =
        !isDab &&
        (_playerState?.processingState == ProcessingState.buffering ||
            _playerState?.processingState == ProcessingState.loading);
    // FM: RDS radiotext (stereo/mono is the badge, see fmStereo below).
    final subtitle = _fmFreqKhz != null
        ? (_dabStatusText ?? _fmRt)
        : (isDab ? _dabStatusText : _icyTitle);
    final errorMessage = isDab ? _dabConnectionWarning : _playbackError;

    return Focus(
      onKeyEvent: _handleKey,
      child: Scaffold(
        backgroundColor: const Color(0xFF05070A),
        body: Stack(
          fit: StackFit.expand,
          children: [
            SafeArea(
              child: Column(
                children: [
                  _MenuBar(
                    // No DAB+/FM station search without a receiver.
                    onOpenDabStations: ref.watch(receiverModeProvider) == ReceiverMode.none
                        ? null
                        : () => Navigator.of(context)
                            .push(MaterialPageRoute(builder: (_) => const DabStationsScreen()))
                            .then((_) => _afterReceiverScreen()),
                    listeningButtons: [
                      if (ref.watch(receiverModeProvider) != ReceiverMode.none)
                        for (final (enabled, icon, label, screen) in [
                          (bands.cb, Icons.forum, 'CB-Funk', () => ScannerScreen(plan: cbBandPlan())),
                          (
                            bands.ham,
                            Icons.cell_tower,
                            'Amateurfunk',
                            () => ScannerScreen(plan: hamBandPlans.first, variants: hamBandPlans),
                          ),
                          (bands.airband, Icons.flight, 'Flugfunk', () => ScannerScreen(plan: airBandPlan)),
                          (bands.mil, Icons.shield_outlined, 'Militärfunk', () => ScannerScreen(plan: milBandPlan)),
                        ])
                          if (enabled)
                            (
                              icon,
                              label,
                              () => Navigator.of(context)
                                  .push(MaterialPageRoute(builder: (_) => screen()))
                                  .then((_) => _afterReceiverScreen()),
                            ),
                    ],
                    onOpenFmStations: ref.watch(receiverModeProvider) == ReceiverMode.none
                        ? null
                        : () => Navigator.of(context)
                            .push(MaterialPageRoute(builder: (_) => const FmStationsScreen()))
                            .then((_) => _afterReceiverScreen()),
                    onOpenInternetSearch: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => const InternetRadioSearchScreen(),
                      ),
                    ),
                    // The receiver settings may have changed the default
                    // rtl_tcp server or freed it for "Testen".
                    onOpenSettings: () => Navigator.of(context)
                        .push(MaterialPageRoute(builder: (_) => const SettingsScreen()))
                        .then((_) => _afterSettings()),
                  ),
                  Expanded(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(
                          // The dimmed station-logo background used to cover
                          // the whole screen, including the sidebar/top/bottom
                          // bars - now that those all have their own opaque
                          // background, it only makes sense - and is only
                          // visible - behind the weather/radar tiles, so it's
                          // scoped (and BoxFit.cover-fitted) to just this area.
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              BackgroundLayer(
                                logoLocalPath:
                                    currentChannel?.logoLocalPath ??
                                    currentRawDabStation?.logoLocalPath ??
                                    currentRawFmStation?.logoLocalPath,
                                logoUrl:
                                    currentChannel?.logoUrl ??
                                    currentRawDabStation?.logoUrl ??
                                    currentRawFmStation?.logoUrl,
                              ),
                              const _WeatherRadarColumn(),
                            ],
                          ),
                        ),
                        FavoritesSidebar(
                          onSelect: _play,
                          onSelectDabStation: _playDabStation,
                          onSelectFmStation: _playFmStation,
                          onEditDone: _afterReceiverScreen,
                        ),
                      ],
                    ),
                  ),
                  NowPlayingBanner(
                    programNumber: currentChannel?.programNumber,
                    displayName:
                        currentChannel?.displayName ??
                        currentRawDabStation?.displayLabel ??
                        currentRawFmStation?.displayLabel,
                    logoUrl:
                        currentChannel?.logoUrl ??
                        currentRawDabStation?.logoUrl ??
                        currentRawFmStation?.logoUrl,
                    logoLocalPath:
                        _liveMotLogoPath ??
                        currentChannel?.logoLocalPath ??
                        currentRawDabStation?.logoLocalPath ??
                        currentRawFmStation?.logoLocalPath,
                    isPlaying: isPlaying,
                    isBuffering: isBuffering,
                    subtitle: (subtitle?.isEmpty ?? true) ? null : subtitle,
                    errorMessage: errorMessage,
                    snrDb: (isDab && isPlaying) ? _dabSnrDb : null,
                    quality: isPlaying ? (isDab ? _dabQuality : _netQuality) : null,
                    fmStereo: isPlaying && _fmFreqKhz != null ? _fmStereo : null,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Hourly forecast, rain radar and sun/moon as compact tiles, centered in
/// the available area (both axes) - deliberately *not* filling the whole
/// space (there's no need for any of them to be that big). Sized from a
/// base size scaled by the user's per-tile size setting (see
/// WeatherDisplaySettings' own doc comment).
///
/// The weather tile can span the full height of the other two stacked on
/// top of each other next to it ("von ganz oben bis ganz nach unten" - see
/// WeatherDisplaySettings.weatherSpanTwoTiles, on by default) rather than
/// sitting in the same flow as everything else, which is why this isn't a
/// single [Wrap] of same-sized tiles anymore: it's an explicit two-column
/// layout, with the right column's total height (radar + sun, whichever are
/// actually enabled) driving the left column's single tile's height so
/// their bottoms line up - unless that setting is off, in which case the
/// weather tile is just its own single-tile height like the other two.
class _WeatherRadarColumn extends ConsumerWidget {
  const _WeatherRadarColumn();

  // All three tiles share the same base width (widescreen, not square) so
  // that at 100% they line up as one visually consistent group.
  static const _tileBaseWidth = 420.0;
  static const _tileBaseHeight = 260.0;
  static const _tileRadius = 16.0;
  static const _tileGap = 16.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(weatherDisplaySettingsProvider);
    if (!settings.weatherEnabled && !settings.radarEnabled && !settings.sunEnabled) {
      return const SizedBox.shrink();
    }

    final rightColumnTiles = <Widget>[
      if (settings.radarEnabled)
        _Tile(
          width: _tileBaseWidth * settings.radarScale,
          height: _tileBaseHeight * settings.radarScale,
          radius: _tileRadius,
          child: RadarPanel(
            urlTemplate: settings.radarUrl,
            isWebPage: settings.radarIsWebPage,
            webCss: settings.radarWebCss,
            token: settings.radarAuthEnabled ? settings.radarToken : null,
            lat: settings.lat,
            lon: settings.lon,
            radiusKm: settings.radarRadiusKm.toDouble(),
            dimming: settings.radarDimming,
          ),
        ),
      if (settings.sunEnabled)
        _Tile(
          width: _tileBaseWidth * settings.sunScale,
          height: _tileBaseHeight * settings.sunScale,
          radius: _tileRadius,
          child: SunMoonPanel(lat: settings.lat, lon: settings.lon, contentScale: settings.sunScale),
        ),
    ];
    final rightColumnHeight = rightColumnTiles.isEmpty
        ? 0.0
        : [
              if (settings.radarEnabled) _tileBaseHeight * settings.radarScale,
              if (settings.sunEnabled) _tileBaseHeight * settings.sunScale,
            ].reduce((a, b) => a + b) +
            _tileGap * (rightColumnTiles.length - 1);

    final weatherTile = settings.weatherEnabled
        ? _Tile(
            width: _tileBaseWidth * settings.weatherScale,
            height: settings.weatherSpanTwoTiles && rightColumnHeight > 0
                ? rightColumnHeight
                : _tileBaseHeight * settings.weatherScale,
            radius: _tileRadius,
            child: WeatherPanel(
              locationName: settings.locationName,
              lat: settings.lat,
              lon: settings.lon,
              contentScale: settings.weatherContentScale,
            ),
          )
        : null;

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ?weatherTile,
            if (weatherTile != null && rightColumnTiles.isNotEmpty) const SizedBox(width: _tileGap),
            if (rightColumnTiles.isNotEmpty)
              Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final (i, tile) in rightColumnTiles.indexed) ...[
                    if (i > 0) const SizedBox(height: _tileGap),
                    tile,
                  ],
                ],
              ),
          ],
        ),
      ),
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({
    required this.width,
    required this.height,
    required this.radius,
    required this.child,
  });

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
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.4),
                blurRadius: 12,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: child,
        ),
      ),
    );
  }
}

class _MenuBar extends StatelessWidget {
  /// Null hides the button (no receiver set up) - same for FM.
  final VoidCallback? onOpenDabStations;
  final VoidCallback? onOpenFmStations;
  /// Listening bands (see ScannerScreen): icon, label, open - left of a
  /// divider, apart from the radio buttons.
  final List<(IconData, String, VoidCallback)> listeningButtons;
  final VoidCallback onOpenInternetSearch;
  final VoidCallback onOpenSettings;

  const _MenuBar({
    required this.onOpenDabStations,
    required this.onOpenFmStations,
    this.listeningButtons = const [],
    required this.onOpenInternetSearch,
    required this.onOpenSettings,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      // Same treatment as NowPlayingBanner at the bottom, so the top and
      // bottom bars read as one consistent pair framing the content.
      color: Colors.black.withValues(alpha: 0.7),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      // A Row can't center the clock against the bar's own width once the
      // left (logo/title) and right (buttons) groups are different widths -
      // it'd only ever sit in the middle of the *remaining* space between
      // them. A Stack with each group Align-ed to its own edge and the
      // clock centered on the whole bar gets a true center regardless of
      // how wide either side group is.
      child: SizedBox(
        // Tall enough for the two-line logo/title group ("Home Radio" +
        // "Powered by Jay") - was 36 (just the logo's own height) before
        // that second line existed.
        height: 44,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Image.asset(
                      'assets/icon/applogo1.png',
                      width: 36,
                      height: 36,
                    ),
                  ),
                  const SizedBox(width: 10),
                  const Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Home Radio',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text(
                        'Powered by Jay',
                        style: TextStyle(
                          color: Colors.green,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const _Clock(),
            Align(
              alignment: Alignment.centerRight,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Listening bands (see ScannerScreen), set apart from the
                  // radio buttons by a divider.
                  for (final (icon, label, onOpen) in listeningButtons) ...[
                    _MenuBarButton(icon: icon, label: label, onPressed: onOpen),
                    const SizedBox(width: 4),
                  ],
                  if (listeningButtons.isNotEmpty)
                    Container(
                      width: 1,
                      height: 28,
                      margin: const EdgeInsets.symmetric(horizontal: 8),
                      color: Colors.white24,
                    ),
                  if (onOpenDabStations case final onOpen?) ...[
                    _MenuBarButton(
                      icon: Icons.radio,
                      label: 'DAB Sender suchen',
                      onPressed: onOpen,
                    ),
                    const SizedBox(width: 4),
                  ],
                  if (onOpenFmStations case final onOpen?) ...[
                    _MenuBarButton(
                      icon: Icons.graphic_eq,
                      label: 'UKW-Sender (FM)',
                      onPressed: onOpen,
                    ),
                    const SizedBox(width: 4),
                  ],
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
            ),
          ],
        ),
      ),
    );
  }
}

/// Live "HH:mm" clock, ticking every second but only rebuilding when the
/// displayed minute actually changes - optionally with the current weekday
/// and date to its left (see [showClockDateProvider]/SettingsScreen).
class _Clock extends ConsumerStatefulWidget {
  const _Clock();

  @override
  ConsumerState<_Clock> createState() => _ClockState();
}

class _ClockState extends ConsumerState<_Clock> {
  late String _timeText = _formatTime(DateTime.now());
  late String _dateText = _formatDate(DateTime.now());
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      final now = DateTime.now();
      final time = _formatTime(now);
      final date = _formatDate(now);
      if (time != _timeText || date != _dateText) {
        setState(() {
          _timeText = time;
          _dateText = date;
        });
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  static String _formatTime(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  static const _weekdays = [
    'Montag',
    'Dienstag',
    'Mittwoch',
    'Donnerstag',
    'Freitag',
    'Samstag',
    'Sonntag',
  ];

  static String _formatDate(DateTime t) {
    final weekday = _weekdays[t.weekday - 1];
    final day = t.day.toString().padLeft(2, '0');
    final month = t.month.toString().padLeft(2, '0');
    return '$weekday $day.$month.${t.year}';
  }

  @override
  Widget build(BuildContext context) {
    final showDate = ref.watch(showClockDateProvider);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (showDate) ...[
          Text(
            _dateText,
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(width: 12),
        ],
        Text(
          _timeText,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 20,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
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
                        child: Text(
                          widget.label,
                          style: const TextStyle(color: Colors.white),
                        ),
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
