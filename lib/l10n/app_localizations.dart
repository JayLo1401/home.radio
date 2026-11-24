import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_de.dart';
import 'app_localizations_en.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations)!;
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('de'),
    Locale('en'),
  ];

  /// No description provided for @adminSubtitle.
  ///
  /// In de, this message translates to:
  /// **'Verwaltung dieses Geräts im Heimnetz'**
  String get adminSubtitle;

  /// No description provided for @adminHostname.
  ///
  /// In de, this message translates to:
  /// **'Hostname'**
  String get adminHostname;

  /// No description provided for @adminIpAddress.
  ///
  /// In de, this message translates to:
  /// **'IP-Adresse'**
  String get adminIpAddress;

  /// No description provided for @adminNotFound.
  ///
  /// In de, this message translates to:
  /// **'Nicht gefunden'**
  String get adminNotFound;

  /// No description provided for @adminSaved.
  ///
  /// In de, this message translates to:
  /// **'Gespeichert'**
  String get adminSaved;

  /// No description provided for @adminOffline.
  ///
  /// In de, this message translates to:
  /// **'Keine Verbindung zum Gerät.'**
  String get adminOffline;

  /// No description provided for @adminInvalidValue.
  ///
  /// In de, this message translates to:
  /// **'Ungültiger Wert.'**
  String get adminInvalidValue;

  /// No description provided for @adminUnknownSetting.
  ///
  /// In de, this message translates to:
  /// **'Diese Einstellung gibt es hier nicht.'**
  String get adminUnknownSetting;

  /// No description provided for @adminSecretPlaceholder.
  ///
  /// In de, this message translates to:
  /// **'unverändert'**
  String get adminSecretPlaceholder;

  /// No description provided for @adminSecretHelp.
  ///
  /// In de, this message translates to:
  /// **'Wird nie angezeigt - nur ein neues eintragen.'**
  String get adminSecretHelp;

  /// No description provided for @adminBackupHeading.
  ///
  /// In de, this message translates to:
  /// **'Backup'**
  String get adminBackupHeading;

  /// No description provided for @adminBackupHelp.
  ///
  /// In de, this message translates to:
  /// **'Enthält Favoriten, Senderlisten und alle Einstellungen - auch Zugangsdaten. Gut aufbewahren.'**
  String get adminBackupHelp;

  /// No description provided for @adminBackupDownload.
  ///
  /// In de, this message translates to:
  /// **'Backup erstellen & herunterladen'**
  String get adminBackupDownload;

  /// No description provided for @adminRestoreHeading.
  ///
  /// In de, this message translates to:
  /// **'Backup wiederherstellen'**
  String get adminRestoreHeading;

  /// No description provided for @adminRestoreHow.
  ///
  /// In de, this message translates to:
  /// **'Zum Wiederherstellen am Gerät Einstellungen → System → Backup wiederherstellen öffnen (oder im Einrichtungsassistenten „Backup wiederherstellen“ wählen). Hier erscheint dann das Hochladen.'**
  String get adminRestoreHow;

  /// No description provided for @adminRestoreReady.
  ///
  /// In de, this message translates to:
  /// **'Das Gerät ist bereit. Alle aktuellen Favoriten, Sender und Einstellungen werden ersetzt, danach startet Home System neu.'**
  String get adminRestoreReady;

  /// No description provided for @adminRestoreButton.
  ///
  /// In de, this message translates to:
  /// **'Backup einspielen'**
  String get adminRestoreButton;

  /// No description provided for @adminRestoring.
  ///
  /// In de, this message translates to:
  /// **'Wird eingespielt …'**
  String get adminRestoring;

  /// No description provided for @adminConfirmRestore.
  ///
  /// In de, this message translates to:
  /// **'Backup „{file}“ einspielen? Alle aktuellen Daten des Geräts werden ersetzt.'**
  String adminConfirmRestore(String file);

  /// No description provided for @adminRestoreLocked.
  ///
  /// In de, this message translates to:
  /// **'Wiederherstellen ist gerade nicht freigegeben - am Gerät „Backup wiederherstellen“ öffnen.'**
  String get adminRestoreLocked;

  /// No description provided for @adminFileTooBig.
  ///
  /// In de, this message translates to:
  /// **'Die Datei ist zu groß für ein Backup.'**
  String get adminFileTooBig;

  /// No description provided for @adminFileInvalid.
  ///
  /// In de, this message translates to:
  /// **'Die Datei ist kein gültiges Backup.'**
  String get adminFileInvalid;

  /// No description provided for @adminRestored.
  ///
  /// In de, this message translates to:
  /// **'Backup eingespielt - Home System startet neu.'**
  String get adminRestored;

  /// No description provided for @adminDisplayHeading.
  ///
  /// In de, this message translates to:
  /// **'Display (Haussteuerung)'**
  String get adminDisplayHeading;

  /// No description provided for @adminDisplayHelp.
  ///
  /// In de, this message translates to:
  /// **'Schaltet das Display des Geräts - dasselbe kann Home Assistant per POST auf /api/display/on, /api/display/off und /api/dashboard/reload.'**
  String get adminDisplayHelp;

  /// No description provided for @adminDisplayOn.
  ///
  /// In de, this message translates to:
  /// **'Display an'**
  String get adminDisplayOn;

  /// No description provided for @adminDisplayOff.
  ///
  /// In de, this message translates to:
  /// **'Display aus'**
  String get adminDisplayOff;

  /// No description provided for @adminDashboardReload.
  ///
  /// In de, this message translates to:
  /// **'Dashboard neu laden'**
  String get adminDashboardReload;

  /// No description provided for @adminDeviceName.
  ///
  /// In de, this message translates to:
  /// **'Gerätename'**
  String get adminDeviceName;

  /// No description provided for @adminPartRadio.
  ///
  /// In de, this message translates to:
  /// **'Radio eingeschaltet'**
  String get adminPartRadio;

  /// No description provided for @adminPartTv.
  ///
  /// In de, this message translates to:
  /// **'TV eingeschaltet'**
  String get adminPartTv;

  /// No description provided for @adminPartDashboard.
  ///
  /// In de, this message translates to:
  /// **'Haussteuerung eingeschaltet'**
  String get adminPartDashboard;

  /// No description provided for @adminStartScreen.
  ///
  /// In de, this message translates to:
  /// **'Beim Start der App'**
  String get adminStartScreen;

  /// No description provided for @adminStartScreenApp.
  ///
  /// In de, this message translates to:
  /// **'Start-App'**
  String get adminStartScreenApp;

  /// No description provided for @adminStartApp.
  ///
  /// In de, this message translates to:
  /// **'Start-App'**
  String get adminStartApp;

  /// No description provided for @adminStartAppFirst.
  ///
  /// In de, this message translates to:
  /// **'Zuerst eine Start-App wählen.'**
  String get adminStartAppFirst;

  /// No description provided for @adminUiScale.
  ///
  /// In de, this message translates to:
  /// **'Größe der Oberfläche (%)'**
  String get adminUiScale;

  /// No description provided for @adminClockDate.
  ///
  /// In de, this message translates to:
  /// **'Datum neben der Uhrzeit'**
  String get adminClockDate;

  /// No description provided for @adminWeather.
  ///
  /// In de, this message translates to:
  /// **'Wetter-Kachel'**
  String get adminWeather;

  /// No description provided for @adminRadar.
  ///
  /// In de, this message translates to:
  /// **'Regenradar-Kachel'**
  String get adminRadar;

  /// No description provided for @adminSun.
  ///
  /// In de, this message translates to:
  /// **'Sonne & Mond-Kachel'**
  String get adminSun;

  /// No description provided for @adminTvHost.
  ///
  /// In de, this message translates to:
  /// **'Receiver: Adresse (IP oder Name)'**
  String get adminTvHost;

  /// No description provided for @adminTvWebPort.
  ///
  /// In de, this message translates to:
  /// **'Receiver: Web-Port'**
  String get adminTvWebPort;

  /// No description provided for @adminTvStreamPort.
  ///
  /// In de, this message translates to:
  /// **'Receiver: Streaming-Port'**
  String get adminTvStreamPort;

  /// No description provided for @adminTvHttps.
  ///
  /// In de, this message translates to:
  /// **'Receiver: HTTPS'**
  String get adminTvHttps;

  /// No description provided for @adminTvUser.
  ///
  /// In de, this message translates to:
  /// **'Receiver: Benutzer'**
  String get adminTvUser;

  /// No description provided for @adminTvPassword.
  ///
  /// In de, this message translates to:
  /// **'Receiver: Passwort'**
  String get adminTvPassword;

  /// No description provided for @adminTvNextUp.
  ///
  /// In de, this message translates to:
  /// **'Hinweis „Als Nächstes“'**
  String get adminTvNextUp;

  /// No description provided for @adminMotionTimeout.
  ///
  /// In de, this message translates to:
  /// **'Display aus nach (Minuten)'**
  String get adminMotionTimeout;

  /// No description provided for @adminMotionTimeoutHelp.
  ///
  /// In de, this message translates to:
  /// **'0 = nie'**
  String get adminMotionTimeoutHelp;

  /// No description provided for @adminCameraOnDevice.
  ///
  /// In de, this message translates to:
  /// **'Der Zugriff auf die Kamera muss einmal am Gerät erlaubt werden: Einstellungen → Haussteuerung.'**
  String get adminCameraOnDevice;

  /// No description provided for @commonOk.
  ///
  /// In de, this message translates to:
  /// **'OK'**
  String get commonOk;

  /// No description provided for @commonCancel.
  ///
  /// In de, this message translates to:
  /// **'Abbrechen'**
  String get commonCancel;

  /// No description provided for @commonSave.
  ///
  /// In de, this message translates to:
  /// **'Speichern'**
  String get commonSave;

  /// No description provided for @commonDelete.
  ///
  /// In de, this message translates to:
  /// **'Löschen'**
  String get commonDelete;

  /// No description provided for @commonClose.
  ///
  /// In de, this message translates to:
  /// **'Schließen'**
  String get commonClose;

  /// No description provided for @commonBack.
  ///
  /// In de, this message translates to:
  /// **'Zurück'**
  String get commonBack;

  /// No description provided for @commonYes.
  ///
  /// In de, this message translates to:
  /// **'Ja'**
  String get commonYes;

  /// No description provided for @commonNo.
  ///
  /// In de, this message translates to:
  /// **'Nein'**
  String get commonNo;

  /// No description provided for @commonOn.
  ///
  /// In de, this message translates to:
  /// **'Ein'**
  String get commonOn;

  /// No description provided for @commonOff.
  ///
  /// In de, this message translates to:
  /// **'Aus'**
  String get commonOff;

  /// No description provided for @commonEdit.
  ///
  /// In de, this message translates to:
  /// **'Bearbeiten'**
  String get commonEdit;

  /// No description provided for @commonRetry.
  ///
  /// In de, this message translates to:
  /// **'Erneut versuchen'**
  String get commonRetry;

  /// No description provided for @commonLoading.
  ///
  /// In de, this message translates to:
  /// **'Wird geladen …'**
  String get commonLoading;

  /// No description provided for @commonError.
  ///
  /// In de, this message translates to:
  /// **'Fehler: {message}'**
  String commonError(String message);

  /// No description provided for @commonLanguage.
  ///
  /// In de, this message translates to:
  /// **'Sprache'**
  String get commonLanguage;

  /// No description provided for @commonLanguageSystem.
  ///
  /// In de, this message translates to:
  /// **'Wie das Gerät'**
  String get commonLanguageSystem;

  /// No description provided for @commonLanguageGerman.
  ///
  /// In de, this message translates to:
  /// **'Deutsch'**
  String get commonLanguageGerman;

  /// No description provided for @commonLanguageEnglish.
  ///
  /// In de, this message translates to:
  /// **'English'**
  String get commonLanguageEnglish;

  /// No description provided for @dashboardTitle.
  ///
  /// In de, this message translates to:
  /// **'Haussteuerung'**
  String get dashboardTitle;

  /// No description provided for @dashboardAndroidOnly.
  ///
  /// In de, this message translates to:
  /// **'Die Haussteuerung gibt es nur unter Android (Tablet, TV-Box).'**
  String get dashboardAndroidOnly;

  /// No description provided for @dashboardNoAddress.
  ///
  /// In de, this message translates to:
  /// **'Noch keine Adresse für das Home-Assistant-Dashboard eingetragen.'**
  String get dashboardNoAddress;

  /// No description provided for @dashboardOpenSettings.
  ///
  /// In de, this message translates to:
  /// **'Einstellungen öffnen'**
  String get dashboardOpenSettings;

  /// No description provided for @dashboardUnreachable.
  ///
  /// In de, this message translates to:
  /// **'{url} ist nicht erreichbar - neuer Versuch in 15 Sekunden.'**
  String dashboardUnreachable(String url);

  /// No description provided for @dashboardSettingsTitle.
  ///
  /// In de, this message translates to:
  /// **'Haussteuerungs-Einstellungen'**
  String get dashboardSettingsTitle;

  /// No description provided for @dashboardAreaSubtitle.
  ///
  /// In de, this message translates to:
  /// **'Home-Assistant-Dashboard, Display per Bewegung'**
  String get dashboardAreaSubtitle;

  /// No description provided for @dashboardAddress.
  ///
  /// In de, this message translates to:
  /// **'Dashboard-Adresse'**
  String get dashboardAddress;

  /// No description provided for @dashboardAddressHint.
  ///
  /// In de, this message translates to:
  /// **'http://homeassistant.local:8123/lovelace/0'**
  String get dashboardAddressHint;

  /// No description provided for @dashboardAddressHelp.
  ///
  /// In de, this message translates to:
  /// **'Die Seite des Dashboards in Home Assistant. Die Anmeldung bleibt gespeichert. Mit „?kiosk“ am Ende (Integration „kiosk-mode“) ohne Kopf- und Seitenleiste.'**
  String get dashboardAddressHelp;

  /// No description provided for @dashboardNotSet.
  ///
  /// In de, this message translates to:
  /// **'nicht eingetragen'**
  String get dashboardNotSet;

  /// No description provided for @dashboardDisplayHeading.
  ///
  /// In de, this message translates to:
  /// **'Display per Bewegung'**
  String get dashboardDisplayHeading;

  /// No description provided for @dashboardMotion.
  ///
  /// In de, this message translates to:
  /// **'Display per Kamera ein- und ausschalten'**
  String get dashboardMotion;

  /// No description provided for @dashboardMotionHelp.
  ///
  /// In de, this message translates to:
  /// **'Die Kamera erkennt Bewegung vor dem Gerät: Das Display geht an und zeigt die Haussteuerung. Ist eine Weile niemand da, geht es aus. Es werden keine Bilder gespeichert oder verschickt.'**
  String get dashboardMotionHelp;

  /// No description provided for @dashboardNoCamera.
  ///
  /// In de, this message translates to:
  /// **'Dieses Gerät hat keine Kamera.'**
  String get dashboardNoCamera;

  /// No description provided for @dashboardCameraDenied.
  ///
  /// In de, this message translates to:
  /// **'Ohne Zugriff auf die Kamera geht das nicht.'**
  String get dashboardCameraDenied;

  /// No description provided for @dashboardNoAccessibility.
  ///
  /// In de, this message translates to:
  /// **'Zum Ausschalten des Displays braucht Home System die Bedienungshilfe „Home System: Home-Taste“ (Android 9 oder neuer).'**
  String get dashboardNoAccessibility;

  /// No description provided for @dashboardSensitivity.
  ///
  /// In de, this message translates to:
  /// **'Empfindlichkeit'**
  String get dashboardSensitivity;

  /// No description provided for @dashboardSensitivityValue.
  ///
  /// In de, this message translates to:
  /// **'{value} von 10'**
  String dashboardSensitivityValue(int value);

  /// No description provided for @dashboardTimeout.
  ///
  /// In de, this message translates to:
  /// **'Display aus nach'**
  String get dashboardTimeout;

  /// No description provided for @dashboardTimeoutMinutes.
  ///
  /// In de, this message translates to:
  /// **'{minutes, plural, =1{1 Minute} other{{minutes} Minuten}}'**
  String dashboardTimeoutMinutes(int minutes);

  /// No description provided for @dashboardTimeoutNever.
  ///
  /// In de, this message translates to:
  /// **'nie'**
  String get dashboardTimeoutNever;

  /// No description provided for @dashboardLevel.
  ///
  /// In de, this message translates to:
  /// **'Bewegung jetzt: {percent} %'**
  String dashboardLevel(int percent);

  /// No description provided for @dashboardLevelMotion.
  ///
  /// In de, this message translates to:
  /// **'Bewegung erkannt'**
  String get dashboardLevelMotion;

  /// No description provided for @dashboardHaHeading.
  ///
  /// In de, this message translates to:
  /// **'Home Assistant'**
  String get dashboardHaHeading;

  /// No description provided for @dashboardWebhook.
  ///
  /// In de, this message translates to:
  /// **'Webhook für Bewegung'**
  String get dashboardWebhook;

  /// No description provided for @dashboardWebhookHint.
  ///
  /// In de, this message translates to:
  /// **'http://homeassistant.local:8123/api/webhook/flur-tablet'**
  String get dashboardWebhookHint;

  /// No description provided for @dashboardWebhookHelp.
  ///
  /// In de, this message translates to:
  /// **'Bei Bewegung schickt Home System \"motion\": true, nach einer Minute Ruhe \"motion\": false - als Auslöser für Automationen (Auslöser „Webhook“).'**
  String get dashboardWebhookHelp;

  /// No description provided for @dashboardRemoteHelp.
  ///
  /// In de, this message translates to:
  /// **'Home Assistant kann das Display schalten und das Dashboard neu laden: {url}/api/display/on, …/off, …/api/dashboard/reload (POST, z. B. mit rest_command).'**
  String dashboardRemoteHelp(String url);

  /// No description provided for @dashboardTestOff.
  ///
  /// In de, this message translates to:
  /// **'Display jetzt ausschalten (Test)'**
  String get dashboardTestOff;

  /// No description provided for @dashboardDimOnly.
  ///
  /// In de, this message translates to:
  /// **'Display nur abdunkeln statt ausschalten'**
  String get dashboardDimOnly;

  /// No description provided for @dashboardDimOnlyHelp.
  ///
  /// In de, this message translates to:
  /// **'Das Display wird schwarz und ganz dunkel, schaltet aber nicht ab - so sperrt Android nicht, und beim Zurückkommen erscheint kein Sperrbildschirm (Fire-Tablets). Bewegung, Tippen oder eine Taste holen es sofort zurück.'**
  String get dashboardDimOnlyHelp;

  /// No description provided for @dashboardBrightnessHeading.
  ///
  /// In de, this message translates to:
  /// **'Helligkeit'**
  String get dashboardBrightnessHeading;

  /// No description provided for @dashboardBrightnessSystem.
  ///
  /// In de, this message translates to:
  /// **'Wie im System eingestellt'**
  String get dashboardBrightnessSystem;

  /// No description provided for @dashboardBrightnessFixed.
  ///
  /// In de, this message translates to:
  /// **'Feste Helligkeit'**
  String get dashboardBrightnessFixed;

  /// No description provided for @dashboardBrightnessAdaptive.
  ///
  /// In de, this message translates to:
  /// **'Adaptiv (Lichtsensor)'**
  String get dashboardBrightnessAdaptive;

  /// No description provided for @dashboardBrightnessLevel.
  ///
  /// In de, this message translates to:
  /// **'Helligkeit'**
  String get dashboardBrightnessLevel;

  /// No description provided for @dashboardBrightnessMin.
  ///
  /// In de, this message translates to:
  /// **'Bei Dunkelheit'**
  String get dashboardBrightnessMin;

  /// No description provided for @dashboardBrightnessMax.
  ///
  /// In de, this message translates to:
  /// **'Bei hellem Raum'**
  String get dashboardBrightnessMax;

  /// No description provided for @dashboardBrightnessLuxForMax.
  ///
  /// In de, this message translates to:
  /// **'Volle Helligkeit ab'**
  String get dashboardBrightnessLuxForMax;

  /// No description provided for @dashboardBrightnessHelp.
  ///
  /// In de, this message translates to:
  /// **'Der Lichtsensor sitzt hinter dem Glas und misst oft wenig: „Volle Helligkeit ab“ auf den Wert stellen, den er bei hellem Raum anzeigt (siehe unten).'**
  String get dashboardBrightnessHelp;

  /// No description provided for @dashboardBrightnessLux.
  ///
  /// In de, this message translates to:
  /// **'Lichtsensor jetzt: {lux} lx'**
  String dashboardBrightnessLux(String lux);

  /// No description provided for @dashboardBrightnessNoSensor.
  ///
  /// In de, this message translates to:
  /// **'Dieses Gerät hat keinen Lichtsensor.'**
  String get dashboardBrightnessNoSensor;

  /// No description provided for @iptvListName.
  ///
  /// In de, this message translates to:
  /// **'Internet-TV'**
  String get iptvListName;

  /// No description provided for @iptvBrowse.
  ///
  /// In de, this message translates to:
  /// **'Sender suchen'**
  String get iptvBrowse;

  /// No description provided for @iptvBrowseTitle.
  ///
  /// In de, this message translates to:
  /// **'Internet-TV – Sender suchen'**
  String get iptvBrowseTitle;

  /// No description provided for @iptvSearchName.
  ///
  /// In de, this message translates to:
  /// **'Sendername'**
  String get iptvSearchName;

  /// No description provided for @iptvCountry.
  ///
  /// In de, this message translates to:
  /// **'Land'**
  String get iptvCountry;

  /// No description provided for @iptvMyCountries.
  ///
  /// In de, this message translates to:
  /// **'Meine Länder ({countries})'**
  String iptvMyCountries(String countries);

  /// No description provided for @iptvAllCountries.
  ///
  /// In de, this message translates to:
  /// **'Alle Länder'**
  String get iptvAllCountries;

  /// No description provided for @iptvCategory.
  ///
  /// In de, this message translates to:
  /// **'Kategorie'**
  String get iptvCategory;

  /// No description provided for @iptvAllCategories.
  ///
  /// In de, this message translates to:
  /// **'Alle Kategorien'**
  String get iptvAllCategories;

  /// No description provided for @iptvLanguage.
  ///
  /// In de, this message translates to:
  /// **'Sprache'**
  String get iptvLanguage;

  /// No description provided for @iptvMyLanguages.
  ///
  /// In de, this message translates to:
  /// **'Meine Sprachen ({languages})'**
  String iptvMyLanguages(String languages);

  /// No description provided for @iptvAllLanguages.
  ///
  /// In de, this message translates to:
  /// **'Alle Sprachen'**
  String get iptvAllLanguages;

  /// No description provided for @iptvBrowseKeyHint.
  ///
  /// In de, this message translates to:
  /// **'OK spielt den Sender  ·  ★ (→) oder Optionen-Taste: in die Internet-TV-Liste aufnehmen bzw. entfernen'**
  String get iptvBrowseKeyHint;

  /// No description provided for @iptvResultCount.
  ///
  /// In de, this message translates to:
  /// **'{count, plural, =1{1 Sender} other{{count} Sender}}'**
  String iptvResultCount(int count);

  /// No description provided for @iptvCatalogueDate.
  ///
  /// In de, this message translates to:
  /// **'Katalog vom {date}'**
  String iptvCatalogueDate(String date);

  /// No description provided for @iptvLoadingCatalogue.
  ///
  /// In de, this message translates to:
  /// **'Senderkatalog wird geladen… (beim ersten Mal kann das eine Minute dauern)'**
  String get iptvLoadingCatalogue;

  /// No description provided for @iptvUpdatingCatalogue.
  ///
  /// In de, this message translates to:
  /// **'wird aktualisiert…'**
  String get iptvUpdatingCatalogue;

  /// No description provided for @iptvUpdateFailed.
  ///
  /// In de, this message translates to:
  /// **'Aktualisieren fehlgeschlagen'**
  String get iptvUpdateFailed;

  /// No description provided for @iptvCatalogueError.
  ///
  /// In de, this message translates to:
  /// **'Senderkatalog nicht ladbar: {error}'**
  String iptvCatalogueError(String error);

  /// No description provided for @iptvTryAgain.
  ///
  /// In de, this message translates to:
  /// **'Nochmal versuchen'**
  String get iptvTryAgain;

  /// No description provided for @iptvNoResults.
  ///
  /// In de, this message translates to:
  /// **'Keine Sender gefunden'**
  String get iptvNoResults;

  /// No description provided for @iptvAddFavorite.
  ///
  /// In de, this message translates to:
  /// **'In die Internet-TV-Liste'**
  String get iptvAddFavorite;

  /// No description provided for @iptvRemoveFavorite.
  ///
  /// In de, this message translates to:
  /// **'Aus der Internet-TV-Liste entfernen'**
  String get iptvRemoveFavorite;

  /// No description provided for @iptvAddedAsNumber.
  ///
  /// In de, this message translates to:
  /// **'„{name}“ ist jetzt Internet-TV Nr. {number}'**
  String iptvAddedAsNumber(String name, int number);

  /// No description provided for @iptvRemoved.
  ///
  /// In de, this message translates to:
  /// **'„{name}“ aus der Internet-TV-Liste entfernt'**
  String iptvRemoved(String name);

  /// No description provided for @iptvFavoriteNumber.
  ///
  /// In de, this message translates to:
  /// **'Nr. {number}'**
  String iptvFavoriteNumber(int number);

  /// No description provided for @iptvEmptyList.
  ///
  /// In de, this message translates to:
  /// **'Noch keine Internet-TV-Sender. Oben „Sender suchen“: dort spielt OK einen Sender, ★ nimmt ihn in diese Liste auf.'**
  String get iptvEmptyList;

  /// No description provided for @iptvChannelListKeyHint.
  ///
  /// In de, this message translates to:
  /// **'OK abspielen (laufender Sender: Info)  ·  → Optionen (verschieben, entfernen)  ·  ← schließen'**
  String get iptvChannelListKeyHint;

  /// No description provided for @iptvMove.
  ///
  /// In de, this message translates to:
  /// **'Verschieben'**
  String get iptvMove;

  /// No description provided for @iptvMoveHint.
  ///
  /// In de, this message translates to:
  /// **'↑/↓ verschieben  ·  OK fertig'**
  String get iptvMoveHint;

  /// No description provided for @iptvChangeNumber.
  ///
  /// In de, this message translates to:
  /// **'Nummer ändern…'**
  String get iptvChangeNumber;

  /// No description provided for @iptvPlay.
  ///
  /// In de, this message translates to:
  /// **'Abspielen'**
  String get iptvPlay;

  /// No description provided for @iptvLinkConnecting.
  ///
  /// In de, this message translates to:
  /// **'Verbinde mit dem Sender…'**
  String get iptvLinkConnecting;

  /// No description provided for @iptvLinkTryingOther.
  ///
  /// In de, this message translates to:
  /// **'Anderer Stream wird versucht ({attempt} von {count})…'**
  String iptvLinkTryingOther(int attempt, int count);

  /// No description provided for @iptvErrorNoPicture.
  ///
  /// In de, this message translates to:
  /// **'„{channel}“ sendet gerade nicht oder ist hier gesperrt (Geo-Sperre).'**
  String iptvErrorNoPicture(String channel);

  /// No description provided for @iptvNoGuide.
  ///
  /// In de, this message translates to:
  /// **'Kein Programmführer für Internet-TV'**
  String get iptvNoGuide;

  /// No description provided for @iptvNoGuideSentence.
  ///
  /// In de, this message translates to:
  /// **'Für Internet-TV-Sender gibt es keinen Programmführer.'**
  String get iptvNoGuideSentence;

  /// No description provided for @iptvBannerKeyHint.
  ///
  /// In de, this message translates to:
  /// **'{channelListKey} Senderliste  ·  {optionsKey} Optionen'**
  String iptvBannerKeyHint(String channelListKey, String optionsKey);

  /// No description provided for @iptvGeoBlocked.
  ///
  /// In de, this message translates to:
  /// **'Evtl. nur im eigenen Land empfangbar (Geo-Sperre)'**
  String get iptvGeoBlocked;

  /// No description provided for @iptvNotAlways.
  ///
  /// In de, this message translates to:
  /// **'Sendet nicht rund um die Uhr'**
  String get iptvNotAlways;

  /// No description provided for @iptvSource.
  ///
  /// In de, this message translates to:
  /// **'Quelle: offener Senderkatalog iptv-org (github.com/iptv-org/iptv)'**
  String get iptvSource;

  /// No description provided for @iptvNotSetUpIntro.
  ///
  /// In de, this message translates to:
  /// **'Oder ganz ohne Receiver: frei empfangbare Sender aus dem Internet (Internet-TV).'**
  String get iptvNotSetUpIntro;

  /// No description provided for @iptvSetUp.
  ///
  /// In de, this message translates to:
  /// **'Internet-TV-Sender suchen'**
  String get iptvSetUp;

  /// No description provided for @iptvSettingsTitle.
  ///
  /// In de, this message translates to:
  /// **'Internet-TV'**
  String get iptvSettingsTitle;

  /// No description provided for @iptvSettingsIntro.
  ///
  /// In de, this message translates to:
  /// **'Frei und legal empfangbare Fernsehsender aus dem Internet – aus dem offenen Senderkatalog iptv-org (github.com/iptv-org/iptv). Internet-TV hat eine eigene Senderliste mit eigenen Nummern; die Liste des Receivers bleibt, wie sie ist. Manche Sender gehen nur in ihrem Land (Geo-Sperre) oder nicht rund um die Uhr.'**
  String get iptvSettingsIntro;

  /// No description provided for @iptvSettingsEnabled.
  ///
  /// In de, this message translates to:
  /// **'Internet-TV im TV anzeigen'**
  String get iptvSettingsEnabled;

  /// No description provided for @iptvSettingsCountries.
  ///
  /// In de, this message translates to:
  /// **'Meine Länder'**
  String get iptvSettingsCountries;

  /// No description provided for @iptvSettingsCountriesHelp.
  ///
  /// In de, this message translates to:
  /// **'Mit diesen Ländern beginnt die Sendersuche.'**
  String get iptvSettingsCountriesHelp;

  /// No description provided for @iptvSettingsLanguages.
  ///
  /// In de, this message translates to:
  /// **'Meine Sprachen'**
  String get iptvSettingsLanguages;

  /// No description provided for @iptvSettingsLanguagesHelp.
  ///
  /// In de, this message translates to:
  /// **'Mit diesen Sprachen beginnt die Sendersuche – keine: alle Sprachen.'**
  String get iptvSettingsLanguagesHelp;

  /// No description provided for @iptvSettingsAddCountry.
  ///
  /// In de, this message translates to:
  /// **'Land hinzufügen'**
  String get iptvSettingsAddCountry;

  /// No description provided for @iptvSettingsAddLanguage.
  ///
  /// In de, this message translates to:
  /// **'Sprache hinzufügen'**
  String get iptvSettingsAddLanguage;

  /// No description provided for @iptvSettingsChipHelp.
  ///
  /// In de, this message translates to:
  /// **'OK auf ein Land bzw. eine Sprache nimmt es wieder heraus.'**
  String get iptvSettingsChipHelp;

  /// No description provided for @iptvSettingsCatalogue.
  ///
  /// In de, this message translates to:
  /// **'Senderkatalog'**
  String get iptvSettingsCatalogue;

  /// No description provided for @iptvSettingsCatalogueHelp.
  ///
  /// In de, this message translates to:
  /// **'Wird beim ersten Suchen geladen und danach höchstens einmal am Tag aktualisiert.'**
  String get iptvSettingsCatalogueHelp;

  /// No description provided for @iptvSettingsRefresh.
  ///
  /// In de, this message translates to:
  /// **'Jetzt aktualisieren'**
  String get iptvSettingsRefresh;

  /// No description provided for @iptvSettingsFavorites.
  ///
  /// In de, this message translates to:
  /// **'{count, plural, =0{Noch keine Sender in der Internet-TV-Liste} =1{1 Sender in der Internet-TV-Liste} other{{count} Sender in der Internet-TV-Liste}}'**
  String iptvSettingsFavorites(int count);

  /// No description provided for @iptvSettingsFavoritesHelp.
  ///
  /// In de, this message translates to:
  /// **'Sortieren und entfernen in der Senderliste des TV: dort → auf einem Sender.'**
  String get iptvSettingsFavoritesHelp;

  /// No description provided for @iptvSettingsClearFavorites.
  ///
  /// In de, this message translates to:
  /// **'Alle entfernen'**
  String get iptvSettingsClearFavorites;

  /// No description provided for @iptvSettingsClearConfirm.
  ///
  /// In de, this message translates to:
  /// **'Alle {count} Sender aus der Internet-TV-Liste entfernen?'**
  String iptvSettingsClearConfirm(int count);

  /// No description provided for @miscApply.
  ///
  /// In de, this message translates to:
  /// **'Übernehmen'**
  String get miscApply;

  /// No description provided for @miscLocationTitle.
  ///
  /// In de, this message translates to:
  /// **'Standort einrichten'**
  String get miscLocationTitle;

  /// No description provided for @miscLocationIntro.
  ///
  /// In de, this message translates to:
  /// **'Gemeinsamer Standort für Wetterprognose, Wetterradar und Sonne & Mond.'**
  String get miscLocationIntro;

  /// No description provided for @miscLocationCurrent.
  ///
  /// In de, this message translates to:
  /// **'Aktuell: {name} ({lat}, {lon})'**
  String miscLocationCurrent(String name, String lat, String lon);

  /// No description provided for @miscLocationSearchLabel.
  ///
  /// In de, this message translates to:
  /// **'Ort suchen, z. B. Graz oder Gleisdorf'**
  String get miscLocationSearchLabel;

  /// No description provided for @miscLocationSearch.
  ///
  /// In de, this message translates to:
  /// **'Suchen'**
  String get miscLocationSearch;

  /// No description provided for @miscLocationSearchFailed.
  ///
  /// In de, this message translates to:
  /// **'Suche fehlgeschlagen - Internetverbindung prüfen.'**
  String get miscLocationSearchFailed;

  /// No description provided for @miscLocationNoResults.
  ///
  /// In de, this message translates to:
  /// **'Kein Ort gefunden.'**
  String get miscLocationNoResults;

  /// No description provided for @miscLocationPicked.
  ///
  /// In de, this message translates to:
  /// **'Standort: {name}'**
  String miscLocationPicked(String name);

  /// No description provided for @miscLocationAttribution.
  ///
  /// In de, this message translates to:
  /// **'Ortssuche: © OpenStreetMap-Mitwirkende (ODbL), über Nominatim.'**
  String get miscLocationAttribution;

  /// No description provided for @miscRadarTitle.
  ///
  /// In de, this message translates to:
  /// **'Wetterradar einrichten'**
  String get miscRadarTitle;

  /// No description provided for @miscRadarInvalidUrl.
  ///
  /// In de, this message translates to:
  /// **'Bitte eine vollständige Adresse mit http:// oder https:// eingeben.'**
  String get miscRadarInvalidUrl;

  /// No description provided for @miscRadarSourceType.
  ///
  /// In de, this message translates to:
  /// **'Art der Quelle'**
  String get miscRadarSourceType;

  /// No description provided for @miscRadarImage.
  ///
  /// In de, this message translates to:
  /// **'Bild'**
  String get miscRadarImage;

  /// No description provided for @miscRadarImageHint.
  ///
  /// In de, this message translates to:
  /// **'PNG oder JPG, z. B. vom eigenen Radar-Server - wird alle 2½ Minuten neu geladen.'**
  String get miscRadarImageHint;

  /// No description provided for @miscRadarWebPage.
  ///
  /// In de, this message translates to:
  /// **'Webseite'**
  String get miscRadarWebPage;

  /// No description provided for @miscRadarWebPageHint.
  ///
  /// In de, this message translates to:
  /// **'Eine Radar-Webseite, z. B. eine interaktive Karte. Braucht mehr Speicher und Grafikleistung als ein Bild - auf schwachen TV-Boxen besser ein Bild verwenden.'**
  String get miscRadarWebPageHint;

  /// No description provided for @miscRadarWebPageUrl.
  ///
  /// In de, this message translates to:
  /// **'Adresse der Webseite (URL)'**
  String get miscRadarWebPageUrl;

  /// No description provided for @miscRadarImageUrl.
  ///
  /// In de, this message translates to:
  /// **'Bild-Adresse (URL)'**
  String get miscRadarImageUrl;

  /// The placeholders are filled with the literal tokens {lat}, {lon}, ... the user types into the URL.
  ///
  /// In de, this message translates to:
  /// **'Platzhalter werden automatisch ersetzt: {lat} {lon} = Standort, {r} = Umkreis in km, {zoom} = Kartenzoom passend zum Umkreis, {w} {h} = Kachelgröße in Pixeln, {scale} = Bildschirmdichte.'**
  String miscRadarPlaceholders(
    String lat,
    String lon,
    String r,
    String zoom,
    String w,
    String h,
    String scale,
  );

  /// No description provided for @miscRadarDisclaimer.
  ///
  /// In de, this message translates to:
  /// **'Die App bringt selbst keine Radarquelle mit. Rechte und Nutzungsbedingungen liegen beim jeweiligen Anbieter - bitte nur Quellen eintragen, die so genutzt werden dürfen.'**
  String get miscRadarDisclaimer;

  /// No description provided for @miscRadarCssLabel.
  ///
  /// In de, this message translates to:
  /// **'Eigenes CSS für die Webseite (optional)'**
  String get miscRadarCssLabel;

  /// No description provided for @miscRadarCssHint.
  ///
  /// In de, this message translates to:
  /// **'Wird nach jedem Laden in die Seite eingefügt, wie ein eigenes Stylesheet im Browser - z. B. um Teile der Seite für die eigene Anzeige auszublenden.'**
  String get miscRadarCssHint;

  /// No description provided for @miscRadarAuth.
  ///
  /// In de, this message translates to:
  /// **'Mit Anmeldung (Token)'**
  String get miscRadarAuth;

  /// No description provided for @miscRadarAuthHint.
  ///
  /// In de, this message translates to:
  /// **'Wird als „Authorization: Bearer …“ mitgeschickt.'**
  String get miscRadarAuthHint;

  /// No description provided for @miscRemoteKeysTitle.
  ///
  /// In de, this message translates to:
  /// **'Tasten der Fernbedienung'**
  String get miscRemoteKeysTitle;

  /// No description provided for @miscRemoteKeysIntro.
  ///
  /// In de, this message translates to:
  /// **'Eine Aktion wählen und dann die Taste drücken, die sie auslösen soll - sie ersetzt die bisherigen Tasten der Aktion. So bleibt z. B. ☰ frei, wenn sie auf der Fernbedienung etwas anderes tut. Pfeiltasten, Zurück und Home lassen sich nicht belegen.'**
  String get miscRemoteKeysIntro;

  /// No description provided for @miscRemoteKeysNone.
  ///
  /// In de, this message translates to:
  /// **'keine Taste'**
  String get miscRemoteKeysNone;

  /// No description provided for @miscRemoteKeysStandard.
  ///
  /// In de, this message translates to:
  /// **'Standard'**
  String get miscRemoteKeysStandard;

  /// No description provided for @miscRemoteKeysResetHint.
  ///
  /// In de, this message translates to:
  /// **'Langer Druck auf OK bei einer Aktion: wieder die Standard-Tasten.'**
  String get miscRemoteKeysResetHint;

  /// No description provided for @miscRemoteKeysNotAssignable.
  ///
  /// In de, this message translates to:
  /// **'{key} lässt sich nicht belegen.'**
  String miscRemoteKeysNotAssignable(String key);

  /// No description provided for @miscRemoteKeysPressNow.
  ///
  /// In de, this message translates to:
  /// **'Jetzt die Taste drücken …'**
  String get miscRemoteKeysPressNow;

  /// No description provided for @miscRemoteKeysBackCancels.
  ///
  /// In de, this message translates to:
  /// **'Zurück bricht ab.'**
  String get miscRemoteKeysBackCancels;

  /// No description provided for @miscActionChannelList.
  ///
  /// In de, this message translates to:
  /// **'Senderliste (TV)'**
  String get miscActionChannelList;

  /// No description provided for @miscActionGuide.
  ///
  /// In de, this message translates to:
  /// **'Programmführer (TV)'**
  String get miscActionGuide;

  /// No description provided for @miscActionOptions.
  ///
  /// In de, this message translates to:
  /// **'Optionen (Kachel unter Home, TV)'**
  String get miscActionOptions;

  /// No description provided for @miscActionAudio.
  ///
  /// In de, this message translates to:
  /// **'Tonspur (TV)'**
  String get miscActionAudio;

  /// No description provided for @miscKeyMenu.
  ///
  /// In de, this message translates to:
  /// **'☰ Menü'**
  String get miscKeyMenu;

  /// No description provided for @miscKeySearch.
  ///
  /// In de, this message translates to:
  /// **'Suche'**
  String get miscKeySearch;

  /// No description provided for @miscKeyRed.
  ///
  /// In de, this message translates to:
  /// **'Rot'**
  String get miscKeyRed;

  /// No description provided for @miscKeyGreen.
  ///
  /// In de, this message translates to:
  /// **'Grün'**
  String get miscKeyGreen;

  /// No description provided for @miscKeyYellow.
  ///
  /// In de, this message translates to:
  /// **'Gelb'**
  String get miscKeyYellow;

  /// No description provided for @miscKeyBlue.
  ///
  /// In de, this message translates to:
  /// **'Blau'**
  String get miscKeyBlue;

  /// No description provided for @miscKeyNamed.
  ///
  /// In de, this message translates to:
  /// **'Taste {key}'**
  String miscKeyNamed(String key);

  /// No description provided for @miscRegionEurope.
  ///
  /// In de, this message translates to:
  /// **'Europa'**
  String get miscRegionEurope;

  /// No description provided for @miscRegionNorthAmerica.
  ///
  /// In de, this message translates to:
  /// **'Nord- & Mittelamerika'**
  String get miscRegionNorthAmerica;

  /// No description provided for @miscRegionSouthAmerica.
  ///
  /// In de, this message translates to:
  /// **'Südamerika'**
  String get miscRegionSouthAmerica;

  /// No description provided for @miscRegionAsia.
  ///
  /// In de, this message translates to:
  /// **'Asien & Nahost'**
  String get miscRegionAsia;

  /// No description provided for @miscRegionAfrica.
  ///
  /// In de, this message translates to:
  /// **'Afrika'**
  String get miscRegionAfrica;

  /// No description provided for @miscRegionOceania.
  ///
  /// In de, this message translates to:
  /// **'Ozeanien'**
  String get miscRegionOceania;

  /// No description provided for @miscRegionOther.
  ///
  /// In de, this message translates to:
  /// **'Andere'**
  String get miscRegionOther;

  /// No description provided for @miscUpdatesTitle.
  ///
  /// In de, this message translates to:
  /// **'Updates'**
  String get miscUpdatesTitle;

  /// No description provided for @miscUpdateDialogTitle.
  ///
  /// In de, this message translates to:
  /// **'Update auf {version}'**
  String miscUpdateDialogTitle(String version);

  /// No description provided for @miscUpdateDownloading.
  ///
  /// In de, this message translates to:
  /// **'Wird geladen…'**
  String get miscUpdateDownloading;

  /// No description provided for @miscUpdateDownloadingPercent.
  ///
  /// In de, this message translates to:
  /// **'Wird geladen… {percent} %'**
  String miscUpdateDownloadingPercent(int percent);

  /// No description provided for @miscUpdateFailed.
  ///
  /// In de, this message translates to:
  /// **'Update fehlgeschlagen: {error}'**
  String miscUpdateFailed(String error);

  /// No description provided for @miscUpdateInstalledVersion.
  ///
  /// In de, this message translates to:
  /// **'Installierte Version: {version}'**
  String miscUpdateInstalledVersion(String version);

  /// No description provided for @miscUpdateLocalBuild.
  ///
  /// In de, this message translates to:
  /// **'Diese Version wurde lokal gebaut und aktualisiert sich nicht selbst.'**
  String get miscUpdateLocalBuild;

  /// No description provided for @miscUpdateAuto.
  ///
  /// In de, this message translates to:
  /// **'Beim Start automatisch aktualisieren'**
  String get miscUpdateAuto;

  /// No description provided for @miscUpdateAutoHint.
  ///
  /// In de, this message translates to:
  /// **'Neue Versionen werden beim Start geladen und installiert.'**
  String get miscUpdateAutoHint;

  /// No description provided for @miscUpdateChecking.
  ///
  /// In de, this message translates to:
  /// **'Suche nach Updates…'**
  String get miscUpdateChecking;

  /// No description provided for @miscUpdateAvailable.
  ///
  /// In de, this message translates to:
  /// **'Neue Version {version} verfügbar.'**
  String miscUpdateAvailable(String version);

  /// No description provided for @miscUpdateNow.
  ///
  /// In de, this message translates to:
  /// **'Jetzt aktualisieren'**
  String get miscUpdateNow;

  /// No description provided for @miscUpdateUpToDate.
  ///
  /// In de, this message translates to:
  /// **'Die App ist aktuell (oder der Update-Server ist nicht erreichbar).'**
  String get miscUpdateUpToDate;

  /// No description provided for @miscUpdateCheckAgain.
  ///
  /// In de, this message translates to:
  /// **'Erneut suchen'**
  String get miscUpdateCheckAgain;

  /// No description provided for @miscUpdateAllowUnknownApps.
  ///
  /// In de, this message translates to:
  /// **'Bitte „Unbekannte Apps installieren“ für Home System erlauben und das Update erneut starten.'**
  String get miscUpdateAllowUnknownApps;

  /// No description provided for @miscUpdateInstallCancelled.
  ///
  /// In de, this message translates to:
  /// **'Installation abgebrochen ({code}).'**
  String miscUpdateInstallCancelled(int code);

  /// No description provided for @miscUpdateDownloadFailed.
  ///
  /// In de, this message translates to:
  /// **'Download fehlgeschlagen (HTTP {status}).'**
  String miscUpdateDownloadFailed(int status);

  /// No description provided for @miscUpdateCorrupt.
  ///
  /// In de, this message translates to:
  /// **'Die heruntergeladene Datei ist beschädigt.'**
  String get miscUpdateCorrupt;

  /// No description provided for @miscAllAppsTitle.
  ///
  /// In de, this message translates to:
  /// **'Alle Apps'**
  String get miscAllAppsTitle;

  /// No description provided for @miscAllAppsOpen.
  ///
  /// In de, this message translates to:
  /// **'Öffnen'**
  String get miscAllAppsOpen;

  /// No description provided for @miscAllAppsAddFavorite.
  ///
  /// In de, this message translates to:
  /// **'Zu den Favoriten hinzufügen'**
  String get miscAllAppsAddFavorite;

  /// No description provided for @miscAllAppsRemoveFavorite.
  ///
  /// In de, this message translates to:
  /// **'Aus den Favoriten entfernen'**
  String get miscAllAppsRemoveFavorite;

  /// No description provided for @miscAllAppsAppInfo.
  ///
  /// In de, this message translates to:
  /// **'App-Info (beenden, deinstallieren …)'**
  String get miscAllAppsAppInfo;

  /// No description provided for @miscAllAppsFavoriteAdded.
  ///
  /// In de, this message translates to:
  /// **'„{app}“ zu den Favoriten hinzugefügt'**
  String miscAllAppsFavoriteAdded(String app);

  /// No description provided for @miscAllAppsFavoriteRemoved.
  ///
  /// In de, this message translates to:
  /// **'„{app}“ aus den Favoriten entfernt'**
  String miscAllAppsFavoriteRemoved(String app);

  /// No description provided for @miscAllAppsSearch.
  ///
  /// In de, this message translates to:
  /// **'App suchen'**
  String get miscAllAppsSearch;

  /// No description provided for @miscAllAppsClearSearch.
  ///
  /// In de, this message translates to:
  /// **'Suche löschen'**
  String get miscAllAppsClearSearch;

  /// No description provided for @miscAllAppsSettingsIsFavorite.
  ///
  /// In de, this message translates to:
  /// **'TV-Einstellungen in den Favoriten'**
  String get miscAllAppsSettingsIsFavorite;

  /// No description provided for @miscAllAppsSettingsAddFavorite.
  ///
  /// In de, this message translates to:
  /// **'TV-Einstellungen als Favorit'**
  String get miscAllAppsSettingsAddFavorite;

  /// No description provided for @miscAllAppsHelp.
  ///
  /// In de, this message translates to:
  /// **'OK: App öffnen  ·  ☰ oder OK lange drücken: Favorit, App-Info (beenden, deinstallieren)'**
  String get miscAllAppsHelp;

  /// No description provided for @miscAllAppsLoadError.
  ///
  /// In de, this message translates to:
  /// **'Apps konnten nicht gelesen werden: {error}'**
  String miscAllAppsLoadError(String error);

  /// No description provided for @miscAllAppsNone.
  ///
  /// In de, this message translates to:
  /// **'Keine Apps gefunden.'**
  String get miscAllAppsNone;

  /// No description provided for @miscAllAppsNoMatch.
  ///
  /// In de, this message translates to:
  /// **'Keine App passt zu „{query}“.'**
  String miscAllAppsNoMatch(String query);

  /// No description provided for @miscBackdropAurora.
  ///
  /// In de, this message translates to:
  /// **'Nordlicht'**
  String get miscBackdropAurora;

  /// No description provided for @miscBackdropSunset.
  ///
  /// In de, this message translates to:
  /// **'Abendrot'**
  String get miscBackdropSunset;

  /// No description provided for @miscBackdropOcean.
  ///
  /// In de, this message translates to:
  /// **'Ozean'**
  String get miscBackdropOcean;

  /// No description provided for @miscBackdropForest.
  ///
  /// In de, this message translates to:
  /// **'Wald'**
  String get miscBackdropForest;

  /// No description provided for @miscBackdropLavender.
  ///
  /// In de, this message translates to:
  /// **'Lavendel'**
  String get miscBackdropLavender;

  /// No description provided for @miscBackdropEmbers.
  ///
  /// In de, this message translates to:
  /// **'Glut'**
  String get miscBackdropEmbers;

  /// No description provided for @miscBackdropNight.
  ///
  /// In de, this message translates to:
  /// **'Nacht'**
  String get miscBackdropNight;

  /// No description provided for @miscBackdropDesert.
  ///
  /// In de, this message translates to:
  /// **'Wüste'**
  String get miscBackdropDesert;

  /// No description provided for @modelsAcarsAckNoContent.
  ///
  /// In de, this message translates to:
  /// **'Quittung (ohne Inhalt)'**
  String get modelsAcarsAckNoContent;

  /// No description provided for @modelsAcarsLinkTest.
  ///
  /// In de, this message translates to:
  /// **'Verbindungstest'**
  String get modelsAcarsLinkTest;

  /// No description provided for @modelsAcarsOnboardComputer.
  ///
  /// In de, this message translates to:
  /// **'Bordrechner (FMS/Wartung)'**
  String get modelsAcarsOnboardComputer;

  /// No description provided for @modelsAcarsSystemStatus.
  ///
  /// In de, this message translates to:
  /// **'Systemstatus'**
  String get modelsAcarsSystemStatus;

  /// No description provided for @modelsAcarsAirlineMessage.
  ///
  /// In de, this message translates to:
  /// **'Airline-Meldung'**
  String get modelsAcarsAirlineMessage;

  /// No description provided for @modelsAcarsFlightData.
  ///
  /// In de, this message translates to:
  /// **'Flugdaten'**
  String get modelsAcarsFlightData;

  /// No description provided for @modelsAcarsMessage.
  ///
  /// In de, this message translates to:
  /// **'Meldung'**
  String get modelsAcarsMessage;

  /// No description provided for @modelsAircraftLight.
  ///
  /// In de, this message translates to:
  /// **'Leichtflugzeug'**
  String get modelsAircraftLight;

  /// No description provided for @modelsAircraftLightShort.
  ///
  /// In de, this message translates to:
  /// **'leicht'**
  String get modelsAircraftLightShort;

  /// No description provided for @modelsAircraftSmall.
  ///
  /// In de, this message translates to:
  /// **'Kleinflugzeug'**
  String get modelsAircraftSmall;

  /// No description provided for @modelsAircraftSmallShort.
  ///
  /// In de, this message translates to:
  /// **'klein'**
  String get modelsAircraftSmallShort;

  /// No description provided for @modelsAircraftLarge.
  ///
  /// In de, this message translates to:
  /// **'Verkehrsflugzeug'**
  String get modelsAircraftLarge;

  /// No description provided for @modelsAircraftLargeShort.
  ///
  /// In de, this message translates to:
  /// **'groß'**
  String get modelsAircraftLargeShort;

  /// No description provided for @modelsAircraftHeavy.
  ///
  /// In de, this message translates to:
  /// **'Großraumflugzeug'**
  String get modelsAircraftHeavy;

  /// No description provided for @modelsAircraftHeavyShort.
  ///
  /// In de, this message translates to:
  /// **'schwer'**
  String get modelsAircraftHeavyShort;

  /// No description provided for @modelsAircraftHighPerformance.
  ///
  /// In de, this message translates to:
  /// **'Hochleistungs-/Militärjet'**
  String get modelsAircraftHighPerformance;

  /// No description provided for @modelsAircraftGlider.
  ///
  /// In de, this message translates to:
  /// **'Segelflugzeug'**
  String get modelsAircraftGlider;

  /// No description provided for @modelsAircraftGliderShort.
  ///
  /// In de, this message translates to:
  /// **'Segler'**
  String get modelsAircraftGliderShort;

  /// No description provided for @modelsAircraftBalloon.
  ///
  /// In de, this message translates to:
  /// **'Ballon / Luftschiff'**
  String get modelsAircraftBalloon;

  /// No description provided for @modelsAircraftUltralight.
  ///
  /// In de, this message translates to:
  /// **'Ultraleicht / Gleitschirm'**
  String get modelsAircraftUltralight;

  /// No description provided for @modelsAircraftUav.
  ///
  /// In de, this message translates to:
  /// **'Drohne'**
  String get modelsAircraftUav;

  /// No description provided for @modelsAircraftSurface.
  ///
  /// In de, this message translates to:
  /// **'Bodenfahrzeug'**
  String get modelsAircraftSurface;

  /// No description provided for @modelsAircraftSurfaceShort.
  ///
  /// In de, this message translates to:
  /// **'Boden'**
  String get modelsAircraftSurfaceShort;

  /// No description provided for @modelsDmrRadio.
  ///
  /// In de, this message translates to:
  /// **'Funkgerät'**
  String get modelsDmrRadio;

  /// No description provided for @modelsDmrDirect.
  ///
  /// In de, this message translates to:
  /// **'Direktverbindung'**
  String get modelsDmrDirect;

  /// No description provided for @modelsIsmRemoteSwitch.
  ///
  /// In de, this message translates to:
  /// **'Funkschalter (EV1527)'**
  String get modelsIsmRemoteSwitch;

  /// No description provided for @modelsIsmButton.
  ///
  /// In de, this message translates to:
  /// **'Taste {code}'**
  String modelsIsmButton(String code);

  /// No description provided for @nasTitle.
  ///
  /// In de, this message translates to:
  /// **'NAS (Netzwerkspeicher)'**
  String get nasTitle;

  /// No description provided for @nasIntro.
  ///
  /// In de, this message translates to:
  /// **'Der Netzwerkspeicher im eigenen Netz: Backups vor jedem Update, Hintergrundbilder für Home - und später Musik, Videos und Filme vom Server.'**
  String get nasIntro;

  /// No description provided for @nasServerSection.
  ///
  /// In de, this message translates to:
  /// **'Server'**
  String get nasServerSection;

  /// No description provided for @nasProtocolWebdav.
  ///
  /// In de, this message translates to:
  /// **'WebDAV'**
  String get nasProtocolWebdav;

  /// No description provided for @nasProtocolWebdavHint.
  ///
  /// In de, this message translates to:
  /// **'Synology, QNAP, Nextcloud, Apache/nginx … - über http oder https.'**
  String get nasProtocolWebdavHint;

  /// No description provided for @nasProtocolFtp.
  ///
  /// In de, this message translates to:
  /// **'FTP'**
  String get nasProtocolFtp;

  /// No description provided for @nasProtocolFtpHint.
  ///
  /// In de, this message translates to:
  /// **'Unverschlüsselt - nur im eigenen Netz verwenden.'**
  String get nasProtocolFtpHint;

  /// No description provided for @nasHost.
  ///
  /// In de, this message translates to:
  /// **'Server-Adresse (IP oder Name)'**
  String get nasHost;

  /// No description provided for @nasHostHint.
  ///
  /// In de, this message translates to:
  /// **'z. B. 192.168.1.10'**
  String get nasHostHint;

  /// No description provided for @nasPort.
  ///
  /// In de, this message translates to:
  /// **'Port (leer = {port})'**
  String nasPort(int port);

  /// No description provided for @nasHttps.
  ///
  /// In de, this message translates to:
  /// **'Verschlüsselt (https)'**
  String get nasHttps;

  /// No description provided for @nasHttpsHint.
  ///
  /// In de, this message translates to:
  /// **'Das Zertifikat des NAS wird akzeptiert, auch wenn es selbst signiert ist.'**
  String get nasHttpsHint;

  /// No description provided for @nasBasePath.
  ///
  /// In de, this message translates to:
  /// **'WebDAV-Pfad'**
  String get nasBasePath;

  /// No description provided for @nasBasePathHint.
  ///
  /// In de, this message translates to:
  /// **'leer, oder z. B. /remote.php/dav/files/NAME'**
  String get nasBasePathHint;

  /// No description provided for @nasUser.
  ///
  /// In de, this message translates to:
  /// **'Benutzername'**
  String get nasUser;

  /// No description provided for @nasPassword.
  ///
  /// In de, this message translates to:
  /// **'Passwort'**
  String get nasPassword;

  /// No description provided for @nasTest.
  ///
  /// In de, this message translates to:
  /// **'Verbindung testen'**
  String get nasTest;

  /// No description provided for @nasTestOk.
  ///
  /// In de, this message translates to:
  /// **'Verbindung OK - {count} Einträge im Hauptordner.'**
  String nasTestOk(int count);

  /// No description provided for @nasTestFailed.
  ///
  /// In de, this message translates to:
  /// **'Keine Verbindung: {message}'**
  String nasTestFailed(String message);

  /// No description provided for @nasFoldersSection.
  ///
  /// In de, this message translates to:
  /// **'Ordner'**
  String get nasFoldersSection;

  /// No description provided for @nasFoldersHint.
  ///
  /// In de, this message translates to:
  /// **'OK wählt einen Ordner auf dem NAS. Musik, Videos und Filme sind für später (Abspielen vom Server).'**
  String get nasFoldersHint;

  /// No description provided for @nasNeedServer.
  ///
  /// In de, this message translates to:
  /// **'Zuerst die Server-Adresse eintragen.'**
  String get nasNeedServer;

  /// No description provided for @nasFolderPictures.
  ///
  /// In de, this message translates to:
  /// **'Bilder'**
  String get nasFolderPictures;

  /// No description provided for @nasFolderMusic.
  ///
  /// In de, this message translates to:
  /// **'Musik'**
  String get nasFolderMusic;

  /// No description provided for @nasFolderVideos.
  ///
  /// In de, this message translates to:
  /// **'Videos'**
  String get nasFolderVideos;

  /// No description provided for @nasFolderMovies.
  ///
  /// In de, this message translates to:
  /// **'Filme'**
  String get nasFolderMovies;

  /// No description provided for @nasFolderBackups.
  ///
  /// In de, this message translates to:
  /// **'Backups'**
  String get nasFolderBackups;

  /// No description provided for @nasFolderNotChosen.
  ///
  /// In de, this message translates to:
  /// **'Nicht gewählt'**
  String get nasFolderNotChosen;

  /// No description provided for @nasFolderClear.
  ///
  /// In de, this message translates to:
  /// **'Auswahl entfernen'**
  String get nasFolderClear;

  /// No description provided for @nasBackupsHint.
  ///
  /// In de, this message translates to:
  /// **'Vor jedem Update wird ein Backup in den Backup-Ordner gelegt; die {count} neuesten dieses Geräts bleiben.'**
  String nasBackupsHint(int count);

  /// No description provided for @nasPicturesHint.
  ///
  /// In de, this message translates to:
  /// **'Die Bilder können der Hintergrund von Home sein (Einstellungen → Home → Hintergrund → Eigener Server).'**
  String get nasPicturesHint;

  /// No description provided for @nasBrowseTitle.
  ///
  /// In de, this message translates to:
  /// **'Ordner für {folder}'**
  String nasBrowseTitle(String folder);

  /// No description provided for @nasChooseThisFolder.
  ///
  /// In de, this message translates to:
  /// **'Diesen Ordner wählen'**
  String get nasChooseThisFolder;

  /// No description provided for @nasUp.
  ///
  /// In de, this message translates to:
  /// **'Eine Ebene höher'**
  String get nasUp;

  /// No description provided for @nasNoSubfolders.
  ///
  /// In de, this message translates to:
  /// **'Keine Unterordner.'**
  String get nasNoSubfolders;

  /// No description provided for @nasFilesInFolder.
  ///
  /// In de, this message translates to:
  /// **'{count} Dateien in diesem Ordner'**
  String nasFilesInFolder(int count);

  /// No description provided for @nasBrowseBackHint.
  ///
  /// In de, this message translates to:
  /// **'Zurück: eine Ebene höher'**
  String get nasBrowseBackHint;

  /// No description provided for @nasErrorTimeout.
  ///
  /// In de, this message translates to:
  /// **'Der Server antwortet nicht (Zeitüberschreitung).'**
  String get nasErrorTimeout;

  /// No description provided for @nasErrorTls.
  ///
  /// In de, this message translates to:
  /// **'Die verschlüsselte Verbindung klappt nicht - stimmen https und der Port?'**
  String get nasErrorTls;

  /// No description provided for @nasErrorRefused.
  ///
  /// In de, this message translates to:
  /// **'Der Server lehnt die Verbindung ab - stimmen Protokoll und Port?'**
  String get nasErrorRefused;

  /// No description provided for @nasErrorHostNotFound.
  ///
  /// In de, this message translates to:
  /// **'Server-Name nicht gefunden.'**
  String get nasErrorHostNotFound;

  /// No description provided for @nasErrorUnreachable.
  ///
  /// In de, this message translates to:
  /// **'Server nicht erreichbar.'**
  String get nasErrorUnreachable;

  /// No description provided for @nasErrorOther.
  ///
  /// In de, this message translates to:
  /// **'Fehler: {message}'**
  String nasErrorOther(String message);

  /// No description provided for @nasErrorLogin.
  ///
  /// In de, this message translates to:
  /// **'Anmeldung fehlgeschlagen - Benutzername oder Passwort falsch, oder keine Berechtigung.'**
  String get nasErrorLogin;

  /// No description provided for @nasErrorNotFound.
  ///
  /// In de, this message translates to:
  /// **'Ordner oder Datei nicht gefunden.'**
  String get nasErrorNotFound;

  /// No description provided for @nasErrorNoWebDav.
  ///
  /// In de, this message translates to:
  /// **'Der Server antwortet nicht wie ein WebDAV-Server - stimmt der WebDAV-Pfad?'**
  String get nasErrorNoWebDav;

  /// No description provided for @nasErrorFull.
  ///
  /// In de, this message translates to:
  /// **'Auf dem NAS ist kein Platz mehr.'**
  String get nasErrorFull;

  /// No description provided for @nasErrorHttp.
  ///
  /// In de, this message translates to:
  /// **'Der Server meldet den HTTP-Fehler {status}.'**
  String nasErrorHttp(int status);

  /// No description provided for @nasErrorTooBig.
  ///
  /// In de, this message translates to:
  /// **'Die Datei ist zu groß.'**
  String get nasErrorTooBig;

  /// No description provided for @nasErrorFtp.
  ///
  /// In de, this message translates to:
  /// **'Der FTP-Server meldet: {reply}'**
  String nasErrorFtp(String reply);

  /// No description provided for @nasBackupRunning.
  ///
  /// In de, this message translates to:
  /// **'Backup auf das NAS …'**
  String get nasBackupRunning;

  /// No description provided for @nasBackupFailed.
  ///
  /// In de, this message translates to:
  /// **'Backup auf das NAS fehlgeschlagen ({message}) - das Update läuft trotzdem.'**
  String nasBackupFailed(String message);

  /// No description provided for @nasRestoreSection.
  ///
  /// In de, this message translates to:
  /// **'Backups auf dem NAS'**
  String get nasRestoreSection;

  /// No description provided for @nasRestoreHint.
  ///
  /// In de, this message translates to:
  /// **'Aus dem Backup-Ordner {folder} - auch die anderer Geräte.'**
  String nasRestoreHint(String folder);

  /// No description provided for @nasRestoreNone.
  ///
  /// In de, this message translates to:
  /// **'Keine Backups im NAS-Ordner.'**
  String get nasRestoreNone;

  /// No description provided for @nasRestoreLoadFailed.
  ///
  /// In de, this message translates to:
  /// **'Die Backups auf dem NAS konnten nicht gelesen werden: {message}'**
  String nasRestoreLoadFailed(String message);

  /// No description provided for @nasRestoreDownloadFailed.
  ///
  /// In de, this message translates to:
  /// **'Das Backup konnte nicht vom NAS geladen werden: {message}'**
  String nasRestoreDownloadFailed(String message);

  /// No description provided for @nasBgFromNas.
  ///
  /// In de, this message translates to:
  /// **'Hintergrundbilder vom NAS'**
  String get nasBgFromNas;

  /// No description provided for @nasBgFromNasHint.
  ///
  /// In de, this message translates to:
  /// **'{folder} (mit Unterordnern) - davon jedes Mal ein zufälliges Bild. Bis zu 30 Bilder liegen verkleinert auf dem Gerät; abgeglichen wird beim App-Start und mit „Jetzt abgleichen“.'**
  String nasBgFromNasHint(String folder);

  /// No description provided for @nasBgNoFolder.
  ///
  /// In de, this message translates to:
  /// **'Zuerst unter Einstellungen → System → NAS-Server einen Ordner für Hintergrundbilder wählen.'**
  String get nasBgNoFolder;

  /// No description provided for @nasBgFromUrl.
  ///
  /// In de, this message translates to:
  /// **'Adresse (http)'**
  String get nasBgFromUrl;

  /// No description provided for @nasBgFromUrlHint.
  ///
  /// In de, this message translates to:
  /// **'Ein Webserver, der Bilder liefert (siehe unten).'**
  String get nasBgFromUrlHint;

  /// No description provided for @nasBgSyncNow.
  ///
  /// In de, this message translates to:
  /// **'Jetzt abgleichen'**
  String get nasBgSyncNow;

  /// No description provided for @nasBgSyncing.
  ///
  /// In de, this message translates to:
  /// **'Wird abgeglichen …'**
  String get nasBgSyncing;

  /// No description provided for @nasBgStatus.
  ///
  /// In de, this message translates to:
  /// **'{count} Bilder auf dem Gerät'**
  String nasBgStatus(int count);

  /// No description provided for @nasBgLastSync.
  ///
  /// In de, this message translates to:
  /// **'{count} Bilder auf dem Gerät, abgeglichen am {date}'**
  String nasBgLastSync(int count, String date);

  /// No description provided for @nasBgSyncError.
  ///
  /// In de, this message translates to:
  /// **'Abgleich fehlgeschlagen: {message}'**
  String nasBgSyncError(String message);

  /// No description provided for @nasFolderBackgrounds.
  ///
  /// In de, this message translates to:
  /// **'Hintergrundbilder (Home)'**
  String get nasFolderBackgrounds;

  /// No description provided for @radioErrorConnectionLost.
  ///
  /// In de, this message translates to:
  /// **'Verbindung zum Sender verloren - versuche erneut…'**
  String get radioErrorConnectionLost;

  /// No description provided for @radioErrorStationUnreachable.
  ///
  /// In de, this message translates to:
  /// **'Sender nicht erreichbar - versuche erneut…'**
  String get radioErrorStationUnreachable;

  /// No description provided for @radioErrorPlayback.
  ///
  /// In de, this message translates to:
  /// **'Wiedergabefehler: {message}'**
  String radioErrorPlayback(String message);

  /// No description provided for @radioSourceFm.
  ///
  /// In de, this message translates to:
  /// **'UKW'**
  String get radioSourceFm;

  /// No description provided for @radioSourceInternet.
  ///
  /// In de, this message translates to:
  /// **'Internetradio'**
  String get radioSourceInternet;

  /// No description provided for @radioMoonNew.
  ///
  /// In de, this message translates to:
  /// **'Neumond'**
  String get radioMoonNew;

  /// No description provided for @radioMoonWaxingCrescent.
  ///
  /// In de, this message translates to:
  /// **'Zunehmende Sichel'**
  String get radioMoonWaxingCrescent;

  /// No description provided for @radioMoonFirstQuarter.
  ///
  /// In de, this message translates to:
  /// **'Zunehmender Halbmond'**
  String get radioMoonFirstQuarter;

  /// No description provided for @radioMoonWaxingGibbous.
  ///
  /// In de, this message translates to:
  /// **'Zunehmender Dreiviertelmond'**
  String get radioMoonWaxingGibbous;

  /// No description provided for @radioMoonFull.
  ///
  /// In de, this message translates to:
  /// **'Vollmond'**
  String get radioMoonFull;

  /// No description provided for @radioMoonWaningGibbous.
  ///
  /// In de, this message translates to:
  /// **'Abnehmender Dreiviertelmond'**
  String get radioMoonWaningGibbous;

  /// No description provided for @radioMoonLastQuarter.
  ///
  /// In de, this message translates to:
  /// **'Abnehmender Halbmond'**
  String get radioMoonLastQuarter;

  /// No description provided for @radioMoonWaningCrescent.
  ///
  /// In de, this message translates to:
  /// **'Abnehmende Sichel'**
  String get radioMoonWaningCrescent;

  /// No description provided for @radioFmSameProgrammeStronger.
  ///
  /// In de, this message translates to:
  /// **'(stärker)'**
  String get radioFmSameProgrammeStronger;

  /// No description provided for @radioFmSameProgrammeWeaker.
  ///
  /// In de, this message translates to:
  /// **'(schwächer)'**
  String get radioFmSameProgrammeWeaker;

  /// No description provided for @radioFmSameProgrammeAlsoOn.
  ///
  /// In de, this message translates to:
  /// **'auch auf {frequency}'**
  String radioFmSameProgrammeAlsoOn(String frequency);

  /// No description provided for @radioDabEnsembleUnknown.
  ///
  /// In de, this message translates to:
  /// **'Ensemble unbekannt'**
  String get radioDabEnsembleUnknown;

  /// No description provided for @radioPlaceSearchFailed.
  ///
  /// In de, this message translates to:
  /// **'Ortssuche: HTTP {code}'**
  String radioPlaceSearchFailed(int code);

  /// No description provided for @radioProgramNumberTitle.
  ///
  /// In de, this message translates to:
  /// **'Programmnummer vergeben'**
  String get radioProgramNumberTitle;

  /// No description provided for @radioEditStationTitle.
  ///
  /// In de, this message translates to:
  /// **'Sender bearbeiten'**
  String get radioEditStationTitle;

  /// No description provided for @radioEditStationName.
  ///
  /// In de, this message translates to:
  /// **'Name'**
  String get radioEditStationName;

  /// No description provided for @radioEditStationSearchLogo.
  ///
  /// In de, this message translates to:
  /// **'Logo suchen'**
  String get radioEditStationSearchLogo;

  /// No description provided for @radioEditStationUseLiveImage.
  ///
  /// In de, this message translates to:
  /// **'Aktuelles Senderbild übernehmen'**
  String get radioEditStationUseLiveImage;

  /// No description provided for @radioEditStationNewLogoHint.
  ///
  /// In de, this message translates to:
  /// **'Neues Logo - wird mit „Speichern“ übernommen.'**
  String get radioEditStationNewLogoHint;

  /// No description provided for @radioLogoDabIdle.
  ///
  /// In de, this message translates to:
  /// **'Holt das Bild, das der Sender selbst ausstrahlt.'**
  String get radioLogoDabIdle;

  /// No description provided for @radioLogoDabWaiting.
  ///
  /// In de, this message translates to:
  /// **'Warte auf ein Bild vom Sender (bis etwa 30 s)…'**
  String get radioLogoDabWaiting;

  /// No description provided for @radioLogoDabUseImage.
  ///
  /// In de, this message translates to:
  /// **'Dieses Bild übernehmen'**
  String get radioLogoDabUseImage;

  /// No description provided for @radioLogoDabNone.
  ///
  /// In de, this message translates to:
  /// **'Der Sender hat in der Zeit kein Bild gesendet.'**
  String get radioLogoDabNone;

  /// No description provided for @radioDabDecoderFailed.
  ///
  /// In de, this message translates to:
  /// **'DAB+-Decoder konnte nicht gestartet werden.'**
  String get radioDabDecoderFailed;

  /// No description provided for @radioLogoDabFetch.
  ///
  /// In de, this message translates to:
  /// **'DAB-Logo holen'**
  String get radioLogoDabFetch;

  /// No description provided for @radioLogoTitle.
  ///
  /// In de, this message translates to:
  /// **'Logo wählen'**
  String get radioLogoTitle;

  /// No description provided for @radioLogoSearchInternet.
  ///
  /// In de, this message translates to:
  /// **'Im Internet suchen (Sendername)'**
  String get radioLogoSearchInternet;

  /// No description provided for @radioLogoNoResults.
  ///
  /// In de, this message translates to:
  /// **'Keine Treffer mit Logo.'**
  String get radioLogoNoResults;

  /// No description provided for @radioLogoOwnUrl.
  ///
  /// In de, this message translates to:
  /// **'oder eigene Bild-Adresse (URL)'**
  String get radioLogoOwnUrl;

  /// No description provided for @radioRegionEurope.
  ///
  /// In de, this message translates to:
  /// **'Europa'**
  String get radioRegionEurope;

  /// No description provided for @radioRegionNorthAmerica.
  ///
  /// In de, this message translates to:
  /// **'Nord- & Mittelamerika'**
  String get radioRegionNorthAmerica;

  /// No description provided for @radioRegionSouthAmerica.
  ///
  /// In de, this message translates to:
  /// **'Südamerika'**
  String get radioRegionSouthAmerica;

  /// No description provided for @radioRegionAsia.
  ///
  /// In de, this message translates to:
  /// **'Asien & Nahost'**
  String get radioRegionAsia;

  /// No description provided for @radioRegionAfrica.
  ///
  /// In de, this message translates to:
  /// **'Afrika'**
  String get radioRegionAfrica;

  /// No description provided for @radioRegionOceania.
  ///
  /// In de, this message translates to:
  /// **'Ozeanien'**
  String get radioRegionOceania;

  /// No description provided for @radioRegionOther.
  ///
  /// In de, this message translates to:
  /// **'Andere'**
  String get radioRegionOther;

  /// No description provided for @radioSavedAsNumber.
  ///
  /// In de, this message translates to:
  /// **'\"{name}\" als Nr. {number} gespeichert.'**
  String radioSavedAsNumber(String name, int number);

  /// No description provided for @radioSearchInternetTitle.
  ///
  /// In de, this message translates to:
  /// **'Internetradio suchen'**
  String get radioSearchInternetTitle;

  /// No description provided for @radioSearchStationName.
  ///
  /// In de, this message translates to:
  /// **'Sendername'**
  String get radioSearchStationName;

  /// No description provided for @radioSearchGenre.
  ///
  /// In de, this message translates to:
  /// **'Genre'**
  String get radioSearchGenre;

  /// No description provided for @radioSearchAllGenres.
  ///
  /// In de, this message translates to:
  /// **'Alle Genres'**
  String get radioSearchAllGenres;

  /// No description provided for @radioSearchRegion.
  ///
  /// In de, this message translates to:
  /// **'Region'**
  String get radioSearchRegion;

  /// No description provided for @radioSearchAllRegions.
  ///
  /// In de, this message translates to:
  /// **'Alle Regionen'**
  String get radioSearchAllRegions;

  /// No description provided for @radioSearchCountry.
  ///
  /// In de, this message translates to:
  /// **'Land'**
  String get radioSearchCountry;

  /// No description provided for @radioSearchAllCountries.
  ///
  /// In de, this message translates to:
  /// **'Alle Länder'**
  String get radioSearchAllCountries;

  /// No description provided for @radioSearchButton.
  ///
  /// In de, this message translates to:
  /// **'Suchen'**
  String get radioSearchButton;

  /// No description provided for @radioSearchNoResults.
  ///
  /// In de, this message translates to:
  /// **'Keine Ergebnisse.'**
  String get radioSearchNoResults;

  /// No description provided for @radioStop.
  ///
  /// In de, this message translates to:
  /// **'Stopp'**
  String get radioStop;

  /// No description provided for @radioSearchPreview.
  ///
  /// In de, this message translates to:
  /// **'Probehören'**
  String get radioSearchPreview;

  /// No description provided for @radioSearchAddFavorite.
  ///
  /// In de, this message translates to:
  /// **'Favorit'**
  String get radioSearchAddFavorite;

  /// No description provided for @radioDabClearAllTitle.
  ///
  /// In de, this message translates to:
  /// **'Alle DAB-Sender löschen?'**
  String get radioDabClearAllTitle;

  /// No description provided for @radioDabClearAllMessage.
  ///
  /// In de, this message translates to:
  /// **'Entfernt alle bisher gefundenen DAB+-Sender aus der Liste \"Alle DAB+ Sender\" und alle DAB+-Favoriten. Kann nicht rückgängig gemacht werden.'**
  String get radioDabClearAllMessage;

  /// No description provided for @radioDabTitle.
  ///
  /// In de, this message translates to:
  /// **'DAB+ Sender'**
  String get radioDabTitle;

  /// No description provided for @radioScanTitle.
  ///
  /// In de, this message translates to:
  /// **'Sendersuchlauf'**
  String get radioScanTitle;

  /// No description provided for @radioDabClearAll.
  ///
  /// In de, this message translates to:
  /// **'Alle DAB-Sender löschen'**
  String get radioDabClearAll;

  /// No description provided for @radioFavorites.
  ///
  /// In de, this message translates to:
  /// **'Favoriten'**
  String get radioFavorites;

  /// No description provided for @radioDabNoFavorites.
  ///
  /// In de, this message translates to:
  /// **'Noch keine DAB+-Favoriten.'**
  String get radioDabNoFavorites;

  /// No description provided for @radioDabAllStations.
  ///
  /// In de, this message translates to:
  /// **'Alle DAB+ Sender'**
  String get radioDabAllStations;

  /// No description provided for @radioDabSortGrouped.
  ///
  /// In de, this message translates to:
  /// **'Nach Ensemble gruppiert'**
  String get radioDabSortGrouped;

  /// No description provided for @radioDabSortByEnsemble.
  ///
  /// In de, this message translates to:
  /// **'Nach Ensemble sortiert'**
  String get radioDabSortByEnsemble;

  /// No description provided for @radioDabSortByName.
  ///
  /// In de, this message translates to:
  /// **'Nach Name'**
  String get radioDabSortByName;

  /// No description provided for @radioDabNoStations.
  ///
  /// In de, this message translates to:
  /// **'Noch keine Sender gefunden. Sendersuchlauf starten.'**
  String get radioDabNoStations;

  /// No description provided for @radioLogoReceiveAllHaveLogo.
  ///
  /// In de, this message translates to:
  /// **'Alle Sender haben schon ein Logo.'**
  String get radioLogoReceiveAllHaveLogo;

  /// No description provided for @radioLogoReceiveProgress.
  ///
  /// In de, this message translates to:
  /// **'Sender {index} von {total} - warte auf ein Bild vom Sender…'**
  String radioLogoReceiveProgress(int index, int total);

  /// No description provided for @radioLogoReceiveDone.
  ///
  /// In de, this message translates to:
  /// **'Fertig: {found} von {total} Sendern haben ein Bild gesendet.'**
  String radioLogoReceiveDone(int found, int total);

  /// No description provided for @radioLogoReceiveTitle.
  ///
  /// In de, this message translates to:
  /// **'Fehlende Logos per Empfang'**
  String get radioLogoReceiveTitle;

  /// No description provided for @radioLogoReceiveStart.
  ///
  /// In de, this message translates to:
  /// **'Fehlende Logos per Empfang holen'**
  String get radioLogoReceiveStart;

  /// No description provided for @radioListen.
  ///
  /// In de, this message translates to:
  /// **'Anhören'**
  String get radioListen;

  /// No description provided for @radioEditNameLogo.
  ///
  /// In de, this message translates to:
  /// **'Bearbeiten (Name, Logo)'**
  String get radioEditNameLogo;

  /// No description provided for @radioRemoveFavorite.
  ///
  /// In de, this message translates to:
  /// **'Favorit entfernen'**
  String get radioRemoveFavorite;

  /// No description provided for @radioProgramNumberChip.
  ///
  /// In de, this message translates to:
  /// **'Nr. {number}'**
  String radioProgramNumberChip(int number);

  /// No description provided for @radioAddFavorite.
  ///
  /// In de, this message translates to:
  /// **'Favorit hinzufügen'**
  String get radioAddFavorite;

  /// No description provided for @radioSourceUsbHint.
  ///
  /// In de, this message translates to:
  /// **'Quelle: RTL-SDR-Stick per USB - siehe \"Radio-Empfänger\" in den Einstellungen.'**
  String get radioSourceUsbHint;

  /// No description provided for @radioSourceNetworkHint.
  ///
  /// In de, this message translates to:
  /// **'Quelle: RTL-SDR über Netzwerk - siehe \"Radio-Empfänger\" in den Einstellungen.'**
  String get radioSourceNetworkHint;

  /// No description provided for @radioScanStart.
  ///
  /// In de, this message translates to:
  /// **'Sendersuchlauf starten'**
  String get radioScanStart;

  /// No description provided for @radioDabSingleChannel.
  ///
  /// In de, this message translates to:
  /// **'Einzelnen Kanal suchen:'**
  String get radioDabSingleChannel;

  /// No description provided for @radioDabSearchChannel.
  ///
  /// In de, this message translates to:
  /// **'{channel} suchen'**
  String radioDabSearchChannel(String channel);

  /// No description provided for @radioPlaybackOfFailed.
  ///
  /// In de, this message translates to:
  /// **'Wiedergabe von \"{name}\" fehlgeschlagen.'**
  String radioPlaybackOfFailed(String name);

  /// No description provided for @radioDabSearchChannelTitle.
  ///
  /// In de, this message translates to:
  /// **'Kanal {channel} suchen'**
  String radioDabSearchChannelTitle(String channel);

  /// No description provided for @radioDabScanningChannel.
  ///
  /// In de, this message translates to:
  /// **'Suche auf {channel} ({freqKhz} kHz), bis zu 15 Sekunden…'**
  String radioDabScanningChannel(String channel, int freqKhz);

  /// No description provided for @radioDabScanProgressOf.
  ///
  /// In de, this message translates to:
  /// **'Kanal {index} von {total}: {label}'**
  String radioDabScanProgressOf(int index, int total, String label);

  /// No description provided for @radioDabScanProgress.
  ///
  /// In de, this message translates to:
  /// **'Kanal {index}: {label}'**
  String radioDabScanProgress(int index, String label);

  /// No description provided for @radioDabChannelNothingFound.
  ///
  /// In de, this message translates to:
  /// **'Auf {channel} wurde kein DAB+-Ensemble empfangen.'**
  String radioDabChannelNothingFound(String channel);

  /// No description provided for @radioDabScanDone.
  ///
  /// In de, this message translates to:
  /// **'Fertig: {ensembles} Ensemble(s) mit {stations} Sender(n) gefunden. Alle gefundenen Sender stehen unter \"Alle DAB+ Sender\".'**
  String radioDabScanDone(int ensembles, int stations);

  /// No description provided for @radioDabNoEnsemblesYet.
  ///
  /// In de, this message translates to:
  /// **'Noch keine Ensembles gefunden…'**
  String get radioDabNoEnsemblesYet;

  /// No description provided for @radioDabEnsembleNameUnknown.
  ///
  /// In de, this message translates to:
  /// **'Ensemble-Name unbekannt'**
  String get radioDabEnsembleNameUnknown;

  /// No description provided for @radioDabEnsembleNoServices.
  ///
  /// In de, this message translates to:
  /// **'Sender in diesem Ensemble noch nicht erkannt (kurz erneut versuchen).'**
  String get radioDabEnsembleNoServices;

  /// No description provided for @radioPlayingShort.
  ///
  /// In de, this message translates to:
  /// **'Läuft…'**
  String get radioPlayingShort;

  /// No description provided for @radioStopPlayback.
  ///
  /// In de, this message translates to:
  /// **'Wiedergabe stoppen'**
  String get radioStopPlayback;

  /// No description provided for @radioFmClearAllTitle.
  ///
  /// In de, this message translates to:
  /// **'Alle UKW-Sender löschen?'**
  String get radioFmClearAllTitle;

  /// No description provided for @radioFmClearAllMessage.
  ///
  /// In de, this message translates to:
  /// **'Entfernt alle gespeicherten UKW-Sender aus der Liste. UKW-Favoriten bleiben erhalten.'**
  String get radioFmClearAllMessage;

  /// No description provided for @radioFmTitle.
  ///
  /// In de, this message translates to:
  /// **'UKW-Sender (FM)'**
  String get radioFmTitle;

  /// No description provided for @radioFmFindStations.
  ///
  /// In de, this message translates to:
  /// **'Sender suchen'**
  String get radioFmFindStations;

  /// No description provided for @radioFmTuneManually.
  ///
  /// In de, this message translates to:
  /// **'Manuell einstellen'**
  String get radioFmTuneManually;

  /// No description provided for @radioFmAllStations.
  ///
  /// In de, this message translates to:
  /// **'Alle UKW-Sender'**
  String get radioFmAllStations;

  /// No description provided for @radioDeleteAll.
  ///
  /// In de, this message translates to:
  /// **'Alle löschen'**
  String get radioDeleteAll;

  /// No description provided for @radioFmNoStations.
  ///
  /// In de, this message translates to:
  /// **'Noch keine UKW-Sender. Suchlauf starten oder einen Sender manuell einstellen und speichern.'**
  String get radioFmNoStations;

  /// No description provided for @radioFmSignal.
  ///
  /// In de, this message translates to:
  /// **'Signal {level}'**
  String radioFmSignal(String level);

  /// No description provided for @radioRemoveStation.
  ///
  /// In de, this message translates to:
  /// **'Sender entfernen'**
  String get radioRemoveStation;

  /// No description provided for @radioFmScanTitle.
  ///
  /// In de, this message translates to:
  /// **'UKW-Sendersuchlauf'**
  String get radioFmScanTitle;

  /// No description provided for @radioReceiverFailed.
  ///
  /// In de, this message translates to:
  /// **'Empfänger konnte nicht gestartet werden.'**
  String get radioReceiverFailed;

  /// No description provided for @radioSearching.
  ///
  /// In de, this message translates to:
  /// **'Suche…'**
  String get radioSearching;

  /// No description provided for @radioFmScanSurvey.
  ///
  /// In de, this message translates to:
  /// **'Schritt 1/2: Band wird vermessen ({frequency})…'**
  String radioFmScanSurvey(String frequency);

  /// No description provided for @radioFmScanProbe.
  ///
  /// In de, this message translates to:
  /// **'Schritt 2/2: Prüfe Sender {index} von {total} ({frequency})…'**
  String radioFmScanProbe(int index, int total, String frequency);

  /// No description provided for @radioFmScanDone.
  ///
  /// In de, this message translates to:
  /// **'Fertig: {count} Sender gefunden und gespeichert.'**
  String radioFmScanDone(int count);

  /// No description provided for @radioFmScanImagesRemoved.
  ///
  /// In de, this message translates to:
  /// **'{count} schwache Störfrequenz(en) aussortiert.'**
  String radioFmScanImagesRemoved(int count);

  /// No description provided for @radioFmSeekNothingFound.
  ///
  /// In de, this message translates to:
  /// **'Kein weiterer Sender gefunden.'**
  String get radioFmSeekNothingFound;

  /// No description provided for @radioFmFrequencyTitle.
  ///
  /// In de, this message translates to:
  /// **'Frequenz in MHz'**
  String get radioFmFrequencyTitle;

  /// No description provided for @radioFmFrequencyHint.
  ///
  /// In de, this message translates to:
  /// **'z. B. 99,9'**
  String get radioFmFrequencyHint;

  /// No description provided for @radioSaved.
  ///
  /// In de, this message translates to:
  /// **'{name} gespeichert.'**
  String radioSaved(String name);

  /// No description provided for @radioFmTuneTitle.
  ///
  /// In de, this message translates to:
  /// **'UKW manuell einstellen'**
  String get radioFmTuneTitle;

  /// No description provided for @radioFmNoRdsName.
  ///
  /// In de, this message translates to:
  /// **'kein RDS-Name'**
  String get radioFmNoRdsName;

  /// No description provided for @radioFmSeek.
  ///
  /// In de, this message translates to:
  /// **'Suchen'**
  String get radioFmSeek;

  /// No description provided for @radioFmStepDown.
  ///
  /// In de, this message translates to:
  /// **'−0,05'**
  String get radioFmStepDown;

  /// No description provided for @radioFmStepUp.
  ///
  /// In de, this message translates to:
  /// **'+0,05'**
  String get radioFmStepUp;

  /// No description provided for @radioFmEnterFrequency.
  ///
  /// In de, this message translates to:
  /// **'Frequenz eingeben'**
  String get radioFmEnterFrequency;

  /// No description provided for @radioFmSaveStation.
  ///
  /// In de, this message translates to:
  /// **'Als Sender speichern'**
  String get radioFmSaveStation;

  /// No description provided for @radioFmSaveFavorite.
  ///
  /// In de, this message translates to:
  /// **'Als Favorit speichern'**
  String get radioFmSaveFavorite;

  /// No description provided for @radioNoStationSelected.
  ///
  /// In de, this message translates to:
  /// **'Kein Sender ausgewählt'**
  String get radioNoStationSelected;

  /// No description provided for @radioStoppedDisconnected.
  ///
  /// In de, this message translates to:
  /// **'Gestoppt - Verbindung getrennt'**
  String get radioStoppedDisconnected;

  /// No description provided for @radioNowPlaying.
  ///
  /// In de, this message translates to:
  /// **'Wiedergabe läuft'**
  String get radioNowPlaying;

  /// No description provided for @radioPaused.
  ///
  /// In de, this message translates to:
  /// **'Pausiert'**
  String get radioPaused;

  /// No description provided for @radioPlay.
  ///
  /// In de, this message translates to:
  /// **'Abspielen'**
  String get radioPlay;

  /// No description provided for @radioWeatherUnavailable.
  ///
  /// In de, this message translates to:
  /// **'Wetter nicht verfügbar - versuche erneut…'**
  String get radioWeatherUnavailable;

  /// No description provided for @radioWeatherNoData.
  ///
  /// In de, this message translates to:
  /// **'Keine Daten'**
  String get radioWeatherNoData;

  /// No description provided for @radioWeatherTemp.
  ///
  /// In de, this message translates to:
  /// **'Temp'**
  String get radioWeatherTemp;

  /// No description provided for @radioWeatherWind.
  ///
  /// In de, this message translates to:
  /// **'Wind km/h'**
  String get radioWeatherWind;

  /// No description provided for @radioWeatherRain.
  ///
  /// In de, this message translates to:
  /// **'Regen l/m²'**
  String get radioWeatherRain;

  /// No description provided for @radioWeatherRainAmount.
  ///
  /// In de, this message translates to:
  /// **'{amount} l'**
  String radioWeatherRainAmount(String amount);

  /// No description provided for @radioSunrise.
  ///
  /// In de, this message translates to:
  /// **'Sonnenaufgang'**
  String get radioSunrise;

  /// No description provided for @radioSunset.
  ///
  /// In de, this message translates to:
  /// **'Sonnenuntergang'**
  String get radioSunset;

  /// No description provided for @radioDawn.
  ///
  /// In de, this message translates to:
  /// **'Morgendämmerung'**
  String get radioDawn;

  /// No description provided for @radioSolarNoon.
  ///
  /// In de, this message translates to:
  /// **'Mittag'**
  String get radioSolarNoon;

  /// No description provided for @radioDusk.
  ///
  /// In de, this message translates to:
  /// **'Abenddämmerung'**
  String get radioDusk;

  /// No description provided for @radioRadarLoginRejected.
  ///
  /// In de, this message translates to:
  /// **'Anmeldung abgelehnt (HTTP {code})'**
  String radioRadarLoginRejected(int code);

  /// No description provided for @radioRadarIsWebPage.
  ///
  /// In de, this message translates to:
  /// **'die Adresse ist eine Webseite, kein Bild - als Art „Webseite“ wählen'**
  String get radioRadarIsWebPage;

  /// No description provided for @radioRadarNotConfigured.
  ///
  /// In de, this message translates to:
  /// **'Kein Wetterradar eingerichtet -\nEinstellungen → Wetterradar → Quelle'**
  String get radioRadarNotConfigured;

  /// No description provided for @radioRadarWebPageAndroidOnly.
  ///
  /// In de, this message translates to:
  /// **'Webseiten als Radarquelle gibt es nur in der Android-Version.'**
  String get radioRadarWebPageAndroidOnly;

  /// No description provided for @radioRadarUnreachable.
  ///
  /// In de, this message translates to:
  /// **'Radar nicht erreichbar: {error}'**
  String radioRadarUnreachable(String error);

  /// No description provided for @radioRadarStale.
  ///
  /// In de, this message translates to:
  /// **'Stand {time} · nicht erreichbar'**
  String radioRadarStale(String time);

  /// No description provided for @radioLinkSourceLost.
  ///
  /// In de, this message translates to:
  /// **'Verbindung zur RTL-SDR-Quelle verloren'**
  String get radioLinkSourceLost;

  /// No description provided for @radioLinkDabSignalFound.
  ///
  /// In de, this message translates to:
  /// **'DAB-Signal gefunden'**
  String get radioLinkDabSignalFound;

  /// No description provided for @radioLinkEnsembleFound.
  ///
  /// In de, this message translates to:
  /// **'Ensemble „{label}“ gefunden'**
  String radioLinkEnsembleFound(String label);

  /// No description provided for @radioLinkStationFound.
  ///
  /// In de, this message translates to:
  /// **'Sender gefunden - Audio startet…'**
  String get radioLinkStationFound;

  /// No description provided for @radioLinkConnected.
  ///
  /// In de, this message translates to:
  /// **'Sender verbunden'**
  String get radioLinkConnected;

  /// No description provided for @radioLinkConnectingServer.
  ///
  /// In de, this message translates to:
  /// **'Verbinde mit dem RTL-Server…'**
  String get radioLinkConnectingServer;

  /// No description provided for @radioLinkWaitingForStick.
  ///
  /// In de, this message translates to:
  /// **'Warte auf den Stick am Server…'**
  String get radioLinkWaitingForStick;

  /// No description provided for @radioLinkOpeningUsbStick.
  ///
  /// In de, this message translates to:
  /// **'USB-Stick wird geöffnet…'**
  String get radioLinkOpeningUsbStick;

  /// No description provided for @radioLinkTuning.
  ///
  /// In de, this message translates to:
  /// **'Sender wird eingestellt…'**
  String get radioLinkTuning;

  /// No description provided for @radioLinkTuningFrequency.
  ///
  /// In de, this message translates to:
  /// **'{frequency} wird eingestellt…'**
  String radioLinkTuningFrequency(String frequency);

  /// No description provided for @radioLinkSearching.
  ///
  /// In de, this message translates to:
  /// **'Sender wird gesucht…'**
  String get radioLinkSearching;

  /// No description provided for @radioLinkSearchingChannel.
  ///
  /// In de, this message translates to:
  /// **'Kanal {channel} wird gesucht…'**
  String radioLinkSearchingChannel(String channel);

  /// No description provided for @radioLinkApp.
  ///
  /// In de, this message translates to:
  /// **'App'**
  String get radioLinkApp;

  /// No description provided for @radioLinkRtlServer.
  ///
  /// In de, this message translates to:
  /// **'RTL-Server'**
  String get radioLinkRtlServer;

  /// No description provided for @radioLinkStick.
  ///
  /// In de, this message translates to:
  /// **'Stick'**
  String get radioLinkStick;

  /// No description provided for @radioLinkUsbStick.
  ///
  /// In de, this message translates to:
  /// **'USB-Stick'**
  String get radioLinkUsbStick;

  /// No description provided for @radioLinkStation.
  ///
  /// In de, this message translates to:
  /// **'Sender'**
  String get radioLinkStation;

  /// No description provided for @radioLinkTvChannel.
  ///
  /// In de, this message translates to:
  /// **'Sender'**
  String get radioLinkTvChannel;

  /// No description provided for @radioDone.
  ///
  /// In de, this message translates to:
  /// **'Fertig'**
  String get radioDone;

  /// No description provided for @radioEditFavorites.
  ///
  /// In de, this message translates to:
  /// **'Favoriten bearbeiten'**
  String get radioEditFavorites;

  /// No description provided for @radioEditFavoritesHint.
  ///
  /// In de, this message translates to:
  /// **'Reihenfolge ändern, umbenennen oder entfernen - mit ✓ fertig.'**
  String get radioEditFavoritesHint;

  /// No description provided for @radioFavoritesLoadError.
  ///
  /// In de, this message translates to:
  /// **'Fehler beim Laden der Favoriten:\n{error}'**
  String radioFavoritesLoadError(String error);

  /// No description provided for @radioNoFavorites.
  ///
  /// In de, this message translates to:
  /// **'Noch keine Favoriten.\nSuche Sender über das Menü.'**
  String get radioNoFavorites;

  /// No description provided for @radioRemoveFavoriteTitle.
  ///
  /// In de, this message translates to:
  /// **'Favorit entfernen?'**
  String get radioRemoveFavoriteTitle;

  /// No description provided for @radioRemoveFavoriteMessage.
  ///
  /// In de, this message translates to:
  /// **'„{name}“ aus den Favoriten entfernen?'**
  String radioRemoveFavoriteMessage(String name);

  /// No description provided for @radioRemove.
  ///
  /// In de, this message translates to:
  /// **'Entfernen'**
  String get radioRemove;

  /// No description provided for @radioSidebarNoFmStations.
  ///
  /// In de, this message translates to:
  /// **'Noch keine UKW-Sender.\nSuchlauf oder manuelles Einstellen über das UKW-Menü oben.'**
  String get radioSidebarNoFmStations;

  /// No description provided for @radioDabStationsLoadError.
  ///
  /// In de, this message translates to:
  /// **'Fehler beim Laden der DAB+ Sender:\n{error}'**
  String radioDabStationsLoadError(String error);

  /// No description provided for @radioSidebarNoDabStations.
  ///
  /// In de, this message translates to:
  /// **'Noch keine DAB+ Sender gefunden.\nSendersuchlauf über das DAB-Menü starten.'**
  String get radioSidebarNoDabStations;

  /// No description provided for @radioMoveUp.
  ///
  /// In de, this message translates to:
  /// **'Nach oben'**
  String get radioMoveUp;

  /// No description provided for @radioMoveDown.
  ///
  /// In de, this message translates to:
  /// **'Nach unten'**
  String get radioMoveDown;

  /// No description provided for @radioLinkBuffering.
  ///
  /// In de, this message translates to:
  /// **'Stream wird gepuffert…'**
  String get radioLinkBuffering;

  /// No description provided for @radioLinkConnectingStation.
  ///
  /// In de, this message translates to:
  /// **'Verbinde mit dem Sender…'**
  String get radioLinkConnectingStation;

  /// No description provided for @radioPausedOtherApp.
  ///
  /// In de, this message translates to:
  /// **'Pausiert - eine andere App spielt Audio ab.'**
  String get radioPausedOtherApp;

  /// No description provided for @radioSourceLostReconnecting.
  ///
  /// In de, this message translates to:
  /// **'Verbindung zur RTL-SDR-Quelle verloren - versuche erneut zu verbinden…'**
  String get radioSourceLostReconnecting;

  /// No description provided for @radioUsbStickDetached.
  ///
  /// In de, this message translates to:
  /// **'USB-Stick getrennt - warte auf Wiederanschluss…'**
  String get radioUsbStickDetached;

  /// No description provided for @radioNoReceiverConfigured.
  ///
  /// In de, this message translates to:
  /// **'Kein Radio-Empfänger eingerichtet (Einstellungen)'**
  String get radioNoReceiverConfigured;

  /// No description provided for @radioFmReceptionFailedDot.
  ///
  /// In de, this message translates to:
  /// **'UKW-Empfang fehlgeschlagen.'**
  String get radioFmReceptionFailedDot;

  /// No description provided for @radioFmReceptionFailed.
  ///
  /// In de, this message translates to:
  /// **'UKW-Empfang fehlgeschlagen'**
  String get radioFmReceptionFailed;

  /// No description provided for @radioSourceUnreachableRetrying.
  ///
  /// In de, this message translates to:
  /// **'RTL-SDR-Quelle nicht erreichbar - versuche erneut…'**
  String get radioSourceUnreachableRetrying;

  /// No description provided for @radioSourceUnreachable.
  ///
  /// In de, this message translates to:
  /// **'RTL-SDR-Quelle nicht erreichbar.'**
  String get radioSourceUnreachable;

  /// No description provided for @radioRtlServerUnreachableRetrying.
  ///
  /// In de, this message translates to:
  /// **'RTL-Server nicht erreichbar - versuche erneut…'**
  String get radioRtlServerUnreachableRetrying;

  /// No description provided for @radioRtlServerUnreachable.
  ///
  /// In de, this message translates to:
  /// **'RTL-Server nicht erreichbar'**
  String get radioRtlServerUnreachable;

  /// No description provided for @radioUsbStickNotFound.
  ///
  /// In de, this message translates to:
  /// **'USB-Stick nicht gefunden oder kein Zugriff'**
  String get radioUsbStickNotFound;

  /// No description provided for @radioNoSignalRetrying.
  ///
  /// In de, this message translates to:
  /// **'Kein Signal! - Versuche erneut…'**
  String get radioNoSignalRetrying;

  /// No description provided for @radioNoSignal.
  ///
  /// In de, this message translates to:
  /// **'Kein Signal!'**
  String get radioNoSignal;

  /// No description provided for @radioLinkNoSignalRetrying.
  ///
  /// In de, this message translates to:
  /// **'Kein Signal - versuche erneut…'**
  String get radioLinkNoSignalRetrying;

  /// No description provided for @radioMenuListening.
  ///
  /// In de, this message translates to:
  /// **'Funk'**
  String get radioMenuListening;

  /// No description provided for @radioMenuDabStations.
  ///
  /// In de, this message translates to:
  /// **'DAB Sender suchen'**
  String get radioMenuDabStations;

  /// No description provided for @radioMenuAmBands.
  ///
  /// In de, this message translates to:
  /// **'LW/MW/KW'**
  String get radioMenuAmBands;

  /// No description provided for @radioMenuSettings.
  ///
  /// In de, this message translates to:
  /// **'Radio-Einstellungen'**
  String get radioMenuSettings;

  /// No description provided for @scannerQuoted.
  ///
  /// In de, this message translates to:
  /// **'„{name}“'**
  String scannerQuoted(String name);

  /// No description provided for @scannerRtlUnreachable.
  ///
  /// In de, this message translates to:
  /// **'rtl_tcp-Server {server} nicht erreichbar ({error})'**
  String scannerRtlUnreachable(String server, String error);

  /// No description provided for @scannerRtlConnectionLost.
  ///
  /// In de, this message translates to:
  /// **'Verbindung zum rtl_tcp-Server unterbrochen ({error})'**
  String scannerRtlConnectionLost(String error);

  /// No description provided for @scannerRtlRefused.
  ///
  /// In de, this message translates to:
  /// **'rtl_tcp-Server hat die Verbindung abgelehnt (belegt oder kein Stick bereit)'**
  String get scannerRtlRefused;

  /// No description provided for @scannerRtlConnectionClosed.
  ///
  /// In de, this message translates to:
  /// **'Verbindung zum rtl_tcp-Server beendet'**
  String get scannerRtlConnectionClosed;

  /// No description provided for @scannerRtlNoAnswer.
  ///
  /// In de, this message translates to:
  /// **'rtl_tcp-Server antwortet nicht'**
  String get scannerRtlNoAnswer;

  /// No description provided for @scannerRtlNotAServer.
  ///
  /// In de, this message translates to:
  /// **'Kein rtl_tcp-Server (unbekannte Begrüßung)'**
  String get scannerRtlNotAServer;

  /// No description provided for @scannerRtlBadStream.
  ///
  /// In de, this message translates to:
  /// **'rtl_tcp-Server: Datenstrom fehlerhaft'**
  String get scannerRtlBadStream;

  /// No description provided for @scannerRtlStickAtServer.
  ///
  /// In de, this message translates to:
  /// **'USB-Stick am rtl_tcp-Server'**
  String get scannerRtlStickAtServer;

  /// No description provided for @scannerRtlAuthUnsupported.
  ///
  /// In de, this message translates to:
  /// **'rtl_tcp-Server verlangt eine Anmeldung, das wird nicht mehr unterstützt. Bitte den rtltcp.server im lokalen Netz verwenden.'**
  String get scannerRtlAuthUnsupported;

  /// No description provided for @scannerRtlStickReady.
  ///
  /// In de, this message translates to:
  /// **'{stick} bereit'**
  String scannerRtlStickReady(String stick);

  /// No description provided for @scannerRtlStickStarting.
  ///
  /// In de, this message translates to:
  /// **'{stick} startet …'**
  String scannerRtlStickStarting(String stick);

  /// No description provided for @scannerRtlStickNotReady.
  ///
  /// In de, this message translates to:
  /// **'{stick} nicht bereit'**
  String scannerRtlStickNotReady(String stick);

  /// No description provided for @scannerRtlStickLost.
  ///
  /// In de, this message translates to:
  /// **'{stick} getrennt – der Server verbindet neu …'**
  String scannerRtlStickLost(String stick);

  /// No description provided for @scannerRtlServer.
  ///
  /// In de, this message translates to:
  /// **'rtl_tcp-Server'**
  String get scannerRtlServer;

  /// No description provided for @scannerRtlBusy.
  ///
  /// In de, this message translates to:
  /// **'{who} wird bereits von einem anderen Gerät verwendet'**
  String scannerRtlBusy(String who);

  /// No description provided for @scannerRtlBusyBy.
  ///
  /// In de, this message translates to:
  /// **'{who} wird bereits von {client} verwendet'**
  String scannerRtlBusyBy(String who, String client);

  /// No description provided for @scannerRtlKicked.
  ///
  /// In de, this message translates to:
  /// **'Vom rtl_tcp-Server getrennt'**
  String get scannerRtlKicked;

  /// No description provided for @scannerRtlProtocolError.
  ///
  /// In de, this message translates to:
  /// **'rtl_tcp-Server meldet einen Protokollfehler'**
  String get scannerRtlProtocolError;

  /// No description provided for @scannerRtlServerSays.
  ///
  /// In de, this message translates to:
  /// **'rtl_tcp-Server: {message}'**
  String scannerRtlServerSays(String message);

  /// No description provided for @scannerRtlStateStarting.
  ///
  /// In de, this message translates to:
  /// **'startet'**
  String get scannerRtlStateStarting;

  /// No description provided for @scannerRtlStateNotReady.
  ///
  /// In de, this message translates to:
  /// **'nicht bereit'**
  String get scannerRtlStateNotReady;

  /// No description provided for @scannerRtlStateLost.
  ///
  /// In de, this message translates to:
  /// **'getrennt'**
  String get scannerRtlStateLost;

  /// No description provided for @scannerRtlStateIdle.
  ///
  /// In de, this message translates to:
  /// **'ruht'**
  String get scannerRtlStateIdle;

  /// No description provided for @scannerRtlSticksOn.
  ///
  /// In de, this message translates to:
  /// **'Sticks auf {host}'**
  String scannerRtlSticksOn(String host);

  /// No description provided for @scannerRtlLocation.
  ///
  /// In de, this message translates to:
  /// **'Standort: {location}'**
  String scannerRtlLocation(String location);

  /// No description provided for @scannerRtlAntenna.
  ///
  /// In de, this message translates to:
  /// **'Antenne: {antenna}'**
  String scannerRtlAntenna(String antenna);

  /// No description provided for @scannerRtlNotSpecified.
  ///
  /// In de, this message translates to:
  /// **'nicht angegeben'**
  String get scannerRtlNotSpecified;

  /// No description provided for @scannerRtlVia.
  ///
  /// In de, this message translates to:
  /// **'über {instance}'**
  String scannerRtlVia(String instance);

  /// No description provided for @scannerRtlBusyByShort.
  ///
  /// In de, this message translates to:
  /// **'belegt von {client}'**
  String scannerRtlBusyByShort(String client);

  /// No description provided for @scannerRtlReceiverTitle.
  ///
  /// In de, this message translates to:
  /// **'Radio-Empfänger (DAB+ & UKW)'**
  String get scannerRtlReceiverTitle;

  /// No description provided for @scannerRtlReceiverLabel.
  ///
  /// In de, this message translates to:
  /// **'Empfänger:'**
  String get scannerRtlReceiverLabel;

  /// No description provided for @scannerRtlModeNone.
  ///
  /// In de, this message translates to:
  /// **'Kein Empfänger (nur Internetradio)'**
  String get scannerRtlModeNone;

  /// No description provided for @scannerRtlModeUsb.
  ///
  /// In de, this message translates to:
  /// **'RTL-SDR-Stick per USB'**
  String get scannerRtlModeUsb;

  /// No description provided for @scannerRtlModeTcp.
  ///
  /// In de, this message translates to:
  /// **'RTL-SDR über Netzwerk (rtl_tcp)'**
  String get scannerRtlModeTcp;

  /// No description provided for @scannerRtlNoneHint.
  ///
  /// In de, this message translates to:
  /// **'DAB+- und UKW-Suche sowie die Reiter „DAB+“ und „FM“ sind ausgeblendet. Vorhandene Favoriten bleiben erhalten und spielen wieder, sobald ein Empfänger eingerichtet ist.'**
  String get scannerRtlNoneHint;

  /// No description provided for @scannerRtlUsbHint.
  ///
  /// In de, this message translates to:
  /// **'Der Empfänger öffnet den Stick direkt über USB, sobald ein Sender startet.'**
  String get scannerRtlUsbHint;

  /// No description provided for @scannerRtlUsbWindows.
  ///
  /// In de, this message translates to:
  /// **'Windows: einmalig den WinUSB-Treiber mit Zadig (zadig.akeo.ie) für „Bulk-In, Interface (Interface 0)“ installieren.'**
  String get scannerRtlUsbWindows;

  /// No description provided for @scannerRtlUsbLinux.
  ///
  /// In de, this message translates to:
  /// **'Linux: braucht eine udev-Regel für den Stick (z. B. aus dem Paket rtl-sdr); der DVB-T-Treiber des Kernels wird automatisch abgekoppelt.'**
  String get scannerRtlUsbLinux;

  /// No description provided for @scannerRtlNoStick.
  ///
  /// In de, this message translates to:
  /// **'Kein RTL-SDR-Stick erkannt.'**
  String get scannerRtlNoStick;

  /// No description provided for @scannerRtlAllowAccess.
  ///
  /// In de, this message translates to:
  /// **'Zugriff erlauben'**
  String get scannerRtlAllowAccess;

  /// No description provided for @scannerRtlAccessGranted.
  ///
  /// In de, this message translates to:
  /// **'Zugriff erteilt'**
  String get scannerRtlAccessGranted;

  /// No description provided for @scannerRtlRescan.
  ///
  /// In de, this message translates to:
  /// **'Neu suchen'**
  String get scannerRtlRescan;

  /// No description provided for @scannerRtlTcpHint.
  ///
  /// In de, this message translates to:
  /// **'rtl_tcp-Server im lokalen Netz: Treiber-App auf diesem Gerät (127.0.0.1), Raspberry Pi oder rtltcp.server. Der markierte Server ist der Standard für DAB+ und UKW. Sticks an anderen Standorten stellt der rtltcp.server über rtl.over.internet lokal bereit.'**
  String get scannerRtlTcpHint;

  /// No description provided for @scannerRtlAddServer.
  ///
  /// In de, this message translates to:
  /// **'Server hinzufügen'**
  String get scannerRtlAddServer;

  /// No description provided for @scannerRtlTestHint.
  ///
  /// In de, this message translates to:
  /// **'„Testen“ unterbricht DAB+ oder UKW, wenn es über diesen Server läuft; der Sender spielt beim Zurückkehren weiter.'**
  String get scannerRtlTestHint;

  /// No description provided for @scannerRtlDefault.
  ///
  /// In de, this message translates to:
  /// **'Standard'**
  String get scannerRtlDefault;

  /// No description provided for @scannerRtlTest.
  ///
  /// In de, this message translates to:
  /// **'Testen'**
  String get scannerRtlTest;

  /// No description provided for @scannerRtlChooseStick.
  ///
  /// In de, this message translates to:
  /// **'Stick wählen ({count})'**
  String scannerRtlChooseStick(int count);

  /// No description provided for @scannerRtlRemove.
  ///
  /// In de, this message translates to:
  /// **'Entfernen'**
  String get scannerRtlRemove;

  /// No description provided for @scannerRtlNoConnection.
  ///
  /// In de, this message translates to:
  /// **'Keine Verbindung'**
  String get scannerRtlNoConnection;

  /// No description provided for @scannerRtlClassicServer.
  ///
  /// In de, this message translates to:
  /// **'rtl_tcp – Server unterstützt Standort und Antenne nicht'**
  String get scannerRtlClassicServer;

  /// No description provided for @scannerRtlProtocol.
  ///
  /// In de, this message translates to:
  /// **'Protokoll: {name}'**
  String scannerRtlProtocol(String name);

  /// No description provided for @scannerRtlTunerInfo.
  ///
  /// In de, this message translates to:
  /// **'Tuner-Typ: {type}, {gains} Gain-Stufen'**
  String scannerRtlTunerInfo(String type, String gains);

  /// No description provided for @scannerAprsCompass.
  ///
  /// In de, this message translates to:
  /// **'N NO O SO S SW W NW'**
  String get scannerAprsCompass;

  /// No description provided for @scannerAprsKindPosition.
  ///
  /// In de, this message translates to:
  /// **'Position'**
  String get scannerAprsKindPosition;

  /// No description provided for @scannerAprsKindWeather.
  ///
  /// In de, this message translates to:
  /// **'Wetter'**
  String get scannerAprsKindWeather;

  /// No description provided for @scannerAprsKindObject.
  ///
  /// In de, this message translates to:
  /// **'Objekt'**
  String get scannerAprsKindObject;

  /// No description provided for @scannerAprsKindObjectDeleted.
  ///
  /// In de, this message translates to:
  /// **'Objekt (gelöscht)'**
  String get scannerAprsKindObjectDeleted;

  /// No description provided for @scannerAprsKindMessage.
  ///
  /// In de, this message translates to:
  /// **'Nachricht'**
  String get scannerAprsKindMessage;

  /// No description provided for @scannerAprsKindAck.
  ///
  /// In de, this message translates to:
  /// **'Bestätigung'**
  String get scannerAprsKindAck;

  /// No description provided for @scannerAprsKindTelemetry.
  ///
  /// In de, this message translates to:
  /// **'Telemetrie'**
  String get scannerAprsKindTelemetry;

  /// No description provided for @scannerAprsKindCapabilities.
  ///
  /// In de, this message translates to:
  /// **'Fähigkeiten'**
  String get scannerAprsKindCapabilities;

  /// No description provided for @scannerAprsKindThirdParty.
  ///
  /// In de, this message translates to:
  /// **'Weitergeleitet'**
  String get scannerAprsKindThirdParty;

  /// No description provided for @scannerAprsKindData.
  ///
  /// In de, this message translates to:
  /// **'Daten'**
  String get scannerAprsKindData;

  /// No description provided for @scannerAprsKindEmpty.
  ///
  /// In de, this message translates to:
  /// **'Leer'**
  String get scannerAprsKindEmpty;

  /// No description provided for @scannerWind.
  ///
  /// In de, this message translates to:
  /// **'Wind {speed} km/h'**
  String scannerWind(String speed);

  /// No description provided for @scannerWindFrom.
  ///
  /// In de, this message translates to:
  /// **'aus {degrees}°'**
  String scannerWindFrom(int degrees);

  /// No description provided for @scannerGusts.
  ///
  /// In de, this message translates to:
  /// **'Böen {speed}'**
  String scannerGusts(String speed);

  /// No description provided for @scannerAprsRain.
  ///
  /// In de, this message translates to:
  /// **'Regen {rate} mm/h'**
  String scannerAprsRain(String rate);

  /// No description provided for @scannerAprsSymbolWeatherStation.
  ///
  /// In de, this message translates to:
  /// **'Wetterstation'**
  String get scannerAprsSymbolWeatherStation;

  /// No description provided for @scannerAprsSymbolHouse.
  ///
  /// In de, this message translates to:
  /// **'Haus'**
  String get scannerAprsSymbolHouse;

  /// No description provided for @scannerAprsSymbolCar.
  ///
  /// In de, this message translates to:
  /// **'Auto'**
  String get scannerAprsSymbolCar;

  /// No description provided for @scannerAprsSymbolAmbulance.
  ///
  /// In de, this message translates to:
  /// **'Rettung'**
  String get scannerAprsSymbolAmbulance;

  /// No description provided for @scannerAprsSymbolNode.
  ///
  /// In de, this message translates to:
  /// **'Knoten'**
  String get scannerAprsSymbolNode;

  /// No description provided for @scannerAprsSymbolTruck.
  ///
  /// In de, this message translates to:
  /// **'LKW'**
  String get scannerAprsSymbolTruck;

  /// No description provided for @scannerAprsSymbolAircraft.
  ///
  /// In de, this message translates to:
  /// **'Flugzeug'**
  String get scannerAprsSymbolAircraft;

  /// No description provided for @scannerAprsSymbolBalloon.
  ///
  /// In de, this message translates to:
  /// **'Ballon'**
  String get scannerAprsSymbolBalloon;

  /// No description provided for @scannerAprsSymbolRepeater.
  ///
  /// In de, this message translates to:
  /// **'Relais'**
  String get scannerAprsSymbolRepeater;

  /// No description provided for @scannerAprsSymbolRv.
  ///
  /// In de, this message translates to:
  /// **'Wohnmobil'**
  String get scannerAprsSymbolRv;

  /// No description provided for @scannerAprsSymbolMotorcycle.
  ///
  /// In de, this message translates to:
  /// **'Motorrad'**
  String get scannerAprsSymbolMotorcycle;

  /// No description provided for @scannerAprsSymbolBicycle.
  ///
  /// In de, this message translates to:
  /// **'Fahrrad'**
  String get scannerAprsSymbolBicycle;

  /// No description provided for @scannerAprsSymbolPedestrian.
  ///
  /// In de, this message translates to:
  /// **'Fußgänger'**
  String get scannerAprsSymbolPedestrian;

  /// No description provided for @scannerAprsSymbolAntennaStation.
  ///
  /// In de, this message translates to:
  /// **'Station mit Antenne'**
  String get scannerAprsSymbolAntennaStation;

  /// No description provided for @scannerAprsSymbolShip.
  ///
  /// In de, this message translates to:
  /// **'Schiff'**
  String get scannerAprsSymbolShip;

  /// No description provided for @scannerAprsSymbolSmallAircraft.
  ///
  /// In de, this message translates to:
  /// **'Kleinflugzeug'**
  String get scannerAprsSymbolSmallAircraft;

  /// No description provided for @scannerAprsSymbolHelicopter.
  ///
  /// In de, this message translates to:
  /// **'Hubschrauber'**
  String get scannerAprsSymbolHelicopter;

  /// No description provided for @scannerAprsSymbolFireTruck.
  ///
  /// In de, this message translates to:
  /// **'Feuerwehr'**
  String get scannerAprsSymbolFireTruck;

  /// No description provided for @scannerAprsSymbolPolice.
  ///
  /// In de, this message translates to:
  /// **'Polizei'**
  String get scannerAprsSymbolPolice;

  /// No description provided for @scannerAprsSymbolSatellite.
  ///
  /// In de, this message translates to:
  /// **'Satellit'**
  String get scannerAprsSymbolSatellite;

  /// No description provided for @scannerAprsSymbolTrain.
  ///
  /// In de, this message translates to:
  /// **'Zug'**
  String get scannerAprsSymbolTrain;

  /// No description provided for @scannerChannel.
  ///
  /// In de, this message translates to:
  /// **'Kanal {channel}'**
  String scannerChannel(String channel);

  /// No description provided for @scannerBandCb.
  ///
  /// In de, this message translates to:
  /// **'CB-Funk'**
  String get scannerBandCb;

  /// No description provided for @scannerMarkEmergency.
  ///
  /// In de, this message translates to:
  /// **'Notruf'**
  String get scannerMarkEmergency;

  /// No description provided for @scannerCbTruckers.
  ///
  /// In de, this message translates to:
  /// **'Fernfahrer'**
  String get scannerCbTruckers;

  /// No description provided for @scannerSegCbFm.
  ///
  /// In de, this message translates to:
  /// **'Sprechfunk FM (Kanal 9 Notruf, 19 Fernfahrer)'**
  String get scannerSegCbFm;

  /// No description provided for @scannerSegCbSsb.
  ///
  /// In de, this message translates to:
  /// **'SSB-Bereich (Kanal 36–40)'**
  String get scannerSegCbSsb;

  /// No description provided for @scannerBandAir.
  ///
  /// In de, this message translates to:
  /// **'Flugfunk'**
  String get scannerBandAir;

  /// No description provided for @scannerBandMil.
  ///
  /// In de, this message translates to:
  /// **'Militärfunk'**
  String get scannerBandMil;

  /// No description provided for @scannerSegMilAir.
  ///
  /// In de, this message translates to:
  /// **'Militärischer Flugfunk'**
  String get scannerSegMilAir;

  /// No description provided for @scannerBandHam.
  ///
  /// In de, this message translates to:
  /// **'Amateurfunk {band}'**
  String scannerBandHam(String band);

  /// No description provided for @scannerSegCw.
  ///
  /// In de, this message translates to:
  /// **'Telegrafie'**
  String get scannerSegCw;

  /// No description provided for @scannerSegDigital.
  ///
  /// In de, this message translates to:
  /// **'Digitale Betriebsarten'**
  String get scannerSegDigital;

  /// No description provided for @scannerSegVoiceLsb.
  ///
  /// In de, this message translates to:
  /// **'Sprechfunk (LSB)'**
  String get scannerSegVoiceLsb;

  /// No description provided for @scannerSegVoiceUsb.
  ///
  /// In de, this message translates to:
  /// **'Sprechfunk (USB)'**
  String get scannerSegVoiceUsb;

  /// No description provided for @scannerSegVoiceSsb.
  ///
  /// In de, this message translates to:
  /// **'Sprechfunk (SSB)'**
  String get scannerSegVoiceSsb;

  /// No description provided for @scannerSegDigitalVoiceUsb.
  ///
  /// In de, this message translates to:
  /// **'Digital & Sprechfunk (USB)'**
  String get scannerSegDigitalVoiceUsb;

  /// No description provided for @scannerSegBeacons.
  ///
  /// In de, this message translates to:
  /// **'Baken'**
  String get scannerSegBeacons;

  /// No description provided for @scannerSegDigitalAllModes.
  ///
  /// In de, this message translates to:
  /// **'Digital & alle Betriebsarten'**
  String get scannerSegDigitalAllModes;

  /// No description provided for @scannerSegBeaconsAllModes.
  ///
  /// In de, this message translates to:
  /// **'Baken & alle Betriebsarten'**
  String get scannerSegBeaconsAllModes;

  /// No description provided for @scannerSegAmVoice.
  ///
  /// In de, this message translates to:
  /// **'AM-Sprechfunk'**
  String get scannerSegAmVoice;

  /// No description provided for @scannerSegFmSimplex.
  ///
  /// In de, this message translates to:
  /// **'FM-Direkt'**
  String get scannerSegFmSimplex;

  /// No description provided for @scannerSegPacket.
  ///
  /// In de, this message translates to:
  /// **'Digital (Packet)'**
  String get scannerSegPacket;

  /// No description provided for @scannerSegSatellites.
  ///
  /// In de, this message translates to:
  /// **'Satelliten'**
  String get scannerSegSatellites;

  /// No description provided for @scannerSegRepeaterInputs.
  ///
  /// In de, this message translates to:
  /// **'FM-Relais-Eingaben'**
  String get scannerSegRepeaterInputs;

  /// No description provided for @scannerSegRepeaterOutputs.
  ///
  /// In de, this message translates to:
  /// **'FM-Relais-Ausgaben'**
  String get scannerSegRepeaterOutputs;

  /// No description provided for @scannerSegFmSimplexCall.
  ///
  /// In de, this message translates to:
  /// **'FM-Direkt ({frequency} Anruf)'**
  String scannerSegFmSimplexCall(String frequency);

  /// No description provided for @scannerMarkCall.
  ///
  /// In de, this message translates to:
  /// **'Anruf'**
  String get scannerMarkCall;

  /// No description provided for @scannerSegCwBeacons.
  ///
  /// In de, this message translates to:
  /// **'Telegrafie & Baken'**
  String get scannerSegCwBeacons;

  /// No description provided for @scannerSegSsbVoiceCall.
  ///
  /// In de, this message translates to:
  /// **'Sprechfunk (SSB, {frequency} Anruf)'**
  String scannerSegSsbVoiceCall(String frequency);

  /// No description provided for @scannerSegAllModes.
  ///
  /// In de, this message translates to:
  /// **'Alle Betriebsarten'**
  String get scannerSegAllModes;

  /// No description provided for @scannerSegCwEme.
  ///
  /// In de, this message translates to:
  /// **'Telegrafie (EME)'**
  String get scannerSegCwEme;

  /// No description provided for @scannerSegAllModesSstv.
  ///
  /// In de, this message translates to:
  /// **'Alle Betriebsarten (SSTV, Digital)'**
  String get scannerSegAllModesSstv;

  /// No description provided for @scannerSegDigitalAprs.
  ///
  /// In de, this message translates to:
  /// **'Digital ({frequency} APRS)'**
  String scannerSegDigitalAprs(String frequency);

  /// No description provided for @scannerSegSatellitesIss.
  ///
  /// In de, this message translates to:
  /// **'Satelliten ({frequency} ISS)'**
  String scannerSegSatellitesIss(String frequency);

  /// No description provided for @scannerSegDigitalRepeaterInputs.
  ///
  /// In de, this message translates to:
  /// **'Digital & Relais-Eingaben'**
  String get scannerSegDigitalRepeaterInputs;

  /// No description provided for @scannerSegRepeaterInputsLpd.
  ///
  /// In de, this message translates to:
  /// **'FM-Relais-Eingaben, LPD-Funkgeräte'**
  String get scannerSegRepeaterInputsLpd;

  /// No description provided for @scannerSegFmSimplexCallLpd.
  ///
  /// In de, this message translates to:
  /// **'FM-Direkt ({frequency} Anruf), LPD'**
  String scannerSegFmSimplexCallLpd(String frequency);

  /// No description provided for @scannerSegLpdIsm.
  ///
  /// In de, this message translates to:
  /// **'LPD-Funkgeräte & ISM ({frequency} Sensoren)'**
  String scannerSegLpdIsm(String frequency);

  /// No description provided for @scannerMarkSensors.
  ///
  /// In de, this message translates to:
  /// **'Sensoren'**
  String get scannerMarkSensors;

  /// No description provided for @scannerSegRepeaterOutputsDigital.
  ///
  /// In de, this message translates to:
  /// **'Relais-Ausgaben (auch DMR/C4FM)'**
  String get scannerSegRepeaterOutputsDigital;

  /// No description provided for @scannerSegAtv.
  ///
  /// In de, this message translates to:
  /// **'Amateurfernsehen (ATV)'**
  String get scannerSegAtv;

  /// No description provided for @scannerSegSatellitesUplink.
  ///
  /// In de, this message translates to:
  /// **'Satelliten (Uplink)'**
  String get scannerSegSatellitesUplink;

  /// No description provided for @scannerSegAtvDigital.
  ///
  /// In de, this message translates to:
  /// **'ATV & Digital'**
  String get scannerSegAtvDigital;

  /// No description provided for @scannerBandLongWave.
  ///
  /// In de, this message translates to:
  /// **'Langwelle'**
  String get scannerBandLongWave;

  /// No description provided for @scannerBandMediumWave.
  ///
  /// In de, this message translates to:
  /// **'Mittelwelle'**
  String get scannerBandMediumWave;

  /// No description provided for @scannerBandShortwave.
  ///
  /// In de, this message translates to:
  /// **'KW-Rundfunk {band}'**
  String scannerBandShortwave(String band);

  /// No description provided for @scannerUtilTimeSignal.
  ///
  /// In de, this message translates to:
  /// **'Zeitzeichen {station}'**
  String scannerUtilTimeSignal(String station);

  /// No description provided for @scannerUtilWeatherFax.
  ///
  /// In de, this message translates to:
  /// **'Wetterfax {station}'**
  String scannerUtilWeatherFax(String station);

  /// No description provided for @scannerUtilWeatherRtty.
  ///
  /// In de, this message translates to:
  /// **'Wetter-RTTY {station}'**
  String scannerUtilWeatherRtty(String station);

  /// No description provided for @scannerBandHfUtility.
  ///
  /// In de, this message translates to:
  /// **'KW-Funkdienste'**
  String get scannerBandHfUtility;

  /// No description provided for @scannerSegFmBroadcast.
  ///
  /// In de, this message translates to:
  /// **'UKW-Rundfunk'**
  String get scannerSegFmBroadcast;

  /// No description provided for @scannerSegAirNavVorIls.
  ///
  /// In de, this message translates to:
  /// **'Flugnavigation (VOR/ILS)'**
  String get scannerSegAirNavVorIls;

  /// No description provided for @scannerSegWeatherSatellites.
  ///
  /// In de, this message translates to:
  /// **'Wettersatelliten'**
  String get scannerSegWeatherSatellites;

  /// No description provided for @scannerSegLandMobile.
  ///
  /// In de, this message translates to:
  /// **'Betriebsfunk'**
  String get scannerSegLandMobile;

  /// No description provided for @scannerSegLandMobileBos.
  ///
  /// In de, this message translates to:
  /// **'Betriebsfunk / BOS'**
  String get scannerSegLandMobileBos;

  /// No description provided for @scannerSegMarine.
  ///
  /// In de, this message translates to:
  /// **'Seefunk (Kanal 16 = {frequency})'**
  String scannerSegMarine(String frequency);

  /// No description provided for @scannerSegLandMobileRail.
  ///
  /// In de, this message translates to:
  /// **'Betriebsfunk / Bahnfunk'**
  String get scannerSegLandMobileRail;

  /// No description provided for @scannerSegDab.
  ///
  /// In de, this message translates to:
  /// **'DAB+ Band III (digital, nicht hörbar)'**
  String get scannerSegDab;

  /// No description provided for @scannerSegRadiosondes.
  ///
  /// In de, this message translates to:
  /// **'Wettersonden'**
  String get scannerSegRadiosondes;

  /// No description provided for @scannerSegDistressBeacons.
  ///
  /// In de, this message translates to:
  /// **'Notfunkbaken (digital)'**
  String get scannerSegDistressBeacons;

  /// No description provided for @scannerSegDvbt.
  ///
  /// In de, this message translates to:
  /// **'Fernsehen DVB-T2 (digital)'**
  String get scannerSegDvbt;

  /// No description provided for @scannerSegLte.
  ///
  /// In de, this message translates to:
  /// **'Mobilfunk LTE (digital)'**
  String get scannerSegLte;

  /// No description provided for @scannerSegSensorsLora.
  ///
  /// In de, this message translates to:
  /// **'Funksensoren / LoRa 868'**
  String get scannerSegSensorsLora;

  /// No description provided for @scannerSegGsm.
  ///
  /// In de, this message translates to:
  /// **'Mobilfunk / GSM-R (digital)'**
  String get scannerSegGsm;

  /// No description provided for @scannerSegAirNavDme.
  ///
  /// In de, this message translates to:
  /// **'Flugnavigation (DME)'**
  String get scannerSegAirNavDme;

  /// No description provided for @scannerSegAdsb.
  ///
  /// In de, this message translates to:
  /// **'ADS-B 1090 (→ Flugzeuge)'**
  String get scannerSegAdsb;

  /// No description provided for @scannerSegGnss.
  ///
  /// In de, this message translates to:
  /// **'Satellitennavigation (GNSS)'**
  String get scannerSegGnss;

  /// No description provided for @scannerSegSatPhone.
  ///
  /// In de, this message translates to:
  /// **'Satelliten-Telefonie (Inmarsat)'**
  String get scannerSegSatPhone;

  /// No description provided for @scannerBandWorld.
  ///
  /// In de, this message translates to:
  /// **'Freier Band-Scan'**
  String get scannerBandWorld;

  /// No description provided for @scannerJumpMarine.
  ///
  /// In de, this message translates to:
  /// **'Seefunk Kanal 16'**
  String get scannerJumpMarine;

  /// No description provided for @scannerJumpMilAir.
  ///
  /// In de, this message translates to:
  /// **'Militärflugfunk'**
  String get scannerJumpMilAir;

  /// No description provided for @scannerSensors.
  ///
  /// In de, this message translates to:
  /// **'Funksensoren'**
  String get scannerSensors;

  /// No description provided for @scannerJumpRepeaters70.
  ///
  /// In de, this message translates to:
  /// **'Relais 70 cm ({frequency})'**
  String scannerJumpRepeaters70(String frequency);

  /// No description provided for @scannerHubTitle.
  ///
  /// In de, this message translates to:
  /// **'Funk'**
  String get scannerHubTitle;

  /// No description provided for @scannerHubCbSubtitle.
  ///
  /// In de, this message translates to:
  /// **'26,965–27,405 MHz · Kanal 1–40 (80)'**
  String get scannerHubCbSubtitle;

  /// No description provided for @scannerHubPmrSubtitle.
  ///
  /// In de, this message translates to:
  /// **'446,00625–446,19375 MHz · Kanal 1–16'**
  String get scannerHubPmrSubtitle;

  /// No description provided for @scannerHubHam.
  ///
  /// In de, this message translates to:
  /// **'Amateurfunk'**
  String get scannerHubHam;

  /// No description provided for @scannerHubHamSubtitle.
  ///
  /// In de, this message translates to:
  /// **'160 m bis 23 cm mit Bandplan'**
  String get scannerHubHamSubtitle;

  /// No description provided for @scannerHubShortwave.
  ///
  /// In de, this message translates to:
  /// **'Kurzwelle'**
  String get scannerHubShortwave;

  /// No description provided for @scannerHubShortwaveSubtitle.
  ///
  /// In de, this message translates to:
  /// **'KW-Rundfunk · Amateurfunk KW · Zeitzeichen & Flugwetter'**
  String get scannerHubShortwaveSubtitle;

  /// No description provided for @scannerHubAircraft.
  ///
  /// In de, this message translates to:
  /// **'Flugzeuge'**
  String get scannerHubAircraft;

  /// No description provided for @scannerHubAircraftSubtitle.
  ///
  /// In de, this message translates to:
  /// **'Flugfunk · ACARS · Radar (ADS-B)'**
  String get scannerHubAircraftSubtitle;

  /// No description provided for @scannerHubSensorsSubtitle.
  ///
  /// In de, this message translates to:
  /// **'433/868 MHz · Thermometer, Wetterstationen, Schalter'**
  String get scannerHubSensorsSubtitle;

  /// No description provided for @scannerHubWorldSubtitle.
  ///
  /// In de, this message translates to:
  /// **'0,5–1766 MHz frei abstimmen, Bänder eingezeichnet'**
  String get scannerHubWorldSubtitle;

  /// No description provided for @scannerHubAirSubtitle.
  ///
  /// In de, this message translates to:
  /// **'118–137 MHz · Sprechfunk (AM)'**
  String get scannerHubAirSubtitle;

  /// No description provided for @scannerHubAcarsSubtitle.
  ///
  /// In de, this message translates to:
  /// **'131,5–131,9 MHz · Textmeldungen von Flugzeugen'**
  String get scannerHubAcarsSubtitle;

  /// No description provided for @scannerHubAdsbSubtitle.
  ///
  /// In de, this message translates to:
  /// **'1090 MHz · Flugnummer, Höhe, Position auf der Karte'**
  String get scannerHubAdsbSubtitle;

  /// No description provided for @scannerUpconverterNone.
  ///
  /// In de, this message translates to:
  /// **'Keiner – Direct Sampling oder RTL-SDR Blog V4'**
  String get scannerUpconverterNone;

  /// No description provided for @scannerUpconverterDialogTitle.
  ///
  /// In de, this message translates to:
  /// **'Aufwärtsmischer vor dem Stick'**
  String get scannerUpconverterDialogTitle;

  /// No description provided for @scannerUpconverter.
  ///
  /// In de, this message translates to:
  /// **'Aufwärtsmischer'**
  String get scannerUpconverter;

  /// No description provided for @scannerHubHfHam.
  ///
  /// In de, this message translates to:
  /// **'Amateurfunk KW'**
  String get scannerHubHfHam;

  /// No description provided for @scannerHubHfHamSubtitle.
  ///
  /// In de, this message translates to:
  /// **'160 m bis 10 m · SSB, CW, FT8'**
  String get scannerHubHfHamSubtitle;

  /// No description provided for @scannerHubHfUtilitySubtitle.
  ///
  /// In de, this message translates to:
  /// **'Zeitzeichen · VOLMET · Shanwick · Wetterfax'**
  String get scannerHubHfUtilitySubtitle;

  /// No description provided for @scannerHubShortwaveFooter.
  ///
  /// In de, this message translates to:
  /// **'Kurzwelle braucht einen Stick mit Kurzwelleneingang: RTL-SDR Blog V3 (Direct Sampling, schaltet unter 24 MHz automatisch um), RTL-SDR Blog V4 (eingebauter Aufwärtsmischer; über rtl_tcp nur, wenn der Server ihn unterstützt) – oder einen beliebigen Stick mit einem Aufwärtsmischer wie dem Ham It Up. Gewöhnliche Sticks (z. B. NooElec NESDR) haben keinen. Dazu eine Antenne für Kurzwelle – eine Langdraht- oder Aktivantenne. Rundfunk auf Lang-, Mittel- und Kurzwelle: eigener Punkt „LW/MW/KW“ oben.'**
  String get scannerHubShortwaveFooter;

  /// No description provided for @scannerRxWaiting.
  ///
  /// In de, this message translates to:
  /// **'Warte auf Daten vom Stick…'**
  String get scannerRxWaiting;

  /// No description provided for @scannerRxNoData.
  ///
  /// In de, this message translates to:
  /// **'Keine Daten vom Stick'**
  String get scannerRxNoData;

  /// No description provided for @scannerRxSlow.
  ///
  /// In de, this message translates to:
  /// **'Daten kommen zu langsam'**
  String get scannerRxSlow;

  /// No description provided for @scannerRxRunning.
  ///
  /// In de, this message translates to:
  /// **'Empfang läuft'**
  String get scannerRxRunning;

  /// No description provided for @scannerRxLevel.
  ///
  /// In de, this message translates to:
  /// **'Pegel'**
  String get scannerRxLevel;

  /// No description provided for @scannerRxClipping.
  ///
  /// In de, this message translates to:
  /// **'übersteuert – Verstärkung senken'**
  String get scannerRxClipping;

  /// No description provided for @scannerMapAttribution.
  ///
  /// In de, this message translates to:
  /// **'© OpenStreetMap-Mitwirkende'**
  String get scannerMapAttribution;

  /// No description provided for @scannerReceiverStartFailed.
  ///
  /// In de, this message translates to:
  /// **'Empfänger konnte nicht gestartet werden.'**
  String get scannerReceiverStartFailed;

  /// No description provided for @scannerReceiverStarting.
  ///
  /// In de, this message translates to:
  /// **'Starte Empfänger…'**
  String get scannerReceiverStarting;

  /// No description provided for @scannerGain.
  ///
  /// In de, this message translates to:
  /// **'Verstärkung'**
  String get scannerGain;

  /// No description provided for @scannerAcarsTitle.
  ///
  /// In de, this message translates to:
  /// **'ACARS (Textmeldungen von Flugzeugen)'**
  String get scannerAcarsTitle;

  /// No description provided for @scannerAcarsVdl2Chip.
  ///
  /// In de, this message translates to:
  /// **'VDL2 · 136,9 MHz'**
  String get scannerAcarsVdl2Chip;

  /// No description provided for @scannerAcarsClassicChip.
  ///
  /// In de, this message translates to:
  /// **'ACARS klassisch · 131 MHz'**
  String get scannerAcarsClassicChip;

  /// No description provided for @scannerAcarsMessageCount.
  ///
  /// In de, this message translates to:
  /// **'{count, plural, =1{1 Meldung} other{{count} Meldungen}}'**
  String scannerAcarsMessageCount(int count);

  /// No description provided for @scannerAcarsHint.
  ///
  /// In de, this message translates to:
  /// **'Alle {count} Kanäle werden gleichzeitig dekodiert. Punkt grün = Meldung in den letzten 10 s, Balken grün = auf dem Kanal wird gerade gesendet.'**
  String scannerAcarsHint(int count);

  /// No description provided for @scannerAcarsVdl2Hint.
  ///
  /// In de, this message translates to:
  /// **'VDL2 ist digital: Bodenstationen und Flugzeuge senden kurze Datenpakete, Textmeldungen (ACARS) sind ein Teil davon.'**
  String get scannerAcarsVdl2Hint;

  /// No description provided for @scannerAcarsWaiting.
  ///
  /// In de, this message translates to:
  /// **'Warte auf Meldungen… Bei Flugverkehr in der Nähe kommen meist mehrere pro Minute.\nAntenne für {antenna} (Viertelwelle) - möglichst frei, am Fenster.'**
  String scannerAcarsWaiting(String antenna);

  /// No description provided for @scannerAcarsAntenna.
  ///
  /// In de, this message translates to:
  /// **'{frequency} MHz: senkrecht, ~{length} cm'**
  String scannerAcarsAntenna(String frequency, String length);

  /// No description provided for @scannerAcarsTryVdl2.
  ///
  /// In de, this message translates to:
  /// **'In Europa senden die meisten Flugzeuge inzwischen über VDL2 - kommt hier nichts, oben auf VDL2 umschalten.'**
  String get scannerAcarsTryVdl2;

  /// No description provided for @scannerColTime.
  ///
  /// In de, this message translates to:
  /// **'Zeit'**
  String get scannerColTime;

  /// No description provided for @scannerColFlight.
  ///
  /// In de, this message translates to:
  /// **'Flug'**
  String get scannerColFlight;

  /// No description provided for @scannerColRegistration.
  ///
  /// In de, this message translates to:
  /// **'Kennzeichen'**
  String get scannerColRegistration;

  /// No description provided for @scannerColType.
  ///
  /// In de, this message translates to:
  /// **'Art'**
  String get scannerColType;

  /// No description provided for @scannerAcarsReceived.
  ///
  /// In de, this message translates to:
  /// **'Empfangen {time} auf {frequency} MHz'**
  String scannerAcarsReceived(String time, String frequency);

  /// No description provided for @scannerAcarsDirection.
  ///
  /// In de, this message translates to:
  /// **'Richtung: {direction}'**
  String scannerAcarsDirection(String direction);

  /// No description provided for @scannerAcarsFromAircraft.
  ///
  /// In de, this message translates to:
  /// **'vom Flugzeug'**
  String get scannerAcarsFromAircraft;

  /// No description provided for @scannerAcarsToAircraft.
  ///
  /// In de, this message translates to:
  /// **'zum Flugzeug'**
  String get scannerAcarsToAircraft;

  /// No description provided for @scannerAcarsRegistration.
  ///
  /// In de, this message translates to:
  /// **'Kennzeichen: {registration}'**
  String scannerAcarsRegistration(String registration);

  /// No description provided for @scannerAcarsFlight.
  ///
  /// In de, this message translates to:
  /// **'Flug {flight}'**
  String scannerAcarsFlight(String flight);

  /// No description provided for @scannerAcarsMessageNo.
  ///
  /// In de, this message translates to:
  /// **'Nr. {number}'**
  String scannerAcarsMessageNo(String number);

  /// No description provided for @scannerAcarsContinued.
  ///
  /// In de, this message translates to:
  /// **'Fortsetzung folgt'**
  String get scannerAcarsContinued;

  /// No description provided for @scannerAcarsNoText.
  ///
  /// In de, this message translates to:
  /// **'(kein Text)'**
  String get scannerAcarsNoText;

  /// No description provided for @scannerAdsbTitle.
  ///
  /// In de, this message translates to:
  /// **'Flugzeuge (ADS-B 1090 MHz)'**
  String get scannerAdsbTitle;

  /// No description provided for @scannerAdsbCount.
  ///
  /// In de, this message translates to:
  /// **'{count, plural, =1{1 Flugzeug} other{{count} Flugzeuge}} · {withPosition} mit Position'**
  String scannerAdsbCount(int count, int withPosition);

  /// No description provided for @scannerAdsbRate.
  ///
  /// In de, this message translates to:
  /// **'{rate} Meldungen/s'**
  String scannerAdsbRate(int rate);

  /// No description provided for @scannerAdsbMap.
  ///
  /// In de, this message translates to:
  /// **'Karte'**
  String get scannerAdsbMap;

  /// No description provided for @scannerAdsbNoAircraft.
  ///
  /// In de, this message translates to:
  /// **'Noch kein Flugzeug empfangen.\nAntenne: senkrecht, ~6,9 cm (Viertelwelle 1090 MHz), möglichst am Fenster.'**
  String get scannerAdsbNoAircraft;

  /// No description provided for @scannerAdsbOnGround.
  ///
  /// In de, this message translates to:
  /// **'am Boden'**
  String get scannerAdsbOnGround;

  /// No description provided for @scannerAdsbColFlight.
  ///
  /// In de, this message translates to:
  /// **'Flug / ICAO'**
  String get scannerAdsbColFlight;

  /// No description provided for @scannerAdsbColAltitude.
  ///
  /// In de, this message translates to:
  /// **'Höhe'**
  String get scannerAdsbColAltitude;

  /// No description provided for @scannerAdsbColSpeed.
  ///
  /// In de, this message translates to:
  /// **'Tempo'**
  String get scannerAdsbColSpeed;

  /// No description provided for @scannerAdsbColClimb.
  ///
  /// In de, this message translates to:
  /// **'Steig/Sink'**
  String get scannerAdsbColClimb;

  /// No description provided for @scannerAdsbColDistance.
  ///
  /// In de, this message translates to:
  /// **'Entfernung'**
  String get scannerAdsbColDistance;

  /// No description provided for @scannerAdsbColCountry.
  ///
  /// In de, this message translates to:
  /// **'Zulassung'**
  String get scannerAdsbColCountry;

  /// No description provided for @scannerAdsbColLastSeen.
  ///
  /// In de, this message translates to:
  /// **'Zuletzt'**
  String get scannerAdsbColLastSeen;

  /// No description provided for @scannerAdsbRouteLoading.
  ///
  /// In de, this message translates to:
  /// **'Route wird geladen…'**
  String get scannerAdsbRouteLoading;

  /// No description provided for @scannerAdsbRouteStale.
  ///
  /// In de, this message translates to:
  /// **'Passt nicht zur Flugrichtung – die Fluglinie vergibt dieses Rufzeichen offenbar für eine andere Strecke; die Routendaten sind veraltet.'**
  String get scannerAdsbRouteStale;

  /// No description provided for @scannerAdsbFrom.
  ///
  /// In de, this message translates to:
  /// **'Von'**
  String get scannerAdsbFrom;

  /// No description provided for @scannerAdsbTo.
  ///
  /// In de, this message translates to:
  /// **'Nach'**
  String get scannerAdsbTo;

  /// No description provided for @scannerAdsbHideRoute.
  ///
  /// In de, this message translates to:
  /// **'Flugroute ausblenden (Zurück)'**
  String get scannerAdsbHideRoute;

  /// No description provided for @scannerAdsbShowRoute.
  ///
  /// In de, this message translates to:
  /// **'Flugroute zeigen (OK)'**
  String get scannerAdsbShowRoute;

  /// No description provided for @scannerAdsbNoRoute.
  ///
  /// In de, this message translates to:
  /// **'Keine Routendaten bekannt'**
  String get scannerAdsbNoRoute;

  /// No description provided for @scannerAdsbAirline.
  ///
  /// In de, this message translates to:
  /// **'Fluglinie'**
  String get scannerAdsbAirline;

  /// No description provided for @scannerAdsbAircraft.
  ///
  /// In de, this message translates to:
  /// **'Flugzeug'**
  String get scannerAdsbAircraft;

  /// No description provided for @scannerAdsbOwner.
  ///
  /// In de, this message translates to:
  /// **'Halter'**
  String get scannerAdsbOwner;

  /// No description provided for @scannerAdsbIcaoAddress.
  ///
  /// In de, this message translates to:
  /// **'ICAO-Adresse'**
  String get scannerAdsbIcaoAddress;

  /// No description provided for @scannerAdsbTrack.
  ///
  /// In de, this message translates to:
  /// **'Kurs'**
  String get scannerAdsbTrack;

  /// No description provided for @scannerAdsbClimbRate.
  ///
  /// In de, this message translates to:
  /// **'Steigen/Sinken'**
  String get scannerAdsbClimbRate;

  /// No description provided for @scannerAdsbGroundSpeed.
  ///
  /// In de, this message translates to:
  /// **'Geschwindigkeit'**
  String get scannerAdsbGroundSpeed;

  /// No description provided for @scannerAdsbPosition.
  ///
  /// In de, this message translates to:
  /// **'{lat}° N, {lon}° O'**
  String scannerAdsbPosition(String lat, String lon);

  /// No description provided for @scannerAdsbBearing.
  ///
  /// In de, this message translates to:
  /// **'Richtung'**
  String get scannerAdsbBearing;

  /// No description provided for @scannerAdsbBearingValue.
  ///
  /// In de, this message translates to:
  /// **'{degrees}° in {distance} km'**
  String scannerAdsbBearingValue(int degrees, String distance);

  /// No description provided for @scannerAdsbReception.
  ///
  /// In de, this message translates to:
  /// **'Empfang'**
  String get scannerAdsbReception;

  /// No description provided for @scannerAdsbReceptionValue.
  ///
  /// In de, this message translates to:
  /// **'{count, plural, =1{1 Meldung} other{{count} Meldungen}} · Signal {signal} dB'**
  String scannerAdsbReceptionValue(int count, String signal);

  /// No description provided for @scannerAdsbDataSource.
  ///
  /// In de, this message translates to:
  /// **'Route und Flugzeugdaten: adsbdb.com'**
  String get scannerAdsbDataSource;

  /// No description provided for @scannerAdsbClimbing.
  ///
  /// In de, this message translates to:
  /// **'↗ steigt'**
  String get scannerAdsbClimbing;

  /// No description provided for @scannerAdsbDescending.
  ///
  /// In de, this message translates to:
  /// **'↘ sinkt'**
  String get scannerAdsbDescending;

  /// No description provided for @scannerAgoSeconds.
  ///
  /// In de, this message translates to:
  /// **'vor {seconds} s'**
  String scannerAgoSeconds(int seconds);

  /// No description provided for @scannerAgoMinutes.
  ///
  /// In de, this message translates to:
  /// **'vor {minutes} min'**
  String scannerAgoMinutes(int minutes);

  /// No description provided for @scannerAgoHours.
  ///
  /// In de, this message translates to:
  /// **'vor {hours} h'**
  String scannerAgoHours(int hours);

  /// No description provided for @scannerIsmNameFor.
  ///
  /// In de, this message translates to:
  /// **'Name für {model}'**
  String scannerIsmNameFor(String model);

  /// No description provided for @scannerIsmNameHint.
  ///
  /// In de, this message translates to:
  /// **'z. B. Balkon, Keller, Nachbar Garten'**
  String get scannerIsmNameHint;

  /// No description provided for @scannerIsmDevices.
  ///
  /// In de, this message translates to:
  /// **'{count, plural, =1{1 Gerät} other{{count} Geräte}}'**
  String scannerIsmDevices(int count);

  /// No description provided for @scannerIsmSignals.
  ///
  /// In de, this message translates to:
  /// **'{count, plural, =1{1 Signal} other{{count} Signale}}'**
  String scannerIsmSignals(int count);

  /// No description provided for @scannerIsmShowHidden.
  ///
  /// In de, this message translates to:
  /// **'Ausgeblendete zeigen ({count})'**
  String scannerIsmShowHidden(int count);

  /// No description provided for @scannerIsmWaiting.
  ///
  /// In de, this message translates to:
  /// **'Warte auf Funksensoren… Die meisten senden alle 30–60 Sekunden.\nAntenne für 433 MHz: senkrecht, ~17 cm (868 MHz: ~8,6 cm).'**
  String get scannerIsmWaiting;

  /// No description provided for @scannerIsmSectionWeather.
  ///
  /// In de, this message translates to:
  /// **'Thermometer & Wetter'**
  String get scannerIsmSectionWeather;

  /// No description provided for @scannerIsmSectionSwitches.
  ///
  /// In de, this message translates to:
  /// **'Schalter, Klingeln, Fernbedienungen'**
  String get scannerIsmSectionSwitches;

  /// No description provided for @scannerIsmSectionKeys.
  ///
  /// In de, this message translates to:
  /// **'Funkschlüssel (anonym)'**
  String get scannerIsmSectionKeys;

  /// No description provided for @scannerIsmSectionUnknown.
  ///
  /// In de, this message translates to:
  /// **'Unbekannt'**
  String get scannerIsmSectionUnknown;

  /// No description provided for @scannerIsmKeyPresses.
  ///
  /// In de, this message translates to:
  /// **'{count, plural, =1{1 Tastendruck} other{{count} Tastendrücke}} in der Umgebung, seit diese Seite offen ist · zuletzt {age}'**
  String scannerIsmKeyPresses(int count, String age);

  /// No description provided for @scannerIsmTransmitters.
  ///
  /// In de, this message translates to:
  /// **'{count, plural, =1{1 Sender} other{{count} Sender}}'**
  String scannerIsmTransmitters(int count);

  /// No description provided for @scannerIsmHideRaw.
  ///
  /// In de, this message translates to:
  /// **'Rohdaten ausblenden'**
  String get scannerIsmHideRaw;

  /// No description provided for @scannerIsmShowRaw.
  ///
  /// In de, this message translates to:
  /// **'Rohdaten ansehen'**
  String get scannerIsmShowRaw;

  /// No description provided for @scannerIsmRain.
  ///
  /// In de, this message translates to:
  /// **'Regen {amount} mm'**
  String scannerIsmRain(String amount);

  /// No description provided for @scannerIsmBatteryOk.
  ///
  /// In de, this message translates to:
  /// **'ok'**
  String get scannerIsmBatteryOk;

  /// No description provided for @scannerIsmBatteryLow.
  ///
  /// In de, this message translates to:
  /// **'schwach'**
  String get scannerIsmBatteryLow;

  /// No description provided for @scannerIsmContinuous.
  ///
  /// In de, this message translates to:
  /// **'Dauersender (FSK, ~{bitTime} µs/Bit)'**
  String scannerIsmContinuous(String bitTime);

  /// No description provided for @scannerIsmNotDecodable.
  ///
  /// In de, this message translates to:
  /// **'fortlaufendes Muster, nicht dekodierbar'**
  String get scannerIsmNotDecodable;

  /// No description provided for @scannerIsmBitTime.
  ///
  /// In de, this message translates to:
  /// **'~{bitTime} µs/Bit'**
  String scannerIsmBitTime(String bitTime);

  /// No description provided for @scannerIsmPulses.
  ///
  /// In de, this message translates to:
  /// **'{count} Pulse ({pulses}, Pausen {gaps})'**
  String scannerIsmPulses(int count, String pulses, String gaps);

  /// No description provided for @scannerIsmAfterSync.
  ///
  /// In de, this message translates to:
  /// **'Nach Sync 2DD4: {data}'**
  String scannerIsmAfterSync(String data);

  /// No description provided for @scannerIsmDevice.
  ///
  /// In de, this message translates to:
  /// **'Gerät: {model} · ID {id}'**
  String scannerIsmDevice(String model, String id);

  /// No description provided for @scannerIsmTemperature.
  ///
  /// In de, this message translates to:
  /// **'Temperatur: {value} °C'**
  String scannerIsmTemperature(String value);

  /// No description provided for @scannerIsmTempRange.
  ///
  /// In de, this message translates to:
  /// **'24 h: {min} bis {max} °C'**
  String scannerIsmTempRange(String min, String max);

  /// No description provided for @scannerIsmHumidity.
  ///
  /// In de, this message translates to:
  /// **'Luftfeuchte: {value} %'**
  String scannerIsmHumidity(String value);

  /// No description provided for @scannerIsmBattery.
  ///
  /// In de, this message translates to:
  /// **'Batterie: {state}'**
  String scannerIsmBattery(String state);

  /// No description provided for @scannerIsmReceived.
  ///
  /// In de, this message translates to:
  /// **'Empfangen: {count}× · zuletzt {age} · Pegel {level} dB'**
  String scannerIsmReceived(int count, String age, int level);

  /// No description provided for @scannerIsmSetName.
  ///
  /// In de, this message translates to:
  /// **'Name vergeben'**
  String get scannerIsmSetName;

  /// No description provided for @scannerIsmRename.
  ///
  /// In de, this message translates to:
  /// **'Umbenennen'**
  String get scannerIsmRename;

  /// No description provided for @scannerIsmShowAgain.
  ///
  /// In de, this message translates to:
  /// **'Wieder anzeigen'**
  String get scannerIsmShowAgain;

  /// No description provided for @scannerIsmHide.
  ///
  /// In de, this message translates to:
  /// **'Ausblenden'**
  String get scannerIsmHide;

  /// No description provided for @scannerJumpTo.
  ///
  /// In de, this message translates to:
  /// **'Springen zu…'**
  String get scannerJumpTo;

  /// No description provided for @scannerFrequencyTitle.
  ///
  /// In de, this message translates to:
  /// **'Frequenz (MHz)'**
  String get scannerFrequencyTitle;

  /// No description provided for @scannerFrequencyHint.
  ///
  /// In de, this message translates to:
  /// **'z. B. 145,500'**
  String get scannerFrequencyHint;

  /// No description provided for @scannerOutOfRange.
  ///
  /// In de, this message translates to:
  /// **'Der Stick empfängt {low}–{high} MHz.'**
  String scannerOutOfRange(String low, String high);

  /// No description provided for @scannerHfHint.
  ///
  /// In de, this message translates to:
  /// **'Nichts zu hören? Kurzwelle braucht einen Stick mit Direct Sampling (RTL-SDR Blog V3, NESDR SMArt v5), einen RTL-SDR Blog V4 (über rtl_tcp nur mit dem Blog-V4-Treiber am Server) oder einen Aufwärtsmischer (Funk → Kurzwelle) - und eine Antenne für Kurzwelle.'**
  String get scannerHfHint;

  /// No description provided for @scannerSignalAboveNoise.
  ///
  /// In de, this message translates to:
  /// **'Signal {snr} dB über Rauschen'**
  String scannerSignalAboveNoise(int snr);

  /// No description provided for @scannerChannelButton.
  ///
  /// In de, this message translates to:
  /// **'Kanal'**
  String get scannerChannelButton;

  /// No description provided for @scannerFrequencyButton.
  ///
  /// In de, this message translates to:
  /// **'Frequenz…'**
  String get scannerFrequencyButton;

  /// No description provided for @scannerFine.
  ///
  /// In de, this message translates to:
  /// **'Fein'**
  String get scannerFine;

  /// No description provided for @scannerCbChannels.
  ///
  /// In de, this message translates to:
  /// **'{count} Kanäle'**
  String scannerCbChannels(int count);

  /// No description provided for @scannerScan.
  ///
  /// In de, this message translates to:
  /// **'Suchlauf'**
  String get scannerScan;

  /// No description provided for @scannerAprsTooltip.
  ///
  /// In de, this message translates to:
  /// **'APRS-Pakete (1200 Baud) dekodieren - auf 144,800 und 145,825 automatisch'**
  String get scannerAprsTooltip;

  /// No description provided for @scannerBandPlanTooltip.
  ///
  /// In de, this message translates to:
  /// **'Modulation und Filter passend zum Bereich des Bandplans'**
  String get scannerBandPlanTooltip;

  /// No description provided for @scannerBandPlan.
  ///
  /// In de, this message translates to:
  /// **'Bandplan'**
  String get scannerBandPlan;

  /// No description provided for @scannerSquelch.
  ///
  /// In de, this message translates to:
  /// **'Rauschsperre'**
  String get scannerSquelch;

  /// No description provided for @scannerSampleRate.
  ///
  /// In de, this message translates to:
  /// **'Bandbreite {rate} MHz (~{mbit} Mbit/s)'**
  String scannerSampleRate(String rate, int mbit);

  /// No description provided for @scannerSignalFilters.
  ///
  /// In de, this message translates to:
  /// **'Signalfilter'**
  String get scannerSignalFilters;

  /// No description provided for @scannerRange.
  ///
  /// In de, this message translates to:
  /// **'Bereich'**
  String get scannerRange;

  /// No description provided for @scannerShowing.
  ///
  /// In de, this message translates to:
  /// **'Zeigt {low}–{high} MHz'**
  String scannerShowing(String low, String high);

  /// No description provided for @scannerFilterWidth.
  ///
  /// In de, this message translates to:
  /// **'Filterbreite'**
  String get scannerFilterWidth;

  /// No description provided for @scannerFilterWidthHelp.
  ///
  /// In de, this message translates to:
  /// **'Schmaler: weniger Rauschen und Nachbarkanäle. Breiter: verständlicher, wenn ein Sender etwas daneben liegt. Auto passt zur Modulation.'**
  String get scannerFilterWidthHelp;

  /// No description provided for @scannerNoiseBlanker.
  ///
  /// In de, this message translates to:
  /// **'Störaustaster'**
  String get scannerNoiseBlanker;

  /// No description provided for @scannerNoiseBlankerHelp.
  ///
  /// In de, this message translates to:
  /// **'Entfernt kurze Knackser von Zündfunken, Weidezäunen und Netzteilen.'**
  String get scannerNoiseBlankerHelp;

  /// No description provided for @scannerVoiceFilter.
  ///
  /// In de, this message translates to:
  /// **'Sprachfilter'**
  String get scannerVoiceFilter;

  /// No description provided for @scannerVoiceFilterHelp.
  ///
  /// In de, this message translates to:
  /// **'Nur der Sprachbereich 300–3000 Hz: weniger Brummen, Rauschen und Pilottöne.'**
  String get scannerVoiceFilterHelp;

  /// No description provided for @scannerAgc.
  ///
  /// In de, this message translates to:
  /// **'Lautstärkeregelung'**
  String get scannerAgc;

  /// No description provided for @scannerAgcHelp.
  ///
  /// In de, this message translates to:
  /// **'Schnell für AM/FM, langsam für SSB - verhindert Pumpen zwischen den Silben. Auto wählt passend zur Modulation.'**
  String get scannerAgcHelp;

  /// No description provided for @scannerAgcFast.
  ///
  /// In de, this message translates to:
  /// **'Schnell'**
  String get scannerAgcFast;

  /// No description provided for @scannerAgcSlow.
  ///
  /// In de, this message translates to:
  /// **'Langsam'**
  String get scannerAgcSlow;

  /// No description provided for @scannerDmrCallPending.
  ///
  /// In de, this message translates to:
  /// **'Gespräch (Kennung folgt…)'**
  String get scannerDmrCallPending;

  /// No description provided for @scannerDmrLast.
  ///
  /// In de, this message translates to:
  /// **'zuletzt {call} {ago}'**
  String scannerDmrLast(String call, String ago);

  /// No description provided for @scannerDmrIdle.
  ///
  /// In de, this message translates to:
  /// **'frei'**
  String get scannerDmrIdle;

  /// No description provided for @scannerDmrReceptionGood.
  ///
  /// In de, this message translates to:
  /// **'Empfang gut'**
  String get scannerDmrReceptionGood;

  /// No description provided for @scannerDmrReceptionFair.
  ///
  /// In de, this message translates to:
  /// **'Empfang mäßig'**
  String get scannerDmrReceptionFair;

  /// No description provided for @scannerDmrReceptionPoor.
  ///
  /// In de, this message translates to:
  /// **'Empfang schlecht'**
  String get scannerDmrReceptionPoor;

  /// No description provided for @scannerDmrSlot.
  ///
  /// In de, this message translates to:
  /// **'Zeitschlitz {slot}'**
  String scannerDmrSlot(int slot);

  /// No description provided for @scannerDmrEmergency.
  ///
  /// In de, this message translates to:
  /// **'NOTRUF'**
  String get scannerDmrEmergency;

  /// No description provided for @scannerDmrEncryptedNoAudio.
  ///
  /// In de, this message translates to:
  /// **'verschlüsselt – kein Ton'**
  String get scannerDmrEncryptedNoAudio;

  /// No description provided for @scannerDmrNoSignal.
  ///
  /// In de, this message translates to:
  /// **'kein DMR-Signal'**
  String get scannerDmrNoSignal;

  /// No description provided for @scannerDmrColorCode.
  ///
  /// In de, this message translates to:
  /// **'Farbcode {code}'**
  String scannerDmrColorCode(int code);

  /// No description provided for @scannerDmrNoVoiceDecoder.
  ///
  /// In de, this message translates to:
  /// **'ohne Sprachdecoder gebaut – nur Anzeige'**
  String get scannerDmrNoVoiceDecoder;

  /// No description provided for @scannerDmrRecentlyHeard.
  ///
  /// In de, this message translates to:
  /// **'Zuletzt gehört'**
  String get scannerDmrRecentlyHeard;

  /// No description provided for @scannerDmrEncrypted.
  ///
  /// In de, this message translates to:
  /// **'verschlüsselt'**
  String get scannerDmrEncrypted;

  /// No description provided for @scannerAprsPackets.
  ///
  /// In de, this message translates to:
  /// **'{count, plural, =1{1 Paket} other{{count} Pakete}}'**
  String scannerAprsPackets(int count);

  /// No description provided for @scannerAprsDecoderWaiting.
  ///
  /// In de, this message translates to:
  /// **'Dekoder läuft - warte auf Pakete…'**
  String get scannerAprsDecoderWaiting;

  /// No description provided for @scannerAprsDecoderRunning.
  ///
  /// In de, this message translates to:
  /// **'Dekoder läuft'**
  String get scannerAprsDecoderRunning;

  /// No description provided for @scannerAprsDecoderOff.
  ///
  /// In de, this message translates to:
  /// **'Dekoder aus'**
  String get scannerAprsDecoderOff;

  /// No description provided for @scannerAprsClear.
  ///
  /// In de, this message translates to:
  /// **'Leeren'**
  String get scannerAprsClear;

  /// No description provided for @scannerAprsTo.
  ///
  /// In de, this message translates to:
  /// **'an {name}'**
  String scannerAprsTo(String name);

  /// No description provided for @scannerAprsReceived.
  ///
  /// In de, this message translates to:
  /// **'Empfangen {time}'**
  String scannerAprsReceived(String time);

  /// No description provided for @scannerEastShort.
  ///
  /// In de, this message translates to:
  /// **'O'**
  String get scannerEastShort;

  /// No description provided for @scannerAprsDistance.
  ///
  /// In de, this message translates to:
  /// **'Entfernung: {distance}'**
  String scannerAprsDistance(String distance);

  /// No description provided for @scannerAprsPath.
  ///
  /// In de, this message translates to:
  /// **'Weg: {path}'**
  String scannerAprsPath(String path);

  /// No description provided for @scannerAprsDirect.
  ///
  /// In de, this message translates to:
  /// **'direkt'**
  String get scannerAprsDirect;

  /// No description provided for @scannerRawData.
  ///
  /// In de, this message translates to:
  /// **'Rohdaten'**
  String get scannerRawData;

  /// Between two addresses of the admin page: 'http://… oder http://…'.
  ///
  /// In de, this message translates to:
  /// **'oder'**
  String get settingsOr;

  /// No description provided for @settingsNotSetUp.
  ///
  /// In de, this message translates to:
  /// **'nicht eingerichtet'**
  String get settingsNotSetUp;

  /// No description provided for @settingsPercent.
  ///
  /// In de, this message translates to:
  /// **'{value} %'**
  String settingsPercent(int value);

  /// No description provided for @settingsMinutesShort.
  ///
  /// In de, this message translates to:
  /// **'{minutes} Min.'**
  String settingsMinutesShort(int minutes);

  /// No description provided for @settingsSecondsShort.
  ///
  /// In de, this message translates to:
  /// **'{seconds} Sek.'**
  String settingsSecondsShort(int seconds);

  /// No description provided for @settingsDeviceNameHelp.
  ///
  /// In de, this message translates to:
  /// **'Eindeutig im Heimnetz - erscheint auf der Verwaltungsseite und im Namen der Backups.'**
  String get settingsDeviceNameHelp;

  /// No description provided for @settingsDeviceNameOwn.
  ///
  /// In de, this message translates to:
  /// **'Eigener Name'**
  String get settingsDeviceNameOwn;

  /// No description provided for @settingsDeviceNameNotSet.
  ///
  /// In de, this message translates to:
  /// **'nicht vergeben'**
  String get settingsDeviceNameNotSet;

  /// No description provided for @settingsDeviceNameSuggestionTerrace.
  ///
  /// In de, this message translates to:
  /// **'Terrassen-Media'**
  String get settingsDeviceNameSuggestionTerrace;

  /// No description provided for @settingsDeviceNameSuggestionLivingRoom.
  ///
  /// In de, this message translates to:
  /// **'Wohnzimmer-TV'**
  String get settingsDeviceNameSuggestionLivingRoom;

  /// No description provided for @settingsDeviceNameSuggestionBedroom.
  ///
  /// In de, this message translates to:
  /// **'Schlafzimmer-TV'**
  String get settingsDeviceNameSuggestionBedroom;

  /// No description provided for @settingsDeviceNameSuggestionKitchen.
  ///
  /// In de, this message translates to:
  /// **'Küchen-Tablet'**
  String get settingsDeviceNameSuggestionKitchen;

  /// No description provided for @settingsReception.
  ///
  /// In de, this message translates to:
  /// **'Empfang'**
  String get settingsReception;

  /// No description provided for @settingsReceiverNone.
  ///
  /// In de, this message translates to:
  /// **'Kein Empfänger'**
  String get settingsReceiverNone;

  /// No description provided for @settingsReceiverUsb.
  ///
  /// In de, this message translates to:
  /// **'RTL-SDR per USB'**
  String get settingsReceiverUsb;

  /// No description provided for @settingsReceiverTcp.
  ///
  /// In de, this message translates to:
  /// **'RTL-SDR über Netzwerk'**
  String get settingsReceiverTcp;

  /// No description provided for @settingsShowDab.
  ///
  /// In de, this message translates to:
  /// **'DAB anzeigen'**
  String get settingsShowDab;

  /// No description provided for @settingsShowFm.
  ///
  /// In de, this message translates to:
  /// **'FM anzeigen'**
  String get settingsShowFm;

  /// No description provided for @settingsShowAm.
  ///
  /// In de, this message translates to:
  /// **'LW/MW/KW anzeigen'**
  String get settingsShowAm;

  /// No description provided for @settingsShowFunk.
  ///
  /// In de, this message translates to:
  /// **'Funk anzeigen'**
  String get settingsShowFunk;

  /// No description provided for @settingsPartsHeading.
  ///
  /// In de, this message translates to:
  /// **'Teile von Home System'**
  String get settingsPartsHeading;

  /// No description provided for @settingsPartsHelp.
  ///
  /// In de, this message translates to:
  /// **'Ausgeschaltete Teile haben keine Kachel unter Home, und ihre Einstellungen sind ausgegraut.'**
  String get settingsPartsHelp;

  /// No description provided for @settingsDeviceHeading.
  ///
  /// In de, this message translates to:
  /// **'Gerät'**
  String get settingsDeviceHeading;

  /// No description provided for @settingsAdminPageOffline.
  ///
  /// In de, this message translates to:
  /// **'Verwaltungsseite (Backups): ohne Netzwerkverbindung nicht erreichbar'**
  String get settingsAdminPageOffline;

  /// No description provided for @settingsAdminPageAt.
  ///
  /// In de, this message translates to:
  /// **'Verwaltungsseite (Backups) im Browser: {url}'**
  String settingsAdminPageAt(String url);

  /// No description provided for @settingsNas.
  ///
  /// In de, this message translates to:
  /// **'NAS-Server'**
  String get settingsNas;

  /// No description provided for @settingsStartShowHome.
  ///
  /// In de, this message translates to:
  /// **'Home anzeigen'**
  String get settingsStartShowHome;

  /// No description provided for @settingsStartRadio.
  ///
  /// In de, this message translates to:
  /// **'Radio mit Sender starten (Radio → Autostart)'**
  String get settingsStartRadio;

  /// No description provided for @settingsStartTv.
  ///
  /// In de, this message translates to:
  /// **'TV mit Sender starten (TV → Sender beim Start)'**
  String get settingsStartTv;

  /// No description provided for @settingsBackground.
  ///
  /// In de, this message translates to:
  /// **'Hintergrund'**
  String get settingsBackground;

  /// No description provided for @settingsBackgroundGradients.
  ///
  /// In de, this message translates to:
  /// **'Farbverläufe'**
  String get settingsBackgroundGradients;

  /// No description provided for @settingsBackgroundPhotos.
  ///
  /// In de, this message translates to:
  /// **'Landschaftsfotos'**
  String get settingsBackgroundPhotos;

  /// No description provided for @settingsBackgroundServer.
  ///
  /// In de, this message translates to:
  /// **'Eigener Server'**
  String get settingsBackgroundServer;

  /// No description provided for @settingsIconPack.
  ///
  /// In de, this message translates to:
  /// **'Icon-Paket'**
  String get settingsIconPack;

  /// No description provided for @settingsIconPackNone.
  ///
  /// In de, this message translates to:
  /// **'Original-Logos'**
  String get settingsIconPackNone;

  /// No description provided for @settingsHomeKey.
  ///
  /// In de, this message translates to:
  /// **'Home-Taste'**
  String get settingsHomeKey;

  /// No description provided for @settingsReceiverHeading.
  ///
  /// In de, this message translates to:
  /// **'Receiver'**
  String get settingsReceiverHeading;

  /// No description provided for @settingsSatReceiver.
  ///
  /// In de, this message translates to:
  /// **'Sat-Receiver (Enigma2)'**
  String get settingsSatReceiver;

  /// No description provided for @settingsTvKeysValue.
  ///
  /// In de, this message translates to:
  /// **'Senderliste, Programmführer, Optionen, Tonspur'**
  String get settingsTvKeysValue;

  /// No description provided for @settingsTvZapEncrypted.
  ///
  /// In de, this message translates to:
  /// **'Receiver bei Bedarf umschalten'**
  String get settingsTvZapEncrypted;

  /// No description provided for @settingsTvZapEncryptedHelp.
  ///
  /// In de, this message translates to:
  /// **'Nur wenn der Receiver eingeschaltet ist: Karte bzw. CI-Modul entschlüsseln dann nur den Sender, den er selbst zeigt, und an einem Sat-Kabel empfangen alle Tuner nur dessen Band. Für einen verschlüsselten Sender oder einen auf einem anderen Band schaltet die App den Receiver dann um (sein Bild wechselt mit).\nIm Standby schaltet die App nie um - der Receiver entschlüsselt dort selbst und bleibt frei. Hält er noch einen Sender fest, gibt die App ihn frei.'**
  String get settingsTvZapEncryptedHelp;

  /// No description provided for @settingsTvStartHeading.
  ///
  /// In de, this message translates to:
  /// **'Sender beim Start'**
  String get settingsTvStartHeading;

  /// No description provided for @settingsTvStartLast.
  ///
  /// In de, this message translates to:
  /// **'Zuletzt gesehenen Sender'**
  String get settingsTvStartLast;

  /// No description provided for @settingsTvStartFixed.
  ///
  /// In de, this message translates to:
  /// **'Festen Sender'**
  String get settingsTvStartFixed;

  /// No description provided for @settingsTvChannelsError.
  ///
  /// In de, this message translates to:
  /// **'Senderliste nicht erreichbar: {error}'**
  String settingsTvChannelsError(String error);

  /// No description provided for @settingsTvSetUpReceiverFirst.
  ///
  /// In de, this message translates to:
  /// **'Erst den Receiver einrichten.'**
  String get settingsTvSetUpReceiverFirst;

  /// No description provided for @settingsTvNextUpHeading.
  ///
  /// In de, this message translates to:
  /// **'Als Nächstes'**
  String get settingsTvNextUpHeading;

  /// No description provided for @settingsTvNextUpHelp.
  ///
  /// In de, this message translates to:
  /// **'Kurz bevor auf dem laufenden Sender die nächste Sendung beginnt, erscheint ein Hinweis, was als Nächstes kommt.'**
  String get settingsTvNextUpHelp;

  /// No description provided for @settingsTvNextUpToggle.
  ///
  /// In de, this message translates to:
  /// **'Hinweis auf die nächste Sendung'**
  String get settingsTvNextUpToggle;

  /// No description provided for @settingsTvNextUpLead.
  ///
  /// In de, this message translates to:
  /// **'Wie lange vorher'**
  String get settingsTvNextUpLead;

  /// No description provided for @settingsTvNextUpShow.
  ///
  /// In de, this message translates to:
  /// **'Wie lange anzeigen'**
  String get settingsTvNextUpShow;

  /// No description provided for @settingsAutostartHeading.
  ///
  /// In de, this message translates to:
  /// **'Autostart'**
  String get settingsAutostartHeading;

  /// No description provided for @settingsAutostartLast.
  ///
  /// In de, this message translates to:
  /// **'Zuletzt gehörten Sender starten'**
  String get settingsAutostartLast;

  /// No description provided for @settingsAutostartFixed.
  ///
  /// In de, this message translates to:
  /// **'Festen Sender starten'**
  String get settingsAutostartFixed;

  /// No description provided for @settingsDisplayHeading.
  ///
  /// In de, this message translates to:
  /// **'Anzeige'**
  String get settingsDisplayHeading;

  /// No description provided for @settingsShowClockDate.
  ///
  /// In de, this message translates to:
  /// **'Datum neben der Uhrzeit anzeigen'**
  String get settingsShowClockDate;

  /// No description provided for @settingsFullscreen.
  ///
  /// In de, this message translates to:
  /// **'Vollbild'**
  String get settingsFullscreen;

  /// No description provided for @settingsFullscreenMonitor.
  ///
  /// In de, this message translates to:
  /// **'Monitor für Vollbild'**
  String get settingsFullscreenMonitor;

  /// No description provided for @settingsMonitorOf.
  ///
  /// In de, this message translates to:
  /// **'{monitor} von {count}'**
  String settingsMonitorOf(int monitor, int count);

  /// No description provided for @settingsUiScale.
  ///
  /// In de, this message translates to:
  /// **'Größe der Oberfläche'**
  String get settingsUiScale;

  /// No description provided for @settingsTilesHeading.
  ///
  /// In de, this message translates to:
  /// **'Kacheln'**
  String get settingsTilesHeading;

  /// No description provided for @settingsLocation.
  ///
  /// In de, this message translates to:
  /// **'Standort'**
  String get settingsLocation;

  /// No description provided for @settingsWeatherForecast.
  ///
  /// In de, this message translates to:
  /// **'Wetterprognose'**
  String get settingsWeatherForecast;

  /// No description provided for @settingsWeatherSpanTwoTiles.
  ///
  /// In de, this message translates to:
  /// **'Über 2 Kacheln (volle Höhe)'**
  String get settingsWeatherSpanTwoTiles;

  /// No description provided for @settingsTileSize.
  ///
  /// In de, this message translates to:
  /// **'Größe der Kachel'**
  String get settingsTileSize;

  /// No description provided for @settingsContentSize.
  ///
  /// In de, this message translates to:
  /// **'Größe des Inhalts'**
  String get settingsContentSize;

  /// No description provided for @settingsWeatherRadar.
  ///
  /// In de, this message translates to:
  /// **'Wetterradar'**
  String get settingsWeatherRadar;

  /// No description provided for @settingsRadarSource.
  ///
  /// In de, this message translates to:
  /// **'Quelle'**
  String get settingsRadarSource;

  /// token is the literal URL placeholder {r}.
  ///
  /// In de, this message translates to:
  /// **'Umkreis um den Standort ({token} in der Adresse)'**
  String settingsRadarRadius(String token);

  /// No description provided for @settingsRadarDimming.
  ///
  /// In de, this message translates to:
  /// **'Abdunkeln (für abends)'**
  String get settingsRadarDimming;

  /// No description provided for @settingsSunMoon.
  ///
  /// In de, this message translates to:
  /// **'Sonne & Mond'**
  String get settingsSunMoon;

  /// No description provided for @settingsMoreSettings.
  ///
  /// In de, this message translates to:
  /// **'Weitere Einstellungen (System, TV)'**
  String get settingsMoreSettings;

  /// No description provided for @settingsMoreHeading.
  ///
  /// In de, this message translates to:
  /// **'Weiteres'**
  String get settingsMoreHeading;

  /// No description provided for @settingsBackupCreate.
  ///
  /// In de, this message translates to:
  /// **'Backup erstellen'**
  String get settingsBackupCreate;

  /// No description provided for @settingsBackupRestore.
  ///
  /// In de, this message translates to:
  /// **'Backup wiederherstellen'**
  String get settingsBackupRestore;

  /// No description provided for @settingsBackupRestoreHint.
  ///
  /// In de, this message translates to:
  /// **'auch über die Verwaltungsseite'**
  String get settingsBackupRestoreHint;

  /// No description provided for @settingsAboutHeading.
  ///
  /// In de, this message translates to:
  /// **'Über'**
  String get settingsAboutHeading;

  /// No description provided for @settingsQuit.
  ///
  /// In de, this message translates to:
  /// **'Programm beenden'**
  String get settingsQuit;

  /// No description provided for @settingsQuitConfirm.
  ///
  /// In de, this message translates to:
  /// **'Programm beenden?'**
  String get settingsQuitConfirm;

  /// No description provided for @settingsQuitButton.
  ///
  /// In de, this message translates to:
  /// **'Beenden'**
  String get settingsQuitButton;

  /// No description provided for @settingsPartOff.
  ///
  /// In de, this message translates to:
  /// **'{part} ist ausgeschaltet - unter System → Teile von Home System einschalten.'**
  String settingsPartOff(String part);

  /// No description provided for @settingsAreaSystemSubtitle.
  ///
  /// In de, this message translates to:
  /// **'Radio & TV ein/aus, Gerätename, NAS, Start, Home, Home-Taste, Anzeige, Backup, Updates'**
  String get settingsAreaSystemSubtitle;

  /// No description provided for @settingsAreaSystemSubtitleNoHomeKey.
  ///
  /// In de, this message translates to:
  /// **'Radio & TV ein/aus, Gerätename, NAS, Start, Home, Anzeige, Backup, Updates'**
  String get settingsAreaSystemSubtitleNoHomeKey;

  /// No description provided for @settingsAreaRadioSubtitle.
  ///
  /// In de, this message translates to:
  /// **'Empfänger (DAB+, UKW, Funk), Autostart-Sender, Wetter, Radar, Sonne & Mond'**
  String get settingsAreaRadioSubtitle;

  /// No description provided for @settingsAreaTvSubtitle.
  ///
  /// In de, this message translates to:
  /// **'Sat-Receiver (Enigma2, z. B. GigaBlue)'**
  String get settingsAreaTvSubtitle;

  /// No description provided for @settingsAreaOff.
  ///
  /// In de, this message translates to:
  /// **'Ausgeschaltet - unter System einschalten'**
  String get settingsAreaOff;

  /// No description provided for @settingsAboutLicense.
  ///
  /// In de, this message translates to:
  /// **'PolyForm Noncommercial 1.0.0 - frei für private und nicht-kommerzielle Nutzung. © 2026 Jürgen Laschak, github.com/JayLo1401/home.system'**
  String get settingsAboutLicense;

  /// No description provided for @settingsAboutWeatherData.
  ///
  /// In de, this message translates to:
  /// **'Daten: © GeoSphere Austria, lizenziert unter CC BY 4.0 (data.hub.geosphere.at)'**
  String get settingsAboutWeatherData;

  /// No description provided for @settingsAboutUvIndex.
  ///
  /// In de, this message translates to:
  /// **'UV-Index'**
  String get settingsAboutUvIndex;

  /// No description provided for @settingsAboutUvData.
  ///
  /// In de, this message translates to:
  /// **'Weather data by Open-Meteo.com, lizenziert unter CC BY 4.0'**
  String get settingsAboutUvData;

  /// No description provided for @settingsAboutInternetRadio.
  ///
  /// In de, this message translates to:
  /// **'Internetradio'**
  String get settingsAboutInternetRadio;

  /// No description provided for @settingsAboutInternetRadioData.
  ///
  /// In de, this message translates to:
  /// **'Sendersuche und Logos über das Community-Verzeichnis Radio Browser (radio-browser.info)'**
  String get settingsAboutInternetRadioData;

  /// No description provided for @settingsAboutPlaceSearch.
  ///
  /// In de, this message translates to:
  /// **'Ortssuche'**
  String get settingsAboutPlaceSearch;

  /// No description provided for @settingsAboutPlaceSearchData.
  ///
  /// In de, this message translates to:
  /// **'© OpenStreetMap-Mitwirkende, Daten unter der Open Database License (ODbL), über Nominatim.'**
  String get settingsAboutPlaceSearchData;

  /// No description provided for @settingsAboutBackgroundPhotos.
  ///
  /// In de, this message translates to:
  /// **'Hintergrundfotos von Home'**
  String get settingsAboutBackgroundPhotos;

  /// No description provided for @settingsAboutBackgroundPhotosData.
  ///
  /// In de, this message translates to:
  /// **'Bing-Bilder des Tages, © bei den jeweiligen Fotografen (nur wenn „Landschaftsfotos aus dem Internet“ gewählt ist).'**
  String get settingsAboutBackgroundPhotosData;

  /// No description provided for @settingsAboutRadarData.
  ///
  /// In de, this message translates to:
  /// **'Das Radarbild kommt von der selbst eingetragenen Quelle; Rechte und Quellenangaben liegen beim jeweiligen Anbieter.'**
  String get settingsAboutRadarData;

  /// Android notification channel of the radio playback.
  ///
  /// In de, this message translates to:
  /// **'Radio-Wiedergabe'**
  String get settingsAudioChannelName;

  /// No description provided for @settingsBackupNotHomeSystem.
  ///
  /// In de, this message translates to:
  /// **'Die Datei ist kein Home-System-Backup.'**
  String get settingsBackupNotHomeSystem;

  /// No description provided for @settingsBackupNewerVersion.
  ///
  /// In de, this message translates to:
  /// **'Das Backup stammt von einer neueren App-Version.'**
  String get settingsBackupNewerVersion;

  /// No description provided for @settingsBackupCorrupt.
  ///
  /// In de, this message translates to:
  /// **'Das Backup ist beschädigt oder unvollständig.'**
  String get settingsBackupCorrupt;

  /// No description provided for @settingsLauncherMenuApp.
  ///
  /// In de, this message translates to:
  /// **'Home System (App-Einstellungen)'**
  String get settingsLauncherMenuApp;

  /// No description provided for @settingsLauncherMenuAndroid.
  ///
  /// In de, this message translates to:
  /// **'Android-Einstellungen'**
  String get settingsLauncherMenuAndroid;

  /// No description provided for @settingsLauncherNotInstalled.
  ///
  /// In de, this message translates to:
  /// **'„{app}“ ist nicht (mehr) installiert.'**
  String settingsLauncherNotInstalled(String app);

  /// No description provided for @settingsLauncherMoveLeft.
  ///
  /// In de, this message translates to:
  /// **'Nach links verschieben'**
  String get settingsLauncherMoveLeft;

  /// No description provided for @settingsLauncherMoveRight.
  ///
  /// In de, this message translates to:
  /// **'Nach rechts verschieben'**
  String get settingsLauncherMoveRight;

  /// No description provided for @settingsLauncherChangeImage.
  ///
  /// In de, this message translates to:
  /// **'Bild ändern'**
  String get settingsLauncherChangeImage;

  /// No description provided for @settingsLauncherRemove.
  ///
  /// In de, this message translates to:
  /// **'Aus der Startleiste entfernen'**
  String get settingsLauncherRemove;

  /// No description provided for @settingsLauncherOptionsHint.
  ///
  /// In de, this message translates to:
  /// **'{key}  Optionen der Kachel'**
  String settingsLauncherOptionsHint(String key);

  /// No description provided for @settingsLauncherOptionsHintMouse.
  ///
  /// In de, this message translates to:
  /// **'{key} oder Rechtsklick  Optionen der Kachel'**
  String settingsLauncherOptionsHintMouse(String key);

  /// No description provided for @settingsLauncherAppInfoFailed.
  ///
  /// In de, this message translates to:
  /// **'Die App-Info von „{app}“ lässt sich nicht öffnen.'**
  String settingsLauncherAppInfoFailed(String app);

  /// No description provided for @settingsLauncherImageTitle.
  ///
  /// In de, this message translates to:
  /// **'Bild für „{tile}“'**
  String settingsLauncherImageTitle(String tile);

  /// No description provided for @settingsLauncherImageAuto.
  ///
  /// In de, this message translates to:
  /// **'Automatisch (Icon-Paket, sonst Original)'**
  String get settingsLauncherImageAuto;

  /// No description provided for @settingsLauncherImageDefault.
  ///
  /// In de, this message translates to:
  /// **'Standard'**
  String get settingsLauncherImageDefault;

  /// No description provided for @settingsLauncherImageOriginal.
  ///
  /// In de, this message translates to:
  /// **'Original der App'**
  String get settingsLauncherImageOriginal;

  /// No description provided for @settingsLauncherImageFromUrl.
  ///
  /// In de, this message translates to:
  /// **'Bild von einer Adresse (URL) …'**
  String get settingsLauncherImageFromUrl;

  /// No description provided for @settingsLauncherImageUrlTitle.
  ///
  /// In de, this message translates to:
  /// **'Bild-Adresse (PNG/JPG, am besten 16:9)'**
  String get settingsLauncherImageUrlTitle;

  /// No description provided for @settingsLauncherFindApps.
  ///
  /// In de, this message translates to:
  /// **'Apps suchen & hinzufügen'**
  String get settingsLauncherFindApps;

  /// No description provided for @settingsWizardTitle.
  ///
  /// In de, this message translates to:
  /// **'Home System einrichten'**
  String get settingsWizardTitle;

  /// No description provided for @settingsWizardStep.
  ///
  /// In de, this message translates to:
  /// **'Schritt {step} von {count}'**
  String settingsWizardStep(int step, int count);

  /// No description provided for @settingsWizardWelcome.
  ///
  /// In de, this message translates to:
  /// **'Willkommen! Gibt es schon ein Backup von Home System?'**
  String get settingsWizardWelcome;

  /// No description provided for @settingsWizardRestoreHint.
  ///
  /// In de, this message translates to:
  /// **'Von diesem Gerät, vom USB-Stick oder über die Verwaltungsseite'**
  String get settingsWizardRestoreHint;

  /// No description provided for @settingsWizardRestoreHintUrl.
  ///
  /// In de, this message translates to:
  /// **'Von diesem Gerät, vom USB-Stick oder über die Verwaltungsseite ({url})'**
  String settingsWizardRestoreHintUrl(String url);

  /// No description provided for @settingsWizardNew.
  ///
  /// In de, this message translates to:
  /// **'Neu einrichten'**
  String get settingsWizardNew;

  /// No description provided for @settingsWizardLanguage.
  ///
  /// In de, this message translates to:
  /// **'Sprache: {language}'**
  String settingsWizardLanguage(String language);

  /// No description provided for @settingsWizardNameQuestion.
  ///
  /// In de, this message translates to:
  /// **'Wie soll dieses Gerät heißen?'**
  String get settingsWizardNameQuestion;

  /// No description provided for @settingsWizardNameHint.
  ///
  /// In de, this message translates to:
  /// **'Ein eindeutiger Name, damit man die Geräte unterscheiden kann - auf der Verwaltungsseite und bei Backups.'**
  String get settingsWizardNameHint;

  /// No description provided for @settingsWizardNameOwn.
  ///
  /// In de, this message translates to:
  /// **'Oder eigener Name'**
  String get settingsWizardNameOwn;

  /// No description provided for @settingsWizardNext.
  ///
  /// In de, this message translates to:
  /// **'Weiter'**
  String get settingsWizardNext;

  /// No description provided for @settingsWizardHomeKeyTitle.
  ///
  /// In de, this message translates to:
  /// **'Home-Taste der Fernbedienung (freiwillig)'**
  String get settingsWizardHomeKeyTitle;

  /// No description provided for @settingsWizardHomeKeyHint.
  ///
  /// In de, this message translates to:
  /// **'Wer möchte, dass die Home-Taste der Fernbedienung Home System öffnet, richtet das hier ein - Home System wird dafür Standard-Launcher, oder eine Bedienungshilfe wird eingeschaltet. Wer das nicht will, geht einfach weiter; es lässt sich jederzeit unter Einstellungen → System → Home-Taste nachholen.'**
  String get settingsWizardHomeKeyHint;

  /// No description provided for @settingsWizardHomeKeySetUp.
  ///
  /// In de, this message translates to:
  /// **'Home-Taste einrichten'**
  String get settingsWizardHomeKeySetUp;

  /// No description provided for @settingsWizardHomeKeySkip.
  ///
  /// In de, this message translates to:
  /// **'Weiter (ohne bzw. nach dem Einrichten)'**
  String get settingsWizardHomeKeySkip;

  /// No description provided for @settingsWizardDone.
  ///
  /// In de, this message translates to:
  /// **'Fertig - „{name}“ ist eingerichtet.'**
  String settingsWizardDone(String name);

  /// No description provided for @settingsWizardDoneHint.
  ///
  /// In de, this message translates to:
  /// **'Home System startet mit Home: Radio, TV und die Apps als Kacheln. Weiteres (Radio-Empfänger, Sat-Receiver, Hintergrund …) unter Einstellungen.'**
  String get settingsWizardDoneHint;

  /// No description provided for @settingsWizardDoneBackups.
  ///
  /// In de, this message translates to:
  /// **'Backups gibt es jederzeit auf der Verwaltungsseite: {url}'**
  String settingsWizardDoneBackups(String url);

  /// No description provided for @settingsWizardStart.
  ///
  /// In de, this message translates to:
  /// **'Los geht\'s'**
  String get settingsWizardStart;

  /// No description provided for @systemStartDashboard.
  ///
  /// In de, this message translates to:
  /// **'Haussteuerung anzeigen (Wandtablet)'**
  String get systemStartDashboard;

  /// No description provided for @systemStartAppNone.
  ///
  /// In de, this message translates to:
  /// **'Andere App starten …'**
  String get systemStartAppNone;

  /// No description provided for @systemStartApp.
  ///
  /// In de, this message translates to:
  /// **'App starten: {app}'**
  String systemStartApp(String app);

  /// No description provided for @systemStartAppPick.
  ///
  /// In de, this message translates to:
  /// **'Welche App beim Start?'**
  String get systemStartAppPick;

  /// No description provided for @systemStartAppMissing.
  ///
  /// In de, this message translates to:
  /// **'Die Start-App „{app}“ ist nicht installiert.'**
  String systemStartAppMissing(String app);

  /// No description provided for @systemSettingsAll.
  ///
  /// In de, this message translates to:
  /// **'Alle Einstellungen'**
  String get systemSettingsAll;

  /// No description provided for @systemTileSettings.
  ///
  /// In de, this message translates to:
  /// **'Einstellungen (TV)'**
  String get systemTileSettings;

  /// No description provided for @systemTileSettingsShort.
  ///
  /// In de, this message translates to:
  /// **'Einstellungen'**
  String get systemTileSettingsShort;

  /// No description provided for @systemSettingsTitleSystem.
  ///
  /// In de, this message translates to:
  /// **'System-Einstellungen'**
  String get systemSettingsTitleSystem;

  /// No description provided for @systemSettingsTitleRadio.
  ///
  /// In de, this message translates to:
  /// **'Radio-Einstellungen'**
  String get systemSettingsTitleRadio;

  /// No description provided for @systemSettingsTitleTv.
  ///
  /// In de, this message translates to:
  /// **'TV-Einstellungen'**
  String get systemSettingsTitleTv;

  /// No description provided for @tvLinkConnecting.
  ///
  /// In de, this message translates to:
  /// **'Verbinde mit dem Receiver…'**
  String get tvLinkConnecting;

  /// No description provided for @tvLinkZapping.
  ///
  /// In de, this message translates to:
  /// **'{reason} - Receiver schaltet um…'**
  String tvLinkZapping(String reason);

  /// No description provided for @tvReasonEncrypted.
  ///
  /// In de, this message translates to:
  /// **'Verschlüsselt'**
  String get tvReasonEncrypted;

  /// No description provided for @tvReasonNoFreeTuner.
  ///
  /// In de, this message translates to:
  /// **'Kein freier Tuner'**
  String get tvReasonNoFreeTuner;

  /// No description provided for @tvLinkLoadingPicture.
  ///
  /// In de, this message translates to:
  /// **'Bild wird geladen…'**
  String get tvLinkLoadingPicture;

  /// No description provided for @tvLinkDescrambling.
  ///
  /// In de, this message translates to:
  /// **'Verschlüsselt - Receiver entschlüsselt…'**
  String get tvLinkDescrambling;

  /// No description provided for @tvLinkPlaying.
  ///
  /// In de, this message translates to:
  /// **'Sender läuft'**
  String get tvLinkPlaying;

  /// No description provided for @tvErrorEncryptedReceiverBusy.
  ///
  /// In de, this message translates to:
  /// **'„{channel}“ ist verschlüsselt und der Receiver zeigt selbst einen anderen Sender - Einstellungen → TV → „Receiver bei Bedarf umschalten“.'**
  String tvErrorEncryptedReceiverBusy(String channel);

  /// No description provided for @tvErrorStillEncrypted.
  ///
  /// In de, this message translates to:
  /// **'„{channel}“ bleibt verschlüsselt - Karte bzw. CI-Modul für diesen Sender freigeschaltet?'**
  String tvErrorStillEncrypted(String channel);

  /// No description provided for @tvErrorNoTunerCableBusy.
  ///
  /// In de, this message translates to:
  /// **'Kein freier Tuner für „{channel}“ - das Sat-Kabel ist gerade auf einem anderen Band belegt (Aufnahme oder ein anderes Gerät).'**
  String tvErrorNoTunerCableBusy(String channel);

  /// No description provided for @tvErrorNoTunerReceiverBusy.
  ///
  /// In de, this message translates to:
  /// **'Kein freier Tuner für „{channel}“ - der Receiver zeigt selbst einen Sender auf einem anderen Band (Einstellungen → TV → „Receiver bei Bedarf umschalten“).'**
  String tvErrorNoTunerReceiverBusy(String channel);

  /// No description provided for @tvErrorNoPicture.
  ///
  /// In de, this message translates to:
  /// **'Kein Bild von „{channel}“ - ist der Receiver an und ein Tuner frei?'**
  String tvErrorNoPicture(String channel);

  /// No description provided for @tvPaused.
  ///
  /// In de, this message translates to:
  /// **'Angehalten - ⏯ spielt weiter'**
  String get tvPaused;

  /// No description provided for @tvAudioTrack.
  ///
  /// In de, this message translates to:
  /// **'Tonspur'**
  String get tvAudioTrack;

  /// No description provided for @tvAudioTrackNumber.
  ///
  /// In de, this message translates to:
  /// **'Tonspur {number}'**
  String tvAudioTrackNumber(int number);

  /// No description provided for @tvAudioTrackCount.
  ///
  /// In de, this message translates to:
  /// **'{count} Tonspuren'**
  String tvAudioTrackCount(int count);

  /// Number of sound channels of an audio track (not 1, 2, 6 or 8).
  ///
  /// In de, this message translates to:
  /// **'{count} Kanäle'**
  String tvAudioChannels(int count);

  /// No description provided for @tvAudioLanguageGerman.
  ///
  /// In de, this message translates to:
  /// **'Deutsch'**
  String get tvAudioLanguageGerman;

  /// No description provided for @tvAudioLanguageEnglish.
  ///
  /// In de, this message translates to:
  /// **'Englisch'**
  String get tvAudioLanguageEnglish;

  /// No description provided for @tvAudioLanguageFrench.
  ///
  /// In de, this message translates to:
  /// **'Französisch'**
  String get tvAudioLanguageFrench;

  /// No description provided for @tvAudioLanguageItalian.
  ///
  /// In de, this message translates to:
  /// **'Italienisch'**
  String get tvAudioLanguageItalian;

  /// No description provided for @tvAudioLanguageSpanish.
  ///
  /// In de, this message translates to:
  /// **'Spanisch'**
  String get tvAudioLanguageSpanish;

  /// No description provided for @tvAudioLanguageTurkish.
  ///
  /// In de, this message translates to:
  /// **'Türkisch'**
  String get tvAudioLanguageTurkish;

  /// No description provided for @tvAudioLanguagePolish.
  ///
  /// In de, this message translates to:
  /// **'Polnisch'**
  String get tvAudioLanguagePolish;

  /// No description provided for @tvAudioLanguageCroatianSerbian.
  ///
  /// In de, this message translates to:
  /// **'Kroatisch/Serbisch'**
  String get tvAudioLanguageCroatianSerbian;

  /// No description provided for @tvAudioOriginal.
  ///
  /// In de, this message translates to:
  /// **'Originalton'**
  String get tvAudioOriginal;

  /// No description provided for @tvAudioDescription.
  ///
  /// In de, this message translates to:
  /// **'Audiodeskription'**
  String get tvAudioDescription;

  /// No description provided for @tvResolutionLines.
  ///
  /// In de, this message translates to:
  /// **'{lines} Zeilen'**
  String tvResolutionLines(int lines);

  /// No description provided for @tvTranscoded.
  ///
  /// In de, this message translates to:
  /// **'Transkodiert'**
  String get tvTranscoded;

  /// No description provided for @tvOriginalStream.
  ///
  /// In de, this message translates to:
  /// **'Original'**
  String get tvOriginalStream;

  /// No description provided for @tvGuide.
  ///
  /// In de, this message translates to:
  /// **'Programmführer'**
  String get tvGuide;

  /// No description provided for @tvAllProgramsOf.
  ///
  /// In de, this message translates to:
  /// **'Alle Sendungen von {channel}'**
  String tvAllProgramsOf(String channel);

  /// No description provided for @tvAllProgramsOfThisChannel.
  ///
  /// In de, this message translates to:
  /// **'Alle Sendungen von diesem Sender'**
  String get tvAllProgramsOfThisChannel;

  /// No description provided for @tvNextUpNow.
  ///
  /// In de, this message translates to:
  /// **'Als Nächstes · gleich'**
  String get tvNextUpNow;

  /// No description provided for @tvNextUpInMinutes.
  ///
  /// In de, this message translates to:
  /// **'Als Nächstes · in {minutes} Min.'**
  String tvNextUpInMinutes(int minutes);

  /// No description provided for @tvNotSetUpIntro.
  ///
  /// In de, this message translates to:
  /// **'Fernsehen vom eigenen Sat-Receiver: Senderlisten, Senderlogos und Programmführer kommen direkt vom Enigma2-Receiver (z. B. GigaBlue, VU+, Dreambox mit OpenWebif) im Heimnetz.'**
  String get tvNotSetUpIntro;

  /// No description provided for @tvSetUpReceiver.
  ///
  /// In de, this message translates to:
  /// **'Receiver einrichten'**
  String get tvSetUpReceiver;

  /// Key hint in the info banner; the placeholders are the names of the assigned remote keys.
  ///
  /// In de, this message translates to:
  /// **'{channelListKey} Senderliste  ·  {guideKey} Programm  ·  {optionsKey} Optionen'**
  String tvBannerKeyHint(
    String channelListKey,
    String guideKey,
    String optionsKey,
  );

  /// No description provided for @tvNoProgramInfo.
  ///
  /// In de, this message translates to:
  /// **'Keine Programminformation'**
  String get tvNoProgramInfo;

  /// No description provided for @tvNoProgramInfoSentence.
  ///
  /// In de, this message translates to:
  /// **'Keine Programminformation.'**
  String get tvNoProgramInfoSentence;

  /// Before the start time and title of the programme after the current one.
  ///
  /// In de, this message translates to:
  /// **'Danach'**
  String get tvThen;

  /// No description provided for @tvChannelListKeyHint.
  ///
  /// In de, this message translates to:
  /// **'OK abspielen (laufender Sender: Info)  ·  → Programm  ·  ← schließen'**
  String get tvChannelListKeyHint;

  /// No description provided for @tvNoChannelsInList.
  ///
  /// In de, this message translates to:
  /// **'Keine Sender in dieser Liste'**
  String get tvNoChannelsInList;

  /// No description provided for @tvChannelList.
  ///
  /// In de, this message translates to:
  /// **'Senderliste'**
  String get tvChannelList;

  /// No description provided for @tvBouquetFavorites.
  ///
  /// In de, this message translates to:
  /// **'Favoriten'**
  String get tvBouquetFavorites;

  /// No description provided for @tvBouquetLastScanned.
  ///
  /// In de, this message translates to:
  /// **'Zuletzt gescannt'**
  String get tvBouquetLastScanned;

  /// Length of a programme.
  ///
  /// In de, this message translates to:
  /// **'{minutes} Min.'**
  String tvMinutes(int minutes);

  /// No description provided for @tvNoDescription.
  ///
  /// In de, this message translates to:
  /// **'Keine Beschreibung.'**
  String get tvNoDescription;

  /// No description provided for @tvToday.
  ///
  /// In de, this message translates to:
  /// **'Heute'**
  String get tvToday;

  /// No description provided for @tvTomorrow.
  ///
  /// In de, this message translates to:
  /// **'Morgen'**
  String get tvTomorrow;

  /// intl DateFormat pattern for a short date without the year (day and month).
  ///
  /// In de, this message translates to:
  /// **'dd.MM.'**
  String get tvDayMonthPattern;

  /// Heading of one channel's list of programmes (usually a week).
  ///
  /// In de, this message translates to:
  /// **'Programm'**
  String get tvSchedule;

  /// No description provided for @tvScheduleNoInfo.
  ///
  /// In de, this message translates to:
  /// **'Für diesen Sender hat der Receiver keine Programminformation.'**
  String get tvScheduleNoInfo;

  /// No description provided for @tvGuideKeyHint.
  ///
  /// In de, this message translates to:
  /// **'OK umschalten  ·  {optionsKey} alle Sendungen  ·  ‹‹ ›› ±3 Std.'**
  String tvGuideKeyHint(String optionsKey);

  /// No description provided for @tvSettingsTitle.
  ///
  /// In de, this message translates to:
  /// **'TV: Receiver'**
  String get tvSettingsTitle;

  /// No description provided for @tvSettingsIntro.
  ///
  /// In de, this message translates to:
  /// **'Ein Enigma2-Sat-Receiver mit OpenWebif im Heimnetz (z. B. GigaBlue, VU+, Dreambox mit teamBlue, OpenATV oder OpenPLi). Senderlisten, Senderlogos (Picons) und der Programmführer kommen vom Receiver, das Bild über seinen Streaming-Port.'**
  String get tvSettingsIntro;

  /// No description provided for @tvSettingsAddress.
  ///
  /// In de, this message translates to:
  /// **'Adresse des Receivers (IP oder Name)'**
  String get tvSettingsAddress;

  /// No description provided for @tvSettingsWebPort.
  ///
  /// In de, this message translates to:
  /// **'Web-Port (OpenWebif)'**
  String get tvSettingsWebPort;

  /// No description provided for @tvSettingsStreamPort.
  ///
  /// In de, this message translates to:
  /// **'Streaming-Port'**
  String get tvSettingsStreamPort;

  /// No description provided for @tvSettingsPortsHelp.
  ///
  /// In de, this message translates to:
  /// **'Üblich: Web 80, Streaming 8001 (8002 = umgewandelt, falls der Receiver das kann).'**
  String get tvSettingsPortsHelp;

  /// No description provided for @tvSettingsHttps.
  ///
  /// In de, this message translates to:
  /// **'HTTPS für die Weboberfläche'**
  String get tvSettingsHttps;

  /// No description provided for @tvSettingsUser.
  ///
  /// In de, this message translates to:
  /// **'Benutzer (falls Anmeldung aktiv)'**
  String get tvSettingsUser;

  /// No description provided for @tvSettingsPassword.
  ///
  /// In de, this message translates to:
  /// **'Passwort'**
  String get tvSettingsPassword;

  /// No description provided for @tvSettingsTestConnection.
  ///
  /// In de, this message translates to:
  /// **'Verbindung testen'**
  String get tvSettingsTestConnection;

  /// No description provided for @tvSettingsEnterAddress.
  ///
  /// In de, this message translates to:
  /// **'Bitte die Adresse des Receivers eintragen.'**
  String get tvSettingsEnterAddress;

  /// No description provided for @tvSettingsConnected.
  ///
  /// In de, this message translates to:
  /// **'Verbunden: {receiver} · {count} Senderlisten'**
  String tvSettingsConnected(String receiver, int count);

  /// No description provided for @tvSettingsChannelList.
  ///
  /// In de, this message translates to:
  /// **'Senderliste für TV'**
  String get tvSettingsChannelList;

  /// No description provided for @tvSettingsChannelListHelp.
  ///
  /// In de, this message translates to:
  /// **'Im TV wechseln ← / → in der Senderliste zwischen den Listen.'**
  String get tvSettingsChannelListHelp;

  /// No description provided for @tvEnigma2Receiver.
  ///
  /// In de, this message translates to:
  /// **'Enigma2-Receiver'**
  String get tvEnigma2Receiver;

  /// No description provided for @tvReceiverNeedsLogin.
  ///
  /// In de, this message translates to:
  /// **'Enigma2-Receiver (Anmeldung nötig)'**
  String get tvReceiverNeedsLogin;

  /// No description provided for @tvSearchReceiver.
  ///
  /// In de, this message translates to:
  /// **'Receiver suchen'**
  String get tvSearchReceiver;

  /// No description provided for @tvSearchScanning.
  ///
  /// In de, this message translates to:
  /// **'Durchsuche das Heimnetz …'**
  String get tvSearchScanning;

  /// No description provided for @tvSearchScanningNetworks.
  ///
  /// In de, this message translates to:
  /// **'Durchsuche das Heimnetz ({networks}) …'**
  String tvSearchScanningNetworks(String networks);

  /// No description provided for @tvSearchNoneFound.
  ///
  /// In de, this message translates to:
  /// **'Kein Receiver gefunden. Ist er eingeschaltet und im selben Netz? Sonst die Adresse bitte von Hand eintragen.'**
  String get tvSearchNoneFound;

  /// No description provided for @tvSearchFound.
  ///
  /// In de, this message translates to:
  /// **'{count, plural, =1{Ein Receiver gefunden - OK übernimmt ihn.} other{{count} Receiver gefunden - OK übernimmt ihn.}}'**
  String tvSearchFound(int count);

  /// No description provided for @tvErrorNoReceiver.
  ///
  /// In de, this message translates to:
  /// **'Kein Receiver eingerichtet'**
  String get tvErrorNoReceiver;

  /// No description provided for @tvErrorUnreachable.
  ///
  /// In de, this message translates to:
  /// **'Receiver nicht erreichbar ({host}): {error}'**
  String tvErrorUnreachable(String host, String error);

  /// No description provided for @tvErrorLoginRejected.
  ///
  /// In de, this message translates to:
  /// **'Anmeldung abgelehnt - Benutzer/Passwort prüfen'**
  String get tvErrorLoginRejected;

  /// No description provided for @tvErrorHttpStatus.
  ///
  /// In de, this message translates to:
  /// **'Receiver antwortet mit Fehler {status}'**
  String tvErrorHttpStatus(String status);

  /// No description provided for @tvErrorUnexpectedResponse.
  ///
  /// In de, this message translates to:
  /// **'Unerwartete Antwort vom Receiver'**
  String get tvErrorUnexpectedResponse;

  /// No description provided for @tvErrorZapFailed.
  ///
  /// In de, this message translates to:
  /// **'Receiver schaltet nicht um: {message}'**
  String tvErrorZapFailed(String message);

  /// No description provided for @tvSettingsButton.
  ///
  /// In de, this message translates to:
  /// **'TV-Einstellungen'**
  String get tvSettingsButton;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['de', 'en'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'de':
      return AppLocalizationsDe();
    case 'en':
      return AppLocalizationsEn();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
