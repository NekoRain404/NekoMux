import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Theme definitions for the app. Each theme has both dark and light variants.
/// アプリのテーマ定義。各テーマにダークとライトの両バリアントを持ちます。
class AppThemeDef {
  final String id;
  final String nameZh;
  final String nameEn;
  final Color bg;
  final Color card;
  final Color border;
  final Color accent;
  final Color accent2;
  final Color danger;
  final Color text1;
  final Color text2;
  final Color? bgLightOverride;
  final Color? cardLightOverride;
  final Color? borderLightOverride;
  final Color? text1LightOverride;
  final Color? text2LightOverride;

  const AppThemeDef({
    required this.id,
    required this.nameZh,
    required this.nameEn,
    required this.bg,
    required this.card,
    required this.border,
    required this.accent,
    required this.accent2,
    required this.danger,
    required this.text1,
    required this.text2,
    this.bgLightOverride,
    this.cardLightOverride,
    this.borderLightOverride,
    this.text1LightOverride,
    this.text2LightOverride,
  });

  /// Light-mode derived colors — bright backgrounds, dark text.
  /// ライトモード派生色 — 明るい背景、暗いテキスト。
  Color get bgLight => bgLightOverride ?? const Color(0xFFF4F6F2);
  Color get cardLight => cardLightOverride ?? const Color(0xFFFFFFFF);
  Color get borderLight => borderLightOverride ?? const Color(0xFFDDE4DA);
  Color get text1Light => text1LightOverride ?? const Color(0xFF243027);
  Color get text2Light => text2LightOverride ?? const Color(0xFF647066);

