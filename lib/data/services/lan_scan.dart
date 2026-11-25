import 'dart:async';
import 'dart:io';

/// Looking for devices in the home network without knowing their address:
/// every address of the device's own networks (each taken as /24) is
/// checked by a function that says what answers there. Used by the
/// searches for the receiver, Home Assistant and rtl_tcp servers.
abstract final class LanScan {
  static const _parallel = 64;
  static const _maxNetworks = 4;
  static const connectTimeout = Duration(milliseconds: 700);

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

  /// Asks [check] about every address of [networks] (default:
  /// [localNetworks]), [_parallel] at a time; what it finds comes as it is
  /// found. [onProgress] gets (addresses checked, addresses in total).
  static Stream<T> scan<T>(
    Future<T?> Function(String host) check, {
    List<String>? networks,
    void Function(int done, int total)? onProgress,
  }) async* {
    final nets = networks ?? await localNetworks();
    // This device itself once only - with several network adapters (a PC)
    // it would show up once per adapter.
    final own = await _ownAddresses();
    var ownSeen = false;
    final hosts = <String>[
      for (final n in nets)
        for (var i = 1; i < 255; i++)
          if (!own.contains('$n.$i') || !ownSeen && (ownSeen = true)) '$n.$i',
    ];
    final found = StreamController<T>();
    var next = 0, done = 0;
    Future<void> worker() async {
      while (next < hosts.length && !found.isClosed) {
        final host = hosts[next++];
        T? result;
        try {
          result = await check(host);
        } catch (_) {}
        if (result != null && !found.isClosed) found.add(result);
        onProgress?.call(++done, hosts.length);
      }
    }

    unawaited(Future.wait([for (var i = 0; i < _parallel; i++) worker()]).whenComplete(() {
      if (!found.isClosed) found.close();
    }));
    try {
      yield* found.stream;
    } finally {
      // Cancelled (dialog closed): the workers stop after their address.
      if (!found.isClosed) await found.close();
    }
  }

  static Future<Set<String>> _ownAddresses() async {
    try {
      final interfaces = await NetworkInterface.list(type: InternetAddressType.IPv4);
      return {
        for (final i in interfaces)
          for (final a in i.addresses) a.address,
      };
    } catch (_) {
      return const {};
    }
  }

  /// Something listens on [host]:[port].
  static Future<bool> isOpen(String host, int port, {Duration timeout = connectTimeout}) async {
    try {
      final socket = await Socket.connect(host, port, timeout: timeout);
      socket.destroy();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// The name the network's DNS has for [ip] ("homeassistant.fritz.box"),
  /// or null.
  static Future<String?> nameOf(String ip) async {
    try {
      final host = (await InternetAddress(ip).reverse().timeout(const Duration(seconds: 2))).host;
      return host == ip || host.toLowerCase() == 'localhost' ? null : host;
    } catch (_) {
      return null;
    }
  }
}
