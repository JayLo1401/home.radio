import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../core/theme.dart' show brandGreen, TvFocusHighlight;
import '../../data/models/adsb.dart';
import '../../data/repositories/settings_repository.dart';
import '../../data/services/adsbdb_service.dart';
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

  /// The aircraft opened with OK: its details unfold in the list. OK again
  /// (or the "Flugroute zeigen" button) draws its route (adsbdb.com) on the
  /// radar, zoomed out to both airports; Back hides it again, Back once more
  /// folds the details. Up/down to another flight folds everything.
  int? _expanded;
  bool _showRoute = false;
  FlightInfo? _info;
  bool _infoLoading = false;
  String? _infoCallsign; // the callsign the info was asked with

  Future<void> _onOk(Aircraft a) async {
    if (_expanded == a.icao) {
      setState(() => _showRoute = !_showRoute);
      return;
    }
    setState(() {
      _expanded = a.icao;
      _selected = a.icao;
      _showRoute = false;
      _info = null;
    });
    await _loadInfo(a);
  }

  void _collapse() => setState(() {
    _expanded = null;
    _showRoute = false;
    _info = null;
  });

  /// Back: route off first, then the details, then leave the screen.
  void _onBack() {
    if (_showRoute) {
      setState(() => _showRoute = false);
    } else if (_expanded != null) {
      _collapse();
    }
  }

  Future<void> _loadInfo(Aircraft a) async {
    final icao = a.icao, callsign = a.callsign;
    setState(() {
      _infoLoading = true;
      _infoCallsign = callsign;
    });
    final info = await AdsbdbService.lookup(icaoHex: a.icaoHex, callsign: callsign);
    if (!mounted || _expanded != icao) return;
    setState(() {
      _info = info;
      _infoLoading = false;
    });
  }

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
      // The callsign often arrives after the position: ask again with it.
      final open = _expanded == null ? null : t.aircraft[_expanded];
      if (open != null && !_infoLoading && open.callsign != null && open.callsign != _infoCallsign) _loadInfo(open);
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
    // Back hides the route, then folds the details, then leaves.
    return PopScope(
      canPop: _expanded == null && !_showRoute,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _onBack();
      },
      child: Scaffold(
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
                                    routeIcao: _showRoute ? _expanded : null,
                                    route: _showRoute ? _info : null,
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
                                        expanded: _expanded == a.icao,
                                        routeShown: _expanded == a.icao && _showRoute,
                                        info: _expanded == a.icao ? _info : null,
                                        loading: _expanded == a.icao && _infoLoading,
                                        onTap: () => _onOk(a),
                                        onRoute: () => setState(() => _showRoute = !_showRoute),
                                        onFocus: (focused) {
                                          if (!focused) return;
                                          // On to another flight: the open one folds.
                                          if (_expanded != null && _expanded != a.icao) {
                                            _expanded = null;
                                            _showRoute = false;
                                            _info = null;
                                          }
                                          setState(() => _selected = a.icao);
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
/// on the radar); OK unfolds the details (route, airline, aircraft), OK
/// again shows the route on the radar - the table itself stays compact.
class _AircraftTile extends StatefulWidget {
  final Aircraft aircraft;
  final double homeLat;
  final double homeLon;
  final bool expanded;
  final bool routeShown;
  final FlightInfo? info;
  final bool loading;
  final VoidCallback onTap;
  final VoidCallback onRoute;
  final ValueChanged<bool> onFocus;

  const _AircraftTile({
    required this.aircraft,
    required this.homeLat,
    required this.homeLon,
    required this.expanded,
    required this.routeShown,
    required this.info,
    required this.loading,
    required this.onTap,
    required this.onRoute,
    required this.onFocus,
  });

  @override
  State<_AircraftTile> createState() => _AircraftTileState();
}

class _AircraftTileState extends State<_AircraftTile> {
  bool _focused = false;

  /// The unfolded part: route, airline, aircraft, then the live data.
  Widget _details() {
    final a = widget.aircraft;
    final info = widget.info;
    final km = a.distanceKm(widget.homeLat, widget.homeLon);
    String n(double v, int d) => v.toStringAsFixed(d).replaceAll('.', ',');
    String place(Airport p) => '${p.city ?? p.name} (${p.code})${p.country != null ? ', ${p.country}' : ''}';
    const label = TextStyle(color: Colors.white54);
    const value = TextStyle(color: Colors.white);
    Widget line(String l, String v) => Padding(
          padding: const EdgeInsets.only(bottom: 2),
          child: Text.rich(TextSpan(children: [TextSpan(text: '$l  ', style: label), TextSpan(text: v, style: value)])),
        );
    final aircraftText = [
      if (info?.manufacturer != null) info!.manufacturer!,
      if (info?.aircraftType != null) info!.aircraftType!,
    ].join(' ');
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 8, 0, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (widget.loading && info == null)
            const Text('Route wird geladen…', style: label)
          else if ((info?.hasRoute ?? false) && !info!.fits(lat: a.lat, lon: a.lon, track: a.track)) ...[
            // A stale route: the callsign flies something else today.
            Text(
              '${info.origin!.code}  →  ${info.destination!.code}  ?',
              style: const TextStyle(color: Colors.white38, fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const Text(
              'Passt nicht zur Flugrichtung – die Fluglinie vergibt dieses Rufzeichen offenbar für eine '
              'andere Strecke; die Routendaten sind veraltet.',
              style: TextStyle(color: Colors.orangeAccent),
            ),
          ] else if (info?.hasRoute ?? false) ...[
            Text(
              '${info!.origin!.code}  →  ${info.destination!.code}',
              style: const TextStyle(color: Colors.amberAccent, fontSize: 18, fontWeight: FontWeight.bold),
            ),
            line('Von', place(info.origin!)),
            line('Nach', place(info.destination!)),
            const SizedBox(height: 4),
            // For the mouse; with the remote it's OK on the row (the button
            // stays out of the focus order, so up/down go to the next flight).
            ExcludeFocus(
              child: OutlinedButton.icon(
                onPressed: widget.onRoute,
                icon: Icon(widget.routeShown ? Icons.layers_clear : Icons.route),
                label: Text(widget.routeShown ? 'Flugroute ausblenden (Zurück)' : 'Flugroute zeigen (OK)'),
              ),
            ),
            const SizedBox(height: 4),
          ] else
            const Text('Keine Routendaten bekannt', style: label),
          if (info?.airline != null) line('Fluglinie', info!.airline!),
          if (aircraftText.isNotEmpty) line('Flugzeug', aircraftText),
          if (info?.registration != null) line('Kennzeichen', info!.registration!),
          if (info?.owner != null) line('Halter', info!.owner!),
          const SizedBox(height: 4),
          line('ICAO-Adresse', '${a.icaoHex}${a.country != null ? ' (${a.country})' : ''}'),
          if (a.squawk != null) line('Squawk', a.squawk!),
          if (a.track != null) line('Kurs', '${a.track!.round()}°'),
          if (a.verticalRateFpm != null)
            line('Steigen/Sinken', '${n(a.verticalRateFpm! * 0.00508, 1)} m/s (${a.verticalRateFpm} ft/min)'),
          if (a.speedKt != null) line('Geschwindigkeit', '${a.speedKmh} km/h (${a.speedKt!.round()} kn)'),
          if (a.hasPosition) line('Position', '${n(a.lat!, 4)}° N, ${n(a.lon!, 4)}° O'),
          if (km != null)
            line('Richtung', '${bearingDeg(widget.homeLat, widget.homeLon, a.lat!, a.lon!).round()}° in ${n(km, 1)} km'),
          line('Empfang', '${a.messages} Meldungen · Signal ${n(a.signalDb, 1)} dB'),
          const SizedBox(height: 2),
          const Text('Route und Flugzeugdaten: adsbdb.com', style: TextStyle(color: Colors.white38, fontSize: 11)),
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
            onTap: widget.onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
              Row(
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
                  Icon(widget.expanded ? Icons.expand_less : Icons.expand_more, color: Colors.white38),
                ],
              ),
                  if (widget.expanded) _details(),
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

  /// The opened aircraft and its route (adsbdb.com), drawn origin →
  /// aircraft → destination.
  final int? routeIcao;
  final FlightInfo? route;

  _RadarPainter({
    required this.aircraft,
    required this.homeLat,
    required this.homeLon,
    required this.selected,
    required this.tiles,
    required this.routeIcao,
    required this.route,
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
    // An opened flight's route: zoomed out until both airports are on it.
    final routeInfo = route;
    final routeAircraft = aircraft.where((x) => x.icao == routeIcao).firstOrNull;
    final routeAirports = routeInfo != null &&
            routeInfo.hasRoute &&
            routeInfo.fits(lat: routeAircraft?.lat, lon: routeAircraft?.lon, track: routeAircraft?.track)
        ? [routeInfo.origin!, routeInfo.destination!]
        : const <Airport>[];
    for (final ap in routeAirports) {
      final d = greatCircleKm(homeLat, homeLon, ap.lat, ap.lon);
      if (d > maxKm) maxKm = d;
    }
    // Ranges whose quarter is a round number (rings at 10/20/25/50/... km).
    final steps = [40.0, 80.0, 100.0, 200.0, 400.0, 600.0, 1000.0, 2000.0, 4000.0, 6000.0, 8000.0, 12000.0];
    var step = steps.indexWhere((s) => s >= maxKm * 1.05);
    if (step < 0) step = steps.length - 1;
    // Web Mercator stretches towards the poles: step on until the airports
    // really sit inside the circle (with room for their labels).
    double zoomAt(int i) => MapTiles.zoomFor(homeLat, steps[i], r);
    bool fits(int i) => routeAirports.every((ap) {
      final z = zoomAt(i);
      return (MapTiles.project(ap.lat, ap.lon, z) - MapTiles.project(homeLat, homeLon, z)).distance <= r * 0.85;
    });
    while (step < steps.length - 1 && !fits(step)) {
      step++;
    }
    final range = steps[step];

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

    _paintRoute(canvas, c, r, zoom, home);

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

  /// The opened flight's route: flown part (origin → aircraft) dashed, the
  /// rest (aircraft → destination) bright; airports mostly lie beyond the
  /// radar, then their code sits at the edge where the line leaves it.
  void _paintRoute(Canvas canvas, Offset c, double r, double zoom, Offset home) {
    final info = route;
    if (info == null || !info.hasRoute) return;
    final a = aircraft.where((x) => x.icao == routeIcao).firstOrNull;
    if (a == null || !a.hasPosition) return;
    // A stale route (see FlightInfo.fits) isn't drawn.
    if (!info.fits(lat: a.lat, lon: a.lon, track: a.track)) return;
    Offset at(double lat, double lon) => c + (MapTiles.project(lat, lon, zoom) - home);
    final pa = at(a.lat!, a.lon!);
    if ((pa - c).distance > r) return;
    final po = at(info.origin!.lat, info.origin!.lon), pd = at(info.destination!.lat, info.destination!.lon);
    const flown = Color(0xB3FFFFFF), ahead = Colors.amberAccent;
    canvas.save();
    canvas.clipPath(Path()..addOval(Rect.fromCircle(center: c, radius: r)));
    _dashed(canvas, po, pa, Paint()
      ..color = flown
      ..strokeWidth = 2);
    canvas.drawLine(pa, pd, Paint()
      ..color = ahead
      ..strokeWidth = 2.5);
    canvas.restore();
    _airportLabel(canvas, c, r, pa, po, info.origin!, flown);
    _airportLabel(canvas, c, r, pa, pd, info.destination!, ahead);
  }

  /// Dashes from [to] backwards, so they stay put next to the aircraft
  /// however far away the airport is.
  static void _dashed(Canvas canvas, Offset from, Offset to, Paint paint) {
    final d = from - to;
    final len = d.distance;
    if (len < 1) return;
    final u = d / len;
    final end = math.min(len, 3000.0); // beyond the radar anyway
    for (var t = 0.0; t < end; t += 12) {
      canvas.drawLine(to + u * t, to + u * math.min(t + 6, end), paint);
    }
  }

  /// The airport as a marker with a readable sign (code and city) at its
  /// spot - the radar is zoomed out to show it; should it still lie
  /// outside (very long routes), at the edge towards it.
  static void _airportLabel(Canvas canvas, Offset c, double r, Offset from, Offset to, Airport ap, Color color) {
    var p = to;
    final inner = r - 8;
    if ((to - c).distance > inner) {
      final d = to - from;
      final len = d.distance;
      if (len < 1) return;
      final u = d / len, f = from - c;
      final b = f.dx * u.dx + f.dy * u.dy;
      final disc = b * b - (f.distanceSquared - inner * inner);
      if (disc < 0) return;
      p = from + u * (-b + math.sqrt(disc));
    }
    canvas.drawCircle(p, 7, Paint()..color = Colors.black);
    canvas.drawCircle(p, 5, Paint()..color = color);
    final tp = TextPainter(
      text: TextSpan(
        children: [
          TextSpan(
            text: ap.code,
            style: TextStyle(color: color, fontSize: 16, fontWeight: FontWeight.bold),
          ),
          if (ap.city != null)
            TextSpan(text: '\n${ap.city}', style: const TextStyle(color: Colors.white, fontSize: 12)),
        ],
      ),
      textDirection: TextDirection.ltr,
      maxLines: 2,
    )..layout(maxWidth: 160);
    // The sign beside the marker, on the side towards the centre, kept
    // inside the radar.
    const pad = 5.0;
    final w = tp.width + 2 * pad, h = tp.height + 2 * pad;
    var x = p.dx < c.dx ? p.dx + 10 : p.dx - 10 - w;
    var y = p.dy < c.dy ? p.dy + 8 : p.dy - 8 - h;
    x = x.clamp(c.dx - r, c.dx + r - w);
    y = y.clamp(c.dy - r, c.dy + r - h);
    final box = RRect.fromRectAndRadius(Rect.fromLTWH(x, y, w, h), const Radius.circular(6));
    canvas.drawRRect(box, Paint()..color = const Color(0xE6000000));
    canvas.drawRRect(
      box,
      Paint()
        ..color = color.withValues(alpha: 0.7)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
    tp.paint(canvas, Offset(x + pad, y + pad));
  }

  static void _text(Canvas canvas, String text, Offset at, TextStyle style) {
    (TextPainter(text: TextSpan(text: text, style: style), textDirection: TextDirection.ltr)..layout()).paint(canvas, at);
  }

  @override
  bool shouldRepaint(covariant _RadarPainter old) => true;
}
