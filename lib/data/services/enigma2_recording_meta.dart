import 'dart:convert';
import 'dart:typed_data';

/// What Enigma2 writes next to a recording ("Name.ts"): "Name.ts.meta"
/// (text: channel, title, description, time, length) and "Name.eit" (the
/// programme's EPG entry as broadcast) - read to show a recording's title,
/// date and length in the list.

/// The lines of a .ts.meta file.
class RecordingMeta {
  const RecordingMeta({
    this.serviceRef = '',
    this.title = '',
    this.description = '',
    this.recorded,
    this.length,
    this.size,
  });

  final String serviceRef;
  final String title;
  final String description;
  final DateTime? recorded;
  final Duration? length;
  final int? size;
}

/// A .ts.meta: service reference, title, description, recording time
/// (Unix seconds), tags, length (in 90 kHz ticks), file size, ...
RecordingMeta parseRecordingMeta(String text) {
  final lines = const LineSplitter().convert(text);
  String line(int i) => i < lines.length ? lines[i].trim() : '';
  final time = int.tryParse(line(3));
  final ticks = int.tryParse(line(5));
  final size = int.tryParse(line(6));
  return RecordingMeta(
    serviceRef: line(0),
    title: line(1),
    description: line(2),
    recorded: time == null || time <= 0 ? null : DateTime.fromMillisecondsSinceEpoch(time * 1000),
    length: ticks == null || ticks <= 0 ? null : Duration(milliseconds: ticks ~/ 90),
    size: size == null || size <= 0 ? null : size,
  );
}

/// A recording's EPG entry from its .eit file.
class RecordingEvent {
  const RecordingEvent({this.title = '', this.shortText = '', this.extendedText = '', this.begin, this.duration});

  final String title;
  final String shortText;
  final String extendedText;
  final DateTime? begin;
  final Duration? duration;

  String get description {
    final s = shortText.trim(), l = extendedText.trim();
    if (s.isEmpty) return l;
    if (l.isEmpty || l.startsWith(s)) return l.isEmpty ? s : l;
    return '$s\n\n$l';
  }
}

/// An .eit file: one DVB EIT event - id, start (MJD + BCD time, UTC),
/// duration (BCD), then its descriptors: the short event (title and
/// text) and the extended ones (the long text, in parts). Null if it isn't
/// one.
RecordingEvent? parseRecordingEit(Uint8List b) {
  if (b.length < 12) return null;
  final mjd = (b[2] << 8) | b[3];
  final begin = _mjdTime(mjd, b[4], b[5], b[6]);
  final duration = _bcdDuration(b[7], b[8], b[9]);
  final loop = ((b[10] & 0x0F) << 8) | b[11];
  var i = 12;
  final end = (12 + loop).clamp(12, b.length);
  var title = '', shortText = '';
  final extended = <int, String>{};
  while (i + 2 <= end) {
    final tag = b[i], len = b[i + 1];
    final body = i + 2;
    if (body + len > end) break;
    if (tag == 0x4D && len >= 5) {
      final nameLen = b[body + 3];
      final nameEnd = body + 4 + nameLen;
      if (nameEnd < body + len) {
        title = decodeDvbText(Uint8List.sublistView(b, body + 4, nameEnd));
        final textLen = b[nameEnd];
        final textEnd = (nameEnd + 1 + textLen).clamp(nameEnd + 1, body + len);
        shortText = decodeDvbText(Uint8List.sublistView(b, nameEnd + 1, textEnd));
      } else {
        title = decodeDvbText(Uint8List.sublistView(b, body + 4, (nameEnd).clamp(body + 4, body + len)));
      }
    } else if (tag == 0x4E && len >= 6) {
      final number = b[body] >> 4;
      final itemsLen = b[body + 4];
      final textAt = body + 5 + itemsLen;
      if (textAt < body + len) {
        final textLen = b[textAt];
        final textEnd = (textAt + 1 + textLen).clamp(textAt + 1, body + len);
        extended[number] = (extended[number] ?? '') + decodeDvbText(Uint8List.sublistView(b, textAt + 1, textEnd));
      }
    }
    i = body + len;
  }
  final numbers = extended.keys.toList()..sort();
  return RecordingEvent(
    title: title,
    shortText: shortText,
    extendedText: [for (final n in numbers) extended[n]!].join(),
    begin: begin,
    duration: duration,
  );
}

