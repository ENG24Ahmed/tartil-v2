import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:vibration/vibration.dart';
import 'dhikr_counter_models.dart';
import 'dhikr_counter_presets.dart';
import 'dhikr_counter_storage.dart';

// ─────────────────────────────────────────────
//  ألوان ثابتة منسجمة مع ثيم ترتيلا
// ─────────────────────────────────────────────
class _DC {
  static const bg = Color(0xFFF0F7F1);
  static const bgDark = Color(0xFF051813);
  static const primary = Color(0xFF1B5E20);
  static const primaryLight = Color(0xFF2E7D32);
  static const accent = Color(0xFF81C784);
  static const card = Colors.white;
  static const cardDark = Color(0xFF0A1F16);
  static const subtitle = Color(0xFF616161);
  static const subtitleDark = Color(0xFFB8C9C0);
  static const divider = Color(0xFFE0E0E0);
  static const dividerDark = Color(0xFF1E3A2C);
  static const starGold = Color(0xFFF9A825);
}

// ─────────────────────────────────────────────
//  الشاشة الرئيسية
// ─────────────────────────────────────────────
class DhikrCounterScreen extends StatefulWidget {
  const DhikrCounterScreen({super.key});

  @override
  State<DhikrCounterScreen> createState() => _DhikrCounterScreenState();
}

