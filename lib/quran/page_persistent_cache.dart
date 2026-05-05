import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show compute;
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

import 'package:quran_app/quran/models/mushaf_line.dart';
import 'package:quran_app/quran/page_cache.dart';

/// تخزين دائم لصفحات المصحف على القرص.
/// يحفظ الصفحات المحملة في مجلد التطبيق لتبقى بعد الإغلاق.
class PagePersistentCache {
  PagePersistentCache._();
  static final PagePersistentCache instance = PagePersistentCache._();

  static const String _cacheDirName = 'mushaf_cache';
  String? _basePath;

  /// طلبات متزامنة لنفس (mode, page) تشترك في نفس [Future] لتفادي قراءة القرص مرتين.
  final Map<String, Future<List<MushafPageLine>?>> _rawGetInFlight = {};

  Future<String> get _baseDir async {
    _basePath ??= p.join(
      (await getApplicationDocumentsDirectory()).path,
      _cacheDirName,
    );
    return _basePath!;
  }

  String _pagePath(String mode, int page) {
    return p.join(_basePath ?? '', mode, 'page_${page.toString().padLeft(3, '0')}.json');
  }

  Future<String> _ensureDir(String mode) async {
    final base = await _baseDir;
    final dir = p.join(base, mode);
    await Directory(dir).create(recursive: true);
    return dir;
  }

  /// حفظ صفحة في التخزين الدائم.
  Future<void> put(String mode, int page, List<MushafPageLine> lines) async {
    try {
      await _ensureDir(mode);
      final path = _pagePath(mode, page);
      final json = jsonEncode(lines.map((l) => l.toJson()).toList());
      await File(path).writeAsString(json);
    } catch (_) {}
  }

  static String _rawKey(String mode, int page) => '${mode}_$page';

  static bool _qpc1LinesOkForRamHydrate(List<MushafPageLine> lines) {
    return lines.isNotEmpty &&
        lines.every((l) =>
            l.lineType != 'ayah' ||
            l.rangeStart == null ||
            (l.ayahSegments != null && l.ayahSegments!.isNotEmpty));
  }

  /// تحميل صفحة من التخزين الدائم (مع دمج الطلبات المتزامنة لنفس المفتاح).
  Future<List<MushafPageLine>?> get(String mode, int page) {
    final key = _rawKey(mode, page);
    final pending = _rawGetInFlight[key];
    if (pending != null) return pending;
    final fut = _readRawPageFile(mode, page).whenComplete(() {
      _rawGetInFlight.remove(key);
    });
    _rawGetInFlight[key] = fut;
    return fut;
  }

  Future<List<MushafPageLine>?> _readRawPageFile(String mode, int page) async {
    try {
      await _baseDir;
      final path = _pagePath(mode, page);
      final file = File(path);
      if (!await file.exists()) return null;
      final raw = await file.readAsString();
      return compute(_decodeMushafLinesFromJson, raw);
    } catch (_) {
      return null;
    }
  }

  /// تعبئة [PageCache] من القرص لنافذة حول [centerPage] (صفحتان قبل وبعد).
  Future<void> hydrateRamWindow({
    required String mode,
    required int centerPage,
    int before = PageCache.cacheWindowBefore,
    int after = PageCache.cacheWindowAfter,
    int totalPages = 604,
  }) async {
    await _baseDir;
    for (var pg = centerPage - before; pg <= centerPage + after; pg++) {
      if (pg < 1 || pg > totalPages) continue;
      if (PageCache.instance.has(mode, pg)) continue;
      final lines = await get(mode, pg);
      if (lines == null || lines.isEmpty) continue;
      if (mode == 'qpc1' && !_qpc1LinesOkForRamHydrate(lines)) continue;
      PageCache.instance.put(mode, pg, lines);
    }
  }

  /// هل الصفحة موجودة في التخزين الدائم؟
  Future<bool> has(String mode, int page) async {
    try {
      await _baseDir;
      return await File(_pagePath(mode, page)).exists();
    } catch (_) {
      return false;
    }
  }

  /// عدد الصفحات المحفوظة لوضع معيّن.
  Future<int> getPageCountForMode(String mode) async {
    try {
      final dir = Directory(p.join(await _baseDir, mode));
      if (!await dir.exists()) return 0;
      int count = 0;
      await for (final e in dir.list()) {
        if (e.path.endsWith('.json')) count++;
      }
      return count;
    } catch (_) {
      return 0;
    }
  }

  /// إجمالي عدد الصفحات المحفوظة.
  Future<int> get totalPersistedCount async {
    try {
      final base = Directory(await _baseDir);
      if (!await base.exists()) return 0;
      int count = 0;
      await for (final entity in base.list()) {
        if (entity is Directory) {
          await for (final e in entity.list()) {
            if (e.path.endsWith('.json')) count++;
          }
        }
      }
      return count;
    } catch (_) {
      return 0;
    }
  }

  /// حجم الملفات المحفوظة (بالبايت).
  Future<int> get totalSizeBytes async {
    try {
      final base = Directory(await _baseDir);
      if (!await base.exists()) return 0;
      int total = 0;
      await for (final entity in base.list(recursive: true)) {
        if (entity is File) {
          total += await entity.length();
        }
      }
      return total;
    } catch (_) {
      return 0;
    }
  }

  /// مسح جميع الصفحات لوضع معيّن.
  Future<void> clearMode(String mode) async {
    try {
      final dir = Directory(p.join(await _baseDir, mode));
      if (await dir.exists()) {
        await for (final entity in dir.list()) {
          if (entity is File) await entity.delete();
        }
      }
    } catch (_) {}
  }
}

List<MushafPageLine> _decodeMushafLinesFromJson(String raw) {
  final json = jsonDecode(raw) as List;
  return json
      .map((e) => MushafPageLine.fromJson(e as Map<String, dynamic>))
      .toList();
}
