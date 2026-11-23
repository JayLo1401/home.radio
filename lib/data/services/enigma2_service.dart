import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// Connection to an Enigma2 satellite receiver (GigaBlue, VU+, Dreambox, ...
/// with OpenWebif - teamBlue, OpenATV, OpenPLi images all have it).
class Enigma2Config {
  const Enigma2Config({
    this.host = '',
    this.webPort = 80,
    this.streamPort = 8001,
    this.useHttps = false,
    this.user = '',
    this.password = '',
  });

  final String host;
  final int webPort;

  /// The receiver's streaming port: 8001 sends the channel as it is
  /// (MPEG-TS), 8002 transcoded where the box supports it.
  final int streamPort;
  final bool useHttps;
  final String user;
  final String password;

  bool get configured => host.trim().isNotEmpty;

  String get _scheme => useHttps ? 'https' : 'http';

  Uri webUri(String path, [Map<String, String>? query]) =>
      Uri(scheme: _scheme, host: host.trim(), port: webPort, path: path, queryParameters: query);

  Map<String, String> get authHeaders => user.isEmpty
      ? const {}
      : {'Authorization': 'Basic ${base64Encode(utf8.encode('$user:$password'))}'};

  /// The live stream of a channel - the box tunes a free tuner for it. The
  /// login (if any) goes along as [authHeaders].
  Uri streamUri(String serviceRef) => Uri.parse('http://${host.trim()}:$streamPort/${Uri.encodeFull(serviceRef)}');

  /// OpenWebif's picon for a channel: the service reference with ':' as '_'
  /// and without the trailing separator ("1_0_19_283D_3FB_1_C00000_0_0_0").
  Uri piconUri(String serviceRef) => webUri('/picon/${piconName(serviceRef)}.png');

  Map<String, Object?> toJson() => {
        'host': host,
        'webPort': webPort,
        'streamPort': streamPort,
        'https': useHttps,
        'user': user,
      };

  static Enigma2Config fromJson(Object? json, {String password = ''}) {
    if (json is! Map) return const Enigma2Config();
    return Enigma2Config(
      host: json['host'] as String? ?? '',
      webPort: json['webPort'] as int? ?? 80,
      streamPort: json['streamPort'] as int? ?? 8001,
      useHttps: json['https'] == true,
      user: json['user'] as String? ?? '',
      password: password,
    );
  }

  Enigma2Config copyWith({String? host, int? webPort, int? streamPort, bool? useHttps, String? user, String? password}) =>
      Enigma2Config(
        host: host ?? this.host,
        webPort: webPort ?? this.webPort,
        streamPort: streamPort ?? this.streamPort,
        useHttps: useHttps ?? this.useHttps,
        user: user ?? this.user,
        password: password ?? this.password,
      );
}

/// "1:0:19:283D:3FB:1:C00000:0:0:0:" -> "1_0_19_283D_3FB_1_C00000_0_0_0" -
/// the file name picons use. Only the first 10 fields count (a name or URL
/// after them, as with IPTV entries, is dropped).
String piconName(String serviceRef) {
  final fields = serviceRef.split(':');
  final core = fields.length > 10 ? fields.sublist(0, 10) : fields.where((f) => f.isNotEmpty).toList();
  // Picons use service type 1 for every TV type (0x19 HD, 0x1F UHD, ...).
  if (core.length > 2) core[2] = '1';
  return core.join('_').toUpperCase();
}

/// A bouquet (channel list) of the receiver, e.g. "Favourites (TV)".
class E2Bouquet {
  const E2Bouquet({required this.ref, required this.name});

  final String ref;
  final String name;
}

/// A TV channel.
class E2Channel {
  const E2Channel({required this.ref, required this.name, required this.number, this.piconPath, this.hasPicon = true});

  final String ref;
  final String name;

  /// Position in the bouquet, counted from 1 (markers don't count).
  final int number;

  /// OpenWebif's own picon path for it, if it told us.
  final String? piconPath;

  /// The receiver has a picon for it - without one, OpenWebif names its own
  /// placeholder ("/images/default_picon.png", the OpenWebif logo), which
  /// isn't the channel's logo.
  final bool hasPicon;

  /// Radio channel (service type 2) rather than TV.
  bool get isRadio => ref.split(':').elementAtOrNull(2) == '2';
}

/// One programme of the EPG.
class E2Event {
  const E2Event({
    required this.serviceRef,
    required this.title,
    required this.begin,
    required this.duration,
    this.shortDescription = '',
    this.longDescription = '',
    this.id,
  });

  final String serviceRef;
  final String title;
  final DateTime begin;
  final Duration duration;
  final String shortDescription;
  final String longDescription;
  final int? id;

  DateTime get end => begin.add(duration);

  bool runsAt(DateTime t) => !t.isBefore(begin) && t.isBefore(end);

  /// 0..1 of the programme gone by at [t].
  double progressAt(DateTime t) {
    if (duration.inSeconds <= 0) return 0;
    return (t.difference(begin).inSeconds / duration.inSeconds).clamp(0.0, 1.0);
  }

