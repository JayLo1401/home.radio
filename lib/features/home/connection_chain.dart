import 'package:flutter/material.dart';

import '../../data/services/dab_rtlsdr_service.dart';

/// The three hops the receiver has to make before a DAB+/FM station plays:
/// reach the rtl_tcp server (only with a network source), get samples from
/// the stick, find the station on air.
enum LinkStage { server, stick, station }

enum LinkState { pending, active, done, retrying, failed }

/// What is known about the receiver's connection setup for the station
/// being tuned (see HomeScreen) - advanced only by the receiver's own
/// results and events, never by timers:
/// - server: [serverReady] = the TCP probe of setServer() succeeded,
/// - stick: [sourceUp] = the source delivers (rtl_tcp session up - the
///   server has the stick open - or any sign of received signal); with a
///   USB stick its opening (useDirectUsb()) counts,
/// - station: playService()/fmPlay() succeeded (DAB+: audio verified by the
///   receiver; FM: plus the first fmStatus measurement).
class ReceiverLink {
  /// Shown in the Now Playing banner.
  bool visible = false;
  bool viaServer = true;
  bool serverReady = false;
  bool sourceUp = false;

  bool _fm = false;
  int? _freqKhz;
  int? _serviceId;
  bool _tuned = false;
  bool _fmSignal = false;
  String? _detail;
  LinkStage? _errorStage;
  String? _error;
  bool _retrying = false;

  /// A new tune of [freqKhz] (DAB+ [serviceId], or FM) starts. A retry of
  /// the same station keeps its "trying again" error on screen meanwhile.
  void start({required bool viaServer, required bool fm, required int freqKhz, int? serviceId}) {
    final same = fm == _fm && freqKhz == _freqKhz && serviceId == _serviceId;
    // The source restarts for the other mode (one stick, one sample rate).
    if (fm != _fm) sourceUp = false;
    this.viaServer = viaServer;
    _fm = fm;
    _freqKhz = freqKhz;
    _serviceId = serviceId;
    _tuned = false;
    _fmSignal = false;
    if (!same || !_retrying) {
      _detail = null;
      _errorStage = null;
      _error = null;
      _retrying = false;
    }
    visible = true;
  }

  /// Nothing of the station's setup applies anymore (internet radio,
  /// stopped, another screen took the receiver).
  void reset() {
    visible = false;
    _freqKhz = null;
    _serviceId = null;
    _tuned = false;
    _fmSignal = false;
    _detail = null;
    _errorStage = null;
    _error = null;
    _retrying = false;
  }

  /// The source was stopped or closed - the next tune connects anew.
  void sourceDown() => sourceUp = false;

  void setServerReady(bool ready) {
    serverReady = ready;
    if (ready && (_errorStage == LinkStage.server || (!viaServer && _errorStage == LinkStage.stick))) {
      _clearError();
    }
  }

  /// The result of playService()/fmPlay().
  void tuned(bool ok) {
    _tuned = ok;
    if (ok) {
      // Audio from the station proves the whole chain.
      sourceUp = true;
      serverReady = true;
      _clearError();
    }
  }

  void fail(LinkStage stage, String message, {required bool retrying}) {
    _errorStage = stage;
    _error = message;
    _retrying = retrying;
    if (stage != LinkStage.station) sourceUp = false;
  }

  bool get hasError => _error != null;

  /// All green: the station plays.
  bool get complete => _tuned && (!_fm || _fmSignal) && _error == null;

  void _clearError() {
    _errorStage = null;
    _error = null;
    _retrying = false;
  }

