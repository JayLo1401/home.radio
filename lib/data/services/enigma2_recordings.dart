import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../l10n/l10n.dart';
import 'enigma2_service.dart';
import 'tv_reminders.dart' show serviceKeyOf;

/// A timer of the receiver (OpenWebif /api/timerlist): a recording, or a
/// switch only ([justPlay]). [begin]/[end] include the receiver's margins.
@immutable
class E2Timer {
  const E2Timer({
    required this.serviceRef,
    required this.serviceName,
    required this.name,
    required this.begin,
    required this.end,
    this.description = '',
    this.eit,
    this.state = 0,
    this.disabled = false,
    this.justPlay = false,
    this.location = '',
  });

  final String serviceRef;
  final String serviceName;
  final String name;
  final String description;
  final DateTime begin;
  final DateTime end;

  /// The EPG event it was made for (null: by hand).
  final int? eit;

  /// Enigma2's TimerEntry state: 0 waiting, 1 about to start, 2 running,
  /// 3 ended.
  final int state;
  final bool disabled;
  final bool justPlay;

  /// Where it records to on the receiver.
  final String location;

  bool get isRecording => !justPlay;
  bool get running => state == 1 || state == 2;
  bool get ended => state == 3;

  static E2Timer? fromJson(Map<dynamic, dynamic> j) {
    final ref = j['serviceref'];
    final begin = _int(j['begin']), end = _int(j['end']);
    if (ref is! String || ref.isEmpty || begin == null || end == null) return null;
    final eit = _int(j['eit']);
    return E2Timer(
      serviceRef: ref,
      serviceName: htmlUnescape('${j['servicename'] ?? ''}'.trim()),
      name: htmlUnescape('${j['name'] ?? ''}'.trim()),
      description: htmlUnescape('${j['description'] ?? ''}'.trim()),
      begin: DateTime.fromMillisecondsSinceEpoch(begin * 1000),
      end: DateTime.fromMillisecondsSinceEpoch(end * 1000),
      eit: eit == null || eit <= 0 ? null : eit,
      state: _int(j['state']) ?? 0,
      disabled: _int(j['disabled']) == 1 || j['disabled'] == true,
      justPlay: _int(j['justplay']) == 1 || j['justplay'] == true,
      location: '${j['location'] ?? ''}',
    );
  }
}

/// What the receiver said to a new timer (or a deletion): taken or not,
/// its own message, and the timers in the way (one satellite cable: a
/// recording on another band blocks the tuner).
@immutable
class E2TimerResult {
  const E2TimerResult({required this.ok, this.message = '', this.conflicts = const []});

  final bool ok;
  final String message;
  final List<E2Timer> conflicts;

  static E2TimerResult fromJson(Map<String, dynamic> j) {
    final conflicts = <E2Timer>[];
    final raw = j['conflicts'];
    if (raw is List) {
      for (final c in raw.whereType<Map>()) {
        final t = E2Timer.fromJson(c);
        if (t != null) conflicts.add(t);
      }
    }
    final result = j['result'];
    return E2TimerResult(
      ok: result == true || result == 'true',
      message: htmlUnescape('${j['message'] ?? ''}'.trim()),
      conflicts: conflicts,
    );
  }
}

/// A finished recording on the receiver (OpenWebif /api/movielist).
@immutable
class E2Recording {
  const E2Recording({
    required this.fileName,
    required this.title,
    this.serviceRef = '',
    this.serviceName = '',
    this.description = '',
    this.recorded,
    this.length,
    this.size,
  });

  /// The file on the receiver ("/media/hdd/movie/20261128 2015 - ... .ts").
  final String fileName;
  final String title;

  /// OpenWebif's reference of the file ("1:0:0:0:0:0:0:0:0:0:/media/...")
  /// - what /api/moviedelete takes.
  final String serviceRef;
  final String serviceName;
  final String description;
  final DateTime? recorded;
  final Duration? length;
  final int? size;

  static E2Recording? fromJson(Map<dynamic, dynamic> j) {
    final file = j['filename'];
    if (file is! String || file.isEmpty) return null;
    final name = htmlUnescape('${j['eventname'] ?? ''}'.trim());
    final short = htmlUnescape('${j['description'] ?? ''}'.trim());
    final long = htmlUnescape('${j['descriptionExtended'] ?? ''}'.trim());
    final time = _int(j['recordingtime']);
    return E2Recording(
      fileName: file,
      title: name.isNotEmpty ? name : file.split('/').last,
      serviceRef: '${j['fullname'] ?? j['serviceref'] ?? ''}',
      serviceName: htmlUnescape('${j['servicename'] ?? ''}'.trim()),
      description: short.isEmpty || long.startsWith(short)
          ? (long.isEmpty ? short : long)
          : (long.isEmpty ? short : '$short\n\n$long'),
      recorded: time == null || time <= 0 ? null : DateTime.fromMillisecondsSinceEpoch(time * 1000),
      length: parseMovieLength('${j['length'] ?? ''}'),
      size: _int(j['filesize']),
    );
  }
}

