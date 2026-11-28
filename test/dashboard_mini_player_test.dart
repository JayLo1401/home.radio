import 'package:audio_service/audio_service.dart' show AudioProcessingState;
import 'package:flutter/painting.dart' show Alignment;
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:home_system/data/repositories/settings_repository.dart';
import 'package:home_system/data/services/audio_focus_guard.dart';
import 'package:home_system/features/dashboard/dashboard_mini_player_logic.dart';

void main() {
  group('miniPlayerSourceOf', () {
    test('nothing loaded: idle', () {
      expect(
        miniPlayerSourceOf(musicLoaded: false, sessionIsGuest: false, hasRadioItem: false, radioIsBusy: false),
        MiniPlayerSource.idle,
      );
    });

    test('a playing radio station', () {
      expect(
        miniPlayerSourceOf(musicLoaded: false, sessionIsGuest: false, hasRadioItem: true, radioIsBusy: true),
        MiniPlayerSource.radio,
      );
    });

    test('a stopped radio collapses the popup', () {
      expect(
        miniPlayerSourceOf(musicLoaded: false, sessionIsGuest: false, hasRadioItem: true, radioIsBusy: false),
        MiniPlayerSource.idle,
      );
    });

    test('music holding the session, also paused', () {
      expect(
        miniPlayerSourceOf(musicLoaded: true, sessionIsGuest: true, hasRadioItem: true, radioIsBusy: false),
        MiniPlayerSource.music,
      );
    });

    test('the radio started over paused music: radio', () {
      expect(
        miniPlayerSourceOf(musicLoaded: true, sessionIsGuest: false, hasRadioItem: true, radioIsBusy: true),
        MiniPlayerSource.radio,
      );
    });

    test('radio stopped, music still loaded: music', () {
      expect(
        miniPlayerSourceOf(musicLoaded: true, sessionIsGuest: false, hasRadioItem: true, radioIsBusy: false),
        MiniPlayerSource.music,
      );
    });
  });

  test('radioBusy: playing, loading and buffering', () {
    expect(radioBusy(playing: true, state: AudioProcessingState.ready), isTrue);
    expect(radioBusy(playing: false, state: AudioProcessingState.loading), isTrue);
    expect(radioBusy(playing: false, state: AudioProcessingState.buffering), isTrue);
    expect(radioBusy(playing: false, state: AudioProcessingState.ready), isFalse);
    expect(radioBusy(playing: false, state: AudioProcessingState.idle), isFalse);
  });

  group('position', () {
    test('parse: unknown or none is bottom centre', () {
      expect(DashboardPopupPosition.parse(null), DashboardPopupPosition.bottomCenter);
      expect(DashboardPopupPosition.parse('nonsense'), DashboardPopupPosition.bottomCenter);
      for (final p in DashboardPopupPosition.values) {
        expect(DashboardPopupPosition.parse(p.name), p);
      }
    });

    test('defaults: shown, bottom centre', () {
      const s = DashboardPopupSettings();
      expect(s.show, isTrue);
      expect(s.position, DashboardPopupPosition.bottomCenter);
      expect(s.loaded, isFalse);
      expect(s.copyWith(show: false).loaded, isTrue);
    });

    test('alignment and the arrow into the popup', () {
      expect(miniPlayerAlignment(DashboardPopupPosition.bottomCenter), Alignment.bottomCenter);
      expect(miniPlayerAlignment(DashboardPopupPosition.topLeft), Alignment.topLeft);
      expect(miniPlayerAlignment(DashboardPopupPosition.bottomRight), Alignment.bottomRight);
      expect(miniPlayerEnterKey(DashboardPopupPosition.bottomLeft), LogicalKeyboardKey.arrowDown);
      expect(miniPlayerEnterKey(DashboardPopupPosition.topRight), LogicalKeyboardKey.arrowUp);
      expect(DashboardPopupPosition.topCenter.atTop, isTrue);
      expect(DashboardPopupPosition.bottomCenter.atTop, isFalse);
    });
  });

  test('webNavMoved reads what the WebView hands back', () {
    expect(webNavMoved(true), isTrue);
    expect(webNavMoved(false), isFalse);
    expect(webNavMoved('true'), isTrue);
    expect(webNavMoved('"false"'), isFalse);
    expect(webNavMoved(null), isFalse);
    expect(webNavMoved(1), isTrue);
  });

  group('AudioFocusGuard', () {
    setUp(AudioFocusGuard.reset);
    tearDown(AudioFocusGuard.reset);

    test('a lost focus pauses normally', () {
      expect(AudioFocusGuard.shouldPauseFor(begin: true), isTrue);
      expect(AudioFocusGuard.shouldPauseFor(begin: false), isFalse);
    });

    test('not while the Haussteuerung is in front', () async {
      await AudioFocusGuard.setKeepPlaying(true);
      expect(AudioFocusGuard.keepPlaying, isTrue);
      expect(AudioFocusGuard.shouldPauseFor(begin: true), isFalse);
      // Nothing plays any more: the focus isn't taken back.
      await AudioFocusGuard.setKeepPlaying(false, playing: () => false);
      expect(AudioFocusGuard.shouldPauseFor(begin: true), isTrue);
    });
  });
}
