import 'package:flutter/material.dart';

import 'i18n.dart';

/// Palette: a modern take on the red cloth-bound hal-khata ledger —
/// warm paper, ink, ledger green, marigold accents.
abstract final class C {
  static const paper = Color(0xFFF4EFE4);
  static const paper2 = Color(0xFFEDE6D7);
  static const card = Color(0xFFFFFDF8);
  static const ink = Color(0xFF1C1915);
  static const ink2 = Color(0xFF5B5449);
  static const ink3 = Color(0xFF8E8678);
  static const line = Color(0xFFE2D9C7);
  static const line2 = Color(0xFFEDE6D8);

  static const brand = Color(0xFF0F4C3A);
  static const brandDeep = Color(0xFF0A3328);
  static const brandMid = Color(0xFF1E6B53);
  static const brandSoft = Color(0xFFE0EDE6);

  static const marigold = Color(0xFFE39B2D);
  static const marigoldSoft = Color(0xFFFAEBD3);

  static const inGreen = Color(0xFF1A7A47);
  static const inSoft = Color(0xFFDFF1E6);
  static const outRed = Color(0xFFB4381F);
  static const outSoft = Color(0xFFF7E1DA);
  static const margin = Color(0xFFD9534F); // khata page margin line
  static const info = Color(0xFF2B5C87);
  static const infoSoft = Color(0xFFE1EAF3);
  static const warn = Color(0xFFA86B0C);
  static const warnSoft = Color(0xFFFAEED6);
}

enum Tone { neutral, brand, good, bad, warn, info, accent }

extension ToneColors on Tone {
  Color get fg => switch (this) {
        Tone.neutral => C.ink2,
        Tone.brand => C.brand,
        Tone.good => C.inGreen,
        Tone.bad => C.outRed,
        Tone.warn => C.warn,
        Tone.info => C.info,
        Tone.accent => const Color(0xFF8A5A10),
      };
  Color get bg => switch (this) {
        Tone.neutral => C.paper2,
        Tone.brand => C.brandSoft,
        Tone.good => C.inSoft,
        Tone.bad => C.outSoft,
        Tone.warn => C.warnSoft,
        Tone.info => C.infoSoft,
        Tone.accent => C.marigoldSoft,
      };
}

const kBody = 'HindSiliguri';
const kDisplay = 'Bricolage';

abstract final class Txt {
  /// Headings and big numbers. Bricolage has no Bangla glyphs, so Bangla
  /// mode uses Hind Siliguri bold instead.
  static TextStyle display(double size, {Color color = C.ink, double weight = 700}) {
    if (isBangla) {
      return TextStyle(
        fontFamily: kBody,
        fontSize: size * 0.95,
        fontWeight: weight >= 650 ? FontWeight.w700 : FontWeight.w600,
        color: color,
        height: 1.25,
      );
    }
    return TextStyle(
      fontFamily: kDisplay,
      fontFamilyFallback: const [kBody],
      fontSize: size,
      fontVariations: [FontVariation('wght', weight), const FontVariation('opsz', 32)],
      letterSpacing: -0.02 * size,
      color: color,
      height: 1.12,
    );
  }

  static const body = TextStyle(fontFamily: kBody, fontSize: 14, color: C.ink, height: 1.35);
  static const small = TextStyle(fontFamily: kBody, fontSize: 12.5, color: C.ink2, height: 1.3);
  static const tiny = TextStyle(fontFamily: kBody, fontSize: 11.5, color: C.ink3, height: 1.25, letterSpacing: 0.2);
  static const label = TextStyle(fontFamily: kBody, fontSize: 12.5, color: C.ink2, fontWeight: FontWeight.w600);
  static const strong = TextStyle(fontFamily: kBody, fontSize: 14, color: C.ink, fontWeight: FontWeight.w600);
  static const caps = TextStyle(
      fontFamily: kBody, fontSize: 11, color: C.ink3, fontWeight: FontWeight.w700, letterSpacing: 1.1);

  /// Money in tables: tabular figures so columns line up.
  static const num = TextStyle(
    fontFamily: kBody,
    fontSize: 14,
    color: C.ink,
    fontWeight: FontWeight.w600,
    fontFeatures: [FontFeature.tabularFigures()],
  );
}