  /// Feeds a receiver event (DabRtlSdrService.events); returns whether the
  /// shown chain changed.
  bool onEvent(Map<String, dynamic> event) {
    // Several events a second while playing - only compared while shown.
    final before = visible ? view : null;
    switch (event['type']) {
      case 'connectionMessage':
        final isError = event['isError'] as bool? ?? false;
        final message = (event['message'] as String?)?.trim() ?? '';
        if (isError) {
          final stage = _stageOf(message);
          fail(
            stage,
            message.isEmpty ? 'Verbindung zur RTL-SDR-Quelle verloren' : message,
            retrying: !_isFinal(message),
          );
        } else {
          // "Verbindung zur rtl_tcp-Quelle hergestellt" (sent on every
          // connect - the server has the stick open by then) or
          // "„Stick“ bereit".
          sourceUp = true;
          serverReady = true;
          if (_errorStage != LinkStage.station) _clearError();
        }
      case 'syncChange' when event['sync'] == true:
        _signSeen();
        _detail = 'DAB-Signal gefunden';
      case 'ensembleLabel':
        _signSeen();
        final label = (event['label'] as String?)?.trim() ?? '';
        if (label.isNotEmpty) _detail = 'Ensemble „$label“ gefunden';
      case 'serviceDetected' when !_fm && event['serviceId'] == _serviceId:
        _signSeen();
        _detail = 'Sender gefunden - Audio startet…';
      case 'snr' || 'audioFormat':
        _signSeen();
      case 'fmStatus' when _fm && event['freqKhz'] == _freqKhz:
        _signSeen();
        _fmSignal = true;
    }
    return before != null && visible && view != before;
  }

  /// Samples arrive and get demodulated: the stick (and the server in
  /// front of it) works.
  void _signSeen() {
    sourceUp = true;
    serverReady = true;
    if (_errorStage == LinkStage.server || _errorStage == LinkStage.stick) _clearError();
  }

  /// Which hop an rtl_tcp/USB source message is about.
  LinkStage _stageOf(String message) {
    if (!viaServer) return LinkStage.stick;
    const stickHints = ['nicht bereit', 'startet', 'verbinde neu', 'wird bereits', 'abgelehnt', 'Stick'];
    return stickHints.any(message.contains) ? LinkStage.stick : LinkStage.server;
  }

  /// Fatal rtl_tcp errors end the source's own reconnect loop (see
  /// RtlTcpSource::fail) - everything else it keeps retrying.
  bool _isFinal(String message) {
    if (!viaServer) return true;
    const finalHints = ['wird bereits', 'Anmeldung', 'Protokollfehler', 'Vom rtl_tcp-Server getrennt', 'rtl_tcp-Server: '];
    return finalHints.any(message.contains);
  }

  LinkState _stateOf(LinkStage stage, {required bool reachable, required bool done}) {
    if (_errorStage == stage) return _retrying ? LinkState.retrying : LinkState.failed;
    // Nothing behind a broken or unfinished hop counts as reached.
    if (!reachable) return LinkState.pending;
    return done ? LinkState.done : LinkState.active;
  }

  /// The chain as shown right now.
  LinkView get view {
    final server = viaServer
        ? _stateOf(LinkStage.server, reachable: true, done: serverReady || sourceUp)
        : LinkState.done;
    final stick = _stateOf(
      LinkStage.stick,
      reachable: server == LinkState.done,
      done: sourceUp || (!viaServer && serverReady),
    );
    final station = _stateOf(
      LinkStage.station,
      reachable: stick == LinkState.done,
      done: _tuned && (!_fm || _fmSignal),
    );
    final String message;
    if (_error case final error?) {
      message = error;
    } else if (station == LinkState.done) {
      message = 'Sender verbunden';
    } else if (server == LinkState.active) {
      message = 'Verbinde mit dem RTL-Server…';
    } else if (stick == LinkState.active) {
      message = viaServer ? 'Warte auf den Stick am Server…' : 'USB-Stick wird geöffnet…';
    } else {
      message = _detail ?? _tuningText();
    }
    return LinkView(
      viaServer: viaServer,
      server: server,
      stick: stick,
      station: station,
      message: message,
    );
  }

  String _tuningText() {
    final freqKhz = _freqKhz;
    if (freqKhz == null) return 'Sender wird eingestellt…';
    if (_fm) {
      final mhz = (freqKhz / 1000).toStringAsFixed(freqKhz % 100 == 0 ? 1 : 2).replaceAll('.', ',');
      return '$mhz MHz wird eingestellt…';
    }
    final channel = DabRtlSdrService.band3Channels.where((c) => c.$2 == freqKhz).firstOrNull?.$1;
    return channel == null ? 'Sender wird gesucht…' : 'Kanal $channel wird gesucht…';
  }
}

