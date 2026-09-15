import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'core/providers.dart';
import 'data/services/audio_player_service.dart';
import 'data/services/radio_audio_handler.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final audioPlayerService = AudioPlayerService();
  // Registers the Android MediaSession/notification so the currently
  // playing (or, for DAB+, currently tuned) station shows up as a proper
  // "Now Playing" media card for Home Assistant and the TV launcher.
  final audioHandler = await AudioService.init(
    builder: () => RadioAudioHandler(audioPlayerService),
    config: AudioServiceConfig(
      androidNotificationChannelId: 'org.lotzapp.home_radio.audio',
      androidNotificationChannelName: 'Home Radio Wiedergabe',
      androidNotificationOngoing: true,
    ),
  );
  runApp(
    ProviderScope(
      overrides: [
        audioPlayerServiceProvider.overrideWithValue(audioPlayerService),
        radioAudioHandlerProvider.overrideWithValue(audioHandler),
      ],
      child: const HomeRadioApp(),
    ),
  );
}
