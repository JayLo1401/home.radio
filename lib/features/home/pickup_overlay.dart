import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../data/services/order_service.dart';

/// Opens/closes the "Bitte abholen" popup for orders the kitchen just
/// completed (see PickupNotifier) - wraps the whole app (MaterialApp's
/// builder) so it appears over whatever screen is open, Settings included.
///
/// A real dialog route on the app's navigator rather than a plain overlay:
/// that's what gives it proper focus handling - the "Schließen" button is
/// focused right away so the remote's OK closes it, the remote's Back key
/// and a mouse click beside it close it too, and D-Pad focus can't wander
/// off into the screen underneath. It also closes on its own once the
/// display duration runs out (PickupNotifier sets its state back to null).
class PickupPopupHost extends ConsumerStatefulWidget {
  const PickupPopupHost({super.key, required this.navigatorKey, required this.child});

  final GlobalKey<NavigatorState> navigatorKey;
  final Widget child;

  @override
  ConsumerState<PickupPopupHost> createState() => _PickupPopupHostState();
}

class _PickupPopupHostState extends ConsumerState<PickupPopupHost> {
  // The open popup's own route, so closing it removes exactly that route -
  // never whatever else happens to be on top of the navigator.
  Route<void>? _route;

  void _open() {
    final navigatorContext = widget.navigatorKey.currentContext;
    if (_route != null || navigatorContext == null) return;
    showDialog<void>(
      context: navigatorContext,
      barrierColor: Colors.black.withValues(alpha: 0.6),
      builder: (dialogContext) {
        _route = ModalRoute.of(dialogContext);
        return const _PickupDialog();
      },
    ).then((_) {
      _route = null;
      // Closed by the user (button, Back, click beside it) rather than by
      // the timer - clear the announcement so it doesn't come back up; new
      // completions still open a fresh popup.
      if (mounted) ref.read(pickupProvider.notifier).dismiss();
    });
  }

  void _close() {
    final route = _route;
    if (route == null || !route.isActive) return;
    route.navigator?.removeRoute(route);
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(pickupProvider, (previous, next) {
      if (next != null && previous == null) {
        // After this frame - showDialog can't run in the middle of a build.
        WidgetsBinding.instance.addPostFrameCallback((_) => _open());
      } else if (next == null && previous != null) {
        _close();
      }
    });
    return widget.child;
  }
}

class _DishGroup {
  _DishGroup(this.icon, this.name);

  final String icon;
  final String name;
  final items = <ReadyItem>[];

  bool get hasOptions => items.any((i) => i.options.isNotEmpty);
}

/// The popup itself - takes most of the screen but not all of it, groups
/// identical dishes ("3× 🎃 Kürbiscremesuppe: Anna, Ben, Carla") since many
/// soups often finish at once, always lists every name (never cut short to
/// "… und 5 weitere" - everyone has to find their own), and scales the list
/// down to fit rather than overflowing however much there is. Watches pickupProvider itself, so orders completed while it's
/// open are added in place.
class _PickupDialog extends ConsumerWidget {
  const _PickupDialog();

  static const _accent = Color(0xFFFFB300);

  List<_DishGroup> _group(List<ReadyItem> items) {
    final groups = <String, _DishGroup>{};
    for (final item in items) {
      groups
          .putIfAbsent('${item.itemIcon}|${item.itemName}', () => _DishGroup(item.itemIcon, item.itemName))
          .items
          .add(item);
    }
    return groups.values.toList();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Kept while the popup is closing (state already back to null) so it
    // doesn't flash empty during its exit animation.
    final items = ref.watch(pickupProvider)?.items ?? const <ReadyItem>[];
    final groups = _group(items);
    final size = MediaQuery.sizeOf(context);
    final width = size.width * 0.7;

    return Dialog(
      backgroundColor: const Color(0xFF141A22),
      insetPadding: EdgeInsets.symmetric(horizontal: size.width * 0.15, vertical: size.height * 0.1),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(24),
        side: const BorderSide(color: _accent, width: 3),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(32, 24, 32, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Row(
              children: [
                Icon(Icons.notifications_active_rounded, color: _accent, size: 48),
                SizedBox(width: 14),
                Expanded(
                  child: Text(
                    'Bitte abholen',
                    style: TextStyle(color: _accent, fontSize: 44, fontWeight: FontWeight.w800),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            // Never overflow, however many orders came in at once - scale
            // the list down instead. The fixed width keeps line wrapping as
            // it would be unscaled.
            Flexible(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: width - 64,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [for (final group in groups) _GroupView(group: group)],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 20),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.icon(
                autofocus: true,
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close_rounded),
                label: const Text('Schließen', style: TextStyle(fontSize: 20)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _GroupView extends StatelessWidget {
  const _GroupView({required this.group});

  final _DishGroup group;

  @override
  Widget build(BuildContext context) {
    final count = group.items.length;
    final title = [if (count > 1) '$count×', if (group.icon.isNotEmpty) group.icon, group.name].join(' ');

    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(color: Colors.white, fontSize: 32, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 4),
          // With options (e.g. ice cream flavour) each guest needs their own
          // line so it's clear whose is whose; without, one compact line of
          // names is far easier to take in when a dozen soups finish at once.
          if (group.hasOptions) ..._optionLines() else _nameLine(),
        ],
      ),
    );
  }

  Widget _nameLine() {
    return Text(
      group.items.map((i) => i.who).join(', '),
      style: const TextStyle(color: Colors.white70, fontSize: 26),
    );
  }

  // Name with its options underneath, as blocks side by side (wrapping)
  // rather than one per line - uses the popup's width, so even a dozen
  // desserts at once need far less shrinking to fit.
  List<Widget> _optionLines() {
    return [
      Wrap(
        spacing: 32,
        runSpacing: 8,
        children: [
          for (final item in group.items)
            Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(item.who, style: const TextStyle(color: Colors.white70, fontSize: 26)),
                if (item.options.isNotEmpty)
                  Text(item.options, style: const TextStyle(color: Colors.white54, fontSize: 20)),
              ],
            ),
        ],
      ),
    ];
  }
}
