import 'package:flutter/material.dart';

/// Design tokens: warm ink, bone text, one gold accent; Fraunces display + Inter body.
/// Flat surfaces, hairline rules, no gradients or glows.
class Atlas {
  static const ink = Color(0xFF0D0D0C);
  static const surface = Color(0xFF151513);
  static const bone = Color(0xFFECE7DC);
  static const boneHi = Color(0xFFF3EEE3);
  static const accent = Color(0xFFE3B65B);
  static const sage = Color(0xFF9ED8B5);
  static const muted = Color(0xFF8F8A7E);
  static const faint = Color(0xFF6F6B61);
  static const body = Color(0xFFCFC9BB);
  static const hair = Color(0x1AECE7DC); // 10 % bone

  static TextStyle serif({double size = 24, double height = 1.15, FontWeight weight = FontWeight.w400, Color? color, bool italic = false}) =>
      TextStyle(
        fontFamily: 'Fraunces',
        fontSize: size,
        height: height,
        fontWeight: weight,
        fontStyle: italic ? FontStyle.italic : FontStyle.normal,
        fontVariations: [
          FontVariation('wght', weight.value.toDouble()),
          FontVariation('opsz', size.clamp(9, 144).toDouble()),
          const FontVariation('SOFT', 0),
          const FontVariation('WONK', 0),
        ],
        letterSpacing: -size * .015,
        color: color ?? boneHi,
      );

  static const kicker = TextStyle(fontSize: 11, letterSpacing: 2.4, fontWeight: FontWeight.w500, color: muted);

  static BoxDecoration outline({double radius = 999}) =>
      BoxDecoration(borderRadius: BorderRadius.circular(radius), border: Border.all(color: bone.withValues(alpha: .22)));

  static ThemeData theme() {
    final scheme = ColorScheme.fromSeed(seedColor: accent, brightness: Brightness.dark).copyWith(
      surface: ink,
      primary: accent,
      onPrimary: ink,
      secondary: sage,
      onSurface: bone,
      onSurfaceVariant: muted,
      surfaceContainer: surface,
      surfaceContainerHigh: const Color(0xFF1B1B18),
      surfaceContainerHighest: const Color(0xFF242421),
      primaryContainer: const Color(0xFF2A2418),
      onPrimaryContainer: bone,
      secondaryContainer: const Color(0xFF23231F),
      onSecondaryContainer: bone,
      outline: const Color(0xFF4A473F),
      outlineVariant: const Color(0xFF2E2D28),
      error: const Color(0xFFE08A7A),
    );
    final shape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(999));
    return ThemeData(
      useMaterial3: true,
      fontFamily: 'Inter',
      colorScheme: scheme,
      scaffoldBackgroundColor: ink,
      canvasColor: ink,
      splashFactory: InkRipple.splashFactory,
      appBarTheme: const AppBarTheme(backgroundColor: ink, surfaceTintColor: Colors.transparent, elevation: 0, scrolledUnderElevation: 0, centerTitle: false),
      cardTheme: CardThemeData(elevation: 0, color: surface, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6))),
      dialogTheme: DialogThemeData(backgroundColor: const Color(0xFF181816), surfaceTintColor: Colors.transparent, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
      bottomSheetTheme: const BottomSheetThemeData(backgroundColor: Color(0xFF151513), surfaceTintColor: Colors.transparent, shape: RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16)))),
      chipTheme: ChipThemeData(
        shape: shape,
        side: BorderSide(color: bone.withValues(alpha: .16)),
        backgroundColor: Colors.transparent,
        selectedColor: accent.withValues(alpha: .18),
        checkmarkColor: accent,
        labelStyle: const TextStyle(fontWeight: FontWeight.w500, fontSize: 13, color: bone),
        padding: const EdgeInsets.symmetric(horizontal: 4),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: bone,
          foregroundColor: ink,
          minimumSize: const Size(0, 44),
          shape: shape,
          textStyle: const TextStyle(fontWeight: FontWeight.w600),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(0, 44),
          foregroundColor: bone,
          side: BorderSide(color: bone.withValues(alpha: .22)),
          shape: shape,
        ),
      ),
      textButtonTheme: TextButtonThemeData(style: TextButton.styleFrom(foregroundColor: bone)),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          shape: WidgetStatePropertyAll(shape),
          side: WidgetStatePropertyAll(BorderSide(color: bone.withValues(alpha: .18))),
          backgroundColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? accent.withValues(alpha: .16) : Colors.transparent),
          foregroundColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? accent : bone),
        ),
      ),
      searchBarTheme: SearchBarThemeData(
        elevation: const WidgetStatePropertyAll(0),
        backgroundColor: const WidgetStatePropertyAll(Colors.transparent),
        shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.circular(999), side: BorderSide(color: bone.withValues(alpha: .2)))),
      ),
      inputDecorationTheme: InputDecorationTheme(
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: bone.withValues(alpha: .2))),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: bone.withValues(alpha: .2))),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: accent)),
      ),
      dividerTheme: const DividerThemeData(color: hair, thickness: 1, space: 1),
      listTileTheme: const ListTileThemeData(iconColor: bone),
      progressIndicatorTheme: const ProgressIndicatorThemeData(color: accent, linearTrackColor: Color(0xFF2A2924)),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? ink : muted),
        trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? accent : const Color(0xFF2A2924)),
        trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
      ),
      navigationRailTheme: const NavigationRailThemeData(
        backgroundColor: ink,
        indicatorColor: Colors.transparent,
        selectedIconTheme: IconThemeData(color: bone),
        unselectedIconTheme: IconThemeData(color: Color(0xFF7E7A6F)),
        selectedLabelTextStyle: TextStyle(color: bone, fontWeight: FontWeight.w600),
        unselectedLabelTextStyle: TextStyle(color: Color(0xFF7E7A6F)),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: ink,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        height: 68,
        indicatorColor: Colors.transparent,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysHide,
        iconTheme: WidgetStateProperty.resolveWith((s) => IconThemeData(color: s.contains(WidgetState.selected) ? bone : const Color(0xFF7E7A6F))),
      ),
      sliderTheme: const SliderThemeData(activeTrackColor: accent, thumbColor: accent, inactiveTrackColor: Color(0xFF2A2924), trackHeight: 3),
    );
  }
}
