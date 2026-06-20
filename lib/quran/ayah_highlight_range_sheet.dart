import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:quran_app/audio/ayah_audio_player.dart';
import 'package:quran_app/quran/ayah_highlight_persistence.dart';
import 'package:quran_app/quran/mushaf_ram_idle_expander.dart';
import 'package:quran_app/quran/quran_menu_palette.dart';
import 'package:quran_app/quran/renderers/qpc_v4_renderer.dart' show AyahRangeHighlight;

const int _kTotalQuranPages = 604;

/// تحميل فهرس السور وعدد آيات كل سورة من [assets/data/hafs_smart_v8.json] — نفس منطق [QuranPageViewer].
Future<
    ({
      List<({int no, String nameAr, int startPage})> suraList,
      Map<int, int> suraAyahCount,
    })> loadSuraCatalogFromHafsJson() async {
  final raw = await rootBundle.loadString('assets/data/hafs_smart_v8.json');
  final list = jsonDecode(raw) as List;
  final suraToMinPage = <int, int>{};
  final suraToNameAr = <int, String>{};
  final suraAyahCount = <int, int>{};

  for (final e in list) {
    final m = Map<String, dynamic>.from(e as Map);
    final page = (m['page'] as num?)?.toInt() ?? 0;
    final suraNo = (m['sura_no'] as num?)?.toInt() ?? 0;
    final suraAr = m['sura_name_ar'] as String?;
    if (page >= 1 && page <= _kTotalQuranPages && suraNo >= 1 && suraNo <= 114) {
      if (!suraToMinPage.containsKey(suraNo) || page < suraToMinPage[suraNo]!) {
        suraToMinPage[suraNo] = page;
        if (suraAr != null) suraToNameAr[suraNo] = suraAr;
      }
    }
    final ayaNo = (m['aya_no'] as num?)?.toInt() ?? 0;
    if (suraNo > 0 && ayaNo > 0) {
      final prev = suraAyahCount[suraNo] ?? 0;
      if (ayaNo > prev) suraAyahCount[suraNo] = ayaNo;
    }
  }

  final suraList = <({int no, String nameAr, int startPage})>[];
  for (var no = 1; no <= 114; no++) {
    final start = suraToMinPage[no];
    if (start != null) {
      suraList.add((no: no, nameAr: suraToNameAr[no] ?? '', startPage: start));
    }
  }
  return (suraList: suraList, suraAyahCount: suraAyahCount);
}

bool _ayahHighlightingDisabledWhileAudioActive() {
  final player = AyahAudioPlayer.instance;
  return player.isActive || player.state == AyahPlayerState.error;
}

class AyahHighlightWheelPicker extends StatelessWidget {
  const AyahHighlightWheelPicker({
    super.key,
    required this.title,
    required this.arabicFontFamily,
    required this.controller,
    required this.itemCount,
    required this.itemBuilder,
    required this.onSelectedItemChanged,
  });

  final String title;
  final String arabicFontFamily;
  final FixedExtentScrollController controller;
  final int itemCount;
  final String Function(int index) itemBuilder;
  final ValueChanged<int> onSelectedItemChanged;

