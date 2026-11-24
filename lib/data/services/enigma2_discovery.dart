import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

/// An Enigma2 receiver found in the home network.
class FoundReceiver {
  const FoundReceiver({required this.host, required this.port, this.model = '', this.image = '', this.needsLogin = false});

  final String host;
  final int port;

  /// "GigaBlue UHD Quad 4K" - empty when the box wants a login first.
  final String model;

  /// "teamBlue 7.4".
  final String image;

  /// OpenWebif asks for user and password (401).
  final bool needsLogin;
}

/// Looks for Enigma2 receivers (OpenWebif) in the home network, so the
/// address doesn't have to be typed in: every device in the device's own
/// networks (each taken as /24) that answers on port 80 is asked for
/// OpenWebif's /api/about.
class Enigma2Discovery {
  Enigma2Discovery({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;
  static const _port = 80;
  static const _streamPort = 8001;
  static const _connectTimeout = Duration(milliseconds: 700);
  static const _parallel = 64;
  static const _maxNetworks = 4;

  /// The private /24 networks of this device, e.g. "192.168.100" - the
  /// Wi-Fi/Ethernet ones first (virtual adapters like VMware's come later
  /// and are cut off after [_maxNetworks]).
  static Future<List<String>> localNetworks() async {
    final interfaces = await NetworkInterface.list(type: InternetAddressType.IPv4);
    interfaces.sort((a, b) => _virtual(a.name).compareTo(_virtual(b.name)));
    final networks = <String>{};
    for (final i in interfaces) {
      for (final a in i.addresses) {
        final p = a.address.split('.');
        if (p.length != 4 || a.isLoopback || a.isLinkLocal) continue;
        final first = int.tryParse(p[0]) ?? 0, second = int.tryParse(p[1]) ?? 0;
        final private = first == 10 || (first == 172 && second >= 16 && second <= 31) || (first == 192 && second == 168);
        if (private) networks.add('${p[0]}.${p[1]}.${p[2]}');
      }
    }
    return networks.take(_maxNetworks).toList();
  }

  static int _virtual(String name) =>
      RegExp('vmware|virtualbox|vbox|hyper-v|vethernet|docker|wsl|tap|tun', caseSensitive: false).hasMatch(name) ? 1 : 0;

  /// Scans [networks] (default: [localNetworks]); receivers as they are found.
  /// [onProgress] gets (addresses checked, addresses in total).
  Stream<FoundReceiver> scan({List<String>? networks, void Function(int done, int total)? onProgress}) async* {
    final nets = networks ?? await localNetworks();
    final hosts = [
      for (final n in nets)
        for (var i = 1; i < 255; i++) '$n.$i',
    ];
    final found = StreamController<FoundReceiver>();
    var next = 0, done = 0;
    Future<void> worker() async {
      while (next < hosts.length) {
        final host = hosts[next++];
        final receiver = await _check(host);
        if (receiver != null && !found.isClosed) found.add(receiver);
        onProgress?.call(++done, hosts.length);
      }
    }

    unawaited(Future.wait([for (var i = 0; i < _parallel; i++) worker()]).whenComplete(found.close));
    yield* found.stream;
  }

  Future<FoundReceiver?> _check(String host) async {
    if (!await _open(host, _port)) return null;
    try {
      final response = await _client.get(Uri.http('$host:$_port', '/api/about')).timeout(const Duration(seconds: 3));
      if (response.statusCode == 401) {
        // A login in front of everything - Enigma2 if it also streams.
        return await _open(host, _streamPort) ? FoundReceiver(host: host, port: _port, needsLogin: true) : null;
      }
      if (response.statusCode != 200) return null;
      final j = jsonDecode(utf8.decode(response.bodyBytes, allowMalformed: true));
      if (j is! Map) return null;
      final info = j['info'] is Map ? j['info'] as Map : j;
      final model = '${info['brand'] ?? ''} ${info['model'] ?? info['boxtype'] ?? ''}'.trim();
      final image = '${info['friendlyimagedistro'] ?? info['imagedistro'] ?? ''} ${info['imagever'] ?? ''}'.trim();
      // Some other web server that happens to answer /api/about.
      if (model.isEmpty && image.isEmpty && info['enigmaver'] == null) return null;
      return FoundReceiver(host: host, port: _port, model: model, image: image);
    } catch (_) {
      return null;
    }
  }

  static Future<bool> _open(String host, int port) async {
    try {
      final socket = await Socket.connect(host, port, timeout: _connectTimeout);
      socket.destroy();
      return true;
    } catch (_) {
      return false;
    }
  }

  void close() => _client.close();
}
