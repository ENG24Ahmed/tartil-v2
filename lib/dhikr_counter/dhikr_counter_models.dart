import 'dart:convert';

/// ذكر واحد: نص + هدف. هدف 0 يعني تسبيح حر بلا هدف.
class DhikrItem {
  final String text;
  final int target; // 0 = free/unlimited

  const DhikrItem({required this.text, required this.target});

  DhikrItem copyWith({String? text, int? target}) =>
      DhikrItem(text: text ?? this.text, target: target ?? this.target);

  Map<String, dynamic> toJson() => {'text': text, 'target': target};

  factory DhikrItem.fromJson(Map<String, dynamic> j) =>
      DhikrItem(text: j['text'] as String, target: j['target'] as int);
}

/// مجموعة أذكار
class DhikrGroup {
  final String name;
  final List<DhikrItem> items;

  /// true = مجموعة جاهزة (لا تُعدّل)، false = مخصصة
  final bool isPreset;

  const DhikrGroup({
    required this.name,
    required this.items,
    this.isPreset = false,
  });

  DhikrGroup copyWith({String? name, List<DhikrItem>? items, bool? isPreset}) =>
      DhikrGroup(
        name: name ?? this.name,
        items: items ?? this.items,
        isPreset: isPreset ?? this.isPreset,
      );

  Map<String, dynamic> toJson() => {
        'name': name,
        'items': items.map((e) => e.toJson()).toList(),
        'isPreset': isPreset,
      };

  factory DhikrGroup.fromJson(Map<String, dynamic> j) => DhikrGroup(
        name: j['name'] as String,
        items: (j['items'] as List)
            .map((e) => DhikrItem.fromJson(e as Map<String, dynamic>))
            .toList(),
        isPreset: j['isPreset'] as bool? ?? false,
      );

  static String encodeList(List<DhikrGroup> groups) =>
      jsonEncode(groups.map((g) => g.toJson()).toList());

  static List<DhikrGroup> decodeList(String raw) {
    final list = jsonDecode(raw) as List;
    return list
        .map((e) => DhikrGroup.fromJson(e as Map<String, dynamic>))
        .toList();
  }
}

/// نوع الجلسة
enum DhikrSessionType {
  group,
  single,
  free, // تسبيح حر بلا هدف
}

/// آخر جلسة محفوظة
class DhikrSession {
  final DhikrSessionType type;
  final String groupName;
  final List<DhikrItem> items;
  final int currentItemIndex;
  final int currentCount;

  const DhikrSession({
    required this.type,
    required this.groupName,
    required this.items,
    required this.currentItemIndex,
    required this.currentCount,
  });

  Map<String, dynamic> toJson() => {
        'type': type.name,
        'groupName': groupName,
        'items': items.map((e) => e.toJson()).toList(),
        'currentItemIndex': currentItemIndex,
        'currentCount': currentCount,
      };

  factory DhikrSession.fromJson(Map<String, dynamic> j) => DhikrSession(
        type: DhikrSessionType.values.firstWhere(
          (e) => e.name == j['type'],
          orElse: () => DhikrSessionType.group,
        ),
        groupName: j['groupName'] as String,
        items: (j['items'] as List)
            .map((e) => DhikrItem.fromJson(e as Map<String, dynamic>))
            .toList(),
        currentItemIndex: j['currentItemIndex'] as int? ?? 0,
        currentCount: j['currentCount'] as int? ?? 0,
      );
}

/// عنصر المفضلة — يمثل مجموعة أو ذكراً مفرداً
class DhikrFavorite {
  /// معرف فريد: "pg:{name}" للمجموعات الجاهزة، "sd:{text}" للمفردة، "cg:{name}" للمخصصة
  final String favoriteId;
  final String displayName;
  final List<DhikrItem> items;
  final DhikrSessionType sessionType;

  const DhikrFavorite({
    required this.favoriteId,
    required this.displayName,
    required this.items,
    required this.sessionType,
  });

  Map<String, dynamic> toJson() => {
        'favoriteId': favoriteId,
        'displayName': displayName,
        'items': items.map((e) => e.toJson()).toList(),
        'sessionType': sessionType.name,
      };

  factory DhikrFavorite.fromJson(Map<String, dynamic> j) => DhikrFavorite(
        favoriteId: j['favoriteId'] as String,
        displayName: j['displayName'] as String,
        items: (j['items'] as List)
            .map((e) => DhikrItem.fromJson(e as Map<String, dynamic>))
            .toList(),
        sessionType: DhikrSessionType.values.firstWhere(
          (e) => e.name == j['sessionType'],
          orElse: () => DhikrSessionType.group,
        ),
      );

  static String encodeList(List<DhikrFavorite> favs) =>
      jsonEncode(favs.map((f) => f.toJson()).toList());

  static List<DhikrFavorite> decodeList(String raw) {
    final list = jsonDecode(raw) as List;
    return list
        .map((e) => DhikrFavorite.fromJson(e as Map<String, dynamic>))
        .toList();
  }
}
