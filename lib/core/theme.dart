import 'package:flutter/material.dart';

/// Accent color, matched to linymo.com's brand green (from its logo mark).
const brandGreen = Color(0xFF2F9E5C);
const brandGreenDark = Color(0xFF1B6B3E);

/// TV-optimized dark theme: large text/targets for 10-foot viewing distance.
ThemeData buildTvTheme() {
  final base = ThemeData(
    brightness: Brightness.dark,
    useMaterial3: true,
    colorSchemeSeed: brandGreen,
    scaffoldBackgroundColor: Colors.black,
    visualDensity: VisualDensity.standard,
  );
  // The seeded dark ColorScheme's `primary` is a lighter tint of the brand
  // green, which reads far better as a focus ring on a black background
  // than the raw (dark) brand color would.
  final focusColor = base.colorScheme.primary;

  // Every standard Material button gets a bold, unmistakable green border
  // whenever it's focused via D-Pad/keyboard - the default Material focus
  // treatment (a faint overlay tint) is too subtle to read from a couch on
  // a 65" TV. This is a single global fix instead of wrapping every button
  // in the app individually.
  WidgetStateProperty<BorderSide?> focusBorder({double width = 3}) {
    return WidgetStateProperty.resolveWith((states) {
      if (states.contains(WidgetState.focused)) {
        return BorderSide(color: focusColor, width: width);
      }
      return null;
    });
  }

  return base.copyWith(
    focusColor: focusColor,
    filledButtonTheme: FilledButtonThemeData(
      style: ButtonStyle(side: focusBorder()),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: ButtonStyle(side: focusBorder()),
    ),
    textButtonTheme: TextButtonThemeData(
      style: ButtonStyle(
        side: focusBorder(),
        // TextButton has no visible border by default even when unfocused;
        // give it a transparent one so the focused border doesn't shift
        // the button's size/position when it appears.
        shape: const WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(8))),
        ),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: ButtonStyle(
        side: focusBorder(width: 2),
        shape: const WidgetStatePropertyAll(CircleBorder()),
      ),
    ),
  );
}

/// Consistent focus highlight used across TV-navigable widgets.
class TvFocusHighlight extends StatelessWidget {
  final bool focused;
  final Widget child;
  final BorderRadius borderRadius;

  const TvFocusHighlight({
    super.key,
    required this.focused,
    required this.child,
    this.borderRadius = const BorderRadius.all(Radius.circular(12)),
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      decoration: BoxDecoration(
        borderRadius: borderRadius,
        border: Border.all(
          color: focused ? Theme.of(context).focusColor : Colors.transparent,
          width: 3,
        ),
        boxShadow: focused
            ? [
                BoxShadow(
                  color: Theme.of(context).focusColor.withValues(alpha: 0.5),
                  blurRadius: 12,
                  spreadRadius: 1,
                ),
              ]
            : null,
      ),
      child: child,
    );
  }
}
