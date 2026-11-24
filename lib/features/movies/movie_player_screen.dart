import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:video_player/video_player.dart' show Caption, SubRipCaptionFile;

import '../../core/dashboard_providers.dart' show displayServiceProvider;
import '../../core/remote_keys.dart';
import '../../core/theme.dart';
import '../../data/services/display_service.dart';
import '../../data/services/movie_dvd.dart';
import '../../data/services/movie_library.dart';
import '../../data/services/movie_resume_store.dart';
import '../../data/services/movie_source.dart';
import '../../data/services/movie_stream_server.dart';
import '../../data/services/nas_service.dart';
import '../../l10n/l10n.dart';
import '../launcher/launcher_providers.dart' show RadioCommand, radioCommandProvider;
import '../tv/tv_player.dart' show TvAudioTrack, audioDetails, audioTrackName;
import '../tv/tv_widgets.dart' show TvRow;
import 'movie_player.dart';
import 'movies_screen.dart' show movieResumeStoreProvider;

/// "1:02:03", "12:05".
String formatMovieTime(Duration d) {
  final negative = d.isNegative;
  final t = d.abs();
  final h = t.inHours;
  final m = t.inMinutes % 60;
  final s = t.inSeconds % 60;
  final text = h > 0 ? '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}' : '$m:${s.toString().padLeft(2, '0')}';
  return negative ? '-$text' : text;
}

/// The seek step for the [presses]th press in a row: 10 s, then 30 s,
/// 1 min, 3 min - holding ◀/▶ goes faster and faster.
Duration movieSeekStep(int presses) => switch (presses) {
      < 3 => const Duration(seconds: 10),
      < 6 => const Duration(seconds: 30),
      < 10 => const Duration(minutes: 1),
      _ => const Duration(minutes: 3),
    };

/// Where ▲/▼ go from [position]: the next / previous chapter if the film
/// has chapters (a DVD), else 5 minutes on / back. Back to the start of
/// the running chapter first, if it's more than a few seconds in.
Duration movieJumpTarget(Duration position, int direction, List<Duration> chapters) {
  if (chapters.length < 2) return position + const Duration(minutes: 5) * direction;
  var current = 0;
  for (var i = 0; i < chapters.length; i++) {
    if (chapters[i] <= position + const Duration(milliseconds: 500)) current = i;
  }
  if (direction > 0) return current + 1 < chapters.length ? chapters[current + 1] : position;
  if (position - chapters[current] > const Duration(seconds: 5)) return chapters[current];
  return chapters[current > 0 ? current - 1 : 0];
}

/// Plays a film from the NAS full screen: through the [MovieStreamServer]
/// (byte ranges for seeking; a DVD's VOB parts as one stream, one sound
/// track at a time), resuming where it was left off.
///
/// Remote: OK / ⏯ pause, ◀ ▶ seek (pressed again and again or held: faster),
/// ▲ ▼ chapters (DVD) or ±5 minutes, ☰ (options key) sound track and
/// subtitles, Back stops.
class MoviePlayerScreen extends ConsumerStatefulWidget {
  const MoviePlayerScreen({super.key, required this.movie, required this.config});

  final MovieItem movie;
  final NasConfig config;

  @override
  ConsumerState<MoviePlayerScreen> createState() => _MoviePlayerScreenState();
}

class _MoviePlayerScreenState extends ConsumerState<MoviePlayerScreen> {
  /// Its own NAS connection (the library's goes on with pictures).
  late final NasClient _client = widget.config.createClient();
  late final MovieResumeStore _resume = ref.read(movieResumeStoreProvider);
  late final DisplayService _display = ref.read(displayServiceProvider);
  final _focus = FocusNode(debugLabel: 'movie player');

  PreparedMovie? _prepared;
  MovieStreamServer? _server;
  MoviePlayer? _player;
  DvdAudioStream? _dvdAudio;
  String? _error;
  bool _opening = true;
  bool _closing = false;

