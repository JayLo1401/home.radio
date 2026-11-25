import 'dart:async';

import 'lan_scan.dart';
import 'rtl_sdr_service.dart';

/// An rtl_tcp server found in the home network - with rtltcp.server, one
/// entry per stick (its own port, location and antenna).
class FoundRtlTcp {
  const FoundRtlTcp({required this.host, required this.port, this.name, this.protocol, this.stick});

  final String host;
  final int port;

  /// What the network's DNS calls the machine ("raspberrypi.fritz.box").
  final String? name;
  final RtlTcpProtocol? protocol;

  /// rtltcp.server: the stick on [port].
  final RtlStick? stick;
}

/// The default rtl_tcp port - rtltcp.server's first stick too (it names the
/// others' ports itself).
const rtlTcpDefaultPort = 1234;

/// What runs on [host]: nothing, a classic rtl_tcp, or rtltcp.server with
/// its sticks.
Future<List<FoundRtlTcp>?> checkRtlTcp(String host, {int port = rtlTcpDefaultPort}) async {
  if (!await LanScan.isOpen(host, port)) return null;
  final result = await RtlSdrService.probe(host, port);
  if (!result.connected) return null;
  final name = await LanScan.nameOf(host);
  final sticks = [
    for (final s in result.devices ?? const <RtlStick>[])
      if (s.port != null) FoundRtlTcp(host: host, port: s.port!, name: name, protocol: result.protocol, stick: s),
  ];
  if (sticks.isNotEmpty) return sticks;
  return [FoundRtlTcp(host: host, port: port, name: name, protocol: result.protocol, stick: result.device)];
}

/// Looks for rtl_tcp servers (port 1234) in the home network; every stick
/// as it is found.
Stream<FoundRtlTcp> findRtlTcp({void Function(int done, int total)? onProgress}) =>
    LanScan.scan(checkRtlTcp, onProgress: onProgress).expand((sticks) => sticks);