/// OpenWebif's length of a recording: "90:12" (minutes:seconds), "1:30:12",
/// "?:??" when unknown.
Duration? parseMovieLength(String text) {
  final parts = text.trim().split(':');
  if (parts.length < 2 || parts.length > 3) return null;
  final n = [for (final p in parts) int.tryParse(p)];
  if (n.contains(null)) return null;
  final seconds = parts.length == 2 ? n[0]! * 60 + n[1]! : n[0]! * 3600 + n[1]! * 60 + n[2]!;
  return seconds <= 0 ? null : Duration(seconds: seconds);
}

int? _int(Object? v) => v is int ? v : (v is num ? v.toInt() : int.tryParse('$v'));

/// The timer of [event] on the channel [serviceRef], if there is one: the
/// one made for its EPG event, or one with its title covering at least
/// half of it (by hand, or the receiver's own EPG had another id).
E2Timer? timerForEvent(Iterable<E2Timer> timers, String serviceRef, E2Event event) {
  final key = serviceKeyOf(serviceRef);
  for (final t in timers) {
    if (!t.isRecording || serviceKeyOf(t.serviceRef) != key) continue;
    if (event.id != null && t.eit == event.id) return t;
    final from = t.begin.isAfter(event.begin) ? t.begin : event.begin;
    final to = t.end.isBefore(event.end) ? t.end : event.end;
    final overlap = to.difference(from).inSeconds;
    final length = event.duration.inSeconds;
    if (length > 0 && overlap >= length / 2 && t.name.trim().toLowerCase() == event.title.trim().toLowerCase()) return t;
  }
  return null;
}

/// The receiver's recording side of OpenWebif: timers (record a programme,
/// the planned recordings, delete one), the finished recordings and where
/// it records to. Only GETs to its JSON API, like [Enigma2Service].
class Enigma2Recordings {
  Enigma2Recordings(this.config, {http.Client? client}) : _client = client ?? http.Client();

  final Enigma2Config config;
  final http.Client _client;
  static const _timeout = Duration(seconds: 15);