  String get description {
    final s = shortDescription.trim(), l = longDescription.trim();
    if (s.isEmpty) return l;
    if (l.isEmpty || l.startsWith(s)) return l.isEmpty ? s : l;
    return '$s\n\n$l';
  }

  static E2Event? fromJson(Map<String, dynamic> j) {
    final title = (j['title'] as String?)?.trim() ?? '';
    final begin = _int(j['begin_timestamp']);
    final duration = _int(j['duration_sec']);
    if (title.isEmpty || begin == null || duration == null) return null;
    return E2Event(
      serviceRef: j['sref'] as String? ?? '',
      title: title,
      begin: DateTime.fromMillisecondsSinceEpoch(begin * 1000),
      duration: Duration(seconds: duration),
      shortDescription: j['shortdesc'] as String? ?? '',
      longDescription: j['longdesc'] as String? ?? '',
      id: _int(j['id']),
    );
  }

  static int? _int(Object? v) => v is int ? v : (v is num ? v.toInt() : int.tryParse('$v'));
}

/// What the receiver says about itself (for "Verbindung testen").
class E2BoxInfo {
  const E2BoxInfo({required this.model, required this.image});

  final String model;
  final String image;
}

class Enigma2Exception implements Exception {
  Enigma2Exception(this.message);

  final String message;

  @override
  String toString() => message;
}

/// OpenWebif's JSON API (/api/...) of an Enigma2 receiver.
class Enigma2Service {
  Enigma2Service(this.config, {http.Client? client}) : _client = client ?? http.Client();

  final Enigma2Config config;
  final http.Client _client;
  static const _timeout = Duration(seconds: 15);

  Future<Map<String, dynamic>> _get(String path, [Map<String, String>? query]) async {
    if (!config.configured) throw Enigma2Exception('Kein Receiver eingerichtet');
    final http.Response response;
    try {
      response = await _client.get(config.webUri(path, query), headers: config.authHeaders).timeout(_timeout);
    } catch (e) {
      throw Enigma2Exception('Receiver nicht erreichbar (${config.host}): $e');
    }
    if (response.statusCode == 401) throw Enigma2Exception('Anmeldung abgelehnt - Benutzer/Passwort prüfen');
    if (response.statusCode != 200) throw Enigma2Exception('Receiver antwortet mit Fehler ${response.statusCode}');
    final decoded = jsonDecode(utf8.decode(response.bodyBytes, allowMalformed: true));
    if (decoded is! Map<String, dynamic>) throw Enigma2Exception('Unerwartete Antwort vom Receiver');
    return decoded;
  }

  Future<E2BoxInfo> about() async {
    final j = await _get('/api/about');
    final info = j['info'] is Map ? j['info'] as Map : j;
    return E2BoxInfo(
      model: '${info['brand'] ?? ''} ${info['model'] ?? info['boxtype'] ?? ''}'.trim(),
      image: '${info['friendlyimagedistro'] ?? info['imagedistro'] ?? ''} ${info['imagever'] ?? ''}'.trim(),
    );
  }

  /// The TV bouquets.
  Future<List<E2Bouquet>> bouquets() async {
    final j = await _get('/api/getservices');
    return [
      for (final s in (j['services'] as List? ?? const []).whereType<Map>())
        if ((s['servicereference'] as String?)?.isNotEmpty ?? false)
          E2Bouquet(ref: s['servicereference'] as String, name: (s['servicename'] as String? ?? '').trim()),
    ];
  }

  /// The channels of a bouquet (markers and empty entries left out).
  Future<List<E2Channel>> channels(String bouquetRef) async {
    final j = await _get('/api/getservices', {'sRef': bouquetRef, 'picon': '1'});
    return parseChannels(j);
  }

  /// What's on now and next on every channel of a bouquet.
  Future<List<E2Event>> nowNext(String bouquetRef) async {
    final j = await _get('/api/epgnownext', {'bRef': bouquetRef});
    return _events(j);
  }

  /// The programmes of every channel of a bouquet from [from] (including
  /// the ones running then) for [span] - the TV guide's grid. One query for
  /// all channels (3 hours of a 100 channel bouquet: about 0.2 s).
  Future<List<E2Event>> epgMulti(String bouquetRef, DateTime from, Duration span) async {
    final j = await _get('/api/epgmulti', {
      'bRef': bouquetRef,
      'time': '${from.millisecondsSinceEpoch ~/ 1000}',
      'endTime': '${span.inMinutes}',
    });
    return _events(j);
  }

  /// The EPG of one channel (as far as the box has it, usually a week).
  Future<List<E2Event>> channelEpg(String serviceRef) async {
    final j = await _get('/api/epgservice', {'sRef': serviceRef});
    return _events(j)..sort((a, b) => a.begin.compareTo(b.begin));
  }

  List<E2Event> _events(Map<String, dynamic> j) => [
        for (final e in (j['events'] as List? ?? const []).whereType<Map<String, dynamic>>()) ?E2Event.fromJson(e),
      ];

