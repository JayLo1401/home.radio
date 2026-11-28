import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:home_system/data/services/enigma2_recording_meta.dart';
import 'package:home_system/data/services/enigma2_recordings.dart';
import 'package:home_system/data/services/enigma2_service.dart';

void main() {
  const ref = '1:0:19:283D:3FB:1:C00000:0:0:0:';

  group('OpenWebif timers', () {
    test('a timer from /api/timerlist', () {
      final t = E2Timer.fromJson({
        'serviceref': ref,
        'servicename': 'Das Erste HD',
        'name': 'Tatort',
        'description': 'Krimi',
        'begin': 1795896900,
        'end': 1795903200,
        'eit': 4711,
        'state': 2,
        'disabled': 0,
        'justplay': 0,
        'location': '/media/autofs/NAS/',
      })!;
      expect(t.name, 'Tatort');
      expect(t.serviceName, 'Das Erste HD');
      expect(t.eit, 4711);
      expect(t.running, isTrue);
      expect(t.isRecording, isTrue);
      expect(t.begin, DateTime.fromMillisecondsSinceEpoch(1795896900 * 1000));
    });

    test('a refused timer with its conflicts', () {
      final r = E2TimerResult.fromJson({
        'result': false,
        'message': 'Conflicting Timer(s) detected!',
        'conflicts': [
          {'serviceref': ref, 'servicename': 'ORF1 HD', 'name': 'ZIB', 'begin': 100, 'end': 200},
        ],
      });
      expect(r.ok, isFalse);
      expect(r.message, contains('Conflicting'));
      expect(r.conflicts.single.name, 'ZIB');
      expect(E2TimerResult.fromJson({'result': true, 'message': 'Timer added'}).ok, isTrue);
    });

    test('the timer of a programme: by its EPG event, else by title and time', () {
      final begin = DateTime(2026, 11, 28, 20, 15);
      final event = E2Event(serviceRef: ref, title: 'Tatort', begin: begin, duration: const Duration(minutes: 90), id: 7);
      E2Timer timer({int? eit, String name = 'Tatort', String sref = ref, int startShift = -3}) => E2Timer(
            serviceRef: sref,
            serviceName: 'Das Erste HD',
            name: name,
            begin: begin.add(Duration(minutes: startShift)),
            end: begin.add(const Duration(minutes: 95)),
            eit: eit,
          );
      expect(timerForEvent([timer(eit: 7, name: 'x')], ref, event), isNotNull);
      // The trailing ':' and case don't matter.
      expect(timerForEvent([timer(sref: ref.toLowerCase().substring(0, ref.length - 1))], ref, event), isNotNull);
      expect(timerForEvent([timer(name: 'Something else')], ref, event), isNull);
      expect(timerForEvent([timer(sref: '1:0:19:1:1:1:C00000:0:0:0:')], ref, event), isNull);
      // A switch-only timer isn't a recording.
      final zap = E2Timer(serviceRef: ref, serviceName: '', name: 'Tatort', begin: begin, end: event.end, justPlay: true);
      expect(timerForEvent([zap], ref, event), isNull);
    });
  });

  group('OpenWebif recordings', () {
    test('a recording from /api/movielist', () {
      final r = E2Recording.fromJson({
        'fullname': '1:0:0:0:0:0:0:0:0:0:/media/autofs/NAS/20261128 2015 - Das Erste HD - Tatort.ts',
        'filename': '/media/autofs/NAS/20261128 2015 - Das Erste HD - Tatort.ts',
        'eventname': 'Tatort',
        'servicename': 'Das Erste HD',
        'description': 'Krimi',
        'descriptionExtended': 'Krimi aus Wien',
        'recordingtime': 1795896900,
        'length': '90:12',
        'filesize': 3221225472,
      })!;
      expect(r.title, 'Tatort');
      expect(r.length, const Duration(minutes: 90, seconds: 12));
      expect(r.description, 'Krimi aus Wien');
      expect(r.serviceRef, startsWith('1:0:0:0:0:0:0:0:0:0:/media'));
      expect(r.size, 3221225472);
    });

    test('lengths as OpenWebif writes them', () {
      expect(parseMovieLength('45:00'), const Duration(minutes: 45));
      expect(parseMovieLength('1:30:05'), const Duration(hours: 1, minutes: 30, seconds: 5));
      expect(parseMovieLength('?:??'), isNull);
      expect(parseMovieLength(''), isNull);
    });
  });

  group('Enigma2 recording files', () {
    test('the .ts.meta lines', () {
      final m = parseRecordingMeta('$ref\nTatort\nKrimi\n1795896900\n\n${90 * 60 * 90000}\n3221225472\n');
      expect(m.serviceRef, ref);
      expect(m.title, 'Tatort');
      expect(m.description, 'Krimi');
      expect(m.recorded, DateTime.fromMillisecondsSinceEpoch(1795896900 * 1000));
      expect(m.length, const Duration(minutes: 90));
      expect(m.size, 3221225472);
      expect(parseRecordingMeta('').title, '');
    });

    test('the name Enigma2 gives a recording', () {
      final r = parseRecordingFileName('/x/20261128 2015 - Das Erste HD - Tatort - Der Fall.ts');
      expect(r.recorded, DateTime(2026, 11, 28, 20, 15));
      expect(r.channel, 'Das Erste HD');
      expect(r.title, 'Tatort - Der Fall');
      expect(parseRecordingFileName('Mein_Film.ts').title, 'Mein Film');
    });

    test('the whole set of files of a recording', () {
      expect(recordingSidecarNames('A - B - C.ts'), containsAll(['A - B - C.ts.meta', 'A - B - C.ts.ap', 'A - B - C.ts.sc', 'A - B - C.ts.cuts', 'A - B - C.eit']));
    });

    test('the receiver\'s last position from .cuts', () {
      final b = ByteData(36);
      // in at 0, a mark, the last position at 10 minutes.
      b.setUint64(0, 0);
      b.setUint32(8, 0);
      b.setUint64(12, 90000 * 30);
      b.setUint32(20, 2);
      b.setUint64(24, 90000 * 600);
      b.setUint32(32, 3);
      expect(parseCutsLastPosition(b.buffer.asUint8List()), const Duration(minutes: 10));
      expect(parseCutsLastPosition(Uint8List(0)), isNull);
    });

    test('an .eit: title, texts, start and duration', () {
      final title = [0x15, ...utf8.encode('Tatort')];
      final short = latin1.encode('Krimi');
      final ext = [0x15, ...utf8.encode('Kommissarin Eisner ermittelt in Wien.')];
      final shortDesc = [0x4D, 3 + 1 + title.length + 1 + short.length, ...ascii.encode('deu'), title.length, ...title, short.length, ...short];
      final extDesc = [0x4E, 1 + 3 + 1 + 1 + ext.length, 0x00, ...ascii.encode('deu'), 0, ext.length, ...ext];
      final loop = shortDesc.length + extDesc.length;
      // MJD 61033 = 2025-12-24 (UTC 19:15:00), 1:30:00.
      final bytes = Uint8List.fromList([
        0x12, 0x34, 61033 >> 8, 61033 & 0xFF, 0x19, 0x15, 0x00, 0x01, 0x30, 0x00, 0x80 | (loop >> 8), loop & 0xFF,
        ...shortDesc, ...extDesc,
      ]);
      final e = parseRecordingEit(bytes)!;
      expect(e.title, 'Tatort');
      expect(e.shortText, 'Krimi');
      expect(e.extendedText, 'Kommissarin Eisner ermittelt in Wien.');
      expect(e.duration, const Duration(hours: 1, minutes: 30));
      expect(e.begin, DateTime.utc(2025, 12, 24, 19, 15).toLocal());
      expect(parseRecordingEit(Uint8List(4)), isNull);
    });

    test('DVB texts: ISO 6937 accents, UTF-8, Latin-1', () {
      // "Grüße" in ISO 6937: ü = 0xC8 'u', ß = 0xFB.
      expect(decodeDvbText(Uint8List.fromList([0x47, 0x72, 0xC8, 0x75, 0xFB, 0x65])), 'Grüße');
      expect(decodeDvbText(Uint8List.fromList([0x15, ...utf8.encode('Österreich')])), 'Österreich');
      expect(decodeDvbText(Uint8List.fromList([0x05, ...latin1.encode('Käse')])), 'Käse');
      expect(decodeDvbText(Uint8List.fromList([0x41, 0x8A, 0x42])), 'A\nB');
    });
  });
}
