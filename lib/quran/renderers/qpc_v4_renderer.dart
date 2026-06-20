import 'dart:async';
import 'dart:math' show min;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:quran_app/audio/ayah_audio_player.dart';
import 'package:quran_app/quran/ayah_long_press_scope.dart';
import 'package:quran_app/quran/font_loader.dart';
import 'package:quran_app/quran/models/mushaf_line.dart';
import 'package:quran_app/quran/page_cache.dart';
import 'package:quran_app/quran/page_persistent_cache.dart';
import 'package:quran_app/quran/quran_db.dart';
import 'package:quran_app/quran/compact_line_spacing_scope.dart';
import 'package:quran_app/quran/mushaf_page_layout.dart';
import 'package:quran_app/quran/mushaf_ayah_highlight.dart';
import 'package:quran_app/quran/temporary_search_ayah_highlight.dart';
import 'package:quran_app/services/qpc_glyph_db.dart';

const Color _kTemporarySearchHighlightColor = Color(0xFFD4AF37);
const double _kTemporarySearchHighlightAlpha = 0.22;

void appendTemporarySearchHighlightBar(
  List<Widget> overlayWidgets, {
  required TextPainter painter,
  required MushafPageLine line,
  required TextStyle style,
  required (int, int, int)? lineTemporarySearch,
  required double temporarySearchOpacity,
}) {
  if (lineTemporarySearch == null || temporarySearchOpacity <= 0.001) return;
  if (line.lineType != 'ayah') return;
  if (lineTemporarySearch.$2 < 0 ||
      lineTemporarySearch.$3 <= lineTemporarySearch.$2) {
    return;
  }
  final ayahR = mushafRangeHorizontalRectWithFallback(
    painter: painter,
    text: line.lineText,
    style: style,
    startChar: lineTemporarySearch.$2.clamp(0, line.lineText.length),
    endChar: lineTemporarySearch.$3.clamp(0, line.lineText.length),
  );
  if (ayahR.width <= 0.01) return;
  overlayWidgets.add(
    mushafFlatHighlightBar(
      left: ayahR.left,
      width: ayahR.width,
      lineHeight: painter.height,
      color: _kTemporarySearchHighlightColor,
      alpha: _kTemporarySearchHighlightAlpha * temporarySearchOpacity,
    ),
  );
}

/// هامش يمين/أعلى/سفل من عرض أو ارتفاع المرجع — **2%** لكل طرف (موحّد مع هوامش `mushaf_page_layout`).
const double kQpcPageMarginFraction = 0.02;

/// هامش اليسار (مثل يمين المصحف) — **2%** من عرض المرجع.
const double kQpcPageMarginLeftFraction = 0.02;

/// هامش جانبي عند الشاشات العريضة القصيرة — **2%** (موحّد مع الافتراضي).
const double kQpcPageMarginTightFraction = 0.02;

/// ارتفاع موحّد لصف رقم الصفحة (QuranReader + quran_page_viewer).
const double kQpcPageNumberRowHeight = 25;

/// فراغ بسيط تحت علامة رقم الصفحة عن حافة منطقة المحتوى.
const double kQpcPageNumberBottomGap = 4;

/// إزاحة بصرية لأعلى لإطار raqum والرقم داخل شريط الصفحة (dy سالب = أعلى).
const double kQpcPageNumberVerticalNudge = -5;

/// تكبير طفيف لرقم الصفحة + علامة raqum داخل نفس ارتفاع الصف (تصغير الإطار المرجعي أمام FittedBox).
const double kQpcPageNumberVisualBoost = 1.24;

/// تكبير إضافي لملف raqum_alsafha.svg فقط (دون تكبير أرقام الصفحة).
const double kQpcRaqumSvgScale = 1.25;

/// عمودي الشريط العلوي (جزء/سور) — أقل من 4 لتقريب أول سطر من الشريط.
const double kQpcTopBarVerticalPadding = 2;

/// إذا كان عرض/ارتفاع منطقة المصحف ≥ هذا، نطبّق هامشاً أضيقاً وخطاً أقل ارتفاعاً (V1).
const double kQpcShortWideAspectThreshold = 0.38;

/// خطوة سطر آية V1 عند الشاشات العريضة القصيرة (مع حد أدنى لارتفاع الخانة).
const double kQpcAyahLineHeightTight = 1.40;

/// هامش سفلي لسطر الآية عند الضغط العمودي.
const double kQpcAyahLinePadTight = 0.24;

/// نسبة ارتفاع إطار اسم السورة إلى عرضه (من viewBox sura_name.svg: 1621.5×171).
const double _surahFrameAspect = 171 / 1621.5;
const String _surahNameFontFamily = 'SurahNameV4';
const double _basmallahRaiseDy = -2.0;
const String _basmallahFontFamily = 'KFGQPCHAFSUthmanicScript';
const double _kBasmallahFontSize = 18;
typedef AyahRangeHighlight = ({
  int sura,
  int fromAyah,
  int toAyah,
  Color color
});

/// مخزن بسيط لتأشيرات الآيات (نطاقات) يُستخدم من شاشة القارئ والرندرز.
class AyahHighlightStore extends ChangeNotifier {
  AyahHighlightStore._();
  static final AyahHighlightStore instance = AyahHighlightStore._();

  List<AyahRangeHighlight> _ranges = const [];
  List<AyahRangeHighlight> get ranges => _ranges;

  void setRanges(List<AyahRangeHighlight> ranges) {
    _ranges = List<AyahRangeHighlight>.from(ranges);
    notifyListeners();
  }
}

const double _persistentHighlightAlpha = 0.18;
const double _persistentHighlightTopInsetFraction = 0.06;
const double _persistentHighlightHeightFraction = 0.88;
const double _persistentHighlightRadius = 10.0;

List<({double left, double width, Color color})> _mergePersistentRectsByColor(
  List<({double left, double width, Color color})> rects,
) {
  if (rects.isEmpty) return const [];
  final grouped = <int, List<({double left, double width, Color color})>>{};
  for (final r in rects) {
    final key = r.color.toARGB32();
    grouped.putIfAbsent(
        key, () => <({double left, double width, Color color})>[]);
    grouped[key]!.add(r);
  }
  final merged = <({double left, double width, Color color})>[];
  for (final list in grouped.values) {
    if (list.length == 1) {
      merged.add(list.first);
      continue;
    }
    var minLeft = list.first.left;
    var maxRight = list.first.left + list.first.width;
    for (final r in list) {
      if (r.left < minLeft) minLeft = r.left;
      final right = r.left + r.width;
      if (right > maxRight) maxRight = right;
    }
    final width = (maxRight - minLeft).clamp(0.0, double.infinity);
    if (width > 0.01) {
      merged.add((left: minLeft, width: width, color: list.first.color));
    }
  }
  merged.sort((a, b) => a.left.compareTo(b.left));
  return merged;
}

Widget _buildPersistentHighlightSegment(
  ({double left, double width, Color color}) rect,
  double lineHeight,
) {
  return Positioned(
    left: rect.left,
    top: lineHeight * _persistentHighlightTopInsetFraction,
    width: rect.width,
    height: lineHeight * _persistentHighlightHeightFraction,
    child: CustomPaint(
      painter: _WavyHighlightPainter(
        color: rect.color.withValues(alpha: _persistentHighlightAlpha),
      ),
    ),
  );
}

class _WavyHighlightPainter extends CustomPainter {
  const _WavyHighlightPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    canvas.save();
    canvas.clipRRect(
      RRect.fromRectAndRadius(
        Offset.zero & size,
        const Radius.circular(_persistentHighlightRadius),
      ),
    );
    final waveInset = (size.height * 0.10).clamp(0.6, 1.8).toDouble();
    final amplitude = (size.height * 0.07).clamp(0.6, 1.8).toDouble();
    final step = (size.width / 6).clamp(14.0, 30.0).toDouble();
    final topY = waveInset.toDouble();
    final bottomY = size.height - waveInset;

    final path = Path()..moveTo(0, topY);

    double x = 0;
    bool up = true;
    while (x < size.width) {
      final nx = (x + step).clamp(0, size.width).toDouble();
      final cx = (x + nx) / 2;
      final cy = up ? topY - amplitude : topY + amplitude;
      path.quadraticBezierTo(cx, cy, nx, topY);
      up = !up;
      x = nx;
    }

    path.lineTo(size.width, bottomY);

    x = size.width;
    up = true;
    while (x > 0) {
      final nx = (x - step).clamp(0, size.width).toDouble();
      final cx = (x + nx) / 2;
      final cy = up ? bottomY + amplitude : bottomY - amplitude;
      path.quadraticBezierTo(cx, cy, nx, bottomY);
      up = !up;
      x = nx;
    }

    path.close();
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.fill,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _WavyHighlightPainter oldDelegate) {
    return oldDelegate.color.toARGB32() != color.toARGB32();
  }
}

TextStyle _basmallahStyle({required double fontSize}) => TextStyle(
      fontFamily: _basmallahFontFamily,
      fontSize: fontSize,
      height: 1.15,
      fontWeight: FontWeight.w600,
      color: Colors.black,
    );

const int _kContentDimsCacheMaxEntries = 400;
final Map<String, (double, double)> _contentDimsCache = {};