  bool _osd = true;
  Timer? _osdTimer;
  Timer? _saveTimer;

  Duration? _seekTarget;
  Timer? _seekTimer;
  int _seekPresses = 0;
  int _seekDirection = 0;
  DateTime _lastSeek = DateTime(2000);

  String? _subtitlePath;
  List<Caption> _captions = const [];

  /// The player the film plays with now - ExoPlayer first on Android,
  /// libmpv if it can't (see firstMovieEngine, movieFallsBackToMpv).
  MovieEngine _engine = MovieEngine.mpv;

  /// Handing the film from ExoPlayer to libmpv.
  bool _switchingEngine = false;

  bool get _exo => _engine == MovieEngine.exoPlayer;

  @override
  void initState() {
    super.initState();
    // The film takes the speakers; the radio plays on when opened again.
    ref.read(radioCommandProvider.notifier).send(RadioCommand.pauseForApp);
    _display.setKeepScreenOn(true);
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  @override
  void dispose() {
    _osdTimer?.cancel();
    _saveTimer?.cancel();
    _seekTimer?.cancel();
    _focus.dispose();
    final player = _player;
    _player = null;
    if (player != null) {
      unawaited(_savePosition(player));
      player.state.removeListener(_onState);
      unawaited(player.dispose());
    }
    unawaited(_server?.close());
    _client.close();
    _display.setKeepScreenOn(false);
    super.dispose();
  }

  Future<void> _start() async {
    try {
      final prepared = await prepareMovie(_client, widget.movie);
      if (!mounted) return;
      _prepared = prepared;
      var start = Duration.zero;
      final resume = await _resume.position(widget.movie.path);
      if (resume != null && mounted) {
        final choice = await _askResume(resume);
        if (!mounted) return;
        if (choice == null) return _close();
        if (choice) start = resume;
      }
      _engine = firstMovieEngine(
        android: MoviePlayer.isAndroid,
        extension: fileExtension(widget.movie.path),
        exoPlayableAudio: !prepared.isDvdStream ||
            prepared.dvdAudio.isEmpty ||
            prepared.playableAudio(exoPlayer: true).isNotEmpty,
      );
      _dvdAudio = prepared.defaultAudio(exoPlayer: _exo, language: _language);
      final server = await MovieStreamServer.start(
        prepared.sourceFor(audio: _dvdAudio, exoPlayer: _exo),
        name: prepared.name,
        mime: prepared.mime,
      );
      if (!mounted) {
        unawaited(server.close());
        return;
      }
      _server = server;
      await _openPlayer(start);
      _saveTimer = Timer.periodic(const Duration(seconds: 15), (_) {
        final player = _player;
        if (player != null) _savePosition(player);
      });
      if (widget.movie.subtitles.isNotEmpty) _autoSubtitles();
    } catch (e) {
      if (mounted) _fail(e);
    }
  }

  String get _language => Localizations.localeOf(context).languageCode;

  void _fail(Object e) {
    final message = switch (e) {
      MovieException(:final message) => message,
      NasException(:final message) => message,
      TimeoutException() => context.l10n.moviesErrorTimeout,
      MovieEngineException(:final message) => context.l10n.moviesErrorPlay(message),
      _ => context.l10n.moviesErrorPlay('$e'),
    };
    setState(() {
      _error = message;
      _opening = false;
    });
  }

  Future<void> _openPlayer(Duration start) async {
    final server = _server!;
    final player = MoviePlayer(server.uri, engine: _engine);
    setState(() {
      _player = player;
      _opening = true;
    });
    player.state.addListener(_onState);
    try {
      // ExoPlayer gets less time: libmpv may still come after it.
      await player.open(
        start: start,
        timeout: movieFallsBackToMpv(player.engine) ? const Duration(seconds: 30) : const Duration(seconds: 45),
      );
    } catch (e) {
      if (!mounted || _player != player) return;
      if (!movieFallsBackToMpv(player.engine)) rethrow;
      debugPrint('MoviePlayerScreen: ExoPlayer failed ($e) - libmpv');
      return _fallBackToMpv(start);
    }
    if (!mounted || _player != player) return;
    setState(() => _opening = false);
    _showOsd();
  }

  /// ExoPlayer couldn't open or play the film (unknown container, no
  /// decoder for its picture, an error while playing): libmpv takes it on
  /// at [position] - the stream server hands it the bytes as they are on
  /// the NAS (no ExoPlayer preparation of DVD sound or M2TS).
  Future<void> _fallBackToMpv(Duration position) async {
    final old = _player;
    final server = _server;
    final prepared = _prepared;
    if (old == null || server == null || prepared == null || _switchingEngine) return;
    _switchingEngine = true;
    try {
      old.state.removeListener(_onState);
      setState(() {
        _player = null;
        _opening = true;
        _engine = MovieEngine.mpv;
      });
      await old.dispose();
      if (!mounted) return;
      server.replaceSource(prepared.sourceFor(audio: _dvdAudio, exoPlayer: false));
      await _openPlayer(position);
    } finally {
      _switchingEngine = false;
    }
  }

  void _onState() {
    final player = _player;
    if (player == null || !mounted) return;
    final s = player.state.value;
    if (s.error != null && _error == null) {
      if (movieFallsBackToMpv(player.engine)) {
        final position = s.position;
        unawaited(_fallBackToMpv(position).catchError((Object e) {
          if (mounted) _fail(e);
        }));
        return;
      }
      _fail(context.l10n.moviesErrorPlay(s.error!));
      return;
    }
    if (s.completed && !_closing) {
      // Watched to the end: next time from the start.
      _closing = true;
      unawaited(_resume.forget(widget.movie.path));
      Future<void>.delayed(const Duration(seconds: 1), () {
        if (mounted) Navigator.of(context).maybePop();
      });
    }
    if (!s.playing && !_osd) setState(() => _osd = true);
  }

  Future<void> _savePosition(MoviePlayer player) async {
    if (_closing && player.state.value.completed) return;
    final s = player.state.value;
    if (s.duration <= Duration.zero && s.position <= Duration.zero) return;
    await _resume.save(widget.movie.path, s.position, s.duration);
  }

  Future<bool?> _askResume(Duration resume) => showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          backgroundColor: const Color(0xFF151A18),
          title: Text(context.l10n.moviesResumeTitle),
          content: Text(widget.movie.title, style: const TextStyle(fontSize: 18, color: Colors.white70)),
          actions: [
            OutlinedButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(context.l10n.moviesFromStart),
            ),
            FilledButton(
              autofocus: true,
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(context.l10n.moviesResumeFrom(formatMovieTime(resume))),
            ),
          ],
        ),
      );

  void _close() {
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  // --- On-screen display ---

  void _showOsd() {
    _osdTimer?.cancel();
    if (!_osd) setState(() => _osd = true);
    _osdTimer = Timer(const Duration(seconds: 4), () {
      final playing = _player?.state.value.playing ?? false;
      if (mounted && playing && _seekTarget == null) setState(() => _osd = false);
    });
  }

  // --- Keys ---

  static final _okKeys = {
    LogicalKeyboardKey.select,
    LogicalKeyboardKey.enter,
    LogicalKeyboardKey.numpadEnter,
    LogicalKeyboardKey.gameButtonA,
    LogicalKeyboardKey.space,
    LogicalKeyboardKey.mediaPlayPause,
  };

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    final player = _player;
    // Back / Esc: PopScope.
    if (key == LogicalKeyboardKey.escape || key == LogicalKeyboardKey.goBack || key == LogicalKeyboardKey.browserBack) {
      return KeyEventResult.ignored;
    }
    if (key == LogicalKeyboardKey.mediaStop) {
      _close();
      return KeyEventResult.handled;
    }
    if (player == null || _opening || _error != null) {
      return _okKeys.contains(key) ? KeyEventResult.handled : KeyEventResult.ignored;
    }
    final repeat = event is KeyRepeatEvent;
    if (key == LogicalKeyboardKey.arrowLeft || key == LogicalKeyboardKey.mediaRewind) {
      _seekBy(-1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowRight || key == LogicalKeyboardKey.mediaFastForward) {
      _seekBy(1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp ||
        key == LogicalKeyboardKey.mediaTrackNext ||
        key == LogicalKeyboardKey.channelUp ||
        key == LogicalKeyboardKey.pageUp) {
      if (!repeat) _jump(1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowDown ||
        key == LogicalKeyboardKey.mediaTrackPrevious ||
        key == LogicalKeyboardKey.channelDown ||
        key == LogicalKeyboardKey.pageDown) {
      if (!repeat) _jump(-1);
      return KeyEventResult.handled;
    }
    if (repeat) return KeyEventResult.handled;
    if (_okKeys.contains(key)) {
      _togglePlay();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.mediaPlay) {
      player.play();
      _showOsd();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.mediaPause) {
      player.pause();
      _showOsd();
      return KeyEventResult.handled;
    }
    final keys = ref.read(remoteKeysProvider);
    if (key == LogicalKeyboardKey.contextMenu ||
        keys.matches(RemoteAction.options, key) ||
        keys.matches(RemoteAction.audio, key) ||
        keys.matches(RemoteAction.guide, key)) {
      _openOptions();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _togglePlay() {
    final player = _player;
    if (player == null) return;
    player.state.value.playing ? player.pause() : player.play();
    _showOsd();
  }

  Duration get _position => _seekTarget ?? _player?.state.value.position ?? Duration.zero;

  Duration _clamp(Duration target) {
    final duration = _player?.state.value.duration ?? Duration.zero;
    if (target < Duration.zero) return Duration.zero;
    if (duration > Duration.zero && target > duration - const Duration(seconds: 2)) {
      return duration - const Duration(seconds: 2);
    }
    return target;
  }

  /// ◀ / ▶: the presses add up (one seek when they stop) - faster the more
  /// come in a row.
  void _seekBy(int direction) {
    final now = DateTime.now();
    final inARow = direction == _seekDirection && now.difference(_lastSeek) < const Duration(milliseconds: 1500);
    _seekPresses = inARow ? _seekPresses + 1 : 0;
    _seekDirection = direction;
    _lastSeek = now;
    _setSeekTarget(_position + movieSeekStep(_seekPresses) * direction);
  }

  void _jump(int direction) {
    _seekPresses = 0;
    _seekDirection = 0;
    _setSeekTarget(movieJumpTarget(_position, direction, _prepared?.dvd?.chapters ?? const []));
  }

  void _setSeekTarget(Duration target) {
    setState(() => _seekTarget = _clamp(target));
    _showOsd();
    _seekTimer?.cancel();
    _seekTimer = Timer(const Duration(milliseconds: 700), _commitSeek);
  }

  Future<void> _commitSeek() async {
    final target = _seekTarget;
    final player = _player;
    if (target == null || player == null) return;
    await player.seekTo(target);
    if (!mounted) return;
    // Until the player reports the new place.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    if (mounted && _seekTarget == target) setState(() => _seekTarget = null);
    _showOsd();
  }

  // --- Sound and subtitles ---

  List<TvAudioTrack> _dvdTracks() {
    final prepared = _prepared;
    if (prepared == null) return const [];
    return [
      for (final (i, a) in prepared.playableAudio(exoPlayer: _exo).indexed)
        TvAudioTrack(
          id: a.id,
          label: [
            audioTrackName(a.language, null, i),
            if (a.extension == 2) context.l10n.moviesAudioDescription,
            if (a.extension == 3 || a.extension == 4) context.l10n.moviesAudioComments,
          ].join(' · '),
          details: audioDetails(a.codecName, a.channels),
          selected: a == _dvdAudio,
        ),
    ];
  }

  Future<void> _openOptions() async {
    final player = _player;
    if (player == null) return;
    final dvd = _prepared?.isDvdStream ?? false;
    final tracks = dvd ? _dvdTracks() : await player.audioTracks();
    if (!mounted) return;
    final subtitles = widget.movie.subtitles;
    final choice = await showDialog<String>(
      context: context,
      builder: (context) {
        Widget row({required String label, String? details, required bool selected, required String value}) => TvRow(
              autofocus: selected,
              selected: selected,
              onTap: () => Navigator.of(context).pop(value),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                child: Row(
                  children: [
                    Icon(selected ? Icons.radio_button_checked : Icons.radio_button_off,
                        color: selected ? brandGreen : Colors.white54),
                    const SizedBox(width: 14),
                    Flexible(child: Text(label, style: const TextStyle(fontSize: 18))),
                    if (details != null) ...[
                      const SizedBox(width: 12),
                      Text(details, style: const TextStyle(color: Colors.white54, fontSize: 15)),
                    ],
                  ],
                ),
              ),
            );
        Widget heading(String text) => Padding(
              padding: const EdgeInsets.fromLTRB(24, 16, 24, 6),
              child: Text(text, style: const TextStyle(color: Colors.white54, fontSize: 15, fontWeight: FontWeight.w600)),
            );
        return SimpleDialog(
          title: Text(context.l10n.moviesOptions),
          children: [
            heading(context.l10n.moviesAudio),
            if (tracks.length < 2)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
                child: Text(
                  tracks.isEmpty ? context.l10n.moviesNoAudioChoice : '${tracks.single.label}  ${tracks.single.details ?? ''}',
                  style: const TextStyle(fontSize: 16, color: Colors.white70),
                ),
              )
            else
              for (final t in tracks) row(label: t.label, details: t.details, selected: t.selected, value: 'a:${t.id}'),
            if (subtitles.isNotEmpty) ...[
              heading(context.l10n.moviesSubtitles),
              row(label: context.l10n.moviesSubtitlesOff, selected: _subtitlePath == null, value: 's:'),
              for (final path in subtitles)
                row(label: path.split('/').last, selected: _subtitlePath == path, value: 's:$path'),
            ],
          ],
        );
      },
    );
    if (choice == null || !mounted || _player != player) return;
    if (choice.startsWith('a:')) {
      final id = choice.substring(2);
      if (dvd) {
        final stream = _prepared!.dvdAudio.where((a) => a.id == id).firstOrNull;
        if (stream != null && stream != _dvdAudio) await _switchDvdAudio(stream);
      } else {
        await player.selectAudio(id);
      }
    } else if (choice.startsWith('s:')) {
      await _setSubtitles(choice.length > 2 ? choice.substring(2) : null);
    }
    _showOsd();
  }

  /// A DVD's other sound track: the stream server hands out the new one,
  /// the player opens again at the same place.
  Future<void> _switchDvdAudio(DvdAudioStream stream) async {
    final old = _player;
    final server = _server;
    final prepared = _prepared;
    if (old == null || server == null || prepared == null) return;
    final position = old.state.value.position;
    old.state.removeListener(_onState);
    setState(() {
      _player = null;
      _dvdAudio = stream;
    });
    await old.dispose();
    server.replaceSource(prepared.sourceFor(audio: stream, exoPlayer: _exo));
    try {
      await _openPlayer(position);
    } catch (e) {
      if (mounted) _fail(e);
    }
  }

  /// The subtitles of [path] (an .srt next to the film), or none.
  Future<void> _setSubtitles(String? path) async {
    if (path == null) {
      setState(() {
        _subtitlePath = null;
        _captions = const [];
      });
      return;
    }
    try {
      final bytes = await _client.read(path, maxBytes: 4 << 20);
      final captions = SubRipCaptionFile(decodeFtpText(bytes)).captions.toList()
        ..sort((a, b) => a.start.compareTo(b.start));
      if (!mounted) return;
      setState(() {
        _subtitlePath = path;
        _captions = captions;
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(context.l10n.moviesErrorPlay('$e'))));
      }
    }
  }

  /// Subtitles in the app's language switch on by themselves (the first
  /// file is the best match, see subtitlesIn).
  void _autoSubtitles() {
    final first = widget.movie.subtitles.first.toLowerCase();
    final codes = _language == 'de' ? const ['.de.', '.ger.', '.deu.', '.german.'] : const ['.en.', '.eng.', '.english.'];
    if (codes.any(first.contains)) _setSubtitles(widget.movie.subtitles.first);
  }

  String? _captionAt(Duration position) {
    final captions = _captions;
    if (captions.isEmpty) return null;
    var lo = 0, hi = captions.length - 1, found = -1;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      if (captions[mid].start <= position) {
        found = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    if (found < 0) return null;
    final c = captions[found];
    return position <= c.end ? c.text : null;
  }

  // --- Build ---

  @override
  Widget build(BuildContext context) {
    final player = _player;
    return PopScope(
      canPop: true,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) _closing = true;
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Focus(
          focusNode: _focus,
          autofocus: true,
          onKeyEvent: _onKey,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => _osd ? _togglePlay() : _showOsd(),
            onDoubleTap: _openOptions,
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (player != null) player.view(),
                if (player != null && _captions.isNotEmpty)
                  ValueListenableBuilder(
                    valueListenable: player.state,
                    builder: (context, s, _) => _Subtitle(text: _captionAt(s.position), raised: _osd),
                  ),
                if (_error != null)
                  _ErrorView(message: _error!, onBack: _close)
                else if (_opening)
                  _Opening(title: widget.movie.title)
                else if (player != null)
                  ValueListenableBuilder(
                    valueListenable: player.state,
                    builder: (context, s, _) => Stack(
                      fit: StackFit.expand,
                      children: [
                        if (s.buffering) const Center(child: CircularProgressIndicator()),
                        AnimatedOpacity(
                          opacity: _osd || !s.playing || _seekTarget != null ? 1 : 0,
                          duration: const Duration(milliseconds: 250),
                          child: _Osd(
                            title: widget.movie.title,
                            state: s,
                            seekTarget: _seekTarget,
                            chapters: _prepared?.dvd?.chapters ?? const [],
                            dvd: _prepared?.isDvdStream ?? false,
                            onRewind: () => _seekBy(-1),
                            onPlayPause: _togglePlay,
                            onForward: () => _seekBy(1),
                            onOptions: _openOptions,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Opening extends StatelessWidget {
  const _Opening({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Colors.black54,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 20),
            Text(title, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Text(context.l10n.moviesOpening, style: const TextStyle(fontSize: 16, color: Colors.white60)),
          ],
        ),
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message, required this.onBack});

  final String message;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Colors.black87,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 680),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, size: 56, color: Colors.white54),
              const SizedBox(height: 16),
              Text(message, textAlign: TextAlign.center, style: const TextStyle(fontSize: 18)),
              const SizedBox(height: 24),
              FilledButton(autofocus: true, onPressed: onBack, child: Text(context.l10n.moviesBack)),
            ],
          ),
        ),
      ),
    );
  }
}

