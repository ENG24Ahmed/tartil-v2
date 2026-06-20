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
///
/// التحسين: تُخزَّن قيم (stableW / stableH / stableMediaQuery) في الـ State
/// وتُعاد حسابها فقط عند تغيّر القيود (constraints) أو DPR — هذا يمنع إنشاء كائن
/// [MediaQueryData] جديد عند كل إعادة بناء سببها تغيير tier، فيحافظ InheritedWidget
/// على هوية البيانات ولا يُشعر الأبناء بتغيير وهمي في MediaQuery.
class MushafStableViewport extends StatefulWidget {
  const MushafStableViewport({
    super.key,
    required this.child,
  });

  /// قيمة مرجعية ثابتة لكثافة العرض المنطقية (ليست كثافة الجهاز الحالية).
  /// تثبيت `physical / kReferenceDevicePixelRatio` يعادل تعويضًا عكسيًا لأثر تغيّر
  /// الـ DPR مع ثبات البكسل الفيزيائي للمنطقة.
  /// أعلى قليلاً من 3.0 يكبّر المحتوى المنطقي عند الـ FittedBox فيُقلّل الفراغ الجانبي الناتج عن contain.
  static const double kReferenceDevicePixelRatio = 3.35;

  final Widget child;

  @override
  State<MushafStableViewport> createState() => _MushafStableViewportState();
}

class _MushafStableViewportState extends State<MushafStableViewport> {
  BoxConstraints? _lastConstraints;
  double? _lastDpr;
  double? _stableW;
  double? _stableH;
  MediaQueryData? _stableMediaQuery;

  void _recompute(BoxConstraints constraints, MediaQueryData mq) {
    final dpr = mq.devicePixelRatio;
    if (constraints == _lastConstraints && dpr == _lastDpr) return;
    _lastConstraints = constraints;
    _lastDpr = dpr;
    final maxW =
        constraints.maxWidth.isFinite ? constraints.maxWidth : mq.size.width;
    final maxH =
        constraints.maxHeight.isFinite ? constraints.maxHeight : mq.size.height;
    if (maxW <= 0 || maxH <= 0) {
      _stableW = null;
      _stableH = null;
      _stableMediaQuery = null;
      return;
    }
    final physicalW = maxW * dpr;
    final physicalH = maxH * dpr;
    _stableW = physicalW / MushafStableViewport.kReferenceDevicePixelRatio;
    _stableH = physicalH / MushafStableViewport.kReferenceDevicePixelRatio;
    // إنشاء كائن MediaQueryData جديد فقط هنا (عند تغيّر constraints/DPR)
    // وليس عند كل rebuild — يمنع InheritedWidget من إشعار الأبناء بتغيير وهمي.
    _stableMediaQuery = mq.copyWith(
      textScaler: TextScaler.noScaling,
      size: Size(_stableW!, _stableH!),
    );
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (lCtx, constraints) {
        final mq = MediaQuery.of(lCtx);
        _recompute(constraints, mq);
        if (_stableW == null || _stableH == null) {
          return const SizedBox.shrink();
        }
        return FittedBox(
          fit: BoxFit.contain,
          alignment: Alignment.center,
          child: SizedBox(
            width: _stableW!,
            height: _stableH!,
            child: MediaQuery(
              data: _stableMediaQuery!,
              child: widget.child,
            ),
          ),
        );
      },
    );
  }
}
