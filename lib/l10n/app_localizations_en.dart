// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get adminSubtitle => 'Managing this device in the home network';

  @override
  String get adminHostname => 'Host name';

  @override
  String get adminIpAddress => 'IP address';

  @override
  String get adminNotFound => 'Not found';

  @override
  String get adminSaved => 'Saved';

  @override
  String get adminOffline => 'No connection to the device.';

  @override
  String get adminInvalidValue => 'Invalid value.';

  @override
  String get adminUnknownSetting => 'This setting isn\'t available here.';

  @override
  String get adminSecretPlaceholder => 'unchanged';

  @override
  String get adminSecretHelp => 'Never shown - only enter a new one.';

  @override
  String get adminBackupHeading => 'Backup';

  @override
  String get adminBackupHelp =>
      'Contains favorites, channel lists and all settings - including passwords. Keep it safe.';

  @override
  String get adminBackupDownload => 'Create & download backup';

  @override
  String get adminRestoreHeading => 'Restore a backup';

  @override
  String get adminRestoreHow =>
      'To restore, open Settings → System → Restore backup on the device (or choose \"Restore backup\" in the setup wizard). The upload then appears here.';

  @override
  String get adminRestoring => 'Restoring …';

  @override
  String get adminRestoreLocked =>
      'Restoring isn\'t enabled right now - open \"Restore backup\" on the device.';

  @override
  String get adminFileTooBig => 'The file is too big for a backup.';

  @override
  String get adminFileInvalid => 'The file isn\'t a valid backup.';

  @override
  String get adminRestored => 'Backup restored - Home System restarts.';

  @override
  String get adminDisplayHeading => 'Display (Smart Home)';

  @override
  String get adminDisplayHelp =>
      'Switches the device\'s display - Home Assistant can do the same with a POST to /api/display/on, /api/display/off and /api/dashboard/reload.';

  @override
  String get adminDisplayOn => 'Display on';

  @override
  String get adminDisplayOff => 'Display off';

  @override
  String get adminDashboardReload => 'Reload dashboard';

  @override
  String get adminDeviceName => 'Device name';

  @override
  String get adminPartRadio => 'Radio switched on';

  @override
  String get adminPartTv => 'TV switched on';

  @override
  String get adminPartDashboard => 'Smart Home switched on';

  @override
  String get adminStartScreen => 'When the app starts';

  @override
  String get adminStartScreenApp => 'Start app';

  @override
  String get adminStartApp => 'Start app';

  @override
  String get adminStartAppFirst => 'Choose a start app first.';

  @override
  String get adminUiScale => 'Interface size (%)';

  @override
  String get adminClockDate => 'Date next to the time';

  @override
  String get adminWeather => 'Weather tile';

  @override
  String get adminRadar => 'Rain radar tile';

  @override
  String get adminSun => 'Sun & moon tile';

  @override
  String get adminTvHost => 'Receiver: address (IP or name)';

  @override
  String get adminTvWebPort => 'Receiver: web port';

  @override
  String get adminTvStreamPort => 'Receiver: streaming port';

  @override
  String get adminTvHttps => 'Receiver: HTTPS';

  @override
  String get adminTvUser => 'Receiver: user';

  @override
  String get adminTvPassword => 'Receiver: password';

  @override
  String get adminTvNextUp => '\"Up next\" note';

  @override
  String get adminMotionTimeout => 'Display off after (minutes)';

  @override
  String get adminMotionTimeoutHelp => '0 = never';

  @override
  String get adminCameraOnDevice =>
      'Camera access has to be allowed once on the device: Settings → Smart Home.';

  @override
  String get adminNasProtocol => 'Protocol';

  @override
  String get adminNasFoldersHint =>
      '“Browse” picks a folder on the NAS - as on the device.';

  @override
  String get adminBrowse => 'Browse…';

  @override
  String get adminNasBackupHeading => 'Backup to the NAS';

  @override
  String get adminNasBackupNow => 'Put a backup into the backup folder now';

  @override
  String get adminNasBackupNoFolder =>
      'Choose a backup folder under “Folders” first.';

  @override
  String adminNasBackupDone(String name) {
    return 'Backup saved on the NAS: $name';
  }

  @override
  String get adminUpdateCheck => 'Look for updates';

  @override
  String get adminUpdateInstall => 'Install update';

  @override
  String get adminUpdateInstallHelp =>
      'Downloads the new version to the device; then Android asks for confirmation on the device (OK on the remote).';

  @override
  String adminUpdateStarted(String version) {
    return 'Downloading version $version - confirm on the device in a moment.';
  }

  @override
  String get adminBack => 'Back';

  @override
  String get adminClose => 'Close';

  @override
  String get adminDeviceOnly =>
      'Only on the device itself: tuner and receiver search, station lists, Home key, permissions, backgrounds and icon packs.';

  @override
  String get adminRestoreOpenBanner =>
      '“Restore backup” is open on the device - upload the file here ›';

  @override
  String get adminMovieFoldersHint =>
      'Each folder is a place of its own in Movies, in this order. “Browse” picks another folder, × removes it from the list.';

  @override
  String get adminMovieFolderName => 'Name in Movies';

  @override
  String get adminMovieFolderNameHelp => 'Empty: the folder\'s name';

  @override
  String get adminMovieFolderPosition => 'Place in the list';

  @override
  String get adminMovieFolderAdd => 'Add a movie folder';

  @override
  String get adminMovieFolderAddHelp =>
      'It\'s named after the folder - change it above.';

  @override
  String get backupAreaSystem => 'System settings';

  @override
  String get backupAreaSystemHint =>
      'Start option, display, language, parts on/off, launcher tiles, remote control buttons, updates';

  @override
  String get backupAreaTv => 'TV settings';

  @override
  String get backupAreaTvHint =>
      'Receiver with login, internet TV, channel lists, reminders, “Up next”';

  @override
  String get backupAreaRadio => 'Radio settings';

  @override
  String get backupAreaRadioHint =>
      'Favourites, DAB+ and FM stations, start station';

  @override
  String backupAreaRadioCounts(int favorites, int dab, int fm) {
    return '$favorites favourites, $dab DAB+ stations, $fm FM stations';
  }

  @override
  String get backupAreaMusic => 'Music';

  @override
  String get backupAreaMusicHint => 'Shuffle, repeat, visualizer, subfolders';

  @override
  String get backupAreaMedia => 'Movies/Pictures';

  @override
  String get backupAreaMediaHint =>
      'Slideshow and the settings for movies and pictures';

  @override
  String get backupAreaNas => 'NAS';

  @override
  String get backupAreaNasHint =>
      'Server, login with password and the chosen folders';

  @override
  String get backupAreaDashboard => 'Home control/Dashboard';

  @override
  String get backupAreaDashboardHint =>
      'Dashboard address, display by motion, brightness';

  @override
  String get backupAreaHa => 'Home Assistant';

  @override
  String get backupAreaHaHint =>
      'MQTT connection and login with password, camera sharing';

  @override
  String get backupAreaSdr => 'Radio scanner/SDR';

  @override
  String get backupAreaSdrHint =>
      'rtl_tcp servers, listening bands, aircraft, sensors';

  @override
  String get backupAreaWeather => 'Weather/Background';

  @override
  String get backupAreaWeatherHint =>
      'Weather, rain radar, sun & moon, background pictures';

  @override
  String get backupAreaBrowser => 'Web browser';

  @override
  String get backupAreaBrowserHint =>
      'Home page, bookmarks, search engine, ad blocker';

  @override
  String get backupAreaOther => 'Other';

  @override
  String get backupAreaOtherHint =>
      'Further settings that belong to none of the areas';

  @override
  String get backupSelectTitle => 'What should be restored?';

  @override
  String get backupSelectHint =>
      'Only the ticked areas are replaced by those from the backup - everything else stays as it is. Home System restarts afterwards.';

  @override
  String backupSelectCreated(String date) {
    return 'Created: $date';
  }

  @override
  String get backupSelectAreas => 'Areas';

  @override
  String backupDeviceNameHelp(String name) {
    return 'This device is currently called “$name” - leave empty to keep the name.';
  }

  @override
  String get backupDeviceNameHelpNone =>
      'Leave empty to keep the current name.';

  @override
  String get backupApply => 'Apply';

  @override
  String get backupNothingSelected =>
      'Nothing selected - tick at least one area or enter a device name.';

  @override
  String get backupNothingInside => 'The backup contains no settings.';

  @override
  String get backupExpired =>
      'The backup is no longer loaded - please choose it again.';

  @override
  String get backupReading => 'Reading …';

  @override
  String get backupPickedFile => 'Selected file';

  @override
  String get backupAdminOpen => 'Open backup';

  @override
  String get backupAdminReady =>
      'The device is ready. Choose a backup file or a backup from the NAS - before restoring you can choose what is taken over.';

  @override
  String get browserTitle => 'Browser';

  @override
  String get browserAndroidOnly =>
      'The browser is only available on Android (TV box, tablet, phone).';

  @override
  String get browserAddress => 'Address or search';

  @override
  String get browserAddressHint => 'e.g. bbc.com or a search term';

  @override
  String get browserBack => 'Back';

  @override
  String get browserForward => 'Forward';

  @override
  String get browserReload => 'Reload';

  @override
  String get browserHome => 'Home page';

  @override
  String get browserBookmarks => 'Bookmarks';

  @override
  String get browserBookmarkAdd => 'Add bookmark';

  @override
  String get browserBookmarkRemove => 'Remove bookmark';

  @override
  String get browserBookmarksEmpty =>
      'No bookmarks yet - add one with the star in a page\'s menu.';

  @override
  String browserBlockedCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count blocked',
      one: '1 blocked',
      zero: 'nothing blocked',
    );
    return '$_temp0';
  }

  @override
  String get browserBlockerSiteOn => 'Ad blocker on for this site';

  @override
  String get browserBlockerSiteOff => 'Ad blocker off for this site';

  @override
  String get browserBlockerOff => 'Ad blocker off';

  @override
  String get browserDesktop => 'Desktop view';

  @override
  String browserTextSize(int percent) {
    return 'Text size $percent %';
  }

  @override
  String get browserSmaller => 'Smaller';

  @override
  String get browserLarger => 'Larger';

  @override
  String get browserSettings => 'Settings';

  @override
  String get browserClose => 'Close browser';

  @override
  String get browserLeaveTitle => 'Close the browser?';

  @override
  String get browserLeave => 'Close';

  @override
  String get browserStay => 'Stay';

  @override
  String get browserEnterText => 'Enter text';

  @override
  String get browserTextInsert => 'Insert';

  @override
  String get browserTextSend => 'Send';

  @override
  String get browserNoField =>
      'No text field selected - click into one with OK first.';

  @override
  String get browserFieldHint =>
      'Text field: OK shows the keyboard, menu key: enter text, Back: done';

  @override
  String get browserPointerHint =>
      'The D-pad moves the pointer, OK clicks, at the edge the page scrolls. Menu key: address, bookmarks, ad blocker.';

  @override
  String get browserDownloadUnsupported =>
      'Downloads aren\'t supported in the browser.';

  @override
  String get browserSettingsTitle => 'Browser settings';

  @override
  String get browserAreaSubtitle => 'Ad blocker, search engine, home page';

  @override
  String get browserBlocker => 'Ad and tracker blocker';

  @override
  String get browserBlockerHelp =>
      'Blocks ads and trackers with the filter lists of uBlock Origin and EasyList - YouTube\'s ads too, as far as possible. Can be switched off per site in the page\'s menu.';

  @override
  String get browserFilterLists => 'Filter lists';

  @override
  String browserListSource(String license, String homepage) {
    return 'License $license - $homepage';
  }

  @override
  String browserListsUpdated(String date, int rules) {
    return 'Updated $date, $rules rules';
  }

  @override
  String get browserListsNever => 'Not loaded yet';

  @override
  String get browserListsUpdating => 'Loading the filter lists …';

  @override
  String get browserListsUpdateNow => 'Update now';

  @override
  String browserListsFailed(String lists) {
    return 'Not loaded (older copy used): $lists';
  }

  @override
  String get browserListsError => 'The filter lists couldn\'t be loaded.';

  @override
  String get browserListsCredit =>
      'Filter lists: uBlock Origin uAssets (GPLv3), EasyList and EasyPrivacy (GPLv3 / CC BY-SA 3.0), Peter Lowe (McRae GPL). The anti-ad scripts (scriptlets) are our own implementation.';

  @override
  String get browserAllowlist => 'Sites without the ad blocker';

  @override
  String get browserAllowlistEmpty =>
      'None - can be switched off in a page\'s menu.';

  @override
  String get browserSearchEngine => 'Search engine';

  @override
  String get browserHomePage => 'Home page';

  @override
  String get browserHomePageDefault => 'The search engine\'s page';

  @override
  String get browserDesktopDefault => 'Open pages in desktop view';

  @override
  String get browserDesktopHelp =>
      'Pages as on a PC instead of the mobile version.';

  @override
  String get browserTextZoom => 'Text size';

  @override
  String get browserClearCookies => 'Delete cookies and logins';

  @override
  String get browserClearCookiesConfirm =>
      'Delete all of the browser\'s cookies and logins?';

  @override
  String get browserClearCache => 'Clear the cache';

  @override
  String get browserCleared => 'Deleted.';

  @override
  String get browserDelete => 'Delete';

  @override
  String get browserRemove => 'Remove';

  @override
  String browserWebView(String version) {
    return 'Browser engine: $version';
  }

  @override
  String get browserAdminPart => 'Browser switched on';

  @override
  String get commonOk => 'OK';

  @override
  String get commonCancel => 'Cancel';

  @override
  String get commonSave => 'Save';

  @override
  String get commonDelete => 'Delete';

  @override
  String get commonClose => 'Close';

  @override
  String get commonBack => 'Back';

  @override
  String get commonYes => 'Yes';

  @override
  String get commonNo => 'No';

  @override
  String get commonOn => 'On';

  @override
  String get commonOff => 'Off';

  @override
  String get commonEdit => 'Edit';

  @override
  String get commonRetry => 'Try again';

  @override
  String get commonLoading => 'Loading …';

  @override
  String commonError(String message) {
    return 'Error: $message';
  }

  @override
  String get commonLanguage => 'Language';

  @override
  String get commonLanguageSystem => 'Same as the device';

  @override
  String get commonLanguageGerman => 'Deutsch';

  @override
  String get commonLanguageEnglish => 'English';

  @override
  String get dashboardTitle => 'Smart Home';

  @override
  String get dashboardAndroidOnly =>
      'Smart Home is only available on Android (tablet, TV box).';

  @override
  String get dashboardNoAddress =>
      'No address for the Home Assistant dashboard yet.';

  @override
  String get dashboardOpenSettings => 'Open settings';

  @override
  String dashboardUnreachable(String url) {
    return '$url can\'t be reached - trying again in 15 seconds.';
  }

  @override
  String get dashboardSettingsTitle => 'Smart Home settings';

  @override
  String get dashboardAreaSubtitle =>
      'Home Assistant dashboard, display by motion';

  @override
  String get dashboardAddress => 'Dashboard address';

  @override
  String get dashboardAddressHint =>
      'http://homeassistant.local:8123/lovelace/0';

  @override
  String get dashboardAddressHelp =>
      'The dashboard\'s page in Home Assistant. The login is kept. Add \"?kiosk\" (integration \"kiosk-mode\") to hide the header and sidebar.';

  @override
  String get dashboardNotSet => 'not set';

  @override
  String get dashboardDisplayHeading => 'Display by motion';

  @override
  String get dashboardMotion => 'Switch the display on and off with the camera';

  @override
  String get dashboardMotionHelp =>
      'The camera notices motion in front of the device: the display comes on and shows Smart Home. When nobody has been around for a while it goes off. No pictures are stored or sent.';

  @override
  String get dashboardNoCamera => 'This device has no camera.';

  @override
  String get dashboardCameraDenied =>
      'This doesn\'t work without access to the camera.';

  @override
  String get dashboardNoAccessibility =>
      'To switch the display off, Home System needs the accessibility service \"Home System: Home key\" (Android 9 or newer).';

  @override
  String get dashboardSensitivity => 'Sensitivity';

  @override
  String dashboardSensitivityValue(int value) {
    return '$value of 10';
  }

  @override
  String get dashboardTimeout => 'Display off after';

  @override
  String dashboardTimeoutMinutes(int minutes) {
    String _temp0 = intl.Intl.pluralLogic(
      minutes,
      locale: localeName,
      other: '$minutes minutes',
      one: '1 minute',
    );
    return '$_temp0';
  }

  @override
  String get dashboardTimeoutNever => 'never';

  @override
  String dashboardLevel(int percent) {
    return 'Motion now: $percent %';
  }

  @override
  String get dashboardLevelMotion => 'Motion detected';

  @override
  String get dashboardHaHeading => 'Home Assistant';

  @override
  String get dashboardWebhook => 'Webhook for motion';

  @override
  String get dashboardWebhookHint =>
      'http://homeassistant.local:8123/api/webhook/hallway-tablet';

  @override
  String get dashboardWebhookHelp =>
      'On motion Home System sends \"motion\": true, after a minute without motion \"motion\": false - a trigger for automations (trigger \"Webhook\"). Simpler: System → Home Assistant - then the device with its motion sensor and switches is in Home Assistant directly.';

  @override
  String dashboardRemoteHelp(String url) {
    return 'Home Assistant can switch the display and reload the dashboard: $url/api/display/on, …/off, …/api/dashboard/reload (POST, e.g. with rest_command).';
  }

  @override
  String get dashboardTestOff => 'Switch the display off now (test)';

  @override
  String get dashboardDimOnly =>
      'Only darken the display instead of switching it off';

  @override
  String get dashboardDimOnlyHelp =>
      'The display only goes black and fully dark, the backlight stays on. Only needed when really switching off doesn\'t work - that goes through the accessibility service \"Home System: Home key\", and a lock screen without PIN is swiped away when the display comes back.';

  @override
  String get dashboardBrightnessHeading => 'Brightness';

  @override
  String get dashboardBrightnessSystem => 'As set in the system';

  @override
  String get dashboardBrightnessFixed => 'Fixed brightness';

  @override
  String get dashboardBrightnessAdaptive => 'Adaptive (light sensor)';

  @override
  String get dashboardBrightnessLevel => 'Brightness';

  @override
  String get dashboardBrightnessMin => 'In the dark';

  @override
  String get dashboardBrightnessMax => 'In a bright room';

  @override
  String get dashboardBrightnessLuxForMax => 'Full brightness from';

  @override
  String get dashboardBrightnessHelp =>
      'The light sensor sits behind the glass and often reads low: set \"Full brightness from\" to what it shows in a bright room (see below).';

  @override
  String dashboardBrightnessLux(String lux) {
    return 'Light sensor now: $lux lx';
  }

  @override
  String get dashboardBrightnessNoSensor => 'This device has no light sensor.';

  @override
  String get dashboardPopupHeading => 'Playback popup';

  @override
  String get dashboardPopupShow => 'Show playback popup';

  @override
  String get dashboardPopupHelp =>
      'Radio and music keep playing in the home control. The slim popup over the dashboard always has a Home button and, while something plays, shows the station or track with previous, pause, stop and next. Remote: the arrow towards the popup at the dashboard\'s edge or the Info key, back with the opposite arrow or Back. The remote\'s play/pause, stop, next and previous keys always work.';

  @override
  String get dashboardPopupPosition => 'Position';

  @override
  String get dashboardPopupBottomCenter => 'Bottom centre';

  @override
  String get dashboardPopupBottomLeft => 'Bottom left';

  @override
  String get dashboardPopupBottomRight => 'Bottom right';

  @override
  String get dashboardPopupTopCenter => 'Top centre';

  @override
  String get dashboardPopupTopLeft => 'Top left';

  @override
  String get dashboardPopupTopRight => 'Top right';

  @override
  String get dashboardPopupHome => 'Home';

  @override
  String get dashboardPopupPlay => 'Play';

  @override
  String get dashboardPopupPause => 'Pause';

  @override
  String get dashboardPopupStop => 'Stop';

  @override
  String get dashboardPopupNext => 'Next';

  @override
  String get dashboardPopupPrevious => 'Previous';

  @override
  String get dashboardPopupHintBottom =>
      'Remote: ▼ at the bottom edge or Info selects this bar, ▲ or Back returns to the dashboard.';

  @override
  String get dashboardPopupHintTop =>
      'Remote: ▲ at the top edge or Info selects this bar, ▼ or Back returns to the dashboard.';

  @override
  String get haTitle => 'Home Assistant';

  @override
  String get haIntro =>
      'Adds this device to Home Assistant as a device of its own - with its device name, switches (screen, motion detection, brightness), buttons, messages, text to speech, sensors (motion, battery, light) and playback (title, play/pause, next, station, volume, open Radio/TV/Music). Home Assistant only needs the MQTT integration with the Mosquitto add-on, no YAML. Switched off, the device disappears there again.';

  @override
  String get haEnabled => 'Connect to Home Assistant';

  @override
  String get haHost => 'MQTT broker (empty = the Smart Home address)';

  @override
  String haPort(int port) {
    return 'Port (empty = $port)';
  }

  @override
  String get haUser => 'Home Assistant user';

  @override
  String get haLoginHint =>
      'Used for both: the Smart Home dashboard logs in with it by itself, and the Mosquitto add-on accepts Home Assistant users for MQTT too. Best create a user of its own (Settings → People → Users, e.g. “homesystem”, without two-factor).';

  @override
  String get haEntitiesHint =>
      'The device then shows up in Home Assistant under Settings → Devices & services → MQTT with its device name.';

  @override
  String get haStatusOff => 'Off';

  @override
  String get haStatusConnecting => 'Connecting…';

  @override
  String haStatusConnected(String name) {
    return 'Connected - in Home Assistant as “$name”';
  }

  @override
  String get haStatusNoHost =>
      'No address: enter the MQTT broker here or the Home Assistant address under Smart Home.';

  @override
  String get haErrorLogin => 'Login refused - check user name and password.';

  @override
  String get haErrorUnreachable =>
      'Broker not reachable - is the Mosquitto add-on running? Trying again in 30 seconds.';

  @override
  String haErrorOther(String message) {
    return 'No connection: $message';
  }

  @override
  String get haScreen => 'Screen';

  @override
  String get haMotionDetection => 'Motion detection';

  @override
  String get haBrightnessMode => 'Brightness mode';

  @override
  String get haBrightness => 'Screen brightness';

  @override
  String get haScreenOffTimer => 'Screen off after';

  @override
  String get haReloadDashboard => 'Reload dashboard';

  @override
  String get haBringToFront => 'Bring to front';

  @override
  String get haSpeak => 'Text to speech';

  @override
  String get haMessage => 'On-screen message';

  @override
  String get haMotion => 'Motion';

  @override
  String get haBattery => 'Battery';

  @override
  String get haPlugged => 'Plugged in';

  @override
  String get haBatteryTemperature => 'Battery temperature';

  @override
  String get haLight => 'Ambient light';

  @override
  String get haForeground => 'Home System in front';

  @override
  String get haFreeMemory => 'Free memory';

  @override
  String get haFreeStorage => 'Free storage';

  @override
  String get haIpAddress => 'IP address';

  @override
  String get haVersion => 'App version';

  @override
  String get haCamera => 'Camera';

  @override
  String get haShareCamera => 'Share the camera with Home Assistant';

  @override
  String get haShareCameraHelp =>
      'A picture every 2 seconds as a camera entity in Home Assistant - only while motion detection runs (Smart Home).';

  @override
  String get haLoginSection => 'Home Assistant login';

  @override
  String get haPlayback => 'Playback';

  @override
  String get haPlaybackPlaying => 'Playing';

  @override
  String get haPlaybackPaused => 'Paused';

  @override
  String get haPlaybackIdle => 'Off';

  @override
  String get haMediaTitle => 'Title';

  @override
  String get haMediaArtist => 'Artist / programme';

  @override
  String get haMediaSource => 'Source';

  @override
  String get haPlayPause => 'Play/pause';

  @override
  String get haStop => 'Stop';

  @override
  String get haNext => 'Next';

  @override
  String get haPrevious => 'Previous';

  @override
  String get haStation => 'Station';

  @override
  String get haVolume => 'Volume';

  @override
  String get haOpenHome => 'Open Home';

  @override
  String get haOpenRadio => 'Open Radio';

  @override
  String get haOpenTv => 'Open TV';

  @override
  String get haOpenMusic => 'Open Music';

  @override
  String get haOpenDashboard => 'Open Smart Home';

  @override
  String get haHostHelp =>
      'Only the IP or name of the machine with the Mosquitto add-on, e.g. 192.168.1.5 - not the Home Assistant page address with :8123.';

  @override
  String get haLaunchApp => 'Start app';

  @override
  String get iptvListName => 'Internet TV';

  @override
  String get iptvBrowse => 'Find channels';

  @override
  String get iptvBrowseTitle => 'Internet TV – find channels';

  @override
  String get iptvSearchName => 'Channel name';

  @override
  String get iptvCountry => 'Country';

  @override
  String iptvMyCountries(String countries) {
    return 'My countries ($countries)';
  }

  @override
  String get iptvAllCountries => 'All countries';

  @override
  String get iptvCategory => 'Category';

  @override
  String get iptvAllCategories => 'All categories';

  @override
  String get iptvLanguage => 'Language';

  @override
  String iptvMyLanguages(String languages) {
    return 'My languages ($languages)';
  }

  @override
  String get iptvAllLanguages => 'All languages';

  @override
  String get iptvBrowseKeyHint =>
      'OK plays the channel  ·  ★ (→) or the options key: add to / remove from the Internet TV list';

  @override
  String iptvResultCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count channels',
      one: '1 channel',
    );
    return '$_temp0';
  }

  @override
  String iptvCatalogueDate(String date) {
    return 'Catalogue of $date';
  }

  @override
  String get iptvLoadingCatalogue =>
      'Loading the channel catalogue… (the first time this can take a minute)';

  @override
  String get iptvUpdatingCatalogue => 'updating…';

  @override
  String get iptvUpdateFailed => 'Update failed';

  @override
  String iptvCatalogueError(String error) {
    return 'Couldn’t load the channel catalogue: $error';
  }

  @override
  String get iptvTryAgain => 'Try again';

  @override
  String get iptvNoResults => 'No channels found';

  @override
  String get iptvAddFavorite => 'Add to the Internet TV list';

  @override
  String get iptvRemoveFavorite => 'Remove from the Internet TV list';

  @override
  String iptvAddedAsNumber(String name, int number) {
    return '“$name” is now Internet TV no. $number';
  }

  @override
  String iptvRemoved(String name) {
    return '“$name” removed from the Internet TV list';
  }

  @override
  String iptvFavoriteNumber(int number) {
    return 'No. $number';
  }

  @override
  String get iptvEmptyList =>
      'No Internet TV channels yet. Use “Find channels” above: there OK plays a channel, ★ adds it to this list.';

  @override
  String get iptvChannelListKeyHint =>
      'OK play (current channel: info)  ·  → Options (move, remove)  ·  ← close';

  @override
  String get iptvMove => 'Move';

  @override
  String get iptvMoveHint => '↑/↓ move  ·  OK done';

  @override
  String get iptvChangeNumber => 'Change number…';

  @override
  String get iptvPlay => 'Play';

  @override
  String get iptvLinkConnecting => 'Connecting to the channel…';

  @override
  String iptvLinkTryingOther(int attempt, int count) {
    return 'Trying another stream ($attempt of $count)…';
  }

  @override
  String iptvErrorNoPicture(String channel) {
    return '“$channel” isn’t on air right now or is blocked here (geo-blocking).';
  }

  @override
  String get iptvNoGuide => 'No TV guide for Internet TV';

  @override
  String get iptvNoGuideSentence =>
      'There’s no TV guide for Internet TV channels.';

  @override
  String iptvBannerKeyHint(String channelListKey, String optionsKey) {
    return '$channelListKey Channel list  ·  $optionsKey Options';
  }

  @override
  String get iptvGeoBlocked =>
      'Possibly only receivable in its own country (geo-blocking)';

  @override
  String get iptvNotAlways => 'Not on air around the clock';

  @override
  String get iptvSource =>
      'Source: the open channel catalogue iptv-org (github.com/iptv-org/iptv)';

  @override
  String get iptvNotSetUpIntro =>
      'Or without any receiver: free channels from the internet (Internet TV).';

  @override
  String get iptvSetUp => 'Find Internet TV channels';

  @override
  String get iptvSettingsTitle => 'Internet TV';

  @override
  String get iptvSettingsIntro =>
      'Free, legal TV channels from the internet – from the open channel catalogue iptv-org (github.com/iptv-org/iptv). Internet TV has its own channel list with its own numbers; the receiver’s list stays as it is. Some channels only work in their own country (geo-blocking) or aren’t on air around the clock.';

  @override
  String get iptvSettingsEnabled => 'Show Internet TV in TV';

  @override
  String get iptvSettingsCountries => 'My countries';

  @override
  String get iptvSettingsCountriesHelp =>
      'Finding channels starts with these countries.';

  @override
  String get iptvSettingsLanguages => 'My languages';

  @override
  String get iptvSettingsLanguagesHelp =>
      'Finding channels starts with these languages – none: all languages.';

  @override
  String get iptvSettingsAddCountry => 'Add country';

  @override
  String get iptvSettingsAddLanguage => 'Add language';

  @override
  String get iptvSettingsChipHelp =>
      'OK on a country or language takes it out again.';

  @override
  String get iptvSettingsCatalogue => 'Channel catalogue';

  @override
  String get iptvSettingsCatalogueHelp =>
      'Loaded the first time you look for channels, then updated at most once a day.';

  @override
  String get iptvSettingsRefresh => 'Update now';

  @override
  String iptvSettingsFavorites(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count channels in the Internet TV list',
      one: '1 channel in the Internet TV list',
      zero: 'No channels in the Internet TV list yet',
    );
    return '$_temp0';
  }

  @override
  String get iptvSettingsFavoritesHelp =>
      'Sort and remove them in TV’s channel list: → on a channel there.';

  @override
  String get iptvSettingsClearFavorites => 'Remove all';

  @override
  String iptvSettingsClearConfirm(int count) {
    return 'Remove all $count channels from the Internet TV list?';
  }

  @override
  String get iptvChipMine => 'My channels';

  @override
  String get iptvChipSearch => 'Search';

  @override
  String lanSearchFound(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count found - OK takes one.',
      one: 'One found - OK takes it.',
    );
    return '$_temp0';
  }

  @override
  String get lanSearchButton => 'Search';

  @override
  String get lanSearchHa => 'Find Home Assistant';

  @override
  String get lanSearchHaHint =>
      'in the home network, instead of typing the address';

  @override
  String get lanSearchHaNone =>
      'No Home Assistant found (port 8123). Is it running and in the same network? Otherwise please enter the address by hand.';

  @override
  String get lanSearchHaMqtt => 'MQTT broker runs there';

  @override
  String get lanSearchHaNoMqtt => 'no MQTT broker (Mosquitto add-on?)';

  @override
  String get lanSearchHaAdminHelp =>
      'Looks for Home Assistant in the home network (takes a few seconds). If one is found it becomes the broker - and the Smart Home address if none is set there yet.';

  @override
  String lanSearchHaTaken(String name, String url) {
    return 'Found and entered: $name ($url)';
  }

  @override
  String lanSearchHaSeveral(String list) {
    return 'Several found: $list - please enter the right address by hand.';
  }

  @override
  String get lanSearchRtl => 'Search the network';

  @override
  String get lanSearchRtlNone =>
      'No rtl_tcp server found (port 1234). Is it running and in the same network? A classic rtl_tcp in use by another device doesn\'t answer.';

  @override
  String get launcherAddToGroup => 'Add to group …';

  @override
  String launcherAddToGroupTitle(String app) {
    return 'Add \"$app\" to group';
  }

  @override
  String get launcherMoveToGroup => 'Move to another group …';

  @override
  String launcherMoveToGroupTitle(String app) {
    return 'Move \"$app\" to';
  }

  @override
  String get launcherRemoveFromGroup => 'Remove from the group';

  @override
  String get launcherNewGroup => 'New group …';

  @override
  String get launcherNewGroupTitle => 'Name of the new group';

  @override
  String get launcherGroupNameHint => 'e.g. System tools';

  @override
  String get launcherGroupUnnamed => 'Group';

  @override
  String launcherGroupOptions(String group) {
    return 'Group \"$group\" …';
  }

  @override
  String get launcherGroupRename => 'Rename';

  @override
  String get launcherGroupRenameTitle => 'Rename group';

  @override
  String get launcherGroupMoveUp => 'Move group up';

  @override
  String get launcherGroupMoveDown => 'Move group down';

  @override
  String get launcherGroupDelete => 'Delete group';

  @override
  String launcherGroupDeleteTitle(String group) {
    return 'Delete group \"$group\"?';
  }

  @override
  String get launcherGroupDeleteBody =>
      'Only the row goes - the apps stay installed, in the favorites and in other groups.';

  @override
  String get launcherGroupEmpty => 'Still empty';

  @override
  String launcherGroupEmptyHint(String key) {
    return '$key  Group options';
  }

  @override
  String launcherAddedToGroup(String app, String group) {
    return '\"$app\" is now in \"$group\"';
  }

  @override
  String launcherRemovedFromGroup(String app, String group) {
    return '\"$app\" removed from \"$group\"';
  }

  @override
  String get launcherAllAppsHelp =>
      'OK: open app  ·  ☰ or hold OK: favorite, group, app info (force stop, uninstall)';

  @override
  String get launcherMoveTile => 'Move';

  @override
  String get launcherMoveTiles => 'Move tiles';

  @override
  String get launcherMoveModeHint =>
      'Move mode: OK pick up/drop · ◀ ▶ move · Hold OK: done';

  @override
  String get launcherMoveModeLiftedHint =>
      '◀ ▶ move · OK: drop here · Back: cancel · Hold OK: done';

  @override
  String get miscApply => 'Apply';

  @override
  String get miscLocationTitle => 'Set up location';

  @override
  String get miscLocationIntro =>
      'Shared location for the weather forecast, weather radar and sun & moon.';

  @override
  String miscLocationCurrent(String name, String lat, String lon) {
    return 'Current: $name ($lat, $lon)';
  }

  @override
  String get miscLocationSearchLabel =>
      'Search for a place, e.g. Graz or Gleisdorf';

  @override
  String get miscLocationSearch => 'Search';

  @override
  String get miscLocationSearchFailed =>
      'Search failed - check the internet connection.';

  @override
  String get miscLocationNoResults => 'No place found.';

  @override
  String miscLocationPicked(String name) {
    return 'Location: $name';
  }

  @override
  String get miscLocationAttribution =>
      'Place search: © OpenStreetMap contributors (ODbL), via Nominatim.';

  @override
  String get miscRadarTitle => 'Set up weather radar';

  @override
  String get miscRadarInvalidUrl =>
      'Please enter a full address starting with http:// or https://.';

  @override
  String get miscRadarSourceType => 'Source type';

  @override
  String get miscRadarImage => 'Image';

  @override
  String get miscRadarImageHint =>
      'PNG or JPG, e.g. from your own radar server - reloaded every 2½ minutes.';

  @override
  String get miscRadarWebPage => 'Web page';

  @override
  String get miscRadarWebPageHint =>
      'A radar web page, e.g. an interactive map. Needs more memory and graphics power than an image - on weak TV boxes, an image is the better choice.';

  @override
  String get miscRadarWebPageUrl => 'Web page address (URL)';

  @override
  String get miscRadarImageUrl => 'Image address (URL)';

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
    return 'Placeholders are filled in automatically: $lat $lon = location, $r = radius in km, $zoom = map zoom matching the radius, $w $h = tile size in pixels, $scale = screen density.';
  }

  @override
  String get miscRadarDisclaimer =>
      'The app doesn\'t come with a radar source of its own. Rights and terms of use belong to each provider - please only enter sources that may be used this way.';

  @override
  String get miscRadarCssLabel => 'Custom CSS for the web page (optional)';

  @override
  String get miscRadarCssHint =>
      'Inserted into the page after every load, like a custom stylesheet in a browser - e.g. to hide parts of the page you don\'t need.';

  @override
  String get miscRadarAuth => 'With sign-in (token)';

  @override
  String get miscRadarAuthHint => 'Sent as “Authorization: Bearer …”.';

  @override
  String get miscRemoteKeysTitle => 'Remote control buttons';

  @override
  String get miscRemoteKeysIntro =>
      'Choose an action, then press the button that should trigger it - it replaces the action\'s previous buttons. That way ☰, for example, stays free if it does something else on your remote. Arrow keys, Back and Home can\'t be assigned.';

  @override
  String get miscRemoteKeysNone => 'no button';

  @override
  String get miscRemoteKeysStandard => 'Default';

  @override
  String get miscRemoteKeysResetHint =>
      'Hold OK on an action to get its default buttons back.';

  @override
  String miscRemoteKeysNotAssignable(String key) {
    return '$key can\'t be assigned.';
  }

  @override
  String get miscRemoteKeysPressNow => 'Press the button now …';

  @override
  String get miscRemoteKeysBackCancels => 'Back cancels.';

  @override
  String get miscActionChannelList => 'Channel list (TV)';

  @override
  String get miscActionGuide => 'Program guide (TV)';

  @override
  String get miscActionOptions => 'Options (tile on Home, TV)';

  @override
  String get miscActionAudio => 'Audio track (TV)';

  @override
  String get miscKeyMenu => '☰ Menu';

  @override
  String get miscKeySearch => 'Search';

  @override
  String get miscKeyRed => 'Red';

  @override
  String get miscKeyGreen => 'Green';

  @override
  String get miscKeyYellow => 'Yellow';

  @override
  String get miscKeyBlue => 'Blue';

  @override
  String miscKeyNamed(String key) {
    return 'Key $key';
  }

  @override
  String get miscRegionEurope => 'Europe';

  @override
  String get miscRegionNorthAmerica => 'North & Central America';

  @override
  String get miscRegionSouthAmerica => 'South America';

  @override
  String get miscRegionAsia => 'Asia & Middle East';

  @override
  String get miscRegionAfrica => 'Africa';

  @override
  String get miscRegionOceania => 'Oceania';

  @override
  String get miscRegionOther => 'Other';

  @override
  String get miscUpdatesTitle => 'Updates';

  @override
  String miscUpdateDialogTitle(String version) {
    return 'Update to $version';
  }

  @override
  String get miscUpdateDownloading => 'Downloading…';

  @override
  String miscUpdateDownloadingPercent(int percent) {
    return 'Downloading… $percent %';
  }

  @override
  String miscUpdateFailed(String error) {
    return 'Update failed: $error';
  }

  @override
  String miscUpdateInstalledVersion(String version) {
    return 'Installed version: $version';
  }

  @override
  String get miscUpdateLocalBuild =>
      'This version was built locally and doesn\'t update itself.';

  @override
  String get miscUpdateAuto => 'Update automatically on start';

  @override
  String get miscUpdateAutoHint =>
      'New versions are downloaded and installed on start.';

  @override
  String get miscUpdateChecking => 'Checking for updates…';

  @override
  String miscUpdateAvailable(String version) {
    return 'New version $version available.';
  }

  @override
  String get miscUpdateNow => 'Update now';

  @override
  String get miscUpdateUpToDate =>
      'The app is up to date (or the update server can\'t be reached).';

  @override
  String get miscUpdateCheckAgain => 'Check again';

  @override
  String get miscUpdateAllowUnknownApps =>
      'Please allow “Install unknown apps” for Home System and start the update again.';

  @override
  String miscUpdateInstallCancelled(int code) {
    return 'Installation cancelled ($code).';
  }

  @override
  String miscUpdateDownloadFailed(int status) {
    return 'Download failed (HTTP $status).';
  }

  @override
  String get miscUpdateCorrupt => 'The downloaded file is corrupt.';

  @override
  String get miscDeviceTitle => 'This device';

  @override
  String miscDeviceAndroid(String release, int sdk) {
    return 'Android $release (API $sdk)';
  }

  @override
  String miscDeviceSystem64(String abi) {
    return 'System: 64-bit ($abi)';
  }

  @override
  String miscDeviceSystem32(String abi) {
    return 'System: 32-bit ($abi)';
  }

  @override
  String get miscDeviceCpu64On32 =>
      'The processor can do 64-bit, but Android runs as 32-bit here - so only the 32-bit version fits.';

  @override
  String miscDeviceChip(String chip) {
    return 'Chip: $chip';
  }

  @override
  String miscDeviceRam(String gb) {
    return 'Memory: $gb GB';
  }

  @override
  String miscDeviceInstalled(String variant) {
    return 'Installed: $variant';
  }

  @override
  String miscDeviceRecommended(String file) {
    return 'Matching file: $file';
  }

  @override
  String get miscDeviceFits => 'The installed version is the matching one.';

  @override
  String get miscDeviceUniversal =>
      'The universal version works but is bigger - the next update brings the matching one.';

  @override
  String get miscDeviceOther => 'The next update brings the matching version.';

  @override
  String get miscDeviceVariantsTitle => 'Which file for which device?';

  @override
  String get miscDeviceVariantArmv7 =>
      'armeabi-v7a: 32-bit Android - Fire TV Stick, Fire TV sets, most TV boxes (even with a 64-bit chip)';

  @override
  String get miscDeviceVariantArm64 =>
      'arm64-v8a: 64-bit Android - Fire tablets, newer phones, tablets and boxes';

  @override
  String get miscDeviceVariantX86 =>
      'x86_64: Android on PCs and emulators (Intel/AMD)';

  @override
  String get miscDeviceVariantUniversal =>
      'universal: runs everywhere, if unsure (bigger)';

  @override
  String miscDeviceMinAndroid(String version) {
    return 'Android $version or newer.';
  }

  @override
  String get miscAllAppsTitle => 'All apps';

  @override
  String get miscAllAppsOpen => 'Open';

  @override
  String get miscAllAppsAddFavorite => 'Add to favorites';

  @override
  String get miscAllAppsRemoveFavorite => 'Remove from favorites';

  @override
  String get miscAllAppsAppInfo => 'App info (force stop, uninstall …)';

  @override
  String miscAllAppsFavoriteAdded(String app) {
    return '“$app” added to favorites';
  }

  @override
  String miscAllAppsFavoriteRemoved(String app) {
    return '“$app” removed from favorites';
  }

  @override
  String get miscAllAppsSearch => 'Search apps';

  @override
  String get miscAllAppsClearSearch => 'Clear search';

  @override
  String get miscAllAppsSettingsIsFavorite => 'TV settings in favorites';

  @override
  String get miscAllAppsSettingsAddFavorite => 'Add TV settings to favorites';

  @override
  String get miscAllAppsHelp =>
      'OK: open app  ·  ☰ or hold OK: favorite, app info (force stop, uninstall)';

  @override
  String miscAllAppsLoadError(String error) {
    return 'Couldn\'t read the apps: $error';
  }

  @override
  String get miscAllAppsNone => 'No apps found.';

  @override
  String miscAllAppsNoMatch(String query) {
    return 'No app matches “$query”.';
  }

  @override
  String get miscBackdropAurora => 'Northern lights';

  @override
  String get miscBackdropSunset => 'Sunset';

  @override
  String get miscBackdropOcean => 'Ocean';

  @override
  String get miscBackdropForest => 'Forest';

  @override
  String get miscBackdropLavender => 'Lavender';

  @override
  String get miscBackdropEmbers => 'Embers';

  @override
  String get miscBackdropNight => 'Night';

  @override
  String get miscBackdropDesert => 'Desert';

  @override
  String get modelsAcarsAckNoContent => 'Acknowledgement (no content)';

  @override
  String get modelsAcarsLinkTest => 'Link test';

  @override
  String get modelsAcarsOnboardComputer => 'Onboard computer (FMS/maintenance)';

  @override
  String get modelsAcarsSystemStatus => 'System status';

  @override
  String get modelsAcarsAirlineMessage => 'Airline message';

  @override
  String get modelsAcarsFlightData => 'Flight data';

  @override
  String get modelsAcarsMessage => 'Message';

  @override
  String get modelsAircraftLight => 'Light aircraft';

  @override
  String get modelsAircraftLightShort => 'light';

  @override
  String get modelsAircraftSmall => 'Small aircraft';

  @override
  String get modelsAircraftSmallShort => 'small';

  @override
  String get modelsAircraftLarge => 'Airliner';

  @override
  String get modelsAircraftLargeShort => 'large';

  @override
  String get modelsAircraftHeavy => 'Wide-body airliner';

  @override
  String get modelsAircraftHeavyShort => 'heavy';

  @override
  String get modelsAircraftHighPerformance => 'High-performance / military jet';

  @override
  String get modelsAircraftGlider => 'Glider';

  @override
  String get modelsAircraftGliderShort => 'Glider';

  @override
  String get modelsAircraftBalloon => 'Balloon / airship';

  @override
  String get modelsAircraftUltralight => 'Ultralight / paraglider';

  @override
  String get modelsAircraftUav => 'Drone';

  @override
  String get modelsAircraftSurface => 'Ground vehicle';

  @override
  String get modelsAircraftSurfaceShort => 'Ground';

  @override
  String get modelsDmrRadio => 'Radio';

  @override
  String get modelsDmrDirect => 'Direct mode';

  @override
  String get modelsIsmRemoteSwitch => 'Radio switch (EV1527)';

  @override
  String modelsIsmButton(String code) {
    return 'Button $code';
  }

  @override
  String get moviesTitle => 'Movies';

  @override
  String get moviesNotSetUpTitle => 'No movie folder yet';

  @override
  String get moviesNotSetUp =>
      'Movies come from the NAS. Under Settings → NAS, enter the server and add one or more folders under “Movie folders”.';

  @override
  String get moviesOpenNasSettings => 'Set up NAS';

  @override
  String get moviesEmpty => 'There are no movies in this folder.';

  @override
  String moviesListError(String error) {
    return 'The folder can\'t be read: $error';
  }

  @override
  String get moviesRetry => 'Try again';

  @override
  String get moviesOpenFolder => 'Open folder';

  @override
  String get moviesHoldOkForFolder => 'Hold OK: open the folder';

  @override
  String get moviesDvd => 'DVD';

  @override
  String get moviesOpening => 'Opening the movie…';

  @override
  String get moviesResumeTitle => 'Continue watching?';

  @override
  String moviesResumeFrom(String time) {
    return 'Resume from $time';
  }

  @override
  String get moviesFromStart => 'From the start';

  @override
  String get moviesErrorNoDvd =>
      'There\'s no video DVD in it (no VIDEO_TS folder with movie files).';

  @override
  String moviesErrorPlay(String error) {
    return 'The movie can\'t be played: $error';
  }

  @override
  String get moviesErrorTimeout =>
      'The movie doesn\'t start - this device probably can\'t play the format, or the NAS delivers too slowly.';

  @override
  String get moviesBack => 'Back';

  @override
  String get moviesOptions => 'Options';

  @override
  String get moviesAudio => 'Sound track';

  @override
  String get moviesSubtitles => 'Subtitles';

  @override
  String get moviesSubtitlesOff => 'Off';

  @override
  String get moviesNoAudioChoice => 'This movie has only one sound track.';

  @override
  String get moviesAudioComments => 'Commentary';

  @override
  String get moviesAudioDescription => 'Audio description';

  @override
  String moviesChapter(int number, int count) {
    return 'Chapter $number of $count';
  }

  @override
  String moviesKeyHint(String jump, String options) {
    return 'OK: pause · ◀ ▶: seek · ▲ ▼: $jump · $options: sound & subtitles';
  }

  @override
  String get moviesJumpChapters => 'chapters';

  @override
  String get moviesJumpMinutes => '±5 min';

  @override
  String get moviesDvdNote => 'DVD without menus and without DVD subtitles';

  @override
  String get moviesAdminPart => 'Films switched on';

  @override
  String get musicTitle => 'Music';

  @override
  String get musicAreaSubtitle => 'Playback, visualisation, index';

  @override
  String get musicAdminPart => 'Music (from the NAS)';

  @override
  String get musicAdminIndex => 'Music index';

  @override
  String get musicAllShuffled => 'Shuffle all';

  @override
  String get musicSearch => 'Search';

  @override
  String get musicNowPlaying => 'Now playing';

  @override
  String get musicSettingsTitle => 'Music';

  @override
  String get musicPlayFolder => 'Play';

  @override
  String get musicShuffleFolder => 'Shuffle';

  @override
  String get musicRefreshFolderIndex => 'Re-read folder (index)';

  @override
  String musicFolderIndexed(int count) {
    return '$count tracks read again.';
  }

  @override
  String musicFolderSummary(int folders, int tracks) {
    return '$folders folders · $tracks tracks';
  }

  @override
  String get musicEmptyFolder => 'There is no music in this folder.';

  @override
  String get musicNoFolder =>
      'No music folder chosen yet.\nChoose it in Settings → NAS.';

  @override
  String get musicOpenNasSettings => 'Open NAS settings';

  @override
  String get musicRetry => 'Try again';

  @override
  String get musicErrorNoFolder => 'No music folder chosen (Settings → NAS).';

  @override
  String get musicErrorNoMusic => 'No music to be found here.';

  @override
  String musicErrorUnplayable(String name) {
    return '“$name” can\'t be played - on to the next track.';
  }

  @override
  String get musicNothingPlaying => 'No music playing right now.';

  @override
  String get musicPaused => 'Paused';

  @override
  String get musicCollecting => 'Still looking through folders …';

  @override
  String musicQueuePosition(int index, int count) {
    return 'Track $index of $count';
  }

  @override
  String get musicQueue => 'Queue';

  @override
  String musicQueueTitle(int count) {
    return 'Queue ($count)';
  }

  @override
  String musicNowPlayingHint(String menu) {
    return 'OK pause · ←/→ seek (hold: faster) · ↑ visualisation · ↓ buttons · $menu queue';
  }

  @override
  String get musicControlsHint =>
      '←/→ choose a button · OK press · ↑ back to seeking';

  @override
  String get musicPlay => 'Play';

  @override
  String get musicPause => 'Pause';

  @override
  String get musicStop => 'Stop';

  @override
  String get musicNext => 'Next track';

  @override
  String get musicPrevious => 'Previous track';

  @override
  String get musicShuffleOn => 'Shuffle: on';

  @override
  String get musicShuffleOff => 'Shuffle: off';

  @override
  String get musicRepeatOff => 'Don\'t repeat';

  @override
  String get musicRepeatAll => 'Repeat all';

  @override
  String get musicRepeatOne => 'Repeat track';

  @override
  String get musicVisualizer => 'Visualisation';

  @override
  String get musicSearchLabel => 'Title, artist or folder';

  @override
  String get musicSearchHint => 'e.g. Queen Bohemian';

  @override
  String get musicSearchIntro =>
      'Searches the file and folder names of the whole collection.';

  @override
  String get musicSearchNothing => 'Nothing found.';

  @override
  String musicSearchResults(String query) {
    return 'Search: $query';
  }

  @override
  String get musicSearchNeedsIndex =>
      'Searching needs the index - a list of all music files, read from the NAS once (takes a while with many tracks, runs in the background).';

  @override
  String get musicIndexBuild => 'Build index';

  @override
  String get musicIndexRefresh => 'Update index';

  @override
  String get musicIndexContinue => 'Continue index';

  @override
  String get musicIndexStop => 'Stop';

  @override
  String get musicIndexDelete => 'Delete index';

  @override
  String get musicIndexNone =>
      'No index - folders are read straight from the NAS.';

  @override
  String musicIndexRunning(int folders, int tracks) {
    return 'Reading: $folders folders, $tracks tracks …';
  }

  @override
  String musicIndexInterrupted(int tracks) {
    return 'Interrupted after $tracks tracks - continues the next time Music is opened.';
  }

  @override
  String musicIndexState(int tracks, int folders, String date) {
    return '$tracks tracks in $folders folders · as of $date';
  }

  @override
  String musicIndexSummary(int tracks, int folders) {
    return '$tracks tracks · $folders folders';
  }

  @override
  String get musicSettingsFolder => 'Music folder';

  @override
  String get musicSettingsNoFolder => 'Not chosen - in the NAS settings';

  @override
  String get musicSettingsPlayback => 'Playback';

  @override
  String get musicSettingsShuffle => 'Shuffle';

  @override
  String get musicSettingsShuffleHelp =>
      'For playing a track; stays until switched.';

  @override
  String get musicSettingsRepeat => 'Repeat';

  @override
  String get musicSettingsPreferTags => 'Title and artist from the files';

  @override
  String get musicSettingsPreferTagsHelp =>
      'From the file\'s tags (ID3, MP4, FLAC …), else from the file name. Off: always the file name.';

  @override
  String get musicSettingsVisualizer => 'Visualisation';

  @override
  String get musicVisualizerOff => 'Off';

  @override
  String get musicVisualizerManual => 'With ↑ on the player';

  @override
  String get musicVisualizerAuto =>
      'Also by itself after a minute without a key';

  @override
  String get musicSettingsQuality => 'Picture quality';

  @override
  String get musicQualityAuto => 'Automatic';

  @override
  String get musicQualityLow => 'Light (weak boxes)';

  @override
  String get musicQualityHigh => 'High';

  @override
  String get musicSettingsReactive => 'Follows the music';

  @override
  String get musicSettingsReactiveHelp =>
      'Moves with the beat. On Android it needs the \"record audio\" permission - without it the picture pulses calmly by itself.';

  @override
  String get musicSettingsReactivePermission =>
      'To follow the music, the visualisation reads the frequency spectrum of the app\'s own playback. Android requires the \"record audio\" permission for that and asks about the microphone - the microphone isn\'t used though, nothing is recorded or stored.';

  @override
  String get musicSettingsReactiveAllow => 'Allow';

  @override
  String get musicSettingsReactiveDenied =>
      'Without the permission the visualisation pulses by itself.';

  @override
  String get musicSettingsIndex => 'Index (optional)';

  @override
  String get musicSettingsIndexHelp =>
      'A list of all music files (names only, no tags) for searching and \"Shuffle all\" without waiting. Browsing and playing folders works without it. Reading runs in the background and continues after an interruption.';

  @override
  String get musicWithSubfolders => 'Include subfolders';

  @override
  String get musicWithSubfoldersHelp =>
      '\"Play\" and \"Shuffle\" also take all of the folder\'s subfolders along.';

  @override
  String get musicSettingsInterval => 'Change to the next visualisation';

  @override
  String musicIntervalSeconds(int seconds) {
    return 'Every $seconds s';
  }

  @override
  String get musicIntervalManual => 'Only with ↑';

  @override
  String get musicVisualizerHint => '↑ next visualisation · ←/→ track · ↓ back';

  @override
  String get musicVisualizerSimulated => 'Simulated';

  @override
  String get musicVisualizerSimulatedHint =>
      'Not following the music - music settings → \"Follows the music\"';

  @override
  String get nasTitle => 'NAS (network storage)';

  @override
  String get nasIntro =>
      'The network storage in your home network: backups before every update, background pictures for Home - and later music, videos and movies from the server.';

  @override
  String get nasServerSection => 'Server';

  @override
  String get nasProtocolWebdav => 'WebDAV';

  @override
  String get nasProtocolWebdavHint =>
      'Synology, QNAP, Nextcloud, Apache/nginx … - over http or https.';

  @override
  String get nasProtocolFtp => 'FTP';

  @override
  String get nasProtocolFtpHint =>
      'Unencrypted - use only in your own network.';

  @override
  String get nasProtocolSmb => 'SMB (Windows file sharing)';

  @override
  String get nasProtocolSmbHint =>
      'Windows PC or server, NAS with Samba - shows all of the server\'s shares (SMB 1 to 2.1).';

  @override
  String get nasHost => 'Server address (IP or name)';

  @override
  String get nasHostHint => 'e.g. 192.168.1.10';

  @override
  String nasPort(int port) {
    return 'Port (empty = $port)';
  }

  @override
  String get nasHttps => 'Encrypted (https)';

  @override
  String get nasHttpsHint =>
      'The NAS\'s certificate is accepted even if it is self-signed.';

  @override
  String get nasBasePath => 'WebDAV path';

  @override
  String get nasBasePathHint => 'empty, or e.g. /remote.php/dav/files/NAME';

  @override
  String get nasUser => 'User name';

  @override
  String get nasPassword => 'Password';

  @override
  String get nasDomain => 'Domain or workgroup (usually empty)';

  @override
  String get nasSmbLoginHint =>
      'An account on the server. For a Microsoft account on Windows: the email address and password (not the PIN).';

  @override
  String get nasTest => 'Test connection';

  @override
  String nasTestOk(int count) {
    return 'Connection OK - $count entries in the main folder.';
  }

  @override
  String nasTestFailed(String message) {
    return 'No connection: $message';
  }

  @override
  String get nasFoldersSection => 'Folders';

  @override
  String get nasFoldersHint => 'OK picks a folder on the NAS.';

  @override
  String get nasNeedServer => 'Enter the server address first.';

  @override
  String get nasFolderPictures => 'Pictures';

  @override
  String get nasFolderMusic => 'Music';

  @override
  String get nasFolderVideos => 'Videos';

  @override
  String get nasFolderMovies => 'Movies';

  @override
  String get nasFolderBackups => 'Backups';

  @override
  String get nasFolderNotChosen => 'Not chosen';

  @override
  String get nasFolderClear => 'Clear choice';

  @override
  String nasBackupsHint(int count) {
    return 'Before every update a backup goes into the backup folder; the $count newest of this device are kept.';
  }

  @override
  String get nasPicturesHint =>
      'The pictures can be Home\'s background (Settings → Home → Background → Own server).';

  @override
  String nasBrowseTitle(String folder) {
    return 'Folder for $folder';
  }

  @override
  String get nasChooseThisFolder => 'Choose this folder';

  @override
  String get nasUp => 'One level up';

  @override
  String get nasNoSubfolders => 'No subfolders.';

  @override
  String nasFilesInFolder(int count) {
    return '$count files in this folder';
  }

  @override
  String get nasBrowseBackHint => 'Back: one level up';

  @override
  String get nasErrorTimeout => 'The server doesn\'t answer (timeout).';

  @override
  String get nasErrorTls =>
      'The encrypted connection fails - are https and the port right?';

  @override
  String get nasErrorRefused =>
      'The server refuses the connection - are protocol and port right?';

  @override
  String get nasErrorHostNotFound => 'Server name not found.';

  @override
  String get nasErrorUnreachable => 'Server not reachable.';

  @override
  String nasErrorOther(String message) {
    return 'Error: $message';
  }

  @override
  String get nasErrorLogin =>
      'Login failed - wrong user name or password, or no permission.';

  @override
  String get nasErrorNotFound => 'Folder or file not found.';

  @override
  String get nasErrorNoWebDav =>
      'The server doesn\'t answer like a WebDAV server - is the WebDAV path right?';

  @override
  String get nasErrorFull => 'The NAS is full.';

  @override
  String nasErrorHttp(int status) {
    return 'The server reports HTTP error $status.';
  }

  @override
  String get nasErrorTooBig => 'The file is too big.';

  @override
  String nasErrorFtp(String reply) {
    return 'The FTP server reports: $reply';
  }

  @override
  String nasErrorSmb(String message) {
    return 'The SMB server reports: $message';
  }

  @override
  String get nasErrorSmbConnect =>
      'No SMB connection - the server may require SMB 3 (the app speaks SMB 1 to 2.1).';

  @override
  String get nasErrorIsFolder => 'That\'s a folder, not a file.';

  @override
  String get nasBackupRunning => 'Backup to the NAS …';

  @override
  String nasBackupFailed(String message) {
    return 'Backup to the NAS failed ($message) - the update goes on anyway.';
  }

  @override
  String get nasRestoreSection => 'Backups on the NAS';

  @override
  String nasRestoreHint(String folder) {
    return 'From the backup folder $folder - other devices\' too.';
  }

  @override
  String get nasRestoreNone => 'No backups in the NAS folder.';

  @override
  String nasRestoreLoadFailed(String message) {
    return 'The backups on the NAS couldn\'t be read: $message';
  }

  @override
  String nasRestoreDownloadFailed(String message) {
    return 'The backup couldn\'t be loaded from the NAS: $message';
  }

  @override
  String get nasBgFromNas => 'Background pictures from the NAS';

  @override
  String nasBgFromNasHint(String folder) {
    return '$folder (with subfolders) - a random picture from it each time. Up to 30 pictures are kept downscaled on the device; synced at app start and with \"Sync now\".';
  }

  @override
  String get nasBgNoFolder =>
      'First choose a folder for background pictures under Settings → System → NAS server.';

  @override
  String get nasBgSyncNow => 'Sync now';

  @override
  String get nasBgSyncing => 'Syncing …';

  @override
  String nasBgStatus(int count) {
    return '$count pictures on the device';
  }

  @override
  String nasBgLastSync(int count, String date) {
    return '$count pictures on the device, synced on $date';
  }

  @override
  String nasBgSyncError(String message) {
    return 'Sync failed: $message';
  }

  @override
  String get nasFolderBackgrounds => 'Background pictures (Home)';

  @override
  String get nasBgSyncListing => 'Reading the folder …';

  @override
  String get nasBgSyncNothingNew => 'No new pictures - finishing …';

  @override
  String nasBgSyncProgress(int loaded, int total) {
    return 'Loading picture $loaded of $total …';
  }

  @override
  String get nasMovieFoldersSection => 'Movie folders';

  @override
  String get nasMovieFoldersHint =>
      'Any number of folders for Movies - each is a place of its own there, in this order. OK on a folder: rename, choose another folder, move or remove.';

  @override
  String get nasMovieFoldersEmpty => 'No movie folder yet.';

  @override
  String get nasMovieFolderAdd => 'Add a movie folder';

  @override
  String get nasMovieFolderName => 'Name in Movies';

  @override
  String get nasMovieFolderRename => 'Rename';

  @override
  String get nasMovieFolderChange => 'Choose another folder';

  @override
  String get nasMovieFolderUp => 'Move up';

  @override
  String get nasMovieFolderDown => 'Move down';

  @override
  String get nasMovieFolderRemove => 'Remove';

  @override
  String nasMovieFolderSaveFailed(String error) {
    return 'The movie folders could not be saved: $error';
  }

  @override
  String get permissionsTitle => 'Permissions';

  @override
  String get permissionsIntro =>
      'Home System only asks for what a feature really needs - and every permission is optional. Without it everything else works as usual; only that one feature is missing.';

  @override
  String permissionsSummary(int granted, int total) {
    return '$granted of $total granted';
  }

  @override
  String get permissionsNoneNeeded =>
      'On this device Home System doesn\'t need any special permissions.';

  @override
  String get permissionsStatusGranted => 'Granted';

  @override
  String get permissionsStatusMissing => 'Not granted';

  @override
  String get permissionsStatusNotNeeded => 'Not needed';

  @override
  String get permissionsStatusUsb => 'Android asks when it\'s plugged in';

  @override
  String get permissionsStatusNotifications => 'No permission needed';

  @override
  String get permissionsStatusAdb => 'adb only';

  @override
  String get permissionsAllow => 'Allow';

  @override
  String get permissionsSetUp => 'Set up';

  @override
  String get permissionsChange => 'Change';

  @override
  String get permissionsLater => 'Later';

  @override
  String get permissionsNotNeededHeading => 'Not needed right now';

  @override
  String get permissionsNotNeededDevice => 'Not needed on this device.';

  @override
  String permissionsNotNeededPart(String part) {
    return 'Not needed while “$part” is switched off.';
  }

  @override
  String get permissionsNotNeededNoCamera => 'This device has no camera.';

  @override
  String get permissionsBlocked =>
      'Android won\'t ask again. Allow it under “Permissions” on the app page that just opened.';

  @override
  String get permissionsDenied =>
      'Not allowed - the feature stays off. You can change this here at any time.';

  @override
  String get permissionsMusicOn => '“Follows the music” is switched on now.';

  @override
  String get permissionsHomeKeyTitle => 'Home key';

  @override
  String get permissionsHomeKeyWhy =>
      'To make the remote\'s Home key open Home System, Home System becomes the default launcher - or, where that isn\'t possible (e.g. Fire TV, Google TV), the service “Home System: Home-Taste” is switched on, an accessibility service. The service only sees which app is in front - no screen content, no input, no passwords.';

  @override
  String get permissionsHomeKeyWhyDashboard =>
      'For the home control the same service also switches the display off and swipes away a lock screen without PIN when the display comes back on.';

  @override
  String get permissionsCameraTitle => 'Camera';

  @override
  String get permissionsCameraWhy =>
      'For the home control (“switch the display on and off by camera”): the camera only detects whether something moves in front of the device. No pictures are stored or sent anywhere.';

  @override
  String get permissionsInstallTitle => 'Install apps';

  @override
  String get permissionsInstallWhy =>
      'So that Home System can install its own updates. Android still asks before every update, and Home System never installs any other apps.';

  @override
  String get permissionsStorageTitle => 'Storage';

  @override
  String get permissionsStorageWhy =>
      'For backups: they\'re kept in the Download/HomeSystem folder, so they survive uninstalling the app. Home System only reads and writes its own backup files there.';

  @override
  String get permissionsAllFilesTitle => 'All files access';

  @override
  String get permissionsAllFilesWhy =>
      'Only for backups: new backups in Download/HomeSystem work without it. Home System only needs this access to find an earlier installation\'s backups after reinstalling - and only reads its own backup files there.';

  @override
  String get permissionsRecordAudioTitle => 'Record audio';

  @override
  String get permissionsRecordAudioWhy =>
      'Only for the music visualisation (“Follows the music”): it reads the frequency spectrum of the app\'s own playback. Android calls that “record audio” and mentions the microphone - but the microphone is never used, nothing is recorded or stored.';

  @override
  String get permissionsUsbTitle => 'USB stick for DAB+ and FM';

  @override
  String get permissionsUsbWhy =>
      'When you plug in an RTL-SDR stick, Android asks once whether Home System may use it. Just choose “OK” (with “Always”, if offered) - Home System only uses that stick.';

  @override
  String get permissionsNotificationsTitle => 'Notifications';

  @override
  String get permissionsNotificationsWhy =>
      'Home System doesn\'t ask for them and sends no notifications. While radio or music is playing, Android shows the playback controls - that needs no permission.';

  @override
  String get permissionsAdvanced => 'For advanced users';

  @override
  String get permissionsSecureSettingsTitle => 'Change system settings';

  @override
  String get permissionsSecureSettingsWhy =>
      'Can only be granted from a computer via adb and isn\'t needed. With it, Home System switches the Home key service on by itself - also when Android switched it off after an update. Home System changes nothing else with it.';

  @override
  String get permissionsRestrictedWhy =>
      'From Android 13 on, Android blocks accessibility services of apps that don\'t come from an app store (“restricted settings”). This command lifts that:';

  @override
  String get permissionsWizardTitle => 'Permissions (optional)';

  @override
  String get permissionsWizardHint =>
      'Here\'s what Home System needs which permission for. None of it is required - “Later” always works, and everything can be done later under Settings → System → Permissions.';

  @override
  String permissionsWizardCounter(int index, int count) {
    return 'Permission $index of $count';
  }

  @override
  String get permissionsWizardNoneLeft => 'That\'s it for permissions.';

  @override
  String get permissionsWizardNoneLeftHint =>
      'You\'ll find all of this later under Settings → System → Permissions.';

  @override
  String get picturesTitle => 'Pictures';

  @override
  String get picturesAreaSubtitle => 'Photos from the NAS, slideshow';

  @override
  String get picturesSettingsTitle => 'Picture settings';

  @override
  String get picturesAdminPart => 'Pictures switched on';

  @override
  String get picturesNoFolder =>
      'No pictures folder chosen yet. Set in the NAS settings where your photos are.';

  @override
  String get picturesOpenNasSettings => 'Open NAS settings';

  @override
  String picturesLoadError(String message) {
    return 'The folder can\'t be read.\n$message';
  }

  @override
  String picturesSlideshowWithSubfolders(String folder) {
    return 'Slideshow: $folder (with subfolders)';
  }

  @override
  String picturesSlideshow(String folder) {
    return 'Slideshow: $folder';
  }

  @override
  String picturesCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count pictures',
      one: '1 picture',
      zero: 'no pictures',
    );
    return '$_temp0';
  }

  @override
  String picturesFolderCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count folders',
      one: '1 folder',
    );
    return '$_temp0';
  }

  @override
  String get picturesEmptyFolder => 'There are no pictures in this folder.';

  @override
  String picturesBrowserHint(String options) {
    return 'OK opens · OK on a picture: slideshow from that picture · ⏯ or $options starts the folder\'s slideshow · Back goes up one level';
  }

  @override
  String get picturesSearching => 'Looking for pictures …';

  @override
  String get picturesNoneFound =>
      'There are no pictures here - not in the subfolders either.';

  @override
  String get picturesStillSearching => 'still looking …';

  @override
  String get picturesPaused => 'Paused';

  @override
  String picturesSlideshowHint(String options) {
    return '← → back/next · OK pause · $options settings · Back ends';
  }

  @override
  String get picturesInterval => 'Next picture after';

  @override
  String picturesIntervalSeconds(int seconds) {
    return '$seconds seconds';
  }

  @override
  String get picturesOrder => 'Order';

  @override
  String get picturesOrderFolders => 'Folder by folder, by name';

  @override
  String get picturesOrderShuffled => 'Shuffled';

  @override
  String get picturesOrderNextTime =>
      'The order applies from the next slideshow.';

  @override
  String get picturesBlur => 'Fill the edges with the blurred picture';

  @override
  String get picturesFolder => 'Pictures folder';

  @override
  String get picturesMusicHelp =>
      'Radio and music simply keep playing during the slideshow.';

  @override
  String get picturesSlideshowHeading => 'Slideshow';

  @override
  String picturesInThisFolder(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count pictures in this folder',
      one: '1 picture in this folder',
    );
    return '$_temp0 - OK on a picture starts the slideshow from there';
  }

  @override
  String picturesResumeFrom(int position, String name) {
    return 'Continue from picture $position ($name)';
  }

  @override
  String get picturesResumeRestart => 'From the start';

  @override
  String get radioErrorConnectionLost =>
      'Lost connection to the station - retrying…';

  @override
  String get radioErrorStationUnreachable =>
      'Station not reachable - retrying…';

  @override
  String radioErrorPlayback(String message) {
    return 'Playback error: $message';
  }

  @override
  String get radioSourceFm => 'FM';

  @override
  String get radioSourceInternet => 'Internet radio';

  @override
  String get radioMoonNew => 'New moon';

  @override
  String get radioMoonWaxingCrescent => 'Waxing crescent';

  @override
  String get radioMoonFirstQuarter => 'First quarter';

  @override
  String get radioMoonWaxingGibbous => 'Waxing gibbous';

  @override
  String get radioMoonFull => 'Full moon';

  @override
  String get radioMoonWaningGibbous => 'Waning gibbous';

  @override
  String get radioMoonLastQuarter => 'Last quarter';

  @override
  String get radioMoonWaningCrescent => 'Waning crescent';

  @override
  String get radioFmSameProgrammeStronger => '(stronger)';

  @override
  String get radioFmSameProgrammeWeaker => '(weaker)';

  @override
  String radioFmSameProgrammeAlsoOn(String frequency) {
    return 'also on $frequency';
  }

  @override
  String get radioDabEnsembleUnknown => 'Unknown ensemble';

  @override
  String radioPlaceSearchFailed(int code) {
    return 'Place search: HTTP $code';
  }

  @override
  String get radioProgramNumberTitle => 'Set program number';

  @override
  String get radioEditStationTitle => 'Edit station';

  @override
  String get radioEditStationName => 'Name';

  @override
  String get radioEditStationSearchLogo => 'Find logo';

  @override
  String get radioEditStationUseLiveImage => 'Use the station\'s current image';

  @override
  String get radioEditStationNewLogoHint => 'New logo - applied with \"Save\".';

  @override
  String get radioLogoDabIdle =>
      'Gets the image the station broadcasts itself.';

  @override
  String get radioLogoDabWaiting =>
      'Waiting for an image from the station (up to about 30 s)…';

  @override
  String get radioLogoDabUseImage => 'Use this image';

  @override
  String get radioLogoDabNone => 'The station didn\'t send an image in time.';

  @override
  String get radioDabDecoderFailed => 'Couldn\'t start the DAB+ decoder.';

  @override
  String get radioLogoDabFetch => 'Get DAB logo';

  @override
  String get radioLogoTitle => 'Choose logo';

  @override
  String get radioLogoSearchInternet => 'Search the internet (station name)';

  @override
  String get radioLogoNoResults => 'No results with a logo.';

  @override
  String get radioLogoOwnUrl => 'or your own image address (URL)';

  @override
  String get radioRegionEurope => 'Europe';

  @override
  String get radioRegionNorthAmerica => 'North & Central America';

  @override
  String get radioRegionSouthAmerica => 'South America';

  @override
  String get radioRegionAsia => 'Asia & Middle East';

  @override
  String get radioRegionAfrica => 'Africa';

  @override
  String get radioRegionOceania => 'Oceania';

  @override
  String get radioRegionOther => 'Other';

  @override
  String radioSavedAsNumber(String name, int number) {
    return '\"$name\" saved as no. $number.';
  }

  @override
  String get radioSearchInternetTitle => 'Find internet radio';

  @override
  String get radioSearchStationName => 'Station name';

  @override
  String get radioSearchGenre => 'Genre';

  @override
  String get radioSearchAllGenres => 'All genres';

  @override
  String get radioSearchRegion => 'Region';

  @override
  String get radioSearchAllRegions => 'All regions';

  @override
  String get radioSearchCountry => 'Country';

  @override
  String get radioSearchAllCountries => 'All countries';

  @override
  String get radioSearchButton => 'Search';

  @override
  String get radioSearchNoResults => 'No results.';

  @override
  String get radioStop => 'Stop';

  @override
  String get radioSearchPreview => 'Preview';

  @override
  String get radioSearchAddFavorite => 'Favorite';

  @override
  String get radioDabClearAllTitle => 'Delete all DAB stations?';

  @override
  String get radioDabClearAllMessage =>
      'Removes all DAB+ stations found so far from the \"All DAB+ stations\" list, and all DAB+ favorites. This can\'t be undone.';

  @override
  String get radioDabTitle => 'DAB+ stations';

  @override
  String get radioScanTitle => 'Station scan';

  @override
  String get radioDabClearAll => 'Delete all DAB stations';

  @override
  String get radioFavorites => 'Favorites';

  @override
  String get radioDabNoFavorites => 'No DAB+ favorites yet.';

  @override
  String get radioDabAllStations => 'All DAB+ stations';

  @override
  String get radioDabSortGrouped => 'Grouped by ensemble';

  @override
  String get radioDabSortByEnsemble => 'Sorted by ensemble';

  @override
  String get radioDabSortByName => 'By name';

  @override
  String get radioDabNoStations =>
      'No stations found yet. Start a station scan.';

  @override
  String get radioLogoReceiveAllHaveLogo => 'All stations already have a logo.';

  @override
  String radioLogoReceiveProgress(int index, int total) {
    return 'Station $index of $total - waiting for an image from the station…';
  }

  @override
  String radioLogoReceiveDone(int found, int total) {
    return 'Done: $found of $total stations sent an image.';
  }

  @override
  String get radioLogoReceiveTitle => 'Missing logos over the air';

  @override
  String get radioLogoReceiveStart => 'Get missing logos over the air';

  @override
  String get radioListen => 'Listen';

  @override
  String get radioEditNameLogo => 'Edit (name, logo)';

  @override
  String get radioRemoveFavorite => 'Remove favorite';

  @override
  String radioProgramNumberChip(int number) {
    return 'No. $number';
  }

  @override
  String get radioAddFavorite => 'Add favorite';

  @override
  String get radioSourceUsbHint =>
      'Source: RTL-SDR stick via USB - see \"Radio receiver\" in the settings.';

  @override
  String get radioSourceNetworkHint =>
      'Source: RTL-SDR over the network - see \"Radio receiver\" in the settings.';

  @override
  String get radioScanStart => 'Start station scan';

  @override
  String get radioDabSingleChannel => 'Scan a single channel:';

  @override
  String radioDabSearchChannel(String channel) {
    return 'Scan $channel';
  }

  @override
  String radioPlaybackOfFailed(String name) {
    return 'Couldn\'t play \"$name\".';
  }

  @override
  String radioDabSearchChannelTitle(String channel) {
    return 'Scan channel $channel';
  }

  @override
  String radioDabScanningChannel(String channel, int freqKhz) {
    return 'Scanning $channel ($freqKhz kHz), up to 15 seconds…';
  }

  @override
  String radioDabScanProgressOf(int index, int total, String label) {
    return 'Channel $index of $total: $label';
  }

  @override
  String radioDabScanProgress(int index, String label) {
    return 'Channel $index: $label';
  }

  @override
  String radioDabChannelNothingFound(String channel) {
    return 'No DAB+ ensemble received on $channel.';
  }

  @override
  String radioDabScanDone(int ensembles, int stations) {
    String _temp0 = intl.Intl.pluralLogic(
      ensembles,
      locale: localeName,
      other: '$ensembles ensembles',
      one: '1 ensemble',
    );
    String _temp1 = intl.Intl.pluralLogic(
      stations,
      locale: localeName,
      other: '$stations stations',
      one: '1 station',
    );
    return 'Done: found $_temp0 with $_temp1. All found stations are listed under \"All DAB+ stations\".';
  }

  @override
  String get radioDabNoEnsemblesYet => 'No ensembles found yet…';

  @override
  String get radioDabEnsembleNameUnknown => 'Ensemble name unknown';

  @override
  String get radioDabEnsembleNoServices =>
      'Stations in this ensemble not detected yet (try again shortly).';

  @override
  String get radioPlayingShort => 'Playing…';

  @override
  String get radioStopPlayback => 'Stop playback';

  @override
  String get radioFmClearAllTitle => 'Delete all FM stations?';

  @override
  String get radioFmClearAllMessage =>
      'Removes all saved FM stations from the list. FM favorites are kept.';

  @override
  String get radioFmTitle => 'FM stations';

  @override
  String get radioFmFindStations => 'Find stations';

  @override
  String get radioFmTuneManually => 'Tune manually';

  @override
  String get radioFmAllStations => 'All FM stations';

  @override
  String get radioDeleteAll => 'Delete all';

  @override
  String get radioFmNoStations =>
      'No FM stations yet. Start a scan, or tune in a station manually and save it.';

  @override
  String radioFmSignal(String level) {
    return 'Signal $level';
  }

  @override
  String get radioRemoveStation => 'Remove station';

  @override
  String get radioFmScanTitle => 'FM station scan';

  @override
  String get radioReceiverFailed => 'Couldn\'t start the receiver.';

  @override
  String get radioSearching => 'Searching…';

  @override
  String radioFmScanSurvey(String frequency) {
    return 'Step 1/2: measuring the band ($frequency)…';
  }

  @override
  String radioFmScanProbe(int index, int total, String frequency) {
    return 'Step 2/2: checking station $index of $total ($frequency)…';
  }

  @override
  String radioFmScanDone(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count stations',
      one: '1 station',
    );
    return 'Done: $_temp0 found and saved.';
  }

  @override
  String radioFmScanImagesRemoved(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count weak spurious frequencies',
      one: '1 weak spurious frequency',
    );
    return '$_temp0 removed.';
  }

  @override
  String get radioFmSeekNothingFound => 'No further station found.';

  @override
  String get radioFmFrequencyTitle => 'Frequency in MHz';

  @override
  String get radioFmFrequencyHint => 'e.g. 99.9';

  @override
  String radioSaved(String name) {
    return '$name saved.';
  }

  @override
  String get radioFmTuneTitle => 'Tune FM manually';

  @override
  String get radioFmNoRdsName => 'no RDS name';

  @override
  String get radioFmSeek => 'Seek';

  @override
  String get radioFmStepDown => '−0.05';

  @override
  String get radioFmStepUp => '+0.05';

  @override
  String get radioFmEnterFrequency => 'Enter frequency';

  @override
  String get radioFmSaveStation => 'Save as station';

  @override
  String get radioFmSaveFavorite => 'Save as favorite';

  @override
  String get radioNoStationSelected => 'No station selected';

  @override
  String get radioStoppedDisconnected => 'Stopped - disconnected';

  @override
  String get radioNowPlaying => 'Now playing';

  @override
  String get radioPaused => 'Paused';

  @override
  String get radioPlay => 'Play';

  @override
  String get radioWeatherUnavailable => 'Weather not available - retrying…';

  @override
  String get radioWeatherNoData => 'No data';

  @override
  String get radioWeatherTemp => 'Temp';

  @override
  String get radioWeatherWind => 'Wind km/h';

  @override
  String get radioWeatherRain => 'Rain mm';

  @override
  String radioWeatherRainAmount(String amount) {
    return '$amount mm';
  }

  @override
  String get radioSunrise => 'Sunrise';

  @override
  String get radioSunset => 'Sunset';

  @override
  String get radioDawn => 'Dawn';

  @override
  String get radioSolarNoon => 'Noon';

  @override
  String get radioDusk => 'Dusk';

  @override
  String radioRadarLoginRejected(int code) {
    return 'Login rejected (HTTP $code)';
  }

  @override
  String get radioRadarIsWebPage =>
      'the address is a web page, not an image - choose the type \"Web page\"';

  @override
  String get radioRadarNotConfigured =>
      'No weather radar set up -\nSettings → Weather radar → Source';

  @override
  String get radioRadarWebPageAndroidOnly =>
      'Web pages as a radar source are only available in the Android version.';

  @override
  String radioRadarUnreachable(String error) {
    return 'Radar not reachable: $error';
  }

  @override
  String radioRadarStale(String time) {
    return 'As of $time · not reachable';
  }

  @override
  String get radioLinkSourceLost => 'Lost connection to the RTL-SDR source';

  @override
  String get radioLinkDabSignalFound => 'DAB signal found';

  @override
  String radioLinkEnsembleFound(String label) {
    return 'Ensemble \"$label\" found';
  }

  @override
  String get radioLinkStationFound => 'Station found - starting audio…';

  @override
  String get radioLinkConnected => 'Station connected';

  @override
  String get radioLinkConnectingServer => 'Connecting to the RTL server…';

  @override
  String get radioLinkWaitingForStick => 'Waiting for the stick on the server…';

  @override
  String get radioLinkOpeningUsbStick => 'Opening the USB stick…';

  @override
  String get radioLinkTuning => 'Tuning in the station…';

  @override
  String radioLinkTuningFrequency(String frequency) {
    return 'Tuning to $frequency…';
  }

  @override
  String get radioLinkSearching => 'Searching for the station…';

  @override
  String radioLinkSearchingChannel(String channel) {
    return 'Searching channel $channel…';
  }

  @override
  String get radioLinkApp => 'App';

  @override
  String get radioLinkRtlServer => 'RTL server';

  @override
  String get radioLinkStick => 'Stick';

  @override
  String get radioLinkUsbStick => 'USB stick';

  @override
  String get radioLinkStation => 'Station';

  @override
  String get radioLinkTvChannel => 'Channel';

  @override
  String get radioDone => 'Done';

  @override
  String get radioEditFavorites => 'Edit favorites';

  @override
  String get radioEditFavoritesHint =>
      'Reorder, rename or remove - press ✓ when done.';

  @override
  String radioFavoritesLoadError(String error) {
    return 'Couldn\'t load the favorites:\n$error';
  }

  @override
  String get radioNoFavorites =>
      'No favorites yet.\nFind stations via the menu.';

  @override
  String get radioRemoveFavoriteTitle => 'Remove favorite?';

  @override
  String radioRemoveFavoriteMessage(String name) {
    return 'Remove \"$name\" from the favorites?';
  }

  @override
  String get radioRemove => 'Remove';

  @override
  String get radioSidebarNoFmStations =>
      'No FM stations yet.\nScan or tune manually via the FM menu above.';

  @override
  String radioDabStationsLoadError(String error) {
    return 'Couldn\'t load the DAB+ stations:\n$error';
  }

  @override
  String get radioSidebarNoDabStations =>
      'No DAB+ stations found yet.\nStart a station scan via the DAB menu.';

  @override
  String get radioMoveUp => 'Move up';

  @override
  String get radioMoveDown => 'Move down';

  @override
  String get radioLinkBuffering => 'Buffering the stream…';

  @override
  String get radioLinkConnectingStation => 'Connecting to the station…';

  @override
  String get radioPausedOtherApp => 'Paused - another app is playing audio.';

  @override
  String get radioSourceLostReconnecting =>
      'Lost connection to the RTL-SDR source - reconnecting…';

  @override
  String get radioUsbStickDetached =>
      'USB stick unplugged - waiting for it to be plugged in again…';

  @override
  String get radioNoReceiverConfigured => 'No radio receiver set up (Settings)';

  @override
  String get radioFmReceptionFailedDot => 'FM reception failed.';

  @override
  String get radioFmReceptionFailed => 'FM reception failed';

  @override
  String get radioSourceUnreachableRetrying =>
      'RTL-SDR source not reachable - retrying…';

  @override
  String get radioSourceUnreachable => 'RTL-SDR source not reachable.';

  @override
  String get radioRtlServerUnreachableRetrying =>
      'RTL server not reachable - retrying…';

  @override
  String get radioRtlServerUnreachable => 'RTL server not reachable';

  @override
  String get radioUsbStickNotFound => 'USB stick not found or no access';

  @override
  String get radioNoSignalRetrying => 'No signal! - Retrying…';

  @override
  String get radioNoSignal => 'No signal!';

  @override
  String get radioLinkNoSignalRetrying => 'No signal - retrying…';

  @override
  String get radioMenuListening => 'Scanner';

  @override
  String get radioMenuDabStations => 'Find DAB stations';

  @override
  String get radioMenuAmBands => 'LW/MW/SW';

  @override
  String get radioMenuSettings => 'Radio settings';

  @override
  String scannerQuoted(String name) {
    return '“$name”';
  }

  @override
  String scannerRtlUnreachable(String server, String error) {
    return 'rtl_tcp server $server unreachable ($error)';
  }

  @override
  String scannerRtlConnectionLost(String error) {
    return 'Connection to the rtl_tcp server lost ($error)';
  }

  @override
  String get scannerRtlRefused =>
      'The rtl_tcp server refused the connection (busy or no stick ready)';

  @override
  String get scannerRtlConnectionClosed =>
      'Connection to the rtl_tcp server closed';

  @override
  String get scannerRtlNoAnswer => 'The rtl_tcp server isn\'t responding';

  @override
  String get scannerRtlNotAServer => 'Not an rtl_tcp server (unknown greeting)';

  @override
  String get scannerRtlBadStream => 'rtl_tcp server: corrupt data stream';

  @override
  String get scannerRtlStickAtServer => 'USB stick at the rtl_tcp server';

  @override
  String get scannerRtlAuthUnsupported =>
      'The rtl_tcp server requires a login, which is no longer supported. Please use the rtltcp.server on the local network.';

  @override
  String scannerRtlStickReady(String stick) {
    return '$stick ready';
  }

  @override
  String scannerRtlStickStarting(String stick) {
    return '$stick starting …';
  }

  @override
  String scannerRtlStickNotReady(String stick) {
    return '$stick not ready';
  }

  @override
  String scannerRtlStickLost(String stick) {
    return '$stick disconnected – the server is reconnecting …';
  }

  @override
  String get scannerRtlServer => 'rtl_tcp server';

  @override
  String scannerRtlBusy(String who) {
    return '$who is already in use by another device';
  }

  @override
  String scannerRtlBusyBy(String who, String client) {
    return '$who is already in use by $client';
  }

  @override
  String get scannerRtlKicked => 'Disconnected by the rtl_tcp server';

  @override
  String get scannerRtlProtocolError =>
      'The rtl_tcp server reports a protocol error';

  @override
  String scannerRtlServerSays(String message) {
    return 'rtl_tcp server: $message';
  }

  @override
  String get scannerRtlStateStarting => 'starting';

  @override
  String get scannerRtlStateNotReady => 'not ready';

  @override
  String get scannerRtlStateLost => 'disconnected';

  @override
  String get scannerRtlStateIdle => 'idle';

  @override
  String scannerRtlSticksOn(String host) {
    return 'Sticks on $host';
  }

  @override
  String scannerRtlLocation(String location) {
    return 'Location: $location';
  }

  @override
  String scannerRtlAntenna(String antenna) {
    return 'Antenna: $antenna';
  }

  @override
  String get scannerRtlNotSpecified => 'not set';

  @override
  String scannerRtlVia(String instance) {
    return 'via $instance';
  }

  @override
  String scannerRtlBusyByShort(String client) {
    return 'in use by $client';
  }

  @override
  String get scannerRtlReceiverTitle => 'Radio receiver (DAB+ & FM)';

  @override
  String get scannerRtlReceiverLabel => 'Receiver:';

  @override
  String get scannerRtlModeNone => 'No receiver (internet radio only)';

  @override
  String get scannerRtlModeUsb => 'RTL-SDR stick via USB';

  @override
  String get scannerRtlModeTcp => 'RTL-SDR over the network (rtl_tcp)';

  @override
  String get scannerRtlNoneHint =>
      'DAB+ and FM scanning and the “DAB+” and “FM” tabs are hidden. Existing favorites are kept and play again once a receiver is set up.';

  @override
  String get scannerRtlUsbHint =>
      'The receiver opens the stick directly over USB as soon as a station starts.';

  @override
  String get scannerRtlUsbWindows =>
      'Windows: install the WinUSB driver once with Zadig (zadig.akeo.ie) for “Bulk-In, Interface (Interface 0)”.';

  @override
  String get scannerRtlUsbLinux =>
      'Linux: needs a udev rule for the stick (e.g. from the rtl-sdr package); the kernel\'s DVB-T driver is detached automatically.';

  @override
  String get scannerRtlNoStick => 'No RTL-SDR stick found.';

  @override
  String get scannerRtlAllowAccess => 'Allow access';

  @override
  String get scannerRtlAccessGranted => 'Access granted';

  @override
  String get scannerRtlRescan => 'Search again';

  @override
  String get scannerRtlTcpHint =>
      'rtl_tcp servers on the local network: driver app on this device (127.0.0.1), Raspberry Pi or rtltcp.server. The marked server is the default for DAB+ and FM. rtltcp.server makes sticks at other locations available locally via rtl.over.internet.';

  @override
  String get scannerRtlAddServer => 'Add server';

  @override
  String get scannerRtlTestHint =>
      '“Test” interrupts DAB+ or FM if it runs over this server; the station resumes when you come back.';

  @override
  String get scannerRtlDefault => 'Default';

  @override
  String get scannerRtlTest => 'Test';

  @override
  String scannerRtlChooseStick(int count) {
    return 'Choose stick ($count)';
  }

  @override
  String get scannerRtlRemove => 'Remove';

  @override
  String get scannerRtlNoConnection => 'No connection';

  @override
  String get scannerRtlClassicServer =>
      'rtl_tcp – the server doesn\'t support location and antenna';

  @override
  String scannerRtlProtocol(String name) {
    return 'Protocol: $name';
  }

  @override
  String scannerRtlTunerInfo(String type, String gains) {
    return 'Tuner type: $type, $gains gain steps';
  }

  @override
  String get scannerAprsCompass => 'N NE E SE S SW W NW';

  @override
  String get scannerAprsKindPosition => 'Position';

  @override
  String get scannerAprsKindWeather => 'Weather';

  @override
  String get scannerAprsKindObject => 'Object';

  @override
  String get scannerAprsKindObjectDeleted => 'Object (deleted)';

  @override
  String get scannerAprsKindMessage => 'Message';

  @override
  String get scannerAprsKindAck => 'Acknowledgement';

  @override
  String get scannerAprsKindTelemetry => 'Telemetry';

  @override
  String get scannerAprsKindCapabilities => 'Capabilities';

  @override
  String get scannerAprsKindThirdParty => 'Third party';

  @override
  String get scannerAprsKindData => 'Data';

  @override
  String get scannerAprsKindEmpty => 'Empty';

  @override
  String scannerWind(String speed) {
    return 'Wind $speed km/h';
  }

  @override
  String scannerWindFrom(int degrees) {
    return 'from $degrees°';
  }

  @override
  String scannerGusts(String speed) {
    return 'gusts $speed';
  }

  @override
  String scannerAprsRain(String rate) {
    return 'Rain $rate mm/h';
  }

  @override
  String get scannerAprsSymbolWeatherStation => 'Weather station';

  @override
  String get scannerAprsSymbolHouse => 'House';

  @override
  String get scannerAprsSymbolCar => 'Car';

  @override
  String get scannerAprsSymbolAmbulance => 'Ambulance';

  @override
  String get scannerAprsSymbolNode => 'Node';

  @override
  String get scannerAprsSymbolTruck => 'Truck';

  @override
  String get scannerAprsSymbolAircraft => 'Aircraft';

  @override
  String get scannerAprsSymbolBalloon => 'Balloon';

  @override
  String get scannerAprsSymbolRepeater => 'Repeater';

  @override
  String get scannerAprsSymbolRv => 'RV';

  @override
  String get scannerAprsSymbolMotorcycle => 'Motorcycle';

  @override
  String get scannerAprsSymbolBicycle => 'Bicycle';

  @override
  String get scannerAprsSymbolPedestrian => 'Pedestrian';

  @override
  String get scannerAprsSymbolAntennaStation => 'Station with antenna';

  @override
  String get scannerAprsSymbolShip => 'Ship';

  @override
  String get scannerAprsSymbolSmallAircraft => 'Small aircraft';

  @override
  String get scannerAprsSymbolHelicopter => 'Helicopter';

  @override
  String get scannerAprsSymbolFireTruck => 'Fire truck';

  @override
  String get scannerAprsSymbolPolice => 'Police';

  @override
  String get scannerAprsSymbolSatellite => 'Satellite';

  @override
  String get scannerAprsSymbolTrain => 'Train';

  @override
  String scannerChannel(String channel) {
    return 'Channel $channel';
  }

  @override
  String get scannerBandCb => 'CB radio';

  @override
  String get scannerMarkEmergency => 'Emergency';

  @override
  String get scannerCbTruckers => 'Truckers';

  @override
  String get scannerSegCbFm => 'FM voice (channel 9 emergency, 19 truckers)';

  @override
  String get scannerSegCbSsb => 'SSB section (channels 36–40)';

  @override
  String get scannerBandAir => 'Airband';

  @override
  String get scannerBandMil => 'Military radio';

  @override
  String get scannerSegMilAir => 'Military airband';

  @override
  String scannerBandHam(String band) {
    return 'Amateur radio $band';
  }

  @override
  String get scannerSegCw => 'CW';

  @override
  String get scannerSegDigital => 'Digital modes';

  @override
  String get scannerSegVoiceLsb => 'Voice (LSB)';

  @override
  String get scannerSegVoiceUsb => 'Voice (USB)';

  @override
  String get scannerSegVoiceSsb => 'Voice (SSB)';

  @override
  String get scannerSegDigitalVoiceUsb => 'Digital & voice (USB)';

  @override
  String get scannerSegBeacons => 'Beacons';

  @override
  String get scannerSegDigitalAllModes => 'Digital & all modes';

  @override
  String get scannerSegBeaconsAllModes => 'Beacons & all modes';

  @override
  String get scannerSegAmVoice => 'AM voice';

  @override
  String get scannerSegFmSimplex => 'FM simplex';

  @override
  String get scannerSegPacket => 'Digital (packet)';

  @override
  String get scannerSegSatellites => 'Satellites';

  @override
  String get scannerSegRepeaterInputs => 'FM repeater inputs';

  @override
  String get scannerSegRepeaterOutputs => 'FM repeater outputs';

  @override
  String scannerSegFmSimplexCall(String frequency) {
    return 'FM simplex ($frequency calling)';
  }

  @override
  String get scannerMarkCall => 'Calling';

  @override
  String get scannerSegCwBeacons => 'CW & beacons';

  @override
  String scannerSegSsbVoiceCall(String frequency) {
    return 'Voice (SSB, $frequency calling)';
  }

  @override
  String get scannerSegAllModes => 'All modes';

  @override
  String get scannerSegCwEme => 'CW (EME)';

  @override
  String get scannerSegAllModesSstv => 'All modes (SSTV, digital)';

  @override
  String scannerSegDigitalAprs(String frequency) {
    return 'Digital ($frequency APRS)';
  }

  @override
  String scannerSegSatellitesIss(String frequency) {
    return 'Satellites ($frequency ISS)';
  }

  @override
  String get scannerSegDigitalRepeaterInputs => 'Digital & repeater inputs';

  @override
  String get scannerSegRepeaterInputsLpd => 'FM repeater inputs, LPD radios';

  @override
  String scannerSegFmSimplexCallLpd(String frequency) {
    return 'FM simplex ($frequency calling), LPD';
  }

  @override
  String scannerSegLpdIsm(String frequency) {
    return 'LPD radios & ISM ($frequency sensors)';
  }

  @override
  String get scannerMarkSensors => 'Sensors';

  @override
  String get scannerSegRepeaterOutputsDigital =>
      'Repeater outputs (incl. DMR/C4FM)';

  @override
  String get scannerSegAtv => 'Amateur TV (ATV)';

  @override
  String get scannerSegSatellitesUplink => 'Satellites (uplink)';

  @override
  String get scannerSegAtvDigital => 'ATV & digital';

  @override
  String get scannerBandLongWave => 'Long wave';

  @override
  String get scannerBandMediumWave => 'Medium wave';

  @override
  String scannerBandShortwave(String band) {
    return 'Shortwave $band';
  }

  @override
  String scannerUtilTimeSignal(String station) {
    return 'Time signal $station';
  }

  @override
  String scannerUtilWeatherFax(String station) {
    return 'Weather fax $station';
  }

  @override
  String scannerUtilWeatherRtty(String station) {
    return 'Weather RTTY $station';
  }

  @override
  String get scannerBandHfUtility => 'Shortwave utility';

  @override
  String get scannerSegFmBroadcast => 'FM broadcast';

  @override
  String get scannerSegAirNavVorIls => 'Air navigation (VOR/ILS)';

  @override
  String get scannerSegWeatherSatellites => 'Weather satellites';

  @override
  String get scannerSegLandMobile => 'Land mobile';

  @override
  String get scannerSegLandMobileBos => 'Land mobile / emergency services';

  @override
  String scannerSegMarine(String frequency) {
    return 'Marine VHF (channel 16 = $frequency)';
  }

  @override
  String get scannerSegLandMobileRail => 'Land mobile / railway';

  @override
  String get scannerSegDab => 'DAB+ Band III (digital, not audible)';

  @override
  String get scannerSegRadiosondes => 'Radiosondes';

  @override
  String get scannerSegDistressBeacons => 'Distress beacons (digital)';

  @override
  String get scannerSegDvbt => 'TV DVB-T2 (digital)';

  @override
  String get scannerSegLte => 'Mobile LTE (digital)';

  @override
  String get scannerSegSensorsLora => 'Wireless sensors / LoRa 868';

  @override
  String get scannerSegGsm => 'Mobile / GSM-R (digital)';

  @override
  String get scannerSegAirNavDme => 'Air navigation (DME)';

  @override
  String get scannerSegAdsb => 'ADS-B 1090 (→ aircraft)';

  @override
  String get scannerSegGnss => 'Satellite navigation (GNSS)';

  @override
  String get scannerSegSatPhone => 'Satellite phones (Inmarsat)';

  @override
  String get scannerBandWorld => 'Free band scan';

  @override
  String get scannerJumpMarine => 'Marine channel 16';

  @override
  String get scannerJumpMilAir => 'Military airband';

  @override
  String get scannerSensors => 'Wireless sensors';

  @override
  String scannerJumpRepeaters70(String frequency) {
    return 'Repeaters 70 cm ($frequency)';
  }

  @override
  String get scannerHubTitle => 'Scanner';

  @override
  String get scannerHubCbSubtitle => '26.965–27.405 MHz · Channels 1–40 (80)';

  @override
  String get scannerHubPmrSubtitle => '446.00625–446.19375 MHz · Channels 1–16';

  @override
  String get scannerHubHam => 'Amateur radio';

  @override
  String get scannerHubHamSubtitle => '160 m to 23 cm with band plan';

  @override
  String get scannerHubShortwave => 'Shortwave';

  @override
  String get scannerHubShortwaveSubtitle =>
      'Shortwave broadcast · HF amateur radio · Time signals & aviation weather';

  @override
  String get scannerHubAircraft => 'Aircraft';

  @override
  String get scannerHubAircraftSubtitle => 'Airband · ACARS · Radar (ADS-B)';

  @override
  String get scannerHubSensorsSubtitle =>
      '433/868 MHz · Thermometers, weather stations, switches';

  @override
  String get scannerHubWorldSubtitle =>
      'Tune freely from 0.5 to 1766 MHz, bands marked';

  @override
  String get scannerHubAirSubtitle => '118–137 MHz · Voice (AM)';

  @override
  String get scannerHubAcarsSubtitle =>
      '131.5–131.9 MHz · Text messages from aircraft';

  @override
  String get scannerHubAdsbSubtitle =>
      '1090 MHz · Flight number, altitude, position on the map';

  @override
  String get scannerUpconverterNone =>
      'None – direct sampling or RTL-SDR Blog V4';

  @override
  String get scannerUpconverterDialogTitle =>
      'Upconverter in front of the stick';

  @override
  String get scannerUpconverter => 'Upconverter';

  @override
  String get scannerHubHfHam => 'HF amateur radio';

  @override
  String get scannerHubHfHamSubtitle => '160 m to 10 m · SSB, CW, FT8';

  @override
  String get scannerHubHfUtilitySubtitle =>
      'Time signals · VOLMET · Shanwick · Weather fax';

  @override
  String get scannerHubShortwaveFooter =>
      'Shortwave needs a stick with a shortwave input: RTL-SDR Blog V3 (direct sampling, switches over automatically below 24 MHz), RTL-SDR Blog V4 (built-in upconverter; over rtl_tcp only if the server supports it) – or any stick with an upconverter such as the Ham It Up. Ordinary sticks (e.g. NooElec NESDR) don\'t have one. Plus a shortwave antenna – a long wire or an active antenna. Broadcasting on long, medium and shortwave: its own “LW/MW/SW” entry above.';

  @override
  String get scannerRxWaiting => 'Waiting for data from the stick…';

  @override
  String get scannerRxNoData => 'No data from the stick';

  @override
  String get scannerRxSlow => 'Data arriving too slowly';

  @override
  String get scannerRxRunning => 'Receiving';

  @override
  String get scannerRxLevel => 'Level';

  @override
  String get scannerRxClipping => 'overloaded – lower the gain';

  @override
  String get scannerMapAttribution => '© OpenStreetMap contributors';

  @override
  String get scannerReceiverStartFailed => 'Couldn\'t start the receiver.';

  @override
  String get scannerReceiverStarting => 'Starting receiver…';

  @override
  String get scannerGain => 'Gain';

  @override
  String get scannerAcarsTitle => 'ACARS (text messages from aircraft)';

  @override
  String get scannerAcarsVdl2Chip => 'VDL2 · 136.9 MHz';

  @override
  String get scannerAcarsClassicChip => 'Classic ACARS · 131 MHz';

  @override
  String scannerAcarsMessageCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count messages',
      one: '1 message',
    );
    return '$_temp0';
  }

  @override
  String scannerAcarsHint(int count) {
    return 'All $count channels are decoded at once. Green dot = message in the last 10 s, green bar = someone is transmitting on the channel right now.';
  }

  @override
  String get scannerAcarsVdl2Hint =>
      'VDL2 is digital: ground stations and aircraft send short data packets, text messages (ACARS) are part of them.';

  @override
  String scannerAcarsWaiting(String antenna) {
    return 'Waiting for messages… With air traffic nearby there are usually several a minute.\nAntenna for $antenna (quarter wave) - as clear as possible, at a window.';
  }

  @override
  String scannerAcarsAntenna(String frequency, String length) {
    return '$frequency MHz: vertical, ~$length cm';
  }

  @override
  String get scannerAcarsTryVdl2 =>
      'In Europe most aircraft now send via VDL2 - if nothing comes in here, switch to VDL2 above.';

  @override
  String get scannerColTime => 'Time';

  @override
  String get scannerColFlight => 'Flight';

  @override
  String get scannerColRegistration => 'Registration';

  @override
  String get scannerColType => 'Type';

  @override
  String scannerAcarsReceived(String time, String frequency) {
    return 'Received $time on $frequency MHz';
  }

  @override
  String scannerAcarsDirection(String direction) {
    return 'Direction: $direction';
  }

  @override
  String get scannerAcarsFromAircraft => 'from the aircraft';

  @override
  String get scannerAcarsToAircraft => 'to the aircraft';

  @override
  String scannerAcarsRegistration(String registration) {
    return 'Registration: $registration';
  }

  @override
  String scannerAcarsFlight(String flight) {
    return 'Flight $flight';
  }

  @override
  String scannerAcarsMessageNo(String number) {
    return 'No. $number';
  }

  @override
  String get scannerAcarsContinued => 'continued';

  @override
  String get scannerAcarsNoText => '(no text)';

  @override
  String get scannerAdsbTitle => 'Aircraft (ADS-B 1090 MHz)';

  @override
  String scannerAdsbCount(int count, int withPosition) {
    return '$count aircraft · $withPosition with position';
  }

  @override
  String scannerAdsbRate(int rate) {
    return '$rate msg/s';
  }

  @override
  String get scannerAdsbMap => 'Map';

  @override
  String get scannerAdsbNoAircraft =>
      'No aircraft received yet.\nAntenna: vertical, ~6.9 cm (quarter wave 1090 MHz), ideally at a window.';

  @override
  String get scannerAdsbOnGround => 'on the ground';

  @override
  String get scannerAdsbColFlight => 'Flight / ICAO';

  @override
  String get scannerAdsbColAltitude => 'Altitude';

  @override
  String get scannerAdsbColSpeed => 'Speed';

  @override
  String get scannerAdsbColClimb => 'Climb';

  @override
  String get scannerAdsbColDistance => 'Distance';

  @override
  String get scannerAdsbColCountry => 'Country';

  @override
  String get scannerAdsbColLastSeen => 'Last seen';

  @override
  String get scannerAdsbRouteLoading => 'Loading route…';

  @override
  String get scannerAdsbRouteStale =>
      'Doesn\'t match the heading – the airline apparently uses this callsign for another route; the route data is out of date.';

  @override
  String get scannerAdsbFrom => 'From';

  @override
  String get scannerAdsbTo => 'To';

  @override
  String get scannerAdsbHideRoute => 'Hide route (Back)';

  @override
  String get scannerAdsbShowRoute => 'Show route (OK)';

  @override
  String get scannerAdsbNoRoute => 'No route data known';

  @override
  String get scannerAdsbAirline => 'Airline';

  @override
  String get scannerAdsbAircraft => 'Aircraft';

  @override
  String get scannerAdsbOwner => 'Owner';

  @override
  String get scannerAdsbIcaoAddress => 'ICAO address';

  @override
  String get scannerAdsbTrack => 'Track';

  @override
  String get scannerAdsbClimbRate => 'Climb/descent';

  @override
  String get scannerAdsbGroundSpeed => 'Speed';

  @override
  String scannerAdsbPosition(String lat, String lon) {
    return '$lat° N, $lon° E';
  }

  @override
  String get scannerAdsbBearing => 'Bearing';

  @override
  String scannerAdsbBearingValue(int degrees, String distance) {
    return '$degrees° at $distance km';
  }

  @override
  String get scannerAdsbReception => 'Reception';

  @override
  String scannerAdsbReceptionValue(int count, String signal) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count messages',
      one: '1 message',
    );
    return '$_temp0 · signal $signal dB';
  }

  @override
  String get scannerAdsbDataSource => 'Route and aircraft data: adsbdb.com';

  @override
  String get scannerAdsbClimbing => '↗ climbing';

  @override
  String get scannerAdsbDescending => '↘ descending';

  @override
  String scannerAgoSeconds(int seconds) {
    return '$seconds s ago';
  }

  @override
  String scannerAgoMinutes(int minutes) {
    return '$minutes min ago';
  }

  @override
  String scannerAgoHours(int hours) {
    return '$hours h ago';
  }

  @override
  String scannerIsmNameFor(String model) {
    return 'Name for $model';
  }

  @override
  String get scannerIsmNameHint =>
      'e.g. Balcony, Basement, Neighbour\'s garden';

  @override
  String scannerIsmDevices(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count devices',
      one: '1 device',
    );
    return '$_temp0';
  }

  @override
  String scannerIsmSignals(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count signals',
      one: '1 signal',
    );
    return '$_temp0';
  }

  @override
  String scannerIsmShowHidden(int count) {
    return 'Show hidden ($count)';
  }

  @override
  String get scannerIsmWaiting =>
      'Waiting for wireless sensors… Most send every 30–60 seconds.\nAntenna for 433 MHz: vertical, ~17 cm (868 MHz: ~8.6 cm).';

  @override
  String get scannerIsmSectionWeather => 'Thermometers & weather';

  @override
  String get scannerIsmSectionSwitches => 'Switches, doorbells, remotes';

  @override
  String get scannerIsmSectionKeys => 'Key fobs (anonymous)';

  @override
  String get scannerIsmSectionUnknown => 'Unknown';

  @override
  String scannerIsmKeyPresses(int count, String age) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count button presses',
      one: '1 button press',
    );
    return '$_temp0 nearby since this page was opened · last $age';
  }

  @override
  String scannerIsmTransmitters(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count transmitters',
      one: '1 transmitter',
    );
    return '$_temp0';
  }

  @override
  String get scannerIsmHideRaw => 'Hide raw data';

  @override
  String get scannerIsmShowRaw => 'Show raw data';

  @override
  String scannerIsmRain(String amount) {
    return 'Rain $amount mm';
  }

  @override
  String get scannerIsmBatteryOk => 'ok';

  @override
  String get scannerIsmBatteryLow => 'low';

  @override
  String scannerIsmContinuous(String bitTime) {
    return 'Continuous transmitter (FSK, ~$bitTime µs/bit)';
  }

  @override
  String get scannerIsmNotDecodable => 'continuous pattern, can\'t be decoded';

  @override
  String scannerIsmBitTime(String bitTime) {
    return '~$bitTime µs/bit';
  }

  @override
  String scannerIsmPulses(int count, String pulses, String gaps) {
    return '$count pulses ($pulses, gaps $gaps)';
  }

  @override
  String scannerIsmAfterSync(String data) {
    return 'After sync 2DD4: $data';
  }

  @override
  String scannerIsmDevice(String model, String id) {
    return 'Device: $model · ID $id';
  }

  @override
  String scannerIsmTemperature(String value) {
    return 'Temperature: $value °C';
  }

  @override
  String scannerIsmTempRange(String min, String max) {
    return '24 h: $min to $max °C';
  }

  @override
  String scannerIsmHumidity(String value) {
    return 'Humidity: $value %';
  }

  @override
  String scannerIsmBattery(String state) {
    return 'Battery: $state';
  }

  @override
  String scannerIsmReceived(int count, String age, int level) {
    return 'Received: $count× · last $age · level $level dB';
  }

  @override
  String get scannerIsmSetName => 'Set name';

  @override
  String get scannerIsmRename => 'Rename';

  @override
  String get scannerIsmShowAgain => 'Show again';

  @override
  String get scannerIsmHide => 'Hide';

  @override
  String get scannerJumpTo => 'Jump to…';

  @override
  String get scannerFrequencyTitle => 'Frequency (MHz)';

  @override
  String get scannerFrequencyHint => 'e.g. 145.500';

  @override
  String scannerOutOfRange(String low, String high) {
    return 'The stick receives $low–$high MHz.';
  }

  @override
  String get scannerHfHint =>
      'Nothing to hear? Shortwave needs a stick with direct sampling (RTL-SDR Blog V3, NESDR SMArt v5), an RTL-SDR Blog V4 (over rtl_tcp only with the Blog V4 driver on the server) or an upconverter (Scanner → Shortwave) - and a shortwave antenna.';

  @override
  String scannerSignalAboveNoise(int snr) {
    return 'Signal $snr dB above noise';
  }

  @override
  String get scannerChannelButton => 'Channel';

  @override
  String get scannerFrequencyButton => 'Frequency…';

  @override
  String get scannerFine => 'Fine';

  @override
  String scannerCbChannels(int count) {
    return '$count channels';
  }

  @override
  String get scannerScan => 'Scan';

  @override
  String get scannerAprsTooltip =>
      'Decode APRS packets (1200 baud) - automatic on 144.800 and 145.825';

  @override
  String get scannerBandPlanTooltip =>
      'Modulation and filter to match the band plan section';

  @override
  String get scannerBandPlan => 'Band plan';

  @override
  String get scannerSquelch => 'Squelch';

  @override
  String scannerSampleRate(String rate, int mbit) {
    return 'Bandwidth $rate MHz (~$mbit Mbit/s)';
  }

  @override
  String get scannerSignalFilters => 'Signal filters';

  @override
  String get scannerRange => 'Range';

  @override
  String scannerShowing(String low, String high) {
    return 'Showing $low–$high MHz';
  }

  @override
  String get scannerFilterWidth => 'Filter width';

  @override
  String get scannerFilterWidthHelp =>
      'Narrower: less noise and fewer neighbouring channels. Wider: clearer when a station is slightly off frequency. Auto matches the modulation.';

  @override
  String get scannerNoiseBlanker => 'Noise blanker';

  @override
  String get scannerNoiseBlankerHelp =>
      'Removes short clicks from ignition sparks, electric fences and power supplies.';

  @override
  String get scannerVoiceFilter => 'Voice filter';

  @override
  String get scannerVoiceFilterHelp =>
      'Only the voice range 300–3000 Hz: less hum, hiss and pilot tones.';

  @override
  String get scannerAgc => 'Automatic gain control';

  @override
  String get scannerAgcHelp =>
      'Fast for AM/FM, slow for SSB - prevents pumping between syllables. Auto picks to suit the modulation.';

  @override
  String get scannerAgcFast => 'Fast';

  @override
  String get scannerAgcSlow => 'Slow';

  @override
  String get scannerDmrCallPending => 'Call (ID to follow…)';

  @override
  String scannerDmrLast(String call, String ago) {
    return 'last $call $ago';
  }

  @override
  String get scannerDmrIdle => 'idle';

  @override
  String get scannerDmrReceptionGood => 'Reception good';

  @override
  String get scannerDmrReceptionFair => 'Reception fair';

  @override
  String get scannerDmrReceptionPoor => 'Reception poor';

  @override
  String scannerDmrSlot(int slot) {
    return 'Time slot $slot';
  }

  @override
  String get scannerDmrEmergency => 'EMERGENCY';

  @override
  String get scannerDmrEncryptedNoAudio => 'encrypted – no audio';

  @override
  String get scannerDmrNoSignal => 'no DMR signal';

  @override
  String scannerDmrColorCode(int code) {
    return 'Color code $code';
  }

  @override
  String get scannerDmrNoVoiceDecoder =>
      'built without voice decoder – display only';

  @override
  String get scannerDmrRecentlyHeard => 'Recently heard';

  @override
  String get scannerDmrEncrypted => 'encrypted';

  @override
  String scannerAprsPackets(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count packets',
      one: '1 packet',
    );
    return '$_temp0';
  }

  @override
  String get scannerAprsDecoderWaiting =>
      'Decoder running - waiting for packets…';

  @override
  String get scannerAprsDecoderRunning => 'Decoder running';

  @override
  String get scannerAprsDecoderOff => 'Decoder off';

  @override
  String get scannerAprsClear => 'Clear';

  @override
  String scannerAprsTo(String name) {
    return 'to $name';
  }

  @override
  String scannerAprsReceived(String time) {
    return 'Received $time';
  }

  @override
  String get scannerEastShort => 'E';

  @override
  String scannerAprsDistance(String distance) {
    return 'Distance: $distance';
  }

  @override
  String scannerAprsPath(String path) {
    return 'Path: $path';
  }

  @override
  String get scannerAprsDirect => 'direct';

  @override
  String get scannerRawData => 'Raw data';

  @override
  String get settingsOr => 'or';

  @override
  String get settingsNotSetUp => 'not set up';

  @override
  String settingsPercent(int value) {
    return '$value%';
  }

  @override
  String settingsMinutesShort(int minutes) {
    return '$minutes min';
  }

  @override
  String settingsSecondsShort(int seconds) {
    return '$seconds s';
  }

  @override
  String get settingsDeviceNameHelp =>
      'Unique in the home network - shown on the admin page and in the backups\' file names.';

  @override
  String get settingsDeviceNameOwn => 'Custom name';

  @override
  String get settingsDeviceNameNotSet => 'not set';

  @override
  String get settingsDeviceNameSuggestionTerrace => 'Terrace-Media';

  @override
  String get settingsDeviceNameSuggestionLivingRoom => 'Living-Room-TV';

  @override
  String get settingsDeviceNameSuggestionBedroom => 'Bedroom-TV';

  @override
  String get settingsDeviceNameSuggestionKitchen => 'Kitchen-Tablet';

  @override
  String get settingsReception => 'Reception';

  @override
  String get settingsReceiverNone => 'No receiver';

  @override
  String get settingsReceiverUsb => 'RTL-SDR via USB';

  @override
  String get settingsReceiverTcp => 'RTL-SDR over the network';

  @override
  String get settingsShowDab => 'Show DAB';

  @override
  String get settingsShowFm => 'Show FM';

  @override
  String get settingsShowAm => 'Show LW/MW/SW';

  @override
  String get settingsShowFunk => 'Show Scanner';

  @override
  String get settingsPartsHeading => 'Parts of Home System';

  @override
  String get settingsPartsHelp =>
      'Parts that are switched off have no tile on Home, and their settings are grayed out.';

  @override
  String get settingsDeviceHeading => 'Device';

  @override
  String get settingsAdminPageOffline =>
      'Admin page (backups): not reachable without a network connection';

  @override
  String settingsAdminPageAt(String url) {
    return 'Admin page (backups) in the browser: $url';
  }

  @override
  String get settingsNas => 'NAS server';

  @override
  String get settingsStartShowHome => 'Show Home';

  @override
  String get settingsStartRadio =>
      'Start Radio with a station (Radio → Autostart)';

  @override
  String get settingsStartTv =>
      'Start TV with a channel (TV → Channel on start)';

  @override
  String get settingsBackground => 'Background';

  @override
  String get settingsBackgroundGradients => 'Color gradients';

  @override
  String get settingsBackgroundPhotos => 'Landscape photos';

  @override
  String get settingsBackgroundServer => 'Own server';

  @override
  String get settingsIconPack => 'Icon pack';

  @override
  String get settingsIconPackNone => 'Original logos';

  @override
  String get settingsHomeKey => 'Home button';

  @override
  String get settingsReceiverHeading => 'Receiver';

  @override
  String get settingsSatReceiver => 'Satellite receiver (Enigma2)';

  @override
  String get settingsTvKeysValue =>
      'Channel list, TV guide, options, audio track';

  @override
  String get settingsTvZapEncrypted => 'Switch receiver when needed';

  @override
  String get settingsTvZapEncryptedHelp =>
      'Only while the receiver is switched on: its card or CI module then only descrambles the channel it shows itself, and on a single satellite cable all tuners only receive that channel\'s band. For an encrypted channel, or one on another band, the app then switches the receiver over (its picture changes too).\nIn standby the app never switches - the receiver descrambles by itself there and stays free. If it still holds on to a channel, the app releases it.';

  @override
  String get settingsTvStartHeading => 'Channel on start';

  @override
  String get settingsTvStartLast => 'Last watched channel';

  @override
  String get settingsTvStartFixed => 'A fixed channel';

  @override
  String settingsTvChannelsError(String error) {
    return 'Channel list not reachable: $error';
  }

  @override
  String get settingsTvSetUpReceiverFirst => 'Set up the receiver first.';

  @override
  String get settingsTvNextUpHeading => 'Up next';

  @override
  String get settingsTvNextUpHelp =>
      'Shortly before the next program starts on the current channel, a note shows what\'s up next.';

  @override
  String get settingsTvNextUpToggle => 'Note about the next program';

  @override
  String get settingsTvNextUpLead => 'How long before';

  @override
  String get settingsTvNextUpShow => 'How long to show it';

  @override
  String get settingsAutostartHeading => 'Autostart';

  @override
  String get settingsAutostartLast => 'Start the last station played';

  @override
  String get settingsAutostartFixed => 'Start a fixed station';

  @override
  String get settingsDisplayHeading => 'Display';

  @override
  String get settingsShowClockDate => 'Show the date next to the time';

  @override
  String get settingsFullscreen => 'Full screen';

  @override
  String get settingsFullscreenMonitor => 'Monitor for full screen';

  @override
  String settingsMonitorOf(int monitor, int count) {
    return '$monitor of $count';
  }

  @override
  String get settingsUiScale => 'Interface size';

  @override
  String get settingsTilesHeading => 'Tiles';

  @override
  String get settingsLocation => 'Location';

  @override
  String get settingsWeatherForecast => 'Weather forecast';

  @override
  String get settingsWeatherSpanTwoTiles => 'Across 2 tiles (full height)';

  @override
  String get settingsTileSize => 'Tile size';

  @override
  String get settingsContentSize => 'Content size';

  @override
  String get settingsWeatherRadar => 'Weather radar';

  @override
  String get settingsRadarSource => 'Source';

  @override
  String settingsRadarRadius(String token) {
    return 'Radius around the location ($token in the address)';
  }

  @override
  String get settingsRadarDimming => 'Dimming (for the evening)';

  @override
  String get settingsSunMoon => 'Sun & moon';

  @override
  String get settingsMoreSettings => 'More settings (System, TV)';

  @override
  String get settingsMoreHeading => 'More';

  @override
  String get settingsBackupCreate => 'Create backup';

  @override
  String get settingsBackupRestore => 'Restore backup';

  @override
  String get settingsBackupRestoreHint => 'also via the admin page';

  @override
  String get settingsAboutHeading => 'About';

  @override
  String get settingsQuit => 'Quit the app';

  @override
  String get settingsQuitConfirm => 'Quit the app?';

  @override
  String get settingsQuitButton => 'Quit';

  @override
  String settingsPartOff(String part) {
    return '$part is switched off - switch it on under System → Parts of Home System.';
  }

  @override
  String get settingsAreaSystemSubtitle =>
      'Radio & TV on/off, device name, NAS, start, Home, Home button, permissions, display, backup, updates';

  @override
  String get settingsAreaSystemSubtitleNoHomeKey =>
      'Radio & TV on/off, device name, NAS, start, Home, display, backup, updates';

  @override
  String get settingsAreaRadioSubtitle =>
      'Receiver (DAB+, FM, Scanner), autostart station, weather, radar, sun & moon';

  @override
  String get settingsAreaTvSubtitle =>
      'Satellite receiver (Enigma2, e.g. GigaBlue)';

  @override
  String get settingsAreaOff => 'Switched off - switch it on under System';

  @override
  String get settingsAboutLicense =>
      'PolyForm Noncommercial 1.0.0 - free for private and non-commercial use. © 2026 Jürgen Laschak, github.com/JayLo1401/home.system';

  @override
  String get settingsAboutWeatherData =>
      'Data: © GeoSphere Austria, licensed under CC BY 4.0 (data.hub.geosphere.at)';

  @override
  String get settingsAboutUvIndex => 'UV index';

  @override
  String get settingsAboutUvData =>
      'Weather data by Open-Meteo.com, licensed under CC BY 4.0';

  @override
  String get settingsAboutInternetRadio => 'Internet radio';

  @override
  String get settingsAboutInternetRadioData =>
      'Station search and logos via the community directory Radio Browser (radio-browser.info)';

  @override
  String get settingsAboutPlaceSearch => 'Place search';

  @override
  String get settingsAboutPlaceSearchData =>
      '© OpenStreetMap contributors, data under the Open Database License (ODbL), via Nominatim.';

  @override
  String get settingsAboutBackgroundPhotos => 'Home\'s background photos';

  @override
  String get settingsAboutBackgroundPhotosData =>
      'Bing images of the day, © the respective photographers (only when \"Landscape photos from the internet\" is chosen).';

  @override
  String get settingsAboutRadarData =>
      'The radar image comes from the source you entered yourself; rights and credits belong to the respective provider.';

  @override
  String get settingsAudioChannelName => 'Radio playback';

  @override
  String get settingsBackupNotHomeSystem =>
      'The file isn\'t a Home System backup.';

  @override
  String get settingsBackupNewerVersion =>
      'The backup comes from a newer app version.';

  @override
  String get settingsBackupCorrupt => 'The backup is damaged or incomplete.';

  @override
  String get settingsLauncherMenuApp => 'Home System (app settings)';

  @override
  String get settingsLauncherMenuAndroid => 'Android settings';

  @override
  String settingsLauncherNotInstalled(String app) {
    return '\"$app\" isn\'t installed (anymore).';
  }

  @override
  String get settingsLauncherChangeImage => 'Change picture';

  @override
  String get settingsLauncherRemove => 'Remove from the start bar';

  @override
  String settingsLauncherOptionsHint(String key) {
    return '$key  Tile options';
  }

  @override
  String settingsLauncherOptionsHintMouse(String key) {
    return '$key or right-click  Tile options';
  }

  @override
  String settingsLauncherAppInfoFailed(String app) {
    return 'Can\'t open the app info of \"$app\".';
  }

  @override
  String settingsLauncherImageTitle(String tile) {
    return 'Picture for \"$tile\"';
  }

  @override
  String get settingsLauncherImageAuto =>
      'Automatic (icon pack, otherwise original)';

  @override
  String get settingsLauncherImageDefault => 'Default';

  @override
  String get settingsLauncherImageOriginal => 'The app\'s original';

  @override
  String get settingsLauncherImageFromUrl => 'Picture from an address (URL) …';

  @override
  String get settingsLauncherImageUrlTitle =>
      'Picture address (PNG/JPG, ideally 16:9)';

  @override
  String get settingsLauncherFindApps => 'Find & add apps';

  @override
  String get settingsWizardTitle => 'Set up Home System';

  @override
  String settingsWizardStep(int step, int count) {
    return 'Step $step of $count';
  }

  @override
  String get settingsWizardWelcome =>
      'Welcome! Is there already a backup of Home System?';

  @override
  String get settingsWizardRestoreHint =>
      'From this device, a USB stick or via the admin page';

  @override
  String settingsWizardRestoreHintUrl(String url) {
    return 'From this device, a USB stick or via the admin page ($url)';
  }

  @override
  String get settingsWizardNew => 'Set up from scratch';

  @override
  String settingsWizardLanguage(String language) {
    return 'Language: $language';
  }

  @override
  String get settingsWizardNameQuestion => 'What should this device be called?';

  @override
  String get settingsWizardNameHint =>
      'A unique name so the devices can be told apart - on the admin page and in backups.';

  @override
  String get settingsWizardNameOwn => 'Or a custom name';

  @override
  String get settingsWizardNext => 'Next';

  @override
  String settingsWizardDone(String name) {
    return 'Done - \"$name\" is set up.';
  }

  @override
  String get settingsWizardDoneHint =>
      'Home System starts with Home: Radio, TV and the apps as tiles. More (radio receiver, satellite receiver, background …) under Settings.';

  @override
  String settingsWizardDoneBackups(String url) {
    return 'Backups are available any time on the admin page: $url';
  }

  @override
  String get settingsWizardStart => 'Let\'s go';

  @override
  String get settingsOpenSourceLicenses => 'Open source licences';

  @override
  String get settingsAboutInternetTv => 'Internet TV';

  @override
  String get settingsAboutInternetTvData =>
      'Channel list, streams and logos from the open directory iptv-org (github.com/iptv-org/iptv) - only freely available channels; the streams come from the broadcasters themselves';

  @override
  String get settingsAboutMaps => 'Maps (Scanner)';

  @override
  String get settingsAboutMapsData =>
      'Map tiles © OpenStreetMap contributors, data under the Open Database License (ODbL), via tile.openstreetmap.org';

  @override
  String get settingsAboutAircraft => 'Aircraft data (ADS-B)';

  @override
  String get settingsAboutAircraftData =>
      'Aircraft types, owners and routes via adsbdb.com';

  @override
  String get settingsBgTitle => 'Home background';

  @override
  String get settingsBgGradientsHint =>
      'Built-in color gradients (Northern lights, Sunset, Ocean, …) - no internet needed.';

  @override
  String get settingsBgPhotos => 'Landscape photos from the internet';

  @override
  String get settingsBgPhotosHint =>
      'Landscape and nature photos - Bing\'s pictures of the day from the last two weeks, taking turns. Place and photographer are shown small at the top right.';

  @override
  String get settingsBgBand => 'Band behind the favorites';

  @override
  String get settingsBgBandHint =>
      'How much the band covers the picture - applies right away.';

  @override
  String get settingsBgBandNone => 'None';

  @override
  String get settingsBgInterval => 'New picture every';

  @override
  String get settingsBgOneHour => '1 hour';

  @override
  String get settingsIconPackTitle => 'Icon pack for the app tiles';

  @override
  String get settingsIconPackNoneOriginal => 'None - the apps\' original logos';

  @override
  String get settingsIconPackNoneInstalled =>
      'No icon pack installed. Icon packs for Android launchers (ADW/Nova format) are supported - install one as an app, then choose it here.\nSingle tiles get their own picture via ☰ on the tile → \"Change picture\".';

  @override
  String get settingsHomeKeyIntro =>
      'The remote\'s Home button opens Home System with Home (the tiles).';

  @override
  String get settingsHomeKeyIsDefault => 'Home System is the default launcher.';

  @override
  String get settingsHomeKeyNotDefault =>
      'Home System isn\'t the default launcher yet.';

  @override
  String get settingsHomeKeyDefaultHelp =>
      'On Android TV boxes, choose Home System as the home screen (\"Home app\"). If the device asks when the Home button is pressed, choose \"Home System\" and \"Always\".';

  @override
  String get settingsHomeKeyChooseDefault => 'Choose default launcher';

  @override
  String get settingsHomeKeyServiceFallback =>
      'If the device doesn\'t allow another launcher (e.g. Google TV), the service below helps - as on the Fire TV.';

  @override
  String get settingsHomeKeyServiceOn =>
      'The service \"Home System: Home key\" is on.';

  @override
  String get settingsHomeKeyServiceOff =>
      'The service \"Home System: Home key\" is off.';

  @override
  String get settingsHomeKeyServiceFireTv =>
      'On the Home button the Fire TV always shows the Amazon home screen. The service (an accessibility service) then brings Home System to the front right away. It only sees which app is in front - no content, no keys and no input.';

  @override
  String get settingsHomeKeyServiceOther =>
      'The service (an accessibility service) brings Home System to the front as soon as the device\'s home screen appears. It only sees which app is in front.';

  @override
  String get settingsHomeKeyEnable => 'Switch the service on';

  @override
  String get settingsHomeKeyOpenA11y => 'Open accessibility settings';

  @override
  String get settingsHomeKeyBlocked =>
      'Android has blocked the service (\"restricted settings\" - from Android 13 on, for apps that don\'t come from an app store). Allow it once from a computer via adb, then \"Switch the service on\" again:';

  @override
  String get settingsHomeKeyEnableThere =>
      'Switch on \"Home System: Home key\" there. If the device doesn\'t show the service or it\'s greyed out, unlock it once from a computer via adb - after that this button switches it on by itself:';

  @override
  String get settingsHomeKeyRedirect => 'Home button opens Home System';

  @override
  String get settingsHomeKeyRedirectHint =>
      'Off: the device\'s home screen stays, Home System opens like any other app.';

  @override
  String settingsBackupSaved(String location) {
    return 'Backup saved: $location';
  }

  @override
  String settingsBackupDownloadAlso(String urls) {
    return 'Also available for download at $urls';
  }

  @override
  String get settingsBackupNoPermission =>
      'Without storage permission the backup can\'t be saved.';

  @override
  String settingsBackupFailed(String message) {
    return 'Backup failed: $message';
  }

  @override
  String get settingsRestoreNoPermission =>
      'Without storage permission no backups can be read.';

  @override
  String settingsRestoreReadFailed(String message) {
    return 'Backups couldn\'t be read ($message).';
  }

  @override
  String get settingsRestoreBusy => 'The device is already restoring a backup.';

  @override
  String get settingsRestoreFromWebDone =>
      'Backup from the admin page restored - the app restarts …';

  @override
  String get settingsRestoreDone => 'Backup restored - the app restarts …';

  @override
  String get settingsRestoreNoPicker =>
      'This device has no file picker. Please allow \"All files access\" instead.';

  @override
  String settingsRestoreFailed(String message) {
    return 'Restore failed: $message';
  }

  @override
  String get settingsRestoreNoAllFilesSetting =>
      'This device doesn\'t offer the \"All files access\" setting.';

  @override
  String get settingsRestoreViaAdmin => 'Via the admin page';

  @override
  String get settingsRestoreNoNetwork =>
      'No network connection - the admin page can\'t be reached.';

  @override
  String get settingsRestoreOpenInBrowser =>
      'Open in the browser on a computer or phone in the same network:';

  @override
  String settingsRestoreHostname(String name) {
    return 'This device\'s host name: $name';
  }

  @override
  String get settingsRestoreAdminHint =>
      'Choose the backup file there and restore it. As long as this screen is open, the device accepts a backup. The app then restarts.';

  @override
  String get settingsRestoreOnDevice => 'Backups on this device';

  @override
  String settingsRestoreOnDeviceHint(String folder) {
    return 'From the folder \"$folder/HomeSystem\" (and HomeRadio of the earlier app).';
  }

  @override
  String get settingsRestoreFolderDocuments => 'Documents';

  @override
  String get settingsRestoreNone => 'No backups found.';

  @override
  String get settingsRestoreAllFilesHint =>
      'Backups from an earlier installation of the app only show up once \"All files access\" has been allowed. Or choose the file directly.';

  @override
  String get settingsRestoreAllowAllFiles => 'Allow all files access';

  @override
  String get settingsRestorePickFile =>
      'Choose a backup file … (e.g. from a USB stick)';

  @override
  String get settingsAboutAdblock => 'Ad blocker (browser)';

  @override
  String get settingsAboutAdblockData =>
      'Filter lists, downloaded at runtime: uBlock Origin uAssets (GPLv3, github.com/uBlockOrigin/uAssets), EasyList, EasyPrivacy, EasyList Germany (GPLv3 or CC BY-SA 3.0, easylist.to), Peter Lowe’s Ad and tracking server list (pgl.yoyo.org/adservers). The scriptlets are our own implementations following uBlock Origin’s names and arguments.';

  @override
  String get settingsHomeKeyWorking => 'working';

  @override
  String get settingsHomeKeyBroken => 'not working - please open';

  @override
  String get settingsHomeKeyNotRunning =>
      'Service \"Home System: Home key\" is switched on but not running (the app was ended). The app restarts it by itself where allowed - otherwise restart it here.';

  @override
  String get settingsHomeKeyRestart => 'Restart service';

  @override
  String errorCaught(String message) {
    return 'Error caught: $message';
  }

  @override
  String get systemStartDashboard => 'Show Smart Home (wall tablet)';

  @override
  String get systemStartAppNone => 'Start another app …';

  @override
  String systemStartApp(String app) {
    return 'Start app: $app';
  }

  @override
  String get systemStartAppPick => 'Which app on start?';

  @override
  String systemStartAppMissing(String app) {
    return 'The start app \"$app\" isn\'t installed.';
  }

  @override
  String get systemSettingsAll => 'All settings';

  @override
  String get systemTileSettings => 'Settings (TV)';

  @override
  String get systemTileSettingsShort => 'Settings';

  @override
  String get systemSettingsTitleSystem => 'System settings';

  @override
  String get systemSettingsTitleRadio => 'Radio settings';

  @override
  String get systemSettingsTitleTv => 'TV settings';

  @override
  String get tvLinkConnecting => 'Connecting to the receiver…';

  @override
  String tvLinkZapping(String reason) {
    return '$reason - switching the receiver…';
  }

  @override
  String get tvReasonEncrypted => 'Encrypted';

  @override
  String get tvReasonNoFreeTuner => 'No free tuner';

  @override
  String get tvLinkLoadingPicture => 'Loading picture…';

  @override
  String get tvLinkDescrambling => 'Encrypted - the receiver is descrambling…';

  @override
  String get tvLinkPlaying => 'Channel playing';

  @override
  String tvErrorEncryptedReceiverBusy(String channel) {
    return '“$channel” is encrypted and the receiver is showing another channel itself - Settings → TV → “Switch receiver when needed”.';
  }

  @override
  String tvErrorStillEncrypted(String channel) {
    return '“$channel” stays encrypted - is your card or CI module enabled for this channel?';
  }

  @override
  String tvErrorNoTunerCableBusy(String channel) {
    return 'No free tuner for “$channel” - the satellite cable is in use on another band right now (a recording or another device).';
  }

  @override
  String tvErrorNoTunerReceiverBusy(String channel) {
    return 'No free tuner for “$channel” - the receiver is showing a channel on another band itself (Settings → TV → “Switch receiver when needed”).';
  }

  @override
  String tvErrorNoPicture(String channel) {
    return 'No picture from “$channel” - is the receiver on and a tuner free?';
  }

  @override
  String get tvPaused => 'Paused - ⏯ resumes';

  @override
  String get tvAudioTrack => 'Audio track';

  @override
  String tvAudioTrackNumber(int number) {
    return 'Audio track $number';
  }

  @override
  String tvAudioTrackCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count audio tracks',
      one: '1 audio track',
    );
    return '$_temp0';
  }

  @override
  String tvAudioChannels(int count) {
    return '$count channels';
  }

  @override
  String get tvAudioLanguageGerman => 'German';

  @override
  String get tvAudioLanguageEnglish => 'English';

  @override
  String get tvAudioLanguageFrench => 'French';

  @override
  String get tvAudioLanguageItalian => 'Italian';

  @override
  String get tvAudioLanguageSpanish => 'Spanish';

  @override
  String get tvAudioLanguageTurkish => 'Turkish';

  @override
  String get tvAudioLanguagePolish => 'Polish';

  @override
  String get tvAudioLanguageCroatianSerbian => 'Croatian/Serbian';

  @override
  String get tvAudioOriginal => 'Original audio';

  @override
  String get tvAudioDescription => 'Audio description';

  @override
  String tvResolutionLines(int lines) {
    return '$lines lines';
  }

  @override
  String get tvTranscoded => 'Transcoded';

  @override
  String get tvOriginalStream => 'Original';

  @override
  String get tvGuide => 'TV guide';

  @override
  String tvAllProgramsOf(String channel) {
    return 'All programs on $channel';
  }

  @override
  String get tvAllProgramsOfThisChannel => 'All programs on this channel';

  @override
  String get tvNextUpNow => 'Up next · starting now';

  @override
  String tvNextUpInMinutes(int minutes) {
    return 'Up next · in $minutes min';
  }

  @override
  String get tvNotSetUpIntro =>
      'TV from your own satellite receiver: channel lists, channel logos and the TV guide come straight from the Enigma2 receiver (e.g. GigaBlue, VU+, Dreambox with OpenWebif) in your home network.';

  @override
  String get tvSetUpReceiver => 'Set up receiver';

  @override
  String tvBannerKeyHint(
    String channelListKey,
    String guideKey,
    String optionsKey,
  ) {
    return '$channelListKey Channel list  ·  $guideKey Guide  ·  $optionsKey Options';
  }

  @override
  String get tvNoProgramInfo => 'No program info';

  @override
  String get tvNoProgramInfoSentence => 'No program info.';

  @override
  String get tvThen => 'Next';

  @override
  String get tvChannelListKeyHint =>
      'OK play (current channel: info)  ·  hold OK options (move)  ·  → Guide  ·  ← close';

  @override
  String get tvMoveKeyHint => '↑/↓ move  ·  OK done  ·  Back cancels';

  @override
  String get tvChannelPlay => 'Play';

  @override
  String get tvChannelInfo => 'What\'s on';

  @override
  String get tvChannelMove => 'Move';

  @override
  String get tvChannelMoveSubtitle => 'Change the order - on the receiver too';

  @override
  String get tvChannelOrderReset => 'Use the receiver\'s order';

  @override
  String get tvChannelOrderResetSubtitle =>
      'Discard the order saved in the app only';

  @override
  String get tvOrderSaved => 'Order saved on the receiver';

  @override
  String get tvOrderLocalOnly =>
      'Order saved in the app only – the receiver\'s bouquet editor isn\'t available';

  @override
  String tvOrderFailed(String error) {
    return 'Order not saved: $error';
  }

  @override
  String get tvOrderMismatch => 'The receiver didn\'t take the new order';

  @override
  String get tvNoChannelsInList => 'No channels in this list';

  @override
  String get tvChannelList => 'Channel list';

  @override
  String get tvBouquetFavorites => 'Favorites';

  @override
  String get tvBouquetLastScanned => 'Last scanned';

  @override
  String tvMinutes(int minutes) {
    return '$minutes min';
  }

  @override
  String get tvNoDescription => 'No description.';

  @override
  String get tvToday => 'Today';

  @override
  String get tvTomorrow => 'Tomorrow';

  @override
  String get tvDayMonthPattern => 'MMM d';

  @override
  String get tvSchedule => 'Schedule';

  @override
  String get tvScheduleNoInfo =>
      'The receiver has no program info for this channel.';

  @override
  String tvGuideKeyHint(String optionsKey) {
    return 'OK watch  ·  hold OK reminder  ·  $optionsKey all programs  ·  ‹‹ ›› ±3 hrs';
  }

  @override
  String get tvSettingsTitle => 'TV: Receiver';

  @override
  String get tvSettingsIntro =>
      'An Enigma2 satellite receiver with OpenWebif in your home network (e.g. GigaBlue, VU+, Dreambox with teamBlue, OpenATV or OpenPLi). Channel lists, channel logos (picons) and the TV guide come from the receiver, the picture through its streaming port.';

  @override
  String get tvSettingsAddress => 'Receiver address (IP or name)';

  @override
  String get tvSettingsWebPort => 'Web port (OpenWebif)';

  @override
  String get tvSettingsStreamPort => 'Streaming port';

  @override
  String get tvSettingsPortsHelp =>
      'Usually: web 80, streaming 8001 (8002 = transcoded, if the receiver supports it).';

  @override
  String get tvSettingsHttps => 'HTTPS for the web interface';

  @override
  String get tvSettingsUser => 'User (if login is enabled)';

  @override
  String get tvSettingsPassword => 'Password';

  @override
  String get tvSettingsTestConnection => 'Test connection';

  @override
  String get tvSettingsEnterAddress => 'Please enter the receiver\'s address.';

  @override
  String tvSettingsConnected(String receiver, int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count channel lists',
      one: '1 channel list',
    );
    return 'Connected: $receiver · $_temp0';
  }

  @override
  String get tvSettingsChannelList => 'Channel list for TV';

  @override
  String get tvSettingsChannelListHelp =>
      'In TV, ← / → in the channel list switch between the lists.';

  @override
  String get tvEnigma2Receiver => 'Enigma2 receiver';

  @override
  String get tvReceiverNeedsLogin => 'Enigma2 receiver (login required)';

  @override
  String get tvSearchReceiver => 'Find receiver';

  @override
  String get tvSearchScanning => 'Searching the home network …';

  @override
  String tvSearchScanningNetworks(String networks) {
    return 'Searching the home network ($networks) …';
  }

  @override
  String get tvSearchNoneFound =>
      'No receiver found. Is it switched on and on the same network? If not, please enter the address by hand.';

  @override
  String tvSearchFound(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count receivers found - OK takes the marked one.',
      one: 'One receiver found - OK takes it.',
    );
    return '$_temp0';
  }

  @override
  String get tvErrorNoReceiver => 'No receiver set up';

  @override
  String tvErrorUnreachable(String host, String error) {
    return 'Receiver not reachable ($host): $error';
  }

  @override
  String get tvErrorLoginRejected => 'Login rejected - check user/password';

  @override
  String tvErrorHttpStatus(String status) {
    return 'Receiver responded with error $status';
  }

  @override
  String get tvErrorUnexpectedResponse =>
      'Unexpected response from the receiver';

  @override
  String tvErrorZapFailed(String message) {
    return 'Receiver won\'t switch channels: $message';
  }

  @override
  String get tvSettingsButton => 'TV settings';

  @override
  String tvBannerLaterHint(int index, int count) {
    return 'Programme $index of $count - → next, ← back';
  }

  @override
  String get tvRowReceiver => 'Receiver';

  @override
  String get tvRemindersTitle => 'Your reminders';

  @override
  String get tvRemindersPick =>
      'Several programmes are about to begin - OK picks the one to watch.';

  @override
  String get tvReminderNow => 'now';

  @override
  String tvReminderInMinutes(int minutes) {
    return 'in $minutes min';
  }

  @override
  String tvReminderSwitchIn(int seconds) {
    return 'Switching in $seconds s';
  }

  @override
  String get tvReminderSwitchNow => 'Switch now';

  @override
  String tvReminderSet(String title, String time, String channel) {
    return 'Reminder set: $title at $time on $channel';
  }

  @override
  String tvReminderRemoved(String title) {
    return 'Reminder removed: $title';
  }

  @override
  String get tvReminderAlreadyRunning =>
      'This programme is already on - reminders are for coming programmes.';

  @override
  String get tvReminderSetHint => 'OK: remind me of this programme';

  @override
  String get tvReminderIsSetHint => 'Reminder set - OK removes it';

  @override
  String get tvReminderRunningHint => 'On now';

  @override
  String get tvReminderSettingsHeading => 'Reminders';

  @override
  String get tvReminderSettingsHelp =>
      'In the programme guide, holding OK marks a coming programme (in a channel\'s programme list: OK) - several at the same time too. Shortly before it begins a note appears: for one programme TV switches by itself after 30 seconds, for several you pick.';

  @override
  String get tvReminderLead => 'Note before the start';
}
