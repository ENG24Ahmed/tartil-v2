import 'dart:math' as math;

/// يساعد عندما يقسّم التعرف الصوتي كلمة قرآنية إلى مقطعين أو يبدّل
/// أحرفاً (مثل: «مده هامه» مقابل «مدهامتان»).
int levenshteinDistanceArabic(String a, String b) {
  if (a == b) return 0;
  if (a.isEmpty) return b.length;
  if (b.isEmpty) return a.length;
  var previous = List<int>.generate(b.length + 1, (j) => j);
  var current = List<int>.filled(b.length + 1, 0);
  for (var i = 1; i <= a.length; i++) {
    current[0] = i;
    for (var j = 1; j <= b.length; j++) {
      final cost = a.codeUnitAt(i - 1) == b.codeUnitAt(j - 1) ? 0 : 1;
      current[j] = math.min(
        math.min(current[j - 1] + 1, previous[j] + 1),
        previous[j - 1] + cost,
      );
    }
    final t = previous;
    previous = current;
    current = t;
  }
  return previous[b.length];
}

/// 0.0 = لا تشابه، 1.0 = تطابق تام. مناسب لتصفية اقتراحات بعد [normalizeForSearch].
double fuzzyRasmSimilarity(String a, String b) {
  if (a.isEmpty || b.isEmpty) return 0.0;
  if (a == b) return 1.0;
  final d = levenshteinDistanceArabic(a, b);
  final maxLen = math.max(a.length, b.length);
  if (maxLen == 0) return 0.0;
  return 1.0 - d / maxLen;
}
