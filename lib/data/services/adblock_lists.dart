// The browser's ad/tracker blocker, part 3: the filter lists - which there
// are, downloading them (weekly), compiling them in the background and
// keeping the result for AdblockEngine.kt.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import 'adblock_compiler.dart';

/// One filter list the browser can use.
class FilterListInfo {
  const FilterListInfo({
    required this.id,
    required this.name,
    required this.urls,
    required this.license,
    required this.homepage,
    this.trusted = false,
    this.defaultOn = true,
    this.germanDefault = false,
  });

  final String id;
  final String name;

  /// Where to get it - the first that answers.
  final List<String> urls;
  final String license;
  final String homepage;

  /// uBlock Origin's own lists: their `trusted-*` scriptlets may run.
  final bool trusted;
  final bool defaultOn;

  /// On by default only on German-speaking devices.
  final bool germanDefault;
}

const _uAssets = 'https://ublockorigin.github.io/uAssetsCDN';
const _uAssetsJsDelivr = 'https://cdn.jsdelivr.net/gh/uBlockOrigin/uAssetsCDN@main';
const _gpl3 = 'GPLv3';
const _easyListLicense = 'GPLv3 / CC BY-SA 3.0';

/// The lists, as uBlock Origin has them by default (plus EasyList Germany).
const filterLists = <FilterListInfo>[
  FilterListInfo(
    id: 'ublock-filters',
    name: 'uBlock filters',
    urls: ['$_uAssets/filters/filters.min.txt', '$_uAssetsJsDelivr/filters/filters.min.txt'],
    license: _gpl3,
    homepage: 'https://github.com/uBlockOrigin/uAssets',
    trusted: true,
  ),
  FilterListInfo(
    id: 'ublock-quick-fixes',
    name: 'uBlock filters – Quick fixes',
    urls: ['$_uAssets/filters/quick-fixes.min.txt', '$_uAssetsJsDelivr/filters/quick-fixes.min.txt'],
    license: _gpl3,
    homepage: 'https://github.com/uBlockOrigin/uAssets',
    trusted: true,
  ),
  FilterListInfo(
    id: 'ublock-badware',
    name: 'uBlock filters – Badware risks',
    urls: ['$_uAssets/filters/badware.min.txt', '$_uAssetsJsDelivr/filters/badware.min.txt'],
    license: _gpl3,
    homepage: 'https://github.com/uBlockOrigin/uAssets',
    trusted: true,
  ),
  FilterListInfo(
    id: 'ublock-privacy',
    name: 'uBlock filters – Privacy',
    urls: ['$_uAssets/filters/privacy.min.txt', '$_uAssetsJsDelivr/filters/privacy.min.txt'],
    license: _gpl3,
    homepage: 'https://github.com/uBlockOrigin/uAssets',
    trusted: true,
  ),
  FilterListInfo(
    id: 'ublock-unbreak',
    name: 'uBlock filters – Unbreak',
    urls: ['$_uAssets/filters/unbreak.min.txt', '$_uAssetsJsDelivr/filters/unbreak.min.txt'],
    license: _gpl3,
    homepage: 'https://github.com/uBlockOrigin/uAssets',
    trusted: true,
  ),
  FilterListInfo(
    id: 'easylist',
    name: 'EasyList',
    urls: ['https://easylist.to/easylist/easylist.txt', '$_uAssets/thirdparties/easylist.txt'],
    license: _easyListLicense,
    homepage: 'https://easylist.to',
  ),
  FilterListInfo(
    id: 'easyprivacy',
    name: 'EasyPrivacy',
    urls: ['https://easylist.to/easylist/easyprivacy.txt', '$_uAssets/thirdparties/easyprivacy.txt'],
    license: _easyListLicense,
    homepage: 'https://easylist.to',
  ),
  FilterListInfo(
    id: 'easylist-germany',
    name: 'EasyList Germany',
    urls: ['https://easylist.to/easylistgermany/easylistgermany.txt'],
    license: _easyListLicense,
    homepage: 'https://easylist.to',
    defaultOn: false,
    germanDefault: true,
  ),
  FilterListInfo(
    id: 'peter-lowe',
    name: "Peter Lowe's Ad and tracking server list",
    urls: ['https://pgl.yoyo.org/adservers/serverlist.php?hostformat=hosts&showintro=1&mimetype=plaintext'],
    license: 'McRae GPL',
    homepage: 'https://pgl.yoyo.org/adservers/',
  ),
];

/// The lists on by default on a device with [languageCode].
Set<String> defaultFilterLists(String languageCode) => {
      for (final l in filterLists)
        if (l.defaultOn || (l.germanDefault && languageCode == 'de')) l.id,
    };

/// What the last update did.
class AdblockMeta {
  const AdblockMeta({required this.updated, required this.lists, required this.stats, required this.failed});

  final DateTime updated;

  /// The list ids the compiled filters were made of.
  final Set<String> lists;

  /// Lists that couldn't be downloaded (an older copy was used, if any).
  final Set<String> failed;
  final Map<String, int> stats;

  int get rules => (stats['hosts'] ?? 0) + (stats['patterns'] ?? 0) + (stats['cosmetic'] ?? 0) + (stats['scriptlets'] ?? 0);

