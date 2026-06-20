import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:quran_app/recitation/arabic_normalizer.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _defaultSourceDb = 'assets/database/quran-data.sqlite';
const _defaultMetadataJson = 'assets/data/hafs_smart_v8.json';
const _defaultOutputDb = 'assets/database/quran-recitation.sqlite';

Future<void> main(List<String> args) async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  final root = Directory.current.path;
  final sourceDbPath = _resolvePath(root, args, 0, _defaultSourceDb);
  final metadataJsonPath = _resolvePath(root, args, 1, _defaultMetadataJson);
  final outputDbPath = _resolvePath(root, args, 2, _defaultOutputDb);

  final sourceDbFile = File(sourceDbPath);
  final metadataFile = File(metadataJsonPath);
  final outputDbFile = File(outputDbPath);

  if (!sourceDbFile.existsSync()) {
    stderr.writeln('Source DB not found: $sourceDbPath');
    exitCode = 1;
    return;
  }

  if (!metadataFile.existsSync()) {
    stderr.writeln('Metadata JSON not found: $metadataJsonPath');
    exitCode = 1;
    return;
  }

  if (outputDbFile.existsSync()) {
    outputDbFile.deleteSync();
  }

  outputDbFile.parent.createSync(recursive: true);

  print('Loading metadata...');
  final metadata = await _loadAyahMetadata(metadataFile);

  print('Opening source database...');
  final sourceDb = await openDatabase(
    sourceDbPath,
    readOnly: true,
    singleInstance: false,
  );

  print('Creating output database...');
  final outputDb = await openDatabase(
    outputDbPath,
    version: 1,
    singleInstance: false,
    onConfigure: (db) async {
      await db.execute('PRAGMA foreign_keys = ON');
    },
    onCreate: (db, version) async {
      await _createSchema(db);
    },
  );

  try {
    final words = await sourceDb.query(
      'words',
      columns: [
        'surah_number',
        'ayah_number',
        'word_number',
        'word_number_all',
        'uthmani',
        'is_ayah_marker',
      ],
      orderBy: 'word_number_all ASC',
    );

    print('Building recitation tables from ${words.length} source rows...');
    await outputDb.transaction((txn) async {
      await _populateRecitationDb(txn, words, metadata);
    });

    print('Verifying generated database...');
    await _verify(outputDb);
    print('Done: $outputDbPath');
  } finally {
    await outputDb.close();
    await sourceDb.close();
  }
}

String _resolvePath(
  String root,
  List<String> args,
  int index,
  String fallback,
) {
  if (args.length > index && args[index].trim().isNotEmpty) {
    final candidate = args[index].trim();
    return p.isAbsolute(candidate) ? candidate : p.join(root, candidate);
  }

  return p.join(root, fallback);
}

Future<Map<String, AyahMetadata>> _loadAyahMetadata(File file) async {
  final raw = await file.readAsString();
  final decoded = jsonDecode(raw) as List<dynamic>;
  final metadata = <String, AyahMetadata>{};

  for (final item in decoded) {
    final row = item as Map<String, dynamic>;
    final surahNumber = _asInt(row['sura_no']);
    final ayahNumber = _asInt(row['aya_no']);
    final key = '$surahNumber:$ayahNumber';
    metadata[key] = AyahMetadata(
      surahNumber: surahNumber,
      ayahNumber: ayahNumber,
      surahNameAr: (row['sura_name_ar'] ?? '').toString().trim(),
      surahNameEn: (row['sura_name_en'] ?? '').toString().trim(),
      pageNumber: _asInt(row['page']),
      juzNumber: _asInt(row['jozz']),
      emlaeyText: (row['aya_text_emlaey'] ?? '').toString().trim(),
    );
  }

  return metadata;
}

