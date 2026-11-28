import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:home_system/core/foreground_part.dart';

/// A page standing for one of the parts ('' = the launcher).
class _Part extends StatelessWidget {
  const _Part(this.name);

  final String name;

  @override
  Widget build(BuildContext context) => Scaffold(body: Text('part $name'));
}

void main() {
  testWidgets('the part on screen: pages under Home and over it, sub pages and dialogs', (tester) async {
    final observer = ForegroundPartObserver(classify: (w) => w is _Part ? w.name : null);
    final nav = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(
      navigatorKey: nav,
      navigatorObservers: [observer],
      home: const _Part('radio'),
    ));
    await tester.pumpAndSettle();
    expect(observer.part.value, 'radio');

    // Home over Radio: no part.
    unawaited(nav.currentState!.push(PageRouteBuilder<void>(pageBuilder: (_, _, _) => const _Part(launcherKind))));
    await tester.pumpAndSettle();
    expect(observer.part.value, isNull);

    unawaited(nav.currentState!.push(MaterialPageRoute<void>(builder: (_) => const _Part('tv'))));
    await tester.pumpAndSettle();
    expect(observer.part.value, 'tv');

    // A page of TV's own and a dialog over it: still TV.
    unawaited(nav.currentState!.push(MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Text('guide')))));
    await tester.pumpAndSettle();
    expect(observer.part.value, 'tv');
    unawaited(showDialog<void>(context: nav.currentContext!, builder: (_) => const AlertDialog(content: Text('note'))));
    await tester.pumpAndSettle();
    expect(observer.part.value, 'tv');

    nav.currentState!.pop();
    nav.currentState!.pop();
    await tester.pumpAndSettle();
    expect(observer.part.value, 'tv');

    // Back to Home, then to Radio.
    nav.currentState!.pop();
    await tester.pumpAndSettle();
    expect(observer.part.value, isNull);
    nav.currentState!.popUntil((r) => r.isFirst);
    await tester.pumpAndSettle();
    expect(observer.part.value, 'radio');

    // A page replaced (as the splash screen is by Radio's).
    unawaited(nav.currentState!.pushReplacement(MaterialPageRoute<void>(builder: (_) => const _Part('music'))));
    await tester.pumpAndSettle();
    expect(observer.part.value, 'music');
  });
}
