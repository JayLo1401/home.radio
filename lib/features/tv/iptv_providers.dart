import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../data/models/iptv_channel.dart';
import '../../data/repositories/iptv_repository.dart';
import '../../data/services/iptv_service.dart';
import '../../l10n/l10n.dart';

export '../../data/repositories/iptv_repository.dart' show TvListKind;

final iptvRepositoryProvider = Provider<IptvRepository>((ref) => IptvRepository(ref.watch(databaseProvider)));

final iptvServiceProvider = Provider<IptvService>((ref) => IptvService());

/// Internet-TV's settings, its favorites and which of TV's lists is open.
@immutable
class IptvState {
  const IptvState({
    required this.enabled,
    required this.countries,
    required this.languages,
    required this.favorites,
    required this.list,
  });

  /// Einstellungen → TV → Internet-TV: shown in TV at all.
  final bool enabled;

  /// What browsing the catalogue starts with ("Meine Länder").
  final List<String> countries;

  /// Empty: all languages.
  final List<String> languages;

  /// In the user's order - the position is the number.
  final List<IptvChannel> favorites;
  final TvListKind list;

  IptvState copyWith({
    bool? enabled,
    List<String>? countries,
    List<String>? languages,
    List<IptvChannel>? favorites,
    TvListKind? list,
  }) =>
      IptvState(
        enabled: enabled ?? this.enabled,
        countries: countries ?? this.countries,
        languages: languages ?? this.languages,
        favorites: favorites ?? this.favorites,
        list: list ?? this.list,
      );

  int? numberOf(String id) => IptvFavorites.numberOf(favorites, id);
  bool isFavorite(String id) => favorites.any((c) => c.id == id);
}

/// null while loading.
class IptvNotifier extends Notifier<IptvState?> {
  @override
  IptvState? build() {
    _load();
    return null;
  }

  IptvRepository get _repo => ref.read(iptvRepositoryProvider);

  Future<void> _load() async {
    final repo = _repo;
    state = IptvState(
      enabled: await repo.getEnabled(),
      countries: await repo.getCountries(),
      languages: await repo.getLanguages(),
      favorites: await repo.getFavorites(),
      list: await repo.getListKind(),
    );
  }

  Future<void> setEnabled(bool value) async {
    final s = state;
    if (s != null) state = s.copyWith(enabled: value);
    await _repo.setEnabled(value);
  }

  Future<void> setCountries(List<String> codes) async {
    final s = state;
    if (s != null) state = s.copyWith(countries: codes);
    await _repo.setCountries(codes);
  }

  Future<void> setLanguages(List<String> codes) async {
    final s = state;
    if (s != null) state = s.copyWith(languages: codes);
    await _repo.setLanguages(codes);
  }

  Future<void> setList(TvListKind kind) async {
    final s = state;
    if (s == null || s.list == kind) return;
    state = s.copyWith(list: kind);
    await _repo.setListKind(kind);
  }

  Future<void> _setFavorites(List<IptvChannel> list) async {
    final s = state;
    if (s == null || identical(list, s.favorites)) return;
    state = s.copyWith(favorites: list);
    await _repo.setFavorites(list);
  }

  /// Adds [channel] at the end; its number.
  Future<int> addFavorite(IptvChannel channel) async {
    final s = state ?? await _ready();
    final list = IptvFavorites.add(s.favorites, channel);
    await _setFavorites(list);
    return IptvFavorites.numberOf(list, channel.id)!;
  }

  Future<void> removeFavorite(String id) async {
    final s = state ?? await _ready();
    await _setFavorites(IptvFavorites.remove(s.favorites, id));
  }

  Future<void> moveFavorite(int from, int to) async {
    final s = state ?? await _ready();
    await _setFavorites(IptvFavorites.move(s.favorites, from, to));
  }

  Future<void> clearFavorites() => _setFavorites(const []);

  /// New stream addresses / logos from a fresh catalogue.
  Future<void> refreshFrom(IptvCatalogue catalogue) async {
    final s = state;
    if (s == null) return;
    await _setFavorites(IptvFavorites.refresh(s.favorites, catalogue));
  }

  Future<void> setLastChannel(IptvChannel channel) => _repo.setLastChannel(channel);

