import 'package:audio_service/audio_service.dart';
import 'package:just_audio/just_audio.dart' as just_audio;

import '../../l10n/l10n.dart';
import '../db/database.dart' show DabStation, FmStation;
import '../models/favorite_channel.dart';
import '../repositories/dab_stations_repository.dart' show DabStationDisplay;
import '../repositories/fm_stations_repository.dart' show FmStationDisplay;
import 'audio_player_service.dart';

/// Another player of the app that takes the media session over while it
/// is in use - Musik: its track shows in the notification / Home
/// Assistant, and the remote's media keys, the notification's buttons and
/// Home Assistant control it. See [RadioAudioHandler.attachGuest].
abstract class MediaSessionGuest {
  Future<void> play();
  Future<void> pause();
  Future<void> stop();
  Future<void> skipToNext();
  Future<void> skipToPrevious();
  Future<void> seek(Duration position);

  /// The radio started playing (a station was chosen, Radio opened again):
  /// the guest stops - the session already went back to the radio.
  void radioStarted();
}

/// Mirrors the app's current channel/playback state into an Android
/// MediaSession (via `audio_service`) - this is what makes the playing
/// station show up as a proper media notification/"Now Playing" card for
/// Home Assistant's media player integration and the TV's launcher, instead
/// of only being visible inside the app itself.
///
/// Internet radio audio is still actually played by [AudioPlayerService]
/// (just_audio) - this handler only forwards its state. DAB+ doesn't have
/// real decoded audio yet (see the project plan's DAB+ phase), so once a
/// DAB+ favorite is tuned this reports it as "playing" with the station's
/// metadata anyway, since RF lock is the closest equivalent state the app
/// has right now and that's what should show up as "on air" externally.
class RadioAudioHandler extends BaseAudioHandler {
  final AudioPlayerService _player;

  RadioAudioHandler(this._player) {
    _player.playerStateStream.listen(_broadcastPlayerState);
    // Internet radio's "now playing" (ICY StreamTitle) as the MediaItem's
    // artist line, so the notification/Home Assistant show the current
    // song too, not just the station name.
    _player.icyTitleStream.listen((title) {
      final item = _radioItem;
      if (item == null || _player.currentUrl == null) return;
      _publishRadioItem(item.copyWith(artist: title));
    });
  }

  // --- Sharing the session with another player (Musik) ---
  //
  // Without a guest everything below behaves as before: the radio's item
  // and state go straight out. With a guest attached, the radio's own
  // updates are only kept (and published again when the guest leaves),
  // the guest's go out instead, and the controls go to the guest. As soon
  // as the radio reports "playing" the guest is told to stop and the
  // session is the radio's again.

  MediaSessionGuest? _guest;
  MediaItem? _radioItem;
  PlaybackState? _radioState;

  /// The radio's last state (what it reported, also while a guest held the
  /// session) - the base its updates build on.
  PlaybackState get _radioBase => _radioState ?? PlaybackState();

  void _publishRadioItem(MediaItem? item) {
    _radioItem = item;
    if (_guest == null) mediaItem.add(item);
  }

  void _publishRadioState(PlaybackState state) {
    // Only a start counts - not the reports of a radio that was still
    // playing when the guest came (it is being stopped right then).
    final started = state.playing && !(_radioState?.playing ?? false);
    _radioState = state;
    final guest = _guest;
    if (guest != null && started) {
      _guest = null;
      mediaItem.add(_radioItem);
      guest.radioStarted();
    }
    if (_guest == null) playbackState.add(state);
  }

  /// Whether a guest holds the session now.
  bool get hasGuest => _guest != null;

  /// [guest] takes the session over (replacing another guest).
  void attachGuest(MediaSessionGuest guest) => _guest = guest;

  /// The guest's track - ignored unless [guest] holds the session. Send it
  /// only when it changed: every item goes to Android, which loads its
  /// artwork again.
  void publishGuestItem(MediaSessionGuest guest, MediaItem? item) {
    if (_guest != guest) return;
    mediaItem.add(item);
  }

  /// The guest's playback state - ignored unless [guest] holds the session.
  /// Every state rebuilds the notification: only on real changes.
  void publishGuestState(MediaSessionGuest guest, PlaybackState state) {
    if (_guest != guest) return;
    playbackState.add(state);
  }

  /// [guest] gives the session back: the radio's last item and state show
  /// again.
  void detachGuest(MediaSessionGuest guest) {
    if (_guest != guest) return;
    _guest = null;
    mediaItem.add(_radioItem);
    playbackState.add(_radioState ?? PlaybackState());
  }

  // The actual station play/pause/skip logic lives in HomeScreen (it needs
  // favorites/DAB-station lists, the DAB tuner, etc. that this handler has
  // no business owning) - these are what Android calls into for hardware
  // media-button presses, Bluetooth headset controls, the notification's
  // own buttons and Assistant "pause music" style requests, including while
  // the app is backgrounded, none of which reach HomeScreen's own in-app
  // KeyEvent handling (that only sees events while the app is foregrounded -
  // see its own doc comment). Bound once, right after HomeScreen resolves
  // this handler.
  Future<void> Function()? _onPlay;
  Future<void> Function()? _onPause;
  Future<void> Function()? _onSkipNext;
  Future<void> Function()? _onSkipPrevious;

  void bindControls({
    required Future<void> Function() onPlay,
    required Future<void> Function() onPause,
    required Future<void> Function() onSkipNext,
    required Future<void> Function() onSkipPrevious,
  }) {
    _onPlay = onPlay;
    _onPause = onPause;
    _onSkipNext = onSkipNext;
    _onSkipPrevious = onSkipPrevious;
  }

