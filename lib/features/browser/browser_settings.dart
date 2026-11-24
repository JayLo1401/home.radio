import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../core/providers.dart';
import '../../data/db/database.dart';
import '../../data/services/adblock_lists.dart';
import 'browser_channel.dart';

/// A search engine for what's typed into the address field that isn't an
/// address.
enum SearchEngine {
  google('Google', 'https://www.google.com/search?q=', 'https://www.google.com/'),
  startpage('Startpage', 'https://www.startpage.com/do/search?q=', 'https://www.startpage.com/'),
  duckDuckGo('DuckDuckGo', 'https://duckduckgo.com/?q=', 'https://duckduckgo.com/'),
  ecosia('Ecosia', 'https://www.ecosia.org/search?q=', 'https://www.ecosia.org/'),
  bing('Bing', 'https://www.bing.com/search?q=', 'https://www.bing.com/');

  const SearchEngine(this.label, this.searchUrl, this.homeUrl);

  final String label;
  final String searchUrl;
  final String homeUrl;

  static SearchEngine parse(String? name) =>
      SearchEngine.values.firstWhere((e) => e.name == name, orElse: () => SearchEngine.google);
}

class Bookmark {
  const Bookmark({required this.title, required this.url});

  final String title;
  final String url;

  Map<String, String> toJson() => {'title': title, 'url': url};

  static Bookmark? fromJson(Object? json) {
    if (json is! Map || json['url'] is! String) return null;
    return Bookmark(title: '${json['title'] ?? json['url']}', url: json['url'] as String);
  }
}

/// The browser's settings (Einstellungen → Browser, the browser's menu).
@immutable
class BrowserSettings {
  const BrowserSettings({
    this.blocker = true,
    this.allowlist = const {},
    this.lists,
    this.searchEngine = SearchEngine.google,
    this.homePage = '',
    this.desktop = false,
    this.textZoom = 100,
    this.bookmarks = const [],
    this.lastUrl = '',
  });

  /// The ad/tracker blocker on.
  final bool blocker;

  /// Sites the blocker is off for (hosts, subdomains included).
  final Set<String> allowlist;

  /// The filter lists switched on; null = the defaults.
  final Set<String>? lists;
  final SearchEngine searchEngine;

  /// '' = the search engine's page.
  final String homePage;

  /// Pages as on a PC (desktop user agent).
  final bool desktop;
  final int textZoom;
  final List<Bookmark> bookmarks;

  /// Where the browser was left - it opens there again.
  final String lastUrl;

  Set<String> get enabledLists => lists ?? defaultFilterLists(PlatformDispatcher.instance.locale.languageCode);

  String get home => homePage.isEmpty ? searchEngine.homeUrl : homePage;

  static const textZoomSteps = [50, 67, 75, 90, 100, 110, 125, 150, 175, 200];

  BrowserSettings copyWith({
    bool? blocker,
    Set<String>? allowlist,
    Set<String>? lists,
    SearchEngine? searchEngine,
    String? homePage,
    bool? desktop,
    int? textZoom,
    List<Bookmark>? bookmarks,
    String? lastUrl,
  }) =>
      BrowserSettings(
        blocker: blocker ?? this.blocker,
        allowlist: allowlist ?? this.allowlist,
        lists: lists ?? this.lists,
        searchEngine: searchEngine ?? this.searchEngine,
        homePage: homePage ?? this.homePage,
        desktop: desktop ?? this.desktop,
        textZoom: textZoom ?? this.textZoom,
        bookmarks: bookmarks ?? this.bookmarks,
        lastUrl: lastUrl ?? this.lastUrl,
      );

  Map<String, Object?> toJson() => {
        'blocker': blocker,
        'allowlist': allowlist.toList(),
        if (lists != null) 'lists': lists!.toList(),
        'searchEngine': searchEngine.name,
        'homePage': homePage,
        'desktop': desktop,
        'textZoom': textZoom,
        'bookmarks': [for (final b in bookmarks) b.toJson()],
        'lastUrl': lastUrl,
      };

