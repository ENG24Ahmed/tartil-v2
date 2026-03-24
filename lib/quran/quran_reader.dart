import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
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
import 'package:quran_app/audio/ayah_audio_player.dart';
import 'package:quran_app/quran/renderers/qpc_v4_renderer.dart'
    show
        AyahHighlightStore,
        DelayedLongPressDetector,
        QpcV4PageView,
        QpcV4Renderer,
        getAyahRangesForPage,
        getAyahWordRangeForPage,
        getJustifiedLineStyle,
        kQpcPageMarginFraction,
        kQpcPageMarginLeftFraction,
        onQpcPageLongPress,
        preloadNearbyPages;

enum QpcMushafMode { qpc1, qpc4, qpc4Black }

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

/// مكوّن صفحة واحد يُستخدم في جميع أنواع العرض (افتراضي، أفقي، صفحتان، قراءة طويلة).
Widget buildQpcPageContent(
  BuildContext context,
  int page,
  QpcMushafMode mode, {
  bool forceWhiteMushafText = false,
}) {
  if (mode == QpcMushafMode.qpc4) return QpcV4PageView(page: page);
  if (mode == QpcMushafMode.qpc4Black) {
    return QpcV4BlackPageView(
      page: page,
      forceWhiteTextOnDark: forceWhiteMushafText,
    );
  }
  final cached = tryGetQpcV1FromCache(page);
  if (cached != null) {
    return _QpcV1PageFromLinesWidget(
      page: page,
      pageLines: cached,
      forceWhiteMushafText: forceWhiteMushafText,
    );
  }
  return FutureBuilder<List<MushafPageLine>>(
    future: loadQpcV1PageForDisplay(page),
    builder: (context, snapshot) {
      if (snapshot.connectionState == ConnectionState.waiting) {
        return const ColoredBox(color: Colors.transparent);
      }
      if (snapshot.hasError) {
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              'فشل تحميل الصفحة: ${snapshot.error}',
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
      );
    },
  );
}

/// عرض صفحة QPC V1 من الأسطر المحملة (يُستخدم من buildQpcPageContent).
class _QpcV1PageFromLinesWidget extends StatelessWidget {
  const _QpcV1PageFromLinesWidget({
    required this.page,
    required this.pageLines,
    required this.forceWhiteMushafText,
  });
  final int page;
  final List<MushafPageLine> pageLines;
  final bool forceWhiteMushafText;

  @override
  Widget build(BuildContext context) {
    return _QuranReaderState.buildV1PageFromLinesStatic(
      context,
      page,
      pageLines,
      forceWhiteMushafText: forceWhiteMushafText,
    );
  }
}

/// فيزياء تقليب سلسة: عتبة 50%، زنبرك ناعم، بدون حد لصفحة واحدة (يسبب طفرة).
class _SmoothPageScrollPhysics extends PageScrollPhysics {
  const _SmoothPageScrollPhysics({super.parent});

  @override
  _SmoothPageScrollPhysics applyTo(ScrollPhysics? ancestor) {
    return _SmoothPageScrollPhysics(parent: buildParent(ancestor));
  }

  @override
  Simulation? createBallisticSimulation(
      ScrollMetrics position, double velocity) {
    if ((velocity <= 0.0 && position.pixels <= position.minScrollExtent) ||
        (velocity >= 0.0 && position.pixels >= position.maxScrollExtent)) {
      return super.createBallisticSimulation(position, velocity);
    }
    final viewport = position.viewportDimension;
    if (viewport <= 0)
      return super.createBallisticSimulation(position, velocity);
    final page = position.pixels / viewport;
    final targetPage =
        page.roundToDouble().clamp(0.0, position.maxScrollExtent / viewport);
    final target = (targetPage * viewport)
        .clamp(position.minScrollExtent, position.maxScrollExtent);
    final tolerance = toleranceFor(position);
    return ScrollSpringSimulation(
      const SpringDescription(mass: 0.5, stiffness: 80, damping: 1.0),
      position.pixels,
      target,
      velocity,
      tolerance: tolerance,
    );
  }
}

/// طبقة لا تشارك في ساحة الإيماءات — تكتشف النقرة عبر Listener فقط حتى لا يمنع السحب الأول.
class _TapOverlay extends StatefulWidget {
  const _TapOverlay({required this.onTap});
  final VoidCallback onTap;

  @override
  State<_TapOverlay> createState() => _TapOverlayState();
}

class _TapOverlayState extends State<_TapOverlay> {
  Offset? _down;
  DateTime? _downTime;
  static const double _tapSlop = 18;
  static const Duration _tapMaxDuration = Duration(milliseconds: 300);

