/// بيانات قارئ التلاوة.
class AyahReciter {
  const AyahReciter({
    required this.id,
    required this.nameAr,
    required this.assetPath,
    this.hasSegments = true,
  });
  final String id;
  final String nameAr;
  final String assetPath;
  final bool hasSegments;
}

/// عدد آيات كل سورة (ترتيب المصحف).
const List<int> _suraAyahCounts = [
  7, 286, 200, 176, 120, 165, 206, 75, 129, 109, 123, 111, 43, 52, 99, 128, 111,
  110, 98, 135, 112, 78, 118, 64, 77, 227, 93, 88, 69, 60, 34, 30, 73, 54, 45,
  83, 182, 88, 75, 85, 54, 53, 89, 59, 37, 35, 38, 29, 18, 45, 60, 49, 62, 55,
  78, 96, 29, 22, 24, 13, 14, 11, 11, 18, 12, 12, 30, 52, 52, 44, 28, 28, 20,
  56, 40, 31, 50, 40, 46, 42, 29, 19, 36, 25, 22, 17, 19, 26, 30, 20, 15, 21,
  11, 8, 8, 19, 5, 8, 8, 11, 11, 8, 3, 9, 5, 4, 7, 3, 6, 3, 5, 4, 5, 6,
];

/// قائمة القراء المعرّفة.
const List<AyahReciter> kAyahReciters = [
  AyahReciter(
    id: 'alnufais',
    nameAr: 'أحمد النفيس',
    assetPath: 'assets/audio/ayah-recitation-alnufais.json/ayah-recitation-alnufais.json',
    hasSegments: true,
  ),
  AyahReciter(
    id: 'sudais',
    nameAr: 'عبدالرحمن السديسي',
    assetPath: 'assets/audio/ayah-recitation-abdur-rahman-as-sudais-recitation.json/ayah-recitation-abdur-rahman-as-sudais-recitation.json',
    hasSegments: true,
  ),
  AyahReciter(
    id: 'husary',
    nameAr: 'محمود خليل الحصري',
    assetPath: 'assets/audio/ayah-recitation-mahmoud-khalil-al-husary-murattal-hafs-957.json/ayah-recitation-mahmoud-khalil-al-husary-murattal-hafs-957.json',
    hasSegments: true,
  ),
  AyahReciter(
    id: 'rifai',
    nameAr: 'هاني الرفاعي',
    assetPath: 'assets/audio/ayah-recitation-hani-ar-rifai-recitation-murattal-hafs-68.json/ayah-recitation-hani-ar-rifai-recitation-murattal-hafs-68.json',
    hasSegments: true,
  ),
  AyahReciter(
    id: 'shuraim',
    nameAr: 'سعود الشريم',
    assetPath: 'assets/audio/ayah-recitation-saud-al-shuraim-murattal-hafs-960.json/ayah-recitation-saud-al-shuraim-murattal-hafs-960.json',
    hasSegments: true,
  ),
  AyahReciter(
    id: 'dosari',
    nameAr: 'ياسر الدوسري',
    assetPath: 'assets/audio/ayah-recitation-yasser-al-dosari-murattal-hafs-961.json/ayah-recitation-yasser-al-dosari-murattal-hafs-961.json',
    hasSegments: true,
  ),
  AyahReciter(
    id: 'minshawi',
    nameAr: 'محمد صديق المنشاوي',
    assetPath: 'assets/audio/ayah-recitation-muhammad-siddiq-al-minshawi-murattal-hafs-959.json/ayah-recitation-muhammad-siddiq-al-minshawi-murattal-hafs-959.json',
    hasSegments: true,
  ),
  AyahReciter(
    id: 'tunaiji',
    nameAr: 'خليفة الطنيجي',
    assetPath: 'assets/audio/ayah-recitation-khalifa-al-tunaiji-murattal-hafs-958.json/ayah-recitation-khalifa-al-tunaiji-murattal-hafs-958.json',
    hasSegments: true,
  ),
  AyahReciter(
    id: 'muaiqly',
    nameAr: 'ماهر المعيقلي',
    assetPath: 'assets/audio/ayah-recitation-maher-al-mu-aiqly-murattal-hafs-948.json/ayah-recitation-maher-al-mu-aiqly-murattal-hafs-948.json',
    hasSegments: true,
  ),
  AyahReciter(
    id: 'abdulbasit',
    nameAr: 'عبدالباسط عبدالصمد',
    assetPath: 'assets/audio/ayah-recitation-abdul-basit-abdul-samad-mujawwad-hafs-949.json/ayah-recitation-abdul-basit-abdul-samad-mujawwad-hafs-949.json',
    hasSegments: true,
  ),
  AyahReciter(
    id: 'shatri',
    nameAr: 'أبو بكر الشاطري',
    assetPath: 'assets/audio/ayah-recitation-abu-bakr-al-shatri-murattal-hafs-952.json/ayah-recitation-abu-bakr-al-shatri-murattal-hafs-952.json',
    hasSegments: true,
  ),
  AyahReciter(
    id: 'ghamdi',
    nameAr: 'سعد الغامدي',
    assetPath: 'assets/audio/ayah-recitation-saad-al-ghamdi-murattal-hafs-954.json/ayah-recitation-saad-al-ghamdi-murattal-hafs-954.json',
    hasSegments: true,
  ),
];

/// الآية السابقة في ترتيب المصحف. تُرجع null عند 1:1.
(bool, int, int)? getPrevAyah(int sura, int ayah) {
  if (sura < 1 || ayah < 1) return null;
  if (sura == 1 && ayah == 1) return null;
  if (ayah > 1) return (true, sura, ayah - 1);
  final prevSura = sura - 1;
  if (prevSura < 1) return null;
  final count = prevSura <= _suraAyahCounts.length
      ? _suraAyahCounts[prevSura - 1]
      : 286;
  return (true, prevSura, count);
}

/// الآية التالية في ترتيب المصحف. تُرجع null عند 114:6.
(bool, int, int)? getNextAyah(int sura, int ayah) {
  if (sura < 1 || ayah < 1) return null;
  final count = sura <= _suraAyahCounts.length
      ? _suraAyahCounts[sura - 1]
      : 286;
  if (ayah < count) return (true, sura, ayah + 1);
  if (sura >= 114) return null;
  return (true, sura + 1, 1);
}
