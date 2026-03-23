import 'dart:async';

import 'package:quran_app/quran/font_loader.dart' show loadQcf4Font;
import 'package:quran_app/quran/page_cache.dart';
import 'package:quran_app/quran/page_persistent_cache.dart';
import 'package:quran_app/quran/qpc_v1_loader.dart' show loadQpcV1Page;
import 'package:quran_app/quran/renderers/qpc_v4_renderer.dart'
    show QpcV4Renderer;

/// تحميل تدريجي لجميع أنواع المصحف (QPC V1 و QPC V4) في الخلفية.
/// الأولوية: الصفحة الحالية ±2، ثم الصفحات بعد الحالية، ثم من البداية.
class PageBackgroundLoader {
  PageBackgroundLoader._();
  static final PageBackgroundLoader instance = PageBackgroundLoader._();

  static const int totalPages = 604;

  int _currentPage = 1;
  bool _running = false;
  bool _disposed = false;

  void setCurrentPage(int page) {
    _currentPage = page.clamp(1, totalPages);
  }

  void start() {
    if (_running || _disposed) return;
    _running = true;
    _loadLoop();
  }

  void stop() {
    _running = false;
  }

  Future<void> _loadLoop() async {
    while (_running && !_disposed) {
      final next = _nextPageToLoad();
      if (next == null) {
        await Future.delayed(const Duration(milliseconds: 500));
        continue;
      }
      await _loadPage(next.page, next.mode);
      await Future.delayed(const Duration(milliseconds: 25));
    }
  }

  ({int page, String mode})? _nextPageToLoad() {
    final modes = ['qpc1', 'qpc4'];
    final nearby = [
      _currentPage - 2,
      _currentPage - 1,
      _currentPage,
      _currentPage + 1,
      _currentPage + 2,
    ];
    for (final p in nearby) {
      if (p < 1 || p > totalPages) continue;
      for (final m in modes) {
        if (!PageCache.instance.has(m, p)) return (page: p, mode: m);
      }
    }
    for (int p = _currentPage + 1; p <= totalPages; p++) {
      for (final m in modes) {
        if (!PageCache.instance.has(m, p)) return (page: p, mode: m);
      }
    }
    for (int p = 1; p < _currentPage; p++) {
      for (final m in modes) {
        if (!PageCache.instance.has(m, p)) return (page: p, mode: m);
      }
    }
    return null;
  }

  Future<void> _loadPage(int page, String mode) async {
    if (PageCache.instance.has(mode, page)) return;
    try {
      if (mode == 'qpc1') {
        final lines = await loadQpcV1Page(page);
        if (lines.isNotEmpty) {
          PageCache.instance.put(mode, page, lines);
          await PagePersistentCache.instance.put(mode, page, lines);
        }
      } else {
        await loadQcf4Font(page);
        await QpcV4Renderer.instance.loadPage(page);
      }
    } catch (_) {}
  }

  void dispose() {
    _disposed = true;
    _running = false;
  }
}
