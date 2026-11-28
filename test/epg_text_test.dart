import 'package:flutter_test/flutter_test.dart';
import 'package:home_system/data/services/enigma2_service.dart';

void main() {
  test('EPG texts: literal \n and DVB 0x8A become line breaks, entities resolved', () {
    expect(epgText(r'Mein Gemeindebau\nReality-Doku, A 2024'), 'Mein Gemeindebau\nReality-Doku, A 2024');
    expect(epgText('Teil 1\u008aTeil 2'), 'Teil 1\nTeil 2');
    expect(epgText('Tom &amp; Jerry'), 'Tom & Jerry');
    expect(epgText(r'a\n\n\n\nb'), 'a\n\nb');
  });
}
