import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'dhikr_counter_models.dart';

const _kCustomGroupsKey = 'dhikr_counter_custom_groups';
const _kLastSessionKey = 'dhikr_counter_last_session';
const _kFavoritesKey = 'dhikr_counter_favorites';

/// تخزين واسترجاع بيانات عداد الذكر
class DhikrCounterStorage {
  // ──────────── المجموعات المخصصة ────────────

  static Future<List<DhikrGroup>> loadCustomGroups() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kCustomGroupsKey);
      if (raw == null || raw.isEmpty) return [];
      return DhikrGroup.decodeList(raw);
    } catch (_) {
      return [];
    }
  }

  static Future<void> saveCustomGroups(List<DhikrGroup> groups) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kCustomGroupsKey, DhikrGroup.encodeList(groups));
  }

  static Future<void> addCustomGroup(DhikrGroup group) async {
    final groups = await loadCustomGroups();
    groups.add(group.copyWith(isPreset: false));
    await saveCustomGroups(groups);
  }

  static Future<void> deleteCustomGroup(int index) async {
    final groups = await loadCustomGroups();
    if (index < 0 || index >= groups.length) return;
    groups.removeAt(index);
    await saveCustomGroups(groups);
  }

  static Future<void> updateCustomGroup(int index, DhikrGroup group) async {
    final groups = await loadCustomGroups();
    if (index < 0 || index >= groups.length) return;
    groups[index] = group.copyWith(isPreset: false);
    await saveCustomGroups(groups);
  }

  // ──────────── المفضلة ────────────

  static Future<List<DhikrFavorite>> loadFavorites() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kFavoritesKey);
      if (raw == null || raw.isEmpty) return [];
      return DhikrFavorite.decodeList(raw);
    } catch (_) {
      return [];
    }
  }

  static Future<void> saveFavorites(List<DhikrFavorite> favs) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kFavoritesKey, DhikrFavorite.encodeList(favs));
  }

  // ──────────── آخر جلسة ────────────

  static Future<void> saveLastSession(DhikrSession session) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kLastSessionKey, jsonEncode(session.toJson()));
    } catch (_) {}
  }

  static Future<DhikrSession?> loadLastSession() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kLastSessionKey);
      if (raw == null || raw.isEmpty) return null;
      return DhikrSession.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  static Future<void> clearLastSession() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kLastSessionKey);
  }
}
