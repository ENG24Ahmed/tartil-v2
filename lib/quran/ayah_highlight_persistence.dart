import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:quran_app/quran/renderers/qpc_v4_renderer.dart'
    show AyahHighlightStore, AyahRangeHighlight;

/// نفس مفتاح [QuranPageViewer] لحفظ نطاقات تضليل الآيات.
const String kAyahHighlightsPrefsKey = 'ayah_highlights_json';

/// مزامنة إظهار تضليل الآيات مع القائمة الرئيسية والتسميع الذكي.
const String kAyahHighlightsVisiblePrefsKey = 'ayah_highlights_visible';

Future<bool> readAyahHighlightsVisible() async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getBool(kAyahHighlightsVisiblePrefsKey) ?? true;
}

Future<void> writeAyahHighlightsVisible(bool value) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setBool(kAyahHighlightsVisiblePrefsKey, value);
}

/// يحدّث [AyahHighlightStore] من المفضّلات (النطاقات + إظهار/إخفاء المحفوظ).
Future<void> syncAyahHighlightStoreFromPrefs() async {
  final prefs = await SharedPreferences.getInstance();
  final ranges =
      decodeAyahHighlightsFromJson(prefs.getString(kAyahHighlightsPrefsKey));
  final visible = prefs.getBool(kAyahHighlightsVisiblePrefsKey) ?? true;
  AyahHighlightStore.instance.setRanges(visible ? ranges : const []);
}

List<AyahRangeHighlight> decodeAyahHighlightsFromJson(String? json) {
  if (json == null || json.isEmpty) return [];
  try {
    final list = jsonDecode(json) as List;
    return list.map((e) {
      final m = e as Map;
      final sura = (m['sura'] as num?)?.toInt() ?? 1;
      final fromAyah = (m['fromAyah'] as num?)?.toInt() ?? 1;
      final toAyah = (m['toAyah'] as num?)?.toInt() ?? fromAyah;
      final colorValue =
          (m['color'] as num?)?.toInt() ?? Colors.yellow.toARGB32();
      return (
        sura: sura,
        fromAyah: fromAyah,
        toAyah: toAyah,
        color: Color(colorValue),
      );
    }).toList();
  } catch (_) {
    return [];
  }
}

String encodeAyahHighlightsToJson(List<AyahRangeHighlight> list) {
  return jsonEncode(
    list
        .map(
          (h) => {
            'sura': h.sura,
            'fromAyah': h.fromAyah,
            'toAyah': h.toAyah,
            'color': h.color.toARGB32(),
          },
        )
        .toList(),
  );
}

Future<List<AyahRangeHighlight>> readAyahHighlightRanges() async {
  final prefs = await SharedPreferences.getInstance();
  return decodeAyahHighlightsFromJson(prefs.getString(kAyahHighlightsPrefsKey));
}

Future<void> writeAyahHighlightRanges(List<AyahRangeHighlight> ranges) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(
    kAyahHighlightsPrefsKey,
    encodeAyahHighlightsToJson(ranges),
  );
}

/// نفس منطق [QuranPageViewer._applyAyahHighlightRange] على قائمة في الذاكرة.
List<AyahRangeHighlight> mergeAyahHighlightApplyRange(
  List<AyahRangeHighlight> current, {
  required int sura,
  required int fromAyah,
  required int toAyah,
  required Color color,
  AyahRangeHighlight? replace,
  required int ayahCountForSura,
}) {
  final ayahCount = ayahCountForSura.clamp(1, 286);
  final from = fromAyah.clamp(1, ayahCount);
  final to = toAyah.clamp(1, ayahCount);
  final list = List<AyahRangeHighlight>.from(current);
  if (replace != null) {
    list.removeWhere(
      (h) =>
          h.sura == replace.sura &&
          h.fromAyah == replace.fromAyah &&
          h.toAyah == replace.toAyah &&
          h.color.toARGB32() == replace.color.toARGB32(),
    );
  }
  list.add((
    sura: sura,
    fromAyah: from <= to ? from : to,
    toAyah: from <= to ? to : from,
    color: color,
  ));
  return list;
}

Future<void> persistAyahHighlightRangesAndPublishStore(
  List<AyahRangeHighlight> ranges,
) async {
  await writeAyahHighlightRanges(ranges);
  AyahHighlightStore.instance.setRanges(ranges);
}
