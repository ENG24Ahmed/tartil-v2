import 'package:shared_preferences/shared_preferences.dart';

const _keyCurrentReciter = 'ayah_reciter_current';
const _keyFavoriteReciters = 'ayah_reciter_favorites';
const _keyPlaybackMode = 'ayah_playback_mode';
const _keyRangeSura = 'ayah_playback_range_sura';
const _keyRangeFromSura = 'ayah_playback_range_from_sura';
const _keyRangeToSura = 'ayah_playback_range_to_sura';
const _keyRangeFrom = 'ayah_playback_range_from';
const _keyRangeTo = 'ayah_playback_range_to';
const _keyShowAyahHighlight = 'ayah_show_ayah_highlight';

/// وضع التشغيل: مرة واحدة، تكرار، متابعة.
enum AyahPlaybackMode { once, repeat, continuous }

class AyahPlaybackRange {
  const AyahPlaybackRange({
    required this.fromSura,
    required this.fromAyah,
    required this.toSura,
    required this.toAyah,
  });

  final int fromSura;
  final int fromAyah;
  final int toSura;
  final int toAyah;

  /// توافق رجعي: بداية النطاق (السورة).
  int get sura => fromSura;

  bool get isSingleSura => fromSura == toSura;
}

class AyahRecitersPrefs {
  AyahRecitersPrefs._();
  static final AyahRecitersPrefs instance = AyahRecitersPrefs._();

  Future<String> getCurrentReciterId() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keyCurrentReciter) ?? 'alnufais';
  }

  Future<void> setCurrentReciterId(String id) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyCurrentReciter, id);
  }

  Future<List<String>> getFavoriteReciterIds() async {
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList(_keyFavoriteReciters);
    return list ?? [];
  }

  Future<void> toggleFavorite(String id) async {
    final list = await getFavoriteReciterIds();
    if (list.contains(id)) {
      list.remove(id);
    } else {
      list.add(id);
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_keyFavoriteReciters, list);
  }

  Future<bool> isFavorite(String id) async {
    return (await getFavoriteReciterIds()).contains(id);
  }

  Future<AyahPlaybackMode> getPlaybackMode() async {
    final prefs = await SharedPreferences.getInstance();
    final v = prefs.getInt(_keyPlaybackMode);
    if (v == null) return AyahPlaybackMode.once;
    return AyahPlaybackMode.values[v.clamp(0, 2)];
  }

  Future<void> setPlaybackMode(AyahPlaybackMode mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_keyPlaybackMode, mode.index);
  }

  Future<AyahPlaybackRange?> getPlaybackRange() async {
    final prefs = await SharedPreferences.getInstance();
    final fromSura = prefs.getInt(_keyRangeFromSura);
    final toSura = prefs.getInt(_keyRangeToSura);
    final from = prefs.getInt(_keyRangeFrom);
    final to = prefs.getInt(_keyRangeTo);
    if (fromSura != null && toSura != null && from != null && to != null) {
      if (fromSura < 1 ||
          fromSura > 114 ||
          toSura < 1 ||
          toSura > 114 ||
          from < 1 ||
          to < 1) {
        return null;
      }
      if ((toSura < fromSura) || (toSura == fromSura && to < from)) {
        return null;
      }
      return AyahPlaybackRange(
        fromSura: fromSura,
        fromAyah: from,
        toSura: toSura,
        toAyah: to,
      );
    }

    // توافق رجعي مع النسخة القديمة (نطاق داخل سورة واحدة فقط).
    final legacySura = prefs.getInt(_keyRangeSura);
    if (legacySura == null || from == null || to == null) return null;
    if (legacySura < 1 || legacySura > 114 || from < 1 || to < from) {
      return null;
    }
    return AyahPlaybackRange(
      fromSura: legacySura,
      fromAyah: from,
      toSura: legacySura,
      toAyah: to,
    );
  }

  Future<void> setPlaybackRange(AyahPlaybackRange range) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_keyRangeFromSura, range.fromSura);
    await prefs.setInt(_keyRangeToSura, range.toSura);
    // توافق رجعي: نكتب بداية السورة أيضاً في المفتاح القديم.
    await prefs.setInt(_keyRangeSura, range.fromSura);
    await prefs.setInt(_keyRangeFrom, range.fromAyah);
    await prefs.setInt(_keyRangeTo, range.toAyah);
  }

  Future<void> clearPlaybackRange() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keyRangeFromSura);
    await prefs.remove(_keyRangeToSura);
    await prefs.remove(_keyRangeSura);
    await prefs.remove(_keyRangeFrom);
    await prefs.remove(_keyRangeTo);
  }

  /// إظهار تأشير الآية كاملة أثناء التلاوة (إن false يبقى تأشير الكلمة فقط).
  /// الافتراضي عند أول تشغيل: false (مخفي) حتى يفعّله المستخدم.
  Future<bool> getShowAyahHighlight() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_keyShowAyahHighlight) ?? false;
  }

  Future<void> setShowAyahHighlight(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyShowAyahHighlight, value);
  }
}
