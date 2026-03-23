import 'package:quran_app/quran/models/mushaf_line.dart';

/// تخطيط صفحة محسوب مسبقاً بأبعاد مرجعية ثابتة.
/// يُخزَّن في ROM لتحميل سريع دون إعادة حساب التخطيط.
class BakedPageLayout {
  const BakedPageLayout({
    required this.version,
    required this.page,
    required this.referenceWidth,
    required this.referenceHeight,
    required this.slotHeight,
    required this.fullH,
    required this.contentW,
    required this.pageWidth,
    required this.leftMargin,
    required this.rightMargin,
    required this.topMargin,
    required this.bottomMargin,
    required this.pageLines,
    required this.lineHeights15,
    required this.slotOffset,
    this.mapping,
  });

  /// رُفع إلى 3 لإجبار إعادة توليد أي تخطيط قديم غير متوافق.
  /// (v2 كان لإصلاح عرض صفحات 4+؛ v3 لإبطال الكاش المحسوب القديم بأمان)
  static const int currentVersion = 3;

  final int version;
  final int page;
  final double referenceWidth;
  final double referenceHeight;
  final double slotHeight;
  final double fullH;
  final double contentW;
  final double pageWidth;
  final double leftMargin;
  final double rightMargin;
  final double topMargin;
  final double bottomMargin;
  final List<MushafPageLine> pageLines;
  final List<double> lineHeights15;

  /// للصفحتين 1 و 2: 3 (أول 3 خانات فارغة). لباقي الصفحات: 0.
  final int slotOffset;
  final Map<int, (int sura, int ayah)>? mapping;

  Map<String, dynamic> toJson() => {
        'version': version,
        'page': page,
        'refW': referenceWidth,
        'refH': referenceHeight,
        'slotH': slotHeight,
        'fullH': fullH,
        'contentW': contentW,
        'pageW': pageWidth,
        'leftM': leftMargin,
        'rightM': rightMargin,
        'topM': topMargin,
        'bottomM': bottomMargin,
        'lines': pageLines.map((l) => l.toJson()).toList(),
        'lineH15': lineHeights15,
        'slotOffset': slotOffset,
        if (mapping != null)
          'mapping': mapping!.entries
              .map((e) => {
                    'k': e.key,
                    's': e.value.$1,
                    'a': e.value.$2,
                  })
              .toList(),
      };

  static BakedPageLayout? fromJson(Map<String, dynamic> m) {
    try {
      final linesList = m['lines'] as List?;
      if (linesList == null || linesList.isEmpty) return null;
      final pageLines = linesList
          .map((e) => MushafPageLine.fromJson(e as Map<String, dynamic>))
          .toList();

      Map<int, (int, int)>? mapping;
      final mapList = m['mapping'] as List?;
      if (mapList != null) {
        mapping = {};
        for (final e in mapList) {
          final x = e as Map<String, dynamic>;
          final k = (x['k'] as num?)?.toInt();
          final s = (x['s'] as num?)?.toInt();
          final a = (x['a'] as num?)?.toInt();
          if (k != null && s != null && a != null) mapping[k] = (s, a);
        }
      }

      return BakedPageLayout(
        version: (m['version'] as num?)?.toInt() ?? 1,
        page: (m['page'] as num?)?.toInt() ?? 1,
        referenceWidth: (m['refW'] as num?)?.toDouble() ?? 1080,
        referenceHeight: (m['refH'] as num?)?.toDouble() ?? 1512,
        slotHeight: (m['slotH'] as num?)?.toDouble() ?? 0,
        fullH: (m['fullH'] as num?)?.toDouble() ?? 0,
        contentW: (m['contentW'] as num?)?.toDouble() ?? 0,
        pageWidth: (m['pageW'] as num?)?.toDouble() ?? 0,
        leftMargin: (m['leftM'] as num?)?.toDouble() ?? 0,
        rightMargin: (m['rightM'] as num?)?.toDouble() ?? 0,
        topMargin: (m['topM'] as num?)?.toDouble() ?? 0,
        bottomMargin: (m['bottomM'] as num?)?.toDouble() ?? 0,
        pageLines: pageLines,
        lineHeights15: (m['lineH15'] as List?)
                ?.map((e) => (e as num).toDouble())
                .toList() ??
            List.filled(15, 0.0),
        slotOffset: (m['slotOffset'] as num?)?.toInt() ?? 0,
        mapping: mapping,
      );
    } catch (_) {
      return null;
    }
  }
}
