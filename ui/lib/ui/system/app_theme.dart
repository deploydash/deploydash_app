import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// The widths at which every workspace changes shape.
///
/// One set for the whole app, so Home, project, server and settings screens
/// reflow at the same points rather than each choosing its own -- which is
/// what makes resizing the window feel like one product.
abstract final class AppWorkspaceBreakpoints {
  /// Below this, a row of actions stacks vertically instead.
  static const double stackedActions = 520;

  /// Below this, contextual navigation becomes a horizontal strip rather than
  /// a side list.
  static const double contextualNavigation = 800;

  /// Above this, a workspace can show a master list and a detail pane side by
  /// side.
  static const double twoColumn = 960;

  /// The widest a content column grows, however wide the window is. Long text
  /// stops being readable past roughly this point.
  static const double maxContentWidth = 1200;
}

/// The one spacing and radius scale for the whole app.
///
/// A theme extension rather than a set of constants so it travels with the
/// theme and can be read anywhere as `context.appThemeTokens` -- there is one
/// spacing scale and one radius scale, and reaching for a literal is how a
/// screen starts to look like it belongs to a different product.
@immutable
class AppThemeTokens extends ThemeExtension<AppThemeTokens> {
  /// Creates a token set. Use [AppThemeTokens.desktop] unless a test needs
  /// specific values.
  const AppThemeTokens({
    required this.spaceXs,
    required this.spaceSm,
    required this.spaceMd,
    required this.spaceLg,
    required this.spaceXl,
    required this.radiusSm,
    required this.radiusMd,
    required this.radiusLg,
  });

  /// The shipped desktop scale.
  const AppThemeTokens.desktop()
    : this(
        spaceXs: 8,
        spaceSm: 12,
        spaceMd: 16,
        spaceLg: 20,
        spaceXl: 24,
        radiusSm: 10,
        radiusMd: 14,
        radiusLg: 18,
      );

  /// The tightest gap: between an icon and its label, or two lines of one
  /// idea.
  final double spaceXs;

  /// Between related controls inside a card.
  final double spaceSm;

  /// A card's own padding, and the gap between cards.
  final double spaceMd;

  /// Between sections within a screen.
  final double spaceLg;

  /// Around the outside of a workspace.
  final double spaceXl;

  /// For small controls -- chips and inline badges.
  final double radiusSm;

  /// The default: buttons, inputs, and most surfaces.
  final double radiusMd;

  /// For cards and dialogs, the largest surfaces on screen.
  final double radiusLg;

  /// A copy with the given values replaced.
  @override
  AppThemeTokens copyWith({
    double? spaceXs,
    double? spaceSm,
    double? spaceMd,
    double? spaceLg,
    double? spaceXl,
    double? radiusSm,
    double? radiusMd,
    double? radiusLg,
  }) {
    return AppThemeTokens(
      spaceXs: spaceXs ?? this.spaceXs,
      spaceSm: spaceSm ?? this.spaceSm,
      spaceMd: spaceMd ?? this.spaceMd,
      spaceLg: spaceLg ?? this.spaceLg,
      spaceXl: spaceXl ?? this.spaceXl,
      radiusSm: radiusSm ?? this.radiusSm,
      radiusMd: radiusMd ?? this.radiusMd,
      radiusLg: radiusLg ?? this.radiusLg,
    );
  }

  /// Interpolates towards [other], so a theme change animates rather than
  /// jumping. Returns this unchanged when [other] is not a token set.
  @override
  AppThemeTokens lerp(ThemeExtension<AppThemeTokens>? other, double t) {
    if (other is! AppThemeTokens) {
      return this;
    }
    return AppThemeTokens(
      spaceXs: _lerpDouble(spaceXs, other.spaceXs, t),
      spaceSm: _lerpDouble(spaceSm, other.spaceSm, t),
      spaceMd: _lerpDouble(spaceMd, other.spaceMd, t),
      spaceLg: _lerpDouble(spaceLg, other.spaceLg, t),
      spaceXl: _lerpDouble(spaceXl, other.spaceXl, t),
      radiusSm: _lerpDouble(radiusSm, other.radiusSm, t),
      radiusMd: _lerpDouble(radiusMd, other.radiusMd, t),
      radiusLg: _lerpDouble(radiusLg, other.radiusLg, t),
    );
  }
}

double _lerpDouble(double a, double b, double t) => a + (b - a) * t;

/// Reads the app's tokens from a [BuildContext].
extension AppThemeContext on BuildContext {
  /// The current token set, falling back to [AppThemeTokens.desktop].
  ///
  /// The fallback matters in tests, which often pump a widget under a bare
  /// `MaterialApp` that carries no extension.
  AppThemeTokens get appThemeTokens =>
      Theme.of(this).extension<AppThemeTokens>() ??
      const AppThemeTokens.desktop();
}

