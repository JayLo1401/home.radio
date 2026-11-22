import 'dart:convert';

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
  const E2Channel({required this.ref, required this.name, required this.number, this.piconPath});

  final String ref;
  final String name;

  /// Position in the bouquet, counted from 1 (markers don't count).
  final int number;

  /// OpenWebif's own picon path for it, if it told us.
  final String? piconPath;

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

  /// The EPG of one channel (as far as the box has it, usually a week).
  Future<List<E2Event>> channelEpg(String serviceRef) async {
    final j = await _get('/api/epgservice', {'sRef': serviceRef});
    return _events(j)..sort((a, b) => a.begin.compareTo(b.begin));
  }

  List<E2Event> _events(Map<String, dynamic> j) => [
        for (final e in (j['events'] as List? ?? const []).whereType<Map<String, dynamic>>()) ?E2Event.fromJson(e),
      ];
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
    channels.add(E2Channel(
      ref: ref,
      name: name,
      number: channels.length + 1,
      piconPath: s['picon'] is String && (s['picon'] as String).isNotEmpty ? s['picon'] as String : null,
    ));
  }
  return channels;
}