class _DhikrCounterScreenState extends State<DhikrCounterScreen> {
  List<DhikrGroup> _customGroups = [];
  List<DhikrFavorite> _favorites = [];
  DhikrSession? _lastSession;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    final groups = await DhikrCounterStorage.loadCustomGroups();
    final favs = await DhikrCounterStorage.loadFavorites();
    final session = await DhikrCounterStorage.loadLastSession();
    if (mounted) {
      setState(() {
        _customGroups = groups;
        _favorites = favs;
        _lastSession = session;
        _loading = false;
      });
    }
  }

  bool get _isDark => Theme.of(context).brightness == Brightness.dark;
  Color get _bg => _isDark ? _DC.bgDark : _DC.bg;
  Color get _cardColor => _isDark ? _DC.cardDark : _DC.card;
  Color get _titleColor => _isDark ? Colors.white : _DC.primary;
  Color get _subtitleColor => _isDark ? _DC.subtitleDark : _DC.subtitle;
  Color get _dividerColor => _isDark ? _DC.dividerDark : _DC.divider;
  Color get _accentColor => _isDark ? _DC.accent : _DC.primaryLight;

  // ── المفضلة ──────────────────────────────────────
  bool _isFavorited(String favId) => _favorites.any((f) => f.favoriteId == favId);

  void _handleStarTap(DhikrFavorite fav) async {
    final favs = List.of(_favorites);
    final idx = favs.indexWhere((f) => f.favoriteId == fav.favoriteId);
    if (idx >= 0) {
      favs.removeAt(idx);
    } else {
      favs.add(fav);
    }
    await DhikrCounterStorage.saveFavorites(favs);
    if (mounted) setState(() => _favorites = favs);
  }

  void _removeFavorite(String favId) async {
    final favs = List.of(_favorites)..removeWhere((f) => f.favoriteId == favId);
    await DhikrCounterStorage.saveFavorites(favs);
    if (mounted) setState(() => _favorites = favs);
  }

  // ── التسبيح الحر ────────────────────────────────
  void _openFreeCount() {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => DhikrCountingScreen(
        groupName: 'التسبيح الحر',
        items: const [DhikrItem(text: 'أستغفر الله', target: 0)],
        type: DhikrSessionType.free,
        isDark: _isDark,
      ),
    )).then((_) => _loadData());
  }

  // ── فتح شاشة تعديل الهدف ثم العد ─────────────────
  void _openEditAndStart(DhikrGroup group) async {
    final result = await showModalBottomSheet<_EditResult>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _EditTargetSheet(
        group: group,
        isDark: _isDark,
        cardColor: _cardColor,
        titleColor: _titleColor,
        subtitleColor: _subtitleColor,
        accentColor: _accentColor,
        dividerColor: _dividerColor,
      ),
    );
    if (result == null || !mounted) return;

    if (result.saveToMine) {
      final newName = group.isPreset
          ? '${group.name} - نسخة مخصصة'
          : group.name;
      await DhikrCounterStorage.addCustomGroup(
          DhikrGroup(name: newName, items: result.items, isPreset: false));
      final updated = await DhikrCounterStorage.loadCustomGroups();
      if (mounted) setState(() => _customGroups = updated);
    }

    if (!mounted) return;
    _startCounting(
      groupName: group.name,
      items: result.items,
      type: DhikrSessionType.group,
    );
  }

  void _openSingleAndStart(DhikrItem item) async {
    final result = await showModalBottomSheet<_EditResult>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _EditTargetSheet(
        group: DhikrGroup(name: item.text, items: [item], isPreset: true),
        isDark: _isDark,
        cardColor: _cardColor,
        titleColor: _titleColor,
        subtitleColor: _subtitleColor,
        accentColor: _accentColor,
        dividerColor: _dividerColor,
        isSingle: true,
      ),
    );
    if (result == null || !mounted) return;
    final editedItem = result.items.isNotEmpty ? result.items.first : item;
    _startCounting(
      groupName: editedItem.text,
      items: [editedItem],
      type: DhikrSessionType.single,
    );
  }

  void _openFavorite(DhikrFavorite fav) {
    if (fav.sessionType == DhikrSessionType.single) {
      _openSingleAndStart(fav.items.first);
    } else {
      _openEditAndStart(
          DhikrGroup(name: fav.displayName, items: fav.items, isPreset: false));
    }
  }

  void _startCounting({
    required String groupName,
    required List<DhikrItem> items,
    required DhikrSessionType type,
    int startIndex = 0,
    int startCount = 0,
  }) {
    if (items.isEmpty) return;
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => DhikrCountingScreen(
        groupName: groupName,
        items: items,
        type: type,
        startItemIndex: startIndex,
        startCount: startCount,
        isDark: _isDark,
      ),
    )).then((_) => _loadData());
  }

  void _resumeLastSession() {
    final s = _lastSession;
    if (s == null) return;
    _startCounting(
      groupName: s.groupName,
      items: s.items,
      type: s.type,
      startIndex: s.currentItemIndex,
      startCount: s.currentCount,
    );
  }

  // ── حذف مجموعة مخصصة ──────────────────────────
  void _deleteCustomGroup(int index) async {
    await DhikrCounterStorage.deleteCustomGroup(index);
    final updated = await DhikrCounterStorage.loadCustomGroups();
    if (mounted) setState(() => _customGroups = updated);
  }

  void _confirmDeleteCustomGroup(int index) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          backgroundColor: _cardColor,
          title: Text('حذف المجموعة',
              style: TextStyle(color: _titleColor, fontSize: 16)),
          content: Text('هل تريد حذف هذه المجموعة؟',
              style: TextStyle(color: _subtitleColor)),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text('إلغاء', style: TextStyle(color: _subtitleColor)),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text('حذف', style: TextStyle(color: Colors.red.shade700)),
            ),
          ],
        ),
      ),
    );
    if (confirm == true) _deleteCustomGroup(index);
  }

  // ── إنشاء مجموعة مخصصة ────────────────────────
  void _openCreateGroup() async {
    final newGroup = await showModalBottomSheet<DhikrGroup>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _CreateGroupSheet(
        isDark: _isDark,
        cardColor: _cardColor,
        titleColor: _titleColor,
        subtitleColor: _subtitleColor,
        accentColor: _accentColor,
        dividerColor: _dividerColor,
      ),
    );
    if (newGroup == null || !mounted) return;
    await DhikrCounterStorage.addCustomGroup(newGroup);
    final updated = await DhikrCounterStorage.loadCustomGroups();
    if (mounted) setState(() => _customGroups = updated);
  }

  // ────────────────────────────────────────────────────
  //  Build
  // ────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        backgroundColor: _bg,
        appBar: AppBar(
          backgroundColor:
              _isDark ? _DC.bgDark : _DC.primary,
          foregroundColor: Colors.white,
          elevation: 0,
          centerTitle: true,
          title: const Text(
            'عداد الذكر',
            style: TextStyle(
                fontSize: 18, fontWeight: FontWeight.w600, color: Colors.white),
          ),
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : _buildBody(),
      ),
    );
  }

  Widget _buildBody() {
    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(child: _buildHeader()),

        // متابعة الجلسة
        if (_lastSession != null) ...[
          SliverToBoxAdapter(child: _buildSectionTitle('متابعة الجلسة')),
          SliverToBoxAdapter(child: _buildLastSessionCard()),
        ],

        // التسبيح الحر
        SliverToBoxAdapter(child: _buildFreeCountCard()),

        // المفضلة
        SliverToBoxAdapter(child: _buildSectionTitle('المفضلة')),
        if (_favorites.isEmpty)
          SliverToBoxAdapter(child: _buildEmptyFavorites())
        else
          SliverList(
            delegate: SliverChildBuilderDelegate(
              (_, i) => _buildFavoriteCard(_favorites[i]),
              childCount: _favorites.length,
            ),
          ),

        // المجموعات الجاهزة
        SliverToBoxAdapter(child: _buildSectionTitle('المجموعات الجاهزة')),
        SliverList(
          delegate: SliverChildBuilderDelegate(
            (_, i) => _buildPresetGroupCard(kPresetGroups[i]),
            childCount: kPresetGroups.length,
          ),
        ),

        // ذكر مفرد
        SliverToBoxAdapter(child: _buildSectionTitle('ذكر مفرد')),
        SliverList(
          delegate: SliverChildBuilderDelegate(
            (_, i) => _buildSingleDhikrCard(kPresetSingleDhikrs[i]),
            childCount: kPresetSingleDhikrs.length,
          ),
        ),

        // مجموعات مخصصة (إن وجدت)
        if (_customGroups.isNotEmpty) ...[
          SliverToBoxAdapter(child: _buildSectionTitle('مجموعات مخصصة')),
          SliverList(
            delegate: SliverChildBuilderDelegate(
              (_, i) => _buildCustomGroupCard(_customGroups[i], i),
              childCount: _customGroups.length,
            ),
          ),
        ],

        // زر إنشاء مجموعة
        SliverToBoxAdapter(child: _buildCreateGroupButton()),
        const SliverToBoxAdapter(child: SizedBox(height: 32)),
      ],
    );
  }

  // ── Widgets ────────────────────────────────────────

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
      child: Text(
        'سبحة رقمية لعدّ الاستغفار والتسبيح والأذكار',
        textAlign: TextAlign.center,
        style: TextStyle(fontSize: 13, color: _subtitleColor, height: 1.6),
      ),
    );
  }

  Widget _buildSectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
      child: Row(
        children: [
          Container(
            width: 4,
            height: 18,
            decoration: BoxDecoration(
              color: _accentColor,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 8),
          Text(title,
              style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: _titleColor)),
        ],
      ),
    );
  }

  Widget _buildFreeCountCard() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Material(
        color: _accentColor.withValues(alpha: _isDark ? 0.22 : 0.13),
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: _openFreeCount,
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                  color: _accentColor.withValues(alpha: 0.4), width: 1.2),
            ),
            padding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _accentColor.withValues(alpha: 0.2),
                  ),
                  child: Icon(Icons.all_inclusive,
                      color: _accentColor, size: 24),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('التسبيح الحر',
                          style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                              color: _titleColor)),
                      const SizedBox(height: 2),
                      Text('عدّ مفتوح بدون هدف',
                          style: TextStyle(
                              fontSize: 12, color: _subtitleColor)),
                    ],
                  ),
                ),
                Icon(Icons.chevron_left, color: _subtitleColor, size: 20),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildEmptyFavorites() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Text(
        'اضغط النجمة بجانب أي ذكر أو مجموعة لإضافتها هنا',
        textAlign: TextAlign.center,
        style: TextStyle(fontSize: 12, color: _subtitleColor, height: 1.5),
      ),
    );
  }

  Widget _buildFavoriteCard(DhikrFavorite fav) {
    final isSingle = fav.sessionType == DhikrSessionType.single;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Material(
        color: _cardColor,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () => _openFavorite(fav),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                  color: _DC.starGold.withValues(alpha: 0.5), width: 1),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: _DC.starGold.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(Icons.star,
                      color: _DC.starGold, size: 22),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        fav.displayName,
                        style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: _titleColor),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (!isSingle && fav.items.length > 1) ...[
                        const SizedBox(height: 2),
                        Text('${fav.items.length} أذكار',
                            style: TextStyle(
                                fontSize: 12, color: _subtitleColor)),
                      ],
                    ],
                  ),
                ),
                GestureDetector(
                  onTap: () => _removeFavorite(fav.favoriteId),
                  child: const Padding(
                    padding: EdgeInsets.all(6),
                    child: Icon(Icons.star,
                        color: _DC.starGold, size: 22),
                  ),
                ),
                const SizedBox(width: 2),
                Icon(Icons.chevron_left, color: _subtitleColor, size: 20),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPresetGroupCard(DhikrGroup group) {
    final favId = 'pg:${group.name}';
    final isFav = _isFavorited(favId);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Material(
        color: _cardColor,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () => _openEditAndStart(group),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: _isDark
                    ? Colors.white.withValues(alpha: 0.1)
                    : _DC.divider,
              ),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: _accentColor.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(Icons.format_list_numbered_rtl,
                      color: _accentColor, size: 22),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(group.name,
                          style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: _titleColor)),
                      const SizedBox(height: 3),
                      Text(
                        '${group.items.length} أذكار • ${group.items.first.text}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 12, color: _subtitleColor),
                      ),
                    ],
                  ),
                ),
                GestureDetector(
                  onTap: () => _handleStarTap(DhikrFavorite(
                    favoriteId: favId,
                    displayName: group.name,
                    items: group.items,
                    sessionType: DhikrSessionType.group,
                  )),
                  child: Padding(
                    padding: const EdgeInsets.all(6),
                    child: Icon(
                      isFav ? Icons.star : Icons.star_border,
                      color: isFav ? _DC.starGold : _subtitleColor,
                      size: 22,
                    ),
                  ),
                ),
                Icon(Icons.chevron_left, color: _subtitleColor, size: 20),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSingleDhikrCard(DhikrItem item) {
    final favId = 'sd:${item.text}';
    final isFav = _isFavorited(favId);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Material(
        color: _cardColor,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () => _openSingleAndStart(item),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: _isDark
                    ? Colors.white.withValues(alpha: 0.1)
                    : _DC.divider,
              ),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: _accentColor.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(Icons.radio_button_checked_outlined,
                      color: _accentColor, size: 20),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    item.text,
                    style: TextStyle(
                        fontSize: 14,
                        color: _titleColor,
                        fontWeight: FontWeight.w500),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  '${item.target}×',
                  style: TextStyle(
                      fontSize: 13,
                      color: _accentColor,
                      fontWeight: FontWeight.bold),
                ),
                GestureDetector(
                  onTap: () => _handleStarTap(DhikrFavorite(
                    favoriteId: favId,
                    displayName: item.text,
                    items: [item],
                    sessionType: DhikrSessionType.single,
                  )),
                  child: Padding(
                    padding: const EdgeInsets.all(6),
                    child: Icon(
                      isFav ? Icons.star : Icons.star_border,
                      color: isFav ? _DC.starGold : _subtitleColor,
                      size: 22,
                    ),
                  ),
                ),
                Icon(Icons.chevron_left, color: _subtitleColor, size: 20),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCustomGroupCard(DhikrGroup group, int index) {
    final favId = 'cg:${group.name}';
    final isFav = _isFavorited(favId);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Material(
        color: _cardColor,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () => _openEditAndStart(group),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: _isDark
                    ? Colors.white.withValues(alpha: 0.1)
                    : _DC.divider,
              ),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: _accentColor.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(Icons.playlist_add_check,
                      color: _accentColor, size: 22),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(group.name,
                          style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: _titleColor)),
                      const SizedBox(height: 3),
                      Text(
                        '${group.items.length} أذكار',
                        style: TextStyle(
                            fontSize: 12, color: _subtitleColor),
                      ),
                    ],
                  ),
                ),
                GestureDetector(
                  onTap: () => _handleStarTap(DhikrFavorite(
                    favoriteId: favId,
                    displayName: group.name,
                    items: group.items,
                    sessionType: DhikrSessionType.group,
                  )),
                  child: Padding(
                    padding: const EdgeInsets.all(6),
                    child: Icon(
                      isFav ? Icons.star : Icons.star_border,
                      color: isFav ? _DC.starGold : _subtitleColor,
                      size: 22,
                    ),
                  ),
                ),
                GestureDetector(
                  onTap: () => _confirmDeleteCustomGroup(index),
                  child: Padding(
                    padding: const EdgeInsets.all(6),
                    child: Icon(Icons.delete_outline,
                        size: 20, color: _subtitleColor),
                  ),
                ),
                Icon(Icons.chevron_left, color: _subtitleColor, size: 20),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCreateGroupButton() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
      child: ElevatedButton.icon(
        style: ElevatedButton.styleFrom(
          backgroundColor: _accentColor,
          foregroundColor: Colors.white,
          minimumSize: const Size(double.infinity, 50),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          elevation: 0,
        ),
        onPressed: _openCreateGroup,
        icon: const Icon(Icons.add, size: 20),
        label: const Text('إنشاء مجموعة',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
      ),
    );
  }

  Widget _buildLastSessionCard() {
    final s = _lastSession!;
    final subtitle = _sessionSubtitle(s);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Material(
        color: _accentColor.withValues(alpha: _isDark ? 0.2 : 0.12),
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: _resumeLastSession,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                Icon(Icons.history, color: _accentColor, size: 22),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(s.groupName,
                          style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: _titleColor),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis),
                      const SizedBox(height: 2),
                      Text(subtitle,
                          style: TextStyle(
                              fontSize: 12, color: _subtitleColor)),
                    ],
                  ),
                ),
                Text('متابعة',
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: _accentColor)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _sessionSubtitle(DhikrSession s) {
    switch (s.type) {
      case DhikrSessionType.free:
        final text =
            s.items.isNotEmpty ? s.items.first.text : 'أستغفر الله';
        return '$text • العدد ${s.currentCount}';
      case DhikrSessionType.group:
        return 'ذكر ${s.currentItemIndex + 1} من ${s.items.length} • العدد ${s.currentCount}';
      case DhikrSessionType.single:
        final target =
            s.items.isNotEmpty ? s.items.first.target : 0;
        return 'العدد ${s.currentCount} من $target';
    }
  }
}

