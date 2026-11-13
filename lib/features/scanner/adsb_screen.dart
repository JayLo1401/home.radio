import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../core/theme.dart' show brandGreen, TvFocusHighlight;
import '../../data/models/adsb.dart';
import '../../data/repositories/settings_repository.dart';
import '../../data/services/dab_rtlsdr_service.dart' show DabRtlSdrService;
import '../shared/logo_picker_dialog.dart' show connectDecoder;
import 'map_tiles.dart';
import 'reception_status.dart';

/// Aircraft overhead via ADS-B (1090 MHz): a radar picture around the home
/// location and a list with flight, altitude, speed and distance. The
/// receiver checks every frame's CRC; the decoding happens in
/// AircraftTracker.
class AdsbScreen extends ConsumerStatefulWidget {
  const AdsbScreen({super.key});

  @override
  ConsumerState<AdsbScreen> createState() => _AdsbScreenState();
}

class _AdsbScreenState extends ConsumerState<AdsbScreen> {
  late final DabRtlSdrService _rx;
  late final SettingsRepository _settings;
  StreamSubscription<Map<String, dynamic>>? _sub;
  Timer? _tick;

  AircraftTracker? _tracker;
  bool _started = false;
  bool _failed = false;
  String? _sourceWarning;

  int _gainIndex = -1;
  double? _gainDb;

  // Messages per second, from the counter's growth between ticks.
  int _lastCount = 0;
  double _rate = 0;

  /// The aircraft focused in the list - highlighted on the radar.
  int? _selected;

  // Reception indicator (see ReceptionStatus).
  RxStatus? _status;
  DateTime? _lastFrame;

  /// Map under the radar (see MapTiles), on/off remembered.
  bool _showMap = false;
  late final MapTiles _tiles = MapTiles(onLoaded: () {
    if (mounted) setState(() {});
  });

  static const _gainKey = 'adsb';

  @override
  void initState() {
    super.initState();
    _rx = ref.read(dabRtlSdrServiceProvider);
    _settings = ref.read(settingsRepositoryProvider);
    _sub = _rx.events.listen(_onEvent);
    _start();
  }

  @override
  void dispose() {
    _tick?.cancel();
    _sub?.cancel();
    _tiles.dispose();
    _rx.adsbStop();
    super.dispose();
  }