class _Subtitle extends StatelessWidget {
  const _Subtitle({required this.text, required this.raised});

  final String? text;
  final bool raised;

  @override
  Widget build(BuildContext context) {
    final t = text;
    if (t == null || t.trim().isEmpty) return const SizedBox.shrink();
    // SRT's <i>, <b> and {\an8} are left out.
    final plain = t.replaceAll(RegExp(r'<[^>]*>|\{\\[^}]*\}'), '');
    const style = TextStyle(fontSize: 30, height: 1.25, fontWeight: FontWeight.w600);
    return Align(
      alignment: Alignment.bottomCenter,
      child: Padding(
        padding: EdgeInsets.fromLTRB(80, 0, 80, raised ? 170 : 48),
        child: Stack(
          children: [
            Text(
              plain,
              textAlign: TextAlign.center,
              style: style.copyWith(
                foreground: Paint()
                  ..style = PaintingStyle.stroke
                  ..strokeWidth = 5
                  ..color = Colors.black,
              ),
            ),
            Text(plain, textAlign: TextAlign.center, style: style.copyWith(color: Colors.white)),
          ],
        ),
      ),
    );
  }
}

/// Title, progress, times and the keys - at the bottom over a shade.
class _Osd extends ConsumerWidget {
  const _Osd({
    required this.title,
    required this.state,
    required this.seekTarget,
    required this.chapters,
    required this.dvd,
    required this.onRewind,
    required this.onPlayPause,
    required this.onForward,
    required this.onOptions,
  });

