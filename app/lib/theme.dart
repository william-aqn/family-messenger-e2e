// Visual foundation of the client: the Crimson Lab theme (the product theme)
// and the two SpecMash variants that stay in the guideline.
//
// Design system rules encoded here:
//   * one radius, 4px, for everything; a 16px pill only for small tags;
//   * no shadows anywhere — what used to carry a shadow gets a 1px ring
//     (`FmColors.ring`, an rgba(228,196,159,.25) / .3 border);
//   * motion is a colour change only, so no splashes and no ripples;
//   * Futura PT for the interface, Roboto for form labels and safety numbers.
//
// Colours that are not a Material role (presence dots, the chrome the chat
// list and call screens sit on, the ring) live in the [FmColors] theme
// extension; screens read them from the theme rather than hard-coding hex.
import 'package:flutter/material.dart';

// ───── Crimson Lab palette ─────────────────────────────────────────────────

/// Chrome: conversation list, window title bar, call screens.
const Color cBg0 = Color(0xFF0D0D0D);

/// Conversation canvas, sign-in background, text on the accent.
const Color cBg1 = Color(0xFF151515);

/// Chrome 2: app bar, toast, card surface, other people's bubbles.
const Color cBg2 = Color(0xFF1F1E1C);

/// Chrome 3: selected list row, table head, hover.
const Color cBg3 = Color(0xFF27231E);

/// The single accent.
const Color sand = Color(0xFFE4C49F);

/// Accent on hover / pressed.
const Color sandHover = Color(0xFFD2B18C);

/// Secondary text, labels, timestamps, previews.
const Color sandDim = Color(0xFF917E68);

/// Faint text and unavailable icons.
const Color sandFaint = Color(0xFF685B4C);

/// Body text.
const Color ink = Color(0xFFEAEAEA);

/// Presence: online, "verified".
const Color cOk = Color(0xFF6FCF6F);

/// Presence: connecting.
const Color cBusy = Color(0xFFD6A84A);

/// Warning: "not in the signed roster", "unverified members".
const Color cWarn = Color(0xFFE0A458);

/// Presence: no connection.
const Color cOffline = Color(0xFFE0795F);

/// Danger: errors, delete, hang up, "keys changed".
const Color cError = Color(0xFFE74C3C);

/// Own bubble: sandA(.15) flattened onto [cBg1].
const Color cBubbleOwn = Color(0xFF342F2A);

/// Alarm banner background: the danger colour at 15% on [cBg1].
const Color cErrorSoft = Color(0xFF32201E);

/// Row divider: sandA(.15) flattened onto [cBg1].
const Color cDivider = Color(0xFF2E2A26);

/// A halftone of the accent. The design system uses .15 / .2 / .25 / .3 / .4.
Color sandA(double a) => sand.withValues(alpha: a);

// ───── SpecMash variants (guideline only, never selected from the UI) ──────

const Color slate900 = Color(0xFF242A35);
const Color slate700 = Color(0xFF313640);
const Color slate600 = Color(0xFF3E4249);
const Color slate500 = Color(0xFF7E8489);
const Color slate400 = Color(0xFF969696);
const Color slate300 = Color(0xFFC4C4C4);
const Color slate200 = Color(0xFFE8E8E8);
const Color slate100 = Color(0xFFF4F4F4);
const Color slate50 = Color(0xFFF8F8F8);
const Color orange500 = Color(0xFFF46C32);
const Color orange600 = Color(0xFFEE5E20);
const Color orange700 = Color(0xFFE45112);
const Color orange400 = Color(0xFFFDBCA1);
const Color orange200 = Color(0xFFFFE0D3);
const Color red500 = Color(0xFFFF2B2B);
const Color red100 = Color(0xFFFFDFDF);
const Color green600 = Color(0xFF219653);
const Color yolk = Color(0xFFFFC978);
const Color sky = Color(0xFFA8D2E4);

