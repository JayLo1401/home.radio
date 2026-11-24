import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'nas_picture_cache.dart';
import '../../l10n/l10n.dart';

/// Fetches the launcher's next background picture (as bytes - shown via
/// MemoryImage): a Bing picture of the day ([randomPhoto]) or one from the
/// NAS background folder's local cache ([fromNas], Settings → NAS).
class LauncherBackgroundService {
  LauncherBackgroundService({http.Client? client, Random? random, this.nasPictures})
      : _client = client ?? http.Client(),
        _random = random ?? Random();

  final http.Client _client;
  final Random _random;

  /// The NAS background folder's cache.
  final NasPictureCache? nasPictures;

  /// What the background setting stores for "from the NAS" (before, an own
  /// HTTP server's address could go there - that's gone).
  static const nasAddress = 'nas:';
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

  /// The next picture from the NAS background folder.
  Future<Uint8List?> fromNas() async => nasPictures?.next();

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
  r'statue\w*|museum\w*|stadion\w*|konzert\w*|festival\w*|'
  // The same in English (captions in the app's language).
  r'pupils?|students?|children|child|kids?|people|person|wom[ae]n|m[ae]n|famil(y|ies)|visitors?|dancers?|'
  r'musicians?|athletes?|celebrations?|parades?|carnivals?|markets?|wall|monuments?|statues?|museums?|'
  r'stadiums?|concerts?|festivals?)\b',
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
