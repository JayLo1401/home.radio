import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/popup_text_field.dart';
import '../../core/providers.dart';
import '../../data/repositories/settings_repository.dart' show ReceiverMode, RtlTcpServer, RtlTcpServers;
import '../../data/services/rtl_sdr_service.dart';
import '../../data/services/rtl_sdr_usb_service.dart';

/// "Radio-Empfänger": whether and how DAB+ and FM reach the RTL-SDR receiver
/// (see [ReceiverMode]) - "Kein Empfänger" for internet radio only.
///
/// rtl_tcp: any number of servers, one row each (host, port, "Testen", and
/// what the test found: location and antenna of the stick with rtl_tcp Jay
/// extended). The radio button marks the default server - the one the
/// receiver uses.
class RtlSdrTestScreen extends ConsumerStatefulWidget {
  const RtlSdrTestScreen({super.key});

  @override
  ConsumerState<RtlSdrTestScreen> createState() => _RtlSdrTestScreenState();
}

/// One server row: its text fields and the last test result.
class _ServerRow {
  _ServerRow(RtlTcpServer server)
      : host = TextEditingController(text: server.host),
        port = TextEditingController(text: '${server.port}');

  final TextEditingController host;
  final TextEditingController port;
  RtlConnectResult? result;

  RtlTcpServer get server => RtlTcpServer(
        host: host.text.trim().isEmpty ? '127.0.0.1' : host.text.trim(),
        port: int.tryParse(port.text.trim()) ?? 1234,
      );

  void dispose() {
    host.dispose();
    port.dispose();
  }
}

class _RtlSdrTestScreenState extends ConsumerState<RtlSdrTestScreen> {
  static const _hint = TextStyle(color: Colors.white70, fontSize: 13);

  final _rows = <_ServerRow>[];
  int _defaultIndex = 0;
  _ServerRow? _testing;

  late ReceiverMode _mode = ref.read(receiverModeProvider);
  List<RtlSdrUsbDevice> _usbDevices = [];
  bool _usbBusy = false;

  @override
  void initState() {
    super.initState();
    _loadPersisted();
    _refreshUsbDevices();
  }

  Future<void> _loadPersisted() async {
    final settings = ref.read(settingsRepositoryProvider);
    final servers = await settings.getRtlTcpServers();
    final mode = await settings.getReceiverMode();
    if (!mounted) return;
    setState(() {
      for (final row in _rows) {
        row.dispose();
      }
      _rows
        ..clear()
        ..addAll(servers.servers.map(_ServerRow.new));
      _defaultIndex = servers.defaultIndex;
      _receiverServer = servers.defaultServer;
      _mode = mode;
    });
  }

  @override
  void dispose() {
    // rtl_tcp serves one client at a time - a test still running when the
    // screen closes must not keep the server from the receiver.
    if (_testing != null) _service.disconnect();
    for (final row in _rows) {
      row.dispose();
    }
    super.dispose();
  }

  RtlSdrService get _service => ref.read(rtlSdrServiceProvider);
  RtlSdrUsbService get _usbService => ref.read(rtlSdrUsbServiceProvider);

  Future<void> _refreshUsbDevices() async {
    final devices = await _usbService.listDevices();
    if (!mounted) return;
    setState(() => _usbDevices = devices);
  }

  Future<void> _requestUsbPermission(RtlSdrUsbDevice device) async {
    setState(() => _usbBusy = true);
    await _usbService.requestPermission(device.deviceName);
    await _refreshUsbDevices();
    if (mounted) setState(() => _usbBusy = false);
  }

  Future<void> _selectMode(ReceiverMode mode) async {
    setState(() => _mode = mode);
    await ref.read(receiverModeProvider.notifier).set(mode);
    if (mode == ReceiverMode.usb) _refreshUsbDevices();
  }

  /// Saved on every change - the receiver connects to the default server
  /// the next time it starts.
  Future<void> _save() async {
    final servers = RtlTcpServers([for (final r in _rows) r.server], _defaultIndex);
    await ref.read(settingsRepositoryProvider).setRtlTcpServers(servers);
    // A new default server: the home screen points the receiver at it and
    // tunes the current station in again once back.
    if (_receiverServer != null && servers.defaultServer != _receiverServer) {
      _receiverServer = servers.defaultServer;
      ref.read(receiverInterruptedProvider.notifier).set(true);
    }
  }

  /// The server the receiver (DAB+/FM) was pointed at when this screen
  /// opened, or since changed to here.
  RtlTcpServer? _receiverServer;

  void _setDefault(int index) {
    setState(() => _defaultIndex = index);
    _save();
  }

  void _add() {
    setState(() => _rows.add(_ServerRow(const RtlTcpServer(host: '', port: 1234))));
  }

