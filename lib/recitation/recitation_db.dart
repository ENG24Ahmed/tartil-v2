import 'dart:io';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:quran_app/recitation/arabic_normalizer.dart';
import 'package:quran_app/recitation/recitation_fuzzy_ayah.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class RecitationDb {
  RecitationDb._();

  static final RecitationDb instance = RecitationDb._();
  static const String _assetPath = 'assets/database/quran-recitation.sqlite';

  Database? _db;

  Database get db {
    if (_db == null) {
      throw StateError('RecitationDb not initialized. Call init() first.');
    }
    return _db!;
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

    _db = await openDatabase(filePath, readOnly: false);
    await _ensureRuntimeTables();
  }

  Future<void> _ensureRuntimeTables() async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS recitation_sessions (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        started_at TEXT NOT NULL,
        ended_at TEXT,
        platform TEXT,
        status TEXT NOT NULL DEFAULT 'active',
        start_surah INTEGER,
        start_ayah INTEGER,
        last_surah INTEGER,
        last_ayah INTEGER,
        last_word_number_all INTEGER,
        total_words INTEGER NOT NULL DEFAULT 0,
        correct_words INTEGER NOT NULL DEFAULT 0,
        wrong_words INTEGER NOT NULL DEFAULT 0,
        updated_at TEXT NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS recitation_state (
        id INTEGER PRIMARY KEY CHECK (id = 1),
        current_session_id INTEGER,
        last_surah INTEGER,
        last_ayah INTEGER,
        last_word_number_all INTEGER,
        updated_at TEXT NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS recitation_ayah_stats (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        surah_number INTEGER NOT NULL,
        ayah_number INTEGER NOT NULL,
        total_attempts INTEGER NOT NULL DEFAULT 0,
        total_words INTEGER NOT NULL DEFAULT 0,
        correct_words INTEGER NOT NULL DEFAULT 0,
        wrong_words INTEGER NOT NULL DEFAULT 0,
        last_score REAL,
        last_status TEXT,
        last_error_word_ids TEXT,
        updated_at TEXT NOT NULL,
        UNIQUE (surah_number, ayah_number)
      )
    ''');

    await _ensureRuntimeSchemaColumns();
  }

  Future<void> _ensureRuntimeSchemaColumns() async {
    await _ensureColumns(
      'recitation_sessions',
      const <(String, String)>[
        ('platform', "TEXT DEFAULT 'mobile'"),
        ('created_at', 'TEXT'),
        ('status', "TEXT NOT NULL DEFAULT 'active'"),
        ('start_surah', 'INTEGER'),
        ('start_ayah', 'INTEGER'),
        ('last_surah', 'INTEGER'),
        ('last_ayah', 'INTEGER'),
        ('last_word_number_all', 'INTEGER'),
        ('total_words', 'INTEGER NOT NULL DEFAULT 0'),
        ('correct_words', 'INTEGER NOT NULL DEFAULT 0'),
        ('wrong_words', 'INTEGER NOT NULL DEFAULT 0'),
        ('updated_at', "TEXT NOT NULL DEFAULT ''"),
      ],
    );
    await _ensureColumns(
      'recitation_state',
      const <(String, String)>[
        ('current_session_id', 'INTEGER'),
        ('last_surah', 'INTEGER'),
        ('last_ayah', 'INTEGER'),
        ('last_word_number_all', 'INTEGER'),
        ('updated_at', "TEXT NOT NULL DEFAULT ''"),
      ],
    );
    await _ensureColumns(
      'recitation_ayah_stats',
      const <(String, String)>[
        ('total_attempts', 'INTEGER NOT NULL DEFAULT 0'),
        ('total_words', 'INTEGER NOT NULL DEFAULT 0'),
        ('correct_words', 'INTEGER NOT NULL DEFAULT 0'),
        ('wrong_words', 'INTEGER NOT NULL DEFAULT 0'),
        ('last_score', 'REAL'),
        ('last_status', 'TEXT'),
        ('last_error_word_ids', 'TEXT'),
        ('updated_at', "TEXT NOT NULL DEFAULT ''"),
      ],
    );
  }

  Future<Set<String>> _tableColumns(String tableName) async {
    final info = await db.rawQuery('PRAGMA table_info($tableName)');
    return info
        .map((row) => (row['name'] ?? '').toString().trim())
        .where((name) => name.isNotEmpty)
        .toSet();
  }

  Future<void> _ensureColumns(
    String tableName,
    List<(String, String)> columns,
  ) async {
    final info = await db.rawQuery('PRAGMA table_info($tableName)');
    final existing = info
        .map((row) => (row['name'] ?? '').toString().trim())
        .where((name) => name.isNotEmpty)
        .toSet();
    for (final (name, definition) in columns) {
      if (existing.contains(name)) {
        continue;
      }
      await db.execute('ALTER TABLE $tableName ADD COLUMN $name $definition');
    }
  }

  Future<List<Map<String, Object?>>> getSurahs() async {
    await init();
    return db.query('surahs', orderBy: 'id ASC');
  }

  Future<Map<String, Object?>?> getAyah(int surahNumber, int ayahNumber) async {
    await init();
    final rows = await db.query(
      'ayahs',
      where: 'surah_number = ? AND ayah_number = ?',
      whereArgs: [surahNumber, ayahNumber],
      limit: 1,
    );

    return rows.isEmpty ? null : rows.first;
  }

  Future<Map<String, Object?>?> getAyahById(int ayahId) async {
    await init();
    final rows = await db.query(
      'ayahs',
      where: 'id = ?',
      whereArgs: [ayahId],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first;
  }

  Future<List<Map<String, Object?>>> getDisplayWordsForAyah(
    int surahNumber,
    int ayahNumber,
  ) async {
    await init();
    return db.query(
      'display_words',
      where: 'surah_number = ? AND ayah_number = ?',
      whereArgs: [surahNumber, ayahNumber],
      orderBy: 'raw_word_number ASC',
    );
  }

  Future<List<Map<String, Object?>>> getWordWindow({
    required int fromWordNumberAll,
    required int toWordNumberAll,
    bool includeAyahMarkers = false,
  }) async {
    await init();
    final whereBuffer = StringBuffer(
      'word_number_all >= ? AND word_number_all <= ?',
    );
    final whereArgs = <Object?>[fromWordNumberAll, toWordNumberAll];
    if (!includeAyahMarkers) {
      whereBuffer.write(' AND is_ayah_marker = 0');
    }

    return db.query(
      'display_words',
      where: whereBuffer.toString(),
      whereArgs: whereArgs,
      orderBy: 'word_number_all ASC',
    );
  }

  Future<Map<String, Object?>?> getNextAyah(
    int surahNumber,
    int ayahNumber,
  ) async {
    await init();
    final rows = await db.rawQuery(
      '''
        SELECT *
        FROM ayahs
        WHERE (surah_number = ? AND ayah_number > ?)
           OR surah_number > ?
        ORDER BY surah_number ASC, ayah_number ASC
        LIMIT 1
      ''',
      [surahNumber, ayahNumber, surahNumber],
    );
    return rows.isEmpty ? null : rows.first;
  }

  Future<Map<String, Object?>?> getPreviousAyah(
    int surahNumber,
    int ayahNumber,
  ) async {
    await init();
    final rows = await db.rawQuery(
      '''
        SELECT *
        FROM ayahs
        WHERE (surah_number = ? AND ayah_number < ?)
           OR surah_number < ?
        ORDER BY surah_number DESC, ayah_number DESC
        LIMIT 1
      ''',
      [surahNumber, ayahNumber, surahNumber],
    );
    return rows.isEmpty ? null : rows.first;
  }

  Future<List<Map<String, Object?>>> searchAyahCandidates(
    String transcript, {
    int limit = 5,
  }) async {
    await init();
    final tokens = _candidateTokens(transcript);
    if (tokens.isEmpty) return const [];

    final scoreTerms = <String>[];
    final scoreArgs = <Object?>[];
    final whereClauses = <String>[];
    final whereArgs = <Object?>[];
    for (final token in tokens) {
      scoreTerms.add('CASE WHEN ayahs.search_text LIKE ? THEN 1 ELSE 0 END');
      scoreArgs.add('%$token%');
      whereClauses.add('ayahs.search_text LIKE ?');
      whereArgs.add('%$token%');
    }

    final scoreExpr = scoreTerms.join(' + ');
    final whereExpr = whereClauses.join(' OR ');
    final minHits = _minimumCandidateHits(tokens.length);
    final fetchLimit = math.max(limit * 8, 30);

    return db.rawQuery(
      '''
        SELECT
          ayahs.id AS ayah_id,
          ayahs.surah_number,
          ayahs.ayah_number,
          ayahs.surah_name_ar,
          ayahs.page_number,
          ayahs.search_text,
          ($scoreExpr) AS rank,
          ($scoreExpr) AS token_hits
        FROM ayahs
        WHERE ($whereExpr)
          AND ($scoreExpr) >= ?
        ORDER BY token_hits DESC, ayahs.word_count ASC, ayahs.surah_number ASC, ayahs.ayah_number ASC
        LIMIT ?
      ''',
      [
        ...scoreArgs,
        ...scoreArgs,
        ...whereArgs,
        ...scoreArgs,
        minHits,
        fetchLimit
      ],
    );
  }

  /// Ayahs the user is reading *from the beginning* of this utterance: the full
  /// [search_text] of a short ayah is either the whole clip or a prefix, then
  /// more speech. Used so very short suwar (e.g. الضحى 1) are not removed by
  /// [searchAyahCandidates] when [searchAyahCandidates]'s per-token [minHits]
  /// is impossible to satisfy.
  Future<List<Map<String, Object?>>> searchAyahCandidatesBySpokenHead(
    String transcript, {
    int maxAyahWordCount = 5,
  }) async {
    await init();
    final q = ArabicNormalizer.normalizeForSearch(transcript).trim();
    if (q.isEmpty) return const [];

    return db.rawQuery(
      '''
        SELECT
          ayahs.id AS ayah_id,
          ayahs.surah_number,
          ayahs.ayah_number,
          ayahs.surah_name_ar,
          ayahs.page_number,
          ayahs.search_text,
          90 AS rank,
          90 AS token_hits
        FROM ayahs
        WHERE ayahs.word_count > 0
          AND ayahs.word_count <= ?
          AND (
            ? = ayahs.search_text
            OR ? LIKE (ayahs.search_text || ' %')
          )
        ORDER BY ayahs.word_count ASC, ayahs.surah_number ASC, ayahs.ayah_number ASC
        LIMIT 50
      ''',
      [maxAyahWordCount, q, q],
    );
  }

  /// عندما يقسّم التعرف الصوتي كلمات غريبة/مميزة أو يحرف، نبحث بـ
  /// [fuzzyRasmSimilarity] عن آيات قريبة بناءً على طول [search_text] ولا يتطابق
  /// معها البحث الرمزي (مثال: «مده هامه» و «مدهامتان»).
  Future<List<Map<String, Object?>>> searchAyahFuzzyByAsr(
    String transcript, {
    int limit = 22,
  }) async {
    await init();
    final n = ArabicNormalizer.normalizeForSearch(transcript).trim();
    if (n.isEmpty) return const [];
    var compact = n.replaceAll(' ', '');
    if (compact.length < 4) return const [];
    if (compact.length > 80) {
      compact = compact.substring(0, 80);
    }
    final plen = math.min(3, compact.length);
    final surLen = math.min(2, compact.length);
    final prefix = compact.substring(0, plen);
    final suffix = compact.substring(compact.length - surLen);
    const minSim = 0.38;
    final minL = math.max(2, compact.length - 6);
    final maxL = compact.length + 6;

    final rows = await db.rawQuery(
      '''
        SELECT
          ayahs.id AS ayah_id,
          ayahs.surah_number,
          ayahs.ayah_number,
          ayahs.surah_name_ar,
          ayahs.page_number,
          ayahs.search_text,
          0 AS rank,
          0 AS token_hits
        FROM ayahs
        WHERE length(replace(ayahs.search_text, ' ', '')) BETWEEN ? AND ?
          AND (ayahs.search_text LIKE ? OR ayahs.search_text LIKE ?)
        LIMIT 500
      ''',
      [minL, maxL, '%$prefix%', '%$suffix%'],
    );
    if (rows.isEmpty) return const [];

    final scored = <(Map<String, Object?>, double)>[];
    for (final row in rows) {
      final st = (row['search_text'] ?? '').toString();
      final tCompact = st.replaceAll(' ', '');
      final s = fuzzyRasmSimilarity(compact, tCompact);
      if (s >= minSim) {
        final m = Map<String, Object?>.from(row);
        m['fuzzy_score'] = s;
        m['rank'] = (s * 100);
        m['token_hits'] = 1;
        scored.add((m, s));
      }
    }
    scored.sort((a, b) => b.$2.compareTo(a.$2));
    return scored.take(limit).map((e) => e.$1).toList(growable: false);
  }

  Future<int> countAyahCandidates(String transcript) async {
    await init();
    final tokens = _candidateTokens(transcript);
    if (tokens.isEmpty) return 0;

    final scoreTerms = <String>[];
    final scoreArgs = <Object?>[];
    final whereClauses = <String>[];
    final whereArgs = <Object?>[];
    for (final token in tokens) {
      scoreTerms.add('CASE WHEN search_text LIKE ? THEN 1 ELSE 0 END');
      scoreArgs.add('%$token%');
      whereClauses.add('search_text LIKE ?');
      whereArgs.add('%$token%');
    }
    final scoreExpr = scoreTerms.join(' + ');
    final whereExpr = whereClauses.join(' OR ');
    final minHits = _minimumCandidateHits(tokens.length);

    final rows = await db.rawQuery(
      '''
        SELECT COUNT(*) AS total
        FROM ayahs
        WHERE ($whereExpr)
          AND ($scoreExpr) >= ?
      ''',
      [...whereArgs, ...scoreArgs, minHits],
    );
    if (rows.isEmpty) return 0;
    return (rows.first['total'] as int?) ??
        int.tryParse(rows.first['total']?.toString() ?? '') ??
        0;
  }

  List<String> _candidateTokens(String transcript) {
    final query = ArabicNormalizer.normalizeForSearch(transcript);
    if (query.isEmpty) return const [];
    return query
        .split(' ')
        .map((token) => token.trim())
        .where((token) => token.isNotEmpty)
        .take(6)
        .toList(growable: false);
  }

  int _minimumCandidateHits(int tokenCount) {
    if (tokenCount <= 1) return 1;
    if (tokenCount == 2) return 2;
    if (tokenCount <= 4) return 2;
    return 3;
  }

  Future<void> updateAyahProgress({
    required int surahNumber,
    required int ayahNumber,
    required String status,
    double? bestMatchScore,
    DateTime? memorizedAt,
    DateTime? lastReviewedAt,
  }) async {
    await init();
    final ayah = await getAyah(surahNumber, ayahNumber);
    if (ayah == null) return;

    await db.update(
      'ayah_progress',
      {
        'status': status,
        'best_match_score': bestMatchScore,
        'memorized_at': memorizedAt?.toUtc().toIso8601String(),
        'last_reviewed_at': lastReviewedAt?.toUtc().toIso8601String(),
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      },
      where: 'ayah_id = ?',
      whereArgs: [ayah['id']],
    );
  }

  Future<Map<String, Object?>> getOverallProgress() async {
    await init();
    final rows = await db.rawQuery(
      '''
        SELECT
          COUNT(*) AS total_ayahs,
          SUM(CASE WHEN status = 'memorized' THEN 1 ELSE 0 END) AS memorized_ayahs,
          SUM(CASE WHEN status = 'review' THEN 1 ELSE 0 END) AS review_ayahs,
          SUM(CASE WHEN status = 'weak' THEN 1 ELSE 0 END) AS weak_ayahs
        FROM ayah_progress
      ''',
    );

    return rows.first;
  }

  Future<Map<String, Object?>> getSurahProgress(int surahNumber) async {
    await init();
    final rows = await db.rawQuery(
      '''
        SELECT
          surah_number,
          COUNT(*) AS total_ayahs,
          SUM(CASE WHEN status = 'memorized' THEN 1 ELSE 0 END) AS memorized_ayahs,
          SUM(CASE WHEN status = 'review' THEN 1 ELSE 0 END) AS review_ayahs,
          SUM(CASE WHEN status = 'weak' THEN 1 ELSE 0 END) AS weak_ayahs
        FROM ayah_progress
        WHERE surah_number = ?
      ''',
      [surahNumber],
    );

    return rows.first;
  }

  Future<int> startRecitationSession({
    required int startSurah,
    required int startAyah,
    required int lastWordNumberAll,
    String platform = 'mobile',
  }) async {
    await init();
    final now = DateTime.now().toUtc().toIso8601String();
    final cols = await _tableColumns('recitation_sessions');
    final row = <String, Object?>{};
    if (cols.contains('started_at')) row['started_at'] = now;
    if (cols.contains('platform')) row['platform'] = platform;
    if (cols.contains('status')) row['status'] = 'active';
    if (cols.contains('created_at')) row['created_at'] = now;
    if (cols.contains('start_surah')) row['start_surah'] = startSurah;
    if (cols.contains('start_ayah')) row['start_ayah'] = startAyah;
    if (cols.contains('last_surah')) row['last_surah'] = startSurah;
    if (cols.contains('last_ayah')) row['last_ayah'] = startAyah;
    if (cols.contains('last_word_number_all')) {
      row['last_word_number_all'] = lastWordNumberAll;
    }
    if (cols.contains('surah_start')) row['surah_start'] = startSurah;
    if (cols.contains('ayah_start')) row['ayah_start'] = startAyah;
    if (cols.contains('surah_end')) row['surah_end'] = startSurah;
    if (cols.contains('ayah_end')) row['ayah_end'] = startAyah;
    if (cols.contains('total_words')) row['total_words'] = 0;
    if (cols.contains('correct_words')) row['correct_words'] = 0;
    if (cols.contains('wrong_words')) row['wrong_words'] = 0;
    if (cols.contains('matched_words')) row['matched_words'] = 0;
    if (cols.contains('source')) row['source'] = 'native_stt';
    if (cols.contains('updated_at')) row['updated_at'] = now;
    final id = await db.insert('recitation_sessions', row);
    await db.insert(
      'recitation_state',
      {
        'id': 1,
        'current_session_id': id,
        'last_surah': startSurah,
        'last_ayah': startAyah,
        'last_word_number_all': lastWordNumberAll,
        'updated_at': now,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    return id;
  }

  Future<void> endRecitationSession(int sessionId) async {
    await init();
    final now = DateTime.now().toUtc().toIso8601String();
    final cols = await _tableColumns('recitation_sessions');
    final data = <String, Object?>{};
    if (cols.contains('ended_at')) data['ended_at'] = now;
    if (cols.contains('status')) data['status'] = 'completed';
    if (cols.contains('updated_at')) data['updated_at'] = now;
    if (data.isNotEmpty) {
      await db.update(
        'recitation_sessions',
        data,
        where: 'id = ?',
        whereArgs: [sessionId],
      );
    }
    await db.update(
      'recitation_state',
      {'current_session_id': null, 'updated_at': now},
      where: 'id = 1',
    );
  }

  Future<void> upsertRecitationState({
    int? sessionId,
    required int surahNumber,
    required int ayahNumber,
    required int lastWordNumberAll,
  }) async {
    await init();
    final now = DateTime.now().toUtc().toIso8601String();
    await db.insert(
      'recitation_state',
      {
        'id': 1,
        'current_session_id': sessionId,
        'last_surah': surahNumber,
        'last_ayah': ayahNumber,
        'last_word_number_all': lastWordNumberAll,
        'updated_at': now,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> updateSessionProgress({
    required int sessionId,
    required int surahNumber,
    required int ayahNumber,
    required int pointerWordNumberAll,
    required int totalWordsDelta,
    required int correctWordsDelta,
    required int wrongWordsDelta,
  }) async {
    await init();
    final now = DateTime.now().toUtc().toIso8601String();
    await db.rawUpdate(
      '''
      UPDATE recitation_sessions
      SET
        last_surah = ?,
        last_ayah = ?,
        last_word_number_all = ?,
        total_words = total_words + ?,
        correct_words = correct_words + ?,
        wrong_words = wrong_words + ?,
        updated_at = ?
      WHERE id = ?
      ''',
      [
        surahNumber,
        ayahNumber,
        pointerWordNumberAll,
        totalWordsDelta,
        correctWordsDelta,
        wrongWordsDelta,
        now,
        sessionId,
      ],
    );
  }

  Future<void> upsertAyahRecitationStats({
    required int surahNumber,
    required int ayahNumber,
    required int totalWords,
    required int correctWords,
    required int wrongWords,
    required double? lastScore,
    required String lastStatus,
    required String lastErrorWordIdsJson,
    bool incrementAttempts = true,
  }) async {
    await init();
    final now = DateTime.now().toUtc().toIso8601String();
    final existing = await db.query(
      'recitation_ayah_stats',
      columns: ['id', 'total_attempts'],
      where: 'surah_number = ? AND ayah_number = ?',
      whereArgs: [surahNumber, ayahNumber],
      limit: 1,
    );
    if (existing.isEmpty) {
      await db.insert('recitation_ayah_stats', {
        'surah_number': surahNumber,
        'ayah_number': ayahNumber,
        'total_attempts': incrementAttempts ? 1 : 0,
        'total_words': totalWords,
        'correct_words': correctWords,
        'wrong_words': wrongWords,
        'last_score': lastScore,
        'last_status': lastStatus,
        'last_error_word_ids': lastErrorWordIdsJson,
        'updated_at': now,
      });
      return;
    }
    final prevAttempts = (existing.first['total_attempts'] as int?) ?? 0;
    await db.update(
      'recitation_ayah_stats',
      {
        'total_attempts': incrementAttempts ? prevAttempts + 1 : prevAttempts,
        'total_words': totalWords,
        'correct_words': correctWords,
        'wrong_words': wrongWords,
        'last_score': lastScore,
        'last_status': lastStatus,
        'last_error_word_ids': lastErrorWordIdsJson,
        'updated_at': now,
      },
      where: 'id = ?',
      whereArgs: [existing.first['id']],
    );
  }

  Future<Map<String, Object?>?> getRecitationState() async {
    await init();
    final rows = await db.query('recitation_state', where: 'id = 1', limit: 1);
    return rows.isEmpty ? null : rows.first;
  }

  Future<List<Map<String, Object?>>> getAyahsForSurah(int surahNumber) async {
    await init();
    return db.query(
      'ayahs',
      where: 'surah_number = ?',
      whereArgs: [surahNumber],
      orderBy: 'ayah_number ASC',
    );
  }

  Future<Map<int, Set<int>>> getErrorWordIdsByAyahForSurah(
      int surahNumber) async {
    await init();
    final rows = await db.query(
      'recitation_ayah_stats',
      columns: ['ayah_number', 'last_error_word_ids'],
      where: 'surah_number = ?',
      whereArgs: [surahNumber],
    );
    final out = <int, Set<int>>{};
    for (final row in rows) {
      final ayah = (row['ayah_number'] as int?) ?? 0;
      if (ayah <= 0) continue;
      final raw = (row['last_error_word_ids'] ?? '').toString().trim();
      if (raw.isEmpty) {
        out[ayah] = <int>{};
        continue;
      }
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          final ids = decoded
              .map((e) => int.tryParse(e.toString()) ?? 0)
              .where((e) => e > 0)
              .toSet();
          out[ayah] = ids;
        }
      } catch (_) {
        out[ayah] = <int>{};
      }
    }
    return out;
  }

  Future<Map<int, Map<String, Object?>>> getAyahStatsBySurah(
      int surahNumber) async {
    await init();
    final rows = await db.query(
      'recitation_ayah_stats',
      columns: [
        'ayah_number',
        'total_attempts',
        'total_words',
        'correct_words',
        'wrong_words',
        'last_status',
        'updated_at',
      ],
      where: 'surah_number = ?',
      whereArgs: [surahNumber],
    );
    final out = <int, Map<String, Object?>>{};
    for (final row in rows) {
      final ayah = (row['ayah_number'] as int?) ?? 0;
      if (ayah <= 0) continue;
      out[ayah] = Map<String, Object?>.from(row);
    }
    return out;
  }

  Future<Map<int, Map<String, int>>> getSurahReviewSummaries() async {
    await init();
    final rows = await db.rawQuery(
      '''
      SELECT
        surah_number,
        COUNT(*) AS read_ayahs,
        SUM(CASE WHEN wrong_words > 0 THEN 1 ELSE 0 END) AS error_ayahs,
        SUM(wrong_words) AS error_words
      FROM (
        SELECT
          surah_number,
          ayah_number,
          MAX(wrong_words) AS wrong_words
        FROM recitation_ayah_stats
        WHERE total_words > 0 OR total_attempts > 0
        GROUP BY surah_number, ayah_number
      ) grouped
      GROUP BY surah_number
      ''',
    );
    final out = <int, Map<String, int>>{};
    for (final row in rows) {
      final surah = (row['surah_number'] as int?) ??
          int.tryParse('${row['surah_number']}') ??
          0;
      if (surah <= 0) continue;
      out[surah] = {
        'read_ayahs': (row['read_ayahs'] as int?) ??
            int.tryParse('${row['read_ayahs']}') ??
            0,
        'error_ayahs': (row['error_ayahs'] as int?) ??
            int.tryParse('${row['error_ayahs']}') ??
            0,
        'error_words': (row['error_words'] as int?) ??
            int.tryParse('${row['error_words']}') ??
            0,
      };
    }
    return out;
  }

  Future<List<Map<String, Object?>>> getAyahsOnPageOrdered(
    int pageNumber,
  ) async {
    await init();
    return db.query(
      'ayahs',
      where: 'page_number = ?',
      whereArgs: [pageNumber],
      orderBy: 'id ASC',
    );
  }

  Future<Map<String, Object?>?> getAyahStatsRow(
    int surahNumber,
    int ayahNumber,
  ) async {
    await init();
    final rows = await db.query(
      'recitation_ayah_stats',
      where: 'surah_number = ? AND ayah_number = ?',
      whereArgs: [surahNumber, ayahNumber],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first;
  }

  Future<List<Map<String, Object?>>> getReadAyahStatsRowsForSurah(
    int surahNumber,
  ) async {
    await init();
    final rows = await db.query(
      'recitation_ayah_stats',
      columns: [
        'ayah_number',
        'total_attempts',
        'total_words',
        'wrong_words',
        'last_error_word_ids',
        'updated_at',
      ],
      where: 'surah_number = ? AND (total_words > 0 OR total_attempts > 0)',
      whereArgs: [surahNumber],
      orderBy: 'updated_at DESC',
    );
    final byAyah = <int, Map<String, Object?>>{};
    for (final row in rows) {
      final ayah = (row['ayah_number'] as int?) ?? 0;
      if (ayah <= 0 || byAyah.containsKey(ayah)) continue;
      byAyah[ayah] = row;
    }
    final deduped = byAyah.values.toList()
      ..sort((a, b) {
        final aa = (a['ayah_number'] as int?) ?? 0;
        final bb = (b['ayah_number'] as int?) ?? 0;
        return aa.compareTo(bb);
      });
    return deduped;
  }
}
