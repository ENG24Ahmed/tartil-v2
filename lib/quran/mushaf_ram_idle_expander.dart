import 'dart:async';

import 'package:quran_app/quran/font_loader.dart' show loadQcf4Font, loadQcfFont;
import 'package:quran_app/quran/models/mushaf_line.dart';
import 'package:quran_app/quran/page_cache.dart';
import 'package:quran_app/quran/page_persistent_cache.dart';
import 'package:quran_app/quran/qpc_v1_loader.dart' show loadQpcV1Page;
import 'package:quran_app/quran/renderers/qpc_v4_renderer.dart' show QpcV4Renderer;

/// بعد ثبات المستخدم على صفحة (٣ ث):
/// - عند تفعيل التحميل الكامل: يوسّع كاش الرام تدريجياً حتى ٦٠٤ صفحة للوضع الحالي.
/// - عند إطفائه: يحمّل فقط 7 صفحات بعد الصفحة الحالية.
/// أي لمسة أو تغيير صفحة/وضع يُلغى التوسيع؛ وفي التحميل الكامل فقط، عند الاكتمال
/// يُوقف [PageCache.trimRamToNearbyPages].
///
/// [beginBlockingUi] / [endBlockingUi]: أثناء قوائم ونماذج (ما عدا قراءة التفسير/الأذكار)
/// يُوقف الجدولة والتوسيع؛ بعد الإغلاق يُعاد احتمال الانتظار ٣ ث.
class MushafRamIdleExpander {
  MushafRamIdleExpander._();
  static final MushafRamIdleExpander instance = MushafRamIdleExpander._();

  static const Duration _kIdleBeforeExpand = Duration(seconds: 3);
  static const int _kTotalPages = 604;
  static const int _kAheadPagesWhenLimited = 7;
  static const Duration _kYieldBetweenPages = Duration(milliseconds: 12);

  Timer? _idleTimer;
  int _cancelToken = 0;
  int _blockingUiDepth = 0;
  int _centerPage = 1;
  String _cacheMode = 'qpc4';
  bool _fullBackgroundWarmupEnabled = false;

  static bool _qpc1LinesOk(List<MushafPageLine> lines) {
    return lines.isNotEmpty &&
        lines.every((l) =>
            l.lineType != 'ayah' ||
            l.rangeStart == null ||
            (l.ayahSegments != null && l.ayahSegments!.isNotEmpty));
  }

  /// صفحة حالية (١…٦٠٤) ووضع الكاش: `qpc1` أو `qpc4` (يشمل V4 وV4 أسود).
  void onPageOrModeContext({
    required int pageOneBased,
    required String cacheMode,
    required bool fullBackgroundWarmupEnabled,
  }) {
    _cancelToken++;
    _centerPage = pageOneBased.clamp(1, _kTotalPages);
    _cacheMode = cacheMode == 'qpc1' ? 'qpc1' : 'qpc4';
    _fullBackgroundWarmupEnabled = fullBackgroundWarmupEnabled;
    if (!_fullBackgroundWarmupEnabled) {
      PageCache.instance.setSkipTrimWhileFullMushafInRam(false);
    }
    _scheduleIdleTimer();
  }

  /// تغيير وضع المصحف (V1/V4/أسود) من الإعدادات: إلغاء «مصحف كامل بالرام» وإعادة الجدولة.
  void onMushafStyleModeChanged({
    required int pageOneBased,
    required String cacheMode,
    required bool fullBackgroundWarmupEnabled,
  }) {
    _cancelToken++;
    _centerPage = pageOneBased.clamp(1, _kTotalPages);
    _cacheMode = cacheMode == 'qpc1' ? 'qpc1' : 'qpc4';
    _fullBackgroundWarmupEnabled = fullBackgroundWarmupEnabled;
    if (!_fullBackgroundWarmupEnabled) {
      PageCache.instance.setSkipTrimWhileFullMushafInRam(false);
    }
    _scheduleIdleTimer();
  }

  /// تغيير تفضيل «التحميل الكامل بالخلفية».
  void onFullBackgroundWarmupPrefChanged({
    required bool enabled,
    required int pageOneBased,
    required String cacheMode,
  }) {
    _cancelToken++;
    _fullBackgroundWarmupEnabled = enabled;
    _centerPage = pageOneBased.clamp(1, _kTotalPages);
    _cacheMode = cacheMode == 'qpc1' ? 'qpc1' : 'qpc4';
    if (!enabled) {
      PageCache.instance.setSkipTrimWhileFullMushafInRam(false);
    }
    _scheduleIdleTimer();
  }