// ─────────────────────────────────────────────
//  نتيجة شاشة تعديل الهدف
// ─────────────────────────────────────────────
class _EditResult {
  final List<DhikrItem> items;
  final bool saveToMine;
  const _EditResult({required this.items, required this.saveToMine});
}

// ─────────────────────────────────────────────
//  شاشة تعديل الهدف (BottomSheet)
// ─────────────────────────────────────────────
class _EditTargetSheet extends StatefulWidget {
  final DhikrGroup group;
  final bool isSingle;
  final bool isDark;
  final Color cardColor;
  final Color titleColor;
  final Color subtitleColor;
  final Color accentColor;
  final Color dividerColor;

  const _EditTargetSheet({
    required this.group,
    required this.isDark,
    required this.cardColor,
    required this.titleColor,
    required this.subtitleColor,
    required this.accentColor,
    required this.dividerColor,
    this.isSingle = false,
  });

  @override
  State<_EditTargetSheet> createState() => _EditTargetSheetState();
}

class _EditTargetSheetState extends State<_EditTargetSheet> {
  late List<DhikrItem> _items;
  late List<TextEditingController> _controllers;

  @override
  void initState() {
    super.initState();
    _items = widget.group.items.map((e) => e.copyWith()).toList();
    _controllers = _items
        .map((e) => TextEditingController(text: e.target.toString()))
        .toList();
  }

