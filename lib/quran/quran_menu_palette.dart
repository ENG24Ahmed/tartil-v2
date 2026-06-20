import 'package:flutter/material.dart';

/// ألوان القوائم والنوافذ المنبثقة (فاتح / داكن) — نفس [QuranPageViewer].
class QuranMenuPaletteData {
  const QuranMenuPaletteData({
    required this.isDark,
    required this.surface,
    required this.surfaceAlt,
    required this.title,
    required this.subtitle,
    required this.accent,
    required this.tileLeadingDecorationColor,
    required this.tileLeadingIconColor,
    required this.divider,
    required this.trailingChevron,
    required this.nestedBarIcon,
    required this.reciterSelectedBg,
    required this.reciterUnselectedBg,
    required this.reciterNameSelected,
    required this.reciterNameUnselected,
    required this.switchActive,
    required this.wheelTrack,
    required this.wheelColumnInnerFill,
    required this.wheelColumnBorder,
    required this.wheelPickerBorder,
    required this.wheelTextSelected,
    required this.wheelTextUnselected,
    required this.tafsirTabSelected,
    required this.tafsirTabUnselected,
    required this.tafsirBodyOnLight,
    required this.tafsirBodyEmptyOnLight,
    required this.searchFieldFill,
    required this.searchFieldText,
    required this.cardSurface,
    required this.azkarAccentIcon,
  });

  final bool isDark;
  final Color surface;
  final Color surfaceAlt;
  final Color title;
  final Color subtitle;
  final Color accent;
  final Color tileLeadingDecorationColor;
  final Color tileLeadingIconColor;
  final Color divider;
  final Color trailingChevron;
  final Color nestedBarIcon;
  final Color reciterSelectedBg;
  final Color reciterUnselectedBg;
  final Color reciterNameSelected;
  final Color reciterNameUnselected;
  final Color switchActive;
  final Color wheelTrack;
  final Color wheelColumnInnerFill;
  final Color wheelColumnBorder;
  final Color wheelPickerBorder;
  final Color wheelTextSelected;
  final Color wheelTextUnselected;
  final Color tafsirTabSelected;
  final Color tafsirTabUnselected;
  final Color tafsirBodyOnLight;
  final Color tafsirBodyEmptyOnLight;
  final Color searchFieldFill;
  final Color searchFieldText;
  final Color cardSurface;
  final Color azkarAccentIcon;

  static final QuranMenuPaletteData light = QuranMenuPaletteData(
    isDark: false,
    surface: const Color(0xFFE8F5E9),
    surfaceAlt: const Color(0xFFF7F7F4),
    title: const Color(0xFF1B5E20),
    subtitle: const Color(0xFF616161),
    accent: const Color(0xFF2E7D32),
    tileLeadingDecorationColor: const Color(0xFF2E7D32).withValues(alpha: 0.12),
    tileLeadingIconColor: const Color(0xFF1B5E20),
    divider: const Color(0xFFE0E0E0),
    trailingChevron: const Color(0xFF9E9E9E),
    nestedBarIcon: const Color(0xFF1B5E20),
    reciterSelectedBg: const Color(0xFFE8F5E9),
    reciterUnselectedBg: Colors.white.withValues(alpha: 0.85),
    reciterNameSelected: const Color(0xFF1B5E20),
    reciterNameUnselected: Colors.black87,
    switchActive: const Color(0xFF2E7D32),
    wheelTrack: const Color(0xFFEFF6F0),
    wheelColumnInnerFill: Colors.white,
    wheelColumnBorder: const Color(0xFFB7DDBD),
    wheelPickerBorder: const Color(0xFF1B5E20),
    wheelTextSelected: const Color(0xFF1B5E20),
    wheelTextUnselected: const Color(0xFF616161),
    tafsirTabSelected: const Color(0xFF2E7D32),
    tafsirTabUnselected: const Color(0xFF757575),
    tafsirBodyOnLight: const Color(0xFF1B5E20),
    tafsirBodyEmptyOnLight: Colors.grey,
    searchFieldFill: Colors.white,
    searchFieldText: const Color(0xFF1B5E20),
    cardSurface: Colors.white,
    azkarAccentIcon: const Color(0xFF2E7D32),
  );

  static final QuranMenuPaletteData dark = QuranMenuPaletteData(
    isDark: true,
    surface: const Color(0xFF051813),
    surfaceAlt: const Color(0xFF0A1F16),
    title: Colors.white,
    subtitle: Color.fromARGB(255, 184, 201, 192),
    accent: const Color(0xFF81C784),
    tileLeadingDecorationColor: Colors.white.withValues(alpha: 0.12),
    tileLeadingIconColor: Colors.white,
    divider: Colors.white.withValues(alpha: 0.18),
    trailingChevron: Colors.white54,
    nestedBarIcon: Colors.white,
    reciterSelectedBg: Colors.white.withValues(alpha: 0.14),
    reciterUnselectedBg: Colors.white.withValues(alpha: 0.06),
    reciterNameSelected: Colors.white,
    reciterNameUnselected: Colors.white70,
    switchActive: const Color(0xFF66BB6A),
    wheelTrack: const Color(0xFF0D2418),
    wheelColumnInnerFill: const Color(0xFF0D2418),
    wheelColumnBorder: Colors.white.withValues(alpha: 0.22),
    wheelPickerBorder: Colors.white.withValues(alpha: 0.22),
    wheelTextSelected: Colors.white,
    wheelTextUnselected: Colors.white60,
    tafsirTabSelected: const Color(0xFF81C784),
    tafsirTabUnselected: Colors.white60,
    tafsirBodyOnLight: Colors.white,
    tafsirBodyEmptyOnLight: Colors.white54,
    searchFieldFill: Colors.white.withValues(alpha: 0.08),
    searchFieldText: Colors.white,
    cardSurface: Colors.white.withValues(alpha: 0.08),
    azkarAccentIcon: const Color(0xFF81C784),
  );
}

class QuranMenuPalette extends InheritedWidget {
  const QuranMenuPalette({
    required this.data,
    required super.child,
    super.key,
  });

  final QuranMenuPaletteData data;

  static QuranMenuPaletteData of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<QuranMenuPalette>();
    return scope?.data ?? QuranMenuPaletteData.light;
  }

  @override
  bool updateShouldNotify(covariant QuranMenuPalette oldWidget) =>
      !identical(oldWidget.data, data);
}