// ───── Geometry ────────────────────────────────────────────────────────────

/// The only radius in the product.
const double fmRadius = 4;

/// Pill radius, small tags only ("verified", "bot", the unread badge).
const double fmPillRadius = 16;

/// Shape shared by every component: buttons, fields, cards, sheets, the FAB.
final RoundedRectangleBorder fmShape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(fmRadius));

const String _futura = 'FuturaPT';
const String _roboto = 'Roboto';

/// Futura PT falls back to FuturaFuturisC for glyphs it does not carry.
const List<String> _futuraFallback = <String>['FuturaFuturisC'];

// ───── Theme extension ─────────────────────────────────────────────────────

/// Colours the redesign needs that Material has no role for.
///
/// Read them as `FmColors.of(context).ok` (or `context.fm.ok`) instead of
/// writing hex into a screen.
@immutable
class FmColors extends ThemeExtension<FmColors> {
  const FmColors({
    required this.ok,
    required this.busy,
    required this.warn,
    required this.offline,
    required this.tagBot,
    required this.chrome,
    required this.ring,
  });

  /// Online, "verified".
  final Color ok;

  /// Connecting, waiting.
  final Color busy;

  /// "Not in the signed roster", "unverified members".
  final Color warn;

  /// No connection (presence dot).
  final Color offline;

  /// Background of the "bot" tag.
  final Color tagBot;

  /// The darkest surface: conversation list, window title bar, call screens.
  final Color chrome;

  /// The 1px ring that replaces every shadow in the design system.
  ///
  /// Use it as `Border.all(color: FmColors.of(context).ring)` or as the
  /// `side:` of a [RoundedRectangleBorder].
  final Color ring;

  /// The heavier ring for popovers, modals, the call card and toasts (.3
  /// instead of .25), derived so callers need not know the base colour.
  Color get ringStrong => ring.withValues(alpha: (ring.a * 1.2).clamp(0.0, 1.0));

  static FmColors of(BuildContext context) => Theme.of(context).extension<FmColors>() ?? _fallback;

  static const FmColors _fallback = FmColors(
    ok: cOk,
    busy: cBusy,
    warn: cWarn,
    offline: cOffline,
    tagBot: Color(0x33E4C49F),
    chrome: cBg0,
    ring: Color(0x40E4C49F),
  );

  @override
  FmColors copyWith({
    Color? ok,
    Color? busy,
    Color? warn,
    Color? offline,
    Color? tagBot,
    Color? chrome,
    Color? ring,
  }) {
    return FmColors(
      ok: ok ?? this.ok,
      busy: busy ?? this.busy,
      warn: warn ?? this.warn,
      offline: offline ?? this.offline,
      tagBot: tagBot ?? this.tagBot,
      chrome: chrome ?? this.chrome,
      ring: ring ?? this.ring,
    );
  }