  Future<IptvState> _ready() async {
    while (state == null) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    return state!;
  }
}

final iptvProvider = NotifierProvider<IptvNotifier, IptvState?>(IptvNotifier.new);

/// The catalogue while it's browsed: read from disk (or downloaded) on
/// first use, let go a few minutes after the last screen using it closed -
/// it's some megabytes, and the Fire TV Stick has 1 GB.
class IptvCatalogueStore {
  IptvCatalogueStore(this._service, this._onFresh);

  final IptvService _service;

  /// Told about every catalogue read or fetched (the favorites take new
  /// stream addresses from it).
  final void Function(IptvCatalogue) _onFresh;

  IptvCatalogue? _catalogue;
  Future<IptvCatalogue>? _loading;
  Future<IptvCatalogue>? _refreshing;
  Timer? _release;
  int _users = 0;

  IptvCatalogue? get current => _catalogue;

  /// A screen using the catalogue - call [release] when it closes.
  void hold() {
    _users++;
    _release?.cancel();
  }

  void release() {
    _users = (_users - 1).clamp(0, 1 << 30);
    if (_users > 0) return;
    _release?.cancel();
    _release = Timer(const Duration(minutes: 3), () {
      if (_users == 0 && _refreshing == null) _catalogue = null;
    });
  }

  /// The catalogue as saved - downloaded first if there's none yet.
  Future<IptvCatalogue> load() {
    if (_catalogue case final c?) return Future.value(c);
    return _loading ??= () async {
      try {
        final cached = await _service.loadCached();
        if (cached != null) {
          _catalogue = cached;
          _onFresh(cached);
          return cached;
        }
        return await refresh();
      } finally {
        _loading = null;
      }
    }();
  }

  /// The catalogue as saved, without downloading (null: none yet).
  Future<IptvCatalogue?> loadCached() async {
    if (_catalogue case final c?) return c;
    final cached = await _service.loadCached();
    if (cached != null && _catalogue == null) {
      _catalogue = cached;
      _onFresh(cached);
    }
    return _catalogue;
  }

  /// Fetches it anew from iptv-org.
  Future<IptvCatalogue> refresh() => _refreshing ??= () async {
        try {
          final fresh = await _service.download();
          _catalogue = fresh;
          _onFresh(fresh);
          return fresh;
        } finally {
          _refreshing = null;
        }
      }();

  bool get refreshing => _refreshing != null;
}

final iptvCatalogueStoreProvider = Provider<IptvCatalogueStore>((ref) {
  return IptvCatalogueStore(
    ref.watch(iptvServiceProvider),
    (catalogue) => ref.read(iptvProvider.notifier).refreshFrom(catalogue),
  );
});

/// A category's name in the app's language.
String iptvCategoryName(String id, [Map<String, String>? englishNames]) {
  if (l10n.localeName == 'de') {
    final de = _categoriesDe[id];
    if (de != null) return de;
  }
  return englishNames?[id] ?? _categoriesEn[id] ?? id;
}

/// A language's name (ISO 639-3) in the app's language.
String iptvLanguageName(String code, [Map<String, String>? englishNames]) {
  final names = l10n.localeName == 'de' ? iptvLanguagesDe : iptvLanguagesEn;
  return names[code] ?? englishNames?[code] ?? iptvLanguagesEn[code] ?? code;
}

const _categoriesDe = {
  'auto': 'Auto',
  'animation': 'Animation',
  'business': 'Wirtschaft',
  'classic': 'Klassiker',
  'comedy': 'Comedy',
  'cooking': 'Kochen',
  'culture': 'Kultur',
  'documentary': 'Dokumentation',
  'education': 'Bildung',
  'entertainment': 'Unterhaltung',
  'family': 'Familie',
  'general': 'Allgemein',
  'interactive': 'Interaktiv',
  'kids': 'Kinder',
  'legislative': 'Parlament',
  'lifestyle': 'Lifestyle',
  'movies': 'Filme',
  'music': 'Musik',
  'news': 'Nachrichten',
  'outdoor': 'Natur & Outdoor',
  'public': 'Öffentlich',
  'relax': 'Entspannung',
  'religious': 'Religion',
  'series': 'Serien',
  'science': 'Wissenschaft',
  'shop': 'Shopping',
  'sports': 'Sport',
  'travel': 'Reisen',
  'weather': 'Wetter',
  'woman': 'Frauen',
};

