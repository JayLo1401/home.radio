// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for German (`de`).
class AppLocalizationsDe extends AppLocalizations {
  AppLocalizationsDe([String locale = 'de']) : super(locale);

  @override
  String get adminSubtitle => 'Verwaltung dieses Geräts im Heimnetz';

  @override
  String get adminHostname => 'Hostname';

  @override
  String get adminIpAddress => 'IP-Adresse';

  @override
  String get adminNotFound => 'Nicht gefunden';

  @override
  String get adminSaved => 'Gespeichert';

  @override
  String get adminOffline => 'Keine Verbindung zum Gerät.';

  @override
  String get adminInvalidValue => 'Ungültiger Wert.';

  @override
  String get adminUnknownSetting => 'Diese Einstellung gibt es hier nicht.';

  @override
  String get adminSecretPlaceholder => 'unverändert';

  @override
  String get adminSecretHelp => 'Wird nie angezeigt - nur ein neues eintragen.';

  @override
  String get adminBackupHeading => 'Backup';

  @override
  String get adminBackupHelp =>
      'Enthält Favoriten, Senderlisten und alle Einstellungen - auch Zugangsdaten. Gut aufbewahren.';

  @override
  String get adminBackupDownload => 'Backup erstellen & herunterladen';

  @override
  String get adminRestoreHeading => 'Backup wiederherstellen';

  @override
  String get adminRestoreHow =>
      'Zum Wiederherstellen am Gerät Einstellungen → System → Backup wiederherstellen öffnen (oder im Einrichtungsassistenten „Backup wiederherstellen“ wählen). Hier erscheint dann das Hochladen.';

  @override
  String get adminRestoreReady =>
      'Das Gerät ist bereit. Alle aktuellen Favoriten, Sender und Einstellungen werden ersetzt, danach startet Home System neu.';

  @override
  String get adminRestoreButton => 'Backup einspielen';

  @override
  String get adminRestoring => 'Wird eingespielt …';

  @override
  String adminConfirmRestore(String file) {
    return 'Backup „$file“ einspielen? Alle aktuellen Daten des Geräts werden ersetzt.';
  }

  @override
  String get adminRestoreLocked =>
      'Wiederherstellen ist gerade nicht freigegeben - am Gerät „Backup wiederherstellen“ öffnen.';

  @override
  String get adminFileTooBig => 'Die Datei ist zu groß für ein Backup.';

  @override
  String get adminFileInvalid => 'Die Datei ist kein gültiges Backup.';

  @override
  String get adminRestored => 'Backup eingespielt - Home System startet neu.';

  @override
  String get adminDisplayHeading => 'Display (Haussteuerung)';

  @override
  String get adminDisplayHelp =>
      'Schaltet das Display des Geräts - dasselbe kann Home Assistant per POST auf /api/display/on, /api/display/off und /api/dashboard/reload.';

  @override
  String get adminDisplayOn => 'Display an';

  @override
  String get adminDisplayOff => 'Display aus';

  @override
  String get adminDashboardReload => 'Dashboard neu laden';

  @override
  String get adminDeviceName => 'Gerätename';

  @override
  String get adminPartRadio => 'Radio eingeschaltet';

  @override
  String get adminPartTv => 'TV eingeschaltet';

  @override
  String get adminPartDashboard => 'Haussteuerung eingeschaltet';

  @override
  String get adminStartScreen => 'Beim Start der App';

  @override
  String get adminStartScreenApp => 'Start-App';

  @override
  String get adminStartApp => 'Start-App';

  @override
  String get adminStartAppFirst => 'Zuerst eine Start-App wählen.';

  @override
  String get adminUiScale => 'Größe der Oberfläche (%)';

  @override
  String get adminClockDate => 'Datum neben der Uhrzeit';

  @override
  String get adminWeather => 'Wetter-Kachel';

  @override
  String get adminRadar => 'Regenradar-Kachel';

  @override
  String get adminSun => 'Sonne & Mond-Kachel';

  @override
  String get adminTvHost => 'Receiver: Adresse (IP oder Name)';

  @override
  String get adminTvWebPort => 'Receiver: Web-Port';

  @override
  String get adminTvStreamPort => 'Receiver: Streaming-Port';

  @override
  String get adminTvHttps => 'Receiver: HTTPS';

  @override
  String get adminTvUser => 'Receiver: Benutzer';

  @override
  String get adminTvPassword => 'Receiver: Passwort';

  @override
  String get adminTvNextUp => 'Hinweis „Als Nächstes“';

  @override
  String get adminMotionTimeout => 'Display aus nach (Minuten)';

  @override
  String get adminMotionTimeoutHelp => '0 = nie';

  @override
  String get adminCameraOnDevice =>
      'Der Zugriff auf die Kamera muss einmal am Gerät erlaubt werden: Einstellungen → Haussteuerung.';

  @override
  String get commonOk => 'OK';

  @override
  String get commonCancel => 'Abbrechen';

  @override
  String get commonSave => 'Speichern';

  @override
  String get commonDelete => 'Löschen';

  @override
  String get commonClose => 'Schließen';

  @override
  String get commonBack => 'Zurück';

  @override
  String get commonYes => 'Ja';

  @override
  String get commonNo => 'Nein';

  @override
  String get commonOn => 'Ein';

  @override
  String get commonOff => 'Aus';

  @override
  String get commonEdit => 'Bearbeiten';

  @override
  String get commonRetry => 'Erneut versuchen';

  @override
  String get commonLoading => 'Wird geladen …';

  @override
  String commonError(String message) {
    return 'Fehler: $message';
  }

  @override
  String get commonLanguage => 'Sprache';

  @override
  String get commonLanguageSystem => 'Wie das Gerät';

  @override
  String get commonLanguageGerman => 'Deutsch';

  @override
  String get commonLanguageEnglish => 'English';

  @override
  String get dashboardTitle => 'Haussteuerung';

  @override
  String get dashboardAndroidOnly =>
      'Die Haussteuerung gibt es nur unter Android (Tablet, TV-Box).';

  @override
  String get dashboardNoAddress =>
      'Noch keine Adresse für das Home-Assistant-Dashboard eingetragen.';

  @override
  String get dashboardOpenSettings => 'Einstellungen öffnen';

  @override
  String dashboardUnreachable(String url) {
    return '$url ist nicht erreichbar - neuer Versuch in 15 Sekunden.';
  }

  @override
  String get dashboardSettingsTitle => 'Haussteuerungs-Einstellungen';

  @override
  String get dashboardAreaSubtitle =>
      'Home-Assistant-Dashboard, Display per Bewegung';

  @override
  String get dashboardAddress => 'Dashboard-Adresse';

  @override
  String get dashboardAddressHint =>
      'http://homeassistant.local:8123/lovelace/0';

  @override
  String get dashboardAddressHelp =>
      'Die Seite des Dashboards in Home Assistant. Die Anmeldung bleibt gespeichert. Mit „?kiosk“ am Ende (Integration „kiosk-mode“) ohne Kopf- und Seitenleiste.';

  @override
  String get dashboardNotSet => 'nicht eingetragen';

  @override
  String get dashboardDisplayHeading => 'Display per Bewegung';

  @override
  String get dashboardMotion => 'Display per Kamera ein- und ausschalten';

  @override
  String get dashboardMotionHelp =>
      'Die Kamera erkennt Bewegung vor dem Gerät: Das Display geht an und zeigt die Haussteuerung. Ist eine Weile niemand da, geht es aus. Es werden keine Bilder gespeichert oder verschickt.';

  @override
  String get dashboardNoCamera => 'Dieses Gerät hat keine Kamera.';

  @override
  String get dashboardCameraDenied =>
      'Ohne Zugriff auf die Kamera geht das nicht.';

  @override
  String get dashboardNoAccessibility =>
      'Zum Ausschalten des Displays braucht Home System die Bedienungshilfe „Home System: Home-Taste“ (Android 9 oder neuer).';

  @override
  String get dashboardSensitivity => 'Empfindlichkeit';

  @override
  String dashboardSensitivityValue(int value) {
    return '$value von 10';
  }

  @override
  String get dashboardTimeout => 'Display aus nach';

  @override
  String dashboardTimeoutMinutes(int minutes) {
    String _temp0 = intl.Intl.pluralLogic(
      minutes,
      locale: localeName,
      other: '$minutes Minuten',
      one: '1 Minute',
    );
    return '$_temp0';
  }

  @override
  String get dashboardTimeoutNever => 'nie';

  @override
  String dashboardLevel(int percent) {
    return 'Bewegung jetzt: $percent %';
  }

  @override
  String get dashboardLevelMotion => 'Bewegung erkannt';

  @override
  String get dashboardHaHeading => 'Home Assistant';

  @override
  String get dashboardWebhook => 'Webhook für Bewegung';

  @override
  String get dashboardWebhookHint =>
      'http://homeassistant.local:8123/api/webhook/flur-tablet';

  @override
  String get dashboardWebhookHelp =>
      'Bei Bewegung schickt Home System \"motion\": true, nach einer Minute Ruhe \"motion\": false - als Auslöser für Automationen (Auslöser „Webhook“).';

  @override
  String dashboardRemoteHelp(String url) {
    return 'Home Assistant kann das Display schalten und das Dashboard neu laden: $url/api/display/on, …/off, …/api/dashboard/reload (POST, z. B. mit rest_command).';
  }

  @override
  String get dashboardTestOff => 'Display jetzt ausschalten (Test)';

  @override
  String get iptvListName => 'Internet-TV';

  @override
  String get iptvBrowse => 'Sender suchen';

  @override
  String get iptvBrowseTitle => 'Internet-TV – Sender suchen';

  @override
  String get iptvSearchName => 'Sendername';

  @override
  String get iptvCountry => 'Land';

  @override
  String iptvMyCountries(String countries) {
    return 'Meine Länder ($countries)';
  }

  @override
  String get iptvAllCountries => 'Alle Länder';

  @override
  String get iptvCategory => 'Kategorie';

  @override
  String get iptvAllCategories => 'Alle Kategorien';

  @override
  String get iptvLanguage => 'Sprache';

  @override
  String iptvMyLanguages(String languages) {
    return 'Meine Sprachen ($languages)';
  }

  @override
  String get iptvAllLanguages => 'Alle Sprachen';

  @override
  String get iptvBrowseKeyHint =>
      'OK spielt den Sender  ·  ★ (→) oder Optionen-Taste: in die Internet-TV-Liste aufnehmen bzw. entfernen';