  /// Build a full [ThemeData] for either dark or light mode.
  /// ダークまたはライトモード用の完全な [ThemeData] を構築します。
  ThemeData buildTheme({bool isDark = true}) {
    final brightness = isDark ? Brightness.dark : Brightness.light;
    final bgColor = isDark ? bg : bgLight;
    final cardColor = isDark ? card : cardLight;
    final borderColor = isDark ? border : borderLight;
    final t1 = isDark ? text1 : text1Light;
    final t2 = isDark ? text2 : text2Light;
    final shadowColor = isDark
        ? Colors.black.withValues(alpha: 0.28)
        : Colors.black.withValues(alpha: 0.08);
    final primaryInk = _bestOnColor(accent);
    final secondaryInk = _bestOnColor(accent2);

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      scaffoldBackgroundColor: bgColor,
      primaryColor: accent,
      colorScheme: ColorScheme(
        brightness: brightness,
        surface: bgColor,
        surfaceContainerHighest: cardColor,
        outline: borderColor,
        primary: accent,
        secondary: accent2,
        onSurface: t1,
        error: danger,
        onPrimary: primaryInk,
        onSecondary: secondaryInk,
        onError: _bestOnColor(danger),
      ),
      splashColor: accent.withValues(alpha: 0.08),
      highlightColor: accent.withValues(alpha: 0.05),
      hoverColor: accent.withValues(alpha: 0.06),
      appBarTheme: AppBarTheme(
        backgroundColor: cardColor,
        foregroundColor: t1,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: true,
        titleTextStyle: GoogleFonts.inter(
          color: t1,
          fontSize: 17,
          fontWeight: FontWeight.w600,
        ),
      ),
      cardTheme: CardThemeData(
        color: cardColor,
        surfaceTintColor: Colors.transparent,
        elevation: isDark ? 1 : 0,
        shadowColor: shadowColor,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide(color: borderColor, width: 0.5),
        ),
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      ),
      drawerTheme: DrawerThemeData(backgroundColor: bgColor),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          elevation: 0,
          backgroundColor: accent,
          foregroundColor: primaryInk,
          surfaceTintColor: Colors.transparent,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: accent2,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: cardColor,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: borderColor),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: borderColor),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: accent2, width: 1.4),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: danger),
        ),
        labelStyle: TextStyle(color: t2),
        hintStyle: TextStyle(color: t2.withValues(alpha: 0.68)),
      ),
      textTheme:
          GoogleFonts.interTextTheme(
            isDark ? ThemeData.dark().textTheme : ThemeData.light().textTheme,
          ).copyWith(
            bodyLarge: TextStyle(color: t1),
            bodyMedium: TextStyle(color: t2),
            titleMedium: TextStyle(color: t1, fontWeight: FontWeight.w600),
          ),
      iconTheme: IconThemeData(color: t2),
      dividerColor: borderColor,
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: cardColor,
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: cardColor,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: cardColor,
        contentTextStyle: TextStyle(color: t1, fontSize: 13),
        behavior: SnackBarBehavior.floating,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide(color: borderColor, width: 0.5),
        ),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) return accent;
          return t2;
        }),
        trackColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return accent.withValues(alpha: 0.32);
          }
          return borderColor.withValues(alpha: 0.55);
        }),
      ),
      pageTransitionsTheme: PageTransitionsTheme(
        builders: {TargetPlatform.android: CupertinoPageTransitionsBuilder()},
      ),
    );
  }

  static Color _bestOnColor(Color color) {
    return color.computeLuminance() > 0.48
        ? const Color(0xFF182018)
        : const Color(0xFFF7FAF2);
  }

  /// All preset themes.
  /// 全プリセットテーマ。
  static final List<AppThemeDef> presets = [
    AppThemeDef(
      id: 'neko_dark',
      nameZh: 'Neko 暗黑',
      nameEn: 'Neko Dark',
      bg: Color(0xFF101612),
      card: Color(0xFF182019),
      border: Color(0xFF2B372D),
      accent: Color(0xFF8FBC8B),
      accent2: Color(0xFF82A6B1),
      danger: Color(0xFFD77A6F),
      text1: Color(0xFFE3E7DA),
      text2: Color(0xFF9EA894),
    ),
    AppThemeDef(
      id: 'eye_care',
      nameZh: '护眼绿',
      nameEn: 'Eye Care',
      bg: Color(0xFF12180F),
      card: Color(0xFF1B2317),
      border: Color(0xFF33402B),
      accent: Color(0xFFA9C48D),
      accent2: Color(0xFFD0B878),
      danger: Color(0xFFD98778),
      text1: Color(0xFFE7E8D2),
      text2: Color(0xFFA9B49A),
      bgLightOverride: Color(0xFFF1F0D8),
      cardLightOverride: Color(0xFFFAF8E8),
      borderLightOverride: Color(0xFFD8D2A8),
      text1LightOverride: Color(0xFF323822),
      text2LightOverride: Color(0xFF6E7257),
    ),
    AppThemeDef(
      id: 'oled',
      nameZh: 'OLED 纯黑',
      nameEn: 'OLED Black',
      bg: Color(0xFF000000),
      card: Color(0xFF0B0D0B),
      border: Color(0xFF202820),
      accent: Color(0xFF7FC98A),
      accent2: Color(0xFF8AA8B0),
      danger: Color(0xFFD76F66),
      text1: Color(0xFFE7EDE4),
      text2: Color(0xFF8E978C),
    ),
    AppThemeDef(
      id: 'ocean',
      nameZh: '深海蓝',
      nameEn: 'Ocean Blue',
      bg: Color(0xFF0E1820),
      card: Color(0xFF16242D),
      border: Color(0xFF2B3E49),
      accent: Color(0xFF8AB8C8),
      accent2: Color(0xFF9BC7AF),
      danger: Color(0xFFD87B72),
      text1: Color(0xFFE4ECEB),
      text2: Color(0xFF9BAEAF),
    ),
    AppThemeDef(
      id: 'forest',
      nameZh: '森林绿',
      nameEn: 'Forest Green',
      bg: Color(0xFF0F1A10),
      card: Color(0xFF172417),
      border: Color(0xFF2A3D2A),
      accent: Color(0xFFA8C989),
      accent2: Color(0xFF88BBA4),
      danger: Color(0xFFD78274),
      text1: Color(0xFFE6EDDF),
      text2: Color(0xFFA4B39D),
    ),
    AppThemeDef(
      id: 'mono',
      nameZh: '极简灰白',
      nameEn: 'Monochrome',
      bg: Color(0xFF171917),
      card: Color(0xFF222522),
      border: Color(0xFF3A403A),
      accent: Color(0xFFD7D9CF),
      accent2: Color(0xFFA8B0A6),
      danger: Color(0xFFD18278),
      text1: Color(0xFFEAEDE5),
      text2: Color(0xFFB2B8AE),
    ),
  ];
}
