import 'dart:async';
import 'dart:collection' show LinkedHashMap;
import 'dart:math' show min;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart' show DragStartBehavior;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart'
    show RenderRepaintBoundary, ScrollDirection;
import 'package:flutter/scheduler.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:quran_app/quran/font_loader.dart';
import 'package:quran_app/quran/models/mushaf_line.dart';
import 'package:quran_app/quran/page_cache.dart';
import 'package:quran_app/quran/page_persistent_cache.dart';
import 'package:quran_app/quran/quran_db.dart';
import 'package:quran_app/quran/renderers/qpc_v4_black_renderer.dart';
import 'package:quran_app/quran/qpc_v1_loader.dart'
    show loadQpcV1PageForDisplay, tryGetQpcV1FromCache;
import 'package:quran_app/quran/compact_line_spacing_scope.dart';
import 'package:quran_app/quran/mushaf_page_layout.dart';
import 'package:quran_app/quran/mushaf_ayah_highlight.dart';
import 'package:quran_app/quran/mushaf_stable_viewport.dart';
import 'package:quran_app/audio/ayah_audio_player.dart';
import 'package:quran_app/quran/renderers/qpc_v4_renderer.dart'
    show
        AyahHighlightStore,
        DelayedLongPressDetector,
        QpcV4PageView,
        getAyahRangesForPage,
        getAyahWordRangeForPage,
        getJustifiedLineStyle,
        kQpcAyahLineHeightTight,
        kQpcAyahLinePadTight,
        kQpcPageNumberRowHeight,
        kQpcPageNumberVerticalNudge,
        kQpcPageNumberVisualBoost,
        kQpcRaqumSvgScale,
        kQpcShortWideAspectThreshold,
        onQpcPageLongPress,
        preloadNearbyPages;

enum QpcMushafMode { qpc1, qpc4, qpc4Black }
enum _PageRenderTier { lite, medium, full }

(int min, int max)? _wordRangeFromLines(List<MushafPageLine>? lines) {
  if (lines == null || lines.isEmpty) return null;
  int? minR;
  int? maxR;
  for (final line in lines) {
    final rs = line.rangeStart;
    final re = line.rangeEnd;
    if (rs == null || re == null) continue;
    minR = minR == null ? rs : (rs < minR ? rs : minR);
    maxR = maxR == null ? re : (re > maxR ? re : maxR);
  }
  if (minR == null || maxR == null || maxR < minR) return null;
  return (minR, maxR);
}

/// تحميل مسبق لـ QPC1: تقليص كاش الرام (صفحتان قبل وبعد) ثم تعبئته من القرص + خطوط مجاورة.
void preloadNearbyQpc1Pages(
  int currentPage, {
  int before = PageCache.cacheWindowBefore,
  int after = PageCache.cacheWindowAfter,
}) {
  const totalPages = 604;
  WidgetsBinding.instance.addPostFrameCallback((_) {
    SchedulerBinding.instance.scheduleTask<void>(
      () async {
        PageCache.instance.trimRamToNearbyPages(currentPage);
        await PagePersistentCache.instance.hydrateRamWindow(
          mode: 'qpc1',
          centerPage: currentPage,
          before: before,
          after: after,
          totalPages: totalPages,
        );
        for (var p = currentPage - before; p <= currentPage + after; p++) {
          if (p < 1 || p > totalPages) continue;
          final lines = PageCache.instance.get('qpc1', p);
          final range = _wordRangeFromLines(lines);
          if (range != null) {
            unawaited(
              QuranDb.instance.prewarmWordToAyahMapping(range.$1, range.$2),
            );
          }
          await loadQcfFont(p);
          await Future<void>.delayed(const Duration(milliseconds: 8));
        }
      },
      Priority.idle,
      debugLabel: 'preloadNearbyQpc1',
    );
  });
}

/// محاذاة FittedBox لأسطر V1: وسط أفقيًا حتى لا يتراكم الفراغ على يسار السطر عندما يكون النص أضيق من عرض السطر بعد التحجيم.
const Alignment _kV1FittedLineAlignment = Alignment.center;

const double _v1PersistentHighlightAlpha = 0.18;
const double _v1PersistentHighlightTopInsetFraction = 0.06;
const double _v1PersistentHighlightHeightFraction = 0.88;
const double _v1PersistentHighlightRadius = 10.0;

List<({double left, double width, Color color})> _mergeV1PersistentRectsByColor(
  List<({double left, double width, Color color})> rects,
) {
  if (rects.isEmpty) return const [];
  final grouped = <int, List<({double left, double width, Color color})>>{};
  for (final r in rects) {
    final key = r.color.toARGB32();
    grouped.putIfAbsent(
        key, () => <({double left, double width, Color color})>[]);
    grouped[key]!.add(r);
  }
  final merged = <({double left, double width, Color color})>[];
  for (final list in grouped.values) {
    var minLeft = list.first.left;
    var maxRight = list.first.left + list.first.width;
    for (final r in list) {
      if (r.left < minLeft) minLeft = r.left;
      final right = r.left + r.width;
      if (right > maxRight) maxRight = right;
    }
    final width = (maxRight - minLeft).clamp(0.0, double.infinity);
    if (width > 0.01) {
      merged.add((left: minLeft, width: width, color: list.first.color));
    }
  }
  merged.sort((a, b) => a.left.compareTo(b.left));
  return merged;
}

Widget _buildV1PersistentHighlightSegment(
  ({double left, double width, Color color}) rect,
  double lineHeight,
) {
  return Positioned(
    left: rect.left,
    top: lineHeight * _v1PersistentHighlightTopInsetFraction,
    width: rect.width,
    height: lineHeight * _v1PersistentHighlightHeightFraction,
    child: CustomPaint(
      painter: _V1WavyHighlightPainter(
        color: rect.color.withValues(alpha: _v1PersistentHighlightAlpha),
      ),
    ),
  );
}

class _V1WavyHighlightPainter extends CustomPainter {
  const _V1WavyHighlightPainter({required this.color});
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    canvas.save();
    canvas.clipRRect(
      RRect.fromRectAndRadius(
        Offset.zero & size,
        const Radius.circular(_v1PersistentHighlightRadius),
      ),
    );
    final waveInset = (size.height * 0.10).clamp(0.6, 1.8).toDouble();
    final amplitude = (size.height * 0.07).clamp(0.6, 1.8).toDouble();
    final step = (size.width / 6).clamp(14.0, 30.0).toDouble();
    final topY = waveInset;
    final bottomY = size.height - waveInset;
    final path = Path()..moveTo(0, topY);
    double x = 0;
    bool up = true;
    while (x < size.width) {
      final nx = (x + step).clamp(0, size.width).toDouble();
      final cx = (x + nx) / 2;
      final cy = up ? topY - amplitude : topY + amplitude;
      path.quadraticBezierTo(cx, cy, nx, topY);
      up = !up;
      x = nx;
    }
    path.lineTo(size.width, bottomY);
    x = size.width;
    up = true;
    while (x > 0) {
      final nx = (x - step).clamp(0, size.width).toDouble();
      final cx = (x + nx) / 2;
      final cy = up ? bottomY + amplitude : bottomY - amplitude;
      path.quadraticBezierTo(cx, cy, nx, bottomY);
      up = !up;
      x = nx;
    }
    path.close();
    canvas.drawPath(path, Paint()..color = color);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _V1WavyHighlightPainter oldDelegate) {
    return oldDelegate.color.toARGB32() != color.toARGB32();
  }
}

// Fix 1: كاش لـ Future تحميل صفحات V1 — يمنع FutureBuilder من إعادة التحميل عند كل rebuild
final Map<int, Future<List<MushafPageLine>>> _v1PageLoadFutures =
    <int, Future<List<MushafPageLine>>>{};

/// مكوّن صفحة واحد يُستخدم في جميع أنواع العرض (افتراضي، أفقي، صفحتان، قراءة طويلة).
/// يُلف داخل [MushafStableViewport] لعزل التخطيط عن حجم العرض المنطقي وتكبير النص من النظام.
Widget buildQpcPageContent(
  BuildContext context,
  int page,
  QpcMushafMode mode, {
  bool forceWhiteMushafText = false,
  bool hideAyahText = false,
  bool lightweightMode = false,
  bool mediumQualityMode = false,
}) {
  final Widget inner;
  if (mode == QpcMushafMode.qpc4) {
    inner = QpcV4PageView(
      page: page,
      hideAyahText: hideAyahText,
      lightweightMode: lightweightMode,
      mediumQualityMode: mediumQualityMode,
    );
  } else if (mode == QpcMushafMode.qpc4Black) {
    inner = QpcV4BlackPageView(
      page: page,
      forceWhiteTextOnDark: forceWhiteMushafText,
      lightweightMode: lightweightMode,
      mediumQualityMode: mediumQualityMode,
    );
  } else {
    final cached = tryGetQpcV1FromCache(page);
    if (cached != null) {
      inner = _QpcV1PageFromLinesWidget(
        page: page,
        pageLines: cached,
        forceWhiteMushafText: forceWhiteMushafText,
        lightweightMode: lightweightMode,
        mediumQualityMode: mediumQualityMode,
      );
    } else {
      inner = FutureBuilder<List<MushafPageLine>>(
        future: _v1PageLoadFutures.putIfAbsent(
            page, () => loadQpcV1PageForDisplay(page)),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return ColoredBox(
              color: MushafPaperBackgroundScope.of(context),
              child: const SizedBox.expand(),
            );
          }
          if (snapshot.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  'تعذّر تحميل الصفحة. أعد المحاولة.',
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 16),
                ),
              ),
            );
          }
          final pageLines = snapshot.data ?? [];
          if (pageLines.isEmpty) {
            return const Center(child: Text('لا توجد بيانات لهذه الصفحة'));
          }
          return _QpcV1PageFromLinesWidget(
            page: page,
            pageLines: pageLines,
            forceWhiteMushafText: forceWhiteMushafText,
            lightweightMode: lightweightMode,
            mediumQualityMode: mediumQualityMode,
          );
        },
      );
    }
  }
  return ColoredBox(
    color: MushafPaperBackgroundScope.of(context),
    child: MushafStableViewport(child: inner),
  );
}

