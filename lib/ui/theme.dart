// Design tokens and theme for MyCloset v2 (docs/design.md sections 1-4).
//
// "Fitted-minimal" direction: white/gray/black, system fonts, frameless
// cutouts, black pill buttons as the only strong ink, green reserved for
// money. Light theme only - the v1 dark theme and cream/serif identity were
// dropped with the v2 redesign.
//
// Colors are exposed two ways:
// - [AppColors] for direct token access from widgets (AppColors.of(context));
// - the Material ThemeData below, so framework widgets stay on-palette too.

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../models/enums.dart';

// ----------------------------------------------------------------- colors

/// Palette tokens (design.md section 1). Light theme only.
class AppColors {
  final Color bg;

  /// Item-detail hero card; grid tiles use [tileWhisper].
  final Color tile;

  /// Grid tiles only - barely distinguishable from [bg].
  final Color tileWhisper;
  final Color surface;
  final Color ink;
  final Color inkSecondary;
  final Color hairline;

  /// Price/value figures only (design.md section 1).
  final Color money;

  /// Destructive actions.
  final Color destructive;

  const AppColors({
    required this.bg,
    required this.tile,
    required this.tileWhisper,
    required this.surface,
    required this.ink,
    required this.inkSecondary,
    required this.hairline,
    required this.money,
    required this.destructive,
  });

  /// The v2 light palette (design.md section 1).
  static const AppColors light = AppColors(
    bg: Color(0xFFFFFFFF),
    tile: Color(0xFFF5F5F6),
    tileWhisper: Color(0xFFF9F9FA),
    surface: Color(0xFFFFFFFF),
    ink: Color(0xFF0B0B0C),
    inkSecondary: Color(0xFF8A8A8E),
    hairline: Color(0xFFECECED),
    money: Color(0xFF1E9E4B),
    destructive: Color(0xFFC4362C),
  );

  /// Palette for the current brightness (always [light] in v2).
  static AppColors of(BuildContext context) => light;

  /// Const token aliases for TextStyle construction without a context.
  static const Color inkToken = Color(0xFF0B0B0C);
  static const Color inkSecondaryToken = Color(0xFF8A8A8E);

  /// Category colors, dashboard bar chart only - never UI chrome
  /// (design.md section 1 and section 8).
  static Color category(Category category) => switch (category) {
        Category.top => const Color(0xFF64A8F0),
        Category.bottom => const Color(0xFFF06292),
        Category.shoes => const Color(0xFFF2C94C),
        Category.dress => const Color(0xFF9B7BD1),
        Category.outerwear => const Color(0xFF4DB6AC),
        Category.accessory => const Color(0xFFF2994A),
      };
}

// ---------------------------------------------------------------- spacing

/// 4pt base grid (design.md section 3).
class Spacing {
  /// Screen edge gutter.
  static const double gutter = 16;

  /// Between grid tiles - Fitted's grid is nearly seamless.
  static const double gridGap = 2;

  /// Section rhythm.
  static const double section = 28;
  static const double s = 8;
  static const double m = 16;

  const Spacing._();
}

// ----------------------------------------------------------------- motion

/// Quiet, functional motion (design.md section 7): 150-250ms, easeOutCubic,
/// no springs, no bounce.
class Motion {
  static const Duration fast = Duration(milliseconds: 150);
  static const Duration base = Duration(milliseconds: 200);
  static const Duration slow = Duration(milliseconds: 250);
  static const Curve curve = Curves.easeOutCubic;

  /// Tile highlight fade after saving a new item (userFlow.md flow 2, step 5).
  static const Duration highlightFade = Duration(seconds: 1);

  const Motion._();
}