  @override
  void dispose() {
    for (final c in _controllers) {
      c.dispose();
    }
    super.dispose();
  }

  void _deleteItem(int i) {
    if (_items.length <= 1) return;
    _controllers[i].dispose();
    setState(() {
      _items.removeAt(i);
      _controllers.removeAt(i);
    });
  }

  void _confirm(bool save) {
    final finalItems = List<DhikrItem>.generate(_items.length, (i) {
      final n = int.tryParse(_controllers[i].text) ?? _items[i].target;
      return _items[i].copyWith(target: n > 0 ? n : _items[i].target);
    });
    Navigator.pop(context, _EditResult(items: finalItems, saveToMine: save));
  }

  @override
  Widget build(BuildContext context) {
    final bg = widget.isDark ? _DC.bgDark : _DC.bg;
    return Directionality(
      textDirection: TextDirection.rtl,
      child: DraggableScrollableSheet(
        initialChildSize: 0.55,
        minChildSize: 0.4,
        maxChildSize: 0.92,
        expand: false,
        builder: (_, scrollCtrl) => Container(
          decoration: BoxDecoration(
            color: bg,
            borderRadius:
                const BorderRadius.vertical(top: Radius.circular(20)),
          ),
          child: Column(
            children: [
              const SizedBox(height: 8),
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: widget.dividerColor,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 12),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Text('تعديل الهدف',
                    style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: widget.titleColor)),
              ),
              const SizedBox(height: 4),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Text(widget.group.name,
                    style: TextStyle(
                        fontSize: 13, color: widget.subtitleColor)),
              ),
              const SizedBox(height: 12),
              Expanded(
                child: ListView.separated(
                  controller: scrollCtrl,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  itemCount: _items.length,
                  separatorBuilder: (_, __) =>
                      Divider(height: 1, color: widget.dividerColor),
                  itemBuilder: (_, i) => _buildItemRow(i),
                ),
              ),
              Padding(
                padding: EdgeInsets.fromLTRB(
                  16,
                  12,
                  16,
                  MediaQuery.of(context).viewInsets.bottom + 16,
                ),
                child: Column(
                  children: [
                    SizedBox(
                      width: double.infinity,
                      height: 48,
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: widget.accentColor,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12)),
                          elevation: 0,
                        ),
                        onPressed: () => _confirm(false),
                        child: const Text('ابدأ',
                            style: TextStyle(
                                fontSize: 16, fontWeight: FontWeight.w700)),
                      ),
                    ),
                    if (!widget.isSingle) ...[
                      const SizedBox(height: 8),
                      SizedBox(
                        width: double.infinity,
                        height: 44,
                        child: OutlinedButton(
                          style: OutlinedButton.styleFrom(
                            foregroundColor: widget.accentColor,
                            side: BorderSide(color: widget.accentColor),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12)),
                          ),
                          onPressed: () => _confirm(true),
                          child: const Text('حفظ نسخة مخصصة',
                              style: TextStyle(fontSize: 14)),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildItemRow(int i) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          Expanded(
            child: Text(
              _items[i].text,
              style: TextStyle(fontSize: 13, color: widget.titleColor),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 12),
          SizedBox(
            width: 72,
            height: 40,
            child: TextField(
              controller: _controllers[i],
              keyboardType: TextInputType.number,
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                  color: widget.titleColor),
              decoration: InputDecoration(
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(color: widget.dividerColor),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(color: widget.dividerColor),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(color: widget.accentColor),
                ),
                filled: true,
                fillColor: widget.cardColor,
              ),
            ),
          ),
          if (_items.length > 1) ...[
            const SizedBox(width: 8),
            GestureDetector(
              onTap: () => _deleteItem(i),
              child: Icon(Icons.remove_circle_outline,
                  color: Colors.red.shade400, size: 20),
            ),
          ],
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────
//  إنشاء مجموعة مخصصة
// ─────────────────────────────────────────────
class _CreateGroupSheet extends StatefulWidget {
  final bool isDark;
  final Color cardColor;
  final Color titleColor;
  final Color subtitleColor;
  final Color accentColor;
  final Color dividerColor;

  const _CreateGroupSheet({
    required this.isDark,
    required this.cardColor,
    required this.titleColor,
    required this.subtitleColor,
    required this.accentColor,
    required this.dividerColor,
  });

  @override
  State<_CreateGroupSheet> createState() => _CreateGroupSheetState();
}

class _CreateGroupSheetState extends State<_CreateGroupSheet> {
  final _nameCtrl = TextEditingController();
  final List<_DhikrEntry> _entries = [_DhikrEntry()];

  @override
  void dispose() {
    _nameCtrl.dispose();
    for (final e in _entries) {
      e.dispose();
    }
    super.dispose();
  }

  void _addEntry() => setState(() => _entries.add(_DhikrEntry()));

  void _removeEntry(int i) {
    if (_entries.length <= 1) return;
    _entries[i].dispose();
    setState(() => _entries.removeAt(i));
  }

  void _save() {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('الرجاء إدخال اسم المجموعة')));
      return;
    }
    final items = <DhikrItem>[];
    for (final e in _entries) {
      final text = e.textCtrl.text.trim();
      final target = int.tryParse(e.targetCtrl.text) ?? 100;
      if (text.isNotEmpty) {
        items.add(DhikrItem(text: text, target: target > 0 ? target : 1));
      }
    }
    if (items.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('الرجاء إضافة ذكر واحد على الأقل')));
      return;
    }
    Navigator.pop(
        context, DhikrGroup(name: name, items: items, isPreset: false));
  }

  @override
  Widget build(BuildContext context) {
    final bg = widget.isDark ? _DC.bgDark : _DC.bg;
    return Directionality(
      textDirection: TextDirection.rtl,
      child: DraggableScrollableSheet(
        initialChildSize: 0.7,
        minChildSize: 0.5,
        maxChildSize: 0.95,
        expand: false,
        builder: (_, scrollCtrl) => Container(
          decoration: BoxDecoration(
            color: bg,
            borderRadius:
                const BorderRadius.vertical(top: Radius.circular(20)),
          ),
          child: Column(
            children: [
              const SizedBox(height: 8),
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: widget.dividerColor,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 12),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Text('إنشاء مجموعة جديدة',
                    style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: widget.titleColor)),
              ),
              const SizedBox(height: 12),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: TextField(
                  controller: _nameCtrl,
                  style:
                      TextStyle(color: widget.titleColor, fontSize: 14),
                  decoration: InputDecoration(
                    hintText: 'اسم المجموعة',
                    hintStyle: TextStyle(color: widget.subtitleColor),
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: BorderSide(color: widget.dividerColor)),
                    enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: BorderSide(color: widget.dividerColor)),
                    focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: BorderSide(color: widget.accentColor)),
                    filled: true,
                    fillColor: widget.cardColor,
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 12),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Expanded(
                child: ListView.separated(
                  controller: scrollCtrl,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  itemCount: _entries.length + 1,
                  separatorBuilder: (_, __) =>
                      Divider(height: 1, color: widget.dividerColor),
                  itemBuilder: (_, i) {
                    if (i == _entries.length) {
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        child: TextButton.icon(
                          onPressed: _addEntry,
                          icon: Icon(Icons.add, color: widget.accentColor),
                          label: Text('إضافة ذكر',
                              style: TextStyle(color: widget.accentColor)),
                        ),
                      );
                    }
                    return _buildEntryRow(i);
                  },
                ),
              ),
              Padding(
                padding: EdgeInsets.fromLTRB(
                  16,
                  8,
                  16,
                  MediaQuery.of(context).viewInsets.bottom + 16,
                ),
                child: SizedBox(
                  width: double.infinity,
                  height: 48,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: widget.accentColor,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                      elevation: 0,
                    ),
                    onPressed: _save,
                    child: const Text('حفظ المجموعة',
                        style: TextStyle(
                            fontSize: 15, fontWeight: FontWeight.w600)),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildEntryRow(int i) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _entries[i].textCtrl,
              style: TextStyle(color: widget.titleColor, fontSize: 13),
              decoration: InputDecoration(
                hintText: 'نص الذكر',
                hintStyle:
                    TextStyle(color: widget.subtitleColor, fontSize: 12),
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(color: widget.dividerColor)),
                enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(color: widget.dividerColor)),
                focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(color: widget.accentColor)),
                filled: true,
                fillColor: widget.cardColor,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
              ),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 68,
            child: TextField(
              controller: _entries[i].targetCtrl,
              keyboardType: TextInputType.number,
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: 13,
                  color: widget.titleColor,
                  fontWeight: FontWeight.bold),
              decoration: InputDecoration(
                hintText: '100',
                hintStyle:
                    TextStyle(color: widget.subtitleColor, fontSize: 12),
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(color: widget.dividerColor)),
                enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(color: widget.dividerColor)),
                focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(color: widget.accentColor)),
                filled: true,
                fillColor: widget.cardColor,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 10),
              ),
            ),
          ),
          const SizedBox(width: 6),
          GestureDetector(
            onTap: () => _removeEntry(i),
            child: Icon(
              Icons.remove_circle_outline,
              color: _entries.length > 1
                  ? Colors.red.shade400
                  : widget.dividerColor,
              size: 20,
            ),
          ),
        ],
      ),
    );
  }
}

