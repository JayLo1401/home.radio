import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show MethodChannel;
import 'package:media_kit/media_kit.dart' as mk;
import 'package:media_kit_video/media_kit_video.dart' as mkv;
import 'package:video_player/video_player.dart';

import '../../data/models/iptv_channel.dart' show IptvStreamFormat;
import '../../l10n/l10n.dart';

/// One sound track of the channel ("Deutsch", "Originalton", ...).
@immutable
class TvAudioTrack {
  const TvAudioTrack({required this.id, required this.label, this.details, this.selected = false});

  final String id;
  final String label;

  /// Format and channels, e.g. "Dolby Digital 5.1".
  final String? details;
  final bool selected;
}

/// What the picture and sound are - shown in the banner.
@immutable
class TvPlayerInfo {
  const TvPlayerInfo({
    this.width,
    this.height,
    this.aspect,
    this.interlaced,
    this.fps,
    this.videoCodec,
    this.audio = const [],
  });

  /// The picture as sent (SD: 720×576 or 704×576 - not square pixels).
  final int? width;
  final int? height;

  /// Its shape on the screen (width / height), e.g. 16:9 for anamorphic SD.
  final double? aspect;

  /// "16:9", "4:3", ...
  String? get aspectLabel {
    final a = aspect;
    if (a == null || a <= 0) return null;
    for (final (label, value) in const [('16:9', 16 / 9), ('4:3', 4 / 3), ('21:9', 64 / 27), ('5:4', 5 / 4)]) {
      if ((a - value).abs() < 0.04) return label;
    }
    return '${a.toStringAsFixed(2)}:1';
  }

  /// Half frames (1080i) - null if the player can't tell.
  final bool? interlaced;

  /// Frames per second of the stream.
  final double? fps;
  final String? videoCodec;
  final List<TvAudioTrack> audio;

  TvAudioTrack? get selectedAudio => audio.where((t) => t.selected).firstOrNull;

  /// "1920×1080i", "1280×720p" - or null before the first picture.
  String? get resolution {
    if (height == null || height == 0) return null;
    final scan = interlaced == null ? '' : (interlaced! ? 'i' : 'p');
    // Without the width as sent (Android): the lines.
    if (width == null || width == 0) return scan.isEmpty ? l10n.tvResolutionLines(height!) : '$height$scan';
    return '$width×$height$scan';
  }

  /// SD / HD / Full HD / UHD by the picture height.
  String? get grade => switch (height) {
        null => null,
        final h when h >= 2000 => 'UHD',
        final h when h >= 1000 => 'Full HD',
        final h when h >= 700 => 'HD',
        _ => 'SD',
      };

  /// Images per second as broadcast: half frames for interlaced ("50").
  String? get rate {
    final f = fps;
    if (f == null || f <= 0) return null;
    // Some 1080i streams state 25 frames, others already the 50 fields.
    final v = interlaced == true && f < 31 ? f * 2 : f;
    return v == v.roundToDouble() ? '${v.round()} Hz' : '${v.toStringAsFixed(2)} Hz';
  }
}

/// TV's player: the receiver's stream as it is (no transcoding), its
/// sound tracks and what the picture is. On Android ExoPlayer (video_player),
/// on the PC libmpv (media_kit) - with deinterlacing for 1080i.
abstract class TvPlayer {
  /// Android's API level (0 elsewhere) - [prepare] reads it once.
  static int _androidSdk = 0;

  /// Android's API level (0 elsewhere or before [prepare]) - the films'
  /// player picks its picture output by it, like TV.
  static int get androidSdk => _androidSdk;

  /// Called once on start (main): what [TvPlayer] needs to know about the
  /// device before the first channel.
  static Future<void> prepare() async {
    if (kIsWeb || !Platform.isAndroid) return;
    try {
      _androidSdk = await const MethodChannel('home_system/launcher').invokeMethod<int>('sdkInt') ?? 0;
    } catch (e) {
      debugPrint('TvPlayer.prepare: $e');
    }
  }

