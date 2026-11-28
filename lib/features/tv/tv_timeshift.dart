import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../core/loading_wave.dart';
import '../../core/nas_providers.dart';
import '../../core/providers.dart';
import '../../core/system_providers.dart' show deviceNameProvider;
import '../../core/theme.dart';
import '../../data/db/database.dart';
import '../../data/services/nas_service.dart';
import '../../data/services/tv_stream_session.dart';
import '../../data/services/tv_timeshift_buffer.dart';
import '../../l10n/l10n.dart';
import 'tv_player.dart';

/// Where TV keeps the live picture for pausing and rewinding (Einstellungen
/// → TV → Aufnahmen & Timeshift). The receiver's own timeshift only works
/// for its HDMI picture - the app keeps the network stream itself.
enum TvTimeshiftMode {
  off,

  /// In memory (a tenth of the device's RAM) - the standard.
  memory,

  /// In the app's cache on this device.
  local,

  /// In the NAS folder "Timeshift".
  nas,
}

typedef TvTimeshiftSettings = ({TvTimeshiftMode mode, int minutes});

/// The mode's name on the settings pages.
String tvTimeshiftModeLabel(BuildContext context, TvTimeshiftMode mode) => switch (mode) {
      TvTimeshiftMode.off => context.l10n.tvShiftModeOff,
      TvTimeshiftMode.memory => context.l10n.tvShiftModeMemory,
      TvTimeshiftMode.local => context.l10n.tvShiftModeLocal,
      TvTimeshiftMode.nas => context.l10n.tvShiftModeNas,
    };

/// How far back local / NAS timeshift goes at most.
const tvTimeshiftMinuteChoices = [15, 30, 60, 90, 120];

/// The timeshift settings in the settings table (backups carry them).
class TvTimeshiftStore {
  TvTimeshiftStore(this._db);

  final AppDatabase _db;
  static const modeKey = 'tv_timeshift_mode';
  static const minutesKey = 'tv_timeshift_minutes';

  Future<TvTimeshiftSettings> load() async {
    final mode = await _db.getSetting(modeKey);
    final minutes = int.tryParse(await _db.getSetting(minutesKey) ?? '');
    return (
      mode: TvTimeshiftMode.values.where((m) => m.name == mode).firstOrNull ?? TvTimeshiftMode.memory,
      minutes: tvTimeshiftMinuteChoices.contains(minutes) ? minutes! : 30,
    );
  }

  Future<void> save(TvTimeshiftSettings s) async {
    await _db.setSetting(modeKey, s.mode.name);
    await _db.setSetting(minutesKey, '${s.minutes}');
  }
}

class TvTimeshiftNotifier extends Notifier<TvTimeshiftSettings> {
  TvTimeshiftStore get _store => TvTimeshiftStore(ref.read(databaseProvider));

  @override
  TvTimeshiftSettings build() {
    // The NAS folder is needed at the first channel already.
    ref.read(nasSettingsProvider);
    _store.load().then((v) => state = v, onError: (Object e) => debugPrint('Timeshift settings: $e'));
    return (mode: TvTimeshiftMode.memory, minutes: 30);
  }

  Future<void> set(TvTimeshiftSettings value) async {
    state = value;
    await _store.save(value);
  }
}

final tvTimeshiftProvider = NotifierProvider<TvTimeshiftNotifier, TvTimeshiftSettings>(TvTimeshiftNotifier.new);

/// The memory timeshift takes on this device (bytes).
final tvTimeshiftMemoryProvider = FutureProvider<int>((ref) => timeshiftMemoryBytes());