  static const _systemActions = {
    MediaAction.play,
    MediaAction.pause,
    MediaAction.stop,
    MediaAction.skipToNext,
    MediaAction.skipToPrevious,
  };

  List<MediaControl> _controlsFor(bool playing) => [
        MediaControl.skipToPrevious,
        playing ? MediaControl.pause : MediaControl.play,
        MediaControl.skipToNext,
        MediaControl.stop,
      ];

  void setChannel(FavoriteChannel channel, {required bool playing}) {
    _publishRadioItem(
      MediaItem(
        id: channel.programNumber.toString(),
        title: channel.displayName,
        album: switch (channel.sourceType) {
          FavoriteSourceType.dab => 'DAB+',
          FavoriteSourceType.fm => l10n.radioSourceFm,
          FavoriteSourceType.internet => l10n.radioSourceInternet,
        },
        artUri: channel.logoUrl != null ? Uri.tryParse(channel.logoUrl!) : null,
      ),
    );
    _publishRadioState(
      _radioBase.copyWith(
        controls: _controlsFor(playing),
        systemActions: _systemActions,
        playing: playing,
        processingState: AudioProcessingState.ready,
      ),
    );
  }

  /// Same as [setChannel] but for a DAB+ station played directly from "Alle
  /// DAB+ Sender" (see FavoritesSidebar) without being a favorite - it has no
  /// program number, so the MediaItem id is built from its frequency/service
  /// id instead.
  void setDabStation(DabStation station, {required bool playing}) {
    _publishRadioItem(
      MediaItem(
        id: 'dab_${station.freqKhz}_${station.serviceId}',
        title: station.displayLabel,
        album: 'DAB+',
      ),
    );
    _publishRadioState(
      _radioBase.copyWith(
        controls: _controlsFor(playing),
        systemActions: _systemActions,
        playing: playing,
        processingState: AudioProcessingState.ready,
      ),
    );
  }

  /// Same as [setDabStation], for an FM station played from the FM tab.
  void setFmStation(FmStation station, {required bool playing}) {
    _publishRadioItem(
      MediaItem(
        id: 'fm_${station.freqKhz}',
        title: station.displayLabel,
        album: '${l10n.radioSourceFm} · ${station.frequencyLabel}',
      ),
    );
    _publishRadioState(
      _radioBase.copyWith(
        controls: _controlsFor(playing),
        systemActions: _systemActions,
        playing: playing,
        processingState: AudioProcessingState.ready,
      ),
    );
  }

  /// DAB+/FM stopped (or started again) from the app - otherwise Android
  /// keeps showing it as playing, and the remote's next Play/Pause press
  /// arrives as another "pause" instead of "play".
  void setPlaying(bool playing) {
    if (_player.currentUrl != null) return; // internet radio reports itself
    _publishRadioState(
      _radioBase.copyWith(
        controls: _controlsFor(playing),
        systemActions: _systemActions,
        playing: playing,
      ),
    );
  }

  void clearChannel() {
    _publishRadioItem(null);
    _publishRadioState(
      _radioBase.copyWith(playing: false, processingState: AudioProcessingState.idle),
    );
  }

  @override
  Future<void> play() async {
    final guest = _guest;
    if (guest != null) return guest.play();
    await _onPlay?.call();
  }

  @override
  Future<void> pause() async {
    final guest = _guest;
    if (guest != null) return guest.pause();
    await _onPause?.call();
  }

  @override
  Future<void> skipToNext() async {
    final guest = _guest;
    if (guest != null) return guest.skipToNext();
    await _onSkipNext?.call();
  }

  @override
  Future<void> skipToPrevious() async {
    final guest = _guest;
    if (guest != null) return guest.skipToPrevious();
    await _onSkipPrevious?.call();
  }

  /// Only the guest (Musik) can seek - a live stream can't.
  @override
  Future<void> seek(Duration position) async {
    await _guest?.seek(position);
  }

  /// Treated the same as [pause] (not a hard stop that forgets the station)
  /// for consistency with every other control surface (in-app remote-key
  /// handling, the notification's own Play/Pause button) - see HomeScreen's
  /// key handling for why "stop" without a resumable position doesn't mean
  /// much more than "pause" for a live stream anyway.
  @override
  Future<void> stop() async {
    final guest = _guest;
    if (guest != null) return guest.stop();
    if (_onPause != null) {
      await _onPause!();
    } else {
      await _player.stop();
      _publishRadioState(_radioBase.copyWith(playing: false));
    }
  }

  void _broadcastPlayerState(just_audio.PlayerState state) {
    // Only internet-radio playback drives this - a DAB "playing" state (set
    // via [setChannel]) is left alone since just_audio isn't involved there.
    if (_player.currentUrl == null) return;
    _publishRadioState(
      _radioBase.copyWith(
        controls: _controlsFor(state.playing),
        systemActions: _systemActions,
        playing: state.playing,
        processingState: _mapProcessingState(state.processingState),
      ),
    );
  }

  AudioProcessingState _mapProcessingState(just_audio.ProcessingState state) {
    switch (state) {
      case just_audio.ProcessingState.idle:
        return AudioProcessingState.idle;
      case just_audio.ProcessingState.loading:
        return AudioProcessingState.loading;
      case just_audio.ProcessingState.buffering:
        return AudioProcessingState.buffering;
      case just_audio.ProcessingState.ready:
        return AudioProcessingState.ready;
      case just_audio.ProcessingState.completed:
        return AudioProcessingState.completed;
    }
  }
}
