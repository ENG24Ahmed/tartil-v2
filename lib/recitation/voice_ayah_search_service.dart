import 'package:quran_app/recitation/arabic_normalizer.dart';
import 'package:quran_app/recitation/recitation_db.dart';

/// نتيجة بحث صوتي واحدة — مشتقة من RecitationDb بدون تعديل قاعدة البيانات.
class VoiceAyahSearchResult {
  const VoiceAyahSearchResult({
    required this.surahNumber,
    required this.surahName,
    required this.ayahNumber,
    required this.pageNumber,
    required this.ayahText,
    required this.confidenceScore,
    required this.isFuzzy,
  });

  final int surahNumber;
  final String surahName;
  final int ayahNumber;
  final int pageNumber;
  final String ayahText;

  /// درجة الثقة: 0.0–1.0 محسوبة من token_hits وword coverage.
  final double confidenceScore;

  /// true إذا جاءت النتيجة من البحث الضبابي fuzzy.
  final bool isFuzzy;
}

/// Wrapper خفيف حول RecitationDb لبحث الآيات من نص صوتي.
/// لا يُعدّل قاعدة البيانات ولا أي منطق من ملفات التسميع الذكي.
class VoiceAyahSearchService {
  VoiceAyahSearchService._();

  static final VoiceAyahSearchService instance = VoiceAyahSearchService._();

  // --- helpers قراءة آمنة للحقول ---

  static int _readInt(Map<String, Object?> row, List<String> keys,
      [int fallback = 0]) {
    for (final key in keys) {
      final v = row[key];
      if (v == null) continue;
      if (v is int) return v;
      if (v is num) return v.toInt();
      final parsed = int.tryParse(v.toString());
      if (parsed != null) return parsed;
    }
    return fallback;
  }

  static double _readDouble(Map<String, Object?> row, List<String> keys,
      [double fallback = 0.0]) {
    for (final key in keys) {
      final v = row[key];
      if (v == null) continue;
      if (v is double) return v;
      if (v is num) return v.toDouble();
      final parsed = double.tryParse(v.toString());
      if (parsed != null) return parsed;
    }
    return fallback;
  }

  static String _readString(Map<String, Object?> row, List<String> keys,
      [String fallback = '']) {
    for (final key in keys) {
      final v = row[key];
      if (v == null) continue;
      final s = v.toString();
      if (s.isNotEmpty) return s;
    }
    return fallback;
  }

  /// يبحث عن أقرب آيات للنص الصوتي ويرجع أفضل 8 نتائج.
  /// يعيد قائمة فارغة إذا كان النص أقل من كلمتين بعد التطبيع.
  Future<List<VoiceAyahSearchResult>> search(String transcript) async {
    final t = transcript.trim();
    if (t.isEmpty) return const [];

    final normalized = ArabicNormalizer.normalizeForSearch(t);
    final words = normalized.split(' ').where((w) => w.isNotEmpty).toList();
    if (words.length < 2) return const [];

    // --- بحث رئيسي: searchAyahCandidates + searchAyahCandidatesBySpokenHead ---
    final primary =
        await RecitationDb.instance.searchAyahCandidates(t, limit: 60);
    final head =
        await RecitationDb.instance.searchAyahCandidatesBySpokenHead(t);

    // --- دمج وإزالة التكرار ---
    final seen = <String>{};
    final merged = <Map<String, Object?>>[];
    for (final row in [...primary, ...head]) {
      final key =
          '${_readInt(row, ['surah_number'])}_${_readInt(row, ['ayah_number'])}';
      if (seen.add(key)) merged.add(row);
    }

    // --- بحث ضبابي احتياطي إذا كانت النتائج قليلة ---
    if (merged.length < 3) {
      final fuzzy =
          await RecitationDb.instance.searchAyahFuzzyByAsr(t, limit: 10);
      for (final row in fuzzy) {
        final key =
            '${_readInt(row, ['surah_number'])}_${_readInt(row, ['ayah_number'])}';
        if (seen.add(key)) merged.add(row);
      }
    }

    // --- تحويل إلى نتائج مع فلترة وترتيب ---
    final results = <VoiceAyahSearchResult>[];
    for (final row in merged) {
      final rawScore = _computeConfidence(row, words);
      // تجاهل النتائج بدرجة ثقة ضعيفة أو غير صالحة
      if (rawScore.isNaN || rawScore.isInfinite || rawScore < 0.55) continue;
      final score = rawScore.clamp(0.0, 1.0);

      final sNum = _readInt(row, ['surah_number']);
      final aNum = _readInt(row, ['ayah_number']);
      final pNum = _readInt(row, ['page_number']);
      final sName = _readString(
          row, ['surah_name_ar', 'surah_name'], 'سورة غير معروفة');
      final aText =
          _readString(row, ['search_text', 'ayah_text', 'text']);

      // تجاهل نتائج ببيانات غير صالحة
      if (pNum < 1 || pNum > 604) continue;
      if (sNum < 1 || aNum < 1) continue;
      if (aText.isEmpty) continue;

      results.add(VoiceAyahSearchResult(
        surahNumber: sNum,
        surahName: sName,
        ayahNumber: aNum,
        pageNumber: pNum,
        ayahText: aText,
        confidenceScore: score,
        isFuzzy: row['fuzzy_score'] != null,
      ));
    }

    results.sort((a, b) => b.confidenceScore.compareTo(a.confidenceScore));
    return results.take(8).toList();
  }

  /// حساب درجة الثقة من حقول RecitationDb الموجودة فعلياً.
  double _computeConfidence(
    Map<String, Object?> row,
    List<String> queryWords,
  ) {
    // fuzzy_score موجود → نستخدمه مباشرة (يكون بين 0.38–1.0)
    final fuzzyRaw = row['fuzzy_score'];
    if (fuzzyRaw != null) {
      final fs = _readDouble(row, ['fuzzy_score']);
      return fs.clamp(0.0, 1.0);
    }

    // coverage من token_hits (DB يأخذ أول 6 tokens)
    final tokenHits = _readInt(row, ['token_hits']);
    final maxTokens = queryWords.length.clamp(1, 6);
    final tokenCoverage = (tokenHits / maxTokens).clamp(0.0, 1.0);

    // word coverage: نسبة كلمات الاستعلام الموجودة في search_text
    final searchText = _readString(row, ['search_text', 'ayah_text', 'text']);
    final wordHits = queryWords
        .where((w) => w.length >= 2 && searchText.contains(w))
        .length;
    final wordCoverage = (wordHits / queryWords.length).clamp(0.0, 1.0);

    final result = tokenCoverage * 0.72 + wordCoverage * 0.28;
    if (result.isNaN || result.isInfinite) return 0.0;
    return result.clamp(0.0, 1.0);
  }
}
