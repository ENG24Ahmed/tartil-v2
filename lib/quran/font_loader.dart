
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

final Set<String> _loadedFonts = <String>{};

// كاش للـ Future لكل صفحة — يمنع FutureBuilder من إعادة تشغيل العمل عند كل rebuild
final Map<int, Future<void>> _qcf4FontFutures = {};

/// Loads a single legacy QCF_P page font (1..604). يجرب .ttf ثم .TTF.
Future<void> loadQcfFont(int page) async {
  final fontName = 'QCF_P${page.toString().padLeft(3, '0')}';
  if (_loadedFonts.contains(fontName)) return;

  final loader = FontLoader(fontName);
  ByteData fontData;
  try {
    fontData = await rootBundle.load('assets/fonts/qcf_pages/$fontName.ttf');
  } catch (_) {
    fontData = await rootBundle.load('assets/fonts/qcf_pages/$fontName.TTF');
  }
  loader.addFont(Future.value(fontData));
  await loader.load();
  _loadedFonts.add(fontName);
}

/// Loads a single QCF4 tajweed page font (1..604). يجرب .ttf ثم .TTF.
Future<void> loadQcf4Font(int page) async {
  final fontName = 'QCF4_tajweed_${page.toString().padLeft(3, '0')}';
  if (_loadedFonts.contains(fontName)) return;

  final loader = FontLoader(fontName);
  ByteData fontData;
  try {
    fontData = await rootBundle.load('assets/fonts/qcf4/$fontName.ttf');
  } catch (_) {
    fontData = await rootBundle.load('assets/fonts/qcf4/$fontName.TTF');
  }
  loader.addFont(Future.value(fontData));
  await loader.load();
  _loadedFonts.add(fontName);
}

/// يضمن تسجيل خط صفحة التجويد في المحرك قبل بناء النص (مسارات الكاش السريعة).
///
/// إذا كان الخط محمّلاً مسبقاً يبني الصفحة **فوراً** بدون FutureBuilder لتفادي
/// الوميض الناتج عن إطار الانتظار حتى مع Future فارية.
Widget buildAfterQcf4FontLoaded(
  int page,
  Widget Function() builder, {
  WidgetBuilder? placeholder,
}) {
  final fontName = 'QCF4_tajweed_${page.toString().padLeft(3, '0')}';
  if (_loadedFonts.contains(fontName)) {
    return builder();
  }
  return FutureBuilder<void>(
    // Fix 3: نفس كائن Future في كل rebuild — FutureBuilder لن يُعيد تشغيل التحميل
    future: _qcf4FontFutures.putIfAbsent(page, () => loadQcf4Font(page)),
    builder: (context, snapshot) {
      if (snapshot.connectionState != ConnectionState.done) {
        return placeholder?.call(context) ?? const SizedBox.expand();
      }
      if (snapshot.hasError) {
        debugPrint('QCF4 font load failed: ${snapshot.error}');
        return const Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              'تعذّر تحميل الخط. أعد المحاولة.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 16),
            ),
          ),
        );
      }
      return builder();
    },
  );
}

/// Loads the dedicated QCF4 basmallah font QCF4_BSML once. يجرب .ttf ثم .TTF.
Future<void> loadQcf4BsmallahFont() async {
  const fontName = 'QCF4_BSML';
  if (_loadedFonts.contains(fontName)) return;

  final loader = FontLoader(fontName);
  try {
    ByteData fontData;
    try {
      fontData = await rootBundle.load('assets/fonts/qcf4/QCF4_BSML.ttf');
    } catch (_) {
      fontData = await rootBundle.load('assets/fonts/qcf4/QCF4_BSML.TTF');
    }
    loader.addFont(Future.value(fontData));
    await loader.load();
    _loadedFonts.add(fontName);
  } catch (_) {
    // لو ملف الخط غير موجود في الأصول، نتجاهل بصمت لتفادي كسر عرض الصفحات.
  }
}