Future<void> _createSchema(DatabaseExecutor db) async {
  await db.execute('''
    CREATE TABLE metadata (
      key TEXT PRIMARY KEY,
      value TEXT NOT NULL
    )
  ''');

  await db.execute('''
    CREATE TABLE surahs (
      id INTEGER PRIMARY KEY,
      name_ar TEXT NOT NULL,
      name_en TEXT NOT NULL,
      total_ayahs INTEGER NOT NULL,
      first_page INTEGER,
      juz_number INTEGER
    )
  ''');

  await db.execute('''
    CREATE TABLE ayahs (
      id INTEGER PRIMARY KEY,
      surah_number INTEGER NOT NULL,
      ayah_number INTEGER NOT NULL,
      surah_name_ar TEXT NOT NULL,
      surah_name_en TEXT NOT NULL,
      juz_number INTEGER,
      page_number INTEGER,
      first_word_number_all INTEGER NOT NULL,
      last_word_number_all INTEGER NOT NULL,
      word_count INTEGER NOT NULL,
      uthmani_text TEXT NOT NULL,
      emlaey_text TEXT NOT NULL,
      normalized_text TEXT NOT NULL,
      search_text TEXT NOT NULL,
      UNIQUE (surah_number, ayah_number)
    )
  ''');

  await db.execute('''
    CREATE TABLE display_words (
      id INTEGER PRIMARY KEY,
      ayah_id INTEGER NOT NULL,
      surah_number INTEGER NOT NULL,
      ayah_number INTEGER NOT NULL,
      raw_word_number INTEGER NOT NULL,
      word_position INTEGER NOT NULL,
      word_number_all INTEGER NOT NULL,
      location_key TEXT NOT NULL,
      display_text TEXT NOT NULL,
      normalized_text TEXT NOT NULL,
      search_key TEXT NOT NULL,
      is_ayah_marker INTEGER NOT NULL DEFAULT 0,
      FOREIGN KEY (ayah_id) REFERENCES ayahs(id) ON DELETE CASCADE,
      UNIQUE (word_number_all)
    )
  ''');

  await db.execute('''
    CREATE TABLE normalized_words (
      id INTEGER PRIMARY KEY,
      display_word_id INTEGER NOT NULL,
      ayah_id INTEGER NOT NULL,
      surah_number INTEGER NOT NULL,
      ayah_number INTEGER NOT NULL,
      word_position INTEGER NOT NULL,
      original_text TEXT NOT NULL,
      normalized_text TEXT NOT NULL,
      search_key TEXT NOT NULL,
      FOREIGN KEY (display_word_id) REFERENCES display_words(id) ON DELETE CASCADE,
      FOREIGN KEY (ayah_id) REFERENCES ayahs(id) ON DELETE CASCADE
    )
  ''');

  await db.execute('''
    CREATE VIRTUAL TABLE ayahs_fts USING fts5(
      search_text,
      surah_number UNINDEXED,
      ayah_number UNINDEXED,
      tokenize = 'unicode61'
    )
  ''');

  await db.execute('''
    CREATE TABLE ayah_progress (
      ayah_id INTEGER PRIMARY KEY,
      surah_number INTEGER NOT NULL,
      ayah_number INTEGER NOT NULL,
      status TEXT NOT NULL DEFAULT 'untracked',
      completion_count INTEGER NOT NULL DEFAULT 0,
      best_match_score REAL,
      memorized_at TEXT,
      last_reviewed_at TEXT,
      updated_at TEXT NOT NULL,
      FOREIGN KEY (ayah_id) REFERENCES ayahs(id) ON DELETE CASCADE
    )
  ''');

  await db.execute('''
    CREATE TABLE memorization_ranges (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      surah_start INTEGER NOT NULL,
      ayah_start INTEGER NOT NULL,
      surah_end INTEGER NOT NULL,
      ayah_end INTEGER NOT NULL,
      status TEXT NOT NULL DEFAULT 'memorized',
      source TEXT NOT NULL DEFAULT 'manual',
      notes TEXT,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    )
  ''');

  await db.execute('''
    CREATE TABLE recitation_sessions (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      started_at TEXT NOT NULL,
      ended_at TEXT,
      surah_start INTEGER,
      ayah_start INTEGER,
      surah_end INTEGER,
      ayah_end INTEGER,
      matched_words INTEGER NOT NULL DEFAULT 0,
      total_words INTEGER NOT NULL DEFAULT 0,
      average_confidence REAL,
      source TEXT NOT NULL DEFAULT 'native_stt',
      created_at TEXT NOT NULL
    )
  ''');

  await db.execute(
    'CREATE INDEX idx_ayahs_ref ON ayahs(surah_number, ayah_number)',
  );
  await db.execute(
    'CREATE INDEX idx_display_words_ayah_pos ON display_words(ayah_id, word_position)',
  );
  await db.execute(
    'CREATE INDEX idx_display_words_ref_pos ON display_words(surah_number, ayah_number, word_position)',
  );
  await db.execute(
    'CREATE INDEX idx_display_words_location ON display_words(location_key)',
  );
  await db.execute(
    'CREATE INDEX idx_normalized_words_lookup ON normalized_words(search_key)',
  );
  await db.execute(
    'CREATE INDEX idx_progress_status ON ayah_progress(status, surah_number, ayah_number)',
  );
}