  @override
  String iptvResultCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count Sender',
      one: '1 Sender',
    );
    return '$_temp0';
  }

  @override
  String iptvCatalogueDate(String date) {
    return 'Katalog vom $date';
  }

  @override
  String get iptvLoadingCatalogue =>
      'Senderkatalog wird geladen… (beim ersten Mal kann das eine Minute dauern)';

  @override
  String get iptvUpdatingCatalogue => 'wird aktualisiert…';

  @override
  String get iptvUpdateFailed => 'Aktualisieren fehlgeschlagen';

  @override
  String iptvCatalogueError(String error) {
    return 'Senderkatalog nicht ladbar: $error';
  }

  @override
  String get iptvTryAgain => 'Nochmal versuchen';

  @override
  String get iptvNoResults => 'Keine Sender gefunden';

  @override
  String get iptvAddFavorite => 'In die Internet-TV-Liste';

  @override
  String get iptvRemoveFavorite => 'Aus der Internet-TV-Liste entfernen';

  @override
  String iptvAddedAsNumber(String name, int number) {
    return '„$name“ ist jetzt Internet-TV Nr. $number';
  }

  @override
  String iptvRemoved(String name) {
    return '„$name“ aus der Internet-TV-Liste entfernt';
  }

  @override
  String iptvFavoriteNumber(int number) {
    return 'Nr. $number';
  }

  @override
  String get iptvEmptyList =>
      'Noch keine Internet-TV-Sender. Oben „Sender suchen“: dort spielt OK einen Sender, ★ nimmt ihn in diese Liste auf.';

  @override
  String get iptvChannelListKeyHint =>
      'OK abspielen (laufender Sender: Info)  ·  → Optionen (verschieben, entfernen)  ·  ← schließen';

  @override
  String get iptvMove => 'Verschieben';

  @override
  String get iptvMoveHint => '↑/↓ verschieben  ·  OK fertig';

  @override
  String get iptvChangeNumber => 'Nummer ändern…';

  @override
  String get iptvPlay => 'Abspielen';

  @override
  String get iptvLinkConnecting => 'Verbinde mit dem Sender…';

  @override
  String iptvLinkTryingOther(int attempt, int count) {
    return 'Anderer Stream wird versucht ($attempt von $count)…';
  }

  @override
  String iptvErrorNoPicture(String channel) {
    return '„$channel“ sendet gerade nicht oder ist hier gesperrt (Geo-Sperre).';
  }

  @override
  String get iptvNoGuide => 'Kein Programmführer für Internet-TV';

  @override
  String get iptvNoGuideSentence =>
      'Für Internet-TV-Sender gibt es keinen Programmführer.';

  @override
  String iptvBannerKeyHint(String channelListKey, String optionsKey) {
    return '$channelListKey Senderliste  ·  $optionsKey Optionen';
  }

  @override
  String get iptvGeoBlocked =>
      'Evtl. nur im eigenen Land empfangbar (Geo-Sperre)';

  @override
  String get iptvNotAlways => 'Sendet nicht rund um die Uhr';

  @override
  String get iptvSource =>
      'Quelle: offener Senderkatalog iptv-org (github.com/iptv-org/iptv)';

  @override
  String get iptvNotSetUpIntro =>
      'Oder ganz ohne Receiver: frei empfangbare Sender aus dem Internet (Internet-TV).';

  @override
  String get iptvSetUp => 'Internet-TV-Sender suchen';

  @override
  String get iptvSettingsTitle => 'Internet-TV';

  @override
  String get iptvSettingsIntro =>
      'Frei und legal empfangbare Fernsehsender aus dem Internet – aus dem offenen Senderkatalog iptv-org (github.com/iptv-org/iptv). Internet-TV hat eine eigene Senderliste mit eigenen Nummern; die Liste des Receivers bleibt, wie sie ist. Manche Sender gehen nur in ihrem Land (Geo-Sperre) oder nicht rund um die Uhr.';

  @override
  String get iptvSettingsEnabled => 'Internet-TV im TV anzeigen';

  @override
  String get iptvSettingsCountries => 'Meine Länder';

  @override
  String get iptvSettingsCountriesHelp =>
      'Mit diesen Ländern beginnt die Sendersuche.';

  @override
  String get iptvSettingsLanguages => 'Meine Sprachen';

  @override
  String get iptvSettingsLanguagesHelp =>
      'Mit diesen Sprachen beginnt die Sendersuche – keine: alle Sprachen.';

  @override
  String get iptvSettingsAddCountry => 'Land hinzufügen';

  @override
  String get iptvSettingsAddLanguage => 'Sprache hinzufügen';

  @override
  String get iptvSettingsChipHelp =>
      'OK auf ein Land bzw. eine Sprache nimmt es wieder heraus.';

  @override
  String get iptvSettingsCatalogue => 'Senderkatalog';

  @override
  String get iptvSettingsCatalogueHelp =>
      'Wird beim ersten Suchen geladen und danach höchstens einmal am Tag aktualisiert.';

  @override
  String get iptvSettingsRefresh => 'Jetzt aktualisieren';

  @override
  String iptvSettingsFavorites(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count Sender in der Internet-TV-Liste',
      one: '1 Sender in der Internet-TV-Liste',
      zero: 'Noch keine Sender in der Internet-TV-Liste',
    );
    return '$_temp0';
  }

  @override
  String get iptvSettingsFavoritesHelp =>
      'Sortieren und entfernen in der Senderliste des TV: dort → auf einem Sender.';

  @override
  String get iptvSettingsClearFavorites => 'Alle entfernen';

  @override
  String iptvSettingsClearConfirm(int count) {
    return 'Alle $count Sender aus der Internet-TV-Liste entfernen?';
  }

  @override
  String get miscApply => 'Übernehmen';

  @override
  String get miscLocationTitle => 'Standort einrichten';

  @override
  String get miscLocationIntro =>
      'Gemeinsamer Standort für Wetterprognose, Wetterradar und Sonne & Mond.';

  @override
  String miscLocationCurrent(String name, String lat, String lon) {
    return 'Aktuell: $name ($lat, $lon)';
  }

  @override
  String get miscLocationSearchLabel => 'Ort suchen, z. B. Graz oder Gleisdorf';

  @override
  String get miscLocationSearch => 'Suchen';

  @override
  String get miscLocationSearchFailed =>
      'Suche fehlgeschlagen - Internetverbindung prüfen.';

  @override
  String get miscLocationNoResults => 'Kein Ort gefunden.';

  @override
  String miscLocationPicked(String name) {
    return 'Standort: $name';
  }

  @override
  String get miscLocationAttribution =>
      'Ortssuche: © OpenStreetMap-Mitwirkende (ODbL), über Nominatim.';

  @override
  String get miscRadarTitle => 'Wetterradar einrichten';

  @override
  String get miscRadarInvalidUrl =>
      'Bitte eine vollständige Adresse mit http:// oder https:// eingeben.';

  @override
  String get miscRadarSourceType => 'Art der Quelle';

  @override
  String get miscRadarImage => 'Bild';

  @override
  String get miscRadarImageHint =>
      'PNG oder JPG, z. B. vom eigenen Radar-Server - wird alle 2½ Minuten neu geladen.';

  @override
  String get miscRadarWebPage => 'Webseite';

  @override
  String get miscRadarWebPageHint =>
      'Eine Radar-Webseite, z. B. eine interaktive Karte. Braucht mehr Speicher und Grafikleistung als ein Bild - auf schwachen TV-Boxen besser ein Bild verwenden.';

  @override
  String get miscRadarWebPageUrl => 'Adresse der Webseite (URL)';

  @override
  String get miscRadarImageUrl => 'Bild-Adresse (URL)';

  @override
  String miscRadarPlaceholders(
    String lat,
    String lon,
    String r,
    String zoom,
    String w,
    String h,
    String scale,
  ) {
    return 'Platzhalter werden automatisch ersetzt: $lat $lon = Standort, $r = Umkreis in km, $zoom = Kartenzoom passend zum Umkreis, $w $h = Kachelgröße in Pixeln, $scale = Bildschirmdichte.';
  }

  @override
  String get miscRadarDisclaimer =>
      'Die App bringt selbst keine Radarquelle mit. Rechte und Nutzungsbedingungen liegen beim jeweiligen Anbieter - bitte nur Quellen eintragen, die so genutzt werden dürfen.';

  @override
  String get miscRadarCssLabel => 'Eigenes CSS für die Webseite (optional)';

  @override
  String get miscRadarCssHint =>
      'Wird nach jedem Laden in die Seite eingefügt, wie ein eigenes Stylesheet im Browser - z. B. um Teile der Seite für die eigene Anzeige auszublenden.';

  @override
  String get miscRadarAuth => 'Mit Anmeldung (Token)';

  @override
  String get miscRadarAuthHint =>
      'Wird als „Authorization: Bearer …“ mitgeschickt.';

  @override
  String get miscRemoteKeysTitle => 'Tasten der Fernbedienung';

  @override
  String get miscRemoteKeysIntro =>
      'Eine Aktion wählen und dann die Taste drücken, die sie auslösen soll - sie ersetzt die bisherigen Tasten der Aktion. So bleibt z. B. ☰ frei, wenn sie auf der Fernbedienung etwas anderes tut. Pfeiltasten, Zurück und Home lassen sich nicht belegen.';

  @override
  String get miscRemoteKeysNone => 'keine Taste';

  @override
  String get miscRemoteKeysStandard => 'Standard';

  @override
  String get miscRemoteKeysResetHint =>
      'Langer Druck auf OK bei einer Aktion: wieder die Standard-Tasten.';

  @override
  String miscRemoteKeysNotAssignable(String key) {
    return '$key lässt sich nicht belegen.';
  }

  @override
  String get miscRemoteKeysPressNow => 'Jetzt die Taste drücken …';

  @override
  String get miscRemoteKeysBackCancels => 'Zurück bricht ab.';

  @override
  String get miscActionChannelList => 'Senderliste (TV)';

  @override
  String get miscActionGuide => 'Programmführer (TV)';

  @override
  String get miscActionOptions => 'Optionen (Kachel unter Home, TV)';

  @override
  String get miscActionAudio => 'Tonspur (TV)';

  @override
  String get miscKeyMenu => '☰ Menü';

  @override
  String get miscKeySearch => 'Suche';

  @override
  String get miscKeyRed => 'Rot';

  @override
  String get miscKeyGreen => 'Grün';

  @override
  String get miscKeyYellow => 'Gelb';

  @override
  String get miscKeyBlue => 'Blau';

  @override
  String miscKeyNamed(String key) {
    return 'Taste $key';
  }

  @override
  String get miscRegionEurope => 'Europa';

  @override
  String get miscRegionNorthAmerica => 'Nord- & Mittelamerika';

  @override
  String get miscRegionSouthAmerica => 'Südamerika';

  @override
  String get miscRegionAsia => 'Asien & Nahost';

  @override
  String get miscRegionAfrica => 'Afrika';

  @override
  String get miscRegionOceania => 'Ozeanien';

  @override
  String get miscRegionOther => 'Andere';

  @override
  String get miscUpdatesTitle => 'Updates';

  @override
  String miscUpdateDialogTitle(String version) {
    return 'Update auf $version';
  }

  @override
  String get miscUpdateDownloading => 'Wird geladen…';

  @override
  String miscUpdateDownloadingPercent(int percent) {
    return 'Wird geladen… $percent %';
  }

  @override
  String miscUpdateFailed(String error) {
    return 'Update fehlgeschlagen: $error';
  }

  @override
  String miscUpdateInstalledVersion(String version) {
    return 'Installierte Version: $version';
  }

  @override
  String get miscUpdateLocalBuild =>
      'Diese Version wurde lokal gebaut und aktualisiert sich nicht selbst.';

  @override
  String get miscUpdateAuto => 'Beim Start automatisch aktualisieren';

  @override
  String get miscUpdateAutoHint =>
      'Neue Versionen werden beim Start geladen und installiert.';

  @override
  String get miscUpdateChecking => 'Suche nach Updates…';

  @override
  String miscUpdateAvailable(String version) {
    return 'Neue Version $version verfügbar.';
  }

  @override
  String get miscUpdateNow => 'Jetzt aktualisieren';

  @override
  String get miscUpdateUpToDate =>
      'Die App ist aktuell (oder der Update-Server ist nicht erreichbar).';

  @override
  String get miscUpdateCheckAgain => 'Erneut suchen';

  @override
  String get miscUpdateAllowUnknownApps =>
      'Bitte „Unbekannte Apps installieren“ für Home System erlauben und das Update erneut starten.';

  @override
  String miscUpdateInstallCancelled(int code) {
    return 'Installation abgebrochen ($code).';
  }

  @override
  String miscUpdateDownloadFailed(int status) {
    return 'Download fehlgeschlagen (HTTP $status).';
  }

  @override
  String get miscUpdateCorrupt => 'Die heruntergeladene Datei ist beschädigt.';

  @override
  String get miscAllAppsTitle => 'Alle Apps';

  @override
  String get miscAllAppsOpen => 'Öffnen';

  @override
  String get miscAllAppsAddFavorite => 'Zu den Favoriten hinzufügen';

  @override
  String get miscAllAppsRemoveFavorite => 'Aus den Favoriten entfernen';

  @override
  String get miscAllAppsAppInfo => 'App-Info (beenden, deinstallieren …)';

  @override
  String miscAllAppsFavoriteAdded(String app) {
    return '„$app“ zu den Favoriten hinzugefügt';
  }

  @override
  String miscAllAppsFavoriteRemoved(String app) {
    return '„$app“ aus den Favoriten entfernt';
  }

  @override
  String get miscAllAppsSearch => 'App suchen';

  @override
  String get miscAllAppsClearSearch => 'Suche löschen';

  @override
  String get miscAllAppsSettingsIsFavorite =>
      'TV-Einstellungen in den Favoriten';

  @override
  String get miscAllAppsSettingsAddFavorite => 'TV-Einstellungen als Favorit';

  @override
  String get miscAllAppsHelp =>
      'OK: App öffnen  ·  ☰ oder OK lange drücken: Favorit, App-Info (beenden, deinstallieren)';

  @override
  String miscAllAppsLoadError(String error) {
    return 'Apps konnten nicht gelesen werden: $error';
  }

  @override
  String get miscAllAppsNone => 'Keine Apps gefunden.';

  @override
  String miscAllAppsNoMatch(String query) {
    return 'Keine App passt zu „$query“.';
  }

  @override
  String get miscBackdropAurora => 'Nordlicht';

  @override
  String get miscBackdropSunset => 'Abendrot';

  @override
  String get miscBackdropOcean => 'Ozean';

  @override
  String get miscBackdropForest => 'Wald';

  @override
  String get miscBackdropLavender => 'Lavendel';

  @override
  String get miscBackdropEmbers => 'Glut';

  @override
  String get miscBackdropNight => 'Nacht';

  @override
  String get miscBackdropDesert => 'Wüste';

  @override
  String get modelsAcarsAckNoContent => 'Quittung (ohne Inhalt)';

  @override
  String get modelsAcarsLinkTest => 'Verbindungstest';

  @override
  String get modelsAcarsOnboardComputer => 'Bordrechner (FMS/Wartung)';

  @override
  String get modelsAcarsSystemStatus => 'Systemstatus';

  @override
  String get modelsAcarsAirlineMessage => 'Airline-Meldung';

  @override
  String get modelsAcarsFlightData => 'Flugdaten';

  @override
  String get modelsAcarsMessage => 'Meldung';

  @override
  String get modelsAircraftLight => 'Leichtflugzeug';

  @override
  String get modelsAircraftLightShort => 'leicht';

  @override
  String get modelsAircraftSmall => 'Kleinflugzeug';

  @override
  String get modelsAircraftSmallShort => 'klein';

  @override
  String get modelsAircraftLarge => 'Verkehrsflugzeug';

  @override
  String get modelsAircraftLargeShort => 'groß';

  @override
  String get modelsAircraftHeavy => 'Großraumflugzeug';

  @override
  String get modelsAircraftHeavyShort => 'schwer';

  @override
  String get modelsAircraftHighPerformance => 'Hochleistungs-/Militärjet';

  @override
  String get modelsAircraftGlider => 'Segelflugzeug';

  @override
  String get modelsAircraftGliderShort => 'Segler';

  @override
  String get modelsAircraftBalloon => 'Ballon / Luftschiff';

  @override
  String get modelsAircraftUltralight => 'Ultraleicht / Gleitschirm';

  @override
  String get modelsAircraftUav => 'Drohne';

  @override
  String get modelsAircraftSurface => 'Bodenfahrzeug';

  @override
  String get modelsAircraftSurfaceShort => 'Boden';

  @override
  String get modelsDmrRadio => 'Funkgerät';

  @override
  String get modelsDmrDirect => 'Direktverbindung';

  @override
  String get modelsIsmRemoteSwitch => 'Funkschalter (EV1527)';

  @override
  String modelsIsmButton(String code) {
    return 'Taste $code';
  }

  @override
  String get nasTitle => 'NAS (Netzwerkspeicher)';

  @override
  String get nasIntro =>
      'Der Netzwerkspeicher im eigenen Netz: Backups vor jedem Update, Hintergrundbilder für Home - und später Musik, Videos und Filme vom Server.';

  @override
  String get nasServerSection => 'Server';

  @override
  String get nasProtocolWebdav => 'WebDAV';

  @override
  String get nasProtocolWebdavHint =>
      'Synology, QNAP, Nextcloud, Apache/nginx … - über http oder https.';

  @override
  String get nasProtocolFtp => 'FTP';

  @override
  String get nasProtocolFtpHint =>
      'Unverschlüsselt - nur im eigenen Netz verwenden.';

  @override
  String get nasHost => 'Server-Adresse (IP oder Name)';

  @override
  String get nasHostHint => 'z. B. 192.168.1.10';

  @override
  String nasPort(int port) {
    return 'Port (leer = $port)';
  }

  @override
  String get nasHttps => 'Verschlüsselt (https)';

  @override
  String get nasHttpsHint =>
      'Das Zertifikat des NAS wird akzeptiert, auch wenn es selbst signiert ist.';

  @override
  String get nasBasePath => 'WebDAV-Pfad';

  @override
  String get nasBasePathHint => 'leer, oder z. B. /remote.php/dav/files/NAME';

  @override
  String get nasUser => 'Benutzername';

  @override
  String get nasPassword => 'Passwort';

  @override
  String get nasTest => 'Verbindung testen';

  @override
  String nasTestOk(int count) {
    return 'Verbindung OK - $count Einträge im Hauptordner.';
  }

  @override
  String nasTestFailed(String message) {
    return 'Keine Verbindung: $message';
  }

  @override
  String get nasFoldersSection => 'Ordner';

  @override
  String get nasFoldersHint =>
      'OK wählt einen Ordner auf dem NAS. Musik, Videos und Filme sind für später (Abspielen vom Server).';

  @override
  String get nasNeedServer => 'Zuerst die Server-Adresse eintragen.';

  @override
  String get nasFolderPictures => 'Bilder';

  @override
  String get nasFolderMusic => 'Musik';

  @override
  String get nasFolderVideos => 'Videos';

  @override
  String get nasFolderMovies => 'Filme';

  @override
  String get nasFolderBackups => 'Backups';

  @override
  String get nasFolderNotChosen => 'Nicht gewählt';

  @override
  String get nasFolderClear => 'Auswahl entfernen';

  @override
  String nasBackupsHint(int count) {
    return 'Vor jedem Update wird ein Backup in den Backup-Ordner gelegt; die $count neuesten dieses Geräts bleiben.';
  }

  @override
  String get nasPicturesHint =>
      'Die Bilder können der Hintergrund von Home sein (Einstellungen → Home → Hintergrund → Eigener Server).';

  @override
  String nasBrowseTitle(String folder) {
    return 'Ordner für $folder';
  }

  @override
  String get nasChooseThisFolder => 'Diesen Ordner wählen';

  @override
  String get nasUp => 'Eine Ebene höher';

  @override
  String get nasNoSubfolders => 'Keine Unterordner.';

  @override
  String nasFilesInFolder(int count) {
    return '$count Dateien in diesem Ordner';
  }

  @override
  String get nasBrowseBackHint => 'Zurück: eine Ebene höher';

  @override
  String get nasErrorTimeout =>
      'Der Server antwortet nicht (Zeitüberschreitung).';

  @override
  String get nasErrorTls =>
      'Die verschlüsselte Verbindung klappt nicht - stimmen https und der Port?';

  @override
  String get nasErrorRefused =>
      'Der Server lehnt die Verbindung ab - stimmen Protokoll und Port?';

  @override
  String get nasErrorHostNotFound => 'Server-Name nicht gefunden.';

  @override
  String get nasErrorUnreachable => 'Server nicht erreichbar.';

  @override
  String nasErrorOther(String message) {
    return 'Fehler: $message';
  }

  @override
  String get nasErrorLogin =>
      'Anmeldung fehlgeschlagen - Benutzername oder Passwort falsch, oder keine Berechtigung.';

  @override
  String get nasErrorNotFound => 'Ordner oder Datei nicht gefunden.';

  @override
  String get nasErrorNoWebDav =>
      'Der Server antwortet nicht wie ein WebDAV-Server - stimmt der WebDAV-Pfad?';

  @override
  String get nasErrorFull => 'Auf dem NAS ist kein Platz mehr.';

  @override
  String nasErrorHttp(int status) {
    return 'Der Server meldet den HTTP-Fehler $status.';
  }

  @override
  String get nasErrorTooBig => 'Die Datei ist zu groß.';

  @override
  String nasErrorFtp(String reply) {
    return 'Der FTP-Server meldet: $reply';
  }

  @override
  String get nasBackupRunning => 'Backup auf das NAS …';

  @override
  String nasBackupFailed(String message) {
    return 'Backup auf das NAS fehlgeschlagen ($message) - das Update läuft trotzdem.';
  }

  @override
  String get nasRestoreSection => 'Backups auf dem NAS';

  @override
  String nasRestoreHint(String folder) {
    return 'Aus dem Backup-Ordner $folder - auch die anderer Geräte.';
  }

  @override
  String get nasRestoreNone => 'Keine Backups im NAS-Ordner.';

  @override
  String nasRestoreLoadFailed(String message) {
    return 'Die Backups auf dem NAS konnten nicht gelesen werden: $message';
  }

  @override
  String nasRestoreDownloadFailed(String message) {
    return 'Das Backup konnte nicht vom NAS geladen werden: $message';
  }

  @override
  String get nasBgFromNas => 'Bilderordner vom NAS';

  @override
  String nasBgFromNasHint(String folder) {
    return '$folder (mit Unterordnern) - davon jedes Mal ein zufälliges Bild. Bis zu 30 Bilder liegen verkleinert auf dem Gerät; abgeglichen wird beim App-Start und mit „Jetzt abgleichen“.';
  }

  @override
  String get nasBgNoFolder =>
      'Zuerst unter Einstellungen → System → NAS einen Bilderordner wählen.';

  @override
  String get nasBgFromUrl => 'Adresse (http)';

  @override
  String get nasBgFromUrlHint =>
      'Ein Webserver, der Bilder liefert (siehe unten).';

  @override
  String get nasBgSyncNow => 'Jetzt abgleichen';

  @override
  String get nasBgSyncing => 'Wird abgeglichen …';

  @override
  String nasBgStatus(int count) {
    return '$count Bilder auf dem Gerät';
  }

  @override
  String nasBgLastSync(int count, String date) {
    return '$count Bilder auf dem Gerät, abgeglichen am $date';
  }

  @override
  String nasBgSyncError(String message) {
    return 'Abgleich fehlgeschlagen: $message';
  }

  @override
  String get radioErrorConnectionLost =>
      'Verbindung zum Sender verloren - versuche erneut…';

  @override
  String get radioErrorStationUnreachable =>
      'Sender nicht erreichbar - versuche erneut…';

  @override
  String radioErrorPlayback(String message) {
    return 'Wiedergabefehler: $message';
  }

  @override
  String get radioSourceFm => 'UKW';

  @override
  String get radioSourceInternet => 'Internetradio';

  @override
  String get radioMoonNew => 'Neumond';

  @override
  String get radioMoonWaxingCrescent => 'Zunehmende Sichel';

  @override
  String get radioMoonFirstQuarter => 'Zunehmender Halbmond';

  @override
  String get radioMoonWaxingGibbous => 'Zunehmender Dreiviertelmond';

  @override
  String get radioMoonFull => 'Vollmond';

  @override
  String get radioMoonWaningGibbous => 'Abnehmender Dreiviertelmond';

  @override
  String get radioMoonLastQuarter => 'Abnehmender Halbmond';

  @override
  String get radioMoonWaningCrescent => 'Abnehmende Sichel';

  @override
  String get radioFmSameProgrammeStronger => '(stärker)';

  @override
  String get radioFmSameProgrammeWeaker => '(schwächer)';

  @override
  String radioFmSameProgrammeAlsoOn(String frequency) {
    return 'auch auf $frequency';
  }

  @override
  String get radioDabEnsembleUnknown => 'Ensemble unbekannt';

  @override
  String radioPlaceSearchFailed(int code) {
    return 'Ortssuche: HTTP $code';
  }

  @override
  String get radioProgramNumberTitle => 'Programmnummer vergeben';

  @override
  String get radioEditStationTitle => 'Sender bearbeiten';

  @override
  String get radioEditStationName => 'Name';

  @override
  String get radioEditStationSearchLogo => 'Logo suchen';

  @override
  String get radioEditStationUseLiveImage => 'Aktuelles Senderbild übernehmen';

  @override
  String get radioEditStationNewLogoHint =>
      'Neues Logo - wird mit „Speichern“ übernommen.';

  @override
  String get radioLogoDabIdle =>
      'Holt das Bild, das der Sender selbst ausstrahlt.';

  @override
  String get radioLogoDabWaiting =>
      'Warte auf ein Bild vom Sender (bis etwa 30 s)…';

  @override
  String get radioLogoDabUseImage => 'Dieses Bild übernehmen';

  @override
  String get radioLogoDabNone =>
      'Der Sender hat in der Zeit kein Bild gesendet.';

  @override
  String get radioDabDecoderFailed =>
      'DAB+-Decoder konnte nicht gestartet werden.';

  @override
  String get radioLogoDabFetch => 'DAB-Logo holen';

  @override
  String get radioLogoTitle => 'Logo wählen';

  @override
  String get radioLogoSearchInternet => 'Im Internet suchen (Sendername)';

  @override
  String get radioLogoNoResults => 'Keine Treffer mit Logo.';

  @override
  String get radioLogoOwnUrl => 'oder eigene Bild-Adresse (URL)';

  @override
  String get radioRegionEurope => 'Europa';

  @override
  String get radioRegionNorthAmerica => 'Nord- & Mittelamerika';

  @override
  String get radioRegionSouthAmerica => 'Südamerika';

  @override
  String get radioRegionAsia => 'Asien & Nahost';

  @override
  String get radioRegionAfrica => 'Afrika';

  @override
  String get radioRegionOceania => 'Ozeanien';

  @override
  String get radioRegionOther => 'Andere';

  @override
  String radioSavedAsNumber(String name, int number) {
    return '\"$name\" als Nr. $number gespeichert.';
  }

  @override
  String get radioSearchInternetTitle => 'Internetradio suchen';

  @override
  String get radioSearchStationName => 'Sendername';

  @override
  String get radioSearchGenre => 'Genre';

  @override
  String get radioSearchAllGenres => 'Alle Genres';

  @override
  String get radioSearchRegion => 'Region';

  @override
  String get radioSearchAllRegions => 'Alle Regionen';

  @override
  String get radioSearchCountry => 'Land';

  @override
  String get radioSearchAllCountries => 'Alle Länder';

  @override
  String get radioSearchButton => 'Suchen';

  @override
  String get radioSearchNoResults => 'Keine Ergebnisse.';

  @override
  String get radioStop => 'Stopp';

  @override
  String get radioSearchPreview => 'Probehören';

  @override
  String get radioSearchAddFavorite => 'Favorit';

  @override
  String get radioDabClearAllTitle => 'Alle DAB-Sender löschen?';

  @override
  String get radioDabClearAllMessage =>
      'Entfernt alle bisher gefundenen DAB+-Sender aus der Liste \"Alle DAB+ Sender\" und alle DAB+-Favoriten. Kann nicht rückgängig gemacht werden.';

  @override
  String get radioDabTitle => 'DAB+ Sender';

  @override
  String get radioScanTitle => 'Sendersuchlauf';

  @override
  String get radioDabClearAll => 'Alle DAB-Sender löschen';

  @override
  String get radioFavorites => 'Favoriten';

  @override
  String get radioDabNoFavorites => 'Noch keine DAB+-Favoriten.';

  @override
  String get radioDabAllStations => 'Alle DAB+ Sender';

  @override
  String get radioDabSortGrouped => 'Nach Ensemble gruppiert';

  @override
  String get radioDabSortByEnsemble => 'Nach Ensemble sortiert';

  @override
  String get radioDabSortByName => 'Nach Name';

  @override
  String get radioDabNoStations =>
      'Noch keine Sender gefunden. Sendersuchlauf starten.';

  @override
  String get radioLogoReceiveAllHaveLogo => 'Alle Sender haben schon ein Logo.';

  @override
  String radioLogoReceiveProgress(int index, int total) {
    return 'Sender $index von $total - warte auf ein Bild vom Sender…';
  }

  @override
  String radioLogoReceiveDone(int found, int total) {
    return 'Fertig: $found von $total Sendern haben ein Bild gesendet.';
  }

  @override
  String get radioLogoReceiveTitle => 'Fehlende Logos per Empfang';

  @override
  String get radioLogoReceiveStart => 'Fehlende Logos per Empfang holen';

  @override
  String get radioListen => 'Anhören';

  @override
  String get radioEditNameLogo => 'Bearbeiten (Name, Logo)';

  @override
  String get radioRemoveFavorite => 'Favorit entfernen';

  @override
  String radioProgramNumberChip(int number) {
    return 'Nr. $number';
  }

  @override
  String get radioAddFavorite => 'Favorit hinzufügen';

  @override
  String get radioSourceUsbHint =>
      'Quelle: RTL-SDR-Stick per USB - siehe \"Radio-Empfänger\" in den Einstellungen.';

  @override
  String get radioSourceNetworkHint =>
      'Quelle: RTL-SDR über Netzwerk - siehe \"Radio-Empfänger\" in den Einstellungen.';

  @override
  String get radioScanStart => 'Sendersuchlauf starten';

  @override
  String get radioDabSingleChannel => 'Einzelnen Kanal suchen:';

  @override
  String radioDabSearchChannel(String channel) {
    return '$channel suchen';
  }

  @override
  String radioPlaybackOfFailed(String name) {
    return 'Wiedergabe von \"$name\" fehlgeschlagen.';
  }

  @override
  String radioDabSearchChannelTitle(String channel) {
    return 'Kanal $channel suchen';
  }

  @override
  String radioDabScanningChannel(String channel, int freqKhz) {
    return 'Suche auf $channel ($freqKhz kHz), bis zu 15 Sekunden…';
  }

  @override
  String radioDabScanProgressOf(int index, int total, String label) {
    return 'Kanal $index von $total: $label';
  }

  @override
  String radioDabScanProgress(int index, String label) {
    return 'Kanal $index: $label';
  }

  @override
  String radioDabChannelNothingFound(String channel) {
    return 'Auf $channel wurde kein DAB+-Ensemble empfangen.';
  }

  @override
  String radioDabScanDone(int ensembles, int stations) {
    return 'Fertig: $ensembles Ensemble(s) mit $stations Sender(n) gefunden. Alle gefundenen Sender stehen unter \"Alle DAB+ Sender\".';
  }

  @override
  String get radioDabNoEnsemblesYet => 'Noch keine Ensembles gefunden…';

  @override
  String get radioDabEnsembleNameUnknown => 'Ensemble-Name unbekannt';

  @override
  String get radioDabEnsembleNoServices =>
      'Sender in diesem Ensemble noch nicht erkannt (kurz erneut versuchen).';

  @override
  String get radioPlayingShort => 'Läuft…';

  @override
  String get radioStopPlayback => 'Wiedergabe stoppen';

  @override
  String get radioFmClearAllTitle => 'Alle UKW-Sender löschen?';

  @override
  String get radioFmClearAllMessage =>
      'Entfernt alle gespeicherten UKW-Sender aus der Liste. UKW-Favoriten bleiben erhalten.';

  @override
  String get radioFmTitle => 'UKW-Sender (FM)';

  @override
  String get radioFmFindStations => 'Sender suchen';

  @override
  String get radioFmTuneManually => 'Manuell einstellen';

  @override
  String get radioFmAllStations => 'Alle UKW-Sender';

  @override
  String get radioDeleteAll => 'Alle löschen';

  @override
  String get radioFmNoStations =>
      'Noch keine UKW-Sender. Suchlauf starten oder einen Sender manuell einstellen und speichern.';

  @override
  String radioFmSignal(String level) {
    return 'Signal $level';
  }

  @override
  String get radioRemoveStation => 'Sender entfernen';

  @override
  String get radioFmScanTitle => 'UKW-Sendersuchlauf';

  @override
  String get radioReceiverFailed => 'Empfänger konnte nicht gestartet werden.';

  @override
  String get radioSearching => 'Suche…';

  @override
  String radioFmScanSurvey(String frequency) {
    return 'Schritt 1/2: Band wird vermessen ($frequency)…';
  }

  @override
  String radioFmScanProbe(int index, int total, String frequency) {
    return 'Schritt 2/2: Prüfe Sender $index von $total ($frequency)…';
  }

  @override
  String radioFmScanDone(int count) {
    return 'Fertig: $count Sender gefunden und gespeichert.';
  }

  @override
  String radioFmScanImagesRemoved(int count) {
    return '$count schwache Störfrequenz(en) aussortiert.';
  }

  @override
  String get radioFmSeekNothingFound => 'Kein weiterer Sender gefunden.';

  @override
  String get radioFmFrequencyTitle => 'Frequenz in MHz';

  @override
  String get radioFmFrequencyHint => 'z. B. 99,9';

  @override
  String radioSaved(String name) {
    return '$name gespeichert.';
  }

  @override
  String get radioFmTuneTitle => 'UKW manuell einstellen';

  @override
  String get radioFmNoRdsName => 'kein RDS-Name';

  @override
  String get radioFmSeek => 'Suchen';

  @override
  String get radioFmStepDown => '−0,05';

  @override
  String get radioFmStepUp => '+0,05';

  @override
  String get radioFmEnterFrequency => 'Frequenz eingeben';

  @override
  String get radioFmSaveStation => 'Als Sender speichern';

  @override
  String get radioFmSaveFavorite => 'Als Favorit speichern';

  @override
  String get radioNoStationSelected => 'Kein Sender ausgewählt';

  @override
  String get radioStoppedDisconnected => 'Gestoppt - Verbindung getrennt';

  @override
  String get radioNowPlaying => 'Wiedergabe läuft';

  @override
  String get radioPaused => 'Pausiert';

  @override
  String get radioPlay => 'Abspielen';

  @override
  String get radioWeatherUnavailable =>
      'Wetter nicht verfügbar - versuche erneut…';

  @override
  String get radioWeatherNoData => 'Keine Daten';

  @override
  String get radioWeatherTemp => 'Temp';

  @override
  String get radioWeatherWind => 'Wind km/h';

  @override
  String get radioWeatherRain => 'Regen l/m²';

  @override
  String radioWeatherRainAmount(String amount) {
    return '$amount l';
  }

  @override
  String get radioSunrise => 'Sonnenaufgang';

  @override
  String get radioSunset => 'Sonnenuntergang';

  @override
  String get radioDawn => 'Morgendämmerung';

  @override
  String get radioSolarNoon => 'Mittag';

  @override
  String get radioDusk => 'Abenddämmerung';

  @override
  String radioRadarLoginRejected(int code) {
    return 'Anmeldung abgelehnt (HTTP $code)';
  }

  @override
  String get radioRadarIsWebPage =>
      'die Adresse ist eine Webseite, kein Bild - als Art „Webseite“ wählen';

  @override
  String get radioRadarNotConfigured =>
      'Kein Wetterradar eingerichtet -\nEinstellungen → Wetterradar → Quelle';

  @override
  String get radioRadarWebPageAndroidOnly =>
      'Webseiten als Radarquelle gibt es nur in der Android-Version.';

  @override
  String radioRadarUnreachable(String error) {
    return 'Radar nicht erreichbar: $error';
  }

  @override
  String radioRadarStale(String time) {
    return 'Stand $time · nicht erreichbar';
  }

  @override
  String get radioLinkSourceLost => 'Verbindung zur RTL-SDR-Quelle verloren';

  @override
  String get radioLinkDabSignalFound => 'DAB-Signal gefunden';

  @override
  String radioLinkEnsembleFound(String label) {
    return 'Ensemble „$label“ gefunden';
  }

  @override
  String get radioLinkStationFound => 'Sender gefunden - Audio startet…';

  @override
  String get radioLinkConnected => 'Sender verbunden';

  @override
  String get radioLinkConnectingServer => 'Verbinde mit dem RTL-Server…';

  @override
  String get radioLinkWaitingForStick => 'Warte auf den Stick am Server…';

  @override
  String get radioLinkOpeningUsbStick => 'USB-Stick wird geöffnet…';

  @override
  String get radioLinkTuning => 'Sender wird eingestellt…';

  @override
  String radioLinkTuningFrequency(String frequency) {
    return '$frequency wird eingestellt…';
  }

  @override
  String get radioLinkSearching => 'Sender wird gesucht…';

  @override
  String radioLinkSearchingChannel(String channel) {
    return 'Kanal $channel wird gesucht…';
  }

  @override
  String get radioLinkApp => 'App';

  @override
  String get radioLinkRtlServer => 'RTL-Server';

  @override
  String get radioLinkStick => 'Stick';

  @override
  String get radioLinkUsbStick => 'USB-Stick';

  @override
  String get radioLinkStation => 'Sender';

  @override
  String get radioLinkTvChannel => 'Sender';

  @override
  String get radioDone => 'Fertig';

  @override
  String get radioEditFavorites => 'Favoriten bearbeiten';

  @override
  String get radioEditFavoritesHint =>
      'Reihenfolge ändern, umbenennen oder entfernen - mit ✓ fertig.';

  @override
  String radioFavoritesLoadError(String error) {
    return 'Fehler beim Laden der Favoriten:\n$error';
  }

  @override
  String get radioNoFavorites =>
      'Noch keine Favoriten.\nSuche Sender über das Menü.';

  @override
  String get radioRemoveFavoriteTitle => 'Favorit entfernen?';

  @override
  String radioRemoveFavoriteMessage(String name) {
    return '„$name“ aus den Favoriten entfernen?';
  }

  @override
  String get radioRemove => 'Entfernen';

  @override
  String get radioSidebarNoFmStations =>
      'Noch keine UKW-Sender.\nSuchlauf oder manuelles Einstellen über das UKW-Menü oben.';

  @override
  String radioDabStationsLoadError(String error) {
    return 'Fehler beim Laden der DAB+ Sender:\n$error';
  }

  @override
  String get radioSidebarNoDabStations =>
      'Noch keine DAB+ Sender gefunden.\nSendersuchlauf über das DAB-Menü starten.';

  @override
  String get radioMoveUp => 'Nach oben';

  @override
  String get radioMoveDown => 'Nach unten';

  @override
  String get radioLinkBuffering => 'Stream wird gepuffert…';

  @override
  String get radioLinkConnectingStation => 'Verbinde mit dem Sender…';

  @override
  String get radioPausedOtherApp =>
      'Pausiert - eine andere App spielt Audio ab.';

  @override
  String get radioSourceLostReconnecting =>
      'Verbindung zur RTL-SDR-Quelle verloren - versuche erneut zu verbinden…';

  @override
  String get radioUsbStickDetached =>
      'USB-Stick getrennt - warte auf Wiederanschluss…';

  @override
  String get radioNoReceiverConfigured =>
      'Kein Radio-Empfänger eingerichtet (Einstellungen)';

  @override
  String get radioFmReceptionFailedDot => 'UKW-Empfang fehlgeschlagen.';

  @override
  String get radioFmReceptionFailed => 'UKW-Empfang fehlgeschlagen';

  @override
  String get radioSourceUnreachableRetrying =>
      'RTL-SDR-Quelle nicht erreichbar - versuche erneut…';

  @override
  String get radioSourceUnreachable => 'RTL-SDR-Quelle nicht erreichbar.';

  @override
  String get radioRtlServerUnreachableRetrying =>
      'RTL-Server nicht erreichbar - versuche erneut…';

  @override
  String get radioRtlServerUnreachable => 'RTL-Server nicht erreichbar';

  @override
  String get radioUsbStickNotFound =>
      'USB-Stick nicht gefunden oder kein Zugriff';

  @override
  String get radioNoSignalRetrying => 'Kein Signal! - Versuche erneut…';

  @override
  String get radioNoSignal => 'Kein Signal!';

  @override
  String get radioLinkNoSignalRetrying => 'Kein Signal - versuche erneut…';

  @override
  String get radioMenuListening => 'Funk';

  @override
  String get radioMenuDabStations => 'DAB Sender suchen';

  @override
  String get radioMenuAmBands => 'LW/MW/KW';

  @override
  String get radioMenuSettings => 'Radio-Einstellungen';

  @override
  String scannerQuoted(String name) {
    return '„$name“';
  }

  @override
  String scannerRtlUnreachable(String server, String error) {
    return 'rtl_tcp-Server $server nicht erreichbar ($error)';
  }

  @override
  String scannerRtlConnectionLost(String error) {
    return 'Verbindung zum rtl_tcp-Server unterbrochen ($error)';
  }

  @override
  String get scannerRtlRefused =>
      'rtl_tcp-Server hat die Verbindung abgelehnt (belegt oder kein Stick bereit)';

  @override
  String get scannerRtlConnectionClosed =>
      'Verbindung zum rtl_tcp-Server beendet';

  @override
  String get scannerRtlNoAnswer => 'rtl_tcp-Server antwortet nicht';

  @override
  String get scannerRtlNotAServer =>
      'Kein rtl_tcp-Server (unbekannte Begrüßung)';

  @override
  String get scannerRtlBadStream => 'rtl_tcp-Server: Datenstrom fehlerhaft';

  @override
  String get scannerRtlStickAtServer => 'USB-Stick am rtl_tcp-Server';

  @override
  String get scannerRtlAuthUnsupported =>
      'rtl_tcp-Server verlangt eine Anmeldung, das wird nicht mehr unterstützt. Bitte den rtltcp.server im lokalen Netz verwenden.';

  @override
  String scannerRtlStickReady(String stick) {
    return '$stick bereit';
  }

  @override
  String scannerRtlStickStarting(String stick) {
    return '$stick startet …';
  }

  @override
  String scannerRtlStickNotReady(String stick) {
    return '$stick nicht bereit';
  }

  @override
  String scannerRtlStickLost(String stick) {
    return '$stick getrennt – der Server verbindet neu …';
  }

  @override
  String get scannerRtlServer => 'rtl_tcp-Server';

  @override
  String scannerRtlBusy(String who) {
    return '$who wird bereits von einem anderen Gerät verwendet';
  }

  @override
  String scannerRtlBusyBy(String who, String client) {
    return '$who wird bereits von $client verwendet';
  }

  @override
  String get scannerRtlKicked => 'Vom rtl_tcp-Server getrennt';

  @override
  String get scannerRtlProtocolError =>
      'rtl_tcp-Server meldet einen Protokollfehler';

  @override
  String scannerRtlServerSays(String message) {
    return 'rtl_tcp-Server: $message';
  }

  @override
  String get scannerRtlStateStarting => 'startet';

  @override
  String get scannerRtlStateNotReady => 'nicht bereit';

  @override
  String get scannerRtlStateLost => 'getrennt';

  @override
  String get scannerRtlStateIdle => 'ruht';

  @override
  String scannerRtlSticksOn(String host) {
    return 'Sticks auf $host';
  }

  @override
  String scannerRtlLocation(String location) {
    return 'Standort: $location';
  }

  @override
  String scannerRtlAntenna(String antenna) {
    return 'Antenne: $antenna';
  }

  @override
  String get scannerRtlNotSpecified => 'nicht angegeben';

  @override
  String scannerRtlVia(String instance) {
    return 'über $instance';
  }

  @override
  String scannerRtlBusyByShort(String client) {
    return 'belegt von $client';
  }

  @override
  String get scannerRtlReceiverTitle => 'Radio-Empfänger (DAB+ & UKW)';

  @override
  String get scannerRtlReceiverLabel => 'Empfänger:';

  @override
  String get scannerRtlModeNone => 'Kein Empfänger (nur Internetradio)';

  @override
  String get scannerRtlModeUsb => 'RTL-SDR-Stick per USB';

  @override
  String get scannerRtlModeTcp => 'RTL-SDR über Netzwerk (rtl_tcp)';

  @override
  String get scannerRtlNoneHint =>
      'DAB+- und UKW-Suche sowie die Reiter „DAB+“ und „FM“ sind ausgeblendet. Vorhandene Favoriten bleiben erhalten und spielen wieder, sobald ein Empfänger eingerichtet ist.';

  @override
  String get scannerRtlUsbHint =>
      'Der Empfänger öffnet den Stick direkt über USB, sobald ein Sender startet.';

  @override
  String get scannerRtlUsbWindows =>
      'Windows: einmalig den WinUSB-Treiber mit Zadig (zadig.akeo.ie) für „Bulk-In, Interface (Interface 0)“ installieren.';

  @override
  String get scannerRtlUsbLinux =>
      'Linux: braucht eine udev-Regel für den Stick (z. B. aus dem Paket rtl-sdr); der DVB-T-Treiber des Kernels wird automatisch abgekoppelt.';

  @override
  String get scannerRtlNoStick => 'Kein RTL-SDR-Stick erkannt.';

  @override
  String get scannerRtlAllowAccess => 'Zugriff erlauben';

  @override
  String get scannerRtlAccessGranted => 'Zugriff erteilt';

  @override
  String get scannerRtlRescan => 'Neu suchen';

  @override
  String get scannerRtlTcpHint =>
      'rtl_tcp-Server im lokalen Netz: Treiber-App auf diesem Gerät (127.0.0.1), Raspberry Pi oder rtltcp.server. Der markierte Server ist der Standard für DAB+ und UKW. Sticks an anderen Standorten stellt der rtltcp.server über rtl.over.internet lokal bereit.';

  @override
  String get scannerRtlAddServer => 'Server hinzufügen';

  @override
  String get scannerRtlTestHint =>
      '„Testen“ unterbricht DAB+ oder UKW, wenn es über diesen Server läuft; der Sender spielt beim Zurückkehren weiter.';

  @override
  String get scannerRtlDefault => 'Standard';

  @override
  String get scannerRtlTest => 'Testen';

  @override
  String scannerRtlChooseStick(int count) {
    return 'Stick wählen ($count)';
  }

  @override
  String get scannerRtlRemove => 'Entfernen';

  @override
  String get scannerRtlNoConnection => 'Keine Verbindung';

  @override
  String get scannerRtlClassicServer =>
      'rtl_tcp – Server unterstützt Standort und Antenne nicht';

  @override
  String scannerRtlProtocol(String name) {
    return 'Protokoll: $name';
  }

  @override
  String scannerRtlTunerInfo(String type, String gains) {
    return 'Tuner-Typ: $type, $gains Gain-Stufen';
  }

  @override
  String get scannerAprsCompass => 'N NO O SO S SW W NW';

  @override
  String get scannerAprsKindPosition => 'Position';

  @override
  String get scannerAprsKindWeather => 'Wetter';

  @override
  String get scannerAprsKindObject => 'Objekt';

  @override
  String get scannerAprsKindObjectDeleted => 'Objekt (gelöscht)';

  @override
  String get scannerAprsKindMessage => 'Nachricht';

  @override
  String get scannerAprsKindAck => 'Bestätigung';

  @override
  String get scannerAprsKindTelemetry => 'Telemetrie';

  @override
  String get scannerAprsKindCapabilities => 'Fähigkeiten';

  @override
  String get scannerAprsKindThirdParty => 'Weitergeleitet';

  @override
  String get scannerAprsKindData => 'Daten';

  @override
  String get scannerAprsKindEmpty => 'Leer';

  @override
  String scannerWind(String speed) {
    return 'Wind $speed km/h';
  }

  @override
  String scannerWindFrom(int degrees) {
    return 'aus $degrees°';
  }

  @override
  String scannerGusts(String speed) {
    return 'Böen $speed';
  }

  @override
  String scannerAprsRain(String rate) {
    return 'Regen $rate mm/h';
  }

  @override
  String get scannerAprsSymbolWeatherStation => 'Wetterstation';

  @override
  String get scannerAprsSymbolHouse => 'Haus';

  @override
  String get scannerAprsSymbolCar => 'Auto';

  @override
  String get scannerAprsSymbolAmbulance => 'Rettung';

  @override
  String get scannerAprsSymbolNode => 'Knoten';

  @override
  String get scannerAprsSymbolTruck => 'LKW';

  @override
  String get scannerAprsSymbolAircraft => 'Flugzeug';

  @override
  String get scannerAprsSymbolBalloon => 'Ballon';

  @override
  String get scannerAprsSymbolRepeater => 'Relais';

  @override
  String get scannerAprsSymbolRv => 'Wohnmobil';

  @override
  String get scannerAprsSymbolMotorcycle => 'Motorrad';

  @override
  String get scannerAprsSymbolBicycle => 'Fahrrad';

  @override
  String get scannerAprsSymbolPedestrian => 'Fußgänger';

  @override
  String get scannerAprsSymbolAntennaStation => 'Station mit Antenne';

  @override
  String get scannerAprsSymbolShip => 'Schiff';

  @override
  String get scannerAprsSymbolSmallAircraft => 'Kleinflugzeug';

  @override
  String get scannerAprsSymbolHelicopter => 'Hubschrauber';

  @override
  String get scannerAprsSymbolFireTruck => 'Feuerwehr';

  @override
  String get scannerAprsSymbolPolice => 'Polizei';

  @override
  String get scannerAprsSymbolSatellite => 'Satellit';

  @override
  String get scannerAprsSymbolTrain => 'Zug';

  @override
  String scannerChannel(String channel) {
    return 'Kanal $channel';
  }

  @override
  String get scannerBandCb => 'CB-Funk';

  @override
  String get scannerMarkEmergency => 'Notruf';

  @override
  String get scannerCbTruckers => 'Fernfahrer';

  @override
  String get scannerSegCbFm => 'Sprechfunk FM (Kanal 9 Notruf, 19 Fernfahrer)';

  @override
  String get scannerSegCbSsb => 'SSB-Bereich (Kanal 36–40)';

  @override
  String get scannerBandAir => 'Flugfunk';

  @override
  String get scannerBandMil => 'Militärfunk';

  @override
  String get scannerSegMilAir => 'Militärischer Flugfunk';

  @override
  String scannerBandHam(String band) {
    return 'Amateurfunk $band';
  }

  @override
  String get scannerSegCw => 'Telegrafie';

  @override
  String get scannerSegDigital => 'Digitale Betriebsarten';

  @override
  String get scannerSegVoiceLsb => 'Sprechfunk (LSB)';

  @override
  String get scannerSegVoiceUsb => 'Sprechfunk (USB)';

  @override
  String get scannerSegVoiceSsb => 'Sprechfunk (SSB)';

  @override
  String get scannerSegDigitalVoiceUsb => 'Digital & Sprechfunk (USB)';

  @override
  String get scannerSegBeacons => 'Baken';

  @override
  String get scannerSegDigitalAllModes => 'Digital & alle Betriebsarten';

  @override
  String get scannerSegBeaconsAllModes => 'Baken & alle Betriebsarten';

  @override
  String get scannerSegAmVoice => 'AM-Sprechfunk';

  @override
  String get scannerSegFmSimplex => 'FM-Direkt';

  @override
  String get scannerSegPacket => 'Digital (Packet)';

  @override
  String get scannerSegSatellites => 'Satelliten';

  @override
  String get scannerSegRepeaterInputs => 'FM-Relais-Eingaben';

  @override
  String get scannerSegRepeaterOutputs => 'FM-Relais-Ausgaben';

  @override
  String scannerSegFmSimplexCall(String frequency) {
    return 'FM-Direkt ($frequency Anruf)';
  }

  @override
  String get scannerMarkCall => 'Anruf';

  @override
  String get scannerSegCwBeacons => 'Telegrafie & Baken';

  @override
  String scannerSegSsbVoiceCall(String frequency) {
    return 'Sprechfunk (SSB, $frequency Anruf)';
  }

  @override
  String get scannerSegAllModes => 'Alle Betriebsarten';

  @override
  String get scannerSegCwEme => 'Telegrafie (EME)';

  @override
  String get scannerSegAllModesSstv => 'Alle Betriebsarten (SSTV, Digital)';

  @override
  String scannerSegDigitalAprs(String frequency) {
    return 'Digital ($frequency APRS)';
  }

  @override
  String scannerSegSatellitesIss(String frequency) {
    return 'Satelliten ($frequency ISS)';
  }

  @override
  String get scannerSegDigitalRepeaterInputs => 'Digital & Relais-Eingaben';

  @override
  String get scannerSegRepeaterInputsLpd =>
      'FM-Relais-Eingaben, LPD-Funkgeräte';

  @override
  String scannerSegFmSimplexCallLpd(String frequency) {
    return 'FM-Direkt ($frequency Anruf), LPD';
  }

  @override
  String scannerSegLpdIsm(String frequency) {
    return 'LPD-Funkgeräte & ISM ($frequency Sensoren)';
  }

  @override
  String get scannerMarkSensors => 'Sensoren';

  @override
  String get scannerSegRepeaterOutputsDigital =>
      'Relais-Ausgaben (auch DMR/C4FM)';

  @override
  String get scannerSegAtv => 'Amateurfernsehen (ATV)';

  @override
  String get scannerSegSatellitesUplink => 'Satelliten (Uplink)';

  @override
  String get scannerSegAtvDigital => 'ATV & Digital';

  @override
  String get scannerBandLongWave => 'Langwelle';

  @override
  String get scannerBandMediumWave => 'Mittelwelle';

  @override
  String scannerBandShortwave(String band) {
    return 'KW-Rundfunk $band';
  }

  @override
  String scannerUtilTimeSignal(String station) {
    return 'Zeitzeichen $station';
  }

  @override
  String scannerUtilWeatherFax(String station) {
    return 'Wetterfax $station';
  }

  @override
  String scannerUtilWeatherRtty(String station) {
    return 'Wetter-RTTY $station';
  }

  @override
  String get scannerBandHfUtility => 'KW-Funkdienste';

  @override
  String get scannerSegFmBroadcast => 'UKW-Rundfunk';

  @override
  String get scannerSegAirNavVorIls => 'Flugnavigation (VOR/ILS)';

  @override
  String get scannerSegWeatherSatellites => 'Wettersatelliten';

  @override
  String get scannerSegLandMobile => 'Betriebsfunk';

  @override
  String get scannerSegLandMobileBos => 'Betriebsfunk / BOS';

  @override
  String scannerSegMarine(String frequency) {
    return 'Seefunk (Kanal 16 = $frequency)';
  }

  @override
  String get scannerSegLandMobileRail => 'Betriebsfunk / Bahnfunk';

  @override
  String get scannerSegDab => 'DAB+ Band III (digital, nicht hörbar)';

  @override
  String get scannerSegRadiosondes => 'Wettersonden';

  @override
  String get scannerSegDistressBeacons => 'Notfunkbaken (digital)';

  @override
  String get scannerSegDvbt => 'Fernsehen DVB-T2 (digital)';

  @override
  String get scannerSegLte => 'Mobilfunk LTE (digital)';

  @override
  String get scannerSegSensorsLora => 'Funksensoren / LoRa 868';

  @override
  String get scannerSegGsm => 'Mobilfunk / GSM-R (digital)';

  @override
  String get scannerSegAirNavDme => 'Flugnavigation (DME)';

  @override
  String get scannerSegAdsb => 'ADS-B 1090 (→ Flugzeuge)';

  @override
  String get scannerSegGnss => 'Satellitennavigation (GNSS)';

  @override
  String get scannerSegSatPhone => 'Satelliten-Telefonie (Inmarsat)';

  @override
  String get scannerBandWorld => 'Freier Band-Scan';

  @override
  String get scannerJumpMarine => 'Seefunk Kanal 16';

  @override
  String get scannerJumpMilAir => 'Militärflugfunk';

  @override
  String get scannerSensors => 'Funksensoren';

  @override
  String scannerJumpRepeaters70(String frequency) {
    return 'Relais 70 cm ($frequency)';
  }

  @override
  String get scannerHubTitle => 'Funk';

  @override
  String get scannerHubCbSubtitle => '26,965–27,405 MHz · Kanal 1–40 (80)';

  @override
  String get scannerHubPmrSubtitle => '446,00625–446,19375 MHz · Kanal 1–16';

  @override
  String get scannerHubHam => 'Amateurfunk';

  @override
  String get scannerHubHamSubtitle => '160 m bis 23 cm mit Bandplan';

  @override
  String get scannerHubShortwave => 'Kurzwelle';

  @override
  String get scannerHubShortwaveSubtitle =>
      'KW-Rundfunk · Amateurfunk KW · Zeitzeichen & Flugwetter';

  @override
  String get scannerHubAircraft => 'Flugzeuge';

  @override
  String get scannerHubAircraftSubtitle => 'Flugfunk · ACARS · Radar (ADS-B)';

  @override
  String get scannerHubSensorsSubtitle =>
      '433/868 MHz · Thermometer, Wetterstationen, Schalter';

  @override
  String get scannerHubWorldSubtitle =>
      '0,5–1766 MHz frei abstimmen, Bänder eingezeichnet';

  @override
  String get scannerHubAirSubtitle => '118–137 MHz · Sprechfunk (AM)';

  @override
  String get scannerHubAcarsSubtitle =>
      '131,5–131,9 MHz · Textmeldungen von Flugzeugen';

  @override
  String get scannerHubAdsbSubtitle =>
      '1090 MHz · Flugnummer, Höhe, Position auf der Karte';

  @override
  String get scannerUpconverterNone =>
      'Keiner – Direct Sampling oder RTL-SDR Blog V4';

  @override
  String get scannerUpconverterDialogTitle => 'Aufwärtsmischer vor dem Stick';

  @override
  String get scannerUpconverter => 'Aufwärtsmischer';

  @override
  String get scannerHubHfHam => 'Amateurfunk KW';

  @override
  String get scannerHubHfHamSubtitle => '160 m bis 10 m · SSB, CW, FT8';

  @override
  String get scannerHubHfUtilitySubtitle =>
      'Zeitzeichen · VOLMET · Shanwick · Wetterfax';

  @override
  String get scannerHubShortwaveFooter =>
      'Kurzwelle braucht einen Stick mit Kurzwelleneingang: RTL-SDR Blog V3 (Direct Sampling, schaltet unter 24 MHz automatisch um), RTL-SDR Blog V4 (eingebauter Aufwärtsmischer; über rtl_tcp nur, wenn der Server ihn unterstützt) – oder einen beliebigen Stick mit einem Aufwärtsmischer wie dem Ham It Up. Gewöhnliche Sticks (z. B. NooElec NESDR) haben keinen. Dazu eine Antenne für Kurzwelle – eine Langdraht- oder Aktivantenne. Rundfunk auf Lang-, Mittel- und Kurzwelle: eigener Punkt „LW/MW/KW“ oben.';

  @override
  String get scannerRxWaiting => 'Warte auf Daten vom Stick…';

  @override
  String get scannerRxNoData => 'Keine Daten vom Stick';

  @override
  String get scannerRxSlow => 'Daten kommen zu langsam';

  @override
  String get scannerRxRunning => 'Empfang läuft';

  @override
  String get scannerRxLevel => 'Pegel';

  @override
  String get scannerRxClipping => 'übersteuert – Verstärkung senken';

  @override
  String get scannerMapAttribution => '© OpenStreetMap-Mitwirkende';

  @override
  String get scannerReceiverStartFailed =>
      'Empfänger konnte nicht gestartet werden.';

  @override
  String get scannerReceiverStarting => 'Starte Empfänger…';

  @override
  String get scannerGain => 'Verstärkung';

  @override
  String get scannerAcarsTitle => 'ACARS (Textmeldungen von Flugzeugen)';

  @override
  String get scannerAcarsVdl2Chip => 'VDL2 · 136,9 MHz';

  @override
  String get scannerAcarsClassicChip => 'ACARS klassisch · 131 MHz';

  @override
  String scannerAcarsMessageCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count Meldungen',
      one: '1 Meldung',
    );
    return '$_temp0';
  }

  @override
  String scannerAcarsHint(int count) {
    return 'Alle $count Kanäle werden gleichzeitig dekodiert. Punkt grün = Meldung in den letzten 10 s, Balken grün = auf dem Kanal wird gerade gesendet.';
  }

  @override
  String get scannerAcarsVdl2Hint =>
      'VDL2 ist digital: Bodenstationen und Flugzeuge senden kurze Datenpakete, Textmeldungen (ACARS) sind ein Teil davon.';

  @override
  String scannerAcarsWaiting(String antenna) {
    return 'Warte auf Meldungen… Bei Flugverkehr in der Nähe kommen meist mehrere pro Minute.\nAntenne für $antenna (Viertelwelle) - möglichst frei, am Fenster.';
  }

  @override
  String scannerAcarsAntenna(String frequency, String length) {
    return '$frequency MHz: senkrecht, ~$length cm';
  }

  @override
  String get scannerAcarsTryVdl2 =>
      'In Europa senden die meisten Flugzeuge inzwischen über VDL2 - kommt hier nichts, oben auf VDL2 umschalten.';

  @override
  String get scannerColTime => 'Zeit';

  @override
  String get scannerColFlight => 'Flug';

  @override
  String get scannerColRegistration => 'Kennzeichen';

  @override
  String get scannerColType => 'Art';

  @override
  String scannerAcarsReceived(String time, String frequency) {
    return 'Empfangen $time auf $frequency MHz';
  }

  @override
  String scannerAcarsDirection(String direction) {
    return 'Richtung: $direction';
  }

  @override
  String get scannerAcarsFromAircraft => 'vom Flugzeug';

  @override
  String get scannerAcarsToAircraft => 'zum Flugzeug';

  @override
  String scannerAcarsRegistration(String registration) {
    return 'Kennzeichen: $registration';
  }

  @override
  String scannerAcarsFlight(String flight) {
    return 'Flug $flight';
  }

  @override
  String scannerAcarsMessageNo(String number) {
    return 'Nr. $number';
  }

  @override
  String get scannerAcarsContinued => 'Fortsetzung folgt';

  @override
  String get scannerAcarsNoText => '(kein Text)';

  @override
  String get scannerAdsbTitle => 'Flugzeuge (ADS-B 1090 MHz)';

  @override
  String scannerAdsbCount(int count, int withPosition) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count Flugzeuge',
      one: '1 Flugzeug',
    );
    return '$_temp0 · $withPosition mit Position';
  }

  @override
  String scannerAdsbRate(int rate) {
    return '$rate Meldungen/s';
  }

  @override
  String get scannerAdsbMap => 'Karte';

  @override
  String get scannerAdsbNoAircraft =>
      'Noch kein Flugzeug empfangen.\nAntenne: senkrecht, ~6,9 cm (Viertelwelle 1090 MHz), möglichst am Fenster.';

  @override
  String get scannerAdsbOnGround => 'am Boden';

  @override
  String get scannerAdsbColFlight => 'Flug / ICAO';

  @override
  String get scannerAdsbColAltitude => 'Höhe';

  @override
  String get scannerAdsbColSpeed => 'Tempo';

  @override
  String get scannerAdsbColClimb => 'Steig/Sink';

  @override
  String get scannerAdsbColDistance => 'Entfernung';

  @override
  String get scannerAdsbColCountry => 'Zulassung';

  @override
  String get scannerAdsbColLastSeen => 'Zuletzt';

  @override
  String get scannerAdsbRouteLoading => 'Route wird geladen…';

  @override
  String get scannerAdsbRouteStale =>
      'Passt nicht zur Flugrichtung – die Fluglinie vergibt dieses Rufzeichen offenbar für eine andere Strecke; die Routendaten sind veraltet.';

  @override
  String get scannerAdsbFrom => 'Von';

  @override
  String get scannerAdsbTo => 'Nach';

  @override
  String get scannerAdsbHideRoute => 'Flugroute ausblenden (Zurück)';

  @override
  String get scannerAdsbShowRoute => 'Flugroute zeigen (OK)';

  @override
  String get scannerAdsbNoRoute => 'Keine Routendaten bekannt';

  @override
  String get scannerAdsbAirline => 'Fluglinie';

  @override
  String get scannerAdsbAircraft => 'Flugzeug';

  @override
  String get scannerAdsbOwner => 'Halter';

  @override
  String get scannerAdsbIcaoAddress => 'ICAO-Adresse';

  @override
  String get scannerAdsbTrack => 'Kurs';

  @override
  String get scannerAdsbClimbRate => 'Steigen/Sinken';

  @override
  String get scannerAdsbGroundSpeed => 'Geschwindigkeit';

  @override
  String scannerAdsbPosition(String lat, String lon) {
    return '$lat° N, $lon° O';
  }

  @override
  String get scannerAdsbBearing => 'Richtung';

  @override
  String scannerAdsbBearingValue(int degrees, String distance) {
    return '$degrees° in $distance km';
  }

  @override
  String get scannerAdsbReception => 'Empfang';

  @override
  String scannerAdsbReceptionValue(int count, String signal) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count Meldungen',
      one: '1 Meldung',
    );
    return '$_temp0 · Signal $signal dB';
  }

  @override
  String get scannerAdsbDataSource => 'Route und Flugzeugdaten: adsbdb.com';

  @override
  String get scannerAdsbClimbing => '↗ steigt';

  @override
  String get scannerAdsbDescending => '↘ sinkt';

  @override
  String scannerAgoSeconds(int seconds) {
    return 'vor $seconds s';
  }

  @override
  String scannerAgoMinutes(int minutes) {
    return 'vor $minutes min';
  }

  @override
  String scannerAgoHours(int hours) {
    return 'vor $hours h';
  }

  @override
  String scannerIsmNameFor(String model) {
    return 'Name für $model';
  }

  @override
  String get scannerIsmNameHint => 'z. B. Balkon, Keller, Nachbar Garten';

  @override
  String scannerIsmDevices(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count Geräte',
      one: '1 Gerät',
    );
    return '$_temp0';
  }

  @override
  String scannerIsmSignals(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count Signale',
      one: '1 Signal',
    );
    return '$_temp0';
  }

  @override
  String scannerIsmShowHidden(int count) {
    return 'Ausgeblendete zeigen ($count)';
  }

  @override
  String get scannerIsmWaiting =>
      'Warte auf Funksensoren… Die meisten senden alle 30–60 Sekunden.\nAntenne für 433 MHz: senkrecht, ~17 cm (868 MHz: ~8,6 cm).';

  @override
  String get scannerIsmSectionWeather => 'Thermometer & Wetter';

  @override
  String get scannerIsmSectionSwitches => 'Schalter, Klingeln, Fernbedienungen';

  @override
  String get scannerIsmSectionKeys => 'Funkschlüssel (anonym)';

  @override
  String get scannerIsmSectionUnknown => 'Unbekannt';

  @override
  String scannerIsmKeyPresses(int count, String age) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count Tastendrücke',
      one: '1 Tastendruck',
    );
    return '$_temp0 in der Umgebung, seit diese Seite offen ist · zuletzt $age';
  }

  @override
  String scannerIsmTransmitters(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count Sender',
      one: '1 Sender',
    );
    return '$_temp0';
  }

  @override
  String get scannerIsmHideRaw => 'Rohdaten ausblenden';

  @override
  String get scannerIsmShowRaw => 'Rohdaten ansehen';

  @override
  String scannerIsmRain(String amount) {
    return 'Regen $amount mm';
  }

  @override
  String get scannerIsmBatteryOk => 'ok';

  @override
  String get scannerIsmBatteryLow => 'schwach';

  @override
  String scannerIsmContinuous(String bitTime) {
    return 'Dauersender (FSK, ~$bitTime µs/Bit)';
  }

  @override
  String get scannerIsmNotDecodable =>
      'fortlaufendes Muster, nicht dekodierbar';

  @override
  String scannerIsmBitTime(String bitTime) {
    return '~$bitTime µs/Bit';
  }

  @override
  String scannerIsmPulses(int count, String pulses, String gaps) {
    return '$count Pulse ($pulses, Pausen $gaps)';
  }

  @override
  String scannerIsmAfterSync(String data) {
    return 'Nach Sync 2DD4: $data';
  }

  @override
  String scannerIsmDevice(String model, String id) {
    return 'Gerät: $model · ID $id';
  }

  @override
  String scannerIsmTemperature(String value) {
    return 'Temperatur: $value °C';
  }

  @override
  String scannerIsmTempRange(String min, String max) {
    return '24 h: $min bis $max °C';
  }

  @override
  String scannerIsmHumidity(String value) {
    return 'Luftfeuchte: $value %';
  }

  @override
  String scannerIsmBattery(String state) {
    return 'Batterie: $state';
  }

  @override
  String scannerIsmReceived(int count, String age, int level) {
    return 'Empfangen: $count× · zuletzt $age · Pegel $level dB';
  }

  @override
  String get scannerIsmSetName => 'Name vergeben';

  @override
  String get scannerIsmRename => 'Umbenennen';

  @override
  String get scannerIsmShowAgain => 'Wieder anzeigen';

  @override
  String get scannerIsmHide => 'Ausblenden';

  @override
  String get scannerJumpTo => 'Springen zu…';

  @override
  String get scannerFrequencyTitle => 'Frequenz (MHz)';

  @override
  String get scannerFrequencyHint => 'z. B. 145,500';

  @override
  String scannerOutOfRange(String low, String high) {
    return 'Der Stick empfängt $low–$high MHz.';
  }

  @override
  String get scannerHfHint =>
      'Nichts zu hören? Kurzwelle braucht einen Stick mit Direct Sampling (RTL-SDR Blog V3, NESDR SMArt v5), einen RTL-SDR Blog V4 (über rtl_tcp nur mit dem Blog-V4-Treiber am Server) oder einen Aufwärtsmischer (Funk → Kurzwelle) - und eine Antenne für Kurzwelle.';

  @override
  String scannerSignalAboveNoise(int snr) {
    return 'Signal $snr dB über Rauschen';
  }

  @override
  String get scannerChannelButton => 'Kanal';

  @override
  String get scannerFrequencyButton => 'Frequenz…';

  @override
  String get scannerFine => 'Fein';

  @override
  String scannerCbChannels(int count) {
    return '$count Kanäle';
  }

  @override
  String get scannerScan => 'Suchlauf';

  @override
  String get scannerAprsTooltip =>
      'APRS-Pakete (1200 Baud) dekodieren - auf 144,800 und 145,825 automatisch';

  @override
  String get scannerBandPlanTooltip =>
      'Modulation und Filter passend zum Bereich des Bandplans';

  @override
  String get scannerBandPlan => 'Bandplan';

  @override
  String get scannerSquelch => 'Rauschsperre';

  @override
  String scannerSampleRate(String rate, int mbit) {
    return 'Bandbreite $rate MHz (~$mbit Mbit/s)';
  }

  @override
  String get scannerSignalFilters => 'Signalfilter';

  @override
  String get scannerRange => 'Bereich';

  @override
  String scannerShowing(String low, String high) {
    return 'Zeigt $low–$high MHz';
  }

  @override
  String get scannerFilterWidth => 'Filterbreite';

  @override
  String get scannerFilterWidthHelp =>
      'Schmaler: weniger Rauschen und Nachbarkanäle. Breiter: verständlicher, wenn ein Sender etwas daneben liegt. Auto passt zur Modulation.';

  @override
  String get scannerNoiseBlanker => 'Störaustaster';

  @override
  String get scannerNoiseBlankerHelp =>
      'Entfernt kurze Knackser von Zündfunken, Weidezäunen und Netzteilen.';

  @override
  String get scannerVoiceFilter => 'Sprachfilter';

  @override
  String get scannerVoiceFilterHelp =>
      'Nur der Sprachbereich 300–3000 Hz: weniger Brummen, Rauschen und Pilottöne.';

  @override
  String get scannerAgc => 'Lautstärkeregelung';

  @override
  String get scannerAgcHelp =>
      'Schnell für AM/FM, langsam für SSB - verhindert Pumpen zwischen den Silben. Auto wählt passend zur Modulation.';

  @override
  String get scannerAgcFast => 'Schnell';

  @override
  String get scannerAgcSlow => 'Langsam';

  @override
  String get scannerDmrCallPending => 'Gespräch (Kennung folgt…)';

  @override
  String scannerDmrLast(String call, String ago) {
    return 'zuletzt $call $ago';
  }

  @override
  String get scannerDmrIdle => 'frei';

  @override
  String get scannerDmrReceptionGood => 'Empfang gut';

  @override
  String get scannerDmrReceptionFair => 'Empfang mäßig';

  @override
  String get scannerDmrReceptionPoor => 'Empfang schlecht';

  @override
  String scannerDmrSlot(int slot) {
    return 'Zeitschlitz $slot';
  }

  @override
  String get scannerDmrEmergency => 'NOTRUF';

  @override
  String get scannerDmrEncryptedNoAudio => 'verschlüsselt – kein Ton';

  @override
  String get scannerDmrNoSignal => 'kein DMR-Signal';

  @override
  String scannerDmrColorCode(int code) {
    return 'Farbcode $code';
  }

  @override
  String get scannerDmrNoVoiceDecoder =>
      'ohne Sprachdecoder gebaut – nur Anzeige';

  @override
  String get scannerDmrRecentlyHeard => 'Zuletzt gehört';

  @override
  String get scannerDmrEncrypted => 'verschlüsselt';

  @override
  String scannerAprsPackets(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count Pakete',
      one: '1 Paket',
    );
    return '$_temp0';
  }

  @override
  String get scannerAprsDecoderWaiting => 'Dekoder läuft - warte auf Pakete…';

  @override
  String get scannerAprsDecoderRunning => 'Dekoder läuft';

  @override
  String get scannerAprsDecoderOff => 'Dekoder aus';

  @override
  String get scannerAprsClear => 'Leeren';

  @override
  String scannerAprsTo(String name) {
    return 'an $name';
  }

  @override
  String scannerAprsReceived(String time) {
    return 'Empfangen $time';
  }

  @override
  String get scannerEastShort => 'O';

  @override
  String scannerAprsDistance(String distance) {
    return 'Entfernung: $distance';
  }

  @override
  String scannerAprsPath(String path) {
    return 'Weg: $path';
  }

  @override
  String get scannerAprsDirect => 'direkt';

  @override
  String get scannerRawData => 'Rohdaten';

  @override
  String get settingsOr => 'oder';

  @override
  String get settingsNotSetUp => 'nicht eingerichtet';

  @override
  String settingsPercent(int value) {
    return '$value %';
  }

  @override
  String settingsMinutesShort(int minutes) {
    return '$minutes Min.';
  }

  @override
  String settingsSecondsShort(int seconds) {
    return '$seconds Sek.';
  }

  @override
  String get settingsDeviceNameHelp =>
      'Eindeutig im Heimnetz - erscheint auf der Verwaltungsseite und im Namen der Backups.';

  @override
  String get settingsDeviceNameOwn => 'Eigener Name';

  @override
  String get settingsDeviceNameNotSet => 'nicht vergeben';

  @override
  String get settingsDeviceNameSuggestionTerrace => 'Terrassen-Media';

  @override
  String get settingsDeviceNameSuggestionLivingRoom => 'Wohnzimmer-TV';

  @override
  String get settingsDeviceNameSuggestionBedroom => 'Schlafzimmer-TV';

  @override
  String get settingsDeviceNameSuggestionKitchen => 'Küchen-Tablet';

  @override
  String get settingsReception => 'Empfang';

  @override
  String get settingsReceiverNone => 'Kein Empfänger';

  @override
  String get settingsReceiverUsb => 'RTL-SDR per USB';

  @override
  String get settingsReceiverTcp => 'RTL-SDR über Netzwerk';

  @override
  String get settingsShowDab => 'DAB anzeigen';

  @override
  String get settingsShowFm => 'FM anzeigen';

  @override
  String get settingsShowAm => 'LW/MW/KW anzeigen';

  @override
  String get settingsShowFunk => 'Funk anzeigen';

  @override
  String get settingsPartsHeading => 'Teile von Home System';

  @override
  String get settingsPartsHelp =>
      'Ausgeschaltete Teile haben keine Kachel unter Home, und ihre Einstellungen sind ausgegraut.';

  @override
  String get settingsDeviceHeading => 'Gerät';

  @override
  String get settingsAdminPageOffline =>
      'Verwaltungsseite (Backups): ohne Netzwerkverbindung nicht erreichbar';

  @override
  String settingsAdminPageAt(String url) {
    return 'Verwaltungsseite (Backups) im Browser: $url';
  }

  @override
  String get settingsNas => 'NAS-Server';

  @override
  String get settingsStartShowHome => 'Home anzeigen';

  @override
  String get settingsStartRadio =>
      'Radio mit Sender starten (Radio → Autostart)';

  @override
  String get settingsStartTv =>
      'TV mit Sender starten (TV → Sender beim Start)';

  @override
  String get settingsBackground => 'Hintergrund';

  @override
  String get settingsBackgroundGradients => 'Farbverläufe';

  @override
  String get settingsBackgroundPhotos => 'Landschaftsfotos';

  @override
  String get settingsBackgroundServer => 'Eigener Server';

  @override
  String get settingsIconPack => 'Icon-Paket';

  @override
  String get settingsIconPackNone => 'Original-Logos';

  @override
  String get settingsHomeKey => 'Home-Taste';

  @override
  String get settingsReceiverHeading => 'Receiver';

  @override
  String get settingsSatReceiver => 'Sat-Receiver (Enigma2)';

  @override
  String get settingsTvKeysValue =>
      'Senderliste, Programmführer, Optionen, Tonspur';

  @override
  String get settingsTvZapEncrypted => 'Receiver bei Bedarf umschalten';

  @override
  String get settingsTvZapEncryptedHelp =>
      'Nur wenn der Receiver eingeschaltet ist: Karte bzw. CI-Modul entschlüsseln dann nur den Sender, den er selbst zeigt, und an einem Sat-Kabel empfangen alle Tuner nur dessen Band. Für einen verschlüsselten Sender oder einen auf einem anderen Band schaltet die App den Receiver dann um (sein Bild wechselt mit).\nIm Standby schaltet die App nie um - der Receiver entschlüsselt dort selbst und bleibt frei. Hält er noch einen Sender fest, gibt die App ihn frei.';

  @override
  String get settingsTvStartHeading => 'Sender beim Start';

  @override
  String get settingsTvStartLast => 'Zuletzt gesehenen Sender';

  @override
  String get settingsTvStartFixed => 'Festen Sender';

  @override
  String settingsTvChannelsError(String error) {
    return 'Senderliste nicht erreichbar: $error';
  }

  @override
  String get settingsTvSetUpReceiverFirst => 'Erst den Receiver einrichten.';

  @override
  String get settingsTvNextUpHeading => 'Als Nächstes';

  @override
  String get settingsTvNextUpHelp =>
      'Kurz bevor auf dem laufenden Sender die nächste Sendung beginnt, erscheint ein Hinweis, was als Nächstes kommt.';

  @override
  String get settingsTvNextUpToggle => 'Hinweis auf die nächste Sendung';

  @override
  String get settingsTvNextUpLead => 'Wie lange vorher';

  @override
  String get settingsTvNextUpShow => 'Wie lange anzeigen';

  @override
  String get settingsAutostartHeading => 'Autostart';

  @override
  String get settingsAutostartLast => 'Zuletzt gehörten Sender starten';

  @override
  String get settingsAutostartFixed => 'Festen Sender starten';

  @override
  String get settingsDisplayHeading => 'Anzeige';

  @override
  String get settingsShowClockDate => 'Datum neben der Uhrzeit anzeigen';

  @override
  String get settingsFullscreen => 'Vollbild';

  @override
  String get settingsFullscreenMonitor => 'Monitor für Vollbild';

  @override
  String settingsMonitorOf(int monitor, int count) {
    return '$monitor von $count';
  }

  @override
  String get settingsUiScale => 'Größe der Oberfläche';

  @override
  String get settingsTilesHeading => 'Kacheln';

  @override
  String get settingsLocation => 'Standort';

  @override
  String get settingsWeatherForecast => 'Wetterprognose';

  @override
  String get settingsWeatherSpanTwoTiles => 'Über 2 Kacheln (volle Höhe)';

  @override
  String get settingsTileSize => 'Größe der Kachel';

  @override
  String get settingsContentSize => 'Größe des Inhalts';

  @override
  String get settingsWeatherRadar => 'Wetterradar';

  @override
  String get settingsRadarSource => 'Quelle';

  @override
  String settingsRadarRadius(String token) {
    return 'Umkreis um den Standort ($token in der Adresse)';
  }

  @override
  String get settingsRadarDimming => 'Abdunkeln (für abends)';

  @override
  String get settingsSunMoon => 'Sonne & Mond';

  @override
  String get settingsMoreSettings => 'Weitere Einstellungen (System, TV)';

  @override
  String get settingsMoreHeading => 'Weiteres';

  @override
  String get settingsBackupCreate => 'Backup erstellen';

  @override
  String get settingsBackupRestore => 'Backup wiederherstellen';

  @override
  String get settingsBackupRestoreHint => 'auch über die Verwaltungsseite';

  @override
  String get settingsAboutHeading => 'Über';

  @override
  String get settingsQuit => 'Programm beenden';

  @override
  String get settingsQuitConfirm => 'Programm beenden?';

  @override
  String get settingsQuitButton => 'Beenden';

  @override
  String settingsPartOff(String part) {
    return '$part ist ausgeschaltet - unter System → Teile von Home System einschalten.';
  }

  @override
  String get settingsAreaSystemSubtitle =>
      'Radio & TV ein/aus, Gerätename, NAS, Start, Home, Home-Taste, Anzeige, Backup, Updates';

  @override
  String get settingsAreaSystemSubtitleNoHomeKey =>
      'Radio & TV ein/aus, Gerätename, NAS, Start, Home, Anzeige, Backup, Updates';

  @override
  String get settingsAreaRadioSubtitle =>
      'Empfänger (DAB+, UKW, Funk), Autostart-Sender, Wetter, Radar, Sonne & Mond';

  @override
  String get settingsAreaTvSubtitle => 'Sat-Receiver (Enigma2, z. B. GigaBlue)';

  @override
  String get settingsAreaOff => 'Ausgeschaltet - unter System einschalten';

  @override
  String get settingsAboutLicense =>
      'PolyForm Noncommercial 1.0.0 - frei für private und nicht-kommerzielle Nutzung. © 2026 Jürgen Laschak, github.com/JayLo1401/home.system';

  @override
  String get settingsAboutWeatherData =>
      'Daten: © GeoSphere Austria, lizenziert unter CC BY 4.0 (data.hub.geosphere.at)';

  @override
  String get settingsAboutUvIndex => 'UV-Index';

  @override
  String get settingsAboutUvData =>
      'Weather data by Open-Meteo.com, lizenziert unter CC BY 4.0';

  @override
  String get settingsAboutInternetRadio => 'Internetradio';

  @override
  String get settingsAboutInternetRadioData =>
      'Sendersuche und Logos über das Community-Verzeichnis Radio Browser (radio-browser.info)';

  @override
  String get settingsAboutPlaceSearch => 'Ortssuche';

  @override
  String get settingsAboutPlaceSearchData =>
      '© OpenStreetMap-Mitwirkende, Daten unter der Open Database License (ODbL), über Nominatim.';

  @override
  String get settingsAboutBackgroundPhotos => 'Hintergrundfotos von Home';

  @override
  String get settingsAboutBackgroundPhotosData =>
      'Bing-Bilder des Tages, © bei den jeweiligen Fotografen (nur wenn „Landschaftsfotos aus dem Internet“ gewählt ist).';

  @override
  String get settingsAboutRadarData =>
      'Das Radarbild kommt von der selbst eingetragenen Quelle; Rechte und Quellenangaben liegen beim jeweiligen Anbieter.';

  @override
  String get settingsAudioChannelName => 'Radio-Wiedergabe';

  @override
  String get settingsBackupNotHomeSystem =>
      'Die Datei ist kein Home-System-Backup.';

  @override
  String get settingsBackupNewerVersion =>
      'Das Backup stammt von einer neueren App-Version.';

  @override
  String get settingsBackupCorrupt =>
      'Das Backup ist beschädigt oder unvollständig.';

  @override
  String get settingsLauncherMenuApp => 'Home System (App-Einstellungen)';

  @override
  String get settingsLauncherMenuAndroid => 'Android-Einstellungen';

  @override
  String settingsLauncherNotInstalled(String app) {
    return '„$app“ ist nicht (mehr) installiert.';
  }

  @override
  String get settingsLauncherMoveLeft => 'Nach links verschieben';

  @override
  String get settingsLauncherMoveRight => 'Nach rechts verschieben';

  @override
  String get settingsLauncherChangeImage => 'Bild ändern';

  @override
  String get settingsLauncherRemove => 'Aus der Startleiste entfernen';

  @override
  String settingsLauncherOptionsHint(String key) {
    return '$key  Optionen der Kachel';
  }

  @override
  String settingsLauncherOptionsHintMouse(String key) {
    return '$key oder Rechtsklick  Optionen der Kachel';
  }

  @override
  String settingsLauncherAppInfoFailed(String app) {
    return 'Die App-Info von „$app“ lässt sich nicht öffnen.';
  }

  @override
  String settingsLauncherImageTitle(String tile) {
    return 'Bild für „$tile“';
  }

  @override
  String get settingsLauncherImageAuto =>
      'Automatisch (Icon-Paket, sonst Original)';

  @override
  String get settingsLauncherImageDefault => 'Standard';

  @override
  String get settingsLauncherImageOriginal => 'Original der App';

  @override
  String get settingsLauncherImageFromUrl => 'Bild von einer Adresse (URL) …';

  @override
  String get settingsLauncherImageUrlTitle =>
      'Bild-Adresse (PNG/JPG, am besten 16:9)';

  @override
  String get settingsLauncherFindApps => 'Apps suchen & hinzufügen';

  @override
  String get settingsWizardTitle => 'Home System einrichten';

  @override
  String settingsWizardStep(int step, int count) {
    return 'Schritt $step von $count';
  }

  @override
  String get settingsWizardWelcome =>
      'Willkommen! Gibt es schon ein Backup von Home System?';

  @override
  String get settingsWizardRestoreHint =>
      'Von diesem Gerät, vom USB-Stick oder über die Verwaltungsseite';

  @override
  String settingsWizardRestoreHintUrl(String url) {
    return 'Von diesem Gerät, vom USB-Stick oder über die Verwaltungsseite ($url)';
  }

  @override
  String get settingsWizardNew => 'Neu einrichten';

  @override
  String settingsWizardLanguage(String language) {
    return 'Sprache: $language';
  }

  @override
  String get settingsWizardNameQuestion => 'Wie soll dieses Gerät heißen?';

  @override
  String get settingsWizardNameHint =>
      'Ein eindeutiger Name, damit man die Geräte unterscheiden kann - auf der Verwaltungsseite und bei Backups.';

  @override
  String get settingsWizardNameOwn => 'Oder eigener Name';

  @override
  String get settingsWizardNext => 'Weiter';

  @override
  String get settingsWizardHomeKeyTitle =>
      'Home-Taste der Fernbedienung (freiwillig)';

  @override
  String get settingsWizardHomeKeyHint =>
      'Wer möchte, dass die Home-Taste der Fernbedienung Home System öffnet, richtet das hier ein - Home System wird dafür Standard-Launcher, oder eine Bedienungshilfe wird eingeschaltet. Wer das nicht will, geht einfach weiter; es lässt sich jederzeit unter Einstellungen → System → Home-Taste nachholen.';

  @override
  String get settingsWizardHomeKeySetUp => 'Home-Taste einrichten';

  @override
  String get settingsWizardHomeKeySkip =>
      'Weiter (ohne bzw. nach dem Einrichten)';

  @override
  String settingsWizardDone(String name) {
    return 'Fertig - „$name“ ist eingerichtet.';
  }

  @override
  String get settingsWizardDoneHint =>
      'Home System startet mit Home: Radio, TV und die Apps als Kacheln. Weiteres (Radio-Empfänger, Sat-Receiver, Hintergrund …) unter Einstellungen.';

  @override
  String settingsWizardDoneBackups(String url) {
    return 'Backups gibt es jederzeit auf der Verwaltungsseite: $url';
  }

  @override
  String get settingsWizardStart => 'Los geht\'s';

  @override
  String get systemStartDashboard => 'Haussteuerung anzeigen (Wandtablet)';

  @override
  String get systemStartAppNone => 'Andere App starten …';

  @override
  String systemStartApp(String app) {
    return 'App starten: $app';
  }

  @override
  String get systemStartAppPick => 'Welche App beim Start?';

  @override
  String systemStartAppMissing(String app) {
    return 'Die Start-App „$app“ ist nicht installiert.';
  }

  @override
  String get systemSettingsAll => 'Alle Einstellungen';

  @override
  String get systemTileSettings => 'Einstellungen (TV)';

  @override
  String get systemTileSettingsShort => 'Einstellungen';

  @override
  String get systemSettingsTitleSystem => 'System-Einstellungen';

  @override
  String get systemSettingsTitleRadio => 'Radio-Einstellungen';

  @override
  String get systemSettingsTitleTv => 'TV-Einstellungen';

  @override
  String get tvLinkConnecting => 'Verbinde mit dem Receiver…';

  @override
  String tvLinkZapping(String reason) {
    return '$reason - Receiver schaltet um…';
  }

  @override
  String get tvReasonEncrypted => 'Verschlüsselt';

  @override
  String get tvReasonNoFreeTuner => 'Kein freier Tuner';

  @override
  String get tvLinkLoadingPicture => 'Bild wird geladen…';

  @override
  String get tvLinkDescrambling => 'Verschlüsselt - Receiver entschlüsselt…';

  @override
  String get tvLinkPlaying => 'Sender läuft';

  @override
  String tvErrorEncryptedReceiverBusy(String channel) {
    return '„$channel“ ist verschlüsselt und der Receiver zeigt selbst einen anderen Sender - Einstellungen → TV → „Receiver bei Bedarf umschalten“.';
  }

  @override
  String tvErrorStillEncrypted(String channel) {
    return '„$channel“ bleibt verschlüsselt - Karte bzw. CI-Modul für diesen Sender freigeschaltet?';
  }

  @override
  String tvErrorNoTunerCableBusy(String channel) {
    return 'Kein freier Tuner für „$channel“ - das Sat-Kabel ist gerade auf einem anderen Band belegt (Aufnahme oder ein anderes Gerät).';
  }

  @override
  String tvErrorNoTunerReceiverBusy(String channel) {
    return 'Kein freier Tuner für „$channel“ - der Receiver zeigt selbst einen Sender auf einem anderen Band (Einstellungen → TV → „Receiver bei Bedarf umschalten“).';
  }

  @override
  String tvErrorNoPicture(String channel) {
    return 'Kein Bild von „$channel“ - ist der Receiver an und ein Tuner frei?';
  }

  @override
  String get tvPaused => 'Angehalten - ⏯ spielt weiter';

  @override
  String get tvAudioTrack => 'Tonspur';

  @override
  String tvAudioTrackNumber(int number) {
    return 'Tonspur $number';
  }

  @override
  String tvAudioTrackCount(int count) {
    return '$count Tonspuren';
  }

  @override
  String tvAudioChannels(int count) {
    return '$count Kanäle';
  }

  @override
  String get tvAudioLanguageGerman => 'Deutsch';

  @override
  String get tvAudioLanguageEnglish => 'Englisch';

  @override
  String get tvAudioLanguageFrench => 'Französisch';

  @override
  String get tvAudioLanguageItalian => 'Italienisch';

  @override
  String get tvAudioLanguageSpanish => 'Spanisch';

  @override
  String get tvAudioLanguageTurkish => 'Türkisch';

  @override
  String get tvAudioLanguagePolish => 'Polnisch';

  @override
  String get tvAudioLanguageCroatianSerbian => 'Kroatisch/Serbisch';

  @override
  String get tvAudioOriginal => 'Originalton';

  @override
  String get tvAudioDescription => 'Audiodeskription';

  @override
  String tvResolutionLines(int lines) {
    return '$lines Zeilen';
  }

  @override
  String get tvTranscoded => 'Transkodiert';

  @override
  String get tvOriginalStream => 'Original';

  @override
  String get tvGuide => 'Programmführer';

  @override
  String tvAllProgramsOf(String channel) {
    return 'Alle Sendungen von $channel';
  }

  @override
  String get tvAllProgramsOfThisChannel => 'Alle Sendungen von diesem Sender';

  @override
  String get tvNextUpNow => 'Als Nächstes · gleich';

  @override
  String tvNextUpInMinutes(int minutes) {
    return 'Als Nächstes · in $minutes Min.';
  }

  @override
  String get tvNotSetUpIntro =>
      'Fernsehen vom eigenen Sat-Receiver: Senderlisten, Senderlogos und Programmführer kommen direkt vom Enigma2-Receiver (z. B. GigaBlue, VU+, Dreambox mit OpenWebif) im Heimnetz.';

  @override
  String get tvSetUpReceiver => 'Receiver einrichten';

  @override
  String tvBannerKeyHint(
    String channelListKey,
    String guideKey,
    String optionsKey,
  ) {
    return '$channelListKey Senderliste  ·  $guideKey Programm  ·  $optionsKey Optionen';
  }

  @override
  String get tvNoProgramInfo => 'Keine Programminformation';

  @override
  String get tvNoProgramInfoSentence => 'Keine Programminformation.';

  @override
  String get tvThen => 'Danach';

  @override
  String get tvChannelListKeyHint =>
      'OK abspielen (laufender Sender: Info)  ·  → Programm  ·  ← schließen';

  @override
  String get tvNoChannelsInList => 'Keine Sender in dieser Liste';

  @override
  String get tvChannelList => 'Senderliste';

  @override
  String get tvBouquetFavorites => 'Favoriten';

  @override
  String get tvBouquetLastScanned => 'Zuletzt gescannt';

  @override
  String tvMinutes(int minutes) {
    return '$minutes Min.';
  }

  @override
  String get tvNoDescription => 'Keine Beschreibung.';

  @override
  String get tvToday => 'Heute';

  @override
  String get tvTomorrow => 'Morgen';

  @override
  String get tvDayMonthPattern => 'dd.MM.';

  @override
  String get tvSchedule => 'Programm';

  @override
  String get tvScheduleNoInfo =>
      'Für diesen Sender hat der Receiver keine Programminformation.';

  @override
  String tvGuideKeyHint(String optionsKey) {
    return 'OK umschalten  ·  $optionsKey alle Sendungen  ·  ‹‹ ›› ±3 Std.';
  }

  @override
  String get tvSettingsTitle => 'TV: Receiver';

  @override
  String get tvSettingsIntro =>
      'Ein Enigma2-Sat-Receiver mit OpenWebif im Heimnetz (z. B. GigaBlue, VU+, Dreambox mit teamBlue, OpenATV oder OpenPLi). Senderlisten, Senderlogos (Picons) und der Programmführer kommen vom Receiver, das Bild über seinen Streaming-Port.';

  @override
  String get tvSettingsAddress => 'Adresse des Receivers (IP oder Name)';

  @override
  String get tvSettingsWebPort => 'Web-Port (OpenWebif)';

  @override
  String get tvSettingsStreamPort => 'Streaming-Port';

  @override
  String get tvSettingsPortsHelp =>
      'Üblich: Web 80, Streaming 8001 (8002 = umgewandelt, falls der Receiver das kann).';

  @override
  String get tvSettingsHttps => 'HTTPS für die Weboberfläche';

  @override
  String get tvSettingsUser => 'Benutzer (falls Anmeldung aktiv)';

  @override
  String get tvSettingsPassword => 'Passwort';

  @override
  String get tvSettingsTestConnection => 'Verbindung testen';

  @override
  String get tvSettingsEnterAddress =>
      'Bitte die Adresse des Receivers eintragen.';

  @override
  String tvSettingsConnected(String receiver, int count) {
    return 'Verbunden: $receiver · $count Senderlisten';
  }

  @override
  String get tvSettingsChannelList => 'Senderliste für TV';

  @override
  String get tvSettingsChannelListHelp =>
      'Im TV wechseln ← / → in der Senderliste zwischen den Listen.';

  @override
  String get tvEnigma2Receiver => 'Enigma2-Receiver';

  @override
  String get tvReceiverNeedsLogin => 'Enigma2-Receiver (Anmeldung nötig)';

  @override
  String get tvSearchReceiver => 'Receiver suchen';

  @override
  String get tvSearchScanning => 'Durchsuche das Heimnetz …';

  @override
  String tvSearchScanningNetworks(String networks) {
    return 'Durchsuche das Heimnetz ($networks) …';
  }

  @override
  String get tvSearchNoneFound =>
      'Kein Receiver gefunden. Ist er eingeschaltet und im selben Netz? Sonst die Adresse bitte von Hand eintragen.';

  @override
  String tvSearchFound(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count Receiver gefunden - OK übernimmt ihn.',
      one: 'Ein Receiver gefunden - OK übernimmt ihn.',
    );
    return '$_temp0';
  }

  @override
  String get tvErrorNoReceiver => 'Kein Receiver eingerichtet';

  @override
  String tvErrorUnreachable(String host, String error) {
    return 'Receiver nicht erreichbar ($host): $error';
  }

  @override
  String get tvErrorLoginRejected =>
      'Anmeldung abgelehnt - Benutzer/Passwort prüfen';

  @override
  String tvErrorHttpStatus(String status) {
    return 'Receiver antwortet mit Fehler $status';
  }

  @override
  String get tvErrorUnexpectedResponse => 'Unerwartete Antwort vom Receiver';

  @override
  String tvErrorZapFailed(String message) {
    return 'Receiver schaltet nicht um: $message';
  }

  @override
  String get tvSettingsButton => 'TV-Einstellungen';
}
