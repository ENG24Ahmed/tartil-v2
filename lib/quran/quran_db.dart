import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:quran_app/khatm/khatm_data.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// نسخ وفتح قاعدة quran-data.sqlite مع دعم Windows (FFI) و Android.
class QuranDb {
  QuranDb._();
  static final QuranDb instance = QuranDb._();

  static const String _assetPath = 'assets/database/quran-data.sqlite';

  Database? _db;
  static const int _mappingCacheMaxEntries = 800;
  final Map<String, Map<int, (int, int)>> _wordToAyahCache = {};
  final Map<String, Future<Map<int, (int, int)>>> _wordToAyahInFlight = {};

  /// عدد الكلمات لكل سورة كاملة (بدون صفوف علامة نهاية الآية) — يُحمَّل مرة واحدة ويُستخدم لجمع النطاقات بسرعة.
  Map<int, int>? _surahWordCountCache;
  /// أعلى رقم آية لكل سورة — للاستعلام عن نطاق 1..آخر دون تكرار MAX لكل سورة.
  Map<int, int>? _maxAyahBySurahCache;

  Database get db {
    if (_db == null) throw StateError('QuranDb not initialized. Call init() first.');
    return _db!;
  }

  static int _toInt(dynamic v, {int fallback = 0}) {
    if (v == null) return fallback;
    final s = v.toString().trim();
    if (s.isEmpty) return fallback;
    return int.tryParse(s) ?? fallback;
  }

  static bool _toBool(dynamic v, {bool fallback = false}) {
    if (v == null) return fallback;
    if (v is bool) return v;
    final s = v.toString().trim().toLowerCase();
    if (s == '1' || s == 'true') return true;
    if (s == '0' || s == 'false') return false;
    return fallback;
  }

  Future<void> init() async {
    if (_db != null) return;

    if (Platform.isWindows || Platform.isLinux) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    }

    final appDir = await getApplicationDocumentsDirectory();
    final dirPath = p.join(appDir.path, 'database');
    final filePath = p.join(dirPath, p.basename(_assetPath));

    final file = File(filePath);
    if (!await file.exists()) {
      await Directory(dirPath).create(recursive: true);
      final data = await rootBundle.load(_assetPath);
      await file.writeAsBytes(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      );
    }