  /// لمس الشاشة: يوقف التوسيع الجاري ويعيد جدولة الانتظار ٣ ث.
  void onUserPointerDown() {
    _cancelToken++;
    _scheduleIdleTimer();
  }

  /// قائمة/نافذة تغطي المصحف: إيقاف التوسيع والمؤقت حتى [endBlockingUi].
  void beginBlockingUi() {
    _blockingUiDepth++;
    _cancelToken++;
    _idleTimer?.cancel();
    _idleTimer = null;
  }

  void endBlockingUi() {
    if (_blockingUiDepth <= 0) return;
    _blockingUiDepth--;
    if (_blockingUiDepth == 0) {
      _scheduleIdleTimer();
    }
  }

  void disposeOnLeaveMushaf() {
    _cancelToken++;
    _blockingUiDepth = 0;
    _idleTimer?.cancel();
    _idleTimer = null;
    PageCache.instance.setSkipTrimWhileFullMushafInRam(false);
  }

  void _scheduleIdleTimer() {
    _idleTimer?.cancel();
    _idleTimer = null;
    if (_blockingUiDepth > 0) return;
    if (PageCache.instance.skipTrimWhileFullMushafInRam) return;
    _idleTimer = Timer(_kIdleBeforeExpand, () {
      _idleTimer = null;
      final token = _cancelToken;
      if (_fullBackgroundWarmupEnabled) {
        unawaited(_expandAllPagesInDistanceOrder(token));
      } else {
        unawaited(_expandForwardPagesLimited(token));
      }
    });
  }

  Future<void> _expandForwardPagesLimited(int token) async {
    if (token != _cancelToken) return;
    if (_blockingUiDepth > 0) return;
    PageCache.instance.setSkipTrimWhileFullMushafInRam(false);

    final mode = _cacheMode;
    final start = (_centerPage + 1).clamp(1, _kTotalPages);
    final end = (_centerPage + _kAheadPagesWhenLimited).clamp(1, _kTotalPages);
    if (end < start) return;

    for (var p = start; p <= end; p++) {
      if (token != _cancelToken) return;
      if (_blockingUiDepth > 0) return;
      await Future<void>.delayed(_kYieldBetweenPages);
      if (token != _cancelToken) return;
      if (_blockingUiDepth > 0) return;
      if (PageCache.instance.has(mode, p)) continue;
      await _loadPageIntoRamAndDisk(mode: mode, page: p, token: token);
    }
  }

  Future<void> _expandAllPagesInDistanceOrder(int token) async {
    if (token != _cancelToken) return;
    if (PageCache.instance.skipTrimWhileFullMushafInRam) return;

    final mode = _cacheMode;
    final center = _centerPage;
    final order = List<int>.generate(_kTotalPages, (i) => i + 1)
      ..sort((a, b) => (a - center).abs().compareTo((b - center).abs()));

    for (final p in order) {
      if (token != _cancelToken) return;
      if (_blockingUiDepth > 0) return;
      await Future<void>.delayed(_kYieldBetweenPages);
      if (token != _cancelToken) return;
      if (_blockingUiDepth > 0) return;
      if (PageCache.instance.has(mode, p)) continue;
      await _loadPageIntoRamAndDisk(mode: mode, page: p, token: token);
    }

    if (token == _cancelToken) {
      PageCache.instance.setSkipTrimWhileFullMushafInRam(true);
    }
  }

  Future<void> _loadPageIntoRamAndDisk({
    required String mode,
    required int page,
    required int token,
  }) async {
    if (mode == 'qpc1') {
      await loadQcfFont(page);
      if (token != _cancelToken) return;
      final disk = await PagePersistentCache.instance.get('qpc1', page);
      if (token != _cancelToken) return;
      if (disk != null && _qpc1LinesOk(disk)) {
        PageCache.instance.put('qpc1', page, disk);
      } else {
        final lines = await loadQpcV1Page(page);
        if (token != _cancelToken) return;
        if (lines.isNotEmpty) {
          PageCache.instance.put('qpc1', page, lines);
          await PagePersistentCache.instance.put('qpc1', page, lines);
        }
      }
    } else {
      await loadQcf4Font(page);
      if (token != _cancelToken) return;
      final disk = await PagePersistentCache.instance.get('qpc4', page);
      if (token != _cancelToken) return;
      if (disk != null && disk.isNotEmpty) {
        PageCache.instance.put('qpc4', page, disk);
      } else {
        await QpcV4Renderer.instance.loadPage(page, populateRamCache: true);
      }
    }
  }
}