/// [live] (a receiver channel's player on [session]) with timeshift as set
/// - or as it is when it's off. The buffer fills behind the scenes from
/// the first descrambled packet on: the start of the picture doesn't wait
/// for it.
TvPlayer withTvTimeshift(WidgetRef ref, TvPlayer live, TvStreamSession session) {
  final settings = ref.read(tvTimeshiftProvider);
  if (settings.mode == TvTimeshiftMode.off) return live;
  try {
    final memory = ref.read(tvTimeshiftMemoryProvider).value ?? (128 << 20);
    TimeshiftBackend? backend;
    String? note;
    switch (settings.mode) {
      case TvTimeshiftMode.local:
        final run = '${DateTime.now().millisecondsSinceEpoch}';
        backend = FileTimeshiftBackend(() async => Directory(p.join((await getTemporaryDirectory()).path, 'timeshift', run)));
      case TvTimeshiftMode.nas:
        final nas = ref.read(nasSettingsProvider).value;
        final folder = nas?.folder(NasFolder.timeshift);
        if (nas == null || folder == null) {
          note = l10n.tvShiftNoNasFolder;
        } else {
          backend = NasTimeshiftBackend(nas.config.createClient(), folder, 'ts_${_fileName(ref.read(deviceNameProvider))}_');
        }
      case TvTimeshiftMode.memory:
      case TvTimeshiftMode.off:
    }
    final buffer = TimeshiftBuffer(
      backend: backend,
      memoryBytes: memory,
      maxAge: backend == null ? null : Duration(minutes: settings.minutes),
    );
    return TvTimeshiftPlayer(live, session, buffer, note: note);
  } catch (e) {
    debugPrint('Timeshift: $e');
    return live;
  }
}

String _fileName(String deviceName) {
  final s = deviceName.trim().replaceAll(RegExp(r'[^A-Za-z0-9-]+'), '-');
  return s.isEmpty ? 'tv' : s;
}

/// What timeshift shows: paused, how far behind live, how far back it
/// goes, a player starting at another place, a note.
@immutable
class TvTimeshiftState {
  const TvTimeshiftState({
    this.paused = false,
    this.delay = Duration.zero,
    this.available = Duration.zero,
    this.busy = false,
    this.seeking = 0,
    this.message,
  });

  final bool paused;

  /// Behind live (where it is, or where it goes while [seeking]).
  final Duration delay;

  /// How far back the buffer goes.
  final Duration available;

  /// A player is starting at another place.
  final bool busy;

  /// Choosing a place: -1 back, 1 forward, 0 not.
  final int seeking;
  final String? message;

  /// Not live: the timeshift keys count, the indicator shows.
  bool get shifted => paused || busy || seeking != 0 || delay >= const Duration(seconds: 3);

  @override
  bool operator ==(Object other) =>
      other is TvTimeshiftState &&
      other.paused == paused &&
      other.delay.inSeconds == delay.inSeconds &&
      other.available.inSeconds == available.inSeconds &&
      other.busy == busy &&
      other.seeking == seeking &&
      other.message == message;

  @override
  int get hashCode => Object.hash(paused, delay.inSeconds, available.inSeconds, busy, seeking, message);
}