  /// [format]: how the stream is packaged, if the address doesn't say
  /// (Internet-TV's HLS / DASH) - ExoPlayer needs it, libmpv finds out.
  /// [broadcast]: the receiver's DVB stream (576/1080 lines at 25 frames
  /// are interlaced there) - not Internet-TV's.
  factory TvPlayer(Uri uri, Map<String, String> headers, {IptvStreamFormat? format, bool broadcast = true}) =>
      !kIsWeb && Platform.isAndroid
          ? _ExoTvPlayer(uri, headers, format)
          : _MpvTvPlayer(uri, headers, broadcast);

  /// Opens the stream; completes with the first picture, throws if none
  /// comes within [timeout].
  Future<void> start({Duration timeout = const Duration(seconds: 20)});

  /// The picture, fitted into the screen.
  Widget view();

  ValueListenable<TvPlayerInfo> get info;

  Future<void> selectAudio(String id);

  Future<void> dispose();
}

/// The PC: libmpv straight (media_kit) - every detail of the stream and its
/// tracks is there.
class _MpvTvPlayer implements TvPlayer {
  _MpvTvPlayer(this._uri, this._headers, this._broadcast);

  final Uri _uri;
  final Map<String, String> _headers;
  final bool _broadcast;
  final _player = mk.Player(configuration: const mk.PlayerConfiguration(title: 'TV'));
  late final _video = mkv.VideoController(_player);
  final _info = ValueNotifier(const TvPlayerInfo());
  final _subscriptions = <StreamSubscription<Object?>>[];
  bool? _interlaced;
  bool _disposed = false;

  mk.NativePlayer? get _native => _player.platform is mk.NativePlayer ? _player.platform as mk.NativePlayer : null;

  @override
  ValueListenable<TvPlayerInfo> get info => _info;

  @override
  Future<void> start({Duration timeout = const Duration(seconds: 20)}) async {
    _subscriptions
      ..add(_player.stream.tracks.listen((_) => _update()))
      ..add(_player.stream.track.listen((_) => _update()))
      ..add(_player.stream.videoParams.listen((_) => _update()));
    final native = _native;
    if (native != null) {
      // Live TV: a short look at the stream before the picture starts
      // (default: up to 5 s) - the receiver's MPEG-TS names every track in
      // its PMT right at the start.
      await native.setProperty('demuxer-lavf-analyzeduration', '0.6');
      // No disk cache for a live stream.
      await native.setProperty('cache-on-disk', 'no');
      // Interlaced pictures deinterlaced from the first frame on;
      // progressive ones (720p, UHD) pass untouched.
    }
    await _player.open(mk.Media(_uri.toString(), httpHeaders: _headers));
    await _video.waitUntilFirstFrameRendered.timeout(timeout);
    await _checkInterlaced();
    await _update();
  }

  /// 1080i and 576i come as half frames ("i" in the banner; deinterlaced
  /// where the libmpv can, see below), progressive pictures (720p50,
  /// 1080p50, UHD) as they are. mpv's own field flag doesn't always come
  /// through (hardware decoding), so DVB's rule decides as well: 576 or
  /// 1080 lines at 25 frames a second are interlaced.
  Future<void> _checkInterlaced() async {
    final native = _native;
    if (native == null) return;
    String? flag;
    double? fps;
    try {
      flag = await native.getProperty('video-frame-info/interlaced');
    } catch (_) {}
    try {
      fps = double.tryParse(await native.getProperty('container-fps'));
    } catch (_) {}
    final h = _player.state.videoParams.h ?? _player.state.height;
    final broadcastInterlaced = _broadcast &&
        fps != null && fps > 0 && fps < 31 && (h == 576 || h == 480 || h == 1080 || h == 1088);
    _interlaced = flag == 'yes' || broadcastInterlaced;
    // Linux: the system's libmpv has FFmpeg's deinterlacers. The libmpv
    // media_kit brings for Windows has none (no software filter, and its
    // graphics card ones need decoding it can't do with Flutter's output) -
    // there interlaced pictures show as they come.
    if (_interlaced! && Platform.isLinux) {
      try {
        await native.setProperty('deinterlace', 'yes');
      } catch (_) {}
    }
  }

