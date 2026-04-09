import 'dart:math' show min;
import 'dart:ui' show BoxWidthStyle;

import 'package:flutter/material.dart';

/// قياس عرض سطر RTL واحد (استدعاءات التبرير/التضليل المشتركة بين QPC1 وQPC4).
double mushafMeasureLineWidth(String text, TextStyle style) {
  final painter = TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: TextDirection.rtl,
    maxLines: 1,
  )..layout(maxWidth: double.infinity);
  return painter.width;
}

/// [TextPainter] لسطر واحد بعد [layout] بعرض أقصى محدد (يجب أن يطابق عرض صندوق الرسم).
TextPainter mushafLaidOutRtlLinePainter(
  String text,
  TextStyle style,
  double layoutMaxWidth,
) {
  final painter = TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: TextDirection.rtl,
    maxLines: 1,
  )..layout(maxWidth: layoutMaxWidth);
  return painter;
}

/// قياس تضليل QPC1: يجب أن يطابق [_v1AyahLineTextStatic] في [quran_reader.dart]
/// (نفس [textAlign]/[textScaler]/[textWidthBasis]) وأن يُستدعى [layout] بنفس
/// [layoutMaxWidth] وارتفاع السطر كما في [mushafHighlightLineStackFixed].
TextPainter mushafLaidOutRtlLinePainterV1Highlight(
  String text,
  TextStyle style,
  double layoutMaxWidth, {
  required bool lineCentered,
}) {
  final painter = TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: TextDirection.rtl,
    textAlign: lineCentered ? TextAlign.center : TextAlign.right,
    maxLines: 1,
    textScaler: TextScaler.noScaling,
    textWidthBasis: TextWidthBasis.parent,
  )..layout(maxWidth: layoutMaxWidth);
  return painter;
}

/// نطاق عمودي ضيق يطابق السطر الأول بعد [TextPainter.layout] (أقرب لحبر الحروف من [height] الكامل).
({double top, double height}) mushafHighlightBandFromLineMetrics(
  TextPainter painter,
) {
  final ph = painter.height;
  final lines = painter.computeLineMetrics();
  if (lines.isEmpty) {
    return (top: 0.0, height: ph);
  }
  final l = lines.first;
  final top = (l.baseline - l.ascent).clamp(0.0, ph);
  var h = l.height;
  if (top + h > ph + 0.5) {
    h = (ph - top).clamp(0.5, ph);
  }
  if (h < 0.01) {
    return (top: 0.0, height: ph);
  }
  return (top: top, height: h);
}

/// حدود أفقية من مؤشري بداية/نهاية النطاق (مناسب لـ RTL/العربية أكثر من دمج الصناديق أحيانًا).
({double left, double width})? _mushafHighlightSpanFromCaretAffinities(
  TextPainter painter,
  int start,
  int end,
) {
  if (end <= start) return null;
  final oxS = painter
      .getOffsetForCaret(
        TextPosition(offset: start, affinity: TextAffinity.downstream),
        Rect.zero,
      )
      .dx;
  final oxE = painter
      .getOffsetForCaret(
        TextPosition(offset: end, affinity: TextAffinity.upstream),
        Rect.zero,
      )
      .dx;
  final l = oxS < oxE ? oxS : oxE;
  final w = (oxE - oxS).abs();
  if (w <= 0.01) return null;
  return (left: l, width: w);
}

void _mushafMergeTextBoxesIntoSpan(
  List<TextBox> boxes,
  void Function(double left, double right) emit,
) {
  double? left;
  double? right;
  for (final b in boxes) {
    if (!b.left.isFinite || !b.right.isFinite) continue;
    left = left == null || b.left < left ? b.left : left;
    right = right == null || b.right > right ? b.right : right;
  }
  if (left != null && right != null && right > left) {
    emit(left, right);
  }
}

