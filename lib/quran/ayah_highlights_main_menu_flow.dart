import 'dart:async';

import 'package:flutter/material.dart';

import 'package:quran_app/quran/ayah_highlight_persistence.dart';
import 'package:quran_app/quran/ayah_long_press_menu_dialog.dart';
import 'package:quran_app/quran/hafs_ayah_page_lookup.dart';
import 'package:quran_app/quran/mushaf_ram_idle_expander.dart';
import 'package:quran_app/quran/nested_quran_menu_app_bar.dart';
import 'package:quran_app/quran/quran_menu_palette.dart';
import 'package:quran_app/quran/quran_menu_sheet_host.dart';
import 'package:quran_app/quran/renderers/qpc_v4_renderer.dart'
    show AyahRangeHighlight;

typedef AyahHighlightsMenuQuranStyle = TextStyle Function({
  required double fontSize,
  required Color color,
  FontWeight fontWeight,
});

/// صف «التضليل» في القائمة الرئيسية (عنوان + إظهار/إخفاء) — نفس تخطيط [QuranPageViewer._buildHighlightingMenuItem].
class AyahHighlightsMainMenuRow extends StatelessWidget {
  const AyahHighlightsMainMenuRow({
    super.key,
    required this.menuPalette,
    required this.menuQuranStyle,
    required this.visible,
    required this.enabled,
    required this.onShowIndex,
    required this.onToggleVisibility,
  });

  final QuranMenuPaletteData menuPalette;
  final AyahHighlightsMenuQuranStyle menuQuranStyle;
  final bool visible;
  final bool enabled;
  final VoidCallback onShowIndex;
  final VoidCallback onToggleVisibility;