/// Fade + 8px slide screen transition (design.md section 7).
PageRoute<T> appRoute<T>(Widget page) {
  return PageRouteBuilder<T>(
    transitionDuration: Motion.base,
    reverseTransitionDuration: Motion.fast,
    pageBuilder: (_, _, _) => page,
    transitionsBuilder: (_, animation, _, child) {
      final curved = CurvedAnimation(parent: animation, curve: Motion.curve);
      return FadeTransition(
        opacity: curved,
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0, 0.02),
            end: Offset.zero,
          ).animate(curved),
          child: child,
        ),
      );
    },
  );
}

// ------------------------------------------------------------- typography

/// System sans only (design.md section 2): one voice, weight does the
/// hierarchy. No serif, no letterspaced small caps.
class AppText {
  /// Value headline, dashboard total (40 / semibold).
  static TextStyle headline(BuildContext context, {Color? color}) =>
      TextStyle(
        fontSize: 40,
        height: 46 / 40,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.5,
        color: color ?? AppColors.of(context).ink,
      );

  /// Screen titles (22 / semibold).
  static TextStyle title(BuildContext context, {Color? color}) => TextStyle(
        fontSize: 22,
        height: 27 / 22,
        fontWeight: FontWeight.w600,
        color: color ?? AppColors.of(context).ink,
      );

  /// Section / tab labels (16 / medium).
  static TextStyle label(BuildContext context, {Color? color}) => TextStyle(
        fontSize: 16,
        height: 20 / 16,
        fontWeight: FontWeight.w500,
        color: color ?? AppColors.of(context).ink,
      );

  /// Metadata values (16 / regular ink).
  static TextStyle value(BuildContext context, {Color? color}) => TextStyle(
        fontSize: 16,
        height: 21 / 16,
        color: color ?? AppColors.of(context).ink,
      );

  /// Metadata labels (15 / regular ink-secondary).
  static TextStyle fieldLabel(BuildContext context, {Color? color}) =>
      TextStyle(
        fontSize: 15,
        height: 20 / 15,
        color: color ?? AppColors.of(context).inkSecondary,
      );

  /// Buttons / pills (15 / medium).
  static TextStyle button(BuildContext context, {Color? color}) => TextStyle(
        fontSize: 15,
        height: 20 / 15,
        fontWeight: FontWeight.w500,
        color: color ?? AppColors.of(context).ink,
      );

  /// Captions (13 / regular ink-secondary).
  static TextStyle caption(BuildContext context, {Color? color}) => TextStyle(
        fontSize: 13,
        height: 17 / 13,
        color: color ?? AppColors.of(context).inkSecondary,
      );

  const AppText._();
}

// ----------------------------------------------------------------- themes

// Plain TextStyle builders for the ThemeData below (same specs as [AppText],
// without a BuildContext dependency).
TextStyle _headline() => const TextStyle(
      fontSize: 40,
      height: 46 / 40,
      fontWeight: FontWeight.w600,
      letterSpacing: -0.5,
      color: AppColors.inkToken,
    );

TextStyle _title() => const TextStyle(
      fontSize: 22,
      height: 27 / 22,
      fontWeight: FontWeight.w600,
      color: AppColors.inkToken,
    );

TextStyle _label() => const TextStyle(
      fontSize: 16,
      height: 20 / 16,
      fontWeight: FontWeight.w500,
      color: AppColors.inkToken,
    );

TextStyle _value() => const TextStyle(
      fontSize: 16,
      height: 21 / 16,
      color: AppColors.inkToken,
    );

TextStyle _fieldLabel() => const TextStyle(
      fontSize: 15,
      height: 20 / 15,
      color: AppColors.inkSecondaryToken,
    );

TextStyle _button() => const TextStyle(
      fontSize: 15,
      height: 20 / 15,
      fontWeight: FontWeight.w500,
      color: AppColors.inkToken,
    );

TextStyle _caption() => const TextStyle(
      fontSize: 13,
      height: 17 / 13,
      color: AppColors.inkSecondaryToken,
    );

