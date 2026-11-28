import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:home_system/data/db/database.dart';
import 'package:home_system/data/repositories/settings_repository.dart';
import 'package:home_system/features/tv/tv_providers.dart';
import 'package:home_system/features/tv/tv_widgets.dart';

void main() {
  testWidgets('the lock shows once a channel turned out encrypted', (tester) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final known = TvStreamKnowledge(SettingsRepository(db));
    await tester.pumpWidget(ProviderScope(
      overrides: [tvStreamKnowledgeProvider.overrideWithValue(known)],
      child: const MaterialApp(
        home: Scaffold(
          body: TvChannelName('ORF1 HD', serviceRef: '1:0:19:1:2:3:4:0:0:0:', style: TextStyle(fontSize: 18)),
        ),
      ),
    ));
    await tester.pump();
    expect(find.byIcon(Icons.lock), findsNothing);
    known.markEncrypted('1:0:19:1:2:3:4:0:0:0:');
    await tester.pump();
    expect(find.byIcon(Icons.lock), findsOneWidget);
    expect(find.text('ORF1 HD'), findsOneWidget);
  });
}
