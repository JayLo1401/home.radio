import 'package:flutter_test/flutter_test.dart';
import 'package:home_system/data/services/tv_stream_session.dart';

void main() {
  List<int> packets(int n) => [
        for (var p = 0; p < n; p++) ...[0x47, 0x01, 0x00, 0x10, ...List.filled(184, 0x47 + p % 2)],
      ];

  test('a chunk starting in the middle of a packet: from the next packet on', () {
    final stream = packets(5);
    // 0x47 inside the payload must not fool it.
    final chunk = stream.sublist(100);
    final aligned = alignToTsPacket(chunk);
    expect(aligned.length, stream.length - 188);
    expect(aligned.first, 0x47);
    expect(aligned[188], 0x47);
  });

  test('an aligned chunk stays as it is', () {
    final chunk = packets(3);
    expect(identical(alignToTsPacket(chunk), chunk), isTrue);
  });
}