DateTime? _mjdTime(int mjd, int h, int m, int s) {
  if (mjd == 0 || mjd == 0xFFFF) return null;
  final y1 = ((mjd - 15078.2) / 365.25).floor();
  final m1 = ((mjd - 14956.1 - (y1 * 365.25).floor()) / 30.6001).floor();
  final day = mjd - 14956 - (y1 * 365.25).floor() - (m1 * 30.6001).floor();
  final k = m1 == 14 || m1 == 15 ? 1 : 0;
  final year = y1 + k + 1900;
  final month = m1 - 1 - k * 12;
  final hh = _bcd(h), mm = _bcd(m), ss = _bcd(s);
  if (hh == null || mm == null || ss == null || month < 1 || month > 12 || day < 1 || day > 31) return null;
  return DateTime.utc(year, month, day, hh, mm, ss).toLocal();
}

Duration? _bcdDuration(int h, int m, int s) {
  final hh = _bcd(h), mm = _bcd(m), ss = _bcd(s);
  if (hh == null || mm == null || ss == null) return null;
  final d = Duration(hours: hh, minutes: mm, seconds: ss);
  return d == Duration.zero ? null : d;
}

int? _bcd(int v) {
  final hi = v >> 4, lo = v & 0x0F;
  if (hi > 9 || lo > 9) return null;
  return hi * 10 + lo;
}

/// A DVB text (EN 300 468 annex A): a first byte below 0x20 names the
/// character set - 0x15 UTF-8, 0x10 xx yy / 0x01..0x0B an ISO 8859 part
/// (read as Latin-1, close enough for German) -, without one it's ISO 6937
/// (accents as a byte before the letter). Control codes: 0x8A new line,
/// 0x86/0x87 emphasis (dropped).
String decodeDvbText(Uint8List bytes) {
  if (bytes.isEmpty) return '';
  var data = bytes;
  var charset = 'iso6937';
  final first = data[0];
  if (first == 0x15) {
    charset = 'utf8';
    data = Uint8List.sublistView(data, 1);
  } else if (first == 0x10) {
    charset = 'latin1';
    data = Uint8List.sublistView(data, data.length >= 3 ? 3 : data.length);
  } else if (first >= 0x01 && first <= 0x0B) {
    charset = 'latin1';
    data = Uint8List.sublistView(data, 1);
  } else if (first < 0x20) {
    data = Uint8List.sublistView(data, 1);
  }
  final String text;
  if (charset == 'utf8') {
    text = utf8.decode(data, allowMalformed: true);
  } else if (charset == 'latin1') {
    text = String.fromCharCodes([for (final c in data) if (c != 0x86 && c != 0x87) c == 0x8A ? 0x0A : c]);
  } else {
    // Some receivers write UTF-8 without the marker.
    final asUtf8 = _strictUtf8(data);
    text = asUtf8 ?? _iso6937(data);
  }
  return text.replaceAll('\u0086', '').replaceAll('\u0087', '').replaceAll('\u008A', '\n').trim();
}

String? _strictUtf8(Uint8List data) {
  if (!data.any((c) => c >= 0x80)) return null;
  try {
    return utf8.decode(data);
  } catch (_) {
    return null;
  }
}

