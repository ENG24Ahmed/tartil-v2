import 'package:flutter/foundation.dart';

/// تضليل مؤقت لآية اختيرت من نتائج البحث (كتابي أو صوتي).
/// غير محفوظ — يُمسح بعد انتهاء الرسوم المتحركة.
class TemporarySearchAyahHighlightStore extends ChangeNotifier {
  TemporarySearchAyahHighlightStore._();

  static final TemporarySearchAyahHighlightStore instance =
      TemporarySearchAyahHighlightStore._();

  int? sura;
  int? ayah;
  int? page;

  /// 0.0 = مخفي، 1.0 = ظهور كامل.
  double opacity = 0.0;

  bool matchesPage(int pageNumber) =>
      sura != null && ayah != null && page == pageNumber && opacity > 0.001;

  void setHighlight({
    required int sura,
    required int ayah,
    required int page,
    required double opacity,
  }) {
    final changed = this.sura != sura ||
        this.ayah != ayah ||
        this.page != page ||
        (this.opacity - opacity).abs() > 0.001;
    this.sura = sura;
    this.ayah = ayah;
    this.page = page;
    this.opacity = opacity.clamp(0.0, 1.0);
    if (changed) notifyListeners();
  }

  void clear() {
    if (sura == null && ayah == null && page == null && opacity == 0.0) {
      return;
    }
    sura = null;
    ayah = null;
    page = null;
    opacity = 0.0;
    notifyListeners();
  }
}
