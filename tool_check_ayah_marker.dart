import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<void> main() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  final path = p.join(Directory.current.path, 'assets/database/quran-data.sqlite');
  final db = await openDatabase(path, readOnly: true);
  final cols = await db.rawQuery('PRAGMA table_info(words)');
  print('columns: ${cols.map((e) => e['name']).join(', ')}');
  final markers = await db.rawQuery(
    'SELECT COUNT(*) AS c FROM words WHERE surah_number=18 AND ayah_number BETWEEN 1 AND 8 AND is_ayah_marker=1',
  );
  print('markers surah18 ayah1-8: $markers');
  final sample = await db.query(
    'words',
    where: 'surah_number = ? AND ayah_number = ?',
    whereArgs: [18, 5],
    orderBy: 'word_number_all ASC',
  );
  for (final row in sample) {
    print(row);
  }
  await db.close();
}
