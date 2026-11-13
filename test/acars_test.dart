import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:home_radio/data/models/acars.dart';

Uint8List frame(String s) => Uint8List.fromList([...s.codeUnits, 0x12, 0x34]); // + BCS

void main() {
  test('downlink with flight and text', () {
    final m = parseAcars(frame('\x012.D-AIZA\x15H13\x02M01ALH1234Hello from FL350\x03'), freqHz: 131725000)!;
    expect(m.registration, 'D-AIZA');
    expect(m.label, 'H1');
    expect(m.downlink, isTrue);
    expect(m.messageNo, 'M01A');
    expect(m.flight, 'LH1234');
    expect(m.text, 'Hello from FL350');
    expect(m.labelName, 'Bordrechner (FMS/Wartung)');
  });

  test('uplink acknowledgement without text', () {
    final m = parseAcars(frame('\x012.OE-LBA\x06_\x7fA\x03'), freqHz: 131525000)!;
    expect(m.registration, 'OE-LBA');
    expect(m.downlink, isFalse);
    expect(m.text, '');
    expect(m.labelName, 'Quittung (ohne Inhalt)');
  });
}
