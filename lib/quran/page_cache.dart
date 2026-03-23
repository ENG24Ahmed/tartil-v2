import 'package:quran_app/quran/models/baked_page_layout.dart';
import 'package:quran_app/quran/models/mushaf_line.dart';

/// In-memory cache for rendered Mushaf page lines.
/// Cache key: 'qpc1' | 'qpc4' + '_' + pageNumber.
/// نفس الآلية لـ qpc1 و qpc4: نافذة 5 صفحات (2 قبل الحالية، 2 بعدها).
class PageCache {
  PageCache._();
  static final PageCache instance = PageCache._();

  /// عدد الصفحات المحفوظة قبل الصفحة الحالية (مع الحالية = 5 صفحات كحد أقصى في النافذة).
  static const int cacheWindowBefore = 2;

  /// عدد الصفحات المحفوظة بعد الصفحة الحالية.
  static const int cacheWindowAfter = 2;

  final Map<String, List<MushafPageLine>> _cache = {};
  final Map<String, BakedPageLayout> _bakedCache = {};

  static String _key(String mode, int page) => '${mode}_$page';
  static String _bakedKey(String mode, int page) => '${mode}_baked_$page';

  static int? _pageFromKey(String key) {
    final tail = key.split('_').last;
    return int.tryParse(tail);
  }

  BakedPageLayout? getBaked(String mode, int page) =>
      _bakedCache[_bakedKey(mode, page)];
  void putBaked(String mode, int page, BakedPageLayout baked) {
    _bakedCache[_bakedKey(mode, page)] = baked;
  }

  bool hasBaked(String mode, int page) =>
      _bakedCache.containsKey(_bakedKey(mode, page));

  List<MushafPageLine>? get(String mode, int page) {
    return _cache[_key(mode, page)];
  }

  void put(String mode, int page, List<MushafPageLine> lines) {
    _cache[_key(mode, page)] = lines;
  }

  bool has(String mode, int page) {
    return _cache.containsKey(_key(mode, page));
  }

  void clear() {
    _cache.clear();
    _bakedCache.clear();
  }

  /// يمسح الصفحات المخزنة لوضع معيّن (مثلاً 'qpc1' لتحميل الصفحات من جديد مع ayahSegments).
  void clearMode(String mode) {
    final keys = _cache.keys.where((k) => k.startsWith('${mode}_')).toList();
    for (final k in keys) {
      _cache.remove(k);
    }
    final bakedKeys =
        _bakedCache.keys.where((k) => k.startsWith('${mode}_baked_')).toList();
    for (final k in bakedKeys) {
      _bakedCache.remove(k);
    }
  }

  /// يبقي فقط الصفحات في النافذة [centerPage-before, centerPage+after].
  /// معطّل عند استخدام التحميل التدريجي والتخزين الدائم — نحتفظ بكل الصفحات المحملة.
  void pruneToWindow(int centerPage, {int? before, int? after}) {
    // لا نمسح الصفحات — التحميل التدريجي والتخزين الدائم يحتفظ بكل ما تم تحميله
  }

  /// عدد الصفحات المحملة لوضع معيّن (qpc1 أو qpc4).
  int getPageCountForMode(String mode) {
    final rawPages = _cache.keys
        .where((k) => k.startsWith('${mode}_'))
        .map(_pageFromKey)
        .whereType<int>()
        .toSet();
    final bakedPages = _bakedCache.keys
        .where((k) => k.startsWith('${mode}_baked_'))
        .map(_pageFromKey)
        .whereType<int>()
        .toSet();
    return rawPages.union(bakedPages).length;
  }

  /// عدد الصفحات الخام فقط لوضع معيّن.
  int getRawPageCountForMode(String mode) {
    return _cache.keys
        .where((k) => k.startsWith('${mode}_'))
        .map(_pageFromKey)
        .whereType<int>()
        .toSet()
        .length;
  }

  /// عدد الصفحات المحسوبة فقط لوضع معيّن.
  int getBakedPageCountForMode(String mode) {
    return _bakedCache.keys
        .where((k) => k.startsWith('${mode}_baked_'))
        .map(_pageFromKey)
        .whereType<int>()
        .toSet()
        .length;
  }

  /// عدد الصفحات الفريدة عبر جميع الأوضاع (qpc1/qpc4/raw/baked) حسب رقم الصفحة فقط.
  int get totalUniquePageCount {
    final pages = <int>{};
    pages.addAll(_cache.keys.map(_pageFromKey).whereType<int>());
    pages.addAll(_bakedCache.keys.map(_pageFromKey).whereType<int>());
    return pages.length;
  }

  /// إجمالي عدد الصفحات المحملة في الذاكرة.
  int get totalCachedPageCount => _cache.length + _bakedCache.length;

  /// تقدير تقريبي لحجم البيانات المحملة (بالبايت).
  int get estimatedSizeBytes {
    int total = 0;
    for (final lines in _cache.values) {
      for (final line in lines) {
        total += line.lineText.length * 4; // تقريباً 4 بايت لكل حرف
        if (line.ayahSegments != null) {
          for (final s in line.ayahSegments!) {
            total += s.text.length * 4;
          }
        }
      }
    }
    for (final baked in _bakedCache.values) {
      for (final line in baked.pageLines) {
        total += line.lineText.length * 4;
      }
      total += baked.lineHeights15.length * 8; // 8 bytes per double
      if (baked.mapping != null) {
        total += baked.mapping!.length * 16; // approx per entry
      }
    }
    return total;
  }
}
