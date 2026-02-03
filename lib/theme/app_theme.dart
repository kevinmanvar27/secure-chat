import 'package:flutter/material.dart';

class AppTheme {
  // ============ CORE COLORS (Only 3 colors) ============
  static const Color white = Color(0xFFFFFFFF);
  static const Color black = Color(0xFF000000);
  static const Color orange = Color(0xFFFF6B00);
  
  // Derived colors for subtle variations
  static const Color lightGray = Color(0xFFF5F5F5);    // Very light gray for backgrounds
  static const Color darkGray = Color(0xFF1A1A1A);     // Very dark gray for dark mode
  static const Color mediumGray = Color(0xFF333333);   // Medium gray for dark surfaces

  // Legacy color mappings (for compatibility)
  static const Color lightPrimary = orange;
  static const Color lightSecondary = orange;
  static const Color lightTertiary = orange;
  static const Color lightBackground = white;
  static const Color lightSurface = white;
  static const Color lightSurfaceVariant = lightGray;
  static const Color lightOnPrimary = white;
  static const Color lightOnBackground = black;
  static const Color lightOnSurface = black;
  static const Color lightOutline = Color(0xFFE0E0E0);
  static const Color lightError = Color(0xFFFF3B30);
  
  static const Color darkPrimary = orange;
  static const Color darkSecondary = orange;
  static const Color darkTertiary = orange;
  static const Color darkBackground = black;
  static const Color darkSurface = darkGray;
  static const Color darkSurfaceVariant = mediumGray;
  static const Color darkOnPrimary = white;
  static const Color darkOnBackground = white;
  static const Color darkOnSurface = white;
  static const Color darkOutline = Color(0xFF333333);
  static const Color darkError = Color(0xFFFF453A);

  // Common colors
  static const Color success = Color(0xFF34C759);
  static const Color successDark = Color(0xFF30D158);
  static const Color error = Color(0xFFFF3B30);
  static const Color errorDark = Color(0xFFFF453A);
  static const Color warning = orange;
  static const Color info = orange;