/// An immutable snapshot of [ReceiverLink] for [ConnectionChain].
@immutable
class LinkView {
  const LinkView({
    required this.viaServer,
    required this.server,
    required this.stick,
    required this.station,
    required this.message,
    this.internet = false,
  }) : tv = false;

  /// Internet radio: "App — Internet — Sender", [server] standing for the
  /// connection to the stream (no stick).
  const LinkView.internet({required LinkState connection, required this.station, required this.message})
    : viaServer = false,
      server = connection,
      stick = LinkState.done,
      internet = true,
      tv = false;

  /// Home TV: "App — Receiver — Sender", [server] standing for the Sat
  /// receiver (reached, switched to an encrypted channel), [station] for
  /// the picture.
  const LinkView.tv({required LinkState receiver, required this.station, required this.message})
    : viaServer = false,
      server = receiver,
      stick = LinkState.done,
      internet = false,
      tv = true;

  final bool internet;
  final bool tv;
  final bool viaServer;
  final LinkState server;
  final LinkState stick;
  final LinkState station;
  final String message;

  bool get animating => [server, stick, station].any((s) => s == LinkState.active || s == LinkState.retrying);

  @override
  bool operator ==(Object other) =>
      other is LinkView &&
      other.internet == internet &&
      other.tv == tv &&
      other.viaServer == viaServer &&
      other.server == server &&
      other.stick == stick &&
      other.station == station &&
      other.message == message;

  @override
  int get hashCode => Object.hash(internet, tv, viaServer, server, stick, station, message);
}

/// "App — RTL-Server — Stick — Sender" in the Now Playing banner while the
/// receiver connects: the hop in progress flows (blue, orange while
/// retrying), finished hops turn green, a failed one red - followed by what
/// is happening or went wrong. One AnimationController, running only while
/// something is in progress; only the moving segments repaint per frame.
class ConnectionChain extends StatefulWidget {
  const ConnectionChain({super.key, required this.view});

  final LinkView view;

  @override
  State<ConnectionChain> createState() => _ConnectionChainState();
}

