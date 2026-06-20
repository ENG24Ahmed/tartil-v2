import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// لون ورق المصحف المحفوظ في التفضيلات — يجب أن يطابق منطق
/// [QuranPageViewerState] (`mushaf_background`: 0 أبيض، 1 بيج، 3 أسود).
///
/// عند غياب المفتاح: نفس الافتراضي في القارئ العادي (`_mushafBackgroundColor = بيج`).
abstract final class KhatmMushafPaper {
  static const String prefsKey = 'mushaf_background';

  static const Color white = Colors.white;
  static const Color beige = Color.fromARGB(255, 255, 248, 235);
  static const Color black = Color(0xFF0B0B0B);

  static bool isBlack(Color c) => c == black;

  /// يطابق `_loadDisplayPrefs` في [QuranPageViewerState] لقيمة `mushaf_background`.
  static Color colorForStoredInt(int? v) {
    if (v == null) return beige;
    if (v == 1 || v == 2) return beige;
    if (v == 3) return black;
    return white;
  }

  static Future<Color> loadBackgroundColor() async {
    final prefs = await SharedPreferences.getInstance();
    return colorForStoredInt(prefs.getInt(prefsKey));
  }
}
