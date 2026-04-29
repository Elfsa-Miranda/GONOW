import 'package:flutter/material.dart';

/// GoNow application color tokens.
abstract final class AppColors {
  static const Color primary = Color(0xFF5B5FEF);
  static const Color primaryVariant = Color(0xFF7C4DFF);
  static const Color secondary = Color(0xFF35C2FF);
  static const Color background = Color(0xFFF7F8FC);
  static const Color surface = Colors.white;
  static const Color onPrimary = Colors.white;
  static const Color onSurface = Color(0xFF1A1B25);
  static const Color textSecondary = Color(0xFF6B7280);
  static const Color border = Color(0xFFE6E8F0);
  static const Color shadow = Color(0x1F3C4C9A);

  static const List<Color> primaryGradient = <Color>[
    Color(0xFF6A5CFF),
    Color(0xFF4C8DFF),
  ];

  static const List<Color> fabGradient = <Color>[
    Color(0xFF7C4DFF),
    Color(0xFF3D9BFF),
  ];
}
