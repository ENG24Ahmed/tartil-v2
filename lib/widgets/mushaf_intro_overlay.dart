import 'package:flutter/material.dart';

/// تعتيم الشاشة مع إبراز مستطيل (منطقة المصحف أو زر القارئ).
class _SpotlightPainter extends CustomPainter {
  _SpotlightPainter({
    required this.hole,
    required this.dimColor,
  });

  final Rect hole;
  final Color dimColor;
  static const double _radius = 14;

  @override
  void paint(Canvas canvas, Size size) {
    final full = Path()..addRect(Rect.fromLTWH(0, 0, size.width, size.height));
    final rrect = RRect.fromRectXY(hole, _radius, _radius);
    final cut = Path()..addRRect(rrect);
    final path = Path.combine(PathOperation.difference, full, cut);
    canvas.drawPath(path, Paint()..color = dimColor);
    final border = Paint()
      ..color = Colors.white.withValues(alpha: 0.85)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5;
    canvas.drawRRect(rrect, border);
  }

  @override
  bool shouldRepaint(covariant _SpotlightPainter oldDelegate) {
    return oldDelegate.hole != hole || oldDelegate.dimColor != dimColor;
  }
}

class MushafIntroOverlay extends StatelessWidget {
  const MushafIntroOverlay({
    super.key,
    required this.focusRect,
    required this.title,
    required this.body,
    required this.onNext,
    this.nextLabel = 'التالي',
    this.showSkip = true,
    this.onSkip,
  });

  final Rect focusRect;
  final String title;
  final String body;
  final VoidCallback onNext;
  final String nextLabel;
  final bool showSkip;
  final VoidCallback? onSkip;

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    return Stack(
      fit: StackFit.expand,
      children: [
        AbsorbPointer(
          absorbing: true,
          child: CustomPaint(
            painter: _SpotlightPainter(
              hole: focusRect,
              dimColor: Colors.black.withValues(alpha: 0.58),
            ),
            child: const SizedBox.expand(),
          ),
        ),
        Positioned(
          left: 16,
          right: 16,
          bottom: 16 + bottomInset,
          child: Material(
            color: const Color(0xFFF1F8F4),
            elevation: 10,
            borderRadius: BorderRadius.circular(16),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(18, 16, 18, 14),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    title,
                    textAlign: TextAlign.right,
                    style: const TextStyle(
                      fontFamily: 'QuranUthmani',
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                      color: Color(0xFF1B5E20),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    body,
                    textAlign: TextAlign.right,
                    style: TextStyle(
                      fontFamily: 'QuranUthmani',
                      fontSize: 15,
                      height: 1.35,
                      color: Colors.green.shade900,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      if (showSkip && onSkip != null)
                        TextButton(
                          onPressed: onSkip,
                          child: Text(
                            'تخطّي',
                            style: TextStyle(
                              fontFamily: 'QuranUthmani',
                              color: Colors.grey.shade700,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        )
                      else
                        const Spacer(),
                      const Spacer(),
                      FilledButton(
                        onPressed: onNext,
                        style: FilledButton.styleFrom(
                          backgroundColor: const Color(0xFF2E7D32),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 22,
                            vertical: 12,
                          ),
                        ),
                        child: Text(
                          nextLabel,
                          style: const TextStyle(
                            fontFamily: 'QuranUthmani',
                            fontWeight: FontWeight.w700,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// يحسب مستطيل الإبراز من [GlobalKey] بعد التخطيط.
Rect? mushafIntroRectFromKey(GlobalKey key, {double pad = 8}) {
  final ctx = key.currentContext;
  if (ctx == null) return null;
  final box = ctx.findRenderObject() as RenderBox?;
  if (box == null || !box.hasSize) return null;
  final topLeft = box.localToGlobal(Offset.zero);
  return Rect.fromLTWH(
    topLeft.dx - pad,
    topLeft.dy - pad,
    box.size.width + pad * 2,
    box.size.height + pad * 2,
  );
}

/// مستطيل افتراضي في منتصف المنطقة الآمنة (احتياط إن فشل القياس).
Rect mushafIntroFallbackRect(BuildContext context) {
  final size = MediaQuery.sizeOf(context);
  final pad = MediaQuery.paddingOf(context);
  final w = size.width * 0.82;
  final h = size.height * 0.42;
  final left = (size.width - w) / 2;
  final top = pad.top + (size.height - pad.vertical - h) * 0.28;
  return Rect.fromLTWH(left, top, w, h);
}

/// احتياط عندما لا يُقاس زر القارئ (مشغّل مخفٍ مثلاً).
Rect mushafIntroReciterFallbackRect(BuildContext context) {
  final size = MediaQuery.sizeOf(context);
  final pad = MediaQuery.paddingOf(context);
  final w = (size.width * 0.55).clamp(140.0, 320.0);
  const h = 52.0;
  final left = (size.width - w) / 2;
  final top = size.height - pad.bottom - h - 88;
  return Rect.fromLTWH(left, top, w, h);
}