  @override
  FmColors lerp(covariant ThemeExtension<FmColors>? other, double t) {
    if (other is! FmColors) return this;
    return FmColors(
      ok: Color.lerp(ok, other.ok, t)!,
      busy: Color.lerp(busy, other.busy, t)!,
      warn: Color.lerp(warn, other.warn, t)!,
      offline: Color.lerp(offline, other.offline, t)!,
      tagBot: Color.lerp(tagBot, other.tagBot, t)!,
      chrome: Color.lerp(chrome, other.chrome, t)!,
      ring: Color.lerp(ring, other.ring, t)!,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is FmColors &&
        other.ok == ok &&
        other.busy == busy &&
        other.warn == warn &&
        other.offline == offline &&
        other.tagBot == tagBot &&
        other.chrome == chrome &&
        other.ring == ring;
  }

  @override
  int get hashCode => Object.hash(ok, busy, warn, offline, tagBot, chrome, ring);
}

/// Sugar so screens can write `context.fm.chrome`.
extension FmThemeContext on BuildContext {
  FmColors get fm => FmColors.of(this);
}

// ───── Themes ──────────────────────────────────────────────────────────────

/// The product theme. Crimson Lab: canvas #151515, one accent #E4C49F.
ThemeData fmCrimson() {
  const ColorScheme scheme = ColorScheme(
    brightness: Brightness.dark,
    primary: sand, // buttons, FAB, unread badge
    onPrimary: cBg1,
    primaryContainer: cBubbleOwn, // own bubble, soft accent
    onPrimaryContainer: ink,
    secondary: sand,
    onSecondary: cBg1,
    tertiary: sand, // sender name, focused field, active tab
    onTertiary: cBg1,
    error: cError,
    onError: Colors.white,
    errorContainer: cErrorSoft, // alarm banner background
    onErrorContainer: ink,
    surface: cBg1, // conversation canvas
    onSurface: ink,
    surfaceContainerHighest: cBg2, // cards, other bubbles, app bar, toast
    surfaceContainerHigh: cBg3, // selected row, table head, neutral banner
    onSurfaceVariant: sandDim, // secondary text
    outline: sandFaint, // field and secondary-button borders
    outlineVariant: cDivider, // row dividers
    inverseSurface: cBg2,
    onInverseSurface: sand, // toast text
    shadow: Colors.transparent,
    surfaceTint: Colors.transparent,
  );
  return _build(
    scheme,
    appBar: cBg2,
    chrome: cBg0,
    fieldFill: cBg2,
    ring: sandA(.25),
    focus: sand,
    selectedTile: cBg3,
    icon: sand,
    ok: cOk,
    busy: cBusy,
    warn: cWarn,
    offline: cOffline,
    tagBot: sandA(.2),
  );
}

/// The SpecMash variants. Guideline only: nothing in the UI selects them.
ThemeData fmTheme(Brightness b) {
  final bool dark = b == Brightness.dark;
  final ColorScheme scheme = ColorScheme(
    brightness: b,
    primary: orange500,
    onPrimary: Colors.white,
    primaryContainer: dark ? orange500 : orange200,
    onPrimaryContainer: dark ? slate900 : Colors.black,
    secondary: orange600,
    onSecondary: Colors.white,
    tertiary: dark ? orange400 : orange600,
    onTertiary: Colors.white,
    error: red500,
    onError: Colors.white,
    errorContainer: dark ? slate600 : red100,
    onErrorContainer: dark ? Colors.white : slate700,
    surface: dark ? slate700 : slate50,
    onSurface: dark ? Colors.white : Colors.black,
    surfaceContainerHighest: dark ? slate600 : Colors.white,
    surfaceContainerHigh: dark ? slate600 : slate200,
    onSurfaceVariant: dark ? slate400 : slate500,
    outline: dark ? slate600 : slate300,
    outlineVariant: dark ? slate900 : slate100,
    inverseSurface: slate700,
    onInverseSurface: Colors.white,
    shadow: Colors.black,
    surfaceTint: Colors.transparent,
  );
  return _build(
    scheme,
    appBar: slate700,
    chrome: slate900,
    fieldFill: dark ? slate900 : Colors.white,
    ring: dark ? slate900 : slate100,
    focus: dark ? orange500 : orange600,
    selectedTile: dark ? slate900 : slate100,
    icon: dark ? Colors.white : slate700,
    ok: green600,
    busy: yolk,
    warn: yolk,
    offline: red500,
    tagBot: sky,
  );
}

/// One body for all three themes: everything is taken from [scheme] and the
/// parameters, never from a palette constant.
///
/// [appBar] is chrome 2, [chrome] the darkest surface (list, title bar,
/// calls), [fieldFill] the filled input background and [ring] the 1px border
/// that stands in for the design system's shadows.
ThemeData _build(
  ColorScheme scheme, {
  required Color appBar,
  required Color chrome,
  required Color fieldFill,
  required Color ring,
  required Color focus,
  required Color selectedTile,
  required Color icon,
  required Color ok,
  required Color busy,
  required Color warn,
  required Color offline,
  required Color tagBot,
}) {
  final TextTheme text = ThemeData(brightness: scheme.brightness)
      .textTheme
      .apply(fontFamily: _futura, fontFamilyFallback: _futuraFallback, bodyColor: scheme.onSurface, displayColor: scheme.onSurface)
      .copyWith(
        // Card / dialog title.
        headlineSmall: TextStyle(
          fontFamily: _futura,
          fontFamilyFallback: _futuraFallback,
          fontWeight: FontWeight.w500,
          fontSize: 24,
          height: 1.2,
          color: scheme.onSurface,
        ),
        // Chat title, app bar, call card. 18 because the app is phone-first.
        titleLarge: TextStyle(
          fontFamily: _futura,
          fontFamilyFallback: _futuraFallback,
          fontWeight: FontWeight.w500,
          fontSize: 18,
          height: 1.2,
          color: scheme.onSurface,
        ),
        // List row title, member name, tab.
        titleMedium: TextStyle(
          fontFamily: _futura,
          fontFamilyFallback: _futuraFallback,
          fontWeight: FontWeight.w500,
          fontSize: 16,
          color: scheme.onSurface,
        ),
        // Message text.
        bodyLarge: TextStyle(
          fontFamily: _futura,
          fontFamilyFallback: _futuraFallback,
          fontSize: 16,
          height: 1.4,
          color: scheme.onSurface,
        ),
        // Preview, subtitle, panel hint, banner.
        bodyMedium: TextStyle(
          fontFamily: _futura,
          fontFamilyFallback: _futuraFallback,
          fontSize: 14,
          color: scheme.onSurfaceVariant,
        ),
        // Safety numbers: Roboto, grouped by four.
        bodySmall: TextStyle(
          fontFamily: _roboto,
          fontSize: 13,
          letterSpacing: 0.5,
          color: scheme.onSurface,
        ),
        // Buttons, sender name in a bubble.
        labelLarge: TextStyle(
          fontFamily: _futura,
          fontFamilyFallback: _futuraFallback,
          fontWeight: FontWeight.w500,
          fontSize: 16,
          color: scheme.onSurface,
        ),
        // Meta: time, "edited", system rows.
        labelSmall: TextStyle(
          fontFamily: _futura,
          fontFamilyFallback: _futuraFallback,
          fontSize: 12,
          color: scheme.onSurfaceVariant,
        ),
      );

  final RoundedRectangleBorder ringShape = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(fmRadius),
    side: BorderSide(color: ring),
  );

