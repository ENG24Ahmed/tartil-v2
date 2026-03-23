import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:quran_app/audio/ayah_audio_player.dart';
import 'package:quran_app/quran/font_loader.dart';
import 'package:quran_app/quran/models/mushaf_line.dart';
import 'package:quran_app/quran/page_cache.dart';
import 'package:quran_app/quran/quran_db.dart';
import 'package:quran_app/quran/compact_line_spacing_scope.dart'
    show
        CompactLineSpacingScope,
        getCompactFontScaleFactor,
        kCompactBottomMarginScale,
        kCompactMarginFraction;
import 'package:quran_app/quran/renderers/qpc_v4_renderer.dart'
    show
        AyahHighlightStore,
        DelayedLongPressDetector,
        QpcV4Renderer,
        getQpcContentDimensions,
        getJustifiedLineStyle,
        getQpcLineHeights,
        getAyahRangesForPage,
        getAyahWordRangeForPage,
        kQpcPageMarginFraction,
        onQpcPageLongPress;

/// نسبة ارتفاع إطار اسم السورة إلى عرضه (من viewBox sura_name.svg: 1621.5×171).
const double _surahFrameAspect = 171 / 1621.5;
const String _surahNameFontFamily = 'SurahNameV4';
const double _basmallahRaiseDy = -2.0;
const String _basmallahFontFamily = 'KFGQPCHAFSUthmanicScript';
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

Future<List<MushafPageLine>> _loadFontThenLoadPageBlack(int page) async {
  await loadQcf4Font(page);
  return QpcV4Renderer.instance.loadPage(page);
}

class QpcV4BlackPageView extends StatelessWidget {
  const QpcV4BlackPageView({
    super.key,
    required this.page,
    this.forceWhiteTextOnDark = false,
  });
  final int page;
  final bool forceWhiteTextOnDark;