/// عرض صفحة QPC V1 من الأسطر المحملة (يُستخدم من buildQpcPageContent).
/// Fix 2: يُخزّن Future تحميل خريطة الكلمات→الآيات ويمنع إعادة إنشائها
/// عند كل pass لـ LayoutBuilder — مثل _WordToAyahMappingLoader في qpc_v4_renderer.dart
class _WordToAyahMappingLoaderV1 extends StatefulWidget {
  const _WordToAyahMappingLoaderV1({
    required this.minR,
    required this.maxR,
    required this.builder,
  });
  final int minR;
  final int maxR;
  final Widget Function(
    BuildContext,
    AsyncSnapshot<Map<int, (int, int)>>,
  ) builder;

  @override
  State<_WordToAyahMappingLoaderV1> createState() =>
      _WordToAyahMappingLoaderV1State();
}

class _WordToAyahMappingLoaderV1State
    extends State<_WordToAyahMappingLoaderV1> {
  late Future<Map<int, (int, int)>> _future;

  @override
  void initState() {
    super.initState();
    _future =
        QuranDb.instance.getWordToAyahMapping(widget.minR, widget.maxR);
  }

  @override
  void didUpdateWidget(covariant _WordToAyahMappingLoaderV1 oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.minR != widget.minR || oldWidget.maxR != widget.maxR) {
      _future =
          QuranDb.instance.getWordToAyahMapping(widget.minR, widget.maxR);
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Map<int, (int, int)>>(
      future: _future,
      builder: widget.builder,
    );
  }
}

class _QpcV1PageFromLinesWidget extends StatelessWidget {
  const _QpcV1PageFromLinesWidget({
    required this.page,
    required this.pageLines,
    required this.forceWhiteMushafText,
    this.lightweightMode = false,
    this.mediumQualityMode = false,
  });
  final int page;
  final List<MushafPageLine> pageLines;
  final bool forceWhiteMushafText;
  final bool lightweightMode;
  final bool mediumQualityMode;

  @override
  Widget build(BuildContext context) {
    return _QuranReaderState.buildV1PageFromLinesStatic(
      context,
      page,
      pageLines,
      forceWhiteMushafText: forceWhiteMushafText,
      lightweightMode: lightweightMode,
      mediumQualityMode: mediumQualityMode,
    );
  }
}

/// طبقة لا تشارك في ساحة الإيماءات — تلتقط النقر فقط دون تعطيل السحب.
class _TapOverlay extends StatelessWidget {
  const _TapOverlay({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: onTap,
      child: const SizedBox.expand(),
    );
  }
}

class _ProfessionalPageScrollPhysics extends PageScrollPhysics {
  const _ProfessionalPageScrollPhysics({super.parent});

  static const double _kTurnPageThresholdSlow = 0.25;
  static const double _kTurnPageThresholdFast = 0.15;
  static const double _kMinFlingVelocity = 150.0;
  static const double _kVelocityPageBias = 0.30;

  @override
  _ProfessionalPageScrollPhysics applyTo(ScrollPhysics? ancestor) {
    return _ProfessionalPageScrollPhysics(parent: buildParent(ancestor));
  }

  @override
  Simulation? createBallisticSimulation(
    ScrollMetrics position,
    double velocity,
  ) {
    if ((velocity <= 0.0 && position.pixels <= position.minScrollExtent) ||
        (velocity >= 0.0 && position.pixels >= position.maxScrollExtent)) {
      return super.createBallisticSimulation(position, velocity);
    }
    final viewport = position.viewportDimension;
    if (viewport <= 0.0) {
      return super.createBallisticSimulation(position, velocity);
    }
    final page = position.pixels / viewport;
    final fastFling = velocity.abs() >= _kMinFlingVelocity;
    final biasedPage =
        fastFling ? page + velocity.sign * _kVelocityPageBias : page;
    final base = biasedPage.floorToDouble();
    final fraction = biasedPage - base;
    final threshold =
        fastFling ? _kTurnPageThresholdFast : _kTurnPageThresholdSlow;
    var targetPage = fraction >= threshold ? base + 1.0 : base;
    final minPage = position.minScrollExtent / viewport;
    final maxPage = position.maxScrollExtent / viewport;
    targetPage = targetPage.clamp(minPage, maxPage);
    final targetPixels = targetPage * viewport;
    final tolerance = toleranceFor(position);
    if ((targetPixels - position.pixels).abs() < tolerance.distance &&
        velocity.abs() < tolerance.velocity) {
      return null;
    }
    return ScrollSpringSimulation(
      spring,
      position.pixels,
      targetPixels,
      velocity,
      tolerance: tolerance,
    );
  }
}

/// قارئ المصحف: QPC V1 أو V4 أو V4 أسود حسب الوضع المختار.
/// عند [embedded] = true يُستخدم كجسم داخل شاشة أخرى (بدون شريط علوي خاص).
/// عند توفير [buildTopBarForPage] يُضمَّن الشريط داخل كل صفحة فيُسحَب معها.
// ─────────────────────────────────────────────────────────────
// Raster cache — stores pages as ui.Image after first full render
// ─────────────────────────────────────────────────────────────

class _PageRasterCache {
  static const int _kMaxImages = 12;
  static final LinkedHashMap<String, ui.Image> _cache =
      LinkedHashMap<String, ui.Image>();

  static ui.Image? get(String key) {
    final img = _cache.remove(key);
    if (img == null) return null;
    _cache[key] = img;
    return img;
  }

  static void put(String key, ui.Image img) {
    _cache.remove(key)?.dispose();
    _cache[key] = img;
    while (_cache.length > _kMaxImages) {
      _cache.remove(_cache.keys.first)?.dispose();
    }
  }

}

class _RasterCapturePageWrapper extends StatefulWidget {
  const _RasterCapturePageWrapper({
    required this.cacheKey,
    required this.tier,
    required this.child,
  });

  final String cacheKey;
  final _PageRenderTier tier;
  final Widget child;

  @override
  State<_RasterCapturePageWrapper> createState() =>
      _RasterCapturePageWrapperState();
}

class _RasterCapturePageWrapperState
    extends State<_RasterCapturePageWrapper> {
  final _repaintKey = GlobalKey();
  bool _captureScheduled = false;

  void _scheduleCapture() {
    if (_captureScheduled) return;
    if (_PageRasterCache.get(widget.cacheKey) != null) return;
    _captureScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      _captureScheduled = false;
      if (!mounted) return;
      try {
        final ro = _repaintKey.currentContext?.findRenderObject();
        if (ro is! RenderRepaintBoundary) return;
        if (ro.debugNeedsPaint) {
          _scheduleCapture();
          return;
        }
        final dpr = MediaQuery.devicePixelRatioOf(context);
        final img = await ro.toImage(pixelRatio: dpr);
        _PageRasterCache.put(widget.cacheKey, img);
        if (mounted) setState(() {});
      } catch (_) {}
    });
  }

  @override
  void didUpdateWidget(covariant _RasterCapturePageWrapper oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.cacheKey != widget.cacheKey) _captureScheduled = false;
  }

  @override
  Widget build(BuildContext context) {
    final cached = _PageRasterCache.get(widget.cacheKey);

    if (cached != null && widget.tier != _PageRenderTier.full) {
      return RepaintBoundary(
        child: SizedBox.expand(
          child: RawImage(image: cached, fit: BoxFit.fill),
        ),
      );
    }

    if (widget.tier == _PageRenderTier.full && cached == null) {
      _scheduleCapture();
    }

    return RepaintBoundary(
      key: (widget.tier == _PageRenderTier.full && cached == null)
          ? _repaintKey
          : null,
      child: widget.child,
    );
  }
}
class QuranReader extends StatefulWidget {
  const QuranReader({
    super.key,
    this.initialPage = 1,
    this.embedded = false,
    this.controller,
    this.onPageChanged,
    this.onTap,
    this.onReady,
    this.mode,
    this.forceWhiteMushafText = false,
    this.buildTopBarForPage,
  });

  final int initialPage;
  final bool embedded;
  final PageController? controller;
  final void Function(int page)? onPageChanged;
  final VoidCallback? onTap;

  /// يُستدعى عند جاهزية العرض (بعد تحميل قاعدة البيانات) — مفيد لمزامنة القفز عند التبديل من وضع آخر.
  final VoidCallback? onReady;

  /// عند الدمج: الوضع من الشاشة الأم. إن لم يُمرَّر يُستخدم الوضع الداخلي.
  final QpcMushafMode? mode;
  final bool forceWhiteMushafText;

  /// عند التوفير: شريط علوي لكل صفحة فيُسحَب مع الصفحة (مثل رقم الصفحة).
  final Widget Function(int page)? buildTopBarForPage;

  @override
  State<QuranReader> createState() => _QuranReaderState();
}

class _QuranReaderState extends State<QuranReader> {
  static const String _v1CacheMode = 'qpc1';
  static const String _surahNameFontFamily = 'SurahNameV4';
  static const double _basmallahRaiseDy = -2.0;
  static const String _basmallahFontFamily = 'KFGQPCHAFSUthmanicScript';
  static const int _v1UniformScaleCacheMaxEntries = 240;
  static final Map<String, double> _v1UniformScaleCache = <String, double>{};
  final QuranDb _db = QuranDb.instance;
  late final PageController _pageController;
  bool _ownsController = false;

