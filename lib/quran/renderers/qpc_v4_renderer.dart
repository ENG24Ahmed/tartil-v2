import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:quran_app/audio/ayah_audio_player.dart';
import 'package:quran_app/quran/ayah_long_press_scope.dart';
import 'package:quran_app/quran/font_loader.dart';
import 'package:quran_app/quran/models/baked_page_layout.dart';
import 'package:quran_app/quran/models/mushaf_line.dart';
import 'package:quran_app/quran/page_cache.dart';
import 'package:quran_app/quran/page_persistent_cache.dart';
import 'package:quran_app/quran/quran_db.dart';
import 'package:quran_app/quran/compact_line_spacing_scope.dart';
import 'package:quran_app/services/qpc_glyph_db.dart';

/// هامش من كل طرف (2%) — يستخدمه V4 و V4 أسود و V1.
const double kQpcPageMarginFraction = 0.02;

/// هامش اليسار في V4 (2% مثل باقي الهوامش).
const double kQpcPageMarginLeftFraction = 0.02;

/// نسبة ارتفاع إطار اسم السورة إلى عرضه (من viewBox sura_name.svg: 1621.5×171).
const double _surahFrameAspect = 171 / 1621.5;
const String _surahNameFontFamily = 'SurahNameV4';
const double _basmallahRaiseDy = -2.0;
const String _basmallahFontFamily = 'KFGQPCHAFSUthmanicScript';
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

(double, double) getQpcContentDimensions(
    List<MushafPageLine> pageLines, TextStyle baseStyle,
    {double linePaddingBottom = kNormalLinePaddingBottom}) {
  double maxW = 0;
  double totalH = 0;
  for (final line in pageLines) {
    TextStyle s = baseStyle.copyWith(fontFamily: line.fontFamily);
    if (line.lineType == 'surah_name')
      s = baseStyle.copyWith(fontFamily: _surahNameFontFamily, fontSize: 22);
    if (line.lineType == 'basmallah') s = _basmallahStyle(fontSize: 22);
    final painter = TextPainter(
      text: TextSpan(text: line.lineText, style: s),
      textDirection: TextDirection.rtl,
      maxLines: 1,
    )..layout(maxWidth: double.infinity);
    if (painter.width > maxW) maxW = painter.width;
    totalH += painter.height + linePaddingBottom;
  }
  return (maxW, totalH);
}

/// ارتفاعات الأسطر (لربط موضع الضغط بالسطر).
List<double> getQpcLineHeights(
    List<MushafPageLine> pageLines, TextStyle baseStyle,
    {double linePaddingBottom = kNormalLinePaddingBottom}) {
  final list = <double>[];
  for (final line in pageLines) {
    TextStyle s = baseStyle.copyWith(fontFamily: line.fontFamily);
    if (line.lineType == 'surah_name')
      s = baseStyle.copyWith(fontFamily: _surahNameFontFamily, fontSize: 22);
    if (line.lineType == 'basmallah') s = _basmallahStyle(fontSize: 22);
    final painter = TextPainter(
      text: TextSpan(text: line.lineText, style: s),
      textDirection: TextDirection.rtl,
      maxLines: 1,
    )..layout(maxWidth: double.infinity);
    list.add(painter.height + linePaddingBottom);
  }
  return list;
}

/// قياس عرض سطر واحد بالستايل المحدد.
double _measureLineWidth(String text, TextStyle style) {
  final painter = TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: TextDirection.rtl,
    maxLines: 1,
  )..layout(maxWidth: double.infinity);
  return painter.width;
}

({double left, double width})? _wordHighlightRect({
  required TextPainter painter,
  required String text,
  required TextStyle style,
  required int startChar,
  required int endChar,
}) {
  final start = startChar.clamp(0, text.length);
  final end = endChar.clamp(0, text.length);
  if (end <= start) return null;

  final boxes = painter.getBoxesForSelection(
    TextSelection(baseOffset: start, extentOffset: end),
  );
  double? left;
  double? right;
  for (final b in boxes) {
    if (!b.left.isFinite || !b.right.isFinite) continue;
    left = left == null || b.left < left ? b.left : left;
    right = right == null || b.right > right ? b.right : right;
  }
  if (left != null && right != null && right > left) {
    return (left: left, width: right - left);
  }

  final s = painter.getOffsetForCaret(TextPosition(offset: start), Rect.zero);
  final e = painter.getOffsetForCaret(TextPosition(offset: end), Rect.zero);
  var l = s.dx < e.dx ? s.dx : e.dx;
  var w = (e.dx - s.dx).abs();
  if (w <= 0.01) {
    final prefixW = _measureLineWidth(text.substring(0, start), style);
    final tokenW = _measureLineWidth(text.substring(start, end), style);
    l = prefixW;
    w = tokenW;
  }
  if (w <= 0.01) return null;
  return (left: l, width: w);
}

/// عدد المسافات في النص (لتوزيعها عند التبرير).
int _countSpaces(String text) => ' '.allMatches(text).length;

