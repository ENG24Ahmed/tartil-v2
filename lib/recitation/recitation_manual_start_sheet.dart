import 'package:flutter/material.dart';
import 'package:quran_app/recitation/recitation_db.dart';

/// عجلتان (سورة + رقم آية) بأسلوب قريب من عجلات التضليل في التطبيق.
Future<({int surahNumber, int ayahNumber})?> showRecitationManualStartSheet(
  BuildContext context, {
  required RecitationDb db,
  required int initialSurahNumber,
  required int initialAyahNumber,
}) {
  return showModalBottomSheet<({int surahNumber, int ayahNumber})>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (ctx) => _RecitationManualStartSheet(
      db: db,
      initialSurahNumber: initialSurahNumber,
      initialAyahNumber: initialAyahNumber,
    ),
  );
}

class _RecitationManualStartSheet extends StatefulWidget {
  const _RecitationManualStartSheet({
    required this.db,
    required this.initialSurahNumber,
    required this.initialAyahNumber,
  });

  final RecitationDb db;
  final int initialSurahNumber;
  final int initialAyahNumber;

  @override
  State<_RecitationManualStartSheet> createState() =>
      _RecitationManualStartSheetState();
}

class _RecitationManualStartSheetState extends State<_RecitationManualStartSheet> {
  static const double _wheelHeight = 200;
  static const double _itemExtent = 40;

  static const Color _surface = Color(0xFFE8F5E9);
  static const Color _title = Color(0xFF1B5E20);
  static const Color _muted = Color(0xFF4F6B54);
  static const Color _wheelFill = Color(0xFFF4F8F4);
  static const Color _wheelBorder = Color(0xFFD8E6D8);
  static const Color _wheelSel = Color(0xFF1B5E20);
  static const Color _wheelUnsel = Color(0xFF7A9A82);

  List<Map<String, Object?>> _surahs = const [];
  bool _loading = true;
  String? _error;

  late int _surahNumber;
  late int _ayahNumber;
  int _ayahCount = 1;

  late FixedExtentScrollController _surahController;
  late FixedExtentScrollController _ayahController;

  int _surahIndexForNumber(int n) {
    final i = _surahs.indexWhere((s) => (s['id'] as int?) == n);
    return i < 0 ? 0 : i;
  }

