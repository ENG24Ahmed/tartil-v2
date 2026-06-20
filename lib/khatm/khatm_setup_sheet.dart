import 'package:flutter/material.dart';

import 'package:quran_app/khatm/khatm_data.dart';
import 'package:quran_app/khatm/khatm_saved_sessions.dart';
import 'package:quran_app/khatm/khatm_session_screen.dart';
import 'package:quran_app/quran/quran_db.dart';
import 'package:quran_app/quran/quran_menu_palette.dart';
import 'package:quran_app/quran/quran_menu_sheet_host.dart';

Future<void> showKhatmMunazamSetup({
  required BuildContext context,
  required bool menuDarkMode,
  required List<({int no, String nameAr, int startPage})> suraList,
  required Map<int, int> suraAyahCount,
  required String arabicUiFontFamily,
  bool horizontallyRotatedReading = false,
}) async {
  final pal =
      menuDarkMode ? QuranMenuPaletteData.dark : QuranMenuPaletteData.light;
  await showQuranMenuSidePanel<void>(
    context: context,
    horizontallyRotatedReading: horizontallyRotatedReading,
    isScrollControlled: true,
    backgroundColor: pal.surface,
    bottomSheetShape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (ctx) => QuranMenuPalette(
      data: pal,
      child: wrapQuranMenuFamilySheetOverlay(
        ctx,
        Directionality(
          textDirection: TextDirection.rtl,
          child: _KhatmSetupSheet(
            suraList: suraList,
            suraAyahCount: suraAyahCount,
            arabicUiFontFamily: arabicUiFontFamily,
            menuDarkMode: menuDarkMode,
            horizontallyRotatedReading: horizontallyRotatedReading,
          ),
        ),
        horizontallyRotatedReading: horizontallyRotatedReading,
        fillSidePanel: true,
      ),
    ),
  );
}

class _KhatmSetupSheet extends StatefulWidget {
  const _KhatmSetupSheet({
    required this.suraList,
    required this.suraAyahCount,
    required this.arabicUiFontFamily,
    required this.menuDarkMode,
    required this.horizontallyRotatedReading,
  });

  final List<({int no, String nameAr, int startPage})> suraList;
  final Map<int, int> suraAyahCount;
  final String arabicUiFontFamily;
  final bool menuDarkMode;
  final bool horizontallyRotatedReading;

  @override
  State<_KhatmSetupSheet> createState() => _KhatmSetupSheetState();
}

class _KhatmSetupSheetState extends State<_KhatmSetupSheet> {
  // ── نطاق السور / نطاق الآيات (ختم منظّم — ليس استماعاً) ───────────────────
  /// true = عجلتا «من سورة» / «إلى سورة»، false = سورة واحدة + من آية / إلى آية.
  bool _surahSpanMode = true;
  int _selectedSurahIndex = 17;
  int _fromSurahIndex = 17;
  int _toSurahIndex = 17;
  int _fromAyah = 1;
  int _toAyah = 1;

  late final FixedExtentScrollController _suraWheelController;
  late final FixedExtentScrollController _fromSuraSpanController;
  late final FixedExtentScrollController _toSuraSpanController;
  late final FixedExtentScrollController _fromAyahController;
  late final FixedExtentScrollController _toAyahController;

  // ── السرعة (كلمات/دقيقة فقط؛ لا اختيار مدة) ───────────────────────────────
  final _wpmCtrl = TextEditingController();
  bool _updatingFields = false;

  // ── حالة التحميل ───────────────────────────────────────────────────────────
  bool _loading = false;
  int _wordCount = 0;
  String? _errorMsg;

  // ── جلسات محفوظة ───────────────────────────────────────────────────────────
  List<KhatmSavedSessionRecord> _savedSessions = const [];

  // ── ثوابت ──────────────────────────────────────────────────────────────────
  static const double _defaultWpm = 80;
  static const double _wpmStep = 10;

  /// في الأفقي: تخطيط مضغوط — عجلات بثلاثة عناصر فقط (واحد فوق المختار وواحد تحته).
  bool get _compactHorizontal =>
      widget.horizontallyRotatedReading ||
      MediaQuery.orientationOf(context) == Orientation.landscape;

  static const double _sheetFontScale = 1.2;

  double _sheetFont(double pt) => pt * _sheetFontScale;

  /// أقل من 1 = مسافة أضيق بين عناصر العجلة.
  static const double _wheelItemSpacingTighten = 0.82;

  double get _wheelItemExtent =>
      (_compactHorizontal ? 28.0 : 36.0) *
      _sheetFontScale *
      _wheelItemSpacingTighten;

  double get _wheelViewportHeight => _wheelItemExtent * 3;

