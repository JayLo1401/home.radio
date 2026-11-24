import 'dart:convert';
import 'dart:typed_data';

/// The DVD side of films: which VOB files make the main film, what the
/// IFO file says about its sound tracks and chapters, and the rewriting of
/// the film's MPEG program stream so the players get exactly one sound
/// track (see [DvdPackFilter]).

/// One VOB file of a title set ("VTS_01_3.VOB": set 1, part 3).
class DvdVob<T> {
  const DvdVob({required this.titleSet, required this.part, required this.size, required this.file});

  final int titleSet;

  /// 0 is the menu, 1... the film's parts (up to 1 GB each).
  final int part;
  final int size;

  /// Where it lies (a NAS path or a place in an image).
  final T file;
}

final _vobName = RegExp(r'^VTS_(\d\d)_(\d)\.VOB$', caseSensitive: false);

/// [name] as a VOB file of a title set, or null.
({int titleSet, int part})? parseVobName(String name) {
  final m = _vobName.firstMatch(name.trim());
  if (m == null) return null;
  return (titleSet: int.parse(m.group(1)!), part: int.parse(m.group(2)!));
}

/// The main film: the title set with the most bytes in its film VOBs
/// (VTS_xx_1..n - not the menu VOB VTS_xx_0), its parts in order. Empty if
/// there's none.
List<DvdVob<T>> pickMainTitle<T>(Iterable<DvdVob<T>> vobs) {
  final sets = <int, List<DvdVob<T>>>{};
  for (final v in vobs) {
    if (v.part >= 1) (sets[v.titleSet] ??= []).add(v);
  }
  if (sets.isEmpty) return const [];
  int total(List<DvdVob<T>> parts) => parts.fold(0, (sum, v) => sum + v.size);
  final best = sets.values.reduce((a, b) => total(b) > total(a) ? b : a);
  return best..sort((a, b) => a.part.compareTo(b.part));
}

/// The IFO file of a title set, e.g. "VTS_01_0.IFO".
String ifoNameOf(int titleSet) => 'VTS_${titleSet.toString().padLeft(2, '0')}_0.IFO';

enum DvdAudioCoding { ac3, mpeg, lpcm, dts, other }

/// One sound track of the film. In the stream: AC3, DTS and LPCM in the
/// private stream 1 (0xBD) with a sub-stream number (0x80+n, 0x88+n,
/// 0xA0+n), MPEG audio as its own stream (0xC0+n).
class DvdAudioStream {
  const DvdAudioStream({
    required this.coding,
    required this.number,
    this.channels,
    this.language,
    this.extension = 0,
  });

  final DvdAudioCoding coding;

  /// The physical stream number (0..7).
  final int number;
  final int? channels;

  /// ISO 639-1 ("de", "en"), or null.
  final String? language;

  /// 2: for the visually impaired, 3/4: director's comments.
  final int extension;

  /// The PES stream id: 0xBD (private stream 1) or 0xC0+n.
  int get streamId => coding == DvdAudioCoding.mpeg ? 0xC0 + number : 0xBD;

  /// The sub-stream in private stream 1 (null for MPEG audio).
  int? get substream => switch (coding) {
        DvdAudioCoding.ac3 => 0x80 + number,
        DvdAudioCoding.dts => 0x88 + number,
        DvdAudioCoding.lpcm => 0xA0 + number,
        DvdAudioCoding.mpeg => null,
        DvdAudioCoding.other => null,
      };

  /// "ac3", "mpeg", ... - as the players' codec names (see audioDetails).
  String get codecName => switch (coding) {
        DvdAudioCoding.ac3 => 'ac3',
        DvdAudioCoding.mpeg => 'mp2',
        DvdAudioCoding.lpcm => 'pcm',
        DvdAudioCoding.dts => 'dts',
        DvdAudioCoding.other => '',
      };

  /// A stable id ("bd80", "c0").
  String get id => substream == null ? streamId.toRadixString(16) : 'bd${substream!.toRadixString(16)}';

  @override
  bool operator ==(Object other) => other is DvdAudioStream && other.id == id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'DvdAudioStream($id, $language, $channels)';
}

/// What the title set's IFO says about the film (its longest program
/// chain): sound tracks, length, chapter starts.
class DvdTitleInfo {
  const DvdTitleInfo({this.audio = const [], this.duration, this.chapters = const []});

  final List<DvdAudioStream> audio;
  final Duration? duration;

  /// Start of every chapter (the first at zero).
  final List<Duration> chapters;
}

int _u16(Uint8List b, int o) => b[o] << 8 | b[o + 1];
int _u32(Uint8List b, int o) => b[o] << 24 | b[o + 1] << 16 | b[o + 2] << 8 | b[o + 3];

