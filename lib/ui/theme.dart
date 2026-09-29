import 'package:flutter/material.dart';

/// Design tokens. Dark-first, from the Dokku Console design.
abstract final class C {
  static const bg = Color(0xFF0A0A0B);
  static const card = Color(0xFF111113);
  static const elev = Color(0xFF16161A);
  static const elev2 = Color(0xFF1C1C21);
  static const field = Color(0xFF0E0E10);
  static const term = Color(0xFF0C0C0E);

  static const fg = Color(0xFFEDEDEF);
  static const soft = Color(0xFFC9C9CC);
  static const muted = Color(0xFF8A8A90);
  static const dim = Color(0xFF5F5F66);

  static const ok = Color(0xFF22C55E);
  static const warn = Color(0xFFF59E0B);
  static const info = Color(0xFF3B82F6);
  static const bad = Color(0xFFEF4444);
  static const mute = Color(0xFF9CA3AF);
  static const violet = Color(0xFFA78BFA);

  /// White at the given opacity, used for hairlines and subtle fills.
  static Color w(double opacity) => Colors.white.withValues(alpha: opacity);

  static final line = w(.08);
  static final lineSoft = w(.06);
  static final lineStrong = w(.10);
}

enum Tone { ok, warn, info, bad, mute, soft }

extension ToneColor on Tone {
  Color get color => switch (this) {
        Tone.ok => C.ok,
        Tone.warn => C.warn,
        Tone.info => C.info,
        Tone.bad => C.bad,
        Tone.mute => C.mute,
        Tone.soft => C.soft,
      };

  /// Tinted surface: 12% fill, 26% border, full-hue text.
  Color get fill => color.withValues(alpha: .12);
  Color get border => color.withValues(alpha: .26);
}

const fontSans = 'Geist';
const fontMono = 'GeistMono';

/// Text styles. Sizes follow the design: 13px base, dense.
abstract final class T {
  static const base = TextStyle(fontFamily: fontSans, fontSize: 13, color: C.fg, height: 1.35, letterSpacing: 0);

  static TextStyle sans(double size, {Color color = C.fg, FontWeight weight = FontWeight.w400, double? height, double spacing = 0}) =>
      TextStyle(fontFamily: fontSans, fontSize: size, color: color, fontWeight: weight, height: height, letterSpacing: spacing);

  static TextStyle mono(double size, {Color color = C.fg, FontWeight weight = FontWeight.w400, double? height, double spacing = 0}) =>
      TextStyle(
        fontFamily: fontMono,
        fontSize: size,
        color: color,
        fontWeight: weight,
        height: height,
        letterSpacing: spacing,
        fontFeatures: const [FontFeature.tabularFigures()],
      );

  static final h1 = sans(26, weight: FontWeight.w600, height: 1.15, spacing: -.6);
  static final title = sans(13.5, weight: FontWeight.w600, spacing: -.13);
  static final body = sans(12.5);
  static final small = sans(12, color: C.muted, height: 1.5);
  static final hint = sans(11.5, color: C.muted, height: 1.45);
  static final tiny = sans(11, color: C.dim);
  static final eyebrow = sans(10.5, color: C.muted, weight: FontWeight.w600, spacing: .5);
  static final code = mono(11.5);
  static final codeMuted = mono(11, color: C.muted, height: 1.5);
  static final meta = mono(10.5, color: C.muted);
  static final th = mono(10.5, color: C.muted, spacing: .4);
  static final stat = mono(27, weight: FontWeight.w500, spacing: -.8, height: 1.1);
}

/// Layout breakpoints.
abstract final class Bp {
  /// Below this the sidebar becomes bottom navigation.
  static const compact = 760.0;

  /// Below this two-column pages stack.
  static const twoCol = 820.0;

  static bool isCompact(BuildContext context) => MediaQuery.sizeOf(context).width < compact;
}

ThemeData buildTheme() {
  final scheme = const ColorScheme.dark(
    surface: C.bg,
    primary: C.fg,
    onPrimary: C.bg,
    secondary: C.info,
    error: C.bad,
    onSurface: C.fg,
  );
  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: scheme,
    scaffoldBackgroundColor: C.bg,
    canvasColor: C.card,
    fontFamily: fontSans,
    splashFactory: NoSplash.splashFactory,
    highlightColor: Colors.transparent,
    hoverColor: C.w(.04),
    dividerColor: C.line,
    textTheme: const TextTheme(bodyMedium: T.base, bodyLarge: T.base, bodySmall: T.base).apply(fontFamily: fontSans),
    textSelectionTheme: TextSelectionThemeData(cursorColor: C.fg, selectionColor: C.w(.18), selectionHandleColor: C.fg),
    scrollbarTheme: ScrollbarThemeData(
      thickness: const WidgetStatePropertyAll(6),
      radius: const Radius.circular(8),
      thumbColor: WidgetStatePropertyAll(C.w(.14)),
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(color: C.elev2, borderRadius: BorderRadius.circular(6), border: Border.all(color: C.lineStrong)),
      textStyle: T.sans(11.5),
      waitDuration: const Duration(milliseconds: 400),
    ),
    dialogTheme: const DialogThemeData(backgroundColor: C.card, surfaceTintColor: Colors.transparent),
    popupMenuTheme: PopupMenuThemeData(
      color: C.card,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: BorderSide(color: C.lineStrong)),
      textStyle: T.body,
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: C.field,
      surfaceTintColor: Colors.transparent,
      indicatorColor: C.w(.09),
      height: 62,
      labelTextStyle: WidgetStateProperty.resolveWith(
        (s) => T.sans(10.5, color: s.contains(WidgetState.selected) ? C.fg : C.muted, weight: FontWeight.w500),
      ),
      iconTheme: WidgetStateProperty.resolveWith(
        (s) => IconThemeData(size: 19, color: s.contains(WidgetState.selected) ? C.fg : C.muted),
      ),
    ),
  );
}