  @override
  Widget build(BuildContext context) {
    const baseStyle = TextStyle(
      fontSize: 23,
      height: 1.52,
      letterSpacing: 0,
      wordSpacing: 0,
      fontFeatures: [FontFeature.disable('kern')],
    );

    final cached = PageCache.instance.get('qpc4', page);
    if (cached != null && cached.isNotEmpty) {
      return _buildPageWithMapping(
        context,
        page,
        cached,
        baseStyle,
        forceWhiteTextOnDark: forceWhiteTextOnDark,
      );
    }

    return FutureBuilder<List<MushafPageLine>>(
      future: _loadFontThenLoadPageBlack(page),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const SizedBox.expand();
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
        );
      },
    );
  }

  static TextStyle _lineStyleForBlack(
      MushafPageLine line, TextStyle baseStyle) {
    return baseStyle.copyWith(fontFamily: line.fontFamily);
  }

  static Widget _buildPageWithMapping(BuildContext context, int page,
      List<MushafPageLine> pageLines, TextStyle baseStyle,
      {bool forceWhiteTextOnDark = false}) {
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
      );
    }
    return FutureBuilder<Map<int, (int, int)>>(
      future: QuranDb.instance.getWordToAyahMapping(minR, maxR),
      builder: (_, mapSnap) {
        return _QpcV4BlackPageContentStateful(
          page: page,
          pageLines: pageLines,
          baseStyle: baseStyle,
          mapping: mapSnap.data,
          forceWhiteTextOnDark: forceWhiteTextOnDark,
        );
      },
    );
  }

  static double _measureLineWidth(String text, TextStyle style) {
    final p = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.rtl,
      maxLines: 1,
    )..layout(maxWidth: double.infinity);
    return p.width;
  }

  static ({double left, double width})? _wordHighlightRect({
    required TextPainter painter,
    required String text,
    required TextStyle style,
    required int startChar,
    required int endChar,
  }) {
    final start = startChar.clamp(0, text.length);
    final end = endChar.clamp(0, text.length);
    if (end <= start) return null;

    final boxes = painter.getBoxesForSelection(
      TextSelection(baseOffset: start, extentOffset: end),
    );
    double? left;
    double? right;
    for (final b in boxes) {
      if (!b.left.isFinite || !b.right.isFinite) continue;
      left = left == null || b.left < left ? b.left : left;
      right = right == null || b.right > right ? b.right : right;
    }
    if (left != null && right != null && right > left) {
      return (left: left, width: right - left);
    }

    final s = painter.getOffsetForCaret(TextPosition(offset: start), Rect.zero);
    final e = painter.getOffsetForCaret(TextPosition(offset: end), Rect.zero);
    var l = s.dx < e.dx ? s.dx : e.dx;
    var w = (e.dx - s.dx).abs();
    if (w <= 0.01) {
      final prefixW = _measureLineWidth(text.substring(0, start), style);
      final tokenW = _measureLineWidth(text.substring(start, end), style);
      l = prefixW;
      w = tokenW;
    }
    if (w <= 0.01) return null;
    return (left: l, width: w);
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
        final marginFraction =
            isCompact ? kCompactMarginFraction : kQpcPageMarginFraction;
        final leftMargin = availableWidth * marginFraction;
        final rightMargin = availableWidth * marginFraction;
        final topMargin = availableHeight * marginFraction;
        final bottomMargin = availableHeight *
            (isCompact
                ? marginFraction * kCompactBottomMarginScale
                : marginFraction);

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
        final availableContentW = availableWidth - leftMargin - rightMargin;
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

        var (baseContentW, contentH) = getQpcContentDimensions(
          pageLines,
          effectiveBaseStyle,
          linePaddingBottom: linePad,
        );
        final lineHeights = getQpcLineHeights(
          pageLines,
          effectiveBaseStyle,
          linePaddingBottom: linePad,
        );

        final contentW = isCompact ? availableContentW : baseContentW;

        final lineHeightsBlack = List<double>.from(lineHeights);
        for (var i = 0; i < pageLines.length; i++) {
          if (pageLines[i].lineType == 'surah_name') {
            lineHeightsBlack[i] = contentW * _surahFrameAspect + linePad;
          }
        }
        contentH = lineHeightsBlack.fold(0.0, (a, b) => a + b);

        final pageLinesWidgets = pageLines.asMap().entries.map((entry) {
          final lineIndex = entry.key;
          final line = entry.value;
          Widget lineWidget;
          if (line.lineType == 'surah_name') {
            final frameHeight = contentW * _surahFrameAspect;
            lineWidget = Padding(
              padding: EdgeInsets.only(bottom: linePad),
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
                            line.lineText,
                            textDirection: TextDirection.rtl,
                            textAlign: TextAlign.center,
                            maxLines: 1,
                            overflow: TextOverflow.visible,
                            style: effectiveBaseStyle.copyWith(
                              fontFamily: _surahNameFontFamily,
                              fontSize: 20 * (isCompact ? fontScale : 1.0),
                              color: glyphColor,
                            ),
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
              padding: EdgeInsets.only(bottom: linePad),
              child: Align(
                alignment: Alignment.center,
                child: SizedBox(
                  width: double.infinity,
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.center,
                    child: Transform.translate(
                      offset: Offset(0, _basmallahRaiseDy * fontScale),
                      child: Text(
                        line.lineText,
                        textDirection: TextDirection.rtl,
                        textAlign: TextAlign.center,
                        softWrap: false,
                        maxLines: 1,
                        overflow: TextOverflow.visible,
                        style: TextStyle(
                          fontFamily: _basmallahFontFamily,
                          fontSize: 22 * (isCompact ? fontScale : 1.0),
                          height: 1.15,
                          fontWeight: FontWeight.w600,
                          color: glyphColor,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
          } else {
            Widget lineContent;
            final lineStyle = getJustifiedLineStyle(
              line,
              effectiveBaseStyle.copyWith(fontFamily: line.fontFamily),
              contentW,
            );
            final segments = line.ayahSegments;
            final hasMarkerInfo = segments != null &&
                segments.isNotEmpty &&
                segments.any((s) => s.isMarker);

            if (hasMarkerInfo) {
              // لون علامة الآية كي تظهر ملونة كما في quran_test (الخط قد لا يكون لونياً).
              const Color ayahMarkerColor = Color(0xFFB71C1C); // أحمر غامق
              final overlaySpans = <InlineSpan>[];
              for (final seg in segments) {
                if (seg.text.isEmpty) continue;
                if (seg.isMarker) {
                  overlaySpans.add(TextSpan(
                    text: seg.text,
                    style: lineStyle.copyWith(color: ayahMarkerColor),
                  ));
                } else {
                  overlaySpans.add(
                    TextSpan(
                      text: seg.text,
                      style: lineStyle.copyWith(color: Colors.transparent),
                    ),
                  );
                }
              }
              lineContent = Stack(
                children: [
                  ColorFiltered(
                    colorFilter: ColorFilter.mode(glyphColor, BlendMode.srcIn),
                    child: Text(
                      line.lineText,
                      textDirection: TextDirection.rtl,
                      textAlign:
                          line.isCentered ? TextAlign.center : TextAlign.right,
                      softWrap: false,
                      maxLines: 1,
                      overflow: TextOverflow.visible,
                      style: lineStyle,
                    ),
                  ),
                  Transform.translate(
                    offset: Offset(0, isCompact ? 6 : 3),
                    child: RichText(
                      textDirection: TextDirection.rtl,
                      textAlign:
                          line.isCentered ? TextAlign.center : TextAlign.right,
                      maxLines: 1,
                      overflow: TextOverflow.visible,
                      text: TextSpan(style: lineStyle, children: overlaySpans),
                    ),
                  ),
                ],
              );
            } else {
              lineContent = Text(
                line.lineText,
                textDirection: TextDirection.rtl,
                textAlign: line.isCentered ? TextAlign.center : TextAlign.right,
                maxLines: 1,
                overflow: TextOverflow.visible,
                style: lineStyle,
              );
              lineContent = ColorFiltered(
                colorFilter: ColorFilter.mode(glyphColor, BlendMode.srcIn),
                child: lineContent,
              );
            }

            lineWidget = Padding(
              padding: EdgeInsets.only(bottom: linePad),
              child: Align(
                alignment:
                    line.isCentered ? Alignment.center : Alignment.centerRight,
                child: SizedBox(
                  width: double.infinity,
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: line.isCentered
                        ? Alignment.center
                        : Alignment.centerRight,
                    child: lineContent,
                  ),
                ),
              ),
            );
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
                lineSelection.$2 >= 0 &&
                lineSelection.$3 > lineSelection.$2) {
              final lineWidth = _measureLineWidth(line.lineText, lineStyle);
              final painter = TextPainter(
                text: TextSpan(text: line.lineText, style: lineStyle),
                textDirection: TextDirection.rtl,
                maxLines: 1,
              )..layout(maxWidth: lineWidth);
              final startOffset = painter.getOffsetForCaret(
                  TextPosition(
                      offset: lineSelection.$2.clamp(0, line.lineText.length)),
                  Rect.zero);
              final endOffset = painter.getOffsetForCaret(
                  TextPosition(
                      offset: lineSelection.$3.clamp(0, line.lineText.length)),
                  Rect.zero);
              final left =
                  startOffset.dx < endOffset.dx ? startOffset.dx : endOffset.dx;
              final width = (endOffset.dx - startOffset.dx).abs();
              double? wordLeft;
              double? wordWidth;
              if (lineWordSelection != null &&
                  lineWordSelection.$2 >= 0 &&
                  lineWordSelection.$3 > lineWordSelection.$2) {
                final rect = _wordHighlightRect(
                  painter: painter,
                  text: line.lineText,
                  style: lineStyle,
                  startChar: lineWordSelection.$2,
                  endChar: lineWordSelection.$3,
                );
                if (rect != null) {
                  wordLeft = rect.left;
                  wordWidth = rect.width;
                }
              }
              return Padding(
                padding: EdgeInsets.only(bottom: linePad),
                child: Align(
                  alignment: line.isCentered
                      ? Alignment.center
                      : Alignment.centerRight,
                  child: SizedBox(
                    width: double.infinity,
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: line.isCentered
                          ? Alignment.center
                          : Alignment.centerRight,
                      child: SizedBox(
                        width: lineWidth,
                        height: painter.height,
                        child: Stack(
                          alignment: Alignment.centerRight,
                          children: [
                            lineContent,
                            Positioned(
                              left: left,
                              top: 0,
                              width: width,
                              height: painter.height,
                              child: Container(
                                decoration: BoxDecoration(
                                  color: ayahSelectionColor.withValues(
                                      alpha: ayahSelectionAlpha),
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
                                    color: wordSelectionColor.withValues(
                                        alpha: wordSelectionAlpha),
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
            if (lineSelection == null && linePersistentSelections.isNotEmpty) {
              final lineWidth = _measureLineWidth(line.lineText, lineStyle);
              final painter = TextPainter(
                text: TextSpan(text: line.lineText, style: lineStyle),
                textDirection: TextDirection.rtl,
                maxLines: 1,
              )..layout(maxWidth: lineWidth);
              final persistentRects =
                  <({double left, double width, Color color})>[];
              for (final p in linePersistentSelections) {
                final rect = _wordHighlightRect(
                  painter: painter,
                  text: line.lineText,
                  style: lineStyle,
                  startChar: p.$2,
                  endChar: p.$3,
                );
                if (rect != null) {
                  persistentRects
                      .add((left: rect.left, width: rect.width, color: p.$4));
                }
              }
              final mergedPersistentRects =
                  _mergePersistentRectsByColorBlack(persistentRects);
              if (mergedPersistentRects.isEmpty) return lineWidget;
              double? wordLeft;
              double? wordWidth;
              if (lineWordSelection != null &&
                  lineWordSelection.$2 >= 0 &&
                  lineWordSelection.$3 > lineWordSelection.$2) {
                final rect = _wordHighlightRect(
                  painter: painter,
                  text: line.lineText,
                  style: lineStyle,
                  startChar: lineWordSelection.$2,
                  endChar: lineWordSelection.$3,
                );
                if (rect != null) {
                  wordLeft = rect.left;
                  wordWidth = rect.width;
                }
              }
              return Padding(
                padding: EdgeInsets.only(bottom: linePad),
                child: Align(
                  alignment: line.isCentered
                      ? Alignment.center
                      : Alignment.centerRight,
                  child: SizedBox(
                    width: double.infinity,
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: line.isCentered
                          ? Alignment.center
                          : Alignment.centerRight,
                      child: SizedBox(
                        width: lineWidth,
                        height: painter.height,
                        child: Stack(
                          alignment: Alignment.centerRight,
                          children: [
                            lineContent,
                            ...mergedPersistentRects.map((rect) =>
                                _buildPersistentHighlightSegmentBlack(
                                    rect, painter.height)),
                            if (wordLeft != null && wordWidth != null)
                              Positioned(
                                left: wordLeft,
                                top: 0,
                                width: wordWidth,
                                height: painter.height,
                                child: Container(
                                  decoration: BoxDecoration(
                                    color: wordSelectionColor.withValues(
                                        alpha: wordSelectionAlpha),
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
            if (lineWordSelection != null &&
                lineWordSelection.$2 >= 0 &&
                lineWordSelection.$3 > lineWordSelection.$2 &&
                line.lineType == 'ayah') {
              final lineWidth = _measureLineWidth(line.lineText, lineStyle);
              final painter = TextPainter(
                text: TextSpan(text: line.lineText, style: lineStyle),
                textDirection: TextDirection.rtl,
                maxLines: 1,
              )..layout(maxWidth: lineWidth);
              final rect = _wordHighlightRect(
                painter: painter,
                text: line.lineText,
                style: lineStyle,
                startChar: lineWordSelection.$2,
                endChar: lineWordSelection.$3,
              );
              if (rect == null) return lineWidget;
              final wordLeft = rect.left;
              final wordWidth = rect.width;
              return Padding(
                padding: EdgeInsets.only(bottom: linePad),
                child: Align(
                  alignment: line.isCentered
                      ? Alignment.center
                      : Alignment.centerRight,
                  child: SizedBox(
                    width: double.infinity,
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: line.isCentered
                          ? Alignment.center
                          : Alignment.centerRight,
                      child: SizedBox(
                        width: lineWidth,
                        height: painter.height,
                        child: Stack(
                          alignment: Alignment.centerRight,
                          children: [
                            lineContent,
                            Positioned(
                              left: wordLeft,
                              top: 0,
                              width: wordWidth,
                              height: painter.height,
                              child: Container(
                                decoration: BoxDecoration(
                                  color: ayahSelectionColor.withValues(
                                      alpha: ayahSelectionAlpha),
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
            return lineWidget;
          }
          return lineWidget;
        }).toList();

        // المسافة العمودية المتاحة بين الشريط العلوي ورقم الصفحة.
        final fullH = availableHeight - topMargin - bottomMargin;
        const int slotsCount = 15;
        final slotHeight = fullH / slotsCount;

        // نأخذ أول 15 سطراً فقط، والباقي يُهمل إن وُجد.
        final displayLines = pageLines.length >= slotsCount
            ? pageLines.sublist(0, slotsCount)
            : pageLines;

        // نبني 15 خانة متساوية الارتفاع، ونضع في كل خانة سطراً أو خانة فارغة.
        final slots = <Widget>[];
        for (int i = 0; i < slotsCount; i++) {
          Widget lineChild = const SizedBox.shrink();
          // في الصفحتين 1 و 2 نترك أول 3 خانات فارغة، فيبدأ أول سطر من الخانة الرابعة.
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
            (int, int, int)? lineWordSelection;
            if (wordSelection != null && wordSelection.$1 == srcIndex) {
              lineWordSelection = wordSelection;
            }

            // نعيد استخدام منطق بناء السطر كما في pageLinesWidgets.
            lineChild = pageLinesWidgets[srcIndex];

            // في حال كان هناك تحديد لآية في هذا السطر، نستخدم مسار overlay الخاص به.
            if (lineSelection != null &&
                lineSelection.$2 >= 0 &&
                lineSelection.$3 > lineSelection.$2) {
              final lineStyle = getJustifiedLineStyle(
                line,
                effectiveBaseStyle.copyWith(fontFamily: line.fontFamily),
                contentW,
              );
              final lineWidth = _measureLineWidth(line.lineText, lineStyle);
              final painter = TextPainter(
                text: TextSpan(text: line.lineText, style: lineStyle),
                textDirection: TextDirection.rtl,
                maxLines: 1,
              )..layout(maxWidth: lineWidth);
              final startOffset = painter.getOffsetForCaret(
                  TextPosition(
                      offset: lineSelection.$2.clamp(0, line.lineText.length)),
                  Rect.zero);
              final endOffset = painter.getOffsetForCaret(
                  TextPosition(
                      offset: lineSelection.$3.clamp(0, line.lineText.length)),
                  Rect.zero);
              final left =
                  startOffset.dx < endOffset.dx ? startOffset.dx : endOffset.dx;
              final width = (endOffset.dx - startOffset.dx).abs();
              double? wordLeft;
              double? wordWidth;
              if (lineWordSelection != null &&
                  lineWordSelection.$2 >= 0 &&
                  lineWordSelection.$3 > lineWordSelection.$2) {
                final wStart = painter.getOffsetForCaret(
                    TextPosition(
                        offset: lineWordSelection.$2
                            .clamp(0, line.lineText.length)),
                    Rect.zero);
                final wEnd = painter.getOffsetForCaret(
                    TextPosition(
                        offset: lineWordSelection.$3
                            .clamp(0, line.lineText.length)),
                    Rect.zero);
                wordLeft = wStart.dx < wEnd.dx ? wStart.dx : wEnd.dx;
                wordWidth = (wEnd.dx - wStart.dx).abs();
              }

              final hasMarkerInfo = line.ayahSegments != null &&
                  line.ayahSegments!.isNotEmpty &&
                  line.ayahSegments!.any((s) => s.isMarker);
              Widget lineContent;
              if (hasMarkerInfo) {
                const Color ayahMarkerColor = Color(0xFFB71C1C);
                final overlaySpans = <InlineSpan>[];
                for (final seg in line.ayahSegments!) {
                  if (seg.text.isEmpty) continue;
                  if (seg.isMarker) {
                    overlaySpans.add(TextSpan(
                      text: seg.text,
                      style: lineStyle.copyWith(color: ayahMarkerColor),
                    ));
                  } else {
                    overlaySpans.add(TextSpan(
                      text: seg.text,
                      style: lineStyle.copyWith(color: Colors.transparent),
                    ));
                  }
                }
                lineContent = Stack(
                  children: [
                    ColorFiltered(
                      colorFilter:
                          ColorFilter.mode(glyphColor, BlendMode.srcIn),
                      child: Text(
                        line.lineText,
                        textDirection: TextDirection.rtl,
                        textAlign: line.isCentered
                            ? TextAlign.center
                            : TextAlign.right,
                        softWrap: false,
                        maxLines: 1,
                        overflow: TextOverflow.visible,
                        style: lineStyle,
                      ),
                    ),
                    Transform.translate(
                      offset: Offset(0, isCompact ? 6 : 3),
                      child: RichText(
                        textDirection: TextDirection.rtl,
                        textAlign: line.isCentered
                            ? TextAlign.center
                            : TextAlign.right,
                        maxLines: 1,
                        overflow: TextOverflow.visible,
                        text:
                            TextSpan(style: lineStyle, children: overlaySpans),
                      ),
                    ),
                  ],
                );
              } else {
                lineContent = Text(
                  line.lineText,
                  textDirection: TextDirection.rtl,
                  textAlign:
                      line.isCentered ? TextAlign.center : TextAlign.right,
                  maxLines: 1,
                  overflow: TextOverflow.visible,
                  style: lineStyle,
                );
                lineContent = ColorFiltered(
                  colorFilter: ColorFilter.mode(glyphColor, BlendMode.srcIn),
                  child: lineContent,
                );
              }

              lineChild = Padding(
                padding: EdgeInsets.only(bottom: linePad),
                child: Align(
                  alignment: line.isCentered
                      ? Alignment.center
                      : Alignment.centerRight,
                  child: SizedBox(
                    width: double.infinity,
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: line.isCentered
                          ? Alignment.center
                          : Alignment.centerRight,
                      child: SizedBox(
                        width: lineWidth,
                        height: painter.height,
                        child: Stack(
                          alignment: Alignment.centerRight,
                          children: [
                            lineContent,
                            Positioned(
                              left: left,
                              top: 0,
                              width: width,
                              height: painter.height,
                              child: Container(
                                decoration: BoxDecoration(
                                  color: ayahSelectionColor.withValues(
                                      alpha: ayahSelectionAlpha),
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
                                    color: wordSelectionColor.withValues(
                                        alpha: wordSelectionAlpha),
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

        // في العرض الأفقي (compact): نستخدم العرض الكامل من الأخضر للأحمر.
        final availableW = availableWidth - leftMargin - rightMargin;
        final pageWidth =
            isCompact || (page == 1 || page == 2) ? availableW : contentW;

        return SingleChildScrollView(
          primary: false,
          physics: const NeverScrollableScrollPhysics(),
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: Padding(
              padding: EdgeInsets.only(
                left: leftMargin,
                right: rightMargin,
                top: topMargin,
                bottom: bottomMargin,
              ),
              child: Align(
                alignment: Alignment.centerLeft,
                child: RepaintBoundary(
                  child: SizedBox(
                    width: pageWidth,
                    height: fullH,
                    child: mapping != null
                        ? DelayedLongPressDetector(
                            duration: const Duration(milliseconds: 400),
                            onTrigger: (Offset pos) {
                              final adjustedPos = (page == 1 || page == 2)
                                  ? pos.translate(0, -3 * slotHeight)
                                  : pos;
                              onQpcPageLongPress(
                                context,
                                adjustedPos,
                                contentW,
                                fullH,
                                lineHeights15,
                                displayLines,
                                effectiveBaseStyle,
                                mapping,
                                _lineStyleForBlack,
                                onSelectLine: onSelectLine,
                                onClearSelection: onClearSelection,
                              );
                            },
                            child: column15,
                          )
                        : column15,
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
  });
  final int page;
  final List<MushafPageLine> pageLines;
  final TextStyle baseStyle;
  final Map<int, (int sura, int ayah)>? mapping;
  final bool forceWhiteTextOnDark;

  @override
  State<_QpcV4BlackPageContentStateful> createState() =>
      _QpcV4BlackPageContentStatefulState();
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
