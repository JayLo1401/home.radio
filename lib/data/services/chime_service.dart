import 'package:flutter/services.dart';

import 'audio_player_service.dart';

/// Bell for the "Bitte abholen" popup (see ChimePlugin.kt for why it's a
/// natively synthesized sound without audio focus rather than a second
/// just_audio player: taking focus would pause the running radio).
///
/// The radio is turned down while the bell rings so it's actually audible -
/// DAB+ natively inside ChimePlugin, internet radio here, around the native
/// call (which only returns once the bell is done).
class ChimeService {
  ChimeService(this._audio);

  static const _channel = MethodChannel('home_radio/chime');
  static const _duckVolume = 0.2;

  final AudioPlayerService _audio;

  Future<void> play() async {
    final ducking = _audio.rampVolume(_duckVolume, const Duration(milliseconds: 250));
    try {
      await _channel.invokeMethod('play');
    } catch (_) {
      // A missing bell isn't worth surfacing - the popup still shows.
    } finally {
      await ducking;
      await _audio.rampVolume(1.0, const Duration(milliseconds: 600));
    }
  }
}
