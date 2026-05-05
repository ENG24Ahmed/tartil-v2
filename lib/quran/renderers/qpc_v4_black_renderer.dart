import 'dart:math' show max, min;
import 'dart:ui' show BoxHeightStyle, BoxWidthStyle;

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:quran_app/audio/ayah_audio_player.dart';
import 'package:quran_app/quran/font_loader.dart' show buildAfterQcf4FontLoaded;
import 'package:quran_app/quran/models/mushaf_line.dart';
import 'package:quran_app/quran/page_cache.dart';
import 'package:quran_app/quran/mushaf_page_layout.dart';
import 'package:quran_app/quran/mushaf_ayah_highlight.dart';
import 'package:quran_app/quran/quran_db.dart';
import 'package:quran_app/quran/compact_line_spacing_scope.dart'
    show CompactLineSpacingScope, getCompactFontScaleFactor;
import 'package:quran_app/quran/renderers/qpc_v4_renderer.dart'
    show
        AyahHighlightStore,
        DelayedLongPressDetector,
        getQpcContentDimensions,
        getJustifiedLineStyle,
        getAyahRangesForPage,
        getAyahWordRangeForPage,
        loadQpcV4PageForDisplay,
        onQpcPageLongPress;

/// نسبة ارتفاع إطار اسم السورة إلى عرضه (من viewBox sura_name.svg: 1621.5×171).
const double _surahFrameAspect = 171 / 1621.5;
const String _surahNameFontFamily = 'SurahNameV4';
const double _basmallahRaiseDy = -2.0;
const String _basmallahFontFamily = 'KFGQPCHAFSUthmanicScript';
const double _kBasmallahFontSize = 18;
const double _persistentHighlightAlpha = 0.18;
const double _persistentHighlightTopInsetFraction = 0.06;
const double _persistentHighlightHeightFraction = 0.88;
const double _persistentHighlightRadius = 10.0;

List<({double left, double width, Color color})>
    _mergePersistentRectsByColorBlack(
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

Widget _buildPersistentHighlightSegmentBlack(
  ({double left, double width, Color color}) rect,
  double lineHeight,
) {
  return Positioned(
    left: rect.left,
    top: lineHeight * _persistentHighlightTopInsetFraction,
    width: rect.width,
    height: lineHeight * _persistentHighlightHeightFraction,
    child: CustomPaint(
      painter: _WavyHighlightPainterBlack(
        color: rect.color.withValues(alpha: _persistentHighlightAlpha),
      ),
    ),
  );
}

List<(int start, int end)> _markerCharRangesInAyahLine(List<AyahSegment> segs) {
  final ranges = <(int start, int end)>[];
  var cursor = 0;
  for (final seg in segs) {
    final next = cursor + seg.text.length;
    if (seg.isMarker && seg.text.isNotEmpty) {
      ranges.add((cursor, next));
    }
    cursor = next;
  }
  return ranges;
}

List<(int start, int end)> _nonMarkerCharRanges(List<AyahSegment> segs) {
  final ranges = <(int start, int end)>[];
  var cursor = 0;
  for (final seg in segs) {
    final next = cursor + seg.text.length;
    if (!seg.isMarker && seg.text.isNotEmpty) {
      ranges.add((cursor, next));
    }
    cursor = next;
  }
  return ranges;
}

bool _sameAyahSegments(List<AyahSegment> a, List<AyahSegment> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i].text != b[i].text || a[i].isMarker != b[i].isMarker) {
      return false;
    }
  }
  return true;
}

