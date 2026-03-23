import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

import 'package:quran_app/quran/models/baked_page_layout.dart';
import 'package:quran_app/quran/models/mushaf_line.dart';

/// تخزين دائم لصفحات المصحف في ROM.
/// يحفظ الصفحات المحملة في مجلد التطبيق لتبقى بعد الإغلاق.
class PagePersistentCache {
  PagePersistentCache._();
  static final PagePersistentCache instance = PagePersistentCache._();

  static const String _cacheDirName = 'mushaf_cache';
  String? _basePath;

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

  String _bakedPagePath(String mode, int page) {
    return p.join(_basePath ?? '', '${mode}_baked', 'page_${page.toString().padLeft(3, '0')}.json');
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

  /// تحميل تخطيط محسوب مسبقاً من التخزين الدائم.
  Future<BakedPageLayout?> getBaked(String mode, int page) async {
    try {
      await _baseDir;
      final path = _bakedPagePath(mode, page);
      final file = File(path);
      if (!await file.exists()) return null;
      final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      return BakedPageLayout.fromJson(json);
    } catch (_) {
      return null;
    }
  }

  /// حفظ تخطيط محسوب مسبقاً في التخزين الدائم.
  Future<void> putBaked(String mode, int page, BakedPageLayout baked) async {
    try {
      await _ensureDir('${mode}_baked');
      final path = _bakedPagePath(mode, page);
      await File(path).writeAsString(jsonEncode(baked.toJson()));
    } catch (_) {}
  }

  /// هل التخطيط المحسوب موجود؟
  Future<bool> hasBaked(String mode, int page) async {
    try {
      await _baseDir;
      return await File(_bakedPagePath(mode, page)).exists();
    } catch (_) {
      return false;
    }
  }

  /// عدد الصفحات المحسوبة مسبقاً لوضع معيّن.
  Future<int> getBakedPageCountForMode(String mode) async {
    try {
      final dir = Directory(p.join(await _baseDir, '${mode}_baked'));
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

  /// تحميل صفحة من التخزين الدائم.
  Future<List<MushafPageLine>?> get(String mode, int page) async {
    try {
      await _baseDir;
      final path = _pagePath(mode, page);
      final file = File(path);
      if (!await file.exists()) return null;
      final json = jsonDecode(await file.readAsString()) as List;
      return json.map((e) => MushafPageLine.fromJson(e as Map<String, dynamic>)).toList();
    } catch (_) {
      return null;
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

  /// مسح جميع الصفحات لوضع معيّن (خيار أ: عند تغيير النسخة).
  Future<void> clearMode(String mode) async {
    try {
      final dir = Directory(p.join(await _baseDir, mode));
      if (await dir.exists()) {
        await for (final entity in dir.list()) {
          if (entity is File) await entity.delete();
        }
      }
      final bakedDir = Directory(p.join(await _baseDir, '${mode}_baked'));
      if (await bakedDir.exists()) {
        await for (final entity in bakedDir.list()) {
          if (entity is File) await entity.delete();
        }
      }
    } catch (_) {}
  }
}
