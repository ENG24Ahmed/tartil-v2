import 'package:shared_preferences/shared_preferences.dart';

enum KhatmRangeType {
  /// من بداية [fromSurah] إلى نهاية [toSurah] (كل سورة كاملة ضمن النطاق).
  surahSpan,
  /// سورة واحدة من [fromAyah] إلى [toAyah] ([fromSurah] == [toSurah]).
  ayahRange,
  /// من (fromSurah, fromAyah) إلى (toSurah, toAyah) بترتيب المصحف — لاستئناف ختم محفوظ.
  readingSegment,
}

class KhatmRange {
  const KhatmRange({
    required this.type,
    required this.fromSurah,
    required this.toSurah,
    required this.fromSurahName,
    required this.toSurahName,
    required this.fromAyah,
    required this.toAyah,
    required this.totalWords,
    this.surahNamesAr = const {},
  });

  final KhatmRangeType type;
  final int fromSurah;
  final int toSurah;
  final String fromSurahName;
  final String toSurahName;
  final int fromAyah;
  final int toAyah;
  final int totalWords;

  /// أسماء السور من قائمة المصحف (`sura_name_ar`) لكل رقم سورة ضمن النطاق — لعرض المقدمة بين السور.
  final Map<int, String> surahNamesAr;

  /// أدنى/أعلى رقم سورة في النطاق (للاستعلام عن قاعدة البيانات).
  int get loSurah => fromSurah <= toSurah ? fromSurah : toSurah;
  int get hiSurah => fromSurah <= toSurah ? toSurah : fromSurah;

  /// اسم السورة بالعربية لعرض «سورة {الاسم}».
  String surahNameAr(int surahNumber) {
    if (surahNumber == fromSurah) return fromSurahName;
    if (surahNumber == toSurah) return toSurahName;
    final m = surahNamesAr[surahNumber];
    if (m != null && m.isNotEmpty) return m;
    return surahNumber.toString();
  }

  String get displayLabel {
    if (type == KhatmRangeType.surahSpan) {
      if (fromSurah == toSurah) {
        return 'سورة $fromSurahName';
      }
      return 'من سورة $fromSurahName إلى سورة $toSurahName';
    }
    if (type == KhatmRangeType.readingSegment) {
      if (fromSurah == toSurah) {
        return '${surahNameAr(fromSurah)} من آية $fromAyah إلى آية $toAyah';
      }
      return 'من ${surahNameAr(fromSurah)} ($fromAyah) إلى ${surahNameAr(toSurah)} ($toAyah)';
    }
    return 'سورة $fromSurahName ($fromAyah – $toAyah)';
  }
}

/// حدود سرعة الختم المنظّم (كلمة/دقيقة) — الإعداد والجلسة.
abstract final class KhatmWpmLimits {
  static const double min = 20;
  static const double max = 250;
}

/// قطعة في سطر الختم: كلمة عثمانية أو علامة نهاية آية (رقم/رمز من قاعدة البيانات).
class KhatmLinePiece {
  const KhatmLinePiece.word(this.text)
      : isMarker = false,
        ayahNumber = 0,
        markerUthmani = '';

  const KhatmLinePiece.verseEnd({
    required this.ayahNumber,
    this.markerUthmani = '',
  })  : isMarker = true,
        text = '';

  final bool isMarker;
  final int ayahNumber;
  final String text;

  /// عمود [uthmani] لصف العلامة (مثل ٥ أو زخرفة أطول من dk_*).
  final String markerUthmani;

  /// علامة **نهاية الآية** (U+06DD) + رقم الآية بالهندية من [ayahNumber]؛
  /// أو نص القاعدة إن لم يكن أرقامًا فقط (زخرفة مدمجة مثل ۝…).
  static const String kArabicEndOfAyah = '\u{06DD}';

  static bool _isDigitLikeRune(int r) =>
      (r >= 0x30 && r <= 0x39) ||
      (r >= 0x0660 && r <= 0x0669) ||
      (r >= 0x06F0 && r <= 0x06F9);

  /// نص العلامة من القاعدة إن كان **أرقامًا فقط** (حتى رقمين مثل ١٠) — لا يُعتبر زخرفة.
  static bool _isAllDigitsLike(String s) {
    if (s.isEmpty) return false;
    for (final r in s.runes) {
      if (!_isDigitLikeRune(r)) return false;
    }
    return true;
  }

