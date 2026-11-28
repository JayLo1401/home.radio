import 'package:audio_service/audio_service.dart' show AudioProcessingState;
import 'package:flutter/painting.dart' show Alignment;
import 'package:flutter/services.dart' show LogicalKeyboardKey;

import '../../data/repositories/settings_repository.dart' show DashboardPopupPosition;

/// What the playback popup over the Haussteuerung shows.
enum MiniPlayerSource {
  /// Nothing plays: Home and a small play button.
  idle,

  /// A radio station plays (or is starting).
  radio,

  /// Music is loaded (playing or paused).
  music,
}

/// The radio plays or is about to (tuning, buffering).
bool radioBusy({required bool playing, required AudioProcessingState state}) =>
    playing || state == AudioProcessingState.loading || state == AudioProcessingState.buffering;

/// A playing radio comes first (it paused the music, which stays loaded),
/// then loaded music; a stopped radio collapses the popup.
/// [sessionIsGuest]: Musik holds the media session.
MiniPlayerSource miniPlayerSourceOf({
  required bool musicLoaded,
  required bool sessionIsGuest,
  required bool hasRadioItem,
  required bool radioIsBusy,
}) {
  if (!sessionIsGuest && hasRadioItem && radioIsBusy) return MiniPlayerSource.radio;
  if (musicLoaded) return MiniPlayerSource.music;
  return MiniPlayerSource.idle;
}

/// Where the popup sits on the screen.
Alignment miniPlayerAlignment(DashboardPopupPosition position) => switch (position) {
      DashboardPopupPosition.bottomCenter => Alignment.bottomCenter,
      DashboardPopupPosition.bottomLeft => Alignment.bottomLeft,
      DashboardPopupPosition.bottomRight => Alignment.bottomRight,
      DashboardPopupPosition.topCenter => Alignment.topCenter,
      DashboardPopupPosition.topLeft => Alignment.topLeft,
      DashboardPopupPosition.topRight => Alignment.topRight,
    };

/// The arrow that leads from the dashboard's edge into the popup (Down for
/// a popup at the bottom); the opposite one leads back.
LogicalKeyboardKey miniPlayerEnterKey(DashboardPopupPosition position) =>
    position.atTop ? LogicalKeyboardKey.arrowUp : LogicalKeyboardKey.arrowDown;

/// The value of `__hsNav` as webview_flutter hands it back (a bool, or its
/// text on some WebViews): whether the frame moved in the page.
bool webNavMoved(Object? result) {
  if (result is bool) return result;
  final text = '$result'.trim().replaceAll('"', '');
  return text == 'true' || text == '1';
}
