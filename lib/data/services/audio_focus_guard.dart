import 'dart:async';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';

/// While the Haussteuerung is in front, its web page may take Android's
/// audio focus for a sound of the dashboard (a doorbell, a chime, a camera
/// with sound). The radio and the music play on then instead of pausing -
/// the dashboard's sound plays over them. Everywhere else a lost focus
/// pauses them as before (another app took the speakers).
///
/// The internet radio ([AudioPlayerService]) and Musik ([MusicPlayer]) ask
/// [shouldPause]; DAB+/FM have their own switch on the native side.
class AudioFocusGuard {
  AudioFocusGuard._();

  static bool _keep = false;
  static bool _lostWhileKept = false;

  /// Whether the players play on when the focus is lost.
  static bool get keepPlaying => _keep;

  /// Whether the interruption [event] pauses the players.
  static bool shouldPause(AudioInterruptionEvent event) => shouldPauseFor(begin: event.begin);

  /// [shouldPause] without the event (for tests).
  static bool shouldPauseFor({required bool begin}) {
    if (!begin) return false;
    if (_keep) {
      _lostWhileKept = true;
      return false;
    }
    return true;
  }

  /// Switched on while the Haussteuerung is in front. Switched off again
  /// after a focus loss was ignored and something still plays ([playing]),
  /// the focus is taken back - so that another app taking it later stops
  /// the radio again. Never throws.
  static Future<void> setKeepPlaying(bool keep, {bool Function()? playing}) async {
    if (_keep == keep) return;
    _keep = keep;
    if (keep || !_lostWhileKept) return;
    _lostWhileKept = false;
    try {
      if (!(playing?.call() ?? false)) return;
      await (await AudioSession.instance).setActive(true);
    } catch (e) {
      debugPrint('audio focus: $e');
    }
  }

  /// Back to the start (tests).
  @visibleForTesting
  static void reset() {
    _keep = false;
    _lostWhileKept = false;
  }
}
