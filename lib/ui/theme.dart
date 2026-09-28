import 'package:flutter/material.dart';

/// "Menetrend" design tokens, átvéve a management web `styles.css`
/// gyökér-token-jeiből (`kebo-drive-management-web/src/styles.css`), a
/// betűméretek egy fokkal feljebb tolva: a sofőr kesztyűben, napfényben,
/// egy kézzel használja a telefont, nem egérrel dolgozó diszpécser.
class AppColors {
  AppColors._();

  // Panel — sötét alap, a rögzített kezelőfelület (app bar, nav).
  static const panel900 = Color(0xFF0C1820);
  static const panel800 = Color(0xFF122530);
  static const panel700 = Color(0xFF1B3543);
  static const panelInk = Color(0xFFE8EDF0);
  static const panelDim = Color(0xFF8CA3B0);

  // Sheet — világos alap, a munkafelület.
  static const sheet000 = Color(0xFFFFFFFF);
  static const sheet050 = Color(0xFFF2F5F6);
  static const sheet100 = Color(0xFFE6EBEE);
  static const rule = Color(0xFFCBD5DA);
  static const ruleFirm = Color(0xFF9FB0B9);
  static const ink900 = Color(0xFF0C1820);
  static const ink600 = Color(0xFF4A5F6B);
  static const ink400 = Color(0xFF5D707B);

  // Jelzések — státusz plate-ekhez, mindig szín + tint párban.
  static const signalRed = Color(0xFFC3262B);
  static const tintRed = Color(0xFFFBECEB);
  static const signalAmber = Color(0xFFB5730A);
  static const tintAmber = Color(0xFFFBF2E2);
  static const signalGreen = Color(0xFF15704C);
  static const tintGreen = Color(0xFFE7F2ED);
  static const signalBlue = Color(0xFF14547A);
  static const tintBlue = Color(0xFFE6EEF3);

  /// A webbel azonos leképezés (`kebo-drive-management-web/src/app/core/status.ts`).
  static (Color, Color) forStatus(String status) => switch (status) {
        'PLANNED' || 'PENDING' => (signalAmber, tintAmber),
        'ACCEPTED' || 'ACTIVE' || 'COMPLETED' => (signalGreen, tintGreen),
        'IN_PROGRESS' || 'ASSIGNED' || 'DRAFT' || 'COMPLETED_PENDING_SYNC' => (signalBlue, tintBlue),
        'REJECTED' || 'WITHDRAWN' || 'CANCELLED' || 'REVOKED' || 'SUSPENDED' || 'ERROR' || 'CONFLICT' => (signalRed, tintRed),
        _ => (ink600, sheet100),
      };
}

/// A webes skála (12/13/14/16/19/23/29) egérrel dolgozó diszpécsernek szól;
/// itt egy fokkal nagyobb, hogy kartávolságból, kesztyűben is olvasható legyen.
class AppText {
  AppText._();
  static const body = 17.0;
  static const secondary = 15.0;
  static const label = 14.0;
  static const screenTitle = 24.0;
  static const plate = 28.0;
}

const _condensed = 'BarlowCondensed';
const _sans = 'Barlow';