const _categoriesEn = {
  'auto': 'Auto',
  'animation': 'Animation',
  'business': 'Business',
  'classic': 'Classic',
  'comedy': 'Comedy',
  'cooking': 'Cooking',
  'culture': 'Culture',
  'documentary': 'Documentary',
  'education': 'Education',
  'entertainment': 'Entertainment',
  'family': 'Family',
  'general': 'General',
  'interactive': 'Interactive',
  'kids': 'Kids',
  'legislative': 'Legislative',
  'lifestyle': 'Lifestyle',
  'movies': 'Movies',
  'music': 'Music',
  'news': 'News',
  'outdoor': 'Outdoor',
  'public': 'Public',
  'relax': 'Relax',
  'religious': 'Religious',
  'series': 'Series',
  'science': 'Science',
  'shop': 'Shop',
  'sports': 'Sports',
  'travel': 'Travel',
  'weather': 'Weather',
  'woman': 'Woman',
};

/// The languages most channels come in (the settings' choice works
/// without the catalogue loaded).
const iptvLanguagesDe = {
  'deu': 'Deutsch',
  'eng': 'Englisch',
  'fra': 'Französisch',
  'ita': 'Italienisch',
  'spa': 'Spanisch',
  'por': 'Portugiesisch',
  'nld': 'Niederländisch',
  'pol': 'Polnisch',
  'ces': 'Tschechisch',
  'slk': 'Slowakisch',
  'slv': 'Slowenisch',
  'hrv': 'Kroatisch',
  'srp': 'Serbisch',
  'bos': 'Bosnisch',
  'hun': 'Ungarisch',
  'ron': 'Rumänisch',
  'bul': 'Bulgarisch',
  'ell': 'Griechisch',
  'tur': 'Türkisch',
  'rus': 'Russisch',
  'ukr': 'Ukrainisch',
  'sqi': 'Albanisch',
  'mkd': 'Mazedonisch',
  'dan': 'Dänisch',
  'swe': 'Schwedisch',
  'nor': 'Norwegisch',
  'fin': 'Finnisch',
  'cat': 'Katalanisch',
  'ara': 'Arabisch',
  'fas': 'Persisch',
  'heb': 'Hebräisch',
  'kur': 'Kurdisch',
  'hin': 'Hindi',
  'urd': 'Urdu',
  'zho': 'Chinesisch',
  'jpn': 'Japanisch',
  'kor': 'Koreanisch',
  'vie': 'Vietnamesisch',
  'tha': 'Thailändisch',
  'ind': 'Indonesisch',
};

const iptvLanguagesEn = {
  'deu': 'German',
  'eng': 'English',
  'fra': 'French',
  'ita': 'Italian',
  'spa': 'Spanish',
  'por': 'Portuguese',
  'nld': 'Dutch',
  'pol': 'Polish',
  'ces': 'Czech',
  'slk': 'Slovak',
  'slv': 'Slovenian',
  'hrv': 'Croatian',
  'srp': 'Serbian',
  'bos': 'Bosnian',
  'hun': 'Hungarian',
  'ron': 'Romanian',
  'bul': 'Bulgarian',
  'ell': 'Greek',
  'tur': 'Turkish',
  'rus': 'Russian',
  'ukr': 'Ukrainian',
  'sqi': 'Albanian',
  'mkd': 'Macedonian',
  'dan': 'Danish',
  'swe': 'Swedish',
  'nor': 'Norwegian',
  'fin': 'Finnish',
  'cat': 'Catalan',
  'ara': 'Arabic',
  'fas': 'Persian',
  'heb': 'Hebrew',
  'kur': 'Kurdish',
  'hin': 'Hindi',
  'urd': 'Urdu',
  'zho': 'Chinese',
  'jpn': 'Japanese',
  'kor': 'Korean',
  'vie': 'Vietnamese',
  'tha': 'Thai',
  'ind': 'Indonesian',
};
