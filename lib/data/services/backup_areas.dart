import '../../l10n/app_localizations.dart';

/// The parts of a backup that can be restored on their own (Backup
/// wiederherstellen → selection on the admin page and on the device).
///
/// Every entry of a backup lands in exactly one area: the radio tables
/// ([backupTableAreas]), every settings key and every secret through
/// [backupAreaOf] - an exact key in [backupAreaKeys], else the longest
/// matching prefix in [backupAreaPrefixes], else [BackupArea.other]. A new
/// setting therefore needs no change in the restore logic: it lands in the
/// area of its prefix (e.g. "tv_…" → TV) or in "Sonstiges"; to place it
/// elsewhere add one line to the tables below.
enum BackupArea {
  system,
  tv,
  radio,
  music,
  media,
  nas,
  dashboard,
  ha,
  sdr,
  weather,
  browser,
  other;

  static BackupArea? byName(String name) {
    for (final a in values) {
      if (a.name == name) return a;
    }
    return null;
  }
}

/// Keys that belong to no area: the device name has its own field in the
/// selection, "setup_done" is always set after a restore.
const backupSpecialKeys = {'device_name', 'setup_done'};

/// The backup's tables (JSON keys) and their area.
const backupTableAreas = <String, BackupArea>{
  'favorites': BackupArea.radio,
  'dabStations': BackupArea.radio,
  'fmStations': BackupArea.radio,
};

/// Single keys whose prefix would say something else (or that have none).
const backupAreaKeys = <String, BackupArea>{
  'language': BackupArea.system,
  'ui_scale': BackupArea.system,
  'fullscreen': BackupArea.system,
  'fullscreen_monitor': BackupArea.system,
  'start_app': BackupArea.system,
  'start_screen': BackupArea.system,
  'remote_keys': BackupArea.system,
  'auto_update': BackupArea.system,
  'show_clock_date': BackupArea.system,
  'enigma2': BackupArea.tv,
  // The Haussteuerung's own part switch is a system setting like the others.
  'part_dashboard_enabled': BackupArea.system,
};

/// Key prefixes and their area - the longest match wins ("launcher_bg_"
/// before "launcher_").
const backupAreaPrefixes = <String, BackupArea>{
  // System: parts on/off, launcher (tiles, groups, icon pack).
  'part_': BackupArea.system,
  'launcher_': BackupArea.system,
  // TV: receiver, IPTV, reminders, channel lists.
  'enigma2_': BackupArea.tv,
  'tv_': BackupArea.tv,
  'iptv_': BackupArea.tv,
  'epg_': BackupArea.tv,
  // Radio: start station, last station, DAB+/FM/AM.
  'radio_': BackupArea.radio,
  'autostart_': BackupArea.radio,
  'last_played_': BackupArea.radio,
  'dab_': BackupArea.radio,
  'fm_': BackupArea.radio,
  'am_': BackupArea.radio,
  'music_': BackupArea.music,
  // Films and pictures.
  'slideshow_': BackupArea.media,
  'pictures_': BackupArea.media,
  'picture_': BackupArea.media,
  'movie_': BackupArea.media,
  'movies_': BackupArea.media,
  'video_': BackupArea.media,
  'videos_': BackupArea.media,
  // NAS: server, login, folders.
  'nas_': BackupArea.nas,
  // Haussteuerung: dashboard, display by motion, brightness.
  'dashboard_': BackupArea.dashboard,
  'motion_': BackupArea.dashboard,
  'brightness_': BackupArea.dashboard,
  'display_': BackupArea.dashboard,
  'screen_': BackupArea.dashboard,
  // Home Assistant: MQTT link and login.
  'ha_': BackupArea.ha,
  // Funk/SDR: rtl_tcp, listening bands, aircraft, sensors.
  'rtl_': BackupArea.sdr,
  'sdr_': BackupArea.sdr,
  'nb_': BackupArea.sdr,
  'cb_': BackupArea.sdr,
  'ham_': BackupArea.sdr,
  'mil_': BackupArea.sdr,
  'funk_': BackupArea.sdr,
  'ism_': BackupArea.sdr,
  'adsb_': BackupArea.sdr,
  'acars_': BackupArea.sdr,
  'hf_': BackupArea.sdr,
  'scanner_': BackupArea.sdr,
  'dmr_': BackupArea.sdr,
  // Weather, radar, sun & moon and Home's background pictures.
  'weather_': BackupArea.weather,
  'radar_': BackupArea.weather,
  'sun_': BackupArea.weather,
  'launcher_bg_': BackupArea.weather,
  'launcher_band_': BackupArea.weather,
  'background_': BackupArea.weather,
  // Web browser.
  'browser.': BackupArea.browser,
  'browser_': BackupArea.browser,
};

/// Settings-table copies of secrets (see SecretStore) - they belong where
/// the secret does.
const _secretFallbackPrefix = 'secret_fallback.';

/// The area of the setting or secret [key] (see the tables above).
BackupArea backupAreaOf(String key) {
  if (key.startsWith(_secretFallbackPrefix)) key = key.substring(_secretFallbackPrefix.length);
  final exact = backupAreaKeys[key];
  if (exact != null) return exact;
  BackupArea? best;
  var bestLength = 0;
  for (final MapEntry(key: prefix, value: area) in backupAreaPrefixes.entries) {
    if (prefix.length > bestLength && key.startsWith(prefix)) {
      best = area;
      bestLength = prefix.length;
    }
  }
  return best ?? BackupArea.other;
}

/// The area's name in the selection.
String backupAreaTitle(AppLocalizations l, BackupArea area) => switch (area) {
      BackupArea.system => l.backupAreaSystem,
      BackupArea.tv => l.backupAreaTv,
      BackupArea.radio => l.backupAreaRadio,
      BackupArea.music => l.backupAreaMusic,
      BackupArea.media => l.backupAreaMedia,
      BackupArea.nas => l.backupAreaNas,
      BackupArea.dashboard => l.backupAreaDashboard,
      BackupArea.ha => l.backupAreaHa,
      BackupArea.sdr => l.backupAreaSdr,
      BackupArea.weather => l.backupAreaWeather,
      BackupArea.browser => l.backupAreaBrowser,
      BackupArea.other => l.backupAreaOther,
    };

/// What the area contains, one line for the selection.
String backupAreaHint(AppLocalizations l, BackupArea area) => switch (area) {
      BackupArea.system => l.backupAreaSystemHint,
      BackupArea.tv => l.backupAreaTvHint,
      BackupArea.radio => l.backupAreaRadioHint,
      BackupArea.music => l.backupAreaMusicHint,
      BackupArea.media => l.backupAreaMediaHint,
      BackupArea.nas => l.backupAreaNasHint,
      BackupArea.dashboard => l.backupAreaDashboardHint,
      BackupArea.ha => l.backupAreaHaHint,
      BackupArea.sdr => l.backupAreaSdrHint,
      BackupArea.weather => l.backupAreaWeatherHint,
      BackupArea.browser => l.backupAreaBrowserHint,
      BackupArea.other => l.backupAreaOtherHint,
    };
