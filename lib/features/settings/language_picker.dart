import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../l10n/l10n.dart';

/// "Wie das Gerät (Deutsch)" / "Deutsch" / "English".
String languageLabel(AppLocalizations l, AppLanguage language) => switch (language) {
      AppLanguage.system => '${l.commonLanguageSystem} (${_name(l, AppLanguage.system.locale.languageCode)})',
      AppLanguage.de => l.commonLanguageGerman,
      AppLanguage.en => l.commonLanguageEnglish,
    };

String _name(AppLocalizations l, String code) => code == 'de' ? l.commonLanguageGerman : l.commonLanguageEnglish;

/// The language choice (Settings → System, setup wizard) - takes effect at once.
Future<void> pickLanguage(BuildContext context, WidgetRef ref) async {
  final current = ref.read(languageProvider);
  final l = context.l10n;
  final picked = await showDialog<AppLanguage>(
    context: context,
    builder: (context) => SimpleDialog(
      title: Text(l.commonLanguage),
      children: [
        for (final language in AppLanguage.values)
          ListTile(
            autofocus: language == current,
            leading: Icon(language == current ? Icons.radio_button_checked : Icons.radio_button_off),
            title: Text(languageLabel(l, language), style: const TextStyle(fontSize: 18)),
            onTap: () => Navigator.of(context).pop(language),
          ),
      ],
    ),
  );
  if (picked != null) await ref.read(languageProvider.notifier).set(picked);
}
