import 'package:quran_app/quran/font_loader.dart' show loadQcfFont;
import 'package:quran_app/quran/models/mushaf_line.dart';
import 'package:quran_app/quran/page_cache.dart';
import 'package:quran_app/quran/page_persistent_cache.dart';
import 'package:quran_app/quran/quran_db.dart';

const String _v1CacheMode = 'qpc1';

bool _hasValidSegments(List<MushafPageLine> lines) {
  return lines.isNotEmpty &&
      lines.every((l) =>
          l.lineType != 'ayah' ||
          l.rangeStart == null ||
          (l.ayahSegments != null && l.ayahSegments!.isNotEmpty));
}

/// استرجاع فوري من الكاش فقط — لتجنب ومضة التحميل عند التقليب.
List<MushafPageLine>? tryGetQpcV1FromCache(int page) {
  final cached = PageCache.instance.get(_v1CacheMode, page);
  if (cached != null && _hasValidSegments(cached)) return cached;
  return null;
}

/// تحميل صفحة QPC V1 للعرض: كاش أولاً، ثم التخزين الدائم، ثم قاعدة البيانات.
/// مهم: تحميل الخط قبل إرجاع بيانات من الكاش/التخزين لتجنب رموز غريبة عند إعادة فتح التطبيق.
Future<List<MushafPageLine>> loadQpcV1PageForDisplay(int page) async {
  await loadQcfFont(page);
  final cached = PageCache.instance.get(_v1CacheMode, page);
  if (cached != null && _hasValidSegments(cached)) return cached;
  final persisted = await PagePersistentCache.instance.get(_v1CacheMode, page);
  if (persisted != null && _hasValidSegments(persisted)) {
    PageCache.instance.put(_v1CacheMode, page, persisted);
    return persisted;
  }
  final lines = await loadQpcV1Page(page);
  PageCache.instance.put(_v1CacheMode, page, lines);
  await PagePersistentCache.instance.put(_v1CacheMode, page, lines);
  return lines;
}

/// تحميل صفحة QPC V1 للكاش والتخزين الدائم.
Future<List<MushafPageLine>> loadQpcV1Page(int page) async {
  final db = QuranDb.instance;
  await db.init();
  await loadQcfFont(page);
  final layout = await db.getLayoutForPage(page);
  final fontFamily = 'QCF_P${page.toString().padLeft(3, '0')}';
  final lines = <MushafPageLine>[];

  for (final row in layout) {
    final isCentered = row['is_centered'] as bool? ?? false;
    final rangeStart = row['range_start'] as int? ?? 0;
    final rangeEnd = row['range_end'] as int? ?? 0;
    final rowType = (row['type']?.toString().trim().toLowerCase() ?? '');

    if (rowType == 'surah_name') {
      final surahTitle = _surahNames[rangeStart] ?? '';
      if (surahTitle.isNotEmpty) {
        lines.add(MushafPageLine(
          lineText: surahTitle,
          isCentered: true,
          fontFamily: fontFamily,
          lineType: 'surah_name',
          pageNumber: page,
        ));
      }
      continue;
    }

    if (rowType == 'basmallah') {
      const basmallah = 'بِسْمِ اللَّهِ الرَّحْمَٰنِ الرَّحِيمِ';
      lines.add(MushafPageLine(
        lineText: basmallah,
        isCentered: true,
        fontFamily: 'QuranUthmani',
        lineType: 'basmallah',
        pageNumber: page,
      ));
      continue;
    }

    if (rangeStart <= 0 || rangeEnd < rangeStart) continue;

    final qpcV1List = await db.getQpcV1InRange(rangeStart, rangeEnd);
    final lineText = qpcV1List.join('');
    if (lineText.isEmpty) continue;

    final ayahSegments = [
      for (final word in qpcV1List) (text: word, isMarker: false),
    ];
    lines.add(MushafPageLine(
      lineText: lineText,
      isCentered: isCentered,
      fontFamily: fontFamily,
      lineType: 'ayah',
      rangeStart: rangeStart,
      rangeEnd: rangeEnd,
      ayahSegments: ayahSegments,
    ));
  }

  return lines;
}