Future<void> _populateRecitationDb(
  DatabaseExecutor db,
  List<Map<String, Object?>> words,
  Map<String, AyahMetadata> metadata,
) async {
  final generatedAt = DateTime.now().toUtc().toIso8601String();
  await db.insert('metadata', {'key': 'schema_version', 'value': '1'});
  await db.insert('metadata', {'key': 'generated_at', 'value': generatedAt});
  await db.insert('metadata', {'key': 'source', 'value': _defaultSourceDb});

  final surahStats = <int, SurahAggregate>{};

  final batch = _ChunkedBatch(db);
  var nextAyahId = 1;
  var nextDisplayWordId = 1;
  var nextNormalizedWordId = 1;

  List<_SourceWord> currentAyahWords = [];
  int? currentSurah;
  int? currentAyah;

  Future<void> flushCurrentAyah() async {
    if (currentAyahWords.isEmpty ||
        currentSurah == null ||
        currentAyah == null) {
      return;
    }

    final key = '$currentSurah:$currentAyah';
    final ayahMeta = metadata[key];
    final spokenWords =
        currentAyahWords.where((word) => !word.isAyahMarker).toList();
    if (spokenWords.isEmpty) {
      currentAyahWords = [];
      return;
    }

    final firstWordNumberAll = spokenWords.first.wordNumberAll;
    final lastWordNumberAll = spokenWords.last.wordNumberAll;
    final uthmaniText = spokenWords.map((word) => word.text).join(' ').trim();
    final emlaeyText = (ayahMeta?.emlaeyText.isNotEmpty ?? false)
        ? ayahMeta!.emlaeyText
        : uthmaniText;
    final normalizedText = ArabicNormalizer.normalizeBasic(emlaeyText);
    final searchText = ArabicNormalizer.normalizeForSearch(emlaeyText);
    final ayahId = nextAyahId++;
    final timestamp = DateTime.now().toUtc().toIso8601String();

    batch.insert('ayahs', {
      'id': ayahId,
      'surah_number': currentSurah,
      'ayah_number': currentAyah,
      'surah_name_ar': ayahMeta?.surahNameAr ?? '',
      'surah_name_en': ayahMeta?.surahNameEn ?? '',
      'juz_number': ayahMeta?.juzNumber,
      'page_number': ayahMeta?.pageNumber,
      'first_word_number_all': firstWordNumberAll,
      'last_word_number_all': lastWordNumberAll,
      'word_count': spokenWords.length,
      'uthmani_text': uthmaniText,
      'emlaey_text': emlaeyText,
      'normalized_text': normalizedText,
      'search_text': searchText,
    });

    batch.insert('ayah_progress', {
      'ayah_id': ayahId,
      'surah_number': currentSurah,
      'ayah_number': currentAyah,
      'status': 'untracked',
      'completion_count': 0,
      'best_match_score': null,
      'memorized_at': null,
      'last_reviewed_at': null,
      'updated_at': timestamp,
    });

    batch.insert('ayahs_fts', {
      'rowid': ayahId,
      'search_text': searchText,
      'surah_number': currentSurah,
      'ayah_number': currentAyah,
    });

    final aggregate = surahStats.putIfAbsent(
      currentSurah,
      () => SurahAggregate(
        id: currentSurah!,
        nameAr: ayahMeta?.surahNameAr ?? '',
        nameEn: ayahMeta?.surahNameEn ?? '',
        firstPage: ayahMeta?.pageNumber,
        juzNumber: ayahMeta?.juzNumber,
      ),
    );
    aggregate.totalAyahs += 1;
    aggregate.firstPage =
        _minNullable(aggregate.firstPage, ayahMeta?.pageNumber);

    var spokenPosition = 0;
    for (final sourceWord in currentAyahWords) {
      final isAyahMarker = sourceWord.isAyahMarker;
      final wordPosition = isAyahMarker ? 0 : ++spokenPosition;
      final displayWordId = nextDisplayWordId++;
      final normalizedWord = ArabicNormalizer.normalizeBasic(sourceWord.text);
      final searchKey = ArabicNormalizer.normalizeForSearch(sourceWord.text);

      batch.insert('display_words', {
        'id': displayWordId,
        'ayah_id': ayahId,
        'surah_number': sourceWord.surahNumber,
        'ayah_number': sourceWord.ayahNumber,
        'raw_word_number': sourceWord.wordNumber,
        'word_position': wordPosition,
        'word_number_all': sourceWord.wordNumberAll,
        'location_key':
            '${sourceWord.surahNumber}:${sourceWord.ayahNumber}:${sourceWord.wordNumber}',
        'display_text': sourceWord.text,
        'normalized_text': normalizedWord,
        'search_key': searchKey,
        'is_ayah_marker': isAyahMarker ? 1 : 0,
      });

      if (!isAyahMarker) {
        batch.insert('normalized_words', {
          'id': nextNormalizedWordId++,
          'display_word_id': displayWordId,
          'ayah_id': ayahId,
          'surah_number': sourceWord.surahNumber,
          'ayah_number': sourceWord.ayahNumber,
          'word_position': wordPosition,
          'original_text': sourceWord.text,
          'normalized_text': normalizedWord,
          'search_key': searchKey,
        });
      }
    }

    currentAyahWords = [];
    await batch.flushIfNeeded();
  }

  for (final row in words) {
    final sourceWord = _SourceWord(
      surahNumber: _asInt(row['surah_number']),
      ayahNumber: _asInt(row['ayah_number']),
      wordNumber: _asInt(row['word_number']),
      wordNumberAll: _asInt(row['word_number_all']),
      text: (row['uthmani'] ?? '').toString().trim(),
      isAyahMarker: _asBool(row['is_ayah_marker']),
    );

    final isSameAyah = currentSurah == sourceWord.surahNumber &&
        currentAyah == sourceWord.ayahNumber;
    if (!isSameAyah) {
      await flushCurrentAyah();
      currentSurah = sourceWord.surahNumber;
      currentAyah = sourceWord.ayahNumber;
    }

    currentAyahWords.add(sourceWord);
  }

  await flushCurrentAyah();

  for (final surahNumber in surahStats.keys.toList()..sort()) {
    final aggregate = surahStats[surahNumber]!;
    batch.insert('surahs', {
      'id': aggregate.id,
      'name_ar': aggregate.nameAr,
      'name_en': aggregate.nameEn,
      'total_ayahs': aggregate.totalAyahs,
      'first_page': aggregate.firstPage,
      'juz_number': aggregate.juzNumber,
    });
  }

  await batch.flush();
}

