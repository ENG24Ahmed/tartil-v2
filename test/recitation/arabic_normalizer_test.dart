import 'package:flutter_test/flutter_test.dart';
import 'package:quran_app/recitation/arabic_normalizer.dart';

void main() {
  group('muqattaat ASR to mushaf rasm', () {
    test('spelled alif-lam-mim becomes الم', () {
      final o = ArabicNormalizer.normalizeForSearch('الف لام ميم');
      expect(o, 'الم');
    });

    test('spelled with hamza on alif', () {
      final o = ArabicNormalizer.normalizeForSearch('ألف لام ميم');
      expect(o, 'الم');
    });

    test('طه and يس style letters collapse', () {
      expect(ArabicNormalizer.normalizeForSearch('طاء هاء'), 'طه');
      expect(ArabicNormalizer.normalizeForSearch('ياء سين'), 'يس');
    });
  });

  test('tokenMatchForms adds common ASR alternates for مدهامتان', () {
    final forms = ArabicNormalizer.tokenMatchForms('مدهامتان');
    expect(forms, contains('مدهامه'));
  });

  test('ض and ظ are one surface for token matching (ASR confusion)', () {
    final withZah = ArabicNormalizer.tokenMatchForms('نظاختان');
    final withDad = ArabicNormalizer.tokenMatchForms('نضاختان');
    expect(withZah.intersection(withDad), isNotEmpty);
  });

  test('normalizeForSearch unifies ظ to ض so partial ASR text matches mushaf', () {
    expect(
      ArabicNormalizer.normalizeForSearch('نظاختان'),
      ArabicNormalizer.normalizeForSearch('نضاختان'),
    );
  });

  group('Huruf muqattaat ASR drifts (29 surahs, 14 patterns)', () {
    test('الم / الام', () {
      final a = ArabicNormalizer.tokenMatchForms('الم');
      final b = ArabicNormalizer.tokenMatchForms('الام');
      expect(a.intersection(b), isNotEmpty);
    });

    test('كهيعص / كهيعض (ص↔ض after normalize)', () {
      final a = ArabicNormalizer.tokenMatchForms('كهيعص');
      final b = ArabicNormalizer.tokenMatchForms('كهيعض');
      expect(a.intersection(b), isNotEmpty);
    });

    test('حمعسق drift form', () {
      final ref = ArabicNormalizer.tokenMatchForms('حمعسق');
      expect(ref, contains('حمعسك'));
    });
  });
}