  static BrowserSettings fromJson(Object? json) {
    if (json is! Map) return const BrowserSettings();
    final zoom = json['textZoom'];
    return BrowserSettings(
      blocker: json['blocker'] != false,
      allowlist: {for (final h in (json['allowlist'] as List? ?? const [])) '$h'},
      lists: json['lists'] is List ? {for (final l in json['lists'] as List) '$l'} : null,
      searchEngine: SearchEngine.parse(json['searchEngine'] as String?),
      homePage: json['homePage'] is String ? json['homePage'] as String : '',
      desktop: json['desktop'] == true,
      textZoom: zoom is int && zoom >= 50 && zoom <= 200 ? zoom : 100,
      bookmarks: [for (final b in (json['bookmarks'] as List? ?? const [])) ?Bookmark.fromJson(b)],
      lastUrl: json['lastUrl'] is String ? json['lastUrl'] as String : '',
    );
  }
}

/// What the address field's text means: an address as it is, a host
/// ("orf.at", "192.168.1.10:8123") with https:// (http:// for local
/// addresses), or else a search.
String browserUrlFor(String input, SearchEngine engine) {
  final text = input.trim();
  if (text.isEmpty) return engine.homeUrl;
  final lower = text.toLowerCase();
  if (RegExp(r'^(https?|about|data|file):', caseSensitive: false).hasMatch(lower)) return text;
  if (!text.contains(' ')) {
    final host = lower.split(RegExp(r'[/?#]')).first;
    final hostOnly = host.split(':').first;
    final local = hostOnly == 'localhost' ||
        RegExp(r'^\d{1,3}(\.\d{1,3}){3}$').hasMatch(hostOnly) ||
        hostOnly.endsWith('.local') ||
        hostOnly.endsWith('.lan') ||
        hostOnly.endsWith('.fritz.box');
    if (local) return 'http://$text';
    if (RegExp(r'^[a-z0-9-]+(\.[a-z0-9-]+)*\.[a-z]{2,}$').hasMatch(hostOnly)) return 'https://$text';
  }
  return '${engine.searchUrl}${Uri.encodeQueryComponent(text)}';
}

/// The host a URL is on ('' if none) - what the allowlist goes by.
String browserHostOf(String url) {
  final uri = Uri.tryParse(url);
  return uri == null || !uri.hasAuthority ? '' : uri.host.toLowerCase();
}

/// Stored in the app's settings table (so backups include it).
class BrowserSettingsRepository {
  BrowserSettingsRepository(this._db);

  final AppDatabase _db;
  static const _key = 'browser.settings';

  Future<BrowserSettings> load() async {
    try {
      final raw = await _db.getSetting(_key);
      return raw == null ? const BrowserSettings() : BrowserSettings.fromJson(jsonDecode(raw));
    } catch (_) {
      return const BrowserSettings();
    }
  }

  Future<void> save(BrowserSettings s) => _db.setSetting(_key, jsonEncode(s.toJson()));
}

final browserSettingsRepositoryProvider =
    Provider<BrowserSettingsRepository>((ref) => BrowserSettingsRepository(ref.watch(databaseProvider)));

class BrowserSettingsNotifier extends Notifier<BrowserSettings> {
  bool _loaded = false;

  @override
  BrowserSettings build() {
    ref.read(browserSettingsRepositoryProvider).load().then((v) {
      _loaded = true;
      state = v;
    });
    return const BrowserSettings();
  }

  /// The stored settings (waits for the first load).
  Future<BrowserSettings> loaded() async {
    if (!_loaded) {
      state = await ref.read(browserSettingsRepositoryProvider).load();
      _loaded = true;
    }
    return state;
  }

  Future<void> set(BrowserSettings value) async {
    state = value;
    await ref.read(browserSettingsRepositoryProvider).save(value);
  }

  Future<void> update(BrowserSettings Function(BrowserSettings) change) async => set(change(await loaded()));

  Future<void> setAllowed(String host, bool blockerOff) => update((s) {
        final list = {...s.allowlist};
        blockerOff ? list.add(host) : list.remove(host);
        return s.copyWith(allowlist: list);
      });