  Future<void> _update() async {
    if (_disposed) return;
    final native = _native;
    var selectedAid = _player.state.track.audio.id;
    String? codec;
    double? fps;
    if (native != null) {
      try {
        selectedAid = await native.getProperty('aid');
        codec = await native.getProperty('video-format');
        fps = double.tryParse(await native.getProperty('container-fps'));
      } catch (_) {}
    }
    if (_disposed) return;
    final tracks = _player.state.tracks.audio.where((t) => t.id != 'auto' && t.id != 'no').toList();
    final params = _player.state.videoParams;
    final w = params.w ?? _player.state.width;
    final h = params.h ?? _player.state.height;
    final dw = params.dw, dh = params.dh;
    _info.value = TvPlayerInfo(
      width: w,
      height: h,
      // Display size: the pixel aspect of SD broadcasts applied.
      aspect: params.aspect ?? (dw != null && dh != null && dh > 0 ? dw / dh : null),
      interlaced: _interlaced,
      fps: fps,
      videoCodec: videoCodecName(codec),
      audio: [
        for (final (i, t) in tracks.indexed)
          TvAudioTrack(
            id: t.id,
            label: audioTrackName(t.language, t.title, i),
            details: audioDetails(t.codec, t.channelscount),
            selected: t.id == selectedAid,
          ),
      ],
    );
  }

  @override
  Future<void> selectAudio(String id) async {
    final track = _player.state.tracks.audio.where((t) => t.id == id).firstOrNull;
    if (track == null) return;
    await _player.setAudioTrack(track);
    await _update();
  }

  @override
  Widget view() => mkv.Video(
        controller: _video,
        controls: mkv.NoVideoControls,
        fill: Colors.black,
        // Scaled to the screen from the original resolution.
        filterQuality: FilterQuality.medium,
        pauseUponEnteringBackgroundMode: false,
      );

  @override
  Future<void> dispose() async {
    _disposed = true;
    for (final s in _subscriptions) {
      await s.cancel();
    }
    _info.dispose();
    await _player.dispose();
  }
}

/// Android: ExoPlayer (video_player) - its sound tracks, the picture size.
class _ExoTvPlayer implements TvPlayer {
  _ExoTvPlayer(Uri uri, Map<String, String> headers, IptvStreamFormat? format)
      : _controller = VideoPlayerController.networkUrl(
          uri,
          httpHeaders: headers,
          formatHint: switch (format) {
            IptvStreamFormat.hls => VideoFormat.hls,
            IptvStreamFormat.dash => VideoFormat.dash,
            null => null,
          },
          // Android 10+: ExoPlayer straight into a SurfaceView. The texture
          // (ImageReader) froze the picture on the Xiaomi box (Amlogic) when
          // the channel list or the guide opened: Flutter stopped taking its
          // frames, the decoder ran out of buffers - the sound played on.
          // Android 9 and older (Fire TV Stick, Fire OS 7) keep the texture:
          // there a platform view copies every frame of the whole UI through
          // main memory (everything crawled), and a full-screen page over it
          // (the guide) stayed hidden behind the picture.
          viewType: TvPlayer._androidSdk >= 29 ? VideoViewType.platformView : VideoViewType.textureView,
        );

  final VideoPlayerController _controller;
  final _info = ValueNotifier(const TvPlayerInfo());
  bool _disposed = false;
  List<TvAudioTrack> _audio = const [];

  @override
  ValueListenable<TvPlayerInfo> get info => _info;

  @override
  Future<void> start({Duration timeout = const Duration(seconds: 20)}) async {
    await _controller.initialize().timeout(timeout);
    await _controller.play();
    _controller.addListener(_publish);
    await _loadTracks();
  }