  Future<Map<String, dynamic>> _get(String path, [Map<String, String>? query]) async {
    if (!config.configured) throw Enigma2Exception(l10n.tvErrorNoReceiver);
    final http.Response response;
    try {
      response = await _client.get(config.webUri(path, query), headers: config.authHeaders).timeout(_timeout);
    } catch (e) {
      throw Enigma2Exception(l10n.tvErrorUnreachable(config.host, '$e'));
    }
    if (response.statusCode == 401) throw Enigma2Exception(l10n.tvErrorLoginRejected);
    if (response.statusCode != 200) throw Enigma2Exception(l10n.tvErrorHttpStatus('${response.statusCode}'));
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(response.bodyBytes, allowMalformed: true));
    } catch (_) {
      throw Enigma2Exception(l10n.tvErrorUnexpectedResponse);
    }
    if (decoded is! Map<String, dynamic>) throw Enigma2Exception(l10n.tvErrorUnexpectedResponse);
    return decoded;
  }

  /// The timers, by start.
  Future<List<E2Timer>> timers() async {
    final j = await _get('/api/timerlist');
    return [
      for (final t in (j['timers'] as List? ?? const []).whereType<Map>()) ?E2Timer.fromJson(t),
    ]..sort((a, b) => a.begin.compareTo(b.begin));
  }

  /// Records [event] of the channel [serviceRef]: by its EPG event (the
  /// receiver adds its margins and the programme's texts), else by its
  /// times. A running programme is recorded from now on.
  Future<E2TimerResult> record(String serviceRef, E2Event event) async {
    final id = event.id;
    final Map<String, dynamic> j;
    if (id != null) {
      j = await _get('/api/timeraddbyeventid', {'sRef': serviceRef, 'eventid': '$id', 'justplay': '0'});
    } else {
      j = await _get('/api/timeradd', {
        'sRef': serviceRef,
        'begin': '${event.begin.millisecondsSinceEpoch ~/ 1000}',
        'end': '${event.end.millisecondsSinceEpoch ~/ 1000}',
        'name': event.title,
        'description': event.shortDescription,
        'justplay': '0',
        'disabled': '0',
        'repeated': '0',
        'afterevent': '3',
      });
    }
    return E2TimerResult.fromJson(j);
  }

  Future<E2TimerResult> deleteTimer(E2Timer timer) async {
    final j = await _get('/api/timerdelete', {
      'sRef': timer.serviceRef,
      'begin': '${timer.begin.millisecondsSinceEpoch ~/ 1000}',
      'end': '${timer.end.millisecondsSinceEpoch ~/ 1000}',
    });
    return E2TimerResult.fromJson(j);
  }

  /// The finished recordings in [folder] (null: the receiver's standard
  /// place), newest first.
  Future<List<E2Recording>> recordings({String? folder}) async {
    final j = await _get('/api/movielist', {'dirname': ?folder});
    return [
      for (final m in (j['movies'] as List? ?? const []).whereType<Map>()) ?E2Recording.fromJson(m),
    ]..sort((a, b) => (b.recorded ?? DateTime(0)).compareTo(a.recorded ?? DateTime(0)));
  }

  Future<E2TimerResult> deleteRecording(E2Recording recording) async {
    final ref = recording.serviceRef.isNotEmpty ? recording.serviceRef : '1:0:0:0:0:0:0:0:0:0:${recording.fileName}';
    return E2TimerResult.fromJson(await _get('/api/moviedelete', {'sRef': ref}));
  }

  /// Where the receiver records: its places and the one it uses now.
  Future<({List<String> locations, String? current})> locations() async {
    final j = await _get('/api/getlocations');
    final list = [for (final l in (j['locations'] as List? ?? const [])) '$l'];
    String? current = j['default'] is String ? j['default'] as String : null;
    try {
      final c = await _get('/api/getcurrlocation');
      if (c['location'] is String && (c['location'] as String).isNotEmpty) current = c['location'] as String;
    } catch (_) {}
    return (locations: list, current: current);
  }

  /// A small file of the receiver (a recording's .cuts) - null if it has
  /// none or it's bigger than [maxBytes].
  Future<Uint8List?> readFile(String fileName, {int maxBytes = 1 << 20}) async {
    if (!config.configured) return null;
    try {
      final response = await _client.get(fileUri(fileName), headers: config.authHeaders).timeout(_timeout);
      if (response.statusCode != 200 || response.bodyBytes.length > maxBytes) return null;
      return response.bodyBytes;
    } catch (_) {
      return null;
    }
  }

  /// A recording's bytes over OpenWebif (seekable: HTTP ranges).
  Uri fileUri(String fileName) => config.webUri('/file', {'file': fileName});
}

/// A little HTTP server on this device (127.0.0.1) that hands a players'
/// requests (with their ranges) on to [target] with [headers] - the films'
/// player can't send the receiver's login itself.
class HttpForwardProxy {
  HttpForwardProxy._(this._server, this._target, this._headers);

  final HttpServer _server;
  final Uri _target;
  final Map<String, String> _headers;
  final _client = http.Client();

  static Future<HttpForwardProxy> start(Uri target, Map<String, String> headers) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final proxy = HttpForwardProxy._(server, target, headers);
    server.listen((r) => unawaited(proxy._serve(r)));
    return proxy;
  }

  Uri get uri => Uri.parse('http://127.0.0.1:${_server.port}/recording.ts');

  Future<void> _serve(HttpRequest request) async {
    final response = request.response;
    try {
      final forward = http.Request(request.method == 'HEAD' ? 'HEAD' : 'GET', _target)..headers.addAll(_headers);
      final range = request.headers.value(HttpHeaders.rangeHeader);
      if (range != null) forward.headers[HttpHeaders.rangeHeader] = range;
      final upstream = await _client.send(forward).timeout(const Duration(seconds: 20));
      response.statusCode = upstream.statusCode;
      for (final h in const ['content-length', 'content-range', 'accept-ranges', 'content-type']) {
        final v = upstream.headers[h];
        if (v != null) response.headers.set(h, v);
      }
      response.headers.contentType ??= ContentType('video', 'mp2t');
      await response.addStream(upstream.stream);
      await response.close();
    } catch (e) {
      try {
        response.statusCode = HttpStatus.badGateway;
        await response.close();
      } catch (_) {}
    }
  }

  Future<void> close() async {
    _client.close();
    await _server.close(force: true);
  }
}
