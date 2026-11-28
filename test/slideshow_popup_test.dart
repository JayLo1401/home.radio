import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:home_system/core/music_providers.dart';
import 'package:home_system/core/pictures_providers.dart';
import 'package:home_system/core/providers.dart';
import 'package:home_system/data/repositories/settings_repository.dart';
import 'package:home_system/data/services/music_player.dart';
import 'package:home_system/data/services/radio_audio_handler.dart';
import 'package:home_system/features/pictures/slideshow_popup.dart';
import 'package:home_system/l10n/l10n.dart';

class _NoMusic extends MusicStateNotifier {
  @override
  MusicState build() => const MusicState();
}

class _Slideshow extends SlideshowSettingsNotifier {
  @override
  SlideshowSettings build() => const SlideshowSettings(intervalSeconds: 8);

  @override
  Future<void> set(SlideshowSettings value) async => state = value;
}

String? get _focused => FocusManager.instance.primaryFocus?.debugLabel;

Future<ProviderContainer> _pump(WidgetTester tester, VoidCallback onClose) async {
  final container = ProviderContainer(
    overrides: [
      musicStateProvider.overrideWith(_NoMusic.new),
      slideshowSettingsProvider.overrideWith(_Slideshow.new),
      // No media session (yet).
      radioAudioHandlerProvider.overrideWith((ref) => Completer<RadioAudioHandler>().future),
    ],
  );
  await tester.pumpWidget(UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      locale: const Locale('de'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: Center(child: SlideshowPopup(onClose: onClose))),
    ),
  ));
  await tester.pump();
  await tester.pump();
  return container;
}

void main() {
  testWidgets('nothing playing: a hint, the display time focused; closes by itself', (tester) async {
    var closed = 0;
    final container = await _pump(tester, () => closed++);
    expect(find.textContaining('Gerade läuft keine Musik und kein Radio'), findsOneWidget);
    expect(find.text('Anzeigedauer'), findsOneWidget);
    expect(find.text('8 Sekunden'), findsOneWidget);
    expect(_focused, 'popup duration');
    // Keys keep it open.
    await tester.pump(const Duration(seconds: 6));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump(const Duration(seconds: 6));
    expect(closed, 0);
    await tester.pump(const Duration(seconds: 3));
    expect(closed, 1);
    await tester.pumpWidget(const SizedBox.shrink());
    container.dispose();
  });

  testWidgets('the display time: OK opens the list, a new value is kept', (tester) async {
    var closed = 0;
    final container = await _pump(tester, () => closed++);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    // The list is open: the popup doesn't close meanwhile.
    await tester.pump(const Duration(seconds: 10));
    expect(closed, 0);
    await tester.tap(find.text('15 Sekunden').last);
    await tester.pumpAndSettle();
    expect(container.read(slideshowSettingsProvider).intervalSeconds, 15);
    expect(SettingsRepository.slideshowIntervals, contains(15));
    expect(find.text('15 Sekunden'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(closed, 1);
    await tester.pumpWidget(const SizedBox.shrink());
    container.dispose();
  });
}