/// The colour of a card or panel.
///
/// A trace of the primary colour blended into the surface, so panels read as
/// slightly lifted without a shadow -- the calm, native look the design rules
/// ask for, rather than decorative elevation.
Color appSurfaceColor(ThemeData theme) {
  final overlay = theme.colorScheme.primary.withValues(
    alpha: theme.brightness == Brightness.light ? 0.018 : 0.05,
  );
  return Color.alphaBlend(overlay, theme.colorScheme.surface);
}

/// The colour of a border or divider, softened from the scheme's outline so
/// it separates without drawing attention.
Color appBorderColor(ThemeData theme) {
  return theme.colorScheme.outlineVariant.withValues(
    alpha: theme.brightness == Brightness.light ? 0.7 : 0.5,
  );
}

/// The rail's background.
///
/// A fixed colour rather than a scheme role: the rail is a constant frame
/// around changing content, and it should not shift as themes vary.
Color appSidebarColor(ThemeData theme) {
  return theme.brightness == Brightness.light
      ? const Color(0xFFF2F3F5)
      : const Color(0xFF1E2024);
}

/// Text and icons on the rail, paired with [appSidebarColor] for contrast.
Color appSidebarForegroundColor(ThemeData theme) {
  return theme.brightness == Brightness.light
      ? const Color(0xFF202227)
      : Colors.white;
}

/// Secondary text on the rail -- section headings and inactive entries.
Color appSidebarMutedForegroundColor(ThemeData theme) {
  return theme.brightness == Brightness.light
      ? const Color(0xFF5E6470)
      : Colors.white70;
}

/// Applies Deploy Dash's visual language to [baseTheme].
///
/// One place, applied to both the light and dark base themes, so buttons,
/// inputs, cards and dialogs are shaped once rather than per screen. Every
/// radius comes from [AppThemeTokens], and the minimum button heights are set
/// here so a control cannot end up below a comfortable click target by
/// omission.
///
/// The text theme falls back to [baseTheme]'s when runtime font fetching is
/// off, which is the case in tests and offline: a font that cannot be
/// downloaded must not stop the app rendering.
/// [googleSansTextThemeBuilder] is injectable for the same reason.
ThemeData buildDeployDashTheme(
  ThemeData baseTheme, {
  TextTheme Function(TextTheme baseTheme)? googleSansTextThemeBuilder,
}) {
  const tokens = AppThemeTokens.desktop();
  final TextTheme Function(TextTheme) resolvedGoogleSansTextThemeBuilder =
      googleSansTextThemeBuilder ?? GoogleFonts.googleSansTextTheme;
  final TextTheme textTheme = GoogleFonts.config.allowRuntimeFetching
      ? resolvedGoogleSansTextThemeBuilder(baseTheme.textTheme)
      : baseTheme.textTheme;
  final borderColor = appBorderColor(baseTheme);
  final surfaceColor = appSurfaceColor(baseTheme);
  final scaffoldColor = baseTheme.brightness == Brightness.light
      ? const Color(0xFFF5F6F8)
      : const Color(0xFF17181C);

  return baseTheme.copyWith(
    textTheme: textTheme.copyWith(
      titleLarge: textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
      titleMedium: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
      titleSmall: textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
      bodySmall: textTheme.bodySmall?.copyWith(height: 1.35),
      bodyMedium: textTheme.bodyMedium?.copyWith(height: 1.4),
    ),
    scaffoldBackgroundColor: scaffoldColor,
    dividerColor: borderColor,
    cardColor: surfaceColor,
    cardTheme: CardThemeData(
      color: surfaceColor,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(tokens.radiusLg),
        side: BorderSide(color: borderColor),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: surfaceColor,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(tokens.radiusLg + 2),
        side: BorderSide(color: borderColor),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(0, 42),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(tokens.radiusMd),
        ),
        textStyle: textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w600),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, 42),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        side: BorderSide(color: borderColor),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(tokens.radiusMd),
        ),
        textStyle: textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w600),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        minimumSize: const Size(0, 38),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(tokens.radiusMd),
        ),
        textStyle: textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w600),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      isDense: true,
      filled: true,
      fillColor: Color.alphaBlend(
        baseTheme.colorScheme.onSurface.withValues(
          alpha: baseTheme.brightness == Brightness.light ? 0.015 : 0.05,
        ),
        surfaceColor,
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(tokens.radiusMd),
        borderSide: BorderSide(color: borderColor),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(tokens.radiusMd),
        borderSide: BorderSide(color: borderColor),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(tokens.radiusMd),
        borderSide: BorderSide(
          color: baseTheme.colorScheme.primary,
          width: 1.2,
        ),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(tokens.radiusMd),
        borderSide: BorderSide(color: baseTheme.colorScheme.error),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(tokens.radiusMd),
        borderSide: BorderSide(color: baseTheme.colorScheme.error, width: 1.2),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(tokens.radiusMd),
      ),
    ),
    tabBarTheme: TabBarThemeData(
      dividerColor: borderColor,
      labelStyle: textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
      unselectedLabelStyle: textTheme.bodyMedium,
    ),
    extensions: const <ThemeExtension<dynamic>>[AppThemeTokens.desktop()],
  );
}
