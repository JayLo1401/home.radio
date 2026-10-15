import 'package:audio_service/audio_service.dart';
import 'package:just_audio/just_audio.dart' as just_audio;

import '../db/database.dart' show DabStation;
import '../models/favorite_channel.dart';
import '../repositories/dab_stations_repository.dart' show DabStationDisplay;
import 'audio_player_service.dart';

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
      final item = mediaItem.value;
      if (item == null || _player.currentUrl == null) return;
      mediaItem.add(item.copyWith(artist: title));
    });
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
    mediaItem.add(
      MediaItem(
        id: channel.programNumber.toString(),
        title: channel.displayName,
        album: channel.sourceType == FavoriteSourceType.dab ? 'DAB+' : 'Internetradio',
        artUri: channel.logoUrl != null ? Uri.tryParse(channel.logoUrl!) : null,
      ),
    );
    playbackState.add(
      playbackState.value.copyWith(
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
    mediaItem.add(
      MediaItem(
        id: 'dab_${station.freqKhz}_${station.serviceId}',
        title: station.displayLabel,
        album: 'DAB+',
      ),
    );
    playbackState.add(
      playbackState.value.copyWith(
        controls: _controlsFor(playing),
        systemActions: _systemActions,
        playing: playing,
        processingState: AudioProcessingState.ready,
      ),
    );
  }

  void clearChannel() {
    mediaItem.add(null);
    playbackState.add(
      playbackState.value.copyWith(playing: false, processingState: AudioProcessingState.idle),
    );
  }

  @override
  Future<void> play() async {
    await _onPlay?.call();
  }

  @override
  Future<void> pause() async {
    await _onPause?.call();
  }

  @override
  Future<void> skipToNext() async {
    await _onSkipNext?.call();
  }

  @override
  Future<void> skipToPrevious() async {
    await _onSkipPrevious?.call();
  }

  /// Treated the same as [pause] (not a hard stop that forgets the station)
  /// for consistency with every other control surface (in-app remote-key
  /// handling, the notification's own Play/Pause button) - see HomeScreen's
  /// key handling for why "stop" without a resumable position doesn't mean
  /// much more than "pause" for a live stream anyway.
  @override
  Future<void> stop() async {
    if (_onPause != null) {
      await _onPause!();
    } else {
      await _player.stop();
      playbackState.add(playbackState.value.copyWith(playing: false));
    }
  }

  void _broadcastPlayerState(just_audio.PlayerState state) {
    // Only internet-radio playback drives this - a DAB "playing" state (set
    // via [setChannel]) is left alone since just_audio isn't involved there.
    if (_player.currentUrl == null) return;
    playbackState.add(
      playbackState.value.copyWith(
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
