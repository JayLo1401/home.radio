import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:home_system/core/music_providers.dart';
import 'package:home_system/core/providers.dart';
import 'package:home_system/core/system_providers.dart';
import 'package:home_system/data/services/music_player.dart' show MusicState;
import 'package:home_system/data/services/radio_audio_handler.dart';
import 'package:home_system/features/dashboard/dashboard_mini_player.dart';
import 'package:home_system/l10n/l10n.dart';

class _Parts extends SystemPartsNotifier {
  @override
  SystemParts build() =>
      (radio: true, tv: false, dashboard: true, pictures: false, movies: false, music: false, browser: false);
}

class _NoMusic extends MusicStateNotifier {
  @override
  MusicState build() => const MusicState();
}

void main() {
  testWidgets('idle: Home and play, Left/Right between them, Up back to the dashboard', (tester) async {
    final key = GlobalKey<DashboardMiniPlayerState>();
    var home = 0;
    var exits = 0;
    final handler = Completer<RadioAudioHandler>();
    await tester.pumpWidget(ProviderScope(
      overrides: [
        systemPartsProvider.overrideWith(_Parts.new),
        musicStateProvider.overrideWith(_NoMusic.new),
        radioAudioHandlerProvider.overrideWith((ref) => handler.future),
      ],
      child: MaterialApp(
        locale: const Locale('de'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: DashboardMiniPlayer(
              key: key,
              atTop: false,
              onHome: () => home++,
              onExit: () => exits++,
              hint: 'Hinweis',
            ),
          ),
        ),
      ),
    ));
    await tester.pump();

    expect(find.byIcon(Icons.home_rounded), findsOneWidget);
    expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);
    expect(find.byIcon(Icons.stop_rounded), findsNothing);
    expect(find.text('Hinweis'), findsOneWidget);

    key.currentState!.focusIn();
    await tester.pump();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'miniPlayerPlay');
    expect(key.currentState!.hasFocus, isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'miniPlayerHome');

    // Left at the end stays.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'miniPlayerHome');

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(home, 1);

    // Down (away from the dashboard) does nothing, Up goes back.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    expect(exits, 0);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    expect(exits, 1);

    await tester.tap(find.byIcon(Icons.home_rounded));
    expect(home, 2);

    await tester.pumpWidget(const SizedBox.shrink());
  });
}