int _bcd(int v) => (v >> 4) * 10 + (v & 0x0F);

/// A playback time of the IFO: hours, minutes, seconds (BCD) and frames
/// (BCD, the top two bits are the frame rate: 1 = 25, 3 = 30).
Duration dvdTime(Uint8List b, int o) {
  final rate = (b[o + 3] >> 6) == 1 ? 25 : 30;
  final frames = _bcd(b[o + 3] & 0x3F);
  return Duration(
    hours: _bcd(b[o]),
    minutes: _bcd(b[o + 1]),
    seconds: _bcd(b[o + 2]),
    milliseconds: frames * 1000 ~/ rate,
  );
}

/// Reads a title set's IFO (VTS_xx_0.IFO); null if it isn't one.
DvdTitleInfo? parseVtsIfo(Uint8List b) {
  if (b.length < 0x300 || ascii.decode(b.sublist(0, 12), allowInvalid: true) != 'DVDVIDEO-VTS') return null;
  // The title set's sound tracks (attributes, 8 bytes each).
  final count = _u16(b, 0x202).clamp(0, 8);
  final attributes = <({DvdAudioCoding coding, int? channels, String? language, int extension})>[];
  for (var i = 0; i < count; i++) {
    final o = 0x204 + i * 8;
    final coding = switch (b[o] >> 5) {
      0 => DvdAudioCoding.ac3,
      2 || 3 => DvdAudioCoding.mpeg,
      4 => DvdAudioCoding.lpcm,
      6 => DvdAudioCoding.dts,
      _ => DvdAudioCoding.other,
    };
    final hasLanguage = (b[o] >> 2) & 3 == 1;
    final code = hasLanguage ? ascii.decode(b.sublist(o + 2, o + 4), allowInvalid: true).trim().toLowerCase() : '';
    attributes.add((
      coding: coding,
      channels: (b[o + 1] & 7) + 1,
      language: RegExp(r'^[a-z]{2}$').hasMatch(code) ? code : null,
      extension: b[o + 5],
    ));
  }

  // The program chains: the longest is the film.
  final pgcit = _u32(b, 0xCC) * 2048;
  Uint8List? pgc;
  Duration? duration;
  if (pgcit > 0 && pgcit + 8 <= b.length) {
    final chains = _u16(b, pgcit).clamp(0, 999);
    for (var i = 0; i < chains; i++) {
      final entry = pgcit + 8 + i * 8;
      if (entry + 8 > b.length) break;
      final at = pgcit + _u32(b, entry + 4);
      if (at + 0xEC > b.length) continue;
      final length = dvdTime(b, at + 4);
      if (duration == null || length > duration) {
        duration = length;
        pgc = Uint8List.sublistView(b, at);
      }
    }
  }

  final audio = <DvdAudioStream>[];
  for (final (i, a) in attributes.indexed) {
    var number = i;
    if (pgc != null) {
      // The chain's audio control: bit 15 = present, bits 8-10 = the
      // stream number in the film.
      final control = _u16(pgc, 0x0C + i * 2);
      if (control & 0x8000 == 0) continue;
      number = (control >> 8) & 7;
    }
    audio.add(DvdAudioStream(
      coding: a.coding,
      number: number,
      channels: a.channels,
      language: a.language,
      extension: a.extension,
    ));
  }

  final chapters = <Duration>[];
  if (pgc != null) {
    final programs = pgc[2];
    final cells = pgc[3];
    final mapAt = _u16(pgc, 0xE6);
    final cellsAt = _u16(pgc, 0xE8);
    if (mapAt > 0 && cellsAt > 0 && mapAt + programs <= pgc.length && cellsAt + cells * 24 <= pgc.length) {
      // Each cell's start; cells of an angle block after its first don't
      // add (they're the same part, seen otherwise).
      final starts = <Duration>[];
      var time = Duration.zero;
      for (var c = 0; c < cells; c++) {
        final o = cellsAt + c * 24;
        starts.add(time);
        final blockMode = pgc[o] >> 6;
        if (blockMode <= 1) time += dvdTime(pgc, o + 4);
      }
      for (var p = 0; p < programs; p++) {
        final cell = pgc[mapAt + p] - 1;
        if (cell >= 0 && cell < starts.length) chapters.add(starts[cell]);
      }
    }
  }
  return DvdTitleInfo(audio: audio, duration: duration, chapters: chapters);
}

