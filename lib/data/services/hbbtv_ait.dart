import 'dart:typed_data';

/// HbbTV's signalling in the channel's MPEG-TS stream: the PMT names a PID
/// with stream_type 0x05 (application_signalling_descriptor) and on it runs
/// the AIT, the Application Information Table (ETSI TS 102 809, 5.3.4) -
/// which applications the channel offers and where they are on the web.
///
/// Enigma2's stream (port 8001) carries the AIT PID along with picture and
/// sound (seen on ORF1 HD, Das Erste HD, ZDF HD, ServusTV HD on Astra
/// 19.2° E): a few seconds of the stream are enough ([AitScanner]).

/// The DVB triplet of an Enigma2 service reference
/// ("1:0:19:283D:3FB:1:C00000:0:0:0:" -> sid 0x283D, tsid 0x3FB, onid 1).
class DvbTriplet {
  const DvbTriplet({required this.sid, required this.tsid, required this.onid});

  final int sid;
  final int tsid;
  final int onid;

  static DvbTriplet? fromServiceRef(String ref) {
    final f = ref.split(':');
    if (f.length < 6) return null;
    final sid = int.tryParse(f[3], radix: 16), tsid = int.tryParse(f[4], radix: 16), onid = int.tryParse(f[5], radix: 16);
    if (sid == null || tsid == null || onid == null || sid == 0) return null;
    return DvbTriplet(sid: sid, tsid: tsid, onid: onid);
  }
}

/// One application of the AIT.
class HbbtvApp {
  const HbbtvApp({
    required this.orgId,
    required this.appId,
    required this.controlCode,
    this.name = '',
    this.url,
    this.priority = 0,
  });

  final int orgId;
  final int appId;

  /// 1 AUTOSTART (the channel's "red button" app), 2 PRESENT, 4 KILL, ...
  final int controlCode;
  final String name;

  /// Where it is on the web (URL base + initial path) - null if it only
  /// comes in the broadcast's object carousel (DSM-CC), which isn't read.
  final String? url;
  final int priority;

  bool get autostart => controlCode == 1;

  /// As HbbTV apps name each other: `dvb://current.ait/<org>.<app>` (hex).
  String get dvbId => '${orgId.toRadixString(16)}.${appId.toRadixString(16)}';

  Map<String, Object?> toJson() => {'org': orgId, 'app': appId, 'name': name, 'url': url};

  @override
  String toString() => 'HbbtvApp($dvbId, $controlCode, "$name", $url)';
}

/// The application to start with the red key: the autostart one with the
/// highest priority that can be loaded from the web; without one, the first
/// loadable one that's offered (control code PRESENT).
HbbtvApp? pickStartApp(List<HbbtvApp> apps) {
  final web = apps.where((a) => a.url != null).toList();
  final auto = web.where((a) => a.autostart).toList()..sort((a, b) => b.priority.compareTo(a.priority));
  if (auto.isNotEmpty) return auto.first;
  return web.where((a) => a.controlCode == 2).firstOrNull;
}

/// The AIT's application type for HbbTV (0x0010); MHP's (1) and others
/// may run on the same PID.
const hbbtvApplicationType = 0x0010;

/// The applications of one AIT section (table_id 0x74), an empty list if it
/// isn't one for HbbTV or is broken.
List<HbbtvApp> parseAitSection(List<int> s) {
  try {
    if (s.length < 16 || s[0] != 0x74) return const [];
    final length = 3 + (((s[1] & 0x0F) << 8) | s[2]);
    if (length > s.length || length < 16) return const [];
    final type = ((s[3] & 0x7F) << 8) | s[4];
    if (type != hbbtvApplicationType) return const [];
    final end = length - 4; // CRC
    var i = 8;
    final commonLength = ((s[i] & 0x0F) << 8) | s[i + 1];
    i += 2 + commonLength;
    if (i + 2 > end) return const [];
    final loopLength = ((s[i] & 0x0F) << 8) | s[i + 1];
    i += 2;
    final loopEnd = (i + loopLength).clamp(0, end);
    final apps = <HbbtvApp>[];
    while (i + 9 <= loopEnd) {
      final orgId = (s[i] << 24) | (s[i + 1] << 16) | (s[i + 2] << 8) | s[i + 3];
      final appId = (s[i + 4] << 8) | s[i + 5];
      final control = s[i + 6];
      final descLength = ((s[i + 7] & 0x0F) << 8) | s[i + 8];
      i += 9;
      final descEnd = (i + descLength).clamp(0, loopEnd);
      apps.add(_app(s, i, descEnd, orgId, appId, control));
      i = descEnd;
    }
    return apps;
  } catch (_) {
    return const [];
  }
}

