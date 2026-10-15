import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Reads a radio stream's current title ("artist - title") over its own
/// short-lived HTTP connection - the fallback for when just_audio's own
/// icyMetadataStream stays silent. Two kinds of stream are understood:
///
/// * Shoutcast/Icecast (`Icy-MetaData: 1`): reads only up to the first
///   metadata block (icy-metaint bytes of audio, typically 8-32 KB) and
///   then disconnects.
/// * HLS (`.m3u8`, e.g. Cadena 100): these carry no ICY metadata at all -
///   the title travels as an ID3 tag (TIT2/TPE1) at the start of each
///   audio segment instead, which just_audio doesn't surface either. The
///   playlist is fetched, then just the ID3 tag at the start of its newest
///   segment (a few KB), not the whole segment.
class IcyMetadataService {
  static const _timeout = Duration(seconds: 10);
  static const _maxPlaylistBytes = 256 * 1024;
  static const _maxId3Bytes = 256 * 1024;

  /// The stream's current title, or null if it has none, carries it in a
  /// way not understood here, or couldn't be reached.
  Future<String?> fetchStreamTitle(String url) async {
    final client = HttpClient()..connectionTimeout = _timeout;
    try {
      final uri = Uri.parse(url);
      final response = await _get(client, uri, icy: true);
      if (response.statusCode != 200) return null;
      final metaInt = int.tryParse(response.headers.value('icy-metaint') ?? '');
      if (metaInt != null && metaInt > 0) {
        final block = await _readFirstMetadataBlock(response, metaInt).timeout(_timeout);
        return block == null ? null : parseStreamTitle(block);
      }
      if (_looksLikeHls(uri, response.headers.contentType)) {
        final playlist = await _readText(response);
        return await _titleFromHls(client, _finalUri(uri, response), playlist, depth: 0);
      }
      return null;
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  Future<HttpClientResponse> _get(HttpClient client, Uri uri, {bool icy = false}) async {
    final request = await client.getUrl(uri).timeout(_timeout);
    if (icy) request.headers.set('Icy-MetaData', '1');
    request.headers.set(HttpHeaders.userAgentHeader, 'home_radio/1.0');
    return request.close().timeout(_timeout);
  }

  /// Where the response actually came from after redirects - relative
  /// segment/variant URIs in a playlist resolve against that, not against
  /// the URL originally requested.
  Uri _finalUri(Uri requested, HttpClientResponse response) {
    var uri = requested;
    for (final redirect in response.redirects) {
      uri = uri.resolveUri(redirect.location);
    }
    return uri;
  }

  bool _looksLikeHls(Uri uri, ContentType? contentType) {
    final mime = contentType?.mimeType.toLowerCase() ?? '';
    return uri.path.toLowerCase().endsWith('.m3u8') || mime.contains('mpegurl');
  }

  Future<String> _readText(Stream<List<int>> body) async {
    final buffer = BytesBuilder();
    await for (final chunk in body.timeout(_timeout)) {
      buffer.add(chunk);
      if (buffer.length > _maxPlaylistBytes) break;
    }
    return utf8.decode(buffer.takeBytes(), allowMalformed: true);
  }

  Future<String?> _titleFromHls(HttpClient client, Uri base, String playlist, {required int depth}) async {
    if (!playlist.trimLeft().startsWith('#EXTM3U') || depth > 2) return null;
    final lines = const LineSplitter().convert(playlist).map((l) => l.trim()).toList();
    final uris = [
      for (final line in lines)
        if (line.isNotEmpty && !line.startsWith('#')) line,
    ];
    if (uris.isEmpty) return null;

    // Master playlist: every variant carries the same title - follow the
    // first one to its media playlist.
    if (lines.any((l) => l.startsWith('#EXT-X-STREAM-INF'))) {
      final variant = base.resolve(uris.first);
      final response = await _get(client, variant);
      if (response.statusCode != 200) return null;
      final text = await _readText(response);
      return _titleFromHls(client, _finalUri(variant, response), text, depth: depth + 1);
    }

    // Media playlist: the newest segment carries the current title.
    final segment = base.resolve(uris.last);
    final response = await _get(client, segment);
    if (response.statusCode != 200) return null;
    final tag = await _readId3Chain(response).timeout(_timeout);
    return tag == null ? null : parseId3Title(tag);
  }

  /// Reads just the ID3 tag(s) at the very start of an audio segment -
  /// stops as soon as they're complete instead of downloading the audio.
  Future<Uint8List?> _readId3Chain(Stream<List<int>> body) async {
    final buffer = BytesBuilder();
    await for (final chunk in body) {
      buffer.add(chunk);
      final bytes = buffer.toBytes();
      final length = _id3ChainLength(bytes);
      if (length == 0) return null; // no ID3 tag at all
      if (length != null) return Uint8List.sublistView(bytes, 0, length);
      if (bytes.length > _maxId3Bytes) return null;
    }
    final bytes = buffer.toBytes();
    final length = _id3ChainLength(bytes, complete: true);
    return length == null || length == 0 ? null : Uint8List.sublistView(bytes, 0, length);
  }

  /// Total length of the consecutive ID3v2 tags at the start of [bytes]
  /// (HLS segments often carry two: a timestamp PRIV tag, then the title),
  /// 0 if there's none, or null if more bytes are needed to tell.
  /// With [complete] (the segment ended), whatever full tags are there
  /// count rather than waiting for more.
  static int? _id3ChainLength(Uint8List bytes, {bool complete = false}) {
    var offset = 0;
    while (true) {
      // Need at least "ID3" to tell whether another tag follows, and the
      // full 10-byte header to know its size.
      if (bytes.length < offset + 3) return complete ? offset : null;
      if (!_isId3At(bytes, offset)) return offset;
      if (bytes.length < offset + 10) return complete ? offset : null;
      final hasFooter = bytes[offset + 5] & 0x10 != 0;
      final end = offset + 10 + _synchsafe(bytes, offset + 6) + (hasFooter ? 10 : 0);
      if (bytes.length < end) return complete ? offset : null;
      offset = end;
    }
  }

  static bool _isId3At(Uint8List b, int o) => b[o] == 0x49 && b[o + 1] == 0x44 && b[o + 2] == 0x33; // "ID3"

  static int _synchsafe(Uint8List b, int o) =>
      (b[o] & 0x7f) << 21 | (b[o + 1] & 0x7f) << 14 | (b[o + 2] & 0x7f) << 7 | (b[o + 3] & 0x7f);

  /// "artist - title" from ID3v2.3/2.4 TPE1/TIT2 frames (or just the title,
  /// if that already contains the artist or there's none).
  static String? parseId3Title(Uint8List bytes) {
    String? title;
    String? artist;
    var offset = 0;
    while (bytes.length >= offset + 10 && _isId3At(bytes, offset)) {
      final version = bytes[offset + 3];
      final flags = bytes[offset + 5];
      final tagEnd = (offset + 10 + _synchsafe(bytes, offset + 6)).clamp(0, bytes.length);
      var p = offset + 10;
      if (flags & 0x40 != 0 && p + 4 <= tagEnd) {
        // Extended header - its size field includes itself in v2.4 only.
        final extSize = version == 4 ? _synchsafe(bytes, p) : ByteData.sublistView(bytes, p, p + 4).getUint32(0) + 4;
        p += extSize;
      }
      while (p + 10 <= tagEnd && bytes[p] != 0) {
        final id = ascii.decode(bytes.sublist(p, p + 4), allowInvalid: true);
        final frameSize = version == 4 ? _synchsafe(bytes, p + 4) : ByteData.sublistView(bytes, p + 4, p + 8).getUint32(0);
        final dataStart = p + 10;
        final dataEnd = dataStart + frameSize;
        if (frameSize <= 0 || dataEnd > tagEnd) break;
        if (id == 'TIT2') title = _decodeTextFrame(Uint8List.sublistView(bytes, dataStart, dataEnd));
        if (id == 'TPE1') artist = _decodeTextFrame(Uint8List.sublistView(bytes, dataStart, dataEnd));
        p = dataEnd;
      }
      offset = tagEnd + (flags & 0x10 != 0 ? 10 : 0);
    }
    title = cleanTitle(title);
    artist = cleanTitle(artist);
    if (title == null) return artist;
    if (artist == null || title.toLowerCase().contains(artist.toLowerCase())) return title;
    return '$artist - $title';
  }

  static String? _decodeTextFrame(Uint8List data) {
    if (data.isEmpty) return null;
    final encoding = data[0];
    final text = Uint8List.sublistView(data, 1);
    switch (encoding) {
      case 0:
        return latin1.decode(text, allowInvalid: true);
      case 3:
        return utf8.decode(text, allowMalformed: true);
      case 1:
      case 2:
        var bigEndian = encoding == 2;
        var start = 0;
        if (encoding == 1 && text.length >= 2) {
          if (text[0] == 0xFF && text[1] == 0xFE) {
            start = 2;
          } else if (text[0] == 0xFE && text[1] == 0xFF) {
            bigEndian = true;
            start = 2;
          }
        }
        final units = <int>[
          for (var i = start; i + 1 < text.length; i += 2)
            bigEndian ? text[i] << 8 | text[i + 1] : text[i + 1] << 8 | text[i],
        ];
        return String.fromCharCodes(units);
      default:
        return null;
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