  final String title;
  final MoviePlaybackState state;
  final Duration? seekTarget;
  final List<Duration> chapters;
  final bool dvd;
  final VoidCallback onRewind;
  final VoidCallback onPlayPause;
  final VoidCallback onForward;
  final VoidCallback onOptions;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final position = seekTarget ?? state.position;
    final duration = state.duration;
    final fraction = duration > Duration.zero ? (position.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0) : null;
    var chapter = 0;
    for (var i = 0; i < chapters.length; i++) {
      if (chapters[i] <= position + const Duration(milliseconds: 500)) chapter = i;
    }
    final keys = ref.watch(remoteKeysProvider);
    final hint = context.l10n.moviesKeyHint(
      chapters.length > 1 ? context.l10n.moviesJumpChapters : context.l10n.moviesJumpMinutes,
      remoteKeyHint(keys, RemoteAction.options),
    );
    final delta = seekTarget == null ? null : seekTarget! - state.position;
    return Stack(
      fit: StackFit.expand,
      children: [
        if (delta != null)
          Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
              decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(14)),
              child: Text(
                '${delta.isNegative ? '−' : '+'}${formatMovieTime(delta.abs())}',
                style: const TextStyle(fontSize: 34, fontWeight: FontWeight.w600),
              ),
            ),
          )
        else if (!state.playing && !state.buffering)
          const Center(child: Icon(Icons.pause_circle_outline, size: 96, color: Colors.white70)),
        Align(
          alignment: Alignment.bottomCenter,
          child: Container(
            padding: const EdgeInsets.fromLTRB(48, 60, 48, 28),
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Colors.transparent, Color(0xDD000000)],
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Expanded(
                      child: Text(title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w600)),
                    ),
                    if (chapters.length > 1)
                      Text(context.l10n.moviesChapter(chapter + 1, chapters.length),
                          style: const TextStyle(fontSize: 16, color: Colors.white70)),
                  ],
                ),
                if (dvd)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(context.l10n.moviesDvdNote, style: const TextStyle(fontSize: 14, color: Colors.white38)),
                  ),
                const SizedBox(height: 14),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: fraction,
                    minHeight: 8,
                    color: brandGreen,
                    backgroundColor: Colors.white24,
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Text(formatMovieTime(position), style: const TextStyle(fontSize: 18)),
                    const SizedBox(width: 6),
                    if (duration > Duration.zero)
                      Text('/ ${formatMovieTime(duration)}', style: const TextStyle(fontSize: 18, color: Colors.white60)),
                    const Spacer(),
                    // For touch and the mouse - the remote has its keys.
                    ExcludeFocus(
                      child: Row(
                        children: [
                          IconButton(onPressed: onRewind, icon: const Icon(Icons.replay_10), iconSize: 30),
                          IconButton(
                            onPressed: onPlayPause,
                            icon: Icon(state.playing ? Icons.pause : Icons.play_arrow),
                            iconSize: 36,
                          ),
                          IconButton(onPressed: onForward, icon: const Icon(Icons.forward_10), iconSize: 30),
                          IconButton(onPressed: onOptions, icon: const Icon(Icons.tune), iconSize: 28),
                        ],
                      ),
                    ),
                  ],
                ),
                Text(hint, style: const TextStyle(fontSize: 14, color: Colors.white38)),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