  @override
  Widget build(BuildContext context) {
    final pal = QuranMenuPalette.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          title,
          style: TextStyle(
            fontFamily: arabicFontFamily,
            fontSize: 14,
            color: pal.title,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: Container(
            height: 120,
            decoration: BoxDecoration(
              color: pal.wheelColumnInnerFill,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: pal.wheelColumnBorder),
            ),
            child: CupertinoPicker.builder(
              scrollController: controller,
              itemExtent: 38,
              magnification: 1.03,
              useMagnifier: true,
              selectionOverlay: Container(
                decoration: BoxDecoration(
                  border: Border.symmetric(
                    horizontal: BorderSide(
                      color: pal.wheelPickerBorder.withValues(alpha: 0.55),
                    ),
                  ),
                ),
              ),
              onSelectedItemChanged: onSelectedItemChanged,
              childCount: itemCount,
              itemBuilder: (_, i) => ListenableBuilder(
                listenable: controller,
                builder: (context, __) {
                  var selectedIndex = 0;
                  if (controller.hasClients) {
                    try {
                      selectedIndex = controller.selectedItem;
                    } catch (_) {}
                  }
                  final isSelected = i == selectedIndex;
                  return Center(
                    child: Text(
                      itemBuilder(i),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontFamily: arabicFontFamily,
                        fontSize: isSelected ? 18 : 16,
                        color: isSelected
                            ? pal.wheelTextSelected
                            : pal.wheelTextUnselected,
                        fontWeight:
                            isSelected ? FontWeight.w700 : FontWeight.w500,
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// ورقة «تضليل الآيات» الموحّدة — نفس النصوص والألوان والعجلات كالقارئ الرئيسي؛
/// الحفظ عبر [persistAyahHighlightRangesAndPublishStore].
Future<void> showAyahHighlightRangeSheet(
  BuildContext context, {
  required int initialSura,
  required int initialFromAyah,
  required int initialToAyah,
  AyahRangeHighlight? editing,
  required List<({int no, String nameAr, int startPage})> suraList,
  required Map<int, int> suraAyahCount,
  required bool menuDarkMode,
  required String arabicUiFontFamily,
  required TextStyle Function({
    required double fontSize,
    required Color color,
    FontWeight fontWeight,
  }) menuQuranStyle,
  required String Function(int) toNormalDigits,
}) async {
  assert(
    editing != null || (initialSura >= 1 && initialFromAyah >= 1),
    'تحرير أو تمرير سورة وآية',
  );
  if (_ayahHighlightingDisabledWhileAudioActive()) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'التضليل متوقف أثناء الاستماع',
          style: menuQuranStyle(fontSize: 14, color: Colors.white),
        ),
        backgroundColor: const Color(0xFF2E7D32),
      ),
    );
    return;
  }

  final isEditing = editing != null;
  final int initSura = editing?.sura ?? initialSura;
  final int initFrom = editing?.fromAyah ?? initialFromAyah;
  final int initTo = editing?.toAyah ?? initialToAyah;
  final suraFoundIndex = suraList.indexWhere((s) => s.no == initSura);
  final initialSuraIndex =
      (suraFoundIndex < 0 ? 0 : suraFoundIndex).clamp(0, suraList.length - 1);
  int selectedSuraIndex = initialSuraIndex;
  int selectedSura = suraList[selectedSuraIndex].no;
  int ayahCount = (suraAyahCount[selectedSura] ?? 286).clamp(1, 286);
  int fromAyah = initFrom.clamp(1, ayahCount);
  int toAyah = initTo.clamp(1, ayahCount);
  Color selectedColor = editing?.color ?? Colors.yellow;
  final basePalette = <Color>[
    Colors.yellow,
    Colors.green,
    Colors.lightBlue,
    Colors.orange,
    Colors.pink,
    Colors.purpleAccent,
  ];
  final colors = List<Color>.from(basePalette);
  if (editing != null &&
      !colors.any((c) => c.toARGB32() == editing.color.toARGB32())) {
    colors.add(editing.color);
  }
  final suraController =
      FixedExtentScrollController(initialItem: selectedSuraIndex);
  final fromController = FixedExtentScrollController(initialItem: fromAyah - 1);
  final toController = FixedExtentScrollController(initialItem: toAyah - 1);

  final pal = menuDarkMode ? QuranMenuPaletteData.dark : QuranMenuPaletteData.light;

  MushafRamIdleExpander.instance.beginBlockingUi();
  try {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: pal.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (ctx) {
        return QuranMenuPalette(
          data: pal,
          child: Directionality(
            textDirection: TextDirection.rtl,
            child: StatefulBuilder(
              builder: (ctx, setLocalState) {
                final cardBg = pal.isDark ? pal.cardSurface : Colors.white;
                final cardBorder = pal.divider;
                return Padding(
                  padding: EdgeInsets.fromLTRB(
                    16,
                    14,
                    16,
                    16 + MediaQuery.of(ctx).viewInsets.bottom,
                  ),
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          isEditing ? 'تعديل التضليل' : 'تضليل الآيات',
                          textAlign: TextAlign.center,
                          style: menuQuranStyle(
                            fontSize: 19,
                            color: pal.title,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 12),
                        Container(
                          decoration: BoxDecoration(
                            color: cardBg,
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(color: cardBorder),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.03),
                                blurRadius: 6,
                                offset: const Offset(0, 2),
                              ),
                            ],
                          ),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 10,
                          ),
                          child: Row(
                            children: [
                              Expanded(
                                child: AyahHighlightWheelPicker(
                                  title: 'السورة',
                                  arabicFontFamily: arabicUiFontFamily,
                                  controller: suraController,
                                  itemCount: suraList.length,
                                  itemBuilder: (i) =>
                                      '${i + 1} ${suraList[i].nameAr.replaceAll('سورة ', '')}',
                                  onSelectedItemChanged: (i) {
                                    setLocalState(() {
                                      selectedSuraIndex = i;
                                      selectedSura = suraList[i].no;
                                      ayahCount = (suraAyahCount[selectedSura] ?? 286)
                                          .clamp(1, 286);
                                      if (fromAyah > ayahCount) {
                                        fromAyah = ayahCount;
                                      }
                                      if (toAyah > ayahCount) {
                                        toAyah = ayahCount;
                                      }
                                    });
                                    if (fromController.selectedItem !=
                                        fromAyah - 1) {
                                      fromController.jumpToItem(fromAyah - 1);
                                    }
                                    if (toController.selectedItem != toAyah - 1) {
                                      toController.jumpToItem(toAyah - 1);
                                    }
                                  },
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: AyahHighlightWheelPicker(
                                  title: 'من آية',
                                  arabicFontFamily: arabicUiFontFamily,
                                  controller: fromController,
                                  itemCount: ayahCount,
                                  itemBuilder: (i) => 'آية ${i + 1}',
                                  onSelectedItemChanged: (i) {
                                    setLocalState(() => fromAyah = i + 1);
                                  },
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: AyahHighlightWheelPicker(
                                  title: 'إلى آية',
                                  arabicFontFamily: arabicUiFontFamily,
                                  controller: toController,
                                  itemCount: ayahCount,
                                  itemBuilder: (i) => 'آية ${i + 1}',
                                  onSelectedItemChanged: (i) {
                                    setLocalState(() => toAyah = i + 1);
                                  },
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 12),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 10),
                          decoration: BoxDecoration(
                            color: cardBg,
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(color: cardBorder),
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                            children: colors.map((c) {
                              final selected =
                                  c.toARGB32() == selectedColor.toARGB32();
                              final labelOnTint = Color.lerp(
                                    c,
                                    pal.isDark ? Colors.white : Colors.black,
                                    pal.isDark ? 0.92 : 0.78,
                                  ) ??
                                  pal.title;
                              return Flexible(
                                child: ChoiceChip(
                                  showCheckmark: false,
                                  label: Text(
                                    selected ? 'مختار' : 'لون',
                                    style: menuQuranStyle(
                                      fontSize: 12,
                                      color:
                                          selected ? Colors.white : labelOnTint,
                                    ),
                                  ),
                                  selected: selected,
                                  selectedColor: c,
                                  backgroundColor: c.withValues(alpha: 0.24),
                                  side: BorderSide(
                                    color: selected ? c : pal.divider,
                                    width: selected ? 1.5 : 1,
                                  ),
                                  onSelected: (_) =>
                                      setLocalState(() => selectedColor = c),
                                ),
                              );
                            }).toList(growable: false),
                          ),
                        ),
                        const SizedBox(height: 14),
                        Row(
                          children: [
                            Expanded(
                              child: OutlinedButton.icon(
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: pal.accent,
                                  side: BorderSide(
                                    color: pal.accent.withValues(alpha: 0.55),
                                  ),
                                  padding:
                                      const EdgeInsets.symmetric(vertical: 12),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(14),
                                  ),
                                ),
                                onPressed: () => Navigator.pop(ctx),
                                icon: Icon(Icons.close, color: pal.accent),
                                label: Text(
                                  'إلغاء التضليل',
                                  style: menuQuranStyle(
                                    fontSize: 16,
                                    color: pal.accent,
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: ElevatedButton.icon(
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: pal.accent,
                                  foregroundColor: Colors.white,
                                  padding:
                                      const EdgeInsets.symmetric(vertical: 12),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(14),
                                  ),
                                ),
                                onPressed: () async {
                                  Navigator.pop(ctx);
                                  final base = await readAyahHighlightRanges();
                                  final countForSura =
                                      (suraAyahCount[selectedSura] ?? 286)
                                          .clamp(1, 286);
                                  final merged = mergeAyahHighlightApplyRange(
                                    base,
                                    sura: selectedSura,
                                    fromAyah: fromAyah,
                                    toAyah: toAyah,
                                    color: selectedColor,
                                    replace: editing,
                                    ayahCountForSura: countForSura,
                                  );
                                  await persistAyahHighlightRangesAndPublishStore(
                                      merged);
                                  if (!context.mounted) return;
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text(
                                        isEditing
                                            ? 'تم تحديث التضليل'
                                            : 'تم حفظ التضليل من آية ${toNormalDigits(fromAyah)} إلى ${toNormalDigits(toAyah)}',
                                        style: menuQuranStyle(
                                            fontSize: 14, color: Colors.white),
                                      ),
                                      backgroundColor: pal.accent,
                                    ),
                                  );
                                },
                                icon: const Icon(Icons.highlight),
                                label: Text(
                                  isEditing ? 'حفظ التعديل' : 'تطبيق التضليل',
                                  style: menuQuranStyle(
                                      fontSize: 16, color: Colors.white),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        );
      },
    );
  } finally {
    MushafRamIdleExpander.instance.endBlockingUi();
  }
}