  /// Switches the receiver itself to [serviceRef] (its live picture). A CI
  /// module / card usually descrambles only that one channel - a stream of
  /// any other encrypted channel stays scrambled.
  Future<void> zap(String serviceRef) async {
    final j = await _get('/api/zap', {'sRef': serviceRef});
    if (j['result'] == false) throw Enigma2Exception('Receiver schaltet nicht um: ${j['message'] ?? ''}');
  }

  /// The channel the receiver shows itself, null if unknown.
  Future<String?> currentServiceRef() async {
    try {
      final j = await _get('/api/statusinfo');
      final ref = j['currservice_serviceref'];
      return ref is String && ref.isNotEmpty ? ref : null;
    } catch (_) {
      return null;
    }
  }

  /// Whether the receiver is in standby, and the channel it holds itself
  /// (null: none - in standby it normally holds nothing; after a switch
  /// over the network it keeps that channel's tuner, and with only one
  /// satellite cable that blocks every other band).
  Future<({bool standby, String? live})> state() async {
    try {
      final j = await _get('/api/statusinfo');
      final ref = j['currservice_serviceref'];
      final standby = j['inStandby'];
      return (
        standby: standby == true || standby == 'true',
        live: ref is String && ref.isNotEmpty ? ref : null,
      );
    } catch (_) {
      return (standby: false, live: null);
    }
  }

  /// Lets go of the channel the receiver holds (in standby): switched to
  /// an empty service, Enigma2 stops the running one and frees its tuner.
  Future<void> release() async {
    await _get('/api/zap', {'sRef': '1:0:0:0:0:0:0:0:0:0:'});
  }
}

enum StreamScrambling { clear, scrambled, unknown }

/// Reads MPEG-TS packets (188 bytes, sync byte 0x47) and tells when the
/// main stream - the PID with the most packets, the picture - runs
/// descrambled: [clearRun] packets in a row without the scrambling bits;
/// or that it's scrambled: [scrambledAfter] of its packets and at least half
/// of them scrambled.
class TsScramblingProbe {
  TsScramblingProbe({this.clearRun = 150, this.scrambledAfter = 300});

  final int clearRun;
  final int scrambledAfter;
  final _count = <int, int>{};
  final _clear = <int, int>{};
  final _scrambled = <int, int>{};
  var _rest = Uint8List(0);
  bool sawScrambled = false;

  /// MPEG-TS packets seen so far (an error text from the receiver has none).
  int packets = 0;

  StreamScrambling? add(List<int> chunk) {
    final data = Uint8List(_rest.length + chunk.length)
      ..setAll(0, _rest)
      ..setAll(_rest.length, chunk);
    var i = 0;
    while (i + 188 <= data.length) {
      if (data[i] != 0x47) {
        i++;
        continue;
      }
      packets++;
      final pid = ((data[i + 1] & 0x1F) << 8) | data[i + 2];
      // PSI tables and padding aren't the picture.
      if (pid >= 0x20 && pid != 0x1FFF) {
        _count[pid] = (_count[pid] ?? 0) + 1;
        if (data[i + 3] >> 6 != 0) {
          _clear[pid] = 0;
          _scrambled[pid] = (_scrambled[pid] ?? 0) + 1;
          sawScrambled = true;
        } else {
          _clear[pid] = (_clear[pid] ?? 0) + 1;
        }
      }
      i += 188;
    }
    _rest = Uint8List.sublistView(data, i);
    if (_count.isEmpty) return null;
    final main = _count.entries.reduce((a, b) => a.value >= b.value ? a : b);
    if ((_clear[main.key] ?? 0) >= clearRun) return StreamScrambling.clear;
    // Half is enough: some packets of a scrambled picture come clear anyway
    // (timing-only ones without picture data, e.g. on ORF's channels).
    if (main.value >= scrambledAfter && (_scrambled[main.key] ?? 0) >= main.value * 0.5) return StreamScrambling.scrambled;
    return null;
  }
}

/// Channels from /api/getservices?sRef=... - markers (type 64) and
/// placeholders ("1:832:...") are not channels; numbers count the rest.
List<E2Channel> parseChannels(Map<String, dynamic> j) {
  final channels = <E2Channel>[];
  for (final s in (j['services'] as List? ?? const []).whereType<Map>()) {
    final ref = s['servicereference'] as String? ?? '';
    final flags = int.tryParse(ref.split(':').elementAtOrNull(1) ?? '') ?? 0;
    if (ref.isEmpty || flags & 64 != 0 || flags & 512 != 0) continue;
    final name = (s['servicename'] as String? ?? '').trim();
    if (name.isEmpty || name == '<n/a>') continue;
    final picon = s['picon'] is String ? (s['picon'] as String).trim() : '';
    final placeholder = picon.contains('default_picon');
    channels.add(E2Channel(
      ref: ref,
      name: name,
      number: channels.length + 1,
      piconPath: picon.isEmpty || placeholder ? null : picon,
      hasPicon: !placeholder,
    ));
  }
  return channels;
}