  static const int totalPages = 604;
  late int _currentPageIndex;
  bool _dbReady = false;
  String? _initError;
  bool _isDraggingPages = false;
  Timer? _dragSettleTimer;
  Timer? _qualityTierTimer;
  double? _lastDragPixels;
  int? _lastDragElapsedUs;
  double _recentDragVelocityPxPerSec = 0.0;
  final Stopwatch _dragStopwatch = Stopwatch()..start();
  final ValueNotifier<_PageRenderTier> _renderTierNotifier =
      ValueNotifier(_PageRenderTier.full);
  QpcMushafMode _mode = QpcMushafMode.qpc4;

  QpcMushafMode get _effectiveMode => widget.mode ?? _mode;
  bool get _useWhiteTextOnDarkMushaf =>
      widget.forceWhiteMushafText &&
      (_effectiveMode == QpcMushafMode.qpc1 ||
          _effectiveMode == QpcMushafMode.qpc4Black);

  @override
  void initState() {
    super.initState();
    if (widget.controller != null) {
      _pageController = widget.controller!;
      _ownsController = false;
      final page = _pageController.hasClients
          ? (_pageController.page ?? 0).round()
          : (widget.initialPage - 1);
      _currentPageIndex = page.clamp(0, totalPages - 1);
    } else {
      _currentPageIndex = (widget.initialPage - 1).clamp(0, totalPages - 1);
      _pageController = PageController(initialPage: _currentPageIndex);
      _ownsController = true;
    }
    _initDb();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final pageNum = _currentPageIndex + 1;
      final radius = _isDraggingPages ? _preloadRadiusForCurrentDrag() : 2;
      if (_effectiveMode == QpcMushafMode.qpc4 ||
          _effectiveMode == QpcMushafMode.qpc4Black) {
        preloadNearbyPages(pageNum, before: radius, after: radius);
      } else if (_effectiveMode == QpcMushafMode.qpc1) {
        _preloadV1Pages(pageNum, before: radius, after: radius);
      }
    });
  }

  @override
  void dispose() {
    _dragSettleTimer?.cancel();
    _qualityTierTimer?.cancel();
    _renderTierNotifier.dispose();
    if (_ownsController) _pageController.dispose();
    super.dispose();
  }

  Future<void> _initDb() async {
    try {
      await _db.init();
      if (mounted) {
        setState(() {
          _dbReady = true;
          _initError = null;
        });
        widget.onReady?.call();
      }
      // لا نبدأ warmAll تلقائيا لتجنب ضغط الخلفية أثناء التقليب.
    } catch (e) {
      debugPrint('QuranReader db init failed: $e');
      if (mounted) {
        setState(() {
          _dbReady = false;
          _initError =
              'حدث خطأ أثناء تحميل قاعدة البيانات. أعد المحاولة.';
        });
      }
    }
  }

  void _preloadV1Pages(
    int currentPage, {
    int before = PageCache.cacheWindowBefore,
    int after = PageCache.cacheWindowAfter,
  }) =>
      preloadNearbyQpc1Pages(currentPage, before: before, after: after);

  int _preloadRadiusForCurrentDrag() {
    final v = _recentDragVelocityPxPerSec.abs();
    if (v >= 3200) return 8;
    if (v >= 2200) return 6;
    if (v >= 1200) return 5;
    if (v >= 700) return 4;
    return 3;
  }

  void _setRenderTier(_PageRenderTier tier) {
    if (_renderTierNotifier.value == tier) return;
    _renderTierNotifier.value = tier;
  }

  void _goBackToMain() {
    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final navigator = Navigator.maybeOf(context);
      if (navigator != null && navigator.canPop()) {
        navigator.pop();
      }
    });
  }

  void _showModeSheet() {
    showModalBottomSheet<void>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: const Text('QPC V1'),
              subtitle: const Text('مصحف النص العادي'),
              onTap: () {
                Navigator.pop(context);
                PageCache.instance.clearMode(_v1CacheMode);
                setState(() => _mode = QpcMushafMode.qpc1);
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted) _preloadV1Pages(_currentPageIndex + 1);
                });
              },
            ),
            ListTile(
              title: const Text('QPC V4'),
              subtitle: const Text('مصحف التجويد الملون'),
              onTap: () {
                Navigator.pop(context);
                setState(() => _mode = QpcMushafMode.qpc4);
              },
            ),
            ListTile(
              title: const Text('QPC V4 أسود'),
              subtitle: const Text('نفس التخطيط بلون أسود'),
              onTap: () {
                Navigator.pop(context);
                setState(() => _mode = QpcMushafMode.qpc4Black);
              },
            ),
          ],
        ),
      ),
    );
  }

  static const double _linePaddingBottom = 0.32;

  static const String _arabicDigits = '٠١٢٣٤٥٦٧٨٩';
  static String _toArabicDigits(int value) {
    return value.toString().replaceAllMapped(
        RegExp(r'\d'), (m) => _arabicDigits[int.parse(m.group(0)!)]);
  }

  /// صف رقم الصفحة داخل صفحة QPC V1 (نفس سلوك الشريط العلوي — يُسحَب مع الصفحة).
  /// إزاحة ~4% من عرض الصف نحو المركز: فردي أقرب لليسار، زوجي أقرب لليمين.
  Widget _buildV1PageNumberRow(int page) {
    return Transform.translate(
      offset: const Offset(0, kQpcPageNumberVerticalNudge),
      child: SizedBox(
        height: kQpcPageNumberRowHeight,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final shift = constraints.maxWidth * 0.04;
            final pad = page.isOdd
                ? EdgeInsets.fromLTRB(16, 0, 16 + shift, 0)
                : EdgeInsets.fromLTRB(16 + shift, 0, 16, 0);
            return Align(
              alignment:
                  page.isOdd ? Alignment.centerRight : Alignment.centerLeft,
              child: Padding(
                padding: pad,
                child: SizedBox(
                  height: kQpcPageNumberRowHeight,
                  child: FittedBox(
                    fit: BoxFit.contain,
                    child: SizedBox(
                      width: 56.25 / kQpcPageNumberVisualBoost,
                      height: 28.125 / kQpcPageNumberVisualBoost,
                      child: Stack(
                        clipBehavior: Clip.none,
                        alignment: Alignment.center,
                        children: [
                          Transform.scale(
                            scale: kQpcRaqumSvgScale,
                            alignment: Alignment.center,
                            child: SvgPicture.asset(
                              'assets/icon/raqum_alsafha.svg',
                              fit: BoxFit.contain,
                            ),
                          ),
                          Text(
                            _toArabicDigits(page),
                            style: TextStyle(
                              fontSize: 18,
                              color: _useWhiteTextOnDarkMushaf
                                  ? Colors.white
                                  : Colors.black,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  /// نفس حجم وخطوة السطر في V4 (تم تكبيره إلى 26 بدلاً من 23).
  static const double _fontSize = 26;
  static const double _lineHeight = 1.25;

  static TextStyle _lineStyle(
    String fontFamily, {
    double? fontSize,
    bool useWhiteTextOnDark = false,
    double? height,
  }) =>
      TextStyle(
        fontFamily: fontFamily,
        fontSize: fontSize ?? _fontSize,
        height: height ?? _lineHeight,
        color: useWhiteTextOnDark ? Colors.white : null,
      );

  static TextStyle _v1LineStyleFromLine(MushafPageLine line,
      {double fontSizeScale = 1.0,
      bool useWhiteTextOnDark = false,
      double? ayahLineHeight}) {
    if (line.lineType == 'surah_name') {
      return GoogleFonts.arefRuqaaInk(
        fontSize: 17 * fontSizeScale,
        height: 1.3,
        fontWeight: FontWeight.w700,
        color: useWhiteTextOnDark ? Colors.white : null,
      );
    }
    if (line.lineType == 'basmallah') {
      return TextStyle(
        fontFamily: _basmallahFontFamily,
        fontSize: 18 * fontSizeScale,
        height: 1.15,
        fontWeight: FontWeight.w600,
        color: useWhiteTextOnDark ? Colors.white : Colors.black,
      );
    }
    return _lineStyle(
      line.fontFamily,
      fontSize: _fontSize * fontSizeScale,
      useWhiteTextOnDark: useWhiteTextOnDark,
      height: ayahLineHeight,
    );
  }

  /// تبرير بتوزيع المسافات — لا نستخدم الحساب الهندسي البديل لمحاذاة يمين RTL.
  static bool _v1LineUsesWordSpacingJustification(
    MushafPageLine line,
    TextStyle base,
    TextStyle applied,
  ) {
    if (line.isCentered) return false;
    return (applied.wordSpacing ?? 0) != (base.wordSpacing ?? 0);
  }

  /// بعض حالات RTL في QPC1 تُرجع إحداثيات قياس على عرض فعلي أصغر من [lineWidth]
  /// (خاصة عند overflow.visible). نعيدها إلى مرجع السطر الكامل حتى يتطابق
  /// موضع التحديد/التضليل مع الرسم.
  static double _v1ResolvedLineLeftAdjustment({
    required MushafPageLine line,
    required TextPainter painter,
    required double lineWidth,
  }) {
    if (line.isCentered) return 0.0;
    final extra = lineWidth - painter.width;
    if (!extra.isFinite || extra <= 0.01) return 0.0;
    return extra;
  }

  /// نص سطر آية QPC1 — يجب أن يبقى متماثلًا مع [mushafLaidOutRtlLinePainterV1Highlight].
  static Widget _v1AyahLineTextStatic(
    String lineText,
    TextStyle lineStyle, {
    required bool lineCentered,
  }) {
    return Text(
      lineText,
      textDirection: TextDirection.rtl,
      textAlign: lineCentered ? TextAlign.center : TextAlign.right,
      softWrap: false,
      maxLines: 1,
      overflow: TextOverflow.visible,
      textScaler: TextScaler.noScaling,
      textWidthBasis: TextWidthBasis.parent,
      style: lineStyle,
    );
  }

  /// غلاف بصري موحّد لسطر الآية (Stack بنفس عرض/ارتفاع التخطيط) حتى يطابق الرسم حساب التضليل.
  static Widget _v1AyahLineVisualShellStatic({
    required MushafPageLine line,
    required double lineWidth,
    required double lineHeight,
    required TextStyle lineStyle,
    required List<Widget> overlayWidgets,
    required EdgeInsets padding,
  }) {
    final alignment =
        line.isCentered ? Alignment.center : Alignment.centerRight;
    return Padding(
      padding: padding,
      child: Align(
        alignment: alignment,
        child: SizedBox(
          width: double.infinity,
          child: Align(
            alignment: alignment,
            child: mushafHighlightLineStackFixed(
              lineWidth: lineWidth,
              lineHeight: lineHeight,
              lineText: _v1AyahLineTextStatic(
                line.lineText,
                lineStyle,
                lineCentered: line.isCentered,
              ),
              overlayWidgets: overlayWidgets,
            ),
          ),
        ),
      ),
    );
  }

  static double _computeMaxLineWidth(
    List<MushafPageLine> pageLines, {
    bool useWhiteTextOnDark = false,
  }) {
    double maxLineWidth = 0;
    for (final line in pageLines) {
      final style = _v1LineStyleFromLine(
        line,
        useWhiteTextOnDark: useWhiteTextOnDark,
      );
      final w = mushafMeasureLineWidth(line.lineText, style);
      if (w > maxLineWidth) maxLineWidth = w;
    }
    return maxLineWidth;
  }

  /// نسبة ارتفاع إطار اسم السورة إلى عرضه (من viewBox sura_name.svg: 1621.5×171).
  static const double _surahFrameAspect = 171 / 1621.5;

  static double _computeContentHeight(
      List<MushafPageLine> pageLines, double contentW) {
    double total = 0;
    final normalLineHeight = _fontSize * _lineHeight + _linePaddingBottom;
    for (final line in pageLines) {
      if (line.lineType == 'surah_name') {
        total += contentW * _surahFrameAspect + _linePaddingBottom;
      } else {
        total += normalLineHeight;
      }
    }
    return total;
  }

  /// نسخة ثابتة لبناء صفحة V1 من الأسطر (للاستخدام من buildQpcPageContent).
  static Widget buildV1PageFromLinesStatic(
    BuildContext context,
    int page,
    List<MushafPageLine> pageLines, {
    bool forceWhiteMushafText = false,
    bool lightweightMode = false,
    bool mediumQualityMode = false,
  }) {
    int? minR;
    int? maxR;
    for (final line in pageLines) {
      if (line.rangeStart != null && line.rangeEnd != null) {
        minR = minR == null
            ? line.rangeStart!
            : (line.rangeStart! < minR ? line.rangeStart! : minR);
        maxR = maxR == null
            ? line.rangeEnd!
            : (line.rangeEnd! > maxR ? line.rangeEnd! : maxR);
      }
    }
    final maxLineWidth = _computeMaxLineWidth(
      pageLines,
      useWhiteTextOnDark: forceWhiteMushafText,
    );
    final contentW = maxLineWidth;
    final contentH = _computeContentHeight(pageLines, contentW);
    final lineHeights = List<double>.generate(
      pageLines.length,
      (i) => pageLines[i].lineType == 'surah_name'
          ? contentW * _surahFrameAspect + _linePaddingBottom
          : _fontSize * _lineHeight + _linePaddingBottom,
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        if (minR == null || maxR == null) {
          return _buildV1PageContentStatic(
            context,
            constraints,
            page,
            null,
            pageLines,
            null,
            null,
            null,
            null,
            null,
            useWhiteTextOnDark: forceWhiteMushafText,
          );
        }
        if (lightweightMode) {
          return _buildV1PageContentStatic(
            context,
            constraints,
            page,
            null,
            pageLines,
            null,
            null,
            null,
            null,
            null,
            useWhiteTextOnDark: forceWhiteMushafText,
          );
        }
        if (mediumQualityMode) {
          return _WordToAyahMappingLoaderV1(
            minR: minR,
            maxR: maxR,
            builder: (_, mapSnap) => _buildV1PageContentStatic(
              context,
              constraints,
              page,
              mapSnap.data,
              pageLines,
              null,
              null,
              null,
              null,
              null,
              useWhiteTextOnDark: forceWhiteMushafText,
            ),
          );
        }
        return _WordToAyahMappingLoaderV1(
          minR: minR,
          maxR: maxR,
          builder: (_, mapSnap) => _V1PageContentStateful(
            constraints: constraints,
            page: page,
            contentW: contentW,
            contentH: contentH,
            lineHeights: lineHeights,
            pageLines: pageLines,
            mapping: mapSnap.data,
            buildContent: (ctx, sel, persistentSel, wordSel, onS, onC) =>
                _buildV1PageContentStatic(
              ctx,
              constraints,
              page,
              mapSnap.data,
              pageLines,
              sel,
              persistentSel,
              wordSel,
              onS,
              onC,
              useWhiteTextOnDark: forceWhiteMushafText,
            ),
          ),
        );
      },
    );
  }

  /// مقياس واحد لجميع أسطر الآية في الصفحة (مثل أضيق سطر يحتاج تصغيراً) حتى لا يختلف حجم الخط بين السطور بسبب [FittedBox] لكل سطر.
  static double _computeV1UniformAyahScale(
    List<MushafPageLine> displayLines,
    double layoutW,
    double slotHeight,
    double fontSizeScale,
    double? ayahLineHeight,
    bool useWhiteTextOnDark,
  ) {
    final cacheKey =
        '${displayLines.length}|${layoutW.toStringAsFixed(2)}|${slotHeight.toStringAsFixed(2)}|${fontSizeScale.toStringAsFixed(4)}|${(ayahLineHeight ?? -1).toStringAsFixed(4)}|$useWhiteTextOnDark';
    final cached = _v1UniformScaleCache[cacheKey];
    if (cached != null) return cached;
    var minScale = 1.0;
    for (final line in displayLines) {
      if (line.lineType != 'ayah') continue;
      final base = _v1LineStyleFromLine(
        line,
        fontSizeScale: fontSizeScale,
        useWhiteTextOnDark: useWhiteTextOnDark,
        ayahLineHeight: ayahLineHeight,
      );
      final style =
          line.isCentered ? base : getJustifiedLineStyle(line, base, layoutW);
      final p = TextPainter(
        text: TextSpan(text: line.lineText, style: style),
        textDirection: TextDirection.rtl,
        maxLines: 1,
      )..layout(maxWidth: double.infinity);
      final w = p.width;
      final h = p.height;
      if (w <= 0 || h <= 0) continue;
      final sw = layoutW / w;
      final sh = slotHeight / h;
      final s = min(1.0, min(sw, sh));
      if (s < minScale) minScale = s;
    }
    if (_v1UniformScaleCache.length >= _v1UniformScaleCacheMaxEntries) {
      _v1UniformScaleCache.remove(_v1UniformScaleCache.keys.first);
    }
    _v1UniformScaleCache[cacheKey] = minScale;
    return minScale;
  }

  static Widget _buildV1PageContentStatic(
      BuildContext context,
      BoxConstraints constraints,
      int page,
      Map<int, (int sura, int ayah)>? mapping,
      List<MushafPageLine> pageLines,
      List<(int lineIndex, int startChar, int endChar)>? selection,
      List<(int lineIndex, int startChar, int endChar, Color color)>?
          persistentSelection,
      (int lineIndex, int startChar, int endChar)? wordSelection,
      void Function(List<(int lineIndex, int startChar, int endChar)>)?
          onSelectLine,
      void Function()? onClearSelection,
      {bool useWhiteTextOnDark = false}) {
    final isCompact = CompactLineSpacingScope.isCompact(context);
    final availableWidth = constraints.maxWidth;
    final omitVertical = SeamlessLongScrollScope.isActive(context);
    final metrics = computeMushafInnerLayoutMetrics(
      maxWidth: availableWidth,
      maxHeight: constraints.maxHeight,
      isCompact: isCompact,
      omitVerticalMargins: omitVertical,
    );
    final aspect = constraints.maxHeight > 0
        ? constraints.maxWidth / constraints.maxHeight
        : 1.0;
    final useTightLateral =
        !isCompact && aspect >= kQpcShortWideAspectThreshold;
    final availableW = metrics.innerWidth;
    final fontScale = isCompact ? getCompactFontScaleFactor(context) : 1.0;
    var linePad = isCompact ? 0.2 : _linePaddingBottom;
    var ayahLineHeight = _lineHeight;
    if (useTightLateral) {
      final slotProbe = metrics.innerHeight / kMushafLineSlotCount;
      const maxFontScale = 1.12;
      final minSlotNeeded = _fontSize * maxFontScale * kQpcAyahLineHeightTight +
          kQpcAyahLinePadTight;
      if (slotProbe >= minSlotNeeded + 0.5) {
        ayahLineHeight = kQpcAyahLineHeightTight;
        linePad = kQpcAyahLinePadTight;
      }
    }
    // عرض عمود النص = المنطقة الداخلية (هامشان 2%).
    final scaledW = availableW;
    final displayLines = pageLines.length >= kMushafLineSlotCount
        ? pageLines.sublist(0, kMushafLineSlotCount)
        : pageLines;
    var baseFontSizeScale = (page == 1 || page == 2)
        ? 1.12
        : (page == 3)
            ? 1.08
            : 1.0;
    if (isCompact) baseFontSizeScale *= fontScale;
    MushafPageLine v1ProbeLine = displayLines.first;
    for (final l in displayLines) {
      if (l.lineType == 'ayah') {
        v1ProbeLine = l;
        break;
      }
    }
    final slotNatural = metrics.slotHeight;
    var squeezedBaseFontScale = baseFontSizeScale;
    var bodyLinePad = linePad;
    late double minSlotH;
    late double layoutHeight;
    late double slotHeight;
    for (var squeezeIter = 0; squeezeIter < 8; squeezeIter++) {
      final v1ProbeStyle = _v1LineStyleFromLine(
        v1ProbeLine,
        fontSizeScale: squeezedBaseFontScale,
        useWhiteTextOnDark: useWhiteTextOnDark,
        ayahLineHeight: ayahLineHeight,
      );
      minSlotH = mushafMinSlotHeightForAyahStyle(
        ayahStyle: v1ProbeStyle,
        linePaddingBottom: bodyLinePad,
      );
      final blockFit = slotNatural + 0.01 < minSlotH;
      layoutHeight =
          blockFit ? kMushafLineSlotCount * minSlotH : metrics.innerHeight;
      slotHeight = blockFit ? minSlotH : slotNatural;
      if (!blockFit || layoutHeight <= metrics.innerHeight + 0.5) {
        break;
      }
      final squeeze = metrics.innerHeight / layoutHeight;
      squeezedBaseFontScale *= squeeze;
      bodyLinePad *= squeeze;
    }
    final uniformAyahScale = _computeV1UniformAyahScale(
      displayLines,
      scaledW,
      slotHeight,
      squeezedBaseFontScale,
      ayahLineHeight,
      useWhiteTextOnDark,
    );
    final slots = <Widget>[];
    for (int i = 0; i < kMushafLineSlotCount; i++) {
      Widget lineChild = const SizedBox.shrink();
      final srcIndex = (page == 1 || page == 2) ? i - 3 : i;
      if (srcIndex >= 0 && srcIndex < displayLines.length) {
        final line = displayLines[srcIndex];
        (int, int, int)? lineSelection;
        if (selection != null) {
          for (final r in selection) {
            if (r.$1 == srcIndex) {
              lineSelection = r;
              break;
            }
          }
        }
        final fontSizeScale = squeezedBaseFontScale;
        (int, int, int)? lineWordSelection;
        if (wordSelection != null && wordSelection.$1 == srcIndex) {
          lineWordSelection = wordSelection;
        }
        final linePersistentSelections = <(int, int, int, Color)>[];
        if (persistentSelection != null) {
          for (final p in persistentSelection) {
            if (p.$1 == srcIndex) {
              linePersistentSelections.add(p);
            }
          }
        }
        if (lineSelection != null &&
            lineSelection.$2 >= 0 &&
            lineSelection.$3 > lineSelection.$2) {
          lineChild = _QuranReaderState._buildV1LineWithAyahOverlayStatic(
              line, scaledW, lineSelection.$2, lineSelection.$3,
              fontSizeScale: fontSizeScale,
              uniformAyahScale: uniformAyahScale,
              linePad: bodyLinePad,
              useWhiteTextOnDark: useWhiteTextOnDark,
              ayahLineHeight: ayahLineHeight,
              wordRange: lineWordSelection != null
                  ? (lineWordSelection.$2, lineWordSelection.$3)
                  : null,
              persistentAlso: linePersistentSelections.isEmpty
                  ? null
                  : linePersistentSelections);
        } else if (linePersistentSelections.isNotEmpty &&
            line.lineType == 'ayah') {
          lineChild =
              _QuranReaderState._buildV1LineWithPersistentHighlightsStatic(
            line,
            scaledW,
            linePersistentSelections,
            fontSizeScale: fontSizeScale,
            uniformAyahScale: uniformAyahScale,
            linePad: bodyLinePad,
            useWhiteTextOnDark: useWhiteTextOnDark,
            ayahLineHeight: ayahLineHeight,
            wordRange: lineWordSelection != null
                ? (lineWordSelection.$2, lineWordSelection.$3)
                : null,
          );
        } else if (lineWordSelection != null &&
            lineWordSelection.$2 >= 0 &&
            lineWordSelection.$3 > lineWordSelection.$2 &&
            line.lineType == 'ayah') {
          lineChild = _QuranReaderState._buildV1LineWithWordOverlayOnlyStatic(
              line, scaledW, lineWordSelection.$2, lineWordSelection.$3,
              fontSizeScale: fontSizeScale,
              uniformAyahScale: uniformAyahScale,
              linePad: bodyLinePad,
              useWhiteTextOnDark: useWhiteTextOnDark,
              ayahLineHeight: ayahLineHeight);
        } else if (line.lineType == 'surah_name') {
          lineChild = _QuranReaderState._buildSurahNameLineStatic(line, scaledW,
              fontSizeScale: fontSizeScale,
              linePad: bodyLinePad,
              useWhiteTextOnDark: useWhiteTextOnDark);
        } else {
          lineChild = _QuranReaderState._buildLineStatic(line,
              contentW: scaledW,
              fontSizeScale: fontSizeScale,
              uniformAyahScale: uniformAyahScale,
              linePad: bodyLinePad,
              useWhiteTextOnDark: useWhiteTextOnDark,
              ayahLineHeight: ayahLineHeight);
        }
      }
      slots.add(SizedBox(
        height: slotHeight,
        child: Align(
          alignment: Alignment.topCenter,
          child: lineChild,
        ),
      ));
    }
    Widget content = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: slots,
    );
    if (mapping != null) {
      final lineHeights15 =
          List<double>.filled(kMushafLineSlotCount, slotHeight);
      content = DelayedLongPressDetector(
        duration: const Duration(milliseconds: 400),
        onTrigger: (Offset pos) {
          final adjustedPos = (page == 1 || page == 2)
              ? pos.translate(0, -3 * slotHeight)
              : pos;
          onQpcPageLongPress(
            context,
            adjustedPos,
            scaledW,
            layoutHeight,
            lineHeights15,
            displayLines,
            const TextStyle(),
            mapping,
            (line, _) => _v1LineStyleFromLine(
              line,
              fontSizeScale: squeezedBaseFontScale * uniformAyahScale,
              useWhiteTextOnDark: useWhiteTextOnDark,
              ayahLineHeight: ayahLineHeight,
            ),
            onSelectLine: onSelectLine,
            onClearSelection: onClearSelection,
            lineTextHorizontallyCentered: false,
            hitTestLayoutFullColumnWidth: true,
            uniformAyahScale: 1.0,
            hitTestTextScaler: TextScaler.noScaling,
            lineHitTestYTolerance: 3.0,
          );
        },
        child: content,
      );
    }
    Widget buildV1ColumnBox() {
      return SizedBox(
        width: scaledW,
        height: layoutHeight,
        child: content,
      );
    }

    final columnAlign = omitVertical ? Alignment.topCenter : Alignment.center;
    final innerSized = SizedBox(
      width: metrics.innerWidth,
      height: metrics.innerHeight,
      child: Align(
        alignment: columnAlign,
        child: buildV1ColumnBox(),
      ),
    );

    // نفس هيكل QPC4: ScrollView + minHeight حتى يتطابق عرض منطقة الهوامش مع V4
    // (2% من عرض constraints الكامل). بدون ذلك قد يضيق عرض المحتوى فيُحسب
    // الهامش من عرض أصغر فيبدو أقل من 2% من عرض الصفحة الظاهر.
    final paddedBody = Padding(
      padding: EdgeInsets.only(
        left: metrics.leftMargin,
        right: metrics.rightMargin,
        top: metrics.topMargin,
        bottom: metrics.bottomMargin,
      ),
      child: Align(
        alignment: columnAlign,
        child: RepaintBoundary(
          child: ColoredBox(
            color: MushafPaperBackgroundScope.of(context),
            child: innerSized,
          ),
        ),
      ),
    );

    return SizedBox(
      width: constraints.maxWidth,
      height: constraints.maxHeight,
      child: SingleChildScrollView(
        primary: false,
        physics: const NeverScrollableScrollPhysics(),
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.maxHeight),
          child: paddedBody,
        ),
      ),
    );
  }

  static Widget _buildLineStatic(MushafPageLine line,
      {double? contentW,
      double fontSizeScale = 1.0,
      double uniformAyahScale = 1.0,
      double? linePad,
      bool useWhiteTextOnDark = false,
      double? ayahLineHeight}) {
    final pad = linePad ?? _linePaddingBottom;
    final alignment =
        line.isCentered ? Alignment.center : Alignment.centerRight;
    final fs = line.lineType == 'ayah'
        ? fontSizeScale * uniformAyahScale
        : fontSizeScale;
    final baseStyle = _v1LineStyleFromLine(
      line,
      fontSizeScale: fs,
      useWhiteTextOnDark: useWhiteTextOnDark,
      ayahLineHeight: ayahLineHeight,
    );
    final effectiveStyle =
        (contentW != null && line.lineType == 'ayah' && !line.isCentered)
            ? getJustifiedLineStyle(line, baseStyle, contentW)
            : baseStyle;
    final inner = (line.lineType == 'basmallah')
        ? Transform.translate(
            offset: Offset(0, _QuranReaderState._basmallahRaiseDy * fs),
            child: Text(
              line.lineText,
              textDirection: TextDirection.rtl,
              textAlign: TextAlign.center,
              softWrap: false,
              maxLines: 1,
              overflow: TextOverflow.visible,
              style: effectiveStyle,
            ),
          )
        : Text(
            line.lineText,
            textDirection: TextDirection.rtl,
            textAlign: line.isCentered ? TextAlign.center : TextAlign.right,
            softWrap: false,
            maxLines: 1,
            overflow: TextOverflow.visible,
            style: effectiveStyle,
          );
    // أسطر الآية: نفس هيكل [mushafHighlightLineStackFixed] المستخدم مع التضليل
    // (عرض/ارتفاع ثابتان + Positioned.fill) حتى يتطابق [TextPainter.layout] مع [RenderParagraph].
    if (line.lineType == 'ayah' && contentW != null) {
      final layoutPainter = mushafLaidOutRtlLinePainterV1Highlight(
        line.lineText,
        effectiveStyle,
        contentW,
        lineCentered: line.isCentered,
      );
      return _v1AyahLineVisualShellStatic(
        line: line,
        lineWidth: contentW,
        lineHeight: layoutPainter.height,
        lineStyle: effectiveStyle,
        overlayWidgets: const [],
        padding: EdgeInsets.only(bottom: pad),
      );
    }
    if (line.lineType == 'ayah') {
      return Padding(
        padding: EdgeInsets.only(bottom: pad),
        child: Align(
          alignment: alignment,
          child: SizedBox(width: double.infinity, child: inner),
        ),
      );
    }
    return Padding(
      padding: EdgeInsets.only(bottom: pad),
      child: Align(
        alignment: alignment,
        child: SizedBox(
          width: double.infinity,
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: _kV1FittedLineAlignment,
            child: inner,
          ),
        ),
      ),
    );
  }

  static Widget _buildSurahNameLineStatic(MushafPageLine line, double contentW,
      {double fontSizeScale = 1.0,
      double? linePad,
      bool useWhiteTextOnDark = false}) {
    final pad = linePad ?? _linePaddingBottom;
    final frameHeight = contentW * _surahFrameAspect;
    return Padding(
      padding: EdgeInsets.only(bottom: pad),
      child: SizedBox(
        width: contentW,
        height: frameHeight,
        child: Stack(
          fit: StackFit.expand,
          alignment: Alignment.center,
          children: [
            SvgPicture.asset(
              'assets/icon/sura_name.svg',
              fit: BoxFit.contain,
            ),
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                mushafSurahTitleDisplayText(line.lineText),
                textDirection: TextDirection.rtl,
                style: _v1LineStyleFromLine(
                  line,
                  fontSizeScale: fontSizeScale,
                  useWhiteTextOnDark: useWhiteTextOnDark,
                ).copyWith(fontFamily: _surahNameFontFamily),
              ),
            ),
          ],
        ),
      ),
    );
  }

  static Widget _buildV1LineWithPersistentHighlightsStatic(
    MushafPageLine line,
    double contentW,
    List<(int lineIndex, int startChar, int endChar, Color color)>
        persistentSelections, {
    (int, int)? wordRange,
    double fontSizeScale = 1.0,
    double uniformAyahScale = 1.0,
    double? linePad,
    bool useWhiteTextOnDark = false,
    double? ayahLineHeight,
  }) {
    final pad = linePad ?? _linePaddingBottom;
    final fs = fontSizeScale * uniformAyahScale;
    final baseStyle = _v1LineStyleFromLine(
      line,
      fontSizeScale: fs,
      useWhiteTextOnDark: useWhiteTextOnDark,
      ayahLineHeight: ayahLineHeight,
    );
    final lineStyle = line.isCentered
        ? baseStyle
        : getJustifiedLineStyle(line, baseStyle, contentW);
    final layoutMaxW = contentW;
    final painter = mushafLaidOutRtlLinePainterV1Highlight(
      line.lineText,
      lineStyle,
      layoutMaxW,
      lineCentered: line.isCentered,
    );
    final lineWidth = layoutMaxW;
    final v1WordSpacingJustified =
        _v1LineUsesWordSpacingJustification(line, baseStyle, lineStyle);
    final rtlGeom = !line.isCentered && !v1WordSpacingJustified;
    final leftAdjust = _v1ResolvedLineLeftAdjustment(
      line: line,
      painter: painter,
      lineWidth: lineWidth,
    );
    final v1FlatBand = mushafHighlightBandFromLineMetrics(painter);

    final persistentRects = <({double left, double width, Color color})>[];
    for (final sel in persistentSelections) {
      final start = sel.$2.clamp(0, line.lineText.length);
      final end = sel.$3.clamp(0, line.lineText.length);
      if (end <= start) continue;
      final rect = mushafWordHighlightRect(
        painter: painter,
        text: line.lineText,
        style: lineStyle,
        startChar: start,
        endChar: end,
        rtlRightAlignedLayoutWidth: lineWidth,
        rtlRightAlignedLayoutWidthIsMeaningful: rtlGeom,
        preferCaretHorizontalBounds: v1WordSpacingJustified,
      );
      if (rect != null && rect.width > 0.01) {
        persistentRects.add(
            (left: rect.left + leftAdjust, width: rect.width, color: sel.$4));
      }
    }
    final mergedPersistentRects =
        _mergeV1PersistentRectsByColor(persistentRects);
    if (mergedPersistentRects.isEmpty) {
      return _buildLineStatic(
        line,
        contentW: contentW,
        fontSizeScale: fontSizeScale,
        uniformAyahScale: uniformAyahScale,
        linePad: linePad,
        useWhiteTextOnDark: useWhiteTextOnDark,
        ayahLineHeight: ayahLineHeight,
      );
    }

    final wordColor =
        useWhiteTextOnDark ? const Color(0xFF7CFFC4) : const Color(0xFFB8E6C1);
    final wordAlpha = useWhiteTextOnDark ? 0.48 : 0.30;
    final overlayWidgets = <Widget>[
      for (final r in mergedPersistentRects)
        _buildV1PersistentHighlightSegment(r, painter.height),
    ];
    if (wordRange != null &&
        wordRange.$1 >= 0 &&
        wordRange.$2 <= line.lineText.length &&
        wordRange.$2 > wordRange.$1) {
      final wordR = mushafRangeHorizontalRectWithFallback(
        painter: painter,
        text: line.lineText,
        style: lineStyle,
        startChar: wordRange.$1.clamp(0, line.lineText.length),
        endChar: wordRange.$2.clamp(0, line.lineText.length),
        rtlRightAlignedLayoutWidth: lineWidth,
        rtlRightAlignedLayoutWidthIsMeaningful: rtlGeom,
        preferCaretHorizontalBounds: v1WordSpacingJustified,
      );
      if (wordR.width > 0.01) {
        overlayWidgets.add(mushafFlatHighlightBar(
          left: wordR.left + leftAdjust,
          width: wordR.width,
          lineHeight: painter.height,
          bandTop: v1FlatBand.top,
          bandHeight: v1FlatBand.height,
          color: wordColor,
          alpha: wordAlpha,
        ));
      }
    }
    return _v1AyahLineVisualShellStatic(
      line: line,
      lineWidth: lineWidth,
      lineHeight: painter.height,
      lineStyle: lineStyle,
      overlayWidgets: overlayWidgets,
      padding: EdgeInsets.only(bottom: pad),
    );
  }

  static Widget _buildV1LineWithAyahOverlayStatic(
      MushafPageLine line, double contentW, int startChar, int endChar,
      {(int, int)? wordRange,
      List<(int, int, int, Color)>? persistentAlso,
      double fontSizeScale = 1.0,
      double uniformAyahScale = 1.0,
      double? linePad,
      bool useWhiteTextOnDark = false,
      double? ayahLineHeight}) {
    final pad = linePad ?? _linePaddingBottom;
    final fs = fontSizeScale * uniformAyahScale;
    final baseStyle = _v1LineStyleFromLine(
      line,
      fontSizeScale: fs,
      useWhiteTextOnDark: useWhiteTextOnDark,
      ayahLineHeight: ayahLineHeight,
    );
    final lineStyle = line.isCentered
        ? baseStyle
        : getJustifiedLineStyle(line, baseStyle, contentW);
    final layoutMaxW = contentW;
    final painter = mushafLaidOutRtlLinePainterV1Highlight(
      line.lineText,
      lineStyle,
      layoutMaxW,
      lineCentered: line.isCentered,
    );
    final lineWidth = layoutMaxW;
    final v1WordSpacingJustified =
        _v1LineUsesWordSpacingJustification(line, baseStyle, lineStyle);
    final rtlGeom = !line.isCentered && !v1WordSpacingJustified;
    final leftAdjust = _v1ResolvedLineLeftAdjustment(
      line: line,
      painter: painter,
      lineWidth: lineWidth,
    );
    final v1FlatBand = mushafHighlightBandFromLineMetrics(painter);
    final ayahR = mushafRangeHorizontalRectWithFallback(
      painter: painter,
      text: line.lineText,
      style: lineStyle,
      startChar: startChar.clamp(0, line.lineText.length),
      endChar: endChar.clamp(0, line.lineText.length),
      rtlRightAlignedLayoutWidth: lineWidth,
      rtlRightAlignedLayoutWidthIsMeaningful: rtlGeom,
      preferCaretHorizontalBounds: v1WordSpacingJustified,
    );

    final ayahColor = useWhiteTextOnDark
        ? const Color(0xFFB3E5FC)
        : const Color.fromARGB(255, 45, 45, 45);
    final wordColor =
        useWhiteTextOnDark ? const Color(0xFF7CFFC4) : const Color(0xFFB8E6C1);
    final ayahAlpha = useWhiteTextOnDark ? 0.34 : 0.18;
    final wordAlpha = useWhiteTextOnDark ? 0.48 : 0.30;
    final overlayWidgets = <Widget>[];
    if (persistentAlso != null && persistentAlso.isNotEmpty) {
      final persistentRects = <({double left, double width, Color color})>[];
      for (final sel in persistentAlso) {
        final rect = mushafWordHighlightRect(
          painter: painter,
          text: line.lineText,
          style: lineStyle,
          startChar: sel.$2.clamp(0, line.lineText.length),
          endChar: sel.$3.clamp(0, line.lineText.length),
          rtlRightAlignedLayoutWidth: lineWidth,
          rtlRightAlignedLayoutWidthIsMeaningful: rtlGeom,
          preferCaretHorizontalBounds: v1WordSpacingJustified,
        );
        if (rect != null && rect.width > 0.01) {
          persistentRects.add(
              (left: rect.left + leftAdjust, width: rect.width, color: sel.$4));
        }
      }
      for (final r in _mergeV1PersistentRectsByColor(persistentRects)) {
        overlayWidgets
            .add(_buildV1PersistentHighlightSegment(r, painter.height));
      }
    }
    overlayWidgets.add(
      mushafFlatHighlightBar(
        left: ayahR.left + leftAdjust,
        width: ayahR.width,
        lineHeight: painter.height,
        bandTop: v1FlatBand.top,
        bandHeight: v1FlatBand.height,
        color: ayahColor,
        alpha: ayahAlpha,
      ),
    );
    if (wordRange != null &&
        wordRange.$1 >= 0 &&
        wordRange.$2 <= line.lineText.length &&
        wordRange.$2 > wordRange.$1) {
      final wordR = mushafRangeHorizontalRectWithFallback(
        painter: painter,
        text: line.lineText,
        style: lineStyle,
        startChar: wordRange.$1.clamp(0, line.lineText.length),
        endChar: wordRange.$2.clamp(0, line.lineText.length),
        rtlRightAlignedLayoutWidth: lineWidth,
        rtlRightAlignedLayoutWidthIsMeaningful: rtlGeom,
        preferCaretHorizontalBounds: v1WordSpacingJustified,
      );
      if (wordR.width > 0.01) {
        overlayWidgets.add(mushafFlatHighlightBar(
          left: wordR.left + leftAdjust,
          width: wordR.width,
          lineHeight: painter.height,
          bandTop: v1FlatBand.top,
          bandHeight: v1FlatBand.height,
          color: wordColor,
          alpha: wordAlpha,
        ));
      }
    }
    return _v1AyahLineVisualShellStatic(
      line: line,
      lineWidth: lineWidth,
      lineHeight: painter.height,
      lineStyle: lineStyle,
      overlayWidgets: overlayWidgets,
      padding: EdgeInsets.only(bottom: pad),
    );
  }

  /// رسم سطر آية بتأشير كلمة القراءة فقط (عند إطفاء تأشير الآية).
  static Widget _buildV1LineWithWordOverlayOnlyStatic(
      MushafPageLine line, double contentW, int wordStart, int wordEnd,
      {double fontSizeScale = 1.0,
      double uniformAyahScale = 1.0,
      double? linePad,
      bool useWhiteTextOnDark = false,
      double? ayahLineHeight}) {
    final pad = linePad ?? _linePaddingBottom;
    final fs = fontSizeScale * uniformAyahScale;
    final baseStyle = _v1LineStyleFromLine(
      line,
      fontSizeScale: fs,
      useWhiteTextOnDark: useWhiteTextOnDark,
      ayahLineHeight: ayahLineHeight,
    );
    final lineStyle = line.isCentered
        ? baseStyle
        : getJustifiedLineStyle(line, baseStyle, contentW);
    final layoutMaxW = contentW;
    final painter = mushafLaidOutRtlLinePainterV1Highlight(
      line.lineText,
      lineStyle,
      layoutMaxW,
      lineCentered: line.isCentered,
    );
    final lineWidth = layoutMaxW;
    final v1WordSpacingJustified =
        _v1LineUsesWordSpacingJustification(line, baseStyle, lineStyle);
    final rtlGeom = !line.isCentered && !v1WordSpacingJustified;
    final leftAdjust = _v1ResolvedLineLeftAdjustment(
      line: line,
      painter: painter,
      lineWidth: lineWidth,
    );
    final v1FlatBand = mushafHighlightBandFromLineMetrics(painter);
    if (wordStart < 0 ||
        wordEnd > line.lineText.length ||
        wordEnd <= wordStart) {
      return _buildLineStatic(line,
          contentW: contentW,
          fontSizeScale: fontSizeScale,
          uniformAyahScale: uniformAyahScale,
          linePad: linePad,
          useWhiteTextOnDark: useWhiteTextOnDark,
          ayahLineHeight: ayahLineHeight);
    }
    final wordR = mushafRangeHorizontalRectWithFallback(
      painter: painter,
      text: line.lineText,
      style: lineStyle,
      startChar: wordStart.clamp(0, line.lineText.length),
      endChar: wordEnd.clamp(0, line.lineText.length),
      rtlRightAlignedLayoutWidth: lineWidth,
      rtlRightAlignedLayoutWidthIsMeaningful: rtlGeom,
      preferCaretHorizontalBounds: v1WordSpacingJustified,
    );
    if (wordR.width <= 0.01) {
      return _buildLineStatic(line,
          contentW: contentW,
          fontSizeScale: fontSizeScale,
          uniformAyahScale: uniformAyahScale,
          linePad: linePad,
          useWhiteTextOnDark: useWhiteTextOnDark,
          ayahLineHeight: ayahLineHeight);
    }
    final ayahColor = useWhiteTextOnDark
        ? const Color(0xFFB3E5FC)
        : const Color.fromARGB(255, 45, 45, 45);
    final ayahAlpha = useWhiteTextOnDark ? 0.34 : 0.18;
    return _v1AyahLineVisualShellStatic(
      line: line,
      lineWidth: lineWidth,
      lineHeight: painter.height,
      lineStyle: lineStyle,
      overlayWidgets: [
        mushafFlatHighlightBar(
          left: wordR.left + leftAdjust,
          width: wordR.width,
          lineHeight: painter.height,
          bandTop: v1FlatBand.top,
          bandHeight: v1FlatBand.height,
          color: ayahColor,
          alpha: ayahAlpha,
        ),
      ],
      padding: EdgeInsets.only(bottom: pad),
    );
  }

  Widget _buildBody() {
    return Stack(
      children: [
        NotificationListener<ScrollNotification>(
          onNotification: (n) {
            if (n is ScrollStartNotification && n.dragDetails != null) {
              _dragSettleTimer?.cancel();
              _qualityTierTimer?.cancel();
              _lastDragPixels = n.metrics.pixels;
              _lastDragElapsedUs = _dragStopwatch.elapsedMicroseconds;
              _isDraggingPages = true; // حقل عادي — لا setState
              _setRenderTier(_PageRenderTier.lite); // ValueNotifier — لا setState
            } else if (n is ScrollUpdateNotification) {
              final nowUs = _dragStopwatch.elapsedMicroseconds;
              final lastPx = _lastDragPixels;
              final lastUs = _lastDragElapsedUs;
              if (lastPx != null && lastUs != null) {
                final dtUs = nowUs - lastUs;
                if (dtUs > 0) {
                  final v =
                      ((n.metrics.pixels - lastPx).abs() * 1000000.0) / dtUs;
                  _recentDragVelocityPxPerSec =
                      (_recentDragVelocityPxPerSec * 0.65) + (v * 0.35);
                }
              }
              _lastDragPixels = n.metrics.pixels;
              _lastDragElapsedUs = nowUs;
            } else if (n is ScrollEndNotification ||
                (n is UserScrollNotification &&
                    n.direction == ScrollDirection.idle)) {
              _lastDragPixels = null;
              _lastDragElapsedUs = null;
              _dragSettleTimer?.cancel();
              _dragSettleTimer = Timer(const Duration(milliseconds: 200), () {
                if (!mounted) return;
                _isDraggingPages = false; // حقل عادي — لا setState
                _qualityTierTimer?.cancel();
                // medium أولاً: تُحمَّل الخريطة فقط بدون highlights كاملة
                _setRenderTier(_PageRenderTier.medium);
                _qualityTierTimer = Timer(const Duration(milliseconds: 350), () {
                  if (!mounted) return;
                  // full في idle frame — يضمن عدم تعارضه مع أي animation جارية
                  SchedulerBinding.instance.scheduleTask(
                    () {
                      if (mounted) _setRenderTier(_PageRenderTier.full);
                    },
                    Priority.idle,
                  );
                });
              });
            }
            return false;
          },
          child: PageView.builder(
            dragStartBehavior: DragStartBehavior.down,
            itemCount: totalPages,
            controller: _pageController,
            reverse: false,
            physics: const _ProfessionalPageScrollPhysics(),
            allowImplicitScrolling: false,
            onPageChanged: (index) {
              // embedded=true: build() يُرجع _buildBody() مباشرة دون استخدام _currentPageIndex
              // لا فائدة من setState في هذه الحالة — نحدّث الحقل مباشرة
              if (!widget.embedded) {
                setState(() => _currentPageIndex = index);
              } else {
                _currentPageIndex = index;
              }
              widget.onPageChanged?.call(index + 1);
              final pageNum = index + 1;
              final radius = _isDraggingPages ? _preloadRadiusForCurrentDrag() : 2;
              PageCache.instance.trimRamToNearbyPages(pageNum);
              if (_effectiveMode == QpcMushafMode.qpc4 ||
                  _effectiveMode == QpcMushafMode.qpc4Black) {
                preloadNearbyPages(pageNum, before: radius, after: radius);
              } else if (_effectiveMode == QpcMushafMode.qpc1) {
                _preloadV1Pages(pageNum, before: radius, after: radius);
              }
            },
            itemBuilder: (context, index) {
              final page = index + 1;
              final mode = _effectiveMode;
              final topBarBuilder = widget.buildTopBarForPage;
              return ValueListenableBuilder<_PageRenderTier>(
                valueListenable: _renderTierNotifier,
                builder: (context, tier, _) {
                  final pageContent = buildQpcPageContent(
                    context,
                    page,
                    mode,
                    forceWhiteMushafText: widget.forceWhiteMushafText,
                    lightweightMode: tier == _PageRenderTier.lite,
                    mediumQualityMode: tier == _PageRenderTier.medium,
                  );
                  // cacheKey يشمل الوضع والصفحة ولون النص
                  final cacheKey =
                      '${mode.name}-$page${widget.forceWhiteMushafText ? '-w' : ''}';
                  final wrappedContent = _RasterCapturePageWrapper(
                    cacheKey: cacheKey,
                    tier: tier,
                    child: pageContent,
                  );
                  if (topBarBuilder != null) {
                    if (mode == QpcMushafMode.qpc1 ||
                        mode == QpcMushafMode.qpc4 ||
                        mode == QpcMushafMode.qpc4Black) {
                      return Column(
                        children: [
                          topBarBuilder(page),
                          Expanded(child: wrappedContent),
                          _buildV1PageNumberRow(page),
                        ],
                      );
                    }
                    return Column(
                      children: [
                        topBarBuilder(page),
                        Expanded(child: wrappedContent),
                      ],
                    );
                  }
                  return wrappedContent;
                },
              );
            },
          ),
        ),
        Positioned.fill(
          child: _TapOverlay(
            onTap: widget.embedded ? (widget.onTap ?? () {}) : _goBackToMain,
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final pageNumber = _currentPageIndex + 1;
    if (_initError != null) {
      if (widget.embedded) {
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              'حدث خطأ أثناء تحميل قاعدة البيانات. أعد المحاولة.',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 16),
            ),
          ),
        );
      }
      return Scaffold(
        appBar: AppBar(title: const Text('قارئ المصحف QPC')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              'حدث خطأ أثناء تحميل قاعدة البيانات. أعد المحاولة.',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 16),
            ),
          ),
        ),
      );
    }
    if (!_dbReady) {
      if (widget.embedded) {
        return const Center(child: CircularProgressIndicator());
      }
      return Scaffold(
        appBar: AppBar(title: const Text('قارئ المصحف QPC')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    if (widget.embedded) return _buildBody();
    return Scaffold(
      appBar: AppBar(
        title: Text('ص $pageNumber / $totalPages'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: _goBackToMain,
          tooltip: 'العودة للصفحة الرئيسية',
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.chevron_right),
            onPressed: () {
              if (_currentPageIndex > 0) {
                _pageController.previousPage(
                  duration: const Duration(milliseconds: 300),
                  curve: Curves.easeInOut,
                );
              }
            },
            tooltip: 'الصفحة السابقة',
          ),
          IconButton(
            icon: const Icon(Icons.chevron_left),
            onPressed: () {
              if (_currentPageIndex < totalPages - 1) {
                _pageController.nextPage(
                  duration: const Duration(milliseconds: 300),
                  curve: Curves.easeInOut,
                );
              }
            },
            tooltip: 'الصفحة التالية',
          ),
          IconButton(
            icon: const Icon(Icons.tune),
            onPressed: _showModeSheet,
            tooltip: 'تغيير الوضع (V1 / V4 / V4 أسود)',
          ),
        ],
      ),
      body: _buildBody(),
    );
  }
}

class _V1PageContentStateful extends StatefulWidget {
  const _V1PageContentStateful({
    required this.constraints,
    required this.page,
    required this.contentW,
    required this.contentH,
    required this.lineHeights,
    required this.pageLines,
    required this.mapping,
    required this.buildContent,
  });
  final BoxConstraints constraints;
  final int page;
  final double contentW;
  final double contentH;
  final List<double> lineHeights;
  final List<MushafPageLine> pageLines;
  final Map<int, (int sura, int ayah)>? mapping;
  final Widget Function(
    BuildContext context,
    List<(int lineIndex, int startChar, int endChar)>? selection,
    List<(int lineIndex, int startChar, int endChar, Color color)>?
        persistentSelection,
    (int lineIndex, int startChar, int endChar)? wordSelection,
    void Function(List<(int lineIndex, int startChar, int endChar)>)?
        onSelectLine,
    void Function()? onClearSelection,
  ) buildContent;

  @override
  State<_V1PageContentStateful> createState() => _V1PageContentStatefulState();
}

class _V1PageContentStatefulState extends State<_V1PageContentStateful> {
  List<(int, int, int)>? _selection;
  List<(int, int, int, Color)>? _persistentSelection;
  int? _lastAudioSura;
  int? _lastAudioAyah;
  int _lastAudioSegmentIndex = -1;
  Object? _lastAudioSegmentToken;
  bool _lastAudioActive = false;
  bool _lastShowAyahHighlight = false;

  @override
  void initState() {
    super.initState();
    AyahAudioPlayer.instance.addListener(_onAudioChanged);
    AyahHighlightStore.instance.addListener(_syncPersistentHighlights);
    _syncPersistentHighlights();
  }

  @override
  void dispose() {
    AyahAudioPlayer.instance.removeListener(_onAudioChanged);
    AyahHighlightStore.instance.removeListener(_syncPersistentHighlights);
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant _V1PageContentStateful oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncPersistentHighlights();
  }

  void _onAudioChanged() {
    final player = AyahAudioPlayer.instance;
    final nextActive = player.isActive;
    final nextSura = player.currentSura;
    final nextAyah = player.currentAyah;
    final nextSegIndex = player.currentSegmentIndex;
    final nextSegToken = player.currentSegmentToken;
    final nextShow = player.showAyahHighlight;
    final changed = _lastAudioActive != nextActive ||
        _lastAudioSura != nextSura ||
        _lastAudioAyah != nextAyah ||
        _lastAudioSegmentIndex != nextSegIndex ||
        _lastAudioSegmentToken != nextSegToken ||
        _lastShowAyahHighlight != nextShow;
    if (!changed) return;
    _lastAudioActive = nextActive;
    _lastAudioSura = nextSura;
    _lastAudioAyah = nextAyah;
    _lastAudioSegmentIndex = nextSegIndex;
    _lastAudioSegmentToken = nextSegToken;
    _lastShowAyahHighlight = nextShow;
    if (mounted) setState(() {});
  }

  void _syncPersistentHighlights() {
    final mapping = widget.mapping;
    if (mapping == null || AyahHighlightStore.instance.ranges.isEmpty) {
      if (_persistentSelection != null) {
        setState(() => _persistentSelection = null);
      }
      return;
    }
    final entries = <(int, int, int, Color)>[];
    for (final range in AyahHighlightStore.instance.ranges) {
      final from =
          range.fromAyah <= range.toAyah ? range.fromAyah : range.toAyah;
      final to = range.fromAyah <= range.toAyah ? range.toAyah : range.fromAyah;
      for (int ayah = from; ayah <= to; ayah++) {
        final ranges =
            getAyahRangesForPage(range.sura, ayah, widget.pageLines, mapping);
        for (final e in ranges) {
          entries.add((e.$1, e.$2, e.$3, range.color));
        }
      }
    }
    entries.sort((a, b) {
      final lineCmp = a.$1.compareTo(b.$1);
      if (lineCmp != 0) return lineCmp;
      final colorCmp = a.$4.toARGB32().compareTo(b.$4.toARGB32());
      if (colorCmp != 0) return colorCmp;
      final startCmp = a.$2.compareTo(b.$2);
      if (startCmp != 0) return startCmp;
      return a.$3.compareTo(b.$3);
    });
    if (entries.isEmpty) {
      if (_persistentSelection != null) {
        setState(() => _persistentSelection = null);
      }
      return;
    }
    setState(() => _persistentSelection = entries);
  }

  @override
  Widget build(BuildContext context) {
    List<(int, int, int)>? effectiveSelection = _selection;
    (int, int, int)? effectiveWordSelection;

    final player = AyahAudioPlayer.instance;
    if (player.isActive &&
        player.currentSura != null &&
        player.currentAyah != null &&
        widget.mapping != null) {
      final sura = player.currentSura!;
      final ayah = player.currentAyah!;
      final ranges = getAyahRangesForPage(
        sura,
        ayah,
        widget.pageLines,
        widget.mapping!,
      );
      if (ranges.isNotEmpty) {
        if (effectiveSelection == null) {
          effectiveSelection = player.showAyahHighlight ? ranges : null;
        }
        final wordRange = getAyahWordRangeForPage(
          sura,
          ayah,
          player.currentSegmentIndex,
          player.currentSegmentToken,
          widget.pageLines,
          widget.mapping!,
        );
        effectiveWordSelection = wordRange;
      }
    }

    return widget.buildContent(
      context,
      effectiveSelection,
      _persistentSelection,
      effectiveWordSelection,
      (List<(int, int, int)> ranges) => setState(() => _selection = ranges),
      () => setState(() => _selection = null),
    );
  }
}