  String get verseMarkerDisplayText {
    if (!isMarker) return '';
    final g = markerUthmani.trim();
    // زخرفة من القاعدة (ليست تسلسل أرقام فقط) — كما هي.
    if (g.isNotEmpty && !_isAllDigitsLike(g)) return g;
    if (ayahNumber <= 0) return g;
    // كان: runes.length > 1 يُعيد الأرقام خامًا؛ من ١٠ فصاعدًا يختفي إطار U+06DD.
    return '$kArabicEndOfAyah${_arabicIndicAyahNumber(ayahNumber)}';
  }

  static String _arabicIndicAyahNumber(int n) {
    if (n <= 0) return '';
    const d = ['٠', '١', '٢', '٣', '٤', '٥', '٦', '٧', '٨', '٩'];
    final buf = StringBuffer();
    for (final ch in n.toString().split('')) {
      final v = int.tryParse(ch);
      if (v != null) buf.write(d[v]);
    }
    return buf.toString();
  }

  @override
  bool operator ==(Object other) =>
      other is KhatmLinePiece &&
      isMarker == other.isMarker &&
      ayahNumber == other.ayahNumber &&
      text == other.text &&
      markerUthmani == other.markerUthmani;

  @override
  int get hashCode => Object.hash(isMarker, ayahNumber, text, markerUthmani);
}

/// حساب المدة والسرعة بناءً على عدد الكلمات
class KhatmCalc {
  const KhatmCalc._();

  /// دقائق → كلمة/دقيقة
  static double minutesToWpm(double minutes, int totalWords) {
    if (minutes <= 0 || totalWords <= 0) return 80;
    return totalWords / minutes;
  }

  /// كلمة/دقيقة → دقائق
  static double wpmToMinutes(double wpm, int totalWords) {
    if (wpm <= 0 || totalWords <= 0) return 10;
    return totalWords / wpm;
  }

  /// اقتراح سرعة مناسبة بناءً على معدل المستخدم المحفوظ أو قيمة افتراضية
  static double suggestWpm({double? learnedAvg, int? totalWords}) {
    double v;
    if (learnedAvg != null && learnedAvg > 10) {
      v = learnedAvg;
    } else {
      v = 80;
    }
    return v.clamp(KhatmWpmLimits.min, KhatmWpmLimits.max);
  }
}

/// حفظ وقراءة تفضيلات الختم المنظّم
class KhatmPrefs {
  const KhatmPrefs._();

  static const String _keyLastWpm = 'khatm_last_wpm';
  static const String _keySessionSpeeds = 'khatm_session_speeds';
  static const String _keyLearnedAvgWpm = 'khatm_learned_avg_wpm';

  static Future<double?> loadLastWpm() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getDouble(_keyLastWpm);
  }

  static Future<void> saveLastWpm(double wpm) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_keyLastWpm, wpm);
  }

  static Future<double> getLearnedAvgWpm() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getDouble(_keyLearnedAvgWpm) ?? 0;
  }

  static Future<void> recordSessionWpm(double wpm) async {
    if (wpm <= 0) return;
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getStringList(_keySessionSpeeds) ?? [];
    stored.add(wpm.toStringAsFixed(1));
    if (stored.length > 20) stored.removeAt(0);
    await prefs.setStringList(_keySessionSpeeds, stored);
    final speeds = stored
        .map((s) => double.tryParse(s) ?? 0.0)
        .where((v) => v > 5)
        .toList();
    if (speeds.isNotEmpty) {
      final avg = speeds.reduce((a, b) => a + b) / speeds.length;
      await prefs.setDouble(_keyLearnedAvgWpm, avg);
    }
  }
}

/// ملخص جلسة الختم المنظّم
class KhatmSessionSummary {
  const KhatmSessionSummary({
    required this.range,
    required this.totalElapsedSeconds,
    required this.avgWpm,
    required this.progressFraction,
    required this.isCompleted,
  });

  final KhatmRange range;
  final double totalElapsedSeconds;
  final double avgWpm;
  final double progressFraction;
  final bool isCompleted;

  Duration get elapsed => Duration(seconds: totalElapsedSeconds.round());

  String get elapsedFormatted {
    final d = elapsed;
    final m = d.inMinutes;
    final s = d.inSeconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }
}