String _contentDimsCacheKey(
  List<MushafPageLine> pageLines,
  TextStyle baseStyle,
  double linePaddingBottom,
) {
  final n = pageLines.length;
  final f0 = n > 0 ? pageLines.first.lineText : '';
  final f0tag = f0.isEmpty ? 0 : f0.codeUnitAt(0);
  final fontSize = (baseStyle.fontSize ?? 23).toStringAsFixed(2);
  final pad = linePaddingBottom.toStringAsFixed(3);
  return '$n|$f0tag|$fontSize|$pad';
}

(double, double) getQpcContentDimensions(
    List<MushafPageLine> pageLines, TextStyle baseStyle,
    {double linePaddingBottom = kNormalLinePaddingBottom}) {
  final key = _contentDimsCacheKey(pageLines, baseStyle, linePaddingBottom);
  final hit = _contentDimsCache[key];
  if (hit != null) return hit;

  double maxW = 0;
  double totalH = 0;
  for (final line in pageLines) {
    TextStyle s = baseStyle.copyWith(fontFamily: line.fontFamily);
    if (line.lineType == 'surah_name')
      s = baseStyle.copyWith(fontFamily: _surahNameFontFamily, fontSize: 22);
    if (line.lineType == 'basmallah')
      s = _basmallahStyle(fontSize: _kBasmallahFontSize);
    final painter = TextPainter(
      text: TextSpan(text: line.lineText, style: s),
      textDirection: TextDirection.rtl,
      maxLines: 1,
    )..layout(maxWidth: double.infinity);
    if (painter.width > maxW) maxW = painter.width;
    totalH += painter.height + linePaddingBottom;
  }
  final result = (maxW, totalH);
  if (_contentDimsCache.length >= _kContentDimsCacheMaxEntries) {
    _contentDimsCache.remove(_contentDimsCache.keys.first);
  }
  _contentDimsCache[key] = result;
  return result;
}

const int _kLineHeightsCacheMaxEntries = 400;
final Map<String, List<double>> _lineHeightsCache = {};

/// ارتفاعات الأسطر (لربط موضع الضغط بالسطر).
List<double> getQpcLineHeights(
    List<MushafPageLine> pageLines, TextStyle baseStyle,
    {double linePaddingBottom = kNormalLinePaddingBottom}) {
  final key = _contentDimsCacheKey(pageLines, baseStyle, linePaddingBottom);
  final hit = _lineHeightsCache[key];
  if (hit != null) return hit;

  final list = <double>[];
  for (final line in pageLines) {
    TextStyle s = baseStyle.copyWith(fontFamily: line.fontFamily);
    if (line.lineType == 'surah_name')
      s = baseStyle.copyWith(fontFamily: _surahNameFontFamily, fontSize: 22);
    if (line.lineType == 'basmallah')
      s = _basmallahStyle(fontSize: _kBasmallahFontSize);
    final painter = TextPainter(
      text: TextSpan(text: line.lineText, style: s),
      textDirection: TextDirection.rtl,
      maxLines: 1,
    )..layout(maxWidth: double.infinity);
    list.add(painter.height + linePaddingBottom);
  }
  if (_lineHeightsCache.length >= _kLineHeightsCacheMaxEntries) {
    _lineHeightsCache.remove(_lineHeightsCache.keys.first);
  }
  _lineHeightsCache[key] = list;
  return list;
}

/// عدد المسافات في النص (لتوزيعها عند التبرير).
int _countSpaces(String text) => ' '.allMatches(text).length;

/// إرجاع ستايل السطر مع wordSpacing لضبط السطر ليعادل contentW (تبرير — نهايات الأسطر متساوية).
TextStyle getJustifiedLineStyle(
    MushafPageLine line, TextStyle lineStyle, double contentW) {
  if (line.isCentered) return lineStyle;
  final w = mushafMeasureLineWidth(line.lineText, lineStyle);
  final spaces = _countSpaces(line.lineText);
  if (spaces <= 0 || w >= contentW) return lineStyle;
  final extra = (contentW - w) / spaces;
  return lineStyle.copyWith(wordSpacing: extra);
}

/// عرض صفحة المصحف من qpc_v4_layout (quran-data.sqlite) + words من qpc-v4.db مع خطوط QCF4.
class QpcV4Renderer {
  QpcV4Renderer._();
  static final QpcV4Renderer instance = QpcV4Renderer._();

  final QuranDb _quranDb = QuranDb.instance;

  static int _toInt(dynamic v, {int fallback = 0}) {
    if (v == null) return fallback;
    final s = v.toString().trim();
    if (s.isEmpty) return fallback;
    return int.tryParse(s) ?? fallback;
  }

  static bool _toBool(dynamic v, {bool fallback = false}) {
    if (v == null) return fallback;
    if (v is bool) return v;
    final s = v.toString().trim().toLowerCase();
    if (s == '1' || s == 'true') return true;
    if (s == '0' || s == 'false') return false;
    return fallback;
  }

  static const Map<int, String> _surahNames = {
    1: 'سورة الفاتحة',
    2: 'سورة البقرة',
    3: 'سورة آل عمران',
    4: 'سورة النساء',
    5: 'سورة المائدة',
    6: 'سورة الأنعام',
    7: 'سورة الأعراف',
    8: 'سورة الأنفال',
    9: 'سورة التوبة',
    10: 'سورة يونس',
    11: 'سورة هود',
    12: 'سورة يوسف',
    13: 'سورة الرعد',
    14: 'سورة إبراهيم',
    15: 'سورة الحجر',
    16: 'سورة النحل',
    17: 'سورة الإسراء',
    18: 'سورة الكهف',
    19: 'سورة مريم',
    20: 'سورة طه',
    21: 'سورة الأنبياء',
    22: 'سورة الحج',
    23: 'سورة المؤمنون',
    24: 'سورة النور',
    25: 'سورة الفرقان',
    26: 'سورة الشعراء',
    27: 'سورة النمل',
    28: 'سورة القصص',
    29: 'سورة العنكبوت',
    30: 'سورة الروم',
    31: 'سورة لقمان',
    32: 'سورة السجدة',
    33: 'سورة الأحزاب',
    34: 'سورة سبأ',
    35: 'سورة فاطر',
    36: 'سورة يس',
    37: 'سورة الصافات',
    38: 'سورة ص',
    39: 'سورة الزمر',
    40: 'سورة غافر',
    41: 'سورة فصلت',
    42: 'سورة الشورى',
    43: 'سورة الزخرف',
    44: 'سورة الدخان',
    45: 'سورة الجاثية',
    46: 'سورة الأحقاف',
    47: 'سورة محمد',
    48: 'سورة الفتح',
    49: 'سورة الحجرات',
    50: 'سورة ق',
    51: 'سورة الذاريات',
    52: 'سورة الطور',
    53: 'سورة النجم',
    54: 'سورة القمر',
    55: 'سورة الرحمن',
    56: 'سورة الواقعة',
    57: 'سورة الحديد',
    58: 'سورة المجادلة',
    59: 'سورة الحشر',
    60: 'سورة الممتحنة',
    61: 'سورة الصف',
    62: 'سورة الجمعة',
    63: 'سورة المنافقون',
    64: 'سورة التغابن',
    65: 'سورة الطلاق',
    66: 'سورة التحريم',
    67: 'سورة الملك',
    68: 'سورة القلم',
    69: 'سورة الحاقة',
    70: 'سورة المعارج',
    71: 'سورة نوح',
    72: 'سورة الجن',
    73: 'سورة المزمل',
    74: 'سورة المدثر',
    75: 'سورة القيامة',
    76: 'سورة الإنسان',
    77: 'سورة المرسلات',
    78: 'سورة النبأ',
    79: 'سورة النازعات',
    80: 'سورة عبس',
    81: 'سورة التكوير',
    82: 'سورة الانفطار',
    83: 'سورة المطففين',
    84: 'سورة الانشقاق',
    85: 'سورة البروج',
    86: 'سورة الطارق',
    87: 'سورة الأعلى',
    88: 'سورة الغاشية',
    89: 'سورة الفجر',
    90: 'سورة البلد',
    91: 'سورة الشمس',
    92: 'سورة الليل',
    93: 'سورة الضحى',
    94: 'سورة الشرح',
    95: 'سورة التين',
    96: 'سورة العلق',
    97: 'سورة القدر',
    98: 'سورة البينة',
    99: 'سورة الزلزلة',
    100: 'سورة العاديات',
    101: 'سورة القارعة',
    102: 'سورة التكاثر',
    103: 'سورة العصر',
    104: 'سورة الهمزة',
    105: 'سورة الفيل',
    106: 'سورة قريش',
    107: 'سورة الماعون',
    108: 'سورة الكوثر',
    109: 'سورة الكافرون',
    110: 'سورة النصر',
    111: 'سورة المسد',
    112: 'سورة الإخلاص',
    113: 'سورة الفلق',
    114: 'سورة الناس',
  };