/// مستطيل أفقي لتضليل جزء من السطر — يفترض أن [painter] ناتج عن نفس قيود [Text]
/// في [mushafHighlightLineStackFixed].
///
/// عند [preferCaretHorizontalBounds] (تبرير بـ wordSpacing) نجرّب المؤشر أولًا لأن
/// [getBoxesForSelection] قد يعطي عرضًا ناقصًا مقارنة بالرسم.
({double left, double width})? mushafWordHighlightRect({
  required TextPainter painter,
  required String text,
  required TextStyle style,
  required int startChar,
  required int endChar,
  /// عرض صندوق السطر لمحاذاة يمين RTL عند فشل الصناديق (لا يُستخدم مع التبرير).
  double? rtlRightAlignedLayoutWidth,
  bool rtlRightAlignedLayoutWidthIsMeaningful = false,
  bool preferCaretHorizontalBounds = false,
}) {
  final start = startChar.clamp(0, text.length);
  final end = endChar.clamp(0, text.length);
  if (end <= start) return null;

  ({double left, double width})? mergeSelectionBoxes() {
    double? boxLeft;
    double? boxRight;
    void takeSpan(double l, double r) {
      boxLeft = boxLeft == null || l < boxLeft! ? l : boxLeft!;
      boxRight = boxRight == null || r > boxRight! ? r : boxRight!;
    }

    _mushafMergeTextBoxesIntoSpan(
      painter.getBoxesForSelection(
        TextSelection(baseOffset: start, extentOffset: end),
        boxWidthStyle: BoxWidthStyle.max,
      ),
      takeSpan,
    );
    _mushafMergeTextBoxesIntoSpan(
      painter.getBoxesForSelection(
        TextSelection(baseOffset: end, extentOffset: start),
        boxWidthStyle: BoxWidthStyle.max,
      ),
      takeSpan,
    );
    if (boxLeft != null && boxRight != null && boxRight! > boxLeft!) {
      return (left: boxLeft!, width: boxRight! - boxLeft!);
    }
    return null;
  }

  if (preferCaretHorizontalBounds) {
    final fromCarets = _mushafHighlightSpanFromCaretAffinities(painter, start, end);
    if (fromCarets != null) {
      return fromCarets;
    }
    final fromBoxes = mergeSelectionBoxes();
    if (fromBoxes != null) {
      return fromBoxes;
    }
  } else {
    final fromBoxes = mergeSelectionBoxes();
    if (fromBoxes != null) {
      return fromBoxes;
    }
    final fromCarets = _mushafHighlightSpanFromCaretAffinities(painter, start, end);
    if (fromCarets != null) {
      return fromCarets;
    }
  }

  final s = painter.getOffsetForCaret(TextPosition(offset: start), Rect.zero);
  final e = painter.getOffsetForCaret(TextPosition(offset: end), Rect.zero);
  var l = s.dx < e.dx ? s.dx : e.dx;
  var w = (e.dx - s.dx).abs();
  if (w <= 0.01 && rtlRightAlignedLayoutWidthIsMeaningful) {
    final pw = rtlRightAlignedLayoutWidth;
    // سطر RTL محاذٍ لليمين: الفهرس 0 = بداية القراءة = يمين الصندوق.
    if (pw != null && pw > 0.01) {
      final wPrefix = mushafMeasureLineWidth(text.substring(0, start), style);
      final wToken = mushafMeasureLineWidth(text.substring(start, end), style);
      l = pw - wPrefix - wToken;
      w = wToken;
    }
  }
  if (w <= 0.01) {
    final prefixW = mushafMeasureLineWidth(text.substring(0, start), style);
    final tokenW = mushafMeasureLineWidth(text.substring(start, end), style);
    l = prefixW;
    w = tokenW;
  }
  if (w <= 0.01) return null;
  return (left: l, width: w);
}

