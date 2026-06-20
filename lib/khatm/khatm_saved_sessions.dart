import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'package:quran_app/khatm/khatm_data.dart';
import 'package:quran_app/quran/quran_db.dart';

/// حد أقصى لعدد الجلسات المحفوظة للختم المنظّم.
const int khatmSavedSessionsMax = 3;

const String _prefsKey = 'khatm_saved_sessions_json_v1';

/// جلسة ختم محفوظة: تُستأنف من أول آية في [range] (تُحسب كأول آية لم يُكملها المستخدم بعد).
class KhatmSavedSessionRecord {
  const KhatmSavedSessionRecord({
    required this.id,
    required this.range,
    required this.wpm,
    required this.savedAtMillis,
    required this.resumeCaption,
  });

  final String id;
  final KhatmRange range;
  final double wpm;
  final int savedAtMillis;

  /// سطر قصير للعرض، مثل: «يُستأنف من آية ١٤».
  final String resumeCaption;

  Map<String, dynamic> toJson() => {
        'id': id,
        'range': khatmRangeToJson(range),
        'wpm': wpm,
        'savedAtMillis': savedAtMillis,
        'resumeCaption': resumeCaption,
      };

  static KhatmSavedSessionRecord fromJson(Map<String, dynamic> m) {
    return KhatmSavedSessionRecord(
      id: m['id'] as String? ?? '${m['savedAtMillis']}',
      range: khatmRangeFromJson(m['range'] as Map<String, dynamic>),
      wpm: (m['wpm'] as num?)?.toDouble() ?? 80,
      savedAtMillis: (m['savedAtMillis'] as num?)?.toInt() ?? 0,
      resumeCaption: m['resumeCaption'] as String? ?? '',
    );
  }
}

Map<String, dynamic> khatmRangeToJson(KhatmRange r) {
  final names = <String, String>{};
  for (final e in r.surahNamesAr.entries) {
    names['${e.key}'] = e.value;
  }
  return {
    'type': r.type.name,
    'fromSurah': r.fromSurah,
    'toSurah': r.toSurah,
    'fromSurahName': r.fromSurahName,
    'toSurahName': r.toSurahName,
    'fromAyah': r.fromAyah,
    'toAyah': r.toAyah,
    'totalWords': r.totalWords,
    'surahNamesAr': names,
  };
}

KhatmRangeType _parseKhatmRangeType(String? s) {
  for (final v in KhatmRangeType.values) {
    if (v.name == s) return v;
  }
  return KhatmRangeType.ayahRange;
}

KhatmRange khatmRangeFromJson(Map<String, dynamic> m) {
  final type = _parseKhatmRangeType(m['type'] as String?);
  final rawNames = m['surahNamesAr'];
  final names = <int, String>{};
  if (rawNames is Map) {
    for (final e in rawNames.entries) {
      final k = int.tryParse('${e.key}');
      if (k != null && e.value is String) names[k] = e.value as String;
    }
  }
  return KhatmRange(
    type: type,
    fromSurah: (m['fromSurah'] as num?)?.toInt() ?? 1,
    toSurah: (m['toSurah'] as num?)?.toInt() ?? 1,
    fromSurahName: m['fromSurahName'] as String? ?? '',
    toSurahName: m['toSurahName'] as String? ?? '',
    fromAyah: (m['fromAyah'] as num?)?.toInt() ?? 1,
    toAyah: (m['toAyah'] as num?)?.toInt() ?? 1,
    totalWords: (m['totalWords'] as num?)?.toInt() ?? 0,
    surahNamesAr: names,
  );
}

/// نهاية المادة القابلة للقراءة في النطاق الحالي (آخر سورة / آخر آية).
Future<({int surah, int ayah})> khatmEndOfReadingMaterial(KhatmRange r) async {
  switch (r.type) {
    case KhatmRangeType.surahSpan:
      final hi = r.hiSurah;
      final last = await QuranDb.instance.maxAyahInSurah(hi);
      return (surah: hi, ayah: last);
    case KhatmRangeType.ayahRange:
      return (surah: r.fromSurah, ayah: r.toAyah);
    case KhatmRangeType.readingSegment:
      return (surah: r.toSurah, ayah: r.toAyah);
  }
}