  /// [populateRamCache]: عطّله عند التسخين الجماعي للقرص حتى لا يُملأ كاش الرام بكل الصفحات.
  Future<List<MushafPageLine>> loadPage(int page,
      {bool populateRamCache = true}) async {
    const mode = 'qpc4';

    if (populateRamCache) {
      final cached = PageCache.instance.get(mode, page);
      if (cached != null && cached.isNotEmpty) return cached;
    }

    final persisted = await PagePersistentCache.instance.get(mode, page);
    if (persisted != null && persisted.isNotEmpty) {
      if (populateRamCache) {
        PageCache.instance.put(mode, page, persisted);
      }
      return persisted;
    }

    await _quranDb.init();
    await QpcGlyphDb.instance.init();

    final layout = await _quranDb.getLayoutForPageV4(page);
    final fontFamily = 'QCF4_tajweed_${page.toString().padLeft(3, '0')}';
    final result = <MushafPageLine>[];

    int minRangeStart = 0;
    int maxRangeEnd = 0;
    for (final row in layout) {
      final rowType = row['type']?.toString().trim().toLowerCase() ?? '';
      if (rowType != 'ayah') continue;
      final rs = _toInt(row['range_start']);
      final re = _toInt(row['range_end']);
      if (rs <= 0 || re < rs) continue;
      if (minRangeStart == 0 || rs < minRangeStart) minRangeStart = rs;
      if (re > maxRangeEnd) maxRangeEnd = re;
    }

    Map<int, String> glyphById = {};
    Map<int, bool> isMarkerById = {};
    if (minRangeStart > 0 && maxRangeEnd >= minRangeStart) {
      final glyphDb = QpcGlyphDb.instance.db;
      List<Map<String, dynamic>> wordRows;
      bool hasMarkerColumn = false;
      try {
        wordRows = await glyphDb.query(
          'words',
          columns: ['id', 'text', 'is_ayah_marker'],
          where: 'id >= ? AND id <= ?',
          whereArgs: [minRangeStart, maxRangeEnd],
          orderBy: 'id ASC',
        );
        hasMarkerColumn = true;
      } catch (_) {
        wordRows = await glyphDb.query(
          'words',
          columns: ['id', 'text'],
          where: 'id >= ? AND id <= ?',
          whereArgs: [minRangeStart, maxRangeEnd],
          orderBy: 'id ASC',
        );
      }
      for (final r in wordRows) {
        final id = _toInt(r['id']);
        final text = r['text']?.toString() ?? '';
        if (text.isNotEmpty) glyphById[id] = text;
        if (hasMarkerColumn) isMarkerById[id] = _toBool(r['is_ayah_marker']);
      }
      if (isMarkerById.isEmpty && glyphById.isNotEmpty) {
        final fromQuranData = await _quranDb.getAyahMarkerByWordNumberAll(
            minRangeStart, maxRangeEnd);
        if (fromQuranData.isNotEmpty) {
          isMarkerById = fromQuranData;
        } else {
          for (final id in glyphById.keys) {
            isMarkerById[id] = false;
          }
        }
      }
    }

    for (final row in layout) {
      final isCentered = _toBool(row['is_centered']);
      final rowType = row['type']?.toString().trim().toLowerCase() ?? '';
      final rangeStart = _toInt(row['range_start']);
      final rangeEnd = _toInt(row['range_end']);

      if (rowType == 'surah_name') {
        final surahTitle = _surahNames[rangeStart] ?? '';
        if (surahTitle.isNotEmpty) {
          result.add(
            MushafPageLine(
              lineText: surahTitle,
              isCentered: true,
              fontFamily: fontFamily,
              lineType: 'surah_name',
              pageNumber: page,
            ),
          );
        }
        continue;
      }

      if (rowType == 'basmallah') {
        const basmallah = 'بِسْمِ اللَّهِ الرَّحْمَٰنِ الرَّحِيمِ';
        result.add(
          MushafPageLine(
            lineText: basmallah,
            isCentered: true,
            fontFamily: 'QuranUthmani',
            lineType: 'basmallah',
            pageNumber: page,
          ),
        );
        continue;
      }

      if (rangeStart <= 0 || rangeEnd < rangeStart) continue;

      final glyphs = <String>[];
      final segments = <AyahSegment>[];
      for (int id = rangeStart; id <= rangeEnd; id++) {
        final t = glyphById[id];
        if (t != null && t.isNotEmpty) {
          glyphs.add(t);
          segments.add((text: t, isMarker: isMarkerById[id] ?? false));
        }
      }
      final lineText = glyphs.join('');
      if (lineText.isEmpty) continue;

      result.add(
        MushafPageLine(
          lineText: lineText,
          isCentered: isCentered,
          fontFamily: fontFamily,
          lineType: 'ayah',
          pageNumber: page,
          ayahSegments: segments.isEmpty ? null : segments,
          rangeStart: rangeStart,
          rangeEnd: rangeEnd,
        ),
      );
    }

    if (populateRamCache) {
      PageCache.instance.put(mode, page, result);
    }
    await PagePersistentCache.instance.put(mode, page, result);
    return result;
  }
}

/// خط ثم كاش الرام أو التخزين الدائم أو التوليد.
Future<List<MushafPageLine>> loadQpcV4PageForDisplay(int page) async {
  await loadQcf4Font(page);
  final ram = PageCache.instance.get('qpc4', page);
  if (ram != null && ram.isNotEmpty) return ram;
  return QpcV4Renderer.instance.loadPage(page);
}

/// نافذة **صفحتان قبل وبعد**: تقليص كاش الرام ثم تعبئته من القرص + تحميل الخطوط (بعد الإطار، أولوية منخفضة).
void preloadNearbyPages(
  int currentPage, {
  int before = PageCache.cacheWindowBefore,
  int after = PageCache.cacheWindowAfter,
}) {
  const totalPages = 604;
  WidgetsBinding.instance.addPostFrameCallback((_) {
    SchedulerBinding.instance.scheduleTask<void>(
      () async {
        PageCache.instance.trimRamToNearbyPages(currentPage);
        await PagePersistentCache.instance.hydrateRamWindow(
          mode: 'qpc4',
          centerPage: currentPage,
          before: before,
          after: after,
          totalPages: totalPages,
        );
        for (var p = currentPage - before; p <= currentPage + after; p++) {
          if (p < 1 || p > totalPages) continue;
          final lines = PageCache.instance.get('qpc4', p);
          if (lines != null && lines.isNotEmpty) {
            int? minR;
            int? maxR;
            for (final line in lines) {
              final rs = line.rangeStart;
              final re = line.rangeEnd;
              if (rs == null || re == null) continue;
              minR = minR == null ? rs : (rs < minR ? rs : minR);
              maxR = maxR == null ? re : (re > maxR ? re : maxR);
            }
            if (minR != null && maxR != null && maxR >= minR) {
              unawaited(QuranDb.instance.prewarmWordToAyahMapping(minR, maxR));
            }
          }
          await loadQcf4Font(p);
          await Future<void>.delayed(const Duration(milliseconds: 8));
        }
      },
      Priority.idle,
      debugLabel: 'preloadNearbyQpc4',
    );
  });
}

class QpcV4PageView extends StatelessWidget {
  const QpcV4PageView({
    super.key,
    required this.page,
    this.hideAyahText = false,
    this.lightweightMode = false,
    this.mediumQualityMode = false,
  });
  final int page;
  final bool hideAyahText;
  final bool lightweightMode;
  final bool mediumQualityMode;
  static const int _v4UniformScaleCacheMaxEntries = 240;
  static final Map<String, double> _v4UniformScaleCache = <String, double>{};
  // Fix 1: نفس كائن Future في كل rebuild — يمنع FutureBuilder من إعادة التحميل
  static final Map<int, Future<List<MushafPageLine>>> _pageLoadFutures =
      <int, Future<List<MushafPageLine>>>{};

  static const TextStyle _baseStyle = TextStyle(
    fontSize: 23,
    height: 1.45,
    letterSpacing: 0,
    wordSpacing: 0,
    fontFeatures: [FontFeature.disable('kern')],
  );