const Map<int, String> _surahNames = {
  1: 'سورة الفاتحة', 2: 'سورة البقرة', 3: 'سورة آل عمران', 4: 'سورة النساء',
  5: 'سورة المائدة', 6: 'سورة الأنعام', 7: 'سورة الأعراف', 8: 'سورة الأنفال',
  9: 'سورة التوبة', 10: 'سورة يونس', 11: 'سورة هود', 12: 'سورة يوسف',
  13: 'سورة الرعد', 14: 'سورة إبراهيم', 15: 'سورة الحجر', 16: 'سورة النحل',
  17: 'سورة الإسراء', 18: 'سورة الكهف', 19: 'سورة مريم', 20: 'سورة طه',
  21: 'سورة الأنبياء', 22: 'سورة الحج', 23: 'سورة المؤمنون', 24: 'سورة النور',
  25: 'سورة الفرقان', 26: 'سورة الشعراء', 27: 'سورة النمل', 28: 'سورة القصص',
  29: 'سورة العنكبوت', 30: 'سورة الروم', 31: 'سورة لقمان', 32: 'سورة السجدة',
  33: 'سورة الأحزاب', 34: 'سورة سبأ', 35: 'سورة فاطر', 36: 'سورة يس',
  37: 'سورة الصافات', 38: 'سورة ص', 39: 'سورة الزمر', 40: 'سورة غافر',
  41: 'سورة فصلت', 42: 'سورة الشورى', 43: 'سورة الزخرف', 44: 'سورة الدخان',
  45: 'سورة الجاثية', 46: 'سورة الأحقاف', 47: 'سورة محمد', 48: 'سورة الفتح',
  49: 'سورة الحجرات', 50: 'سورة ق', 51: 'سورة الذاريات', 52: 'سورة الطور',
  53: 'سورة النجم', 54: 'سورة القمر', 55: 'سورة الرحمن', 56: 'سورة الواقعة',
  57: 'سورة الحديد', 58: 'سورة المجادلة', 59: 'سورة الحشر', 60: 'سورة الممتحنة',
  61: 'سورة الصف', 62: 'سورة الجمعة', 63: 'سورة المنافقون', 64: 'سورة التغابن',
  65: 'سورة الطلاق', 66: 'سورة التحريم', 67: 'سورة الملك', 68: 'سورة القلم',
  69: 'سورة الحاقة', 70: 'سورة المعارج', 71: 'سورة نوح', 72: 'سورة الجن',
  73: 'سورة المزمل', 74: 'سورة المدثر', 75: 'سورة القيامة', 76: 'سورة الإنسان',
  77: 'سورة المرسلات', 78: 'سورة النبأ', 79: 'سورة النازعات', 80: 'سورة عبس',
  81: 'سورة التكوير', 82: 'سورة الانفطار', 83: 'سورة المطففين', 84: 'سورة الانشقاق',
  85: 'سورة البروج', 86: 'سورة الطارق', 87: 'سورة الأعلى', 88: 'سورة الغاشية',
  89: 'سورة الفجر', 90: 'سورة البلد', 91: 'سورة الشمس', 92: 'سورة الليل',
  93: 'سورة الضحى', 94: 'سورة الشرح', 95: 'سورة التين', 96: 'سورة العلق',
  97: 'سورة القدر', 98: 'سورة البينة', 99: 'سورة الزلزلة', 100: 'سورة العاديات',
  101: 'سورة القارعة', 102: 'سورة التكاثر', 103: 'سورة العصر', 104: 'سورة الهمزة',
  105: 'سورة الفيل', 106: 'سورة قريش', 107: 'سورة الماعون', 108: 'سورة الكوثر',
  109: 'سورة الكافرون', 110: 'سورة النصر', 111: 'سورة المسد', 112: 'سورة الإخلاص',
  113: 'سورة الفلق', 114: 'سورة الناس',
};
