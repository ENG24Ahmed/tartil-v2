import 'package:flutter/material.dart';

/// عند true: مسافة أصغر بين الأسطر (للعرض الأفقي فقط).
const double kCompactLinePaddingBottom = 1.0;
const double kNormalLinePaddingBottom = 7.0;

/// في العرض الأفقي: هوامش 2% على أطراف الأسطر.
const double kCompactMarginFraction = 0.02;

/// الهامش السفلي في العرض الأفقي مخفّض لرفع الخط البرتقالي.
const double kCompactBottomMarginScale = 0.5;

/// تكبير الغليفات في العرض الأفقي — حساب تلقائي يتكيف مع عرض الهاتف.
/// القاعدة: 2.0 لعرض 360px، يتناسب مع الشاشات الأخرى.
double getCompactFontScaleFactor(BuildContext context) {
  final width = MediaQuery.sizeOf(context).width;
  const refWidth = 360.0;
  const baseScale = 2.0;
  final scale = baseScale * (width / refWidth);
  return scale.clamp(1.5, 2.5);
}

class CompactLineSpacingScope extends InheritedWidget {
  const CompactLineSpacingScope({
    super.key,
    required this.compact,
    required super.child,
  });

  final bool compact;

  static double linePaddingOf(BuildContext context) {
    final scope =
        context.dependOnInheritedWidgetOfExactType<CompactLineSpacingScope>();
    return (scope?.compact ?? false)
        ? kCompactLinePaddingBottom
        : kNormalLinePaddingBottom;
  }

  static bool isCompact(BuildContext context) {
    final scope =
        context.dependOnInheritedWidgetOfExactType<CompactLineSpacingScope>();
    return scope?.compact ?? false;
  }

  @override
  bool updateShouldNotify(CompactLineSpacingScope old) =>
      compact != old.compact;
}