/// أول آية يُفترض أن يبدأ منها المستخدم لاحقًا، من [progressFraction] ٠…١.
/// إن كان التقدّم عند نهاية آية كاملة يُعاد **الآية التالية** (آخر آية مقروءة بالكامل = السابقة).
Future<({int surah, int ayah})> khatmResumeAyahFromProgress(
  KhatmRange range,
  double progressFraction,
) async {
  final rows = await QuranDb.instance.getAyahWordRowsForKhatmRange(range);
  if (rows.isEmpty) {
    return (surah: range.fromSurah, ayah: range.fromAyah);
  }
  final total = range.totalWords;
  if (total <= 0) {
    final f = rows.first;
    return (surah: f.surah, ayah: f.ayah);
  }
  final passedUnits =
      (progressFraction.clamp(0.0, 1.0) * total).floor().clamp(0, total);
  if (passedUnits == 0) {
    final f = rows.first;
    return (surah: f.surah, ayah: f.ayah);
  }
  if (passedUnits >= total) {
    final last = rows.last;
    return (surah: last.surah, ayah: last.ayah);
  }
  var cum = 0;
  for (final row in rows) {
    final next = cum + row.words;
    if (passedUnits < next) {
      return (surah: row.surah, ayah: row.ayah);
    }
    cum = next;
  }
  final last = rows.last;
  return (surah: last.surah, ayah: last.ayah);
}

Future<KhatmRange> khatmBuildReadingSegmentRange({
  required KhatmRange sourceContext,
  required int resumeSurah,
  required int resumeAyah,
  required int endSurah,
  required int endAyah,
}) async {
  final total = await QuranDb.instance.getWordCountForReadingSegment(
    resumeSurah,
    resumeAyah,
    endSurah,
    endAyah,
  );
  final names = <int, String>{};
  final loS = resumeSurah <= endSurah ? resumeSurah : endSurah;
  final hiS = resumeSurah <= endSurah ? endSurah : resumeSurah;
  for (final e in sourceContext.surahNamesAr.entries) {
    if (e.key >= loS && e.key <= hiS) {
      names[e.key] = e.value;
    }
  }
  return KhatmRange(
    type: KhatmRangeType.readingSegment,
    fromSurah: resumeSurah,
    toSurah: endSurah,
    fromSurahName: sourceContext.surahNameAr(resumeSurah),
    toSurahName: sourceContext.surahNameAr(endSurah),
    fromAyah: resumeAyah,
    toAyah: endAyah,
    totalWords: total,
    surahNamesAr: names,
  );
}

abstract final class KhatmSavedSessionsStore {
  static Future<List<KhatmSavedSessionRecord>> loadAll() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      return list
          .map((e) => KhatmSavedSessionRecord.fromJson(
                Map<String, dynamic>.from(e as Map),
              ))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  static Future<void> _writeAll(List<KhatmSavedSessionRecord> list) async {
    final prefs = await SharedPreferences.getInstance();
    final enc = jsonEncode(list.map((e) => e.toJson()).toList());
    await prefs.setString(_prefsKey, enc);
  }

  /// يضيف الجلسة؛ إن تجاوز العدد [khatmSavedSessionsMax] يُحذف الأقدم.
  static Future<void> add(KhatmSavedSessionRecord record) async {
    final cur = await loadAll();
    final next = [...cur, record]
      ..sort((a, b) => a.savedAtMillis.compareTo(b.savedAtMillis));
    while (next.length > khatmSavedSessionsMax) {
      next.removeAt(0);
    }
    await _writeAll(next);
  }

  static Future<void> removeById(String id) async {
    final cur = await loadAll();
    await _writeAll(cur.where((e) => e.id != id).toList());
  }
}