  OutlineInputBorder fieldBorder(Color color) => OutlineInputBorder(
        borderRadius: BorderRadius.circular(fmRadius),
        borderSide: BorderSide(color: color, width: 2),
      );

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    textTheme: text,
    fontFamily: _futura,
    fontFamilyFallback: _futuraFallback,
    scaffoldBackgroundColor: scheme.surface,
    canvasColor: scheme.surface,
    dividerColor: scheme.outlineVariant,
    applyElevationOverlayColor: false,
    // Motion is a colour change only: no ripples, no highlight wash.
    splashFactory: NoSplash.splashFactory,
    splashColor: Colors.transparent,
    highlightColor: Colors.transparent,
    iconTheme: IconThemeData(color: icon, size: 20),
    appBarTheme: AppBarTheme(
      backgroundColor: appBar,
      foregroundColor: scheme.onSurface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      toolbarHeight: 56,
      iconTheme: IconThemeData(color: icon, size: 20),
      actionsIconTheme: IconThemeData(color: icon, size: 20),
      titleTextStyle: text.titleLarge,
    ),
    cardTheme: CardThemeData(
      shape: ringShape,
      elevation: 0,
      color: scheme.surfaceContainerHighest,
      surfaceTintColor: Colors.transparent,
      margin: EdgeInsets.zero,
    ),
    dialogTheme: DialogThemeData(
      shape: ringShape,
      backgroundColor: scheme.surfaceContainerHighest,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      barrierColor: Colors.black.withValues(alpha: .5),
      titleTextStyle: text.titleLarge,
      contentTextStyle: text.bodyLarge,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: scheme.surfaceContainerHighest,
      modalBackgroundColor: scheme.surfaceContainerHighest,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      modalElevation: 0,
      modalBarrierColor: Colors.black.withValues(alpha: .5),
      dragHandleColor: scheme.outline,
      dragHandleSize: const Size(32, 4),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(fmRadius)),
      ),
    ),
    inputDecorationTheme: InputDecorationThemeData(
      filled: true,
      fillColor: fieldFill,
      labelStyle: TextStyle(fontFamily: _roboto, fontSize: 14, color: scheme.onSurfaceVariant),
      floatingLabelStyle: TextStyle(fontFamily: _roboto, fontSize: 14, color: focus),
      // The design draws a caption above a field, never inside its border: no
      // artboard shows a filled field carrying a label. Material's floating
      // label would also overflow the field at this size and be clipped by the
      // scroll view of a dialog, so the label stays a placeholder and vanishes
      // as soon as there is something to read.
      floatingLabelBehavior: FloatingLabelBehavior.never,
      // 16 in the field itself: this build is phone-first.
      hintStyle: TextStyle(fontFamily: _roboto, fontSize: 16, color: scheme.onSurfaceVariant),
      helperStyle: TextStyle(fontFamily: _roboto, fontSize: 12, color: scheme.onSurfaceVariant),
      errorStyle: TextStyle(fontFamily: _roboto, fontSize: 12, color: scheme.error),
      prefixStyle: TextStyle(fontFamily: _roboto, fontSize: 16, color: scheme.onSurfaceVariant),
      suffixStyle: TextStyle(fontFamily: _roboto, fontSize: 16, color: scheme.onSurfaceVariant),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
      border: fieldBorder(scheme.outline),
      enabledBorder: fieldBorder(scheme.outline),
      focusedBorder: fieldBorder(focus),
      errorBorder: fieldBorder(scheme.error),
      focusedErrorBorder: fieldBorder(scheme.error),
      disabledBorder: fieldBorder(scheme.outline.withValues(alpha: .4)),
    ),
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: scheme.primary,
      selectionColor: scheme.primary.withValues(alpha: .3),
      selectionHandleColor: scheme.primary,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: scheme.primary,
        foregroundColor: scheme.onPrimary,
        disabledBackgroundColor: scheme.primary.withValues(alpha: .4),
        disabledForegroundColor: scheme.onPrimary.withValues(alpha: .6),
        shape: fmShape,
        elevation: 0,
        minimumSize: const Size(44, 48),
        padding: const EdgeInsets.symmetric(horizontal: 24),
        textStyle: text.labelLarge,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: scheme.onSurface,
        side: BorderSide(color: scheme.outline, width: 2),
        shape: fmShape,
        elevation: 0,
        minimumSize: const Size(44, 48),
        padding: const EdgeInsets.symmetric(horizontal: 24),
        textStyle: text.labelLarge,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: scheme.onSurface,
        shape: fmShape,
        minimumSize: const Size(44, 44),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        textStyle: text.labelLarge,
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        foregroundColor: icon,
        shape: fmShape,
        minimumSize: const Size(44, 44),
        highlightColor: Colors.transparent,
      ),
    ),
    // 56 square with a 4px radius, sand on the canvas colour.
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: scheme.primary,
      foregroundColor: scheme.onPrimary,
      splashColor: Colors.transparent,
      focusColor: scheme.primary,
      hoverColor: scheme.primary,
      elevation: 0,
      focusElevation: 0,
      hoverElevation: 0,
      highlightElevation: 0,
      disabledElevation: 0,
      iconSize: 24,
      sizeConstraints: const BoxConstraints.tightFor(width: 56, height: 56),
      shape: fmShape,
    ),
    listTileTheme: ListTileThemeData(
      shape: fmShape,
      minVerticalPadding: 12,
      tileColor: Colors.transparent,
      selectedTileColor: selectedTile,
      selectedColor: scheme.onSurface,
      iconColor: scheme.onSurfaceVariant,
      textColor: scheme.onSurface,
      titleTextStyle: text.titleMedium,
      subtitleTextStyle: text.bodyMedium,
      leadingAndTrailingTextStyle: text.labelSmall,
    ),
    dividerTheme: DividerThemeData(color: scheme.outlineVariant, thickness: 1, space: 1),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: scheme.inverseSurface,
      contentTextStyle: TextStyle(
        fontFamily: _futura,
        fontFamilyFallback: _futuraFallback,
        fontSize: 14,
        color: scheme.onInverseSurface,
      ),
      actionTextColor: scheme.onInverseSurface,
      elevation: 0,
      shape: ringShape,
      behavior: SnackBarBehavior.floating,
    ),
    chipTheme: ChipThemeData(
      shape: fmShape,
      side: BorderSide(color: scheme.outline, width: 2),
      backgroundColor: Colors.transparent,
      selectedColor: scheme.primaryContainer,
      elevation: 0,
      pressElevation: 0,
      showCheckmark: false,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      labelStyle: TextStyle(
        fontFamily: _futura,
        fontFamilyFallback: _futuraFallback,
        fontWeight: FontWeight.w500,
        fontSize: 14,
        color: scheme.onSurface,
      ),
    ),
    checkboxTheme: CheckboxThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(2)),
      side: BorderSide(color: scheme.outline, width: 2),
      fillColor: WidgetStateProperty.all(Colors.transparent),
      checkColor: WidgetStateProperty.all(scheme.primary),
      splashRadius: 0,
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? scheme.onPrimary : scheme.onSurfaceVariant),
      trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? scheme.primary : Colors.transparent),
      trackOutlineColor: WidgetStateProperty.all(scheme.outline),
    ),
    radioTheme: RadioThemeData(fillColor: WidgetStateProperty.all(scheme.primary)),
    tabBarTheme: TabBarThemeData(
      labelColor: scheme.primary,
      unselectedLabelColor: scheme.onSurfaceVariant,
      labelStyle: text.titleMedium,
      unselectedLabelStyle: text.titleMedium,
      indicatorColor: scheme.primary,
      indicatorSize: TabBarIndicatorSize.tab,
      dividerColor: scheme.outlineVariant,
      dividerHeight: 1,
      splashFactory: NoSplash.splashFactory,
      overlayColor: WidgetStateProperty.all(Colors.transparent),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: scheme.primary,
      linearMinHeight: 4,
      linearTrackColor: Colors.transparent,
      circularTrackColor: Colors.transparent,
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: scheme.surfaceContainerHighest,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: ringShape,
      textStyle: text.bodyLarge,
    ),
    menuTheme: MenuThemeData(
      style: MenuStyle(
        backgroundColor: WidgetStateProperty.all(scheme.surfaceContainerHighest),
        surfaceTintColor: WidgetStateProperty.all(Colors.transparent),
        elevation: WidgetStateProperty.all(0),
        shape: WidgetStateProperty.all(ringShape),
      ),
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: scheme.inverseSurface,
        borderRadius: BorderRadius.circular(fmRadius),
        border: Border.all(color: ring),
      ),
      textStyle: TextStyle(
        fontFamily: _futura,
        fontFamilyFallback: _futuraFallback,
        fontSize: 12,
        color: scheme.onInverseSurface,
      ),
    ),
    extensions: <ThemeExtension<dynamic>>[
      FmColors(ok: ok, busy: busy, warn: warn, offline: offline, tagBot: tagBot, chrome: chrome, ring: ring),
    ],
  );
}
