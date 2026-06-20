import 'dart:async';
import 'dart:math' show max, pi;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'package:quran_app/khatm/khatm_data.dart';
import 'package:quran_app/khatm/khatm_mushaf_paper.dart';
import 'package:quran_app/khatm/khatm_saved_sessions.dart';
import 'package:quran_app/quran/quran_db.dart';
import 'package:quran_app/quran/quran_menu_palette.dart';
import 'package:quran_app/quran/quran_menu_sheet_host.dart';

const Locale _khatmTextLocale = Locale('ar');

/// مدة عرض اسم السورة أو البسملة قبل/بين المقاطع (ثانية ونصف).
const Duration _kKhatmSurahIntroHold = Duration(milliseconds: 2500);

/// نص البسملة كما في مصحف قنديل (Uthmani).
const String _kKhatmBasmallahUthmani = 'بِسْمِ اللَّهِ الرَّحْمَٰنِ الرَّحِيمِ';

const String _kKhatmBasmallahFontFamily = 'KFGQPCHAFSUthmanicScript';

/// حجم نص القراءة في الختم المنظّم (Scheherazade).
const double _khatmReadingFontSize = 28;

/// سطر مشكّل (TextSpan) — لغة عربية وارتفاع سطر مناسب للحركات.
TextPainter createKhatmLinePainterForSpan(InlineSpan span) {
  final painter = TextPainter(
    text: span,
    textDirection: TextDirection.rtl,
    locale: _khatmTextLocale,
    textScaler: TextScaler.noScaling,
    textHeightBehavior: const TextHeightBehavior(
      applyHeightToFirstAscent: true,
      applyHeightToLastDescent: true,
      leadingDistribution: TextLeadingDistribution.even,
    ),
    maxLines: 1,
  )..layout(maxWidth: double.infinity);
  return painter;
}

// ─────────────────────────────────────────────────────────────────────────────
// Entry point
// ─────────────────────────────────────────────────────────────────────────────

/// خط قراءة الختم: **Scheherazade New** (SIL OFL) — نسخ منخفضة مدمجة، تغطية Unicode عربية موسّعة
/// (مناسبة لرموز المصحف التكميلية التي تفشل مع خطوط أضيق). المصدر: sil.org/scheherazade
const String _kKhatmReadingFontFamily = 'ScheherazadeNew';

class KhatmSessionScreen extends StatefulWidget {
  const KhatmSessionScreen({
    super.key,
    required this.range,
    required this.initialWpm,
    required this.arabicUiFontFamily,
    this.horizontallyRotated = false,
  });

  final KhatmRange range;
  final double initialWpm;
  final String arabicUiFontFamily;

  /// وضع القراءة الأفقية الدوّارة: تُدار الشاشة كلها 90° كما في القائمة الرئيسية.
  final bool horizontallyRotated;

  static Future<void> open(
    BuildContext context, {
    required KhatmRange range,
    required double initialWpm,
    required String arabicUiFontFamily,
    bool horizontallyRotated = false,
  }) {
    return Navigator.push<void>(
      context,
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) => KhatmSessionScreen(
          range: range,
          initialWpm: initialWpm,
          arabicUiFontFamily: arabicUiFontFamily,
          horizontallyRotated: horizontallyRotated,
        ),
      ),
    );
  }

  @override
  State<KhatmSessionScreen> createState() => _KhatmSessionScreenState();
}

// ─────────────────────────────────────────────────────────────────────────────
// State
// ─────────────────────────────────────────────────────────────────────────────

class _KhatmReadChunk {
  _KhatmReadChunk({
    required this.surah,
    required this.fromAyah,
    required this.toAyah,
    required this.wordCount,
  });

  final int surah;
  final int fromAyah;
  final int toAyah;
  final int wordCount;
  double measuredWidth = 0;
}

class _KhatmRenderedLine {
  _KhatmRenderedLine(this.painter);

  final TextPainter painter;

  double get width => painter.width;
  double get height => painter.height;

  void dispose() {
    painter.dispose();
  }
}

