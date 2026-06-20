import 'package:flutter/material.dart';

/// يطابق تدوير القائمة الرئيسية في الأفقي أو وضع القراءة الأفقية الدوّارة.
Widget wrapQuranMenuFamilySheetOverlay(
  BuildContext sheetContext,
  Widget child, {
  required bool horizontallyRotatedReading,
  Alignment overlayAlignment = Alignment.center,
  /// يملأ [Material] بالكامل قبل التدوير — يمنع الفراغ فوق الصف الأول بعد 90°.
  bool fillSidePanel = false,
}) {
  final rotate = horizontallyRotatedReading ||
      MediaQuery.orientationOf(sheetContext) == Orientation.landscape;
  if (!rotate) return child;
  if (fillSidePanel) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final panelW = constraints.maxWidth;
        final panelH = constraints.maxHeight;
        if (!panelW.isFinite ||
            !panelH.isFinite ||
            panelW <= 0 ||
            panelH <= 0) {
          return child;
        }
        // قبل التدوير: العرض = ارتفاع اللوحة، الارتفاع = عرض اللوحة.
        return RotatedBox(
          quarterTurns: 1,
          child: SizedBox(
            width: panelH,
            height: panelW,
            child: child,
          ),
        );
      },
    );
  }
  final maxWidth = (MediaQuery.sizeOf(sheetContext).height - 16)
      .clamp(280.0, 720.0)
      .toDouble();
  return Align(
    alignment: overlayAlignment,
    child: RotatedBox(
      quarterTurns: 1,
      child: SizedBox(width: maxWidth, child: child),
    ),
  );
}

/// في **الأفقي** أو **القراءة الأفقية الدوّارة**: لوحة من يسار الشاشة ومتوسّطة عمودياً.
/// في **العمودي** العادي: ورقة سفلية كما كان سابقاً.
Future<T?> showQuranMenuSidePanel<T>({
  required BuildContext context,
  required bool horizontallyRotatedReading,
  required Widget Function(BuildContext sheetContext) builder,
  Color backgroundColor = const Color(0xFFE8F5E9),
  bool isScrollControlled = false,
  ShapeBorder? bottomSheetShape,
  bool omitBottomSheetShape = false,
}) {
  final useSidePanel = horizontallyRotatedReading ||
      MediaQuery.orientationOf(context) == Orientation.landscape;

  if (!useSidePanel) {
    if (omitBottomSheetShape) {
      return showModalBottomSheet<T>(
        context: context,
        isScrollControlled: isScrollControlled,
        backgroundColor: backgroundColor,
        builder: builder,
      );
    }
    return showModalBottomSheet<T>(
      context: context,
      isScrollControlled: isScrollControlled,
      backgroundColor: backgroundColor,
      shape: bottomSheetShape ??
          const RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
          ),
      builder: builder,
    );
  }

  final barrierLabel =
      MaterialLocalizations.of(context).modalBarrierDismissLabel;
  final transparent = backgroundColor.alpha == 0;
  return showGeneralDialog<T>(
    context: context,
    useRootNavigator: true,
    barrierDismissible: true,
    barrierLabel: barrierLabel,
    barrierColor: Colors.black54,
    transitionDuration: const Duration(milliseconds: 280),
    pageBuilder: (dialogContext, animation, secondaryAnimation) {
      final mq = MediaQuery.of(dialogContext);
      final size = mq.size;
      final pad = mq.padding;
      final availH = size.height - pad.top - pad.bottom;
      final panelH = (availH * 0.92).clamp(240.0, 900.0);
      final maxW = (size.width - 20).clamp(260.0, 560.0);
      final panelW = (size.width * 0.86).clamp(280.0, 400.0).toDouble();
      final w = panelW > maxW ? maxW : panelW;
      return SafeArea(
        child: Align(
          alignment: Alignment.centerLeft,
          child: Padding(
            padding: const EdgeInsets.only(left: 10),
            child: SizedBox(
              width: w,
              height: panelH,
              child: Material(
                color: transparent ? Colors.transparent : backgroundColor,
                elevation: transparent ? 0 : 10,
                shadowColor: Colors.black45,
                surfaceTintColor: Colors.transparent,
                borderRadius: BorderRadius.circular(16),
                clipBehavior: Clip.antiAlias,
                child: builder(dialogContext),
              ),
            ),
          ),
        ),
      );
    },
    transitionBuilder: (ctx, animation, secondaryAnimation, child) {
      final curved = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      );
      return SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(-1, 0),
          end: Offset.zero,
        ).animate(curved),
        child: FadeTransition(opacity: curved, child: child),
      );
    },
  );
}