ThemeData buildTheme() {
  final scheme = ColorScheme.fromSeed(seedColor: C.brand).copyWith(
    primary: C.brand,
    onPrimary: Colors.white,
    primaryContainer: C.brandSoft,
    onPrimaryContainer: C.brandDeep,
    secondary: C.marigold,
    onSecondary: C.ink,
    secondaryContainer: C.marigoldSoft,
    surface: C.card,
    onSurface: C.ink,
    onSurfaceVariant: C.ink2,
    surfaceContainerLowest: Colors.white,
    surfaceContainerLow: C.card,
    surfaceContainer: C.paper,
    surfaceContainerHigh: C.paper2,
    surfaceContainerHighest: C.paper2,
    error: C.outRed,
    outline: C.line,
    outlineVariant: C.line2,
  );

  final radius = BorderRadius.circular(10);
  OutlineInputBorder border(Color c, [double w = 1]) =>
      OutlineInputBorder(borderRadius: radius, borderSide: BorderSide(color: c, width: w));

  final buttonShape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(10));
  const buttonText = TextStyle(fontFamily: kBody, fontSize: 14, fontWeight: FontWeight.w600);

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    fontFamily: kBody,
    scaffoldBackgroundColor: C.paper,
    canvasColor: C.card,
    visualDensity: VisualDensity.standard,
    splashFactory: InkSparkle.splashFactory,
    textTheme: const TextTheme(
      bodyLarge: TextStyle(fontSize: 15, color: C.ink),
      bodyMedium: TextStyle(fontSize: 14, color: C.ink),
      bodySmall: TextStyle(fontSize: 12.5, color: C.ink2),
      titleLarge: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: C.ink),
      titleMedium: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: C.ink),
      titleSmall: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: C.ink),
      labelLarge: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: Colors.white,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      border: border(C.line),
      enabledBorder: border(C.line),
      focusedBorder: border(C.brand, 1.6),
      errorBorder: border(C.outRed),
      focusedErrorBorder: border(C.outRed, 1.6),
      labelStyle: const TextStyle(color: C.ink2, fontSize: 14),
      floatingLabelStyle: const TextStyle(color: C.brand, fontWeight: FontWeight.w600),
      hintStyle: const TextStyle(color: C.ink3, fontSize: 14),
      prefixIconColor: C.ink3,
      suffixIconColor: C.ink3,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: C.brand,
        foregroundColor: Colors.white,
        disabledBackgroundColor: C.paper2,
        minimumSize: const Size(0, 42),
        padding: const EdgeInsets.symmetric(horizontal: 18),
        shape: buttonShape,
        textStyle: buttonText,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: C.ink,
        backgroundColor: C.card,
        minimumSize: const Size(0, 42),
        padding: const EdgeInsets.symmetric(horizontal: 16),
        side: const BorderSide(color: C.line),
        shape: buttonShape,
        textStyle: buttonText,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: C.brand,
        minimumSize: const Size(0, 38),
        shape: buttonShape,
        textStyle: buttonText,
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(foregroundColor: C.ink2, shape: buttonShape),
    ),
    cardTheme: CardThemeData(
      color: C.card,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14), side: const BorderSide(color: C.line)),
    ),
    dividerTheme: const DividerThemeData(color: C.line2, space: 1, thickness: 1),
    dialogTheme: DialogThemeData(
      backgroundColor: C.card,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      titleTextStyle: Txt.display(20),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: C.ink,
      contentTextStyle: const TextStyle(fontFamily: kBody, color: Colors.white, fontSize: 14),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(color: C.ink, borderRadius: BorderRadius.circular(6)),
      textStyle: const TextStyle(fontFamily: kBody, color: Colors.white, fontSize: 12),
      waitDuration: const Duration(milliseconds: 400),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: C.card,
      selectedColor: C.brandSoft,
      side: const BorderSide(color: C.line),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      labelStyle: const TextStyle(fontFamily: kBody, fontSize: 13, color: C.ink),
      showCheckmark: false,
      padding: const EdgeInsets.symmetric(horizontal: 6),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? Colors.white : C.ink3),
      trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? C.brand : C.paper2),
      trackOutlineColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? C.brand : C.line),
    ),
    checkboxTheme: CheckboxThemeData(
      fillColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? C.brand : Colors.transparent),
      side: const BorderSide(color: C.ink3, width: 1.4),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
    ),
    scrollbarTheme: ScrollbarThemeData(
      thickness: const WidgetStatePropertyAll(8),
      radius: const Radius.circular(8),
      thumbColor: WidgetStatePropertyAll(C.ink3.withValues(alpha: 0.35)),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: C.card,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: const BorderSide(color: C.line)),
      textStyle: const TextStyle(fontFamily: kBody, fontSize: 14, color: C.ink),
    ),
    tabBarTheme: const TabBarThemeData(
      labelColor: C.brand,
      unselectedLabelColor: C.ink2,
      indicatorColor: C.brand,
      dividerColor: C.line2,
      labelStyle: TextStyle(fontFamily: kBody, fontWeight: FontWeight.w700, fontSize: 14),
      unselectedLabelStyle: TextStyle(fontFamily: kBody, fontWeight: FontWeight.w500, fontSize: 14),
      tabAlignment: TabAlignment.start,
    ),
    datePickerTheme: DatePickerThemeData(
      backgroundColor: C.card,
      surfaceTintColor: Colors.transparent,
      headerBackgroundColor: C.brand,
      headerForegroundColor: Colors.white,
      rangeSelectionBackgroundColor: C.brandSoft,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(color: C.brand),
  );
}
