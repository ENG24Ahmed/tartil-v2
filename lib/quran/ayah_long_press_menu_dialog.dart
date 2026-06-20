import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:quran_app/audio/ayah_audio_player.dart';
import 'package:quran_app/audio/ayah_reciters_config.dart';
import 'package:quran_app/quran/mushaf_ram_idle_expander.dart';

/// عنصر في قائمة الضغط المطول على آية (نفس تخطيط القارئ الرئيسي).
class AyahLongPressMenuItem extends StatelessWidget {
  const AyahLongPressMenuItem({
    super.key,
    required this.icon,
    required this.label,
    this.subtitle,
    required this.arabicFontFamily,
    this.enabled = true,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final String? subtitle;
  final String arabicFontFamily;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = enabled ? Colors.white : Colors.white54;
    return InkWell(
      onTap: enabled ? onTap : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        child: Row(
          children: [
            Icon(icon,
                color: enabled ? Colors.white : Colors.white38, size: 22),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    label,
                    style: TextStyle(
                      fontFamily: arabicFontFamily,
                      fontSize: 15,
                      color: color,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (subtitle != null) ...[
                    const SizedBox(height: 1),
                    Text(
                      subtitle!,
                      style: TextStyle(
                        fontFamily: arabicFontFamily,
                        fontSize: 12,
                        color: Colors.white70,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

bool ayahHighlightingDisabledWhileAudioActive() {
  final player = AyahAudioPlayer.instance;
  return player.isActive || player.state == AyahPlayerState.error;
}

String _reciterNameArForMenu() {
  for (final r in kAyahReciters) {
    if (r.id == AyahAudioPlayer.instance.currentReciterId) return r.nameAr;
  }
  return 'القارئ الحالي';
}

/// تفسير آية واحدة (السعدي / الميسّر) بدون اعتماد على حالة [QuranPageViewer].
Future<void> showStandaloneTafseerForAyah(
  BuildContext context, {
  required int sura,
  required int ayah,
  required String suraName,
  required String arabicUiFontFamily,
  required TextStyle Function({
    required double fontSize,
    required Color color,
    FontWeight fontWeight,
  }) menuQuranStyle,
  required String Function(int) toNormalDigits,
}) async {
  await TafseerAssetMaps.instance.ensureLoaded();
  if (!context.mounted) return;
  final key = '$sura:$ayah';
  final saadi = TafseerAssetMaps.instance.saadi[key] ?? '';
  final mouaser = TafseerAssetMaps.instance.mouaser[key] ?? '';
  const emptyHint = 'لا يوجد تفسير لهذه الآية';

  await showDialog<void>(
    context: context,
    barrierColor: Colors.black26,
    builder: (ctx) {
      return Directionality(
        textDirection: TextDirection.rtl,
        child: DefaultTabController(
          length: 2,
          child: AlertDialog(
            title: Text(
              'تفسير $suraName – الآية ${toNormalDigits(ayah)}',
              textAlign: TextAlign.center,
              style: menuQuranStyle(
                fontSize: 16,
                color: Theme.of(ctx).colorScheme.onSurface,
                fontWeight: FontWeight.bold,
              ),
            ),
            content: SizedBox(
              width: double.maxFinite,
              height: MediaQuery.sizeOf(ctx).height * 0.42,
              child: Column(
                children: [
                  TabBar(
                    labelColor: Theme.of(ctx).colorScheme.primary,
                    tabs: const [
                      Tab(text: 'السعدي'),
                      Tab(text: 'الميسّر'),
                    ],
                  ),
                  Expanded(
                    child: TabBarView(
                      children: [
                        SingleChildScrollView(
                          child: Text(
                            saadi.isEmpty ? emptyHint : saadi,
                            style: menuQuranStyle(
                              fontSize: 15,
                              color: Theme.of(ctx).colorScheme.onSurface,
                            ),
                          ),
                        ),
                        SingleChildScrollView(
                          child: Text(
                            mouaser.isEmpty ? emptyHint : mouaser,
                            style: menuQuranStyle(
                              fontSize: 15,
                              color: Theme.of(ctx).colorScheme.onSurface,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () {
                  if (saadi.isNotEmpty) {
                    Clipboard.setData(ClipboardData(text: saadi));
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          'تم نسخ تفسير السعدي',
                          style: menuQuranStyle(
                              fontSize: 14, color: Colors.white),
                        ),
                        backgroundColor: const Color(0xFF2E7D32),
                      ),
                    );
                  }
                  Navigator.pop(ctx);
                },
                child: Text(
                  'نسخ السعدي',
                  style: menuQuranStyle(
                    fontSize: 15,
                    color: Theme.of(ctx).colorScheme.primary,
                  ),
                ),
              ),
              TextButton(
                onPressed: () {
                  if (mouaser.isNotEmpty) {
                    Clipboard.setData(ClipboardData(text: mouaser));
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          'تم نسخ تفسير الميسّر',
                          style: menuQuranStyle(
                              fontSize: 14, color: Colors.white),
                        ),
                        backgroundColor: const Color(0xFF2E7D32),
                      ),
                    );
                  }
                  Navigator.pop(ctx);
                },
                child: Text(
                  'نسخ الميسّر',
                  style: menuQuranStyle(
                    fontSize: 15,
                    color: Theme.of(ctx).colorScheme.primary,
                  ),
                ),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text(
                  'إغلاق',
                  style: menuQuranStyle(
                    fontSize: 15,
                    color: Theme.of(ctx).colorScheme.primary,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}

/// قائمة الضغط المطول على آية — نفس شكل القارئ الرئيسي؛ [onTafseer]/[onHighlight] اختياريان.
///
/// خيارات التسميع الذكي: [onRecitationOverrideAyahErrors] يُعرض بدل «التفسير»؛
/// [onRecitationJumpToAyahStart] صف إضافي للبدء من أول الآية؛
/// [onOpenSmartRecitationFromAyah] للقارئ العادي (فتح التسميع من هذه الآية).
Future<void> showAyahLongPressMenuDialog({
  required BuildContext parentContext,
  required int sura,
  required int ayah,
  required String ayahText,
  required VoidCallback onClearSelection,
  required String suraName,
  required String arabicUiFontFamily,
  required TextStyle Function({
    required double fontSize,
    required Color color,
    FontWeight fontWeight,
  }) menuQuranStyle,
  required String Function(int) toNormalDigits,
  bool rotateMenuForLandscape = false,
  required bool isHighlightingDisabledByAudio,
  VoidCallback? onTafseer,
  VoidCallback? onHighlight,
  VoidCallback? onRecitationOverrideAyahErrors,
  bool recitationOverrideAyahErrorsEnabled = false,
  VoidCallback? onRecitationJumpToAyahStart,
  bool recitationJumpToAyahStartEnabled = true,
  VoidCallback? onOpenSmartRecitationFromAyah,
  bool openSmartRecitationFromAyahEnabled = true,
}) async {
  final reciterName = _reciterNameArForMenu();
  final hasRecitationExtras = onRecitationOverrideAyahErrors != null ||
      onRecitationJumpToAyahStart != null ||
      onOpenSmartRecitationFromAyah != null;
  MushafRamIdleExpander.instance.beginBlockingUi();
  await showDialog<void>(
    context: parentContext,
    barrierColor: Colors.black26,
    builder: (menuCtx) => Directionality(
      textDirection: TextDirection.rtl,
      child: Center(
        child: Material(
          color: Colors.transparent,
          child: RotatedBox(
            quarterTurns: rotateMenuForLandscape ? 1 : 0,
            child: Container(
              constraints: BoxConstraints(
                maxWidth: 280,
                maxHeight: MediaQuery.sizeOf(menuCtx).height *
                    (hasRecitationExtras ? 0.52 : 0.35),
              ),
              decoration: BoxDecoration(
                color: const Color.fromARGB(255, 5, 24, 13)
                    .withValues(alpha: 0.78),
                borderRadius: BorderRadius.circular(16),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.2),
                    blurRadius: 16,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                    child: Text(
                      '$suraName – الآية ${toNormalDigits(ayah)}',
                      style: menuQuranStyle(
                        fontSize: 15,
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                  Divider(
                      height: 1, color: Colors.white.withValues(alpha: 0.3)),
                  Flexible(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Column(
                        children: [
                          AyahLongPressMenuItem(
                            icon: Icons.volume_up_outlined,
                            label: 'الاستماع للآية',
                            subtitle: 'تلاوة $reciterName',
                            arabicFontFamily: arabicUiFontFamily,
                            enabled: true,
                            onTap: () async {
                              Navigator.pop(menuCtx);
                              final ok = await AyahAudioPlayer.instance
                                  .playAyah(sura, ayah);
                              if (!parentContext.mounted) return;
                              if (!ok) {
                                ScaffoldMessenger.of(parentContext)
                                    .showSnackBar(
                                  SnackBar(
                                    content: Text(
                                      'تعذّر تشغيل تلاوة هذه الآية. تحقق من اتصالك بالإنترنت وحاول مرة أخرى.',
                                      style: menuQuranStyle(
                                          fontSize: 14, color: Colors.white),
                                    ),
                                    backgroundColor: const Color(0xFF2E7D32),
                                  ),
                                );
                              }
                            },
                          ),
                          if (onTafseer != null)
                            AyahLongPressMenuItem(
                              icon: Icons.menu_book_outlined,
                              label: 'التفسير',
                              subtitle: 'السعدي / الميسّر',
                              arabicFontFamily: arabicUiFontFamily,
                              onTap: () {
                                Navigator.pop(menuCtx);
                                onTafseer();
                              },
                            ),
                          if (onOpenSmartRecitationFromAyah != null)
                            AyahLongPressMenuItem(
                              icon: Icons.mic_rounded,
                              label: 'بدء التسميع من هذه الآية',
                              subtitle: openSmartRecitationFromAyahEnabled
                                  ? 'فتح التسميع الذكي من أول كلمة في هذه الآية'
                                  : 'متوقف أثناء الاستماع',
                              arabicFontFamily: arabicUiFontFamily,
                              enabled: openSmartRecitationFromAyahEnabled,
                              onTap: () {
                                Navigator.pop(menuCtx);
                                onOpenSmartRecitationFromAyah();
                              },
                            ),
                          if (onRecitationOverrideAyahErrors != null)
                            AyahLongPressMenuItem(
                              icon: Icons.verified_outlined,
                              label: 'تجاوز أخطاء الآية',
                              subtitle: recitationOverrideAyahErrorsEnabled
                                  ? 'احتساب كل كلمات هذه الآية صحيحة في التسميع'
                                  : 'يتاح بعد بدء قراءة الآية ووجود أخطاء',
                              arabicFontFamily: arabicUiFontFamily,
                              enabled: recitationOverrideAyahErrorsEnabled,
                              onTap: () {
                                Navigator.pop(menuCtx);
                                onRecitationOverrideAyahErrors();
                              },
                            ),
                          if (onRecitationJumpToAyahStart != null)
                            AyahLongPressMenuItem(
                              icon: Icons.start_rounded,
                              label: 'البدء من هذا الموضع',
                              subtitle: recitationJumpToAyahStartEnabled
                                  ? 'من أول كلمة في هذه الآية (مثل إعادة التموضع)'
                                  : 'أنت بالفعل عند بداية هذه الآية',
                              arabicFontFamily: arabicUiFontFamily,
                              enabled: recitationJumpToAyahStartEnabled,
                              onTap: () {
                                Navigator.pop(menuCtx);
                                onRecitationJumpToAyahStart();
                              },
                            ),
                          if (onHighlight != null)
                            AyahLongPressMenuItem(
                              icon: Icons.highlight,
                              label: 'التضليل',
                              subtitle: isHighlightingDisabledByAudio
                                  ? 'متوقف أثناء الاستماع'
                                  : 'تضليل الآية أو نطاق آيات',
                              arabicFontFamily: arabicUiFontFamily,
                              enabled: !isHighlightingDisabledByAudio,
                              onTap: () {
                                Navigator.pop(menuCtx);
                                onHighlight();
                              },
                            ),
                          AyahLongPressMenuItem(
                            icon: Icons.copy,
                            label: 'نسخ الآية',
                            arabicFontFamily: arabicUiFontFamily,
                            onTap: () {
                              Clipboard.setData(ClipboardData(text: ayahText));
                              Navigator.pop(menuCtx);
                              onClearSelection();
                            },
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  ).whenComplete(() {
    MushafRamIdleExpander.instance.endBlockingUi();
    onClearSelection();
  });
}

/// تحميل مرة واحدة لخرائط التفسير (نفس مصادر [QuranPageViewer]).
class TafseerAssetMaps {
  TafseerAssetMaps._();
  static final TafseerAssetMaps instance = TafseerAssetMaps._();

  final Map<String, String> saadi = {};
  final Map<String, String> mouaser = {};
  Future<void>? _loadFuture;

  Future<void> ensureLoaded() {
    return _loadFuture ??= _load();
  }

  Future<void> _load() async {
    try {
      final tRaw =
          await rootBundle.loadString('assets/tafseer/tafseerMouaser_v03.txt');
      final lines = const LineSplitter().convert(tRaw);
      if (lines.length > 1) {
        for (var i = 1; i < lines.length; i++) {
          final line = lines[i];
          if (line.trim().isEmpty) continue;
          final parts = line.split('\t');
          if (parts.length < 12) continue;
          final suraNo = int.tryParse(parts[3].trim()) ?? 0;
          final ayaNo = int.tryParse(parts[8].trim()) ?? 0;
          if (suraNo <= 0 || ayaNo <= 0) continue;
          var tafseer = parts.length > 11 ? parts[11].trim() : '';
          if (tafseer.isEmpty) continue;
          if (tafseer.startsWith('[')) {
            final idx = tafseer.indexOf(']');
            if (idx != -1 && idx + 1 < tafseer.length) {
              tafseer = tafseer.substring(idx + 1).trim();
            }
          }
          tafseer = tafseer.replaceAll(RegExp(r'<[^>]+>'), '');
          if (tafseer.isNotEmpty) {
            mouaser['$suraNo:$ayaNo'] = tafseer;
          }
        }
      }
    } catch (_) {}

    try {
      final sRaw = await rootBundle.loadString('assets/tafseer/ar.saddi.json');
      final sJson = jsonDecode(sRaw) as Map<String, dynamic>;
      final all = (sJson['tafsir'] as List).cast<List>();
      for (var s = 0; s < all.length; s++) {
        final suraIndex = s + 1;
        final suraList = all[s].cast<String>();
        for (var a = 0; a < suraList.length; a++) {
          final ayaIndex = a + 1;
          var text = suraList[a].trim();
          if (text.isEmpty) continue;
          text = text.replaceAll(RegExp(r'<[^>]+>'), '');
          if (text.isEmpty) continue;
          saadi['$suraIndex:$ayaIndex'] = text;
        }
      }
    } catch (_) {}
  }
}
