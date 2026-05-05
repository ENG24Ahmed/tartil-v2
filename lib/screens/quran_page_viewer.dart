import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter/scheduler.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:vibration/vibration.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import '../audio/ayah_audio_player.dart';
import '../audio/ayah_reciters_config.dart';
import '../audio/ayah_reciters_prefs.dart';
import '../quran/ayah_highlight_persistence.dart';
import '../quran/ayah_highlight_range_sheet.dart';
import '../quran/ayah_long_press_menu_dialog.dart';
import '../quran/ayah_long_press_scope.dart';
import '../quran/quran_menu_palette.dart';
import '../quran/font_loader.dart';
import '../quran/models/mushaf_line.dart';
import '../quran/qpc_v1_loader.dart' show loadQpcV1Page;
import '../quran/quran_db.dart';
import '../quran/compact_line_spacing_scope.dart';
import '../quran/mushaf_page_layout.dart'
    show
        MushafPaperBackgroundScope,
        SeamlessLongScrollScope,
        mushafVerticalMarginFractionSum;
import '../quran/mushaf_ram_idle_expander.dart';
import '../quran/quran_reader.dart'
    show
        QuranReader,
        QpcMushafMode,
        buildQpcPageContent,
        preloadNearbyQpc1Pages;
import '../quran/renderers/qpc_v4_renderer.dart'
    show
        AyahHighlightStore,
        AyahRangeHighlight,
        kQpcPageNumberRowHeight,
        kQpcPageNumberBottomGap,
        kQpcPageNumberVerticalNudge,
        kQpcPageNumberVisualBoost,
        kQpcRaqumSvgScale,
        kQpcTopBarVerticalPadding,
        preloadNearbyPages,
        QpcV4Renderer;
import '../services/qpc_glyph_db.dart';
import '../features/developer/developer_options_screen.dart';
import '../quran/page_background_loader.dart';
import '../onboarding/mushaf_intro_prefs.dart';
import '../recitation/recitation_screen.dart';
import '../widgets/mushaf_intro_overlay.dart';
import '../quran/ayah_highlights_main_menu_flow.dart';
import '../quran/nested_quran_menu_app_bar.dart';
import '../quran/quran_menu_sheet_host.dart';

/// مسار منزلق LTR مع عكس القيمة: اللون النشط من الإبهام حتى **يمين** المسار
/// (أصغر حجم خط منطقيًا على اليمين).
class _FontScaleTrailingActiveTrackShape extends SliderTrackShape {
  @override
  Rect getPreferredRect({
    required RenderBox parentBox,
    Offset offset = Offset.zero,
    required SliderThemeData sliderTheme,
    bool isEnabled = false,
    bool isDiscrete = false,
  }) {
    final double h = sliderTheme.trackHeight ?? 4;
    final double top = offset.dy + (parentBox.size.height - h) / 2;
    return Rect.fromLTWH(offset.dx, top, parentBox.size.width, h);
  }

  @override
  void paint(
    PaintingContext context,
    Offset offset, {
    required Animation<double> enableAnimation,
    bool isDiscrete = false,
    bool isEnabled = false,
    required Offset thumbCenter,
    Offset? secondaryOffset,
    required SliderThemeData sliderTheme,
    required TextDirection textDirection,
    required RenderBox parentBox,
  }) {
    final double? th = sliderTheme.trackHeight;
    if (th == null || th <= 0) return;

    final trackRect = getPreferredRect(
      parentBox: parentBox,
      offset: offset,
      sliderTheme: sliderTheme,
      isEnabled: isEnabled,
      isDiscrete: isDiscrete,
    );

    final Color inactiveBase = sliderTheme.inactiveTrackColor ?? Colors.grey;
    final Color activeBase =
        sliderTheme.activeTrackColor ?? const Color(0xFF2E7D32);
    final Color inactiveColor = ColorTween(
      begin: sliderTheme.disabledInactiveTrackColor ?? inactiveBase,
      end: inactiveBase,
    ).evaluate(enableAnimation)!;
    final Color activeColor = ColorTween(
      begin: sliderTheme.disabledActiveTrackColor ?? activeBase,
      end: activeBase,
    ).evaluate(enableAnimation)!;

    final thumbX = thumbCenter.dx.clamp(trackRect.left, trackRect.right);
    final r = Radius.circular(trackRect.height / 2);

    final inactiveRect = Rect.fromLTRB(
      trackRect.left,
      trackRect.top,
      thumbX,
      trackRect.bottom,
    );
    if (inactiveRect.width > 0) {
      context.canvas.drawRRect(
        RRect.fromRectAndRadius(inactiveRect, r),
        Paint()..color = inactiveColor,
      );
    }

    final activeRect = Rect.fromLTRB(
      thumbX,
      trackRect.top,
      trackRect.right,
      trackRect.bottom,
    );
    if (activeRect.width > 0) {
      context.canvas.drawRRect(
        RRect.fromRectAndRadius(activeRect, r),
        Paint()..color = activeColor,
      );
    }
  }
}

/// نوع العرض: افتراضي، أفقي، صفحتان، تمرير طويل عمودي/أفقي (زر «التمرير الطويل» في القائمة).
enum DisplayType {
  standard,
  horizontal,
  twoPage,
  longScroll,
  horizontalLongScroll
}

/// يلتقط "نقرة" من دون تعطيل السحب/التمرير للأبناء.
class _PassiveTapListener extends StatelessWidget {
  const _PassiveTapListener({
    required this.child,
    required this.onTap,
  });

  final Widget child;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.deferToChild,
      onTap: onTap,
      child: child,
    );
  }
}

class _MainMenuCompactItem {
  final IconData icon;
  final String title;
  final VoidCallback onTap;
  final bool closeMenuBeforeAction;

  const _MainMenuCompactItem({
    required this.icon,
    required this.title,
    required this.onTap,
    this.closeMenuBeforeAction = true,
  });
}

/// معاينة موحّدة لاختيار خط النصوص العربية (القوائم، التفسير، وغيرها).
const String _kArabicUiFontPreviewPhrase =
    'رضيت بالله ربا . وبالإسلام دينا . وبمحمد صلى الله عليه وسلم نبيا';

class _ArabicUiFontChoice {
  const _ArabicUiFontChoice({
    required this.id,
    required this.labelAr,
    required this.fontFamily,
  });
  final String id;
  final String labelAr;
  final String fontFamily;
}

const String _kArabicUiFontIdUthmani = 'quran_uthmani';

const List<_ArabicUiFontChoice> _kArabicUiFontChoices = [
  _ArabicUiFontChoice(
    id: _kArabicUiFontIdUthmani,
    labelAr: 'عثماني (افتراضي)',
    fontFamily: 'QuranUthmani',
  ),
  _ArabicUiFontChoice(
    id: 'tafsir_glass_flowers',
    labelAr: 'Glass Flowers 3D',
    fontFamily: 'TafsirFontGlassFlowers3D',
  ),
  _ArabicUiFontChoice(
    id: 'tafsir_lantx_italic',
    labelAr: 'LANTX مائل',
    fontFamily: 'TafsirFontLantxItalic',
  ),
  _ArabicUiFontChoice(
    id: 'tafsir_takeaway_combo',
    labelAr: 'Takeaway Combo',
    fontFamily: 'TafsirFontTakeawayCombo',
  ),
  _ArabicUiFontChoice(
    id: 'tafsir_handicrafts',
    labelAr: 'The Year of Handicrafts',
    fontFamily: 'TafsirFontHandicraftsSemiBold',
  ),
];

String _arabicUiFontFamilyResolved(String id) {
  for (final c in _kArabicUiFontChoices) {
    if (c.id == id) return c.fontFamily;
  }
  return 'QuranUthmani';
}

_ArabicUiFontChoice? _arabicUiFontChoiceForId(String id) {
  for (final c in _kArabicUiFontChoices) {
    if (c.id == id) return c;
  }
  return null;
}

class QuranPageViewer extends StatefulWidget {
  const QuranPageViewer({super.key});

  @override
  State<QuranPageViewer> createState() => _QuranPageViewerState();
}

