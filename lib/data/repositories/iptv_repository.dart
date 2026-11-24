import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../db/database.dart';
import '../models/iptv_channel.dart';

/// Which of TV's lists is open: the receiver's bouquet (its numbers) or
/// the Internet-TV favorites (their own numbers).
enum TvListKind { receiver, iptv }

/// Internet-TV's settings and favorites, in the settings table (so they're
/// in every backup - the backup takes the whole table).
///
/// Keys: `iptv_enabled`, `iptv_countries`, `iptv_languages` (JSON lists),
/// `iptv_favorites` (JSON list of channels, in the user's order - the
/// position is the number), `iptv_last_channel` (JSON of the channel last
/// watched, also one played from the catalogue), `tv_list_kind`
/// ("receiver" / "iptv").
class IptvRepository {
  IptvRepository(this._db);

  final AppDatabase _db;

  static const keyEnabled = 'iptv_enabled';
  static const keyCountries = 'iptv_countries';
  static const keyLanguages = 'iptv_languages';
  static const keyFavorites = 'iptv_favorites';
  static const keyLastChannel = 'iptv_last_channel';
  static const keyListKind = 'tv_list_kind';

  /// Austria and Germany, and the device's own country if it's another.
  static List<String> defaultCountries([String? deviceCountry]) {
    final own = (deviceCountry ?? PlatformDispatcher.instance.locale.countryCode ?? '').toUpperCase();
    return ['AT', 'DE', if (own.length == 2 && own != 'AT' && own != 'DE') own];
  }

  Future<bool> getEnabled() async => await _db.getSetting(keyEnabled) != 'false';
  Future<void> setEnabled(bool value) => _db.setSetting(keyEnabled, '$value');

  Future<List<String>> getCountries() async => _stringList(await _db.getSetting(keyCountries)) ?? defaultCountries();
  Future<void> setCountries(List<String> codes) => _db.setSetting(keyCountries, jsonEncode(codes));

  /// Empty: all languages.
  Future<List<String>> getLanguages() async => _stringList(await _db.getSetting(keyLanguages)) ?? const [];
  Future<void> setLanguages(List<String> codes) => _db.setSetting(keyLanguages, jsonEncode(codes));

  Future<List<IptvChannel>> getFavorites() async => decodeChannels(await _db.getSetting(keyFavorites));
  Future<void> setFavorites(List<IptvChannel> list) =>
      _db.setSetting(keyFavorites, jsonEncode([for (final c in list) c.toJson()]));

  Future<IptvChannel?> getLastChannel() async {
    final v = await _db.getSetting(keyLastChannel);
    if (v == null || v.isEmpty) return null;
    try {
      return IptvChannel.fromJson(jsonDecode(v) as Map<String, dynamic>);
    } catch (e) {
      debugPrint('IPTV last channel: $e');
      return null;
    }
  }

  Future<void> setLastChannel(IptvChannel channel) => _db.setSetting(keyLastChannel, jsonEncode(channel.toJson()));

  Future<TvListKind> getListKind() async =>
      await _db.getSetting(keyListKind) == TvListKind.iptv.name ? TvListKind.iptv : TvListKind.receiver;
  Future<void> setListKind(TvListKind kind) => _db.setSetting(keyListKind, kind.name);

  /// The favorites from their stored JSON - broken entries left out.
  static List<IptvChannel> decodeChannels(String? json) {
    if (json == null || json.isEmpty) return const [];
    try {
      final list = jsonDecode(json);
      if (list is! List) return const [];
      return [
        for (final e in list)
          if (e is Map<String, dynamic> && e['id'] is String && e['streams'] is List) IptvChannel.fromJson(e),
      ];
    } catch (e) {
      debugPrint('IPTV favorites: $e');
      return const [];
    }
  }

  static List<String>? _stringList(String? json) {
    if (json == null || json.isEmpty) return null;
    try {
      final v = jsonDecode(json);
      return v is List ? [for (final e in v) if (e is String) e] : null;
    } catch (_) {
      return null;
    }
  }
}