HbbtvApp _app(List<int> s, int from, int to, int orgId, int appId, int control) {
  var name = '';
  var priority = 0;
  var labels = <int>[];
  var path = '';
  // Transport protocol label -> HTTP URL base (protocol 3).
  final http = <int, String>{};
  var i = from;
  while (i + 2 <= to) {
    final tag = s[i], len = s[i + 1];
    final d = i + 2, e = (d + len).clamp(0, to);
    switch (tag) {
      case 0x00: // application_descriptor
        if (d < e) {
          final profilesLength = s[d];
          final p = d + 1 + profilesLength;
          if (p + 2 <= e) {
            priority = s[p + 1];
            labels = [for (var k = p + 2; k < e; k++) s[k]];
          }
        }
      case 0x01: // application_name_descriptor: language (3), length, name
        if (name.isEmpty && d + 4 <= e) {
          final n = s[d + 3];
          name = _text(s, d + 4, (d + 4 + n).clamp(0, e));
        }
      case 0x02: // transport_protocol_descriptor
        if (d + 3 <= e) {
          final protocol = (s[d] << 8) | s[d + 1];
          final label = s[d + 2];
          if (protocol == 3 && d + 4 <= e) {
            final n = s[d + 3];
            final base = _text(s, d + 4, (d + 4 + n).clamp(0, e));
            if (base.isNotEmpty) http[label] = base;
          }
        }
      case 0x15: // simple_application_location_descriptor
        path = _text(s, d, e);
    }
    i = e;
  }
  String? url;
  if (http.isNotEmpty) {
    final base = labels.map((l) => http[l]).whereType<String>().firstOrNull ?? http.values.first;
    url = joinAppUrl(base, path);
  }
  return HbbtvApp(orgId: orgId, appId: appId, controlCode: control, name: name, url: url, priority: priority);
}

/// URL base + initial path (the base normally ends with '/').
String joinAppUrl(String base, String path) {
  if (path.isEmpty) return base;
  if (path.startsWith('http://') || path.startsWith('https://')) return path;
  if (base.endsWith('/') && path.startsWith('/')) return base + path.substring(1);
  if (!base.endsWith('/') && !path.startsWith('/')) return '$base/$path';
  return base + path;
}

/// Names and URLs are ASCII / ISO 8859-1 in practice (DVB's default table).
String _text(List<int> s, int from, int to) {
  if (from >= to) return '';
  var a = from;
  // A DVB character table byte in front (0x01..0x1F) - left out.
  if (s[a] < 0x20) a += s[a] == 0x10 ? 3 : 1;
  return String.fromCharCodes([for (var k = a; k < to; k++) if (s[k] >= 0x20) s[k]]).trim();
}

/// MPEG-2's CRC-32 of a PSI section (0 over a section with its CRC).
int mpegCrc32(List<int> data, [int start = 0, int? end]) {
  var crc = 0xFFFFFFFF;
  for (var i = start; i < (end ?? data.length); i++) {
    crc ^= data[i] << 24;
    for (var b = 0; b < 8; b++) {
      crc = (crc & 0x80000000) != 0 ? ((crc << 1) ^ 0x04C11DB7) : (crc << 1);
      crc &= 0xFFFFFFFF;
    }
  }
  return crc;
}

/// Puts PSI sections back together from the TS packets of one PID.
class _SectionAssembler {
  final _buffer = BytesBuilder(copy: false);
  Uint8List _pending = Uint8List(0);
  bool _synced = false;

  /// [payload]: the packet's payload, [start]: payload_unit_start_indicator.
  List<Uint8List> add(Uint8List payload, bool start) {
    final out = <Uint8List>[];
    if (start) {
      if (payload.isEmpty) return out;
      final pointer = payload[0];
      if (_synced && 1 + pointer <= payload.length) {
        _append(Uint8List.sublistView(payload, 1, 1 + pointer));
        _drain(out);
      }
      _pending = Uint8List(0);
      _synced = true;
      if (1 + pointer <= payload.length) _append(Uint8List.sublistView(payload, 1 + pointer));
    } else if (_synced) {
      _append(payload);
    }
    _drain(out);
    return out;
  }

  void _append(Uint8List bytes) {
    _buffer
      ..add(_pending)
      ..add(bytes);
    _pending = _buffer.takeBytes();
  }

  void _drain(List<Uint8List> out) {
    while (_pending.length >= 3) {
      if (_pending[0] == 0xFF) {
        // Stuffing up to the next section start.
        _pending = Uint8List(0);
        _synced = false;
        return;
      }
      final length = 3 + (((_pending[1] & 0x0F) << 8) | _pending[2]);
      if (length > 4096) {
        _pending = Uint8List(0);
        _synced = false;
        return;
      }
      if (_pending.length < length) return;
      out.add(Uint8List.fromList(Uint8List.sublistView(_pending, 0, length)));
      _pending = Uint8List.sublistView(_pending, length);
    }
  }
}

enum AitScanState {
  /// Still looking.
  searching,

  /// The AIT is complete: [AitScanner.apps].
  found,

  /// The channel's PMT names no AIT - it has no HbbTV.
  none,
}

/// Reads a channel's MPEG-TS stream until it has the AIT: PAT (PID 0) ->
/// the service's PMT -> the PID with stream_type 0x05 -> all sections of
/// the AIT. Feed it chunks of the stream with [add].
class AitScanner {
  AitScanner({this.serviceId});

  /// The service (program_number) to look at - without one (or if the PAT
  /// lacks it) the first program whose PMT comes along.
  final int? serviceId;

