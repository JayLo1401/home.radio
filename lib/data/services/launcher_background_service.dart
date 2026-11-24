import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'nas_picture_cache.dart';
import '../../l10n/l10n.dart';

/// Fetches the launcher's next background picture (as bytes - shown via
/// MemoryImage, so a server answering one address with a different picture
/// each time isn't stuck in Flutter's image cache).
///
/// The own server ([fromServer]) may answer its address with
/// - a picture itself (e.g. a "random wallpaper" script),
/// - a JSON list of picture addresses (`["a.jpg", ...]`, or
///   `{"images": [...]}`; entries may also be `{"url": "..."}`),
/// - an HTML page linking pictures, e.g. a plain directory listing of nginx,
///   Apache or `python -m http.server` on a folder of wallpapers.
/// Relative addresses count from the server's address.
///
/// The address [nasAddress] stands for the NAS pictures folder (Settings →
/// NAS) instead: pictures from [nasPictures]' local cache.
class LauncherBackgroundService {
  LauncherBackgroundService({http.Client? client, Random? random, this.nasPictures})
      : _client = client ?? http.Client(),
        _random = random ?? Random();

  final http.Client _client;
  final Random _random;

  /// The NAS pictures folder's cache - for the address [nasAddress].
  final NasPictureCache? nasPictures;

  /// The own server's address meaning "the NAS pictures folder".
  static const nasAddress = 'nas:';

  static bool isNasAddress(String address) => address.trim() == nasAddress;
  static const _timeout = Duration(seconds: 20);

  List<({String url, String caption})> _bingImages = const [];
  DateTime? _bingLoadedAt;

  /// A landscape/nature photo: one of Bing's recent pictures of the day
  /// (about 15, refreshed every few hours), with its caption ("Hallstatt,
  /// Österreich (© ...)") for the credit line.
  Future<({Uint8List bytes, String caption})?> randomPhoto() async {
    final loadedAt = _bingLoadedAt;
    if (_bingImages.isEmpty || loadedAt == null || DateTime.now().difference(loadedAt) > const Duration(hours: 6)) {
      final images = <({String url, String caption})>[];
      for (final idx in const [0, 7]) {
        // The pictures' captions in the app's language.
        final market = l10n.localeName == 'de' ? 'de-DE' : 'en-US';
        final uri = Uri.parse('https://www.bing.com/HPImageArchive.aspx?format=js&idx=$idx&n=8&mkt=$market');
        final response = await _client.get(uri).timeout(_timeout);
        if (response.statusCode != 200) continue;
        for (final image in parseBingArchive(utf8.decode(response.bodyBytes, allowMalformed: true))) {
          if (!images.any((i) => i.url == image.url)) images.add(image);
        }
      }
      if (images.isNotEmpty) {
        _bingImages = images;
        _bingLoadedAt = DateTime.now();
      }
    }
    if (_bingImages.isEmpty) return null;
    final pick = _bingImages[_random.nextInt(_bingImages.length)];
    final bytes = await _image(Uri.parse(pick.url));
    return bytes == null ? null : (bytes: bytes, caption: pick.caption);
  }

  Future<Uint8List?> fromServer(String address) async {
    if (isNasAddress(address)) return nasPictures?.next();
    final uri = Uri.tryParse(address.trim());
    if (uri == null || !uri.scheme.startsWith('http')) return null;
    final response = await _client.get(uri).timeout(_timeout);
    if (response.statusCode != 200) return null;
    final type = response.headers['content-type'] ?? '';
    if (type.startsWith('image/')) return response.bodyBytes;
    final candidates = extractImageUrls(utf8.decode(response.bodyBytes, allowMalformed: true), type, directoryBase(uri));
    if (candidates.isEmpty) return null;
    return _image(candidates[_random.nextInt(candidates.length)]);
  }

  Future<Uint8List?> _image(Uri uri) async {
    final response = await _client.get(uri).timeout(_timeout);
    if (response.statusCode != 200) return null;
    final type = response.headers['content-type'] ?? '';
    if (type.isNotEmpty && !type.startsWith('image/') && !type.startsWith('application/octet-stream')) return null;
    return response.bodyBytes;
  }
}

/// Words in a Bing caption that mean the picture is about people, events or
/// buildings rather than landscape or nature - those are left out.
final _notLandscape = RegExp(
  r'\b(schüler\w*|kinder\w*|kind|menschen|mensch|leute|frau\w*|mann|männer|familie\w*|besucher\w*|'
  r'tänzer\w*|musiker\w*|sportler\w*|fest\w*|feier\w*|parade\w*|karneval\w*|markt\w*|mauer|denkmal\w*|'
  r'statue\w*|museum\w*|stadion\w*|konzert\w*|festival\w*)\b',
  caseSensitive: false,
  unicode: true,
);

bool isLandscapeCaption(String caption) => !_notLandscape.hasMatch(caption.split('(©').first);

/// Bing's picture-of-the-day archive (format=js): full-HD address and
/// caption of each landscape/nature picture.
List<({String url, String caption})> parseBingArchive(String body) {
  try {
    final decoded = jsonDecode(body);
    final images = decoded is Map ? decoded['images'] : null;
    if (images is! List) return const [];
    return [
      for (final i in images.whereType<Map>())
        if (i['urlbase'] is String && (i['urlbase'] as String).isNotEmpty)
          (
            url: 'https://www.bing.com${i['urlbase']}_1920x1080.jpg',
            caption: (i['copyright'] as String? ?? i['title'] as String? ?? '').trim(),
          ),
    ].where((i) => isLandscapeCaption(i.caption)).toList();
  } catch (_) {
    return const [];
  }
}

/// "http://nas/wallpapers" is a folder (the server redirects it to
/// ".../wallpapers/"), so "a.jpg" in its listing means ".../wallpapers/a.jpg"
/// - a last path part without a dot counts as a folder.
Uri directoryBase(Uri uri) {
  final segments = uri.pathSegments;
  if (segments.isEmpty || uri.path.endsWith('/') || segments.last.contains('.')) return uri;
  return uri.replace(path: '${uri.path}/');
}

final _imageExtension =RegExp(r'\.(jpe?g|png|webp|gif|bmp)(\?.*)?$', caseSensitive: false);
final _href = RegExp(r'''(?:href|src)\s*=\s*["']([^"'#]+)["']''', caseSensitive: false);

/// The picture addresses in a server's answer (JSON list or HTML page, see
/// [LauncherBackgroundService]), resolved against [base].
List<Uri> extractImageUrls(String body, String contentType, Uri base) {
  final found = <String>[];
  final trimmed = body.trimLeft();
  if (contentType.contains('json') || trimmed.startsWith('[') || trimmed.startsWith('{')) {
    try {
      var decoded = jsonDecode(body);
      if (decoded is Map) decoded = decoded['images'] ?? decoded['urls'] ?? decoded['files'];
      if (decoded is List) {
        for (final e in decoded) {
          final url = e is String ? e : (e is Map ? (e['url'] ?? e['src']) : null);
          if (url is String && url.isNotEmpty) found.add(url);
        }
      }
    } catch (_) {}
  }
  if (found.isEmpty) {
    for (final m in _href.allMatches(body)) {
      final url = m.group(1)!;
      if (_imageExtension.hasMatch(Uri.decodeFull(url))) found.add(url);
    }
  }
  final result = <Uri>[];
  for (final url in found) {
    try {
      final resolved = base.resolve(url);
      if (resolved.scheme.startsWith('http') && !result.contains(resolved)) result.add(resolved);
    } catch (_) {}
  }
  return result;
}