    _db = await openDatabase(filePath, readOnly: true);
  }

  static Map<String, dynamic> _layoutRow(Map<String, dynamic> row, {required int page}) {
    return {
      'page': _toInt(row['page'], fallback: page),
      'line': _toInt(row['line']),
      'type': row['type']?.toString().trim() ?? '',
      'is_centered': _toBool(row['is_centered']),
      'range_start': _toInt(row['range_start']),
      'range_end': _toInt(row['range_end']),
    };
  }

  Future<List<Map<String, dynamic>>> getLayoutForPage(int page) async {
    await init();
    final rows = await db.query(
      'qpc_v1_layout',
      columns: ['page', 'line', 'type', 'is_centered', 'range_start', 'range_end'],
      where: 'page = ?',
      whereArgs: [page],
      orderBy: 'line ASC',
    );
    return rows.map((r) => _layoutRow(r, page: page)).toList();
  }

  Future<List<Map<String, dynamic>>> getLayoutForPageV4(int page) async {
    await init();
    final rows = await db.query(
      'qpc_v4_layout',
      columns: ['page', 'line', 'type', 'is_centered', 'range_start', 'range_end'],
      where: 'page = ?',
      whereArgs: [page],
      orderBy: 'line ASC',
    );
    return rows.map((r) => _layoutRow(r, page: page)).toList();
  }

  Future<List<String>> getQpcV1InRange(int rangeStart, int rangeEnd) async {
    await init();
    final rows = await db.query(
      'words',
      columns: ['word_number_all', 'qpc_v1', 'is_ayah_marker'],
      where: 'word_number_all >= ? AND word_number_all <= ?',
      whereArgs: [rangeStart, rangeEnd],
      orderBy: 'word_number_all ASC',
    );
    return rows
        .map((r) => r['qpc_v1']?.toString() ?? '')
        .where((s) => s.isNotEmpty)
        .toList();
  }

  /// نص QPC1 لكل [word_number_all] في النطاق (مع الحفاظ على الفهارس الفعلية).
  Future<Map<int, String>> getQpcV1TextByWordNumberAll(
      int minId, int maxId) async {
    final out = <int, String>{};
    try {
      await init();
      final rows = await db.query(
        'words',
        columns: ['word_number_all', 'qpc_v1'],
        where: 'word_number_all >= ? AND word_number_all <= ?',
        whereArgs: [minId, maxId],
        orderBy: 'word_number_all ASC',
      );
      for (final r in rows) {
        final id = _toInt(r['word_number_all']);
        out[id] = r['qpc_v1']?.toString() ?? '';
      }
    } catch (_) {}
    return out;
  }

  Future<Map<int, bool>> getAyahMarkerByWordNumberAll(int minId, int maxId) async {
    final out = <int, bool>{};
    try {
      await init();
      final rows = await db.query(
        'words',
        columns: ['word_number_all', 'is_ayah_marker'],
        where: 'word_number_all >= ? AND word_number_all <= ?',
        whereArgs: [minId, maxId],
        orderBy: 'word_number_all ASC',
      );
      for (final r in rows) {
        final id = _toInt(r['word_number_all']);
        out[id] = _toBool(r['is_ayah_marker']);
      }
    } catch (_) {}
    return out;
  }

  /// ربط word_number_all → (surah_number, ayah_number) لنطاق كلمات (لنسخ الآية عند الضغط المطول).
  /// الاستعلام: SELECT word_number_all, surah_number, ayah_number FROM words WHERE ...
  Future<Map<int, (int sura, int ayah)>> getWordToAyahMapping(int minId, int maxId) async {
    final key = '$minId:$maxId';
    final cached = _wordToAyahCache[key];
    if (cached != null) return cached;
    final pending = _wordToAyahInFlight[key];
    if (pending != null) return pending;

    final fut = _queryWordToAyahMapping(minId, maxId).whenComplete(() {
      _wordToAyahInFlight.remove(key);
    });
    _wordToAyahInFlight[key] = fut;
    final out = await fut;
    if (_wordToAyahCache.length >= _mappingCacheMaxEntries) {
      _wordToAyahCache.remove(_wordToAyahCache.keys.first);
    }
    _wordToAyahCache[key] = out;
    return out;
  }

  Future<Map<int, (int sura, int ayah)>> _queryWordToAyahMapping(
      int minId, int maxId) async {
    final out = <int, (int, int)>{};
    try {
      await init();
      final rows = await db.query(
        'words',
        columns: ['word_number_all', 'surah_number', 'ayah_number'],
        where: 'word_number_all >= ? AND word_number_all <= ?',
        whereArgs: [minId, maxId],
        orderBy: 'word_number_all ASC',
      );
      for (final r in rows) {
        final id = _toInt(r['word_number_all']);
        final sura = _toInt(r['surah_number']);
        final ayah = _toInt(r['ayah_number']);
        if (sura > 0 && ayah > 0) out[id] = (sura, ayah);
      }
    } catch (_) {}
    return out;
  }

  Future<void> prewarmWordToAyahMapping(int minId, int maxId) async {
    if (minId <= 0 || maxId < minId) return;
    await getWordToAyahMapping(minId, maxId);
  }

  /// نطاق word_number_all لآية معينة (للعثور على السطر الذي يحتويها في التخطيط).
  Future<(int min, int max)?> getWordRangeForAyah(int surahNumber, int ayahNumber) async {
    try {
      await init();
      final rows = await db.query(
        'words',
        columns: ['word_number_all'],
        where: 'surah_number = ? AND ayah_number = ?',
        whereArgs: [surahNumber, ayahNumber],
        orderBy: 'word_number ASC',
      );
      if (rows.isEmpty) return null;
      final ids = rows.map((r) => _toInt(r['word_number_all'])).where((i) => i > 0).toList();
      if (ids.isEmpty) return null;
      return (ids.reduce((a, b) => a < b ? a : b), ids.reduce((a, b) => a > b ? a : b));
    } catch (_) {}
    return null;
  }

  /// يزيل `U+06ED` من النص المعروض فقط (بعض الخطوط تعرضه كحرف «م» زائد).
  static String stripUthmaniLowMeemMark(String s) => s.replaceAll('\u06ED', '');

  /// نص الآية كاملة من عمود uthmani (للعرض والنسخ).
  /// الاستعلام: SELECT uthmani FROM words WHERE surah_number = ? AND ayah_number = ? ORDER BY word_number ASC
  Future<String> getAyahTextUthmani(int surahNumber, int ayahNumber) async {
    try {
      await init();
      final rows = await db.query(
        'words',
        columns: ['uthmani'],
        where: 'surah_number = ? AND ayah_number = ?',
        whereArgs: [surahNumber, ayahNumber],
        orderBy: 'word_number ASC',
      );
      final parts = rows.map((r) => r['uthmani']?.toString().trim() ?? '').where((s) => s.isNotEmpty);
      return parts.join(' ');
    } catch (_) {}
    return '';
  }

  /// نص عثماني لنطاق آيات (للختم المنظّم)، يشمل صفوف علامة نهاية الآية (`is_ayah_marker`).
  /// للعرض يُستبعد الرمز U+06ED فقط (انظر [stripUthmaniLowMeemMark]).
  Future<String> getUthmaniTextForRange(
    int surahNumber,
    int fromAyah,
    int toAyah,
  ) async {
    final pieces = await getKhatmLinePiecesForRange(surahNumber, fromAyah, toAyah);
    final buf = StringBuffer();
    for (var i = 0; i < pieces.length; i++) {
      if (i > 0) buf.write(' ');
      final p = pieces[i];
      if (p.isMarker) {
        buf.write(p.verseMarkerDisplayText);
      } else {
        buf.write(p.text);
      }
    }
    return buf.toString();
  }

  /// قطع سطر الختم: كلمات + علامات نهاية آية (نص العلامة من قاعدة البيانات أو رقم هندي).
  Future<List<KhatmLinePiece>> getKhatmLinePiecesForRange(
    int surahNumber,
    int fromAyah,
    int toAyah,
  ) async {
    try {
      await init();
      final rows = await db.query(
        'words',
        columns: ['uthmani', 'ayah_number', 'word_number', 'is_ayah_marker'],
        where: 'surah_number = ? AND ayah_number >= ? AND ayah_number <= ?',
        whereArgs: [surahNumber, fromAyah, toAyah],
        orderBy: 'word_number_all ASC',
      );
      final out = <KhatmLinePiece>[];
      for (final r in rows) {
        final marker = _toBool(r['is_ayah_marker']);
        final ayah = _toInt(r['ayah_number']);
        final raw = (r['uthmani'] ?? '').toString().trim();
        if (marker) {
          if (ayah > 0) {
            final glyph = stripUthmaniLowMeemMark(raw);
            out.add(KhatmLinePiece.verseEnd(
              ayahNumber: ayah,
              markerUthmani: glyph,
            ));
          }
        } else {
          final u = stripUthmaniLowMeemMark(raw);
          if (u.isNotEmpty) out.add(KhatmLinePiece.word(u));
        }
      }
      return out;
    } catch (_) {}
    return const [];
  }

  /// آخر رقم آية في السورة (من جدول الكلمات).
  Future<int> maxAyahInSurah(int surahNumber) async {
    try {
      await init();
      final rows = await db.rawQuery(
        'SELECT MAX(ayah_number) AS m FROM words WHERE surah_number = ?',
        [surahNumber],
      );
      final m = _toInt(rows.firstOrNull?['m'], fallback: 0);
      return m > 0 ? m : 1;
    } catch (_) {}
    return 1;
  }

  /// يحمّل خريطة «رقم السورة → عدد كلمات السورة كاملة» مرة واحدة (استعلام واحد).
  Future<Map<int, int>> getSurahWordCounts() async {
    if (_surahWordCountCache != null) return _surahWordCountCache!;
    try {
      await init();
      final rows = await db.rawQuery(
        '''
        SELECT surah_number, COUNT(*) AS cnt
        FROM words
        WHERE (is_ayah_marker IS NULL OR is_ayah_marker = 0)
        GROUP BY surah_number
        ''',
      );
      final map = <int, int>{};
      for (final r in rows) {
        final sn = _toInt(r['surah_number']);
        if (sn > 0) map[sn] = _toInt(r['cnt']);
      }
      _surahWordCountCache = map;
      return map;
    } catch (_) {
      _surahWordCountCache = {};
      return _surahWordCountCache!;
    }
  }

  /// أعلى [ayah_number] لكل سورة (استعلام واحد).
  Future<Map<int, int>> getMaxAyahBySurah() async {
    if (_maxAyahBySurahCache != null) return _maxAyahBySurahCache!;
    try {
      await init();
      final rows = await db.rawQuery(
        '''
        SELECT surah_number, MAX(ayah_number) AS m
        FROM words
        GROUP BY surah_number
        ''',
      );
      final map = <int, int>{};
      for (final r in rows) {
        final sn = _toInt(r['surah_number']);
        final m = _toInt(r['m']);
        if (sn > 0 && m > 0) map[sn] = m;
      }
      _maxAyahBySurahCache = map;
      return map;
    } catch (_) {
      _maxAyahBySurahCache = {};
      return _maxAyahBySurahCache!;
    }
  }

  /// عدد الكلمات لعدة سور كاملة من [fromSurah] إلى [toSurah] (بالترتيب الرقمي).
  Future<int> getWordCountForSurahSpan(int fromSurah, int toSurah) async {
    final lo = fromSurah <= toSurah ? fromSurah : toSurah;
    final hi = fromSurah <= toSurah ? toSurah : fromSurah;
    final map = await getSurahWordCounts();
    var sum = 0;
    for (var s = lo; s <= hi; s++) {
      sum += map[s] ?? 0;
    }
    return sum;
  }

  /// قطع سطر الختم لعدة سور كاملة (بفراغ بين السور للقراءة المتواصلة).
  Future<List<KhatmLinePiece>> getKhatmLinePiecesForSurahSpan(
    int fromSurah,
    int toSurah,
  ) async {
    final lo = fromSurah <= toSurah ? fromSurah : toSurah;
    final hi = fromSurah <= toSurah ? toSurah : fromSurah;
    final maxMap = await getMaxAyahBySurah();
    final out = <KhatmLinePiece>[];
    for (var s = lo; s <= hi; s++) {
      final last = maxMap[s] ?? await maxAyahInSurah(s);
      final part = await getKhatmLinePiecesForRange(s, 1, last);
      if (out.isNotEmpty && part.isNotEmpty) {
        out.add(const KhatmLinePiece.word(' '));
      }
      out.addAll(part);
    }
    return out;
  }

  /// عدد الكلمات لنطاق آيات (بدون علامات الآيات).
  Future<int> getWordCountForRange(
    int surahNumber,
    int fromAyah,
    int toAyah,
  ) async {
    try {
      await init();
      final rows = await db.rawQuery(
        '''
        SELECT COUNT(*) AS cnt
        FROM words
        WHERE surah_number = ?
          AND ayah_number >= ?
          AND ayah_number <= ?
          AND (is_ayah_marker IS NULL OR is_ayah_marker = 0)
        ''',
        [surahNumber, fromAyah, toAyah],
      );
      return _toInt(rows.firstOrNull?['cnt']);
    } catch (_) {}
    return 0;
  }

  /// عدد كلمات كل آية في سورة واحدة ضمن نطاق آيات.
  Future<List<({int surah, int ayah, int words})>> getAyahWordCountsForSurah(
    int surahNumber,
    int fromAyah,
    int toAyah,
  ) async {
    try {
      await init();
      final rows = await db.rawQuery(
        '''
        SELECT surah_number, ayah_number, COUNT(*) AS cnt
        FROM words
        WHERE surah_number = ?
          AND ayah_number >= ?
          AND ayah_number <= ?
          AND (is_ayah_marker IS NULL OR is_ayah_marker = 0)
        GROUP BY surah_number, ayah_number
        ORDER BY ayah_number ASC
        ''',
        [surahNumber, fromAyah, toAyah],
      );
      return rows
          .map((r) => (
                surah: _toInt(r['surah_number']),
                ayah: _toInt(r['ayah_number']),
                words: _toInt(r['cnt']),
              ))
          .where((e) => e.surah > 0 && e.ayah > 0 && e.words > 0)
          .toList();
    } catch (_) {}
    return const [];
  }

  /// عدد كلمات كل آية لعدة سور كاملة (من [fromSurah] إلى [toSurah]).
  Future<List<({int surah, int ayah, int words})>> getAyahWordCountsForSurahSpan(
    int fromSurah,
    int toSurah,
  ) async {
    final lo = fromSurah <= toSurah ? fromSurah : toSurah;
    final hi = fromSurah <= toSurah ? toSurah : fromSurah;
    try {
      await init();
      final rows = await db.rawQuery(
        '''
        SELECT surah_number, ayah_number, COUNT(*) AS cnt
        FROM words
        WHERE surah_number >= ?
          AND surah_number <= ?
          AND (is_ayah_marker IS NULL OR is_ayah_marker = 0)
        GROUP BY surah_number, ayah_number
        ORDER BY surah_number ASC, ayah_number ASC
        ''',
        [lo, hi],
      );
      return rows
          .map((r) => (
                surah: _toInt(r['surah_number']),
                ayah: _toInt(r['ayah_number']),
                words: _toInt(r['cnt']),
              ))
          .where((e) => e.surah > 0 && e.ayah > 0 && e.words > 0)
          .toList();
    } catch (_) {}
    return const [];
  }

  /// عدد كلمات كل آية من بداية ([fromSurah],[fromAyah]) إلى نهاية ([toSurah],[toAyah]) بترتيب المصحف.
  Future<List<({int surah, int ayah, int words})>> getAyahWordCountsForReadingSegment(
    int fromSurah,
    int fromAyah,
    int toSurah,
    int toAyah,
  ) async {
    final loS = fromSurah <= toSurah ? fromSurah : toSurah;
    final hiS = fromSurah <= toSurah ? toSurah : fromSurah;
    final loA = fromSurah <= toSurah ? fromAyah : toAyah;
    final hiA = fromSurah <= toSurah ? toAyah : fromAyah;
    try {
      await init();
      final rows = await db.rawQuery(
        '''
        SELECT surah_number, ayah_number, COUNT(*) AS cnt
        FROM words
        WHERE (
            surah_number > ? OR (surah_number = ? AND ayah_number >= ?)
          )
          AND (
            surah_number < ? OR (surah_number = ? AND ayah_number <= ?)
          )
          AND (is_ayah_marker IS NULL OR is_ayah_marker = 0)
        GROUP BY surah_number, ayah_number
        ORDER BY surah_number ASC, ayah_number ASC
        ''',
        [loS, loS, loA, hiS, hiS, hiA],
      );
      return rows
          .map((r) => (
                surah: _toInt(r['surah_number']),
                ayah: _toInt(r['ayah_number']),
                words: _toInt(r['cnt']),
              ))
          .where((e) => e.surah > 0 && e.ayah > 0 && e.words > 0)
          .toList();
    } catch (_) {}
    return const [];
  }

  Future<int> getWordCountForReadingSegment(
    int fromSurah,
    int fromAyah,
    int toSurah,
    int toAyah,
  ) async {
    final rows = await getAyahWordCountsForReadingSegment(
      fromSurah,
      fromAyah,
      toSurah,
      toAyah,
    );
    var s = 0;
    for (final r in rows) {
      s += r.words;
    }
    return s;
  }

  /// نص الختم لقطعة قراءة متعدّدة السور (بفراغ بين السور كما في [getKhatmLinePiecesForSurahSpan]).
  Future<List<KhatmLinePiece>> getKhatmLinePiecesForReadingSegment(
    int fromSurah,
    int fromAyah,
    int toSurah,
    int toAyah,
  ) async {
    final loS = fromSurah <= toSurah ? fromSurah : toSurah;
    final hiS = fromSurah <= toSurah ? toSurah : fromSurah;
    final loA = fromSurah <= toSurah ? fromAyah : toAyah;
    final hiA = fromSurah <= toSurah ? toAyah : fromAyah;
    final maxMap = await getMaxAyahBySurah();
    final out = <KhatmLinePiece>[];
    for (var s = loS; s <= hiS; s++) {
      final lastInS = maxMap[s] ?? await maxAyahInSurah(s);
      final a0 = s == loS ? loA : 1;
      final a1 = s == hiS ? hiA : lastInS;
      if (a0 > a1) continue;
      final part = await getKhatmLinePiecesForRange(s, a0, a1);
      if (out.isNotEmpty && part.isNotEmpty) {
        out.add(const KhatmLinePiece.word(' '));
      }
      out.addAll(part);
    }
    return out;
  }

  /// صفوف آيات الختم لأي [KhatmRange] يدعمه التطبيق.
  Future<List<({int surah, int ayah, int words})>> getAyahWordRowsForKhatmRange(
    KhatmRange range,
  ) async {
    switch (range.type) {
      case KhatmRangeType.surahSpan:
        return getAyahWordCountsForSurahSpan(range.loSurah, range.hiSurah);
      case KhatmRangeType.ayahRange:
        return getAyahWordCountsForSurah(
          range.fromSurah,
          range.fromAyah,
          range.toAyah,
        );
      case KhatmRangeType.readingSegment:
        return getAyahWordCountsForReadingSegment(
          range.fromSurah,
          range.fromAyah,
          range.toSurah,
          range.toAyah,
        );
    }
  }
}