class _KhatmSessionScreenState extends State<KhatmSessionScreen>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  // ── text & layout ──────────────────────────────────────────────────────────
  List<KhatmLinePiece> _pieces = const [];
  _KhatmRenderedLine? _lineRender;
  bool _textLoaded = false;

  /// نطاق كبير: أجزاء متعدّدة + رسامون كسولون (لا قائمة قطع واحدة ضخمة).
  static const double _chunkGapPx = 16;
  // هدف عملي: مقطع خفيف نسبيًا لتقليل أي drop.
  static const int _targetWordsPerChunk = 220;
  static const int _maxWordsPerChunk = 300;
  static const int _initialWarmupChunks = 36;
  bool _virtualStripMode = false;
  final Map<int, _KhatmRenderedLine> _chunkLines = {};
  List<_KhatmReadChunk> _readChunks = [];
  List<double> _chunkVirtLeft = const [];
  double _totalVirtualWidth = 0;
  int _measureChunksTotal = 0;
  int _measureChunksDone = 0;

  /// لون ورق المصحف (من التفضيلات `mushaf_background`) — يُحدَّث بعد [initState].
  Color _paperBackgroundColor = KhatmMushafPaper.beige;
  double _textWidth = 0;
  double _screenWidth = 0;

  // ── scrolling ──────────────────────────────────────────────────────────────
  /// إزاحة التمرير: الحد الأدنى [_minScrollPx] (هامش بداية من اليمين) → [_maxScrollPx] (نهاية النص).
  double _scrollPx = 0;
  double _maxScrollPx = 0;

  /// هامش بداية القراءة بالبكسل: يُسمح بـ [_scrollPx] سالب حتى تبدأ أوائل الكلمات من جهة اليسار.
  double _readLeadInPx = 0;

  final ValueNotifier<double> _scrollPxNotifier = ValueNotifier<double>(0);
  final ValueNotifier<int> _statsRefreshNotifier = ValueNotifier<int>(0);

  late final Ticker _ticker;
  Duration _lastTickStamp = Duration.zero;

  // ── session state ──────────────────────────────────────────────────────────
  bool _running = false;
  bool _paused = false;

  /// أثناء عرض اسم السورة/البسملة: يُجمّد التمرير والزمن المنقضي.
  bool _introBlocking = false;
  String? _introOverlayText;

  /// أول مقطع للسورة القادمة التي ستظهر لها المقدمة.
  int _pendingSurahIntroChunkIndex = -1;

  /// Accumulated elapsed seconds (excluding paused time)
  double _elapsedSeconds = 0;

  // ── speed ──────────────────────────────────────────────────────────────────
  late double _wpm;

  /// Pixels per second, computed after text layout
  double _pixelsPerSecond = 0;

  /// العرض التقديري الأولي للكلمة الواحدة (بالبكسل).
  /// نستخدم رقماً واقعياً مع حجم الخط المكبّر لتقليل القفزات عند القياس الفعلي.
  static const double _kInitialPxPerWord = 47.0;

  /// فاصل كبير عند الانتقال بين السور حتى لا تختلط نهاية السورة السابقة ببداية التالية.
  double get _surahBoundaryGapPx =>
      _screenWidth > 0 ? (_screenWidth + _readLeadInPx) : 400.0;

  double get _minScrollPx =>
      _readLeadInPx <= 0 || _screenWidth <= 0 ? 0.0 : -_readLeadInPx;

  double _clampScroll(double v) {
    final lo = _minScrollPx;
    final hi = _maxScrollPx;
    if (hi <= lo) return lo;
    return v.clamp(lo, hi);
  }

  /// يُستدعى بعد معرفة عرض الشاشة و[_maxScrollPx] — قبل المقدمة أو بدء التمرير.
  void _applyReadLeadInset() {
    final firstWordLeftX =
        _screenWidth <= 0 ? 0.0 : max(64.0, _screenWidth * 0.18);
    _readLeadInPx =
        _screenWidth <= firstWordLeftX ? 0.0 : _screenWidth - firstWordLeftX;
    _scrollPx = _clampScroll(_minScrollPx);
    _scrollPxNotifier.value = _scrollPx;
  }

  double _scrollForChunkStart(int index) {
    if (index < 0 ||
        index >= _readChunks.length ||
        index >= _chunkVirtLeft.length) {
      return _scrollPx;
    }
    final ch = _readChunks[index];
    final startAtRightEdge =
        _totalVirtualWidth - _chunkVirtLeft[index] - ch.measuredWidth;
    return _clampScroll(startAtRightEdge + _minScrollPx);
  }

  double _gapAfterChunk(int j) {
    final n = _readChunks.length;
    if (j < 0 || j >= n - 1) return 0;
    final sameSurah = _readChunks[j].surah == _readChunks[j + 1].surah;
    return sameSurah ? _chunkGapPx : _surahBoundaryGapPx;
  }

  int _findNextSurahStartChunk(int fromIndex) {
    final n = _readChunks.length;
    if (n < 2) return -1;
    final start = fromIndex.clamp(0, n - 1);
    for (var i = start + 1; i < n; i++) {
      if (_readChunks[i].surah != _readChunks[i - 1].surah) {
        return i;
      }
    }
    return -1;
  }

  void _layoutVirtualFromChunks({double? dScroll}) {
    final n = _readChunks.length;

    double newTotal = 0;
    for (var j = 0; j < n; j++) {
      newTotal += _readChunks[j].measuredWidth;
      if (j < n - 1) newTotal += _gapAfterChunk(j);
    }

    final lefts = List<double>.filled(n, 0);
    var pref = 0.0;
    for (var j = 0; j < n; j++) {
      // الموضع من اليسار = العرض الكلي - المسافة المقطوعة من اليمين - عرض المقطع الحالي
      lefts[j] = newTotal - pref - _readChunks[j].measuredWidth;
      pref += _readChunks[j].measuredWidth;
      if (j < n - 1) pref += _gapAfterChunk(j);
    }

    _totalVirtualWidth = newTotal;
    _chunkVirtLeft = lefts;
    _textWidth = newTotal;
    _maxScrollPx = (_textWidth - _screenWidth).clamp(0.0, double.infinity);

    if (dScroll != null && !_introBlocking) {
      _scrollPx = _clampScroll(_scrollPx + dScroll);
    }
    _scrollPx = _clampScroll(_scrollPx);
    _scrollPxNotifier.value = _scrollPx;
  }

  // ── key for text measurement ───────────────────────────────────────────────
  final _repaintKey = GlobalKey();

  // ── controls visibility ────────────────────────────────────────────────────
  bool _controlsVisible = true;
  Timer? _controlsHideTimer;

  // ─── WPM step (each tap on faster/slower) ─────────────────────────────────
  static const double _wpmStep = 10;

  // ─────────────────────────────────────────────────────────────────────────
  // Lifecycle
  // ─────────────────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _wpm = widget.initialWpm.clamp(KhatmWpmLimits.min, KhatmWpmLimits.max);
    _ticker = createTicker(_onTick);
    _applySystemChromeForPaper();
    WakelockPlus.enable().ignore();
    unawaited(_loadMushafPaperColor());
    _loadText();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ticker.dispose();
    _controlsHideTimer?.cancel();
    _lineRender?.dispose();
    _disposeChunkPainters();
    _scrollPxNotifier.dispose();
    _statsRefreshNotifier.dispose();
    WakelockPlus.disable().ignore();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_loadMushafPaperColor());
    }
  }

  void _disposeChunkPainters() {
    for (final line in _chunkLines.values) {
      line.dispose();
    }
    _chunkLines.clear();
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Mushaf paper (matches Quran page viewer)
  // ─────────────────────────────────────────────────────────────────────────

  void _applySystemChromeForPaper() {
    final lightPaper = !KhatmMushafPaper.isBlack(_paperBackgroundColor);
    SystemChrome.setSystemUIOverlayStyle(
      lightPaper ? SystemUiOverlayStyle.dark : SystemUiOverlayStyle.light,
    );
  }

  Future<void> _loadMushafPaperColor() async {
    final bg = await KhatmMushafPaper.loadBackgroundColor();
    if (!mounted) return;
    final changed = _paperBackgroundColor != bg;
    if (changed) {
      setState(() => _paperBackgroundColor = bg);
    }
    _applySystemChromeForPaper();
    if (changed && _textLoaded) {
      if (_virtualStripMode) {
        _disposeChunkPainters();
        _measureChunksDone = 0;
        _scheduleEnsureChunksForViewport();
      } else {
        _lineRender?.dispose();
        _lineRender = _KhatmRenderedLine(
          createKhatmLinePainterForSpan(_buildRootSpan(_pieces)),
        );
      }
      if (mounted) setState(() {});
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Text loading
  // ─────────────────────────────────────────────────────────────────────────

  void _appendChunksFromAyahCounts(
    List<_KhatmReadChunk> out,
    List<({int surah, int ayah, int words})> rows,
  ) {
    if (rows.isEmpty) return;
    var i = 0;
    while (i < rows.length) {
      final start = rows[i];
      final s = start.surah;
      var from = start.ayah;
      var to = start.ayah;
      var sum = start.words;
      i++;
      while (i < rows.length) {
        final r = rows[i];
        if (r.surah != s) break;
        final nextSum = sum + r.words;
        if (sum >= _targetWordsPerChunk && nextSum > _maxWordsPerChunk) {
          break;
        }
        to = r.ayah;
        sum = nextSum;
        i++;
      }
      out.add(_KhatmReadChunk(
        surah: s,
        fromAyah: from,
        toAyah: to,
        wordCount: sum,
      ));
    }
  }

  Future<List<_KhatmReadChunk>> _buildReadChunks() async {
    final out = <_KhatmReadChunk>[];
    final r = widget.range;
    if (r.type == KhatmRangeType.surahSpan) {
      final rows = await QuranDb.instance.getAyahWordCountsForSurahSpan(
        r.loSurah,
        r.hiSurah,
      );
      _appendChunksFromAyahCounts(out, rows);
    } else if (r.type == KhatmRangeType.readingSegment) {
      final rows = await QuranDb.instance.getAyahWordCountsForReadingSegment(
        r.fromSurah,
        r.fromAyah,
        r.toSurah,
        r.toAyah,
      );
      _appendChunksFromAyahCounts(out, rows);
    } else {
      final rows = await QuranDb.instance.getAyahWordCountsForSurah(
        r.fromSurah,
        r.fromAyah,
        r.toAyah,
      );
      _appendChunksFromAyahCounts(out, rows);
    }
    return out;
  }

  void _initStableVirtualLayout() {
    final n = _readChunks.length;
    for (var j = 0; j < n; j++) {
      _readChunks[j].measuredWidth =
          _readChunks[j].wordCount * _kInitialPxPerWord;
    }
    _layoutVirtualFromChunks();
    _recomputePixelsPerSecond();
  }

  Set<int> _wantedChunkIndices() {
    final n = _readChunks.length;
    if (n == 0 || _totalVirtualWidth <= 0 || _chunkVirtLeft.length != n) {
      return {for (var i = 0; i < n && i < _initialWarmupChunks; i++) i};
    }
    if (_screenWidth <= 0) {
      return {for (var i = 0; i < n && i < _initialWarmupChunks; i++) i};
    }
    final mid = _scrollPx + _screenWidth * 0.35;
    var best = n - 1;
    for (var j = 0; j < n; j++) {
      final L = _chunkVirtLeft[j];
      final R = L + _readChunks[j].measuredWidth;
      if (mid >= L && mid <= R) {
        best = j;
        break;
      }
      if (mid < L) {
        best = j > 0 ? j - 1 : 0;
        break;
      }
      best = j;
    }
    if (best < 0) best = 0;
    if (best >= n) best = n - 1;
    final want = <int>{};
    // نحضر مقاطع كثيرة للأمام، لكن الرسم نفسه يرسم المرئي فقط.
    for (var d = -2; d <= 12; d++) {
      final i = best + d;
      if (i >= 0 && i < n) want.add(i);
    }
    return want;
  }

  void _evictChunkPaintersBeyond(Set<int> keep) {
    for (final k in _chunkLines.keys.toList()) {
      if (!keep.contains(k)) {
        _chunkLines.remove(k)?.dispose();
      }
    }
  }

  Future<void> _ensureChunksForViewport() async {
    final keep = _wantedChunkIndices();
    var changed = false;
    final active = _activeChunkIndex();

    final ordered = keep.toList()
      ..sort((a, b) {
        final da = (a - active).abs();
        final db = (b - active).abs();
        return da.compareTo(db);
      });

    var loadedThisPass = 0;
    final maxLoadsThisPass = _running ? 1 : ordered.length;
    for (final j in ordered) {
      if (_chunkLines.containsKey(j)) continue;
      final ch = _readChunks[j];
      try {
        final line = await _renderedLineForChunk(ch);
        if (!mounted) return;

        final dW = line.width - ch.measuredWidth;
        ch.measuredWidth = line.width;
        _chunkLines[j] = line;
        _measureChunksDone =
            (_measureChunksDone + 1).clamp(0, _measureChunksTotal).toInt();
        changed = true;

        // الحفاظ على ثبات النص الظاهر عند تحديث القياسات
        double? dScroll;
        if (j <= active) {
          dScroll = dW;
        }
        _layoutVirtualFromChunks(dScroll: dScroll);

        loadedThisPass++;
        if (loadedThisPass >= maxLoadsThisPass) break;
      } catch (_) {}
    }
    _evictChunkPaintersBeyond(keep);
    if (changed && mounted) setState(() {});
  }

  Future<_KhatmRenderedLine> _renderedLineForChunk(_KhatmReadChunk ch) async {
    final pieces = await QuranDb.instance.getKhatmLinePiecesForRange(
      ch.surah,
      ch.fromAyah,
      ch.toAyah,
    );
    final use = pieces.isNotEmpty
        ? pieces
        : const <KhatmLinePiece>[KhatmLinePiece.word('…')];
    return _KhatmRenderedLine(
      createKhatmLinePainterForSpan(_buildRootSpan(use)),
    );
  }

  int _activeChunkIndex() {
    final n = _readChunks.length;
    if (n == 0 || _chunkVirtLeft.length != n) return 0;
    final mid = _scrollPx + _screenWidth * 0.35;
    var best = n - 1;
    for (var j = 0; j < n; j++) {
      final L = _chunkVirtLeft[j];
      final R = L + _readChunks[j].measuredWidth;
      if (mid >= L && mid <= R) return j;
      if (mid < L) {
        best = j > 0 ? j - 1 : 0;
        break;
      }
      best = j;
    }
    return best.clamp(0, n - 1);
  }

  Future<void> _loadText() async {
    _measureChunksTotal = 0;
    _measureChunksDone = 0;
    try {
      final chunks = await _buildReadChunks();
      if (!mounted) return;
      _virtualStripMode = chunks.length > 1;
      if (_virtualStripMode) {
        _measureChunksTotal = chunks.length;
        setState(() {});
      }
      if (!_virtualStripMode) {
        _disposeChunkPainters();
        _readChunks = [];
        _chunkVirtLeft = const [];
        _totalVirtualWidth = 0;
        _measureChunksTotal = 0;
        _measureChunksDone = 0;
        final List<KhatmLinePiece> pieces;
        final r = widget.range;
        if (r.type == KhatmRangeType.surahSpan) {
          pieces = await QuranDb.instance.getKhatmLinePiecesForSurahSpan(
            r.loSurah,
            r.hiSurah,
          );
        } else if (r.type == KhatmRangeType.readingSegment) {
          pieces = await QuranDb.instance.getKhatmLinePiecesForReadingSegment(
            r.fromSurah,
            r.fromAyah,
            r.toSurah,
            r.toAyah,
          );
        } else {
          pieces = await QuranDb.instance.getKhatmLinePiecesForRange(
            r.fromSurah,
            r.fromAyah,
            r.toAyah,
          );
        }
        if (!mounted) return;
        _lineRender?.dispose();
        _pieces = pieces.isNotEmpty ? pieces : const [KhatmLinePiece.word('…')];
        _lineRender = _KhatmRenderedLine(
          createKhatmLinePainterForSpan(_buildRootSpan(_pieces)),
        );
      } else {
        _lineRender?.dispose();
        _lineRender = null;
        _pieces = const [];
        _readChunks = chunks;
        _measureChunksDone = 0;
        _disposeChunkPainters();

        // بناء الهيكل الافتراضي فوراً وبدون انتظار أي قياس
        _initStableVirtualLayout();

        // تحميل أول مجموعة للعرض فقط
        await _ensureChunksForViewport();
      }
      if (!mounted) return;
      setState(() {
        _textLoaded = true;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        unawaited(_measureAndStart());
      });
    } catch (_) {
      if (!mounted) return;
      _virtualStripMode = false;
      _measureChunksTotal = 0;
      _measureChunksDone = 0;
      _disposeChunkPainters();
      _readChunks = [];
      _lineRender?.dispose();
      _pieces = const [KhatmLinePiece.word('…')];
      _lineRender = _KhatmRenderedLine(
        createKhatmLinePainterForSpan(_buildRootSpan(_pieces)),
      );
      setState(() {
        _textLoaded = true;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        unawaited(_measureAndStart());
      });
    }
  }

  Future<void> _runSurahIntroSequence(int surahNumber, int fromAyah) async {
    if (!mounted) return;
    final resumeTickerAfter = _ticker.isActive;
    if (resumeTickerAfter) _ticker.stop();
    final frozenScrollPx = _scrollPx;

    void restoreFrozenScroll() {
      _scrollPx = _clampScroll(frozenScrollPx);
      _scrollPxNotifier.value = _scrollPx;
    }

    setState(() {
      restoreFrozenScroll();
      _introBlocking = true;
      _introOverlayText = 'سورة ${widget.range.surahNameAr(surahNumber)}';
    });
    await Future<void>.delayed(_kKhatmSurahIntroHold);
    if (!mounted) return;
    restoreFrozenScroll();
    final showBasmallah = fromAyah == 1 && surahNumber != 1 && surahNumber != 9;
    if (showBasmallah) {
      setState(() {
        restoreFrozenScroll();
        _introOverlayText = _kKhatmBasmallahUthmani;
      });
      await Future<void>.delayed(_kKhatmSurahIntroHold);
    }
    if (!mounted) return;
    setState(() {
      restoreFrozenScroll();
      _introBlocking = false;
      _introOverlayText = null;
    });
    _lastTickStamp = Duration.zero;
    if (resumeTickerAfter && mounted) {
      _ticker.start();
    }
  }

  void _maybeSurahBoundaryIntro() {
    if (!_virtualStripMode || !_running || _paused || _introBlocking) return;
    final idx = _pendingSurahIntroChunkIndex;
    if (idx <= 0 || idx >= _readChunks.length) {
      return;
    }

    final triggerAt = _scrollForChunkStart(idx);
    if (_scrollPx < triggerAt) return;

    // لا ندع أي حرف من السورة الجديدة يظهر قبل المقدمة.
    _scrollPx = triggerAt;
    _scrollPxNotifier.value = _scrollPx;
    final ch = _readChunks[idx];
    _pendingSurahIntroChunkIndex = _findNextSurahStartChunk(idx);
    unawaited(
      _runSurahIntroSequence(ch.surah, ch.fromAyah),
    );
  }

  Future<void> _measureAndStart() async {
    if (!mounted) return;
    final box = _repaintKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;
    _screenWidth = box.size.width;

    if (_virtualStripMode) {
      if (_readChunks.isEmpty || _totalVirtualWidth <= 0) return;
      // إعادة حساب العرض بناءً على حجم الشاشة الحقيقي
      _maxScrollPx =
          (_totalVirtualWidth - _screenWidth).clamp(0.0, double.infinity);
      _applyReadLeadInset();
      final first = _readChunks.first;
      await _runSurahIntroSequence(first.surah, first.fromAyah);
      if (!mounted) return;
      _pendingSurahIntroChunkIndex = _findNextSurahStartChunk(0);
      setState(() => _running = true);
      _lastTickStamp = Duration.zero;
      _ticker.start();
      _scheduleControlsHide();
      return;
    }

    if (_lineRender == null) return;
    _textWidth = _lineRender!.width;
    _maxScrollPx = (_textWidth - _screenWidth).clamp(0.0, double.infinity);
    _recomputePixelsPerSecond();
    _applyReadLeadInset();
    final r = widget.range;
    final int surah;
    final int fromA;
    if (r.type == KhatmRangeType.surahSpan) {
      surah = r.loSurah;
      fromA = 1;
    } else {
      surah = r.fromSurah;
      fromA = r.fromAyah;
    }
    await _runSurahIntroSequence(surah, fromA);
    if (!mounted) return;
    setState(() => _running = true);
    _lastTickStamp = Duration.zero;
    _ticker.start();
    _scheduleControlsHide();
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Ticker callback
  // ─────────────────────────────────────────────────────────────────────────

  bool _chunkPrefetchInFlight = false;

  void _scheduleEnsureChunksForViewport() {
    if (_chunkPrefetchInFlight) return;
    _chunkPrefetchInFlight = true;
    unawaited(
      _ensureChunksForViewport().whenComplete(() {
        _chunkPrefetchInFlight = false;
      }),
    );
  }

  void _onTick(Duration elapsed) {
    if (_paused || !_running || _introBlocking) {
      _lastTickStamp = elapsed;
      return;
    }
    final delta = _lastTickStamp == Duration.zero
        ? Duration.zero
        : elapsed - _lastTickStamp;
    _lastTickStamp = elapsed;

    final dt = delta.inMicroseconds / 1e6;
    _elapsedSeconds += dt;
    _scrollPx = _clampScroll(_scrollPx + _pixelsPerSecond * dt);
    _scrollPxNotifier.value = _scrollPx;
    // شريط الوقت/الإنجاز يبني عبر [_statsRefreshNotifier] — بدون إشعار هنا يبقى
    // ثابتاً حتى يحدث setState من تفاعل آخر.
    _statsRefreshNotifier.value++;

    if (_virtualStripMode) {
      _maybeSurahBoundaryIntro();
    }

    if (_scrollPx >= _maxScrollPx && _maxScrollPx > 0) {
      _ticker.stop();
      _onSessionComplete(completed: true);
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Speed helpers
  // ─────────────────────────────────────────────────────────────────────────

  void _recomputePixelsPerSecond() {
    // السرعة الآن تعتمد فقط على العرض الافتراضي والـ WPM
    // بكسل/ثانية = (كلمة/دقيقة ÷ 60 ثانية) × بكسل/كلمة
    _pixelsPerSecond = (_wpm / 60.0) * _kInitialPxPerWord;
  }

  void _changeWpm(double newWpm) {
    final clamped = newWpm.clamp(KhatmWpmLimits.min, KhatmWpmLimits.max);
    final prev = _wpm <= 0 ? clamped : _wpm;
    setState(() {
      _wpm = clamped;
      if (_running) {
        // أثناء الجلسة: نعدّل السرعة بنسبة مباشرة بدون إعادة معايرة على طول النص.
        final ratio = clamped / prev;
        _pixelsPerSecond =
            (_pixelsPerSecond * ratio).clamp(0.0, double.infinity);
      } else {
        _recomputePixelsPerSecond();
      }
    });
    KhatmPrefs.saveLastWpm(clamped).ignore();
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Session completion
  // ─────────────────────────────────────────────────────────────────────────

  Future<void> _onSessionComplete({required bool completed}) async {
    _ticker.stop();
    _running = false;
    _introBlocking = false;
    _introOverlayText = null;

    final span = _maxScrollPx - _minScrollPx;
    final progress =
        span > 0 ? ((_scrollPx - _minScrollPx) / span).clamp(0.0, 1.0) : 0.0;
    final avgWpm = _elapsedSeconds > 0
        ? (widget.range.totalWords / (_elapsedSeconds / 60.0))
        : _wpm;

    await KhatmPrefs.recordSessionWpm(avgWpm);
    await KhatmPrefs.saveLastWpm(_wpm);

    final summary = KhatmSessionSummary(
      range: widget.range,
      totalElapsedSeconds: _elapsedSeconds,
      avgWpm: avgWpm,
      progressFraction: progress.clamp(0.0, 1.0),
      isCompleted: completed,
    );

    if (!mounted) return;
    await _showSummaryDialog(summary);
    if (!mounted) return;
    Navigator.pop(context);
  }

  Future<void> _showSummaryDialog(KhatmSessionSummary summary) async {
    final pal = _sessionPalette;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => wrapQuranMenuFamilySheetOverlay(
        ctx,
        _KhatmSummaryDialog(
          summary: summary,
          pal: pal,
          fontFamily: widget.arabicUiFontFamily,
          horizontallyRotatedReading: widget.horizontallyRotated,
        ),
        horizontallyRotatedReading: widget.horizontallyRotated,
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Controls visibility
  // ─────────────────────────────────────────────────────────────────────────

  void _scheduleControlsHide() {
    _controlsHideTimer?.cancel();
    _controlsHideTimer = Timer(const Duration(seconds: 4), () {
      if (mounted && _running && !_paused) {
        setState(() => _controlsVisible = false);
      }
    });
  }

  void _showControls() {
    setState(() => _controlsVisible = true);
    _statsRefreshNotifier.value++;
    _scheduleControlsHide();
  }

  int _countWordPieces() {
    var n = 0;
    for (final p in _pieces) {
      if (!p.isMarker) n++;
    }
    return n;
  }

  /// تراجع بعدد كلمات تقريبي (١٠) مع الحفاظ على نفس منطق التمرير للنطاق الواحد أو المقاطع.
  void _jumpBackWords(int words) {
    if (words <= 0 || !_textLoaded) return;
    final totalWords = widget.range.totalWords;
    final span = _maxScrollPx - _minScrollPx;
    if (totalWords <= 0 || span <= 0) return;

    if (!_virtualStripMode) {
      final line = _lineRender;
      if (line == null) return;
      final w = _countWordPieces();
      if (w <= 0) return;
      final pxPerWord = line.width / w;
      final delta = pxPerWord * words;
      setState(() {
        _scrollPx = _clampScroll(_scrollPx - delta);
        _scrollPxNotifier.value = _scrollPx;
      });
      _showControls();
      return;
    }

    final frac = ((_scrollPx - _minScrollPx) / span).clamp(0.0, 1.0);
    final passedWords = frac * totalWords;
    final newPassed = (passedWords - words).clamp(0.0, totalWords.toDouble());
    final newFrac = newPassed / totalWords;
    setState(() {
      _scrollPx = _clampScroll(_minScrollPx + newFrac * span);
      _scrollPxNotifier.value = _scrollPx;
    });
    _scheduleEnsureChunksForViewport();
    _showControls();
  }

  /// رسالة تأكيد: SnackBar في العمودي، وبطاقة مُدارة 90° فوق المحتوى في الأفقي.
  void _showSessionFeedback(String message) {
    if (!mounted) return;
    if (!_rotatedReading) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            message,
            style: TextStyle(fontFamily: widget.arabicUiFontFamily),
          ),
        ),
      );
      return;
    }
    final pal = _sessionPalette;
    final overlay = Overlay.of(context, rootOverlay: true);
    final maxWidth = (MediaQuery.sizeOf(context).height * 0.75)
        .clamp(220.0, 560.0)
        .toDouble();
    late final OverlayEntry entry;
    entry = OverlayEntry(
      builder: (_) => IgnorePointer(
        child: Center(
          child: RotatedBox(
            quarterTurns: 1,
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: maxWidth),
              child: Material(
                color: pal.isDark
                    ? Colors.white.withValues(alpha: 0.92)
                    : Colors.black.withValues(alpha: 0.82),
                borderRadius: BorderRadius.circular(12),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  child: Text(
                    message,
                    textDirection: TextDirection.rtl,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontFamily: widget.arabicUiFontFamily,
                      fontSize: 14,
                      color: pal.isDark ? Colors.black87 : Colors.white,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    overlay.insert(entry);
    Timer(const Duration(milliseconds: 2800), () {
      if (entry.mounted) entry.remove();
    });
  }

  Future<void> _onSaveReadingBookmark() async {
    if (!mounted || !_textLoaded) return;
    if ((!_running && !_paused) || _introBlocking) return;

    final end = await khatmEndOfReadingMaterial(widget.range);
    final resume = await khatmResumeAyahFromProgress(
      widget.range,
      _progressFraction,
    );
    final invalidEnd = resume.surah > end.surah ||
        (resume.surah == end.surah && resume.ayah > end.ayah);
    if (invalidEnd) {
      if (!mounted) return;
      _showSessionFeedback('لا يوجد موضع للحفظ بعد نهاية النطاق.');
      return;
    }

    final nextRange = await khatmBuildReadingSegmentRange(
      sourceContext: widget.range,
      resumeSurah: resume.surah,
      resumeAyah: resume.ayah,
      endSurah: end.surah,
      endAyah: end.ayah,
    );
    final sn = widget.range.surahNameAr(resume.surah);
    final caption = 'يُستأنف من آية ${resume.ayah} — $sn';
    final id = DateTime.now().millisecondsSinceEpoch.toString();
    await KhatmSavedSessionsStore.add(
      KhatmSavedSessionRecord(
        id: id,
        range: nextRange,
        wpm: _wpm,
        savedAtMillis: DateTime.now().millisecondsSinceEpoch,
        resumeCaption: caption,
      ),
    );
    if (!mounted) return;
    _showSessionFeedback(
      'تم حفظ الموضع ($caption). يمكنك المتابعة من «الجلسات المحفوظة» في إعداد الختم.',
    );
    _showControls();
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Computed getters
  // ─────────────────────────────────────────────────────────────────────────

  double get _progressFraction {
    final span = _maxScrollPx - _minScrollPx;
    if (span <= 0) return 0.0;
    return ((_scrollPx - _minScrollPx) / span).clamp(0.0, 1.0);
  }

  double get _remainingSeconds {
    final remaining = _maxScrollPx - _scrollPx;
    if (_pixelsPerSecond <= 0) return 0;
    return remaining / _pixelsPerSecond;
  }

  String _formatTime(double seconds) {
    final totalSec = seconds.round();
    final h = totalSec ~/ 3600;
    final m = (totalSec % 3600) ~/ 60;
    final s = totalSec % 60;
    if (h > 0) {
      return '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    }
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Text style
  // ─────────────────────────────────────────────────────────────────────────

  /// خط Scheherazade New مدمج في pubspec.yaml — لا يعتمد على تحميل من الشبكة.
  /// ارتفاع سطر أعلى من الافتراضي لتقليل التصاق الحركات بالحروف؛ حجم أخف قليلاً يخفّف الزحام البصري.
  TextStyle get _textStyle => TextStyle(
        fontFamily: _kKhatmReadingFontFamily,
        fontSize: _khatmReadingFontSize,
        fontWeight: FontWeight.w400,
        color: _readingTextColor,
        height: 1.42,
        locale: _khatmTextLocale,
      );

  /// أشرطة الحوار والإحصاءات: تباين مع لون الورق (أسود → لوحة داكنة).
  QuranMenuPaletteData get _sessionPalette =>
      KhatmMushafPaper.isBlack(_paperBackgroundColor)
          ? QuranMenuPaletteData.dark
          : QuranMenuPaletteData.light;

  /// نص القرآن: أسود على ورق فاتح، أبيض على ورق أسود المصحف.
  Color get _readingTextColor => KhatmMushafPaper.isBlack(_paperBackgroundColor)
      ? Colors.white
      : Colors.black;

  Color get _bgColor => _paperBackgroundColor;

  Color get _accentColor => KhatmMushafPaper.isBlack(_paperBackgroundColor)
      ? const Color(0xFF81C784)
      : const Color(0xFF2E7D32);

  /// علامة نهاية الآية بلون **أخضر** (مستثاة من لون نص القرآن الأسود/الأبيض).
  TextStyle get _verseMarkerStyle => _textStyle.copyWith(
        fontSize: _khatmReadingFontSize * 1.12,
        fontWeight: FontWeight.w600,
        height: 1.35,
        color: _accentColor,
      );

  InlineSpan _buildRootSpan(List<KhatmLinePiece> pieces) {
    final children = <InlineSpan>[];
    for (var i = 0; i < pieces.length; i++) {
      final p = pieces[i];
      if (i > 0) {
        children.add(TextSpan(text: ' ', style: _textStyle));
      }
      if (p.isMarker) {
        children.add(TextSpan(
          text: p.verseMarkerDisplayText,
          style: _verseMarkerStyle,
        ));
      } else {
        children.add(TextSpan(text: p.text, style: _textStyle));
      }
    }
    return TextSpan(children: children);
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Build
  // ─────────────────────────────────────────────────────────────────────────

  Future<void> _handlePopRequest() async {
    if (!_textLoaded) {
      if (mounted) Navigator.of(context).pop();
      return;
    }
    if (!_running && !_paused && !_introBlocking) {
      if (mounted) Navigator.of(context).pop();
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => wrapQuranMenuFamilySheetOverlay(
        ctx,
        Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          backgroundColor: _sessionPalette.surface,
          title: Text(
            'إنهاء الجلسة؟',
            style: TextStyle(
              fontFamily: widget.arabicUiFontFamily,
              color: _sessionPalette.title,
              fontWeight: FontWeight.w700,
            ),
          ),
          content: Text(
            'سيتوقف التمرير والعودة إلى المصحف.',
            style: TextStyle(
              fontFamily: widget.arabicUiFontFamily,
              color: _sessionPalette.subtitle,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(
                'إلغاء',
                style: TextStyle(
                  fontFamily: widget.arabicUiFontFamily,
                  color: _sessionPalette.subtitle,
                ),
              ),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(
                'خروج',
                style: TextStyle(
                  fontFamily: widget.arabicUiFontFamily,
                  color: Colors.red.shade400,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
        ),
        horizontallyRotatedReading: widget.horizontallyRotated,
      ),
    );
    if (ok == true && mounted) {
      _ticker.stop();
      setState(() {
        _running = false;
        _paused = false;
        _introBlocking = false;
        _introOverlayText = null;
      });
      Navigator.of(context).pop();
    }
  }

  /// نفس منطق القائمة الرئيسية: التدوير في القراءة الأفقية الدوّارة أو الأفقي الحقيقي.
  bool get _rotatedReading =>
      widget.horizontallyRotated ||
      MediaQuery.orientationOf(context) == Orientation.landscape;

  @override
  Widget build(BuildContext context) {
    Widget body = GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _showControls,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                // ── scrolling text layer ────────────────────────────────────
                Positioned.fill(
                  child: _textLoaded ? _buildScrollingText() : _buildLoading(),
                ),
                if (_introOverlayText != null)
                  Positioned.fill(
                    child: IgnorePointer(
                      child: ColoredBox(
                        color: _bgColor,
                        child: Center(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 24),
                            child: Text(
                              _introOverlayText!,
                              textAlign: TextAlign.center,
                              style: _introOverlayText ==
                                      _kKhatmBasmallahUthmani
                                  ? TextStyle(
                                      fontFamily: _kKhatmBasmallahFontFamily,
                                      fontSize: 32,
                                      fontWeight: FontWeight.w400,
                                      height: 1.45,
                                      color: _readingTextColor,
                                      locale: _khatmTextLocale,
                                    )
                                  : TextStyle(
                                      fontFamily: widget.arabicUiFontFamily,
                                      fontSize: 34,
                                      fontWeight: FontWeight.w700,
                                      height: 1.35,
                                      color: _readingTextColor,
                                      locale: _khatmTextLocale,
                                    ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                // ── top stats bar ([Positioned] must be direct Stack child) ─
                if (_running || _paused)
                  Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    child: AnimatedOpacity(
                      opacity: _controlsVisible ? 1.0 : 0.0,
                      duration: const Duration(milliseconds: 300),
                      child: _buildTopBarContent(),
                    ),
                  ),
                // ── bottom controls bar ───────────────────────────────────
                Positioned(
                  bottom: 0,
                  left: 0,
                  right: 0,
                  child: AnimatedOpacity(
                    opacity: _controlsVisible ? 1.0 : 0.0,
                    duration: const Duration(milliseconds: 300),
                    child: _buildBottomControlsContent(),
                  ),
                ),
              ],
            ),
          );

    if (_rotatedReading) {
      // كما في القائمة الرئيسية: يدور كل المحتوى 90° (النص، الأشرطة، المقدمات).
      final mq = MediaQuery.of(context);
      body = SafeArea(
        child: MediaQuery(
          data: mq.copyWith(
            padding: EdgeInsets.zero,
            viewPadding: EdgeInsets.zero,
          ),
          child: RotatedBox(quarterTurns: 1, child: body),
        ),
      );
    }

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (bool didPop, Object? result) async {
        if (didPop) return;
        await _handlePopRequest();
      },
      child: Directionality(
        textDirection: TextDirection.rtl,
        child: Scaffold(
          backgroundColor: _bgColor,
          body: body,
        ),
      ),
    );
  }

  Widget _buildLoading() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircularProgressIndicator(color: _accentColor),
          const SizedBox(height: 16),
          Text(
            'جارٍ تحميل النص…',
            style: TextStyle(
              fontFamily: widget.arabicUiFontFamily,
              fontSize: 16,
              color: _readingTextColor.withValues(alpha: 0.7),
            ),
          ),
          if (_measureChunksTotal > 1) ...[
            const SizedBox(height: 10),
            Text(
              'تجهيز المقاطع ${_measureChunksDone.clamp(0, _measureChunksTotal)}/$_measureChunksTotal',
              style: TextStyle(
                fontFamily: widget.arabicUiFontFamily,
                fontSize: 13,
                color: _readingTextColor.withValues(alpha: 0.55),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildScrollingText() {
    if (_virtualStripMode) {
      final n = _readChunks.length;
      if (n == 0) return const SizedBox.expand();
      final loadedLines = _chunkLines.entries
          .map((e) => (index: e.key, line: e.value))
          .toList(growable: false)
        ..sort((a, b) => a.index.compareTo(b.index));
      return RepaintBoundary(
        key: _repaintKey,
        child: CustomPaint(
          painter: _MultiKhatmScrollPainter(
            chunkVirtLeft: _chunkVirtLeft,
            loadedLines: loadedLines,
            totalWidth: _totalVirtualWidth,
            scrollPxListenable: _scrollPxNotifier,
          ),
          child: const SizedBox.expand(),
        ),
      );
    }
    final line = _lineRender;
    if (line == null) return const SizedBox.expand();
    return RepaintBoundary(
      key: _repaintKey,
      child: CustomPaint(
        painter: _KhatmScrollPainter(
          line: line,
          scrollPxListenable: _scrollPxNotifier,
        ),
        child: const SizedBox.expand(),
      ),
    );
  }

  Widget _buildTopBarContent() {
    return ValueListenableBuilder<int>(
      valueListenable: _statsRefreshNotifier,
      builder: (context, _, __) {
        final pal = _sessionPalette;
        return Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                _bgColor.withValues(alpha: 0.98),
                _bgColor.withValues(alpha: 0.0),
              ],
            ),
          ),
          padding: EdgeInsets.only(
            top: MediaQuery.of(context).padding.top + 8,
            left: 16,
            right: 16,
            bottom: 20,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: _progressFraction,
                  backgroundColor: pal.divider,
                  color: _accentColor,
                  minHeight: 5,
                ),
              ),
              const SizedBox(height: 10),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: _statChip(
                      icon: Icons.timer_outlined,
                      label: 'منقضي',
                      value: _formatTime(_elapsedSeconds),
                      pal: pal,
                    ),
                  ),
                  Expanded(
                    child: _statChip(
                      icon: Icons.hourglass_bottom_rounded,
                      label: 'متبقي',
                      value: _formatTime(_remainingSeconds),
                      pal: pal,
                    ),
                  ),
                  Expanded(
                    child: _statChip(
                      icon: Icons.speed_rounded,
                      label: 'كلمة بالدقيقة',
                      value: _wpm.toStringAsFixed(0),
                      pal: pal,
                    ),
                  ),
                  Expanded(
                    child: _statChip(
                      icon: Icons.percent_rounded,
                      label: 'إنجاز',
                      value: '${(_progressFraction * 100).toStringAsFixed(0)}%',
                      pal: pal,
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _statChip({
    required IconData icon,
    required String label,
    required String value,
    required QuranMenuPaletteData pal,
  }) {
    // عمودي: أيقونة → تسمية → رقم، كلها في منتصف ربع العرض لتوزيع متساوٍ ومحاذاة دقيقة.
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 3),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Icon(icon, size: 17, color: _accentColor),
          const SizedBox(height: 5),
          Text(
            label,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontFamily: widget.arabicUiFontFamily,
              fontSize: 14,
              height: 1.2,
              color: pal.subtitle,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            value,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontFamily: widget.arabicUiFontFamily,
              fontSize: 19,
              fontWeight: FontWeight.w700,
              color: pal.title,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSaveBookmarkControl(
    QuranMenuPaletteData pal, {
    required bool inlineWithTools,
  }) {
    final enabled = (_running || _paused) && !_introBlocking;
    final tooltip = 'حفظ موضع القراءة (حتى $khatmSavedSessionsMax جلسات)';

    if (inlineWithTools) {
      return Tooltip(
        message: tooltip,
        child: Opacity(
          opacity: enabled ? 1.0 : 0.4,
          child: _KhatmSessionToolButton(
            pal: pal,
            icon: Icons.bookmark_add_outlined,
            label: 'حفظ الموضع',
            iconColor: pal.accent,
            fontFamily: widget.arabicUiFontFamily,
            onTap: enabled ? _onSaveReadingBookmark : () {},
          ),
        ),
      );
    }

    return TextButton.icon(
      onPressed: enabled ? _onSaveReadingBookmark : null,
      icon: Icon(Icons.bookmark_add_outlined, color: pal.accent),
      label: Text(
        tooltip,
        textAlign: TextAlign.center,
        style: TextStyle(
          fontFamily: widget.arabicUiFontFamily,
          fontWeight: FontWeight.w700,
          color: pal.accent,
        ),
      ),
    );
  }

  Widget _buildBottomControlsContent() {
    final pal = _sessionPalette;
    // في الوضع المُدار يستهلك SafeArea الخارجي الهوامش، فلا نضيفها مرة أخرى.
    final bottomInset =
        _rotatedReading ? 0.0 : MediaQuery.of(context).padding.bottom;
    final shadow = pal.isDark
        ? Colors.black.withValues(alpha: 0.45)
        : Colors.black.withValues(alpha: 0.12);

    return Padding(
      padding: EdgeInsets.fromLTRB(12, 8, 12, bottomInset + 10),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: pal.cardSurface.withValues(alpha: pal.isDark ? 0.94 : 0.98),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
          border: Border.all(color: pal.divider.withValues(alpha: 0.85)),
          boxShadow: [
            BoxShadow(
              color: shadow,
              blurRadius: 18,
              offset: const Offset(0, -2),
            ),
          ],
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                textDirection: TextDirection.ltr,
                children: [
                  if (_rotatedReading)
                    Expanded(
                      child: _buildSaveBookmarkControl(
                        pal,
                        inlineWithTools: true,
                      ),
                    ),
                  Expanded(
                    child: _KhatmSessionToolButton(
                      pal: pal,
                      icon: Icons.replay_10,
                      label: 'للخلف',
                      iconColor: pal.nestedBarIcon,
                      fontFamily: widget.arabicUiFontFamily,
                      onTap: () => _jumpBackWords(10),
                    ),
                  ),
                  Expanded(
                    child: _KhatmSessionToolButton(
                      pal: pal,
                      icon: Icons.add_rounded,
                      label: 'أسرع',
                      iconColor: pal.accent,
                      fontFamily: widget.arabicUiFontFamily,
                      onTap: () {
                        _changeWpm(_wpm + _wpmStep);
                        _showControls();
                      },
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Material(
                          color: pal.accent,
                          shape: const CircleBorder(),
                          elevation: 3,
                          shadowColor: pal.accent.withValues(alpha: 0.45),
                          child: InkWell(
                            customBorder: const CircleBorder(),
                            onTap: () {
                              setState(() {
                                if (_paused) {
                                  _paused = false;
                                  _lastTickStamp = Duration.zero;
                                  _scheduleControlsHide();
                                } else {
                                  _paused = true;
                                  _controlsHideTimer?.cancel();
                                  _controlsVisible = true;
                                }
                              });
                            },
                            child: SizedBox(
                              width: 56,
                              height: 56,
                              child: Center(
                                child: Transform.rotate(
                                  angle: pi,
                                  child: Icon(
                                    _paused
                                        ? Icons.play_arrow_rounded
                                        : Icons.pause_rounded,
                                    color: Colors.white,
                                    size: 36,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          _paused ? 'تشغيل' : 'إيقاف مؤقت',
                          textAlign: TextAlign.center,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontFamily: widget.arabicUiFontFamily,
                            fontSize: 13,
                            height: 1.2,
                            color: pal.subtitle,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: _KhatmSessionToolButton(
                      pal: pal,
                      icon: Icons.remove_rounded,
                      label: 'أبطأ',
                      iconColor: pal.accent,
                      fontFamily: widget.arabicUiFontFamily,
                      onTap: () {
                        _changeWpm(_wpm - _wpmStep);
                        _showControls();
                      },
                    ),
                  ),
                  Expanded(
                    child: _KhatmSessionToolButton(
                      pal: pal,
                      icon: Icons.stop_circle_outlined,
                      label: 'إنهاء',
                      iconColor: const Color(0xFFE57373),
                      fontFamily: widget.arabicUiFontFamily,
                      onTap: () => _onSessionComplete(completed: false),
                    ),
                  ),
                ],
              ),
              if (!_rotatedReading) ...[
                const SizedBox(height: 8),
                _buildSaveBookmarkControl(pal, inlineWithTools: false),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// CustomPainter: تمرير أفقي لسطر جاهز (TextPainter)
// ─────────────────────────────────────────────────────────────────────────────

class _KhatmScrollPainter extends CustomPainter {
  _KhatmScrollPainter({
    required this.line,
    required this.scrollPxListenable,
  }) : super(repaint: scrollPxListenable);

  final _KhatmRenderedLine line;
  final ValueNotifier<double> scrollPxListenable;

  @override
  void paint(Canvas canvas, Size size) {
    final scrollPx = scrollPxListenable.value;
    final x = size.width - line.width + scrollPx;
    final y = (size.height - line.height) / 2;
    const verticalBleed = 56.0;
    canvas.save();
    canvas.clipRect(
      Rect.fromLTWH(
          0, -verticalBleed, size.width, size.height + 2 * verticalBleed),
    );
    line.painter.paint(canvas, Offset(x, y));
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _KhatmScrollPainter old) =>
      !identical(line, old.line);
}

/// تمرير أفقي لعدة مقاطع نصّية (نطاق واسع) — كل مقطع [TextPainter] مستقل.
class _MultiKhatmScrollPainter extends CustomPainter {
  _MultiKhatmScrollPainter({
    required this.chunkVirtLeft,
    required this.loadedLines,
    required this.totalWidth,
    required this.scrollPxListenable,
  }) : super(repaint: scrollPxListenable);

  final List<double> chunkVirtLeft;
  final List<({int index, _KhatmRenderedLine line})> loadedLines;
  final double totalWidth;
  final ValueNotifier<double> scrollPxListenable;

  @override
  void paint(Canvas canvas, Size size) {
    final scrollPx = scrollPxListenable.value;
    const verticalBleed = 56.0;
    canvas.save();
    canvas.clipRect(
      Rect.fromLTWH(
          0, -verticalBleed, size.width, size.height + 2 * verticalBleed),
    );
    for (final item in loadedLines) {
      final j = item.index;
      if (j < 0 || j >= chunkVirtLeft.length) continue;
      final line = item.line;
      final x = size.width - totalWidth + scrollPx + chunkVirtLeft[j];
      if (x > size.width + 120 || x + line.width < -120) continue;
      final y = (size.height - line.height) / 2;
      line.painter.paint(canvas, Offset(x, y));
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _MultiKhatmScrollPainter old) {
    if (totalWidth != old.totalWidth) return true;
    if (loadedLines.length != old.loadedLines.length) return true;
    for (var i = 0; i < loadedLines.length; i++) {
      if (loadedLines[i].index != old.loadedLines[i].index) return true;
      if (!identical(loadedLines[i].line, old.loadedLines[i].line)) {
        return true;
      }
    }
    return false;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Summary Dialog
// ─────────────────────────────────────────────────────────────────────────────

class _KhatmSummaryDialog extends StatelessWidget {
  const _KhatmSummaryDialog({
    required this.summary,
    required this.pal,
    required this.fontFamily,
    required this.horizontallyRotatedReading,
  });

  final KhatmSessionSummary summary;
  final QuranMenuPaletteData pal;
  final String fontFamily;
  final bool horizontallyRotatedReading;

  bool _compact(BuildContext context) =>
      horizontallyRotatedReading ||
      MediaQuery.orientationOf(context) == Orientation.landscape;

  Widget _headerIcon({required double size}) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: summary.isCompleted
            ? pal.accent.withValues(alpha: 0.15)
            : Colors.orange.withValues(alpha: 0.15),
        shape: BoxShape.circle,
      ),
      child: Icon(
        summary.isCompleted
            ? Icons.check_circle_rounded
            : Icons.incomplete_circle_rounded,
        color: summary.isCompleted ? pal.accent : Colors.orange,
        size: size * 0.56,
      ),
    );
  }

  Widget _progressBar() {
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: LinearProgressIndicator(
        value: summary.progressFraction,
        backgroundColor: pal.divider,
        color: pal.accent,
        minHeight: 8,
      ),
    );
  }

  Widget _okButton(BuildContext context, {bool compact = false}) {
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton(
        onPressed: () => Navigator.pop(context),
        style: ElevatedButton.styleFrom(
          backgroundColor: pal.accent,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(compact ? 10 : 12),
          ),
          padding: EdgeInsets.symmetric(vertical: compact ? 10 : 14),
          elevation: 0,
        ),
        child: Text(
          'حسناً',
          style: TextStyle(
            fontFamily: fontFamily,
            fontSize: compact ? 15 : 16,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final compact = _compact(context);
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Dialog(
        backgroundColor: pal.surface,
        insetPadding: EdgeInsets.symmetric(
          horizontal: compact ? 12 : 24,
          vertical: compact ? 10 : 24,
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        child: Padding(
          padding: EdgeInsets.all(compact ? 16 : 24),
          child: compact ? _buildCompactBody(context) : _buildPortraitBody(context),
        ),
      ),
    );
  }

  /// أفقي: عنوان وإحصاءات في صفّين، ثم شريط التقدّم والزر.
  Widget _buildCompactBody(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            _headerIcon(size: 48),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    summary.isCompleted ? 'أُكملت الجلسة' : 'انتهت الجلسة',
                    style: TextStyle(
                      fontFamily: fontFamily,
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      color: pal.title,
                      height: 1.2,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    summary.range.displayLabel,
                    style: TextStyle(
                      fontFamily: fontFamily,
                      fontSize: 13,
                      color: pal.subtitle,
                      fontWeight: FontWeight.normal,
                      height: 1.2,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        Row(
          children: [
            Expanded(
              child: _compactStatTile(
                icon: Icons.timer_outlined,
                label: 'مدة الجلسة',
                value: summary.elapsedFormatted,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _compactStatTile(
                icon: Icons.speed_rounded,
                label: 'متوسط السرعة',
                value: '${summary.avgWpm.toStringAsFixed(0)} ك/د',
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _compactStatTile(
                icon: Icons.percent_rounded,
                label: 'نسبة الإنجاز',
                value:
                    '${(summary.progressFraction * 100).toStringAsFixed(0)}%',
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        _progressBar(),
        const SizedBox(height: 12),
        _okButton(context, compact: true),
      ],
    );
  }

  Widget _buildPortraitBody(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _headerIcon(size: 64),
        const SizedBox(height: 16),
        Text(
          summary.isCompleted ? 'أُكملت الجلسة' : 'انتهت الجلسة',
          style: TextStyle(
            fontFamily: fontFamily,
            fontSize: 20,
            fontWeight: FontWeight.w700,
            color: pal.title,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          summary.range.displayLabel,
          style: TextStyle(
            fontFamily: fontFamily,
            fontSize: 14,
            color: pal.subtitle,
            fontWeight: FontWeight.normal,
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 20),
        Divider(color: pal.divider),
        const SizedBox(height: 16),
        _statRow(
          icon: Icons.timer_outlined,
          label: 'مدة الجلسة',
          value: summary.elapsedFormatted,
        ),
        const SizedBox(height: 12),
        _statRow(
          icon: Icons.speed_rounded,
          label: 'متوسط السرعة',
          value: '${summary.avgWpm.toStringAsFixed(0)} ك/د',
        ),
        const SizedBox(height: 12),
        _statRow(
          icon: Icons.percent_rounded,
          label: 'نسبة الإنجاز',
          value: '${(summary.progressFraction * 100).toStringAsFixed(0)}%',
        ),
        const SizedBox(height: 16),
        _progressBar(),
        const SizedBox(height: 24),
        _okButton(context),
      ],
    );
  }

  Widget _compactStatTile({
    required IconData icon,
    required String label,
    required String value,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 10),
      decoration: BoxDecoration(
        color: pal.accent.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: pal.divider.withValues(alpha: 0.7)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 18, color: pal.accent),
          const SizedBox(height: 6),
          Text(
            label,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontFamily: fontFamily,
              fontSize: 11,
              color: pal.subtitle,
              height: 1.2,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            value,
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontFamily: fontFamily,
              fontSize: 14,
              fontWeight: FontWeight.w700,
              color: pal.title,
            ),
          ),
        ],
      ),
    );
  }

  Widget _statRow({
    required IconData icon,
    required String label,
    required String value,
  }) {
    return Row(
      children: [
        Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            color: pal.accent.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(icon, size: 18, color: pal.accent),
        ),
        const SizedBox(width: 10),
        Text(
          label,
          style: TextStyle(
            fontFamily: fontFamily,
            fontSize: 14,
            color: pal.subtitle,
            fontWeight: FontWeight.normal,
          ),
        ),
        const Spacer(),
        Text(
          value,
          style: TextStyle(
            fontFamily: fontFamily,
            fontSize: 16,
            fontWeight: FontWeight.w700,
            color: pal.title,
          ),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Bottom bar tool button (matches Quran menu palette)
// ─────────────────────────────────────────────────────────────────────────────

class _KhatmSessionToolButton extends StatelessWidget {
  const _KhatmSessionToolButton({
    required this.pal,
    required this.icon,
    required this.label,
    required this.iconColor,
    required this.fontFamily,
    required this.onTap,
  });

  final QuranMenuPaletteData pal;
  final IconData icon;
  final String label;
  final Color iconColor;
  final String fontFamily;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 2),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 50,
                height: 50,
                decoration: BoxDecoration(
                  color: pal.tileLeadingDecorationColor,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: pal.divider.withValues(alpha: 0.55),
                  ),
                ),
                child: Icon(icon, color: iconColor, size: 28),
              ),
              const SizedBox(height: 6),
              Text(
                label,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontFamily: fontFamily,
                  fontSize: 13,
                  height: 1.2,
                  color: pal.subtitle,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
