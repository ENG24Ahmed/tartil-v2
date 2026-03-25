import 'package:flutter/material.dart';

/// عزل شاشة المصحف عن تغيّر [MediaQuery.size] و [MediaQuery.textScaler] الناتج عن
/// إعدادات أندرويد (حجم شاشة العرض، تكبير النص).
///
/// الفكرة: عرض مساحة الصفحة الفعلية بالبكسل الفيزيائي للمنطقة المعروضة ثابتة تقريبًا
/// مهما تغيّر الـ logical size أو الـ devicePixelRatio. نستنتج عرضًا/ارتفاعًا منطقيًا
/// مرجعيًا ثابتًا: `stable = physical / kReferenceDevicePixelRatio`، ثم نرسم
/// المحتوى داخل [SizedBox] بهذا الحجم ونطبّق [FittedBox] (contain) لملء المساحة
/// المتاحة ككتلة واحدة بنفس النسب — فيبقى التوزيع الداخلي ثابتًا ولا يُعاد بناؤه
/// حسب إعدادات النظام.
class MushafStableViewport extends StatelessWidget {
  const MushafStableViewport({
    super.key,
    required this.child,
  });

  /// قيمة مرجعية ثابتة لكثافة العرض المنطقية (ليست كثافة الجهاز الحالية).
  /// تثبيت `physical / kReferenceDevicePixelRatio` يعادل تعويضًا عكسيًا لأثر تغيّر
  /// الـ DPR مع ثبات البكسل الفيزيائي للمنطقة.
  static const double kReferenceDevicePixelRatio = 3.0;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final mq = MediaQuery.of(context);
        final dpr = mq.devicePixelRatio;
        final maxW = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : mq.size.width;
        final maxH = constraints.maxHeight.isFinite
            ? constraints.maxHeight
            : mq.size.height;
        if (maxW <= 0 || maxH <= 0) {
          return const SizedBox.shrink();
        }

        final physicalW = maxW * dpr;
        final physicalH = maxH * dpr;
        final stableW = physicalW / kReferenceDevicePixelRatio;
        final stableH = physicalH / kReferenceDevicePixelRatio;

        final stableMediaQuery = mq.copyWith(
          textScaler: TextScaler.noScaling,
          size: Size(stableW, stableH),
        );

        return FittedBox(
          fit: BoxFit.contain,
          alignment: Alignment.center,
          child: SizedBox(
            width: stableW,
            height: stableH,
            child: MediaQuery(
              data: stableMediaQuery,
              child: child,
            ),
          ),
        );
      },
    );
  }
}