  Future<void> _loadTracks() async {
    if (_disposed || !_controller.isAudioTrackSupportAvailable()) return _publish();
    try {
      final tracks = await _controller.getAudioTracks();
      _audio = [
        for (final (i, t) in tracks.indexed)
          TvAudioTrack(
            id: t.id,
            label: audioTrackName(t.language, t.label, i),
            details: audioDetails(t.codec, t.channelCount),
            selected: t.isSelected,
          ),
      ];
    } catch (_) {}
    _publish();
  }

  void _publish() {
    if (_disposed) return;
    final size = _controller.value.size;
    // ExoPlayer reports the display size (pixel aspect already applied: SD
    // 720×576 comes as 1047×576) - so only the lines count.
    _info.value = TvPlayerInfo(
      height: size.height > 0 ? size.height.round() : null,
      aspect: size.height > 0 ? size.width / size.height : null,
      audio: _audio,
    );
  }

  @override
  Future<void> selectAudio(String id) async {
    await _controller.selectAudioTrack(id);
    await _loadTracks();
  }

  @override
  Widget view() => Center(
        child: AspectRatio(aspectRatio: _controller.value.aspectRatio, child: VideoPlayer(_controller)),
      );

  @override
  Future<void> dispose() async {
    _disposed = true;
    _controller.removeListener(_publish);
    _info.dispose();
    await _controller.dispose();
  }
}

/// mpv's / ExoPlayer's codec names as people know them.
String? videoCodecName(String? codec) {
  final c = codec?.toLowerCase();
  if (c == null || c.isEmpty) return null;
  if (c.contains('hevc') || c.contains('h265')) return 'HEVC';
  if (c.contains('h264') || c.contains('avc')) return 'H.264';
  if (c.contains('mpeg2')) return 'MPEG-2';
  return codec;
}

String? audioDetails(String? codec, int? channels) {
  final c = codec?.toLowerCase() ?? '';
  final name = switch (c) {
    _ when c.contains('eac3') || c.contains('e-ac-3') || c.contains('ec-3') => 'Dolby Digital Plus',
    _ when c.contains('ac3') || c.contains('ac-3') => 'Dolby Digital',
    _ when c.contains('aac') || c.contains('mp4a') => 'AAC',
    _ when c.contains('mp2') || c.contains('mpeg') => 'MPEG',
    _ when c.isEmpty => null,
    _ => codec,
  };
  final layout = switch (channels) {
    1 => 'Mono',
    2 => 'Stereo',
    6 => '5.1',
    8 => '7.1',
    null || <= 0 => null,
    _ => l10n.tvAudioChannels(channels),
  };
  final parts = [?name, ?layout];
  return parts.isEmpty ? null : parts.join(' ');
}

/// A track's name from its language code (DVB: ISO 639-2, "deu"/"ger",
/// "qaa" = original sound) and title; numbered if neither says anything.
String audioTrackName(String? language, String? title, int index) {
  final lang = language?.toLowerCase().trim();
  final named = switch (lang) {
    'deu' || 'ger' || 'de' => l10n.tvAudioLanguageGerman,
    'eng' || 'en' => l10n.tvAudioLanguageEnglish,
    'fra' || 'fre' || 'fr' => l10n.tvAudioLanguageFrench,
    'ita' || 'it' => l10n.tvAudioLanguageItalian,
    'spa' || 'es' => l10n.tvAudioLanguageSpanish,
    'tur' || 'tr' => l10n.tvAudioLanguageTurkish,
    'pol' || 'pl' => l10n.tvAudioLanguagePolish,
    'hrv' || 'srp' || 'bos' => l10n.tvAudioLanguageCroatianSerbian,
    'qaa' || 'mul' || 'orig' || 'org' => l10n.tvAudioOriginal,
    'qad' || 'dsc' => l10n.tvAudioDescription,
    'mis' || 'und' || '' || null => null,
    _ => lang.toUpperCase(),
  };
  final t = title?.trim();
  if (named != null && t != null && t.isNotEmpty && t.toLowerCase() != lang) return '$named ($t)';
  return named ?? (t != null && t.isNotEmpty ? t : l10n.tvAudioTrackNumber(index + 1));
}
