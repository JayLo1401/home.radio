import 'package:collection/collection.dart' show mergeSort;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/country_names_de.dart';
import '../../core/popup_text_field.dart';
import '../../core/remote_keys.dart';
import '../../core/theme.dart';
import '../../data/models/iptv_channel.dart';
import '../../l10n/l10n.dart';
import '../settings/iptv_settings_screen.dart';
import 'iptv_providers.dart';
import 'tv_widgets.dart';

/// Internet-TV's catalogue (iptv-org): find channels by country, category,
/// language and name. OK plays a channel (the screen closes with it), ★
/// (right of the row) or the options key adds it to the Internet-TV
/// favorites or takes it out again.
///
/// Closes with the channel to play (or nothing).
class IptvBrowseScreen extends ConsumerStatefulWidget {
  const IptvBrowseScreen({super.key, this.current});

  /// The channel on air - marked in the list.
  final IptvChannel? current;

  @override
  ConsumerState<IptvBrowseScreen> createState() => _IptvBrowseScreenState();
}

/// The filters' "Meine Länder" / "Meine Sprachen".
const _mine = '*';

/// The filters' "Alle ...".
const _all = '';

class _IptvBrowseScreenState extends ConsumerState<IptvBrowseScreen> {
  late final IptvCatalogueStore _store = ref.read(iptvCatalogueStoreProvider);
  final _name = TextEditingController();
  final _firstRow = FocusNode(debugLabel: 'iptv first result');
  final _scroll = ScrollController();

  IptvCatalogue? _catalogue;
  String? _error;
  bool _updating = false;
  String? _updateError;

  String _country = _mine;
  String _category = _all;
  late String _language = (ref.read(iptvProvider)?.languages.isNotEmpty ?? false) ? _mine : _all;
  List<IptvChannel> _results = const [];
  IptvChannel? _focused;

  static const _rowExtent = 84.0;

  @override
  void initState() {
    super.initState();
    _store.hold();
    _load();
  }

