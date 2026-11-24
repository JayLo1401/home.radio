import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:home_system/core/remote_keys.dart';

void main() {
  test('standard keys: OK opens the channel list, ☰ the options, Info the guide', () {
    const keys = RemoteKeys();
    expect(keys.actionOf(LogicalKeyboardKey.select), RemoteAction.channelList);
    expect(keys.actionOf(LogicalKeyboardKey.contextMenu), RemoteAction.options);
    expect(keys.actionOf(LogicalKeyboardKey.info), RemoteAction.guide);
    expect(keys.actionOf(LogicalKeyboardKey.keyE), RemoteAction.guide);
    expect(keys.actionOf(LogicalKeyboardKey.arrowUp), isNull);
  });

  test('an assigned key replaces the standard ones - ☰ is free then', () {
    final keys = RemoteKeys({
      RemoteAction.options: [LogicalKeyboardKey.colorF2Yellow],
    });
    expect(keys.actionOf(LogicalKeyboardKey.contextMenu), isNull);
    expect(keys.actionOf(LogicalKeyboardKey.colorF2Yellow), RemoteAction.options);
    expect(keys.isCustom(RemoteAction.options), isTrue);
    expect(keys.isCustom(RemoteAction.guide), isFalse);
  });

  test('key names as on the remote', () {
    expect(remoteKeyLabel(LogicalKeyboardKey.select), 'OK');
    expect(remoteKeyLabel(LogicalKeyboardKey.contextMenu), '☰ Menü');
    expect(remoteKeyLabel(LogicalKeyboardKey.colorF0Red), 'Rot');
    expect(remoteKeyLabel(LogicalKeyboardKey.keyE), 'Taste E');
  });
}