  @override
  void initState() {
    super.initState();
    final n = widget.suraList.length;
    if (n > 0) {
      _selectedSurahIndex = _selectedSurahIndex.clamp(0, n - 1);
      _fromSurahIndex = _selectedSurahIndex;
      _toSurahIndex = _selectedSurahIndex;
      final suraNo = widget.suraList[_selectedSurahIndex].no;
      final ac = widget.suraAyahCount[suraNo] ?? 1;
      _toAyah = ac;
    }
    _suraWheelController =
        FixedExtentScrollController(initialItem: _selectedSurahIndex);
    _fromSuraSpanController =
        FixedExtentScrollController(initialItem: _fromSurahIndex);
    _toSuraSpanController =
        FixedExtentScrollController(initialItem: _toSurahIndex);
    _fromAyahController =
        FixedExtentScrollController(initialItem: _fromAyah - 1);
    _toAyahController = FixedExtentScrollController(initialItem: _toAyah - 1);
    _wpmCtrl.addListener(_onWpmChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final lastWpm = await KhatmPrefs.loadLastWpm();
      if (!mounted) return;
      _setWpmValue(lastWpm ?? _defaultWpm);
      await _reloadWordCount();
      await _reloadSavedSessions();
    });
  }

  Future<void> _reloadSavedSessions() async {
    final list = await KhatmSavedSessionsStore.loadAll();
    if (!mounted) return;
    setState(() => _savedSessions = list);
  }

  @override
  void dispose() {
    _suraWheelController.dispose();
    _fromSuraSpanController.dispose();
    _toSuraSpanController.dispose();
    _fromAyahController.dispose();
    _toAyahController.dispose();
    _wpmCtrl.dispose();
    super.dispose();
  }

  // ────────────────────────────────────────────────────────────────────────────
  // helpers
  // ────────────────────────────────────────────────────────────────────────────

  ({int no, String nameAr, int startPage}) get _surah =>
      widget.suraList[_selectedSurahIndex];

  int get _surahAyahCount => widget.suraAyahCount[_surah.no] ?? 1;

  void _jumpIfNeeded(FixedExtentScrollController controller, int item) {
    if (!controller.hasClients) return;
    if (controller.selectedItem != item) {
      controller.jumpToItem(item);
    }
  }

  String _suraWheelLabel(int i) {
    if (i < 0 || i >= widget.suraList.length) return '';
    final s = widget.suraList[i];
    return '${s.no} - ${s.nameAr}';
  }

  String _selectionSummaryLine() {
    if (_surahSpanMode) {
      final f = widget.suraList[_fromSurahIndex];
      final t = widget.suraList[_toSurahIndex];
      if (f.no == t.no) {
        return 'سيتم الختم من بداية ${f.nameAr} إلى نهايتها';
      }
      return 'من ${f.nameAr} إلى ${t.nameAr} — كل سورة كاملة ضمن النطاق';
    }
    final name = _surah.nameAr;
    return 'النطاق: $name من آية $_fromAyah إلى $_toAyah';
  }

  Widget _modeButton({
    required QuranMenuPaletteData pal,
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    final compact = _compactHorizontal;
    return Expanded(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(compact ? 8 : 10),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: EdgeInsets.symmetric(vertical: compact ? 9 : 10),
          decoration: BoxDecoration(
            color: selected ? pal.accent : pal.cardSurface,
            borderRadius: BorderRadius.circular(compact ? 8 : 10),
            border: Border.all(color: pal.accent),
          ),
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontFamily: widget.arabicUiFontFamily,
              fontSize: _sheetFont(compact ? 14 : 15),
              fontWeight: FontWeight.w700,
              color: selected ? Colors.white : pal.title,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildWheelColumn({
    required QuranMenuPaletteData pal,
    required String title,
    required int selectedIndex,
    required int childCount,
    required FixedExtentScrollController controller,
    required String Function(int index) labelBuilder,
    required ValueChanged<int> onChanged,
  }) {
    final compact = _compactHorizontal;
    final extent = _wheelItemExtent;
    Widget wheelList(double itemExtent) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(compact ? 8 : 10),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: pal.wheelColumnInnerFill,
            borderRadius: BorderRadius.circular(compact ? 8 : 10),
            border: Border.all(color: pal.wheelColumnBorder),
          ),
          child: ListWheelScrollView.useDelegate(
            controller: controller,
            itemExtent: itemExtent,
            perspective: compact ? 0.002 : 0.004,
            diameterRatio: compact ? 3.0 : 1.7,
            physics: const BouncingScrollPhysics(
              parent: FixedExtentScrollPhysics(),
            ),
            onSelectedItemChanged: onChanged,
            childDelegate: ListWheelChildBuilderDelegate(
              childCount: childCount,
              builder: (_, i) {
                final selected = i == selectedIndex;
                return Center(
                  child: Padding(
                    padding: EdgeInsets.symmetric(horizontal: compact ? 3 : 4),
                    child: Text(
                      labelBuilder(i),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontFamily: widget.arabicUiFontFamily,
                        fontSize: _sheetFont(
                            compact ? (selected ? 15 : 14) : 15),
                        fontWeight:
                            selected ? FontWeight.w700 : FontWeight.w500,
                        color: selected
                            ? pal.wheelTextSelected
                            : pal.wheelTextUnselected,
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      );
    }

    final wheelBody = compact
        ? Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final dynamicExtent = constraints.maxHeight.isFinite &&
                        constraints.maxHeight > 0
                    ? (constraints.maxHeight / 3.5 * _wheelItemSpacingTighten)
                        .clamp(26.0 * _sheetFontScale, 46.0 * _sheetFontScale)
                    : extent;
                return wheelList(dynamicExtent);
              },
            ),
          )
        : Expanded(child: wheelList(extent));

    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            title,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: pal.accent,
              fontFamily: widget.arabicUiFontFamily,
              fontSize: _sheetFont(compact ? 12 : 14),
              fontWeight: FontWeight.w600,
            ),
          ),
          SizedBox(height: compact ? 4 : 6),
          wheelBody,
        ],
      ),
    );
  }

  double get _wheelRowHeight {
    if (!_compactHorizontal) return 220;
    return _wheelViewportHeight + 22;
  }

  Widget _buildSurahSpanWheelContent(QuranMenuPaletteData pal) {
    if (widget.suraList.isEmpty) return const SizedBox.shrink();
    final row = Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildWheelColumn(
            pal: pal,
            title: 'من سورة',
            selectedIndex: _fromSurahIndex,
            childCount: widget.suraList.length,
            controller: _fromSuraSpanController,
            labelBuilder: _suraWheelLabel,
            onChanged: (i) {
              if (i < 0 || i >= widget.suraList.length) return;
              setState(() {
                _fromSurahIndex = i;
                if (_toSurahIndex < _fromSurahIndex) {
                  _toSurahIndex = _fromSurahIndex;
                }
              });
              _jumpIfNeeded(_toSuraSpanController, _toSurahIndex);
              _reloadWordCount();
            },
          ),
          SizedBox(width: _compactHorizontal ? 5 : 8),
          _buildWheelColumn(
            pal: pal,
            title: 'إلى سورة',
            selectedIndex: _toSurahIndex,
            childCount: widget.suraList.length,
            controller: _toSuraSpanController,
            labelBuilder: _suraWheelLabel,
            onChanged: (i) {
              if (i < 0 || i >= widget.suraList.length) return;
              setState(() {
                _toSurahIndex = i;
                if (_toSurahIndex < _fromSurahIndex) {
                  _fromSurahIndex = _toSurahIndex;
                }
              });
              _jumpIfNeeded(_fromSuraSpanController, _fromSurahIndex);
              _reloadWordCount();
            },
          ),
        ],
      );
    if (_compactHorizontal) return row;
    return SizedBox(height: _wheelRowHeight, child: row);
  }

  Widget _buildAyahModeWheelContent(QuranMenuPaletteData pal) {
    if (widget.suraList.isEmpty) return const SizedBox.shrink();
    final ayahCount = _surahAyahCount;
    final row = Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildWheelColumn(
            pal: pal,
            title: 'السورة',
            selectedIndex: _selectedSurahIndex,
            childCount: widget.suraList.length,
            controller: _suraWheelController,
            labelBuilder: _suraWheelLabel,
            onChanged: (i) {
              if (i < 0 || i >= widget.suraList.length) return;
              setState(() {
                _selectedSurahIndex = i;
                final c = widget.suraAyahCount[widget.suraList[i].no] ?? 1;
                _fromAyah = _fromAyah.clamp(1, c);
                _toAyah = _toAyah.clamp(_fromAyah, c);
              });
              _jumpIfNeeded(_fromAyahController, _fromAyah - 1);
              _jumpIfNeeded(_toAyahController, _toAyah - 1);
              _reloadWordCount();
            },
          ),
          SizedBox(width: _compactHorizontal ? 4 : 8),
          _buildWheelColumn(
            pal: pal,
            title: 'من آية',
            selectedIndex: _fromAyah - 1,
            childCount: ayahCount,
            controller: _fromAyahController,
            labelBuilder: (i) => '${i + 1}',
            onChanged: (i) {
              final value = (i + 1).clamp(1, ayahCount);
              setState(() {
                _fromAyah = value;
                if (_toAyah < _fromAyah) _toAyah = _fromAyah;
              });
              _jumpIfNeeded(_toAyahController, _toAyah - 1);
              _reloadWordCount();
            },
          ),
          SizedBox(width: _compactHorizontal ? 4 : 8),
          _buildWheelColumn(
            pal: pal,
            title: 'إلى آية',
            selectedIndex: _toAyah - 1,
            childCount: ayahCount,
            controller: _toAyahController,
            labelBuilder: (i) => '${i + 1}',
            onChanged: (i) {
              final value = (i + 1).clamp(_fromAyah, ayahCount);
              setState(() {
                _toAyah = value;
              });
              _jumpIfNeeded(_toAyahController, _toAyah - 1);
              _reloadWordCount();
            },
          ),
        ],
      );
    if (_compactHorizontal) return row;
    return SizedBox(height: _wheelRowHeight, child: row);
  }

  double get _currentWpm {
    final v =
        double.tryParse(_wpmCtrl.text.replaceAll(',', '.')) ?? _defaultWpm;
    return v.clamp(KhatmWpmLimits.min, KhatmWpmLimits.max);
  }

  void _setWpmValue(double wpm) {
    _updatingFields = true;
    final clamped = wpm.clamp(KhatmWpmLimits.min, KhatmWpmLimits.max);
    final wpmStr =
        clamped.toStringAsFixed(clamped == clamped.roundToDouble() ? 0 : 1);
    if (_wpmCtrl.text != wpmStr) _wpmCtrl.text = wpmStr;
    _updatingFields = false;
    // أثناء التعيين البرمجي يتجاهل [_onWpmChanged] الـ setState؛ نعرض الرقم بـ [Text] وليس [TextField].
    if (mounted) setState(() {});
  }

  void _nudgeWpm(double delta) {
    _setWpmValue(_currentWpm + delta);
  }

  void _onWpmChanged() {
    if (_updatingFields) return;
    setState(() {});
  }

  Future<void> _reloadWordCount() async {
    if (widget.suraList.isEmpty) return;
    setState(() {
      _loading = true;
      _errorMsg = null;
    });
    try {
      int count;
      if (_surahSpanMode) {
        final fromNo = widget.suraList[_fromSurahIndex].no;
        final toNo = widget.suraList[_toSurahIndex].no;
        count = await QuranDb.instance.getWordCountForSurahSpan(fromNo, toNo);
      } else {
        final surahNo = _surah.no;
        count = await QuranDb.instance.getWordCountForRange(
          surahNo,
          _fromAyah,
          _toAyah,
        );
      }
      if (!mounted) return;
      setState(() {
        _wordCount = count;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMsg = 'تعذّر تحميل بيانات الكلمات';
        _loading = false;
      });
    }
  }

  Future<void> _onStart() async {
    final raw = double.tryParse(_wpmCtrl.text.replaceAll(',', '.'));
    final wpm = raw ?? _defaultWpm;
    if (wpm < KhatmWpmLimits.min || wpm > KhatmWpmLimits.max) {
      setState(() => _errorMsg =
          'أدخل سرعة بين ${KhatmWpmLimits.min.toInt()} و${KhatmWpmLimits.max.toInt()} كلمة/دقيقة');
      return;
    }
    if (_wordCount == 0) {
      setState(() => _errorMsg = 'تعذّر تحميل بيانات الكلمات');
      return;
    }

    await KhatmPrefs.saveLastWpm(wpm);

    final KhatmRange range;
    if (_surahSpanMode) {
      final f = widget.suraList[_fromSurahIndex];
      final t = widget.suraList[_toSurahIndex];
      final lo = f.no <= t.no ? f.no : t.no;
      final hi = f.no <= t.no ? t.no : f.no;
      final names = <int, String>{};
      for (final row in widget.suraList) {
        if (row.no >= lo && row.no <= hi) {
          names[row.no] = row.nameAr;
        }
      }
      range = KhatmRange(
        type: KhatmRangeType.surahSpan,
        fromSurah: f.no,
        toSurah: t.no,
        fromSurahName: f.nameAr,
        toSurahName: t.nameAr,
        fromAyah: 1,
        toAyah: 1,
        totalWords: _wordCount,
        surahNamesAr: names,
      );
    } else {
      final s = _surah;
      range = KhatmRange(
        type: KhatmRangeType.ayahRange,
        fromSurah: s.no,
        toSurah: s.no,
        fromSurahName: s.nameAr,
        toSurahName: s.nameAr,
        fromAyah: _fromAyah,
        toAyah: _toAyah,
        totalWords: _wordCount,
        surahNamesAr: {s.no: s.nameAr},
      );
    }

    if (!mounted) return;
    Navigator.pop(context);
    if (!mounted) return;

    await KhatmSessionScreen.open(
      context,
      range: range,
      initialWpm: wpm,
      arabicUiFontFamily: widget.arabicUiFontFamily,
      horizontallyRotated: widget.horizontallyRotatedReading,
    );
  }

  Future<void> _openSavedSession(KhatmSavedSessionRecord record) async {
    await KhatmPrefs.saveLastWpm(record.wpm);
    if (!mounted) return;
    Navigator.pop(context);
    if (!mounted) return;
    await KhatmSessionScreen.open(
      context,
      range: record.range,
      initialWpm: record.wpm,
      arabicUiFontFamily: widget.arabicUiFontFamily,
      horizontallyRotated: widget.horizontallyRotatedReading,
    );
  }

  Widget _buildCompactModeToggleRow(QuranMenuPaletteData pal) {
    return Row(
      children: [
        _modeButton(
          pal: pal,
          label: 'نطاق السور',
          selected: _surahSpanMode,
          onTap: () {
            if (_surahSpanMode) return;
            setState(() {
              _surahSpanMode = true;
              _fromSurahIndex = _selectedSurahIndex;
              _toSurahIndex = _selectedSurahIndex;
              _fromAyah = 1;
              _toAyah = _surahAyahCount;
            });
            _jumpIfNeeded(_fromSuraSpanController, _fromSurahIndex);
            _jumpIfNeeded(_toSuraSpanController, _toSurahIndex);
            _jumpIfNeeded(_fromAyahController, _fromAyah - 1);
            _jumpIfNeeded(_toAyahController, _toAyah - 1);
            _reloadWordCount();
          },
        ),
        SizedBox(width: _compactHorizontal ? 5 : 8),
        _modeButton(
          pal: pal,
          label: 'نطاق الآيات',
          selected: !_surahSpanMode,
          onTap: () {
            if (!_surahSpanMode) return;
            setState(() {
              _surahSpanMode = false;
              _selectedSurahIndex = _fromSurahIndex;
              final c = _surahAyahCount;
              _fromAyah = 1;
              _toAyah = c;
            });
            _jumpIfNeeded(_suraWheelController, _selectedSurahIndex);
            _jumpIfNeeded(_fromAyahController, _fromAyah - 1);
            _jumpIfNeeded(_toAyahController, _toAyah - 1);
            _reloadWordCount();
          },
        ),
      ],
    );
  }

  /// في الأفقي: عمود التحكم الأوسع (يسار) + عجلات أضيق بـ 25% (يمين).
  Widget _buildCompactWheelsAndControlsRow(QuranMenuPaletteData pal) {
    return Row(
      textDirection: TextDirection.ltr,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(flex: 50, child: _buildCompactControlsColumn(pal)),
        const SizedBox(width: 10),
        Expanded(flex: 50, child: _buildCompactWheelsColumn(pal)),
      ],
    );
  }

  Widget _buildCompactWheelsColumn(QuranMenuPaletteData pal) {
    final wheels = widget.suraList.isEmpty
        ? Text(
            'لا توجد بيانات للسور',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontFamily: widget.arabicUiFontFamily,
              color: pal.subtitle,
              fontSize: _sheetFont(13),
            ),
          )
        : AnimatedSwitcher(
            duration: const Duration(milliseconds: 180),
            child: _surahSpanMode
                ? KeyedSubtree(
                    key: const ValueKey('khatm_full'),
                    child: _buildSurahSpanWheelContent(pal),
                  )
                : KeyedSubtree(
                    key: const ValueKey('khatm_ayah'),
                    child: _buildAyahModeWheelContent(pal),
                  ),
          );

    return Column(
      mainAxisSize: MainAxisSize.max,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildCompactModeToggleRow(pal),
        const SizedBox(height: 8),
        Expanded(child: wheels),
        if (widget.suraList.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(
            _selectionSummaryLine(),
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontFamily: widget.arabicUiFontFamily,
              fontSize: _sheetFont(13),
              height: 1.2,
              color: pal.accent,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ],
    );
  }

  /// الحقول الأربعة عمودياً: عدد الكلمات، السرعة، ابدأ، المحفوظة.
  Widget _buildCompactControlsColumn(QuranMenuPaletteData pal) {
    final labelStyle = TextStyle(
      fontFamily: widget.arabicUiFontFamily,
      fontSize: _sheetFont(12),
      color: pal.subtitle,
      fontWeight: FontWeight.w500,
    );
    final valueStyle = TextStyle(
      fontFamily: widget.arabicUiFontFamily,
      fontSize: _sheetFont(14),
      color: pal.title,
      fontWeight: FontWeight.w600,
    );
    final radius = BorderRadius.circular(10);

    return Column(
        mainAxisSize: MainAxisSize.max,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            flex: 2,
            child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
            decoration: BoxDecoration(
              color: pal.accent.withValues(alpha: pal.isDark ? 0.12 : 0.08),
              borderRadius: radius,
              border: Border.all(color: pal.accent.withValues(alpha: 0.25)),
            ),
            alignment: Alignment.center,
            child: _loading
                ? SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: pal.accent,
                    ),
                  )
                : Text(
                    'كلمات: $_wordCount',
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: valueStyle.copyWith(fontSize: _sheetFont(13)),
                  ),
          ),
          ),
          const SizedBox(height: 8),
          Text('السرعة', style: labelStyle, textAlign: TextAlign.center),
          const SizedBox(height: 4),
          Expanded(
            flex: 2,
            child: Container(
            decoration: BoxDecoration(
              color: pal.searchFieldFill,
              borderRadius: radius,
              border: Border.all(color: pal.divider),
            ),
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Directionality(
              textDirection: TextDirection.ltr,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _buildWpmStepButton(
                    pal: pal,
                    icon: Icons.remove_rounded,
                    enabled: _currentWpm > KhatmWpmLimits.min + 0.001,
                    onTap: () => _nudgeWpm(-_wpmStep),
                    iconSize: 22,
                    padding: 4,
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Text(
                      _currentWpm == _currentWpm.roundToDouble()
                          ? _currentWpm.toStringAsFixed(0)
                          : _currentWpm.toStringAsFixed(1),
                      style: valueStyle.copyWith(fontSize: _sheetFont(15)),
                    ),
                  ),
                  _buildWpmStepButton(
                    pal: pal,
                    icon: Icons.add_rounded,
                    enabled: _currentWpm < KhatmWpmLimits.max - 0.001,
                    onTap: () => _nudgeWpm(_wpmStep),
                    iconSize: 22,
                    padding: 4,
                  ),
                ],
              ),
            ),
          ),
          ),
          const SizedBox(height: 8),
          Expanded(
            flex: 3,
            child: ElevatedButton(
              onPressed: _loading ? null : _onStart,
              style: ElevatedButton.styleFrom(
                backgroundColor: pal.accent,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: radius),
                elevation: 0,
                padding: const EdgeInsets.symmetric(horizontal: 4),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.play_arrow_rounded, size: 22),
                  const SizedBox(width: 6),
                  Text(
                    'ابدأ الجلسة',
                    style: TextStyle(
                      fontFamily: widget.arabicUiFontFamily,
                      fontSize: _sheetFont(14),
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            flex: 3,
            child: OutlinedButton(
              onPressed: _openSavedSessionsSheet,
              style: OutlinedButton.styleFrom(
                foregroundColor: pal.accent,
                side: BorderSide(color: pal.accent.withValues(alpha: 0.65)),
                shape: RoundedRectangleBorder(borderRadius: radius),
                padding: const EdgeInsets.symmetric(horizontal: 4),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.bookmarks_outlined, size: 20, color: pal.accent),
                  const SizedBox(width: 5),
                  Text(
                    'المحفوظة',
                    style: TextStyle(
                      fontFamily: widget.arabicUiFontFamily,
                      fontSize: _sheetFont(13),
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  if (_savedSessions.isNotEmpty) ...[
                    const SizedBox(width: 4),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 5,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: pal.accent.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        '${_savedSessions.length}',
                        style: TextStyle(
                          fontFamily: widget.arabicUiFontFamily,
                          fontSize: _sheetFont(12),
                          fontWeight: FontWeight.w800,
                          color: pal.accent,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
    );
  }

  // ────────────────────────────────────────────────────────────────────────────
  // Build
  // ────────────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final pal = QuranMenuPalette.of(context);
    final mq = MediaQuery.of(context);
    final compact = _compactHorizontal;
    final content = Column(
            mainAxisSize: compact ? MainAxisSize.max : MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (compact)
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    InkWell(
                      onTap: () => Navigator.pop(context),
                      borderRadius: BorderRadius.circular(8),
                      child: Padding(
                        padding: const EdgeInsets.all(4),
                        child: Icon(
                          Icons.close_rounded,
                          color: pal.title,
                          size: 22,
                        ),
                      ),
                    ),
                    Expanded(
                      child: Text(
                        'تحديد نطاق الختم المنظّم',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontFamily: widget.arabicUiFontFamily,
                          fontSize: _sheetFont(18),
                          height: 1.1,
                          color: pal.title,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    const SizedBox(width: 30),
                  ],
                )
              else
                Row(
                  children: [
                    IconButton(
                      icon: Icon(Icons.close_rounded,
                          color: pal.title, size: 24),
                      tooltip: 'إغلاق',
                      onPressed: () => Navigator.pop(context),
                    ),
                    Expanded(
                      child: Text(
                        'تحديد نطاق الختم المنظّم',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontFamily: widget.arabicUiFontFamily,
                          fontSize: _sheetFont(18),
                          color: pal.title,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    const SizedBox(width: 48),
                  ],
                ),
              SizedBox(height: compact ? 10 : 14),
              if (!compact)
                Row(
                  children: [
                    _modeButton(
                      pal: pal,
                      label: 'نطاق السور',
                      selected: _surahSpanMode,
                      onTap: () {
                        if (_surahSpanMode) return;
                        setState(() {
                          _surahSpanMode = true;
                          _fromSurahIndex = _selectedSurahIndex;
                          _toSurahIndex = _selectedSurahIndex;
                          _fromAyah = 1;
                          _toAyah = _surahAyahCount;
                        });
                        _jumpIfNeeded(_fromSuraSpanController, _fromSurahIndex);
                        _jumpIfNeeded(_toSuraSpanController, _toSurahIndex);
                        _jumpIfNeeded(_fromAyahController, _fromAyah - 1);
                        _jumpIfNeeded(_toAyahController, _toAyah - 1);
                        _reloadWordCount();
                      },
                    ),
                    const SizedBox(width: 8),
                    _modeButton(
                      pal: pal,
                      label: 'نطاق الآيات',
                      selected: !_surahSpanMode,
                      onTap: () {
                        if (!_surahSpanMode) return;
                        setState(() {
                          _surahSpanMode = false;
                          _selectedSurahIndex = _fromSurahIndex;
                          final c = _surahAyahCount;
                          _fromAyah = 1;
                          _toAyah = c;
                        });
                        _jumpIfNeeded(_suraWheelController, _selectedSurahIndex);
                        _jumpIfNeeded(_fromAyahController, _fromAyah - 1);
                        _jumpIfNeeded(_toAyahController, _toAyah - 1);
                        _reloadWordCount();
                      },
                    ),
                  ],
                ),
              if (!compact) const SizedBox(height: 12),
              if (compact)
                Expanded(child: _buildCompactWheelsAndControlsRow(pal))
              else ...[
                if (widget.suraList.isEmpty)
                  Text(
                    'لا توجد بيانات للسور',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontFamily: widget.arabicUiFontFamily,
                      color: pal.subtitle,
                    ),
                  )
                else
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 180),
                    child: _surahSpanMode
                        ? KeyedSubtree(
                            key: const ValueKey('khatm_full'),
                            child: _buildSurahSpanWheelContent(pal),
                          )
                        : KeyedSubtree(
                            key: const ValueKey('khatm_ayah'),
                            child: _buildAyahModeWheelContent(pal),
                          ),
                  ),
                const SizedBox(height: 10),
                if (widget.suraList.isNotEmpty)
                  Text(
                    _selectionSummaryLine(),
                    textAlign: TextAlign.center,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: widget.arabicUiFontFamily,
                      fontSize: _sheetFont(14),
                      color: pal.accent,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                const SizedBox(height: 20),
                _buildWordCountAndSpeedRow(pal),
                const SizedBox(height: 8),
                _buildSpeedHint(pal),
              ],
              if (_errorMsg != null) ...[
                SizedBox(height: compact ? 6 : 10),
                Text(
                  _errorMsg!,
                  style: TextStyle(
                    color: Colors.red.shade400,
                    fontSize: _sheetFont(compact ? 12 : 13),
                  ),
                  textAlign: TextAlign.center,
                ),
              ],
              if (!compact) ...[
                const SizedBox(height: 20),
                _buildStartAndSavedRow(pal),
              ],
            ],
          );

    return SafeArea(
      top: !compact,
      bottom: !compact,
      child: Padding(
        padding: EdgeInsets.only(bottom: mq.viewInsets.bottom),
        child: compact
            ? Padding(
                padding: const EdgeInsets.fromLTRB(10, 10, 10, 6),
                child: content,
              )
            : SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 20, 16, 24),
                child: content,
              ),
      ),
    );
  }

  Widget _buildWordCountAndSpeedRow(QuranMenuPaletteData pal) {
    final compact = _compactHorizontal;
    final labelStyle = TextStyle(
      fontFamily: widget.arabicUiFontFamily,
      fontSize: _sheetFont(compact ? 11 : 12),
      color: pal.subtitle,
      fontWeight: FontWeight.normal,
    );
    final valueStyle = TextStyle(
      fontFamily: widget.arabicUiFontFamily,
      fontSize: _sheetFont(compact ? 14 : 16),
      color: pal.title,
      fontWeight: FontWeight.w600,
    );
    final border = Border.all(color: pal.divider);
    final radius = BorderRadius.circular(10);

    Widget wordCountChip() {
      return Container(
        padding: EdgeInsets.symmetric(
          horizontal: compact ? 8 : 12,
          vertical: compact ? 6 : 10,
        ),
        decoration: BoxDecoration(
          color: pal.accent.withValues(alpha: pal.isDark ? 0.12 : 0.08),
          borderRadius: radius,
          border: Border.all(color: pal.accent.withValues(alpha: 0.25)),
        ),
        alignment: Alignment.center,
        child: _loading
            ? SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: pal.accent,
                ),
              )
            : Text(
                'عدد الكلمات: $_wordCount',
                textAlign: TextAlign.center,
                style: valueStyle.copyWith(
                    fontSize: _sheetFont(compact ? 13 : 15)),
              ),
      );
    }

    Widget speedBox() {
      final atMin = _currentWpm <= KhatmWpmLimits.min + 0.001;
      final atMax = _currentWpm >= KhatmWpmLimits.max - 0.001;
      return Container(
        decoration: BoxDecoration(
          color: pal.searchFieldFill,
          borderRadius: radius,
          border: border,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
        child: Center(
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                _buildWpmStepButton(
                  pal: pal,
                  icon: Icons.remove_rounded,
                  enabled: !atMin,
                  onTap: () => _nudgeWpm(-_wpmStep),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: Text(
                    _currentWpm == _currentWpm.roundToDouble()
                        ? _currentWpm.toStringAsFixed(0)
                        : _currentWpm.toStringAsFixed(1),
                    style: valueStyle,
                  ),
                ),
                _buildWpmStepButton(
                  pal: pal,
                  icon: Icons.add_rounded,
                  enabled: !atMax,
                  onTap: () => _nudgeWpm(_wpmStep),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('السرعة (كلمة/دقيقة)', style: labelStyle),
        SizedBox(height: compact ? 4 : 6),
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(flex: 3, child: wordCountChip()),
            SizedBox(width: compact ? 6 : 10),
            Expanded(flex: 2, child: speedBox()),
          ],
        ),
        if (!compact) ...[
          const SizedBox(height: 6),
          Text(
            'من ${KhatmWpmLimits.min.toInt()} إلى ${KhatmWpmLimits.max.toInt()} كلمة/دقيقة',
            textAlign: TextAlign.center,
            style: labelStyle,
          ),
        ],
      ],
    );
  }

  Widget _buildWpmStepButton({
    required QuranMenuPaletteData pal,
    required IconData icon,
    required bool enabled,
    required VoidCallback onTap,
    double iconSize = 22,
    double padding = 4,
  }) {
    final color = enabled ? pal.accent : pal.subtitle.withValues(alpha: 0.35);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: EdgeInsets.all(padding),
          child: Icon(icon, size: iconSize, color: color),
        ),
      ),
    );
  }

  Widget _buildSpeedHint(QuranMenuPaletteData pal) {
    if (_wordCount <= 0) return const SizedBox.shrink();
    final wpm = _currentWpm;
    String hint;
    if (wpm < 50) {
      hint = 'سرعة بطيئة — مناسبة للتأمل والتدبر';
    } else if (wpm < 90) {
      hint = 'سرعة مريحة — مناسبة للقراءة العادية';
    } else if (wpm < 140) {
      hint = 'سرعة متوسطة — مناسبة للمراجعة';
    } else {
      hint = 'سرعة عالية — مناسبة للمراجعة السريعة';
    }
    return Text(
      hint,
      textAlign: TextAlign.center,
      style: TextStyle(
        fontFamily: widget.arabicUiFontFamily,
        fontSize: _sheetFont(12),
        color: pal.subtitle,
        fontWeight: FontWeight.normal,
      ),
    );
  }

  Future<void> _openSavedSessionsSheet() async {
    if (!mounted) return;
    final pal = QuranMenuPalette.of(context);
    final live = List<KhatmSavedSessionRecord>.from(
      await KhatmSavedSessionsStore.loadAll(),
    )..sort((a, b) => b.savedAtMillis.compareTo(a.savedAtMillis));
    if (!mounted) return;

    await showQuranMenuSidePanel<void>(
      context: context,
      horizontallyRotatedReading: widget.horizontallyRotatedReading,
      isScrollControlled: true,
      backgroundColor: pal.surface,
      bottomSheetShape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetCtx) {
        return wrapQuranMenuFamilySheetOverlay(
          sheetCtx,
          SafeArea(
          child: Directionality(
            textDirection: TextDirection.rtl,
            child: Padding(
              padding: EdgeInsets.only(
                left: 16,
                right: 16,
                top: 10,
                bottom: MediaQuery.of(sheetCtx).viewInsets.bottom + 16,
              ),
              child: StatefulBuilder(
                builder: (context, setModalState) {
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Center(
                        child: Container(
                          width: 40,
                          height: 4,
                          decoration: BoxDecoration(
                            color: pal.divider,
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          IconButton(
                            onPressed: () => Navigator.pop(sheetCtx),
                            icon: Icon(Icons.close_rounded, color: pal.title),
                          ),
                          Expanded(
                            child: Text(
                              'جلسات محفوظة (${live.length}/$khatmSavedSessionsMax)',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontFamily: widget.arabicUiFontFamily,
                                fontSize: _sheetFont(17),
                                fontWeight: FontWeight.w700,
                                color: pal.title,
                              ),
                            ),
                          ),
                          const SizedBox(width: 48),
                        ],
                      ),
                      const SizedBox(height: 8),
                      if (live.isEmpty)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 28),
                          child: Text(
                            'لا توجد جلسات محفوظة.\nاحفظ موضع القراءة من شاشة الختم (زر أسفل الشاشة).',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontFamily: widget.arabicUiFontFamily,
                              fontSize: _sheetFont(14),
                              height: 1.45,
                              color: pal.subtitle,
                            ),
                          ),
                        )
                      else
                        ConstrainedBox(
                          constraints: BoxConstraints(
                            // في الأفقي تكون المساحة العمودية للوحة الجانبية محدودة.
                            maxHeight: (widget.horizontallyRotatedReading ||
                                    MediaQuery.orientationOf(sheetCtx) ==
                                        Orientation.landscape)
                                ? 200
                                : MediaQuery.of(sheetCtx).size.height * 0.5,
                          ),
                          child: ListView.separated(
                            shrinkWrap: true,
                            itemCount: live.length,
                            separatorBuilder: (_, __) =>
                                const SizedBox(height: 8),
                            itemBuilder: (context, index) {
                              final r = live[index];
                              return Material(
                                color: pal.searchFieldFill,
                                borderRadius: BorderRadius.circular(12),
                                child: InkWell(
                                  borderRadius: BorderRadius.circular(12),
                                  onTap: () {
                                    Navigator.pop(sheetCtx);
                                    _openSavedSession(r);
                                  },
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 10,
                                      vertical: 10,
                                    ),
                                    child: Row(
                                      children: [
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                r.range.displayLabel,
                                                maxLines: 2,
                                                overflow: TextOverflow.ellipsis,
                                                style: TextStyle(
                                                  fontFamily:
                                                      widget.arabicUiFontFamily,
                                                  fontSize: _sheetFont(14),
                                                  fontWeight: FontWeight.w700,
                                                  color: pal.title,
                                                ),
                                              ),
                                              const SizedBox(height: 4),
                                              Text(
                                                '${r.resumeCaption} · ${r.wpm.toStringAsFixed(0)} ك/د',
                                                maxLines: 2,
                                                overflow: TextOverflow.ellipsis,
                                                style: TextStyle(
                                                  fontFamily:
                                                      widget.arabicUiFontFamily,
                                                  fontSize: _sheetFont(12),
                                                  color: pal.subtitle,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                        IconButton(
                                          tooltip: 'حذف',
                                          onPressed: () async {
                                            await KhatmSavedSessionsStore
                                                .removeById(r.id);
                                            live.removeWhere((e) => e.id == r.id);
                                            setModalState(() {});
                                            await _reloadSavedSessions();
                                          },
                                          icon: Icon(
                                            Icons.delete_outline_rounded,
                                            color: Colors.red.shade400,
                                          ),
                                        ),
                                        Icon(
                                          Icons.chevron_left_rounded,
                                          color: pal.subtitle,
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                    ],
                  );
                },
              ),
            ),
          ),
          ),
          horizontallyRotatedReading: widget.horizontallyRotatedReading,
          fillSidePanel: true,
        );
      },
    );
    if (mounted) await _reloadSavedSessions();
  }

  Widget _buildStartAndSavedRow(QuranMenuPaletteData pal) {
    final compact = _compactHorizontal;
    final btnH = compact ? 40.0 : 50.0;
    final btnRadius = compact ? 10.0 : 14.0;
    return Row(
      textDirection: TextDirection.rtl,
      children: [
        Expanded(
          flex: 3,
          child: SizedBox(
            height: btnH,
            child: ElevatedButton(
              onPressed: _loading ? null : _onStart,
              style: ElevatedButton.styleFrom(
                backgroundColor: pal.accent,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(btnRadius),
                ),
                elevation: 0,
                padding: compact
                    ? const EdgeInsets.symmetric(horizontal: 8)
                    : null,
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.play_arrow_rounded, size: compact ? 18 : 22),
                  SizedBox(width: compact ? 4 : 8),
                  Text(
                    'ابدأ الجلسة',
                    style: TextStyle(
                      fontFamily: widget.arabicUiFontFamily,
                      fontSize: _sheetFont(compact ? 14 : 16),
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        SizedBox(width: compact ? 6 : 10),
        Expanded(
          flex: 2,
          child: SizedBox(
            height: btnH,
            child: Tooltip(
              message: 'الجلسات المحفوظة',
              child: OutlinedButton(
                onPressed: _openSavedSessionsSheet,
                style: OutlinedButton.styleFrom(
                  foregroundColor: pal.accent,
                  side: BorderSide(color: pal.accent.withValues(alpha: 0.65)),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(btnRadius),
                  ),
                  padding: compact
                      ? const EdgeInsets.symmetric(horizontal: 4)
                      : null,
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.bookmarks_outlined,
                        size: compact ? 17 : 20, color: pal.accent),
                    SizedBox(width: compact ? 3 : 6),
                    Flexible(
                      child: Text(
                        'المحفوظة',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontFamily: widget.arabicUiFontFamily,
                          fontSize: _sheetFont(compact ? 12 : 14),
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    if (_savedSessions.isNotEmpty) ...[
                      const SizedBox(width: 4),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: pal.accent.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          '${_savedSessions.length}',
                          style: TextStyle(
                            fontFamily: widget.arabicUiFontFamily,
                            fontSize: _sheetFont(12),
                            fontWeight: FontWeight.w800,
                            color: pal.accent,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
