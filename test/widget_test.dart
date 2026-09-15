import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:home_radio/app.dart';

void main() {
  testWidgets('Home screen shows without crashing', (WidgetTester tester) async {
    await tester.pumpWidget(const ProviderScope(child: HomeRadioApp()));
    await tester.pump();
    expect(find.text('Kein Sender ausgewählt'), findsOneWidget);

    // Tear the tree down explicitly so the audio player (and its internal
    // position-polling timer) is disposed before the test framework checks
    // for pending timers.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 50));
  });
}