class _DhikrEntry {
  final textCtrl = TextEditingController();
  final targetCtrl = TextEditingController(text: '100');

  void dispose() {
    textCtrl.dispose();
    targetCtrl.dispose();
  }
}

// ─────────────────────────────────────────────
//  شاشة العد
// ─────────────────────────────────────────────
class DhikrCountingScreen extends StatefulWidget {
  final String groupName;
  final List<DhikrItem> items;
  final DhikrSessionType type;
  final int startItemIndex;
  final int startCount;
  final bool isDark;

  const DhikrCountingScreen({
    super.key,
    required this.groupName,
    required this.items,
    required this.type,
    required this.isDark,
    this.startItemIndex = 0,
    this.startCount = 0,
  });

  @override
  State<DhikrCountingScreen> createState() => _DhikrCountingScreenState();
}

class _DhikrCountingScreenState extends State<DhikrCountingScreen> {
  late int _currentIndex;
  late int _count;
  late String _freeText; // نص الذكر الحر (يمكن تعديله)
  bool _completed = false;
  /// true أثناء فاصل الانتقال بين ذكر وذكر داخل المجموعة
  bool _isTransitioning = false;

  @override
  void initState() {
    super.initState();
    _currentIndex =
        widget.startItemIndex.clamp(0, widget.items.length - 1);
    _count = widget.startCount;
    _freeText =
        widget.items.isNotEmpty ? widget.items.first.text : 'أستغفر الله';
    _saveSession();
  }

