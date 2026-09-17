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
  }

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
        controls: [MediaControl.stop],
        systemActions: const {MediaAction.stop},
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
        controls: [MediaControl.stop],
        systemActions: const {MediaAction.stop},
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
  Future<void> stop() async {
    await _player.stop();
    playbackState.add(playbackState.value.copyWith(playing: false));
  }

  void _broadcastPlayerState(just_audio.PlayerState state) {
    // Only internet-radio playback drives this - a DAB "playing" state (set
    // via [setChannel]) is left alone since just_audio isn't involved there.
    if (_player.currentUrl == null) return;
    playbackState.add(
      playbackState.value.copyWith(
        controls: [MediaControl.stop],
        systemActions: const {MediaAction.stop},
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