  final _assemblers = <int, _SectionAssembler>{};
  var _rest = Uint8List(0);
  final _pmtPids = <int, int>{}; // PID -> program number
  int? _aitPid;
  int? _version;
  final _sections = <int, List<HbbtvApp>>{};
  int? _lastSection;

  AitScanState state = AitScanState.searching;

  /// The AIT's HbbTV applications once [state] is [AitScanState.found].
  List<HbbtvApp> apps = const [];

  /// Whether the PMT was seen (and so whether the AIT PID is known).
  bool get pmtSeen => _aitPid != null || state == AitScanState.none;

  int packets = 0;

  AitScanState add(List<int> chunk) {
    if (state != AitScanState.searching) return state;
    final data = Uint8List(_rest.length + chunk.length)
      ..setAll(0, _rest)
      ..setAll(_rest.length, chunk);
    var i = 0;
    while (i + 188 <= data.length && state == AitScanState.searching) {
      if (data[i] != 0x47) {
        i++;
        continue;
      }
      packets++;
      _packet(Uint8List.sublistView(data, i, i + 188));
      i += 188;
    }
    _rest = state == AitScanState.searching ? Uint8List.fromList(Uint8List.sublistView(data, i)) : Uint8List(0);
    return state;
  }

  void _packet(Uint8List p) {
    final pid = ((p[1] & 0x1F) << 8) | p[2];
    final wanted = pid == 0 || _pmtPids.containsKey(pid) || pid == _aitPid;
    if (!wanted) return;
    if (p[3] >> 6 != 0) return; // scrambled (PSI never is)
    final afc = (p[3] >> 4) & 3;
    if (afc & 1 == 0) return;
    var off = 4;
    if (afc & 2 != 0) off += 1 + p[4];
    if (off >= 188) return;
    final sections = _assemblers.putIfAbsent(pid, _SectionAssembler.new).add(Uint8List.sublistView(p, off), p[1] & 0x40 != 0);
    for (final s in sections) {
      if (state != AitScanState.searching) return;
      if (s.length < 8 || mpegCrc32(s) != 0) continue;
      if (pid == 0 && s[0] == 0x00) {
        _pat(s);
      } else if (pid == _aitPid && s[0] == 0x74) {
        _ait(s);
      } else if (_pmtPids.containsKey(pid) && s[0] == 0x02) {
        _pmt(s, _pmtPids[pid]!);
      }
    }
  }

  void _pat(Uint8List s) {
    if (_pmtPids.isNotEmpty) return;
    final end = s.length - 4;
    final programs = <int, int>{};
    for (var i = 8; i + 4 <= end; i += 4) {
      final number = (s[i] << 8) | s[i + 1];
      final pid = ((s[i + 2] & 0x1F) << 8) | s[i + 3];
      if (number != 0) programs[pid] = number;
    }
    final mine = programs.entries.where((e) => e.value == serviceId);
    _pmtPids.addAll(mine.isNotEmpty ? Map.fromEntries(mine) : programs);
  }

  void _pmt(Uint8List s, int program) {
    if (_aitPid != null) return;
    final end = s.length - 4;
    final infoLength = ((s[10] & 0x0F) << 8) | s[11];
    var i = 12 + infoLength;
    while (i + 5 <= end) {
      final type = s[i];
      final pid = ((s[i + 1] & 0x1F) << 8) | s[i + 2];
      final esInfo = ((s[i + 3] & 0x0F) << 8) | s[i + 4];
      if (type == 0x05 && _signalsHbbtv(s, i + 5, (i + 5 + esInfo).clamp(0, end))) {
        _aitPid = pid;
        return;
      }
      i += 5 + esInfo;
    }
    // This program has no AIT - if it's the one asked for (or the only one).
    if (serviceId == null || program == serviceId || _pmtPids.length == 1) state = AitScanState.none;
  }

  /// stream_type 0x05 with an application_signalling_descriptor (0x6F)
  /// naming HbbTV (or none - then any application type).
  static bool _signalsHbbtv(Uint8List s, int from, int to) {
    var i = from;
    var sawSignalling = false;
    while (i + 2 <= to) {
      final tag = s[i], len = s[i + 1];
      if (tag == 0x6F) {
        sawSignalling = true;
        if (len == 0) return true;
        for (var k = i + 2; k + 3 <= i + 2 + len && k + 3 <= to; k += 3) {
          if ((((s[k] & 0x7F) << 8) | s[k + 1]) == hbbtvApplicationType) return true;
        }
      }
      i += 2 + len;
    }
    return !sawSignalling;
  }

  void _ait(Uint8List s) {
    final type = ((s[3] & 0x7F) << 8) | s[4];
    if (type != hbbtvApplicationType) return;
    final version = (s[5] >> 1) & 0x1F;
    if (s[5] & 1 == 0) return; // not yet valid
    if (_version != version) {
      _version = version;
      _sections.clear();
    }
    _lastSection = s[7];
    _sections[s[6]] = parseAitSection(s);
    if (_sections.length > _lastSection!) {
      apps = [for (var n = 0; n <= _lastSection!; n++) ...?_sections[n]];
      state = AitScanState.found;
    }
  }
}