  static ThemeData lightTheme = ThemeData(
    useMaterial3: true,
    brightness: Brightness.light,
    colorScheme: const ColorScheme.light(
      primary: orange,
      secondary: orange,
      tertiary: orange,
      surface: white,
      background: white,
      onPrimary: white,
      onSecondary: white,
      onSurface: black,
      onBackground: black,
      outline: Color(0xFFE0E0E0),
      error: Color(0xFFFF3B30),
    ),
    scaffoldBackgroundColor: white,
    appBarTheme: const AppBarTheme(
      backgroundColor: white,
      foregroundColor: black,
      elevation: 0,
      centerTitle: false,
      surfaceTintColor: Colors.transparent,
    ),
    cardTheme: CardThemeData(
      color: white,
      elevation: 2,
      shadowColor: black.withOpacity(0.1),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: orange,
        foregroundColor: white,
        elevation: 0,
        padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 14),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: orange,
        side: const BorderSide(color: orange, width: 1.5),
        padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 14),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: orange,
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: lightGray,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: orange, width: 2),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
    ),
    floatingActionButtonTheme: const FloatingActionButtonThemeData(
      backgroundColor: orange,
      foregroundColor: white,
      elevation: 4,
    ),
    chipTheme: ChipThemeData(
      backgroundColor: lightGray,
      labelStyle: const TextStyle(color: black),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: black,
      contentTextStyle: const TextStyle(color: white),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      behavior: SnackBarBehavior.floating,
    ),
    bottomNavigationBarTheme: const BottomNavigationBarThemeData(
      backgroundColor: white,
      selectedItemColor: orange,
      unselectedItemColor: Color(0xFF999999),
    ),
    tabBarTheme: const TabBarThemeData(
      labelColor: orange,
      unselectedLabelColor: Color(0xFF999999),
      indicatorColor: orange,
    ),
    dividerTheme: const DividerThemeData(
      color: Color(0xFFE0E0E0),
      thickness: 1,
    ),
    iconTheme: const IconThemeData(
      color: black,
    ),
    fontFamily: 'Roboto',
  );

  static ThemeData darkTheme = ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: const ColorScheme.dark(
      primary: orange,
      secondary: orange,
      tertiary: orange,
      surface: darkGray,
      background: black,
      onPrimary: white,
      onSecondary: white,
      onSurface: white,
      onBackground: white,
      outline: Color(0xFF333333),
      error: Color(0xFFFF453A),
    ),
    scaffoldBackgroundColor: black,
    appBarTheme: const AppBarTheme(
      backgroundColor: black,
      foregroundColor: white,
      elevation: 0,
      centerTitle: false,
      surfaceTintColor: Colors.transparent,
    ),
    cardTheme: CardThemeData(
      color: darkGray,
      elevation: 2,
      shadowColor: black.withOpacity(0.3),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: orange,
        foregroundColor: white,
        elevation: 0,
        padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 14),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: orange,
        side: const BorderSide(color: orange, width: 1.5),
        padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 14),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: orange,
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: mediumGray,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: orange, width: 2),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
    ),
    floatingActionButtonTheme: const FloatingActionButtonThemeData(
      backgroundColor: orange,
      foregroundColor: white,
      elevation: 4,
    ),
    chipTheme: ChipThemeData(
      backgroundColor: mediumGray,
      labelStyle: const TextStyle(color: white),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: white,
      contentTextStyle: const TextStyle(color: black),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      behavior: SnackBarBehavior.floating,
    ),
    bottomNavigationBarTheme: const BottomNavigationBarThemeData(
      backgroundColor: black,
      selectedItemColor: orange,
      unselectedItemColor: Color(0xFF666666),
    ),
    tabBarTheme: const TabBarThemeData(
      labelColor: orange,
      unselectedLabelColor: Color(0xFF666666),
      indicatorColor: orange,
    ),
    dividerTheme: const DividerThemeData(
      color: Color(0xFF333333),
      thickness: 1,
    ),
    iconTheme: const IconThemeData(
      color: white,
    ),
    fontFamily: 'Roboto',
  );

  // ============ DYNAMIC COLOR HELPERS ============
  
  /// Get primary color (Orange)
  static Color getPrimaryColor(BuildContext context) {
    return orange;
  }
  
  /// Get secondary color (Orange)
  static Color getSecondaryColor(BuildContext context) {
    return orange;
  }
  
  /// Get tertiary color (Orange)
  static Color getTertiaryColor(BuildContext context) {
    return orange;
  }
  
  /// Get background color based on current theme
  static Color getBackgroundColor(BuildContext context) {
    return Theme.of(context).brightness == Brightness.light ? white : black;
  }
  
  /// Get surface color based on current theme
  static Color getSurfaceColor(BuildContext context) {
    return Theme.of(context).brightness == Brightness.light ? white : darkGray;
  }
  
  /// Get surface variant color based on current theme
  static Color getSurfaceVariantColor(BuildContext context) {
    return Theme.of(context).brightness == Brightness.light ? lightGray : mediumGray;
  }
  
  /// Get on-primary color (text/icon on primary)
  static Color getOnPrimaryColor(BuildContext context) {
    return white;
  }
  
  /// Get on-surface color (text/icon on surface) based on current theme
  static Color getOnSurfaceColor(BuildContext context) {
    return Theme.of(context).brightness == Brightness.light ? black : white;
  }
  
  /// Get outline color based on current theme
  static Color getOutlineColor(BuildContext context) {
    return Theme.of(context).brightness == Brightness.light 
        ? const Color(0xFFE0E0E0) 
        : const Color(0xFF333333);
  }

  /// Get dialog background color
  static Color getDialogBackgroundColor(BuildContext context) {
    return Theme.of(context).brightness == Brightness.light ? white : darkGray;
  }
  
  /// Get overlay/scrim color for video call screens
  static Color getOverlayColor(BuildContext context) {
    return black;
  }
  
  /// Get gradient colors for primary gradient
  static List<Color> getPrimaryGradient(BuildContext context) {
    return [orange, orange.withOpacity(0.8)];
  }
  
  /// Get gradient colors for secondary gradient
  static List<Color> getSecondaryGradient(BuildContext context) {
    return [orange, orange.withOpacity(0.8)];
  }
  
  /// Get gradient for call screen background
  static List<Color> getCallBackgroundGradient(BuildContext context) {
    return [black, darkGray, black];
  }

  // ============ MESSAGE COLORS ============
  
  static Color getMyMessageColor(BuildContext context) {
    return orange;
  }

  static Color getOtherMessageColor(BuildContext context) {
    return Theme.of(context).brightness == Brightness.light ? lightGray : mediumGray;
  }

  static Color getMyMessageTextColor(BuildContext context) {
    return white;
  }

  static Color getOtherMessageTextColor(BuildContext context) {
    return Theme.of(context).brightness == Brightness.light ? black : white;
  }
  
  // ============ STATUS COLORS ============
  
  /// Get success color (green for connected status)
  static Color getSuccessColor(BuildContext context) {
    return success;
  }
  
  /// Get error color (red for errors, end call)
  static Color getErrorColor(BuildContext context) {
    return error;
  }
  
  /// Get text color on error backgrounds
  static Color getOnErrorColor(BuildContext context) {
    return white;
  }
  
  /// Get warning color
  static Color getWarningColor(BuildContext context) {
    return orange;
  }
  
  // ============ INDICATOR COLORS ============
  
  /// Get active indicator color (green dot for connected)
  static Color getActiveIndicatorColor(BuildContext context) {
    return success;
  }
  
  /// Get connecting indicator color
  static Color getConnectingIndicatorColor(BuildContext context) {
    return orange;
  }
  
  // ============ BUTTON COLORS ============
  
  /// Get control button active gradient
  static List<Color> getControlButtonActiveGradient(BuildContext context) {
    return [
      white.withOpacity(0.2),
      white.withOpacity(0.1),
    ];
  }
  
  /// Get control button inactive gradient (for muted/off state)
  static List<Color> getControlButtonInactiveGradient(BuildContext context) {
    return [
      error.withOpacity(0.8),
      error.withOpacity(0.6),
    ];
  }
  
  /// Get end call button gradient
  static List<Color> getEndCallGradient(BuildContext context) {
    return [error, errorDark];
  }
  
  /// Get next/skip button gradient
  static List<Color> getNextButtonGradient(BuildContext context) {
    return [orange, orange.withOpacity(0.8)];
  }
  
  // ============ CHAT BUTTON COLORS ============
  
  /// Get chat button gradient
  static List<Color> getChatButtonGradient(BuildContext context) {
    return [orange.withOpacity(0.9), orange.withOpacity(0.7)];
  }
  
  /// Get chat button shadow color
  static Color getChatButtonShadowColor(BuildContext context) {
    return orange.withOpacity(0.4);
  }
  
  // ============ VIDEO PREVIEW COLORS ============
  
  /// Get local video preview border gradient
  static List<Color> getLocalVideoBorderGradient(BuildContext context) {
    return [orange.withOpacity(0.5), orange.withOpacity(0.3)];
  }
  
  /// Get local video preview border color
  static Color getLocalVideoBorderColor(BuildContext context) {
    return orange.withOpacity(0.5);
  }
  
  // ============ ADDITIONAL UTILITY COLORS ============
  
  /// Get disabled/inactive color
  static Color getDisabledColor(BuildContext context) {
    return Theme.of(context).brightness == Brightness.light 
        ? const Color(0xFFCCCCCC)
        : const Color(0xFF666666);
  }
  
  /// Get snackbar background color
  static Color getSnackBarBackground(BuildContext context) {
    return Theme.of(context).brightness == Brightness.light ? black : white;
  }
  
  /// Get call screen background color
  static Color getCallScreenBackground(BuildContext context) {
    return black;
  }
}