  bool get _isFree => widget.type == DhikrSessionType.free;
  bool get _isSingle => widget.type == DhikrSessionType.single;

  DhikrItem get _currentItem => _isFree
      ? DhikrItem(text: _freeText, target: 0)
      : widget.items[_currentIndex];

  Color get _bg => widget.isDark ? _DC.bgDark : _DC.bg;
  Color get _cardColor => widget.isDark ? _DC.cardDark : _DC.card;
  Color get _titleColor => widget.isDark ? Colors.white : _DC.primary;
  Color get _subtitleColor =>
      widget.isDark ? _DC.subtitleDark : _DC.subtitle;
  Color get _accentColor =>
      widget.isDark ? _DC.accent : _DC.primaryLight;

  void _increment() {
    if (_completed || _isTransitioning) return;
    HapticFeedback.lightImpact();
    setState(() => _count++);

    if (!_isFree && _count >= _currentItem.target) {
      _onTargetReached();
    } else {
      _saveSession();
    }
  }

  Future<void> _onTargetReached() async {
    final hasVibrator = await Vibration.hasVibrator();

    if (_isSingle) {
      // ── ذكر مفرد: اهتزاز متوسط ──────────────────
      if (hasVibrator == true) Vibration.vibrate(duration: 160);
      if (!mounted) return;
      setState(() => _completed = true);
      await DhikrCounterStorage.clearLastSession();
      return;
    }

    if (_currentIndex < widget.items.length - 1) {
      // ── اكتمال ذكر داخل مجموعة مع وجود ذكر بعده ──
      if (hasVibrator == true) {
        try {
          // نمط مزدوج: قصير + أطول للتمييز الواضح
          Vibration.vibrate(pattern: [0, 80, 70, 140]);
        } catch (_) {
          Vibration.vibrate(duration: 180);
        }
      }

      // فاصل انتقال مع حماية من setState بعد dispose
      if (!mounted) return;
      setState(() => _isTransitioning = true);

      await Future.delayed(const Duration(milliseconds: 900));

      if (!mounted) return;
      setState(() {
        _currentIndex++;
        _count = 0;
        _isTransitioning = false;
      });
      _saveSession();
    } else {
      // ── اكتمال المجموعة كاملة: اهتزاز أقوى وأطول ──
      if (hasVibrator == true) {
        try {
          Vibration.vibrate(pattern: [0, 120, 80, 180, 80, 220]);
        } catch (_) {
          Vibration.vibrate(duration: 300);
        }
      }
      if (!mounted) return;
      setState(() => _completed = true);
      await DhikrCounterStorage.clearLastSession();
    }
  }