  @override
  Widget build(BuildContext context) {
    final cached = PageCache.instance.get('qpc4', page);
    if (cached != null && cached.isNotEmpty) {
      return buildAfterQcf4FontLoaded(
        page,
        () => _buildPageWithMapping(
          context,
          page,
          cached,
          _baseStyle,
          hideAyahText: hideAyahText,
          lightweightMode: lightweightMode,
          mediumQualityMode: mediumQualityMode,
        ),
        placeholder: (context) => ColoredBox(
          color: MushafPaperBackgroundScope.of(context),
          child: const SizedBox.expand(),
        ),
      );
    }
    return FutureBuilder<List<MushafPageLine>>(
      future: _pageLoadFutures.putIfAbsent(
          page, () => loadQpcV4PageForDisplay(page)),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return ColoredBox(
            color: MushafPaperBackgroundScope.of(context),
            child: const SizedBox.expand(),
          );
        }
        if (snapshot.hasError) {
          debugPrint('QPC V4 page load failed: ${snapshot.error}');
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'تعذّر تحميل الصفحة. أعد المحاولة.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 16),
              ),
            ),
          );
        }
        final pageLines = snapshot.data ?? [];
        if (pageLines.isEmpty) {
          return const Center(child: Text('لا توجد بيانات لهذه الصفحة'));
        }
        return _buildPageWithMapping(
          context,
          page,
          pageLines,
          _baseStyle,
          hideAyahText: hideAyahText,
          lightweightMode: lightweightMode,
          mediumQualityMode: mediumQualityMode,
        );
      },
    );
  }

  static Widget _buildPageWithMapping(
    BuildContext context,
    int page,
    List<MushafPageLine> pageLines,
    TextStyle baseStyle, {
    bool hideAyahText = false,
    bool lightweightMode = false,
    bool mediumQualityMode = false,
  }) {
    int? minR;
    int? maxR;
    for (final line in pageLines) {
      if (line.lineType == 'ayah' &&
          line.rangeStart != null &&
          line.rangeEnd != null) {
        minR = minR == null
            ? line.rangeStart!
            : (line.rangeStart! < minR ? line.rangeStart! : minR);
        maxR = maxR == null
            ? line.rangeEnd!
            : (line.rangeEnd! > maxR ? line.rangeEnd! : maxR);
      }
    }
    if (minR == null || maxR == null) {
      return _buildContent(
        context,
        page,
        pageLines,
        baseStyle,
        null,
        null,
        null,
        null,
        hideAyahText: hideAyahText,
      );
    }
    if (lightweightMode) {
      return _buildContent(
        context,
        page,
        pageLines,
        baseStyle,
        null,
        null,
        null,
        null,
        hideAyahText: hideAyahText,
      );
    }
    if (mediumQualityMode) {
      return _WordToAyahMappingLoader(
        minR: minR,
        maxR: maxR,
        builder: (_, mapSnap) => _buildContent(
          context,
          page,
          pageLines,
          baseStyle,
          mapSnap.data,
          null,
          null,
          null,
          hideAyahText: hideAyahText,
        ),
      );
    }
    return _WordToAyahMappingLoader(
      minR: minR,
      maxR: maxR,
      builder: (_, mapSnap) {
        return _QpcV4PageContentStateful(
          page: page,
          pageLines: pageLines,
          baseStyle: baseStyle,
          mapping: mapSnap.data,
          hideAyahText: hideAyahText,
        );
      },
    );
  }

  static TextStyle _lineStyleFor(MushafPageLine line, TextStyle baseStyle,
      {double fontSizeScale = 1.0}) {
    if (line.lineType == 'surah_name') {
      return baseStyle.copyWith(
          fontFamily: _surahNameFontFamily, fontSize: 22 * fontSizeScale);
    }
    if (line.lineType == 'basmallah') {
      return _basmallahStyle(fontSize: _kBasmallahFontSize * fontSizeScale);
    }
    return baseStyle.copyWith(fontFamily: line.fontFamily);
  }

  /// مقياس واحد لجميع أسطر الآية في الصفحة (مثل أضيق سطر يحتاج تصغيراً) حتى لا يختلف حجم الخط بين السطور بسبب [FittedBox] لكل سطر.
  static double _computeV4UniformAyahScale(
    List<MushafPageLine> displayLines,
    double layoutW,
    double slotHeight,
    TextStyle effectiveBaseStyle,
    double lineStyleFontSizeScale,
  ) {
    final cacheKey =
        '${displayLines.length}|${layoutW.toStringAsFixed(2)}|${slotHeight.toStringAsFixed(2)}|${(effectiveBaseStyle.fontSize ?? 23).toStringAsFixed(4)}|${lineStyleFontSizeScale.toStringAsFixed(4)}';
    final cached = _v4UniformScaleCache[cacheKey];
    if (cached != null) return cached;
    var minScale = 1.0;
    for (final line in displayLines) {
      if (line.lineType != 'ayah') continue;
      final lineStyle = _lineStyleFor(line, effectiveBaseStyle,
          fontSizeScale: lineStyleFontSizeScale);
      final style = line.isCentered
          ? lineStyle
          : getJustifiedLineStyle(line, lineStyle, layoutW);
      final p = TextPainter(
        text: TextSpan(text: line.lineText, style: style),
        textDirection: TextDirection.rtl,
        maxLines: 1,
      )..layout(maxWidth: double.infinity);
      final w = p.width;
      final h = p.height;
      if (w <= 0 || h <= 0) continue;
      final sw = layoutW / w;
      final sh = slotHeight / h;
      final s = min(1.0, min(sw, sh));
      if (s < minScale) minScale = s;
    }
    if (_v4UniformScaleCache.length >= _v4UniformScaleCacheMaxEntries) {
      _v4UniformScaleCache.remove(_v4UniformScaleCache.keys.first);
    }
    _v4UniformScaleCache[cacheKey] = minScale;
    return minScale;
  }

  /// تحديد الآية: قائمة (سطر، بداية، نهاية) لكل سطر يحتوي جزءاً من الآية.
  static Widget _buildContent(
    BuildContext context,
    int page,
    List<MushafPageLine> pageLines,
    TextStyle baseStyle,
    Map<int, (int sura, int ayah)>? mapping,
    List<(int lineIndex, int startChar, int endChar)>? selection,
    void Function(List<(int lineIndex, int startChar, int endChar)>)?
        onSelectLine,
    void Function()? onClearSelection, {
    (int, int, int)? wordSelection,
    List<(int, int, int, Color)>? persistentSelection,
    List<(int lineIndex, int startChar, int endChar)>? temporarySearchSelection,
    double temporarySearchOpacity = 0.0,
    bool hideAyahText = false,
  }) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isCompact = CompactLineSpacingScope.isCompact(context);
        final availableWidth = constraints.maxWidth;
        final availableHeight = constraints.maxHeight;
        final seamlessLongScrollBody =
            SeamlessLongScrollScope.isActive(context);
        final metrics = computeMushafInnerLayoutMetrics(
          maxWidth: availableWidth,
          maxHeight: availableHeight,
          isCompact: isCompact,
          omitVerticalMargins: seamlessLongScrollBody,
        );

        final compactBaseScale =
            isCompact ? getCompactFontScaleFactor(context) : 1.0;
        final prefitBaseStyle = isCompact
            ? baseStyle.copyWith(
                fontSize: (baseStyle.fontSize ?? 23) * compactBaseScale,
              )
            : baseStyle;

        final linePad = CompactLineSpacingScope.linePaddingOf(context);
        final (prefitContentW, _) = getQpcContentDimensions(
          pageLines,
          prefitBaseStyle,
          linePaddingBottom: linePad,
        );
        final availableContentW = metrics.innerWidth;
        final compactFitScale = (isCompact &&
                prefitContentW > 0 &&
                prefitContentW > availableContentW)
            ? (availableContentW / prefitContentW).clamp(0.5, 1.0)
            : 1.0;
        final fontScale = compactBaseScale * compactFitScale;
        final effectiveBaseStyle = isCompact
            ? baseStyle.copyWith(
                fontSize: (baseStyle.fontSize ?? 23) * fontScale,
              )
            : baseStyle;

        // عرض النص = المنطقة الداخلية (هامشان 2% من العرض). عدم استخدام
        // عرض المحتوى الطبيعي الأضيق حتى لا تظهر هوامش جانبية إضافية.
        final contentW = metrics.innerWidth;

        const int slotsCount = kMushafLineSlotCount;
        final displayLines = pageLines.length >= slotsCount
            ? pageLines.sublist(0, slotsCount)
            : pageLines;
        MushafPageLine probeLine = displayLines.first;
        for (final l in displayLines) {
          if (l.lineType == 'ayah') {
            probeLine = l;
            break;
          }
        }
        final slotNatural = metrics.slotHeight;
        var bodyStyle = effectiveBaseStyle;
        var bodyLinePad = linePad;
        late double minSlotH;
        late double layoutHeight;
        late double slotHeight;
        // عند ضيق خانات الـ15 عمودياً كنا نلف المحتوى بـ FittedBox(contain) فينكمش
        // العرض مع الارتفاع. نُنقص الخط والهامش السفلي للسطر بنفس النسبة حتى
        // 15×minSlotH ≤ innerHeight ويبقى العمود بعرض innerWidth بالكامل.
        for (var squeezeIter = 0; squeezeIter < 8; squeezeIter++) {
          final probeStyle = _lineStyleFor(
            probeLine,
            bodyStyle,
            fontSizeScale: isCompact ? fontScale : 1.0,
          );
          minSlotH = mushafMinSlotHeightForAyahStyle(
            ayahStyle: probeStyle,
            linePaddingBottom: bodyLinePad,
          );
          final blockFit = slotNatural + 0.01 < minSlotH;
          layoutHeight =
              blockFit ? kMushafLineSlotCount * minSlotH : metrics.innerHeight;
          slotHeight = blockFit ? minSlotH : slotNatural;
          if (!blockFit || layoutHeight <= metrics.innerHeight + 0.5) {
            break;
          }
          final squeeze = metrics.innerHeight / layoutHeight;
          bodyStyle = bodyStyle.copyWith(
            fontSize: (bodyStyle.fontSize ?? 23) * squeeze,
          );
          bodyLinePad *= squeeze;
        }

        final refBaseSize = effectiveBaseStyle.fontSize ?? 23;
        final lineStyleFontScale = (isCompact ? fontScale : 1.0) *
            ((bodyStyle.fontSize ?? 23) / refBaseSize);

        final uniformAyahScale = _computeV4UniformAyahScale(
          displayLines,
          contentW,
          slotHeight,
          bodyStyle,
          lineStyleFontScale,
        );

        final pageLinesWidgets = pageLines.asMap().entries.map((entry) {
          final lineIndex = entry.key;
          final line = entry.value;
          final baseForLine = line.lineType == 'ayah'
              ? bodyStyle.copyWith(
                  fontSize: (bodyStyle.fontSize ?? 23) * uniformAyahScale,
                )
              : bodyStyle;
          final lineStyle = _lineStyleFor(line, baseForLine,
              fontSizeScale: lineStyleFontScale);
          final justifiedStyle =
              getJustifiedLineStyle(line, lineStyle, contentW);
          final renderedStyle = hideAyahText && line.lineType == 'ayah'
              ? justifiedStyle.copyWith(color: Colors.transparent)
              : justifiedStyle;
          Widget lineWidget;
          if (line.lineType == 'surah_name') {
            final frameHeight = contentW * _surahFrameAspect;
            lineWidget = Padding(
              padding: EdgeInsets.only(bottom: bodyLinePad),
              child: SizedBox(
                width: contentW,
                height: frameHeight,
                child: Stack(
                  fit: StackFit.expand,
                  alignment: Alignment.center,
                  children: [
                    SvgPicture.asset(
                      'assets/icon/sura_name.svg',
                      fit: BoxFit.contain,
                      width: contentW,
                      height: frameHeight,
                    ),
                    Center(
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Padding(
                          padding:
                              EdgeInsets.symmetric(horizontal: contentW * 0.08),
                          child: Text(
                            mushafSurahTitleDisplayText(line.lineText),
                            textDirection: TextDirection.rtl,
                            textAlign: TextAlign.center,
                            maxLines: 1,
                            overflow: TextOverflow.visible,
                            style: renderedStyle,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          } else if (line.lineType == 'basmallah') {
            lineWidget = Padding(
              padding: EdgeInsets.only(bottom: bodyLinePad),
              child: Align(
                alignment: Alignment.center,
                child: SizedBox(
                  width: double.infinity,
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.center,
                    child: Transform.translate(
                      offset: Offset(0, _basmallahRaiseDy * lineStyleFontScale),
                      child: Text(
                        line.lineText,
                        textDirection: TextDirection.rtl,
                        textAlign: TextAlign.center,
                        softWrap: false,
                        maxLines: 1,
                        overflow: TextOverflow.visible,
                        style: lineStyle,
                      ),
                    ),
                  ),
                ),
              ),
            );
          } else {
            final lineW = mushafMeasureLineWidth(line.lineText, justifiedStyle);
            final linePainter = mushafLaidOutRtlLinePainter(
              line.lineText,
              justifiedStyle,
              lineW,
            );
            final lineH = linePainter.height;
            // غلاف ثابت لسطر الآية: نفس هيكل الويدجت سواء وُجد تضليل أم لا،
            // كي لا يقفز السطر للأعلى/الأسفل عند ظهور/اختفاء التضليل
            // (نفس إصلاح مُصيِّر QPC4 الأسود).
            lineWidget = Padding(
              padding: EdgeInsets.only(bottom: bodyLinePad),
              child: Align(
                alignment: Alignment.center,
                child: SizedBox(
                  width: double.infinity,
                  height: lineH,
                  child: Align(
                    alignment: Alignment.topCenter,
                    child: mushafHighlightLineStackFixed(
                      lineWidth: lineW,
                      lineHeight: lineH,
                      lineText: Text(
                        line.lineText,
                        textDirection: TextDirection.rtl,
                        textAlign: line.isCentered
                            ? TextAlign.center
                            : TextAlign.right,
                        softWrap: false,
                        maxLines: 1,
                        overflow: TextOverflow.visible,
                        style: renderedStyle,
                      ),
                      overlayWidgets: const [],
                    ),
                  ),
                ),
              ),
            );
          }
          (int, int, int)? lineSelection;
          final linePersistentSelections = <(int, int, int, Color)>[];
          (int, int, int)? lineTemporarySearch;
          if (selection != null) {
            for (final e in selection) {
              if (e.$1 == lineIndex) {
                lineSelection = e;
                break;
              }
            }
          }
          if (temporarySearchSelection != null) {
            for (final e in temporarySearchSelection) {
              if (e.$1 == lineIndex) {
                lineTemporarySearch = e;
                break;
              }
            }
          }
          if (persistentSelection != null) {
            for (final e in persistentSelection) {
              if (e.$1 == lineIndex) linePersistentSelections.add(e);
            }
          }
          (int, int, int)? lineWordSelection;
          if (wordSelection != null && wordSelection.$1 == lineIndex) {
            lineWordSelection = wordSelection;
          }
          if (lineSelection != null &&
              line.lineType == 'ayah' &&
              lineSelection.$2 >= 0 &&
              lineSelection.$3 > lineSelection.$2) {
            final lineWidth =
                mushafMeasureLineWidth(line.lineText, justifiedStyle);
            final painter = mushafLaidOutRtlLinePainter(
                line.lineText, justifiedStyle, lineWidth);
            final ayahR = mushafRangeHorizontalRectWithFallback(
              painter: painter,
              text: line.lineText,
              style: justifiedStyle,
              startChar: lineSelection.$2.clamp(0, line.lineText.length),
              endChar: lineSelection.$3.clamp(0, line.lineText.length),
            );
            final overlayWidgets = <Widget>[];
            if (linePersistentSelections.isNotEmpty) {
              final persistentRects =
                  <({double left, double width, Color color})>[];
              for (final h in linePersistentSelections) {
                final rect = mushafWordHighlightRect(
                  painter: painter,
                  text: line.lineText,
                  style: justifiedStyle,
                  startChar: h.$2.clamp(0, line.lineText.length),
                  endChar: h.$3.clamp(0, line.lineText.length),
                );
                if (rect != null && rect.width > 0.01) {
                  persistentRects
                      .add((left: rect.left, width: rect.width, color: h.$4));
                }
              }
              for (final r in _mergePersistentRectsByColor(persistentRects)) {
                overlayWidgets
                    .add(_buildPersistentHighlightSegment(r, painter.height));
              }
            }
            overlayWidgets.add(
              mushafFlatHighlightBar(
                left: ayahR.left,
                width: ayahR.width,
                lineHeight: painter.height,
                color: const Color.fromARGB(255, 45, 45, 45),
                alpha: 0.18,
              ),
            );
            appendTemporarySearchHighlightBar(
              overlayWidgets,
              painter: painter,
              line: line,
              style: justifiedStyle,
              lineTemporarySearch: lineTemporarySearch,
              temporarySearchOpacity: temporarySearchOpacity,
            );
            if (lineWordSelection != null &&
                lineWordSelection.$2 >= 0 &&
                lineWordSelection.$3 > lineWordSelection.$2) {
              final wordR = mushafRangeHorizontalRectWithFallback(
                painter: painter,
                text: line.lineText,
                style: justifiedStyle,
                startChar: lineWordSelection.$2.clamp(0, line.lineText.length),
                endChar: lineWordSelection.$3.clamp(0, line.lineText.length),
              );
              if (wordR.width > 0.01) {
                overlayWidgets.add(mushafFlatHighlightBar(
                  left: wordR.left,
                  width: wordR.width,
                  lineHeight: painter.height,
                  color: const Color(0xFFB8E6C1),
                  alpha: 0.3,
                ));
              }
            }
            return Padding(
              padding: EdgeInsets.only(bottom: bodyLinePad),
              child: Align(
                alignment: Alignment.center,
                child: SizedBox(
                  width: double.infinity,
                  height: painter.height,
                  child: Align(
                    alignment: Alignment.topCenter,
                    child: mushafHighlightLineStackFixed(
                      lineWidth: lineWidth,
                      lineHeight: painter.height,
                      lineText: Text(
                        line.lineText,
                        textDirection: TextDirection.rtl,
                        textAlign: line.isCentered
                            ? TextAlign.center
                            : TextAlign.right,
                        softWrap: false,
                        maxLines: 1,
                        overflow: TextOverflow.visible,
                        style: renderedStyle,
                      ),
                      overlayWidgets: overlayWidgets,
                    ),
                  ),
                ),
              ),
            );
          }
          if (lineSelection == null &&
              linePersistentSelections.isNotEmpty &&
              line.lineType == 'ayah') {
            final lineWidth =
                mushafMeasureLineWidth(line.lineText, justifiedStyle);
            final painter = mushafLaidOutRtlLinePainter(
                line.lineText, justifiedStyle, lineWidth);
            final rects = <({double left, double width, Color color})>[];
            for (final h in linePersistentSelections) {
              final rect = mushafWordHighlightRect(
                painter: painter,
                text: line.lineText,
                style: justifiedStyle,
                startChar: h.$2.clamp(0, line.lineText.length),
                endChar: h.$3.clamp(0, line.lineText.length),
              );
              if (rect != null && rect.width > 0.01) {
                rects.add((left: rect.left, width: rect.width, color: h.$4));
              }
            }
            if (rects.isEmpty) return lineWidget;
            final mergedRects = _mergePersistentRectsByColor(rects);
            final tempOverlayWidgets = <Widget>[
              for (final r in mergedRects)
                _buildPersistentHighlightSegment(r, painter.height),
            ];
            appendTemporarySearchHighlightBar(
              tempOverlayWidgets,
              painter: painter,
              line: line,
              style: justifiedStyle,
              lineTemporarySearch: lineTemporarySearch,
              temporarySearchOpacity: temporarySearchOpacity,
            );
            return Padding(
              padding: EdgeInsets.only(bottom: bodyLinePad),
              child: Align(
                alignment: Alignment.center,
                child: SizedBox(
                  width: double.infinity,
                  height: painter.height,
                  child: Align(
                    alignment: Alignment.topCenter,
                    child: mushafHighlightLineStackFixed(
                      lineWidth: lineWidth,
                      lineHeight: painter.height,
                      lineText: Text(
                        line.lineText,
                        textDirection: TextDirection.rtl,
                        textAlign: line.isCentered
                            ? TextAlign.center
                            : TextAlign.right,
                        softWrap: false,
                        maxLines: 1,
                        overflow: TextOverflow.visible,
                        style: renderedStyle,
                      ),
                      overlayWidgets: tempOverlayWidgets,
                    ),
                  ),
                ),
              ),
            );
          }
          if (lineTemporarySearch != null &&
              line.lineType == 'ayah' &&
              temporarySearchOpacity > 0.001 &&
              lineTemporarySearch.$2 >= 0 &&
              lineTemporarySearch.$3 > lineTemporarySearch.$2) {
            final lineWidth =
                mushafMeasureLineWidth(line.lineText, justifiedStyle);
            final painter = mushafLaidOutRtlLinePainter(
                line.lineText, justifiedStyle, lineWidth);
            final tempOverlayWidgets = <Widget>[];
            appendTemporarySearchHighlightBar(
              tempOverlayWidgets,
              painter: painter,
              line: line,
              style: justifiedStyle,
              lineTemporarySearch: lineTemporarySearch,
              temporarySearchOpacity: temporarySearchOpacity,
            );
            if (tempOverlayWidgets.isNotEmpty) {
              return Padding(
                padding: EdgeInsets.only(bottom: bodyLinePad),
                child: Align(
                  alignment: Alignment.center,
                  child: SizedBox(
                    width: double.infinity,
                    height: painter.height,
                    child: Align(
                      alignment: Alignment.topCenter,
                      child: mushafHighlightLineStackFixed(
                        lineWidth: lineWidth,
                        lineHeight: painter.height,
                        lineText: Text(
                          line.lineText,
                          textDirection: TextDirection.rtl,
                          textAlign: line.isCentered
                              ? TextAlign.center
                              : TextAlign.right,
                          softWrap: false,
                          maxLines: 1,
                          overflow: TextOverflow.visible,
                          style: renderedStyle,
                        ),
                        overlayWidgets: tempOverlayWidgets,
                      ),
                    ),
                  ),
                ),
              );
            }
          }
          // عند إخفاء تضليل الآية أثناء الاستماع، نبقي تضليل الكلمة المقروءة فقط.
          if (lineWordSelection != null &&
              line.lineType == 'ayah' &&
              lineWordSelection.$2 >= 0 &&
              lineWordSelection.$3 > lineWordSelection.$2) {
            final lineWidth =
                mushafMeasureLineWidth(line.lineText, justifiedStyle);
            final painter = mushafLaidOutRtlLinePainter(
                line.lineText, justifiedStyle, lineWidth);
            final wordR = mushafRangeHorizontalRectWithFallback(
              painter: painter,
              text: line.lineText,
              style: justifiedStyle,
              startChar: lineWordSelection.$2.clamp(0, line.lineText.length),
              endChar: lineWordSelection.$3.clamp(0, line.lineText.length),
            );
            if (wordR.width <= 0.01) return lineWidget;
            return Padding(
              padding: EdgeInsets.only(bottom: bodyLinePad),
              child: Align(
                alignment: Alignment.center,
                child: SizedBox(
                  width: double.infinity,
                  height: painter.height,
                  child: Align(
                    alignment: Alignment.topCenter,
                    child: mushafHighlightLineStackFixed(
                      lineWidth: lineWidth,
                      lineHeight: painter.height,
                      lineText: Text(
                        line.lineText,
                        textDirection: TextDirection.rtl,
                        textAlign: line.isCentered
                            ? TextAlign.center
                            : TextAlign.right,
                        softWrap: false,
                        maxLines: 1,
                        overflow: TextOverflow.visible,
                        style: renderedStyle,
                      ),
                      overlayWidgets: [
                        mushafFlatHighlightBar(
                          left: wordR.left,
                          width: wordR.width,
                          lineHeight: painter.height,
                          color: const Color.fromARGB(255, 45, 45, 45),
                          alpha: 0.18,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          }
          return lineWidget;
        }).toList();

        // منطق 15 خانة: المسافة بين الشريط العلوي ورقم الصفحة تُقسم على 15 سطراً.
        final slots = <Widget>[];
        for (int i = 0; i < slotsCount; i++) {
          Widget lineChild = const SizedBox.shrink();
          // في الصفحتين 1 و 2 نترك أول 3 خانات فارغة، فيبدأ أول سطر من الخانة الرابعة.
          final srcIndex = (page == 1 || page == 2) ? i - 3 : i;
          if (srcIndex >= 0 &&
              srcIndex < displayLines.length &&
              srcIndex < pageLinesWidgets.length) {
            lineChild = pageLinesWidgets[srcIndex];
          }
          slots.add(
            SizedBox(
              height: slotHeight,
              child: Align(
                alignment: Alignment.topCenter,
                child: lineChild,
              ),
            ),
          );
        }

        final column15 = Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: slots,
        );

        final lineHeights15 =
            List<double>.filled(slotsCount, slotHeight, growable: false);

        // عمود النص بعرض المنطقة الداخلية بالكامل (بعد هوامش 2%).
        final availableW = metrics.innerWidth;
        final pageWidth = availableW;

        Widget buildMushafColumnBox() {
          return SizedBox(
            width: pageWidth,
            height: layoutHeight,
            child: mapping != null
                ? DelayedLongPressDetector(
                    duration: const Duration(milliseconds: 400),
                    onTrigger: (Offset pos) {
                      _onPageLongPress(
                        context,
                        pos,
                        contentW,
                        layoutHeight,
                        lineHeights15,
                        displayLines,
                        bodyStyle,
                        mapping,
                        (line, style) => _lineStyleFor(line, style,
                            fontSizeScale: lineStyleFontScale),
                        onSelectLine: onSelectLine,
                        onClearSelection: onClearSelection,
                        lineTextHorizontallyCentered: true,
                        uniformAyahScale: uniformAyahScale,
                        hitTestColumnWidth: pageWidth,
                        visualLineIndexOffset: (page == 1 || page == 2) ? 3 : 0,
                      );
                    },
                    child: column15,
                  )
                : column15,
          );
        }

        final columnAlign =
            seamlessLongScrollBody ? Alignment.topCenter : Alignment.center;
        final repaintChild = SizedBox(
          width: metrics.innerWidth,
          height: metrics.innerHeight,
          child: Align(
            alignment: columnAlign,
            child: buildMushafColumnBox(),
          ),
        );

        return SingleChildScrollView(
          primary: false,
          physics: const NeverScrollableScrollPhysics(),
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: Padding(
              padding: EdgeInsets.only(
                left: metrics.leftMargin,
                right: metrics.rightMargin,
                top: metrics.topMargin,
                bottom: metrics.bottomMargin,
              ),
              child: Align(
                alignment: columnAlign,
                child: RepaintBoundary(
                  child: ColoredBox(
                    color: MushafPaperBackgroundScope.of(context),
                    child: repaintChild,
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  static void _onPageLongPress(
    BuildContext context,
    Offset localPosition,
    double contentW,
    double contentH,
    List<double> lineHeights,
    List<MushafPageLine> pageLines,
    TextStyle baseStyle,
    Map<int, (int sura, int ayah)> mapping,
    TextStyle Function(MushafPageLine, TextStyle) lineStyleFor, {
    void Function(List<(int lineIndex, int startChar, int endChar)>)?
        onSelectLine,
    void Function()? onClearSelection,
    bool lineTextHorizontallyCentered = false,
    double uniformAyahScale = 1.0,
    double? hitTestColumnWidth,
    int visualLineIndexOffset = 0,
  }) {
    onQpcPageLongPress(context, localPosition, contentW, contentH, lineHeights,
        pageLines, baseStyle, mapping, lineStyleFor,
        onSelectLine: onSelectLine,
        onClearSelection: onClearSelection,
        lineTextHorizontallyCentered: lineTextHorizontallyCentered,
        uniformAyahScale: uniformAyahScale,
        hitTestColumnWidth: hitTestColumnWidth,
        visualLineIndexOffset: visualLineIndexOffset);
  }
}

/// يطلق الـ callback بعد مدة ضغط (مثلاً 1.5 ثانية) دون الحاجة لرفع الإصبع.
class DelayedLongPressDetector extends StatefulWidget {
  const DelayedLongPressDetector({
    required this.duration,
    required this.onTrigger,
    required this.child,
  });
  final Duration duration;
  final void Function(Offset localPosition) onTrigger;
  final Widget child;

  @override
  State<DelayedLongPressDetector> createState() =>
      DelayedLongPressDetectorState();
}

class DelayedLongPressDetectorState extends State<DelayedLongPressDetector> {
  Timer? _timer;
  Offset? _position;

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (TapDownDetails d) {
        _position = d.localPosition;
        _timer?.cancel();
        _timer = Timer(widget.duration, () {
          if (!mounted || _position == null) return;
          widget.onTrigger(_position!);
          _timer?.cancel();
          _position = null;
        });
      },
      onTapUp: (_) {
        _timer?.cancel();
        _position = null;
      },
      onTapCancel: () {
        _timer?.cancel();
        _position = null;
      },
      child: widget.child,
    );
  }
}

class _WordToAyahMappingLoader extends StatefulWidget {
  const _WordToAyahMappingLoader({
    required this.minR,
    required this.maxR,
    required this.builder,
  });

  final int minR;
  final int maxR;
  final Widget Function(
    BuildContext context,
    AsyncSnapshot<Map<int, (int, int)>> snapshot,
  ) builder;

  @override
  State<_WordToAyahMappingLoader> createState() =>
      _WordToAyahMappingLoaderState();
}

class _WordToAyahMappingLoaderState extends State<_WordToAyahMappingLoader> {
  late Future<Map<int, (int, int)>> _mappingFuture;

  @override
  void initState() {
    super.initState();
    _mappingFuture =
        QuranDb.instance.getWordToAyahMapping(widget.minR, widget.maxR);
  }

  @override
  void didUpdateWidget(covariant _WordToAyahMappingLoader oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.minR != widget.minR || oldWidget.maxR != widget.maxR) {
      _mappingFuture =
          QuranDb.instance.getWordToAyahMapping(widget.minR, widget.maxR);
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Map<int, (int, int)>>(
      future: _mappingFuture,
      builder: widget.builder,
    );
  }
}

class _QpcV4PageContentStateful extends StatefulWidget {
  const _QpcV4PageContentStateful({
    required this.page,
    required this.pageLines,
    required this.baseStyle,
    required this.mapping,
    this.hideAyahText = false,
  });
  final int page;
  final List<MushafPageLine> pageLines;
  final TextStyle baseStyle;
  final Map<int, (int sura, int ayah)>? mapping;
  final bool hideAyahText;

  @override
  State<_QpcV4PageContentStateful> createState() =>
      _QpcV4PageContentStatefulState();
}

class _QpcV4PageContentStatefulState extends State<_QpcV4PageContentStateful> {
  List<(int, int, int)>? _selection; // تحديد الضغط الطويل (يدوي)
  List<(int, int, int)>? _audioSelection; // تضليل الآية أثناء الاستماع
  (int, int, int)? _wordSelection;
  List<(int, int, int, Color)>? _persistentSelection;
  List<(int, int, int)>? _temporarySearchSelection;
  double _temporarySearchOpacity = 0.0;

  @override
  void initState() {
    super.initState();
    AyahAudioPlayer.instance.addListener(_syncAudioHighlight);
    AyahHighlightStore.instance.addListener(_syncPersistentHighlights);
    TemporarySearchAyahHighlightStore.instance
        .addListener(_syncTemporarySearchHighlight);
    _syncAudioHighlight();
    _syncPersistentHighlights();
    _syncTemporarySearchHighlight();
  }

  @override
  void didUpdateWidget(covariant _QpcV4PageContentStateful oldWidget) {
    super.didUpdateWidget(oldWidget);
    // أعد الحساب فقط عند تغيّر المابينغ أو قائمة الأسطر
    if (!identical(oldWidget.mapping, widget.mapping) ||
        !identical(oldWidget.pageLines, widget.pageLines)) {
      _syncAudioHighlight();
      _syncPersistentHighlights();
    }
  }

  @override
  void dispose() {
    AyahAudioPlayer.instance.removeListener(_syncAudioHighlight);
    AyahHighlightStore.instance.removeListener(_syncPersistentHighlights);
    TemporarySearchAyahHighlightStore.instance
        .removeListener(_syncTemporarySearchHighlight);
    super.dispose();
  }

  void _syncTemporarySearchHighlight() {
    final store = TemporarySearchAyahHighlightStore.instance;
    final mapping = widget.mapping;
    if (!store.matchesPage(widget.page) || mapping == null) {
      if (_temporarySearchSelection != null || _temporarySearchOpacity != 0.0) {
        setState(() {
          _temporarySearchSelection = null;
          _temporarySearchOpacity = 0.0;
        });
      }
      return;
    }
    final ranges = _getAyahRangesAcrossLines(
      store.sura!,
      store.ayah!,
      widget.pageLines,
      mapping,
    );
    final nextOpacity = store.opacity;
    if (_sameSelectionRanges(_temporarySearchSelection, ranges) &&
        (_temporarySearchOpacity - nextOpacity).abs() < 0.001) {
      return;
    }
    setState(() {
      _temporarySearchSelection = ranges.isEmpty ? null : ranges;
      _temporarySearchOpacity = nextOpacity;
    });
  }

  void _syncPersistentHighlights() {
    final mapping = widget.mapping;
    if (mapping == null || AyahHighlightStore.instance.ranges.isEmpty) {
      if (_persistentSelection != null) {
        setState(() => _persistentSelection = null);
      }
      return;
    }
    final entries = <(int, int, int, Color)>[];
    for (final range in AyahHighlightStore.instance.ranges) {
      final from =
          range.fromAyah <= range.toAyah ? range.fromAyah : range.toAyah;
      final to = range.fromAyah <= range.toAyah ? range.toAyah : range.fromAyah;
      for (int ayah = from; ayah <= to; ayah++) {
        final r = _getAyahRangesAcrossLines(
          range.sura,
          ayah,
          widget.pageLines,
          mapping,
        );
        for (final e in r) {
          entries.add((e.$1, e.$2, e.$3, range.color));
        }
      }
    }
    if (entries.isEmpty) {
      if (_persistentSelection != null) {
        setState(() => _persistentSelection = null);
      }
      return;
    }
    if (_samePersistentEntries(_persistentSelection, entries)) return;
    setState(() => _persistentSelection = entries);
  }

  void _syncAudioHighlight() {
    final player = AyahAudioPlayer.instance;
    final mapping = widget.mapping;
    final s = player.currentSura;
    final a = player.currentAyah;
    if (mapping == null || s == null || a == null || !player.isActive) {
      if (_audioSelection != null || _wordSelection != null) {
        setState(() {
          _audioSelection = null;
          _wordSelection = null;
        });
      }
      return;
    }
    final ranges = getAyahRangesForPage(s, a, widget.pageLines, mapping);
    final wordRange = getAyahWordRangeForPage(
      s,
      a,
      player.currentSegmentIndex,
      player.currentSegmentToken,
      widget.pageLines,
      mapping,
    );
    if (_sameSelectionRanges(_audioSelection, ranges) &&
        _wordSelection == wordRange) {
      return;
    }
    setState(() {
      _audioSelection = ranges.isEmpty ? null : ranges;
      _wordSelection = wordRange;
    });
  }

  @override
  Widget build(BuildContext context) {
    final player = AyahAudioPlayer.instance;
    final selectionForAyahHighlight =
        _selection ?? (player.showAyahHighlight ? _audioSelection : null);
    return QpcV4PageView._buildContent(
      context,
      widget.page,
      widget.pageLines,
      widget.baseStyle,
      widget.mapping,
      selectionForAyahHighlight,
      (List<(int, int, int)> ranges) => setState(() => _selection = ranges),
      () => setState(() => _selection = null),
      wordSelection: _wordSelection,
      persistentSelection: _persistentSelection,
      temporarySearchSelection: _temporarySearchSelection,
      temporarySearchOpacity: _temporarySearchOpacity,
      hideAyahText: widget.hideAyahText,
    );
  }
}

bool _sameSelectionRanges(
  List<(int, int, int)>? a,
  List<(int, int, int)>? b,
) {
  final aa = a ?? const <(int, int, int)>[];
  final bb = b ?? const <(int, int, int)>[];
  if (aa.length != bb.length) return false;
  for (int i = 0; i < aa.length; i++) {
    if (aa[i] != bb[i]) return false;
  }
  return true;
}

bool _samePersistentEntries(
  List<(int, int, int, Color)>? a,
  List<(int, int, int, Color)>? b,
) {
  final aa = a ?? const <(int, int, int, Color)>[];
  final bb = b ?? const <(int, int, int, Color)>[];
  if (aa.length != bb.length) return false;
  for (int i = 0; i < aa.length; i++) {
    if (aa[i].$1 != bb[i].$1 ||
        aa[i].$2 != bb[i].$2 ||
        aa[i].$3 != bb[i].$3 ||
        aa[i].$4.toARGB32() != bb[i].$4.toARGB32()) return false;
  }
  return true;
}

List<(int lineIndex, int startChar, int endChar)> getAyahRangesForPage(
  int sura,
  int ayah,
  List<MushafPageLine> pageLines,
  Map<int, (int sura, int ayah)> mapping,
) {
  return _getAyahRangesAcrossLines(sura, ayah, pageLines, mapping);
}

(int lineIndex, int startChar, int endChar)? getAyahWordRangeForPage(
  int sura,
  int ayah,
  int segmentIndex,
  int? segmentToken,
  List<MushafPageLine> pageLines,
  Map<int, (int sura, int ayah)> mapping,
) {
  // بعض محركات الصوت قد تعطي segmentIndex = -1 لحظيًا عند الانتقال بين الكلمات،
  // بينما يكون segmentToken ما زال صالحًا. لا نُسقط التحديد مباشرة في هذه الحالة.
  if (segmentIndex < 0 && (segmentToken == null || segmentToken <= 0)) {
    return null;
  }
  final words = <(int, int, int)>[];
  final suraAyah = (sura, ayah);
  for (int lineIndex = 0; lineIndex < pageLines.length; lineIndex++) {
    final line = pageLines[lineIndex];
    if (line.lineType != 'ayah' ||
        line.rangeStart == null ||
        line.rangeEnd == null ||
        line.ayahSegments == null ||
        line.ayahSegments!.isEmpty) {
      continue;
    }
    int sum = 0;
    for (int i = 0; i < line.ayahSegments!.length; i++) {
      final seg = line.ayahSegments![i];
      final startChar = sum;
      sum += seg.text.length;
      final endChar = sum;
      final wordId = line.rangeStart! + i;
      if (mapping[wordId] == suraAyah && !seg.isMarker && endChar > startChar) {
        words.add((lineIndex, startChar, endChar));
      }
    }
  }
  if (words.isEmpty) return null;
  if (segmentToken != null && segmentToken > 0) {
    final tokenIdx = segmentToken - 1;
    if (tokenIdx >= 0 && tokenIdx < words.length) return words[tokenIdx];
  }
  if (segmentIndex < 0) return words.last;
  final idx = segmentIndex.clamp(0, words.length - 1);
  return words[idx];
}

/// يُرجع قائمة (رقم السطر، بداية نطاق الآية، نهاية نطاق الآية) لجميع الأسطر التي تحتوي أي جزء من الآية.
List<(int lineIndex, int startChar, int endChar)> _getAyahRangesAcrossLines(
  int sura,
  int ayah,
  List<MushafPageLine> pageLines,
  Map<int, (int sura, int ayah)> mapping,
) {
  final suraAyah = (sura, ayah);
  final ranges = <(int, int, int)>[];
  for (int lineIndex = 0; lineIndex < pageLines.length; lineIndex++) {
    final line = pageLines[lineIndex];
    if (line.lineType != 'ayah' ||
        line.rangeStart == null ||
        line.rangeEnd == null) continue;
    final segments = line.ayahSegments;
    if (segments == null || segments.isEmpty) continue;
    int firstWord = -1;
    int lastWord = -1;
    for (int i = 0; i < segments.length; i++) {
      final wordId = line.rangeStart! + i;
      if (mapping[wordId] == suraAyah) {
        if (firstWord < 0) firstWord = i;
        lastWord = i;
      }
    }
    if (firstWord < 0 || lastWord < 0) continue;
    int sum = 0;
    for (int i = 0; i < firstWord; i++) sum += segments[i].text.length;
    final startChar = sum;
    for (int i = firstWord; i <= lastWord; i++) sum += segments[i].text.length;
    final endChar = sum;
    ranges.add((lineIndex, startChar, endChar));
  }
  return ranges;
}

/// استدعاء من قارئ V4 أو V4 أسود عند الضغط المطول — يحدد الآية على كل الأسطر (تحديد بصري) ويعرض خيار نسخ الآية.
void onQpcPageLongPress(
  BuildContext context,
  Offset localPosition,
  double contentW,
  double contentH,
  List<double> lineHeights,
  List<MushafPageLine> pageLines,
  TextStyle baseStyle,
  Map<int, (int sura, int ayah)> mapping,
  TextStyle Function(MushafPageLine, TextStyle) lineStyleFor, {
  void Function(List<(int lineIndex, int startChar, int endChar)>)?
      onSelectLine,
  void Function()? onClearSelection,

  /// سطر بعرض أضيق من العمود ويُوسَّط أفقياً (نادر). QPC1 عادة false لأن الآية بعرض العمود مع تبرير/يمين.
  bool lineTextHorizontallyCentered = false,

  /// QPC1: أسطر الآية بعرض العمود كاملاً مع تبرير — يجب أن يطابق [TextPainter.layout] عرض العمود وليس العرض الطبيعي للنص.
  bool hitTestLayoutFullColumnWidth = false,

  /// نفس [uniformAyahScale] المستخدم في بناء أسطر الآية (وإلا يختلف عرض الحروف عن الرسم).
  double uniformAyahScale = 1.0,

  /// عرض العمود الفعلي لحساب يمين/وسط السطر؛ إن كان null يُستخدم [contentW].
  double? hitTestColumnWidth,

  /// عدد الخانات الفارغة في أعلى العمود قبل أول سطر بيانات (مثال: 3 في الصفحة 1 و2).
  int visualLineIndexOffset = 0,

  /// مقياس النص المستخدم في القياس أثناء hit-test. إن كان null يُستخدم MediaQuery.
  TextScaler? hitTestTextScaler,

  /// سماحية التقاط السطر عموديًا (كلما صغرت زادت الدقة قرب حدود السطر).
  double lineHitTestYTolerance = 6.0,
}) async {
  if (lineHeights.isEmpty || pageLines.isEmpty) return;
  if (!context.mounted) return;
  final columnW = hitTestColumnWidth ?? contentW;
  final media = MediaQuery.maybeOf(context);
  final textScaler =
      hitTestTextScaler ?? media?.textScaler ?? TextScaler.noScaling;
  final locale = Localizations.maybeLocaleOf(context);
  // هامش تسامح عمودي: حدود التحديد قد تختلف قليلاً عن ترتيب العرض (خانات vs محتوى).
  final yTolerance = lineHitTestYTolerance < 0 ? 0.0 : lineHitTestYTolerance;
  double cum = 0;
  int lineIndex = -1;
  for (int i = 0; i < lineHeights.length; i++) {
    final lineTop = i == 0 ? 0.0 : cum - yTolerance;
    final lineBottom =
        cum + lineHeights[i] + (i < lineHeights.length - 1 ? yTolerance : 0.0);
    if (localPosition.dy >= lineTop && localPosition.dy < lineBottom) {
      lineIndex = i;
      break;
    }
    cum += lineHeights[i];
  }
  final dataLineIndex = lineIndex - visualLineIndexOffset;
  if (dataLineIndex < 0 || dataLineIndex >= pageLines.length) return;
  final line = pageLines[dataLineIndex];
  if (line.lineType != 'ayah' ||
      line.rangeStart == null ||
      line.rangeEnd == null) return;

  final hitBaseStyle = baseStyle.copyWith(
    fontSize: (baseStyle.fontSize ?? 23) * uniformAyahScale,
  );
  final lineStyle = lineStyleFor(line, hitBaseStyle);

  // التبرير بـcontentW كما في الرسم (getJustifiedLineStyle في بناء السطر).
  final justifiedStyle = getJustifiedLineStyle(line, lineStyle, contentW);

  // عرض السطر بعد التبرير — بنفس textScaler/locale حتى يطابق ويدجت [Text].
  late final double tapXInText;
  late final TextPainter painter;

  if (hitTestLayoutFullColumnWidth) {
    final centered = lineTextHorizontallyCentered || line.isCentered;
    final measurePainter = TextPainter(
      text: TextSpan(text: line.lineText, style: justifiedStyle),
      textDirection: TextDirection.rtl,
      maxLines: 1,
      textScaler: textScaler,
      locale: locale,
    )..layout(maxWidth: columnW);
    final measuredW = measurePainter.width;
    if (measuredW <= 0) return;
    final lineLeft =
        centered ? (columnW - measuredW) / 2.0 : (columnW - measuredW);
    final xTolerance = (columnW * 0.02).clamp(4.0, 18.0);
    if (localPosition.dx < lineLeft - xTolerance ||
        localPosition.dx > lineLeft + measuredW + xTolerance) {
      return;
    }
    tapXInText = (localPosition.dx - lineLeft).clamp(0.0, measuredW).toDouble();
    painter = TextPainter(
      text: TextSpan(text: line.lineText, style: justifiedStyle),
      textDirection: TextDirection.rtl,
      maxLines: 1,
      textScaler: textScaler,
      locale: locale,
    )..layout(maxWidth: measuredW);
  } else {
    final centered = lineTextHorizontallyCentered || line.isCentered;
    final measurePainter = TextPainter(
      text: TextSpan(text: line.lineText, style: justifiedStyle),
      textDirection: TextDirection.rtl,
      maxLines: 1,
      textScaler: textScaler,
      locale: locale,
    )..layout(maxWidth: double.infinity);
    final measuredW = measurePainter.width;
    if (measuredW <= 0) return;

    final lineLeft =
        centered ? (columnW - measuredW) / 2.0 : columnW - measuredW;

    final xTolerance = (measuredW * 0.06).clamp(4.0, 22.0);
    if (localPosition.dx < lineLeft - xTolerance ||
        localPosition.dx > lineLeft + measuredW + xTolerance) {
      return;
    }
    tapXInText = (localPosition.dx - lineLeft).clamp(0.0, measuredW).toDouble();

    painter = TextPainter(
      text: TextSpan(text: line.lineText, style: justifiedStyle),
      textDirection: TextDirection.rtl,
      maxLines: 1,
      textScaler: textScaler,
      locale: locale,
    )..layout(maxWidth: measuredW);
  }

  final dy = painter.height > 0 ? painter.height * 0.5 : 0.0;
  final position = painter.getPositionForOffset(Offset(tapXInText, dy));
  final charOffset = position.offset.clamp(0, line.lineText.length);

  int wordIndex = 0;
  final segments = line.ayahSegments;
  if (segments != null && segments.isNotEmpty) {
    int sum = 0;
    bool found = false;
    for (int i = 0; i < segments.length; i++) {
      if (charOffset < sum + segments[i].text.length) {
        wordIndex = i;
        found = true;
        break;
      }
      sum += segments[i].text.length;
    }
    if (!found) wordIndex = segments.length - 1;
  }

  final wordId = line.rangeStart! + wordIndex;
  final suraAyah = mapping[wordId];
  if (suraAyah == null) return;

  final (sura, ayah) = suraAyah;
  final ranges = _getAyahRangesAcrossLines(sura, ayah, pageLines, mapping);
  onSelectLine?.call(ranges);

  final ayahText = await QuranDb.instance.getAyahTextUthmani(sura, ayah);
  if (ayahText.isEmpty) return;

  if (!context.mounted) return;
  final scope = AyahLongPressScope.maybeOf(context);
  if (scope != null) {
    scope.onAyahLongPress(
        context, sura, ayah, ayahText, onClearSelection ?? () {});
    return;
  }
  // عدم عرض قائمة قديمة (نسخ فقط) — جميع أوضاع العرض تستخدم AyahLongPressScope
  onClearSelection?.call();
}
