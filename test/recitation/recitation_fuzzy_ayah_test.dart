import 'package:flutter_test/flutter_test.dart';
import 'package:quran_app/recitation/arabic_normalizer.dart';
import 'package:quran_app/recitation/recitation_fuzzy_ayah.dart';

void main() {
  test('ASR split «مده هامه» is close to «مدهامتان» after compact', () {
    const wrongAsr = 'مده هامه';
    final q = ArabicNormalizer.normalizeForSearch(wrongAsr);
    final compact = q.replaceAll(' ', '');
    const target = 'مدهامتان';
    final s = fuzzyRasmSimilarity(compact, target);
    expect(s, greaterThan(0.45));
  });
}