/// A receiver channel's player with timeshift: the live player at first
/// (straight from the [TvStreamSession]); paused or rewound, a player on
/// the [TimeshiftBuffer] takes over at that place - started behind the
/// still picture and swapped in once it shows. [view] always shows the
/// one playing.
class TvTimeshiftPlayer implements TvPlayer {
  TvTimeshiftPlayer(TvPlayer live, this._session, this._buffer, {String? note})
      : _live = live,
        _current = ValueNotifier<TvPlayer>(live) {
    _subscription = _session.clearData.listen(_buffer.append);
    _follow(live);
    _buffer.problem.addListener(_onProblem);
    if (note != null) _say(note);
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => _publish());
  }

  /// Between the stream's arrival and the picture on the live player.
  static const _liveLatency = Duration(milliseconds: 1500);
  static const smallStep = Duration(seconds: 10);
  static const bigStep = Duration(minutes: 1);

  final TvPlayer _live;
  final TvStreamSession _session;
  final TimeshiftBuffer _buffer;
  final ValueNotifier<TvPlayer> _current;

  /// Between two players: the old one closed, the new one not showing yet
  /// (only ever one video decoder - a second one at the same time froze
  /// libmpv on Windows, and weak TV boxes have only one).
  final _gap = ValueNotifier(false);
  final _info = ValueNotifier(const TvPlayerInfo());
  final state = ValueNotifier(const TvTimeshiftState());
  StreamSubscription<List<int>>? _subscription;
  Future<TimeshiftServer>? _server;
  Timer? _ticker;
  Timer? _seekTimer;
  Timer? _messageTimer;

  /// The live player straight from the session is the one on screen.
  bool _direct = true;
  bool _paused = false;
  bool _busy = false;
  bool _disposed = false;
  bool _liveDisposed = false;

  /// When what's on screen arrived ([_content], null: live) - as of
  /// [_wall]; it moves on with the clock while playing.
  DateTime? _content;
  DateTime _wall = DateTime.now();
  DateTime? _seekTarget;
  int _seekDirection = 0;
  String? _message;
  String? _audioId;
  int _swap = 0;

  void _follow(TvPlayer player) {
    _info.value = player.info.value;
    player.info.addListener(_mirror);
  }

  void _unfollow(TvPlayer player) {
    try {
      player.info.removeListener(_mirror);
    } catch (_) {}
  }

  void _mirror() {
    if (!_disposed) _info.value = _current.value.info.value;
  }

  void _onProblem() {
    final problem = _buffer.problem.value;
    if (problem == null) return;
    _say(problem == TimeshiftProblem.tooSlow ? l10n.tvShiftTooSlow : l10n.tvShiftWriteFailed);
  }

  void _say(String text) {
    _messageTimer?.cancel();
    _message = text;
    _publish();
    _messageTimer = Timer(const Duration(seconds: 8), () {
      _message = null;
      _publish();
    });
  }

  DateTime _contentTime(DateTime now) {
    final c = _content;
    if (c == null) return now;
    return _paused ? c : c.add(now.difference(_wall));
  }

  void _publish() {
    if (_disposed) return;
    final now = DateTime.now();
    var delay = now.difference(_seekTarget ?? _contentTime(now));
    if (delay.isNegative) delay = Duration.zero;
    state.value = TvTimeshiftState(
      paused: _paused,
      delay: delay,
      available: _buffer.span,
      busy: _busy,
      seeking: _seekTarget == null ? 0 : _seekDirection,
      message: _message,
    );
  }

  Future<void> togglePause() => _paused ? resume() : pause();

  Future<void> pause() async {
    if (_paused || _disposed) return;
    final now = DateTime.now();
    _content = _content == null ? now.subtract(_liveLatency) : _contentTime(now);
    _paused = true;
    _seekTimer?.cancel();
    _seekTarget = null;
    // The live player plays on from the buffer later - the stream mustn't
    // pile up for it meanwhile.
    if (_direct) _session.stopFeedingPlayer();
    _publish();
    try {
      await _current.value.setPaused(true);
    } catch (e) {
      debugPrint('Timeshift: pause: $e');
    }
  }

  Future<void> resume() async {
    if (!_paused || _disposed) return;
    final content = _content ?? DateTime.now();
    final oldest = _buffer.oldestTime;
    // The live player (its stream stopped) - or the place it held is gone
    // from the buffer meanwhile: a player on the buffer from there.
    if (_direct || (oldest != null && content.isBefore(oldest.add(const Duration(seconds: 2))))) {
      return _playFrom(content);
    }
    _paused = false;
    _wall = DateTime.now();
    _publish();
    try {
      await _current.value.setPaused(false);
    } catch (e) {
      debugPrint('Timeshift: resume: $e');
    }
  }

  /// Back (negative) or forward - the presses add up, the player moves once
  /// they stop. Forward up to now goes live.
  void seekBy(Duration by) {
    if (_disposed) return;
    final now = DateTime.now();
    if (_buffer.span < const Duration(seconds: 3)) {
      _say(l10n.tvShiftNothingYet);
      return;
    }
    var target = (_seekTarget ?? _contentTime(now)).add(by);
    final oldest = _buffer.oldestTime ?? now;
    if (target.isBefore(oldest)) target = oldest;
    if (target.isAfter(now)) target = now;
    _seekTarget = target;
    _seekDirection = by.isNegative ? -1 : 1;
    _publish();
    _seekTimer?.cancel();
    _seekTimer = Timer(const Duration(milliseconds: 800), _commitSeek);
  }

  void _commitSeek() {
    final target = _seekTarget;
    if (target == null || _disposed) return;
    if (DateTime.now().difference(target) < const Duration(seconds: 4)) {
      unawaited(goLive());
    } else {
      unawaited(_playFrom(target));
    }
  }

  /// Back to live: the newest part of the buffer, as it comes.
  Future<void> goLive() async {
    if (_disposed) return;
    _seekTimer?.cancel();
    if (!_paused && _content == null) {
      _seekTarget = null;
      _publish();
      return;
    }
    await _swapTo(_buffer.head, content: null);
  }

  Future<void> _playFrom(DateTime t) async {
    final offset = _buffer.offsetAt(t);
    await _swapTo(offset, content: _buffer.timeAt(offset));
  }

  Future<void> _swapTo(int offset, {required DateTime? content}) async {
    if (_disposed) return;
    final swap = ++_swap;
    _busy = true;
    _publish();
    TvPlayer? player;
    try {
      final server = await (_server ??= TimeshiftServer.start(_buffer));
      if (_disposed || swap != _swap) return;
      // The player on screen goes first - never two decoding at once.
      final old = _current.value;
      if (!_gap.value) {
        _unfollow(old);
        if (_direct) {
          _direct = false;
          _session.stopFeedingPlayer();
        }
        _gap.value = true;
        await _disposePlayer(old);
        if (_disposed || swap != _swap) return;
      }
      final next = player = TvPlayer(server.uriAt(offset), const {});
      await next.start(timeout: const Duration(seconds: 15));
    } catch (e) {
      debugPrint('Timeshift: player: $e');
      if (player != null) unawaited(player.dispose().catchError((Object _) {}));
      if (!_disposed && swap == _swap) {
        _busy = false;
        _seekTarget = null;
        _say(l10n.tvShiftPlayFailed);
      }
      return;
    }
    if (_disposed || swap != _swap) {
      unawaited(player.dispose().catchError((Object _) {}));
      return;
    }
    _current.value = player;
    _gap.value = false;
    _follow(player);
    _paused = false;
    _busy = false;
    _seekTarget = null;
    _content = content;
    _wall = DateTime.now();
    _publish();
    final audio = _audioId;
    if (audio != null) unawaited(player.selectAudio(audio).catchError((Object _) {}));
  }

  /// The players closed already (each only once).
  final _closed = Expando<bool>();

  Future<void> _disposePlayer(TvPlayer player) async {
    if (identical(player, _live)) {
      if (_liveDisposed) return;
      _liveDisposed = true;
    }
    if (_closed[player] == true) return;
    _closed[player] = true;
    try {
      await player.dispose();
    } catch (_) {}
  }

  /// The remote's keys while a receiver channel plays - true if [event]
  /// (down or repeat) was one: ⏯ / ⏸ / ▶ pause and play on, ⏪ goes back a
  /// minute, ⏩ forward (live: the next channel, as before), ← / → ten
  /// seconds while not live, ■ back to live. On a PC keyboard: Space is ⏯,
  /// J / L a minute back / forward, End back to live.
  /// The PC keyboard's stand-ins for the remote's media keys.
  static final _pcKeys = {
    LogicalKeyboardKey.space: LogicalKeyboardKey.mediaPlayPause,
    LogicalKeyboardKey.keyJ: LogicalKeyboardKey.mediaRewind,
    LogicalKeyboardKey.keyL: LogicalKeyboardKey.mediaFastForward,
    LogicalKeyboardKey.end: LogicalKeyboardKey.mediaStop,
  };

  bool handleKey(KeyEvent event) {
    final key = _pcKeys[event.logicalKey] ?? event.logicalKey;
    final repeat = event is KeyRepeatEvent;
    final shifted = state.value.shifted;
    if (key == LogicalKeyboardKey.mediaPlayPause) {
      if (!repeat) unawaited(togglePause());
      return true;
    }
    if (key == LogicalKeyboardKey.mediaPause) {
      if (!repeat) unawaited(pause());
      return true;
    }
    if (key == LogicalKeyboardKey.mediaPlay) {
      if (!repeat) unawaited(resume());
      return true;
    }
    if (key == LogicalKeyboardKey.mediaStop) {
      if (!shifted) return false;
      if (!repeat) unawaited(goLive());
      return true;
    }
    if (key == LogicalKeyboardKey.mediaRewind) {
      seekBy(-bigStep);
      return true;
    }
    if (key == LogicalKeyboardKey.mediaFastForward) {
      if (!shifted) return false;
      seekBy(bigStep);
      return true;
    }
    if (shifted && key == LogicalKeyboardKey.arrowLeft) {
      seekBy(-smallStep);
      return true;
    }
    if (shifted && key == LogicalKeyboardKey.arrowRight) {
      seekBy(smallStep);
      return true;
    }
    return false;
  }

  @override
  Future<void> start({Duration timeout = const Duration(seconds: 20)}) => _live.start(timeout: timeout);

  @override
  Widget view() => ValueListenableBuilder<bool>(
        valueListenable: _gap,
        builder: (context, gap, _) => gap
            // The old player closed, the new one starting: black with the
            // loading wave (a moment).
            ? const ColoredBox(color: Colors.black, child: Center(child: LoadingWave()))
            : ValueListenableBuilder<TvPlayer>(
                valueListenable: _current,
                builder: (context, player, _) => KeyedSubtree(key: ObjectKey(player), child: player.view()),
              ),
      );

  @override
  ValueListenable<TvPlayerInfo> get info => _info;

  @override
  Future<void> selectAudio(String id) async {
    _audioId = id;
    await _current.value.selectAudio(id);
  }

  @override
  Future<void> setPaused(bool paused) => paused ? pause() : resume();

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _ticker?.cancel();
    _seekTimer?.cancel();
    _messageTimer?.cancel();
    await _subscription?.cancel();
    _buffer.problem.removeListener(_onProblem);
    final current = _current.value;
    _unfollow(current);
    await _disposePlayer(current);
    if (!identical(current, _live)) await _disposePlayer(_live);
    final server = _server;
    if (server != null) {
      try {
        await (await server).close();
      } catch (_) {}
    }
    await _buffer.close();
    // The notifiers stay (no listener may be left on a disposed one while
    // the screen lets go of this player); they go with it.
  }
}

