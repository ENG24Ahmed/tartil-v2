import 'dhikr_counter_models.dart';

/// المجموعات الجاهزة الثمانية
const List<DhikrGroup> kPresetGroups = [
  DhikrGroup(
    name: 'تسبيح بعد الصلاة',
    isPreset: true,
    items: [
      DhikrItem(text: 'سبحان الله', target: 33),
      DhikrItem(text: 'الحمد لله', target: 33),
      DhikrItem(text: 'الله أكبر', target: 33),
      DhikrItem(
        text:
            'لا إله إلا الله وحده لا شريك له، له الملك وله الحمد، وهو على كل شيء قدير',
        target: 1,
      ),
    ],
  ),
  DhikrGroup(
    name: 'تسبيح قبل النوم',
    isPreset: true,
    items: [
      DhikrItem(text: 'سبحان الله', target: 33),
      DhikrItem(text: 'الحمد لله', target: 33),
      DhikrItem(text: 'الله أكبر', target: 34),
    ],
  ),
  DhikrGroup(
    name: 'ورد الاستغفار',
    isPreset: true,
    items: [
      DhikrItem(text: 'أستغفر الله', target: 100),
      DhikrItem(text: 'أستغفر الله العظيم وأتوب إليه', target: 100),
    ],
  ),
  DhikrGroup(
    name: 'ورد التهليل',
    isPreset: true,
    items: [
      DhikrItem(text: 'لا إله إلا الله', target: 100),
      DhikrItem(
        text:
            'لا إله إلا الله وحده لا شريك له، له الملك وله الحمد، وهو على كل شيء قدير',
        target: 100,
      ),
    ],
  ),
  DhikrGroup(
    name: 'الصلاة على النبي ﷺ',
    isPreset: true,
    items: [
      DhikrItem(text: 'اللهم صلِّ على محمد', target: 100),
      DhikrItem(text: 'اللهم صلِّ وسلم على نبينا محمد', target: 100),
    ],
  ),
  DhikrGroup(
    name: 'الباقيات الصالحات',
    isPreset: true,
    items: [
      DhikrItem(text: 'سبحان الله', target: 100),
      DhikrItem(text: 'الحمد لله', target: 100),
      DhikrItem(text: 'لا إله إلا الله', target: 100),
      DhikrItem(text: 'الله أكبر', target: 100),
    ],
  ),
  DhikrGroup(
    name: 'كلمات خفيفة على اللسان',
    isPreset: true,
    items: [
      DhikrItem(text: 'سبحان الله وبحمده', target: 100),
      DhikrItem(text: 'سبحان الله العظيم', target: 100),
      DhikrItem(
        text: 'سبحان الله وبحمده، سبحان الله العظيم',
        target: 100,
      ),
    ],
  ),
  DhikrGroup(
    name: 'ورد يومي مقترح',
    isPreset: true,
    items: [
      DhikrItem(text: 'أستغفر الله', target: 100),
      DhikrItem(text: 'سبحان الله وبحمده', target: 100),
      DhikrItem(
        text:
            'لا إله إلا الله وحده لا شريك له، له الملك وله الحمد، وهو على كل شيء قدير',
        target: 100,
      ),
      DhikrItem(text: 'اللهم صلِّ وسلم على نبينا محمد', target: 100),
    ],
  ),
];

/// الأذكار المفردة الجاهزة (مرتبة حسب الأهمية والشيوع)
const List<DhikrItem> kPresetSingleDhikrs = [
  DhikrItem(text: 'أستغفر الله', target: 100),
  DhikrItem(text: 'سبحان الله وبحمده', target: 100),
  DhikrItem(
    text:
        'لا إله إلا الله وحده لا شريك له، له الملك وله الحمد، وهو على كل شيء قدير',
    target: 100,
  ),
  DhikrItem(text: 'لا حول ولا قوة إلا بالله', target: 100),
  DhikrItem(text: 'اللهم صلِّ على محمد', target: 100),
  DhikrItem(text: 'سبحان الله', target: 100),
  DhikrItem(text: 'الحمد لله', target: 100),
  DhikrItem(text: 'الله أكبر', target: 100),
  DhikrItem(text: 'لا إله إلا الله', target: 100),
  DhikrItem(text: 'أستغفر الله العظيم وأتوب إليه', target: 100),
  DhikrItem(text: 'سبحان الله العظيم', target: 100),
  DhikrItem(text: 'سبحان الله وبحمده، سبحان الله العظيم', target: 100),
  DhikrItem(text: 'اللهم صلِّ وسلم على نبينا محمد', target: 100),
];
