import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

/// قاعدة غليف QPC V4 فقط (qpc-v4.db) — للقارئ QPC V1/V4/V4 أسود.
/// سينجلتون حتى تُفتح الاتصال مرة واحدة.
class QpcGlyphDb {
  QpcGlyphDb._();
  static final QpcGlyphDb instance = QpcGlyphDb._();

  static const String _assetPath = 'assets/database/qpc-v4.db';
  static const String _fileName = 'qpc_v4.db';

  Database? _db;

  Database get db {
    if (_db == null) throw StateError('QpcGlyphDb not initialized. Call init() first.');
    return _db!;
  }

  Future<void> init() async {
    if (_db != null) return;

    final appDir = await getApplicationDocumentsDirectory();
    final dirPath = p.join(appDir.path, 'database');
    final filePath = p.join(dirPath, _fileName);

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
}