/// نفس [mushafWordHighlightRect] مع ضمان إرجاع عرض عبر المؤشر إن لزم.
({double left, double width}) mushafRangeHorizontalRectWithFallback({
  required TextPainter painter,
  required String text,
  required TextStyle style,
  required int startChar,
  required int endChar,
  double? rtlRightAlignedLayoutWidth,
  bool rtlRightAlignedLayoutWidthIsMeaningful = false,
  bool preferCaretHorizontalBounds = false,
}) {
  final box = mushafWordHighlightRect(
    painter: painter,
    text: text,
    style: style,
    startChar: startChar,
    endChar: endChar,
    rtlRightAlignedLayoutWidth: rtlRightAlignedLayoutWidth,
    rtlRightAlignedLayoutWidthIsMeaningful:
        rtlRightAlignedLayoutWidthIsMeaningful,
    preferCaretHorizontalBounds: preferCaretHorizontalBounds,
  );
  if (box != null && box.width > 0.01) {
    return (left: box.left, width: box.width);
  }
  final s0 = startChar.clamp(0, text.length);
  final e0 = endChar.clamp(0, text.length);
  final s = painter.getOffsetForCaret(TextPosition(offset: s0), Rect.zero);
  final e = painter.getOffsetForCaret(TextPosition(offset: e0), Rect.zero);
  final left = s.dx < e.dx ? s.dx : e.dx;
  final width = (e.dx - s.dx).abs();
  return (left: left, width: width);
}

/// طبقة تضليل بعرض/ارتفاع ثابتين **بدون** [LayoutBuilder] ولا [Transform.scale].
/// يُستخدم في QPC1 حتى لا تنزاح الأسطر للأعلى عند الضغط المطوّل عندما تكون خانة
/// السطر أعلى من ارتفاع السطر (المسار السابق كان يطبّق scale فيُغيّر الموضع البصري).
///
/// النص يُرسم داخل [Positioned.fill] بنفس [lineWidth]/[lineHeight] المستعملين في
/// [mushafLaidOutRtlLinePainter] حتى تطابق إحداثيات [Positioned] للتضليل مع الحروف
/// (محاذاة [Stack] فقط كانت تضع [Text] بعرضه الطبيعي فيُنزح التضليل قليلاً).
Widget mushafHighlightLineStackFixed({
  required double lineWidth,
  required double lineHeight,
  required Widget lineText,
  required List<Widget> overlayWidgets,
}) {
  return SizedBox(
    width: lineWidth,
    height: lineHeight,
    child: Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned.fill(child: lineText),
        ...overlayWidgets,
      ],
    ),
  );
}

/// تضليل آية فوق سطر واحد: محاذاة من **الأعلى** مثل [Text] العادي داخل خانة المصحف،
/// وتجنّب [FittedBox] عندما يكفي المكان (يقلّل قفزة بصرية عند ظهور التحديد).
Widget mushafHighlightFittedLineStack({
  required bool lineCentered,
  required double lineWidth,
  required double lineHeight,
  required Widget lineText,
  required List<Widget> overlayWidgets,
}) {
  final align =
      lineCentered ? Alignment.topCenter : Alignment.topRight;
  final core = SizedBox(
    width: lineWidth,
    height: lineHeight,
    child: Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned.fill(child: lineText),
        ...overlayWidgets,
      ],
    ),
  );
  return LayoutBuilder(
    builder: (context, constraints) {
      final maxW = constraints.maxWidth;
      final maxH = constraints.maxHeight;
      var scale = 1.0;
      if (maxW.isFinite && maxW > 0 && lineWidth > maxW) {
        scale = min(scale, maxW / lineWidth);
      }
      if (maxH.isFinite && maxH > 0 && lineHeight > maxH) {
        scale = min(scale, maxH / lineHeight);
      }
      if (scale >= 0.999) {
        return Align(alignment: align, child: core);
      }
      return Align(
        alignment: align,
        child: Transform.scale(
          scale: scale,
          alignment: align,
          filterQuality: FilterQuality.medium,
          child: core,
        ),
      );
    },
  );
}

/// مستطيل تظليل لوني مسطح فوق السطر.
///
/// [bandTop] / [bandHeight] اختياريان: عند تعيينهما يُحصر الشريط بشريحة السطر من
/// [mushafHighlightBandFromLineMetrics] بدل ارتفاع الصندوق بالكامل.
Widget mushafFlatHighlightBar({
  required double left,
  required double width,
  required double lineHeight,
  double? bandTop,
  double? bandHeight,
  required Color color,
  required double alpha,
}) {
  final top = bandTop ?? 0;
  final height = bandHeight ?? lineHeight;
  return Positioned(
    left: left,
    top: top,
    width: width,
    height: height,
    child: Container(
      decoration: BoxDecoration(
        color: color.withValues(alpha: alpha),
        borderRadius: BorderRadius.circular(2),
      ),
    ),
  );
}