class _ConnectionChainState extends State<ConnectionChain> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  );

  // Node pulse 0.45 → 1 → 0.45 per cycle.
  late final Animation<double> _pulse = _controller.drive(
    TweenSequence([
      TweenSequenceItem(tween: Tween(begin: 0.45, end: 1.0), weight: 1),
      TweenSequenceItem(tween: Tween(begin: 1.0, end: 0.45), weight: 1),
    ]),
  );

  @override
  void initState() {
    super.initState();
    _syncController();
  }

  @override
  void didUpdateWidget(ConnectionChain oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncController();
  }

  void _syncController() {
    if (widget.view.animating) {
      if (!_controller.isAnimating) _controller.repeat();
    } else if (_controller.isAnimating) {
      _controller.stop();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  static Color _colorOf(LinkState state) => switch (state) {
        LinkState.pending => Colors.white38,
        LinkState.active => Colors.lightBlueAccent,
        LinkState.done => Colors.greenAccent,
        LinkState.retrying => Colors.orangeAccent,
        LinkState.failed => Colors.redAccent,
      };

  static const _iconSize = 26.0;

  /// The symbol, its name small and faint underneath.
  Widget _node(IconData icon, String label, LinkState state) {
    final color = _colorOf(state);
    Widget symbol = Icon(icon, size: _iconSize, color: color);
    if (state == LinkState.active || state == LinkState.retrying) {
      symbol = FadeTransition(opacity: _pulse, child: symbol);
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        symbol,
        const SizedBox(height: 2),
        Text(label, style: TextStyle(color: color.withValues(alpha: 0.6), fontSize: 12)),
      ],
    );
  }

  /// A link at the height of the symbols (not of their names).
  Widget _segment(LinkState state) {
    final moving = state == LinkState.active || state == LinkState.retrying;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: CustomPaint(
        size: const Size(44, _iconSize),
        painter: _SegmentPainter(
          color: _colorOf(state),
          state: state,
          progress: moving ? _controller : null,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final view = widget.view;
    final messageColor = switch ([view.server, view.stick, view.station]) {
      final s when s.contains(LinkState.failed) => Colors.redAccent,
      final s when s.contains(LinkState.retrying) => Colors.orangeAccent,
      _ => Colors.white70,
    };
    // Symbols on top with their names faint underneath; the links sit at
    // the symbols' height, what's happening follows on the right. With a USB
    // stick there's no server: App — Stick — Sender.
    return RepaintBoundary(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _node(Icons.tv, 'App', LinkState.done),
          if (view.internet) ...[
            // Internet radio: the stream comes over the internet.
            _segment(view.server),
            _node(Icons.public, 'Internet', view.server),
          ] else if (view.tv) ...[
            // Home TV: the picture comes from the Sat receiver.
            _segment(view.server),
            _node(Icons.settings_input_antenna, 'Receiver', view.server),
          ] else ...[
            if (view.viaServer) ...[
              _segment(view.server),
              _node(Icons.dns_outlined, 'RTL-Server', view.server),
            ],
            _segment(view.stick),
            _node(Icons.usb, view.viaServer ? 'Stick' : 'USB-Stick', view.stick),
          ],
          _segment(view.station),
          _node(view.tv ? Icons.live_tv : (view.internet ? Icons.radio : Icons.cell_tower), 'Sender', view.station),
          const SizedBox(width: 18),
          Expanded(
            child: SizedBox(
              height: _iconSize,
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  view.message,
                  style: TextStyle(color: messageColor, fontSize: 18),
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// One link between two nodes: dotted (pending), flowing dashes (in
/// progress - repainted by [progress] alone, no widget rebuilds), solid
/// (done) or dashed with a cross (failed).
class _SegmentPainter extends CustomPainter {
  _SegmentPainter({required this.color, required this.state, this.progress}) : super(repaint: progress);

  final Color color;
  final LinkState state;
  final Animation<double>? progress;

  @override
  void paint(Canvas canvas, Size size) {
    final y = size.height / 2;
    final paint = Paint()
      ..color = color
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;
    switch (state) {
      case LinkState.done:
        canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
      case LinkState.pending:
        for (var x = 2.0; x < size.width; x += 8) {
          canvas.drawCircle(Offset(x, y), 1.6, paint);
        }
      case LinkState.failed:
        for (var x = 0.0; x < size.width; x += 10) {
          canvas.drawLine(Offset(x, y), Offset((x + 5).clamp(0, size.width), y), paint);
        }
        final c = Offset(size.width / 2, y);
        canvas.drawLine(c + const Offset(-5, -5), c + const Offset(5, 5), paint);
        canvas.drawLine(c + const Offset(-5, 5), c + const Offset(5, -5), paint);
      case LinkState.active || LinkState.retrying:
        // Faint track, dashes flowing towards the next node, and a bright
        // head travelling along it.
        canvas.drawLine(Offset(0, y), Offset(size.width, y), Paint()
          ..color = color.withValues(alpha: 0.18)
          ..strokeWidth = 3
          ..strokeCap = StrokeCap.round);
        const period = 11.0;
        final t = progress?.value ?? 0;
        canvas.save();
        canvas.clipRect(Offset.zero & size);
        for (var x = -period + t * period * 2 % period; x < size.width; x += period) {
          canvas.drawLine(Offset(x, y), Offset(x + 5, y), paint);
        }
        canvas.restore();
        canvas.drawCircle(Offset(t * size.width, y), 3.5, Paint()..color = Colors.white.withValues(alpha: 0.9));
    }
  }

  @override
  bool shouldRepaint(covariant _SegmentPainter old) => old.color != color || old.state != state || old.progress != progress;
}
