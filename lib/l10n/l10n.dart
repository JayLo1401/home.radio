import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/widgets.dart';

import 'app_localizations.dart';

export 'app_localizations.dart';

/// The app's language setting: the device's, or fixed German / English.
enum AppLanguage {
  system,
  de,
  en;

  static AppLanguage parse(String? value) =>
      AppLanguage.values.firstWhere((l) => l.name == value, orElse: () => AppLanguage.system);

  /// German on a German device, English on any other.
  Locale get locale => switch (this) {
        AppLanguage.de => const Locale('de'),
        AppLanguage.en => const Locale('en'),
        AppLanguage.system => PlatformDispatcher.instance.locale.languageCode == 'de' ? const Locale('de') : const Locale('en'),
      };
}

AppLocalizations _current = lookupAppLocalizations(AppLanguage.system.locale);

/// The texts in the current language for code outside the widget tree
/// (services, the admin page, notifications). Widgets use [L10nContext.l10n]
/// so they rebuild when the language changes.
AppLocalizations get l10n => _current;

/// Called by the language provider when the setting is loaded or changed.
void applyAppLocale(Locale locale) => _current = lookupAppLocalizations(locale);

extension L10nContext on BuildContext {
  /// The texts in the current language - rebuilds the widget on a change.
  AppLocalizations get l10n => AppLocalizations.of(this);
}
