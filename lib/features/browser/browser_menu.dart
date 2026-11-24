import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/dpad_text_field.dart';
import '../../core/theme.dart';
import '../../l10n/l10n.dart';
import 'browser_settings.dart';

/// A button of the browser's bar: icon (and label), a clear frame when the
/// remote's focus is on it.
class BrowserBarButton extends StatefulWidget {
  const BrowserBarButton({
    super.key,
    required this.icon,
    required this.tooltip,
    this.label,
    this.onPressed,
    this.active = false,
    this.autofocus = false,
  });

  final IconData icon;
  final String tooltip;
  final String? label;
  final VoidCallback? onPressed;

  /// Shown as switched on (desktop view, bookmark set).
  final bool active;
  final bool autofocus;

  @override
  State<BrowserBarButton> createState() => _BrowserBarButtonState();
}

class _BrowserBarButtonState extends State<BrowserBarButton> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = widget.onPressed == null
        ? Colors.white38
        : (widget.active ? scheme.primary : Colors.white);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Tooltip(
        message: widget.tooltip,
        child: TvFocusHighlight(
          focused: _focused,
          borderRadius: BorderRadius.circular(10),
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            autofocus: widget.autofocus,
            focusColor: Colors.white12,
            onFocusChange: (v) => setState(() => _focused = v),
            onTap: widget.onPressed,
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: widget.label == null ? 10 : 12, vertical: 9),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(widget.icon, color: color, size: 24),
                  if (widget.label != null) ...[
                    const SizedBox(width: 8),
                    Text(widget.label!, style: TextStyle(color: color, fontSize: 15)),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The address in the bar: the page's title and address; OK opens the
/// address entry.
class BrowserAddressButton extends StatefulWidget {
  const BrowserAddressButton({super.key, required this.url, required this.title, required this.onPressed, this.autofocus = false});

  final String url;
  final String title;
  final VoidCallback onPressed;
  final bool autofocus;

  @override
  State<BrowserAddressButton> createState() => _BrowserAddressButtonState();
}

class _BrowserAddressButtonState extends State<BrowserAddressButton> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final secure = widget.url.startsWith('https://');
    return TvFocusHighlight(
      focused: _focused,
      borderRadius: BorderRadius.circular(22),
      child: Material(
        color: Colors.white10,
        borderRadius: BorderRadius.circular(22),
        child: InkWell(
          borderRadius: BorderRadius.circular(22),
          autofocus: widget.autofocus,
          focusColor: Colors.white12,
          onFocusChange: (v) => setState(() => _focused = v),
          onTap: widget.onPressed,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            child: Row(
              children: [
                Icon(secure ? Icons.lock_outline : Icons.public, size: 18, color: Colors.white70),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (widget.title.isNotEmpty)
                        Text(widget.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: Colors.white, fontSize: 15)),
                      Text(widget.url.isEmpty ? context.l10n.browserAddress : widget.url,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: Colors.white60, fontSize: 13)),
                    ],
                  ),
                ),
                const Icon(Icons.edit_outlined, size: 18, color: Colors.white54),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The bookmarks: OK opens one, the bin next to it removes it. Returns the
/// address to open.
Future<String?> showBrowserBookmarks(
  BuildContext context, {
  required List<Bookmark> Function() bookmarks,
  required Future<void> Function(String url) onRemove,
}) {
  return showDialog<String>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) {
        final l = context.l10n;
        final list = bookmarks();
        return AlertDialog(
          title: Text(l.browserBookmarks),
          content: SizedBox(
            width: 560,
            child: list.isEmpty
                ? Text(l.browserBookmarksEmpty)
                : ListView.builder(
                    shrinkWrap: true,
                    itemCount: list.length,
                    itemBuilder: (context, i) {
                      final b = list[i];
                      return Row(
                        children: [
                          Expanded(
                            child: ListTile(
                              autofocus: i == 0,
                              leading: const Icon(Icons.bookmark_outline),
                              title: Text(b.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                              subtitle: Text(b.url, maxLines: 1, overflow: TextOverflow.ellipsis),
                              onTap: () => Navigator.of(context).pop(b.url),
                            ),
                          ),
                          IconButton(
                            tooltip: l.browserRemove,
                            icon: const Icon(Icons.delete_outline),
                            onPressed: () async {
                              await onRemove(b.url);
                              setState(() {});
                            },
                          ),
                        ],
                      );
                    },
                  ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(l.commonCancel)),
          ],
        );
      },
    ),
  );
}

/// Text for a field of the page, typed with the remote (or the keyboard):
/// "Einfügen" puts it in, "Senden" also presses Enter. Returns null on Back.
Future<({String text, bool submit})?> showBrowserTextEntry(
  BuildContext context, {
  required String initial,
  String label = '',
  bool password = false,
  bool number = false,
}) {
  return showDialog<({String text, bool submit})>(
    context: context,
    builder: (_) => _TextEntryDialog(initial: initial, label: label, password: password, number: number),
  );
}

class _TextEntryDialog extends StatefulWidget {
  const _TextEntryDialog({required this.initial, required this.label, required this.password, required this.number});

  final String initial;
  final String label;
  final bool password;
  final bool number;

  @override
  State<_TextEntryDialog> createState() => _TextEntryDialogState();
}

class _TextEntryDialogState extends State<_TextEntryDialog> {
  late final _controller = TextEditingController(text: widget.initial)
    ..selection = TextSelection(baseOffset: 0, extentOffset: widget.initial.length);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _done(bool submit) => Navigator.of(context).pop((text: _controller.text, submit: submit));

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return AlertDialog(
      title: Text(widget.label.isEmpty ? l.browserEnterText : widget.label),
      content: SizedBox(
        width: 560,
        child: DpadTextField(
          controller: _controller,
          autofocus: true,
          obscureText: widget.password,
          keyboardType: widget.number ? TextInputType.number : TextInputType.text,
          decoration: const InputDecoration(),
          onSubmitted: (_) => _done(true),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(l.commonCancel)),
        TextButton(onPressed: () => _done(false), child: Text(l.browserTextInsert)),
        FilledButton(onPressed: () => _done(true), child: Text(l.browserTextSend)),
      ],
    );
  }
}

/// Keys that open / close the browser's bar.
bool isBrowserMenuKey(LogicalKeyboardKey key) => key == LogicalKeyboardKey.contextMenu;