  @override
  Widget build(BuildContext context) {
    final pal = menuPalette;
    final titleColor = enabled ? pal.title : pal.subtitle;
    final accentColor = enabled ? pal.accent : pal.trailingChevron;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Material(
        color: pal.cardSurface,
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        elevation: 1,
        shadowColor: Colors.black.withValues(alpha: 0.06),
        child: InkWell(
          onTap: enabled ? onShowIndex : null,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: enabled
                        ? pal.accent.withValues(alpha: 0.10)
                        : pal.subtitle.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(Icons.highlight, color: accentColor, size: 22),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(
                    'التضليل',
                    style: menuQuranStyle(
                      fontSize: 17,
                      color: titleColor,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                InkWell(
                  onTap: enabled ? onToggleVisibility : null,
                  borderRadius: BorderRadius.circular(8),
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          visible ? Icons.visibility : Icons.visibility_off,
                          size: 20,
                          color: enabled
                              ? (visible ? pal.accent : pal.subtitle)
                              : pal.trailingChevron,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          visible ? 'إخفاء' : 'إظهار',
                          style: menuQuranStyle(
                            fontSize: 14,
                            color: enabled
                                ? (visible ? pal.accent : pal.subtitle)
                                : pal.trailingChevron,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                Icon(Icons.arrow_forward_ios,
                    size: 16, color: pal.trailingChevron),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// فهرس «التضليلات المحفوظة» — نفس سلوك [QuranPageViewer._showAyahHighlightsIndex].
Future<void> showAyahHighlightsIndexPanel(
  BuildContext context, {
  required bool menuDarkMode,
  required bool horizontallyRotatedReading,
  required AyahHighlightsMenuQuranStyle menuQuranStyle,
  required String Function(int) toNormalDigits,
  required String Function(int suraNo) suraNameFromNo,
  required void Function(BuildContext dismissContext) onDismissAllMenus,
  void Function(int pageOneBased)? onJumpToMushafPage,
  Future<void> Function(BuildContext context, AyahRangeHighlight editing)?
      onEditHighlight,
  Future<void> Function(BuildContext context, AyahRangeHighlight highlight)?
      onRecitationFromHighlight,
  Future<void> Function()? onHighlightsListMutated,
}) async {
  final entries = List<AyahRangeHighlight>.from(await readAyahHighlightRanges());
  if (entries.isEmpty) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'لا توجد تضليلات محفوظة حالياً',
          style: menuQuranStyle(
            fontSize: 14,
            color: Colors.white,
            fontWeight: FontWeight.normal,
          ),
        ),
        backgroundColor: const Color(0xFF2E7D32),
      ),
    );
    return;
  }

  final pageLookup = await loadAyahFirstPageLookupFromHafs();
  final pal = menuDarkMode ? QuranMenuPaletteData.dark : QuranMenuPaletteData.light;

  Future<void> reopenAfterMutation(BuildContext outerContext) async {
    await onHighlightsListMutated?.call();
    if (!outerContext.mounted) return;
    await showAyahHighlightsIndexPanel(
      outerContext,
      menuDarkMode: menuDarkMode,
      horizontallyRotatedReading: horizontallyRotatedReading,
      menuQuranStyle: menuQuranStyle,
      toNormalDigits: toNormalDigits,
      suraNameFromNo: suraNameFromNo,
      onDismissAllMenus: onDismissAllMenus,
      onJumpToMushafPage: onJumpToMushafPage,
      onEditHighlight: onEditHighlight,
      onRecitationFromHighlight: onRecitationFromHighlight,
      onHighlightsListMutated: onHighlightsListMutated,
    );
  }

  MushafRamIdleExpander.instance.beginBlockingUi();
  await showQuranMenuSidePanel<void>(
    context: context,
    horizontallyRotatedReading: horizontallyRotatedReading,
    isScrollControlled: true,
    backgroundColor: pal.surface,
    builder: (ctx) => QuranMenuPalette(
      data: pal,
      child: wrapQuranMenuFamilySheetOverlay(
        ctx,
        Directionality(
          textDirection: TextDirection.rtl,
          child: SafeArea(
            child: SizedBox(
              height: MediaQuery.of(ctx).size.height * 0.62,
              child: Column(
                children: [
                  NestedQuranMenuAppBar(
                    title: 'التضليلات المحفوظة',
                    titleStyle: menuQuranStyle(
                      fontSize: 18,
                      color: pal.title,
                      fontWeight: FontWeight.bold,
                    ),
                    onBack: () => Navigator.pop(ctx),
                    onDismissAll: () => onDismissAllMenus(ctx),
                  ),
                  Divider(height: 1, color: pal.divider),
                  Expanded(
                    child: ListView.separated(
                      padding: const EdgeInsets.symmetric(
                          vertical: 12, horizontal: 12),
                      itemCount: entries.length,
                      separatorBuilder: (_, __) =>
                          Divider(height: 1, color: pal.divider),
                      itemBuilder: (itemCtx, i) {
                        final e = entries[i];
                        final page = pageLookup['${e.sura}:${e.fromAyah}'];
                        final title = suraNameFromNo(e.sura);
                        final rangeText = e.fromAyah == e.toAyah
                            ? 'آية ${toNormalDigits(e.fromAyah)}'
                            : 'من ${toNormalDigits(e.fromAyah)} إلى ${toNormalDigits(e.toAyah)}';
                        return ListTile(
                          leading: CircleAvatar(
                            backgroundColor: e.color.withValues(alpha: 0.90),
                            child: const Icon(Icons.highlight,
                                color: Colors.white, size: 18),
                          ),
                          title: Text(
                            title,
                            style: menuQuranStyle(
                              fontSize: 16,
                              color: pal.title,
                            ),
                          ),
                          subtitle: Text(
                            page == null
                                ? rangeText
                                : '$rangeText — ص ${toNormalDigits(page)}',
                            style: menuQuranStyle(
                              fontSize: 12,
                              color: pal.subtitle,
                              fontWeight: FontWeight.normal,
                            ),
                          ),
                          trailing: SizedBox(
                            width: onRecitationFromHighlight != null ? 172 : 118,
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.end,
                              children: [
                                if (onRecitationFromHighlight != null) ...[
                                  InkWell(
                                    borderRadius: BorderRadius.circular(8),
                                    onTap: () {
                                      final cb = onRecitationFromHighlight;
                                      Navigator.pop(ctx);
                                      unawaited(cb(context, e));
                                    },
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 4, vertical: 4),
                                      child: Column(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          const Icon(
                                            Icons.mic_rounded,
                                            size: 22,
                                            color: Color(0xFF2E7D32),
                                          ),
                                          const SizedBox(height: 2),
                                          Text(
                                            'تسميع',
                                            style: menuQuranStyle(
                                              fontSize: 11,
                                              color: const Color(0xFF2E7D32),
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 4),
                                ],
                                InkWell(
                                  borderRadius: BorderRadius.circular(8),
                                  onTap: () {
                                    if (ayahHighlightingDisabledWhileAudioActive()) {
                                      ScaffoldMessenger.of(context)
                                          .showSnackBar(
                                        SnackBar(
                                          content: Text(
                                            'التضليل متوقف أثناء الاستماع',
                                            style: menuQuranStyle(
                                              fontSize: 14,
                                              color: Colors.white,
                                            ),
                                          ),
                                          backgroundColor:
                                              const Color(0xFF2E7D32),
                                        ),
                                      );
                                      return;
                                    }
                                    final edit = onEditHighlight;
                                    if (edit == null) return;
                                    Navigator.pop(ctx);
                                    unawaited(edit(context, e));
                                  },
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 6, vertical: 4),
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(
                                          Icons.edit_outlined,
                                          size: 22,
                                          color:
                                              ayahHighlightingDisabledWhileAudioActive() ||
                                                      onEditHighlight == null
                                                  ? Colors.grey
                                                  : const Color(0xFF2E7D32),
                                        ),
                                        const SizedBox(height: 2),
                                        Text(
                                          'تعديل',
                                          style: menuQuranStyle(
                                            fontSize: 11,
                                            color:
                                                ayahHighlightingDisabledWhileAudioActive() ||
                                                        onEditHighlight == null
                                                    ? Colors.grey
                                                    : const Color(0xFF2E7D32),
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 6),
                                InkWell(
                                  borderRadius: BorderRadius.circular(8),
                                  onTap: () async {
                                    final shouldDelete = await showDialog<bool>(
                                          context: itemCtx,
                                          builder: (dialogCtx) =>
                                              Directionality(
                                            textDirection: TextDirection.rtl,
                                            child: AlertDialog(
                                              title: Text(
                                                'حذف التضليل',
                                                style: menuQuranStyle(
                                                  fontSize: 18,
                                                  color:
                                                      const Color(0xFF1B5E20),
                                                ),
                                              ),
                                              content: Text(
                                                'هل تريد حذف هذا التضليل؟',
                                                style: menuQuranStyle(
                                                  fontSize: 14,
                                                  color: Colors.black87,
                                                  fontWeight: FontWeight.normal,
                                                ),
                                              ),
                                              actions: [
                                                TextButton(
                                                  onPressed: () =>
                                                      Navigator.pop(
                                                          dialogCtx, false),
                                                  child: Text(
                                                    'إلغاء',
                                                    style: menuQuranStyle(
                                                      fontSize: 14,
                                                      color: Colors.grey,
                                                    ),
                                                  ),
                                                ),
                                                FilledButton(
                                                  style: FilledButton.styleFrom(
                                                      backgroundColor:
                                                          Colors.red),
                                                  onPressed: () =>
                                                      Navigator.pop(
                                                          dialogCtx, true),
                                                  child: Text(
                                                    'حذف',
                                                    style: menuQuranStyle(
                                                      fontSize: 14,
                                                      color: Colors.white,
                                                    ),
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                        ) ??
                                        false;
                                    if (!shouldDelete) return;
                                    final list =
                                        await readAyahHighlightRanges();
                                    list.removeWhere(
                                      (h) =>
                                          h.sura == e.sura &&
                                          h.fromAyah == e.fromAyah &&
                                          h.toAyah == e.toAyah &&
                                          h.color.toARGB32() ==
                                              e.color.toARGB32(),
                                    );
                                    await writeAyahHighlightRanges(list);
                                    await syncAyahHighlightStoreFromPrefs();
                                    if (!context.mounted) return;
                                    Navigator.pop(ctx);
                                    final next =
                                        await readAyahHighlightRanges();
                                    if (next.isEmpty) {
                                      await onHighlightsListMutated?.call();
                                      return;
                                    }
                                    await reopenAfterMutation(context);
                                  },
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 6, vertical: 4),
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        const Icon(Icons.delete_outline,
                                            color: Colors.red, size: 22),
                                        const SizedBox(height: 2),
                                        Text(
                                          'مسح',
                                          style: menuQuranStyle(
                                            fontSize: 11,
                                            color: Colors.red.shade700,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          onTap: () {
                            final jump = onJumpToMushafPage;
                            if (page != null && jump != null) {
                              onDismissAllMenus(ctx);
                              jump(page);
                              return;
                            }
                            if (page == null) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(
                                    'تعذّر تحديد صفحة البداية لهذا التضليل',
                                    style: menuQuranStyle(
                                      fontSize: 14,
                                      color: Colors.white,
                                    ),
                                  ),
                                  backgroundColor: const Color(0xFF2E7D32),
                                ),
                              );
                              return;
                            }
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(
                                  'انتقل للمصحف الرئيسي للذهاب إلى ص ${toNormalDigits(page)}',
                                  style: menuQuranStyle(
                                    fontSize: 14,
                                    color: Colors.white,
                                  ),
                                ),
                                backgroundColor: const Color(0xFF2E7D32),
                              ),
                            );
                          },
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        horizontallyRotatedReading: horizontallyRotatedReading,
      ),
    ),
  ).whenComplete(MushafRamIdleExpander.instance.endBlockingUi);
}