  @override
  void initState() {
    super.initState();
    _surahNumber = widget.initialSurahNumber.clamp(1, 114);
    _ayahNumber = widget.initialAyahNumber.clamp(1, 286);
    _surahController = FixedExtentScrollController();
    _ayahController = FixedExtentScrollController();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    try {
      await widget.db.init();
      final surahs = await widget.db.getSurahs();
      if (surahs.isEmpty) throw StateError('لا توجد سور');
      if (!mounted) return;
      setState(() {
        _surahs = surahs;
        _loading = false;
        _error = null;
        _surahNumber = _surahNumber.clamp(1, 114);
      });
      await _clampSurahAndAyah();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _surahController.jumpToItem(_surahIndexForNumber(_surahNumber));
        _ayahController.jumpToItem(_ayahNumber - 1);
      });
    } catch (e) {
      debugPrint('Manual start sheet bootstrap failed: $e');
      if (mounted) {
        setState(() {
          _loading = false;
          _error = 'تعذّر تحميل بيانات البداية. أعد المحاولة.';
        });
      }
    }
  }

  Future<void> _clampSurahAndAyah() async {
    final list = await widget.db.getAyahsForSurah(_surahNumber);
    final count = list.length.clamp(1, 999);
    if (!mounted) return;
    setState(() {
      _ayahCount = count;
      _ayahNumber = _ayahNumber.clamp(1, _ayahCount);
    });
  }

  @override
  void dispose() {
    _surahController.dispose();
    _ayahController.dispose();
    super.dispose();
  }

  String _toArabicDigits(int value) {
    const western = '0123456789';
    const arabic = '٠١٢٣٤٥٦٧٨٩';
    final input = value.toString();
    final buffer = StringBuffer();
    for (final rune in input.runes) {
      final ch = String.fromCharCode(rune);
      final index = western.indexOf(ch);
      buffer.write(index >= 0 ? arabic[index] : ch);
    }
    return buffer.toString();
  }

  Widget _wheelColumn({
    required String title,
    required int selectedIndex,
    required int childCount,
    required FixedExtentScrollController controller,
    required String Function(int index) labelBuilder,
    required ValueChanged<int> onChanged,
  }) {
    return Expanded(
      child: Column(
        children: [
          Text(
            title,
            style: const TextStyle(
              color: _muted,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          Expanded(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: _wheelFill,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: _wheelBorder),
              ),
              child: ListWheelScrollView.useDelegate(
                controller: controller,
                itemExtent: _itemExtent,
                perspective: 0.005,
                diameterRatio: 1.5,
                physics: const BouncingScrollPhysics(
                  parent: FixedExtentScrollPhysics(),
                ),
                onSelectedItemChanged: onChanged,
                childDelegate: ListWheelChildBuilderDelegate(
                  childCount: childCount,
                  builder: (_, i) {
                    final selected = i == selectedIndex;
                    return Center(
                      child: Text(
                        labelBuilder(i),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: selected ? 16 : 15,
                          fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                          color: selected ? _wheelSel : _wheelUnsel,
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: Material(
          color: _surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(18)),
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      IconButton(
                        tooltip: 'رجوع',
                        onPressed: () => Navigator.pop(context),
                        icon: const Icon(Icons.arrow_back_ios_new_rounded,
                            size: 20, color: _title),
                      ),
                      const Expanded(
                        child: Text(
                          'تحديد موضع البداية',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w700,
                            color: _title,
                          ),
                        ),
                      ),
                      const SizedBox(width: 48),
                    ],
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'اختر السورة ثم رقم الآية، ثم أكّد للعودة إلى الاستماع.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 13,
                      color: _muted,
                      height: 1.45,
                    ),
                  ),
                  const SizedBox(height: 12),
                  if (_loading)
                    const SizedBox(
                      height: _wheelHeight,
                      child: Center(child: CircularProgressIndicator()),
                    )
                  else if (_error != null)
                    SizedBox(
                      height: 120,
                      child: Center(
                        child: Text(
                          _error!,
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: Colors.red),
                        ),
                      ),
                    )
                  else
                    SizedBox(
                      height: _wheelHeight,
                      child: Row(
                        children: [
                          _wheelColumn(
                            title: 'السورة',
                            selectedIndex: _surahIndexForNumber(_surahNumber),
                            childCount: _surahs.length,
                            controller: _surahController,
                            labelBuilder: (i) {
                              final s = _surahs[i];
                              final no = (s['id'] as int?) ?? (i + 1);
                              final name = (s['name_ar'] ?? '').toString();
                              return '${_toArabicDigits(no)} — $name';
                            },
                            onChanged: (i) async {
                              if (i < 0 || i >= _surahs.length) return;
                              final no = (_surahs[i]['id'] as int?) ?? 1;
                              setState(() {
                                _surahNumber = no;
                              });
                              await _clampSurahAndAyah();
                              if (mounted) {
                                _ayahController.jumpToItem(_ayahNumber - 1);
                              }
                            },
                          ),
                          const SizedBox(width: 10),
                          _wheelColumn(
                            title: 'رقم الآية',
                            selectedIndex: _ayahNumber - 1,
                            childCount: _ayahCount,
                            controller: _ayahController,
                            labelBuilder: (i) => _toArabicDigits(i + 1),
                            onChanged: (i) {
                              final n = (i + 1).clamp(1, _ayahCount);
                              setState(() => _ayahNumber = n);
                            },
                          ),
                        ],
                      ),
                    ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () => Navigator.pop(context),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: _title,
                            side: const BorderSide(color: _wheelBorder),
                            padding: const EdgeInsets.symmetric(vertical: 14),
                          ),
                          child: const Text('إلغاء'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: FilledButton(
                          onPressed: _loading || _error != null
                              ? null
                              : () {
                                  Navigator.pop(
                                    context,
                                    (
                                      surahNumber: _surahNumber,
                                      ayahNumber: _ayahNumber,
                                    ),
                                  );
                                },
                          style: FilledButton.styleFrom(
                            backgroundColor: const Color(0xFF2E7D32),
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 14),
                          ),
                          child: const Text('تأكيد'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