  void _onPointerDown(PointerDownEvent e) {
    _down = e.position;
    _downTime = DateTime.now();
  }

  void _onPointerUp(PointerUpEvent e) {
    final down = _down;
    final downTime = _downTime;
    _down = null;
    _downTime = null;
    if (down == null || downTime == null) return;
    final dx = (e.position.dx - down.dx).abs();
    final dy = (e.position.dy - down.dy).abs();
    final duration = DateTime.now().difference(downTime);
    if (dx <= _tapSlop && dy <= _tapSlop && duration <= _tapMaxDuration) {
      widget.onTap();
    }
  }

  void _onPointerCancel(PointerCancelEvent _) {
    _down = null;
    _downTime = null;
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: _onPointerDown,
      onPointerUp: _onPointerUp,
      onPointerCancel: _onPointerCancel,
      child: const SizedBox.expand(),
    );
  }
}

/// قارئ المصحف: QPC V1 أو V4 أو V4 أسود حسب الوضع المختار.
/// عند [embedded] = true يُستخدم كجسم داخل شاشة أخرى (بدون شريط علوي خاص).
/// عند توفير [buildTopBarForPage] يُضمَّن الشريط داخل كل صفحة فيُسحَب معها.
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
  static const String _surahNameFontFamily = 'SurahNameV4';
  static const double _basmallahRaiseDy = -2.0;
  static const String _basmallahFontFamily = 'KFGQPCHAFSUthmanicScript';
  final QuranDb _db = QuranDb.instance;
  late final PageController _pageController;
  bool _ownsController = false;

  static const int totalPages = 604;
  late int _currentPageIndex;
  bool _dbReady = false;
  String? _initError;
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
      if (mounted &&
          (_effectiveMode == QpcMushafMode.qpc4 ||
              _effectiveMode == QpcMushafMode.qpc4Black)) {
        preloadNearbyPages(_currentPageIndex + 1);
      }
    });
  }

  @override
  void dispose() {
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
    } catch (e) {
      if (mounted) {
        setState(() {
          _dbReady = false;
          _initError = '$e';
        });
      }
    }
  }

  static const String _v1CacheMode = 'qpc1';

  static const Map<int, String> _surahNames = {
    1: 'سورة الفاتحة',
    2: 'سورة البقرة',
    3: 'سورة آل عمران',
    4: 'سورة النساء',
    5: 'سورة المائدة',
    6: 'سورة الأنعام',
    7: 'سورة الأعراف',
    8: 'سورة الأنفال',
    9: 'سورة التوبة',
    10: 'سورة يونس',
    11: 'سورة هود',
    12: 'سورة يوسف',
    13: 'سورة الرعد',
    14: 'سورة إبراهيم',
    15: 'سورة الحجر',
    16: 'سورة النحل',
    17: 'سورة الإسراء',
    18: 'سورة الكهف',
    19: 'سورة مريم',
    20: 'سورة طه',
    21: 'سورة الأنبياء',
    22: 'سورة الحج',
    23: 'سورة المؤمنون',
    24: 'سورة النور',
    25: 'سورة الفرقان',
    26: 'سورة الشعراء',
    27: 'سورة النمل',
    28: 'سورة القصص',
    29: 'سورة العنكبوت',
    30: 'سورة الروم',
    31: 'سورة لقمان',
    32: 'سورة السجدة',
    33: 'سورة الأحزاب',
    34: 'سورة سبأ',
    35: 'سورة فاطر',
    36: 'سورة يس',
    37: 'سورة الصافات',
    38: 'سورة ص',
    39: 'سورة الزمر',
    40: 'سورة غافر',
    41: 'سورة فصلت',
    42: 'سورة الشورى',
    43: 'سورة الزخرف',
    44: 'سورة الدخان',
    45: 'سورة الجاثية',
    46: 'سورة الأحقاف',
    47: 'سورة محمد',
    48: 'سورة الفتح',
    49: 'سورة الحجرات',
    50: 'سورة ق',
    51: 'سورة الذاريات',
    52: 'سورة الطور',
    53: 'سورة النجم',
    54: 'سورة القمر',
    55: 'سورة الرحمن',
    56: 'سورة الواقعة',
    57: 'سورة الحديد',
    58: 'سورة المجادلة',
    59: 'سورة الحشر',
    60: 'سورة الممتحنة',
    61: 'سورة الصف',
    62: 'سورة الجمعة',
    63: 'سورة المنافقون',
    64: 'سورة التغابن',
    65: 'سورة الطلاق',
    66: 'سورة التحريم',
    67: 'سورة الملك',
    68: 'سورة القلم',
    69: 'سورة الحاقة',
    70: 'سورة المعارج',
    71: 'سورة نوح',
    72: 'سورة الجن',
    73: 'سورة المزمل',
    74: 'سورة المدثر',
    75: 'سورة القيامة',
    76: 'سورة الإنسان',
    77: 'سورة المرسلات',
    78: 'سورة النبأ',
    79: 'سورة النازعات',
    80: 'سورة عبس',
    81: 'سورة التكوير',
    82: 'سورة الانفطار',
    83: 'سورة المطففين',
    84: 'سورة الانشقاق',
    85: 'سورة البروج',
    86: 'سورة الطارق',
    87: 'سورة الأعلى',
    88: 'سورة الغاشية',
    89: 'سورة الفجر',
    90: 'سورة البلد',
    91: 'سورة الشمس',
    92: 'سورة الليل',
    93: 'سورة الضحى',
    94: 'سورة الشرح',
    95: 'سورة التين',
    96: 'سورة العلق',
    97: 'سورة القدر',
    98: 'سورة البينة',
    99: 'سورة الزلزلة',
    100: 'سورة العاديات',
    101: 'سورة القارعة',
    102: 'سورة التكاثر',
    103: 'سورة العصر',
    104: 'سورة الهمزة',
    105: 'سورة الفيل',
    106: 'سورة قريش',
    107: 'سورة الماعون',
    108: 'سورة الكوثر',
    109: 'سورة الكافرون',
    110: 'سورة النصر',
    111: 'سورة المسد',
    112: 'سورة الإخلاص',
    113: 'سورة الفلق',
    114: 'سورة الناس',
  };

  Future<List<MushafPageLine>> _loadPage(int page) async {
    if (_effectiveMode == QpcMushafMode.qpc4) {
      return QpcV4Renderer.instance.loadPage(page);
    }

    await loadQcfFont(page);
    final cached = PageCache.instance.get(_v1CacheMode, page);
    if (cached != null) {
      final hasSegments = cached.every((l) =>
          l.lineType != 'ayah' ||
          l.rangeStart == null ||
          (l.ayahSegments != null && l.ayahSegments!.isNotEmpty));
      if (hasSegments) return cached;
    }

    final persisted =
        await PagePersistentCache.instance.get(_v1CacheMode, page);
    if (persisted != null && persisted.isNotEmpty) {
      final hasSegments = persisted.every((l) =>
          l.lineType != 'ayah' ||
          l.rangeStart == null ||
          (l.ayahSegments != null && l.ayahSegments!.isNotEmpty));
      if (hasSegments) {
        PageCache.instance.put(_v1CacheMode, page, persisted);
        return persisted;
      }
    }

    final layout = await _db.getLayoutForPage(page);
    final lines = <MushafPageLine>[];
    final fontFamily = 'QCF_P${page.toString().padLeft(3, '0')}';

    for (final row in layout) {
      final isCentered = row['is_centered'] as bool? ?? false;
      final rangeStart = row['range_start'] as int? ?? 0;
      final rangeEnd = row['range_end'] as int? ?? 0;
      final rowType = (row['type']?.toString().trim().toLowerCase() ?? '');

      if (rowType == 'surah_name') {
        final surahTitle = _surahNames[rangeStart] ?? '';
        if (surahTitle.isNotEmpty) {
          lines.add(MushafPageLine(
            lineText: surahTitle,
            isCentered: true,
            fontFamily: fontFamily,
            lineType: 'surah_name',
            pageNumber: page,
          ));
        }
        continue;
      }

      if (rowType == 'basmallah') {
        const basmallah = 'بِسْمِ اللَّهِ الرَّحْمَٰنِ الرَّحِيمِ';
        lines.add(MushafPageLine(
          lineText: basmallah,
          isCentered: true,
          fontFamily: 'QuranUthmani',
          lineType: 'basmallah',
          pageNumber: page,
        ));
        continue;
      }

      if (rangeStart <= 0 || rangeEnd < rangeStart) continue;

      final qpcV1List = await _db.getQpcV1InRange(rangeStart, rangeEnd);
      final lineText = qpcV1List.join('');

      if (lineText.isEmpty) continue;

      final ayahSegments = [
        for (final word in qpcV1List) (text: word, isMarker: false),
      ];
      lines.add(MushafPageLine(
        lineText: lineText,
        isCentered: isCentered,
        fontFamily: fontFamily,
        lineType: 'ayah',
        rangeStart: rangeStart,
        rangeEnd: rangeEnd,
        ayahSegments: ayahSegments,
      ));
    }

    PageCache.instance.put(_v1CacheMode, page, lines);
    PagePersistentCache.instance.put(_v1CacheMode, page, lines);
    return lines;
  }

  /// نفس آلية QPC4: تحميل مسبق للنافذة فقط (2 قبل، 2 بعد الحالية).
  void _preloadV1Pages(int currentPage) {
    const totalPages = 604;
    final before = PageCache.cacheWindowBefore;
    final after = PageCache.cacheWindowAfter;
    for (int p = currentPage - before; p <= currentPage + after; p++) {
      if (p < 1 || p > totalPages) continue;
      if (PageCache.instance.has(_v1CacheMode, p)) continue;
      Future(() => _loadPage(p));
    }
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

  static const double _linePaddingBottom = 0.5;

  static const String _arabicDigits = '٠١٢٣٤٥٦٧٨٩';
  static String _toArabicDigits(int value) {
    return value.toString().replaceAllMapped(
        RegExp(r'\d'), (m) => _arabicDigits[int.parse(m.group(0)!)]);
  }

  /// صف رقم الصفحة داخل صفحة QPC V1 (نفس سلوك الشريط العلوي — يُسحَب مع الصفحة).
  Widget _buildV1PageNumberRow(int page) {
    return SizedBox(
      height: 40,
      child: Align(
        alignment: page.isOdd ? Alignment.centerRight : Alignment.centerLeft,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: SizedBox(
            width: 56.25,
            height: 28.125,
            child: Stack(
              alignment: Alignment.center,
              children: [
                SvgPicture.asset(
                  'assets/icon/raqum_alsafha.svg',
                  fit: BoxFit.contain,
                ),
                Text(
                  _toArabicDigits(page),
                  style: TextStyle(
                    fontSize: 18,
                    color:
                        _useWhiteTextOnDarkMushaf ? Colors.white : Colors.black,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// نفس حجم وخطوة السطر في V4 (تم تكبيره إلى 26 بدلاً من 23).
  static const double _fontSize = 26;
  static const double _lineHeight = 1.52;

  static TextStyle _lineStyle(
    String fontFamily, {
    double? fontSize,
    bool useWhiteTextOnDark = false,
  }) =>
      TextStyle(
        fontFamily: fontFamily,
        fontSize: fontSize ?? _fontSize,
        height: _lineHeight,
        color: useWhiteTextOnDark ? Colors.white : null,
      );

  static TextStyle _v1LineStyleFromLine(MushafPageLine line,
      {double fontSizeScale = 1.0, bool useWhiteTextOnDark = false}) {
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
        fontSize: 22 * fontSizeScale,
        height: 1.15,
        fontWeight: FontWeight.w600,
        color: useWhiteTextOnDark ? Colors.white : Colors.black,
      );
    }
    return _lineStyle(
      line.fontFamily,
      fontSize: _fontSize * fontSizeScale,
      useWhiteTextOnDark: useWhiteTextOnDark,
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
      final painter = TextPainter(
        text: TextSpan(text: line.lineText, style: style),
        textDirection: TextDirection.rtl,
        maxLines: 1,
      )..layout(maxWidth: double.infinity);
      if (painter.width > maxLineWidth) maxLineWidth = painter.width;
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

  static double _measureV1LineWidth(String text, TextStyle style) {
    final p = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.rtl,
      maxLines: 1,
    )..layout(maxWidth: double.infinity);
    return p.width;
  }

  /// نسخة ثابتة لبناء صفحة V1 من الأسطر (للاستخدام من buildQpcPageContent).
  static Widget buildV1PageFromLinesStatic(
    BuildContext context,
    int page,
    List<MushafPageLine> pageLines, {
    bool forceWhiteMushafText = false,
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
            contentW,
            contentH,
            null,
            lineHeights,
            pageLines,
            null,
            null,
            null,
            null,
            null,
            useWhiteTextOnDark: forceWhiteMushafText,
          );
        }
        return FutureBuilder<Map<int, (int, int)>>(
          future: QuranDb.instance.getWordToAyahMapping(minR, maxR),
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
              contentW,
              contentH,
              mapSnap.data,
              lineHeights,
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

  static Widget _buildV1PageContentStatic(
      BuildContext context,
      BoxConstraints constraints,
      int page,
      double contentW,
      double contentH,
      Map<int, (int sura, int ayah)>? mapping,
      List<double> lineHeights,
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
    const compactMarginFraction = 0.02;
    final availableWidth = constraints.maxWidth;
    final marginFraction =
        isCompact ? compactMarginFraction : kQpcPageMarginFraction;
    final leftMargin = availableWidth *
        (isCompact ? compactMarginFraction : kQpcPageMarginLeftFraction);
    final rightMargin = availableWidth * marginFraction;
    final availableW = availableWidth - leftMargin - rightMargin;
    final fontScale = isCompact ? getCompactFontScaleFactor(context) : 1.0;
    final linePad = isCompact ? 0.2 : _linePaddingBottom;
    var scaledW = availableW;
    var scaleFinal = contentW > 0 ? availableW / contentW : 1.0;
    if (!isCompact) {
      scaleFinal = scaleFinal.clamp(0.5, 3.0);
      scaledW = contentW * scaleFinal;
      if ((page == 1 || page == 2) && contentW > 0 && scaledW < availableW) {
        scaledW = availableW;
        scaleFinal = availableW / contentW;
      }
      if (page == 3 && contentW > 0 && scaledW < availableW) {
        scaledW = availableW;
        scaleFinal = availableW / contentW;
      }
    }
    final fullH = constraints.maxHeight;
    final slotCount = 15;
    final slotHeight = fullH / slotCount;
    final displayLines =
        pageLines.length >= 15 ? pageLines.sublist(0, 15) : pageLines;
    final slots = <Widget>[];
    for (int i = 0; i < 15; i++) {
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
        var fontSizeScale = (page == 1 || page == 2)
            ? 1.12
            : (page == 3)
                ? 1.08
                : 1.0;
        if (isCompact) fontSizeScale *= fontScale;
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
              linePad: linePad,
              useWhiteTextOnDark: useWhiteTextOnDark,
              wordRange: lineWordSelection != null
                  ? (lineWordSelection.$2, lineWordSelection.$3)
                  : null);
        } else if (linePersistentSelections.isNotEmpty &&
            line.lineType == 'ayah') {
          lineChild =
              _QuranReaderState._buildV1LineWithPersistentHighlightsStatic(
            line,
            scaledW,
            linePersistentSelections,
            fontSizeScale: fontSizeScale,
            linePad: linePad,
            useWhiteTextOnDark: useWhiteTextOnDark,
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
              linePad: linePad,
              useWhiteTextOnDark: useWhiteTextOnDark);
        } else if (line.lineType == 'surah_name') {
          lineChild = _QuranReaderState._buildSurahNameLineStatic(
              line, contentW,
              fontSizeScale: fontSizeScale,
              linePad: linePad,
              useWhiteTextOnDark: useWhiteTextOnDark);
        } else {
          lineChild = _QuranReaderState._buildLineStatic(line,
              contentW: scaledW,
              fontSizeScale: fontSizeScale,
              linePad: linePad,
              useWhiteTextOnDark: useWhiteTextOnDark);
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
      final lineHeights15 = List<double>.filled(15, slotHeight);
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
            fullH,
            lineHeights15,
            displayLines,
            const TextStyle(),
            mapping,
            (line, _) => _v1LineStyleFromLine(
              line,
              useWhiteTextOnDark: useWhiteTextOnDark,
            ),
            onSelectLine: onSelectLine,
            onClearSelection: onClearSelection,
            lineTextHorizontallyCentered: true,
          );
        },
        child: content,
      );
    }
    Widget result = SizedBox(
      width: scaledW,
      height: fullH,
      child: content,
    );
    return Padding(
      padding: EdgeInsets.only(left: leftMargin, right: rightMargin),
      child: Align(
        // توسيط الكتلة عندما يكون عرض المحتوى أضيق من المساحة بين الهامشين
        // حتى لا يتراكم الفراغ على جانب واحد فقط.
        alignment: Alignment.center,
        child: result,
      ),
    );
  }

  static Widget _buildLineStatic(MushafPageLine line,
      {double? contentW,
      double fontSizeScale = 1.0,
      double? linePad,
      bool useWhiteTextOnDark = false}) {
    final pad = linePad ?? _linePaddingBottom;
    final alignment =
        line.isCentered ? Alignment.center : Alignment.centerRight;
    final baseStyle = _v1LineStyleFromLine(
      line,
      fontSizeScale: fontSizeScale,
      useWhiteTextOnDark: useWhiteTextOnDark,
    );
    final effectiveStyle =
        (contentW != null && line.lineType == 'ayah' && !line.isCentered)
            ? getJustifiedLineStyle(line, baseStyle, contentW)
            : baseStyle;
    return Padding(
      padding: EdgeInsets.only(bottom: pad),
      child: Align(
        alignment: alignment,
        child: SizedBox(
          width: double.infinity,
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: _kV1FittedLineAlignment,
            child: (line.lineType == 'basmallah')
                ? Transform.translate(
                    offset: Offset(
                        0, _QuranReaderState._basmallahRaiseDy * fontSizeScale),
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
                    textAlign:
                        line.isCentered ? TextAlign.center : TextAlign.right,
                    softWrap: false,
                    maxLines: 1,
                    overflow: TextOverflow.visible,
                    style: effectiveStyle,
                  ),
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
                line.lineText,
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
    double? linePad,
    bool useWhiteTextOnDark = false,
  }) {
    final pad = linePad ?? _linePaddingBottom;
    final baseStyle = _v1LineStyleFromLine(
      line,
      fontSizeScale: fontSizeScale,
      useWhiteTextOnDark: useWhiteTextOnDark,
    );
    final lineStyle = line.isCentered
        ? baseStyle
        : getJustifiedLineStyle(line, baseStyle, contentW);
    final lineWidth = _measureV1LineWidth(line.lineText, lineStyle);
    final painter = TextPainter(
      text: TextSpan(text: line.lineText, style: lineStyle),
      textDirection: TextDirection.rtl,
      maxLines: 1,
    )..layout(maxWidth: double.infinity);

    final persistentRects = <({double left, double width, Color color})>[];
    for (final sel in persistentSelections) {
      final start = sel.$2.clamp(0, line.lineText.length);
      final end = sel.$3.clamp(0, line.lineText.length);
      if (end <= start) continue;
      final startOffset =
          painter.getOffsetForCaret(TextPosition(offset: start), Rect.zero);
      final endOffset =
          painter.getOffsetForCaret(TextPosition(offset: end), Rect.zero);
      final left =
          startOffset.dx < endOffset.dx ? startOffset.dx : endOffset.dx;
      final width = (endOffset.dx - startOffset.dx).abs();
      if (width > 0.01) {
        persistentRects.add((left: left, width: width, color: sel.$4));
      }
    }
    final mergedPersistentRects =
        _mergeV1PersistentRectsByColor(persistentRects);
    if (mergedPersistentRects.isEmpty) {
      return _buildLineStatic(
        line,
        contentW: contentW,
        fontSizeScale: fontSizeScale,
        linePad: linePad,
        useWhiteTextOnDark: useWhiteTextOnDark,
      );
    }

    double? wordLeft;
    double? wordWidth;
    if (wordRange != null &&
        wordRange.$1 >= 0 &&
        wordRange.$2 <= line.lineText.length &&
        wordRange.$2 > wordRange.$1) {
      final wStart = painter.getOffsetForCaret(
          TextPosition(offset: wordRange.$1.clamp(0, line.lineText.length)),
          Rect.zero);
      final wEnd = painter.getOffsetForCaret(
          TextPosition(offset: wordRange.$2.clamp(0, line.lineText.length)),
          Rect.zero);
      wordLeft = wStart.dx < wEnd.dx ? wStart.dx : wEnd.dx;
      wordWidth = (wEnd.dx - wStart.dx).abs();
    }
    final wordColor =
        useWhiteTextOnDark ? const Color(0xFF7CFFC4) : const Color(0xFFB8E6C1);
    final wordAlpha = useWhiteTextOnDark ? 0.48 : 0.30;
    final alignment =
        line.isCentered ? Alignment.center : Alignment.centerRight;
    return Padding(
      padding: EdgeInsets.only(bottom: pad),
      child: Align(
        alignment: alignment,
        child: SizedBox(
          width: double.infinity,
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: _kV1FittedLineAlignment,
            child: SizedBox(
              width: lineWidth,
              height: painter.height,
              child: Stack(
                alignment: Alignment.centerRight,
                children: [
                  Text(
                    line.lineText,
                    textDirection: TextDirection.rtl,
                    textAlign:
                        line.isCentered ? TextAlign.center : TextAlign.right,
                    softWrap: false,
                    maxLines: 1,
                    overflow: TextOverflow.visible,
                    style: lineStyle,
                  ),
                  ...mergedPersistentRects.map((rect) =>
                      _buildV1PersistentHighlightSegment(rect, painter.height)),
                  if (wordLeft != null && wordWidth != null)
                    Positioned(
                      left: wordLeft,
                      top: 0,
                      width: wordWidth,
                      height: painter.height,
                      child: Container(
                        decoration: BoxDecoration(
                          color: wordColor.withValues(alpha: wordAlpha),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  static Widget _buildV1LineWithAyahOverlayStatic(
      MushafPageLine line, double contentW, int startChar, int endChar,
      {(int, int)? wordRange,
      double fontSizeScale = 1.0,
      double? linePad,
      bool useWhiteTextOnDark = false}) {
    final pad = linePad ?? _linePaddingBottom;
    final baseStyle = _v1LineStyleFromLine(
      line,
      fontSizeScale: fontSizeScale,
      useWhiteTextOnDark: useWhiteTextOnDark,
    );
    final lineStyle = line.isCentered
        ? baseStyle
        : getJustifiedLineStyle(line, baseStyle, contentW);
    final lineWidth = _measureV1LineWidth(line.lineText, lineStyle);
    final painter = TextPainter(
      text: TextSpan(text: line.lineText, style: lineStyle),
      textDirection: TextDirection.rtl,
      maxLines: 1,
    )..layout(maxWidth: double.infinity);
    final startOffset = painter.getOffsetForCaret(
        TextPosition(offset: startChar.clamp(0, line.lineText.length)),
        Rect.zero);
    final endOffset = painter.getOffsetForCaret(
        TextPosition(offset: endChar.clamp(0, line.lineText.length)),
        Rect.zero);
    final left = startOffset.dx < endOffset.dx ? startOffset.dx : endOffset.dx;
    final width = (endOffset.dx - startOffset.dx).abs();

    double? wordLeft;
    double? wordWidth;
    if (wordRange != null &&
        wordRange.$1 >= 0 &&
        wordRange.$2 <= line.lineText.length &&
        wordRange.$2 > wordRange.$1) {
      final wStart = painter.getOffsetForCaret(
          TextPosition(offset: wordRange.$1.clamp(0, line.lineText.length)),
          Rect.zero);
      final wEnd = painter.getOffsetForCaret(
          TextPosition(offset: wordRange.$2.clamp(0, line.lineText.length)),
          Rect.zero);
      wordLeft = wStart.dx < wEnd.dx ? wStart.dx : wEnd.dx;
      wordWidth = (wEnd.dx - wStart.dx).abs();
    }

    final ayahColor = useWhiteTextOnDark
        ? const Color(0xFFB3E5FC)
        : const Color.fromARGB(255, 45, 45, 45);
    final wordColor =
        useWhiteTextOnDark ? const Color(0xFF7CFFC4) : const Color(0xFFB8E6C1);
    final ayahAlpha = useWhiteTextOnDark ? 0.34 : 0.18;
    final wordAlpha = useWhiteTextOnDark ? 0.48 : 0.30;
    final alignment =
        line.isCentered ? Alignment.center : Alignment.centerRight;
    return Padding(
      padding: EdgeInsets.only(bottom: pad),
      child: Align(
        alignment: alignment,
        child: SizedBox(
          width: double.infinity,
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: _kV1FittedLineAlignment,
            child: SizedBox(
              width: lineWidth,
              height: painter.height,
              child: Stack(
                alignment: Alignment.centerRight,
                children: [
                  Text(
                    line.lineText,
                    textDirection: TextDirection.rtl,
                    textAlign:
                        line.isCentered ? TextAlign.center : TextAlign.right,
                    softWrap: false,
                    maxLines: 1,
                    overflow: TextOverflow.visible,
                    style: lineStyle,
                  ),
                  Positioned(
                    left: left,
                    top: 0,
                    width: width,
                    height: painter.height,
                    child: Container(
                      decoration: BoxDecoration(
                        color: ayahColor.withValues(alpha: ayahAlpha),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  if (wordLeft != null && wordWidth != null)
                    Positioned(
                      left: wordLeft,
                      top: 0,
                      width: wordWidth,
                      height: painter.height,
                      child: Container(
                        decoration: BoxDecoration(
                          color: wordColor.withValues(alpha: wordAlpha),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// رسم سطر آية بتأشير كلمة القراءة فقط (عند إطفاء تأشير الآية).
  static Widget _buildV1LineWithWordOverlayOnlyStatic(
      MushafPageLine line, double contentW, int wordStart, int wordEnd,
      {double fontSizeScale = 1.0,
      double? linePad,
      bool useWhiteTextOnDark = false}) {
    final pad = linePad ?? _linePaddingBottom;
    final baseStyle = _v1LineStyleFromLine(
      line,
      fontSizeScale: fontSizeScale,
      useWhiteTextOnDark: useWhiteTextOnDark,
    );
    final lineStyle = line.isCentered
        ? baseStyle
        : getJustifiedLineStyle(line, baseStyle, contentW);
    final lineWidth = _measureV1LineWidth(line.lineText, lineStyle);
    final painter = TextPainter(
      text: TextSpan(text: line.lineText, style: lineStyle),
      textDirection: TextDirection.rtl,
      maxLines: 1,
    )..layout(maxWidth: double.infinity);
    double? wordLeft;
    double? wordWidth;
    if (wordStart >= 0 &&
        wordEnd <= line.lineText.length &&
        wordEnd > wordStart) {
      final wStart = painter.getOffsetForCaret(
          TextPosition(offset: wordStart.clamp(0, line.lineText.length)),
          Rect.zero);
      final wEnd = painter.getOffsetForCaret(
          TextPosition(offset: wordEnd.clamp(0, line.lineText.length)),
          Rect.zero);
      wordLeft = wStart.dx < wEnd.dx ? wStart.dx : wEnd.dx;
      wordWidth = (wEnd.dx - wStart.dx).abs();
    }
    if (wordLeft == null || wordWidth == null) {
      return _buildLineStatic(line,
          contentW: contentW,
          fontSizeScale: fontSizeScale,
          linePad: linePad,
          useWhiteTextOnDark: useWhiteTextOnDark);
    }
    final ayahColor = useWhiteTextOnDark
        ? const Color(0xFFB3E5FC)
        : const Color.fromARGB(255, 45, 45, 45);
    final ayahAlpha = useWhiteTextOnDark ? 0.34 : 0.18;
    final alignment =
        line.isCentered ? Alignment.center : Alignment.centerRight;
    return Padding(
      padding: EdgeInsets.only(bottom: pad),
      child: Align(
        alignment: alignment,
        child: SizedBox(
          width: double.infinity,
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: _kV1FittedLineAlignment,
            child: SizedBox(
              width: lineWidth,
              height: painter.height,
              child: Stack(
                alignment: Alignment.centerRight,
                children: [
                  Text(
                    line.lineText,
                    textDirection: TextDirection.rtl,
                    textAlign:
                        line.isCentered ? TextAlign.center : TextAlign.right,
                    softWrap: false,
                    maxLines: 1,
                    overflow: TextOverflow.visible,
                    style: lineStyle,
                  ),
                  Positioned(
                    left: wordLeft,
                    top: 0,
                    width: wordWidth,
                    height: painter.height,
                    child: Container(
                      decoration: BoxDecoration(
                        color: ayahColor.withValues(alpha: ayahAlpha),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBody() {
    return Stack(
      children: [
        PageView.builder(
          itemCount: totalPages,
          controller: _pageController,
          reverse: false,
          physics: const _SmoothPageScrollPhysics(),
          allowImplicitScrolling: true,
          onPageChanged: (index) {
            setState(() => _currentPageIndex = index);
            widget.onPageChanged?.call(index + 1);
            final pageNum = index + 1;
            PageCache.instance.pruneToWindow(pageNum);
            if (_effectiveMode == QpcMushafMode.qpc4 ||
                _effectiveMode == QpcMushafMode.qpc4Black) {
              preloadNearbyPages(pageNum);
            } else if (_effectiveMode == QpcMushafMode.qpc1) {
              _preloadV1Pages(pageNum);
            }
          },
          itemBuilder: (context, index) {
            final page = index + 1;
            final pageContent = buildQpcPageContent(
              context,
              page,
              _effectiveMode,
              forceWhiteMushafText: widget.forceWhiteMushafText,
            );
            final wrappedContent = RepaintBoundary(child: pageContent);
            if (widget.buildTopBarForPage != null) {
              if (_effectiveMode == QpcMushafMode.qpc1 ||
                  _effectiveMode == QpcMushafMode.qpc4 ||
                  _effectiveMode == QpcMushafMode.qpc4Black) {
                return Column(
                  children: [
                    widget.buildTopBarForPage!(page),
                    Expanded(child: wrappedContent),
                    _buildV1PageNumberRow(page),
                  ],
                );
              }
              return Column(
                children: [
                  widget.buildTopBarForPage!(page),
                  Expanded(child: wrappedContent),
                ],
              );
            }
            return wrappedContent;
          },
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
              'فشل تحميل قاعدة البيانات:\n$_initError',
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
              'فشل تحميل قاعدة البيانات:\n$_initError',
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

  void _onAudioChanged() => setState(() {});

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