bool _sameCharRanges(
    List<(int start, int end)> a, List<(int start, int end)> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

List<(int start, int end, Color color)> _recitationCharRangesInAyahLine(
  List<AyahSegment> segs,
  int? rangeStart,
  Map<int, Color> recitationWordColors,
) {
  if (segs.isEmpty || rangeStart == null || recitationWordColors.isEmpty) {
    return const [];
  }

  final ranges = <(int start, int end, Color color)>[];
  var cursor = 0;
  for (var i = 0; i < segs.length; i++) {
    final seg = segs[i];
    final next = cursor + seg.text.length;
    if (!seg.isMarker && seg.text.isNotEmpty) {
      final wordId = rangeStart + i;
      final color = recitationWordColors[wordId];
      if (color != null) {
        if (ranges.isNotEmpty &&
            ranges.last.$3.toARGB32() == color.toARGB32() &&
            ranges.last.$2 == cursor) {
          final previous = ranges.removeLast();
          ranges.add((previous.$1, next, color));
        } else {
          ranges.add((cursor, next, color));
        }
      }
    }
    cursor = next;
  }
  return ranges;
}

/// قصّ يُظهر فقط مقطع علامة الآية من نفس [Text] الأصلي (بدون نص علوي مستقل).
class _BlackAyahMarkerRevealClipper extends CustomClipper<Path> {
  _BlackAyahMarkerRevealClipper({
    required this.lineText,
    required this.lineStyle,
    required this.isCentered,
    required this.ayahSegments,
    required this.textScaler,
  });

  final String lineText;
  final TextStyle lineStyle;
  final bool isCentered;
  final List<AyahSegment> ayahSegments;
  final TextScaler textScaler;

  @override
  Path getClip(Size size) {
    final ranges = _markerCharRangesInAyahLine(ayahSegments);
    if (ranges.isEmpty) {
      return Path();
    }
    final painter = TextPainter(
      text: TextSpan(text: lineText, style: lineStyle),
      textDirection: TextDirection.rtl,
      textAlign: isCentered ? TextAlign.center : TextAlign.right,
      maxLines: 1,
      textScaler: textScaler,
      textWidthBasis: TextWidthBasis.parent,
    )..layout(maxWidth: size.width);
    final path = Path();
    const pad = 1.0;
    for (final range in ranges) {
      for (final rect in _glyphRectsForSelectionRobust(
        painter,
        lineText,
        range.$1,
        range.$2,
        pad: pad,
      )) {
        path.addRect(rect);
      }
    }
    return path;
  }

  @override
  bool shouldReclip(covariant _BlackAyahMarkerRevealClipper oldClipper) {
    return oldClipper.lineText != lineText ||
        oldClipper.lineStyle != lineStyle ||
        oldClipper.isCentered != isCentered ||
        oldClipper.textScaler != textScaler ||
        !_sameAyahSegments(oldClipper.ayahSegments, ayahSegments);
  }
}

class _BlackAyahRangeClipper extends CustomClipper<Path> {
  _BlackAyahRangeClipper({
    required this.lineText,
    required this.lineStyle,
    required this.isCentered,
    required this.ranges,
    required this.textScaler,
  });

  final String lineText;
  final TextStyle lineStyle;
  final bool isCentered;
  final List<(int start, int end)> ranges;
  final TextScaler textScaler;

  @override
  Path getClip(Size size) {
    if (ranges.isEmpty) return Path();
    final painter = TextPainter(
      text: TextSpan(text: lineText, style: lineStyle),
      textDirection: TextDirection.rtl,
      textAlign: isCentered ? TextAlign.center : TextAlign.right,
      maxLines: 1,
      textScaler: textScaler,
      textWidthBasis: TextWidthBasis.parent,
    )..layout(maxWidth: size.width);
    final path = Path();
    const pad = 1.0;
    for (final range in ranges) {
      for (final rect in _glyphRectsForSelectionRobust(
        painter,
        lineText,
        range.$1,
        range.$2,
        pad: pad,
      )) {
        path.addRect(rect);
      }
    }
    return path;
  }

  @override
  bool shouldReclip(covariant _BlackAyahRangeClipper oldClipper) {
    return oldClipper.lineText != lineText ||
        oldClipper.lineStyle != lineStyle ||
        oldClipper.isCentered != isCentered ||
        oldClipper.textScaler != textScaler ||
        !_sameCharRanges(oldClipper.ranges, ranges);
  }
}

List<Rect> _tightBoxRectsForSelection(
  TextPainter laidOut, {
  required int start,
  required int end,
  double pad = 1.0,
}) {
  if (end <= start) return const <Rect>[];
  final boxes = laidOut.getBoxesForSelection(
    TextSelection(baseOffset: start, extentOffset: end),
    boxWidthStyle: BoxWidthStyle.tight,
    boxHeightStyle: BoxHeightStyle.tight,
  );
  return [for (final b in boxes) b.toRect().inflate(pad)];
}

/// When [getBoxesForSelection] returns nothing (RTL / ayah marker clusters), fall
/// back so marker reveal still paints above [ColorFiltered] black.
List<Rect> _glyphRectsForSelectionRobust(
  TextPainter laidOut,
  String lineText,
  int start,
  int end, {
  double pad = 1.0,
  bool allowLooseMaxFallback = true,
}) {
  if (end <= start || start < 0 || end > lineText.length) {
    return const <Rect>[];
  }
  var rects = _tightBoxRectsForSelection(
    laidOut,
    start: start,
    end: end,
    pad: 0,
  );
  if (rects.isNotEmpty) {
    return [for (final r in rects) r.inflate(pad)];
  }
  if (allowLooseMaxFallback) {
    final loose = laidOut.getBoxesForSelection(
      TextSelection(baseOffset: start, extentOffset: end),
      boxWidthStyle: BoxWidthStyle.max,
      boxHeightStyle: BoxHeightStyle.max,
    );
    if (loose.isNotEmpty) {
      return [for (final b in loose) b.toRect().inflate(pad)];
    }
  }
  final proto =
      Rect.fromLTWH(0, 0, laidOut.width.clamp(1, 99999), laidOut.height);
  final oStart = laidOut.getOffsetForCaret(
    TextPosition(offset: start, affinity: TextAffinity.downstream),
    proto,
  );
  final oEnd = laidOut.getOffsetForCaret(
    TextPosition(offset: end, affinity: TextAffinity.upstream),
    proto,
  );
  final left = min(oStart.dx, oEnd.dx);
  final right = max(oStart.dx, oEnd.dx);
  if (right - left < 0.15 && (oEnd.dx - oStart.dx).abs() < 0.15) {
    return const <Rect>[];
  }
  return [
    Rect.fromLTRB(left - pad, -pad, right + pad, laidOut.height + pad),
  ];
}

/// Pull non-marker clip rects away from marker ink horizontally (RTL) so black
/// [srcIn] doesn’t cover the right edge of ayah markers.
List<Rect> _shrinkNonMarkerRectsAwayFromMarkers(
  List<Rect> nonMarker,
  List<Rect> markerRects,
  double gap,
) {
  if (markerRects.isEmpty || nonMarker.isEmpty || gap <= 0) return nonMarker;
  final out = <Rect>[];
  for (final s in nonMarker) {
    var left = s.left;
    var right = s.right;
    for (final m in markerRects) {
      if (s.bottom <= m.top || s.top >= m.bottom) continue;
      final mx0 = m.left - gap;
      final mx1 = m.right + gap;
      if (right <= mx0 || left >= mx1) continue;
      final mcx = m.center.dx;
      final scx = s.center.dx;
      if (mcx > scx) {
        right = min(right, mx0);
      } else if (mcx < scx) {
        left = max(left, mx1);
      }
    }
    if (right > left + 0.5) {
      out.add(Rect.fromLTRB(left, s.top, right, s.bottom));
    }
  }
  return out;
}

/// Clip rects for [srcIn] black on non-marker spans only (no [BoxWidthStyle.max],
/// so boxes don’t extend into ayah marker clusters).
List<Rect> _nonMarkerBlackClipRects(
  TextPainter laidOut,
  String lineText,
  List<AyahSegment> ayahSegments,
  double markerAdjacentTrimPx,
) {
  var rects = <Rect>[];
  for (final r in _nonMarkerCharRanges(ayahSegments)) {
    rects.addAll(
      _glyphRectsForSelectionRobust(
        laidOut,
        lineText,
        r.$1,
        r.$2,
        allowLooseMaxFallback: false,
      ),
    );
  }
  if (markerAdjacentTrimPx > 0) {
    final markerBoxes = <Rect>[];
    for (final r in _markerCharRangesInAyahLine(ayahSegments)) {
      markerBoxes.addAll(
        _glyphRectsForSelectionRobust(
          laidOut,
          lineText,
          r.$1,
          r.$2,
          allowLooseMaxFallback: false,
        ),
      );
    }
    if (markerBoxes.isNotEmpty) {
      rects = _shrinkNonMarkerRectsAwayFromMarkers(
        rects,
        markerBoxes,
        markerAdjacentTrimPx,
      );
    }
  }
  return rects;
}

Rect? _rectUnion(List<Rect> rects) {
  if (rects.isEmpty) return null;
  var left = rects.first.left;
  var top = rects.first.top;
  var right = rects.first.right;
  var bottom = rects.first.bottom;
  for (var i = 1; i < rects.length; i++) {
    final r = rects[i];
    if (r.left < left) left = r.left;
    if (r.top < top) top = r.top;
    if (r.right > right) right = r.right;
    if (r.bottom > bottom) bottom = r.bottom;
  }
  return Rect.fromLTRB(left, top, right, bottom);
}

class _MushafTextBoxListClipper extends CustomClipper<Path> {
  const _MushafTextBoxListClipper({required this.boxes});
  final List<Rect> boxes;

  @override
  Path getClip(Size size) {
    final p = Path();
    for (final r in boxes) {
      p.addRect(r);
    }
    return p;
  }

  @override
  bool shouldReclip(covariant _MushafTextBoxListClipper o) {
    if (o.boxes.length != boxes.length) return true;
    for (var i = 0; i < boxes.length; i++) {
      if (o.boxes[i] != boxes[i]) return true;
    }
    return false;
  }
}

class _WavyHighlightPainterBlack extends CustomPainter {
  const _WavyHighlightPainterBlack({required this.color});
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    canvas.save();
    canvas.clipRRect(
      RRect.fromRectAndRadius(
        Offset.zero & size,
        const Radius.circular(_persistentHighlightRadius),
      ),
    );
    final waveInset = (size.height * 0.10).clamp(0.6, 1.8).toDouble();
    final amplitude = (size.height * 0.07).clamp(0.6, 1.8).toDouble();
    final step = (size.width / 6).clamp(14.0, 30.0).toDouble();
    final topY = waveInset.toDouble();
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
  bool shouldRepaint(covariant _WavyHighlightPainterBlack oldDelegate) {
    return oldDelegate.color.toARGB32() != color.toARGB32();
  }
}

class QpcV4BlackPageView extends StatelessWidget {
  const QpcV4BlackPageView({
    super.key,
    required this.page,
    this.forceWhiteTextOnDark = false,
    this.hideUnrevealedWords = false,
    this.recitationWordColors = const {},
    this.usePreciseRecitationOverlay = false,
    this.lightweightMode = false,
    this.mediumQualityMode = false,
  });
  final int page;
  final bool forceWhiteTextOnDark;
  final bool hideUnrevealedWords;
  final Map<int, Color> recitationWordColors;
  final bool usePreciseRecitationOverlay;
  final bool lightweightMode;
  final bool mediumQualityMode;
  static const int _blackUniformScaleCacheMaxEntries = 240;
  static final Map<String, double> _blackUniformScaleCache =
      <String, double>{};

  @override
  Widget build(BuildContext context) {
    const baseStyle = TextStyle(
      fontSize: 23,
      height: 1.45,
      letterSpacing: 0,
      wordSpacing: 0,
      fontFeatures: [FontFeature.disable('kern')],
    );

    final cached = PageCache.instance.get('qpc4', page);
    if (cached != null && cached.isNotEmpty) {
      return buildAfterQcf4FontLoaded(
        page,
        () => _buildPageWithMapping(
          context,
          page,
          cached,
          baseStyle,
          forceWhiteTextOnDark: forceWhiteTextOnDark,
          hideUnrevealedWords: hideUnrevealedWords,
          recitationWordColors: recitationWordColors,
          usePreciseRecitationOverlay: usePreciseRecitationOverlay,
          lightweightMode: lightweightMode,
          mediumQualityMode: mediumQualityMode,
        ),
        placeholder: (context) => ColoredBox(
          color: MushafPaperBackgroundScope.of(context),
          child: const SizedBox.expand(),
        ),
      );
    }

    return FutureBuilder<List<MushafPageLine>>(
      future: loadQpcV4PageForDisplay(page),
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
        return _buildPageWithMapping(
          context,
          page,
          pageLines,
          baseStyle,
          forceWhiteTextOnDark: forceWhiteTextOnDark,
          hideUnrevealedWords: hideUnrevealedWords,
          recitationWordColors: recitationWordColors,
          usePreciseRecitationOverlay: usePreciseRecitationOverlay,
          lightweightMode: lightweightMode,
          mediumQualityMode: mediumQualityMode,
        );
      },
    );
  }

  static TextStyle _lineStyleForBlack(MushafPageLine line, TextStyle baseStyle,
      {double fontSizeScale = 1.0}) {
    if (line.lineType == 'surah_name') {
      return baseStyle.copyWith(
          fontFamily: _surahNameFontFamily, fontSize: 22 * fontSizeScale);
    }
    if (line.lineType == 'basmallah') {
      return TextStyle(
        fontFamily: _basmallahFontFamily,
        fontSize: _kBasmallahFontSize * fontSizeScale,
        height: 1.15,
        fontWeight: FontWeight.w600,
        color: Colors.black,
      );
    }
    return baseStyle.copyWith(fontFamily: line.fontFamily);
  }

  static Widget _buildPageWithMapping(BuildContext context, int page,
      List<MushafPageLine> pageLines, TextStyle baseStyle,
      {bool forceWhiteTextOnDark = false,
      bool hideUnrevealedWords = false,
      Map<int, Color> recitationWordColors = const {},
      bool usePreciseRecitationOverlay = false,
      bool lightweightMode = false,
      bool mediumQualityMode = false}) {
    int? minR;
    int? maxR;
    for (final line in pageLines) {
      if (line.lineType == 'ayah' &&
          line.rangeStart != null &&
          line.rangeEnd != null) {
        minR = minR == null
            ? line.rangeStart!
            : (line.rangeStart! < minR ? line.rangeStart! : minR);
        maxR = maxR == null
            ? line.rangeEnd!
            : (line.rangeEnd! > maxR ? line.rangeEnd! : maxR);
      }
    }
    if (minR == null || maxR == null) {
      return _buildContent(
        context,
        page,
        pageLines,
        baseStyle,
        null,
        null,
        null,
        null,
        forceWhiteTextOnDark: forceWhiteTextOnDark,
        hideUnrevealedWords: hideUnrevealedWords,
        recitationWordColors: recitationWordColors,
        usePreciseRecitationOverlay: usePreciseRecitationOverlay,
      );
    }
    if (lightweightMode) {
      return _buildContent(
        context,
        page,
        pageLines,
        baseStyle,
        null,
        null,
        null,
        null,
        forceWhiteTextOnDark: forceWhiteTextOnDark,
        hideUnrevealedWords: false,
        recitationWordColors: const {},
        usePreciseRecitationOverlay: false,
      );
    }
    if (mediumQualityMode) {
      return _WordToAyahMappingLoaderBlack(
        minRange: minR,
        maxRange: maxR,
        builder: (mapping) => _buildContent(
          context,
          page,
          pageLines,
          baseStyle,
          mapping,
          null,
          null,
          null,
          forceWhiteTextOnDark: forceWhiteTextOnDark,
          hideUnrevealedWords: false,
          recitationWordColors: const {},
          usePreciseRecitationOverlay: false,
        ),
      );
    }
    return _WordToAyahMappingLoaderBlack(
      minRange: minR,
      maxRange: maxR,
      builder: (mapping) => _QpcV4BlackPageContentStateful(
        page: page,
        pageLines: pageLines,
        baseStyle: baseStyle,
        mapping: mapping,
        forceWhiteTextOnDark: forceWhiteTextOnDark,
        hideUnrevealedWords: hideUnrevealedWords,
        recitationWordColors: recitationWordColors,
        usePreciseRecitationOverlay: usePreciseRecitationOverlay,
      ),
    );
  }

  /// سطر آية أسود: [ColorFiltered] يزيل ألوان التجويد في خط QCF.
  /// نفس حقول [Text] كما في سطر الآية في [QpcV4PageView] (بدون [TextScaler.noScaling])
  /// حتى يطابق التجويد موضعًا؛ عند وجود علامة آية: رسم واحد + استثناء العلامة من srcIn.
  static Widget _buildBlackAyahLine({
    required BuildContext context,
    required String lineText,
    required TextStyle lineStyle,
    required Color glyphColor,
    required bool isCentered,
    required double lineLayoutWidth,
    List<AyahSegment>? ayahSegments,
    int? rangeStart,
    bool hideUnrevealedWords = false,
    Map<int, Color> recitationWordColors = const {},
    bool usePreciseRecitationOverlay = false,
  }) {
    final textScaler = MediaQuery.textScalerOf(context);
    final paperColor = MushafPaperBackgroundScope.of(context);
    final align = isCentered ? TextAlign.center : TextAlign.right;
    Text baseTextWidget() => Text(
          lineText,
          textDirection: TextDirection.rtl,
          textAlign: align,
          softWrap: false,
          maxLines: 1,
          overflow: TextOverflow.visible,
          textScaler: textScaler,
          textWidthBasis: TextWidthBasis.parent,
          style: lineStyle,
        );
    final markerAdjacentTrimPx =
        ((lineStyle.fontSize ?? 23) * 0.026).clamp(0.55, 1.15);
    final hasMarkerLayer = ayahSegments != null &&
        ayahSegments.isNotEmpty &&
        ayahSegments.any((s) => s.isMarker);
    final recitationRanges = ayahSegments == null
        ? const <(int start, int end, Color color)>[]
        : _recitationCharRangesInAyahLine(
            ayahSegments,
            rangeStart,
            recitationWordColors,
          );
    final baseGlyphColor = hideUnrevealedWords ? paperColor : glyphColor;
    if (!usePreciseRecitationOverlay &&
        !hasMarkerLayer &&
        recitationRanges.isEmpty) {
      return ColorFiltered(
        colorFilter: ColorFilter.mode(baseGlyphColor, BlendMode.srcIn),
        child: baseTextWidget(),
      );
    }
    final usePreciseOverlayNow = usePreciseRecitationOverlay;
    if (usePreciseOverlayNow) {
      final laidOut = TextPainter(
        text: TextSpan(text: lineText, style: lineStyle),
        textDirection: TextDirection.rtl,
        textAlign: align,
        maxLines: 1,
        textScaler: textScaler,
        textWidthBasis: TextWidthBasis.parent,
      )..layout(maxWidth: lineLayoutWidth);

      final children = <Widget>[];

      void addRecitationOrMarkerLayer({
        required int start,
        required int end,
        required bool colorFiltered,
        Color? filterColor,
      }) {
        if (start < 0 || end <= start || end > lineText.length) return;
        final rects = colorFiltered
            ? _tightBoxRectsForSelection(
                laidOut,
                start: start,
                end: end,
              )
            : _glyphRectsForSelectionRobust(
                laidOut,
                lineText,
                start,
                end,
              );
        if (rects.isEmpty) return;
        if (rects.length == 1) {
          final r = rects.first;
          if (!r.isFinite) return;
          final sub = lineText.substring(start, end);
          if (sub.isEmpty) return;
          final inner = Text(
            sub,
            textDirection: TextDirection.rtl,
            textAlign: TextAlign.center,
            softWrap: false,
            maxLines: 1,
            overflow: TextOverflow.visible,
            textScaler: textScaler,
            textWidthBasis: TextWidthBasis.parent,
            style: lineStyle,
          );
          final painted = colorFiltered && filterColor != null
              ? ColorFiltered(
                  colorFilter: ColorFilter.mode(filterColor, BlendMode.srcIn),
                  child: inner,
                )
              : inner;
          final subPainter = TextPainter(
            text: TextSpan(text: sub, style: lineStyle),
            textDirection: TextDirection.rtl,
            textAlign: TextAlign.center,
            maxLines: 1,
            textScaler: textScaler,
            textWidthBasis: TextWidthBasis.parent,
          )..layout(maxWidth: r.width);
          final subRects = _tightBoxRectsForSelection(
            subPainter,
            start: 0,
            end: sub.length,
            pad: 0,
          );
          final subBounds = _rectUnion(subRects);
          final horizontalNudge = -((lineStyle.fontSize ?? 23) * 0.090);
          final overlayTop =
              subBounds == null ? r.top : (r.center.dy - subBounds.center.dy);
          final overlayLeft = subBounds == null
              ? (r.left + horizontalNudge)
              : (r.center.dx - subBounds.center.dx + horizontalNudge);
          final overlayHeight =
              subPainter.height > 0 ? subPainter.height : r.height;
          children.add(
            Positioned(
              left: overlayLeft,
              top: overlayTop,
              width: r.width,
              height: overlayHeight,
              child: SizedBox(
                width: r.width,
                height: overlayHeight,
                child: Align(
                  alignment: Alignment.center,
                  child: painted,
                ),
              ),
            ),
          );
          return;
        }
        if (colorFiltered && filterColor != null) {
          children.add(
            ClipPath(
              clipBehavior: Clip.hardEdge,
              clipper: _MushafTextBoxListClipper(boxes: rects),
              child: ColorFiltered(
                colorFilter: ColorFilter.mode(filterColor, BlendMode.srcIn),
                child: baseTextWidget(),
              ),
            ),
          );
        } else {
          children.add(
            ClipPath(
              clipBehavior: Clip.hardEdge,
              clipper: _MushafTextBoxListClipper(boxes: rects),
              child: baseTextWidget(),
            ),
          );
        }
      }

      /// Full tajweed underneath; black [srcIn] only on non-marker spans — markers
      /// never pass through flat black (fixes lines where marker “reveal” boxes fail).
      if (hasMarkerLayer && !hideUnrevealedWords) {
        final nonMarkerRects = _nonMarkerBlackClipRects(
          laidOut,
          lineText,
          ayahSegments,
          markerAdjacentTrimPx,
        );
        children.add(Positioned.fill(child: baseTextWidget()));
        if (nonMarkerRects.isNotEmpty) {
          children.add(
            ClipPath(
              clipBehavior: Clip.hardEdge,
              clipper: _MushafTextBoxListClipper(boxes: nonMarkerRects),
              child: ColorFiltered(
                colorFilter: ColorFilter.mode(baseGlyphColor, BlendMode.srcIn),
                child: baseTextWidget(),
              ),
            ),
          );
        }
        for (final range in recitationRanges) {
          addRecitationOrMarkerLayer(
            start: range.$1,
            end: range.$2,
            colorFiltered: true,
            filterColor: range.$3,
          );
        }
        return Stack(
          alignment: Alignment.topCenter,
          clipBehavior: Clip.none,
          children: children,
        );
      }

      // Base layer in precise mode: draw full ayah line using the same
      // positioned top-layer pipeline so all lines share one rendering path.
      addRecitationOrMarkerLayer(
        start: 0,
        end: lineText.length,
        colorFiltered: true,
        filterColor: baseGlyphColor,
      );

      for (final range in recitationRanges) {
        addRecitationOrMarkerLayer(
          start: range.$1,
          end: range.$2,
          colorFiltered: true,
          filterColor: range.$3,
        );
      }
      if (hasMarkerLayer) {
        for (final range in _markerCharRangesInAyahLine(ayahSegments)) {
          addRecitationOrMarkerLayer(
            start: range.$1,
            end: range.$2,
            colorFiltered: false,
          );
        }
      }

      return Stack(
        alignment: Alignment.topCenter,
        clipBehavior: Clip.none,
        children: children,
      );
    }

    final overlayLayers = <Widget>[];
    if (hasMarkerLayer && !hideUnrevealedWords) {
      final pOverlay = TextPainter(
        text: TextSpan(text: lineText, style: lineStyle),
        textDirection: TextDirection.rtl,
        textAlign: align,
        maxLines: 1,
        textScaler: textScaler,
        textWidthBasis: TextWidthBasis.parent,
      )..layout(maxWidth: lineLayoutWidth);
      final nonMarkerRects = _nonMarkerBlackClipRects(
        pOverlay,
        lineText,
        ayahSegments,
        markerAdjacentTrimPx,
      );
      overlayLayers.add(Positioned.fill(child: baseTextWidget()));
      if (nonMarkerRects.isNotEmpty) {
        overlayLayers.add(
          ClipPath(
            clipBehavior: Clip.hardEdge,
            clipper: _MushafTextBoxListClipper(boxes: nonMarkerRects),
            child: ColorFiltered(
              colorFilter: ColorFilter.mode(baseGlyphColor, BlendMode.srcIn),
              child: baseTextWidget(),
            ),
          ),
        );
      }
    } else {
      overlayLayers.add(
        ColorFiltered(
          colorFilter: ColorFilter.mode(baseGlyphColor, BlendMode.srcIn),
          child: baseTextWidget(),
        ),
      );
    }

    for (final range in recitationRanges) {
      overlayLayers.add(
        ClipPath(
          clipBehavior: Clip.hardEdge,
          clipper: _BlackAyahRangeClipper(
            lineText: lineText,
            lineStyle: lineStyle,
            isCentered: isCentered,
            ranges: [(range.$1, range.$2)],
            textScaler: textScaler,
          ),
          child: ColorFiltered(
            colorFilter: ColorFilter.mode(range.$3, BlendMode.srcIn),
            child: baseTextWidget(),
          ),
        ),
      );
    }

    if (hasMarkerLayer && hideUnrevealedWords) {
      overlayLayers.add(
        ClipPath(
          clipBehavior: Clip.hardEdge,
          clipper: _BlackAyahMarkerRevealClipper(
            lineText: lineText,
            lineStyle: lineStyle,
            isCentered: isCentered,
            ayahSegments: ayahSegments,
            textScaler: textScaler,
          ),
          child: baseTextWidget(),
        ),
      );
    }

    return Stack(
      alignment: Alignment.topCenter,
      clipBehavior: Clip.none,
      children: overlayLayers,
    );
  }

  /// مقياس واحد لجميع أسطر الآية في الصفحة (مثل أضيق سطر يحتاج تصغيراً) حتى لا يختلف حجم الخط بين السطور بسبب [FittedBox] لكل سطر.
  static double _computeBlackUniformAyahScale(
    int page,
    List<MushafPageLine> displayLines,
    double layoutW,
    double slotHeight,
    TextStyle effectiveBaseStyle,
    double lineStyleFontSizeScale,
  ) {
    final cacheKey = [
      page,
      layoutW.toStringAsFixed(2),
      slotHeight.toStringAsFixed(2),
      (effectiveBaseStyle.fontSize ?? 23).toStringAsFixed(4),
      lineStyleFontSizeScale.toStringAsFixed(4),
    ].join('|');
    final cached = _blackUniformScaleCache[cacheKey];
    if (cached != null) return cached;

    var minScale = 1.0;
    for (final line in displayLines) {
      if (line.lineType != 'ayah') continue;
      final lineStyle = _lineStyleForBlack(line, effectiveBaseStyle,
          fontSizeScale: lineStyleFontSizeScale);
      final style = line.isCentered
          ? lineStyle
          : getJustifiedLineStyle(line, lineStyle, layoutW);
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
    if (_blackUniformScaleCache.length >= _blackUniformScaleCacheMaxEntries) {
      _blackUniformScaleCache.remove(_blackUniformScaleCache.keys.first);
    }
    _blackUniformScaleCache[cacheKey] = minScale;
    return minScale;
  }

  static Widget _buildContent(
    BuildContext context,
    int page,
    List<MushafPageLine> pageLines,
    TextStyle baseStyle,
    Map<int, (int sura, int ayah)>? mapping,
    List<(int lineIndex, int startChar, int endChar)>? selection,
    void Function(List<(int lineIndex, int startChar, int endChar)>)?
        onSelectLine,
    void Function()? onClearSelection, {
    (int, int, int)? wordSelection,
    List<(int, int, int, Color)>? persistentSelection,
    bool forceWhiteTextOnDark = false,
    bool hideUnrevealedWords = false,
    Map<int, Color> recitationWordColors = const {},
    bool usePreciseRecitationOverlay = false,
  }) {
    final glyphColor = forceWhiteTextOnDark ? Colors.white : Colors.black;

    final ayahSelectionColor = forceWhiteTextOnDark
        ? const Color(0xFFB3E5FC)
        : const Color.fromARGB(255, 45, 45, 45);
    final wordSelectionColor = forceWhiteTextOnDark
        ? const Color(0xFF7CFFC4)
        : const Color(0xFFB8E6C1);
    final ayahSelectionAlpha = forceWhiteTextOnDark ? 0.34 : 0.18;
    final wordSelectionAlpha = forceWhiteTextOnDark ? 0.48 : 0.30;
    return LayoutBuilder(
      builder: (context, constraints) {
        final isCompact = CompactLineSpacingScope.isCompact(context);
        final availableWidth = constraints.maxWidth;
        final availableHeight = constraints.maxHeight;
        final seamlessLongScrollBody =
            SeamlessLongScrollScope.isActive(context);
        final metrics = computeMushafInnerLayoutMetrics(
          maxWidth: availableWidth,
          maxHeight: availableHeight,
          isCompact: isCompact,
          omitVerticalMargins: seamlessLongScrollBody,
        );

        final compactBaseScale =
            isCompact ? getCompactFontScaleFactor(context) : 1.0;
        final prefitBaseStyle = isCompact
            ? baseStyle.copyWith(
                fontSize: (baseStyle.fontSize ?? 23) * compactBaseScale,
              )
            : baseStyle;

        final linePad = CompactLineSpacingScope.linePaddingOf(context);
        final (prefitContentW, _) = getQpcContentDimensions(
          pageLines,
          prefitBaseStyle,
          linePaddingBottom: linePad,
        );
        final availableContentW = metrics.innerWidth;
        final compactFitScale = (isCompact &&
                prefitContentW > 0 &&
                prefitContentW > availableContentW)
            ? (availableContentW / prefitContentW).clamp(0.5, 1.0)
            : 1.0;
        final fontScale = compactBaseScale * compactFitScale;
        final effectiveBaseStyle = isCompact
            ? baseStyle.copyWith(
                fontSize: (baseStyle.fontSize ?? 23) * fontScale,
              )
            : baseStyle;

        final contentW = metrics.innerWidth;

        const int slotsCount = kMushafLineSlotCount;
        final displayLines = pageLines.length >= slotsCount
            ? pageLines.sublist(0, slotsCount)
            : pageLines;
        MushafPageLine probeLine = displayLines.first;
        for (final l in displayLines) {
          if (l.lineType == 'ayah') {
            probeLine = l;
            break;
          }
        }
        final slotNatural = metrics.slotHeight;
        var bodyStyle = effectiveBaseStyle;
        var bodyLinePad = linePad;
        late double minSlotH;
        late double layoutHeight;
        late double slotHeight;
        for (var squeezeIter = 0; squeezeIter < 8; squeezeIter++) {
          final probeStyle =
              bodyStyle.copyWith(fontFamily: probeLine.fontFamily);
          minSlotH = mushafMinSlotHeightForAyahStyle(
            ayahStyle: probeStyle,
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
          bodyStyle = bodyStyle.copyWith(
            fontSize: (bodyStyle.fontSize ?? 23) * squeeze,
          );
          bodyLinePad *= squeeze;
        }

        final refBaseSize = effectiveBaseStyle.fontSize ?? 23;
        final lineStyleFontScale = (isCompact ? fontScale : 1.0) *
            ((bodyStyle.fontSize ?? 23) / refBaseSize);

        final uniformAyahScale = _computeBlackUniformAyahScale(
          page,
          displayLines,
          contentW,
          slotHeight,
          bodyStyle,
          lineStyleFontScale,
        );

        final pageLinesWidgets = pageLines.asMap().entries.map((entry) {
          final lineIndex = entry.key;
          final line = entry.value;
          Widget lineWidget;
          if (line.lineType == 'surah_name') {
            final frameHeight = contentW * _surahFrameAspect;
            lineWidget = Padding(
              padding: EdgeInsets.only(bottom: bodyLinePad),
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
                      width: contentW,
                      height: frameHeight,
                      // استثناء سطر اسم السورة من فرض اللون الأسود — الإطار يظهر بالألوان الأصلية في sura_name.svg.
                    ),
                    Center(
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Padding(
                          padding:
                              EdgeInsets.symmetric(horizontal: contentW * 0.08),
                          child: Text(
                            mushafSurahTitleDisplayText(line.lineText),
                            textDirection: TextDirection.rtl,
                            textAlign: TextAlign.center,
                            maxLines: 1,
                            overflow: TextOverflow.visible,
                            style: getJustifiedLineStyle(
                              line,
                              _lineStyleForBlack(
                                line,
                                bodyStyle,
                                fontSizeScale: lineStyleFontScale,
                              ),
                              contentW,
                            ).copyWith(color: glyphColor),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          } else if (line.lineType == 'basmallah') {
            lineWidget = Padding(
              padding: EdgeInsets.only(bottom: bodyLinePad),
              child: Align(
                alignment: Alignment.center,
                child: SizedBox(
                  width: double.infinity,
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.center,
                    child: Transform.translate(
                      offset: Offset(0, _basmallahRaiseDy * lineStyleFontScale),
                      child: Text(
                        line.lineText,
                        textDirection: TextDirection.rtl,
                        textAlign: TextAlign.center,
                        softWrap: false,
                        maxLines: 1,
                        overflow: TextOverflow.visible,
                        style: _lineStyleForBlack(
                          line,
                          bodyStyle,
                          fontSizeScale: lineStyleFontScale,
                        ).copyWith(color: glyphColor),
                      ),
                    ),
                  ),
                ),
              ),
            );
          } else {
            final baseForLine = bodyStyle.copyWith(
              fontSize: (bodyStyle.fontSize ?? 23) * uniformAyahScale,
            );
            final lineStyleStep = _lineStyleForBlack(
              line,
              baseForLine,
              fontSizeScale: lineStyleFontScale,
            );
            final lineStyle =
                getJustifiedLineStyle(line, lineStyleStep, contentW);
            final lineWidth = mushafMeasureLineWidth(line.lineText, lineStyle);
            final lineContent = _buildBlackAyahLine(
              context: context,
              lineText: line.lineText,
              lineStyle: lineStyle,
              glyphColor: glyphColor,
              isCentered: line.isCentered,
              lineLayoutWidth: lineWidth,
              ayahSegments: line.ayahSegments,
              rangeStart: line.rangeStart,
              hideUnrevealedWords: hideUnrevealedWords,
              recitationWordColors: recitationWordColors,
              usePreciseRecitationOverlay: usePreciseRecitationOverlay,
            );
            final linePainter = mushafLaidOutRtlLinePainter(
              line.lineText,
              lineStyle,
              lineWidth,
            );
            final lineH = linePainter.height;
            Widget buildStableAyahShell(List<Widget> overlayWidgets) {
              return Padding(
                padding: EdgeInsets.only(bottom: bodyLinePad),
                child: Align(
                  alignment: Alignment.center,
                  child: SizedBox(
                    width: double.infinity,
                    height: lineH,
                    child: Align(
                      alignment: Alignment.topCenter,
                      child: mushafHighlightLineStackFixed(
                        lineWidth: lineWidth,
                        lineHeight: lineH,
                        lineText: lineContent,
                        overlayWidgets: overlayWidgets,
                      ),
                    ),
                  ),
                ),
              );
            }

            lineWidget = buildStableAyahShell(const []);

            (int, int, int)? lineSelection;
            if (selection != null) {
              for (final e in selection) {
                if (e.$1 == lineIndex) {
                  lineSelection = e;
                  break;
                }
              }
            }
            (int, int, int)? lineWordSelection;
            if (wordSelection != null && wordSelection.$1 == lineIndex) {
              lineWordSelection = wordSelection;
            }
            final linePersistentSelections = <(int, int, int, Color)>[];
            if (persistentSelection != null) {
              for (final p in persistentSelection) {
                if (p.$1 == lineIndex) {
                  linePersistentSelections.add(p);
                }
              }
            }
            if (lineSelection != null &&
                line.lineType == 'ayah' &&
                lineSelection.$2 >= 0 &&
                lineSelection.$3 > lineSelection.$2) {
              final painter = mushafLaidOutRtlLinePainter(
                  line.lineText, lineStyle, lineWidth);
              final ayahR = mushafRangeHorizontalRectWithFallback(
                painter: painter,
                text: line.lineText,
                style: lineStyle,
                startChar: lineSelection.$2.clamp(0, line.lineText.length),
                endChar: lineSelection.$3.clamp(0, line.lineText.length),
              );
              final overlayWidgets = <Widget>[];
              if (linePersistentSelections.isNotEmpty) {
                final persistentRects =
                    <({double left, double width, Color color})>[];
                for (final h in linePersistentSelections) {
                  final rect = mushafWordHighlightRect(
                    painter: painter,
                    text: line.lineText,
                    style: lineStyle,
                    startChar: h.$2.clamp(0, line.lineText.length),
                    endChar: h.$3.clamp(0, line.lineText.length),
                  );
                  if (rect != null && rect.width > 0.01) {
                    persistentRects
                        .add((left: rect.left, width: rect.width, color: h.$4));
                  }
                }
                for (final r
                    in _mergePersistentRectsByColorBlack(persistentRects)) {
                  overlayWidgets
                      .add(_buildPersistentHighlightSegmentBlack(r, lineH));
                }
              }
              overlayWidgets.add(
                mushafFlatHighlightBar(
                  left: ayahR.left,
                  width: ayahR.width,
                  lineHeight: lineH,
                  color: ayahSelectionColor,
                  alpha: ayahSelectionAlpha,
                ),
              );
              if (lineWordSelection != null &&
                  lineWordSelection.$2 >= 0 &&
                  lineWordSelection.$3 > lineWordSelection.$2) {
                final wordR = mushafRangeHorizontalRectWithFallback(
                  painter: painter,
                  text: line.lineText,
                  style: lineStyle,
                  startChar:
                      lineWordSelection.$2.clamp(0, line.lineText.length),
                  endChar: lineWordSelection.$3.clamp(0, line.lineText.length),
                );
                if (wordR.width > 0.01) {
                  overlayWidgets.add(mushafFlatHighlightBar(
                    left: wordR.left,
                    width: wordR.width,
                    lineHeight: lineH,
                    color: wordSelectionColor,
                    alpha: wordSelectionAlpha,
                  ));
                }
              }
              return buildStableAyahShell(overlayWidgets);
            }
            if (lineSelection == null &&
                linePersistentSelections.isNotEmpty &&
                line.lineType == 'ayah') {
              final painter = mushafLaidOutRtlLinePainter(
                  line.lineText, lineStyle, lineWidth);
              final rects = <({double left, double width, Color color})>[];
              for (final h in linePersistentSelections) {
                final rect = mushafWordHighlightRect(
                  painter: painter,
                  text: line.lineText,
                  style: lineStyle,
                  startChar: h.$2.clamp(0, line.lineText.length),
                  endChar: h.$3.clamp(0, line.lineText.length),
                );
                if (rect != null && rect.width > 0.01) {
                  rects.add((left: rect.left, width: rect.width, color: h.$4));
                }
              }
              if (rects.isEmpty) return lineWidget;
              final mergedRects = _mergePersistentRectsByColorBlack(rects);
              return buildStableAyahShell([
                for (final r in mergedRects)
                  _buildPersistentHighlightSegmentBlack(r, lineH),
              ]);
            }
            if (lineWordSelection != null &&
                line.lineType == 'ayah' &&
                lineWordSelection.$2 >= 0 &&
                lineWordSelection.$3 > lineWordSelection.$2) {
              final painter = mushafLaidOutRtlLinePainter(
                  line.lineText, lineStyle, lineWidth);
              final wordR = mushafRangeHorizontalRectWithFallback(
                painter: painter,
                text: line.lineText,
                style: lineStyle,
                startChar: lineWordSelection.$2.clamp(0, line.lineText.length),
                endChar: lineWordSelection.$3.clamp(0, line.lineText.length),
              );
              if (wordR.width <= 0.01) return lineWidget;
              return buildStableAyahShell([
                mushafFlatHighlightBar(
                  left: wordR.left,
                  width: wordR.width,
                  lineHeight: lineH,
                  color: ayahSelectionColor,
                  alpha: ayahSelectionAlpha,
                ),
              ]);
            }
            return lineWidget;
          }
          return lineWidget;
        }).toList();

        // نبني 15 خانة متساوية الارتفاع، ونضع في كل خانة سطراً أو خانة فارغة.
        final slots = <Widget>[];
        for (int i = 0; i < slotsCount; i++) {
          Widget lineChild = const SizedBox.shrink();
          // في الصفحتين 1 و 2 نترك أول 3 خانات فارغة، فيبدأ أول سطر من الخانة الرابعة.
          final srcIndex = (page == 1 || page == 2) ? i - 3 : i;
          if (srcIndex >= 0 && srcIndex < displayLines.length) {
            lineChild = pageLinesWidgets[srcIndex];
          }

          slots.add(SizedBox(
            height: slotHeight,
            child: Align(
              alignment: Alignment.topCenter,
              child: lineChild,
            ),
          ));
        }

        final column15 = Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: slots,
        );

        // lineHeights لا بد أن تعكس 15 خانة متساوية لربط الضغط المطول.
        final lineHeights15 =
            List<double>.filled(slotsCount, slotHeight, growable: false);

        final availableW = metrics.innerWidth;
        final pageWidth = availableW;

        Widget buildBlackColumnBox() {
          return SizedBox(
            width: pageWidth,
            height: layoutHeight,
            child: mapping != null
                ? DelayedLongPressDetector(
                    duration: const Duration(milliseconds: 400),
                    onTrigger: (Offset pos) {
                      onQpcPageLongPress(
                        context,
                        pos,
                        contentW,
                        layoutHeight,
                        lineHeights15,
                        displayLines,
                        bodyStyle,
                        mapping,
                        (line, base) => _lineStyleForBlack(
                          line,
                          base,
                          fontSizeScale: lineStyleFontScale,
                        ),
                        onSelectLine: onSelectLine,
                        onClearSelection: onClearSelection,
                        lineTextHorizontallyCentered: true,
                        uniformAyahScale: uniformAyahScale,
                        hitTestColumnWidth: pageWidth,
                        visualLineIndexOffset: (page == 1 || page == 2) ? 3 : 0,
                      );
                    },
                    child: column15,
                  )
                : column15,
          );
        }

        final columnAlign =
            seamlessLongScrollBody ? Alignment.topCenter : Alignment.center;
        final repaintChild = SizedBox(
          width: metrics.innerWidth,
          height: metrics.innerHeight,
          child: Align(
            alignment: columnAlign,
            child: buildBlackColumnBox(),
          ),
        );

        return SingleChildScrollView(
          primary: false,
          physics: const NeverScrollableScrollPhysics(),
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: Padding(
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
                    child: repaintChild,
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _QpcV4BlackPageContentStateful extends StatefulWidget {
  const _QpcV4BlackPageContentStateful({
    required this.page,
    required this.pageLines,
    required this.baseStyle,
    required this.mapping,
    required this.forceWhiteTextOnDark,
    required this.hideUnrevealedWords,
    required this.recitationWordColors,
    required this.usePreciseRecitationOverlay,
  });
  final int page;
  final List<MushafPageLine> pageLines;
  final TextStyle baseStyle;
  final Map<int, (int sura, int ayah)>? mapping;
  final bool forceWhiteTextOnDark;
  final bool hideUnrevealedWords;
  final Map<int, Color> recitationWordColors;
  final bool usePreciseRecitationOverlay;

  @override
  State<_QpcV4BlackPageContentStateful> createState() =>
      _QpcV4BlackPageContentStatefulState();
}

class _WordToAyahMappingLoaderBlack extends StatefulWidget {
  const _WordToAyahMappingLoaderBlack({
    required this.minRange,
    required this.maxRange,
    required this.builder,
  });

  final int minRange;
  final int maxRange;
  final Widget Function(Map<int, (int sura, int ayah)>? mapping) builder;

  @override
  State<_WordToAyahMappingLoaderBlack> createState() =>
      _WordToAyahMappingLoaderBlackState();
}

class _WordToAyahMappingLoaderBlackState
    extends State<_WordToAyahMappingLoaderBlack> {
  late Future<Map<int, (int sura, int ayah)>> _mappingFuture;

  @override
  void initState() {
    super.initState();
    _mappingFuture = QuranDb.instance.getWordToAyahMapping(
      widget.minRange,
      widget.maxRange,
    );
  }

  @override
  void didUpdateWidget(covariant _WordToAyahMappingLoaderBlack oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.minRange != widget.minRange ||
        oldWidget.maxRange != widget.maxRange) {
      _mappingFuture = QuranDb.instance.getWordToAyahMapping(
        widget.minRange,
        widget.maxRange,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Map<int, (int, int)>>(
      future: _mappingFuture,
      builder: (_, snapshot) => widget.builder(snapshot.data),
    );
  }
}

class _QpcV4BlackPageContentStatefulState
    extends State<_QpcV4BlackPageContentStateful> {
  List<(int, int, int)>? _selection; // تحديد الضغط الطويل (يدوي)
  List<(int, int, int)>? _audioSelection; // تضليل الآية أثناء الاستماع
  (int, int, int)? _wordSelection;
  List<(int, int, int, Color)>? _persistentSelection;

  @override
  void initState() {
    super.initState();
    AyahAudioPlayer.instance.addListener(_syncAudioHighlight);
    AyahHighlightStore.instance.addListener(_syncPersistentHighlights);
    _syncAudioHighlight();
    _syncPersistentHighlights();
  }

  @override
  void didUpdateWidget(covariant _QpcV4BlackPageContentStateful oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncAudioHighlight();
    _syncPersistentHighlights();
  }

  @override
  void dispose() {
    AyahAudioPlayer.instance.removeListener(_syncAudioHighlight);
    AyahHighlightStore.instance.removeListener(_syncPersistentHighlights);
    super.dispose();
  }

  void _syncAudioHighlight() {
    final player = AyahAudioPlayer.instance;
    final mapping = widget.mapping;
    final s = player.currentSura;
    final a = player.currentAyah;
    if (mapping == null || s == null || a == null || !player.isActive) {
      if (_audioSelection != null || _wordSelection != null) {
        setState(() {
          _audioSelection = null;
          _wordSelection = null;
        });
      }
      return;
    }
    final ranges = getAyahRangesForPage(s, a, widget.pageLines, mapping);
    final wordRange = getAyahWordRangeForPage(
      s,
      a,
      player.currentSegmentIndex,
      player.currentSegmentToken,
      widget.pageLines,
      mapping,
    );
    if (_sameSelectionRanges(_audioSelection, ranges) &&
        _wordSelection == wordRange) {
      return;
    }
    setState(() {
      _audioSelection = ranges.isEmpty ? null : ranges;
      _wordSelection = wordRange;
    });
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
        final r =
            getAyahRangesForPage(range.sura, ayah, widget.pageLines, mapping);
        for (final e in r) {
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
    final player = AyahAudioPlayer.instance;
    final selectionForAyahHighlight =
        _selection ?? (player.showAyahHighlight ? _audioSelection : null);
    return QpcV4BlackPageView._buildContent(
      context,
      widget.page,
      widget.pageLines,
      widget.baseStyle,
      widget.mapping,
      selectionForAyahHighlight,
      (List<(int, int, int)> ranges) => setState(() => _selection = ranges),
      () => setState(() => _selection = null),
      wordSelection: _wordSelection,
      persistentSelection: _persistentSelection,
      forceWhiteTextOnDark: widget.forceWhiteTextOnDark,
      hideUnrevealedWords: widget.hideUnrevealedWords,
      recitationWordColors: widget.recitationWordColors,
      usePreciseRecitationOverlay: widget.usePreciseRecitationOverlay,
    );
  }
}

bool _sameSelectionRanges(
  List<(int, int, int)>? a,
  List<(int, int, int)>? b,
) {
  final aa = a ?? const <(int, int, int)>[];
  final bb = b ?? const <(int, int, int)>[];
  if (aa.length != bb.length) return false;
  for (int i = 0; i < aa.length; i++) {
    if (aa[i] != bb[i]) return false;
  }
  return true;
}