  Future<void> toggleBookmark(String url, String title) => update((s) {
        final has = s.bookmarks.any((b) => b.url == url);
        return s.copyWith(
          bookmarks: has
              ? s.bookmarks.where((b) => b.url != url).toList()
              : [...s.bookmarks, Bookmark(title: title.isEmpty ? url : title, url: url)],
        );
      });

  Future<void> removeBookmark(String url) =>
      update((s) => s.copyWith(bookmarks: s.bookmarks.where((b) => b.url != url).toList()));
}

final browserSettingsProvider =
    NotifierProvider<BrowserSettingsNotifier, BrowserSettings>(BrowserSettingsNotifier.new);

/// The filter lists' state for the settings.
@immutable
class AdblockStatus {
  const AdblockStatus({this.meta, this.updating = false, this.error, this.loaded = false});

  final AdblockMeta? meta;
  final bool updating;
  final String? error;

  /// The filters are in the WebView's blocker.
  final bool loaded;

  AdblockStatus copyWith({AdblockMeta? meta, bool? updating, String? error, bool clearError = false, bool? loaded}) =>
      AdblockStatus(
        meta: meta ?? this.meta,
        updating: updating ?? this.updating,
        error: clearError ? null : (error ?? this.error),
        loaded: loaded ?? this.loaded,
      );
}

/// Keeps the native blocker supplied: loads the compiled filters, updates
/// them weekly (or when other lists are chosen), and hands the switches over.
class AdblockController extends Notifier<AdblockStatus> {
  AdblockLists? _lists;

  @override
  AdblockStatus build() {
    // The switches follow the settings at once.
    ref.listen(browserSettingsProvider, (prev, next) {
      if (prev?.blocker != next.blocker || !setEquals(prev?.allowlist, next.allowlist)) _sendSwitches(next);
    });
    return const AdblockStatus();
  }

  Future<AdblockLists> _get() async {
    final lists = _lists;
    if (lists != null) return lists;
    final dir = Directory(p.join((await getApplicationSupportDirectory()).path, 'adblock'));
    await dir.create(recursive: true);
    return _lists = AdblockLists(dir);
  }

  void _sendSwitches(BrowserSettings s) {
    if (!BrowserChannel.supported) return;
    BrowserChannel.setBlocking(enabled: s.blocker, allowlist: s.allowlist);
  }

  /// When the browser opens: the switches, the filters there are, and an
  /// update in the background when due.
  Future<void> prepare() async {
    if (!BrowserChannel.supported) return;
    final settings = await ref.read(browserSettingsProvider.notifier).loaded();
    _sendSwitches(settings);
    final lists = await _get();
    final meta = await lists.meta();
    state = state.copyWith(meta: meta);
    if (!state.loaded && File(lists.compiledPath).existsSync()) {
      final ok = await BrowserChannel.loadFilters(lists.compiledPath);
      state = state.copyWith(loaded: ok);
    }
    if (settings.blocker && await lists.needsUpdate(settings.enabledLists)) await update();
  }

  /// Downloads and compiles the lists now.
  Future<void> update() async {
    if (state.updating || !BrowserChannel.supported) return;
    state = state.copyWith(updating: true, clearError: true);
    try {
      final settings = await ref.read(browserSettingsProvider.notifier).loaded();
      final lists = await _get();
      final meta = await lists.update(settings.enabledLists);
      final ok = await BrowserChannel.loadFilters(lists.compiledPath);
      state = AdblockStatus(meta: meta, loaded: ok);
    } catch (e) {
      debugPrint('adblock update: $e');
      state = state.copyWith(updating: false, error: '$e');
    }
  }

  /// Other lists chosen: compile anew.
  Future<void> setLists(Set<String> ids) async {
    await ref.read(browserSettingsProvider.notifier).update((s) => s.copyWith(lists: ids));
    await update();
  }
}

final adblockProvider = NotifierProvider<AdblockController, AdblockStatus>(AdblockController.new);