Future<void> _verify(Database db) async {
  final surahs =
      _firstInt(await db.rawQuery('SELECT COUNT(*) AS value FROM surahs'));
  final ayahs =
      _firstInt(await db.rawQuery('SELECT COUNT(*) AS value FROM ayahs'));
  final displayWords = _firstInt(
      await db.rawQuery('SELECT COUNT(*) AS value FROM display_words'));
  final normalizedWords = _firstInt(
      await db.rawQuery('SELECT COUNT(*) AS value FROM normalized_words'));

  final searchProbe = await db.rawQuery(
    '''
      SELECT surah_number, ayah_number, bm25(ayahs_fts) AS rank
      FROM ayahs_fts
      WHERE ayahs_fts MATCH ?
      ORDER BY rank
      LIMIT 3
    ''',
    ['الحمد'],
  );

  print('Surahs: $surahs');
  print('Ayahs: $ayahs');
  print('Display words: $displayWords');
  print('Normalized words: $normalizedWords');
  print('FTS probe rows: ${searchProbe.length}');
}

int _firstInt(List<Map<String, Object?>> rows) {
  if (rows.isEmpty) return 0;
  final value = rows.first['value'];
  return _asInt(value);
}

int _asInt(Object? value, {int fallback = 0}) {
  if (value == null) return fallback;
  if (value is int) return value;
  return int.tryParse(value.toString()) ?? fallback;
}