/// إرجاع ستايل السطر مع wordSpacing لضبط السطر ليعادل contentW (تبرير — نهايات الأسطر متساوية).
TextStyle getJustifiedLineStyle(
    MushafPageLine line, TextStyle lineStyle, double contentW) {
  if (line.isCentered) return lineStyle;
  final w = _measureLineWidth(line.lineText, lineStyle);
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

  Future<List<MushafPageLine>> loadPage(int page) async {
    const mode = 'qpc4';
    final cached = PageCache.instance.get(mode, page);
    if (cached != null && cached.isNotEmpty) return cached;

    final persisted = await PagePersistentCache.instance.get(mode, page);
    if (persisted != null && persisted.isNotEmpty) {
      PageCache.instance.put(mode, page, persisted);
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

    PageCache.instance.put(mode, page, result);
    await PagePersistentCache.instance.put(mode, page, result);
    return result;
  }

  static const double _refWidth = 1080;
  static const double _refHeight = 1512;

  /// حساب التخطيط عند أبعاد مرجعية ثابتة.
  static BakedPageLayout bakePage(
    int page,
    List<MushafPageLine> pageLines,
    TextStyle baseStyle,
    Map<int, (int sura, int ayah)>? mapping,
  ) {
    final (contentW, _) = getQpcContentDimensions(pageLines, baseStyle);
    final lineHeights = getQpcLineHeights(pageLines, baseStyle);
    final lineHeightsWithFrame = List<double>.from(lineHeights);
    for (var i = 0; i < pageLines.length; i++) {
      if (pageLines[i].lineType == 'surah_name') {
        lineHeightsWithFrame[i] =
            contentW * _surahFrameAspect + kNormalLinePaddingBottom;
      }
    }
    final leftMargin = _refWidth * kQpcPageMarginLeftFraction;
    final rightMargin = _refWidth * kQpcPageMarginFraction;
    final topMargin = _refHeight * kQpcPageMarginFraction;
    final bottomMargin = _refHeight * kQpcPageMarginFraction;
    final fullH = _refHeight - topMargin - bottomMargin;
    const slotsCount = 15;
    final slotHeight = fullH / slotsCount;
    final availableW = _refWidth - leftMargin - rightMargin;

    /// استخدام العرض المتاح بالكامل لجميع الصفحات لضمان عرض متناسق (صفحات 4+ كانت تظهر أصغر).
    final pageWidth = availableW;
    final slotOffset = (page == 1 || page == 2) ? 3 : 0;
    final lineHeights15 =
        List<double>.filled(slotsCount, slotHeight, growable: false);
    return BakedPageLayout(
      version: BakedPageLayout.currentVersion,
      page: page,
      referenceWidth: _refWidth,
      referenceHeight: _refHeight,
      slotHeight: slotHeight,
      fullH: fullH,
      contentW: contentW,
      pageWidth: pageWidth,
      leftMargin: leftMargin,
      rightMargin: rightMargin,
      topMargin: topMargin,
      bottomMargin: bottomMargin,
      pageLines: pageLines,
      lineHeights15: lineHeights15,
      slotOffset: slotOffset,
      mapping: mapping,
    );
  }
}

const TextStyle _kBaseStyle = TextStyle(
  fontSize: 23,
  height: 1.52,
  letterSpacing: 0,
  wordSpacing: 0,
  fontFeatures: [FontFeature.disable('kern')],
);

Future<List<MushafPageLine>> _loadRawOnly(int page) async {
  await loadQcf4Font(page);
  final cached = PageCache.instance.get('qpc4', page);
  if (cached != null && cached.isNotEmpty) return cached;
  final persisted = await PagePersistentCache.instance.get('qpc4', page);
  if (persisted != null && persisted.isNotEmpty) {
    PageCache.instance.put('qpc4', page, persisted);
    return persisted;
  }
  return await QpcV4Renderer.instance.loadPage(page);
}

Future<({BakedPageLayout? baked, List<MushafPageLine>? lines})> _loadBakedOrRaw(
    int page) async {
  await loadQcf4Font(page);
  final cachedBaked = PageCache.instance.getBaked('qpc4', page);
  if (cachedBaked != null) return (baked: cachedBaked, lines: null);
  final persistedBaked =
      await PagePersistentCache.instance.getBaked('qpc4', page);
  if (persistedBaked != null &&
      persistedBaked.version >= BakedPageLayout.currentVersion) {
    PageCache.instance.putBaked('qpc4', page, persistedBaked);
    return (baked: persistedBaked, lines: null);
  }
  final cached = PageCache.instance.get('qpc4', page);
  if (cached != null && cached.isNotEmpty) return (baked: null, lines: cached);
  final persisted = await PagePersistentCache.instance.get('qpc4', page);
  if (persisted != null && persisted.isNotEmpty) {
    PageCache.instance.put('qpc4', page, persisted);
    return (baked: null, lines: persisted);
  }
  final lines = await QpcV4Renderer.instance.loadPage(page);
  Future(() async {
    try {
      int? minR;
      int? maxR;
      for (final line in lines) {
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
      if (minR != null && maxR != null) {
        final mapping = await QuranDb.instance.getWordToAyahMapping(minR, maxR);
        final baked = QpcV4Renderer.bakePage(page, lines, _kBaseStyle, mapping);
        await PagePersistentCache.instance.putBaked('qpc4', page, baked);
        PageCache.instance.putBaked('qpc4', page, baked);
      }
    } catch (_) {}
  });
  return (baked: null, lines: lines);
}

/// نفس آلية الكاش لـ QPC1: نافذة 5 صفحات (2 قبل، 2 بعد الحالية).
void preloadNearbyPages(int currentPage) {
  const totalPages = 604;
  final before = PageCache.cacheWindowBefore;
  final after = PageCache.cacheWindowAfter;
  for (int p = currentPage - before; p <= currentPage + after; p++) {
    if (p < 1 || p > totalPages) continue;
    if (QpcV4PageView._useRawForPage(p)) {
      if (PageCache.instance.has('qpc4', p)) continue;
      Future(() => _loadRawOnly(p));
    } else {
      if (PageCache.instance.hasBaked('qpc4', p)) continue;
      if (PageCache.instance.has('qpc4', p)) continue;
      Future(() => _loadBakedOrRaw(p));
    }
  }
}

class QpcV4PageView extends StatelessWidget {
  const QpcV4PageView({super.key, required this.page});
  final int page;

  static const TextStyle _baseStyle = TextStyle(
    fontSize: 23,
    height: 1.52,
    letterSpacing: 0,
    wordSpacing: 0,
    fontFeatures: [FontFeature.disable('kern')],
  );

  /// الصفحات 1–3 لها تخطيط خاص (خانات فارغة، توسيع) — نستخدم المسار الخام دائماً
  /// لتفادي مشاكل العرض في القراءة الطويلة والعرض الأفقي.
  static bool _useRawForPage(int page) => page <= 3;

  @override
  Widget build(BuildContext context) {
    if (_useRawForPage(page)) {
      final cached = PageCache.instance.get('qpc4', page);
      if (cached != null && cached.isNotEmpty) {
        return _buildPageWithMapping(context, page, cached, _baseStyle);
      }
      return FutureBuilder<List<MushafPageLine>>(
        future: _loadRawOnly(page),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const SizedBox.expand();
          }
          if (snapshot.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  'فشل تحميل الصفحة: ${snapshot.error}',
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 16),
                ),
              ),
            );
          }
          final pageLines = snapshot.data ?? [];
          if (pageLines.isEmpty) {
            return const Center(child: Text('لا توجد بيانات لهذه الصفحة'));
          }
          return _buildPageWithMapping(context, page, pageLines, _baseStyle);
        },
      );
    }

    final cachedBaked = PageCache.instance.getBaked('qpc4', page);
    if (cachedBaked != null) {
      return _buildContentFromBaked(context, cachedBaked);
    }
    final cached = PageCache.instance.get('qpc4', page);
    if (cached != null && cached.isNotEmpty) {
      return _buildPageWithMapping(context, page, cached, _baseStyle);
    }

    return FutureBuilder<
        ({BakedPageLayout? baked, List<MushafPageLine>? lines})>(
      future: _loadBakedOrRaw(page),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const SizedBox.expand();
        }
        if (snapshot.hasError) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                'فشل تحميل الصفحة: ${snapshot.error}',
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 16),
              ),
            ),
          );
        }
        final data = snapshot.data;
        if (data == null) {
          return const Center(child: Text('لا توجد بيانات لهذه الصفحة'));
        }
        if (data.baked != null) {
          return _buildContentFromBaked(context, data.baked!);
        }
        final pageLines = data.lines ?? [];
        if (pageLines.isEmpty) {
          return const Center(child: Text('لا توجد بيانات لهذه الصفحة'));
        }
        return _buildPageWithMapping(context, page, pageLines, _baseStyle);
      },
    );
  }

  /// يستخدم العرض الفعلي من القيود (LayoutBuilder) لضمان تطابق العرض في جميع الأوضاع
  /// — القراءة الطولية والعرض الافتراضي يستدعيان نفس التخطيط من ROM بنفس النسب.
  static Widget _buildContentFromBaked(
      BuildContext context, BakedPageLayout baked) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final availableWidth = constraints.maxWidth;
        final scale = availableWidth / baked.referenceWidth;
        return _QpcV4BakedContentStateful(
          baked: baked,
          scale: scale,
        );
      },
    );
  }

  static Widget _buildPageWithMapping(
    BuildContext context,
    int page,
    List<MushafPageLine> pageLines,
    TextStyle baseStyle,
  ) {
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
          context, page, pageLines, baseStyle, null, null, null, null);
    }
    return FutureBuilder<Map<int, (int, int)>>(
      future: QuranDb.instance.getWordToAyahMapping(minR, maxR),
      builder: (_, mapSnap) {
        return _QpcV4PageContentStateful(
          page: page,
          pageLines: pageLines,
          baseStyle: baseStyle,
          mapping: mapSnap.data,
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
      return _basmallahStyle(fontSize: 22 * fontSizeScale);
    }
    return baseStyle.copyWith(fontFamily: line.fontFamily);
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
  }) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isCompact = CompactLineSpacingScope.isCompact(context);
        final availableWidth = constraints.maxWidth;
        final availableHeight = constraints.maxHeight;
        final marginFraction =
            isCompact ? kCompactMarginFraction : kQpcPageMarginFraction;
        final leftMargin = availableWidth * marginFraction;
        final rightMargin = availableWidth * marginFraction;
        final topMargin = availableHeight * marginFraction;
        final bottomMargin = availableHeight *
            (isCompact
                ? marginFraction * kCompactBottomMarginScale
                : marginFraction);

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
        final availableContentW = availableWidth - leftMargin - rightMargin;
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

        var (baseContentW, contentH) = getQpcContentDimensions(
          pageLines,
          effectiveBaseStyle,
          linePaddingBottom: linePad,
        );
        final lineHeights = getQpcLineHeights(
          pageLines,
          effectiveBaseStyle,
          linePaddingBottom: linePad,
        );

        final contentW = isCompact ? availableContentW : baseContentW;

        final lineHeightsWithFrame = List<double>.from(lineHeights);
        for (var i = 0; i < pageLines.length; i++) {
          if (pageLines[i].lineType == 'surah_name') {
            lineHeightsWithFrame[i] = contentW * _surahFrameAspect + linePad;
          }
        }
        contentH = lineHeightsWithFrame.fold(0.0, (a, b) => a + b);

        final pageLinesWidgets = pageLines.asMap().entries.map((entry) {
          final lineIndex = entry.key;
          final line = entry.value;
          final lineStyle = _lineStyleFor(line, effectiveBaseStyle,
              fontSizeScale: isCompact ? fontScale : 1.0);
          final justifiedStyle =
              getJustifiedLineStyle(line, lineStyle, contentW);
          Widget lineWidget;
          if (line.lineType == 'surah_name') {
            final frameHeight = contentW * _surahFrameAspect;
            lineWidget = Padding(
              padding: EdgeInsets.only(bottom: linePad),
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
                            line.lineText,
                            textDirection: TextDirection.rtl,
                            textAlign: TextAlign.center,
                            maxLines: 1,
                            overflow: TextOverflow.visible,
                            style: justifiedStyle,
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
              padding: EdgeInsets.only(bottom: linePad),
              child: Align(
                alignment: Alignment.center,
                child: SizedBox(
                  width: double.infinity,
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.center,
                    child: Transform.translate(
                      offset: Offset(0, _basmallahRaiseDy * fontScale),
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
            lineWidget = Padding(
              padding: EdgeInsets.only(bottom: linePad),
              child: Align(
                alignment:
                    line.isCentered ? Alignment.center : Alignment.centerRight,
                child: SizedBox(
                  width: double.infinity,
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: line.isCentered
                        ? Alignment.center
                        : Alignment.centerRight,
                    child: Text(
                      line.lineText,
                      textDirection: TextDirection.rtl,
                      textAlign:
                          line.isCentered ? TextAlign.center : TextAlign.right,
                      softWrap: false,
                      maxLines: 1,
                      overflow: TextOverflow.visible,
                      style: justifiedStyle,
                    ),
                  ),
                ),
              ),
            );
          }
          (int, int, int)? lineSelection;
          final linePersistentSelections = <(int, int, int, Color)>[];
          if (selection != null) {
            for (final e in selection) {
              if (e.$1 == lineIndex) {
                lineSelection = e;
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
            final lineWidth = _measureLineWidth(line.lineText, justifiedStyle);
            final painter = TextPainter(
              text: TextSpan(text: line.lineText, style: justifiedStyle),
              textDirection: TextDirection.rtl,
              maxLines: 1,
            )..layout(maxWidth: lineWidth);
            final startOffset = painter.getOffsetForCaret(
                TextPosition(
                    offset: lineSelection.$2.clamp(0, line.lineText.length)),
                Rect.zero);
            final endOffset = painter.getOffsetForCaret(
                TextPosition(
                    offset: lineSelection.$3.clamp(0, line.lineText.length)),
                Rect.zero);
            final left =
                startOffset.dx < endOffset.dx ? startOffset.dx : endOffset.dx;
            final width = (endOffset.dx - startOffset.dx).abs();
            double? wordLeft;
            double? wordWidth;
            if (lineWordSelection != null &&
                lineWordSelection.$2 >= 0 &&
                lineWordSelection.$3 > lineWordSelection.$2) {
              final rect = _wordHighlightRect(
                painter: painter,
                text: line.lineText,
                style: justifiedStyle,
                startChar: lineWordSelection.$2,
                endChar: lineWordSelection.$3,
              );
              if (rect != null) {
                wordLeft = rect.left;
                wordWidth = rect.width;
              }
            }
            return Padding(
              padding: EdgeInsets.only(bottom: linePad),
              child: Align(
                alignment:
                    line.isCentered ? Alignment.center : Alignment.centerRight,
                child: SizedBox(
                  width: double.infinity,
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: line.isCentered
                        ? Alignment.center
                        : Alignment.centerRight,
                    child: SizedBox(
                      width: lineWidth,
                      height: painter.height,
                      child: Stack(
                        alignment: Alignment.centerRight,
                        children: [
                          Text(
                            line.lineText,
                            textDirection: TextDirection.rtl,
                            textAlign: line.isCentered
                                ? TextAlign.center
                                : TextAlign.right,
                            softWrap: false,
                            maxLines: 1,
                            overflow: TextOverflow.visible,
                            style: justifiedStyle,
                          ),
                          Positioned(
                            left: left,
                            top: 0,
                            width: width,
                            height: painter.height,
                            child: Container(
                              decoration: BoxDecoration(
                                color: const Color.fromARGB(255, 45, 45, 45)
                                    .withValues(alpha: 0.18),
                                borderRadius: BorderRadius.circular(2),
                              ),
                            ),
                          ),
                          if (wordLeft != null && wordWidth != null)
                            Positioned(
                              left: wordLeft,
                              top: 0,
                              width: wordWidth,
                              height: painter.height,
                              child: Container(
                                decoration: BoxDecoration(
                                  color: const Color(0xFFB8E6C1)
                                      .withValues(alpha: 0.3),
                                  borderRadius: BorderRadius.circular(2),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            );
          }
          if (lineSelection == null &&
              linePersistentSelections.isNotEmpty &&
              line.lineType == 'ayah') {
            final lineWidth = _measureLineWidth(line.lineText, justifiedStyle);
            final painter = TextPainter(
              text: TextSpan(text: line.lineText, style: justifiedStyle),
              textDirection: TextDirection.rtl,
              maxLines: 1,
            )..layout(maxWidth: lineWidth);
            final rects = <({double left, double width, Color color})>[];
            for (final h in linePersistentSelections) {
              final startOffset = painter.getOffsetForCaret(
                TextPosition(offset: h.$2.clamp(0, line.lineText.length)),
                Rect.zero,
              );
              final endOffset = painter.getOffsetForCaret(
                TextPosition(offset: h.$3.clamp(0, line.lineText.length)),
                Rect.zero,
              );
              final left =
                  startOffset.dx < endOffset.dx ? startOffset.dx : endOffset.dx;
              final width = (endOffset.dx - startOffset.dx).abs();
              if (width > 0.01) {
                rects.add((left: left, width: width, color: h.$4));
              }
            }
            if (rects.isEmpty) return lineWidget;
            final mergedRects = _mergePersistentRectsByColor(rects);
            return Padding(
              padding: EdgeInsets.only(bottom: linePad),
              child: Align(
                alignment:
                    line.isCentered ? Alignment.center : Alignment.centerRight,
                child: SizedBox(
                  width: double.infinity,
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: line.isCentered
                        ? Alignment.center
                        : Alignment.centerRight,
                    child: SizedBox(
                      width: lineWidth,
                      height: painter.height,
                      child: Stack(
                        alignment: Alignment.centerRight,
                        children: [
                          Text(
                            line.lineText,
                            textDirection: TextDirection.rtl,
                            textAlign: line.isCentered
                                ? TextAlign.center
                                : TextAlign.right,
                            softWrap: false,
                            maxLines: 1,
                            overflow: TextOverflow.visible,
                            style: justifiedStyle,
                          ),
                          for (final r in mergedRects)
                            _buildPersistentHighlightSegment(r, painter.height),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            );
          }
          // عند إخفاء تضليل الآية أثناء الاستماع، نبقي تضليل الكلمة المقروءة فقط.
          if (lineWordSelection != null &&
              line.lineType == 'ayah' &&
              lineWordSelection.$2 >= 0 &&
              lineWordSelection.$3 > lineWordSelection.$2) {
            final lineWidth = _measureLineWidth(line.lineText, justifiedStyle);
            final painter = TextPainter(
              text: TextSpan(text: line.lineText, style: justifiedStyle),
              textDirection: TextDirection.rtl,
              maxLines: 1,
            )..layout(maxWidth: lineWidth);
            final rect = _wordHighlightRect(
              painter: painter,
              text: line.lineText,
              style: justifiedStyle,
              startChar: lineWordSelection.$2,
              endChar: lineWordSelection.$3,
            );
            if (rect == null) return lineWidget;
            final wordLeft = rect.left;
            final wordWidth = rect.width;
            return Padding(
              padding: EdgeInsets.only(bottom: linePad),
              child: Align(
                alignment:
                    line.isCentered ? Alignment.center : Alignment.centerRight,
                child: SizedBox(
                  width: double.infinity,
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: line.isCentered
                        ? Alignment.center
                        : Alignment.centerRight,
                    child: SizedBox(
                      width: lineWidth,
                      height: painter.height,
                      child: Stack(
                        alignment: Alignment.centerRight,
                        children: [
                          Text(
                            line.lineText,
                            textDirection: TextDirection.rtl,
                            textAlign: line.isCentered
                                ? TextAlign.center
                                : TextAlign.right,
                            softWrap: false,
                            maxLines: 1,
                            overflow: TextOverflow.visible,
                            style: justifiedStyle,
                          ),
                          Positioned(
                            left: wordLeft,
                            top: 0,
                            width: wordWidth,
                            height: painter.height,
                            child: Container(
                              decoration: BoxDecoration(
                                color: const Color.fromARGB(255, 45, 45, 45)
                                    .withValues(alpha: 0.18),
                                borderRadius: BorderRadius.circular(2),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            );
          }
          return lineWidget;
        }).toList();

        // منطق 15 خانة: المسافة بين الشريط العلوي ورقم الصفحة تُقسم على 15 سطراً.
        final fullH = availableHeight - topMargin - bottomMargin;
        const int slotsCount = 15;
        final slotHeight = fullH / slotsCount;

        final displayLines = pageLines.length >= slotsCount
            ? pageLines.sublist(0, slotsCount)
            : pageLines;

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

        // في العرض الأفقي (compact): نستخدم العرض الكامل من الأخضر للأحمر.
        // للصفحتين 1 و 2: نستخدم العرض المتاح بالكامل. لباقي الصفحات: contentW ما لم يكن compact.
        final availableW = availableWidth - leftMargin - rightMargin;
        final pageWidth =
            isCompact || (page == 1 || page == 2) ? availableW : contentW;

        return SingleChildScrollView(
          primary: false,
          physics: const NeverScrollableScrollPhysics(),
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: Padding(
              padding: EdgeInsets.only(
                left: leftMargin,
                right: rightMargin,
                top: topMargin,
                bottom: bottomMargin,
              ),
              child: Align(
                alignment: Alignment.centerLeft,
                child: RepaintBoundary(
                  child: SizedBox(
                    width: pageWidth,
                    height: fullH,
                    child: mapping != null
                        ? DelayedLongPressDetector(
                            duration: const Duration(milliseconds: 400),
                            onTrigger: (Offset pos) {
                              final adjustedPos = (page == 1 || page == 2)
                                  ? pos.translate(0, -3 * slotHeight)
                                  : pos;
                              _onPageLongPress(
                                context,
                                adjustedPos,
                                contentW,
                                fullH,
                                lineHeights15,
                                displayLines,
                                effectiveBaseStyle,
                                mapping,
                                (line, style) => _lineStyleFor(line, style,
                                    fontSizeScale: isCompact ? fontScale : 1.0),
                                onSelectLine: onSelectLine,
                                onClearSelection: onClearSelection,
                              );
                            },
                            child: column15,
                          )
                        : column15,
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
  }) {
    onQpcPageLongPress(context, localPosition, contentW, contentH, lineHeights,
        pageLines, baseStyle, mapping, lineStyleFor,
        onSelectLine: onSelectLine, onClearSelection: onClearSelection);
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

class _QpcV4BakedContentStateful extends StatefulWidget {
  const _QpcV4BakedContentStateful({
    required this.baked,
    required this.scale,
  });
  final BakedPageLayout baked;
  final double scale;

  @override
  State<_QpcV4BakedContentStateful> createState() =>
      _QpcV4BakedContentStatefulState();
}

class _QpcV4BakedContentStatefulState
    extends State<_QpcV4BakedContentStateful> {
  List<(int, int, int)>? _selection; // تحديد الضغط الطويل (يدوي)
  List<(int, int, int)>? _audioSelection; // تضليل الآية أثناء الاستماع
  (int, int, int)? _wordSelection;
  List<(int, int, int, Color)>? _persistentSelection;

  @override
  void initState() {
    super.initState();
    AyahAudioPlayer.instance.addListener(_syncAudioHighlight);
    AyahHighlightStore.instance.addListener(_syncPersistentHighlights);
    _syncAudioHighlight();
    _syncPersistentHighlights();
  }

  @override
  void didUpdateWidget(covariant _QpcV4BakedContentStateful oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncAudioHighlight();
    _syncPersistentHighlights();
  }

  @override
  void dispose() {
    AyahAudioPlayer.instance.removeListener(_syncAudioHighlight);
    AyahHighlightStore.instance.removeListener(_syncPersistentHighlights);
    super.dispose();
  }

  void _syncPersistentHighlights() {
    final mapping = widget.baked.mapping;
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
          widget.baked.pageLines,
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
    setState(() => _persistentSelection = entries);
  }

  void _syncAudioHighlight() {
    final player = AyahAudioPlayer.instance;
    final mapping = widget.baked.mapping;
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
    final ranges = getAyahRangesForPage(s, a, widget.baked.pageLines, mapping);
    final wordRange = getAyahWordRangeForPage(
      s,
      a,
      player.currentSegmentIndex,
      player.currentSegmentToken,
      widget.baked.pageLines,
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
    final b = widget.baked;
    final player = AyahAudioPlayer.instance;
    final selectionForAyahHighlight =
        _selection ?? (player.showAyahHighlight ? _audioSelection : null);
    if (CompactLineSpacingScope.isCompact(context)) {
      return QpcV4PageView._buildContent(
        context,
        b.page,
        b.pageLines,
        QpcV4PageView._baseStyle,
        b.mapping,
        selectionForAyahHighlight,
        (List<(int, int, int)> ranges) => setState(() => _selection = ranges),
        () => setState(() => _selection = null),
        wordSelection: _wordSelection,
        persistentSelection: _persistentSelection,
      );
    }
    final linePad = CompactLineSpacingScope.linePaddingOf(context);
    final s = widget.scale;
    final leftM = b.leftMargin * s;
    final rightM = b.rightMargin * s;
    final topM = b.topMargin * s;
    final bottomM = b.bottomMargin * s;
    final fullH = b.fullH * s;
    final slotH = b.slotHeight * s;
    final contentW = b.contentW;
    final pageW = b.pageWidth * s;
    final displayLines =
        b.pageLines.length >= 15 ? b.pageLines.sublist(0, 15) : b.pageLines;

    final pageLinesWidgets = displayLines.asMap().entries.map((entry) {
      final lineIndex = entry.key;
      final line = entry.value;
      final lineStyle =
          QpcV4PageView._lineStyleFor(line, QpcV4PageView._baseStyle);
      final justifiedStyle = getJustifiedLineStyle(line, lineStyle, contentW);
      Widget lineWidget;
      if (line.lineType == 'surah_name') {
        final frameHeight = contentW * _surahFrameAspect;
        lineWidget = Padding(
          padding: EdgeInsets.only(bottom: linePad),
          child: SizedBox(
            width: contentW * s,
            height: frameHeight * s,
            child: Stack(
              fit: StackFit.expand,
              alignment: Alignment.center,
              children: [
                SvgPicture.asset(
                  'assets/icon/sura_name.svg',
                  fit: BoxFit.contain,
                  width: contentW * s,
                  height: frameHeight * s,
                ),
                Center(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Padding(
                      padding:
                          EdgeInsets.symmetric(horizontal: contentW * 0.08 * s),
                      child: Text(
                        line.lineText,
                        textDirection: TextDirection.rtl,
                        textAlign: TextAlign.center,
                        maxLines: 1,
                        overflow: TextOverflow.visible,
                        style: justifiedStyle,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      } else {
        lineWidget = Padding(
          padding: EdgeInsets.only(bottom: linePad),
          child: Align(
            alignment:
                line.isCentered ? Alignment.center : Alignment.centerRight,
            child: SizedBox(
              width: double.infinity,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment:
                    line.isCentered ? Alignment.center : Alignment.centerRight,
                child: Text(
                  line.lineText,
                  textDirection: TextDirection.rtl,
                  textAlign:
                      line.isCentered ? TextAlign.center : TextAlign.right,
                  softWrap: false,
                  maxLines: 1,
                  overflow: TextOverflow.visible,
                  style: justifiedStyle,
                ),
              ),
            ),
          ),
        );
      }
      (int, int, int)? lineSelection;
      final linePersistentSelections = <(int, int, int, Color)>[];
      if (selectionForAyahHighlight != null) {
        for (final e in selectionForAyahHighlight) {
          if (e.$1 == lineIndex) {
            lineSelection = e;
            break;
          }
        }
      }
      if (_persistentSelection != null) {
        for (final e in _persistentSelection!) {
          if (e.$1 == lineIndex) linePersistentSelections.add(e);
        }
      }
      (int, int, int)? lineWordSelection;
      if (_wordSelection != null && _wordSelection!.$1 == lineIndex) {
        lineWordSelection = _wordSelection;
      }
      if (lineSelection != null &&
          line.lineType == 'ayah' &&
          lineSelection.$2 >= 0 &&
          lineSelection.$3 > lineSelection.$2) {
        final lineWidth = _measureLineWidth(line.lineText, justifiedStyle);
        final painter = TextPainter(
          text: TextSpan(text: line.lineText, style: justifiedStyle),
          textDirection: TextDirection.rtl,
          maxLines: 1,
        )..layout(maxWidth: lineWidth);
        final startOffset = painter.getOffsetForCaret(
            TextPosition(
                offset: lineSelection.$2.clamp(0, line.lineText.length)),
            Rect.zero);
        final endOffset = painter.getOffsetForCaret(
            TextPosition(
                offset: lineSelection.$3.clamp(0, line.lineText.length)),
            Rect.zero);
        final left =
            startOffset.dx < endOffset.dx ? startOffset.dx : endOffset.dx;
        final width = (endOffset.dx - startOffset.dx).abs();
        double? wordLeft;
        double? wordWidth;
        if (lineWordSelection != null &&
            lineWordSelection.$2 >= 0 &&
            lineWordSelection.$3 > lineWordSelection.$2) {
          final wStart = painter.getOffsetForCaret(
              TextPosition(
                  offset: lineWordSelection.$2.clamp(0, line.lineText.length)),
              Rect.zero);
          final wEnd = painter.getOffsetForCaret(
              TextPosition(
                  offset: lineWordSelection.$3.clamp(0, line.lineText.length)),
              Rect.zero);
          wordLeft = wStart.dx < wEnd.dx ? wStart.dx : wEnd.dx;
          wordWidth = (wEnd.dx - wStart.dx).abs();
        }
        return Padding(
          padding: EdgeInsets.only(bottom: linePad),
          child: Align(
            alignment:
                line.isCentered ? Alignment.center : Alignment.centerRight,
            child: SizedBox(
              width: double.infinity,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment:
                    line.isCentered ? Alignment.center : Alignment.centerRight,
                child: SizedBox(
                  width: lineWidth,
                  height: painter.height,
                  child: Stack(
                    alignment: Alignment.centerRight,
                    children: [
                      Text(
                        line.lineText,
                        textDirection: TextDirection.rtl,
                        textAlign: line.isCentered
                            ? TextAlign.center
                            : TextAlign.right,
                        softWrap: false,
                        maxLines: 1,
                        overflow: TextOverflow.visible,
                        style: justifiedStyle,
                      ),
                      Positioned(
                        left: left,
                        top: 0,
                        width: width,
                        height: painter.height,
                        child: Container(
                          decoration: BoxDecoration(
                            color: const Color.fromARGB(255, 45, 45, 45)
                                .withValues(alpha: 0.24),
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
                      if (wordLeft != null && wordWidth != null)
                        Positioned(
                          left: wordLeft,
                          top: 0,
                          width: wordWidth,
                          height: painter.height,
                          child: Container(
                            decoration: BoxDecoration(
                              color: const Color(0xFFB8E6C1)
                                  .withValues(alpha: 0.30),
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      }
      if (lineSelection == null &&
          linePersistentSelections.isNotEmpty &&
          line.lineType == 'ayah') {
        final lineWidth = _measureLineWidth(line.lineText, justifiedStyle);
        final painter = TextPainter(
          text: TextSpan(text: line.lineText, style: justifiedStyle),
          textDirection: TextDirection.rtl,
          maxLines: 1,
        )..layout(maxWidth: lineWidth);
        final rects = <({double left, double width, Color color})>[];
        for (final h in linePersistentSelections) {
          final startOffset = painter.getOffsetForCaret(
            TextPosition(offset: h.$2.clamp(0, line.lineText.length)),
            Rect.zero,
          );
          final endOffset = painter.getOffsetForCaret(
            TextPosition(offset: h.$3.clamp(0, line.lineText.length)),
            Rect.zero,
          );
          final left =
              startOffset.dx < endOffset.dx ? startOffset.dx : endOffset.dx;
          final width = (endOffset.dx - startOffset.dx).abs();
          if (width > 0.01) {
            rects.add((left: left, width: width, color: h.$4));
          }
        }
        if (rects.isEmpty) return lineWidget;
        final mergedRects = _mergePersistentRectsByColor(rects);
        return Padding(
          padding: EdgeInsets.only(bottom: linePad),
          child: Align(
            alignment:
                line.isCentered ? Alignment.center : Alignment.centerRight,
            child: SizedBox(
              width: double.infinity,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment:
                    line.isCentered ? Alignment.center : Alignment.centerRight,
                child: SizedBox(
                  width: lineWidth,
                  height: painter.height,
                  child: Stack(
                    alignment: Alignment.centerRight,
                    children: [
                      Text(
                        line.lineText,
                        textDirection: TextDirection.rtl,
                        textAlign: line.isCentered
                            ? TextAlign.center
                            : TextAlign.right,
                        softWrap: false,
                        maxLines: 1,
                        overflow: TextOverflow.visible,
                        style: justifiedStyle,
                      ),
                      for (final r in mergedRects)
                        _buildPersistentHighlightSegment(r, painter.height),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      }
      if (lineWordSelection != null &&
          line.lineType == 'ayah' &&
          lineWordSelection.$2 >= 0 &&
          lineWordSelection.$3 > lineWordSelection.$2) {
        final lineWidth = _measureLineWidth(line.lineText, justifiedStyle);
        final painter = TextPainter(
          text: TextSpan(text: line.lineText, style: justifiedStyle),
          textDirection: TextDirection.rtl,
          maxLines: 1,
        )..layout(maxWidth: lineWidth);
        final wStart = painter.getOffsetForCaret(
            TextPosition(
                offset: lineWordSelection.$2.clamp(0, line.lineText.length)),
            Rect.zero);
        final wEnd = painter.getOffsetForCaret(
            TextPosition(
                offset: lineWordSelection.$3.clamp(0, line.lineText.length)),
            Rect.zero);
        final wordLeft = wStart.dx < wEnd.dx ? wStart.dx : wEnd.dx;
        final wordWidth = (wEnd.dx - wStart.dx).abs();
        return Padding(
          padding: EdgeInsets.only(bottom: linePad),
          child: Align(
            alignment:
                line.isCentered ? Alignment.center : Alignment.centerRight,
            child: SizedBox(
              width: double.infinity,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment:
                    line.isCentered ? Alignment.center : Alignment.centerRight,
                child: SizedBox(
                  width: lineWidth,
                  height: painter.height,
                  child: Stack(
                    alignment: Alignment.centerRight,
                    children: [
                      Text(
                        line.lineText,
                        textDirection: TextDirection.rtl,
                        textAlign: line.isCentered
                            ? TextAlign.center
                            : TextAlign.right,
                        softWrap: false,
                        maxLines: 1,
                        overflow: TextOverflow.visible,
                        style: justifiedStyle,
                      ),
                      Positioned(
                        left: wordLeft,
                        top: 0,
                        width: wordWidth,
                        height: painter.height,
                        child: Container(
                          decoration: BoxDecoration(
                            color: const Color.fromARGB(255, 45, 45, 45)
                                .withValues(alpha: 0.18),
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      }
      if (lineWordSelection != null &&
          line.lineType == 'ayah' &&
          lineWordSelection.$2 >= 0 &&
          lineWordSelection.$3 > lineWordSelection.$2) {
        final lineWidth = _measureLineWidth(line.lineText, justifiedStyle);
        final painter = TextPainter(
          text: TextSpan(text: line.lineText, style: justifiedStyle),
          textDirection: TextDirection.rtl,
          maxLines: 1,
        )..layout(maxWidth: lineWidth);
        final wStart = painter.getOffsetForCaret(
            TextPosition(
                offset: lineWordSelection.$2.clamp(0, line.lineText.length)),
            Rect.zero);
        final wEnd = painter.getOffsetForCaret(
            TextPosition(
                offset: lineWordSelection.$3.clamp(0, line.lineText.length)),
            Rect.zero);
        final wordLeft = wStart.dx < wEnd.dx ? wStart.dx : wEnd.dx;
        final wordWidth = (wEnd.dx - wStart.dx).abs();
        return Padding(
          padding: EdgeInsets.only(bottom: linePad),
          child: Align(
            alignment:
                line.isCentered ? Alignment.center : Alignment.centerRight,
            child: SizedBox(
              width: double.infinity,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment:
                    line.isCentered ? Alignment.center : Alignment.centerRight,
                child: SizedBox(
                  width: lineWidth,
                  height: painter.height,
                  child: Stack(
                    alignment: Alignment.centerRight,
                    children: [
                      Text(
                        line.lineText,
                        textDirection: TextDirection.rtl,
                        textAlign: line.isCentered
                            ? TextAlign.center
                            : TextAlign.right,
                        softWrap: false,
                        maxLines: 1,
                        overflow: TextOverflow.visible,
                        style: justifiedStyle,
                      ),
                      Positioned(
                        left: wordLeft,
                        top: 0,
                        width: wordWidth,
                        height: painter.height,
                        child: Container(
                          decoration: BoxDecoration(
                            color: const Color.fromARGB(255, 45, 45, 45)
                                .withValues(alpha: 0.18),
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      }
      return lineWidget;
    }).toList();

    final slots = <Widget>[];
    for (var i = 0; i < 15; i++) {
      final srcIndex = i - b.slotOffset;
      Widget lineChild = const SizedBox.shrink();
      if (srcIndex >= 0 && srcIndex < pageLinesWidgets.length) {
        lineChild = pageLinesWidgets[srcIndex];
      }
      slots.add(
        SizedBox(
          height: slotH,
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

    Widget content = column15;
    if (b.mapping != null) {
      content = DelayedLongPressDetector(
        duration: const Duration(milliseconds: 400),
        onTrigger: (Offset pos) {
          var adjustedPos = pos;
          if (b.slotOffset > 0)
            adjustedPos = pos.translate(0, -b.slotOffset * slotH);
          adjustedPos = Offset(adjustedPos.dx / s, adjustedPos.dy / s);
          final availableW = b.referenceWidth - b.leftMargin - b.rightMargin;
          if (b.pageWidth > b.contentW) {
            adjustedPos = Offset(
                adjustedPos.dx - (availableW - b.contentW), adjustedPos.dy);
          }
          onQpcPageLongPress(
            context,
            adjustedPos,
            b.contentW,
            b.fullH,
            b.lineHeights15,
            displayLines,
            QpcV4PageView._baseStyle,
            b.mapping!,
            QpcV4PageView._lineStyleFor,
            onSelectLine: (sel) => setState(() => _selection = sel),
            onClearSelection: () => setState(() => _selection = null),
          );
        },
        child: column15,
      );
    }

    return SingleChildScrollView(
      primary: false,
      physics: const NeverScrollableScrollPhysics(),
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: fullH + topM + bottomM),
        child: Padding(
          padding: EdgeInsets.only(
              left: leftM, right: rightM, top: topM, bottom: bottomM),
          child: Align(
            alignment: Alignment.center,
            child: RepaintBoundary(
              child: SizedBox(
                width: pageW,
                height: fullH,
                child: content,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _QpcV4PageContentStateful extends StatefulWidget {
  const _QpcV4PageContentStateful({
    required this.page,
    required this.pageLines,
    required this.baseStyle,
    required this.mapping,
  });
  final int page;
  final List<MushafPageLine> pageLines;
  final TextStyle baseStyle;
  final Map<int, (int sura, int ayah)>? mapping;

  @override
  State<_QpcV4PageContentStateful> createState() =>
      _QpcV4PageContentStatefulState();
}

class _QpcV4PageContentStatefulState extends State<_QpcV4PageContentStateful> {
  List<(int, int, int)>? _selection; // تحديد الضغط الطويل (يدوي)
  List<(int, int, int)>? _audioSelection; // تضليل الآية أثناء الاستماع
  (int, int, int)? _wordSelection;
  List<(int, int, int, Color)>? _persistentSelection;

  @override
  void initState() {
    super.initState();
    AyahAudioPlayer.instance.addListener(_syncAudioHighlight);
    AyahHighlightStore.instance.addListener(_syncPersistentHighlights);
    _syncAudioHighlight();
    _syncPersistentHighlights();
  }

  @override
  void didUpdateWidget(covariant _QpcV4PageContentStateful oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncAudioHighlight();
    _syncPersistentHighlights();
  }

  @override
  void dispose() {
    AyahAudioPlayer.instance.removeListener(_syncAudioHighlight);
    AyahHighlightStore.instance.removeListener(_syncPersistentHighlights);
    super.dispose();
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
}) async {
  if (lineHeights.isEmpty || pageLines.isEmpty) return;
  // هامش تسامح عمودي: حدود التحديد قد تختلف قليلاً عن ترتيب العرض (خانات vs محتوى).
  const yTolerance = 4.0;
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
  if (lineIndex < 0 || lineIndex >= pageLines.length) return;
  final line = pageLines[lineIndex];
  if (line.lineType != 'ayah' ||
      line.rangeStart == null ||
      line.rangeEnd == null) return;

  final lineStyle = lineStyleFor(line, baseStyle);
  final justifiedStyle = getJustifiedLineStyle(line, lineStyle, contentW);
  final lineWidth = _measureLineWidth(line.lineText, justifiedStyle);
  final lineLeft = contentW - lineWidth;
  var tapXInText = localPosition.dx - lineLeft;
  // هامش تسامح على الجوانب: حدود التحديد قد تختلف قليلاً عن العرض الفعلي (FittedBox، هوامش).
  final xTolerance = (contentW * 0.06).clamp(4.0, 24.0);
  if (tapXInText < -xTolerance || tapXInText > lineWidth + xTolerance) return;
  tapXInText = tapXInText.clamp(0.0, lineWidth);

  final painter = TextPainter(
    text: TextSpan(text: line.lineText, style: justifiedStyle),
    textDirection: TextDirection.rtl,
    maxLines: 1,
  )..layout(maxWidth: contentW);
  final position = painter.getPositionForOffset(Offset(tapXInText, 0));
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
