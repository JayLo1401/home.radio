import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/popup_text_field.dart';
import '../../data/services/adblock_lists.dart';
import '../../l10n/l10n.dart';
import 'browser_channel.dart';
import 'browser_settings.dart';

/// Einstellungen → Browser: the blocker (on/off, filter lists and their
/// sources, sites without it), search engine, home page, desktop view, text
/// size, clearing cookies / cache.
class BrowserSettingsScreen extends ConsumerStatefulWidget {
  const BrowserSettingsScreen({super.key});

  @override
  ConsumerState<BrowserSettingsScreen> createState() => _BrowserSettingsScreenState();
}

class _BrowserSettingsScreenState extends ConsumerState<BrowserSettingsScreen> {
  String? _webView;

  @override
  void initState() {
    super.initState();
    ref.read(browserSettingsProvider.notifier).loaded();
    ref.read(adblockProvider.notifier).prepare();
    BrowserChannel.webViewVersion().then((v) {
      if (mounted) setState(() => _webView = v);
    });
  }

  BrowserSettingsNotifier get _notifier => ref.read(browserSettingsProvider.notifier);

  Future<void> _chooseSearchEngine(BrowserSettings s) async {
    final engine = await showDialog<SearchEngine>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(context.l10n.browserSearchEngine),
        children: [
          for (final e in SearchEngine.values)
            SimpleDialogOption(
              onPressed: () => Navigator.of(context).pop(e),
              child: Row(
                children: [
                  Icon(e == s.searchEngine ? Icons.radio_button_checked : Icons.radio_button_unchecked),
                  const SizedBox(width: 12),
                  Text(e.label),
                ],
              ),
            ),
        ],
      ),
    );
    if (engine != null) await _notifier.update((s) => s.copyWith(searchEngine: engine));
  }

  Future<void> _editHomePage(BrowserSettings s) async {
    final l = context.l10n;
    final text = await showTextInputDialog(
      context,
      title: l.browserHomePage,
      initialValue: s.homePage,
      hint: s.searchEngine.homeUrl,
      keyboardType: TextInputType.url,
    );
    if (text == null) return;
    await _notifier.update((s) => s.copyWith(homePage: text.isEmpty ? '' : browserUrlFor(text, s.searchEngine)));
  }

  Future<void> _clear({required bool cookies}) async {
    final l = context.l10n;
    if (cookies) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(l.browserClearCookiesConfirm),
          actions: [
            TextButton(autofocus: true, onPressed: () => Navigator.of(context).pop(false), child: Text(l.commonCancel)),
            FilledButton(onPressed: () => Navigator.of(context).pop(true), child: Text(l.browserDelete)),
          ],
        ),
      );
      if (ok != true) return;
    }
    await BrowserChannel.clearData(cookies: cookies, cache: !cookies);
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l.browserCleared)));
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final s = ref.watch(browserSettingsProvider);
    final status = ref.watch(adblockProvider);
    final enabled = s.enabledLists;
    final meta = status.meta;
    final help = Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.white60);
    final locale = Localizations.localeOf(context).toLanguageTag();

    return Scaffold(
      appBar: AppBar(title: Text(l.browserSettingsTitle)),
      body: !BrowserChannel.supported
          ? Center(child: Text(l.browserAndroidOnly))
          : ListView(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              children: [
                SwitchListTile(
                  autofocus: true,
                  title: Text(l.browserBlocker),
                  subtitle: Text(l.browserBlockerHelp),
                  value: s.blocker,
                  onChanged: (v) => _notifier.update((s) => s.copyWith(blocker: v)),
                ),
                const Divider(),
                ListTile(
                  title: Text(l.browserFilterLists, style: Theme.of(context).textTheme.titleMedium),
                  subtitle: Text(
                    status.updating
                        ? l.browserListsUpdating
                        : meta == null
                            ? l.browserListsNever
                            : l.browserListsUpdated(DateFormat.yMd(locale).add_Hm().format(meta.updated), meta.rules),
                  ),
                  trailing: status.updating
                      ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))
                      : null,
                ),
                if (status.error != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Text(l.browserListsError, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                  ),
                if (meta != null && meta.failed.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Text(
                      l.browserListsFailed(
                          filterLists.where((f) => meta.failed.contains(f.id)).map((f) => f.name).join(', ')),
                      style: help,
                    ),
                  ),
                for (final list in filterLists)
                  CheckboxListTile(
                    value: enabled.contains(list.id),
                    title: Text(list.name),
                    subtitle: Text(l.browserListSource(list.license, list.homepage)),
                    onChanged: s.blocker && !status.updating
                        ? (v) {
                            final next = {...enabled};
                            v == true ? next.add(list.id) : next.remove(list.id);
                            if (next.isEmpty) return;
                            ref.read(adblockProvider.notifier).setLists(next);
                          }
                        : null,
                  ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                    child: OutlinedButton.icon(
                      icon: const Icon(Icons.refresh),
                      label: Text(l.browserListsUpdateNow),
                      onPressed: s.blocker && !status.updating ? () => ref.read(adblockProvider.notifier).update() : null,
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                  child: Text(l.browserListsCredit, style: help),
                ),
                const Divider(),
                ListTile(
                  title: Text(l.browserAllowlist, style: Theme.of(context).textTheme.titleMedium),
                  subtitle: s.allowlist.isEmpty ? Text(l.browserAllowlistEmpty) : null,
                ),
                for (final host in s.allowlist.toList()..sort())
                  ListTile(
                    leading: const Icon(Icons.shield_outlined),
                    title: Text(host),
                    trailing: const Icon(Icons.delete_outline),
                    onTap: () => _notifier.setAllowed(host, false),
                  ),
                const Divider(),
                ListTile(
                  leading: const Icon(Icons.search),
                  title: Text(l.browserSearchEngine),
                  subtitle: Text(s.searchEngine.label),
                  onTap: () => _chooseSearchEngine(s),
                ),
                ListTile(
                  leading: const Icon(Icons.home_outlined),
                  title: Text(l.browserHomePage),
                  subtitle: Text(s.homePage.isEmpty ? l.browserHomePageDefault : s.homePage),
                  onTap: () => _editHomePage(s),
                ),
                SwitchListTile(
                  secondary: const Icon(Icons.desktop_windows_outlined),
                  title: Text(l.browserDesktopDefault),
                  subtitle: Text(l.browserDesktopHelp),
                  value: s.desktop,
                  onChanged: (v) => _notifier.update((s) => s.copyWith(desktop: v)),
                ),
                ListTile(
                  leading: const Icon(Icons.format_size),
                  title: Text(l.browserTextZoom),
                  subtitle: Text(l.browserTextSize(s.textZoom)),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        tooltip: l.browserSmaller,
                        icon: const Icon(Icons.remove),
                        onPressed: () => _stepZoom(s, -1),
                      ),
                      IconButton(
                        tooltip: l.browserLarger,
                        icon: const Icon(Icons.add),
                        onPressed: () => _stepZoom(s, 1),
                      ),
                    ],
                  ),
                ),
                const Divider(),
                ListTile(
                  leading: const Icon(Icons.cookie_outlined),
                  title: Text(l.browserClearCookies),
                  onTap: () => _clear(cookies: true),
                ),
                ListTile(
                  leading: const Icon(Icons.cleaning_services_outlined),
                  title: Text(l.browserClearCache),
                  onTap: () => _clear(cookies: false),
                ),
                if (_webView != null)
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(l.browserWebView(_webView!), style: help),
                  ),
              ],
            ),
    );
  }

  Future<void> _stepZoom(BrowserSettings s, int step) {
    const steps = BrowserSettings.textZoomSteps;
    var i = steps.indexOf(s.textZoom);
    if (i < 0) i = steps.indexOf(100);
    return _notifier.update((s) => s.copyWith(textZoom: steps[(i + step).clamp(0, steps.length - 1)]));
  }
}
