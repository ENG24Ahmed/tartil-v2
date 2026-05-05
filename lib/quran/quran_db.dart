import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
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
}