/// ISO 6937 with the accents German, French, ... texts need.
String _iso6937(Uint8List data) {
  const accents = {
    0xC1: {'a': 'à', 'e': 'è', 'i': 'ì', 'o': 'ò', 'u': 'ù', 'A': 'À', 'E': 'È', 'I': 'Ì', 'O': 'Ò', 'U': 'Ù'},
    0xC2: {'a': 'á', 'e': 'é', 'i': 'í', 'o': 'ó', 'u': 'ú', 'y': 'ý', 'c': 'ć', 'n': 'ń', 's': 'ś', 'z': 'ź',
      'A': 'Á', 'E': 'É', 'I': 'Í', 'O': 'Ó', 'U': 'Ú', 'Y': 'Ý', 'C': 'Ć', 'N': 'Ń', 'S': 'Ś', 'Z': 'Ź'},
    0xC3: {'a': 'â', 'e': 'ê', 'i': 'î', 'o': 'ô', 'u': 'û', 'A': 'Â', 'E': 'Ê', 'I': 'Î', 'O': 'Ô', 'U': 'Û'},
    0xC4: {'a': 'ã', 'n': 'ñ', 'o': 'õ', 'A': 'Ã', 'N': 'Ñ', 'O': 'Õ'},
    0xC8: {'a': 'ä', 'e': 'ë', 'i': 'ï', 'o': 'ö', 'u': 'ü', 'y': 'ÿ', 'A': 'Ä', 'E': 'Ë', 'I': 'Ï', 'O': 'Ö', 'U': 'Ü'},
    0xCA: {'a': 'å', 'u': 'ů', 'A': 'Å', 'U': 'Ů'},
    0xCB: {'c': 'ç', 's': 'ş', 'C': 'Ç', 'S': 'Ş'},
    0xCF: {'c': 'č', 's': 'š', 'z': 'ž', 'r': 'ř', 'e': 'ě', 'n': 'ň', 'C': 'Č', 'S': 'Š', 'Z': 'Ž', 'R': 'Ř', 'E': 'Ě', 'N': 'Ň'},
  };
  const singles = {0xA4: '\$', 0xA6: '#', 0xA9: '‘', 0xAA: '“', 0xB9: '’', 0xBA: '”', 0xFB: 'ß', 0xE9: 'ø', 0xF9: 'ø',
    0xEA: 'Œ', 0xFA: 'œ', 0xE8: 'Ł', 0xF8: 'ł', 0xE1: 'Æ', 0xF1: 'æ', 0x8A: '\n'};
  final out = StringBuffer();
  for (var i = 0; i < data.length; i++) {
    final c = data[i];
    if (c == 0x86 || c == 0x87) continue;
    final accent = accents[c];
    if (accent != null) {
      if (i + 1 < data.length) {
        final letter = String.fromCharCode(data[i + 1]);
        out.write(accent[letter] ?? letter);
        i++;
      }
      continue;
    }
    if (c >= 0xC0 && c <= 0xCF) continue; // an accent we don't know: the letter alone follows
    final single = singles[c];
    if (single != null) {
      out.write(single);
    } else if (c < 0x80) {
      out.writeCharCode(c);
    } else if (c >= 0xA0) {
      out.writeCharCode(c);
    }
  }
  return out.toString();
}

/// Enigma2's name for a recording: "20261128 2015 - Das Erste HD -
/// Tatort.ts" - when it began, the channel and the title.
({DateTime? recorded, String channel, String title}) parseRecordingFileName(String fileName) {
  var name = fileName.split('/').last;
  final dot = name.lastIndexOf('.');
  if (dot > 0) name = name.substring(0, dot);
  final m = RegExp(r'^(\d{4})(\d{2})(\d{2}) (\d{2})(\d{2}) - (.*)$').firstMatch(name);
  if (m == null) return (recorded: null, channel: '', title: name.replaceAll('_', ' ').trim());
  final t = DateTime(int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!), int.parse(m[4]!), int.parse(m[5]!));
  final rest = m[6]!;
  final sep = rest.indexOf(' - ');
  if (sep < 0) return (recorded: t, channel: rest.trim(), title: rest.trim());
  return (recorded: t, channel: rest.substring(0, sep).trim(), title: rest.substring(sep + 3).trim());
}

/// The files of the recording [tsName] ("Name.ts") as Enigma2 keeps them
/// next to it: Name.ts.meta / .ts.ap / .ts.sc / .ts.cuts, Name.eit (and
/// Name.meta, Name.jpg some images write) - moved and deleted together.
List<String> recordingSidecarNames(String tsName) {
  final dot = tsName.lastIndexOf('.');
  final base = dot > 0 ? tsName.substring(0, dot) : tsName;
  return ['$tsName.meta', '$tsName.ap', '$tsName.sc', '$tsName.cuts', '$base.eit', '$base.meta', '$base.jpg'];
}

/// Where the receiver stopped watching a recording: the last "last
/// position" mark (type 3) of its .cuts file - 12-byte records, a 64-bit
/// PTS (90 kHz, from the recording's start) and a 32-bit type, big-endian.
Duration? parseCutsLastPosition(Uint8List cuts) {
  final data = ByteData.sublistView(cuts);
  Duration? last;
  for (var i = 0; i + 12 <= cuts.length; i += 12) {
    final pts = data.getUint64(i);
    final type = data.getUint32(i + 8);
    if (type == 3 && pts > 0) last = Duration(milliseconds: pts ~/ 90);
  }
  return last;
}
