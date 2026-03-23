/// مقطع في سطر آية: النص + هل هو علامة آية (نحتفظ بلونها الأصلي).
typedef AyahSegment = ({String text, bool isMarker});

/// سطر واحد في صفحة المصحف (مشترك بين QPC V1 و V4).
class MushafPageLine {
  final String lineText;
  final bool isCentered;
  final String fontFamily;
  final String lineType; // 'ayah', 'surah_name', 'basmallah', etc.
  /// For ayah lines: when true, ayah marker glyphs should keep original color (QPC V4 أسود).
  final bool isAyahMarkerSensitive;
  /// Page number (1..604) for cache key and preload.
  final int pageNumber;
  /// مقاطع سطر الآية من قاعدة البيانات (نص عادي vs علامة آية). إن وُجد يُستخدم في الوضع الأسود.
  final List<AyahSegment>? ayahSegments;
  /// نطاق كلمات السطر (word_number_all) — لربط الضغط المطول بالآية. فقط لسطور type == 'ayah'.
  final int? rangeStart;
  final int? rangeEnd;

  const MushafPageLine({
    required this.lineText,
    required this.isCentered,
    required this.fontFamily,
    this.lineType = 'ayah',
    this.isAyahMarkerSensitive = false,
    this.pageNumber = 0,
    this.ayahSegments,
    this.rangeStart,
    this.rangeEnd,
  });

  Map<String, dynamic> toJson() => {
        'lineText': lineText,
        'isCentered': isCentered,
        'fontFamily': fontFamily,
        'lineType': lineType,
        'isAyahMarkerSensitive': isAyahMarkerSensitive,
        'pageNumber': pageNumber,
        'ayahSegments': ayahSegments
            ?.map((s) => {'text': s.text, 'isMarker': s.isMarker}).toList(),
        'rangeStart': rangeStart,
        'rangeEnd': rangeEnd,
      };

  static MushafPageLine fromJson(Map<String, dynamic> m) {
    List<AyahSegment>? segs;
    final segList = m['ayahSegments'] as List?;
    if (segList != null) {
      segs = segList.map((e) {
        final x = e as Map<String, dynamic>;
        return (text: x['text'] as String? ?? '', isMarker: x['isMarker'] as bool? ?? false);
      }).toList();
    }
    return MushafPageLine(
      lineText: m['lineText'] as String? ?? '',
      isCentered: m['isCentered'] as bool? ?? false,
      fontFamily: m['fontFamily'] as String? ?? '',
      lineType: m['lineType'] as String? ?? 'ayah',
      isAyahMarkerSensitive: m['isAyahMarkerSensitive'] as bool? ?? false,
      pageNumber: (m['pageNumber'] as num?)?.toInt() ?? 0,
      ayahSegments: segs,
      rangeStart: (m['rangeStart'] as num?)?.toInt(),
      rangeEnd: (m['rangeEnd'] as num?)?.toInt(),
    );
  }
}