  @override
  void dispose() {
    _store.release();
    _name.dispose();
    _firstRow.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final catalogue = await _store.load();
      if (!mounted) return;
      setState(() => _catalogue = catalogue);
      _filter(focusFirst: true);
      if (catalogue.isStale(DateTime.now())) await _refresh();
    } catch (e) {
      debugPrint('IPTV catalogue: $e');
      if (mounted) setState(() => _error = '$e');
    }
  }

  /// Older than a day: fetched anew, the old one shown meanwhile.
  Future<void> _refresh() async {
    setState(() {
      _updating = true;
      _updateError = null;
    });
    try {
      final fresh = await _store.refresh();
      if (!mounted) return;
      setState(() => _catalogue = fresh);
      _filter();
    } catch (e) {
      debugPrint('IPTV catalogue update: $e');
      if (mounted) setState(() => _updateError = '$e');
    } finally {
      if (mounted) setState(() => _updating = false);
    }
  }

  void _filter({bool focusFirst = false}) {
    final catalogue = _catalogue;
    final settings = ref.read(iptvProvider);
    if (catalogue == null) return;
    final myCountries = settings?.countries ?? const <String>[];
    final countries = switch (_country) {
      _mine => myCountries.isEmpty ? null : myCountries.toSet(),
      _all => null,
      final c => {c},
    };
    final languages = switch (_language) {
      _mine => (settings?.languages ?? const <String>[]).toSet(),
      _all => null,
      final l => {l},
    };
    final query = _name.text.trim();
    final results = catalogue.channels
        .where((c) =>
            (countries == null || countries.contains(c.country)) &&
            (_category == _all || c.categories.contains(_category)) &&
            (languages == null || languages.isEmpty || c.languages.any(languages.contains)) &&
            c.matches(query))
        .toList();
    // "Meine Länder": in their order (Austria first, then Germany, ...).
    if (_country == _mine) {
      int rank(IptvChannel c) => myCountries.indexOf(c.country);
      mergeSort(results, compare: (a, b) => rank(a).compareTo(rank(b)));
    }
    setState(() => _results = results);
    if (_scroll.hasClients) _scroll.jumpTo(0);
    if (focusFirst) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _firstRow.context != null) _firstRow.requestFocus();
      });
    }
  }

  Future<void> _toggleFavorite(IptvChannel channel) async {
    final notifier = ref.read(iptvProvider.notifier);
    final t = context.l10n;
    final messenger = ScaffoldMessenger.of(context);
    final String message;
    if (ref.read(iptvProvider)?.isFavorite(channel.id) ?? false) {
      await notifier.removeFavorite(channel.id);
      message = t.iptvRemoved(channel.name);
    } else {
      final number = await notifier.addFavorite(channel);
      message = t.iptvAddedAsNumber(channel.name, number);
    }
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message), duration: const Duration(seconds: 3)));
  }

  KeyEventResult _onListKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (ref.read(remoteKeysProvider).matches(RemoteAction.options, event.logicalKey)) {
      final c = _focused;
      if (c != null) _toggleFavorite(c);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  String _countryLabel(String code) {
    final english = _catalogue?.countries[code]?.name ?? '';
    return countryName(code, english);
  }

  String _subtitle(IptvChannel c) {
    final catalogue = _catalogue;
    return [
      if (c.country.isNotEmpty) _countryLabel(c.country),
      if (c.categories.isNotEmpty) c.categories.map((x) => iptvCategoryName(x, catalogue?.categories)).join(', '),
      if (c.languages.isNotEmpty) c.languages.map((x) => iptvLanguageName(x, catalogue?.languages)).join(', '),
      if (c.streams.firstOrNull?.quality case final q?) '${q}p',
    ].join('  ·  ');
  }

  @override
  Widget build(BuildContext context) {
    final t = context.l10n;
    final settings = ref.watch(iptvProvider);
    final catalogue = _catalogue;
    final myCountries = settings?.countries ?? const <String>[];
    final myLanguages = settings?.languages ?? const <String>[];
    final countryCodes = (catalogue?.countries.keys.toList() ?? <String>[])
      ..sort((a, b) => _countryLabel(a).compareTo(_countryLabel(b)));
    final categoryIds = (catalogue?.categories.keys.toList() ?? <String>[])
      ..sort((a, b) => iptvCategoryName(a, catalogue?.categories).compareTo(iptvCategoryName(b, catalogue?.categories)));
    final languageCodes = (catalogue?.languages.keys.toList() ?? <String>[])
      ..sort((a, b) => iptvLanguageName(a, catalogue?.languages).compareTo(iptvLanguageName(b, catalogue?.languages)));
    // A choice no longer there (another catalogue, other settings): all -
    // the dropdowns are rebuilt then (their keys).
    if (catalogue != null) {
      if (_country != _mine && _country != _all && !countryCodes.contains(_country)) _country = _all;
      if (_category != _all && !categoryIds.contains(_category)) _category = _all;
      if (_language != _mine && _language != _all && !languageCodes.contains(_language)) _language = _all;
    }
    if (_language == _mine && myLanguages.isEmpty) _language = _all;
    final dropdownKey = '${catalogue?.updated.millisecondsSinceEpoch}|${myCountries.join()}|${myLanguages.join()}';

    return Scaffold(
      appBar: AppBar(
        title: Text(t.iptvBrowseTitle),
        actions: [
          IconButton(
            tooltip: t.iptvSettingsTitle,
            icon: const Icon(Icons.settings),
            // Back with other countries / languages: filtered anew.
            onPressed: () => Navigator.of(context)
                .push(MaterialPageRoute<void>(builder: (_) => const IptvSettingsScreen()))
                .then((_) => _filter()),
          ),
        ],
      ),
      body: FocusTraversalGroup(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Wrap(
                spacing: 16,
                runSpacing: 12,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  SizedBox(
                    width: 260,
                    child: PopupTextField(
                      controller: _name,
                      label: t.iptvSearchName,
                      icon: Icons.search,
                      onSubmitted: (_) => _filter(focusFirst: true),
                    ),
                  ),
                  SizedBox(
                    width: 260,
                    child: DropdownButtonFormField<String>(
                      key: ValueKey('country $dropdownKey'),
                      initialValue: _country,
                      isExpanded: true,
                      decoration: InputDecoration(labelText: t.iptvCountry, border: const OutlineInputBorder()),
                      items: [
                        DropdownMenuItem(
                          value: _mine,
                          child: Text(t.iptvMyCountries(myCountries.map((c) => _countryLabel(c)).join(', ')),
                              overflow: TextOverflow.ellipsis),
                        ),
                        DropdownMenuItem(value: _all, child: Text(t.iptvAllCountries)),
                        for (final c in countryCodes) DropdownMenuItem(value: c, child: Text(_countryLabel(c))),
                      ],
                      onChanged: (v) {
                        _country = v ?? _mine;
                        _filter();
                      },
                    ),
                  ),
                  SizedBox(
                    width: 220,
                    child: DropdownButtonFormField<String>(
                      key: ValueKey('category $dropdownKey'),
                      initialValue: _category,
                      isExpanded: true,
                      decoration: InputDecoration(labelText: t.iptvCategory, border: const OutlineInputBorder()),
                      items: [
                        DropdownMenuItem(value: _all, child: Text(t.iptvAllCategories)),
                        for (final c in categoryIds)
                          DropdownMenuItem(value: c, child: Text(iptvCategoryName(c, catalogue?.categories))),
                      ],
                      onChanged: (v) {
                        _category = v ?? _all;
                        _filter();
                      },
                    ),
                  ),
                  SizedBox(
                    width: 240,
                    child: DropdownButtonFormField<String>(
                      key: ValueKey('language $dropdownKey'),
                      initialValue: _language,
                      isExpanded: true,
                      decoration: InputDecoration(labelText: t.iptvLanguage, border: const OutlineInputBorder()),
                      items: [
                        if (myLanguages.isNotEmpty)
                          DropdownMenuItem(
                            value: _mine,
                            child: Text(
                                t.iptvMyLanguages(
                                    myLanguages.map((l) => iptvLanguageName(l, catalogue?.languages)).join(', ')),
                                overflow: TextOverflow.ellipsis),
                          ),
                        DropdownMenuItem(value: _all, child: Text(t.iptvAllLanguages)),
                        for (final l in languageCodes)
                          DropdownMenuItem(value: l, child: Text(iptvLanguageName(l, catalogue?.languages))),
                      ],
                      onChanged: (v) {
                        _language = v ?? _all;
                        _filter();
                      },
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      catalogue == null
                          ? ''
                          : [
                              t.iptvResultCount(_results.length),
                              t.iptvCatalogueDate(DateFormat.yMd(t.localeName).add_Hm().format(catalogue.updated)),
                              if (_updating) t.iptvUpdatingCatalogue,
                              if (_updateError != null) t.iptvUpdateFailed,
                            ].join('  ·  '),
                      style: const TextStyle(color: Colors.white60, fontSize: 14),
                    ),
                  ),
                  if (_updating) const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: Text(t.iptvBrowseKeyHint, style: TextStyle(color: Colors.white.withValues(alpha: 0.45), fontSize: 14)),
            ),
            const Divider(height: 1),
            Expanded(child: _body(context)),
          ],
        ),
      ),
    );
  }

  Widget _body(BuildContext context) {
    final t = context.l10n;
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(t.iptvCatalogueError(_error!), textAlign: TextAlign.center, style: const TextStyle(color: Colors.amber)),
              const SizedBox(height: 16),
              FilledButton.icon(
                autofocus: true,
                onPressed: () {
                  setState(() => _error = null);
                  _load();
                },
                icon: const Icon(Icons.refresh),
                label: Text(t.iptvTryAgain),
              ),
            ],
          ),
        ),
      );
    }
    if (_catalogue == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text(t.iptvLoadingCatalogue, style: const TextStyle(color: Colors.white70)),
          ],
        ),
      );
    }
    if (_results.isEmpty) {
      return Center(child: Text(t.iptvNoResults, style: const TextStyle(color: Colors.white70, fontSize: 18)));
    }
    final state = ref.watch(iptvProvider);
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: _onListKey,
      child: ListView.builder(
        controller: _scroll,
        itemCount: _results.length,
        itemExtent: _rowExtent,
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
        itemBuilder: (context, i) {
          final c = _results[i];
          final number = state?.numberOf(c.id);
          return Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(
              children: [
                Expanded(
                  child: TvRow(
                    focusNode: i == 0 ? _firstRow : null,
                    selected: c.id == widget.current?.id,
                    onFocused: () => _focused = c,
                    onTap: () => Navigator.of(context).pop(c),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      child: Row(
                        children: [
                          IptvLogo(channel: c, width: 84, height: 50),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(c.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600)),
                                const SizedBox(height: 2),
                                Text(_subtitle(c),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(color: Colors.white60, fontSize: 14)),
                              ],
                            ),
                          ),
                          if (number != null)
                            Padding(
                              padding: const EdgeInsets.only(left: 8),
                              child: Text(t.iptvFavoriteNumber(number),
                                  style: const TextStyle(color: brandGreen, fontSize: 15, fontWeight: FontWeight.w600)),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                IconButton(
                  tooltip: number != null ? t.iptvRemoveFavorite : t.iptvAddFavorite,
                  onPressed: () => _toggleFavorite(c),
                  icon: Icon(number != null ? Icons.star : Icons.star_border,
                      color: number != null ? brandGreen : Colors.white70, size: 30),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
