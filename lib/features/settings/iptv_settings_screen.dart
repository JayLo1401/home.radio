import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/country_names_de.dart';
import '../../l10n/l10n.dart';
import '../tv/iptv_providers.dart';

/// Einstellungen → TV → Internet-TV: on/off, the countries and languages
/// browsing the catalogue starts with, the catalogue itself (update now)
/// and the favorites (all off).
class IptvSettingsScreen extends ConsumerStatefulWidget {
  const IptvSettingsScreen({super.key});

  @override
  ConsumerState<IptvSettingsScreen> createState() => _IptvSettingsScreenState();
}

class _IptvSettingsScreenState extends ConsumerState<IptvSettingsScreen> {
  bool _refreshing = false;
  String? _refreshResult;

  late final IptvCatalogueStore _store = ref.read(iptvCatalogueStoreProvider);

  IptvNotifier get _notifier => ref.read(iptvProvider.notifier);

  @override
  void initState() {
    super.initState();
    // What the saved catalogue has (its date, the languages it knows).
    _store.hold();
    _store.loadCached().then((_) {
      if (mounted) setState(() {});
    }, onError: (Object e) => debugPrint('IPTV catalogue: $e'));
  }

  @override
  void dispose() {
    _store.release();
    super.dispose();
  }

  Future<void> _addCountry(List<String> current) async {
    final codes = countryNamesDe.keys.where((c) => !current.contains(c)).toList()
      ..sort((a, b) => countryName(a, '').compareTo(countryName(b, '')));
    final picked = await _pick(context.l10n.iptvSettingsAddCountry, {for (final c in codes) c: countryName(c, '')});
    if (picked != null) await _notifier.setCountries([...current, picked]);
  }

  Future<void> _addLanguage(List<String> current) async {
    final catalogue = _store.current;
    final codes = {...iptvLanguagesEn.keys, ...?catalogue?.languages.keys}.where((c) => !current.contains(c)).toList()
      ..sort((a, b) => iptvLanguageName(a, catalogue?.languages).compareTo(iptvLanguageName(b, catalogue?.languages)));
    final picked = await _pick(
      context.l10n.iptvSettingsAddLanguage,
      {for (final c in codes) c: iptvLanguageName(c, catalogue?.languages)},
    );
    if (picked != null) await _notifier.setLanguages([...current, picked]);
  }

  /// A list to pick one entry from - OK picks, Back cancels.
  Future<String?> _pick(String title, Map<String, String> options) => showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          contentPadding: const EdgeInsets.fromLTRB(8, 12, 8, 8),
          content: SizedBox(
            width: 420,
            height: 480,
            child: ListView(
              children: [
                for (final (i, e) in options.entries.indexed)
                  ListTile(
                    autofocus: i == 0,
                    title: Text(e.value),
                    trailing: Text(e.key, style: const TextStyle(color: Colors.white38)),
                    onTap: () => Navigator.of(context).pop(e.key),
                  ),
              ],
            ),
          ),
        ),
      );

  Future<void> _refresh() async {
    setState(() {
      _refreshing = true;
      _refreshResult = null;
    });
    try {
      final catalogue = await _store.refresh();
      if (mounted) setState(() => _refreshResult = context.l10n.iptvResultCount(catalogue.channels.length));
    } catch (e) {
      if (mounted) setState(() => _refreshResult = context.l10n.iptvCatalogueError('$e'));
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  Future<void> _clearFavorites(int count) async {
    final t = context.l10n;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        content: Text(t.iptvSettingsClearConfirm(count)),
        actions: [
          TextButton(autofocus: true, onPressed: () => Navigator.of(context).pop(false), child: Text(t.commonCancel)),
          TextButton(onPressed: () => Navigator.of(context).pop(true), child: Text(t.iptvSettingsClearFavorites)),
        ],
      ),
    );
    if (ok == true) await _notifier.clearFavorites();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.l10n;
    final state = ref.watch(iptvProvider);
    const help = TextStyle(color: Colors.white54, fontSize: 13);
    final catalogue = _store.current;
    return Scaffold(
      appBar: AppBar(title: Text(t.iptvSettingsTitle)),
      body: state == null
          ? const Center(child: CircularProgressIndicator())
          : FocusTraversalGroup(
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  Text(t.iptvSettingsIntro, style: help),
                  const SizedBox(height: 12),
                  SwitchListTile(
                    autofocus: true,
                    title: Text(t.iptvSettingsEnabled),
                    value: state.enabled,
                    onChanged: _notifier.setEnabled,
                  ),
                  const Divider(height: 32),
                  Text(t.iptvSettingsCountries, style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 4),
                  Text(t.iptvSettingsCountriesHelp, style: help),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final c in state.countries)
                        ActionChip(
                          avatar: const Icon(Icons.close, size: 16),
                          label: Text(countryName(c, c)),
                          onPressed: () => _notifier.setCountries([...state.countries]..remove(c)),
                        ),
                      ActionChip(
                        avatar: const Icon(Icons.add, size: 18),
                        label: Text(t.iptvSettingsAddCountry),
                        onPressed: () => _addCountry(state.countries),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  Text(t.iptvSettingsLanguages, style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 4),
                  Text(t.iptvSettingsLanguagesHelp, style: help),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final l in state.languages)
                        ActionChip(
                          avatar: const Icon(Icons.close, size: 16),
                          label: Text(iptvLanguageName(l, catalogue?.languages)),
                          onPressed: () => _notifier.setLanguages([...state.languages]..remove(l)),
                        ),
                      ActionChip(
                        avatar: const Icon(Icons.add, size: 18),
                        label: Text(t.iptvSettingsAddLanguage),
                        onPressed: () => _addLanguage(state.languages),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(t.iptvSettingsChipHelp, style: help),
                  const Divider(height: 32),
                  Text(t.iptvSettingsCatalogue, style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 4),
                  Text(
                    catalogue == null
                        ? t.iptvSettingsCatalogueHelp
                        : '${t.iptvResultCount(catalogue.channels.length)}  ·  '
                            '${t.iptvCatalogueDate(DateFormat.yMd(t.localeName).add_Hm().format(catalogue.updated))}',
                    style: help,
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      OutlinedButton.icon(
                        onPressed: _refreshing ? null : _refresh,
                        icon: const Icon(Icons.refresh),
                        label: Text(t.iptvSettingsRefresh),
                      ),
                      const SizedBox(width: 12),
                      if (_refreshing) const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                      if (_refreshResult != null) Expanded(child: Text(_refreshResult!)),
                    ],
                  ),
                  const Divider(height: 32),
                  Text(t.iptvSettingsFavorites(state.favorites.length), style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 4),
                  Text(t.iptvSettingsFavoritesHelp, style: help),
                  if (state.favorites.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: OutlinedButton.icon(
                        onPressed: () => _clearFavorites(state.favorites.length),
                        icon: const Icon(Icons.delete_outline),
                        label: Text(t.iptvSettingsClearFavorites),
                      ),
                    ),
                  ],
                ],
              ),
            ),
    );
  }
}