/// "−12:34" / "−1:02:03".
String formatTimeshiftDelay(Duration d) {
  final s = d.inSeconds;
  final h = s ~/ 3600, m = (s % 3600) ~/ 60, sec = s % 60;
  final mm = m.toString().padLeft(h > 0 ? 2 : 1, '0'), ss = sec.toString().padLeft(2, '0');
  return h > 0 ? '−$h:$mm:$ss' : '−$mm:$ss';
}

/// Timeshift on screen (top left): paused / behind live, where in the
/// buffer, and the keys - only while not live (or with a note).
class TvTimeshiftIndicator extends StatelessWidget {
  const TvTimeshiftIndicator({super.key, required this.player});

  final TvTimeshiftPlayer player;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<TvTimeshiftState>(
        valueListenable: player.state,
        builder: (context, s, _) {
          if (!s.shifted && s.message == null) return const SizedBox.shrink();
          final l = context.l10n;
          final icon = s.busy
              ? Icons.hourglass_top
              : s.seeking < 0
                  ? Icons.fast_rewind
                  : s.seeking > 0
                      ? Icons.fast_forward
                      : s.paused
                          ? Icons.pause
                          : Icons.history;
          final total = s.available.inMilliseconds;
          final position = total <= 0 ? 1.0 : (1 - s.delay.inMilliseconds / total).clamp(0.0, 1.0);
          return Container(
            width: 380,
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.75),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (s.shifted) ...[
                  Row(
                    children: [
                      Icon(icon, color: brandGreen, size: 30),
                      const SizedBox(width: 12),
                      Text(
                        s.delay.inSeconds < 3 ? l.tvShiftLive : formatTimeshiftDelay(s.delay),
                        style: const TextStyle(color: Colors.white, fontSize: 26, fontWeight: FontWeight.bold),
                      ),
                      const Spacer(),
                      Text(l.tvShiftTitle, style: const TextStyle(color: Colors.white60, fontSize: 15)),
                    ],
                  ),
                  const SizedBox(height: 10),
                  LayoutBuilder(
                    builder: (context, size) => SizedBox(
                      height: 12,
                      child: Stack(
                        children: [
                          Positioned.fill(
                            top: 3,
                            bottom: 3,
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(3),
                              child: LinearProgressIndicator(
                                value: position,
                                minHeight: 6,
                                backgroundColor: Colors.white24,
                                valueColor: const AlwaysStoppedAnimation(brandGreen),
                              ),
                            ),
                          ),
                          Positioned(
                            left: (size.maxWidth - 4) * position,
                            top: 0,
                            bottom: 0,
                            child: Container(width: 4, color: Colors.white),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(l.tvShiftKeyHint, style: TextStyle(color: Colors.white.withValues(alpha: 0.5), fontSize: 13)),
                ],
                if (s.message case final message?) ...[
                  if (s.shifted) const SizedBox(height: 8),
                  Text(message, style: const TextStyle(color: Colors.amber, fontSize: 15)),
                ],
              ],
            ),
          );
        },
      );
}