  Future<void> _start() async {
    final lat = await _settings.getWeatherLat();
    final lon = await _settings.getWeatherLon();
    _gainIndex = await _settings.getNbGain(_gainKey);
    _showMap = await _settings.getAdsbMap();
    _tracker = AircraftTracker(homeLat: lat, homeLon: lon);
    // The home screen tunes its station in again once back.
    ref.read(receiverInterruptedProvider.notifier).set(true);
    if (!await connectDecoder(ref)) {
      if (mounted) setState(() => _failed = true);
      return;
    }
    final ok = await _rx.adsbStart();
    if (ok) _gainDb = await _rx.nbSetGain(_gainIndex);
    if (!mounted) return;
    setState(() {
      _started = ok;
      _failed = !ok;
    });
    // The list is redrawn once a second, not for every frame.
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      final t = _tracker;
      if (t == null || !mounted) return;
      t.prune();
      setState(() {
        _rate = (t.messageCount - _lastCount).toDouble();
        _lastCount = t.messageCount;
      });
    });
  }

  void _onEvent(Map<String, dynamic> event) {
    switch (event['type']) {
      case 'rxStatus':
        if (!mounted) return;
        setState(() {
          _status = RxStatus.fromEvent(event);
          if (_gainIndex < 0) _gainDb = _status!.gainDb;
        });
      case 'adsbFrame':
        final bytes = adsbFrameFromEvent(event);
        if (bytes == null) return;
        _lastFrame = DateTime.now();
        _tracker?.update(bytes, event['icao'] as int, (event['signalDb'] as num?)?.toDouble() ?? -99);
      case 'connectionMessage':
        final isError = event['isError'] as bool? ?? false;
        final message = (event['message'] as String?)?.trim() ?? '';
        if (mounted) setState(() => _sourceWarning = isError && message.isNotEmpty ? message : null);
    }
  }

  Future<void> _stepGain(int delta) async {
    final next = (_gainIndex + delta).clamp(-1, DabRtlSdrService.nbGainSteps - 1);
    if (next == _gainIndex) return;
    setState(() => _gainIndex = next);
    await _settings.setNbGain(_gainKey, next);
    final db = await _rx.nbSetGain(next);
    if (mounted) setState(() => _gainDb = db);
  }

  /// With position first, nearest first; then the rest by last heard.
  List<Aircraft> get _sorted {
    final t = _tracker;
    if (t == null) return const [];
    final list = t.aircraft.values.toList();
    list.sort((a, b) {
      final da = a.distanceKm(t.homeLat, t.homeLon), db = b.distanceKm(t.homeLat, t.homeLon);
      if (da != null && db != null) return da.compareTo(db);
      if (da != null) return -1;
      if (db != null) return 1;
      return b.lastSeen.compareTo(a.lastSeen);
    });
    return list;
  }

  @override
  Widget build(BuildContext context) {
    final t = _tracker;
    final list = _sorted;
    final withPos = list.where((a) => a.hasPosition).length;
    const muted = TextStyle(color: Colors.white70);
    String db(double v) => v.toStringAsFixed(1).replaceAll('.', ',');
    return Scaffold(
      appBar: AppBar(title: const Text('Flugzeuge (ADS-B 1090 MHz)')),
      body: _failed
          ? const Center(child: Text('Empfänger konnte nicht gestartet werden.'))
          : Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (_sourceWarning case final warning?)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(warning, style: const TextStyle(color: Colors.orangeAccent, fontSize: 16)),
                    ),
                  Wrap(
                    spacing: 16,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(
                        _started ? '${list.length} Flugzeuge · $withPos mit Position' : 'Starte Empfänger…',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      Text('${_rate.round()} Meldungen/s', style: muted),
                      const SizedBox(width: 8),
                      const Text('Verstärkung', style: muted),
                      IconButton(
                        autofocus: true,
                        onPressed: () => _stepGain(-1),
                        icon: const Icon(Icons.remove),
                      ),
                      Text(
                        _gainIndex < 0
                            ? 'Auto${_gainDb == null ? '' : ' (${db(_gainDb!)} dB)'}'
                            : '${db(_gainDb ?? 0)} dB',
                      ),
                      IconButton(onPressed: () => _stepGain(1), icon: const Icon(Icons.add)),
                      FilterChip(
                        label: const Text('Karte'),
                        selected: _showMap,
                        onSelected: (v) {
                          setState(() => _showMap = v);
                          _settings.setAdsbMap(v);
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  ReceptionStatus(status: _status, expectedRate: 2000000, lastSignal: _lastFrame),
                  const SizedBox(height: 12),
                  Expanded(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        // Radar: home in the middle, north up.
                        AspectRatio(
                          aspectRatio: 1,
                          child: t == null
                              ? const SizedBox()
                              : CustomPaint(
                                  painter: _RadarPainter(
                                    aircraft: list,
                                    homeLat: t.homeLat,
                                    homeLon: t.homeLon,
                                    selected: _selected,
                                    tiles: _showMap ? _tiles : null,
                                  ),
                                ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: list.isEmpty
                              ? Center(
                                  child: Text(
                                    _started
                                        ? 'Noch kein Flugzeug empfangen.\nAntenne: senkrecht, ~6,9 cm (Viertelwelle 1090 MHz), '
                                              'möglichst am Fenster.'
                                        : '',
                                    textAlign: TextAlign.center,
                                    style: const TextStyle(color: Colors.white54, fontSize: 16),
                                  ),
                                )
                              : ListView(
                                  children: [
                                    const _AircraftHeader(),
                                    for (final a in list)
                                      _AircraftTile(
                                        aircraft: a,
                                        homeLat: t!.homeLat,
                                        homeLon: t.homeLon,
                                        onFocus: (focused) {
                                          if (focused) setState(() => _selected = a.icao);
                                        },
                                      ),
                                  ],
                                ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
    );
  }
}

String _fmtAlt(Aircraft a) {
  if (a.onGround) return 'am Boden';
  final ft = a.altitudeFt;
  if (ft == null) return '';
  return '${_thousands(a.altitudeM!)} m (FL${(ft / 100).round().toString().padLeft(3, '0')})';
}

String _thousands(int v) {
  final s = v.abs().toString();
  final b = StringBuffer(v < 0 ? '-' : '');
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write('.');
    b.write(s[i]);
  }
  return b.toString();
}

// Column widths, shared by the header and the rows.
const _wFlight = 120.0, _wAlt = 190.0, _wSpeed = 100.0, _wClimb = 80.0, _wDist = 90.0;

/// Column titles above the aircraft list.
class _AircraftHeader extends StatelessWidget {
  const _AircraftHeader();

  @override
  Widget build(BuildContext context) {
    const s = TextStyle(color: Colors.white54, fontSize: 13, fontWeight: FontWeight.w600);
    // Same insets as a row: focus frame (3) + card padding (12).
    return const Padding(
      padding: EdgeInsets.fromLTRB(15, 0, 15, 6),
      child: Row(
        children: [
          SizedBox(width: _wFlight, child: Text('Flug / ICAO', style: s)),
          SizedBox(width: _wAlt, child: Text('Höhe', style: s)),
          SizedBox(width: _wSpeed, child: Text('Tempo', style: s)),
          SizedBox(width: _wClimb, child: Text('Steig/Sink', style: s)),
          SizedBox(width: _wDist, child: Text('Entfernung', style: s)),
          Expanded(child: Text('Zulassung', style: s)),
          Text('Zuletzt', style: s),
        ],
      ),
    );
  }
}

/// One aircraft in the list - focusable with the remote (it's then marked
/// on the radar), OK shows all details.
class _AircraftTile extends StatefulWidget {
  final Aircraft aircraft;
  final double homeLat;
  final double homeLon;
  final ValueChanged<bool> onFocus;

  const _AircraftTile({required this.aircraft, required this.homeLat, required this.homeLon, required this.onFocus});

  @override
  State<_AircraftTile> createState() => _AircraftTileState();
}

class _AircraftTileState extends State<_AircraftTile> {
  bool _focused = false;

  void _details() {
    final a = widget.aircraft;
    final km = a.distanceKm(widget.homeLat, widget.homeLon);
    String n(double v, int d) => v.toStringAsFixed(d).replaceAll('.', ',');
    showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(a.callsign ?? a.icaoHex),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('ICAO-Adresse: ${a.icaoHex}${a.country != null ? ' (${a.country})' : ''}'),
            if (a.squawk != null) Text('Squawk: ${a.squawk}'),
            if (_fmtAlt(a).isNotEmpty) Text('Höhe: ${_fmtAlt(a)}'),
            if (a.speedKmh != null) Text('Geschwindigkeit: ${a.speedKmh} km/h (${a.speedKt!.round()} kn)'),
            if (a.track != null) Text('Kurs: ${a.track!.round()}°'),
            if (a.verticalRateFpm != null)
              Text('Steigen/Sinken: ${n(a.verticalRateFpm! * 0.00508, 1)} m/s (${a.verticalRateFpm} ft/min)'),
            if (a.hasPosition) Text('Position: ${n(a.lat!, 4)}° N, ${n(a.lon!, 4)}° O'),
            if (km != null)
              Text('Entfernung: ${n(km, 1)} km, Richtung ${bearingDeg(widget.homeLat, widget.homeLon, a.lat!, a.lon!).round()}°'),
            Text('Meldungen: ${a.messages} · Signal ${n(a.signalDb, 1)} dB'),
          ],
        ),
        actions: [
          TextButton(autofocus: true, onPressed: () => Navigator.of(context).pop(), child: const Text('Schließen')),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final a = widget.aircraft;
    final km = a.distanceKm(widget.homeLat, widget.homeLon);
    final age = DateTime.now().difference(a.lastSeen).inSeconds;
    const dim = TextStyle(color: Colors.white70);
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: TvFocusHighlight(
        focused: _focused,
        borderRadius: BorderRadius.circular(8),
        child: Card(
          margin: EdgeInsets.zero,
          child: InkWell(
            focusColor: Colors.transparent,
            onFocusChange: (v) {
              setState(() => _focused = v);
              widget.onFocus(v);
            },
            onTap: _details,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  SizedBox(
                    width: _wFlight,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(a.callsign ?? '—', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                        Text(a.icaoHex, style: const TextStyle(color: Colors.white54, fontSize: 12)),
                      ],
                    ),
                  ),
                  SizedBox(width: _wAlt, child: Text(_fmtAlt(a), style: dim)),
                  SizedBox(width: _wSpeed, child: Text(a.speedKmh != null ? '${a.speedKmh} km/h' : '', style: dim)),
                  SizedBox(
                    width: _wClimb,
                    child: Text(
                      a.verticalRateFpm == null || a.verticalRateFpm!.abs() < 200
                          ? ''
                          : (a.verticalRateFpm! > 0 ? '↗ steigt' : '↘ sinkt'),
                      style: dim,
                    ),
                  ),
                  SizedBox(
                    width: _wDist,
                    child: Text(
                      km == null ? '' : '${km.toStringAsFixed(km < 10 ? 1 : 0).replaceAll('.', ',')} km',
                      style: const TextStyle(color: Colors.greenAccent),
                    ),
                  ),
                  Expanded(child: Text(a.country ?? '', style: const TextStyle(color: Colors.white54))),
                  Text(age <= 1 ? '' : 'vor $age s', style: const TextStyle(color: Colors.white38, fontSize: 12)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// North-up radar around home: range rings, aircraft as arrows along their
/// track with the flight number.
class _RadarPainter extends CustomPainter {
  final List<Aircraft> aircraft;
  final double homeLat;
  final double homeLon;
  final int? selected;

  /// The background map, null = off.
  final MapTiles? tiles;

  _RadarPainter({
    required this.aircraft,
    required this.homeLat,
    required this.homeLon,
    required this.selected,
    required this.tiles,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.shortestSide / 2 - 4;
    canvas.drawCircle(c, r, Paint()..color = const Color(0xFF040A06));
    // Range: the farthest aircraft, rounded up to 50/100/200/... km.
    var maxKm = 50.0;
    for (final a in aircraft) {
      final d = a.distanceKm(homeLat, homeLon);
      if (d != null && d > maxKm) maxKm = d;
    }
    // Ranges whose quarter is a round number (rings at 10/20/25/50/... km).
    final steps = [40.0, 80.0, 100.0, 200.0, 400.0, 600.0];
    final range = steps.firstWhere((s) => s >= maxKm * 1.05, orElse: () => 600);

    // Map under it, dimmed so the aircraft stand out; same Web Mercator
    // projection for the aircraft below, so they sit right on the map.
    final zoom = MapTiles.zoomFor(homeLat, range, r);
    final home = MapTiles.project(homeLat, homeLon, zoom);
    if (tiles != null) {
      canvas.save();
      canvas.clipPath(Path()..addOval(Rect.fromCircle(center: c, radius: r)));
      tiles!.paint(canvas, c, r, homeLat, homeLon, range);
      canvas.drawCircle(c, r, Paint()..color = Colors.black.withValues(alpha: 0.25));
      canvas.restore();
      final tp = TextPainter(
        text: const TextSpan(text: MapTiles.attribution, style: TextStyle(color: Colors.white54, fontSize: 10)),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(size.width - tp.width - 2, size.height - tp.height - 2));
    }
    final ring = Paint()
      ..color = brandGreen.withValues(alpha: 0.35)
      ..style = PaintingStyle.stroke;
    const label = TextStyle(color: Colors.white38, fontSize: 11);
    for (var i = 1; i <= 4; i++) {
      final rr = r * i / 4;
      canvas.drawCircle(c, rr, ring);
      _text(canvas, '${(range * i / 4).round()} km', c + Offset(4, -rr + 2), label);
    }
    canvas.drawLine(c - Offset(0, r), c + Offset(0, r), ring);
    canvas.drawLine(c - Offset(r, 0), c + Offset(r, 0), ring);
    _text(canvas, 'N', c - Offset(4, r - 2), const TextStyle(color: Colors.white70, fontSize: 13));
    canvas.drawCircle(c, 4, Paint()..color = Colors.white);

    for (final a in aircraft) {
      if (!a.hasPosition) continue;
      final p = c + (MapTiles.project(a.lat!, a.lon!, zoom) - home);
      if ((p - c).distance > r) continue;
      final isSel = a.icao == selected;
      final color = isSel ? Colors.amberAccent : (a.onGround ? Colors.white54 : Colors.greenAccent);
      final paint = Paint()
        ..color = color
        ..strokeWidth = isSel ? 3 : 2;
      canvas.drawCircle(p, isSel ? 6 : 4, paint);
      if (a.track != null) {
        final t = a.track! * math.pi / 180;
        canvas.drawLine(p, p + Offset(math.sin(t), -math.cos(t)) * 16, paint);
      }
      _text(
        canvas,
        a.callsign ?? a.icaoHex,
        p + const Offset(7, -7),
        TextStyle(color: color, fontSize: isSel ? 13 : 11, fontWeight: isSel ? FontWeight.bold : null),
      );
    }
  }

  static void _text(Canvas canvas, String text, Offset at, TextStyle style) {
    (TextPainter(text: TextSpan(text: text, style: style), textDirection: TextDirection.ltr)..layout()).paint(canvas, at);
  }

  @override
  bool shouldRepaint(covariant _RadarPainter old) => true;
}
