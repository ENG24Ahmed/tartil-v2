import 'package:quran_app/quran/models/mushaf_line.dart';

/// كاش ذاكرة لصفحات المصحف: يُبقى فقط **صفحتان قبل وبعد** الصفحة المركزية (معها = 5 صفحات).
/// المفتاح: 'qpc1' | 'qpc4' + '_' + رقم الصفحة.
class PageCache {
  PageCache._();
  static final PageCache instance = PageCache._();

  /// عدد الصفحات المحفوظة قبل الصفحة الحالية (مع الحالية = 5 صفحات كحد أقصى في النافذة).
  static const int cacheWindowBefore = 2;

  /// عدد الصفحات المحفوظة بعد الصفحة الحالية.
  static const int cacheWindowAfter = 2;

  final Map<String, List<MushafPageLine>> _cache = {};

  /// عند اكتمال تعبئة الرام للمصحف كاملاً (توسيع بعد ثبات): لا يُقلّص الكاش بالنافذة ٢+٢.
  bool _skipTrimWhileFullMushafInRam = false;

  bool get skipTrimWhileFullMushafInRam => _skipTrimWhileFullMushafInRam;

  void setSkipTrimWhileFullMushafInRam(bool value) {
    _skipTrimWhileFullMushafInRam = value;
  }

  static String _key(String mode, int page) => '${mode}_$page';

  static int? _pageFromKey(String key) {
    final tail = key.split('_').last;
    return int.tryParse(tail);
  }

  List<MushafPageLine>? get(String mode, int page) {
    return _cache[_key(mode, page)];
  }

  void put(String mode, int page, List<MushafPageLine> lines) {
    _cache[_key(mode, page)] = lines;
  }

  /// إزالة صفوف [qpc1] و [qpc4] خارج النافذة حول [centerPage] لتقليل استهلاك الرام.
  void trimRamToNearbyPages(
    int centerPage, {
    int before = cacheWindowBefore,
    int after = cacheWindowAfter,
    int totalPages = 604,
  }) {
    if (_skipTrimWhileFullMushafInRam) return;
    final low = (centerPage - before).clamp(1, totalPages);
    final high = (centerPage + after).clamp(1, totalPages);
    for (final mode in const ['qpc1', 'qpc4']) {
      final prefix = '${mode}_';
      final toRemove = <String>[];
      for (final k in _cache.keys) {
        if (!k.startsWith(prefix)) continue;
        final pg = _pageFromKey(k);
        if (pg == null || pg < low || pg > high) {
          toRemove.add(k);
        }
      }
      for (final k in toRemove) {
        _cache.remove(k);
      }
    }
  }

  bool has(String mode, int page) {
    return _cache.containsKey(_key(mode, page));
  }

  void clear() {
    _cache.clear();
    _skipTrimWhileFullMushafInRam = false;
  }

  /// يمسح الصفحات المخزنة لوضع معيّن (مثلاً 'qpc1' لتحميل الصفحات من جديد مع ayahSegments).
  void clearMode(String mode) {
    final keys = _cache.keys.where((k) => k.startsWith('${mode}_')).toList();
    for (final k in keys) {
      _cache.remove(k);
    }
    _skipTrimWhileFullMushafInRam = false;
  }

  /// عدد الصفحات المحملة لوضع معيّن (qpc1 أو qpc4).
  int getPageCountForMode(String mode) {
    return _cache.keys
        .where((k) => k.startsWith('${mode}_'))
        .map(_pageFromKey)
        .whereType<int>()
        .toSet()
        .length;
  }

  /// إجمالي عدد الصفحات المحملة في الذاكرة.
  int get totalCachedPageCount => _cache.length;

  /// تقدير تقريبي لحجم البيانات المحملة (بالبايت).
  int get estimatedSizeBytes {
    int total = 0;
    for (final lines in _cache.values) {
      for (final line in lines) {
        total += line.lineText.length * 4;
        if (line.ayahSegments != null) {
          for (final s in line.ayahSegments!) {
            total += s.text.length * 4;
          }
        }
      }
    }
    return total;
  }
}
