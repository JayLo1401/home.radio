import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Reads the current "StreamTitle" (artist - title) straight from a
/// Shoutcast/Icecast stream, over its own short-lived HTTP connection with
/// `Icy-MetaData: 1` - the fallback for when just_audio's own
/// icyMetadataStream stays silent (it depends on the platform player
/// actually requesting/forwarding ICY metadata, which doesn't happen for
/// every stream/redirect setup). Reads only up to the first metadata block
/// (icy-metaint bytes of audio, typically 8-32 KB) and then disconnects.
class IcyMetadataService {
  static const _timeout = Duration(seconds: 10);

  /// The stream's current title, or null if it has none, doesn't support
  /// ICY metadata at all, or couldn't be reached.
  Future<String?> fetchStreamTitle(String url) async {
    final client = HttpClient()..connectionTimeout = _timeout;
    try {
      final request = await client.getUrl(Uri.parse(url)).timeout(_timeout);
      request.headers.set('Icy-MetaData', '1');
      request.headers.set(HttpHeaders.userAgentHeader, 'home_radio/1.0');
      final response = await request.close().timeout(_timeout);
      final metaInt = int.tryParse(response.headers.value('icy-metaint') ?? '');
      if (response.statusCode != 200 || metaInt == null || metaInt <= 0) return null;
      final block = await _readFirstMetadataBlock(response, metaInt).timeout(_timeout);
      return block == null ? null : parseStreamTitle(block);
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  Future<Uint8List?> _readFirstMetadataBlock(Stream<List<int>> body, int metaInt) async {
    final buffer = BytesBuilder();
    await for (final chunk in body) {
      buffer.add(chunk);
      if (buffer.length <= metaInt) continue;
      final bytes = buffer.toBytes();
      final metaLength = bytes[metaInt] * 16;
      if (metaLength == 0) return Uint8List(0);
      final end = metaInt + 1 + metaLength;
      if (bytes.length >= end) return Uint8List.sublistView(bytes, metaInt + 1, end);
      // Otherwise keep reading until the whole metadata block is in.
    }
    return null;
  }

  /// Extracts StreamTitle='...'; from a raw ICY metadata block - stations
  /// send it as UTF-8 or Latin-1 with no way to tell which, so UTF-8 is
  /// tried first and Latin-1 used if that doesn't decode cleanly.
  static String? parseStreamTitle(List<int> block) {
    String text;
    try {
      text = utf8.decode(block);
    } on FormatException {
      text = latin1.decode(block, allowInvalid: true);
    }
    final match = RegExp(r"StreamTitle='(.*?)';", dotAll: true).firstMatch(text);
    return cleanTitle(match?.group(1));
  }

  /// Normalizes a stream title for display - null for the placeholder
  /// values some stations send between songs (empty, just "-").
  static String? cleanTitle(String? title) {
    final trimmed = title?.replaceAll('\u0000', '').trim();
    if (trimmed == null || trimmed.isEmpty || RegExp(r'^[-\s]*$').hasMatch(trimmed)) return null;
    return trimmed;
  }
}
