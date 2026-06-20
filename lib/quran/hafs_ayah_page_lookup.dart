import 'dart:convert';

import 'package:flutter/services.dart';

const int _kTotalQuranPages = 604;

/// أول صفحة تظهر فيها الآية (من [assets/data/hafs_smart_v8.json]) — نفس منطق بناء [_ayahList] في [QuranPageViewer].
Future<Map<String, int>> loadAyahFirstPageLookupFromHafs() async {
  final raw = await rootBundle.loadString('assets/data/hafs_smart_v8.json');
  final list = jsonDecode(raw) as List;
  final best = <String, int>{};
  for (final e in list) {
    final m = Map<String, dynamic>.from(e as Map);
    final page = (m['page'] as num?)?.toInt() ?? 0;
    final suraNo = (m['sura_no'] as num?)?.toInt() ?? 0;
    final ayaNo = (m['aya_no'] as num?)?.toInt() ?? 0;
    if (page < 1 ||
        page > _kTotalQuranPages ||
        suraNo < 1 ||
        suraNo > 114 ||
        ayaNo < 1) {
      continue;
    }
    final key = '$suraNo:$ayaNo';
    final prev = best[key];
    if (prev == null || page < prev) {
      best[key] = page;
    }
  }
  return best;
}