/// The v2 light theme (design.md section 1: dark mode dropped with v1).
ThemeData buildTheme() {
  const c = AppColors.light;
  final scheme = ColorScheme(
    brightness: Brightness.light,
    primary: c.ink,
    onPrimary: c.bg,
    secondary: c.ink,
    onSecondary: c.bg,
    surface: c.surface,
    onSurface: c.ink,
    surfaceContainerHighest: c.tile,
    onSurfaceVariant: c.inkSecondary,
    error: c.destructive,
    onError: c.bg,
    outline: c.hairline,
    outlineVariant: c.hairline,
  );

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: c.bg,
    splashFactory: InkSparkle.splashFactory,
    visualDensity: VisualDensity.comfortable,
    appBarTheme: AppBarTheme(
      backgroundColor: c.bg,
      foregroundColor: c.ink,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: _title(),
    ),
    iconTheme: IconThemeData(color: c.inkSecondary, size: 22),
    dividerTheme: DividerThemeData(color: c.hairline, thickness: 1, space: 1),
    textTheme: TextTheme(
      displayMedium: _headline(),
      headlineMedium: _title(),
      titleMedium: _label(),
      bodyMedium: _value(),
      bodySmall: _fieldLabel(),
      labelSmall: _caption(),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: false,
      hintStyle: _value().copyWith(color: c.hairline),
      contentPadding: EdgeInsets.zero,
      enabledBorder: InputBorder.none,
      focusedBorder: InputBorder.none,
      border: InputBorder.none,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        // Black pill: the primary action style (design.md section 1).
        backgroundColor: c.ink,
        foregroundColor: c.bg,
        disabledBackgroundColor: c.tile,
        disabledForegroundColor: c.inkSecondary,
        textStyle: _button(),
        shape: const StadiumBorder(),
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        // Outlined pill: the secondary action style.
        foregroundColor: c.ink,
        textStyle: _button(),
        side: BorderSide(color: c.hairline),
        shape: const StadiumBorder(),
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: c.ink,
        textStyle: _button(),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: c.ink,
      contentTextStyle: _button().copyWith(color: c.bg),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: c.surface,
      modalBackgroundColor: c.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      showDragHandle: false,
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: c.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      titleTextStyle: _title(),
      contentTextStyle: _value().copyWith(color: c.inkSecondary),
    ),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: c.ink,
      foregroundColor: c.bg,
      elevation: 0,
      highlightElevation: 0,
      shape: const CircleBorder(),
    ),
  );
}

// ----------------------------------------------------------------- icons

/// Icon sizes and the shared set (design.md section 4). Material Symbols
/// Outlined only - no emojis anywhere.
class AppIcons {
  // Nav set.
  static const IconData wardrobe = Symbols.checkroom;

  /// `hanger` has no Material Symbols glyph; documented fallback.
  static const IconData outfits = Symbols.dry_cleaning;
  static const IconData suggest = Symbols.auto_awesome;
  static const IconData settings = Symbols.settings;

  // Shared set.
  static const IconData add = Symbols.add;
  static const IconData camera = Symbols.camera_alt;
  static const IconData gallery = Symbols.photo_library;
  static const IconData check = Symbols.check;
  static const IconData close = Symbols.close;
  static const IconData edit = Symbols.edit;
  static const IconData delete = Symbols.delete_outline;
  static const IconData tune = Symbols.tune;
  static const IconData shuffle = Symbols.shuffle;

  /// Garment placeholder icon when a cutout cannot load.
  static const IconData hanger = Symbols.checkroom;
  static const IconData calendar = Symbols.calendar_month;
  static const IconData archive = Symbols.archive;
  static const IconData back = Symbols.arrow_back;
  static const IconData brush = Symbols.brush;
  static const IconData search = Symbols.search;
  static const IconData undo = Symbols.undo;
  static const IconData expandMore = Symbols.expand_more;
  static const IconData info = Symbols.info;
  static const IconData restore = Symbols.settings_backup_restore;

  const AppIcons._();
}