bool _asBool(Object? value) {
  if (value == null) return false;
  if (value is bool) return value;
  final normalized = value.toString().trim().toLowerCase();
  return normalized == '1' || normalized == 'true';
}

int? _minNullable(int? left, int? right) {
  if (left == null) return right;
  if (right == null) return left;
  return left < right ? left : right;
}

class AyahMetadata {
  const AyahMetadata({
    required this.surahNumber,
    required this.ayahNumber,
    required this.surahNameAr,
    required this.surahNameEn,
    required this.pageNumber,
    required this.juzNumber,
    required this.emlaeyText,
  });

  final int surahNumber;
  final int ayahNumber;
  final String surahNameAr;
  final String surahNameEn;
  final int pageNumber;
  final int juzNumber;
  final String emlaeyText;
}

class SurahAggregate {
  SurahAggregate({
    required this.id,
    required this.nameAr,
    required this.nameEn,
    required this.firstPage,
    required this.juzNumber,
  });

  final int id;
  final String nameAr;
  final String nameEn;
  int totalAyahs = 0;
  int? firstPage;
  final int? juzNumber;
}

class _SourceWord {
  const _SourceWord({
    required this.surahNumber,
    required this.ayahNumber,
    required this.wordNumber,
    required this.wordNumberAll,
    required this.text,
    required this.isAyahMarker,
  });

  final int surahNumber;
  final int ayahNumber;
  final int wordNumber;
  final int wordNumberAll;
  final String text;
  final bool isAyahMarker;
}

class _ChunkedBatch {
  _ChunkedBatch(this._db);

  final DatabaseExecutor _db;
  static const int _chunkSize = 1000;
  Batch? _batch;
  int _pendingCount = 0;

  void insert(String table, Map<String, Object?> values) {
    _ensureBatch().insert(table, values);
    _pendingCount += 1;
  }

  Future<void> flushIfNeeded() async {
    if (_pendingCount >= _chunkSize) {
      await flush();
    }
  }

  Future<void> flush() async {
    if (_pendingCount == 0 || _batch == null) return;
    await _batch!.commit(noResult: true, continueOnError: false);
    _batch = null;
    _pendingCount = 0;
  }

  Batch _ensureBatch() {
    _batch ??= (_db as dynamic).batch() as Batch;
    return _batch!;
  }
}