/// The sound tracks found in the first packs of a DVD stream - for VOB
/// files without their IFO. In stream order.
List<DvdAudioStream> scanDvdAudio(Uint8List bytes) {
  final found = <DvdAudioStream>{};
  for (var at = 0; at + discPack <= bytes.length; at += discPack) {
    forEachPes(Uint8List.sublistView(bytes, at, at + discPack), (pack, pos, id, end) {
      if (id >= 0xC0 && id <= 0xC7) {
        found.add(DvdAudioStream(coding: DvdAudioCoding.mpeg, number: id - 0xC0));
      } else if (id == 0xBD) {
        final sub = _substream(pack, pos, end);
        if (sub == null) return;
        final stream = switch (sub) {
          >= 0x80 && <= 0x87 => DvdAudioStream(coding: DvdAudioCoding.ac3, number: sub - 0x80),
          >= 0x88 && <= 0x8F => DvdAudioStream(coding: DvdAudioCoding.dts, number: sub - 0x88),
          >= 0xA0 && <= 0xA7 => DvdAudioStream(coding: DvdAudioCoding.lpcm, number: sub - 0xA0),
          _ => null,
        };
        if (stream != null) found.add(stream);
      }
    });
  }
  return found.toList();
}

/// A DVD pack: one sector.
const discPack = 2048;

/// Calls [visit] for each PES packet in the MPEG-2 pack [pack] with its
/// start, stream id and end (exclusive). Stops at anything it doesn't
/// understand.
void forEachPes(Uint8List pack, void Function(Uint8List pack, int pos, int id, int end) visit) {
  if (pack.length < 14 || pack[0] != 0 || pack[1] != 0 || pack[2] != 1 || pack[3] != 0xBA) return;
  var pos = switch (pack[4] >> 6) {
    1 => 14 + (pack[13] & 7), // MPEG-2
    _ when pack[4] >> 4 == 2 => 12, // MPEG-1
    _ => -1,
  };
  if (pos < 0) return;
  while (pos + 6 <= pack.length) {
    if (pack[pos] != 0 || pack[pos + 1] != 0 || pack[pos + 2] != 1) return;
    final id = pack[pos + 3];
    if (id == 0xB9 || id == 0xBA) return;
    final end = pos + 6 + _u16(pack, pos + 4);
    if (end > pack.length) return;
    visit(pack, pos, id, end);
    pos = end;
  }
}

/// The sub-stream number of the private stream 1 packet at [pos] (MPEG-2
/// PES header), or null.
int? _substream(Uint8List pack, int pos, int end) {
  if (pos + 9 > end || pack[pos + 6] >> 6 != 2) return null;
  final payload = pos + 9 + pack[pos + 8];
  return payload < end ? pack[payload] : null;
}

/// Rewrites DVD packs in place (same size - every byte stays where it was,
/// so ranges and seeking aren't affected):
///
/// * every sound track but [keep] and the DVD subtitles (bitmaps) become
///   padding (stream id 0xBE) - the player only sees the chosen sound;
/// * [stripHeader] (ExoPlayer): the 4 bytes DVDs put in front of AC3 in
///   private stream 1 (sub-stream number, frame count, pointer) become PES
///   header stuffing. ExoPlayer reads private stream 1 straight as AC3, so
///   the bytes would land inside the AC3 frames. libmpv wants them (it
///   tells the tracks apart by them).
///
/// [keep] null: the sound tracks stay as they are.
class DvdPackFilter {
  const DvdPackFilter({this.keep, this.stripHeader = false});

  final DvdAudioStream? keep;
  final bool stripHeader;

  void apply(Uint8List pack) {
    final keep = this.keep;
    forEachPes(pack, (pack, pos, id, end) {
      if (id >= 0xC0 && id <= 0xDF) {
        if (keep != null && id != keep.streamId) pack[pos + 3] = 0xBE;
        return;
      }
      if (id != 0xBD) return;
      final sub = _substream(pack, pos, end);
      if (sub == null) return;
      final isSound = sub >= 0x80 && sub <= 0xAF;
      if (!isSound) {
        // Subtitles (0x20-0x3F) and anything else.
        pack[pos + 3] = 0xBE;
        return;
      }
      if (keep == null) return;
      if (sub != keep.substream) {
        pack[pos + 3] = 0xBE;
        return;
      }
      final headerLength = pack[pos + 8];
      if (stripHeader && sub >= 0x80 && sub <= 0x87 && headerLength + 4 <= 0xFF && pos + 9 + headerLength + 4 <= end) {
        final payload = pos + 9 + headerLength;
        pack.fillRange(payload, payload + 4, 0xFF);
        pack[pos + 8] = headerLength + 4;
      }
    });
  }
}

/// Whether [head] (the start of a file) looks like a DVD stream: MPEG-2
/// packs on every 2048 bytes.
bool looksLikeDvdStream(Uint8List head) {
  if (head.length < discPack + 4) return false;
  bool packAt(int at) => head[at] == 0 && head[at + 1] == 0 && head[at + 2] == 1 && head[at + 3] == 0xBA;
  return packAt(0) && packAt(discPack) && head[4] >> 6 == 1;
}