  Future<void> _saveSession() async {
    await DhikrCounterStorage.saveLastSession(DhikrSession(
      type: widget.type,
      groupName: widget.groupName,
      items: _isFree
          ? [DhikrItem(text: _freeText, target: 0)]
          : widget.items,
      currentItemIndex: _currentIndex,
      currentCount: _count,
    ));
  }

  void _resetCurrent() {
    setState(() {
      _count = 0;
      _completed = false;
      _isTransitioning = false;
    });
    _saveSession();
  }

  void _reset() {
    setState(() {
      _currentIndex = 0;
      _count = 0;
      _completed = false;
      _isTransitioning = false;
    });
    _saveSession();
  }

  void _editFreeText() async {
    final result = await showDialog<String>(
      context: context,
      builder: (_) => _EditFreeTextDialog(
        initialText: _freeText,
        accentColor: _accentColor,
        titleColor: _titleColor,
        subtitleColor: _subtitleColor,
        cardColor: _cardColor,
      ),
    );
    if (result != null && result.isNotEmpty && mounted) {
      setState(() => _freeText = result);
      _saveSession();
    }
  }

  // ── Build ────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        backgroundColor: _bg,
        appBar: AppBar(
          backgroundColor: widget.isDark ? _DC.bgDark : _DC.primary,
          foregroundColor: Colors.white,
          elevation: 0,
          centerTitle: true,
          title: Text(
            widget.groupName,
            style: const TextStyle(fontSize: 16, color: Colors.white),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          // نفس أسلوب زر الرجوع: Flutter يضيفه تلقائياً بلون أبيض من foregroundColor
        ),
        body: _completed ? _buildCompletedView() : _buildCountingView(),
      ),
    );
  }

  Widget _buildCountingView() {
    final sw = MediaQuery.of(context).size.width;
    final hMargin = sw * 0.05;

    return SafeArea(
      child: Column(
        children: [
          // ── منطقة العد الواسعة ──────────────────────
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _increment,
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: hMargin),
                child: Column(
                  children: [
                    const SizedBox(height: 12),
                    // مؤشر التقدم للمجموعة
                    if (!_isFree && !_isSingle && widget.items.length > 1)
                      Text(
                        '${_currentIndex + 1} من ${widget.items.length}',
                        style: TextStyle(
                            fontSize: 13, color: _subtitleColor),
                      ),
                    const SizedBox(height: 16),
                    // نص الذكر
                    Text(
                      _currentItem.text,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w600,
                        color: _titleColor,
                        height: 1.7,
                      ),
                    ),
                    const Spacer(),
                    // الدائرة الكبيرة
                    _buildCountCircle(),
                    // نص الانتقال بين الأذكار
                    if (_isTransitioning) ...[
                      const SizedBox(height: 12),
                      Text(
                        'اكتمل هذا الذكر',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 13,
                          color: _accentColor,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                    const Spacer(),
                  ],
                ),
              ),
            ),
          ),
          // ── أزرار التحكم (خارج منطقة العد) ──────────
          _buildBottomButtons(),
        ],
      ),
    );
  }

  Widget _buildCountCircle() {
    return Container(
      width: 220,
      height: 220,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: _accentColor.withValues(alpha: widget.isDark ? 0.25 : 0.15),
        border: Border.all(
          color: _accentColor.withValues(alpha: widget.isDark ? 0.5 : 0.4),
          width: 3,
        ),
        boxShadow: [
          BoxShadow(
            color: _accentColor.withValues(alpha: 0.12),
            blurRadius: 20,
            spreadRadius: 4,
          ),
        ],
      ),
      child: _isFree
          ? Center(
              child: Text(
                '$_count',
                style: TextStyle(
                  fontSize: 72,
                  fontWeight: FontWeight.bold,
                  color: _titleColor,
                  height: 1,
                ),
              ),
            )
          : Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  '$_count',
                  style: TextStyle(
                    fontSize: 62,
                    fontWeight: FontWeight.bold,
                    color: _titleColor,
                    height: 1,
                  ),
                ),
                const SizedBox(height: 4),
                Container(
                    width: 60,
                    height: 1.5,
                    color: _accentColor.withValues(alpha: 0.5)),
                const SizedBox(height: 4),
                Text(
                  '${_currentItem.target}',
                  style: TextStyle(
                      fontSize: 28, color: _subtitleColor, height: 1),
                ),
              ],
            ),
    );
  }

  Widget _buildBottomButtons() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _buildBottomBtn(
            icon: Icons.refresh,
            label: 'إعادة',
            onTap: _resetCurrent,
          ),
          _buildBottomBtn(
            icon: Icons.edit_outlined,
            label: 'تعديل',
            onTap: _isFree
                ? _editFreeText
                : () => Navigator.pop(context),
          ),
          _buildBottomBtn(
            icon: Icons.arrow_back,
            label: 'رجوع',
            onTap: () => Navigator.pop(context),
          ),
        ],
      ),
    );
  }

  Widget _buildBottomBtn({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: _cardColor,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: widget.isDark
                ? Colors.white.withValues(alpha: 0.12)
                : _DC.divider,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 17, color: _accentColor),
            const SizedBox(width: 5),
            Text(label,
                style: TextStyle(
                    fontSize: 13,
                    color: _titleColor,
                    fontWeight: FontWeight.w500)),
          ],
        ),
      ),
    );
  }

  Widget _buildCompletedView() {
    return SafeArea(
      child: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 90,
                height: 90,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _accentColor.withValues(alpha: 0.15),
                ),
                child: Icon(Icons.check_circle_outline_rounded,
                    color: _accentColor, size: 54),
              ),
              const SizedBox(height: 24),
              Text('اكتمل الذكر',
                  style: TextStyle(
                      fontSize: 26,
                      fontWeight: FontWeight.bold,
                      color: _titleColor)),
              const SizedBox(height: 10),
              Text(widget.groupName,
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 15, color: _subtitleColor)),
              const SizedBox(height: 40),
              SizedBox(
                width: double.infinity,
                height: 50,
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _accentColor,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14)),
                    elevation: 0,
                  ),
                  onPressed: _reset,
                  icon: const Icon(Icons.refresh, size: 20),
                  label: const Text('إعادة',
                      style: TextStyle(
                          fontSize: 15, fontWeight: FontWeight.w600)),
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                height: 46,
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: _accentColor,
                    side: BorderSide(
                        color: _accentColor.withValues(alpha: 0.6)),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14)),
                  ),
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.arrow_back, size: 18),
                  label: const Text('العودة للمجموعات',
                      style: TextStyle(fontSize: 14)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────
//  Dialog تعديل نص التسبيح الحر
//  StatefulWidget مستقل لضمان dispose() صحيح
//  للـ TextEditingController بعد انتهاء أنيميشن الإغلاق
// ─────────────────────────────────────────────
class _EditFreeTextDialog extends StatefulWidget {
  final String initialText;
  final Color accentColor;
  final Color titleColor;
  final Color subtitleColor;
  final Color cardColor;

  const _EditFreeTextDialog({
    required this.initialText,
    required this.accentColor,
    required this.titleColor,
    required this.subtitleColor,
    required this.cardColor,
  });

  @override
  State<_EditFreeTextDialog> createState() => _EditFreeTextDialogState();
}

class _EditFreeTextDialogState extends State<_EditFreeTextDialog> {
  late final TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.initialText);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: AlertDialog(
        backgroundColor: widget.cardColor,
        title: Text('تعديل الذكر',
            style: TextStyle(color: widget.titleColor, fontSize: 16)),
        content: TextField(
          controller: _ctrl,
          autofocus: true,
          style: TextStyle(color: widget.titleColor, fontSize: 15),
          decoration: InputDecoration(
            hintText: 'أدخل نص الذكر',
            hintStyle: TextStyle(color: widget.subtitleColor),
            border:
                OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide(color: widget.accentColor),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('إلغاء',
                style: TextStyle(color: widget.subtitleColor)),
          ),
          TextButton(
            onPressed: () =>
                Navigator.pop(context, _ctrl.text.trim()),
            child: Text('تأكيد',
                style: TextStyle(color: widget.accentColor)),
          ),
        ],
      ),
    );
  }
}