  Map<String, Object?> toJson() => {
        'updated': updated.toIso8601String(),
        'lists': lists.toList(),
        'failed': failed.toList(),
        'stats': stats,
      };

  static AdblockMeta? fromJson(Object? json) {
    if (json is! Map) return null;
    final updated = DateTime.tryParse('${json['updated']}');
    if (updated == null) return null;
    return AdblockMeta(
      updated: updated,
      lists: {for (final l in (json['lists'] as List? ?? const [])) '$l'},
      failed: {for (final l in (json['failed'] as List? ?? const [])) '$l'},
      stats: {for (final e in (json['stats'] as Map? ?? const {}).entries) '${e.key}': (e.value as num).toInt()},
    );
  }
}

/// Downloads and compiles the filter lists into [directory].
class AdblockLists {
  AdblockLists(this.directory, {http.Client? client}) : _client = client ?? http.Client();

  final Directory directory;
  final http.Client _client;

  static const updateEvery = Duration(days: 7);

  String get compiledPath => p.join(directory.path, 'filters.hsab');
  File get _metaFile => File(p.join(directory.path, 'meta.json'));
  File _rawFile(String id) => File(p.join(directory.path, 'lists', '$id.txt.gz'));

  Future<AdblockMeta?> meta() async {
    try {
      return AdblockMeta.fromJson(jsonDecode(await _metaFile.readAsString()));
    } catch (_) {
      return null;
    }
  }

  /// Whether the filters are missing, older than a week or made of other lists.
  Future<bool> needsUpdate(Set<String> enabled) async {
    final m = await meta();
    if (m == null || !File(compiledPath).existsSync()) return true;
    if (!setEquals(m.lists, enabled)) return true;
    return DateTime.now().difference(m.updated) > updateEvery;
  }

  /// Downloads the [enabled] lists (an older copy stands in for one that
  /// fails) and compiles them. Throws when there's nothing at all.
  Future<AdblockMeta> update(Set<String> enabled) async {
    await Directory(p.join(directory.path, 'lists')).create(recursive: true);
    final failed = <String>{};
    final sources = <(String, bool)>[];
    for (final info in filterLists.where((l) => enabled.contains(l.id))) {
      String? text;
      try {
        text = await _download(info);
        await _rawFile(info.id).writeAsBytes(gzip.encode(utf8.encode(text)));
      } catch (e) {
        debugPrint('adblock: ${info.id}: $e');
        failed.add(info.id);
        try {
          text = utf8.decode(gzip.decode(await _rawFile(info.id).readAsBytes()));
        } catch (_) {}
      }
      if (text != null) sources.add((text, info.trusted));
    }
    if (sources.isEmpty) throw StateError('no filter list could be loaded');
    // Compiling ~150k rules takes a while on a TV stick - not on the UI's isolate.
    final (compiled, stats) = await compute(_compile, sources);
    final tmp = File('$compiledPath.tmp');
    await tmp.writeAsString(compiled, flush: true);
    await tmp.rename(compiledPath);
    final m = AdblockMeta(updated: DateTime.now(), lists: enabled, stats: stats, failed: failed);
    await _metaFile.writeAsString(jsonEncode(m.toJson()));
    // Lists switched off: their copies aren't needed any more.
    for (final l in filterLists.where((l) => !enabled.contains(l.id))) {
      final f = _rawFile(l.id);
      if (f.existsSync()) await f.delete();
    }
    return m;
  }

  Future<String> _download(FilterListInfo info) async {
    Object? error;
    for (final url in info.urls) {
      try {
        final text = await _get(Uri.parse(url));
        return await _resolveIncludes(text, Uri.parse(url));
      } catch (e) {
        error = e;
      }
    }
    throw error ?? StateError('no address');
  }

  Future<String> _get(Uri uri) async {
    final res = await _client.get(uri).timeout(const Duration(seconds: 60));
    if (res.statusCode != 200) throw HttpException('HTTP ${res.statusCode}', uri: uri);
    final text = utf8.decode(res.bodyBytes, allowMalformed: true);
    if (text.trimLeft().startsWith('<')) throw HttpException('not a filter list', uri: uri);
    return text;
  }

  /// uBlock's `!#include file.txt` (same folder) - one level, as uBlock does.
  Future<String> _resolveIncludes(String text, Uri base) async {
    if (!text.contains('!#include ')) return text;
    final out = StringBuffer();
    for (final line in const LineSplitter().convert(text)) {
      if (line.startsWith('!#include ')) {
        final name = line.substring(10).trim();
        final uri = base.resolve(name);
        if (uri.host != base.host || name.contains('..')) continue;
        try {
          out.writeln(await _get(uri));
        } catch (e) {
          debugPrint('adblock: include $uri: $e');
        }
      } else {
        out.writeln(line);
      }
    }
    return out.toString();
  }
}

(String, Map<String, int>) _compile(List<(String, bool)> sources) {
  final data = AdblockCompiler.compile([for (final (t, trusted) in sources) FilterListSource(t, trusted: trusted)]);
  return (data.serialize(), data.stats.toJson());
}
