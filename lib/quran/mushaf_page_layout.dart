import 'package:flutter/material.dart';

import 'package:quran_app/quran/compact_line_spacing_scope.dart';

/// لون ورق المصحف الافتراضي (بيج فاتح) — يُطابق الافتراضي في عارض الصفحة.
const Color kMushafPaperBackgroundFallback = Color(0xFFFFF8EB);

/// يمرّر لون خلفية صفحة المصحف للرسم الموحّد أثناء التحميل وخلف [RepaintBoundary]
/// حتى لا تظهر ومضة بلون مختلف عن الورق.
class MushafPaperBackgroundScope extends InheritedWidget {
  const MushafPaperBackgroundScope({
    super.key,
    required this.color,
    required super.child,
  });

  final Color color;

  static Color of(BuildContext context) {
    return context
            .dependOnInheritedWidgetOfExactType<MushafPaperBackgroundScope>()
            ?.color ??
        kMushafPaperBackgroundFallback;
  }

  @override
  bool updateShouldNotify(MushafPaperBackgroundScope oldWidget) =>
      color != oldWidget.color;
}

/// عدد أسطر النص في صفحة المصحف المدني.
const int kMushafLineSlotCount = 15;

/// هامش يمين/يسار ثابت: **2%** من عرض المنطقة.
const double kMushafSideMarginFraction = 0.02;

/// قياسات المنطقة الداخلية بعد هوامش الصفحة (بين الشريط العلوي ورقم الصفحة
/// عند استخدام [QuranReader] مع [buildTopBarForPage]).
class MushafInnerLayoutMetrics {
  const MushafInnerLayoutMetrics({
    required this.maxWidth,
    required this.maxHeight,
    required this.leftMargin,
    required this.rightMargin,
    required this.topMargin,
    required this.bottomMargin,
    required this.innerWidth,
    required this.innerHeight,
    required this.slotHeight,
  });

  final double maxWidth;
  final double maxHeight;
  final double leftMargin;
  final double rightMargin;
  final double topMargin;
  final double bottomMargin;

  /// العرض بعد طرح الهوامش الجانبية.
  final double innerWidth;

  /// الارتفاع بعد طرح الهوامش العلوية/السفلية.
  final double innerHeight;

  /// `innerHeight / 15` — يزيد في الشاشات الطويلة وينقص في القصيرة.
  final double slotHeight;
}

/// مجموع نسب الهامش العلوي+السفلي في [computeMushafInnerLayoutMetrics] — يُستخدم
/// في التمرير المتصل لضبط ارتفاع عنصر القائمة ليطابق مساحة النص الفعلية.
double mushafVerticalMarginFractionSum({required bool isCompact}) {
  final vFrac =
      isCompact ? kCompactMarginFraction : kMushafSideMarginFraction;
  final bottomFrac =
      vFrac * (isCompact ? kCompactBottomMarginScale : 1.0);
  return vFrac + bottomFrac;
}

/// عند التفعيل: يُلغى الهامش العمودي داخل الصفحة حتى لا يتراكب هامش سفلي + علوي
/// بين صفحتين متجاورتين في التمرير المتصل (فيصبح الفصل مثل تباعد السطور فقط).
class SeamlessLongScrollScope extends InheritedWidget {
  const SeamlessLongScrollScope({
    super.key,
    required this.active,
    required super.child,
  });

  final bool active;

  static bool isActive(BuildContext context) {
    return context
            .dependOnInheritedWidgetOfExactType<SeamlessLongScrollScope>()
            ?.active ??
        false;
  }

  @override
  bool updateShouldNotify(SeamlessLongScrollScope old) =>
      active != old.active;
}

/// هوامش علوية/سفلية بنفس نسبة الجوانب في الوضع العادي؛ في [compact] الهامش
/// السفلي يُخفّض (كما في [kCompactBottomMarginScale]).
MushafInnerLayoutMetrics computeMushafInnerLayoutMetrics({
  required double maxWidth,
  required double maxHeight,
  required bool isCompact,
  bool omitVerticalMargins = false,
}) {
  final vFrac =
      isCompact ? kCompactMarginFraction : kMushafSideMarginFraction;
  final bottomFrac =
      vFrac * (isCompact ? kCompactBottomMarginScale : 1.0);
  final leftMargin = maxWidth * kMushafSideMarginFraction;
  final rightMargin = maxWidth * kMushafSideMarginFraction;
  final double topMargin;
  final double bottomMargin;
  if (omitVerticalMargins) {
    topMargin = 0;
    bottomMargin = 0;
  } else {
    topMargin = maxHeight * vFrac;
    bottomMargin = maxHeight * bottomFrac;
  }
  final innerWidth = maxWidth - leftMargin - rightMargin;
  final innerHeight = maxHeight - topMargin - bottomMargin;
  final slotHeight =
      innerHeight > 0 ? innerHeight / kMushafLineSlotCount : 0.0;
  return MushafInnerLayoutMetrics(
    maxWidth: maxWidth,
    maxHeight: maxHeight,
    leftMargin: leftMargin,
    rightMargin: rightMargin,
    topMargin: topMargin,
    bottomMargin: bottomMargin,
    innerWidth: innerWidth.clamp(0.0, double.infinity),
    innerHeight: innerHeight.clamp(0.0, double.infinity),
    slotHeight: slotHeight,
  );
}

/// أدنى ارتفاع خانة سطر يُعتمد عند ضغط عمودي: ارتفاع سطر آية تقريبي + هامش سفلي.
double mushafMinSlotHeightForAyahStyle({
  required TextStyle ayahStyle,
  required double linePaddingBottom,
}) {
  final p = TextPainter(
    text: TextSpan(text: 'نص', style: ayahStyle),
    textDirection: TextDirection.rtl,
    maxLines: 1,
  )..layout(maxWidth: double.infinity);
  return p.height + linePaddingBottom;
}
