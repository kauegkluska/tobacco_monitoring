import 'package:flutter/material.dart';

/// Cores de estado e do gráfico (tokens do DESIGN.md), com variação clara e escura.
@immutable
class AppColors extends ThemeExtension<AppColors> {
  const AppColors({
    required this.surface2,
    required this.surface3,
    required this.border,
    required this.muted,
    required this.textSecondary,
    required this.ok,
    required this.okContainer,
    required this.onOkContainer,
    required this.warn,
    required this.warnContainer,
    required this.onWarnContainer,
    required this.crit,
    required this.critContainer,
    required this.onCritContainer,
    required this.offline,
    required this.offlineContainer,
    required this.onOfflineContainer,
    required this.infoContainer,
    required this.onInfoContainer,
    required this.chartLine,
    required this.chartArea,
    required this.chartBand,
    required this.chartGrid,
    required this.chartLimit,
  });

  final Color surface2;
  final Color surface3;
  final Color border;
  final Color muted;
  final Color textSecondary;
  final Color ok;
  final Color okContainer;
  final Color onOkContainer;
  final Color warn;
  final Color warnContainer;
  final Color onWarnContainer;
  final Color crit;
  final Color critContainer;
  final Color onCritContainer;
  final Color offline;
  final Color offlineContainer;
  final Color onOfflineContainer;
  final Color infoContainer;
  final Color onInfoContainer;
  final Color chartLine;
  final Color chartArea;
  final Color chartBand;
  final Color chartGrid;
  final Color chartLimit;

  static const light = AppColors(
    surface2: Color(0xffeef3ee),
    surface3: Color(0xffe3ebe3),
    border: Color(0xffdde6dc),
    muted: Color(0xff69735f),
    textSecondary: Color(0xff40493d),
    ok: Color(0xff2e7d32),
    okContainer: Color(0xffdff0dc),
    onOkContainer: Color(0xff0b3d10),
    warn: Color(0xffc68100),
    warnContainer: Color(0xfffff3cf),
    onWarnContainer: Color(0xff3d2800),
    crit: Color(0xffba1a1a),
    critContainer: Color(0xffffdad6),
    onCritContainer: Color(0xff7a0008),
    offline: Color(0xff616161),
    offlineContainer: Color(0xffececec),
    onOfflineContainer: Color(0xff2f2f2f),
    infoContainer: Color(0xffe2ecf5),
    onInfoContainer: Color(0xff0f2c45),
    chartLine: Color(0xff2e7d32),
    chartArea: Color(0x1a2e7d32),
    chartBand: Color(0x122e7d32),
    chartGrid: Color(0xffe4eae3),
    chartLimit: Color(0xff9aa895),
  );

  static const dark = AppColors(
    surface2: Color(0xff212621),
    surface3: Color(0xff2a302a),
    border: Color(0xff2f362f),
    muted: Color(0xff95a08f),
    textSecondary: Color(0xffc2cabd),
    ok: Color(0xff88d982),
    okContainer: Color(0xff1f3a20),
    onOkContainer: Color(0xffb8f0b2),
    warn: Color(0xffffb938),
    warnContainer: Color(0xff3a2b0a),
    onWarnContainer: Color(0xffffe3b0),
    crit: Color(0xffffb4ab),
    critContainer: Color(0xff4a1512),
    onCritContainer: Color(0xffffdad6),
    offline: Color(0xffb0b0b0),
    offlineContainer: Color(0xff2c2c2c),
    onOfflineContainer: Color(0xffe0e0e0),
    infoContainer: Color(0xff1b2c3b),
    onInfoContainer: Color(0xffcfe3f5),
    chartLine: Color(0xff48a64c),
    chartArea: Color(0x2448a64c),
    chartBand: Color(0x1748a64c),
    chartGrid: Color(0xff293029),
    chartLimit: Color(0xff6b7866),
  );

  @override
  AppColors copyWith() => this;

  @override
  AppColors lerp(ThemeExtension<AppColors>? other, double t) => t < 0.5 ? this : (other as AppColors? ?? this);
}

extension AppThemeContext on BuildContext {
  AppColors get colors => Theme.of(this).extension<AppColors>()!;
  ColorScheme get scheme => Theme.of(this).colorScheme;
  TextTheme get text => Theme.of(this).textTheme;
}

const _primary = Color(0xff2e7d32);

ThemeData buildTheme(Brightness brightness) {
  final isDark = brightness == Brightness.dark;
  final colors = isDark ? AppColors.dark : AppColors.light;
  final scheme = ColorScheme.fromSeed(seedColor: _primary, brightness: brightness).copyWith(
    primary: isDark ? const Color(0xff88d982) : _primary,
    onPrimary: isDark ? const Color(0xff00390a) : Colors.white,
    primaryContainer: isDark ? const Color(0xff1f3a20) : const Color(0xffcfe8cb),
    onPrimaryContainer: isDark ? const Color(0xffb8f0b2) : const Color(0xff002204),
    surface: isDark ? const Color(0xff191d19) : Colors.white,
    onSurface: isDark ? const Color(0xffe3e6e0) : const Color(0xff1b1c1c),
    onSurfaceVariant: colors.textSecondary,
    surfaceContainerLowest: isDark ? const Color(0xff101410) : const Color(0xfff4f7f4),
    surfaceContainerLow: isDark ? const Color(0xff161a16) : const Color(0xfff7faf7),
    surfaceContainer: colors.surface2,
    surfaceContainerHigh: colors.surface2,
    surfaceContainerHighest: colors.surface3,
    outline: isDark ? const Color(0xff46503f) : const Color(0xffb9c6b6),
    outlineVariant: colors.border,
    error: colors.crit,
    errorContainer: colors.critContainer,
    onErrorContainer: colors.onCritContainer,
  );
  final background = isDark ? const Color(0xff101410) : const Color(0xfff4f7f4);

  final base = ThemeData(useMaterial3: true, colorScheme: scheme, brightness: brightness);
  return base.copyWith(
    scaffoldBackgroundColor: background,
    extensions: [colors],
    textTheme: base.textTheme.apply(bodyColor: scheme.onSurface, displayColor: scheme.onSurface),
    appBarTheme: AppBarTheme(
      backgroundColor: background,
      surfaceTintColor: Colors.transparent,
      scrolledUnderElevation: 1,
      centerTitle: false,
      titleTextStyle: base.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600, color: scheme.onSurface),
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      margin: EdgeInsets.zero,
      color: scheme.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: BorderSide(color: colors.border)),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: scheme.surface,
      indicatorColor: scheme.primaryContainer,
      height: 72,
      labelTextStyle: WidgetStateProperty.all(const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
    ),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: scheme.surface,
      indicatorColor: scheme.primaryContainer,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(64, 48),
        textStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(64, 48),
        textStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(textStyle: const TextStyle(fontWeight: FontWeight.w600)),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: scheme.surface,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: scheme.outline)),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
    ),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: scheme.surface,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
    ),
    dividerTheme: DividerThemeData(color: colors.border, space: 1),
  );
}