class _QuranPageViewerState extends State<QuranPageViewer>
    with WidgetsBindingObserver, TickerProviderStateMixin {
  static const String _surahNameFontFamily = 'SurahNameV4';
  static const int totalPages = 604;

  /// أسماء الأجزاء/الأحزاب بالعربية (المصدر: hafs_smart_v8.json يُحدد رقم الجزء فقط)
  static const List<String> _juzNames = [
    'الأول',
    'الثاني',
    'الثالث',
    'الرابع',
    'الخامس',
    'السادس',
    'السابع',
    'الثامن',
    'التاسع',
    'العاشر',
    'الحادي عشر',
    'الثاني عشر',
    'الثالث عشر',
    'الرابع عشر',
    'الخامس عشر',
    'السادس عشر',
    'السابع عشر',
    'الثامن عشر',
    'التاسع عشر',
    'العشرون',
    'الحادي والعشرون',
    'الثاني والعشرون',
    'الثالث والعشرون',
    'الرابع والعشرون',
    'الخامس والعشرون',
    'السادس والعشرون',
    'السابع والعشرون',
    'الثامن والعشرون',
    'التاسع والعشرون',
    'الثلاثون',
  ];

  /// من hafs_smart_v8.json: صفحة → جزء، صفحة → اسم السورة، صفحة → حزب (1–60)
  Map<int, int> _pageToJuz = {};
  Map<int, String> _pageToSuraName = {};
  Map<int, int> _pageToHizb = {};

  /// أول صفحة لكل جزء (1–30) وللفهرس: قائمة السور مع أول صفحة
  Map<int, int> _juzStartPage = {};
  List<({int no, String nameAr, int startPage})> _suraList = [];

  /// عدد الآيات لكل سورة (مشتق من الحقل aya_no)
  Map<int, int> _suraAyahCount = {};

  /// قائمة الآيات للبحث (من hafs_smart_v8.json): صفحة، سورة، رقم آية، اسم السورة، نص الآية (إملائي)
  List<({int page, int suraNo, int ayaNo, String suraNameAr, String text})>
      _ayahList = [];

  /// نص الآيات بالحركات كما في المصحف من ملف quran.json (chapter:verse -> text)
  Map<String, String> _quranTextBySuraAya = {};

  /// التفسير الميسّر: مفتاح سورة:آية → نص التفسير
  Map<String, String> _tafseerMouaserBySuraAya = {};

  /// تفسير السعدي: مفتاح سورة:آية → نص التفسير
  Map<String, String> _tafseerSaadiBySuraAya = {};

  /// بيانات الأذكار: قائمة من الأذكار
  List<
      ({
        int id,
        String title,
        String? titleAr,
        String? audioUrl,
        List<
            ({
              int id,
              String arabicText,
              String? languageArabicTranslatedText,
              String? translatedText,
              int repeat,
              String? audio
            })> texts
      })> _azkarList = [];

  int _extractAzkarGroupAudioId(String? audioUrl) {
    if (audioUrl == null) return -1;
    final match = RegExp(r'/(\d+)\.mp3$', caseSensitive: false)
        .firstMatch(audioUrl.trim());
    if (match == null) return -1;
    return int.tryParse(match.group(1) ?? '') ?? -1;
  }

  int _azkarPriorityByAudioId(int audioId) {
    // تقديم المجموعات المطلوبة اعتماداً على رقم ID في ملف hisn.json (من رابط Audio)
    // 002: أذكار الاستيقاظ، 028: أذكار الصباح/المساء، 029: أذكار النوم
    return switch (audioId) {
      2 => 0,
      28 => 1,
      29 => 2,
      _ => 99,
    };
  }

  String _normalizeAzkarTitleForOrder(String s) {
    var t = s.trim().toLowerCase();
    t = t.replaceAll(RegExp(r'[\u064B-\u065F\u0670]'), '');
    t = t.replaceAll(RegExp(r'[\u0610-\u061A\u0640]'), '');
    t = t
        .replaceAll('أ', 'ا')
        .replaceAll('إ', 'ا')
        .replaceAll('آ', 'ا')
        .replaceAll('ى', 'ي')
        .replaceAll('ة', 'ه');
    return t;
  }

  int _azkarPriorityByTitle(String title) {
    final t = _normalizeAzkarTitleForOrder(title);
    if (t.contains('الاستيقاظ')) return 0;
    if (t.contains('الصباح')) return 1;
    if (t.contains('المساء')) return 2;
    if (t.contains('النوم')) return 3;
    return 99;
  }

  List<
      ({
        int id,
        String title,
        String? titleAr,
        String? audioUrl,
        List<
            ({
              int id,
              String arabicText,
              String? languageArabicTranslatedText,
              String? translatedText,
              int repeat,
              String? audio
            })> texts
      })> _prioritizeAzkarGroups(
    List<
            ({
              int id,
              String title,
              String? titleAr,
              String? audioUrl,
              List<
                  ({
                    int id,
                    String arabicText,
                    String? languageArabicTranslatedText,
                    String? translatedText,
                    int repeat,
                    String? audio
                  })> texts
            })>
        groups,
  ) {
    final indexed = groups.asMap().entries.toList();
    indexed.sort((a, b) {
      final aTitle = a.value.titleAr ?? a.value.title;
      final bTitle = b.value.titleAr ?? b.value.title;
      final ptA = _azkarPriorityByTitle(aTitle);
      final ptB = _azkarPriorityByTitle(bTitle);
      if (ptA != ptB) return ptA.compareTo(ptB);

      final aId = _extractAzkarGroupAudioId(a.value.audioUrl);
      final bId = _extractAzkarGroupAudioId(b.value.audioUrl);
      final pa = _azkarPriorityByAudioId(aId);
      final pb = _azkarPriorityByAudioId(bId);
      if (pa != pb) return pa.compareTo(pb);
      return a.key.compareTo(b.key);
    });
    return indexed.map((e) => e.value).toList();
  }

  bool _loading = true;
  String? _error;

  late PageController _pageController;
  int _currentPageIndex = 0;
  bool _longScrollNeedsInitialJump = false;
  bool _standardNeedsInitialJump = false;
  bool _lightweightMushafDuringScroll = false;
  bool _mediumQualityMushafAfterScroll = false;
  Timer? _mushafRenderTierTimer;
  Timer? _inactivityTimer;
  Timer? _saveCurrentPageDebounce;
  Timer? _preloadDebounce;
  int? _pendingPreloadPage;
  int? _pendingCurrentPageSave;
  SharedPreferences? _sharedPrefsCache;
  static const Duration _inactivityDuration = Duration(minutes: 30);

  static const _keyCurrentPage = 'current_page';
  static const _keyMainBookmark = 'main_bookmark_page';
  static const _keySavedBookmarks = 'saved_bookmarks_json';
  static const _keyKhatmaBookmark = 'khatma_bookmark_page';
  static const _keyKhatmaPlan = 'khatma_plan_json';
  static const _keyHighlights = 'highlights_json';
  static const _keyAyahHighlights = 'ayah_highlights_json';
  static const _keyDisplayType = 'display_type';
  static const _keyQpcMode = 'qpc_mode';
  static const _keyMushafBackground = 'mushaf_background';
  static const _keyAutoScrollEnabled = 'auto_scroll_enabled';
  static const _keyAutoScrollSpeed = 'auto_scroll_speed';
  static const _keyHorizontalRotation = 'horizontal_rotation_enabled';
  static const _keyLongScrollRestoreBase = 'long_scroll_restore_base';
  static const _keyMenuFontScale = 'menu_font_scale';
  static const _keyTafsirFontScale = 'tafsir_font_scale';
  static const _keyArabicUiFontId = 'arabic_ui_font_id';
  static const _keyLongScrollSeamless = 'long_scroll_seamless_reading';
  static const _keyMenuDarkMode = 'menu_dark_mode';
  static const _keyFullMushafBackgroundWarmup = 'full_mushaf_background_warmup';

  /// ألوان الخلفية المتاحة لشكل المصحف
  static const Color _bgWhite = Colors.white;
  static const Color _bgBeige = Color.fromARGB(255, 255, 248, 235);
  static const Color _bgBlack = Color(0xFF0B0B0B);

  static const double _wideScreenThreshold = 700;

  int? _mainBookmarkPage;
  int? _khatmaBookmarkPage;
  List<({String name, int page, Color color})> _savedBookmarks = [];
  QpcMushafMode _qpcMode = QpcMushafMode.qpc4Black;
  Color _mushafBackgroundColor = _bgBeige;
  bool get _isBlackMushafBackground => _mushafBackgroundColor == _bgBlack;
  bool get _useWhiteTextOnDarkMushaf =>
      _isBlackMushafBackground &&
      (_qpcMode == QpcMushafMode.qpc1 || _qpcMode == QpcMushafMode.qpc4Black);
  Color get _mushafTopBarMainColor => _useWhiteTextOnDarkMushaf
      ? const Color(0xFFE7FFEF)
      : const Color(0xFF1B5E20);

  /// ألوان شريط الحالة/التنقل = لون خلفية المصحف (مناسب لمحاكي Pixel والوضع الافتراضي دون edge-to-edge عالمي).
  SystemUiOverlayStyle get _qpcSystemUiOverlayStyle {
    final lightBg = !_isBlackMushafBackground;
    final bg = _mushafBackgroundColor;
    return SystemUiOverlayStyle(
      statusBarColor: bg,
      statusBarIconBrightness: lightBg ? Brightness.dark : Brightness.light,
      statusBarBrightness: lightBg ? Brightness.light : Brightness.dark,
      systemNavigationBarColor: bg,
      systemNavigationBarIconBrightness:
          lightBg ? Brightness.dark : Brightness.light,
      systemNavigationBarContrastEnforced: false,
    );
  }

  Color? _lastAppliedMushafBgForSystemUi;

  void _applyMushafSystemUiOverlayIfNeeded() {
    if (!mounted || _loading || _error != null) return;
    if (_lastAppliedMushafBgForSystemUi == _mushafBackgroundColor) return;
    _lastAppliedMushafBgForSystemUi = _mushafBackgroundColor;
    SystemChrome.setSystemUIOverlayStyle(_qpcSystemUiOverlayStyle);
  }

  DisplayType _displayType = DisplayType.standard;

  /// للعودة عند إطفاء «التمرير الطويل» (صفحة واحدة / عرض أفقي / صفحتان فقط).
  DisplayType _longScrollRestoreBase = DisplayType.standard;

  bool _horizontalRotationEnabled = true;
  bool get _isHorizontallyRotatedReading =>
      _horizontalRotationEnabled &&
      (_displayType == DisplayType.horizontal ||
          _displayType == DisplayType.horizontalLongScroll);
  bool _autoScrollEnabled = false;
  double _autoScrollSpeed = 0.5;
  Ticker? _autoScrollTicker;
  DateTime? _autoScrollLastFrameTime;
  ScrollController? _longScrollController;
  ScrollController? _horizontalScrollController;
  ScrollController? _horizontalLongScrollController;

  /// استبدال الشريط بأيقونة صغيرة بعد 3 ث + 2 ث من الخمول.
  bool _longScrollBarMinimized = false;

  /// بعد 3 ث من ظهور الأيقونة تصبح شفافة قليلاً.
  bool _longScrollPeekDimmed = false;
  bool _horizontalLongScrollNeedsInitialJump = false;
  Timer? _longScrollBarIdleTimer;
  Timer? _longScrollBarMinimizeTimer;
  Timer? _longScrollPeekFadeTimer;

  /// إخفاء شريط السورة/الجزء ورقم الصفحة في التمرير الطويل لعرض متصل.
  bool _longScrollSeamlessReading = false;
  static const double _autoScrollUiMin = 0.10; // يظهر 10%
  static const double _autoScrollUiMax = 1.00; // يظهر 100%
  static const double _autoScrollActualMin = 0.02; // سرعة فعلية 2%
  static const double _autoScrollActualMax = 1.20; // سرعة فعلية 120%

  /// ظهور شريط مشغل التلاوة: يتحكم به المستخدم فقط (ضغطة للإظهار/الإخفاء)
  bool _playerOverlayVisible = true;

  /// المستخدم أخفى المشغل يدوياً فلا يُعاد إظهاره إلا بضغطه مرة أخرى
  bool _userDismissedPlayerOverlay = false;

  double _effectiveAutoScrollSpeed() {
    final t = ((_autoScrollSpeed - _autoScrollUiMin) /
            (_autoScrollUiMax - _autoScrollUiMin))
        .clamp(0.0, 1.0);
    return _autoScrollActualMin +
        (_autoScrollActualMax - _autoScrollActualMin) * t;
  }

  double _normalizeStoredAutoScrollSpeed(double? raw) {
    if (raw == null || raw.isNaN || !raw.isFinite) return 0.5;
    // توافق رجعي: الإصدارات السابقة كانت تسمح حتى 200% (2.0).
    if (raw > _autoScrollUiMax) {
      final legacyPercent = (raw * 100).clamp(10.0, 200.0);
      return (legacyPercent.clamp(10.0, 100.0) / 100.0).toDouble();
    }
    return raw.clamp(_autoScrollUiMin, _autoScrollUiMax).toDouble();
  }

  static const int _autoScrollPercentStepUi = 5;
  static const int _autoScrollPercentMinUi = 10;
  static const int _autoScrollPercentMaxUi = 100;

  int get _autoScrollSpeedStepIndex {
    final p = (_autoScrollSpeed * 100)
        .round()
        .clamp(_autoScrollPercentMinUi, _autoScrollPercentMaxUi);
    final idx =
        ((p - _autoScrollPercentMinUi) / _autoScrollPercentStepUi).round();
    return idx.clamp(0, 18);
  }

  int get _autoScrollSpeedPercentSnapped =>
      _autoScrollPercentMinUi +
      _autoScrollSpeedStepIndex * _autoScrollPercentStepUi;

  void _changeAutoScrollSpeedBySteps(int delta) {
    var idx = _autoScrollSpeedStepIndex + delta;
    idx = idx.clamp(0, 18);
    final p = _autoScrollPercentMinUi + idx * _autoScrollPercentStepUi;
    _expandLongScrollBarAndResetIdle();
    setState(() => _autoScrollSpeed = p / 100.0);
    _saveDisplayPrefs();
    if (_autoScrollEnabled) {
      _stopAutoScrollTicker();
      _startAutoScroll();
    }
  }

  static const double _longScrollBarIconRowH = 44;
  static const double _longScrollBarCaptionH = 26;
  static const double _longScrollBarIconSize = 26;
  static const double _longScrollBarBetweenGroups = 6;
  static const double _longScrollBarSpeedIconMin = 40;

  /// − و+ والنسبة للشريط السفلي: نفس ارتفاع عمودَي التشغيل و«صفحات متصلة».
  Widget _buildLongScrollBottomBarSpeedCluster(BuildContext context) {
    final atMin = _autoScrollSpeedStepIndex <= 0;
    final atMax = _autoScrollSpeedStepIndex >= 18;
    const green = Color(0xFF2E7D32);
    const percentFontSize = 17.0;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        SizedBox(
          height: _longScrollBarIconRowH,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              IconButton(
                tooltip: 'تقليل السرعة',
                icon: const Icon(Icons.remove_circle_outline,
                    size: _longScrollBarIconSize, color: green),
                onPressed:
                    atMin ? null : () => _changeAutoScrollSpeedBySteps(-1),
                padding: const EdgeInsets.all(2),
                visualDensity: VisualDensity.compact,
                constraints: const BoxConstraints(
                    minWidth: _longScrollBarSpeedIconMin,
                    minHeight: _longScrollBarIconRowH),
              ),
              SizedBox(
                width: 50,
                height: _longScrollBarIconRowH,
                child: Center(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      '${_toNormalDigits(_autoScrollSpeedPercentSnapped)}%',
                      textAlign: TextAlign.center,
                      style: _menuQuranStyle(
                        fontSize: percentFontSize,
                        color: const Color(0xFF1B5E20),
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
              ),
              IconButton(
                tooltip: 'زيادة السرعة',
                icon: const Icon(Icons.add_circle_outline,
                    size: _longScrollBarIconSize, color: green),
                onPressed:
                    atMax ? null : () => _changeAutoScrollSpeedBySteps(1),
                padding: const EdgeInsets.all(2),
                visualDensity: VisualDensity.compact,
                constraints: const BoxConstraints(
                    minWidth: _longScrollBarSpeedIconMin,
                    minHeight: _longScrollBarIconRowH),
              ),
            ],
          ),
        ),
        SizedBox(
          height: _longScrollBarCaptionH,
          width: 130,
          child: Align(
            alignment: Alignment.topCenter,
            child: Text(
              'السرعة',
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: _menuQuranStyle(
                fontSize: 11,
                color: const Color(0xFF1B5E20),
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// للتأكد من عدم إظهار المشغل تلقائياً عند كل notify — نُظهر فقط عند بدء التشغيل
  bool _wasPlayerActive = false;
  String? _lastSyncedAudioAyahKey;
  bool _ayahHighlightsTemporarilyDisabledByAudio = false;
  bool _ayahHighlightsVisibleBeforeAudio = true;
  bool get _isAyahHighlightingDisabledByAudio {
    final player = AyahAudioPlayer.instance;
    return player.isActive || player.state == AyahPlayerState.error;
  }

  /// التأشير: التأشيرات المحفوظة
  Map<int, List<({List<Offset> points, Color color})>> _highlights = {};
  List<AyahRangeHighlight> _ayahHighlights = [];
  bool _ayahHighlightsVisible = true;

  /// مضاعف حجم خط القوائم والنوافذ (ما عدا شريط صفحة المصحف).
  double _menuFontScale = 1.0;

  /// مضاعف حجم خط نص التفسير في التبويبات.
  double _tafsirFontScale = 1.0;

  /// معرّف خط النصوص العربية في القوائم والتفسير وعناصر الواجهة المرتبطة.
  String _arabicUiFontId = _kArabicUiFontIdUthmani;

  /// واجهة القوائم والنوافذ: داكن (أسود مخضر) أو فاتح.
  bool _menuDarkMode = false;

  /// عند التفعيل: الخمول يوسّع الكاش تدريجياً حتى كامل المصحف (مع الإيقاف باللمس).
  /// عند الإطفاء: الخمول يحمّل 7 صفحات فقط بعد الصفحة الحالية.
  bool _fullMushafBackgroundWarmup = false;

  QuranMenuPaletteData get _menuPal =>
      _menuDarkMode ? QuranMenuPaletteData.dark : QuranMenuPaletteData.light;

  String get _arabicUiFontFamily =>
      _arabicUiFontFamilyResolved(_arabicUiFontId);

  String _arabicUiFontSettingsSubtitle() {
    final i = _kArabicUiFontChoices.indexWhere((c) => c.id == _arabicUiFontId);
    if (i < 0) return 'معاينة ثم تطبيق';
    return 'الخط الحالي: خط ${_toNormalDigits(i + 1)}';
  }

  /// سطر ملخّص لبند «إعدادات الخط» في الإعدادات الرئيسية.
  String _fontSettingsEntrySubtitle() {
    final i = _kArabicUiFontChoices.indexWhere((c) => c.id == _arabicUiFontId);
    final lineNo = i >= 0 ? _toNormalDigits(i + 1) : '؟';
    return 'قوائم ${_ltrUiPercent((_menuFontScale * 100).round())} — خط $lineNo — تفسير ${_ltrUiPercent((_tafsirFontScale * 100).round())}';
  }

  /// نسبة مئوية داخل نص RTL: تضمين LTR + `%` اللاتينية حتى تُعرض 120 كاملةً لا 20.
  String _ltrUiPercent(int percent) {
    const lre = '\u202A';
    const pdf = '\u202C';
    return '$lre$percent%$pdf';
  }

  /// ملخص سطر «إعدادات المشغل» في الإعدادات الرئيسية.
  String _playerSettingsEntrySubtitle() {
    final player = AyahAudioPlayer.instance;
    final reciter =
        kAyahReciters.where((r) => r.id == player.currentReciterId).firstOrNull;
    final reciterName = reciter?.nameAr ?? 'غير محدد';
    final hl = player.showAyahHighlight ? 'تضليل مُفعل' : 'تضليل غير مُفعل';
    final mode = _playbackModeLabel(player.playbackMode);
    return '$reciterName — $hl — $mode';
  }

  /// تعليم أول تشغيل (قائمة / ضغط مطوّل / القارئ)
  final GlobalKey _introMushafAreaKey = GlobalKey();
  final GlobalKey _introReciterKey = GlobalKey();
  final GlobalKey _fihristCurrentSuraKey = GlobalKey();
  int _mushafIntroStep = MushafIntroPrefs.completedMarker;

  /// خطة الختمة: جلسات مقسمة على الأيام
  List<
      ({
        int dayIndex,
        int sessionIndex,
        int globalIndex,
        int startPage,
        int endPage,
        String timeOfDay,
        bool completed,
      })> _khatmaPlan = [];

  /// أرقام السور المدنية حسب الترتيب (الباقي مكي)
  static const Set<int> _madaniSuras = {
    2,
    3,
    4,
    5,
    8,
    9,
    13,
    22,
    24,
    33,
    47,
    48,
    49,
    55,
    57,
    58,
    59,
    60,
    61,
    62,
    63,
    64,
    65,
    66,
    76,
    98,
    99,
    110,
  };

  /// تحويل الأرقام العادية إلى أرقام عربية ٠١٢٣٤٥٦٧٨٩ (للنص القرآني/وضع التكبير فقط)
  String _toArabicDigits(int value) {
    const western = ['0', '1', '2', '3', '4', '5', '6', '7', '8', '9'];
    const eastern = ['٠', '١', '٢', '٣', '٤', '٥', '٦', '٧', '٨', '٩'];
    final s = value.toString();
    final buffer = StringBuffer();
    for (final ch in s.split('')) {
      final index = western.indexOf(ch);
      buffer.write(index == -1 ? ch : eastern[index]);
    }
    return buffer.toString();
  }

  /// أرقام عادية (واجهة التطبيق عدا القرآن النصي/المكبّر)
  String _toNormalDigits(int value) => value.toString();

  ScrollController get _longScrollControllerOrCreate {
    _longScrollController ??= ScrollController();
    return _longScrollController!;
  }

  ScrollController get _horizontalLongScrollControllerOrCreate {
    _horizontalLongScrollController ??= ScrollController();
    return _horizontalLongScrollController!;
  }

  void _ensureAutoScrollTicker() {
    _autoScrollTicker ??= createTicker(_handleAutoScrollTick);
  }

  @override
  void initState() {
    super.initState();
    _ensureAutoScrollTicker();
    WidgetsBinding.instance.addObserver(this);
    _pageController = PageController();
    AyahAudioPlayer.instance.addListener(_onAyahPlayerChanged);
    WakelockPlus.enable();
    _resetInactivityTimer();
    _loadFromJson();
  }

  void _onAyahPlayerChanged() {
    if (!mounted) return;
    final player = AyahAudioPlayer.instance;

    if (_mushafIntroStep == MushafIntroPrefs.stepWaitPlayback &&
        player.isActive &&
        !player.isAzkarSession) {
      setState(() {
        _mushafIntroStep = MushafIntroPrefs.stepReciter;
        if (!_playerOverlayVisible) _playerOverlayVisible = true;
        _userDismissedPlayerOverlay = false;
      });
      MushafIntroPrefs.setStep(MushafIntroPrefs.stepReciter);
    }

    final shouldDisableAyahHighlighting = _isAyahHighlightingDisabledByAudio;
    var needsUiRefresh = false;
    var needsStoreSync = false;

    if (shouldDisableAyahHighlighting) {
      if (!_ayahHighlightsTemporarilyDisabledByAudio) {
        _ayahHighlightsTemporarilyDisabledByAudio = true;
        _ayahHighlightsVisibleBeforeAudio = _ayahHighlightsVisible;
        needsUiRefresh = true;
      }
      if (_ayahHighlightsVisible) {
        _ayahHighlightsVisible = false;
        needsStoreSync = true;
        needsUiRefresh = true;
      }
    } else if (_ayahHighlightsTemporarilyDisabledByAudio) {
      _ayahHighlightsTemporarilyDisabledByAudio = false;
      if (_ayahHighlightsVisible != _ayahHighlightsVisibleBeforeAudio) {
        _ayahHighlightsVisible = _ayahHighlightsVisibleBeforeAudio;
        needsStoreSync = true;
      }
      needsUiRefresh = true;
    }

    if (player.isActive) {
      final justStarted = !_wasPlayerActive;
      _wasPlayerActive = true;
      if (justStarted && !_userDismissedPlayerOverlay) {
        _playerOverlayVisible = true;
        needsUiRefresh = true;
      }
      final s = player.currentSura;
      final a = player.currentAyah;
      final key = (s != null && a != null) ? '$s:$a' : null;
      if (key != null && key != _lastSyncedAudioAyahKey) {
        _lastSyncedAudioAyahKey = key;
        _ensurePlayingAyahVisible();
      }
      if (needsUiRefresh) setState(() {});
      if (needsStoreSync) _syncAyahHighlightsStore();
      return;
    }
    _lastSyncedAudioAyahKey = null;
    _wasPlayerActive = false;
    if (needsUiRefresh) setState(() {});
    if (needsStoreSync) _syncAyahHighlightsStore();
    // لا نعيد تعيين _userDismissedPlayerOverlay هنا — عند الانتقال التلقائي للآية التالية
    // يصبح isActive مؤقتاً false فنكون قد أعدنا التعيين خطأً. التعيين يحدث فقط عند
    // إغلاق المستخدم للمشغل (زر ×) في setState هناك.
  }

  void _ensurePlayingAyahVisible() {
    final player = AyahAudioPlayer.instance;
    final s = player.currentSura;
    final a = player.currentAyah;
    if (s == null || a == null) return;
    final targetAyah =
        _ayahList.where((e) => e.suraNo == s && e.ayaNo == a).firstOrNull;
    if (targetAyah == null) return;
    final targetIndex = (targetAyah.page - 1).clamp(0, totalPages - 1);
    final screenWidth = MediaQuery.sizeOf(context).width;
    final screenHeight = MediaQuery.sizeOf(context).height;
    final isWide = screenWidth >= _wideScreenThreshold;
    final effectiveType = (_displayType == DisplayType.twoPage && !isWide)
        ? DisplayType.standard
        : _displayType;

    if (effectiveType == DisplayType.standard ||
        effectiveType == DisplayType.horizontal ||
        effectiveType == DisplayType.twoPage) {
      if (!_pageController.hasClients) return;
      final targetPage = effectiveType == DisplayType.twoPage
          ? (targetIndex ~/ 2).clamp(0, 301)
          : targetIndex;
      final current =
          (_pageController.page ?? _currentPageIndex.toDouble()).round();
      if (current != targetPage) {
        _pageController.animateToPage(
          targetPage,
          duration: const Duration(milliseconds: 280),
          curve: Curves.easeOutCubic,
        );
      }
      return;
    }

    if (effectiveType == DisplayType.longScroll) {
      final ctrl = _longScrollController;
      if (ctrl == null || !ctrl.hasClients) return;
      final itemExtent = _verticalLongScrollItemExtent(screenHeight);
      final target =
          (targetIndex * itemExtent).clamp(0.0, ctrl.position.maxScrollExtent);
      if ((ctrl.offset - target).abs() > itemExtent * 0.35) {
        ctrl.animateTo(
          target,
          duration: const Duration(milliseconds: 280),
          curve: Curves.easeOutCubic,
        );
      }
      return;
    }

    if (effectiveType == DisplayType.horizontalLongScroll) {
      final ctrl = _horizontalLongScrollController;
      if (ctrl == null || !ctrl.hasClients) return;
      final itemExtent =
          _horizontalLongScrollItemExtent(screenWidth, screenHeight);
      final target =
          (targetIndex * itemExtent).clamp(0.0, ctrl.position.maxScrollExtent);
      if ((ctrl.offset - target).abs() > itemExtent * 0.35) {
        ctrl.animateTo(
          target,
          duration: const Duration(milliseconds: 280),
          curve: Curves.easeOutCubic,
        );
      }
    }
  }

  ({int suraNo, int ayaNo})? _currentRecitationStart() {
    if (_ayahList.isEmpty) return null;
    final pageNumber = _currentPageIndex + 1;
    final onPage =
        _ayahList.where((a) => a.page == pageNumber).toList(growable: false);
    if (onPage.isEmpty) return null;
    onPage.sort((a, b) {
      if (a.suraNo != b.suraNo) return a.suraNo.compareTo(b.suraNo);
      return a.ayaNo.compareTo(b.ayaNo);
    });
    final first = onPage.first;
    return (suraNo: first.suraNo, ayaNo: first.ayaNo);
  }

  Future<void> _openRecitationScreen(BuildContext menuContext) async {
    final start = _currentRecitationStart();
    if (start == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('تعذر تحديد موضع التسميع الحالي')),
      );
      return;
    }
    _dismissAllMenuOverlays(menuContext);
    await RecitationScreen.open(
      context,
      initialSurahNumber: start.suraNo,
      initialAyahNumber: start.ayaNo,
    );
  }

  void _handleMushafTap() {
    if (AyahAudioPlayer.instance.isActive) {
      setState(() {
        _playerOverlayVisible = !_playerOverlayVisible;
        if (_playerOverlayVisible) {
          _userDismissedPlayerOverlay = false;
        } else {
          _userDismissedPlayerOverlay = true;
        }
      });
    } else {
      unawaited(_showOptionsSheet(context, _currentPageIndex));
    }
  }

  double _horizontalLongItemExtent(double screenWidth, double screenHeight) {
    const verticalMarginFraction = 0.02;
    const visibleQuarterFraction = 4.0;
    const refWidth = 360.0;
    const baseScale = 0.65;
    final widthScale = (screenWidth / refWidth).clamp(0.6, 1.2);
    final windowHeight = screenHeight * (1 - 2 * verticalMarginFraction);
    return (windowHeight / _mushafAspectRatio) *
        visibleQuarterFraction *
        baseScale *
        widthScale;
  }

  /// شريط السورة/الجزء + صف رقم الصفحة في التمرير الطويل — نفس المساحة المخصصة لهما
  /// في الوضع العادي؛ يُطرح من ارتفاع/عرض عنصر القائمة في «صفحات متصلة» حتى لا يتوسع
  /// `slotHeight` في المُصَفّف فيزيد تباعد الأسطر، ولا يبقى فراغ بين الصفحات.
  double _longScrollChromeHeight() {
    const topBarApprox = 30.0;
    return topBarApprox + kQpcPageNumberBottomGap + kQpcPageNumberRowHeight;
  }

  double _verticalLongScrollItemExtentFor(bool seamless, double screenHeight) {
    if (!seamless) return screenHeight;
    final e =
        (screenHeight - _longScrollChromeHeight()).clamp(120.0, screenHeight);
    // بدون هذا العامل: هامش سفلي لصفحة + علوي للتي تليها = فراغ أكبر من تباعد السطور.
    final frac = mushafVerticalMarginFractionSum(isCompact: false);
    return (e * (1.0 - frac)).clamp(100.0, screenHeight);
  }

  double _verticalLongScrollItemExtent(double screenHeight) =>
      _verticalLongScrollItemExtentFor(
          _longScrollSeamlessReading, screenHeight);

  double _horizontalLongScrollItemExtentFor(
      bool seamless, double screenWidth, double screenHeight) {
    final base = _horizontalLongItemExtent(screenWidth, screenHeight);
    if (!seamless) return base;
    final e = (base - _longScrollChromeHeight()).clamp(48.0, base);
    final frac = mushafVerticalMarginFractionSum(isCompact: true);
    return (e * (1.0 - frac)).clamp(40.0, base);
  }

  double _horizontalLongScrollItemExtent(
          double screenWidth, double screenHeight) =>
      _horizontalLongScrollItemExtentFor(
          _longScrollSeamlessReading, screenWidth, screenHeight);

  void _resyncLongScrollAfterSeamlessToggle({
    required bool wasSeamless,
    required double screenWidth,
    required double screenHeight,
  }) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final nowSeamless = _longScrollSeamlessReading;
      if (_displayType == DisplayType.longScroll) {
        final ctrl = _longScrollController;
        if (ctrl == null || !ctrl.hasClients) return;
        final oldEx =
            _verticalLongScrollItemExtentFor(wasSeamless, screenHeight);
        final newEx =
            _verticalLongScrollItemExtentFor(nowSeamless, screenHeight);
        if ((oldEx - newEx).abs() < 0.5) return;
        final idx = (ctrl.offset / oldEx).round().clamp(0, totalPages - 1);
        ctrl.jumpTo((idx * newEx).clamp(0.0, ctrl.position.maxScrollExtent));
      } else if (_displayType == DisplayType.horizontalLongScroll) {
        final ctrl = _horizontalLongScrollController;
        if (ctrl == null || !ctrl.hasClients) return;
        final oldEx = _horizontalLongScrollItemExtentFor(
            wasSeamless, screenWidth, screenHeight);
        final newEx = _horizontalLongScrollItemExtentFor(
            nowSeamless, screenWidth, screenHeight);
        if ((oldEx - newEx).abs() < 0.5) return;
        final idx = (ctrl.offset / oldEx).round().clamp(0, totalPages - 1);
        ctrl.jumpTo((idx * newEx).clamp(0.0, ctrl.position.maxScrollExtent));
      }
    });
  }

  void _navigateToPage(int oneBasedPage, {bool animate = true}) {
    final targetIndex = (oneBasedPage - 1).clamp(0, totalPages - 1);
    final screenWidth = MediaQuery.sizeOf(context).width;
    final screenHeight = MediaQuery.sizeOf(context).height;
    final isWide = screenWidth >= _wideScreenThreshold;
    final effectiveType = (_displayType == DisplayType.twoPage && !isWide)
        ? DisplayType.standard
        : _displayType;

    if (_currentPageIndex != targetIndex) {
      setState(() => _currentPageIndex = targetIndex);
    }
    PageBackgroundLoader.instance.setCurrentPage(targetIndex + 1);
    _saveCurrentPage(targetIndex);
    _syncMushafRamExpanderContext();
    final preloadCenter = targetIndex + 1;
    if (_qpcMode == QpcMushafMode.qpc1) {
      preloadNearbyQpc1Pages(preloadCenter);
    } else {
      preloadNearbyPages(preloadCenter);
    }

    if (effectiveType == DisplayType.standard ||
        effectiveType == DisplayType.horizontal ||
        effectiveType == DisplayType.twoPage) {
      final targetPage = effectiveType == DisplayType.twoPage
          ? (targetIndex ~/ 2).clamp(0, 301)
          : targetIndex;
      if (!_pageController.hasClients) {
        _standardNeedsInitialJump = true;
        return;
      }
      if (animate) {
        _pageController.animateToPage(
          targetPage,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeInOut,
        );
      } else {
        _pageController.jumpToPage(targetPage);
      }
      return;
    }

    if (effectiveType == DisplayType.longScroll) {
      final ctrl = _longScrollControllerOrCreate;
      if (!ctrl.hasClients) {
        _longScrollNeedsInitialJump = true;
        return;
      }
      final itemExtent = _verticalLongScrollItemExtent(screenHeight);
      final target =
          (targetIndex * itemExtent).clamp(0.0, ctrl.position.maxScrollExtent);
      if (animate) {
        ctrl.animateTo(
          target,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeInOut,
        );
      } else {
        ctrl.jumpTo(target);
      }
      return;
    }

    if (effectiveType == DisplayType.horizontalLongScroll) {
      final ctrl = _horizontalLongScrollControllerOrCreate;
      if (!ctrl.hasClients) {
        _horizontalLongScrollNeedsInitialJump = true;
        return;
      }
      final itemExtent =
          _horizontalLongScrollItemExtent(screenWidth, screenHeight);
      final target =
          (targetIndex * itemExtent).clamp(0.0, ctrl.position.maxScrollExtent);
      if (animate) {
        ctrl.animateTo(
          target,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeInOut,
        );
      } else {
        ctrl.jumpTo(target);
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.resumed) {
      _lastAppliedMushafBgForSystemUi = null;
      _applyMushafSystemUiOverlayIfNeeded();
    }
  }

  @override
  void dispose() {
    final pendingPage = _pendingCurrentPageSave;
    _saveCurrentPageDebounce?.cancel();
    _preloadDebounce?.cancel();
    _mushafRenderTierTimer?.cancel();
    if (pendingPage != null) {
      unawaited(_saveCurrentPageNow(pendingPage));
    }
    WidgetsBinding.instance.removeObserver(this);
    AyahAudioPlayer.instance.removeListener(_onAyahPlayerChanged);
    _longScrollController?.dispose();
    _horizontalScrollController?.dispose();
    _horizontalLongScrollController?.dispose();
    _autoScrollTicker?.dispose();
    _autoScrollTicker = null;
    _longScrollBarIdleTimer?.cancel();
    _longScrollBarMinimizeTimer?.cancel();
    _longScrollPeekFadeTimer?.cancel();
    _inactivityTimer?.cancel();
    WakelockPlus.disable();
    MushafRamIdleExpander.instance.disposeOnLeaveMushaf();
    _pageController.dispose();
    super.dispose();
  }

  String _mushafRamCacheModeKey() =>
      _qpcMode == QpcMushafMode.qpc1 ? 'qpc1' : 'qpc4';

  void _syncMushafRamExpanderContext() {
    MushafRamIdleExpander.instance.onPageOrModeContext(
      pageOneBased: _currentPageIndex + 1,
      cacheMode: _mushafRamCacheModeKey(),
      fullBackgroundWarmupEnabled: _fullMushafBackgroundWarmup,
    );
  }

  void _schedulePreloadAroundPage(int pageOneBased) {
    _pendingPreloadPage = pageOneBased.clamp(1, totalPages);
    _preloadDebounce?.cancel();
    _preloadDebounce = Timer(const Duration(milliseconds: 120), () {
      final target = _pendingPreloadPage;
      _pendingPreloadPage = null;
      if (target == null) return;
      if (_qpcMode == QpcMushafMode.qpc1) {
        preloadNearbyQpc1Pages(target);
      } else {
        preloadNearbyPages(target);
      }
    });
  }

  void _enterScrollRenderLite() {
    _mushafRenderTierTimer?.cancel();
    var changed = false;
    if (!_lightweightMushafDuringScroll) {
      _lightweightMushafDuringScroll = true;
      changed = true;
    }
    if (_mediumQualityMushafAfterScroll) {
      _mediumQualityMushafAfterScroll = false;
      changed = true;
    }
    if (changed) setState(() {});
  }

  void _settleScrollRenderTier() {
    _mushafRenderTierTimer?.cancel();
    var changed = false;
    if (_lightweightMushafDuringScroll) {
      _lightweightMushafDuringScroll = false;
      changed = true;
    }
    if (!_mediumQualityMushafAfterScroll) {
      _mediumQualityMushafAfterScroll = true;
      changed = true;
    }
    if (changed) setState(() {});
    _mushafRenderTierTimer = Timer(const Duration(milliseconds: 180), () {
      if (!mounted) return;
      if (_mediumQualityMushafAfterScroll) {
        setState(() => _mediumQualityMushafAfterScroll = false);
      }
    });
  }

  Future<SharedPreferences> _prefs() async {
    final cached = _sharedPrefsCache;
    if (cached != null) return cached;
    final prefs = await SharedPreferences.getInstance();
    _sharedPrefsCache = prefs;
    return prefs;
  }

  Future<void> _loadPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    final page = prefs.getInt(_keyCurrentPage);
    if (page != null && page >= 0 && page < totalPages) {
      _currentPageIndex = page;
      // القفز إلى الصفحة يتم في post-frame داخل build حسب وضع العرض (ورقة/ورقتين)
    }
    final main = prefs.getInt(_keyMainBookmark);
    if (main != null && main >= 1 && main <= totalPages) {
      _mainBookmarkPage = main;
    }
    final khatma = prefs.getInt(_keyKhatmaBookmark);
    if (khatma != null && khatma >= 1 && khatma <= totalPages) {
      _khatmaBookmarkPage = khatma;
    }
    final json = prefs.getString(_keySavedBookmarks);
    if (json != null) {
      try {
        final list = jsonDecode(json) as List;
        _savedBookmarks = list
            .map((e) {
              final m = (e as Map);
              return (
                name: m['name'] as String? ?? '',
                page: (m['page'] as num?)?.toInt() ?? 1,
                color: m['color'] == null
                    ? const Color(0xFF2E7D32)
                    : Color((m['color'] as num).toInt()),
              );
            })
            .where((e) => e.page >= 1 && e.page <= totalPages)
            .toList();
      } catch (_) {}
    }
    final planJson = prefs.getString(_keyKhatmaPlan);
    if (planJson != null) {
      try {
        final list = jsonDecode(planJson) as List;
        _khatmaPlan = list
            .map((e) => (
                  dayIndex: (e as Map)['dayIndex'] as int? ?? 0,
                  sessionIndex: e['sessionIndex'] as int? ?? 0,
                  globalIndex: e['globalIndex'] as int? ?? 0,
                  startPage: e['startPage'] as int? ?? 1,
                  endPage: e['endPage'] as int? ?? 1,
                  timeOfDay: e['timeOfDay'] as String? ?? '',
                  completed: e['completed'] as bool? ?? false,
                ))
            .toList();
        // تحديث الجدول بناءً على علامة الختمة المحفوظة
        if (_khatmaPlan.isNotEmpty && _khatmaBookmarkPage != null) {
          _recalculateKhatmaPlan();
        }
      } catch (_) {}
    }
    final highlightsJson = prefs.getString(_keyHighlights);
    if (highlightsJson != null) {
      try {
        final map = jsonDecode(highlightsJson) as Map;
        _highlights = {};
        for (final entry in map.entries) {
          final page = int.parse(entry.key);
          final list = (entry.value as List).map((e) {
            final pathData = e['path'] as List;
            final points = pathData
                .map((p) => Offset(
                      (p['x'] as num).toDouble(),
                      (p['y'] as num).toDouble(),
                    ))
                .toList();
            return (
              points: points,
              color: Color((e['color'] as num).toInt()),
            );
          }).toList();
          _highlights[page] = list;
        }
      } catch (_) {}
    }
    final ayahHighlightsJson = prefs.getString(_keyAyahHighlights);
    if (ayahHighlightsJson != null) {
      try {
        final list = jsonDecode(ayahHighlightsJson) as List;
        _ayahHighlights = list.map((e) {
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
        }).toList(growable: true);
      } catch (_) {
        _ayahHighlights = [];
      }
    }
    _ayahHighlightsVisible =
        prefs.getBool(kAyahHighlightsVisiblePrefsKey) ?? true;
    _syncAyahHighlightsStore();
    final displayTypeStr = prefs.getString(_keyDisplayType);
    if (displayTypeStr != null) {
      switch (displayTypeStr) {
        case 'longScroll':
          _displayType = DisplayType.longScroll;
          _longScrollNeedsInitialJump = true;
          _longScrollRestoreBase =
              _deserializeLongScrollRestoreBase(prefs) ?? DisplayType.standard;
          break;
        case 'horizontalLongScroll':
          _displayType = DisplayType.horizontalLongScroll;
          _horizontalLongScrollNeedsInitialJump = true;
          _longScrollRestoreBase = _deserializeLongScrollRestoreBase(prefs) ??
              DisplayType.horizontal;
          break;
        case 'horizontal':
          _displayType = DisplayType.horizontal;
          _standardNeedsInitialJump = true;
          break;
        case 'twoPage':
          _displayType = DisplayType.twoPage;
          _standardNeedsInitialJump = true;
          break;
        case 'standard':
        default:
          _displayType = DisplayType.standard;
          _standardNeedsInitialJump = true;
      }
    }
    if (_displayType != DisplayType.longScroll &&
        _displayType != DisplayType.horizontalLongScroll) {
      _standardNeedsInitialJump = true;
    }
    final qpcModeStr = prefs.getString(_keyQpcMode);
    if (qpcModeStr != null) {
      switch (qpcModeStr) {
        case 'qpc1':
          _qpcMode = QpcMushafMode.qpc1;
          break;
        case 'qpc4Black':
          _qpcMode = QpcMushafMode.qpc4Black;
          break;
        case 'qpc4':
        default:
          _qpcMode = QpcMushafMode.qpc4;
      }
    }
    final bgValue = prefs.getInt(_keyMushafBackground);
    if (bgValue != null) {
      if (bgValue == 1) {
        _mushafBackgroundColor = _bgBeige;
      } else if (bgValue == 2) {
        // قيمة قديمة للخلفية الخضراء/التراثية: نوحدها على البيج.
        _mushafBackgroundColor = _bgBeige;
      } else if (bgValue == 3) {
        _mushafBackgroundColor = _bgBlack;
      } else {
        _mushafBackgroundColor = _bgWhite;
      }
    }
    _horizontalRotationEnabled = prefs.getBool(_keyHorizontalRotation) ?? true;
    _autoScrollEnabled = prefs.getBool(_keyAutoScrollEnabled) ?? false;
    _autoScrollSpeed =
        _normalizeStoredAutoScrollSpeed(prefs.getDouble(_keyAutoScrollSpeed));
    _longScrollSeamlessReading = prefs.getBool(_keyLongScrollSeamless) ?? false;
    _menuDarkMode = prefs.getBool(_keyMenuDarkMode) ?? false;
    _fullMushafBackgroundWarmup =
        prefs.getBool(_keyFullMushafBackgroundWarmup) ?? false;
    _menuFontScale =
        (prefs.getDouble(_keyMenuFontScale) ?? 1.0).clamp(0.85, 1.4);
    _tafsirFontScale =
        (prefs.getDouble(_keyTafsirFontScale) ?? 1.0).clamp(0.85, 1.4);
    final storedFontId = prefs.getString(_keyArabicUiFontId);
    _arabicUiFontId =
        (storedFontId != null && _arabicUiFontChoiceForId(storedFontId) != null)
            ? storedFontId
            : _kArabicUiFontIdUthmani;
    await MushafIntroPrefs.migrateLegacyUsers();
    if (await MushafIntroPrefs.isCompleted()) {
      _mushafIntroStep = MushafIntroPrefs.completedMarker;
    } else {
      _mushafIntroStep = await MushafIntroPrefs.loadStep();
    }
    setState(() {});
    _startBackgroundLoader();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _syncMushafRamExpanderContext();
    });
  }

  void _startBackgroundLoader() {
    PageBackgroundLoader.instance.setCurrentPage(_currentPageIndex + 1);
    PageBackgroundLoader.instance.start();
  }

  Future<void> _saveDisplayPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    final typeStr = switch (_displayType) {
      DisplayType.standard => 'standard',
      DisplayType.horizontal => 'horizontal',
      DisplayType.twoPage => 'twoPage',
      DisplayType.longScroll => 'longScroll',
      DisplayType.horizontalLongScroll => 'horizontalLongScroll',
    };
    await prefs.setString(_keyDisplayType, typeStr);
    if (_displayType == DisplayType.longScroll ||
        _displayType == DisplayType.horizontalLongScroll) {
      await prefs.setString(
        _keyLongScrollRestoreBase,
        _serializeLongScrollRestoreBase(_longScrollRestoreBase),
      );
    } else {
      await prefs.remove(_keyLongScrollRestoreBase);
    }
    await prefs.setBool(_keyHorizontalRotation, _horizontalRotationEnabled);
    await prefs.setBool(_keyAutoScrollEnabled, _autoScrollEnabled);
    await prefs.setDouble(_keyAutoScrollSpeed, _autoScrollSpeed);
    await prefs.setBool(_keyLongScrollSeamless, _longScrollSeamlessReading);
  }

  static DisplayType? _deserializeLongScrollRestoreBase(
      SharedPreferences prefs) {
    return switch (prefs.getString(_keyLongScrollRestoreBase)) {
      'standard' => DisplayType.standard,
      'horizontal' => DisplayType.horizontal,
      'twoPage' => DisplayType.twoPage,
      _ => null,
    };
  }

  static String _serializeLongScrollRestoreBase(DisplayType base) {
    return switch (base) {
      DisplayType.standard => 'standard',
      DisplayType.horizontal => 'horizontal',
      DisplayType.twoPage => 'twoPage',
      DisplayType.longScroll => 'standard',
      DisplayType.horizontalLongScroll => 'horizontal',
    };
  }

  /// تغيير صفحة واحدة / أفقي / صفحتان مع الإبقاء على التمرير الطويل إن كان مفعّلاً.
  void _applyBaseDisplayModeSelection(DisplayType type) {
    assert(type != DisplayType.longScroll &&
        type != DisplayType.horizontalLongScroll);
    if (_displayType != DisplayType.longScroll &&
        _displayType != DisplayType.horizontalLongScroll) {
      _displayType = type;
      _standardNeedsInitialJump = true;
      return;
    }
    _longScrollRestoreBase = type;
    if (type == DisplayType.standard) {
      _displayType = DisplayType.longScroll;
      _longScrollBarMinimized = false;
      _longScrollPeekDimmed = false;
      _longScrollNeedsInitialJump = true;
    } else {
      _displayType = DisplayType.horizontalLongScroll;
      _longScrollBarMinimized = false;
      _longScrollPeekDimmed = false;
      _horizontalLongScrollNeedsInitialJump = true;
    }
  }

  /// تمرير طويل واحد: من صفحة واحدة → عمودي، من أفقي/صفحتان → أفقي؛ الضغطة الثانية تعيد الأساس.
  void _applyUnifiedLongScrollToggle() {
    if (_displayType == DisplayType.longScroll ||
        _displayType == DisplayType.horizontalLongScroll) {
      final back = _longScrollRestoreBase;
      _displayType = (back == DisplayType.longScroll ||
              back == DisplayType.horizontalLongScroll)
          ? DisplayType.standard
          : back;
      _standardNeedsInitialJump = true;
    } else {
      _longScrollRestoreBase = _displayType;
      if (_displayType == DisplayType.standard) {
        _displayType = DisplayType.longScroll;
        _longScrollBarMinimized = false;
        _longScrollPeekDimmed = false;
        _longScrollNeedsInitialJump = true;
      } else {
        _displayType = DisplayType.horizontalLongScroll;
        _longScrollBarMinimized = false;
        _longScrollPeekDimmed = false;
        _horizontalLongScrollNeedsInitialJump = true;
      }
    }
  }

  Future<void> _saveMushafStylePrefs() async {
    final prefs = await SharedPreferences.getInstance();
    final modeStr = switch (_qpcMode) {
      QpcMushafMode.qpc1 => 'qpc1',
      QpcMushafMode.qpc4 => 'qpc4',
      QpcMushafMode.qpc4Black => 'qpc4Black',
    };
    await prefs.setString(_keyQpcMode, modeStr);
    final bgValue = _mushafBackgroundColor == _bgBeige
        ? 1
        : _mushafBackgroundColor == _bgBlack
            ? 3
            : 0;
    await prefs.setInt(_keyMushafBackground, bgValue);
  }

  Future<void> _saveCurrentPage(int index) async {
    _pendingCurrentPageSave = index;
    _saveCurrentPageDebounce?.cancel();
    _saveCurrentPageDebounce = Timer(const Duration(milliseconds: 450), () {
      final target = _pendingCurrentPageSave;
      _pendingCurrentPageSave = null;
      if (target == null) return;
      unawaited(_saveCurrentPageNow(target));
    });
  }

  Future<void> _saveCurrentPageNow(int index) async {
    final prefs = await _prefs();
    await prefs.setInt(_keyCurrentPage, index);
  }

  Future<void> _saveBookmarks() async {
    final prefs = await SharedPreferences.getInstance();
    if (_mainBookmarkPage != null) {
      await prefs.setInt(_keyMainBookmark, _mainBookmarkPage!);
    } else {
      await prefs.remove(_keyMainBookmark);
    }
    if (_khatmaBookmarkPage != null) {
      await prefs.setInt(_keyKhatmaBookmark, _khatmaBookmarkPage!);
    } else {
      await prefs.remove(_keyKhatmaBookmark);
    }
    await prefs.setString(
        _keySavedBookmarks,
        jsonEncode(_savedBookmarks
            .map(
                (e) => {'name': e.name, 'page': e.page, 'color': e.color.value})
            .toList()));
    await prefs.setString(
        _keyKhatmaPlan,
        jsonEncode(_khatmaPlan
            .map((e) => {
                  'dayIndex': e.dayIndex,
                  'sessionIndex': e.sessionIndex,
                  'globalIndex': e.globalIndex,
                  'startPage': e.startPage,
                  'endPage': e.endPage,
                  'timeOfDay': e.timeOfDay,
                  'completed': e.completed,
                })
            .toList()));
    final highlightsMap = <String, List<Map<String, dynamic>>>{};
    for (final entry in _highlights.entries) {
      highlightsMap[entry.key.toString()] = entry.value
          .map((h) => {
                'path': h.points.map((p) => {'x': p.dx, 'y': p.dy}).toList(),
                'color': h.color.value,
              })
          .toList();
    }
    await prefs.setString(_keyHighlights, jsonEncode(highlightsMap));
    await prefs.setString(
      _keyAyahHighlights,
      jsonEncode(
        _ayahHighlights
            .map(
              (h) => {
                'sura': h.sura,
                'fromAyah': h.fromAyah,
                'toAyah': h.toAyah,
                'color': h.color.toARGB32(),
              },
            )
            .toList(),
      ),
    );
  }

  void _syncAyahHighlightsStore() {
    AyahHighlightStore.instance
        .setRanges(_ayahHighlightsVisible ? _ayahHighlights : const []);
  }

  /// حساب تقسيم الختمة: تقسيم الصفحات على الجلسات مع معالجة الكسور
  void _calculateKhatmaPlan({
    required int startPage,
    required int days,
    required int sessionsPerDay,
    required List<String> sessionTimes,
  }) {
    _khatmaPlan.clear();
    // دائماً نبدأ من الصفحة الأولى
    final actualStartPage = 1;
    final totalPagesToRead = totalPages - actualStartPage + 1;
    final totalSessions = days * sessionsPerDay;
    final pagesPerSession = totalPagesToRead / totalSessions;

    int currentPage = actualStartPage;
    int globalIndex = 0;
    bool useCeil = true; // نبدأ بـ ceil ثم نتبادل

    for (int day = 0; day < days; day++) {
      for (int session = 0; session < sessionsPerDay; session++) {
        final pagesInThisSession =
            useCeil ? pagesPerSession.ceil() : pagesPerSession.floor();
        final endPage =
            (currentPage + pagesInThisSession - 1).clamp(1, totalPages);
        final sessionStartPage = currentPage.clamp(1, totalPages);

        _khatmaPlan.add((
          dayIndex: day,
          sessionIndex: session,
          globalIndex: globalIndex++,
          startPage: sessionStartPage,
          endPage: endPage,
          timeOfDay: session < sessionTimes.length
              ? sessionTimes[session]
              : '${session + 1}',
          completed: false,
        ));

        currentPage = endPage + 1;
        if (currentPage > totalPages) break;
        useCeil = !useCeil; // التناوب بين ceil و floor
      }
      if (currentPage > totalPages) break;
    }
  }

  /// تحديث حالة الجلسات المكتملة بناءً على علامة الختمة
  void _updateCompletedSessionsFromBookmark() {
    if (_khatmaPlan.isEmpty || _khatmaBookmarkPage == null) return;

    final bookmarkPage = _khatmaBookmarkPage!;

    // تحديث جميع الجلسات التي تم إكمالها (نهاية الجلسة قبل علامة الختمة)
    for (int i = 0; i < _khatmaPlan.length; i++) {
      final session = _khatmaPlan[i];
      // إذا كانت نهاية الجلسة قبل علامة الختمة، فهي مكتملة
      if (session.endPage < bookmarkPage && !session.completed) {
        _khatmaPlan[i] = (
          dayIndex: session.dayIndex,
          sessionIndex: session.sessionIndex,
          globalIndex: session.globalIndex,
          startPage: session.startPage,
          endPage: session.endPage,
          timeOfDay: session.timeOfDay,
          completed: true,
        );
      }
      // إذا كانت الجلسة تبدأ بعد علامة الختمة، فهي غير مكتملة
      else if (session.startPage >= bookmarkPage && session.completed) {
        _khatmaPlan[i] = (
          dayIndex: session.dayIndex,
          sessionIndex: session.sessionIndex,
          globalIndex: session.globalIndex,
          startPage: session.startPage,
          endPage: session.endPage,
          timeOfDay: session.timeOfDay,
          completed: false,
        );
      }
    }
  }

  /// إعادة حساب الجدول بناءً على علامة الختمة الحالية
  void _recalculateKhatmaPlan() {
    if (_khatmaPlan.isEmpty || _khatmaBookmarkPage == null) return;

    final bookmarkPage = _khatmaBookmarkPage!;

    // تحديث حالة الجلسات المكتملة أولاً
    _updateCompletedSessionsFromBookmark();

    // الحصول على معلومات الجلسات الأصلية
    final sessionsPerDay = _khatmaPlan.where((s) => s.dayIndex == 0).length;
    if (sessionsPerDay == 0) return;

    // فصل الجلسات المكتملة عن المتبقية
    final remainingSessions = _khatmaPlan
        .where((s) => !s.completed && s.startPage >= bookmarkPage)
        .toList();

    if (remainingSessions.isEmpty) return;

    // حساب عدد الأيام المتبقية
    final remainingDays =
        remainingSessions.map((s) => s.dayIndex).toSet().length;

    if (remainingDays == 0) return;

    // حساب الصفحات المتبقية
    final totalPagesToRead = totalPages - bookmarkPage + 1;
    final totalRemainingSessions = remainingDays * sessionsPerDay;
    final pagesPerSession = totalPagesToRead / totalRemainingSessions;

    int currentPage = bookmarkPage;
    bool useCeil = true;

    // تحديث الجلسات المتبقية فقط
    for (var oldSession in remainingSessions) {
      final pagesInThisSession =
          useCeil ? pagesPerSession.ceil() : pagesPerSession.floor();
      final endPage =
          (currentPage + pagesInThisSession - 1).clamp(1, totalPages);
      final actualStartPage = currentPage.clamp(1, totalPages);

      final idx = _khatmaPlan
          .indexWhere((s) => s.globalIndex == oldSession.globalIndex);
      if (idx != -1) {
        _khatmaPlan[idx] = (
          dayIndex: oldSession.dayIndex,
          sessionIndex: oldSession.sessionIndex,
          globalIndex: oldSession.globalIndex,
          startPage: actualStartPage,
          endPage: endPage,
          timeOfDay: oldSession.timeOfDay,
          completed: false,
        );
      }

      currentPage = endPage + 1;
      if (currentPage > totalPages) break;
      useCeil = !useCeil;
    }
  }

  void _resetInactivityTimer() {
    _inactivityTimer?.cancel();
    WakelockPlus.enable();
    _inactivityTimer = Timer(_inactivityDuration, () {
      WakelockPlus.disable();
    });
  }

  TextStyle _quranStyle(
      {required double fontSize,
      required Color color,
      FontWeight fontWeight = FontWeight.w600}) {
    // خط قرآني من ملف محلي (يجب وضعه في assets/fonts/quran_uthmani.ttf)
    return TextStyle(
      fontFamily: _arabicUiFontFamily,
      fontSize: fontSize,
      color: color,
      fontWeight: fontWeight,
    );
  }

  TextStyle _menuQuranStyle({
    required double fontSize,
    required Color color,
    FontWeight fontWeight = FontWeight.w600,
  }) {
    final scaled = (fontSize * _menuFontScale).clamp(10.0, 34.0);
    return _quranStyle(fontSize: scaled, color: color, fontWeight: fontWeight);
  }

  InputDecoration _menuDialogInputDecoration(
    QuranMenuPaletteData pal, {
    String? labelText,
    String? hintText,
  }) {
    final baseBorder = OutlineInputBorder(
      borderRadius: BorderRadius.circular(8),
      borderSide: BorderSide(color: pal.divider),
    );
    return InputDecoration(
      filled: true,
      fillColor: pal.searchFieldFill,
      labelText: labelText,
      hintText: hintText,
      labelStyle: _menuQuranStyle(fontSize: 14, color: pal.subtitle),
      hintStyle: _menuQuranStyle(
        fontSize: 13,
        color: pal.subtitle.withValues(alpha: 0.72),
      ),
      border: baseBorder,
      enabledBorder: baseBorder,
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: pal.accent, width: 2),
      ),
    );
  }

  void _dismissAllMenuOverlays(BuildContext context) {
    Navigator.of(context).popUntil((route) => route.isFirst);
  }

  /// تدوير 90° كما في [_showOptionsSheet] حتى تخرج الفروع بنفس اتجاه القائمة.
  Widget _wrapMainMenuFamilyOverlay(BuildContext sheetContext, Widget child) {
    return QuranMenuPalette(
      data: _menuPal,
      child: wrapQuranMenuFamilySheetOverlay(
        sheetContext,
        child,
        horizontallyRotatedReading: _isHorizontallyRotatedReading,
      ),
    );
  }

  /// نافذة البحث فقط: في **الأفقي** تدوير فعلي 90° لتظهر كالوضع العمودي.
  Widget _wrapSearchDialogOverlay(BuildContext sheetContext, Widget child) {
    return QuranMenuPalette(
      data: _menuPal,
      child: wrapQuranMenuFamilySheetOverlay(
        sheetContext,
        child,
        horizontallyRotatedReading:
            MediaQuery.orientationOf(sheetContext) == Orientation.landscape,
      ),
    );
  }

  double get _tafsirBodyFontSize => (19.0 * _tafsirFontScale).clamp(12.0, 32.0);

  Future<void> _saveUiFontPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_keyMenuFontScale, _menuFontScale);
    await prefs.setDouble(_keyTafsirFontScale, _tafsirFontScale);
    await prefs.setString(_keyArabicUiFontId, _arabicUiFontId);
  }

  Future<void> _saveMenuDarkModePref() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyMenuDarkMode, _menuDarkMode);
  }

  Future<void> _saveFullMushafBackgroundWarmupPref() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(
      _keyFullMushafBackgroundWarmup,
      _fullMushafBackgroundWarmup,
    );
  }

  static const double _fontScaleSliderMin = 0.85;
  static const double _fontScaleSliderMax = 1.4;

  /// منزلق حجم الخط: اتجاه LTR + عكس القيمة حتى تكون الأصغر يمينًا؛
  /// المسار الأخضر من أصغر قيمة (يمين) حتى موضع الإبهام.
  Widget _buildFontScaleRtlSlider(
    BuildContext context, {
    required double scale,
    required ValueChanged<double> onChanged,
  }) {
    final inverted = (_fontScaleSliderMax + _fontScaleSliderMin - scale)
        .clamp(_fontScaleSliderMin, _fontScaleSliderMax);
    final base = SliderTheme.of(context);
    return Directionality(
      textDirection: TextDirection.ltr,
      child: SliderTheme(
        data: base.copyWith(
          trackShape: _FontScaleTrailingActiveTrackShape(),
          activeTrackColor: const Color(0xFF2E7D32),
          inactiveTrackColor: Colors.grey.shade300,
          thumbColor: const Color(0xFF2E7D32),
          overlayColor: WidgetStateColor.resolveWith((_) => Colors.transparent),
          trackHeight: 4,
        ),
        child: Slider(
          value: inverted,
          min: _fontScaleSliderMin,
          max: _fontScaleSliderMax,
          divisions: 11,
          label: _ltrUiPercent((scale * 100).round()),
          onChanged: (v) {
            onChanged(
              (_fontScaleSliderMax + _fontScaleSliderMin - v)
                  .clamp(_fontScaleSliderMin, _fontScaleSliderMax),
            );
          },
        ),
      ),
    );
  }

  /// تجاهل اختلاف الهمزة (أ إ آ ء) عند البحث — توحيدها إلى ا
  static String _normalizeForSearch(String s) {
    // إزالة الحركات (التشكيل)
    String normalized = s.replaceAll(RegExp(r'[\u064B-\u065F\u0670]'), '');
    // إزالة علامات التشكيل الأخرى
    normalized = normalized.replaceAll(RegExp(r'[\u0610-\u061A\u0640]'), '');
    // توحيد الهمزات
    normalized = normalized
        .replaceAll('أ', 'ا')
        .replaceAll('إ', 'ا')
        .replaceAll('آ', 'ا')
        .replaceAll('ء', 'ا')
        .replaceAll('ؤ', 'و')
        .replaceAll('ئ', 'ي')
        .replaceAll('ى', 'ي')
        .replaceAll('ة', 'ه');
    return normalized.toLowerCase();
  }

  Future<void> _loadFromJson() async {
    try {
      final raw = await rootBundle.loadString('assets/data/hafs_smart_v8.json');
      final list = jsonDecode(raw) as List;
      final Map<int, int> pageToJuz = {};
      final Map<int, String> pageToSuraName = {};
      for (final e in list) {
        final m = Map<String, dynamic>.from(e as Map);
        final page = (m['page'] as num?)?.toInt() ?? 0;
        final jozz = (m['jozz'] as num?)?.toInt() ?? 0;
        final suraAr = m['sura_name_ar'] as String?;
        if (page >= 1 && page <= totalPages && jozz >= 1 && jozz <= 30) {
          pageToJuz.putIfAbsent(page, () => jozz);
          if (suraAr != null && suraAr.isNotEmpty) {
            pageToSuraName.putIfAbsent(page, () => suraAr);
          }
        }
      }
      // الحزب 1–60 من الملف: كل جزء = حزبان، نوزع الصفحات حسب ترتيب الصفحة داخل الجزء
      final Map<int, List<int>> juzToPages = {};
      for (int p = 1; p <= totalPages; p++) {
        final j = pageToJuz[p] ?? 1;
        juzToPages.putIfAbsent(j, () => []).add(p);
      }
      for (final list in juzToPages.values) {
        list.sort();
      }
      final Map<int, int> pageToHizb = {};
      final Map<int, int> juzStartPage = {};
      for (int juz = 1; juz <= 30; juz++) {
        final pages = juzToPages[juz] ?? [];
        pages.sort();
        if (pages.isNotEmpty) juzStartPage[juz] = pages.first;
        final half = (pages.length / 2).ceil();
        for (int i = 0; i < pages.length; i++) {
          final hizb = (juz - 1) * 2 + (i < half ? 1 : 2);
          pageToHizb[pages[i]] = hizb.clamp(1, 60);
        }
      }
      // الفهرس: قائمة السور مع أول صفحة من الملف
      final Map<int, int> suraToMinPage = {};
      final Map<int, String> suraToNameAr = {};
      for (final e in list) {
        final m = Map<String, dynamic>.from(e as Map);
        final page = (m['page'] as num?)?.toInt() ?? 0;
        final suraNo = (m['sura_no'] as num?)?.toInt() ?? 0;
        final suraAr = m['sura_name_ar'] as String?;
        if (page >= 1 && page <= totalPages && suraNo >= 1 && suraNo <= 114) {
          if (!suraToMinPage.containsKey(suraNo) ||
              page < suraToMinPage[suraNo]!) {
            suraToMinPage[suraNo] = page;
            if (suraAr != null) suraToNameAr[suraNo] = suraAr;
          }
        }
      }
      final suraList = <({int no, String nameAr, int startPage})>[];
      for (int no = 1; no <= 114; no++) {
        final start = suraToMinPage[no];
        if (start != null)
          suraList
              .add((no: no, nameAr: suraToNameAr[no] ?? '', startPage: start));
      }
      // قائمة الآيات للبحث في النص (aya_text_emlaey)
      final ayahList = <({
        int page,
        int suraNo,
        int ayaNo,
        String suraNameAr,
        String text
      })>[];
      for (final e in list) {
        final m = Map<String, dynamic>.from(e as Map);
        final page = (m['page'] as num?)?.toInt() ?? 0;
        final suraNo = (m['sura_no'] as num?)?.toInt() ?? 0;
        final ayaNo = (m['aya_no'] as num?)?.toInt() ?? 0;
        final suraAr = m['sura_name_ar'] as String? ?? '';
        final emlaey =
            m['aya_text_emlaey'] as String? ?? m['aya_text'] as String? ?? '';
        if (page >= 1 && page <= totalPages && emlaey.isNotEmpty) {
          ayahList.add((
            page: page,
            suraNo: suraNo,
            ayaNo: ayaNo,
            suraNameAr: suraAr,
            text: emlaey
          ));
          if (suraNo > 0 && ayaNo > 0) {
            final prev = _suraAyahCount[suraNo] ?? 0;
            if (ayaNo > prev) _suraAyahCount[suraNo] = ayaNo;
          }
        }
      }
      // تحميل نص القرآن بالحركات من ملف quran.json
      final quranTextBySuraAya = <String, String>{};
      try {
        final qRaw = await rootBundle.loadString('assets/data/quran.json');
        final qJson = jsonDecode(qRaw) as Map<String, dynamic>;
        qJson.forEach((_, verses) {
          final listVerses = verses as List;
          for (final v in listVerses) {
            final vm = Map<String, dynamic>.from(v as Map);
            final chapter = (vm['chapter'] as num?)?.toInt() ?? 0;
            final verse = (vm['verse'] as num?)?.toInt() ?? 0;
            final text = vm['text'] as String? ?? '';
            if (chapter > 0 && verse > 0 && text.isNotEmpty) {
              quranTextBySuraAya['$chapter:$verse'] = text;
            }
          }
        });
      } catch (_) {
        // لو فشل تحميل ملف quran.json نستمر بدون تعطيل التطبيق
      }

      // تحميل التفسير الميسّر من ملف tafseerMouaser_v03.txt (مفصول بعلامة TAB)
      final tafseerMouaserBySuraAya = <String, String>{};
      try {
        final tRaw = await rootBundle
            .loadString('assets/tafseer/tafseerMouaser_v03.txt');
        final lines = const LineSplitter().convert(tRaw);
        if (lines.length > 1) {
          // السطر الأول ترويسة
          for (int i = 1; i < lines.length; i++) {
            final line = lines[i];
            if (line.trim().isEmpty) continue;
            final parts = line.split('\t');
            // التحقق من وجود عدد كافٍ من الأعمدة (12 عمود على الأقل)
            if (parts.length < 12) continue;
            final suraNo = int.tryParse(parts[3].trim()) ?? 0;
            final ayaNo = int.tryParse(parts[8].trim()) ?? 0;
            if (suraNo <= 0 || ayaNo <= 0) continue;
            var tafseer = parts.length > 11 ? parts[11].trim() : '';
            if (tafseer.isEmpty) continue;
            // إزالة رقم الآية داخل [] في بداية التفسير إن وجد
            if (tafseer.startsWith('[')) {
              final idx = tafseer.indexOf(']');
              if (idx != -1 && idx + 1 < tafseer.length) {
                tafseer = tafseer.substring(idx + 1).trim();
              }
            }
            // إزالة وسوم HTML البسيطة
            tafseer = tafseer.replaceAll(RegExp(r'<[^>]+>'), '');
            if (tafseer.isNotEmpty) {
              tafseerMouaserBySuraAya['$suraNo:$ayaNo'] = tafseer;
            }
          }
        }
      } catch (e) {
        // لو فشل تحميل ملف التفسير نستمر بدون تعطيل التطبيق
        debugPrint('خطأ في تحميل التفسير: $e');
      }

      // تحميل تفسير السعدي من ملف ar.saddi.json
      final tafseerSaadiBySuraAya = <String, String>{};
      try {
        final sRaw =
            await rootBundle.loadString('assets/tafseer/ar.saddi.json');
        final sJson = jsonDecode(sRaw) as Map<String, dynamic>;
        final all = (sJson['tafsir'] as List).cast<List>();
        for (int s = 0; s < all.length; s++) {
          final suraIndex = s + 1; // السور 1..114
          final suraList = all[s].cast<String>();
          for (int a = 0; a < suraList.length; a++) {
            final ayaIndex = a + 1;
            var text = suraList[a].trim();
            if (text.isEmpty) continue;
            text = text.replaceAll(RegExp(r'<[^>]+>'), '');
            if (text.isEmpty) continue;
            tafseerSaadiBySuraAya['$suraIndex:$ayaIndex'] = text;
          }
        }
      } catch (e) {
        debugPrint('خطأ في تحميل تفسير السعدي (JSON): $e');
      }

      // تحميل الأذكار من ملف hisn.json
      final azkarList = <({
        int id,
        String title,
        String? titleAr,
        String? audioUrl,
        List<
            ({
              int id,
              String arabicText,
              String? languageArabicTranslatedText,
              String? translatedText,
              int repeat,
              String? audio
            })> texts
      })>[];
      try {
        final hisnRaw = await rootBundle.loadString('assets/azkar/hisn.json');
        final hisnJson = jsonDecode(hisnRaw);
        if (hisnJson is Map<String, dynamic>) {
          int groupId = 1;
          for (final entry in hisnJson.entries) {
            final titleAr = entry.key.trim();
            final group = entry.value;
            if (group is! Map) continue;
            final groupMap = Map<String, dynamic>.from(group);
            final audioUrl = groupMap['Audio'] as String?;
            final adhkarRaw = groupMap['Adhkar'];
            if (adhkarRaw is! List) continue;

            final texts = <({
              int id,
              String arabicText,
              String? languageArabicTranslatedText,
              String? translatedText,
              int repeat,
              String? audio
            })>[];

            int textId = 1;
            for (final item in adhkarRaw) {
              if (item is! Map) continue;
              final textMap = Map<String, dynamic>.from(item);
              final arabicText = (textMap['Text'] as String? ?? '').trim();
              if (arabicText.isEmpty) continue;
              final reference = (textMap['Reference'] as String?)?.trim();
              final countRaw = textMap['Count'];
              final repeat = countRaw is num
                  ? countRaw.toInt()
                  : int.tryParse((countRaw ?? '1').toString()) ?? 1;
              texts.add((
                id: textId++,
                arabicText: arabicText,
                languageArabicTranslatedText:
                    (reference != null && reference.isNotEmpty)
                        ? reference
                        : null,
                translatedText: null,
                repeat: repeat > 0 ? repeat : 1,
                audio: null
              ));
            }

            if (texts.isEmpty) continue;
            azkarList.add((
              id: groupId++,
              title: titleAr,
              titleAr: titleAr,
              audioUrl: audioUrl,
              texts: texts
            ));
          }
        }
      } catch (e) {
        debugPrint('خطأ في تحميل الأذكار: $e');
      }
      final prioritizedAzkarList = _prioritizeAzkarGroups(azkarList);

      setState(() {
        _pageToJuz = pageToJuz;
        _pageToSuraName = pageToSuraName;
        _pageToHizb = pageToHizb;
        _juzStartPage = juzStartPage;
        _suraList = suraList;
        _ayahList = ayahList;
        _quranTextBySuraAya = quranTextBySuraAya;
        _tafseerMouaserBySuraAya = tafseerMouaserBySuraAya;
        _tafseerSaadiBySuraAya = tafseerSaadiBySuraAya;
        _azkarList = prioritizedAzkarList;
        _loading = false;
        _error = null;
      });
      await _loadPrefs();
    } catch (e) {
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  int _juzFromPage(int page) {
    return _pageToJuz[page] ?? 1;
  }

  String _suraNameFromNo(int sura) {
    final s = _suraList.where((x) => x.no == sura).firstOrNull;
    return s?.nameAr ?? 'سورة $sura';
  }

  /// فهرس عنصر السورة في `_suraList` التي يقرؤها المستخدم على الصفحة (١…٦٠٤).
  ///
  /// إن وُجدت بيانات آيات للصفحة: نأخذ **أول سورة تظهر على الصفحة** (ترتيب
  /// سورة ثم آية) حتى لا نختار آخر سورة تبدأ في نفس الصفحة بينما القارئ
  /// ما زال في آيات السورة السابقة.
  int _suraListIndexForPage(int page1Based) {
    if (_suraList.isEmpty) return 0;
    if (_ayahList.isNotEmpty) {
      final onPage =
          _ayahList.where((a) => a.page == page1Based).toList(growable: false);
      if (onPage.isNotEmpty) {
        onPage.sort((a, b) {
          if (a.suraNo != b.suraNo) return a.suraNo.compareTo(b.suraNo);
          return a.ayaNo.compareTo(b.ayaNo);
        });
        final suraNo = onPage.first.suraNo;
        final i = _suraList.indexWhere((s) => s.no == suraNo);
        if (i >= 0) return i;
      }
    }
    var idx = 0;
    for (var i = 0; i < _suraList.length; i++) {
      if (_suraList[i].startPage <= page1Based) {
        idx = i;
      } else {
        break;
      }
    }
    return idx;
  }

  /// قائمة الضغط المطول على آية: نافذة عائمة عصريّة
  void _showAyahLongPressMenu(
    BuildContext context,
    int sura,
    int ayah,
    String ayahText,
    VoidCallback onClearSelection,
  ) {
    final suraName = _suraNameFromNo(sura);
    unawaited(showAyahLongPressMenuDialog(
      parentContext: context,
      sura: sura,
      ayah: ayah,
      ayahText: ayahText,
      onClearSelection: onClearSelection,
      suraName: suraName,
      arabicUiFontFamily: _arabicUiFontFamily,
      menuQuranStyle: _menuQuranStyle,
      toNormalDigits: _toNormalDigits,
      rotateMenuForLandscape: _isHorizontallyRotatedReading,
      isHighlightingDisabledByAudio: _isAyahHighlightingDisabledByAudio,
      onTafseer: () => _showTafseerForAyah(
            context,
            sura,
            ayah,
            suraName,
            onClearSelection,
          ),
      onHighlight: () => _showAyahHighlightSheet(
            context,
            sura: sura,
            ayah: ayah,
          ),
    ));
  }

  Future<void> _showAyahHighlightSheet(
    BuildContext context, {
    int? sura,
    int? ayah,
    AyahRangeHighlight? editing,
  }) async {
    assert(
      editing != null || (sura != null && ayah != null),
      'تحرير أو تمرير سورة وآية',
    );
    if (_isAyahHighlightingDisabledByAudio) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'التضليل متوقف أثناء الاستماع',
            style: _menuQuranStyle(fontSize: 14, color: Colors.white),
          ),
          backgroundColor: const Color(0xFF2E7D32),
        ),
      );
      return;
    }
    final int initSura = editing?.sura ?? sura!;
    final int initFrom = editing?.fromAyah ?? ayah!;
    final int initTo = editing?.toAyah ?? ayah!;

    await showAyahHighlightRangeSheet(
      context,
      initialSura: initSura,
      initialFromAyah: initFrom,
      initialToAyah: initTo,
      editing: editing,
      suraList: _suraList,
      suraAyahCount: _suraAyahCount,
      menuDarkMode: _menuDarkMode,
      arabicUiFontFamily: _arabicUiFontFamily,
      menuQuranStyle: _menuQuranStyle,
      toNormalDigits: _toNormalDigits,
    );
    if (!mounted) return;
    final next = List<AyahRangeHighlight>.from(await readAyahHighlightRanges());
    setState(() {
      _ayahHighlights
        ..clear()
        ..addAll(next);
    });
    _syncAyahHighlightsStore();
  }

  /// فتح تبويبة اختيار الآيات من القائمة الرئيسية — التحديد التلقائي: السورة والآيات في الصفحة الحالية
  void _showTafseerFromMainMenu(BuildContext context) {
    final pageNumber = _currentPageIndex + 1;
    final list = _ayahList.where((a) => a.page == pageNumber).toList();
    if (list.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
          'لا توجد آيات في هذه الصفحة',
          style: _menuQuranStyle(fontSize: 14, color: Colors.white),
        ),
        backgroundColor: const Color(0xFF2E7D32),
      ));
      return;
    }
    list.sort((a, b) {
      if (a.suraNo != b.suraNo) return a.suraNo.compareTo(b.suraNo);
      return a.ayaNo.compareTo(b.ayaNo);
    });
    final firstSura = list.first.suraNo;
    final ayatOfFirstSura =
        list.where((a) => a.suraNo == firstSura).map((a) => a.ayaNo).toList();
    ayatOfFirstSura.sort();
    final from = ayatOfFirstSura.first;
    final to = (ayatOfFirstSura.last - from + 1 > 30)
        ? from + 29
        : ayatOfFirstSura.last;

    MushafRamIdleExpander.instance.beginBlockingUi();
    showQuranMenuSidePanel<void>(
      context: context,
      horizontallyRotatedReading: _isHorizontallyRotatedReading,
      backgroundColor: _menuPal.surface,
      builder: (ctx) => _wrapMainMenuFamilyOverlay(
        ctx,
        Directionality(
          textDirection: TextDirection.rtl,
          child: _TafseerRangePickerSheet(
            sura: firstSura,
            fromAyah: from,
            toAyah: to,
            suraList: _suraList,
            suraAyahCount: _suraAyahCount,
            toNormalDigits: _toNormalDigits,
            quranStyle: _menuQuranStyle,
            menuPalette: _menuPal,
            maxAyat: 30,
            onDismissAll: () => _dismissAllMenuOverlays(ctx),
            onChanged: (s, f, t) {},
            onConfirm: (s, f, t) {
              _dismissAllMenuOverlays(ctx);
              _showTafseerForAyahWithRange(context, s, f, t);
            },
          ),
        ),
      ),
    ).whenComplete(MushafRamIdleExpander.instance.endBlockingUi);
  }

  /// فتح نافذة التفسير بنطاق آيات محدد
  void _showTafseerForAyahWithRange(
    BuildContext context,
    int sura,
    int fromAyah,
    int toAyah,
  ) {
    showDialog<void>(
      context: context,
      barrierColor: Colors.black26,
      builder: (ctx) => _TafseerAyahDialog(
        initialSura: sura,
        initialAyah: fromAyah,
        initialFromAyah: fromAyah,
        initialToAyah: toAyah,
        suraList: _suraList,
        suraAyahCount: _suraAyahCount,
        tafseerSaadiBySuraAya: _tafseerSaadiBySuraAya,
        tafseerMouaserBySuraAya: _tafseerMouaserBySuraAya,
        toNormalDigits: _toNormalDigits,
        quranStyle: _menuQuranStyle,
        arabicUiFontFamily: _arabicUiFontFamily,
        tafsirBodyFontSize: _tafsirBodyFontSize,
        rotateOverlaysLikeMainMenu: _isHorizontallyRotatedReading,
        menuPalette: _menuPal,
        onClearSelection: () {},
      ),
    );
  }

  /// تفسير آية واحدة بتبويبات (السعدي / الميسّر) مع إمكانية اختيار نطاق آيات
  void _showTafseerForAyah(
    BuildContext context,
    int sura,
    int ayah,
    String suraName,
    VoidCallback onClearSelection,
  ) {
    showDialog<void>(
      context: context,
      barrierColor: Colors.black26,
      builder: (ctx) => _TafseerAyahDialog(
        initialSura: sura,
        initialAyah: ayah,
        suraList: _suraList,
        suraAyahCount: _suraAyahCount,
        tafseerSaadiBySuraAya: _tafseerSaadiBySuraAya,
        tafseerMouaserBySuraAya: _tafseerMouaserBySuraAya,
        toNormalDigits: _toNormalDigits,
        quranStyle: _menuQuranStyle,
        arabicUiFontFamily: _arabicUiFontFamily,
        tafsirBodyFontSize: _tafsirBodyFontSize,
        rotateOverlaysLikeMainMenu: _isHorizontallyRotatedReading,
        menuPalette: _menuPal,
        onClearSelection: onClearSelection,
      ),
    ).then((_) => onClearSelection());
  }

  /// عرض الأذكار (قائمة مع إمكانية الرجوع من تفاصيل مجموعة دون إغلاق القائمة)
  Future<void> _showAzkarDialog(BuildContext context) async {
    if (_azkarList.isEmpty) {
      try {
        final hisnRaw = await rootBundle.loadString('assets/azkar/hisn.json');
        final hisnJson = jsonDecode(hisnRaw);
        final parsed = <({
          int id,
          String title,
          String? titleAr,
          String? audioUrl,
          List<
              ({
                int id,
                String arabicText,
                String? languageArabicTranslatedText,
                String? translatedText,
                int repeat,
                String? audio
              })> texts
        })>[];
        if (hisnJson is Map<String, dynamic>) {
          int groupId = 1;
          for (final entry in hisnJson.entries) {
            final titleAr = entry.key.trim();
            final group = entry.value;
            if (group is! Map) continue;
            final groupMap = Map<String, dynamic>.from(group);
            final audioUrl = groupMap['Audio'] as String?;
            final adhkarRaw = groupMap['Adhkar'];
            if (adhkarRaw is! List) continue;

            final texts = <({
              int id,
              String arabicText,
              String? languageArabicTranslatedText,
              String? translatedText,
              int repeat,
              String? audio
            })>[];

            int textId = 1;
            for (final item in adhkarRaw) {
              if (item is! Map) continue;
              final textMap = Map<String, dynamic>.from(item);
              final arabicText = (textMap['Text'] as String? ?? '').trim();
              if (arabicText.isEmpty) continue;
              final reference = (textMap['Reference'] as String?)?.trim();
              final countRaw = textMap['Count'];
              final repeat = countRaw is num
                  ? countRaw.toInt()
                  : int.tryParse((countRaw ?? '1').toString()) ?? 1;
              texts.add((
                id: textId++,
                arabicText: arabicText,
                languageArabicTranslatedText:
                    (reference != null && reference.isNotEmpty)
                        ? reference
                        : null,
                translatedText: null,
                repeat: repeat > 0 ? repeat : 1,
                audio: null
              ));
            }
            if (texts.isEmpty) continue;
            parsed.add((
              id: groupId++,
              title: titleAr,
              titleAr: titleAr,
              audioUrl: audioUrl,
              texts: texts
            ));
          }
        }
        final prioritizedParsed = _prioritizeAzkarGroups(parsed);
        if (prioritizedParsed.isNotEmpty && mounted) {
          setState(() {
            _azkarList = prioritizedParsed;
          });
        }
      } catch (e) {
        debugPrint('خطأ في التحميل الفوري للأذكار: $e');
      }
    }

    final ordered = _prioritizeAzkarGroups(_azkarList);
    if (mounted) {
      setState(() {
        _azkarList = ordered;
      });
    }
    _showAzkarDialogByList(
      context,
      azkarList: ordered,
      sheetTitle: 'أذكار وأدعية',
      emptyMessage: 'لا توجد أذكار متاحة',
    );
  }

  void _showAzkarDialogByList(
    BuildContext context, {
    required List<
            ({
              int id,
              String title,
              String? titleAr,
              String? audioUrl,
              List<
                  ({
                    int id,
                    String arabicText,
                    String? languageArabicTranslatedText,
                    String? translatedText,
                    int repeat,
                    String? audio
                  })> texts
            })>
        azkarList,
    required String sheetTitle,
    required String emptyMessage,
  }) {
    if (azkarList.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
          emptyMessage,
          style: _menuQuranStyle(fontSize: 14, color: Colors.white),
        ),
        backgroundColor: const Color(0xFF2E7D32),
      ));
      return;
    }

    showQuranMenuSidePanel<void>(
      context: context,
      horizontallyRotatedReading: _isHorizontallyRotatedReading,
      isScrollControlled: true,
      backgroundColor: _menuPal.surface,
      builder: (ctx) => _wrapMainMenuFamilyOverlay(
        ctx,
        Directionality(
          textDirection: TextDirection.rtl,
          child: SafeArea(
            child: SizedBox(
              height: MediaQuery.of(ctx).size.height * 0.9,
              child: _AzkarSheetContent(
                azkarList: azkarList,
                sheetTitle: sheetTitle,
                toNormalDigits: _toNormalDigits,
                quranStyle: _menuQuranStyle,
                arabicRegex: _arabicRegex,
                onBack: () => Navigator.pop(ctx),
                onDismissAll: () => _dismissAllMenuOverlays(ctx),
              ),
            ),
          ),
        ),
      ),
    );
  }

  static final RegExp _arabicRegex = RegExp(r'[\u0600-\u06FF]');

  String _suraName(int page) {
    return _pageToSuraName[page] ?? '—';
  }

  String _suraNamesForPage(int page) {
    if (_ayahList.isNotEmpty) {
      final names = <String>[];
      int? lastSura;
      for (final a in _ayahList) {
        if (a.page != page) continue;
        if (lastSura != a.suraNo) {
          lastSura = a.suraNo;
          final n = a.suraNameAr.trim();
          if (n.isNotEmpty) names.add(n);
        }
      }
      if (names.isNotEmpty) {
        // بعض الصفحات تحتوي أكثر من سورة (أحياناً 3) — نفصل بينها بفاصلة.
        return names.join('، ');
      }
    }
    return _suraName(page);
  }

  String _juzHizbLabelForPage(int page) {
    final j = _juzFromPage(page).clamp(1, 30);
    final hizb = _pageToHizb[page] ?? 1;
    return 'الجزء ${_juzNames[j - 1]} - الحزب: ${_toNormalDigits(hizb)}';
  }

  /// شريط علوي لكل صفحة: يُستخدم في QPC V1 و V4 و V4 أسود، يُسحَب مع الصفحة.
  Widget _buildQpcTopBarForPage(int pageNumber) {
    // في QPC V1 و QPC V4 العادي و QPC V4 أسود: شريط نصي بسيط بدون أي إطار SVG.
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: 12,
        vertical: kQpcTopBarVerticalPadding,
      ),
      child: Row(
        children: [
          // يمين: الجزء + الحزب
          Expanded(
            child: Align(
              alignment: Alignment.centerRight,
              child: Text(
                _juzHizbLabelForPage(pageNumber),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: _quranStyle(fontSize: 16, color: _mushafTopBarMainColor),
              ),
            ),
          ),
          const SizedBox(width: 8),
          // يمين اسم السورة: علامات (أيقونة كتاب)
          _buildBookmarkIndicators(pageNumber),
          const SizedBox(width: 10),
          // يسار: اسم/أسماء السور (قد تكون 3 سور في الصفحة)
          Expanded(
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                _suraNamesForPage(pageNumber),
                textAlign: TextAlign.left,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: _quranStyle(fontSize: 16, color: _mushafTopBarMainColor)
                    .copyWith(fontFamily: _surahNameFontFamily),
              ),
            ),
          ),
        ],
      ),
    );
  }

  static const Color _mainBookmarkColor = Color(0xFF2E7D32);
  static const Color _khatmaBookmarkColor = Color(0xFF1E88E5);

  Widget _bookmarkIcon(Color c) => Icon(
        Icons.bookmark,
        size: 20,
        color: c,
      );

  Widget _buildBookmarkIndicators(int page) {
    final icons = <Widget>[];
    if (_mainBookmarkPage == page) icons.add(_bookmarkIcon(_mainBookmarkColor));
    if (_khatmaBookmarkPage == page)
      icons.add(_bookmarkIcon(_khatmaBookmarkColor));
    for (final b in _savedBookmarks) {
      if (b.page == page) {
        icons.add(_bookmarkIcon(b.color));
        if (icons.length >= 3) break;
      }
    }
    if (icons.isEmpty) return const SizedBox(width: 20);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (int i = 0; i < icons.length; i++) ...[
          if (i != 0) const SizedBox(width: 4),
          icons[i],
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        backgroundColor: Colors.white,
        body: Center(
          child: CircularProgressIndicator(color: Color(0xFF2E7D32)),
        ),
      );
    }

    if (_error != null) {
      return Scaffold(
        backgroundColor: Colors.white,
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              _error!,
              style: const TextStyle(color: Colors.black87),
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }

    WidgetsBinding.instance
        .addPostFrameCallback((_) => _applyMushafSystemUiOverlayIfNeeded());

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: _qpcSystemUiOverlayStyle,
      child: ColoredBox(
        color: _mushafBackgroundColor,
        child: Scaffold(
          backgroundColor: Colors.transparent,
          resizeToAvoidBottomInset: false,
          body: _buildQpcBody(),
        ),
      ),
    );
  }

  Widget _buildQpcBody() {
    final screenWidth = MediaQuery.sizeOf(context).width;
    final screenHeight = MediaQuery.sizeOf(context).height;
    final isWide = screenWidth >= _wideScreenThreshold;

    // عرض صفحتان: يظهر فقط على الشاشات العريضة، وإلا نرجع للافتراضي
    // لا يوجد تحويل تلقائي حسب تدوير الهاتف — العرض حسب اختيار المستخدم فقط
    final effectiveType = (_displayType == DisplayType.twoPage && !isWide)
        ? DisplayType.standard
        : _displayType;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (effectiveType == DisplayType.longScroll) {
        if (_longScrollNeedsInitialJump) {
          _longScrollNeedsInitialJump = false;
          final ctrl = _longScrollControllerOrCreate;
          if (ctrl.hasClients) {
            final itemExtent = _verticalLongScrollItemExtent(screenHeight);
            final target = (_currentPageIndex * itemExtent)
                .clamp(0.0, ctrl.position.maxScrollExtent);
            ctrl.jumpTo(target);
          }
        }
      } else if (effectiveType == DisplayType.horizontalLongScroll) {
        if (_horizontalLongScrollNeedsInitialJump) {
          _horizontalLongScrollNeedsInitialJump = false;
          final ctrl = _horizontalLongScrollControllerOrCreate;
          if (ctrl.hasClients) {
            final itemExtent =
                _horizontalLongScrollItemExtent(screenWidth, screenHeight);
            final target = (_currentPageIndex * itemExtent)
                .clamp(0.0, ctrl.position.maxScrollExtent);
            ctrl.jumpTo(target);
          }
        }
      } else if (_standardNeedsInitialJump) {
        if (_pageController.hasClients) {
          _standardNeedsInitialJump = false;
          final target = effectiveType == DisplayType.twoPage
              ? (_currentPageIndex ~/ 2).clamp(0, 301)
              : _currentPageIndex;
          _pageController.jumpToPage(target);
        } else {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && _standardNeedsInitialJump) setState(() {});
          });
        }
      }
    });

    final pageNumber = _currentPageIndex + 1;
    final introOverlay = _buildMushafIntroOverlay(context);
    return Listener(
      onPointerDown: (_) {
        _resetInactivityTimer();
        MushafRamIdleExpander.instance.onUserPointerDown();
      },
      child: Directionality(
        textDirection: TextDirection.rtl,
        child: Stack(
          children: [
            Column(
              children: [
                Expanded(
                  child: ColoredBox(
                    color: _mushafBackgroundColor,
                    child: Padding(
                      padding: EdgeInsets.only(
                        top: MediaQuery.viewPaddingOf(context).top,
                        bottom: MediaQuery.viewPaddingOf(context).bottom,
                      ),
                      child: KeyedSubtree(
                        key: _introMushafAreaKey,
                        child: MushafPaperBackgroundScope(
                          color: _mushafBackgroundColor,
                          child: _buildDisplayContent(
                            context,
                            effectiveType,
                            pageNumber,
                            screenWidth,
                            screenHeight,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
            if (effectiveType == DisplayType.longScroll)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: _buildLongScrollBottomBar(context),
              ),
            if (effectiveType == DisplayType.horizontalLongScroll)
              Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                child: _buildHorizontalLongScrollBar(context),
              ),
            _buildAyahMiniPlayer(context),
            if (introOverlay != null) introOverlay,
          ],
        ),
      ),
    );
  }

  /// طبقة التعريف فوق المشغّل حتى يُبرَز زر القارئ في الخطوة الأخيرة.
  Widget? _buildMushafIntroOverlay(BuildContext context) {
    if (_loading || _error != null) return null;
    if (_mushafIntroStep == MushafIntroPrefs.completedMarker ||
        _mushafIntroStep == MushafIntroPrefs.stepWaitPlayback) {
      return null;
    }
    final rect = _mushafIntroStep == MushafIntroPrefs.stepReciter
        ? (mushafIntroRectFromKey(_introReciterKey) ??
            mushafIntroReciterFallbackRect(context))
        : (mushafIntroRectFromKey(_introMushafAreaKey) ??
            mushafIntroFallbackRect(context));

    late final String title;
    late final String body;
    late final String nextLabel;
    switch (_mushafIntroStep) {
      case MushafIntroPrefs.stepTapMenu:
        title = 'عرض القائمة بسرعة';
        body =
            'المس مرة واحدة على صفحة المصحف (في منطقة النص وليس على آية محددة إن أمكن) لفتح القائمة الرئيسية: البحث، العلامات، الأذكار، الختمة، وغيرها.';
        nextLabel = 'التالي';
        break;
      case MushafIntroPrefs.stepLongPress:
        title = 'قائمة الاستماع';
        body =
            'اضغط مطولاً على أي آية حتى تظهر نافذة فيها «الاستماع للآية» والتفسير والتضليل ونسخ النص.';
        nextLabel = 'التالي';
        break;
      case MushafIntroPrefs.stepReciter:
        title = 'تغيير القارئ';
        body =
            'من المشغّل العائم في الأسفل، اضغط على اسم القارئ الظاهر في المنتصف لفتح قائمة القرّاء والاختيار بينهم.';
        nextLabel = 'تم';
        break;
      default:
        return null;
    }

    return Positioned.fill(
      child: MushafIntroOverlay(
        focusRect: rect,
        title: title,
        body: body,
        nextLabel: nextLabel,
        onNext: () => _onMushafIntroNext(context),
        onSkip: _onMushafIntroSkip,
        showSkip: true,
      ),
    );
  }

  Future<void> _onMushafIntroNext(BuildContext context) async {
    switch (_mushafIntroStep) {
      case MushafIntroPrefs.stepTapMenu:
        await MushafIntroPrefs.setStep(MushafIntroPrefs.stepLongPress);
        if (mounted)
          setState(() => _mushafIntroStep = MushafIntroPrefs.stepLongPress);
        break;
      case MushafIntroPrefs.stepLongPress:
        await MushafIntroPrefs.setStep(MushafIntroPrefs.stepWaitPlayback);
        if (mounted) {
          setState(() => _mushafIntroStep = MushafIntroPrefs.stepWaitPlayback);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'الآن: اضغط مطولاً على آية واختر «الاستماع للآية». عند بدء التشغيل يظهر شرح تغيير القارئ.',
                style: _menuQuranStyle(fontSize: 14, color: Colors.white),
              ),
              backgroundColor: const Color(0xFF2E7D32),
              duration: const Duration(seconds: 6),
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
        break;
      case MushafIntroPrefs.stepReciter:
        await MushafIntroPrefs.markCompleted();
        if (mounted) {
          setState(() => _mushafIntroStep = MushafIntroPrefs.completedMarker);
        }
        break;
      default:
        break;
    }
  }

  Future<void> _onMushafIntroSkip() async {
    await MushafIntroPrefs.markCompleted();
    if (mounted) {
      setState(() => _mushafIntroStep = MushafIntroPrefs.completedMarker);
    }
  }

  /// مشغل تلاوة عائم: صف علوي (السورة + القارئ)، صف سفلي (أزرار التشغيل + تأشير الآية + إغلاق).
  Widget _buildAyahMiniPlayer(BuildContext context) {
    final player = AyahAudioPlayer.instance;
    final rotateWholePlayer = _isHorizontallyRotatedReading ||
        MediaQuery.orientationOf(context) == Orientation.landscape;
    return ListenableBuilder(
      listenable: player,
      builder: (bctx, __) {
        if (player.isAzkarSession) {
          return const SizedBox.shrink();
        }
        if (!player.isActive && player.state != AyahPlayerState.error) {
          return const SizedBox.shrink();
        }
        final sura = player.currentSura;
        final ayah = player.currentAyah;
        final suraName = sura != null ? _suraNameFromNo(sura) : '';
        final reciter = kAyahReciters
            .where((r) => r.id == player.currentReciterId)
            .firstOrNull;
        final reciterName = reciter?.nameAr ?? 'القارئ';
        final screenSize = MediaQuery.sizeOf(bctx);
        final safePadding = MediaQuery.paddingOf(bctx);
        final leftSideFullSpan =
            (screenSize.height - safePadding.top - safePadding.bottom - 8)
                .clamp(220.0, double.infinity)
                .toDouble();
        final titleText = player.state == AyahPlayerState.error
            ? (player.errorMessage ?? 'خطأ')
            : (suraName.isNotEmpty && ayah != null
                ? '$suraName — آية $ayah'
                : suraName.isNotEmpty
                    ? suraName
                    : '');
        final infoStrip = Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: Tooltip(
                message: 'تحديد نطاق التشغيل',
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    onTap: () => _showAudioRangePicker(bctx),
                    borderRadius: BorderRadius.circular(999),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.10),
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.22),
                        ),
                      ),
                      child: Row(
                        children: [
                          const Icon(
                            Icons.keyboard_arrow_down_rounded,
                            color: Colors.white70,
                            size: 18,
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              titleText,
                              style: _quranStyle(
                                fontSize: 15,
                                color: Colors.white,
                                fontWeight: FontWeight.w600,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.right,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: KeyedSubtree(
                key: _introReciterKey,
                child: Tooltip(
                  message: 'تغيير القارئ',
                  child: Material(
                    color: Colors.transparent,
                    child: InkWell(
                      onTap: () => _showReciterPicker(bctx),
                      borderRadius: BorderRadius.circular(999),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.10),
                          borderRadius: BorderRadius.circular(999),
                          border: Border.all(
                            color: Colors.white.withValues(alpha: 0.22),
                          ),
                        ),
                        child: Row(
                          children: [
                            const Icon(
                              Icons.keyboard_arrow_down_rounded,
                              color: Colors.white70,
                              size: 18,
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                reciterName,
                                style: _quranStyle(
                                  fontSize: 15,
                                  color: Colors.white,
                                  fontWeight: FontWeight.w600,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                textAlign: TextAlign.center,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 4),
            Tooltip(
              message: 'إيقاف',
              child: IconButton(
                icon: const Icon(Icons.close, size: 20),
                color: Colors.white70,
                padding: const EdgeInsets.all(4),
                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                onPressed: () async {
                  await player.stop();
                  if (player.state == AyahPlayerState.error) {
                    player.dismissError();
                  }
                  setState(() {
                    _playerOverlayVisible = false;
                    _userDismissedPlayerOverlay = false;
                  });
                },
              ),
            ),
          ],
        );

        final controlsStrip = Row(
          children: [
            Expanded(
              child: _miniPlayerLabeledAction(
                icon: Icon(
                  _playbackModeIcon(player.playbackMode),
                  color: Colors.white70,
                  size: 20,
                ),
                label: _playbackModeLabel(player.playbackMode),
                tooltip: _playbackModeTooltip(player.playbackMode),
                onPressed: () => player.cyclePlaybackMode(),
              ),
            ),
            Expanded(
              child: _miniPlayerLabeledAction(
                icon: Transform.rotate(
                  angle: 3.14159265359,
                  child: const Icon(Icons.skip_previous),
                ),
                label: 'السابق',
                tooltip: 'السابق',
                color: Colors.white,
                onPressed: player.hasPrev ? () => player.playPrev() : null,
              ),
            ),
            Expanded(
              child: _miniPlayerLabeledAction(
                icon: Transform.rotate(
                  angle: 3.14159265359,
                  child: Icon(
                    player.isPlaying ? Icons.pause : Icons.play_arrow,
                    color: Colors.white,
                    size: 28,
                  ),
                ),
                label: player.isPlaying ? 'إيقاف مؤقت' : 'تشغيل',
                tooltip: player.isPlaying ? 'إيقاف مؤقت' : 'تشغيل',
                onPressed: () async {
                  if (player.isPlaying) {
                    await player.pause();
                  } else {
                    await player.resume();
                  }
                },
              ),
            ),
            Expanded(
              child: _miniPlayerLabeledAction(
                icon: Transform.rotate(
                  angle: 3.14159265359,
                  child: const Icon(Icons.skip_next),
                ),
                label: 'التالي',
                tooltip: 'التالي',
                color: Colors.white,
                onPressed: player.hasNext ? () => player.playNext() : null,
              ),
            ),
            Expanded(
              child: _miniPlayerLabeledAction(
                icon: Icon(
                  player.showAyahHighlight
                      ? Icons.highlight
                      : Icons.highlight_outlined,
                  size: 22,
                ),
                label: player.showAyahHighlight
                    ? 'إخفاء\nالتضليل'
                    : 'إظهار\nالتضليل',
                tooltip: player.showAyahHighlight
                    ? 'إخفاء تضليل الآية'
                    : 'إظهار تضليل الآية',
                color: player.showAyahHighlight ? Colors.white : Colors.white54,
                onPressed: () async {
                  await player.setShowAyahHighlight(!player.showAyahHighlight);
                },
              ),
            ),
          ],
        );

        final playerCore = Material(
          elevation: 12,
          borderRadius: BorderRadius.circular(12),
          clipBehavior: Clip.antiAlias,
          color: const Color.fromARGB(255, 8, 32, 16).withValues(alpha: 0.96),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
            child: rotateWholePlayer
                ? Row(
                    children: [
                      Expanded(child: controlsStrip),
                      const SizedBox(width: 6),
                      Expanded(child: infoStrip),
                    ],
                  )
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      infoStrip,
                      const SizedBox(height: 6),
                      controlsStrip,
                    ],
                  ),
          ),
        );

        final positionedChild = rotateWholePlayer
            ? RotatedBox(
                quarterTurns: 1,
                child: SizedBox(
                  width: leftSideFullSpan,
                  child: playerCore,
                ),
              )
            : playerCore;

        return Positioned(
          left: 8,
          right: rotateWholePlayer ? null : 8,
          top: rotateWholePlayer ? 0 : null,
          bottom: rotateWholePlayer ? 0 : 8,
          child: AnimatedSlide(
            offset: _playerOverlayVisible ? Offset.zero : const Offset(0, 1.5),
            duration: const Duration(milliseconds: 400),
            curve: Curves.easeInOutCubic,
            child: IgnorePointer(
              ignoring: !_playerOverlayVisible,
              child: SafeArea(
                top: false,
                child: Align(
                  alignment: rotateWholePlayer
                      ? Alignment.centerLeft
                      : Alignment.bottomCenter,
                  child: positionedChild,
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  IconData _playbackModeIcon(AyahPlaybackMode mode) {
    return switch (mode) {
      AyahPlaybackMode.once => Icons.filter_1,
      AyahPlaybackMode.repeat => Icons.repeat_one,
      AyahPlaybackMode.continuous => Icons.queue_music,
    };
  }

  String _playbackModeTooltip(AyahPlaybackMode mode) {
    return switch (mode) {
      AyahPlaybackMode.once => 'مرة واحدة',
      AyahPlaybackMode.repeat => 'تكرار الآية',
      AyahPlaybackMode.continuous => 'متابعة',
    };
  }

  String _playbackModeLabel(AyahPlaybackMode mode) {
    return switch (mode) {
      AyahPlaybackMode.once => 'بدون تكرار',
      AyahPlaybackMode.repeat => 'تكرار الآية',
      AyahPlaybackMode.continuous => 'التشغيل المستمر',
    };
  }

  Future<void> _setPlaybackMode(AyahPlaybackMode target) async {
    final player = AyahAudioPlayer.instance;
    for (int i = 0;
        i < AyahPlaybackMode.values.length && player.playbackMode != target;
        i++) {
      await player.cyclePlaybackMode();
    }
  }

  Future<AyahPlaybackMode?> _showPlaybackModePicker(BuildContext context) {
    return showQuranMenuSidePanel<AyahPlaybackMode>(
      context: context,
      horizontallyRotatedReading: _isHorizontallyRotatedReading,
      backgroundColor: _menuPal.surface,
      builder: (ctx) {
        final current = AyahAudioPlayer.instance.playbackMode;
        return _wrapMainMenuFamilyOverlay(
          ctx,
          Directionality(
            textDirection: TextDirection.rtl,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'اختر نمط التشغيل',
                      style: _menuQuranStyle(
                        fontSize: 18,
                        color: const Color(0xFF1B5E20),
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 10),
                    for (final mode in AyahPlaybackMode.values)
                      ListTile(
                        leading: Icon(
                          _playbackModeIcon(mode),
                          color: const Color(0xFF2E7D32),
                        ),
                        title: Text(
                          _playbackModeLabel(mode),
                          style: _menuQuranStyle(
                            fontSize: 15,
                            color: const Color(0xFF1B5E20),
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        trailing: mode == current
                            ? const Icon(Icons.check_circle_rounded,
                                color: Color(0xFF2E7D32))
                            : const SizedBox.shrink(),
                        onTap: () => Navigator.pop(ctx, mode),
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _miniPlayerLabeledAction({
    required Widget icon,
    required String label,
    required String tooltip,
    required VoidCallback? onPressed,
    Color? color,
  }) {
    final enabled = onPressed != null;
    return Tooltip(
      message: tooltip,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: icon,
            color: color ?? Colors.white,
            padding: const EdgeInsets.all(4),
            constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
            onPressed: onPressed,
          ),
          Text(
            label,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: _quranStyle(
              fontSize: 13,
              color: enabled ? Colors.white70 : Colors.white38,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _showAudioRangePicker(BuildContext context) async {
    final player = AyahAudioPlayer.instance;
    final rotateWithPlayer = _isHorizontallyRotatedReading ||
        MediaQuery.orientationOf(context) == Orientation.landscape;
    MushafRamIdleExpander.instance.beginBlockingUi();
    try {
      await showQuranMenuSidePanel<void>(
        context: context,
        horizontallyRotatedReading: _isHorizontallyRotatedReading,
        isScrollControlled: true,
        bottomSheetShape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
        ),
        backgroundColor: _menuPal.surface,
        builder: (ctx) {
          final safePadding = MediaQuery.paddingOf(ctx);
          final rotatedSheetHeight = (MediaQuery.sizeOf(ctx).width -
                  safePadding.top -
                  safePadding.bottom -
                  12)
              .clamp(320.0, 760.0)
              .toDouble();
          final sheet = Directionality(
            textDirection: TextDirection.rtl,
            child: SizedBox(
              height: rotateWithPlayer ? rotatedSheetHeight : null,
              child: _AudioRangePickerSheet(
                initialRange: player.playbackRange,
                currentSura: player.currentSura,
                currentAyah: player.currentAyah,
                suraList: _suraList,
                suraAyahCount: _suraAyahCount,
                toNormalDigits: _toNormalDigits,
                arabicFontFamily: _arabicUiFontFamily,
                menuPalette: _menuPal,
                compactLandscapeLayout: rotateWithPlayer,
                onClear: () async {
                  await player.clearPlaybackRange();
                },
                onApply: (fromSura, fromAyah, toSura, toAyah) async {
                  await player.setPlaybackRangeSpan(
                    fromSura,
                    fromAyah,
                    toSura,
                    toAyah,
                  );
                  await player.playAyah(fromSura, fromAyah);
                },
              ),
            ),
          );
          return _wrapMainMenuFamilyOverlay(ctx, sheet);
        },
      );
    } finally {
      MushafRamIdleExpander.instance.endBlockingUi();
    }
  }

  Future<void> _showReciterPicker(BuildContext context) async {
    final favorites = await AyahRecitersPrefs.instance.getFavoriteReciterIds();
    final currentId = AyahAudioPlayer.instance.currentReciterId;
    final favReciters =
        kAyahReciters.where((r) => favorites.contains(r.id)).toList();
    final otherReciters =
        kAyahReciters.where((r) => !favorites.contains(r.id)).toList();
    if (!context.mounted) return;
    final rotateWithPlayer = _isHorizontallyRotatedReading ||
        MediaQuery.orientationOf(context) == Orientation.landscape;
    final maxSheetHeight = MediaQuery.sizeOf(context).height * 0.6;
    MushafRamIdleExpander.instance.beginBlockingUi();
    showQuranMenuSidePanel<void>(
      context: context,
      horizontallyRotatedReading: _isHorizontallyRotatedReading,
      isScrollControlled: true,
      backgroundColor: _menuPal.surface,
      builder: (ctx) {
        final safePadding = MediaQuery.paddingOf(ctx);
        final rotatedSheetHeight = (MediaQuery.sizeOf(ctx).width -
                safePadding.top -
                safePadding.bottom -
                12)
            .clamp(320.0, 760.0)
            .toDouble();
        final sheet = Directionality(
          textDirection: TextDirection.rtl,
          child: SizedBox(
            height: rotateWithPlayer ? rotatedSheetHeight : maxSheetHeight,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'اختر القارئ',
                      style: _menuQuranStyle(
                        fontSize: 20,
                        color: _menuPal.title,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Expanded(
                      child: SingleChildScrollView(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            if (favReciters.isNotEmpty) ...[
                              Text(
                                'المفضلون',
                                style: _menuQuranStyle(
                                  fontSize: 13,
                                  color: _menuPal.accent,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 6),
                              ...favReciters.map(
                                (r) =>
                                    _reciterTile(ctx, r, currentId, favorites),
                              ),
                              if (otherReciters.isNotEmpty)
                                const SizedBox(height: 8),
                            ],
                            if (otherReciters.isNotEmpty)
                              ...otherReciters.map(
                                (r) =>
                                    _reciterTile(ctx, r, currentId, favorites),
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
        );
        return _wrapMainMenuFamilyOverlay(ctx, sheet);
      },
    ).whenComplete(MushafRamIdleExpander.instance.endBlockingUi);
  }

  Widget _reciterTile(
    BuildContext ctx,
    AyahReciter r,
    String currentId,
    List<String> favorites,
  ) {
    final p = _menuPal;
    final isSelected = r.id == currentId;
    final isFav = favorites.contains(r.id);
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: isSelected ? p.reciterSelectedBg : p.reciterUnselectedBg,
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () async {
            await AyahAudioPlayer.instance.setReciter(r.id);
            if (ctx.mounted) Navigator.pop(ctx);
            final s = AyahAudioPlayer.instance.currentSura;
            final a = AyahAudioPlayer.instance.currentAyah;
            if (s != null && a != null) {
              await AyahAudioPlayer.instance.playAyah(s, a);
            }
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Row(
              children: [
                IconButton(
                  icon: Icon(
                    isFav ? Icons.star_rounded : Icons.star_border_rounded,
                    color: isFav ? p.accent : p.trailingChevron,
                    size: 24,
                  ),
                  onPressed: () async {
                    await AyahRecitersPrefs.instance.toggleFavorite(r.id);
                    if (!ctx.mounted) return;
                    Navigator.pop(ctx);
                    if (mounted) _showReciterPicker(context);
                  },
                  style: IconButton.styleFrom(
                    minimumSize: const Size(40, 40),
                    padding: EdgeInsets.zero,
                  ),
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        r.nameAr,
                        style: _menuQuranStyle(
                          fontSize: 17,
                          color: isSelected
                              ? p.reciterNameSelected
                              : p.reciterNameUnselected,
                          fontWeight:
                              isSelected ? FontWeight.bold : FontWeight.w600,
                        ),
                      ),
                      if (r.hasSegments) ...[
                        const SizedBox(height: 2),
                        Text(
                          'يدعم التضليل',
                          style: _menuQuranStyle(
                            fontSize: 12,
                            color: p.accent.withValues(alpha: 0.9),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (isSelected)
                  Icon(Icons.check_circle_rounded, color: p.accent, size: 24),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDisplayContent(
    BuildContext context,
    DisplayType type,
    int pageNumber,
    double screenWidth,
    double screenHeight,
  ) {
    final reader = AyahLongPressScope(
      onAyahLongPress: _showAyahLongPressMenu,
      child: CompactLineSpacingScope(
        compact: type == DisplayType.horizontal,
        child: QuranReader(
          embedded: true,
          controller: _pageController,
          initialPage: pageNumber,
          mode: _qpcMode,
          forceWhiteMushafText: _useWhiteTextOnDarkMushaf,
          buildTopBarForPage: _buildQpcTopBarForPage,
          onPageChanged: (p) {
            final nextIndex = p - 1;
            if (nextIndex == _currentPageIndex) return;
            setState(() => _currentPageIndex = nextIndex);
            _saveCurrentPage(_currentPageIndex);
            _syncMushafRamExpanderContext();
            if (type == DisplayType.horizontal) {
              _horizontalScrollController?.jumpTo(0);
            }
          },
          onTap: _handleMushafTap,
          onReady: _standardNeedsInitialJump
              ? () {
                  if (mounted) setState(() {});
                }
              : null,
        ),
      ),
    );

    switch (type) {
      case DisplayType.standard:
        return reader;
      case DisplayType.horizontal:
        if (!_horizontalRotationEnabled) return reader;
        const horizontalMarginFraction = 0.02;
        const verticalMarginFraction = 0.02;
        const visibleQuarterFraction = 4.0;
        const refWidth = 360.0;
        const baseScale = 0.65;
        final widthScale = (screenWidth / refWidth).clamp(0.6, 1.2);
        final windowHeight = screenHeight * (1 - 2 * verticalMarginFraction);
        final fullPageHeight = windowHeight;
        final fullPageWidth = (windowHeight / _mushafAspectRatio) *
            visibleQuarterFraction *
            baseScale *
            widthScale;
        const bottomFraction = 0.08 * 0.5;
        _horizontalScrollController ??= ScrollController();
        return SingleChildScrollView(
          controller: _horizontalScrollController,
          scrollDirection: Axis.horizontal,
          padding: EdgeInsets.only(
            left: screenWidth * horizontalMarginFraction,
            right: screenWidth * horizontalMarginFraction,
            top: screenHeight * 0.02,
            bottom: screenHeight * bottomFraction,
          ),
          child: SizedBox(
            width: fullPageWidth,
            height: fullPageHeight,
            child: Center(
              child: SizedBox(
                width: fullPageWidth,
                height: fullPageHeight,
                child: RotatedBox(
                  quarterTurns: 1,
                  child: SizedBox(
                    width: fullPageHeight,
                    height: fullPageWidth,
                    child: reader,
                  ),
                ),
              ),
            ),
          ),
        );
      case DisplayType.twoPage:
        return AyahLongPressScope(
          onAyahLongPress: _showAyahLongPressMenu,
          child: _PassiveTapListener(
            onTap: _handleMushafTap,
            child: _buildTwoPageView(context, screenWidth),
          ),
        );
      case DisplayType.longScroll:
        return _buildLongScrollView(context, screenWidth, screenHeight);
      case DisplayType.horizontalLongScroll:
        return _buildHorizontalLongScrollView(
            context, screenWidth, screenHeight);
    }
  }

  /// القراءة الأفقية الطويلة: نفس تخطيط الوضع الأفقي، صفحات بجانب بعض أفقياً.
  /// السلوك والميزات كالقراءة الطويلة (شريط التحكم، التمرير التلقائي، حفظ الموضع).
  Widget _buildHorizontalLongScrollView(
      BuildContext context, double screenWidth, double screenHeight) {
    if (!_horizontalRotationEnabled) {
      return _buildLongScrollView(context, screenWidth, screenHeight);
    }
    const verticalMarginFraction = 0.02;
    const horizontalMarginFraction = 0.02;
    final windowHeight = screenHeight * (1 - 2 * verticalMarginFraction);
    final fullPageHeight = windowHeight;
    final itemExtent =
        _horizontalLongScrollItemExtent(screenWidth, screenHeight);
    const bottomFraction = 0.08 * 0.5;
    final bottomPadding = screenHeight * bottomFraction;
    final topPadding = screenHeight * 0.02;
    final sidePadding = screenWidth * horizontalMarginFraction;
    return CompactLineSpacingScope(
      compact: true,
      child: AyahLongPressScope(
        onAyahLongPress: _showAyahLongPressMenu,
        child: Padding(
          padding: EdgeInsets.only(
            left: sidePadding,
            right: sidePadding,
            top: topPadding,
            bottom: bottomPadding,
          ),
          child: _PassiveTapListener(
            onTap: _handleMushafTap,
            child: NotificationListener<ScrollNotification>(
              onNotification: (n) {
                if (n is ScrollStartNotification && n.dragDetails != null) {
                  if (_autoScrollEnabled) {
                    setState(() => _autoScrollEnabled = false);
                    _stopAutoScrollTicker();
                    _saveDisplayPrefs();
                  }
                  _enterScrollRenderLite();
                }
                if (n is ScrollUpdateNotification ||
                    n is ScrollEndNotification) {
                  final ctrl = _horizontalLongScrollController;
                  if (ctrl != null && ctrl.hasClients) {
                    final page = ((ctrl.offset / itemExtent).round() + 1)
                        .clamp(1, totalPages);
                    if (page - 1 != _currentPageIndex) {
                      _schedulePreloadAroundPage(page);
                      setState(() {
                        _currentPageIndex = page - 1;
                        PageBackgroundLoader.instance.setCurrentPage(page);
                        _saveCurrentPage(_currentPageIndex);
                      });
                      _syncMushafRamExpanderContext();
                    }
                  }
                }
                if (n is ScrollEndNotification ||
                    (n is UserScrollNotification &&
                        n.direction == ScrollDirection.idle)) {
                  _settleScrollRenderTier();
                }
                return false;
              },
              child: ListView.builder(
                controller: _horizontalLongScrollControllerOrCreate,
                scrollDirection: Axis.horizontal,
                itemCount: totalPages,
                itemExtent: itemExtent,
                itemBuilder: (context, index) {
                  final page = index + 1;
                  return SizedBox(
                    width: itemExtent,
                    height: fullPageHeight,
                    child: Center(
                      child: RotatedBox(
                        quarterTurns: 1,
                        child: SizedBox(
                          width: fullPageHeight,
                          height: itemExtent,
                          child: _buildSinglePageForMode(
                            page,
                            seamlessLongScroll: _longScrollSeamlessReading,
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTwoPageView(BuildContext context, double screenWidth) {
    const spreadMaxWidth = 1100.0;
    const dividerWidth = 2.0;
    const horizontalPadding = 24.0;
    // عرض السبريد: يستغل الشاشة مع حد أقصى، الصفحتان في المنتصف بشكل منظم
    final spreadWidth =
        (screenWidth - horizontalPadding * 2).clamp(600.0, spreadMaxWidth);
    return NotificationListener<ScrollNotification>(
      onNotification: (n) {
        if (n is ScrollStartNotification && n.dragDetails != null) {
          _enterScrollRenderLite();
        } else if (n is ScrollEndNotification ||
            (n is UserScrollNotification &&
                n.direction == ScrollDirection.idle)) {
          _settleScrollRenderTier();
        }
        return false;
      },
      child: PageView.builder(
        controller: _pageController,
        itemCount: 302,
        onPageChanged: (index) {
          setState(() => _currentPageIndex = index * 2);
          PageBackgroundLoader.instance.setCurrentPage(index * 2 + 1);
          _saveCurrentPage(_currentPageIndex);
          final center = index * 2 + 1;
          _syncMushafRamExpanderContext();
          if (_qpcMode == QpcMushafMode.qpc1) {
            preloadNearbyQpc1Pages(center);
          } else {
            preloadNearbyPages(center);
          }
        },
        itemBuilder: (context, index) {
          final leftPage = index * 2 + 1;
          final rightPage = index * 2 + 2;
          return Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: horizontalPadding),
              child: SizedBox(
                width: spreadWidth,
                child: Container(
                  decoration: BoxDecoration(
                    color: _mushafBackgroundColor,
                    borderRadius: BorderRadius.circular(4),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.1),
                        blurRadius: 16,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: Row(
                    children: [
                      Expanded(
                        child: _buildSinglePageForMode(leftPage),
                      ),
                      Container(
                        width: dividerWidth,
                        color: Colors.grey.shade400,
                      ),
                      Expanded(
                        child: _buildSinglePageForMode(rightPage),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildSinglePageForMode(int page, {bool seamlessLongScroll = false}) {
    final content = buildQpcPageContent(
      context,
      page,
      _qpcMode,
      forceWhiteMushafText: _useWhiteTextOnDarkMushaf,
      lightweightMode: _lightweightMushafDuringScroll,
      mediumQualityMode: _mediumQualityMushafAfterScroll,
    );
    if (seamlessLongScroll) {
      return ColoredBox(
        color: _mushafBackgroundColor,
        child: SeamlessLongScrollScope(
          active: true,
          child: SizedBox.expand(child: content),
        ),
      );
    }
    return Column(
      children: [
        _buildQpcTopBarForPage(page),
        Expanded(child: content),
        _buildQpcPageNumberRow(page),
      ],
    );
  }

  /// صف رقم الصفحة (يمين للفردي، يسار للزوجي) — نفس العرض الافتراضي: إطار raqum_alsafha + رقم عربي.
  /// إزاحة ~4% من عرض الصف نحو المركز: فردي أقرب لليسار، زوجي أقرب لليمين.
  Widget _buildQpcPageNumberRow(int page) {
    final pageNumberColor =
        _useWhiteTextOnDarkMushaf ? const Color(0xFFE7FFEF) : Colors.black;
    return Padding(
      padding: const EdgeInsets.only(bottom: kQpcPageNumberBottomGap),
      child: Transform.translate(
        offset: const Offset(0, kQpcPageNumberVerticalNudge),
        child: SizedBox(
          height: kQpcPageNumberRowHeight,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final shift = constraints.maxWidth * 0.04;
              final pad = page.isOdd
                  ? EdgeInsets.fromLTRB(16, 0, 16 + shift, 0)
                  : EdgeInsets.fromLTRB(16 + shift, 0, 16, 0);
              return Align(
                alignment:
                    page.isOdd ? Alignment.centerRight : Alignment.centerLeft,
                child: Padding(
                  padding: pad,
                  child: SizedBox(
                    height: kQpcPageNumberRowHeight,
                    child: FittedBox(
                      fit: BoxFit.contain,
                      child: SizedBox(
                        width: 56.25 / kQpcPageNumberVisualBoost,
                        height: 28.125 / kQpcPageNumberVisualBoost,
                        child: Stack(
                          clipBehavior: Clip.none,
                          alignment: Alignment.center,
                          children: [
                            Transform.scale(
                              scale: kQpcRaqumSvgScale,
                              alignment: Alignment.center,
                              child: SvgPicture.asset(
                                'assets/icon/raqum_alsafha.svg',
                                fit: BoxFit.contain,
                              ),
                            ),
                            Text(
                              _toArabicDigits(page),
                              style: TextStyle(
                                fontSize: 18,
                                color: pageNumberColor,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
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

  static const double _mushafAspectRatio = 1.4;

  /// القراءة الطويلة: نفس حسابات العرض الافتراضي بالضبط — نفس التخطيط من ROM،
  /// فقط الترتيب عمودي (صفحة تحت صفحة) بدل أفقي.
  /// كل صفحة تأخذ ارتفاع الشاشة كاملًا كما في العرض الافتراضي.
  Widget _buildLongScrollView(
      BuildContext context, double screenWidth, double screenHeight) {
    final itemExtent = _verticalLongScrollItemExtent(screenHeight);
    return AyahLongPressScope(
      onAyahLongPress: _showAyahLongPressMenu,
      child: _PassiveTapListener(
        onTap: _handleMushafTap,
        child: NotificationListener<ScrollNotification>(
          onNotification: (n) {
            if (n is ScrollStartNotification && n.dragDetails != null) {
              if (_autoScrollEnabled) {
                setState(() => _autoScrollEnabled = false);
                _stopAutoScrollTicker();
                _saveDisplayPrefs();
              }
              _enterScrollRenderLite();
            }
            if (n is ScrollUpdateNotification || n is ScrollEndNotification) {
              final ctrl = _longScrollController;
              if (ctrl != null && ctrl.hasClients) {
                final page = ((ctrl.offset / itemExtent).round() + 1)
                    .clamp(1, totalPages);
                if (page - 1 != _currentPageIndex) {
                  _schedulePreloadAroundPage(page);
                  setState(() {
                    _currentPageIndex = page - 1;
                    PageBackgroundLoader.instance.setCurrentPage(page);
                    _saveCurrentPage(_currentPageIndex);
                  });
                  _syncMushafRamExpanderContext();
                }
              }
            }
            if (n is ScrollEndNotification ||
                (n is UserScrollNotification &&
                    n.direction == ScrollDirection.idle)) {
              _settleScrollRenderTier();
            }
            return false;
          },
          child: ListView.builder(
            controller: _longScrollControllerOrCreate,
            itemCount: totalPages,
            itemExtent: itemExtent,
            itemBuilder: (context, index) {
              final page = index + 1;
              return _buildSinglePageForMode(
                page,
                seamlessLongScroll: _longScrollSeamlessReading,
              );
            },
          ),
        ),
      ),
    );
  }

  void _scheduleLongScrollPeekFadeTimer() {
    _longScrollPeekFadeTimer?.cancel();
    _longScrollPeekFadeTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _longScrollPeekDimmed = true);
    });
  }

  void _expandLongScrollBarAndResetIdle() {
    _longScrollBarIdleTimer?.cancel();
    _longScrollBarMinimizeTimer?.cancel();
    _longScrollPeekFadeTimer?.cancel();
    if (_longScrollBarMinimized || _longScrollPeekDimmed) {
      setState(() {
        _longScrollBarMinimized = false;
        _longScrollPeekDimmed = false;
      });
    }
    _longScrollBarIdleTimer = Timer(const Duration(seconds: 3), () {
      if (!mounted) return;
      _longScrollBarMinimizeTimer?.cancel();
      _longScrollBarMinimizeTimer = Timer(const Duration(seconds: 2), () {
        if (!mounted) return;
        setState(() {
          _longScrollBarMinimized = true;
          _longScrollPeekDimmed = false;
        });
        _scheduleLongScrollPeekFadeTimer();
      });
    });
  }

  void _startLongScrollBarIdleTimer() {
    _longScrollBarIdleTimer?.cancel();
    _longScrollBarMinimizeTimer?.cancel();
    _longScrollPeekFadeTimer?.cancel();
    _longScrollBarIdleTimer = Timer(const Duration(seconds: 3), () {
      if (!mounted) return;
      _longScrollBarMinimizeTimer?.cancel();
      _longScrollBarMinimizeTimer = Timer(const Duration(seconds: 2), () {
        if (!mounted) return;
        setState(() {
          _longScrollBarMinimized = true;
          _longScrollPeekDimmed = false;
        });
        _scheduleLongScrollPeekFadeTimer();
      });
    });
  }

  static const Duration _longScrollBarSwitchDuration =
      Duration(milliseconds: 420);

  Widget _buildLongScrollBarSwitcherTransition(
      Widget child, Animation<double> animation) {
    final curved =
        CurvedAnimation(parent: animation, curve: Curves.easeOutCubic);
    return FadeTransition(
      opacity: curved,
      child: ScaleTransition(
        scale: Tween<double>(begin: 0.88, end: 1.0).animate(curved),
        child: child,
      ),
    );
  }

  /// أيقونة دائرية كخيار «التمرير الطويل» في القائمة — تُظهر الشريط عند الضغط.
  Widget _buildLongScrollPeekChip(BuildContext context) {
    return AnimatedOpacity(
      duration: const Duration(milliseconds: 380),
      curve: Curves.easeInOut,
      opacity: _longScrollPeekDimmed ? 0.52 : 1.0,
      child: Tooltip(
        message: 'إظهار شريط التمرير',
        child: Material(
          elevation: 6,
          shape: const CircleBorder(),
          clipBehavior: Clip.antiAlias,
          color: const Color(0xFFE8F5E9).withOpacity(0.96),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: _expandLongScrollBarAndResetIdle,
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: const Color(0xFF1B5E20).withOpacity(0.08),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.keyboard_double_arrow_down_rounded,
                  size: 24,
                  color: Color(0xFF1B5E20),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// تشغيل/إيقاف التمرير التلقائي — يمين الشريط السفلي (مع RTL).
  Widget _buildLongScrollAutoScrollControl(BuildContext context) {
    final running = _autoScrollEnabled;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        SizedBox(
          height: _longScrollBarIconRowH,
          child: Center(
            child: IconButton(
              tooltip:
                  running ? 'إيقاف التمرير التلقائي' : 'تشغيل التمرير التلقائي',
              icon: Transform.rotate(
                angle: 3.14159265359,
                child: Icon(
                  running
                      ? Icons.pause_circle_filled
                      : Icons.play_circle_outline,
                  color: const Color(0xFF2E7D32),
                  size: _longScrollBarIconSize,
                ),
              ),
              onPressed: () {
                _expandLongScrollBarAndResetIdle();
                setState(() {
                  _autoScrollEnabled = !_autoScrollEnabled;
                  if (_autoScrollEnabled) {
                    _startAutoScroll();
                  } else {
                    _stopAutoScrollTicker();
                  }
                });
                _saveDisplayPrefs();
              },
              padding: const EdgeInsets.all(4),
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints(
                  minWidth: _longScrollBarIconRowH,
                  minHeight: _longScrollBarIconRowH),
            ),
          ),
        ),
        SizedBox(
          height: _longScrollBarCaptionH,
          width: 78,
          child: Align(
            alignment: Alignment.topCenter,
            child: Text(
              running ? 'إيقاف التمرير' : 'تشغيل التمرير',
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: _menuQuranStyle(
                fontSize: 11,
                color: const Color(0xFF1B5E20),
                fontWeight: running ? FontWeight.w700 : FontWeight.w500,
              ).copyWith(height: 1.05),
            ),
          ),
        ),
      ],
    );
  }

  /// زر تبديل «صفحات متصلة» في شريط السرعة (يسار الشاشة في الشريط السفلي).
  Widget _buildLongScrollSeamlessToggle(BuildContext context) {
    final on = _longScrollSeamlessReading;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        SizedBox(
          height: _longScrollBarIconRowH,
          child: Center(
            child: IconButton(
              tooltip: on
                  ? 'إظهار شريط السورة والجزء ورقم الصفحة'
                  : 'إخفاء الشريط ورقم الصفحة لصفحات متصلة',
              icon: Icon(
                on ? Icons.view_stream : Icons.view_day_outlined,
                color: on ? const Color(0xFF0D47A1) : const Color(0xFF2E7D32),
                size: _longScrollBarIconSize,
              ),
              onPressed: () {
                _expandLongScrollBarAndResetIdle();
                final was = _longScrollSeamlessReading;
                final sw = MediaQuery.sizeOf(context).width;
                final sh = MediaQuery.sizeOf(context).height;
                setState(() => _longScrollSeamlessReading = !was);
                _saveDisplayPrefs();
                _resyncLongScrollAfterSeamlessToggle(
                  wasSeamless: was,
                  screenWidth: sw,
                  screenHeight: sh,
                );
              },
              padding: const EdgeInsets.all(4),
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints(
                  minWidth: _longScrollBarIconRowH,
                  minHeight: _longScrollBarIconRowH),
            ),
          ),
        ),
        SizedBox(
          height: _longScrollBarCaptionH,
          width: 84,
          child: Align(
            alignment: Alignment.topCenter,
            child: Text(
              'صفحات متصلة',
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: _menuQuranStyle(
                fontSize: 11,
                color: const Color(0xFF1B5E20),
                fontWeight: on ? FontWeight.w700 : FontWeight.w500,
              ).copyWith(height: 1.05),
            ),
          ),
        ),
      ],
    );
  }

  /// صف التحكم نفس ترتيب الشريط السفلي (RTL): تشغيل، −/النسبة/+، صفحات متصلة.
  Widget _buildLongScrollBarControlRow(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _buildLongScrollAutoScrollControl(context),
        SizedBox(width: _longScrollBarBetweenGroups),
        _buildLongScrollBottomBarSpeedCluster(context),
        SizedBox(width: _longScrollBarBetweenGroups),
        _buildLongScrollSeamlessToggle(context),
      ],
    );
  }

  /// بطاقة الشريط (نفس شكل الشريط السفلي) بدون طبقة الشفافية عند الخمول.
  Widget _buildLongScrollBarMaterialCard(BuildContext context) {
    return Material(
      color: const Color(0xFFE8F5E9).withOpacity(0.96),
      borderRadius: BorderRadius.circular(24),
      elevation: 6,
      child: InkWell(
        onTap: _expandLongScrollBarAndResetIdle,
        borderRadius: BorderRadius.circular(24),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.center,
            child: _buildLongScrollBarControlRow(context),
          ),
        ),
      ),
    );
  }

  /// التمرير الأفقي الطويل: نفس لوحة الشريط السفلي، مدوّرة 90° ككتلة واحدة على اليسار.
  Widget _buildHorizontalLongScrollBar(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted &&
          _displayType == DisplayType.horizontalLongScroll &&
          !_longScrollBarMinimized) {
        _startLongScrollBarIdleTimer();
      }
    });
    final screenHeight = MediaQuery.sizeOf(context).height;
    final screenWidth = MediaQuery.sizeOf(context).width;
    const marginFraction = 0.02;
    final margin = screenHeight * marginFraction;
    final leftMargin =
        MediaQuery.paddingOf(context).left + screenWidth * marginFraction;
    return Padding(
      padding: EdgeInsets.only(left: leftMargin, top: margin, bottom: margin),
      child: AnimatedSwitcher(
        duration: _longScrollBarSwitchDuration,
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeInCubic,
        layoutBuilder: (Widget? currentChild, List<Widget> previousChildren) {
          return Stack(
            clipBehavior: Clip.none,
            alignment: Alignment.centerLeft,
            children: <Widget>[
              ...previousChildren,
              if (currentChild != null) currentChild,
            ],
          );
        },
        transitionBuilder: _buildLongScrollBarSwitcherTransition,
        child: _longScrollBarMinimized
            ? KeyedSubtree(
                key: const ValueKey<Object>('long_scroll_peek_h'),
                child: RotatedBox(
                  quarterTurns: 1,
                  child: _buildLongScrollPeekChip(context),
                ),
              )
            : KeyedSubtree(
                key: const ValueKey<Object>('long_scroll_strip_h'),
                child: GestureDetector(
                  onTap: _expandLongScrollBarAndResetIdle,
                  onPanDown: (_) => _expandLongScrollBarAndResetIdle(),
                  child: RotatedBox(
                    quarterTurns: 1,
                    child: _buildLongScrollBarMaterialCard(context),
                  ),
                ),
              ),
      ),
    );
  }

  Widget _buildLongScrollBottomBar(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted &&
          _displayType == DisplayType.longScroll &&
          !_longScrollBarMinimized) {
        _startLongScrollBarIdleTimer();
      }
    });
    final bottomPad = MediaQuery.paddingOf(context).bottom;
    return SafeArea(
      top: false,
      child: Padding(
        padding: EdgeInsets.fromLTRB(12, 0, 12, bottomPad > 0 ? 2 : 4),
        child: AnimatedSwitcher(
          duration: _longScrollBarSwitchDuration,
          switchInCurve: Curves.easeOutCubic,
          switchOutCurve: Curves.easeInCubic,
          layoutBuilder: (Widget? currentChild, List<Widget> previousChildren) {
            return Stack(
              clipBehavior: Clip.none,
              alignment: Alignment.bottomCenter,
              children: <Widget>[
                ...previousChildren,
                if (currentChild != null) currentChild,
              ],
            );
          },
          transitionBuilder: _buildLongScrollBarSwitcherTransition,
          child: _longScrollBarMinimized
              ? KeyedSubtree(
                  key: const ValueKey<Object>('long_scroll_peek_v'),
                  child: _buildLongScrollPeekChip(context),
                )
              : KeyedSubtree(
                  key: const ValueKey<Object>('long_scroll_strip_v'),
                  child: SizedBox(
                    width: double.infinity,
                    child: GestureDetector(
                      onTap: _expandLongScrollBarAndResetIdle,
                      onPanDown: (_) => _expandLongScrollBarAndResetIdle(),
                      child: _buildLongScrollBarMaterialCard(context),
                    ),
                  ),
                ),
        ),
      ),
    );
  }

  void _stopAutoScrollTicker() {
    _autoScrollTicker?.stop();
    _autoScrollLastFrameTime = null;
  }

  /// تمرير مزامن مع الإطار + Δt فعلي؛ يحافظ على نفس بكسل/ثانية القديم (مؤقت 50ms + jumpTo).
  void _handleAutoScrollTick(Duration _) {
    if (!mounted || !_autoScrollEnabled) {
      _stopAutoScrollTicker();
      return;
    }
    if (_displayType != DisplayType.longScroll &&
        _displayType != DisplayType.horizontalLongScroll) {
      _stopAutoScrollTicker();
      return;
    }
    final ctrl = _displayType == DisplayType.horizontalLongScroll
        ? _horizontalLongScrollControllerOrCreate
        : _longScrollControllerOrCreate;
    if (!ctrl.hasClients) return;

    final pos = ctrl.position;
    // قبل اكتمال التخطيط يكون maxScrollExtent = 0 فيُخطأ باعتبارنا في النهاية.
    if (pos.hasContentDimensions &&
        pos.maxScrollExtent > 0 &&
        pos.pixels >= pos.maxScrollExtent - 0.5) {
      _stopAutoScrollTicker();
      setState(() => _autoScrollEnabled = false);
      _saveDisplayPrefs();
      return;
    }
    if (!pos.hasContentDimensions || pos.maxScrollExtent <= 0) return;

    final now = DateTime.now();
    final dt = _autoScrollLastFrameTime == null
        ? 0.0
        : now.difference(_autoScrollLastFrameTime!).inMicroseconds / 1e6;
    _autoScrollLastFrameTime = now;
    if (dt <= 0 || dt > 0.2) return;

    final effectiveSpeed = _effectiveAutoScrollSpeed();
    final pixelsPerSecond = (0.15 + effectiveSpeed * 1.85) * 20.0;
    final delta = pixelsPerSecond * dt;
    ctrl.jumpTo(
      (pos.pixels + delta).clamp(0.0, pos.maxScrollExtent),
    );
  }

  void _startAutoScroll() {
    _ensureAutoScrollTicker();
    _stopAutoScrollTicker();
    _autoScrollLastFrameTime = null;
    _autoScrollTicker!.start();
  }

  Future<bool> _confirmEnableFullMushafBackgroundWarmup(
    BuildContext context,
  ) async {
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          backgroundColor: _menuPal.surface,
          surfaceTintColor: Colors.transparent,
          title: Text(
            'تفعيل التحميل الكامل بالخلفية',
            style: _menuQuranStyle(
              fontSize: 18,
              color: _menuPal.title,
              fontWeight: FontWeight.bold,
            ),
          ),
          content: Text(
            'قد تلاحظ بطئًا مؤقتًا لمدة تصل إلى 5 دقائق بعد فتح التطبيق، لأن التطبيق سيجهز صفحات المصحف تدريجيًا في الخلفية لتحسين سرعة التنقل لاحقًا.',
            style: _menuQuranStyle(
              fontSize: 14,
              color: _menuPal.subtitle,
              fontWeight: FontWeight.normal,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(
                'إلغاء',
                style: _menuQuranStyle(
                  fontSize: 14,
                  color: _menuPal.trailingChevron,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: _menuPal.accent,
                foregroundColor: Colors.white,
              ),
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(
                'موافق',
                style: _menuQuranStyle(
                  fontSize: 14,
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        ),
      ),
    );
    return result ?? false;
  }

  Future<void> _setFullMushafBackgroundWarmup(
    BuildContext context,
    bool enabled,
  ) async {
    if (enabled && !_fullMushafBackgroundWarmup) {
      final ok = await _confirmEnableFullMushafBackgroundWarmup(context);
      if (!ok) return;
    }
    setState(() => _fullMushafBackgroundWarmup = enabled);
    await _saveFullMushafBackgroundWarmupPref();
    MushafRamIdleExpander.instance.onFullBackgroundWarmupPrefChanged(
      enabled: _fullMushafBackgroundWarmup,
      pageOneBased: _currentPageIndex + 1,
      cacheMode: _mushafRamCacheModeKey(),
    );
  }

  void _showSettingsSheet(BuildContext context) {
    MushafRamIdleExpander.instance.beginBlockingUi();
    showQuranMenuSidePanel<void>(
      context: context,
      horizontallyRotatedReading: _isHorizontallyRotatedReading,
      isScrollControlled: true,
      backgroundColor: _menuPal.surface,
      builder: (ctx) => _wrapMainMenuFamilyOverlay(
        ctx,
        StatefulBuilder(
          builder: (ctx, setSheetState) => Directionality(
            textDirection: TextDirection.rtl,
            child: SafeArea(
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    NestedQuranMenuAppBar(
                      title: 'الإعدادات',
                      titleStyle: _menuQuranStyle(
                        fontSize: 18,
                        color: _menuPal.title,
                        fontWeight: FontWeight.bold,
                      ),
                      onBack: () => Navigator.pop(ctx),
                      onDismissAll: () => _dismissAllMenuOverlays(ctx),
                    ),
                    Divider(height: 1, color: _menuPal.divider),
                    ListTile(
                      leading: Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: _menuPal.tileLeadingDecorationColor,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Icon(
                          Icons.palette_rounded,
                          color: _menuPal.tileLeadingIconColor,
                          size: 24,
                        ),
                      ),
                      title: Text(
                        'شكل المصحف',
                        style: _menuQuranStyle(
                          fontSize: 17,
                          color: _menuPal.title,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      subtitle: Text(
                        'لون الخلفية ونوع المصحف',
                        style: _menuQuranStyle(
                          fontSize: 13,
                          color: _menuPal.subtitle,
                          fontWeight: FontWeight.normal,
                        ),
                      ),
                      trailing: Icon(
                        Icons.arrow_forward_ios,
                        size: 14,
                        color: _menuPal.trailingChevron,
                      ),
                      onTap: () => _showMushafStyleSheet(ctx),
                    ),
                    ListTile(
                      leading: Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: _menuPal.tileLeadingDecorationColor,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Icon(
                          Icons.text_fields_rounded,
                          color: _menuPal.tileLeadingIconColor,
                          size: 24,
                        ),
                      ),
                      title: Text(
                        'إعدادات الخط',
                        style: _menuQuranStyle(
                          fontSize: 17,
                          color: _menuPal.title,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      subtitle: Text(
                        _fontSettingsEntrySubtitle(),
                        style: _menuQuranStyle(
                          fontSize: 13,
                          color: _menuPal.subtitle,
                          fontWeight: FontWeight.normal,
                        ),
                      ),
                      trailing: Icon(
                        Icons.arrow_forward_ios,
                        size: 14,
                        color: _menuPal.trailingChevron,
                      ),
                      onTap: () => _showFontSettingsSheet(
                        ctx,
                        onParentListRefresh: () => setSheetState(() {}),
                      ),
                    ),
                    ListenableBuilder(
                      listenable: AyahAudioPlayer.instance,
                      builder: (context, _) {
                        return ListTile(
                          leading: Container(
                            width: 44,
                            height: 44,
                            decoration: BoxDecoration(
                              color: _menuPal.tileLeadingDecorationColor,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Icon(
                              Icons.play_circle_outline_rounded,
                              color: _menuPal.tileLeadingIconColor,
                              size: 24,
                            ),
                          ),
                          title: Text(
                            'إعدادات المشغل',
                            style: _menuQuranStyle(
                              fontSize: 17,
                              color: _menuPal.title,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          subtitle: Text(
                            _playerSettingsEntrySubtitle(),
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: _menuQuranStyle(
                              fontSize: 13,
                              color: _menuPal.subtitle,
                              fontWeight: FontWeight.normal,
                            ),
                          ),
                          trailing: Icon(
                            Icons.arrow_forward_ios,
                            size: 14,
                            color: _menuPal.trailingChevron,
                          ),
                          onTap: () => _showPlayerSettingsSheet(
                            ctx,
                            onParentListRefresh: () => setSheetState(() {}),
                          ),
                        );
                      },
                    ),
                    SwitchListTile.adaptive(
                      secondary: Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: _menuPal.tileLeadingDecorationColor,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        alignment: Alignment.center,
                        child: Icon(
                          Icons.dark_mode_outlined,
                          color: _menuPal.tileLeadingIconColor,
                          size: 24,
                        ),
                      ),
                      title: Text(
                        'الوضع الداكن',
                        style: _menuQuranStyle(
                          fontSize: 17,
                          color: _menuPal.title,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      subtitle: Text(
                        _menuDarkMode
                            ? 'قوائم وألوان قريبة من قائمة الآية'
                            : 'خلفية فاتحة ونص أخضر داكن',
                        style: _menuQuranStyle(
                          fontSize: 13,
                          color: _menuPal.subtitle,
                          fontWeight: FontWeight.normal,
                        ),
                      ),
                      value: _menuDarkMode,
                      activeColor: _menuPal.switchActive,
                      onChanged: (v) async {
                        setState(() => _menuDarkMode = v);
                        setSheetState(() {});
                        await _saveMenuDarkModePref();
                      },
                    ),
                    SwitchListTile.adaptive(
                      secondary: Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: _menuPal.tileLeadingDecorationColor,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        alignment: Alignment.center,
                        child: Icon(
                          Icons.cloud_download_outlined,
                          color: _menuPal.tileLeadingIconColor,
                          size: 24,
                        ),
                      ),
                      title: Text(
                        'تحميل المصحف في الخلفية كامل',
                        style: _menuQuranStyle(
                          fontSize: 17,
                          color: _menuPal.title,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      subtitle: Text(
                        _fullMushafBackgroundWarmup
                            ? 'مفعّل: في الخمول يتم تحميل صفحات المصحف كاملة تدريجيًا'
                            : 'مطفأ: في الخمول يتم تحميل 7 صفحات بعد الصفحة الحالية فقط',
                        style: _menuQuranStyle(
                          fontSize: 13,
                          color: _menuPal.subtitle,
                          fontWeight: FontWeight.normal,
                        ),
                      ),
                      value: _fullMushafBackgroundWarmup,
                      activeTrackColor: _menuPal.switchActive,
                      activeColor: _menuPal.switchActive,
                      onChanged: (v) async {
                        await _setFullMushafBackgroundWarmup(ctx, v);
                        setSheetState(() {});
                      },
                    ),
                    ListTile(
                      leading: Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: _menuPal.tileLeadingDecorationColor,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Icon(
                          Icons.info_outline,
                          color: _menuPal.tileLeadingIconColor,
                          size: 24,
                        ),
                      ),
                      title: Text(
                        'حول التطبيق',
                        style: _menuQuranStyle(
                          fontSize: 17,
                          color: _menuPal.title,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      subtitle: Text(
                        'نبذة , الإصدار والتواصل مع المطور',
                        style: _menuQuranStyle(
                          fontSize: 13,
                          color: _menuPal.subtitle,
                          fontWeight: FontWeight.normal,
                        ),
                      ),
                      trailing: Icon(
                        Icons.arrow_forward_ios,
                        size: 14,
                        color: _menuPal.trailingChevron,
                      ),
                      onTap: () => _showAboutDialog(context),
                    ),
                    const SizedBox(height: 12),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    ).whenComplete(MushafRamIdleExpander.instance.endBlockingUi);
  }

  /// القوائم + نوع الخط + حجم التفسير في شاشة واحدة.
  void _showFontSettingsSheet(
    BuildContext context, {
    required VoidCallback onParentListRefresh,
  }) {
    final sidePanel = _isHorizontallyRotatedReading ||
        MediaQuery.orientationOf(context) == Orientation.landscape;
    MushafRamIdleExpander.instance.beginBlockingUi();
    showQuranMenuSidePanel<void>(
      context: context,
      horizontallyRotatedReading: _isHorizontallyRotatedReading,
      isScrollControlled: true,
      backgroundColor: _menuPal.surface,
      builder: (ctx) => _wrapMainMenuFamilyOverlay(
        ctx,
        StatefulBuilder(
          builder: (ctx, setFontSheetState) {
            void bump() {
              setFontSheetState(() {});
              onParentListRefresh();
            }

            final scroll = SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ListTile(
                    leading: Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: _menuPal.tileLeadingDecorationColor,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(
                        Icons.format_size_rounded,
                        color: _menuPal.tileLeadingIconColor,
                        size: 24,
                      ),
                    ),
                    title: Text(
                      'حجم خط القوائم',
                      style: _menuQuranStyle(
                        fontSize: 17,
                        color: _menuPal.title,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    subtitle: Text(
                      'القائمة الرئيسية والنوافذ (${_ltrUiPercent((_menuFontScale * 100).round())})',
                      style: _menuQuranStyle(
                        fontSize: 13,
                        color: _menuPal.subtitle,
                        fontWeight: FontWeight.normal,
                      ),
                    ),
                    trailing: Icon(
                      Icons.arrow_forward_ios,
                      size: 14,
                      color: _menuPal.trailingChevron,
                    ),
                    onTap: () => _showMenuFontScaleSheet(
                      ctx,
                      onLiveChanged: bump,
                    ),
                  ),
                  ListTile(
                    leading: Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: _menuPal.tileLeadingDecorationColor,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(
                        Icons.menu_book_outlined,
                        color: _menuPal.tileLeadingIconColor,
                        size: 24,
                      ),
                    ),
                    title: Text(
                      'حجم خط التفسير',
                      style: _menuQuranStyle(
                        fontSize: 17,
                        color: _menuPal.title,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    subtitle: Text(
                      'نص السعدي والميسّر (${_ltrUiPercent((_tafsirFontScale * 100).round())})',
                      style: _menuQuranStyle(
                        fontSize: 13,
                        color: _menuPal.subtitle,
                        fontWeight: FontWeight.normal,
                      ),
                    ),
                    trailing: Icon(
                      Icons.arrow_forward_ios,
                      size: 14,
                      color: _menuPal.trailingChevron,
                    ),
                    onTap: () => _showTafsirFontScaleSheet(
                      ctx,
                      onLiveChanged: bump,
                    ),
                  ),
                  ListTile(
                    leading: Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: _menuPal.tileLeadingDecorationColor,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(
                        Icons.font_download_rounded,
                        color: _menuPal.tileLeadingIconColor,
                        size: 24,
                      ),
                    ),
                    title: Text(
                      'نوع الخط',
                      style: _menuQuranStyle(
                        fontSize: 17,
                        color: _menuPal.title,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    subtitle: Text(
                      _arabicUiFontSettingsSubtitle(),
                      style: _menuQuranStyle(
                        fontSize: 13,
                        color: _menuPal.subtitle,
                        fontWeight: FontWeight.normal,
                      ),
                    ),
                    trailing: Icon(
                      Icons.arrow_forward_ios,
                      size: 14,
                      color: _menuPal.trailingChevron,
                    ),
                    onTap: () => _showArabicFontPickerSheet(
                      ctx,
                      onApplied: bump,
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
              ),
            );

            return Directionality(
              textDirection: TextDirection.rtl,
              child: SafeArea(
                child: Column(
                  mainAxisSize: sidePanel ? MainAxisSize.max : MainAxisSize.min,
                  children: [
                    NestedQuranMenuAppBar(
                      title: 'إعدادات الخط',
                      titleStyle: _menuQuranStyle(
                        fontSize: 20,
                        color: _menuPal.title,
                        fontWeight: FontWeight.bold,
                      ),
                      onBack: () => Navigator.pop(ctx),
                      onDismissAll: () => _dismissAllMenuOverlays(ctx),
                    ),
                    Divider(height: 1, color: _menuPal.divider),
                    if (sidePanel) Expanded(child: scroll) else scroll,
                  ],
                ),
              ),
            );
          },
        ),
      ),
    ).whenComplete(MushafRamIdleExpander.instance.endBlockingUi);
  }

  /// القارئ الافتراضي + تضليل التلاوة + نمط التشغيل.
  void _showPlayerSettingsSheet(
    BuildContext context, {
    required VoidCallback onParentListRefresh,
  }) {
    final sidePanel = _isHorizontallyRotatedReading ||
        MediaQuery.orientationOf(context) == Orientation.landscape;
    MushafRamIdleExpander.instance.beginBlockingUi();
    showQuranMenuSidePanel<void>(
      context: context,
      horizontallyRotatedReading: _isHorizontallyRotatedReading,
      isScrollControlled: true,
      backgroundColor: _menuPal.surface,
      builder: (ctx) => _wrapMainMenuFamilyOverlay(
        ctx,
        StatefulBuilder(
          builder: (ctx, setPlayerSheetState) {
            void bump() {
              setPlayerSheetState(() {});
              onParentListRefresh();
            }

            final body = ListenableBuilder(
              listenable: AyahAudioPlayer.instance,
              builder: (context, _) {
                final player = AyahAudioPlayer.instance;
                final reciter = kAyahReciters
                    .where((r) => r.id == player.currentReciterId)
                    .firstOrNull;
                final reciterName = reciter?.nameAr ?? 'غير محدد';
                return SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      ListTile(
                        leading: Container(
                          width: 44,
                          height: 44,
                          decoration: BoxDecoration(
                            color: _menuPal.tileLeadingDecorationColor,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Icon(
                            Icons.record_voice_over_outlined,
                            color: _menuPal.tileLeadingIconColor,
                            size: 24,
                          ),
                        ),
                        title: Text(
                          'القارئ الافتراضي',
                          style: _menuQuranStyle(
                            fontSize: 17,
                            color: _menuPal.title,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        subtitle: Text(
                          reciterName,
                          style: _menuQuranStyle(
                            fontSize: 13,
                            color: _menuPal.subtitle,
                            fontWeight: FontWeight.normal,
                          ),
                        ),
                        trailing: Icon(
                          Icons.arrow_forward_ios,
                          size: 14,
                          color: _menuPal.trailingChevron,
                        ),
                        onTap: () async {
                          await _showReciterPicker(ctx);
                          bump();
                        },
                      ),
                      ListTile(
                        leading: Container(
                          width: 44,
                          height: 44,
                          decoration: BoxDecoration(
                            color: _menuPal.tileLeadingDecorationColor,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Icon(
                            Icons.highlight_alt_rounded,
                            color: _menuPal.tileLeadingIconColor,
                            size: 24,
                          ),
                        ),
                        title: Text(
                          'تضليل أثناء التلاوة',
                          style: _menuQuranStyle(
                            fontSize: 17,
                            color: _menuPal.title,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        subtitle: Text(
                          player.showAyahHighlight ? 'مُفعل' : 'غير مُفعل',
                          style: _menuQuranStyle(
                            fontSize: 13,
                            color: _menuPal.subtitle,
                            fontWeight: FontWeight.normal,
                          ),
                        ),
                        trailing: Switch.adaptive(
                          value: player.showAyahHighlight,
                          activeTrackColor: _menuPal.switchActive,
                          activeColor: _menuPal.switchActive,
                          onChanged: (v) async {
                            await player.setShowAyahHighlight(v);
                            bump();
                          },
                        ),
                      ),
                      ListTile(
                        leading: Container(
                          width: 44,
                          height: 44,
                          decoration: BoxDecoration(
                            color: _menuPal.tileLeadingDecorationColor,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Icon(
                            Icons.repeat_rounded,
                            color: _menuPal.tileLeadingIconColor,
                            size: 24,
                          ),
                        ),
                        title: Text(
                          'نمط التشغيل',
                          style: _menuQuranStyle(
                            fontSize: 17,
                            color: _menuPal.title,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        subtitle: Text(
                          _playbackModeLabel(player.playbackMode),
                          style: _menuQuranStyle(
                            fontSize: 13,
                            color: _menuPal.subtitle,
                            fontWeight: FontWeight.normal,
                          ),
                        ),
                        trailing: Icon(
                          Icons.arrow_forward_ios,
                          size: 14,
                          color: _menuPal.trailingChevron,
                        ),
                        onTap: () async {
                          final selected = await _showPlaybackModePicker(ctx);
                          if (selected != null) {
                            await _setPlaybackMode(selected);
                            bump();
                          }
                        },
                      ),
                      const SizedBox(height: 12),
                    ],
                  ),
                );
              },
            );

            return Directionality(
              textDirection: TextDirection.rtl,
              child: SafeArea(
                child: Column(
                  mainAxisSize: sidePanel ? MainAxisSize.max : MainAxisSize.min,
                  children: [
                    NestedQuranMenuAppBar(
                      title: 'إعدادات المشغل',
                      titleStyle: _menuQuranStyle(
                        fontSize: 20,
                        color: _menuPal.title,
                        fontWeight: FontWeight.bold,
                      ),
                      onBack: () => Navigator.pop(ctx),
                      onDismissAll: () => _dismissAllMenuOverlays(ctx),
                    ),
                    Divider(height: 1, color: _menuPal.divider),
                    if (sidePanel) Expanded(child: body) else body,
                  ],
                ),
              ),
            );
          },
        ),
      ),
    ).whenComplete(MushafRamIdleExpander.instance.endBlockingUi);
  }

  void _showFontScaleSheet(
    BuildContext outerContext, {
    required String title,
    required double currentScale,
    required ValueChanged<double> onScaleChanged,
  }) {
    var localScale = currentScale;
    MushafRamIdleExpander.instance.beginBlockingUi();
    showQuranMenuSidePanel<void>(
      context: outerContext,
      horizontallyRotatedReading: _isHorizontallyRotatedReading,
      isScrollControlled: true,
      backgroundColor: _menuPal.surface,
      builder: (ctx) => _wrapMainMenuFamilyOverlay(
        ctx,
        StatefulBuilder(
          builder: (ctx, setModal) {
            final bottom = MediaQuery.viewInsetsOf(ctx).bottom;
            return Padding(
              padding: EdgeInsets.fromLTRB(20, 16, 20, 16 + bottom),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    title,
                    textAlign: TextAlign.center,
                    style: _menuQuranStyle(
                      fontSize: 18,
                      color: const Color(0xFF1B5E20),
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _ltrUiPercent((localScale * 100).round()),
                    textAlign: TextAlign.center,
                    style: _menuQuranStyle(
                      fontSize: 16,
                      color: const Color(0xFF2E7D32),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  _buildFontScaleRtlSlider(
                    ctx,
                    scale: localScale,
                    onChanged: (v) {
                      localScale = v;
                      onScaleChanged(v);
                      setModal(() {});
                      _saveUiFontPrefs();
                    },
                  ),
                  Row(
                    children: [
                      TextButton(
                        onPressed: () {
                          localScale = 1.0;
                          onScaleChanged(1.0);
                          setModal(() {});
                          _saveUiFontPrefs();
                        },
                        child: Text(
                          'إعادة الافتراضي',
                          style: _menuQuranStyle(
                            fontSize: 14,
                            color: const Color(0xFF2E7D32),
                          ),
                        ),
                      ),
                      const Spacer(),
                      TextButton(
                        onPressed: () => Navigator.pop(ctx),
                        child: Text(
                          'تم',
                          style: _menuQuranStyle(
                            fontSize: 16,
                            color: const Color(0xFF2E7D32),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            );
          },
        ),
      ),
    ).whenComplete(MushafRamIdleExpander.instance.endBlockingUi);
  }

  void _showMenuFontScaleSheet(
    BuildContext outerContext, {
    VoidCallback? onLiveChanged,
  }) {
    _showFontScaleSheet(
      outerContext,
      title: 'حجم خط القوائم',
      currentScale: _menuFontScale,
      onScaleChanged: (v) {
        setState(() => _menuFontScale = v);
        onLiveChanged?.call();
      },
    );
  }

  void _showTafsirFontScaleSheet(
    BuildContext outerContext, {
    VoidCallback? onLiveChanged,
  }) {
    _showFontScaleSheet(
      outerContext,
      title: 'حجم خط التفسير',
      currentScale: _tafsirFontScale,
      onScaleChanged: (v) {
        setState(() => _tafsirFontScale = v);
        onLiveChanged?.call();
      },
    );
  }

  void _showArabicFontPickerSheet(
    BuildContext outerContext, {
    VoidCallback? onApplied,
  }) {
    var localId = _arabicUiFontId;
    MushafRamIdleExpander.instance.beginBlockingUi();
    showQuranMenuSidePanel<void>(
      context: outerContext,
      horizontallyRotatedReading: _isHorizontallyRotatedReading,
      isScrollControlled: true,
      backgroundColor: _menuPal.surface,
      builder: (ctx) => _wrapMainMenuFamilyOverlay(
        ctx,
        Directionality(
          textDirection: TextDirection.rtl,
          child: SafeArea(
            child: StatefulBuilder(
              builder: (ctx, setModal) {
                final bottom = MediaQuery.viewInsetsOf(ctx).bottom;
                final choices = _kArabicUiFontChoices;
                return SizedBox(
                  height: MediaQuery.sizeOf(ctx).height * 0.9,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      NestedQuranMenuAppBar(
                        title: 'اختيار الخط',
                        titleStyle: _menuQuranStyle(
                          fontSize: 20,
                          color: _menuPal.title,
                          fontWeight: FontWeight.bold,
                        ),
                        onBack: () => Navigator.pop(ctx),
                        onDismissAll: () => _dismissAllMenuOverlays(ctx),
                      ),
                      Divider(height: 1, color: _menuPal.divider),
                      Expanded(
                        child: ListView.separated(
                          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                          itemCount: choices.length,
                          separatorBuilder: (_, __) =>
                              const SizedBox(height: 16),
                          itemBuilder: (_, i) {
                            final c = choices[i];
                            final selected = localId == c.id;
                            return InkWell(
                              onTap: () {
                                localId = c.id;
                                setModal(() {});
                              },
                              borderRadius: BorderRadius.circular(12),
                              child: Container(
                                padding: const EdgeInsets.all(16),
                                decoration: BoxDecoration(
                                  color: _menuPal.cardSurface,
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(
                                    color: selected
                                        ? _menuPal.accent
                                        : _menuPal.divider,
                                    width: selected ? 2 : 1,
                                  ),
                                  boxShadow: [
                                    BoxShadow(
                                      color:
                                          Colors.black.withValues(alpha: 0.05),
                                      blurRadius: 4,
                                      offset: const Offset(0, 2),
                                    ),
                                  ],
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        Expanded(
                                          child: Text(
                                            'خط ${_toNormalDigits(i + 1)}',
                                            style: _menuQuranStyle(
                                              fontSize: 18,
                                              color: _menuPal.title,
                                              fontWeight: FontWeight.bold,
                                            ),
                                          ),
                                        ),
                                        if (selected)
                                          Icon(
                                            Icons.check_circle_rounded,
                                            color: _menuPal.accent,
                                            size: 26,
                                          )
                                        else
                                          Icon(
                                            Icons.arrow_forward_ios,
                                            size: 16,
                                            color: _menuPal.trailingChevron,
                                          ),
                                      ],
                                    ),
                                    const SizedBox(height: 10),
                                    Text(
                                      _kArabicUiFontPreviewPhrase,
                                      style: TextStyle(
                                        fontFamily: c.fontFamily,
                                        fontSize: 17,
                                        height: 1.5,
                                        color: _menuPal.title,
                                        fontWeight: FontWeight.w500,
                                      ),
                                      textDirection: TextDirection.rtl,
                                    ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                      Padding(
                        padding: EdgeInsets.fromLTRB(16, 8, 16, 16 + bottom),
                        child: Row(
                          children: [
                            TextButton(
                              onPressed: () {
                                localId = _kArabicUiFontIdUthmani;
                                setModal(() {});
                              },
                              child: Text(
                                'الافتراضي',
                                style: _menuQuranStyle(
                                  fontSize: 14,
                                  color: _menuPal.accent,
                                ),
                              ),
                            ),
                            const Spacer(),
                            TextButton(
                              onPressed: () => Navigator.pop(ctx),
                              child: Text(
                                'إلغاء',
                                style: _menuQuranStyle(
                                  fontSize: 14,
                                  color: _menuPal.subtitle,
                                ),
                              ),
                            ),
                            TextButton(
                              onPressed: () {
                                setState(() => _arabicUiFontId = localId);
                                _saveUiFontPrefs();
                                onApplied?.call();
                                Navigator.pop(ctx);
                              },
                              child: Text(
                                'تطبيق',
                                style: _menuQuranStyle(
                                  fontSize: 16,
                                  color: _menuPal.accent,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ),
      ),
    ).whenComplete(MushafRamIdleExpander.instance.endBlockingUi);
  }

  void _showMushafStyleSheet(BuildContext context) {
    Color selectedBg = _mushafBackgroundColor;
    MushafRamIdleExpander.instance.beginBlockingUi();
    showQuranMenuSidePanel<void>(
      context: context,
      horizontallyRotatedReading: _isHorizontallyRotatedReading,
      backgroundColor: _menuPal.surfaceAlt,
      builder: (ctx) => _wrapMainMenuFamilyOverlay(
        ctx,
        StatefulBuilder(
          builder: (context, setSheetState) {
            final sidePanel = _isHorizontallyRotatedReading ||
                MediaQuery.orientationOf(context) == Orientation.landscape;
            return Directionality(
              textDirection: TextDirection.rtl,
              child: SafeArea(
                child: Column(
                  mainAxisSize: sidePanel ? MainAxisSize.max : MainAxisSize.min,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(8, 12, 8, 8),
                      child: Row(
                        children: [
                          IconButton(
                            icon: Icon(Icons.arrow_back, color: _menuPal.title),
                            onPressed: () => Navigator.pop(ctx),
                            tooltip: 'رجوع',
                          ),
                          Expanded(
                            child: Center(
                              child: Text(
                                'شكل المصحف',
                                style: _menuQuranStyle(
                                  fontSize: 18,
                                  color: _menuPal.title,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 48),
                        ],
                      ),
                    ),
                    Divider(height: 1, color: _menuPal.divider),
                    sidePanel
                        ? Expanded(
                            child: SingleChildScrollView(
                              padding: const EdgeInsets.symmetric(
                                  vertical: 12, horizontal: 8),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  Padding(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 8),
                                    child: Text(
                                      'ألوان الخلفية',
                                      style: _menuQuranStyle(
                                        fontSize: 14,
                                        color: _menuPal.title,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  Row(
                                    children: [
                                      Expanded(
                                        child: _backgroundColorChip(
                                          label: 'أبيض',
                                          color: _bgWhite,
                                          isSelected: selectedBg == _bgWhite,
                                          onTap: () {
                                            setSheetState(() {
                                              selectedBg = _bgWhite;
                                            });
                                          },
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: _backgroundColorChip(
                                          label: 'بيجي',
                                          color: _bgBeige,
                                          isSelected: selectedBg == _bgBeige,
                                          onTap: () {
                                            setSheetState(() {
                                              selectedBg = _bgBeige;
                                            });
                                          },
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: _backgroundColorChip(
                                          label: 'أسود',
                                          color: _bgBlack,
                                          isSelected: selectedBg == _bgBlack,
                                          onTap: () {
                                            setSheetState(() {
                                              selectedBg = _bgBlack;
                                            });
                                          },
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 14),
                                  Padding(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 8),
                                    child: Text(
                                      'أنواع المصاحف',
                                      style: _menuQuranStyle(
                                        fontSize: 14,
                                        color: _menuPal.title,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  _mushafSection(
                                    ctx,
                                    selectedBg,
                                    _mushafOptionsForBackground(selectedBg),
                                  ),
                                ],
                              ),
                            ),
                          )
                        : Flexible(
                            child: SingleChildScrollView(
                              padding: const EdgeInsets.symmetric(
                                  vertical: 12, horizontal: 8),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  Padding(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 8),
                                    child: Text(
                                      'ألوان الخلفية',
                                      style: _menuQuranStyle(
                                        fontSize: 14,
                                        color: _menuPal.title,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  Row(
                                    children: [
                                      Expanded(
                                        child: _backgroundColorChip(
                                          label: 'أبيض',
                                          color: _bgWhite,
                                          isSelected: selectedBg == _bgWhite,
                                          onTap: () {
                                            setSheetState(() {
                                              selectedBg = _bgWhite;
                                            });
                                          },
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: _backgroundColorChip(
                                          label: 'بيجي',
                                          color: _bgBeige,
                                          isSelected: selectedBg == _bgBeige,
                                          onTap: () {
                                            setSheetState(() {
                                              selectedBg = _bgBeige;
                                            });
                                          },
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: _backgroundColorChip(
                                          label: 'أسود',
                                          color: _bgBlack,
                                          isSelected: selectedBg == _bgBlack,
                                          onTap: () {
                                            setSheetState(() {
                                              selectedBg = _bgBlack;
                                            });
                                          },
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 14),
                                  Padding(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 8),
                                    child: Text(
                                      'أنواع المصاحف',
                                      style: _menuQuranStyle(
                                        fontSize: 14,
                                        color: _menuPal.title,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  _mushafSection(
                                    ctx,
                                    selectedBg,
                                    _mushafOptionsForBackground(selectedBg),
                                  ),
                                ],
                              ),
                            ),
                          ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    ).whenComplete(MushafRamIdleExpander.instance.endBlockingUi);
  }

  /// آية المزمل:٤ كما في المصحف (من quran.json) مع علامتها ٤
  static const String _mushafPreviewAyah73_4 =
      'أَوۡ زِدۡ عَلَيۡهِ وَرَتِّلِ ٱلۡقُرۡءَانَ تَرۡتِيلًا ٤';

  Widget _mushafSection(
    BuildContext ctx,
    Color bgColor,
    List<(String label, QpcMushafMode mode)> options,
  ) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: options
            .map((option) => _mushafStyleTile(
                  ctx,
                  option.$1,
                  option.$2,
                  bgColor,
                ))
            .toList(),
      ),
    );
  }

  List<(String label, QpcMushafMode mode)> _mushafOptionsForBackground(
      Color bgColor) {
    if (bgColor == _bgBlack) {
      return const [
        ('مصحف المدينة 1439 هـ', QpcMushafMode.qpc4Black),
        ('مصحف المدينة 1405 هـ', QpcMushafMode.qpc1),
      ];
    }
    return const [
      ('مصحف المدينة 1439 هـ', QpcMushafMode.qpc4Black),
      ('مصحف المدينة 1405 هـ', QpcMushafMode.qpc1),
      ('مصحف المدينة 1439 هـ تجويد', QpcMushafMode.qpc4),
    ];
  }

  Widget _backgroundColorChip({
    required String label,
    required Color color,
    required bool isSelected,
    required VoidCallback onTap,
  }) {
    final borderColor = isSelected ? _menuPal.accent : const Color(0xFFBDBDBD);
    // اسم اللون يظهر أسفل الشريحة على خلفية فاتحة، لذا نستخدم لوناً داكناً ثابتاً
    // حتى يبقى "أسود" واضحاً مثل بقية الألوان.
    final textColor = const Color(0xFF1B5E20);
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 6),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.65),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: borderColor, width: isSelected ? 2 : 1),
        ),
        child: Column(
          children: [
            Container(
              height: 24,
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: color == _bgWhite
                      ? const Color(0xFFBDBDBD)
                      : Colors.transparent,
                ),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              label,
              style: _menuQuranStyle(
                fontSize: 12,
                color: textColor,
                fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }

  static const int _previewPage = 569;
  static final Map<QpcMushafMode, MushafPageLine?> _previewLineCache = {};

  String? _mushafPreviewImageFor(Color bgColor, QpcMushafMode mode) {
    if (bgColor == _bgBlack) {
      return switch (mode) {
        QpcMushafMode.qpc4Black => 'assets/icon/1439b.jpg',
        QpcMushafMode.qpc1 => 'assets/icon/1405b.jpg',
        QpcMushafMode.qpc4 => null,
      };
    }
    if (bgColor == _bgWhite) {
      return switch (mode) {
        QpcMushafMode.qpc4Black => 'assets/icon/1439wb.jpg',
        QpcMushafMode.qpc1 => 'assets/icon/1405w.jpg',
        QpcMushafMode.qpc4 => 'assets/icon/1439wtartel.jpg',
      };
    }
    return switch (mode) {
      QpcMushafMode.qpc4Black => 'assets/icon/1439sb.jpg',
      QpcMushafMode.qpc1 => 'assets/icon/1405s.jpg',
      QpcMushafMode.qpc4 => 'assets/icon/1439startel.jpg',
    };
  }

  Widget _mushafPreviewBox(Color bgColor, QpcMushafMode mode) {
    final previewImage = _mushafPreviewImageFor(bgColor, mode);
    return Container(
      width: double.infinity,
      height: 56,
      margin: const EdgeInsets.only(bottom: 6),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: _menuPal.accent, width: 0.5),
      ),
      clipBehavior: Clip.antiAlias,
      alignment: Alignment.center,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: previewImage != null
            ? Image.asset(
                previewImage,
                fit: BoxFit.contain,
                errorBuilder: (_, __, ___) => FutureBuilder<MushafPageLine?>(
                  future: _loadPreviewLineForMode(mode),
                  builder: (context, snapshot) {
                    final line = snapshot.data;
                    if (line == null) return _buildFallbackPreview(bgColor);
                    return _buildPreviewLineContent(line, mode, bgColor);
                  },
                ),
              )
            : FutureBuilder<MushafPageLine?>(
                future: _loadPreviewLineForMode(mode),
                builder: (context, snapshot) {
                  final line = snapshot.data;
                  if (line == null) return _buildFallbackPreview(bgColor);
                  return _buildPreviewLineContent(line, mode, bgColor);
                },
              ),
      ),
    );
  }

  Widget _buildFallbackPreview(Color bgColor) {
    return Text(
      _quranTextBySuraAya['73:4'] ?? _mushafPreviewAyah73_4,
      style: _menuQuranStyle(
        fontSize: 14,
        color: bgColor == _bgBlack ? Colors.white : Colors.black87,
        fontWeight: FontWeight.w600,
      ),
      textAlign: TextAlign.center,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
    );
  }

  Future<MushafPageLine?> _loadPreviewLineForMode(QpcMushafMode mode) async {
    if (_previewLineCache.containsKey(mode)) return _previewLineCache[mode];

    try {
      await QuranDb.instance.init();
      if (mode == QpcMushafMode.qpc1) {
        await loadQcfFont(_previewPage);
      } else {
        await loadQcf4Font(_previewPage);
        await QpcGlyphDb.instance.init();
      }

      List<MushafPageLine> pageLines;
      if (mode == QpcMushafMode.qpc1) {
        pageLines = await loadQpcV1Page(_previewPage);
      } else {
        pageLines = await QpcV4Renderer.instance.loadPage(_previewPage);
      }

      int? minR, maxR;
      for (final line in pageLines) {
        if (line.lineType != 'ayah' ||
            line.rangeStart == null ||
            line.rangeEnd == null) continue;
        final rs = line.rangeStart!;
        final re = line.rangeEnd!;
        minR = minR == null ? rs : (rs < minR ? rs : minR);
        maxR = maxR == null ? re : (re > maxR ? re : maxR);
      }
      if (minR == null || maxR == null) {
        _previewLineCache[mode] = null;
        return null;
      }

      final mapping = await QuranDb.instance.getWordToAyahMapping(minR, maxR);
      for (final line in pageLines) {
        if (line.lineType != 'ayah' ||
            line.rangeStart == null ||
            line.rangeEnd == null) continue;
        for (int id = line.rangeStart!; id <= line.rangeEnd!; id++) {
          final sa = mapping[id];
          if (sa != null && sa.$1 == 73 && sa.$2 == 4) {
            _previewLineCache[mode] = line;
            return line;
          }
        }
      }
    } catch (_) {}
    _previewLineCache[mode] = null;
    return null;
  }

  Widget _buildPreviewLineContent(
      MushafPageLine line, QpcMushafMode mode, Color bgColor) {
    const baseStyle = TextStyle(
      fontSize: 14,
      height: 1.4,
      letterSpacing: 0,
      wordSpacing: 0,
      fontFeatures: [FontFeature.disable('kern')],
    );
    final whiteOnDark = bgColor == _bgBlack &&
        (mode == QpcMushafMode.qpc1 || mode == QpcMushafMode.qpc4Black);
    final textColor = whiteOnDark ? Colors.white : Colors.black;
    final lineStyle =
        baseStyle.copyWith(fontFamily: line.fontFamily, color: textColor);

    if (mode == QpcMushafMode.qpc4Black) {
      final segments = line.ayahSegments;
      final hasMarker = segments != null &&
          segments.isNotEmpty &&
          segments.any((s) => s.isMarker);

      if (hasMarker) {
        const ayahMarkerColor = Color(0xFFB71C1C);
        return FittedBox(
          fit: BoxFit.scaleDown,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              ColorFiltered(
                colorFilter: ColorFilter.mode(textColor, BlendMode.srcIn),
                child: Text(
                  line.lineText,
                  textDirection: TextDirection.rtl,
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.visible,
                  style: lineStyle,
                ),
              ),
              Transform.translate(
                offset: const Offset(0, 3),
                child: RichText(
                  textDirection: TextDirection.rtl,
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.visible,
                  text: TextSpan(
                    style: lineStyle,
                    children: [
                      for (final seg in segments)
                        TextSpan(
                          text: seg.text,
                          style: lineStyle.copyWith(
                            color: seg.isMarker
                                ? ayahMarkerColor
                                : Colors.transparent,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      }
      return FittedBox(
        fit: BoxFit.scaleDown,
        child: ColorFiltered(
          colorFilter: ColorFilter.mode(textColor, BlendMode.srcIn),
          child: Text(
            line.lineText,
            textDirection: TextDirection.rtl,
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.visible,
            style: lineStyle,
          ),
        ),
      );
    }

    return FittedBox(
      fit: BoxFit.scaleDown,
      child: Text(
        line.lineText,
        textDirection: TextDirection.rtl,
        textAlign: TextAlign.center,
        maxLines: 1,
        overflow: TextOverflow.visible,
        style: lineStyle,
      ),
    );
  }

  Widget _mushafStyleTile(
    BuildContext ctx,
    String label,
    QpcMushafMode mode,
    Color bgColor,
  ) {
    final selected = _qpcMode == mode && _mushafBackgroundColor == bgColor;
    return InkWell(
      onTap: () {
        Navigator.pop(ctx);
        if (selected) return;
        final prevMode = _qpcMode;
        setState(() {
          _qpcMode = mode;
          _mushafBackgroundColor = bgColor;
        });
        _saveMushafStylePrefs();
        if (prevMode != mode) {
          MushafRamIdleExpander.instance.onMushafStyleModeChanged(
            pageOneBased: _currentPageIndex + 1,
            cacheMode: _mushafRamCacheModeKey(),
            fullBackgroundWarmupEnabled: _fullMushafBackgroundWarmup,
          );
        }
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
          children: [
            Icon(
              selected ? Icons.radio_button_checked : Icons.radio_button_off,
              color: _menuPal.accent,
              size: 24,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  _mushafPreviewBox(bgColor, mode),
                  Text(
                    label,
                    style: _menuQuranStyle(fontSize: 14, color: _menuPal.title),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showDeveloperOptions(BuildContext context) {
    MushafRamIdleExpander.instance.beginBlockingUi();
    Navigator.of(context)
        .push(
          MaterialPageRoute<void>(
            builder: (ctx) => DeveloperOptionsScreen(currentMode: _qpcMode),
          ),
        )
        .whenComplete(MushafRamIdleExpander.instance.endBlockingUi);
  }

  Future<void> _showAboutDialog(BuildContext context) async {
    final pal = _menuPal;
    String version = '2.1.20';
    try {
      final info = await PackageInfo.fromPlatform();
      if (context.mounted) version = info.version;
    } catch (_) {}
    if (!context.mounted) return;
    MushafRamIdleExpander.instance.beginBlockingUi();
    showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          backgroundColor: pal.surface,
          insetPadding:
              const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          titlePadding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
          contentPadding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
          title: Text(
            'حول التطبيق',
            textAlign: TextAlign.center,
            style: _menuQuranStyle(
              fontSize: 28,
              fontWeight: FontWeight.bold,
              color: pal.title,
            ),
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: pal.cardSurface,
                    borderRadius: BorderRadius.circular(16),
                    boxShadow: [
                      BoxShadow(
                        color: const Color(0xFF1B5E20).withValues(alpha: 0.08),
                        blurRadius: 12,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: Text(
                    'تطبيق قرآني متكامل يوفر قراءة واستماع مرن مع عدة قرّاء، تفاسير صحيحة، أذكار مع عدّاد وصوت، ونظام ذكي لتقسيم الختمة.\n\n'
                    'يدعم العرض الأفقي والعمودي مع تمرير تلقائي وتجربة استخدام مريحة.',
                    textAlign: TextAlign.center,
                    style: _menuQuranStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w500,
                      color: pal.accent,
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                Text(
                  'المطور: المهندس أحمد خليل',
                  textAlign: TextAlign.center,
                  style: _menuQuranStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                    color: pal.title,
                  ),
                ),
                const SizedBox(height: 20),
                Text(
                  'إذا كانت لديك مشاكل، يرجى التواصل معنا',
                  textAlign: TextAlign.center,
                  style: _menuQuranStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w500,
                    color: pal.subtitle,
                  ),
                ),
                const SizedBox(height: 16),
                Material(
                  color: const Color(0xFF25D366),
                  borderRadius: BorderRadius.circular(14),
                  elevation: 2,
                  shadowColor: const Color(0xFF25D366).withValues(alpha: 0.4),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(14),
                    onTap: () => _openWhatsAppChat(ctx),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        vertical: 16,
                        horizontal: 20,
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.chat_bubble_outline,
                            color: Colors.white,
                            size: 28,
                          ),
                          const SizedBox(width: 12),
                          Text(
                            'تواصل عبر واتساب',
                            style: _menuQuranStyle(
                              fontSize: 19,
                              fontWeight: FontWeight.w600,
                              color: Colors.white,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                _buildVersionWithSecret(
                  version: version,
                  onOpenDeveloper: () {
                    Navigator.pop(ctx);
                    _showDeveloperOptions(context);
                  },
                ),
              ],
            ),
          ),
          actionsPadding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(
                'إغلاق',
                style: _menuQuranStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                  color: pal.accent,
                ),
              ),
            ),
          ],
        ),
      ),
    ).whenComplete(MushafRamIdleExpander.instance.endBlockingUi);
  }

  static const String _whatsAppPhone = '+9647721801124';

  /// عرض الإصدار مع إمكانية فتح خيار المطور بالنقر 7 مرات عليه
  Widget _buildVersionWithSecret({
    required String version,
    required VoidCallback onOpenDeveloper,
  }) {
    int tapCount = 0;
    DateTime? lastTapTime;
    return StatefulBuilder(
      builder: (context, setLocalState) {
        return GestureDetector(
          onTap: () {
            final now = DateTime.now();
            if (lastTapTime != null &&
                now.difference(lastTapTime!).inMilliseconds < 250) {
              tapCount++;
            } else {
              tapCount = 1;
            }
            lastTapTime = now;
            if (tapCount >= 7) {
              tapCount = 0;
              onOpenDeveloper();
            }
          },
          child: Text(
            'الإصدار $version',
            textAlign: TextAlign.center,
            style: _menuQuranStyle(
              fontSize: 15,
              fontWeight: FontWeight.w500,
              color: Colors.grey.shade600,
            ),
          ),
        );
      },
    );
  }

  Future<void> _openWhatsAppChat(BuildContext context) async {
    final phone = _whatsAppPhone.replaceAll(RegExp(r'[^\d]'), '');
    final uri = Uri.parse('https://wa.me/$phone');
    try {
      final launched = await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );
      if (!launched && context.mounted) {
        await launchUrl(uri, mode: LaunchMode.inAppWebView);
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'لا يمكن فتح واتساب. تأكد من تثبيت التطبيق أو افتح الرابط في المتصفح.',
              style: _menuQuranStyle(fontSize: 14, color: Colors.white),
            ),
            backgroundColor: Colors.orange.shade700,
          ),
        );
      }
    }
  }

  /// أوضاع الأساس في الشريط (بدون التمرير الطويل — له زر تبديل منفصل).
  List<DisplayType> _baseDisplayTypesForSheet(BuildContext context) {
    final w = MediaQuery.sizeOf(context).width;
    final isWide = w >= _wideScreenThreshold;
    if (isWide) {
      return [DisplayType.horizontal, DisplayType.twoPage];
    }
    return [DisplayType.standard, DisplayType.horizontal];
  }

  static String _displayTypeLabel(DisplayType type) {
    return switch (type) {
      DisplayType.standard => 'عرض افتراضي',
      DisplayType.horizontal => 'عرض أفقي',
      DisplayType.twoPage => 'صفحتان',
      DisplayType.longScroll => 'تمرير عمودي',
      DisplayType.horizontalLongScroll => 'تمرير أفقي',
    };
  }

  /// أيقونات توحي بالتسمية: عرض افتراضي، عرض أفقي، صفحتان، تمرير عمودي، تمرير أفقي.
  static IconData _displayTypeIcon(DisplayType type) {
    return switch (type) {
      DisplayType.standard => Icons.article_rounded,
      DisplayType.horizontal => Icons.crop_landscape_rounded,
      DisplayType.twoPage => Icons.menu_book_rounded,
      DisplayType.longScroll => Icons.view_list_rounded,
      DisplayType.horizontalLongScroll => Icons.view_carousel_rounded,
    };
  }

  Widget _buildDisplayModeStrip(BuildContext ctx, BuildContext parentContext) {
    final pal = _menuPal;
    final types = _baseDisplayTypesForSheet(ctx);
    final isWide = MediaQuery.sizeOf(ctx).width >= _wideScreenThreshold;
    final longScrollOn = _displayType == DisplayType.longScroll ||
        _displayType == DisplayType.horizontalLongScroll;
    final selectedStripBg = pal.isDark
        ? pal.accent.withValues(alpha: 0.22)
        : const Color(0xFFC8E6C9);
    final iconCircleBg = pal.tileLeadingDecorationColor;
    final iconAndLabelColor = pal.title;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          ...types.map((DisplayType type) {
            final selected = longScrollOn
                ? _longScrollRestoreBase == type
                : _displayType == type;
            return Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Material(
                  color: selected ? selectedStripBg : Colors.transparent,
                  borderRadius: BorderRadius.circular(12),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(12),
                    onTap: () {
                      Navigator.pop(ctx);
                      setState(() => _applyBaseDisplayModeSelection(type));
                      _saveDisplayPrefs();
                    },
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            padding: const EdgeInsets.all(6),
                            decoration: BoxDecoration(
                              color: iconCircleBg,
                              shape: BoxShape.circle,
                            ),
                            child: Icon(
                              _displayTypeIcon(type),
                              size: isWide ? 24 : 22,
                              color: iconAndLabelColor,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            _displayTypeLabel(type),
                            style: _menuQuranStyle(
                              fontSize: isWide ? 15 : 13,
                              color: iconAndLabelColor,
                              fontWeight:
                                  selected ? FontWeight.bold : FontWeight.w500,
                            ),
                            textAlign: TextAlign.center,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            );
          }),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Material(
                color: longScrollOn ? selectedStripBg : Colors.transparent,
                borderRadius: BorderRadius.circular(12),
                child: InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: () {
                    Navigator.pop(ctx);
                    setState(_applyUnifiedLongScrollToggle);
                    _saveDisplayPrefs();
                  },
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          padding: const EdgeInsets.all(6),
                          decoration: BoxDecoration(
                            color: iconCircleBg,
                            shape: BoxShape.circle,
                          ),
                          child: Icon(
                            Icons.keyboard_double_arrow_down_rounded,
                            size: isWide ? 24 : 22,
                            color: iconAndLabelColor,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'التمرير الطويل',
                          style: _menuQuranStyle(
                            fontSize: isWide ? 15 : 13,
                            color: iconAndLabelColor,
                            fontWeight: longScrollOn
                                ? FontWeight.bold
                                : FontWeight.w500,
                          ),
                          textAlign: TextAlign.center,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Material(
                color: Colors.transparent,
                borderRadius: BorderRadius.circular(12),
                child: InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: () {
                    _showSettingsSheet(parentContext);
                  },
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          padding: const EdgeInsets.all(6),
                          decoration: BoxDecoration(
                            color: iconCircleBg,
                            shape: BoxShape.circle,
                          ),
                          child: Icon(
                            Icons.settings_outlined,
                            size: isWide ? 24 : 22,
                            color: iconAndLabelColor,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'الإعدادات',
                          style: _menuQuranStyle(
                            fontSize: isWide ? 15 : 13,
                            color: iconAndLabelColor,
                            fontWeight: FontWeight.w500,
                          ),
                          textAlign: TextAlign.center,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _showOptionsSheet(BuildContext context, int currentIndex) async {
    final syncedVisible = await readAyahHighlightsVisible();
    if (!mounted) return;
    if (syncedVisible != _ayahHighlightsVisible) {
      setState(() => _ayahHighlightsVisible = syncedVisible);
    }
    MushafRamIdleExpander.instance.beginBlockingUi();
    await showQuranMenuSidePanel<void>(
      context: context,
      horizontallyRotatedReading: _isHorizontallyRotatedReading,
      backgroundColor: _menuPal.surface,
      builder: (ctx) {
        final sidePanel = _isHorizontallyRotatedReading ||
            MediaQuery.orientationOf(ctx) == Orientation.landscape;
        final menuScroll = SingleChildScrollView(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Column(
                  children: [
                    _buildSearchMainMenuCard(ctx, context, currentIndex,
                        onTap: () =>
                            _showSearchDialog(context, _currentPageIndex)),
                    const SizedBox(height: 6),
                    _buildMainMenuCompactRow(
                      ctx,
                      context,
                      currentIndex,
                      items: [
                        _MainMenuCompactItem(
                          icon: Icons.list,
                          title: 'الفهرس',
                          closeMenuBeforeAction: false,
                          onTap: () => _showFihrist(context, _currentPageIndex),
                        ),
                        _MainMenuCompactItem(
                          icon: Icons.menu_book,
                          title: 'الأجزاء',
                          closeMenuBeforeAction: false,
                          onTap: () => _showAjza(context, _currentPageIndex),
                        ),
                        _MainMenuCompactItem(
                          icon: Icons.numbers,
                          title: 'الصفحات',
                          closeMenuBeforeAction: false,
                          onTap: () =>
                              _showPagesDialog(context, _currentPageIndex),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    _buildMainMenuCompactRow(
                      ctx,
                      context,
                      currentIndex,
                      items: [
                        _MainMenuCompactItem(
                          icon: Icons.bookmark_border,
                          title: 'حفظ علامة',
                          closeMenuBeforeAction: false,
                          onTap: () => _showSaveBookmarkSheet(
                              context, _currentPageIndex),
                        ),
                        _MainMenuCompactItem(
                          icon: Icons.bookmark,
                          title: 'انتقال إلى علامة',
                          closeMenuBeforeAction: false,
                          onTap: () => _showGoToBookmarkSheet(
                              context, _currentPageIndex),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    _buildMainMenuCompactRow(
                      ctx,
                      context,
                      currentIndex,
                      items: [
                        _MainMenuCompactItem(
                          icon: Icons.auto_stories_outlined,
                          title: 'أذكار وأدعية',
                          closeMenuBeforeAction: false,
                          onTap: () => _showAzkarDialog(context),
                        ),
                        _MainMenuCompactItem(
                          icon: Icons.menu_book_outlined,
                          title: 'التفسير',
                          closeMenuBeforeAction: false,
                          onTap: () => _showTafseerFromMainMenu(context),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    _buildMainMenuCompactRow(
                      ctx,
                      context,
                      currentIndex,
                      items: [
                        _MainMenuCompactItem(
                          icon: Icons.flag_outlined,
                          title: 'تقسيم ختمة',
                          closeMenuBeforeAction: false,
                          onTap: () => _showKhatmaSetupDialog(
                              context, _currentPageIndex),
                        ),
                        _MainMenuCompactItem(
                          icon: Icons.view_list_rounded,
                          title: 'جدول الختمة',
                          closeMenuBeforeAction: false,
                          onTap: () => _showKhatmaSchedule(context),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                  ],
                ),
              ),
              const SizedBox(height: 6),
              _buildSmartRecitationMainMenuItem(ctx),
              const SizedBox(height: 6),
              _buildHighlightingMenuItem(
                ctx,
                context,
                currentIndex,
                visible: _ayahHighlightsVisible,
                enabled: !_isAyahHighlightingDisabledByAudio,
                onShowIndex: () => _showAyahHighlightsIndex(context),
                onToggleVisibility: () async {
                  setState(() {
                    _ayahHighlightsVisible = !_ayahHighlightsVisible;
                  });
                  await writeAyahHighlightsVisible(_ayahHighlightsVisible);
                  _syncAyahHighlightsStore();
                },
              ),
            ],
          ),
        );
        final sheet = Directionality(
          textDirection: TextDirection.rtl,
          child: SafeArea(
            child: Column(
              mainAxisSize: sidePanel ? MainAxisSize.max : MainAxisSize.min,
              children: [
                _buildDisplayModeStrip(ctx, context),
                Divider(height: 1, color: _menuPal.divider),
                sidePanel
                    ? Expanded(child: menuScroll)
                    : Flexible(child: menuScroll),
              ],
            ),
          ),
        );
        return _wrapMainMenuFamilyOverlay(ctx, sheet);
      },
    ).whenComplete(MushafRamIdleExpander.instance.endBlockingUi);
  }

  Widget _buildSearchMainMenuCard(
    BuildContext ctx,
    BuildContext context,
    int currentIndex, {
    required VoidCallback onTap,
  }) {
    final pal = _menuPal;
    final borderC = pal.title.withValues(alpha: 0.22);
    final fillC = pal.isDark
        ? pal.accent.withValues(alpha: 0.20)
        : pal.title.withValues(alpha: 0.10);
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: fillC,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: borderC),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.search, color: pal.title, size: 22),
            const SizedBox(width: 8),
            Text(
              'بحث',
              style: _menuQuranStyle(
                fontSize: 17,
                color: pal.title,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMainMenuCompactRow(
    BuildContext ctx,
    BuildContext context,
    int currentIndex, {
    required List<_MainMenuCompactItem> items,
  }) {
    return Row(
      children: [
        for (int i = 0; i < items.length; i++) ...[
          Expanded(
            child: _buildMainMenuCompactItem(
              ctx,
              context,
              currentIndex,
              item: items[i],
            ),
          ),
          if (i < items.length - 1) const SizedBox(width: 8),
        ],
      ],
    );
  }

  Widget _buildMainMenuCompactItem(
    BuildContext ctx,
    BuildContext context,
    int currentIndex, {
    required _MainMenuCompactItem item,
  }) {
    final pal = _menuPal;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () {
        if (item.closeMenuBeforeAction) Navigator.pop(ctx);
        item.onTap();
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        decoration: BoxDecoration(
          color: pal.cardSurface,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: pal.title.withValues(alpha: 0.14)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.03),
              blurRadius: 4,
              offset: const Offset(0, 1),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(item.icon, color: pal.tileLeadingIconColor, size: 20),
            const SizedBox(height: 2),
            Text(
              item.title,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: _menuQuranStyle(
                fontSize: 14,
                color: pal.title,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSmartRecitationMainMenuItem(BuildContext menuOverlayContext) {
    final pal = _menuPal;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Material(
        color: pal.cardSurface,
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        elevation: 1,
        shadowColor: Colors.black.withValues(alpha: 0.06),
        child: InkWell(
          onTap: () => _openRecitationScreen(menuOverlayContext),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: pal.accent.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(
                    Icons.mic_external_on_rounded,
                    color: pal.accent,
                    size: 22,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'التسميع الذكي',
                        style: _menuQuranStyle(
                          fontSize: 17,
                          color: pal.title,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'ابدأ التسميع من الصفحة الحالية مع متابعة الكلمات',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: _menuQuranStyle(
                          fontSize: 13,
                          color: pal.subtitle,
                          fontWeight: FontWeight.normal,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(
                  Icons.arrow_forward_ios,
                  size: 16,
                  color: pal.trailingChevron,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHighlightingMenuItem(
    BuildContext ctx,
    BuildContext context,
    int currentIndex, {
    required bool visible,
    required bool enabled,
    required VoidCallback onShowIndex,
    required VoidCallback onToggleVisibility,
  }) {
    return AyahHighlightsMainMenuRow(
      menuPalette: _menuPal,
      menuQuranStyle: _menuQuranStyle,
      visible: visible,
      enabled: enabled,
      onShowIndex: onShowIndex,
      onToggleVisibility: onToggleVisibility,
    );
  }

  /// فهرس نطاقات تأشير الآيات المحفوظة — نفس لوحة [showAyahHighlightsIndexPanel].
  void _showAyahHighlightsIndex(BuildContext context) {
    unawaited(showAyahHighlightsIndexPanel(
      context,
      menuDarkMode: _menuDarkMode,
      horizontallyRotatedReading: _isHorizontallyRotatedReading,
      menuQuranStyle: _menuQuranStyle,
      toNormalDigits: _toNormalDigits,
      suraNameFromNo: _suraNameFromNo,
      onDismissAllMenus: (ctx) => _dismissAllMenuOverlays(ctx),
      onJumpToMushafPage: (page) => _navigateToPage(page),
      onEditHighlight: (c, e) => _showAyahHighlightSheet(c, editing: e),
      onHighlightsListMutated: () async {
        final list = await readAyahHighlightRanges();
        if (!mounted) return;
        setState(() {
          _ayahHighlights
            ..clear()
            ..addAll(list);
        });
        _syncAyahHighlightsStore();
      },
    ));
  }

  void _showSaveBookmarkSheet(BuildContext context, int currentIndex) {
    final currentPage = currentIndex + 1;
    final pal = _menuPal;
    final textStyle = _menuQuranStyle(fontSize: 16, color: pal.title);
    final subtitleStyle = _menuQuranStyle(
        fontSize: 12, color: pal.subtitle, fontWeight: FontWeight.normal);

    MushafRamIdleExpander.instance.beginBlockingUi();
    showQuranMenuSidePanel<void>(
      context: context,
      horizontallyRotatedReading: _isHorizontallyRotatedReading,
      isScrollControlled: true,
      backgroundColor: _menuPal.surface,
      builder: (ctx) => _wrapMainMenuFamilyOverlay(
        ctx,
        Directionality(
          textDirection: TextDirection.rtl,
          child: SafeArea(
            child: SizedBox(
              height: MediaQuery.of(ctx).size.height * 0.5,
              child: Column(
                children: [
                  NestedQuranMenuAppBar(
                    title: 'حفظ العلامة',
                    titleStyle: _menuQuranStyle(
                        fontSize: 18,
                        color: pal.title,
                        fontWeight: FontWeight.w700),
                    onBack: () => Navigator.pop(ctx),
                    onDismissAll: () => _dismissAllMenuOverlays(ctx),
                  ),
                  Divider(height: 1, color: pal.divider),
                  Expanded(
                    child: ListView(
                      padding: const EdgeInsets.symmetric(
                          vertical: 16, horizontal: 12),
                      children: [
                        const SizedBox(height: 8),
                        ListTile(
                          trailing: Icon(
                            Icons.bookmark,
                            color: _mainBookmarkPage == currentPage
                                ? pal.accent
                                : pal.accent.withValues(alpha: 0.65),
                          ),
                          title: Text('العلامة الرئيسية', style: textStyle),
                          subtitle: Text(
                            _mainBookmarkPage != null
                                ? 'ص $_mainBookmarkPage'
                                : 'غير معينة — اضغط لتعيين الصفحة الحالية',
                            style: subtitleStyle,
                          ),
                          onTap: () {
                            setState(() => _mainBookmarkPage = currentPage);
                            _saveBookmarks();
                            Navigator.pop(ctx);
                          },
                        ),
                        ListTile(
                          trailing: Icon(
                            Icons.bookmark,
                            color: _khatmaBookmarkPage == currentPage
                                ? _khatmaBookmarkColor
                                : _khatmaBookmarkColor.withValues(alpha: 0.85),
                          ),
                          title: Text('علامة الختمة', style: textStyle),
                          subtitle: Text(
                            _khatmaBookmarkPage != null
                                ? 'ص $_khatmaBookmarkPage'
                                : 'غير معينة — اضغط لتعيين الصفحة الحالية للختمة',
                            style: subtitleStyle,
                          ),
                          onTap: () {
                            setState(() {
                              _khatmaBookmarkPage = currentPage;
                              // تحديث الجدول بناءً على علامة الختمة الجديدة
                              if (_khatmaPlan.isNotEmpty) {
                                _recalculateKhatmaPlan();
                              }
                            });
                            _saveBookmarks();
                            Navigator.pop(ctx);
                          },
                        ),
                        Divider(height: 1, color: pal.divider),
                        Text('العلامات المحفوظة',
                            style: _menuQuranStyle(
                                fontSize: 14,
                                color: pal.accent,
                                fontWeight: FontWeight.w600)),
                        ..._savedBookmarks.map(
                          (b) => ListTile(
                            leading: Icon(
                              Icons.bookmark,
                              color: b.color,
                              size: 26,
                            ),
                            title: Text('${b.name} — ص ${b.page}',
                                style: textStyle),
                            onTap: () {
                              _dismissAllMenuOverlays(ctx);
                              _navigateToPage(b.page);
                            },
                          ),
                        ),
                        const SizedBox(height: 8),
                        ListTile(
                          trailing:
                              Icon(Icons.add_circle_outline, color: pal.accent),
                          title: Text('إضافة علامة جديدة', style: textStyle),
                          subtitle: Text(
                            'حفظ الصفحة الحالية (ص $currentPage) باسم',
                            style: subtitleStyle,
                          ),
                          onTap: () {
                            Navigator.pop(ctx);
                            _showAddBookmarkDialog(context, currentPage);
                          },
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ).whenComplete(MushafRamIdleExpander.instance.endBlockingUi);
  }

  void _showKhatmaSchedule(BuildContext context) {
    if (_khatmaPlan.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'لا توجد خطة ختمة محفوظة',
            style: _menuQuranStyle(
                fontSize: 14,
                color: Colors.white,
                fontWeight: FontWeight.normal),
          ),
        ),
      );
      return;
    }

    // تجميع الجلسات حسب اليوم
    final daysMap = <int,
        List<
            ({
              int dayIndex,
              int sessionIndex,
              int globalIndex,
              int startPage,
              int endPage,
              String timeOfDay,
              bool completed,
            })>>{};
    for (var session in _khatmaPlan) {
      daysMap.putIfAbsent(session.dayIndex, () => []).add(session);
    }

    MushafRamIdleExpander.instance.beginBlockingUi();
    showQuranMenuSidePanel<void>(
      context: context,
      horizontallyRotatedReading: _isHorizontallyRotatedReading,
      isScrollControlled: true,
      backgroundColor: _menuPal.surface,
      builder: (ctx) => _wrapMainMenuFamilyOverlay(
        ctx,
        Directionality(
          textDirection: TextDirection.rtl,
          child: SizedBox(
            height: MediaQuery.of(ctx).size.height * 0.85,
            child: Column(
              children: [
                NestedQuranMenuAppBar(
                  title: 'جدول الختمة',
                  titleStyle: _menuQuranStyle(
                      fontSize: 18,
                      color: _menuPal.title,
                      fontWeight: FontWeight.bold),
                  onBack: () => Navigator.pop(ctx),
                  onDismissAll: () => _dismissAllMenuOverlays(ctx),
                ),
                Expanded(
                  child: ListView.separated(
                    padding: const EdgeInsets.all(8),
                    itemCount: daysMap.length,
                    separatorBuilder: (_, __) =>
                        Divider(height: 1, color: _menuPal.divider),
                    itemBuilder: (_, dayIdx) {
                      final pal = _menuPal;
                      final day = daysMap.keys.toList()..sort();
                      final dayNumber = day[dayIdx];
                      final sessions = daysMap[dayNumber]!
                        ..sort(
                            (a, b) => a.sessionIndex.compareTo(b.sessionIndex));
                      final isAnyCompleted = sessions.any((s) => s.completed);
                      final allCompleted = sessions.every((s) => s.completed);
                      final expansionBg = allCompleted
                          ? (pal.isDark
                              ? pal.accent.withValues(alpha: 0.28)
                              : const Color(0xFFC8E6C9))
                          : isAnyCompleted
                              ? (pal.isDark
                                  ? pal.accent.withValues(alpha: 0.14)
                                  : const Color(0xFFE8F5E9))
                              : (pal.isDark ? pal.cardSurface : Colors.white);

                      return ExpansionTile(
                        initiallyExpanded: dayIdx == 0,
                        backgroundColor: expansionBg,
                        collapsedBackgroundColor: expansionBg,
                        title: Row(
                          children: [
                            Text(
                              'اليوم ${dayNumber + 1}',
                              style: _menuQuranStyle(
                                  fontSize: 18,
                                  color: pal.title,
                                  fontWeight: FontWeight.bold),
                            ),
                            const SizedBox(width: 8),
                            if (allCompleted)
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 8, vertical: 4),
                                decoration: BoxDecoration(
                                  color: pal.accent,
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Text(
                                  'مكتمل',
                                  style: _menuQuranStyle(
                                      fontSize: 12,
                                      color: Colors.white,
                                      fontWeight: FontWeight.bold),
                                ),
                              ),
                          ],
                        ),
                        children: sessions.map((session) {
                          final len = session.endPage - session.startPage + 1;
                          final bookmark = _khatmaBookmarkPage;
                          double progress;
                          if (session.completed) {
                            progress = 1.0;
                          } else if (bookmark == null) {
                            progress = 0.0;
                          } else if (bookmark <= session.startPage) {
                            progress = 0.0;
                          } else if (bookmark > session.endPage) {
                            progress = 1.0;
                          } else {
                            // علامة الختمة تشير عادةً للصفحة التالية بعد آخر صفحة تمت قراءتها.
                            final readPages =
                                (bookmark - session.startPage).clamp(0, len);
                            progress = len > 0 ? (readPages / len) : 0.0;
                          }

                          return Column(
                            children: [
                              ListTile(
                                dense: true,
                                leading: Container(
                                  width: 32,
                                  height: 32,
                                  decoration: BoxDecoration(
                                    color: session.completed
                                        ? pal.accent
                                        : pal.subtitle.withValues(alpha: 0.35),
                                    shape: BoxShape.circle,
                                  ),
                                  child: Center(
                                    child: session.completed
                                        ? const Icon(Icons.check,
                                            color: Colors.white, size: 20)
                                        : Text(
                                            '${session.sessionIndex + 1}',
                                            style: _menuQuranStyle(
                                                fontSize: 14,
                                                color: pal.title,
                                                fontWeight: FontWeight.bold),
                                          ),
                                  ),
                                ),
                                title: Text(
                                  session.timeOfDay,
                                  style: _menuQuranStyle(
                                      fontSize: 16,
                                      color: pal.title,
                                      fontWeight: FontWeight.w600),
                                ),
                                subtitle: Text(
                                  'صفحات ${session.startPage} - ${session.endPage} '
                                  '($len صفحة)',
                                  style: _menuQuranStyle(
                                      fontSize: 13,
                                      color: pal.subtitle,
                                      fontWeight: FontWeight.normal),
                                ),
                                trailing: session.completed
                                    ? Icon(Icons.check_circle,
                                        color: pal.accent)
                                    : IconButton(
                                        icon: Icon(Icons.radio_button_unchecked,
                                            color: pal.trailingChevron),
                                        onPressed: () {
                                          // تحديث حالة الجلسة كمكتملة
                                          setState(() {
                                            final idx = _khatmaPlan.indexWhere(
                                                (s) =>
                                                    s.globalIndex ==
                                                    session.globalIndex);
                                            if (idx != -1) {
                                              _khatmaPlan[idx] = (
                                                dayIndex: session.dayIndex,
                                                sessionIndex:
                                                    session.sessionIndex,
                                                globalIndex:
                                                    session.globalIndex,
                                                startPage: session.startPage,
                                                endPage: session.endPage,
                                                timeOfDay: session.timeOfDay,
                                                completed: true,
                                              );
                                              // تحديث علامة الختمة إلى نهاية هذه الجلسة
                                              _khatmaBookmarkPage =
                                                  session.endPage + 1;
                                              if (_khatmaBookmarkPage! >
                                                  totalPages) {
                                                _khatmaBookmarkPage =
                                                    totalPages;
                                              }
                                              _saveBookmarks();
                                              // إعادة حساب الجدول
                                              _recalculateKhatmaPlan();
                                              _saveBookmarks();
                                            }
                                          });
                                          Navigator.pop(ctx);
                                          _showKhatmaSchedule(context);
                                        },
                                      ),
                                onTap: () {
                                  // الانتقال إلى صفحة بداية الجلسة
                                  Navigator.pop(ctx);
                                  _navigateToPage(session.startPage);
                                },
                              ),
                              Padding(
                                padding: const EdgeInsetsDirectional.only(
                                    start: 72, end: 16, bottom: 8),
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: ClipRRect(
                                        borderRadius:
                                            BorderRadius.circular(999),
                                        child: LinearProgressIndicator(
                                          minHeight: 4,
                                          value: progress.clamp(0.0, 1.0),
                                          backgroundColor: pal.subtitle
                                              .withValues(alpha: 0.22),
                                          valueColor:
                                              AlwaysStoppedAnimation<Color>(
                                            session.completed
                                                ? pal.accent
                                                : const Color(0xFF1E88E5),
                                          ),
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 10),
                                    Text(
                                      '${_toNormalDigits((progress * 100).round().clamp(0, 100))}%',
                                      textDirection: TextDirection.ltr,
                                      style: _menuQuranStyle(
                                        fontSize: 12,
                                        color: pal.subtitle,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          );
                        }).toList(),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ).whenComplete(MushafRamIdleExpander.instance.endBlockingUi);
  }

  void _showAddBookmarkDialog(BuildContext context, int currentPage) {
    final nameController = TextEditingController();
    Color selected = _mainBookmarkColor;
    MushafRamIdleExpander.instance.beginBlockingUi();
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (dialogContext, setDialogState) {
          final palette = <Color>[
            _mainBookmarkColor,
            _khatmaBookmarkColor,
            const Color(0xFFFFB300), // برتقالي/كهرماني
            const Color(0xFFE53935), // أحمر
            const Color(0xFF8E24AA), // بنفسجي
            const Color(0xFF00897B), // تركواز
            const Color(0xFFF4511E), // برتقالي غامق
            const Color(0xFF1BD8C8), //
            const Color(0xFF5E35B1), // بنفسجي غامق
            const Color(0xFF795548), // بني
          ];
          final pal = _menuPal;
          return _wrapMainMenuFamilyOverlay(
            ctx,
            Directionality(
              textDirection: TextDirection.rtl,
              child: AlertDialog(
                backgroundColor: pal.surface,
                surfaceTintColor: Colors.transparent,
                title: Text('إضافة علامة جديدة',
                    style: _menuQuranStyle(fontSize: 18, color: pal.title)),
                content: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: nameController,
                      decoration: _menuDialogInputDecoration(
                        pal,
                        hintText: 'اسم العلامة (مثلاً: آخر قراءة)',
                      ),
                      style: _menuQuranStyle(
                          fontSize: 16, color: pal.searchFieldText),
                      autofocus: true,
                    ),
                    const SizedBox(height: 12),
                    Align(
                      alignment: Alignment.centerRight,
                      child: Text(
                        'لون العلامة',
                        style: _menuQuranStyle(
                          fontSize: 14,
                          color: pal.title,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 10,
                      runSpacing: 10,
                      children: [
                        for (final c in palette)
                          InkWell(
                            onTap: () => setDialogState(() => selected = c),
                            borderRadius: BorderRadius.circular(8),
                            child: Container(
                              width: 36,
                              height: 36,
                              padding: const EdgeInsets.all(4),
                              decoration: BoxDecoration(
                                border: Border.all(
                                  color:
                                      selected == c ? pal.accent : pal.divider,
                                  width: selected == c ? 2 : 1,
                                ),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Icon(Icons.bookmark, color: c, size: 24),
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: Text('إلغاء',
                        style:
                            _menuQuranStyle(fontSize: 14, color: pal.accent)),
                  ),
                  FilledButton(
                    style: FilledButton.styleFrom(backgroundColor: pal.accent),
                    onPressed: () {
                      final name = nameController.text.trim().isEmpty
                          ? 'علامة ص $currentPage'
                          : nameController.text.trim();
                      setState(() {
                        _savedBookmarks = [
                          ..._savedBookmarks,
                          (name: name, page: currentPage, color: selected)
                        ];
                      });
                      _saveBookmarks();
                      Navigator.pop(ctx);
                    },
                    child: Text('حفظ',
                        style:
                            _menuQuranStyle(fontSize: 14, color: Colors.white)),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    ).whenComplete(MushafRamIdleExpander.instance.endBlockingUi);
  }

  void _showKhatmaSetupDialog(BuildContext context, int currentIndex) {
    final currentPage = currentIndex + 1;
    final daysController = TextEditingController(text: '30');
    final sessionsController = TextEditingController(text: '1');
    final sessionTimeControllers = <TextEditingController>[
      TextEditingController(text: 'الفجر'),
    ];

    MushafRamIdleExpander.instance.beginBlockingUi();
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (dialogContext, setDialogState) {
          final pal = _menuPal;
          void disposeKhatmaFields() {
            for (var c in sessionTimeControllers) {
              c.dispose();
            }
          }

          return _wrapMainMenuFamilyOverlay(
            ctx,
            Directionality(
              textDirection: TextDirection.rtl,
              child: AlertDialog(
                backgroundColor: pal.surface,
                surfaceTintColor: Colors.transparent,
                titlePadding: EdgeInsets.zero,
                title: NestedQuranMenuAppBar(
                  title: 'تقسيم ختمة',
                  titleStyle: _menuQuranStyle(fontSize: 18, color: pal.title),
                  onBack: () {
                    disposeKhatmaFields();
                    Navigator.pop(ctx);
                  },
                  onDismissAll: () {
                    disposeKhatmaFields();
                    _dismissAllMenuOverlays(ctx);
                  },
                ),
                content: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        'سيتم تقسيم الختمة من الصفحة الأولى دائماً. حدد عدد الأيام وعدد القراءات في اليوم. '
                        'سيتم استخدام علامة الختمة لتتبع آخر صفحة وصلت إليها.',
                        style: _menuQuranStyle(
                            fontSize: 12,
                            color: pal.subtitle,
                            fontWeight: FontWeight.normal),
                      ),
                      const SizedBox(height: 12),
                      Text('عدد الأيام للختمة',
                          style: _menuQuranStyle(
                              fontSize: 14,
                              color: pal.title,
                              fontWeight: FontWeight.w600)),
                      const SizedBox(height: 4),
                      TextField(
                        controller: daysController,
                        keyboardType: TextInputType.number,
                        decoration: _menuDialogInputDecoration(pal),
                        style: _menuQuranStyle(
                            fontSize: 16, color: pal.searchFieldText),
                        onChanged: (_) => setDialogState(() {}),
                      ),
                      const SizedBox(height: 8),
                      Text('عدد القراءات في اليوم',
                          style: _menuQuranStyle(
                              fontSize: 14,
                              color: pal.title,
                              fontWeight: FontWeight.w600)),
                      const SizedBox(height: 4),
                      TextField(
                        controller: sessionsController,
                        keyboardType: TextInputType.number,
                        decoration: _menuDialogInputDecoration(pal),
                        style: _menuQuranStyle(
                            fontSize: 16, color: pal.searchFieldText),
                        onChanged: (value) {
                          final count = int.tryParse(value) ?? 1;
                          while (sessionTimeControllers.length < count) {
                            sessionTimeControllers.add(TextEditingController(
                                text:
                                    'القراءة ${sessionTimeControllers.length + 1}'));
                          }
                          while (sessionTimeControllers.length > count) {
                            sessionTimeControllers.removeLast().dispose();
                          }
                          setDialogState(() {});
                        },
                      ),
                      if (int.tryParse(sessionsController.text) != null &&
                          int.parse(sessionsController.text) > 0) ...[
                        const SizedBox(height: 12),
                        Text('أوقات القراءات',
                            style: _menuQuranStyle(
                                fontSize: 14,
                                color: pal.title,
                                fontWeight: FontWeight.w600)),
                        const SizedBox(height: 4),
                        ...List.generate(
                          int.tryParse(sessionsController.text) ?? 1,
                          (i) {
                            if (i >= sessionTimeControllers.length) {
                              sessionTimeControllers.add(TextEditingController(
                                  text: 'القراءة ${i + 1}'));
                            }
                            return Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: TextField(
                                controller: sessionTimeControllers[i],
                                decoration: _menuDialogInputDecoration(
                                  pal,
                                  labelText: 'وقت القراءة ${i + 1}',
                                  hintText: 'مثال: الفجر، الظهر، العصر...',
                                ),
                                style: _menuQuranStyle(
                                    fontSize: 16, color: pal.searchFieldText),
                              ),
                            );
                          },
                        ),
                      ],
                    ],
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: () {
                      for (var c in sessionTimeControllers) {
                        c.dispose();
                      }
                      Navigator.pop(ctx);
                    },
                    child: Text('إلغاء',
                        style:
                            _menuQuranStyle(fontSize: 14, color: pal.accent)),
                  ),
                  FilledButton(
                    style: FilledButton.styleFrom(backgroundColor: pal.accent),
                    onPressed: () {
                      final days = int.tryParse(daysController.text);
                      final sessions = int.tryParse(sessionsController.text);
                      if (days == null ||
                          days < 1 ||
                          sessions == null ||
                          sessions < 1) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(
                              'يرجى إدخال أرقام صحيحة',
                              style: _menuQuranStyle(
                                  fontSize: 14,
                                  color: Colors.white,
                                  fontWeight: FontWeight.normal),
                            ),
                          ),
                        );
                        return;
                      }

                      final sessionTimes = sessionTimeControllers
                          .map((c) => c.text.trim().isEmpty
                              ? 'القراءة ${sessionTimeControllers.indexOf(c) + 1}'
                              : c.text.trim())
                          .toList();

                      // حساب خطة الختمة (دائماً من الصفحة الأولى)
                      _calculateKhatmaPlan(
                        startPage: 1,
                        days: days,
                        sessionsPerDay: sessions,
                        sessionTimes: sessionTimes,
                      );

                      // تعيين علامة الختمة
                      setState(() => _khatmaBookmarkPage = currentPage);
                      _saveBookmarks();

                      for (var c in sessionTimeControllers) {
                        c.dispose();
                      }
                      Navigator.pop(ctx);

                      // عرض جدول الختمة
                      _showKhatmaSchedule(context);
                    },
                    child: Text('حفظ وإنشاء الجدول',
                        style:
                            _menuQuranStyle(fontSize: 14, color: Colors.white)),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    ).whenComplete(MushafRamIdleExpander.instance.endBlockingUi);
  }

  void _showGoToBookmarkSheet(BuildContext context, int currentIndex) {
    final pal = _menuPal;
    final textStyle = _menuQuranStyle(fontSize: 16, color: pal.title);

    MushafRamIdleExpander.instance.beginBlockingUi();
    showQuranMenuSidePanel<void>(
      context: context,
      horizontallyRotatedReading: _isHorizontallyRotatedReading,
      isScrollControlled: true,
      backgroundColor: _menuPal.surface,
      builder: (ctx) => _wrapMainMenuFamilyOverlay(
        ctx,
        Directionality(
          textDirection: TextDirection.rtl,
          child: StatefulBuilder(
            builder: (modalCtx, setModalState) => SafeArea(
              child: SizedBox(
                height: MediaQuery.of(ctx).size.height * 0.6,
                child: Column(
                  children: [
                    NestedQuranMenuAppBar(
                      title: 'انتقال إلى علامة',
                      titleStyle: _menuQuranStyle(
                          fontSize: 18,
                          color: pal.title,
                          fontWeight: FontWeight.w700),
                      onBack: () => Navigator.pop(ctx),
                      onDismissAll: () => _dismissAllMenuOverlays(ctx),
                    ),
                    Divider(height: 1, color: pal.divider),
                    Expanded(
                      child: ListView(
                        padding: const EdgeInsets.symmetric(
                            vertical: 16, horizontal: 12),
                        children: [
                          const SizedBox(height: 12),
                          if (_mainBookmarkPage != null)
                            ListTile(
                              trailing: Icon(Icons.bookmark,
                                  color: pal.accent, size: 22),
                              title: Text(
                                  'العلامة الرئيسية — ص $_mainBookmarkPage',
                                  style: textStyle),
                              onTap: () {
                                _dismissAllMenuOverlays(ctx);
                                _navigateToPage(_mainBookmarkPage!);
                              },
                            ),
                          if (_khatmaBookmarkPage != null)
                            ListTile(
                              trailing: const Icon(Icons.bookmark,
                                  color: Color(0xFF1565C0), size: 22),
                              title: Text(
                                  'علامة الختمة — ص $_khatmaBookmarkPage',
                                  style: textStyle),
                              onTap: () {
                                _dismissAllMenuOverlays(ctx);
                                _navigateToPage(_khatmaBookmarkPage!);
                              },
                            ),
                          ..._savedBookmarks.asMap().entries.map((entry) {
                            final index = entry.key;
                            final b = entry.value;
                            return ListTile(
                              leading: Icon(
                                Icons.bookmark,
                                color: b.color,
                                size: 26,
                              ),
                              trailing: IconButton(
                                icon: const Icon(Icons.delete_outline,
                                    color: Colors.red, size: 22),
                                onPressed: () async {
                                  final confirm = await showDialog<bool>(
                                    context: context,
                                    builder: (dialogContext) => Directionality(
                                      textDirection: TextDirection.rtl,
                                      child: AlertDialog(
                                        title: Text('تأكيد الحذف',
                                            style: _menuQuranStyle(
                                                fontSize: 18,
                                                color: pal.title)),
                                        content: Text(
                                            'هل متأكد من حذف علامة (${b.name})؟',
                                            style: _menuQuranStyle(
                                                fontSize: 14,
                                                color: pal.subtitle,
                                                fontWeight: FontWeight.normal)),
                                        actions: [
                                          TextButton(
                                            onPressed: () => Navigator.pop(
                                                dialogContext, false),
                                            child: Text('إلغاء',
                                                style: _menuQuranStyle(
                                                    fontSize: 14,
                                                    color: pal.subtitle)),
                                          ),
                                          FilledButton(
                                            style: FilledButton.styleFrom(
                                                backgroundColor: pal.accent),
                                            onPressed: () => Navigator.pop(
                                                dialogContext, true),
                                            child: Text('نعم',
                                                style: _menuQuranStyle(
                                                    fontSize: 14,
                                                    color: Colors.white)),
                                          ),
                                        ],
                                      ),
                                    ),
                                  );
                                  if (confirm == true && mounted) {
                                    setState(() {
                                      final updated = List<
                                          ({
                                            String name,
                                            int page,
                                            Color color
                                          })>.from(_savedBookmarks);
                                      if (index >= 0 &&
                                          index < updated.length) {
                                        updated.removeAt(index);
                                      }
                                      _savedBookmarks = updated;
                                    });
                                    setModalState(() {});
                                    _saveBookmarks();
                                  }
                                },
                              ),
                              title: Text('${b.name} — ص ${b.page}',
                                  style: textStyle),
                              onTap: () {
                                _dismissAllMenuOverlays(ctx);
                                _navigateToPage(b.page);
                              },
                            );
                          }),
                          if (_mainBookmarkPage == null &&
                              _savedBookmarks.isEmpty)
                            Padding(
                              padding: const EdgeInsets.all(24),
                              child: Text(
                                'لا توجد علامات محفوظة. استخدم "حفظ علامة" أولاً.',
                                style: _menuQuranStyle(
                                    fontSize: 14,
                                    color: pal.subtitle,
                                    fontWeight: FontWeight.normal),
                                textAlign: TextAlign.center,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    ).whenComplete(MushafRamIdleExpander.instance.endBlockingUi);
  }

  void _showSearchDialog(BuildContext context, int currentIndex) {
    final queryText = ValueNotifier<String>('');
    final results = ValueNotifier<
        List<
            ({
              int page,
              int suraNo,
              int ayaNo,
              String suraNameAr,
              String text
            })>>([]);

    void runSearch(String q) {
      final t = q.trim();
      if (t.isEmpty) {
        results.value = [];
        return;
      }
      final normalizedQuery = _normalizeForSearch(t);
      results.value = _ayahList
          .where((a) => _normalizeForSearch(a.text).contains(normalizedQuery))
          .take(200)
          .toList();
    }

    MushafRamIdleExpander.instance.beginBlockingUi();
    showDialog(
      context: context,
      builder: (ctx) => _wrapSearchDialogOverlay(
        ctx,
        Directionality(
          textDirection: TextDirection.rtl,
          child: AlertDialog(
            contentPadding: EdgeInsets.zero,
            insetPadding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 24),
            titlePadding: EdgeInsets.zero,
            title: NestedQuranMenuAppBar(
              title: 'بحث في الآيات',
              titleStyle:
                  _menuQuranStyle(fontSize: 20, color: const Color(0xFF1B5E20)),
              onBack: () {
                FocusManager.instance.primaryFocus?.unfocus();
                Navigator.of(ctx).maybePop();
              },
              onDismissAll: () {
                FocusManager.instance.primaryFocus?.unfocus();
                Navigator.of(ctx).maybePop();
              },
            ),
            content: SizedBox(
              width: double.maxFinite,
              height: MediaQuery.of(ctx).size.height * 0.8,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: TextField(
                      style: _menuQuranStyle(
                          fontSize: 18,
                          color: Colors.black87,
                          fontWeight: FontWeight.normal),
                      decoration: InputDecoration(
                        hintText: 'اكتب جزءاً من الآية...',
                        hintStyle: _menuQuranStyle(
                            fontSize: 16,
                            color: Colors.grey,
                            fontWeight: FontWeight.normal),
                        border: const OutlineInputBorder(),
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 12),
                      ),
                      onChanged: (value) {
                        queryText.value = value;
                        runSearch(value);
                      },
                      autofocus: true,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Expanded(
                    child: ValueListenableBuilder<String>(
                      valueListenable: queryText,
                      builder: (_, query, __) => ValueListenableBuilder<
                          List<
                              ({
                                int page,
                                int suraNo,
                                int ayaNo,
                                String suraNameAr,
                                String text
                              })>>(
                        valueListenable: results,
                        builder: (_, list, __) {
                          if (list.isEmpty && query.trim().isEmpty) {
                            return Center(
                              child: Text('اكتب نص الآية للبحث في الملف',
                                  style: _menuQuranStyle(
                                      fontSize: 16,
                                      color: Colors.grey,
                                      fontWeight: FontWeight.normal)),
                            );
                          }
                          if (list.isEmpty) {
                            return Center(
                              child: Text('لا توجد نتائج',
                                  style: _menuQuranStyle(
                                      fontSize: 16,
                                      color: Colors.grey,
                                      fontWeight: FontWeight.normal)),
                            );
                          }
                          return ListView.builder(
                            padding: const EdgeInsets.symmetric(horizontal: 4),
                            itemCount: list.length,
                            itemBuilder: (_, i) {
                              final a = list[i];
                              final snippet = a.text.length > 80
                                  ? '${a.text.substring(0, 80)}...'
                                  : a.text;
                              return ListTile(
                                dense: false,
                                contentPadding: const EdgeInsets.symmetric(
                                    horizontal: 8, vertical: 6),
                                title: Text(snippet,
                                    style: _menuQuranStyle(
                                        fontSize: 18,
                                        color: const Color(0xFF1B5E20),
                                        fontWeight: FontWeight.normal)),
                                subtitle: Padding(
                                  padding: const EdgeInsets.only(top: 4),
                                  child: Text(
                                      '${a.suraNameAr} — آية ${a.ayaNo} — ص ${a.page}',
                                      style: _menuQuranStyle(
                                          fontSize: 15,
                                          color: const Color(0xFF2E7D32),
                                          fontWeight: FontWeight.w600)),
                                ),
                                onTap: () {
                                  _dismissAllMenuOverlays(ctx);
                                  _navigateToPage(a.page);
                                },
                              );
                            },
                          );
                        },
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ).whenComplete(() {
      queryText.dispose();
      results.dispose();
      MushafRamIdleExpander.instance.endBlockingUi();
    });
  }

  void _showFihrist(BuildContext context, int currentIndex) {
    final page1Based = (currentIndex + 1).clamp(1, totalPages);
    final targetListIndex = _suraListIndexForPage(page1Based);
    MushafRamIdleExpander.instance.beginBlockingUi();
    showQuranMenuSidePanel<void>(
      context: context,
      horizontallyRotatedReading: _isHorizontallyRotatedReading,
      isScrollControlled: true,
      backgroundColor: _menuPal.surface,
      builder: (ctx) => _wrapMainMenuFamilyOverlay(
        ctx,
        Directionality(
          textDirection: TextDirection.rtl,
          child: DraggableScrollableSheet(
            initialChildSize: 0.6,
            maxChildSize: 0.9,
            minChildSize: 0.3,
            expand: false,
            builder: (_, scrollController) => Column(
              children: [
                NestedQuranMenuAppBar(
                  title: 'الفهرس',
                  titleStyle:
                      _menuQuranStyle(fontSize: 20, color: _menuPal.title),
                  onBack: () => Navigator.pop(ctx),
                  onDismissAll: () => _dismissAllMenuOverlays(ctx),
                ),
                Divider(height: 1, color: _menuPal.divider),
                Expanded(
                  child: _FihristScrollOnOpen(
                    scrollController: scrollController,
                    targetListIndex: targetListIndex,
                    itemKey: _fihristCurrentSuraKey,
                    child: ListView.separated(
                      controller: scrollController,
                      itemCount: _suraList.length,
                      separatorBuilder: (_, __) => Divider(
                        height: 0.5,
                        color: _menuPal.divider,
                      ),
                      itemBuilder: (_, i) {
                        final s = _suraList[i];
                        final pageIndex = s.startPage - 1;
                        final suraNo = s.no;
                        final ayatCount = _suraAyahCount[suraNo] ?? 0;
                        final isMadani = _madaniSuras.contains(suraNo);
                        final isCurrentSuraRow = i == targetListIndex;
                        final pal = _menuPal;
                        return InkWell(
                          key: isCurrentSuraRow ? _fihristCurrentSuraKey : null,
                          onTap: () {
                            _dismissAllMenuOverlays(ctx);
                            _navigateToPage(pageIndex + 1);
                          },
                          child: DecoratedBox(
                            decoration: isCurrentSuraRow
                                ? BoxDecoration(
                                    color: pal.accent.withValues(
                                        alpha: pal.isDark ? 0.22 : 0.10),
                                    borderRadius: BorderRadius.circular(10),
                                  )
                                : const BoxDecoration(),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 10),
                              child: Row(
                                children: [
                                  SizedBox(
                                    width: 32,
                                    child: Align(
                                      alignment: Alignment.centerRight,
                                      child: Text(
                                        '$suraNo',
                                        style: _menuQuranStyle(
                                            fontSize: 16,
                                            color: pal.accent,
                                            fontWeight: FontWeight.w700),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      s.nameAr,
                                      style: _menuQuranStyle(
                                          fontSize: 18,
                                          color: pal.title,
                                          fontWeight: FontWeight.w700),
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  SizedBox(
                                    width: 80,
                                    child: Align(
                                      alignment: Alignment.centerRight,
                                      child: Text(
                                        'آيَاتُها $ayatCount',
                                        style: _menuQuranStyle(
                                            fontSize: 14,
                                            color: pal.subtitle,
                                            fontWeight: FontWeight.w500),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 2),
                                  SizedBox(
                                    width: 70,
                                    child: Center(
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 8, vertical: 4),
                                        decoration: BoxDecoration(
                                          color: isMadani
                                              ? const Color.fromARGB(
                                                  255, 50, 168, 56)
                                              : const Color.fromARGB(
                                                  255, 23, 112, 153),
                                          borderRadius:
                                              BorderRadius.circular(10),
                                        ),
                                        child: Text(
                                          isMadani ? 'مدنية' : 'مكية',
                                          style: _menuQuranStyle(
                                              fontSize: 13,
                                              color: Colors.white,
                                              fontWeight: FontWeight.w700),
                                        ),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  SizedBox(
                                    width: 56,
                                    child: Align(
                                      alignment: Alignment.centerRight,
                                      child: Text(
                                        'ص ${s.startPage}',
                                        style: _menuQuranStyle(
                                            fontSize: 15,
                                            color: pal.accent,
                                            fontWeight: FontWeight.w700),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ).whenComplete(MushafRamIdleExpander.instance.endBlockingUi);
  }

  void _showAjza(BuildContext context, int currentIndex) {
    MushafRamIdleExpander.instance.beginBlockingUi();
    showQuranMenuSidePanel<void>(
      context: context,
      horizontallyRotatedReading: _isHorizontallyRotatedReading,
      isScrollControlled: true,
      backgroundColor: _menuPal.surface,
      builder: (ctx) => _wrapMainMenuFamilyOverlay(
        ctx,
        Directionality(
          textDirection: TextDirection.rtl,
          child: DraggableScrollableSheet(
            initialChildSize: 0.6,
            maxChildSize: 0.9,
            minChildSize: 0.3,
            expand: false,
            builder: (_, scrollController) => Column(
              children: [
                NestedQuranMenuAppBar(
                  title: 'الأجزاء',
                  titleStyle:
                      _menuQuranStyle(fontSize: 20, color: _menuPal.title),
                  onBack: () => Navigator.pop(ctx),
                  onDismissAll: () => _dismissAllMenuOverlays(ctx),
                ),
                Divider(height: 1, color: _menuPal.divider),
                Expanded(
                  child: ListView.separated(
                    controller: scrollController,
                    itemCount: 30,
                    separatorBuilder: (_, __) => Divider(
                      height: 0.5,
                      color: _menuPal.divider,
                    ),
                    itemBuilder: (_, i) {
                      final juz = i + 1;
                      final startPage = _juzStartPage[juz] ?? 1;
                      final pageIndex = startPage - 1;
                      final pal = _menuPal;
                      return InkWell(
                        onTap: () {
                          _dismissAllMenuOverlays(ctx);
                          _navigateToPage(pageIndex + 1);
                        },
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 10),
                          child: Row(
                            children: [
                              SizedBox(
                                width: 60,
                                child: Align(
                                  alignment: Alignment.centerRight,
                                  child: Text(
                                    _toNormalDigits(juz),
                                    style: TextStyle(
                                      fontSize: 18,
                                      color: pal.accent,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Text('الجزء ${_juzNames[i]}',
                                    style: _menuQuranStyle(
                                        fontSize: 18,
                                        color: pal.title,
                                        fontWeight: FontWeight.w600)),
                              ),
                              const SizedBox(width: 10),
                              Text('ص ${_toNormalDigits(startPage)}',
                                  style: TextStyle(
                                      fontSize: 15,
                                      color: pal.accent,
                                      fontWeight: FontWeight.w700)),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ).whenComplete(MushafRamIdleExpander.instance.endBlockingUi);
  }

  void _showPagesDialog(BuildContext context, int currentIndex) {
    final initialPage = (currentIndex + 1).clamp(1, totalPages);
    MushafRamIdleExpander.instance.beginBlockingUi();
    showQuranMenuSidePanel<void>(
      context: context,
      horizontallyRotatedReading: _isHorizontallyRotatedReading,
      isScrollControlled: true,
      omitBottomSheetShape: true,
      backgroundColor: Colors.transparent,
      builder: (sheetCtx) => _wrapMainMenuFamilyOverlay(
        sheetCtx,
        _PageNumberPickerSheet(
          initialPage: initialPage,
          toNormalDigits: _toNormalDigits,
          arabicFontFamily: _arabicUiFontFamily,
          titleStyle: _menuQuranStyle(
            fontSize: 16,
            color: _menuPal.title,
            fontWeight: FontWeight.w600,
          ),
          menuPalette: _menuPal,
          onDismissAll: () => _dismissAllMenuOverlays(sheetCtx),
          onApply: (page) {
            _navigateToPage(page);
          },
        ),
      ),
    ).whenComplete(MushafRamIdleExpander.instance.endBlockingUi);
  }
}

/// عند فتح الفهرس: تمرير القائمة لتوسيط السورة الحالية في نافذة التمرير.
class _FihristScrollOnOpen extends StatefulWidget {
  const _FihristScrollOnOpen({
    required this.scrollController,
    required this.targetListIndex,
    required this.itemKey,
    required this.child,
  });

  final ScrollController scrollController;
  final int targetListIndex;
  final GlobalKey itemKey;
  final Widget child;

  @override
  State<_FihristScrollOnOpen> createState() => _FihristScrollOnOpenState();
}

class _FihristScrollOnOpenState extends State<_FihristScrollOnOpen> {
  /// ارتفاع تقريبي لصف + فاصل القائمة (للقفز الأول قبل بناء كل العناصر).
  static const double _rowExtent = 60.0;
  int _attachAttempts = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback(_tryScroll);
  }

  void _jumpNearTarget(ScrollController sc, {bool alignTop = false}) {
    final pos = sc.position;
    final vh = pos.viewportDimension;
    final max = pos.maxScrollExtent;
    final i = widget.targetListIndex;
    final raw =
        alignTop ? i * _rowExtent : i * _rowExtent - vh / 2 + _rowExtent / 2;
    sc.jumpTo(raw.clamp(0.0, max));
  }

  void _ensureTargetCentered(int pass) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final c = widget.itemKey.currentContext;
      if (c != null) {
        Scrollable.ensureVisible(
          c,
          alignment: 0.5,
          duration: Duration.zero,
        );
        return;
      }
      final sc = widget.scrollController;
      if (!sc.hasClients || pass >= 8) return;
      final max = sc.position.maxScrollExtent;
      final i = widget.targetListIndex;
      // إزاحة تدريجية حتى يدخل الصف المستهدف في نطاق بناء القائمة الكسولة
      final delta = (pass - 3) * _rowExtent * 0.4;
      sc.jumpTo((i * _rowExtent + delta).clamp(0.0, max));
      _ensureTargetCentered(pass + 1);
    });
  }

  void _tryScroll(_) {
    if (!mounted) return;
    final sc = widget.scrollController;
    if (!sc.hasClients) {
      _attachAttempts++;
      if (_attachAttempts < 40) {
        WidgetsBinding.instance.addPostFrameCallback(_tryScroll);
      }
      return;
    }
    _jumpNearTarget(sc, alignTop: false);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final c = widget.itemKey.currentContext;
      if (c != null) {
        Scrollable.ensureVisible(
          c,
          alignment: 0.5,
          duration: Duration.zero,
        );
      } else {
        _jumpNearTarget(sc, alignTop: true);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          final c2 = widget.itemKey.currentContext;
          if (c2 != null) {
            Scrollable.ensureVisible(
              c2,
              alignment: 0.5,
              duration: Duration.zero,
            );
          } else {
            _ensureTargetCentered(0);
          }
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class _PageNumberPickerSheet extends StatefulWidget {
  const _PageNumberPickerSheet({
    required this.initialPage,
    required this.toNormalDigits,
    required this.arabicFontFamily,
    required this.titleStyle,
    required this.menuPalette,
    required this.onDismissAll,
    required this.onApply,
  });

  final int initialPage; // 1..604
  final String Function(int) toNormalDigits;
  final String arabicFontFamily;
  final TextStyle titleStyle;
  final QuranMenuPaletteData menuPalette;
  final VoidCallback onDismissAll;
  final void Function(int page) onApply;

  @override
  State<_PageNumberPickerSheet> createState() => _PageNumberPickerSheetState();
}

class _PageNumberPickerSheetState extends State<_PageNumberPickerSheet> {
  static const int _maxPage = 604;
  static const double _wheelHeight = 170;
  static const double _wheelItemExtent = 34;
  static const double _wheelMaxWidth = 88;

  late int _page;
  late int _hundreds;
  late int _tens;
  late int _ones;

  late FixedExtentScrollController _hundredsController;
  late FixedExtentScrollController _tensController;
  late FixedExtentScrollController _onesController;

  @override
  void initState() {
    super.initState();
    _page = widget.initialPage.clamp(1, _maxPage);
    _hundreds = (_page ~/ 100).clamp(0, 6);
    _tens = ((_page % 100) ~/ 10).clamp(0, 9);
    _ones = (_page % 10).clamp(0, 9);
    _hundredsController = FixedExtentScrollController(initialItem: _hundreds);
    _tensController = FixedExtentScrollController(initialItem: _tens);
    _onesController = FixedExtentScrollController(initialItem: _ones);
  }

  @override
  void dispose() {
    _hundredsController.dispose();
    _tensController.dispose();
    _onesController.dispose();
    super.dispose();
  }

  void _jumpIfNeeded(FixedExtentScrollController controller, int item) {
    if (!controller.hasClients) return;
    if (controller.selectedItem != item) controller.jumpToItem(item);
  }

  void _setPage(int page) {
    final p = page.clamp(1, _maxPage);
    final h = (p ~/ 100).clamp(0, 6);
    final t = ((p % 100) ~/ 10).clamp(0, 9);
    final o = (p % 10).clamp(0, 9);
    setState(() {
      _page = p;
      _hundreds = h;
      _tens = t;
      _ones = o;
    });
    _jumpIfNeeded(_hundredsController, _hundreds);
    _jumpIfNeeded(_tensController, _tens);
    _jumpIfNeeded(_onesController, _ones);
  }

  int _composePage(int h, int t, int o) {
    final p = h * 100 + t * 10 + o;
    return p <= 0 ? 1 : p;
  }

  Widget _buildWheelColumn({
    required String title,
    required int selectedIndex,
    required int childCount,
    required FixedExtentScrollController controller,
    required String Function(int index) labelBuilder,
    required ValueChanged<int> onChanged,
  }) {
    final pal = widget.menuPalette;
    // يجب ألا يكون الجذر Expanded: الأب هنا SizedBox وليس Row — وإلا تنهار العجلات (ارتفاع 0).
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          title,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: pal.accent,
            fontFamily: widget.arabicFontFamily,
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 6),
        Expanded(
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: pal.wheelColumnInnerFill,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: pal.wheelColumnBorder),
            ),
            child: ListWheelScrollView.useDelegate(
              controller: controller,
              itemExtent: _wheelItemExtent,
              perspective: 0.004,
              diameterRatio: 1.55,
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
                        fontFamily: widget.arabicFontFamily,
                        fontSize: selected ? 22 : 18,
                        fontWeight:
                            selected ? FontWeight.w700 : FontWeight.w500,
                        color: selected
                            ? pal.wheelTextSelected
                            : pal.wheelTextUnselected,
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

  @override
  Widget build(BuildContext context) {
    final pal = widget.menuPalette;
    return QuranMenuPalette(
      data: pal,
      child: SafeArea(
        top: false,
        child: Directionality(
          textDirection: TextDirection.rtl,
          child: Padding(
            padding: EdgeInsets.only(
              left: 12,
              right: 12,
              bottom: MediaQuery.viewInsetsOf(context).bottom + 12,
            ),
            child: Material(
              color: pal.surface,
              borderRadius: BorderRadius.circular(16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    decoration: BoxDecoration(
                      color: pal.surface,
                      borderRadius:
                          const BorderRadius.vertical(top: Radius.circular(16)),
                    ),
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
                    child: NestedQuranMenuAppBar(
                      title: 'انتقال إلى صفحة',
                      titleStyle: widget.titleStyle,
                      onBack: () => Navigator.pop(context),
                      onDismissAll: widget.onDismissAll,
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'الصفحة: ${widget.toNormalDigits(_page)}',
                          style: TextStyle(
                            fontFamily: widget.arabicFontFamily,
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                            color: pal.title,
                          ),
                        ),
                        const SizedBox(height: 10),
                        SizedBox(
                          height: _wheelHeight,
                          child: LayoutBuilder(
                            builder: (context, constraints) {
                              final w = (constraints.maxWidth - 16) / 3;
                              final wheelW = w.clamp(56.0, _wheelMaxWidth);
                              return Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  SizedBox(
                                    width: wheelW,
                                    height: _wheelHeight,
                                    child: _buildWheelColumn(
                                      title: 'الآحاد',
                                      selectedIndex: _ones,
                                      childCount: 10,
                                      controller: _onesController,
                                      labelBuilder: (i) =>
                                          widget.toNormalDigits(i),
                                      onChanged: (i) {
                                        final p =
                                            _composePage(_hundreds, _tens, i);
                                        _setPage(p);
                                      },
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  SizedBox(
                                    width: wheelW,
                                    height: _wheelHeight,
                                    child: _buildWheelColumn(
                                      title: 'العشرات',
                                      selectedIndex: _tens,
                                      childCount: 10,
                                      controller: _tensController,
                                      labelBuilder: (i) =>
                                          widget.toNormalDigits(i),
                                      onChanged: (i) {
                                        final p =
                                            _composePage(_hundreds, i, _ones);
                                        _setPage(p);
                                      },
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  SizedBox(
                                    width: wheelW,
                                    height: _wheelHeight,
                                    child: _buildWheelColumn(
                                      title: 'المئات',
                                      selectedIndex: _hundreds,
                                      childCount: 7,
                                      controller: _hundredsController,
                                      labelBuilder: (i) =>
                                          widget.toNormalDigits(i),
                                      onChanged: (i) {
                                        final p = _composePage(i, _tens, _ones);
                                        _setPage(p);
                                      },
                                    ),
                                  ),
                                ],
                              );
                            },
                          ),
                        ),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            Expanded(
                              child: OutlinedButton(
                                onPressed: () => _setPage(widget.initialPage),
                                style: OutlinedButton.styleFrom(
                                  backgroundColor: pal.wheelColumnInnerFill,
                                  side: BorderSide(color: pal.accent),
                                ),
                                child: Text(
                                  'إعادة',
                                  style: TextStyle(
                                    fontFamily: widget.arabicFontFamily,
                                    fontWeight: FontWeight.w700,
                                    color: pal.title,
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: FilledButton(
                                style: FilledButton.styleFrom(
                                  backgroundColor: pal.accent,
                                ),
                                onPressed: () {
                                  widget.onDismissAll();
                                  widget.onApply(_page);
                                },
                                child: Text(
                                  'انتقال',
                                  style: TextStyle(
                                    fontFamily: widget.arabicFontFamily,
                                    fontWeight: FontWeight.w700,
                                    color: Colors.white,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
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

enum _AudioListenMode { surah, ayah }

class _AudioRangePickerSheet extends StatefulWidget {
  const _AudioRangePickerSheet({
    required this.initialRange,
    required this.currentSura,
    required this.currentAyah,
    required this.suraList,
    required this.suraAyahCount,
    required this.toNormalDigits,
    required this.arabicFontFamily,
    required this.menuPalette,
    required this.onApply,
    required this.onClear,
    this.compactLandscapeLayout = false,
  });

  final AyahPlaybackRange? initialRange;
  final int? currentSura;
  final int? currentAyah;
  final List<({int no, String nameAr, int startPage})> suraList;
  final Map<int, int> suraAyahCount;
  final String Function(int) toNormalDigits;
  final String arabicFontFamily;
  final QuranMenuPaletteData menuPalette;
  final Future<void> Function(
      int fromSura, int fromAyah, int toSura, int toAyah) onApply;
  final Future<void> Function() onClear;
  final bool compactLandscapeLayout;

  @override
  State<_AudioRangePickerSheet> createState() => _AudioRangePickerSheetState();
}

class _AudioRangePickerSheetState extends State<_AudioRangePickerSheet> {
  late _AudioListenMode _mode;
  late int _fromSura;
  late int _toSura;
  late int _ayahSura;
  late int _fromAyah;
  late int _toAyah;

  late FixedExtentScrollController _fromSuraController;
  late FixedExtentScrollController _toSuraController;
  late FixedExtentScrollController _ayahSuraController;
  late FixedExtentScrollController _fromAyahController;
  late FixedExtentScrollController _toAyahController;

  int _ayahCountFor(int sura) => widget.suraAyahCount[sura] ?? 286;

  int _suraIndex(int sura) {
    final idx = widget.suraList.indexWhere((s) => s.no == sura);
    if (idx >= 0) return idx;
    return (sura - 1).clamp(0, widget.suraList.length - 1);
  }

  String _suraName(int sura) {
    final s = widget.suraList.where((x) => x.no == sura).firstOrNull;
    return s?.nameAr ?? 'سورة ${widget.toNormalDigits(sura)}';
  }

  bool _isLikelySurahMode(AyahPlaybackRange? range) {
    if (range == null) return false;
    if (range.fromSura != range.toSura) return true;
    return range.fromAyah == 1 && range.toAyah == _ayahCountFor(range.toSura);
  }

  void _jumpIfNeeded(FixedExtentScrollController controller, int item) {
    if (!controller.hasClients) return;
    if (controller.selectedItem != item) {
      controller.jumpToItem(item);
    }
  }

  @override
  void initState() {
    super.initState();
    final fallbackSura =
        (widget.currentSura ?? widget.initialRange?.fromSura ?? 1)
            .clamp(1, 114);
    _fromSura = widget.initialRange?.fromSura ?? fallbackSura;
    _toSura = widget.initialRange?.toSura ?? _fromSura;
    if (_toSura < _fromSura) _toSura = _fromSura;

    _ayahSura = widget.initialRange?.fromSura ?? fallbackSura;
    final ayahCount = _ayahCountFor(_ayahSura);
    _fromAyah = (widget.initialRange?.fromAyah ?? widget.currentAyah ?? 1)
        .clamp(1, ayahCount);
    if (widget.initialRange != null &&
        widget.initialRange!.fromSura == widget.initialRange!.toSura) {
      _toAyah = widget.initialRange!.toAyah.clamp(_fromAyah, ayahCount);
    } else {
      _toAyah = _fromAyah;
    }
    _mode = _isLikelySurahMode(widget.initialRange)
        ? _AudioListenMode.surah
        : _AudioListenMode.ayah;

    _fromSuraController =
        FixedExtentScrollController(initialItem: _suraIndex(_fromSura));
    _toSuraController =
        FixedExtentScrollController(initialItem: _suraIndex(_toSura));
    _ayahSuraController =
        FixedExtentScrollController(initialItem: _suraIndex(_ayahSura));
    _fromAyahController =
        FixedExtentScrollController(initialItem: _fromAyah - 1);
    _toAyahController = FixedExtentScrollController(initialItem: _toAyah - 1);
  }

  @override
  void dispose() {
    _fromSuraController.dispose();
    _toSuraController.dispose();
    _ayahSuraController.dispose();
    _fromAyahController.dispose();
    _toAyahController.dispose();
    super.dispose();
  }

  Widget _modeButton({
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    final pal = widget.menuPalette;
    return Expanded(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: selected ? pal.accent : pal.cardSurface,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: pal.accent),
          ),
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontFamily: widget.arabicFontFamily,
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: selected ? Colors.white : pal.title,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildWheelColumn({
    required String title,
    required int selectedIndex,
    required int childCount,
    required FixedExtentScrollController controller,
    required String Function(int index) labelBuilder,
    required ValueChanged<int> onChanged,
  }) {
    final pal = widget.menuPalette;
    return Expanded(
      child: Column(
        children: [
          Text(
            title,
            style: TextStyle(
              color: pal.accent,
              fontFamily: widget.arabicFontFamily,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          Expanded(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: pal.wheelColumnInnerFill,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: pal.wheelColumnBorder),
              ),
              child: ListWheelScrollView.useDelegate(
                controller: controller,
                itemExtent: 40,
                perspective: 0.004,
                diameterRatio: 1.55,
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
                          fontFamily: widget.arabicFontFamily,
                          fontSize: 15,
                          fontWeight:
                              selected ? FontWeight.w700 : FontWeight.w500,
                          color: selected
                              ? pal.wheelTextSelected
                              : pal.wheelTextUnselected,
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

  Widget _buildSurahModeContent() {
    return SizedBox(
      height: 220,
      child: Row(
        children: [
          _buildWheelColumn(
            title: 'من سورة',
            selectedIndex: _suraIndex(_fromSura),
            childCount: widget.suraList.length,
            controller: _fromSuraController,
            labelBuilder: (i) =>
                '${widget.toNormalDigits(widget.suraList[i].no)} - ${widget.suraList[i].nameAr}',
            onChanged: (i) {
              if (i < 0 || i >= widget.suraList.length) return;
              setState(() {
                _fromSura = widget.suraList[i].no;
                if (_toSura < _fromSura) _toSura = _fromSura;
              });
              _jumpIfNeeded(_toSuraController, _suraIndex(_toSura));
            },
          ),
          const SizedBox(width: 8),
          _buildWheelColumn(
            title: 'إلى سورة',
            selectedIndex: _suraIndex(_toSura),
            childCount: widget.suraList.length,
            controller: _toSuraController,
            labelBuilder: (i) =>
                '${widget.toNormalDigits(widget.suraList[i].no)} - ${widget.suraList[i].nameAr}',
            onChanged: (i) {
              if (i < 0 || i >= widget.suraList.length) return;
              setState(() {
                _toSura = widget.suraList[i].no;
                if (_toSura < _fromSura) _toSura = _fromSura;
              });
              _jumpIfNeeded(_toSuraController, _suraIndex(_toSura));
            },
          ),
        ],
      ),
    );
  }

  Widget _buildAyahModeContent() {
    final ayahCount = _ayahCountFor(_ayahSura);
    return SizedBox(
      height: 220,
      child: Row(
        children: [
          _buildWheelColumn(
            title: 'السورة',
            selectedIndex: _suraIndex(_ayahSura),
            childCount: widget.suraList.length,
            controller: _ayahSuraController,
            labelBuilder: (i) =>
                '${widget.toNormalDigits(widget.suraList[i].no)} - ${widget.suraList[i].nameAr}',
            onChanged: (i) {
              if (i < 0 || i >= widget.suraList.length) return;
              setState(() {
                _ayahSura = widget.suraList[i].no;
                final c = _ayahCountFor(_ayahSura);
                _fromAyah = _fromAyah.clamp(1, c);
                _toAyah = _toAyah.clamp(_fromAyah, c);
              });
              _jumpIfNeeded(_fromAyahController, _fromAyah - 1);
              _jumpIfNeeded(_toAyahController, _toAyah - 1);
            },
          ),
          const SizedBox(width: 8),
          _buildWheelColumn(
            title: 'من آية',
            selectedIndex: _fromAyah - 1,
            childCount: ayahCount,
            controller: _fromAyahController,
            labelBuilder: (i) => widget.toNormalDigits(i + 1),
            onChanged: (i) {
              final value = (i + 1).clamp(1, ayahCount);
              setState(() {
                _fromAyah = value;
                if (_toAyah < _fromAyah) _toAyah = _fromAyah;
              });
              _jumpIfNeeded(_toAyahController, _toAyah - 1);
            },
          ),
          const SizedBox(width: 8),
          _buildWheelColumn(
            title: 'إلى آية',
            selectedIndex: _toAyah - 1,
            childCount: ayahCount,
            controller: _toAyahController,
            labelBuilder: (i) => widget.toNormalDigits(i + 1),
            onChanged: (i) {
              final value = (i + 1).clamp(_fromAyah, ayahCount);
              setState(() {
                _toAyah = value;
              });
              _jumpIfNeeded(_toAyahController, _toAyah - 1);
            },
          ),
        ],
      ),
    );
  }

  String _selectionSummary() {
    if (_mode == _AudioListenMode.surah) {
      return 'سيتم التشغيل من بداية ${_suraName(_fromSura)} إلى نهاية ${_suraName(_toSura)}';
    }
    return 'النطاق: ${_suraName(_ayahSura)} من آية ${widget.toNormalDigits(_fromAyah)} إلى ${widget.toNormalDigits(_toAyah)}';
  }

  Future<void> _applyAndPlay() async {
    if (_mode == _AudioListenMode.surah) {
      final endAyah = _ayahCountFor(_toSura);
      await widget.onApply(_fromSura, 1, _toSura, endAyah);
    } else {
      await widget.onApply(_ayahSura, _fromAyah, _ayahSura, _toAyah);
    }
    if (!context.mounted) return;
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final pal = widget.menuPalette;
    final isLandscape = widget.compactLandscapeLayout ||
        MediaQuery.orientationOf(context) == Orientation.landscape;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 16),
        child: isLandscape
            ? LayoutBuilder(
                builder: (context, constraints) {
                  final panelHeight =
                      (constraints.maxHeight - 190).clamp(110.0, 190.0);
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        'تحديد نطاق التشغيل',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontFamily: widget.arabicFontFamily,
                          fontSize: 18,
                          color: pal.title,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          _modeButton(
                            label: 'الاستماع لسورة',
                            selected: _mode == _AudioListenMode.surah,
                            onTap: () {
                              setState(() {
                                _mode = _AudioListenMode.surah;
                              });
                            },
                          ),
                          const SizedBox(width: 8),
                          _modeButton(
                            label: 'الاستماع لآية',
                            selected: _mode == _AudioListenMode.ayah,
                            onTap: () {
                              setState(() {
                                _mode = _AudioListenMode.ayah;
                              });
                            },
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Expanded(
                        child: SingleChildScrollView(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              SizedBox(
                                height: panelHeight.toDouble(),
                                child: AnimatedSwitcher(
                                  duration: const Duration(milliseconds: 180),
                                  child: _mode == _AudioListenMode.surah
                                      ? _buildSurahModeContent()
                                      : _buildAyahModeContent(),
                                ),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                _selectionSummary(),
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontFamily: widget.arabicFontFamily,
                                  fontSize: 14,
                                  color: pal.accent,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton(
                              onPressed: () async {
                                await widget.onClear();
                                if (!context.mounted) return;
                                Navigator.pop(context);
                              },
                              style: OutlinedButton.styleFrom(
                                side: BorderSide(color: pal.accent),
                              ),
                              child: Text(
                                'إلغاء المدى',
                                style: TextStyle(
                                  fontFamily: widget.arabicFontFamily,
                                  color: pal.title,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: FilledButton(
                              onPressed: _applyAndPlay,
                              style: FilledButton.styleFrom(
                                backgroundColor: pal.accent,
                              ),
                              child: Text(
                                'تطبيق وتشغيل',
                                style: TextStyle(
                                  fontFamily: widget.arabicFontFamily,
                                  color: Colors.white,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  );
                },
              )
            : SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'تحديد نطاق التشغيل',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontFamily: widget.arabicFontFamily,
                        fontSize: 18,
                        color: pal.title,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        _modeButton(
                          label: 'الاستماع لسورة',
                          selected: _mode == _AudioListenMode.surah,
                          onTap: () {
                            setState(() {
                              _mode = _AudioListenMode.surah;
                            });
                          },
                        ),
                        const SizedBox(width: 8),
                        _modeButton(
                          label: 'الاستماع لآية',
                          selected: _mode == _AudioListenMode.ayah,
                          onTap: () {
                            setState(() {
                              _mode = _AudioListenMode.ayah;
                            });
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 180),
                      child: _mode == _AudioListenMode.surah
                          ? _buildSurahModeContent()
                          : _buildAyahModeContent(),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      _selectionSummary(),
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontFamily: widget.arabicFontFamily,
                        fontSize: 14,
                        color: pal.accent,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            onPressed: () async {
                              await widget.onClear();
                              if (!context.mounted) return;
                              Navigator.pop(context);
                            },
                            style: OutlinedButton.styleFrom(
                              side: BorderSide(color: pal.accent),
                            ),
                            child: Text(
                              'إلغاء المدى',
                              style: TextStyle(
                                fontFamily: widget.arabicFontFamily,
                                color: pal.title,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: FilledButton(
                            onPressed: _applyAndPlay,
                            style: FilledButton.styleFrom(
                              backgroundColor: pal.accent,
                            ),
                            child: Text(
                              'تطبيق وتشغيل',
                              style: TextStyle(
                                fontFamily: widget.arabicFontFamily,
                                color: Colors.white,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
      ),
    );
  }
}

/// نافذة تفسير آية/آيات بتبويبات وزر نسخ — الضغط على العنوان يفتح عجلات اختيار السورة ونطاق الآيات
class _TafseerAyahDialog extends StatefulWidget {
  const _TafseerAyahDialog({
    required this.initialSura,
    required this.initialAyah,
    this.initialFromAyah,
    this.initialToAyah,
    required this.suraList,
    required this.suraAyahCount,
    required this.tafseerSaadiBySuraAya,
    required this.tafseerMouaserBySuraAya,
    required this.toNormalDigits,
    required this.quranStyle,
    required this.arabicUiFontFamily,
    required this.tafsirBodyFontSize,
    required this.rotateOverlaysLikeMainMenu,
    required this.menuPalette,
    required this.onClearSelection,
  });
  final int initialSura;
  final int initialAyah;
  final int? initialFromAyah;
  final int? initialToAyah;
  final List<({int no, String nameAr, int startPage})> suraList;
  final Map<int, int> suraAyahCount;
  final Map<String, String> tafseerSaadiBySuraAya;
  final Map<String, String> tafseerMouaserBySuraAya;
  final String Function(int) toNormalDigits;
  final TextStyle Function(
      {required double fontSize,
      required Color color,
      FontWeight fontWeight}) quranStyle;
  final String arabicUiFontFamily;
  final double tafsirBodyFontSize;
  final bool rotateOverlaysLikeMainMenu;
  final QuranMenuPaletteData menuPalette;
  final VoidCallback onClearSelection;

  @override
  State<_TafseerAyahDialog> createState() => _TafseerAyahDialogState();
}

class _TafseerAyahDialogState extends State<_TafseerAyahDialog>
    with SingleTickerProviderStateMixin {
  static const int _maxAyat = 30;
  late TabController _tabController;
  late int _sura;
  late int _fromAyah;
  late int _toAyah;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _sura = widget.initialSura;
    _fromAyah = widget.initialFromAyah ?? widget.initialAyah;
    _toAyah = widget.initialToAyah ?? widget.initialAyah;
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  int get _ayahCount => widget.suraAyahCount[_sura] ?? 286;

  String _suraName() {
    final s = widget.suraList.where((x) => x.no == _sura).firstOrNull;
    return s?.nameAr ?? 'سورة $_sura';
  }

  String _buildTafseerForRange(Map<String, String> sourceMap) {
    final from = _fromAyah.clamp(1, _ayahCount);
    final to = _toAyah.clamp(1, _ayahCount);
    final f = from <= to ? from : to;
    final t = from <= to ? to : from;
    if (t - f + 1 > _maxAyat) return 'لا يمكن عرض تفسير أكثر من $_maxAyat آيات';
    final sb = StringBuffer();
    for (int a = f; a <= t; a++) {
      final key = '$_sura:$a';
      final text = sourceMap[key];
      if (text != null && text.isNotEmpty) {
        if (f < t) sb.writeln('الآية ${widget.toNormalDigits(a)}:\n');
        sb.writeln(text);
        if (a < t) sb.writeln('\n');
      }
    }
    final result = sb.toString().trim();
    return result.isEmpty ? 'لا يوجد تفسير لهذا النطاق' : result;
  }

  void _copyCurrentTafseer() {
    final text = _tabController.index == 0
        ? _buildTafseerForRange(widget.tafseerSaadiBySuraAya)
        : _buildTafseerForRange(widget.tafseerMouaserBySuraAya);
    if (text.isNotEmpty && !text.startsWith('لا يمكن')) {
      Clipboard.setData(ClipboardData(text: text));
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
          'تم نسخ التفسير',
          style: widget.quranStyle(fontSize: 14, color: Colors.white),
        ),
        backgroundColor: const Color(0xFF2E7D32),
      ));
    }
  }

  void _showRangePicker() {
    int from = _fromAyah.clamp(1, _ayahCount);
    int to = _toAyah.clamp(1, _ayahCount);
    if (from > to) {
      final tmp = from;
      from = to;
      to = tmp;
    }
    if (to - from + 1 > _maxAyat) to = from + _maxAyat - 1;

    MushafRamIdleExpander.instance.beginBlockingUi();
    final pal = widget.menuPalette;
    showQuranMenuSidePanel<void>(
      context: context,
      horizontallyRotatedReading: widget.rotateOverlaysLikeMainMenu,
      backgroundColor: pal.surface,
      builder: (ctx) => QuranMenuPalette(
        data: pal,
        child: wrapQuranMenuFamilySheetOverlay(
          ctx,
          Directionality(
            textDirection: TextDirection.rtl,
            child: _TafseerRangePickerSheet(
              sura: _sura,
              fromAyah: from,
              toAyah: to,
              suraList: widget.suraList,
              suraAyahCount: widget.suraAyahCount,
              toNormalDigits: widget.toNormalDigits,
              quranStyle: widget.quranStyle,
              menuPalette: pal,
              maxAyat: _maxAyat,
              onDismissAll: () =>
                  Navigator.of(ctx).popUntil((route) => route.isFirst),
              onChanged: (s, f, t) {
                setState(() {
                  _sura = s;
                  _fromAyah = f;
                  _toAyah = t;
                });
              },
            ),
          ),
          horizontallyRotatedReading: widget.rotateOverlaysLikeMainMenu,
        ),
      ),
    ).whenComplete(MushafRamIdleExpander.instance.endBlockingUi);
  }

  @override
  Widget build(BuildContext context) {
    final pal = widget.menuPalette;
    final tafseerSaadi = _buildTafseerForRange(widget.tafseerSaadiBySuraAya);
    final tafseerMouaser =
        _buildTafseerForRange(widget.tafseerMouaserBySuraAya);
    final headerText = _fromAyah == _toAyah
        ? 'تفسير ${_suraName()} – الآية ${widget.toNormalDigits(_fromAyah)}'
        : 'تفسير ${_suraName()} – من ${widget.toNormalDigits(_fromAyah)} إلى ${widget.toNormalDigits(_toAyah)}';
    final bodyLight = !pal.isDark;

    return Directionality(
      textDirection: TextDirection.rtl,
      child: Center(
        child: Material(
          color: Colors.transparent,
          child: Container(
            constraints: BoxConstraints(
              maxWidth: 360,
              maxHeight: MediaQuery.of(context).size.height * 0.65,
            ),
            decoration: BoxDecoration(
              color: pal.surface,
              borderRadius: BorderRadius.circular(16),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.15),
                  blurRadius: 16,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
                  child: Row(
                    children: [
                      IconButton(
                        icon: Icon(Icons.close, color: pal.nestedBarIcon),
                        onPressed: () => Navigator.pop(context),
                      ),
                      Expanded(
                        child: InkWell(
                          onTap: _showRangePicker,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            child: Text(
                              headerText,
                              style: widget.quranStyle(
                                fontSize: 16,
                                color: pal.title,
                                fontWeight: FontWeight.bold,
                              ),
                              textAlign: TextAlign.center,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 48),
                    ],
                  ),
                ),
                TabBar(
                  controller: _tabController,
                  labelColor: pal.tafsirTabSelected,
                  unselectedLabelColor: pal.tafsirTabUnselected,
                  indicatorColor: pal.tafsirTabSelected,
                  tabs: const [
                    Tab(text: 'السعدي'),
                    Tab(text: 'الميسّر'),
                  ],
                ),
                Expanded(
                  child: TabBarView(
                    controller: _tabController,
                    children: [
                      _TafseerTabContent(
                        text: tafseerSaadi,
                        isEmpty: tafseerSaadi.isEmpty ||
                            tafseerSaadi.startsWith('لا يوجد') ||
                            tafseerSaadi.startsWith('لا يمكن'),
                        isLightTheme: bodyLight,
                        fontFamily: widget.arabicUiFontFamily,
                        fontSize: widget.tafsirBodyFontSize,
                      ),
                      _TafseerTabContent(
                        text: tafseerMouaser,
                        isEmpty: tafseerMouaser.isEmpty ||
                            tafseerMouaser.startsWith('لا يوجد') ||
                            tafseerMouaser.startsWith('لا يمكن'),
                        isLightTheme: bodyLight,
                        fontFamily: widget.arabicUiFontFamily,
                        fontSize: widget.tafsirBodyFontSize,
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                  child: SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: _copyCurrentTafseer,
                      icon: const Icon(Icons.copy, size: 20),
                      label: const Text('نسخ التفسير'),
                      style: FilledButton.styleFrom(
                        backgroundColor: pal.accent,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// لوحة اختيار السورة ونطاق الآيات — مع عجلات تبدأ عند التحديد الحالي
class _TafseerRangePickerSheet extends StatefulWidget {
  const _TafseerRangePickerSheet({
    required this.sura,
    required this.fromAyah,
    required this.toAyah,
    required this.suraList,
    required this.suraAyahCount,
    required this.toNormalDigits,
    required this.quranStyle,
    required this.menuPalette,
    required this.maxAyat,
    required this.onChanged,
    required this.onDismissAll,
    this.onConfirm,
  });
  final int sura;
  final int fromAyah;
  final int toAyah;
  final List<({int no, String nameAr, int startPage})> suraList;
  final Map<int, int> suraAyahCount;
  final String Function(int) toNormalDigits;
  final TextStyle Function(
      {required double fontSize,
      required Color color,
      FontWeight fontWeight}) quranStyle;
  final QuranMenuPaletteData menuPalette;
  final int maxAyat;
  final void Function(int sura, int fromAyah, int toAyah) onChanged;
  final VoidCallback onDismissAll;
  final void Function(int sura, int fromAyah, int toAyah)? onConfirm;

  @override
  State<_TafseerRangePickerSheet> createState() =>
      _TafseerRangePickerSheetState();
}

class _TafseerRangePickerSheetState extends State<_TafseerRangePickerSheet> {
  late FixedExtentScrollController _suraController;
  late FixedExtentScrollController _fromController;
  late FixedExtentScrollController _toController;
  late int _sura;
  late int _fromAyah;
  late int _toAyah;

  int get _ayahCount => widget.suraAyahCount[_sura] ?? 286;

  @override
  void initState() {
    super.initState();
    _sura = widget.sura;
    _fromAyah = widget.fromAyah.clamp(1, _ayahCount);
    _toAyah = widget.toAyah.clamp(1, _ayahCount);
    if (_toAyah - _fromAyah + 1 > widget.maxAyat) {
      _toAyah = _fromAyah + widget.maxAyat - 1;
    }
    final suraIdx = widget.suraList.indexWhere((s) => s.no == _sura);
    _suraController =
        FixedExtentScrollController(initialItem: suraIdx >= 0 ? suraIdx : 0);
    _fromController = FixedExtentScrollController(
        initialItem: (_fromAyah - 1).clamp(0, _ayahCount - 1));
    _toController = FixedExtentScrollController(
        initialItem: (_toAyah - 1).clamp(0, _ayahCount - 1));
  }

  @override
  void dispose() {
    _suraController.dispose();
    _fromController.dispose();
    _toController.dispose();
    super.dispose();
  }

  void _notify() {
    widget.onChanged(_sura, _fromAyah, _toAyah);
  }

  @override
  Widget build(BuildContext context) {
    final pal = widget.menuPalette;
    final textColor = pal.title;
    final mutedColor = pal.accent;
    final wheelUnsel = pal.wheelTextUnselected;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            NestedQuranMenuAppBar(
              title: 'التفسير',
              titleStyle: widget.quranStyle(
                fontSize: 17,
                color: textColor,
                fontWeight: FontWeight.bold,
              ),
              onBack: () => Navigator.pop(context),
              onDismissAll: widget.onDismissAll,
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Text(
                'اختر السورة ونطاق الآيات (حد أقصى ${widget.maxAyat} آيات)',
                style: widget.quranStyle(
                  fontSize: 14,
                  color: mutedColor,
                  fontWeight: FontWeight.w600,
                ),
                textAlign: TextAlign.center,
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 180,
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      children: [
                        Text('السورة',
                            style: TextStyle(color: mutedColor, fontSize: 14)),
                        Expanded(
                          child: ListWheelScrollView.useDelegate(
                            controller: _suraController,
                            itemExtent: 40,
                            perspective: 0.005,
                            diameterRatio: 1.5,
                            physics: const BouncingScrollPhysics(
                                parent: FixedExtentScrollPhysics()),
                            onSelectedItemChanged: (i) {
                              if (i >= 0 && i < widget.suraList.length) {
                                setState(() {
                                  _sura = widget.suraList[i].no;
                                  final count =
                                      widget.suraAyahCount[_sura] ?? 286;
                                  _fromAyah = _fromAyah.clamp(1, count);
                                  _toAyah = _toAyah.clamp(1, count);
                                  if (_toAyah - _fromAyah + 1 >
                                      widget.maxAyat) {
                                    _toAyah = _fromAyah + widget.maxAyat - 1;
                                  }
                                });
                                _notify();
                              }
                            },
                            childDelegate: ListWheelChildBuilderDelegate(
                              childCount: widget.suraList.length,
                              builder: (_, i) {
                                final s = widget.suraList[i];
                                final sel = s.no == _sura;
                                return Center(
                                  child: Text(
                                    '${widget.toNormalDigits(s.no)} - ${s.nameAr}',
                                    style: TextStyle(
                                      fontSize: 15,
                                      color: sel ? textColor : wheelUnsel,
                                      fontWeight: sel
                                          ? FontWeight.bold
                                          : FontWeight.normal,
                                    ),
                                    overflow: TextOverflow.ellipsis,
                                    textAlign: TextAlign.center,
                                  ),
                                );
                              },
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: Column(
                      children: [
                        Text('من آية',
                            style: TextStyle(color: mutedColor, fontSize: 14)),
                        Expanded(
                          child: ListWheelScrollView.useDelegate(
                            controller: _fromController,
                            itemExtent: 40,
                            perspective: 0.005,
                            diameterRatio: 1.5,
                            physics: const BouncingScrollPhysics(
                                parent: FixedExtentScrollPhysics()),
                            onSelectedItemChanged: (i) {
                              final newFrom = (i + 1).clamp(1, _ayahCount);
                              setState(() {
                                _fromAyah = newFrom;
                                if (_toAyah - _fromAyah + 1 > widget.maxAyat) {
                                  _toAyah = _fromAyah + widget.maxAyat - 1;
                                }
                                if (_toAyah < _fromAyah) _toAyah = _fromAyah;
                              });
                              _notify();
                            },
                            childDelegate: ListWheelChildBuilderDelegate(
                              childCount: _ayahCount,
                              builder: (_, i) {
                                final n = i + 1;
                                final sel = n == _fromAyah;
                                return Center(
                                  child: Text(
                                    widget.toNormalDigits(n),
                                    style: TextStyle(
                                      fontSize: 16,
                                      color: sel ? textColor : wheelUnsel,
                                      fontWeight: sel
                                          ? FontWeight.bold
                                          : FontWeight.normal,
                                    ),
                                  ),
                                );
                              },
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: Column(
                      children: [
                        Text('إلى آية',
                            style: TextStyle(color: mutedColor, fontSize: 14)),
                        Expanded(
                          child: ListWheelScrollView.useDelegate(
                            controller: _toController,
                            itemExtent: 40,
                            perspective: 0.005,
                            diameterRatio: 1.5,
                            physics: const BouncingScrollPhysics(
                                parent: FixedExtentScrollPhysics()),
                            onSelectedItemChanged: (i) {
                              final newTo = (i + 1).clamp(1, _ayahCount);
                              setState(() {
                                _toAyah = newTo;
                                if (_toAyah - _fromAyah + 1 > widget.maxAyat) {
                                  _toAyah = _fromAyah + widget.maxAyat - 1;
                                }
                                if (_toAyah < _fromAyah) _toAyah = _fromAyah;
                              });
                              _notify();
                            },
                            childDelegate: ListWheelChildBuilderDelegate(
                              childCount: _ayahCount,
                              builder: (_, i) {
                                final n = i + 1;
                                final sel = n == _toAyah;
                                return Center(
                                  child: Text(
                                    widget.toNormalDigits(n),
                                    style: TextStyle(
                                      fontSize: 16,
                                      color: sel ? textColor : wheelUnsel,
                                      fontWeight: sel
                                          ? FontWeight.bold
                                          : FontWeight.normal,
                                    ),
                                  ),
                                );
                              },
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (widget.onConfirm != null)
                  Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: FilledButton(
                      onPressed: () {
                        widget.onConfirm!(_sura, _fromAyah, _toAyah);
                      },
                      style: FilledButton.styleFrom(
                        backgroundColor: mutedColor,
                        foregroundColor: Colors.white,
                      ),
                      child: const Text('عرض التفسير'),
                    ),
                  ),
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: Text('إغلاق', style: TextStyle(color: mutedColor)),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// محتوى تبويب التفسير — يدعم الثيم الفاتح (القائمة الرئيسية)
class _TafseerTabContent extends StatelessWidget {
  const _TafseerTabContent({
    required this.text,
    required this.isEmpty,
    this.isLightTheme = false,
    required this.fontFamily,
    this.fontSize = 19,
  });
  final String text;
  final bool isEmpty;
  final bool isLightTheme;
  final String fontFamily;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final textColor = isLightTheme
        ? (isEmpty ? Colors.grey : const Color(0xFF1B5E20))
        : (isEmpty ? Colors.white54 : Colors.white);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Text(
        text,
        style: TextStyle(
          fontFamily: fontFamily,
          fontSize: fontSize,
          color: textColor,
          height: 1.7,
        ),
        textDirection: TextDirection.rtl,
      ),
    );
  }
}

/// زر عداد التكرار: عادي ثم يكبر ويصبح دائرياً عند البدء، ويرجع طبيعياً ويتوقف عند الوصول للهدف
class _AzkarCounterButton extends StatelessWidget {
  final int current;
  final int repeat;
  final String Function(int) toNormalDigits;
  final TextStyle Function(
      {required double fontSize,
      required Color color,
      FontWeight fontWeight}) quranStyle;
  final VoidCallback? onTap;

  const _AzkarCounterButton({
    required this.current,
    required this.repeat,
    required this.toNormalDigits,
    required this.quranStyle,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final reached = current >= repeat;
    final counting = current > 0 && !reached;
    final isBig = counting;
    final width = isBig ? 112.0 : 58.0;
    final height = isBig ? 76.0 : 46.0;
    final borderRadius = BorderRadius.circular(isBig ? 22 : 14);

    return Material(
      color: reached ? const Color(0xFF2E7D32) : const Color(0xFFE8F5E9),
      borderRadius: borderRadius,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        customBorder: RoundedRectangleBorder(borderRadius: borderRadius),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          width: width,
          height: height,
          alignment: Alignment.center,
          child: Text(
            toNormalDigits(current),
            style: quranStyle(
                fontSize: isBig ? 28 : 18,
                color: reached ? Colors.white : const Color(0xFF1B5E20),
                fontWeight: FontWeight.bold),
          ),
        ),
      ),
    );
  }
}

/// محتوى شاشة الأذكار: قائمة + تفاصيل مع رجوع وعداد تكرار
class _AzkarSheetContent extends StatefulWidget {
  final List<
      ({
        int id,
        String title,
        String? titleAr,
        String? audioUrl,
        List<
            ({
              int id,
              String arabicText,
              String? languageArabicTranslatedText,
              String? translatedText,
              int repeat,
              String? audio
            })> texts
      })> azkarList;
  final String Function(int) toNormalDigits;
  final TextStyle Function(
      {required double fontSize,
      required Color color,
      FontWeight fontWeight}) quranStyle;
  final RegExp arabicRegex;

  /// رجوع خطوة واحدة (مثلاً إلى القائمة الرئيسية).
  final VoidCallback onBack;
  final VoidCallback onDismissAll;
  final String sheetTitle;

  const _AzkarSheetContent({
    required this.azkarList,
    required this.toNormalDigits,
    required this.quranStyle,
    required this.arabicRegex,
    required this.onBack,
    required this.onDismissAll,
    this.sheetTitle = 'أذكار وأدعية',
  });

  @override
  State<_AzkarSheetContent> createState() => _AzkarSheetContentState();
}

class _AzkarSheetContentState extends State<_AzkarSheetContent> {
  int? _selectedIndex;
  List<int> _counts = [];
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';

  /// يُشغَّل عبر [AyahAudioPlayer.playAzkarAudio] — نفس مشغّل الآيات وإشعار الوسائط.
  int? _playingGroupIndex;
  bool _audioPlayerVisible = false;
  bool _audioLoading = false;
  bool _audioPlaying = false;

  void _syncAzkarPlayerUi() {
    if (!mounted) return;
    final p = AyahAudioPlayer.instance;
    if (p.isAzkarSession) {
      setState(() {
        _audioPlaying = p.state == AyahPlayerState.playing;
        _audioLoading = p.state == AyahPlayerState.loading;
        if (p.isActive) _audioPlayerVisible = true;
      });
    } else {
      if (_audioPlayerVisible || _playingGroupIndex != null) {
        setState(() {
          _audioPlayerVisible = false;
          _playingGroupIndex = null;
          _audioPlaying = false;
          _audioLoading = false;
        });
      }
    }
  }

  @override
  void initState() {
    super.initState();
    AyahAudioPlayer.instance.addListener(_syncAzkarPlayerUi);
    _syncAzkarPlayerUi();
  }

  @override
  void dispose() {
    AyahAudioPlayer.instance.removeListener(_syncAzkarPlayerUi);
    _searchController.dispose();
    super.dispose();
  }

  bool _matchesSearch(int index) {
    if (_searchQuery.trim().isEmpty) return true;
    final q = _normalizeForSearch(_searchQuery.trim());
    final zikr = widget.azkarList[index];
    final titleAr = _normalizeForSearch(zikr.titleAr ?? '');
    final title = _normalizeForSearch(zikr.title);
    if (titleAr.contains(q) || title.contains(q)) return true;
    for (final t in zikr.texts) {
      final arabicText = _normalizeForSearch(t.arabicText);
      final translatedText = _normalizeForSearch(t.translatedText ?? '');
      final languageArabicTranslatedText =
          _normalizeForSearch(t.languageArabicTranslatedText ?? '');
      if (arabicText.contains(q) ||
          translatedText.contains(q) ||
          languageArabicTranslatedText.contains(q)) return true;
    }
    return false;
  }

  String _normalizeForSearch(String s) {
    // إزالة الحركات (التشكيل)
    String normalized = s.replaceAll(RegExp(r'[\u064B-\u065F\u0670]'), '');
    // إزالة علامات التشكيل الأخرى
    normalized = normalized.replaceAll(RegExp(r'[\u0610-\u061A\u0640]'), '');
    // توحيد الهمزات
    normalized = normalized
        .replaceAll('أ', 'ا')
        .replaceAll('إ', 'ا')
        .replaceAll('آ', 'ا')
        .replaceAll('ء', 'ا')
        .replaceAll('ؤ', 'و')
        .replaceAll('ئ', 'ي')
        .replaceAll('ى', 'ي')
        .replaceAll('ة', 'ه');
    return normalized.toLowerCase();
  }

  void _openZikr(int index) {
    setState(() {
      _selectedIndex = index;
      _counts = List.filled(widget.azkarList[index].texts.length, 0);
    });
  }

  void _back() {
    setState(() {
      _selectedIndex = null;
      _counts = [];
    });
  }

  void _incrementCounter(int itemIndex) {
    if (_selectedIndex == null || itemIndex >= _counts.length) return;
    final target = widget.azkarList[_selectedIndex!].texts[itemIndex].repeat;
    final before = _counts[itemIndex];
    setState(() {
      _counts[itemIndex] = _counts[itemIndex] + 1;
    });
    final after = _counts[itemIndex];
    if (before < target && after >= target) {
      unawaited(_notifyCounterComplete());
    }
  }

  Future<void> _notifyCounterComplete() async {
    await _vibrateOnCounterComplete();
    try {
      await SystemSound.play(SystemSoundType.alert);
    } catch (_) {
      // قد لا يدعم بعض الأجهزة نوع الصوت هذا
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        duration: const Duration(milliseconds: 900),
        backgroundColor: const Color(0xFF1B5E20),
        content: Text(
          'اكتمل العدد لهذا الذكر',
          style: widget.quranStyle(fontSize: 14, color: Colors.white),
        ),
      ),
    );
  }

  Future<void> _vibrateOnCounterComplete() async {
    // اهتزاز فعلي قصير (أقل من ثانية) مع fallback إلى HapticFeedback.
    try {
      final hasVibrator = await Vibration.hasVibrator();
      if (hasVibrator) {
        final hasAmplitudeControl = await Vibration.hasAmplitudeControl();
        await Vibration.vibrate(
          duration: 280,
          amplitude: hasAmplitudeControl ? 180 : -1,
        );
        return;
      }
    } catch (_) {
      // fallback below
    }
    await HapticFeedback.heavyImpact();
    await Future.delayed(const Duration(milliseconds: 120));
    await HapticFeedback.vibrate();
  }

  bool _hasPlayableAudio(int index) {
    if (index < 0 || index >= widget.azkarList.length) return false;
    final url = widget.azkarList[index].audioUrl?.trim() ?? '';
    return url.isNotEmpty;
  }

  int? _previousPlayableIndex() {
    final current = _playingGroupIndex;
    if (current == null) return null;
    for (int i = current - 1; i >= 0; i--) {
      if (_hasPlayableAudio(i)) return i;
    }
    return null;
  }

  int? _nextPlayableIndex() {
    final current = _playingGroupIndex;
    if (current == null) return null;
    for (int i = current + 1; i < widget.azkarList.length; i++) {
      if (_hasPlayableAudio(i)) return i;
    }
    return null;
  }

  Future<void> _playGroup(int index) async {
    if (!_hasPlayableAudio(index)) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'لا يوجد ملف صوتي لهذه المجموعة',
            style: widget.quranStyle(fontSize: 14, color: Colors.white),
          ),
          backgroundColor: const Color(0xFF2E7D32),
        ),
      );
      return;
    }
    final url =
        _normalizeAzkarAudioUrl(widget.azkarList[index].audioUrl!.trim());
    final zikr = widget.azkarList[index];
    final rawTitle = (zikr.titleAr ?? zikr.title).trim();
    final title = rawTitle.isEmpty ? 'أذكار وأدعية' : rawTitle;
    setState(() {
      _playingGroupIndex = index;
      _audioPlayerVisible = true;
      _audioLoading = true;
    });
    try {
      final ok = await AyahAudioPlayer.instance
          .playAzkarAudio(url, title: title)
          .timeout(const Duration(seconds: 28));
      if (!mounted) return;
      if (!ok) {
        setState(() {
          _audioLoading = false;
          _audioPlaying = false;
          _audioPlayerVisible = false;
          _playingGroupIndex = null;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'تعذر تشغيل صوت المجموعة',
              style: widget.quranStyle(fontSize: 14, color: Colors.white),
            ),
            backgroundColor: const Color(0xFFB71C1C),
          ),
        );
      }
    } on TimeoutException {
      await AyahAudioPlayer.instance.stop();
      if (!mounted) return;
      setState(() {
        _audioLoading = false;
        _audioPlaying = false;
        _audioPlayerVisible = false;
        _playingGroupIndex = null;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'انتهت مهلة تحميل الصوت، جرّب مرة أخرى',
            style: widget.quranStyle(fontSize: 14, color: Colors.white),
          ),
          backgroundColor: const Color(0xFFB71C1C),
        ),
      );
    } catch (_) {
      await AyahAudioPlayer.instance.stop();
      if (!mounted) return;
      setState(() {
        _audioLoading = false;
        _audioPlaying = false;
        _audioPlayerVisible = false;
        _playingGroupIndex = null;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'تعذر تشغيل صوت المجموعة',
            style: widget.quranStyle(fontSize: 14, color: Colors.white),
          ),
          backgroundColor: const Color(0xFFB71C1C),
        ),
      );
    }
  }

  String _normalizeAzkarAudioUrl(String url) {
    final parsed = Uri.tryParse(url);
    if (parsed == null) return url;
    // بعض روابط hisn.json تستخدم download.media.islamway.net
    // بينما الشهادة صالحة لـ static.media.islamway.net فقط.
    if (parsed.host.toLowerCase() == 'download.media.islamway.net') {
      return parsed.replace(host: 'static.media.islamway.net').toString();
    }
    return url;
  }

  Future<void> _togglePlayPause() async {
    if (_audioLoading) {
      await AyahAudioPlayer.instance.stop();
      if (!mounted) return;
      setState(() {
        _audioLoading = false;
        _audioPlaying = false;
      });
      return;
    }
    final current = _playingGroupIndex;
    if (current == null) {
      final firstPlayable = widget.azkarList.indexWhere((z) {
        final url = z.audioUrl?.trim() ?? '';
        return url.isNotEmpty;
      });
      if (firstPlayable >= 0) {
        await _playGroup(firstPlayable);
      }
      return;
    }
    final p = AyahAudioPlayer.instance;
    if (!p.isAzkarSession) {
      await _playGroup(current);
      return;
    }
    if (_audioPlaying) {
      await p.pause();
    } else {
      await p.resume();
    }
  }

  Future<void> _playPreviousGroup() async {
    final prev = _previousPlayableIndex();
    if (prev == null) return;
    await _playGroup(prev);
  }

  Future<void> _playNextGroup() async {
    final next = _nextPlayableIndex();
    if (next == null) return;
    await _playGroup(next);
  }

  Future<void> _closeAudioPlayer() async {
    await AyahAudioPlayer.instance.stop();
    if (!mounted) return;
    setState(() {
      _audioPlayerVisible = false;
      _playingGroupIndex = null;
      _audioPlaying = false;
      _audioLoading = false;
    });
  }

  Future<void> _cancelLoadingOrStop() async {
    await AyahAudioPlayer.instance.stop();
    if (!mounted) return;
    setState(() {
      _audioLoading = false;
      _audioPlaying = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final content = _selectedIndex != null
        ? _buildDetails(context, _selectedIndex!)
        : _buildList(context);
    return Stack(
      children: [
        Padding(
          padding: EdgeInsets.only(bottom: _audioPlayerVisible ? 96 : 0),
          child: content,
        ),
        if (_audioPlayerVisible)
          Positioned(
            left: 12,
            right: 12,
            bottom: 8,
            child: _buildAzkarMiniPlayer(),
          ),
      ],
    );
  }

  Widget _buildList(BuildContext context) {
    final pal = QuranMenuPalette.of(context);
    final list = widget.azkarList;
    final indices = List.generate(list.length, (i) => i)
        .where((i) => _matchesSearch(i))
        .toList();
    return Column(
      children: [
        NestedQuranMenuAppBar(
          title: widget.sheetTitle,
          titleStyle: widget.quranStyle(
              fontSize: 20, color: pal.title, fontWeight: FontWeight.bold),
          onBack: widget.onBack,
          onDismissAll: widget.onDismissAll,
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: TextField(
            controller: _searchController,
            onChanged: (v) => setState(() => _searchQuery = v),
            decoration: InputDecoration(
              hintText: 'بحث في العناوين أو الذكر...',
              prefixIcon: Icon(Icons.search, color: pal.azkarAccentIcon),
              filled: true,
              fillColor: pal.searchFieldFill,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            ),
            style: widget.quranStyle(
                fontSize: 16,
                color: pal.searchFieldText,
                fontWeight: FontWeight.normal),
          ),
        ),
        Divider(height: 1, color: pal.divider),
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            itemCount: indices.length,
            separatorBuilder: (_, __) => const SizedBox(height: 16),
            itemBuilder: (context, listIndex) {
              final index = indices[listIndex];
              final zikr = list[index];
              return InkWell(
                onTap: () => _openZikr(index),
                child: Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: pal.cardSurface,
                    borderRadius: BorderRadius.circular(12),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.05),
                        blurRadius: 4,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              zikr.titleAr ??
                                  'مجموعة أذكار ${widget.toNormalDigits(index + 1)}',
                              style: widget.quranStyle(
                                  fontSize: 18,
                                  color: pal.title,
                                  fontWeight: FontWeight.bold),
                            ),
                          ),
                          IconButton(
                            onPressed: _hasPlayableAudio(index)
                                ? () => _playGroup(index)
                                : null,
                            tooltip: 'تشغيل صوت المجموعة',
                            icon: Transform.rotate(
                              angle: 3.14159265359,
                              child: Icon(
                                Icons.play_circle_fill_rounded,
                                size: 24,
                                color: _hasPlayableAudio(index)
                                    ? pal.azkarAccentIcon
                                    : pal.trailingChevron,
                              ),
                            ),
                          ),
                          Icon(
                            Icons.arrow_forward_ios,
                            size: 16,
                            color: pal.azkarAccentIcon,
                          ),
                        ],
                      ),
                      if (zikr.texts.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Text(
                          'عدد الأذكار: ${widget.toNormalDigits(zikr.texts.length)}',
                          style: widget.quranStyle(
                              fontSize: 14,
                              color: pal.subtitle,
                              fontWeight: FontWeight.normal),
                        ),
                      ],
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildDetails(BuildContext context, int index) {
    final pal = QuranMenuPalette.of(context);
    final zikr = widget.azkarList[index];
    final arabicTitle =
        zikr.titleAr ?? 'مجموعة أذكار ${widget.toNormalDigits(index + 1)}';
    return Column(
      children: [
        NestedQuranMenuAppBar(
          title: arabicTitle,
          titleStyle: widget.quranStyle(
              fontSize: 18, color: pal.title, fontWeight: FontWeight.bold),
          onBack: _back,
          onDismissAll: widget.onDismissAll,
        ),
        if (_hasPlayableAudio(index))
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: IconButton(
              icon: Transform.rotate(
                angle: 3.14159265359,
                child: Icon(
                  (_playingGroupIndex == index && _audioPlaying)
                      ? Icons.pause_circle_filled_rounded
                      : Icons.play_circle_fill_rounded,
                  color: pal.azkarAccentIcon,
                ),
              ),
              tooltip: 'تشغيل صوت المجموعة',
              onPressed: () async {
                final p = AyahAudioPlayer.instance;
                if (_playingGroupIndex == index && p.isAzkarSession) {
                  if (_audioPlaying) {
                    await p.pause();
                  } else {
                    await p.resume();
                  }
                } else {
                  await _playGroup(index);
                }
              },
            ),
          ),
        Divider(height: 1, color: pal.divider),
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            itemCount: zikr.texts.length,
            separatorBuilder: (_, __) => const SizedBox(height: 16),
            itemBuilder: (context, itemIndex) {
              final text = zikr.texts[itemIndex];
              final current =
                  itemIndex < _counts.length ? _counts[itemIndex] : 0;
              final reached = current >= text.repeat;
              final showLangAr = text.languageArabicTranslatedText != null &&
                  text.languageArabicTranslatedText!.isNotEmpty &&
                  widget.arabicRegex
                      .hasMatch(text.languageArabicTranslatedText!);
              return Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: pal.cardSurface,
                  borderRadius: BorderRadius.circular(12),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.05),
                      blurRadius: 4,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      text.arabicText,
                      style: widget.quranStyle(
                          fontSize: 22,
                          color: pal.isDark ? pal.title : Colors.black87,
                          fontWeight: FontWeight.w500),
                      textAlign: TextAlign.right,
                    ),
                    const SizedBox(height: 12),
                    if (showLangAr) ...[
                      Text(
                        text.languageArabicTranslatedText!,
                        style: widget.quranStyle(
                            fontSize: 16,
                            color: pal.accent,
                            fontWeight: FontWeight.w600),
                        textAlign: TextAlign.right,
                      ),
                      const SizedBox(height: 8),
                    ],
                    Row(
                      children: [
                        // الزر على اليمين (في RTL أول عنصر يكون على اليمين)
                        Tooltip(
                          message: 'اضغط عند كل مرة تقول فيها الذكر',
                          child: _AzkarCounterButton(
                            current: current,
                            repeat: text.repeat,
                            toNormalDigits: widget.toNormalDigits,
                            quranStyle: widget.quranStyle,
                            onTap: reached
                                ? null
                                : () => _incrementCounter(itemIndex),
                          ),
                        ),
                        const Spacer(),
                        // عدد المرات على اليسار
                        Text(
                          'عدد المرات: ${widget.toNormalDigits(text.repeat)}',
                          style: widget.quranStyle(
                              fontSize: 14,
                              color: const Color(0xFF2E7D32),
                              fontWeight: FontWeight.w600),
                        ),
                      ],
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildAzkarMiniPlayer() {
    final idx = _playingGroupIndex;
    final groupName = idx != null && idx >= 0 && idx < widget.azkarList.length
        ? (widget.azkarList[idx].titleAr ?? widget.azkarList[idx].title)
        : 'مشغل الأذكار';
    return Material(
      elevation: 12,
      borderRadius: BorderRadius.circular(12),
      color: const Color.fromARGB(255, 8, 32, 16).withValues(alpha: 0.96),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                const SizedBox(width: 32),
                Expanded(
                  child: Text(
                    groupName,
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: widget.quranStyle(
                      fontSize: 15,
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                IconButton(
                  onPressed: _closeAudioPlayer,
                  icon: const Icon(Icons.close, color: Colors.white70),
                  tooltip: 'إغلاق',
                ),
              ],
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                Expanded(
                  child: _buildAzkarControlButton(
                    iconWidget: Transform.rotate(
                      angle: 3.14159265359,
                      child:
                          const Icon(Icons.skip_previous, color: Colors.white),
                    ),
                    label: 'السابق',
                    onPressed: _previousPlayableIndex() != null
                        ? _playPreviousGroup
                        : null,
                  ),
                ),
                Expanded(
                  child: _buildAzkarControlButton(
                    iconWidget: Transform.rotate(
                      angle: 3.14159265359,
                      child: Icon(
                        _audioLoading
                            ? Icons.stop_circle_outlined
                            : (_audioPlaying ? Icons.pause : Icons.play_arrow),
                        color: Colors.white,
                      ),
                    ),
                    label: _audioLoading
                        ? 'إيقاف'
                        : (_audioPlaying ? 'إيقاف مؤقت' : 'تشغيل'),
                    onPressed:
                        _audioLoading ? _cancelLoadingOrStop : _togglePlayPause,
                    iconSize: 28,
                  ),
                ),
                Expanded(
                  child: _buildAzkarControlButton(
                    iconWidget: Transform.rotate(
                      angle: 3.14159265359,
                      child: const Icon(Icons.skip_next, color: Colors.white),
                    ),
                    label: 'التالي',
                    onPressed:
                        _nextPlayableIndex() != null ? _playNextGroup : null,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAzkarControlButton({
    IconData? icon,
    Widget? iconWidget,
    required String label,
    required Future<void> Function()? onPressed,
    double iconSize = 24,
  }) {
    final enabled = onPressed != null;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          icon: iconWidget ?? Icon(icon, color: Colors.white),
          iconSize: iconSize,
          onPressed: onPressed == null
              ? null
              : () async {
                  await onPressed();
                },
        ),
        Text(
          label,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: widget.quranStyle(
            fontSize: 13,
            color: enabled ? Colors.white70 : Colors.white38,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }
}