ThemeData buildAppTheme() {
  const scheme = ColorScheme.light(
    primary: AppColors.signalBlue,
    onPrimary: Colors.white,
    secondary: AppColors.signalGreen,
    onSecondary: Colors.white,
    error: AppColors.signalRed,
    onError: Colors.white,
    surface: AppColors.sheet000,
    onSurface: AppColors.ink900,
  );

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: AppColors.sheet050,
    fontFamily: _sans,
    visualDensity: VisualDensity.standard,
    dividerColor: AppColors.rule,
    dividerTheme: const DividerThemeData(color: AppColors.rule, thickness: 1, space: 1),
    appBarTheme: const AppBarTheme(
      backgroundColor: AppColors.panel900,
      foregroundColor: AppColors.panelInk,
      elevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(
        fontFamily: _condensed,
        fontSize: AppText.screenTitle,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.5,
        color: AppColors.panelInk,
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: AppColors.panel900,
      // A kiválasztott fül egyértelmű: élénk kék jelölő, fehér félkövér felirat; a többi halvány.
      indicatorColor: AppColors.signalBlue,
      height: 68,
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      labelTextStyle: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? const TextStyle(fontFamily: _condensed, fontSize: 14, fontWeight: FontWeight.w800, color: Colors.white)
            : const TextStyle(fontFamily: _condensed, fontSize: 12, fontWeight: FontWeight.w500, color: AppColors.panelDim),
      ),
      iconTheme: WidgetStateProperty.resolveWith(
        (states) => IconThemeData(color: states.contains(WidgetState.selected) ? Colors.white : AppColors.panelDim),
      ),
    ),
    cardTheme: const CardThemeData(
      color: AppColors.sheet000,
      elevation: 0,
      margin: EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.zero,
        side: BorderSide(color: AppColors.rule),
      ),
    ),
    textTheme: const TextTheme(
      headlineMedium: TextStyle(fontFamily: _condensed, fontSize: AppText.screenTitle, fontWeight: FontWeight.w700, color: AppColors.ink900),
      titleLarge: TextStyle(fontFamily: _condensed, fontSize: 20, fontWeight: FontWeight.w700, color: AppColors.ink900),
      bodyLarge: TextStyle(fontSize: AppText.body, color: AppColors.ink900, height: 1.35),
      bodyMedium: TextStyle(fontSize: AppText.secondary, color: AppColors.ink900, height: 1.35),
      labelLarge: TextStyle(fontFamily: _condensed, fontSize: AppText.label, fontWeight: FontWeight.w600, letterSpacing: 0.4),
    ),
    listTileTheme: const ListTileThemeData(
      contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      minVerticalPadding: 12,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: AppColors.signalBlue,
        foregroundColor: Colors.white,
        // Size(width, 56), NOT Size.fromHeight(56) — that sets width to
        // double.infinity, which crashes ("BoxConstraints forces an infinite
        // width") the moment the button sits in a Row without Expanded (e.g.
        // a card's trailing action). A Column with CrossAxisAlignment.stretch
        // still gets a full-width button; this only sets the height floor.
        minimumSize: const Size(64, 56),
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(2))),
        textStyle: const TextStyle(fontFamily: _condensed, fontSize: 16, fontWeight: FontWeight.w600, letterSpacing: 0.4),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: AppColors.ink900,
        side: const BorderSide(color: AppColors.ruleFirm),
        minimumSize: const Size(64, 56),
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(2))),
        textStyle: const TextStyle(fontFamily: _condensed, fontSize: 16, fontWeight: FontWeight.w600, letterSpacing: 0.4),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: AppColors.signalBlue,
        minimumSize: const Size(56, 48),
        textStyle: const TextStyle(fontFamily: _condensed, fontSize: 15, fontWeight: FontWeight.w600),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: AppColors.sheet000,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
      labelStyle: const TextStyle(fontSize: AppText.secondary, color: AppColors.ink600),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(2), borderSide: const BorderSide(color: AppColors.ruleFirm)),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(2), borderSide: const BorderSide(color: AppColors.ruleFirm)),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(2), borderSide: const BorderSide(color: AppColors.signalBlue, width: 2)),
    ),
    dialogTheme: const DialogThemeData(
      backgroundColor: AppColors.sheet000,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(2))),
    ),
    snackBarTheme: const SnackBarThemeData(
      backgroundColor: AppColors.panel900,
      contentTextStyle: TextStyle(color: AppColors.panelInk, fontSize: AppText.secondary),
    ),
  );
}

/// Státusz plate: keret és szöveg `currentColor`, kitöltés a 10%-os tint —
/// nem pill, ahogy a webes rendszerben sem az.
class StatusPlate extends StatelessWidget {
  const StatusPlate(this.status, {super.key, this.labelOverride});
  final String status;
  final String? labelOverride;

  @override
  Widget build(BuildContext context) {
    final (color, tint) = AppColors.forStatus(status);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(color: tint, border: Border.all(color: color)),
      child: Text(
        (labelOverride ?? status).toUpperCase(),
        style: TextStyle(
          fontFamily: _condensed,
          fontSize: 13,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.6,
          color: color,
        ),
      ),
    );
  }
}