  void _remove(int index) {
    setState(() {
      _rows.removeAt(index).dispose();
      if (_defaultIndex == index) {
        _defaultIndex = 0;
      } else if (_defaultIndex > index) {
        _defaultIndex--;
      }
    });
    _save();
  }

  void _edited(_ServerRow row) {
    setState(() => row.result = null);
    _save();
  }

  /// Asks the server what is behind the port (see RtlSdrService.inspect).
  /// The receiver's own server is freed first - a playing DAB+/FM station
  /// would hold the stick; the home screen tunes it in again once back.
  Future<void> _test(_ServerRow row) async {
    final server = row.server;
    final receiverServer = _receiverServer;
    setState(() {
      _testing = row;
      row.result = null;
    });
    await _save();
    if (_mode == ReceiverMode.tcp && server == receiverServer) {
      ref.read(receiverInterruptedProvider.notifier).set(true);
      await ref.read(dabRtlSdrServiceProvider).resetSession();
      // Give the server a moment to notice the closed connection.
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    final result = await _service.inspect(host: server.host, port: server.port);
    if (!mounted) return;
    setState(() {
      _testing = null;
      row.result = result;
    });
  }

  /// All sticks of the server (rtltcp.server ≥ 1.8); picking one takes over
  /// its port.
  Future<void> _chooseStick(_ServerRow row) async {
    final sticks = row.result?.devices ?? const <RtlStick>[];
    final current = row.server.port;
    final port = await showDialog<int>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text('Sticks auf ${row.server.host}'),
        children: [
          for (final s in sticks)
            if (s.port != null)
              SimpleDialogOption(
                onPressed: () => Navigator.pop(context, s.port),
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(s.port == current ? Icons.radio_button_checked : Icons.radio_button_unchecked),
                  title: Text('${s.name ?? 'Stick'} · Port ${s.port}'),
                  subtitle: Text(_stickDetails(s)),
                ),
              ),
        ],
      ),
    );
    if (port == null || port == current || !mounted) return;
    row.port.text = '$port';
    await _test(row);
  }

  /// "Standort: … · Antenne: … · über … · belegt von …" for one stick.
  static String _stickDetails(RtlStick s, {bool withName = false}) => [
        if (withName && s.name != null) '„${s.name}“',
        'Standort: ${s.location ?? 'nicht angegeben'}',
        'Antenne: ${s.antenna ?? 'nicht angegeben'}',
        if (s.isRemote && s.remoteInstance != null) 'über ${s.remoteInstance}',
        if (s.busyBy != null) 'belegt von ${s.busyBy}' else if (s.stateText != null) s.stateText!,
      ].join(' · ');

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Radio-Empfänger (DAB+ & UKW)')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Text('Empfänger:'),
                const SizedBox(width: 12),
                DropdownButton<ReceiverMode>(
                  value: _mode,
                  items: const [
                    DropdownMenuItem(value: ReceiverMode.none, child: Text('Kein Empfänger (nur Internetradio)')),
                    DropdownMenuItem(value: ReceiverMode.usb, child: Text('RTL-SDR-Stick per USB')),
                    DropdownMenuItem(value: ReceiverMode.tcp, child: Text('RTL-SDR über Netzwerk (rtl_tcp)')),
                  ],
                  onChanged: _testing != null ? null : (m) => m == null ? null : _selectMode(m),
                ),
              ],
            ),
            const SizedBox(height: 8),
            ...switch (_mode) {
              ReceiverMode.none => [
                  const Text(
                    'DAB+- und UKW-Suche sowie die Reiter „DAB+“ und „FM“ sind ausgeblendet. '
                    'Vorhandene Favoriten bleiben erhalten und spielen wieder, sobald ein Empfänger eingerichtet ist.',
                    style: _hint,
                  ),
                ],
              ReceiverMode.usb => _usbSection(),
              ReceiverMode.tcp => _tcpSection(),
            },
          ],
        ),
      ),
    );
  }

  List<Widget> _usbSection() => [
        Text(
          [
            'Der Empfänger öffnet den Stick direkt über USB, sobald ein Sender startet.',
            if (Platform.isWindows)
              'Windows: einmalig den WinUSB-Treiber mit Zadig (zadig.akeo.ie) für '
                  '„Bulk-In, Interface (Interface 0)“ installieren.',
            if (Platform.isLinux)
              'Linux: braucht eine udev-Regel für den Stick (z. B. aus dem Paket rtl-sdr); '
                  'der DVB-T-Treiber des Kernels wird automatisch abgekoppelt.',
          ].join(' '),
          style: _hint,
        ),
        const SizedBox(height: 8),
        if (_usbDevices.isEmpty)
          const Text('Kein RTL-SDR-Stick erkannt.', style: TextStyle(color: Colors.orangeAccent)),
        for (final device in _usbDevices)
          Row(
            children: [
              Expanded(child: Text(device.label)),
              if (!device.hasPermission)
                ElevatedButton(
                  onPressed: _usbBusy ? null : () => _requestUsbPermission(device),
                  child: const Text('Zugriff erlauben'),
                )
              else
                const Text('Zugriff erteilt', style: TextStyle(color: Colors.greenAccent)),
            ],
          ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: _refreshUsbDevices,
            icon: const Icon(Icons.refresh),
            label: const Text('Neu suchen'),
          ),
        ),
      ];

  List<Widget> _tcpSection() => [
        const Text(
          'rtl_tcp-Server im lokalen Netz: Treiber-App auf diesem Gerät (127.0.0.1), Raspberry Pi oder '
          'rtltcp.server. Der markierte Server ist der Standard für DAB+ und UKW. Sticks an anderen '
          'Standorten stellt der rtltcp.server über rtl.over.internet lokal bereit.',
          style: _hint,
        ),
        const SizedBox(height: 8),
        RadioGroup<int>(
          groupValue: _defaultIndex,
          onChanged: (i) => i == null ? null : _setDefault(i),
          child: Column(
            children: [
              for (var i = 0; i < _rows.length; i++) _serverRow(i, _rows[i]),
            ],
          ),
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: _testing != null ? null : _add,
            icon: const Icon(Icons.add),
            label: const Text('Server hinzufügen'),
          ),
        ),
        const Text(
          '„Testen“ unterbricht DAB+ oder UKW, wenn es über diesen Server läuft; der Sender spielt beim '
          'Zurückkehren weiter.',
          style: TextStyle(color: Colors.white54, fontSize: 12),
        ),
      ];

  Widget _serverRow(int index, _ServerRow row) {
    final testing = _testing == row;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Tooltip(
            message: 'Standard',
            child: Radio<int>(value: index),
          ),
          SizedBox(
            width: 200,
            child: PopupTextField(
              controller: row.host,
              enabled: _testing == null,
              label: 'Host (IP)',
              onSubmitted: (_) => _edited(row),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 130,
            child: PopupTextField(
              controller: row.port,
              enabled: _testing == null,
              keyboardType: TextInputType.number,
              label: 'Port',
              onSubmitted: (_) => _edited(row),
            ),
          ),
          const SizedBox(width: 8),
          OutlinedButton(
            onPressed: _testing != null ? null : () => _test(row),
            child: testing
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('Testen'),
          ),
          const SizedBox(width: 12),
          Expanded(child: _resultText(row.result)),
          if ((row.result?.devices?.length ?? 0) > 1)
            TextButton(
              onPressed: _testing != null ? null : () => _chooseStick(row),
              child: Text('Stick wählen (${row.result!.devices!.length})'),
            ),
          IconButton(
            tooltip: 'Entfernen',
            onPressed: _rows.length > 1 && _testing == null ? () => _remove(index) : null,
            icon: const Icon(Icons.delete_outline),
          ),
        ],
      ),
    );
  }

  /// Location and antenna (rtl_tcp Jay extended), "not supported" for a
  /// classic server, or the error. Details in the tooltip.
  Widget _resultText(RtlConnectResult? r) {
    if (r == null) return const SizedBox.shrink();
    final String text;
    final Color color;
    if (!r.connected) {
      text = r.error ?? 'Keine Verbindung';
      color = Colors.redAccent;
    } else if (r.protocol != RtlTcpProtocol.jayExtended) {
      text = 'rtl_tcp – Server unterstützt Standort und Antenne nicht';
      color = Colors.white70;
    } else {
      // The `devices` entry of this port carries state and busy_by too.
      final port = r.device?.port;
      final stick = r.devices?.where((s) => port != null && s.port == port).firstOrNull ??
          r.device ??
          const RtlStick();
      text = _stickDetails(stick, withName: true);
      final trouble = stick.busyBy != null || (stick.stateText != null && stick.state != 'idle');
      color = trouble ? Colors.orangeAccent : Colors.greenAccent;
    }
    final details = [
      if (r.protocol != null) 'Protokoll: ${r.protocol!.label}',
      if (r.server?.isNotEmpty ?? false) 'Server: ${r.server}',
      if (r.tunerType != null) 'Tuner-Typ: ${r.tunerType}, ${r.tunerGainCount ?? '?'} Gain-Stufen',
    ];
    final label = Text(text, style: TextStyle(color: color), maxLines: 2, overflow: TextOverflow.ellipsis);
    return details.isEmpty ? label : Tooltip(message: details.join('\n'), child: label);
  }
}
