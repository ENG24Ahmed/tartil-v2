import 'dart:async';
import 'dart:convert';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
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
import '../quran/ayah_long_press_scope.dart';
import '../quran/font_loader.dart';
import '../quran/models/mushaf_line.dart';
import '../quran/qpc_v1_loader.dart' show loadQpcV1Page;
import '../quran/quran_db.dart';
import '../quran/compact_line_spacing_scope.dart';
import '../quran/quran_reader.dart'
    show QuranReader, QpcMushafMode, buildQpcPageContent;
import '../quran/renderers/qpc_v4_renderer.dart'
    show
        AyahHighlightStore,
        AyahRangeHighlight,
        preloadNearbyPages,
        QpcV4Renderer;
import '../services/qpc_glyph_db.dart';
import '../features/developer/developer_options_screen.dart';
import '../quran/page_background_loader.dart';
import '../onboarding/mushaf_intro_prefs.dart';
import '../widgets/mushaf_intro_overlay.dart';

/// نوع العرض: افتراضي، أفقي، صفحتان، قراءة طويلة، قراءة أفقية طويلة
enum DisplayType {
  standard,
  horizontal,
  twoPage,
  longScroll,
  horizontalLongScroll
}

/// يلتقط "نقرة" من دون تعطيل السحب/التمرير للأبناء.
class _PassiveTapListener extends StatefulWidget {
  const _PassiveTapListener({
    required this.child,
    required this.onTap,
  });

  final Widget child;
  final VoidCallback onTap;

  @override
  State<_PassiveTapListener> createState() => _PassiveTapListenerState();
}

class _PassiveTapListenerState extends State<_PassiveTapListener> {
  Offset? _down;
  DateTime? _downTime;
  static const double _tapSlop = 18;
  static const Duration _tapMaxDuration = Duration(milliseconds: 300);

  void _onPointerDown(PointerDownEvent e) {
    _down = e.position;
    _downTime = DateTime.now();
  }

  void _onPointerUp(PointerUpEvent e) {
    final down = _down;
    final downTime = _downTime;
    _down = null;
    _downTime = null;
    if (down == null || downTime == null) return;
    final dx = (e.position.dx - down.dx).abs();
    final dy = (e.position.dy - down.dy).abs();
    final duration = DateTime.now().difference(downTime);
    if (dx <= _tapSlop && dy <= _tapSlop && duration <= _tapMaxDuration) {
      widget.onTap();
    }
  }

  void _onPointerCancel(PointerCancelEvent _) {
    _down = null;
    _downTime = null;
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.deferToChild,
      onPointerDown: _onPointerDown,
      onPointerUp: _onPointerUp,
      onPointerCancel: _onPointerCancel,
      child: widget.child,
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

class QuranPageViewer extends StatefulWidget {
  const QuranPageViewer({super.key});

  @override
  State<QuranPageViewer> createState() => _QuranPageViewerState();
}

class _QuranPageViewerState extends State<QuranPageViewer> {
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
  Timer? _inactivityTimer;
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

  DisplayType _displayType = DisplayType.standard;
  bool _horizontalRotationEnabled = true;
  bool _autoScrollEnabled = false;
  double _autoScrollSpeed = 0.5;
  Timer? _autoScrollTimer;
  ScrollController? _longScrollController;
  ScrollController? _horizontalScrollController;
  ScrollController? _horizontalLongScrollController;
  bool _longScrollBarCollapsed = false;
  bool _horizontalLongScrollNeedsInitialJump = false;
  Timer? _longScrollBarIdleTimer;
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

  /// تعليم أول تشغيل (قائمة / ضغط مطوّل / القارئ)
  final GlobalKey _introMushafAreaKey = GlobalKey();
  final GlobalKey _introReciterKey = GlobalKey();
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

  @override
  void initState() {
    super.initState();
    _pageController = PageController();
    _pageController.addListener(_onPageChanged);
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
      final itemExtent = screenHeight;
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
      const verticalMarginFraction = 0.02;
      const visibleQuarterFraction = 4.0;
      const refWidth = 360.0;
      const baseScale = 0.65;
      final widthScale = (screenWidth / refWidth).clamp(0.6, 1.2);
      final windowHeight = screenHeight * (1 - 2 * verticalMarginFraction);
      final itemExtent = (windowHeight / _mushafAspectRatio) *
          visibleQuarterFraction *
          baseScale *
          widthScale;
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
      _showOptionsSheet(context, _currentPageIndex);
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
    preloadNearbyPages(targetIndex + 1);

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
      final itemExtent = screenHeight;
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
      final itemExtent = _horizontalLongItemExtent(screenWidth, screenHeight);
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
  void dispose() {
    AyahAudioPlayer.instance.removeListener(_onAyahPlayerChanged);
    _pageController.removeListener(_onPageChanged);
    _longScrollController?.dispose();
    _horizontalScrollController?.dispose();
    _horizontalLongScrollController?.dispose();
    _autoScrollTimer?.cancel();
    _longScrollBarIdleTimer?.cancel();
    _inactivityTimer?.cancel();
    WakelockPlus.disable();
    _pageController.dispose();
    super.dispose();
  }

  void _onPageChanged() {
    final raw = (_pageController.page ?? 0).round();
    final p = raw.clamp(0, totalPages - 1);
    if (p != _currentPageIndex) {
      _currentPageIndex = p;
      PageBackgroundLoader.instance.setCurrentPage(p + 1);
      _saveCurrentPage(p);
      setState(() {});
    }
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
    _syncAyahHighlightsStore();
    final displayTypeStr = prefs.getString(_keyDisplayType);
    if (displayTypeStr != null) {
      switch (displayTypeStr) {
        case 'longScroll':
          _displayType = DisplayType.longScroll;
          _longScrollNeedsInitialJump = true;
          break;
        case 'horizontalLongScroll':
          _displayType = DisplayType.horizontalLongScroll;
          _horizontalLongScrollNeedsInitialJump = true;
          break;
        case 'horizontal':
        case 'twoPage':
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
    await MushafIntroPrefs.migrateLegacyUsers();
    if (await MushafIntroPrefs.isCompleted()) {
      _mushafIntroStep = MushafIntroPrefs.completedMarker;
    } else {
      _mushafIntroStep = await MushafIntroPrefs.loadStep();
    }
    setState(() {});
    _startBackgroundLoader();
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
    await prefs.setBool(_keyHorizontalRotation, _horizontalRotationEnabled);
    await prefs.setBool(_keyAutoScrollEnabled, _autoScrollEnabled);
    await prefs.setDouble(_keyAutoScrollSpeed, _autoScrollSpeed);
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
    final prefs = await SharedPreferences.getInstance();
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
      fontFamily: 'QuranUthmani',
      fontSize: fontSize,
      color: color,
      fontWeight: fontWeight,
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

  /// قائمة الضغط المطول على آية: نافذة عائمة عصريّة
  void _showAyahLongPressMenu(
    BuildContext context,
    int sura,
    int ayah,
    String ayahText,
    VoidCallback onClearSelection,
  ) {
    final suraName = _suraNameFromNo(sura);
    final isHighlightingDisabledByAudio = _isAyahHighlightingDisabledByAudio;
    final reciterName = kAyahReciters
            .where((r) => r.id == AyahAudioPlayer.instance.currentReciterId)
            .firstOrNull
            ?.nameAr ??
        'القارئ الحالي';
    showDialog<void>(
      context: context,
      barrierColor: Colors.black26,
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: Center(
          child: Material(
            color: Colors.transparent,
            child: Container(
              constraints: BoxConstraints(
                maxWidth: 280,
                maxHeight: MediaQuery.of(ctx).size.height * 0.35,
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
                      '$suraName – الآية ${_toNormalDigits(ayah)}',
                      style: _quranStyle(
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
                          _AyahMenuItem(
                            icon: Icons.volume_up_outlined,
                            label: 'الاستماع للآية',
                            subtitle: 'تلاوة $reciterName',
                            enabled: true,
                            onTap: () async {
                              Navigator.pop(ctx);
                              final ok = await AyahAudioPlayer.instance
                                  .playAyah(sura, ayah);
                              if (!ctx.mounted) return;
                              if (!ok) {
                                ScaffoldMessenger.of(ctx).showSnackBar(
                                  SnackBar(
                                    content: Text(
                                      'تعذر تشغيل تلاوة هذه الآية',
                                      style: _quranStyle(
                                          fontSize: 14, color: Colors.white),
                                    ),
                                    backgroundColor: const Color(0xFF2E7D32),
                                  ),
                                );
                              }
                            },
                          ),
                          _AyahMenuItem(
                            icon: Icons.menu_book_outlined,
                            label: 'التفسير',
                            subtitle: 'السعدي / الميسّر',
                            onTap: () {
                              Navigator.pop(ctx);
                              _showTafseerForAyah(context, sura, ayah, suraName,
                                  onClearSelection);
                            },
                          ),
                          _AyahMenuItem(
                            icon: Icons.highlight,
                            label: 'التضليل',
                            subtitle: isHighlightingDisabledByAudio
                                ? 'متوقف أثناء الاستماع'
                                : 'تضليل الآية أو نطاق آيات',
                            enabled: !isHighlightingDisabledByAudio,
                            onTap: () {
                              Navigator.pop(ctx);
                              _showAyahHighlightSheet(
                                context,
                                sura: sura,
                                ayah: ayah,
                              );
                            },
                          ),
                          _AyahMenuItem(
                            icon: Icons.copy,
                            label: 'نسخ الآية',
                            onTap: () {
                              Clipboard.setData(ClipboardData(text: ayahText));
                              Navigator.pop(ctx);
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
    ).then((_) => onClearSelection());
  }

  Future<void> _applyAyahHighlightRange({
    required int sura,
    required int fromAyah,
    required int toAyah,
    required Color color,
  }) async {
    final ayahCount = (_suraAyahCount[sura] ?? 286).clamp(1, 286);
    final from = fromAyah.clamp(1, ayahCount);
    final to = toAyah.clamp(1, ayahCount);
    setState(() {
      _ayahHighlights.add((
        sura: sura,
        fromAyah: from <= to ? from : to,
        toAyah: from <= to ? to : from,
        color: color,
      ));
    });
    _syncAyahHighlightsStore();
    await _saveBookmarks();
  }

  Future<void> _showAyahHighlightSheet(
    BuildContext context, {
    required int sura,
    required int ayah,
  }) async {
    if (_isAyahHighlightingDisabledByAudio) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'التضليل متوقف أثناء الاستماع',
            style: _quranStyle(fontSize: 14, color: Colors.white),
          ),
          backgroundColor: const Color(0xFF2E7D32),
        ),
      );
      return;
    }
    final suraFoundIndex = _suraList.indexWhere((s) => s.no == sura);
    final initialSuraIndex = (suraFoundIndex < 0 ? 0 : suraFoundIndex)
        .clamp(0, _suraList.length - 1);
    int selectedSuraIndex = initialSuraIndex;
    int selectedSura = _suraList[selectedSuraIndex].no;
    int ayahCount = (_suraAyahCount[selectedSura] ?? 286).clamp(1, 286);
    int fromAyah = ayah.clamp(1, ayahCount);
    int toAyah = ayah.clamp(1, ayahCount);
    Color selectedColor = Colors.yellow;
    final colors = <Color>[
      Colors.yellow,
      Colors.green,
      Colors.lightBlue,
      Colors.orange,
      Colors.pink,
      Colors.purpleAccent,
    ];
    final suraController =
        FixedExtentScrollController(initialItem: selectedSuraIndex);
    final fromController =
        FixedExtentScrollController(initialItem: fromAyah - 1);
    final toController = FixedExtentScrollController(initialItem: toAyah - 1);

    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFFE8F5E9),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      isScrollControlled: true,
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: StatefulBuilder(
          builder: (ctx, setLocalState) => Padding(
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
                    'تضليل الآيات',
                    textAlign: TextAlign.center,
                    style: _quranStyle(
                      fontSize: 19,
                      color: const Color(0xFF1B5E20),
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Container(
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: const Color(0xFF1B5E20).withValues(alpha: 0.12),
                      ),
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
                          child: _AyahWheelPicker(
                            title: 'السورة',
                            controller: suraController,
                            itemCount: _suraList.length,
                            itemBuilder: (i) =>
                                '${i + 1} ${_suraList[i].nameAr.replaceAll('سورة ', '')}',
                            onSelectedItemChanged: (i) {
                              setLocalState(() {
                                selectedSuraIndex = i;
                                selectedSura = _suraList[i].no;
                                ayahCount =
                                    (_suraAyahCount[selectedSura] ?? 286)
                                        .clamp(1, 286);
                                if (fromAyah > ayahCount) fromAyah = ayahCount;
                                if (toAyah > ayahCount) toAyah = ayahCount;
                              });
                              if (fromController.selectedItem != fromAyah - 1) {
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
                          child: _AyahWheelPicker(
                            title: 'من آية',
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
                          child: _AyahWheelPicker(
                            title: 'إلى آية',
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
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: const Color(0xFF1B5E20).withValues(alpha: 0.12),
                      ),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: colors.map((c) {
                        final selected =
                            c.toARGB32() == selectedColor.toARGB32();
                        return Flexible(
                          child: ChoiceChip(
                            label: Text(
                              selected ? 'مختار' : 'لون',
                              style: _quranStyle(
                                fontSize: 12,
                                color: selected
                                    ? Colors.white
                                    : const Color(0xFF1B5E20),
                              ),
                            ),
                            selected: selected,
                            selectedColor: c,
                            backgroundColor: c.withValues(alpha: 0.24),
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
                            foregroundColor: const Color(0xFF1B5E20),
                            side: BorderSide(
                              color: const Color(0xFF1B5E20)
                                  .withValues(alpha: 0.5),
                            ),
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                          ),
                          onPressed: () => Navigator.pop(ctx),
                          icon: const Icon(Icons.close),
                          label: Text(
                            'إلغاء التضليل',
                            style: _quranStyle(
                              fontSize: 16,
                              color: const Color(0xFF1B5E20),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF2E7D32),
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                          ),
                          onPressed: () async {
                            Navigator.pop(ctx);
                            await _applyAyahHighlightRange(
                              sura: selectedSura,
                              fromAyah: fromAyah,
                              toAyah: toAyah,
                              color: selectedColor,
                            );
                            if (!context.mounted) return;
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(
                                  'تم حفظ التضليل من آية ${_toNormalDigits(fromAyah)} إلى ${_toNormalDigits(toAyah)}',
                                  style: _quranStyle(
                                      fontSize: 14, color: Colors.white),
                                ),
                                backgroundColor: const Color(0xFF2E7D32),
                              ),
                            );
                          },
                          icon: const Icon(Icons.highlight),
                          label: Text(
                            'تطبيق التضليل',
                            style:
                                _quranStyle(fontSize: 16, color: Colors.white),
                          ),
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

  /// فتح تبويبة اختيار الآيات من القائمة الرئيسية — التحديد التلقائي: السورة والآيات في الصفحة الحالية
  void _showTafseerFromMainMenu(BuildContext context) {
    final pageNumber = _currentPageIndex + 1;
    final list = _ayahList.where((a) => a.page == pageNumber).toList();
    if (list.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
          'لا توجد آيات في هذه الصفحة',
          style: _quranStyle(fontSize: 14, color: Colors.white),
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

    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFFE8F5E9),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: _TafseerRangePickerSheet(
          sura: firstSura,
          fromAyah: from,
          toAyah: to,
          suraList: _suraList,
          suraAyahCount: _suraAyahCount,
          toNormalDigits: _toNormalDigits,
          quranStyle: _quranStyle,
          maxAyat: 30,
          onChanged: (s, f, t) {},
          onConfirm: (s, f, t) {
            Navigator.pop(ctx);
            _showTafseerForAyahWithRange(context, s, f, t);
          },
        ),
      ),
    );
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
        quranStyle: _quranStyle,
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
        quranStyle: _quranStyle,
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
          style: _quranStyle(fontSize: 14, color: Colors.white),
        ),
        backgroundColor: const Color(0xFF2E7D32),
      ));
      return;
    }

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFFE8F5E9),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: SafeArea(
          child: SizedBox(
            height: MediaQuery.of(ctx).size.height * 0.9,
            child: _AzkarSheetContent(
              azkarList: azkarList,
              sheetTitle: sheetTitle,
              toNormalDigits: _toNormalDigits,
              quranStyle: _quranStyle,
              arabicRegex: _arabicRegex,
              onClose: () => Navigator.pop(ctx),
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
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
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
                style: _quranStyle(fontSize: 15, color: _mushafTopBarMainColor),
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
                style: _quranStyle(fontSize: 12, color: _mushafTopBarMainColor)
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

    return ColoredBox(
      color: _mushafBackgroundColor,
      child: Scaffold(
        backgroundColor: Colors.transparent,
        resizeToAvoidBottomInset: false,
        body: _buildQpcBody(),
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
            final itemExtent = screenHeight;
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
            const verticalMarginFraction = 0.02;
            const visibleQuarterFraction = 4.0;
            const refWidth = 360.0;
            const baseScale = 0.65;
            final widthScale = (screenWidth / refWidth).clamp(0.6, 1.2);
            final windowHeight =
                screenHeight * (1 - 2 * verticalMarginFraction);
            final fullPageWidth = (windowHeight / _mushafAspectRatio) *
                visibleQuarterFraction *
                baseScale *
                widthScale;
            final target = (_currentPageIndex * fullPageWidth)
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
      onPointerDown: (_) => _resetInactivityTimer(),
      child: Directionality(
        textDirection: TextDirection.rtl,
        child: Stack(
          children: [
            Column(
              children: [
                SafeArea(
                  bottom: false,
                  left: false,
                  right: false,
                  child: const SizedBox.shrink(),
                ),
                Expanded(
                  child: ColoredBox(
                    color: _mushafBackgroundColor,
                    child: KeyedSubtree(
                      key: _introMushafAreaKey,
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
        if (mounted) setState(() => _mushafIntroStep = MushafIntroPrefs.stepLongPress);
        break;
      case MushafIntroPrefs.stepLongPress:
        await MushafIntroPrefs.setStep(MushafIntroPrefs.stepWaitPlayback);
        if (mounted) {
          setState(() => _mushafIntroStep = MushafIntroPrefs.stepWaitPlayback);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'الآن: اضغط مطولاً على آية واختر «الاستماع للآية». عند بدء التشغيل يظهر شرح تغيير القارئ.',
                style: _quranStyle(fontSize: 14, color: Colors.white),
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
    return ListenableBuilder(
      listenable: player,
      builder: (_, __) {
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
        final titleText = player.state == AyahPlayerState.error
            ? (player.errorMessage ?? 'خطأ')
            : (suraName.isNotEmpty && ayah != null
                ? '$suraName — آية $ayah'
                : suraName.isNotEmpty
                    ? suraName
                    : '');
        return Positioned(
          left: 8,
          right: 8,
          bottom: 8,
          child: AnimatedSlide(
            offset: _playerOverlayVisible ? Offset.zero : const Offset(0, 1.5),
            duration: const Duration(milliseconds: 400),
            curve: Curves.easeInOutCubic,
            child: IgnorePointer(
              ignoring: !_playerOverlayVisible,
              child: SafeArea(
                top: false,
                child: Material(
                  elevation: 12,
                  borderRadius: BorderRadius.circular(12),
                  color: const Color.fromARGB(255, 8, 32, 16)
                      .withValues(alpha: 0.96),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 6,
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            Expanded(
                              child: InkWell(
                                onTap: () => _showAudioRangePicker(context),
                                borderRadius: BorderRadius.circular(8),
                                child: Tooltip(
                                  message: 'تحديد نطاق التشغيل',
                                  child: Padding(
                                    padding: const EdgeInsets.only(
                                      right: 16,
                                      left: 4,
                                      top: 4,
                                      bottom: 4,
                                    ),
                                    child: Text(
                                      titleText,
                                      style: _quranStyle(
                                        fontSize: 15,
                                        color: Colors.white,
                                        fontWeight: FontWeight.w600,
                                      ),
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      textAlign: TextAlign.right,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            Expanded(
                              child: Center(
                                child: KeyedSubtree(
                                  key: _introReciterKey,
                                  child: InkWell(
                                    onTap: () => _showReciterPicker(context),
                                    borderRadius: BorderRadius.circular(8),
                                    child: Tooltip(
                                      message: 'تغيير القارئ',
                                      child: Padding(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 8,
                                          vertical: 4,
                                        ),
                                        child: Text(
                                          reciterName,
                                          style: _quranStyle(
                                            fontSize: 14,
                                            color: Colors.white,
                                            fontWeight: FontWeight.w600,
                                          ),
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                          textAlign: TextAlign.center,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            IconButton(
                              icon: const Icon(Icons.close, size: 20),
                              color: Colors.white70,
                              padding: const EdgeInsets.all(4),
                              constraints: const BoxConstraints(
                                minWidth: 32,
                                minHeight: 32,
                              ),
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
                          ],
                        ),
                        const SizedBox(height: 6),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Expanded(
                              child: IconButton(
                                icon: Icon(
                                  player.showAyahHighlight
                                      ? Icons.highlight
                                      : Icons.highlight_outlined,
                                  size: 22,
                                ),
                                color: player.showAyahHighlight
                                    ? Colors.white
                                    : Colors.white54,
                                padding: const EdgeInsets.all(4),
                                constraints: const BoxConstraints(
                                  minWidth: 32,
                                  minHeight: 36,
                                ),
                                tooltip: player.showAyahHighlight
                                    ? 'إخفاء تأشير الآية'
                                    : 'إظهار تأشير الآية',
                                onPressed: () async {
                                  await player.setShowAyahHighlight(
                                    !player.showAyahHighlight,
                                  );
                                },
                              ),
                            ),
                            Expanded(
                              child: IconButton(
                                icon: Transform.rotate(
                                  angle: 3.14159265359,
                                  child: const Icon(Icons.skip_previous),
                                ),
                                color: Colors.white,
                                iconSize: 24,
                                padding: const EdgeInsets.all(4),
                                constraints: const BoxConstraints(
                                  minWidth: 36,
                                  minHeight: 36,
                                ),
                                onPressed: player.hasPrev
                                    ? () => player.playPrev()
                                    : null,
                              ),
                            ),
                            Expanded(
                              child: IconButton(
                                icon: Transform.rotate(
                                  angle: 3.14159265359,
                                  child: Icon(
                                    player.isPlaying
                                        ? Icons.pause
                                        : Icons.play_arrow,
                                    color: Colors.white,
                                    size: 28,
                                  ),
                                ),
                                padding: const EdgeInsets.all(4),
                                constraints: const BoxConstraints(
                                  minWidth: 36,
                                  minHeight: 36,
                                ),
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
                              child: IconButton(
                                icon: Transform.rotate(
                                  angle: 3.14159265359,
                                  child: const Icon(Icons.skip_next),
                                ),
                                color: Colors.white,
                                iconSize: 24,
                                padding: const EdgeInsets.all(4),
                                constraints: const BoxConstraints(
                                  minWidth: 36,
                                  minHeight: 36,
                                ),
                                onPressed: player.hasNext
                                    ? () => player.playNext()
                                    : null,
                              ),
                            ),
                            Expanded(
                              child: IconButton(
                                icon: Icon(
                                  _playbackModeIcon(player.playbackMode),
                                  color: Colors.white70,
                                  size: 20,
                                ),
                                padding: const EdgeInsets.all(4),
                                constraints: const BoxConstraints(
                                  minWidth: 32,
                                  minHeight: 32,
                                ),
                                tooltip:
                                    _playbackModeTooltip(player.playbackMode),
                                onPressed: () => player.cyclePlaybackMode(),
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

  Future<void> _showAudioRangePicker(BuildContext context) async {
    final player = AyahAudioPlayer.instance;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFFF1F8E9),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: _AudioRangePickerSheet(
          initialRange: player.playbackRange,
          currentSura: player.currentSura,
          currentAyah: player.currentAyah,
          suraList: _suraList,
          suraAyahCount: _suraAyahCount,
          toNormalDigits: _toNormalDigits,
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
  }

  Future<void> _showReciterPicker(BuildContext context) async {
    final favorites = await AyahRecitersPrefs.instance.getFavoriteReciterIds();
    final currentId = AyahAudioPlayer.instance.currentReciterId;
    final favReciters =
        kAyahReciters.where((r) => favorites.contains(r.id)).toList();
    final otherReciters =
        kAyahReciters.where((r) => !favorites.contains(r.id)).toList();
    if (!context.mounted) return;
    final maxSheetHeight = MediaQuery.sizeOf(context).height * 0.6;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFFF1F8E9),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: SizedBox(
          height: maxSheetHeight,
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'اختر القارئ',
                    style: _quranStyle(
                      fontSize: 20,
                      color: const Color(0xFF1B5E20),
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
                              style: _quranStyle(
                                fontSize: 13,
                                color: const Color(0xFF2E7D32),
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 6),
                            ...favReciters.map(
                              (r) => _reciterTile(ctx, r, currentId, favorites),
                            ),
                            if (otherReciters.isNotEmpty)
                              const SizedBox(height: 8),
                          ],
                          if (otherReciters.isNotEmpty)
                            ...otherReciters.map(
                              (r) => _reciterTile(ctx, r, currentId, favorites),
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
    );
  }

  Widget _reciterTile(
    BuildContext ctx,
    AyahReciter r,
    String currentId,
    List<String> favorites,
  ) {
    final isSelected = r.id == currentId;
    final isFav = favorites.contains(r.id);
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: isSelected
            ? const Color(0xFFE8F5E9)
            : Colors.white.withValues(alpha: 0.85),
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
                    color:
                        isFav ? const Color(0xFF2E7D32) : Colors.grey.shade500,
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
                        style: _quranStyle(
                          fontSize: 17,
                          color: isSelected
                              ? const Color(0xFF1B5E20)
                              : Colors.black87,
                          fontWeight:
                              isSelected ? FontWeight.bold : FontWeight.w600,
                        ),
                      ),
                      if (r.hasSegments) ...[
                        const SizedBox(height: 2),
                        Text(
                          'يدعم التضليل',
                          style: _quranStyle(
                            fontSize: 12,
                            color:
                                const Color(0xFF2E7D32).withValues(alpha: 0.85),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (isSelected)
                  const Icon(Icons.check_circle_rounded,
                      color: Color(0xFF2E7D32), size: 24),
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
            setState(() => _currentPageIndex = p - 1);
            _saveCurrentPage(_currentPageIndex);
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
        const horizontalMarginFraction = 0.0;
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
    final itemExtent = fullPageWidth;
    const bottomFraction = 0.08 * 0.5;
    final bottomPadding = screenHeight * bottomFraction;
    final topPadding = screenHeight * 0.02;
    return CompactLineSpacingScope(
      compact: true,
      child: AyahLongPressScope(
        onAyahLongPress: _showAyahLongPressMenu,
        child: Padding(
          padding: EdgeInsets.only(top: topPadding, bottom: bottomPadding),
          child: _PassiveTapListener(
            onTap: _handleMushafTap,
            child: NotificationListener<ScrollNotification>(
              onNotification: (n) {
                if (n is ScrollStartNotification && n.dragDetails != null) {
                  if (_autoScrollEnabled) {
                    setState(() => _autoScrollEnabled = false);
                    _autoScrollTimer?.cancel();
                    _saveDisplayPrefs();
                  }
                }
                if (n is ScrollUpdateNotification ||
                    n is ScrollEndNotification) {
                  final ctrl = _horizontalLongScrollController;
                  if (ctrl != null && ctrl.hasClients) {
                    final page = ((ctrl.offset / itemExtent).round() + 1)
                        .clamp(1, totalPages);
                    preloadNearbyPages(page);
                    if (page - 1 != _currentPageIndex) {
                      setState(() {
                        _currentPageIndex = page - 1;
                        PageBackgroundLoader.instance.setCurrentPage(page);
                        _saveCurrentPage(_currentPageIndex);
                      });
                    }
                  }
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
                    width: fullPageWidth,
                    height: fullPageHeight,
                    child: Center(
                      child: RotatedBox(
                        quarterTurns: 1,
                        child: SizedBox(
                          width: fullPageHeight,
                          height: fullPageWidth,
                          child: _buildSinglePageForMode(page),
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
    return PageView.builder(
      controller: _pageController,
      itemCount: 302,
      onPageChanged: (index) {
        setState(() => _currentPageIndex = index * 2);
        PageBackgroundLoader.instance.setCurrentPage(index * 2 + 1);
        _saveCurrentPage(_currentPageIndex);
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
    );
  }

  Widget _buildSinglePageForMode(int page) {
    final content = buildQpcPageContent(
      context,
      page,
      _qpcMode,
      forceWhiteMushafText: _useWhiteTextOnDarkMushaf,
    );
    return Column(
      children: [
        _buildQpcTopBarForPage(page),
        Expanded(child: content),
        _buildQpcPageNumberRow(page),
      ],
    );
  }

  /// صف رقم الصفحة (يمين للفردي، يسار للزوجي) — نفس العرض الافتراضي: إطار raqum_alsafha + رقم عربي.
  Widget _buildQpcPageNumberRow(int page) {
    final pageNumberColor =
        _useWhiteTextOnDarkMushaf ? const Color(0xFFE7FFEF) : Colors.black;
    return SizedBox(
      height: 40,
      child: Align(
        alignment: page.isOdd ? Alignment.centerRight : Alignment.centerLeft,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: SizedBox(
            width: 56.25,
            height: 28.125,
            child: Stack(
              alignment: Alignment.center,
              children: [
                SvgPicture.asset(
                  'assets/icon/raqum_alsafha.svg',
                  fit: BoxFit.contain,
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
    );
  }

  static const double _mushafAspectRatio = 1.4;

  /// القراءة الطويلة: نفس حسابات العرض الافتراضي بالضبط — نفس التخطيط من ROM،
  /// فقط الترتيب عمودي (صفحة تحت صفحة) بدل أفقي.
  /// كل صفحة تأخذ ارتفاع الشاشة كاملًا كما في العرض الافتراضي.
  Widget _buildLongScrollView(
      BuildContext context, double screenWidth, double screenHeight) {
    final itemExtent = screenHeight;
    return AyahLongPressScope(
      onAyahLongPress: _showAyahLongPressMenu,
      child: _PassiveTapListener(
        onTap: _handleMushafTap,
        child: NotificationListener<ScrollNotification>(
          onNotification: (n) {
            if (n is ScrollStartNotification && n.dragDetails != null) {
              if (_autoScrollEnabled) {
                setState(() => _autoScrollEnabled = false);
                _autoScrollTimer?.cancel();
                _saveDisplayPrefs();
              }
            }
            if (n is ScrollUpdateNotification || n is ScrollEndNotification) {
              final ctrl = _longScrollController;
              if (ctrl != null && ctrl.hasClients) {
                final page = ((ctrl.offset / itemExtent).round() + 1)
                    .clamp(1, totalPages);
                preloadNearbyPages(page);
                if (page - 1 != _currentPageIndex) {
                  setState(() {
                    _currentPageIndex = page - 1;
                    PageBackgroundLoader.instance.setCurrentPage(page);
                    _saveCurrentPage(_currentPageIndex);
                  });
                }
              }
            }
            return false;
          },
          child: ListView.builder(
            controller: _longScrollControllerOrCreate,
            itemCount: totalPages,
            itemExtent: itemExtent,
            itemBuilder: (context, index) {
              final page = index + 1;
              return _buildSinglePageForMode(page);
            },
          ),
        ),
      ),
    );
  }

  void _expandLongScrollBarAndResetIdle() {
    _longScrollBarIdleTimer?.cancel();
    if (_longScrollBarCollapsed) {
      setState(() => _longScrollBarCollapsed = false);
    }
    _longScrollBarIdleTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _longScrollBarCollapsed = true);
    });
  }

  void _startLongScrollBarIdleTimer() {
    _longScrollBarIdleTimer?.cancel();
    _longScrollBarIdleTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _longScrollBarCollapsed = true);
    });
  }

  /// شريط التحكم للقراءة الأفقية الطويلة: عمودي على يسار الشاشة، أبعاد صحيحة بدون تدوير.
  Widget _buildHorizontalLongScrollBar(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted &&
          _displayType == DisplayType.horizontalLongScroll &&
          !_longScrollBarCollapsed) {
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
      child: Center(
        child: Transform.rotate(
          angle: 3.14159265359,
          child: GestureDetector(
            onTap: _expandLongScrollBarAndResetIdle,
            onPanDown: (_) => _expandLongScrollBarAndResetIdle(),
            child: AnimatedOpacity(
              duration: const Duration(milliseconds: 300),
              opacity: _longScrollBarCollapsed ? 0.5 : 1.0,
              child: Material(
                color: const Color(0xFFE8F5E9).withOpacity(0.96),
                borderRadius: BorderRadius.circular(12),
                elevation: 6,
                child: InkWell(
                  onTap: _expandLongScrollBarAndResetIdle,
                  borderRadius: BorderRadius.circular(12),
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(vertical: 4, horizontal: 6),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          icon: Transform.rotate(
                            angle: 4.71238898038,
                            child: Transform.rotate(
                              angle: 3.14159265359,
                              child: Icon(
                                _autoScrollEnabled
                                    ? Icons.pause_circle_filled
                                    : Icons.play_circle_outline,
                                color: const Color(0xFF2E7D32),
                                size: 24,
                              ),
                            ),
                          ),
                          onPressed: () {
                            _expandLongScrollBarAndResetIdle();
                            setState(() {
                              _autoScrollEnabled = !_autoScrollEnabled;
                              if (_autoScrollEnabled) {
                                _startAutoScroll();
                              } else {
                                _autoScrollTimer?.cancel();
                              }
                            });
                            _saveDisplayPrefs();
                          },
                          padding: const EdgeInsets.all(4),
                          constraints:
                              const BoxConstraints(minWidth: 25, minHeight: 25),
                        ),
                        SizedBox(
                          height: 180,
                          width: 14,
                          child: RotatedBox(
                            quarterTurns: -1,
                            child: SliderTheme(
                              data: SliderTheme.of(context).copyWith(
                                activeTrackColor: const Color(0xFF2E7D32),
                                inactiveTrackColor: Colors.grey.shade300,
                                thumbColor: const Color(0xFF2E7D32),
                                overlayColor: Colors.transparent,
                                trackHeight: 2,
                                thumbShape: const RoundSliderThumbShape(
                                    enabledThumbRadius: 7),
                              ),
                              child: Slider(
                                value: _autoScrollSpeed,
                                min: _autoScrollUiMin,
                                max: _autoScrollUiMax,
                                onChanged: (v) {
                                  _expandLongScrollBarAndResetIdle();
                                  setState(() => _autoScrollSpeed = v);
                                  _saveDisplayPrefs();
                                  if (_autoScrollEnabled) {
                                    _autoScrollTimer?.cancel();
                                    _startAutoScroll();
                                  }
                                },
                              ),
                            ),
                          ),
                        ),
                        Transform.rotate(
                          angle: 4.71238898038,
                          child: Text(
                            '${_toNormalDigits((_autoScrollSpeed * 100).round())}%',
                            style: _quranStyle(
                                fontSize: 16, color: const Color(0xFF1B5E20)),
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
      ),
    );
  }

  Widget _buildLongScrollBottomBar(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted &&
          (_displayType == DisplayType.longScroll ||
              _displayType == DisplayType.horizontalLongScroll) &&
          !_longScrollBarCollapsed) {
        _startLongScrollBarIdleTimer();
      }
    });
    final bottomPad = MediaQuery.paddingOf(context).bottom;
    return GestureDetector(
      onTap: _expandLongScrollBarAndResetIdle,
      onPanDown: (_) => _expandLongScrollBarAndResetIdle(),
      child: SafeArea(
        top: false,
        child: Padding(
          padding:
              EdgeInsets.fromLTRB(16, 0, 16, bottomPad > 0 ? bottomPad : 8),
          child: Center(
            child: AnimatedOpacity(
              duration: const Duration(milliseconds: 300),
              opacity: _longScrollBarCollapsed ? 0.5 : 1.0,
              child: Material(
                color: const Color(0xFFE8F5E9).withOpacity(0.96),
                borderRadius: BorderRadius.circular(24),
                elevation: 6,
                child: InkWell(
                  onTap: _expandLongScrollBarAndResetIdle,
                  borderRadius: BorderRadius.circular(24),
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          icon: Transform.rotate(
                            angle: 3.14159265359,
                            child: Icon(
                              _autoScrollEnabled
                                  ? Icons.pause_circle_filled
                                  : Icons.play_circle_outline,
                              color: const Color(0xFF2E7D32),
                              size: 28,
                            ),
                          ),
                          onPressed: () {
                            _expandLongScrollBarAndResetIdle();
                            setState(() {
                              _autoScrollEnabled = !_autoScrollEnabled;
                              if (_autoScrollEnabled) {
                                _startAutoScroll();
                              } else {
                                _autoScrollTimer?.cancel();
                              }
                            });
                            _saveDisplayPrefs();
                          },
                          padding: const EdgeInsets.all(4),
                          constraints:
                              const BoxConstraints(minWidth: 36, minHeight: 36),
                        ),
                        SizedBox(
                          width: 120,
                          child: SliderTheme(
                            data: SliderTheme.of(context).copyWith(
                              activeTrackColor: const Color(0xFF2E7D32),
                              inactiveTrackColor: Colors.grey.shade300,
                              thumbColor: const Color(0xFF2E7D32),
                              overlayColor: Colors.transparent,
                              trackHeight: 2,
                              thumbShape: const RoundSliderThumbShape(
                                  enabledThumbRadius: 5),
                            ),
                            child: Slider(
                              value: _autoScrollSpeed,
                              min: _autoScrollUiMin,
                              max: _autoScrollUiMax,
                              onChanged: (v) {
                                _expandLongScrollBarAndResetIdle();
                                setState(() => _autoScrollSpeed = v);
                                _saveDisplayPrefs();
                                if (_autoScrollEnabled) {
                                  _autoScrollTimer?.cancel();
                                  _startAutoScroll();
                                }
                              },
                            ),
                          ),
                        ),
                        SizedBox(
                          width: 40,
                          child: Text(
                            '${_toNormalDigits((_autoScrollSpeed * 100).round())}%',
                            style: _quranStyle(
                                fontSize: 15, color: const Color(0xFF1B5E20)),
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
      ),
    );
  }

  void _startAutoScroll() {
    _autoScrollTimer?.cancel();
    const step = Duration(milliseconds: 50);
    final effectiveSpeed = _effectiveAutoScrollSpeed();
    final pixelsPerTick = 0.15 + effectiveSpeed * 1.85;

    void tick() {
      if (!mounted || !_autoScrollEnabled) return;
      final ctrl = _displayType == DisplayType.horizontalLongScroll
          ? _horizontalLongScrollController
          : _longScrollController;
      if (ctrl == null || !ctrl.hasClients) return;
      final pos = ctrl.position;
      if (pos.pixels >= pos.maxScrollExtent) {
        _autoScrollTimer?.cancel();
        setState(() => _autoScrollEnabled = false);
        _saveDisplayPrefs();
        return;
      }
      ctrl.jumpTo(
        (pos.pixels + pixelsPerTick).clamp(0, pos.maxScrollExtent),
      );
      _autoScrollTimer = Timer(step, tick);
    }

    _autoScrollTimer = Timer(step, tick);
  }

  void _showMushafStyleSheet(BuildContext context) {
    Color selectedBg = _mushafBackgroundColor;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFFF7F7F4),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (context, setSheetState) => Directionality(
          textDirection: TextDirection.rtl,
          child: SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 12, 8, 8),
                  child: Row(
                    children: [
                      IconButton(
                        icon: const Icon(Icons.arrow_back,
                            color: Color(0xFF1B5E20)),
                        onPressed: () {
                          Navigator.pop(ctx);
                          _showOptionsSheet(context, _currentPageIndex);
                        },
                        tooltip: 'رجوع إلى القائمة',
                      ),
                      Expanded(
                        child: Center(
                          child: Text(
                            'شكل المصحف',
                            style: _quranStyle(
                                fontSize: 18,
                                color: const Color(0xFF1B5E20),
                                fontWeight: FontWeight.bold),
                          ),
                        ),
                      ),
                      const SizedBox(width: 48),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Flexible(
                  child: SingleChildScrollView(
                    padding:
                        const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          child: Text(
                            'ألوان الخلفية',
                            style: _quranStyle(
                              fontSize: 14,
                              color: const Color(0xFF1B5E20),
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
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          child: Text(
                            'أنواع المصاحف',
                            style: _quranStyle(
                              fontSize: 14,
                              color: const Color(0xFF1B5E20),
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
        ),
      ),
    );
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
      ('مصحف المدينة 1439 هـ ترتيل', QpcMushafMode.qpc4),
    ];
  }

  Widget _backgroundColorChip({
    required String label,
    required Color color,
    required bool isSelected,
    required VoidCallback onTap,
  }) {
    final borderColor =
        isSelected ? const Color(0xFF1B5E20) : const Color(0xFFBDBDBD);
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
              style: _quranStyle(
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
        border: Border.all(color: const Color(0xFF2E7D32), width: 0.5),
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
      style: _quranStyle(
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
        setState(() {
          _qpcMode = mode;
          _mushafBackgroundColor = bgColor;
        });
        _saveMushafStylePrefs();
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
          children: [
            Icon(
              selected ? Icons.radio_button_checked : Icons.radio_button_off,
              color: const Color(0xFF2E7D32),
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
                    style: _quranStyle(
                        fontSize: 14, color: const Color(0xFF1B5E20)),
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
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (ctx) => DeveloperOptionsScreen(currentMode: _qpcMode),
      ),
    );
  }

  Future<void> _showAboutDialog(BuildContext context) async {
    String version = '2.0.0';
    try {
      final info = await PackageInfo.fromPlatform();
      if (context.mounted) version = info.version;
    } catch (_) {}
    if (!context.mounted) return;
    showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          backgroundColor: const Color(0xFFF1F8E9),
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
            style: _quranStyle(
              fontSize: 28,
              fontWeight: FontWeight.bold,
              color: const Color(0xFF1B5E20),
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
                    color: Colors.white,
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
                    style: _quranStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w500,
                      color: const Color(0xFF2E7D32),
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                Text(
                  'المطور: المهندس أحمد خليل',
                  textAlign: TextAlign.center,
                  style: _quranStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                    color: const Color(0xFF1B5E20),
                  ),
                ),
                const SizedBox(height: 20),
                Text(
                  'إذا كانت لديك مشاكل، يرجى التواصل معنا',
                  textAlign: TextAlign.center,
                  style: _quranStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w500,
                    color: Colors.grey.shade700,
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
                            style: _quranStyle(
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
                style: _quranStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                  color: const Color(0xFF2E7D32),
                ),
              ),
            ),
          ],
        ),
      ),
    );
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
            style: _quranStyle(
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
              style: _quranStyle(fontSize: 14, color: Colors.white),
            ),
            backgroundColor: Colors.orange.shade700,
          ),
        );
      }
    }
  }

  /// أوضاع العرض المعروضة: هاتف ضيّق = بدون صفحتان؛ تابلت/واسع = أفقي + صفحتان + أفقي طويل فقط.
  List<DisplayType> _displayTypesForSheet(BuildContext context) {
    final w = MediaQuery.sizeOf(context).width;
    final isWide = w >= _wideScreenThreshold;
    if (isWide) {
      return [
        DisplayType.horizontal,
        DisplayType.twoPage,
        DisplayType.horizontalLongScroll,
      ];
    }
    return [
      DisplayType.standard,
      DisplayType.horizontal,
      DisplayType.longScroll,
      DisplayType.horizontalLongScroll,
    ];
  }

  static String _displayTypeLabel(DisplayType type) {
    return switch (type) {
      DisplayType.standard => 'صفحة واحدة',
      DisplayType.horizontal => 'عرض أفقي',
      DisplayType.twoPage => 'صفحتان',
      DisplayType.longScroll => 'تمرير عمودي',
      DisplayType.horizontalLongScroll => 'تمرير أفقي',
    };
  }

  /// أيقونات توحي بالتسمية: صفحة واحدة، عرض أفقي، صفحتان، تمرير عمودي، تمرير أفقي.
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
    final types = _displayTypesForSheet(ctx);
    final isWide = MediaQuery.sizeOf(ctx).width >= _wideScreenThreshold;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          ...types.map((DisplayType type) {
            final selected = _displayType == type;
            return Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Material(
                  color:
                      selected ? const Color(0xFFC8E6C9) : Colors.transparent,
                  borderRadius: BorderRadius.circular(12),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(12),
                    onTap: () {
                      Navigator.pop(ctx);
                      setState(() {
                        _displayType = type;
                        if (type == DisplayType.longScroll) {
                          _longScrollBarCollapsed = false;
                          _longScrollNeedsInitialJump = true;
                        } else if (type == DisplayType.horizontalLongScroll) {
                          _longScrollBarCollapsed = false;
                          _horizontalLongScrollNeedsInitialJump = true;
                        } else {
                          _standardNeedsInitialJump = true;
                        }
                      });
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
                              color: const Color(0xFF1B5E20).withOpacity(0.08),
                              shape: BoxShape.circle,
                            ),
                            child: Icon(
                              _displayTypeIcon(type),
                              size: isWide ? 24 : 22,
                              color: const Color(0xFF1B5E20),
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            _displayTypeLabel(type),
                            style: _quranStyle(
                              fontSize: isWide ? 15 : 13,
                              color: const Color(0xFF1B5E20),
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
                color: Colors.transparent,
                borderRadius: BorderRadius.circular(12),
                child: InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: () {
                    Navigator.pop(ctx);
                    _showMushafStyleSheet(parentContext);
                  },
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          padding: const EdgeInsets.all(6),
                          decoration: BoxDecoration(
                            color: const Color(0xFF1B5E20).withOpacity(0.08),
                            shape: BoxShape.circle,
                          ),
                          child: Icon(
                            Icons.palette_rounded,
                            size: isWide ? 24 : 22,
                            color: const Color(0xFF1B5E20),
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'المصحف',
                          style: _quranStyle(
                            fontSize: isWide ? 15 : 13,
                            color: const Color(0xFF1B5E20),
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

  void _showOptionsSheet(BuildContext context, int currentIndex) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFFE8F5E9),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildDisplayModeStrip(ctx, context),
              const Divider(height: 1),
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: Column(
                          children: [
                            _buildSearchMainMenuCard(ctx, context, currentIndex,
                                onTap: () => _showSearchDialog(
                                    context, _currentPageIndex)),
                            const SizedBox(height: 6),
                            _buildMainMenuCompactRow(
                              ctx,
                              context,
                              currentIndex,
                              items: [
                                _MainMenuCompactItem(
                                  icon: Icons.list,
                                  title: 'الفهرس',
                                  onTap: () =>
                                      _showFihrist(context, _currentPageIndex),
                                ),
                                _MainMenuCompactItem(
                                  icon: Icons.menu_book,
                                  title: 'الأجزاء',
                                  onTap: () =>
                                      _showAjza(context, _currentPageIndex),
                                ),
                                _MainMenuCompactItem(
                                  icon: Icons.numbers,
                                  title: 'الصفحات',
                                  closeMenuBeforeAction: false,
                                  onTap: () => _showPagesDialog(
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
                                  icon: Icons.bookmark_border,
                                  title: 'حفظ علامة',
                                  onTap: () => _showSaveBookmarkSheet(
                                      context, _currentPageIndex),
                                ),
                                _MainMenuCompactItem(
                                  icon: Icons.bookmark,
                                  title: 'انتقال إلى علامة',
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
                                  onTap: () => _showAzkarDialog(context),
                                ),
                                _MainMenuCompactItem(
                                  icon: Icons.menu_book_outlined,
                                  title: 'التفسير',
                                  onTap: () =>
                                      _showTafseerFromMainMenu(context),
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
                                  onTap: () => _showKhatmaSetupDialog(
                                      context, _currentPageIndex),
                                ),
                                _MainMenuCompactItem(
                                  icon: Icons.view_list_rounded,
                                  title: 'جدول الختمة',
                                  onTap: () => _showKhatmaSchedule(context),
                                ),
                              ],
                            ),
                            const SizedBox(height: 6),
                          ],
                        ),
                      ),
                      const SizedBox(height: 6),
                      _buildHighlightingMenuItem(
                        ctx,
                        context,
                        currentIndex,
                        visible: _ayahHighlightsVisible,
                        enabled: !_isAyahHighlightingDisabledByAudio,
                        onShowIndex: () => _showAyahHighlightsIndex(context),
                        onToggleVisibility: () {
                          setState(() {
                            _ayahHighlightsVisible = !_ayahHighlightsVisible;
                          });
                          _syncAyahHighlightsStore();
                        },
                      ),
                      const SizedBox(height: 6),
                      _buildAboutMenuItemWithSecret(ctx, context, currentIndex),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSearchMainMenuCard(
    BuildContext ctx,
    BuildContext context,
    int currentIndex, {
    required VoidCallback onTap,
  }) {
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () {
        Navigator.pop(ctx);
        onTap();
      },
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: const Color(0xFF1B5E20).withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
              color: const Color(0xFF1B5E20).withValues(alpha: 0.14)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.search, color: const Color(0xFF1B5E20), size: 22),
            const SizedBox(width: 8),
            Text(
              'بحث',
              style: _quranStyle(
                fontSize: 17,
                color: const Color(0xFF1B5E20),
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
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () {
        if (item.closeMenuBeforeAction) Navigator.pop(ctx);
        item.onTap();
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
              color: const Color(0xFF1B5E20).withValues(alpha: 0.14)),
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
            Icon(item.icon, color: const Color(0xFF2E7D32), size: 20),
            const SizedBox(height: 2),
            Text(
              item.title,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: _quranStyle(
                fontSize: 14,
                color: const Color(0xFF1B5E20),
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAboutMenuItemWithSecret(
    BuildContext ctx,
    BuildContext parentContext,
    int currentIndex,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: InkWell(
        onTap: () {
          Navigator.pop(ctx);
          _showAboutDialog(parentContext);
        },
        borderRadius: BorderRadius.circular(12),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.05),
                blurRadius: 4,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: const Color(0xFF2E7D32).withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(
                  Icons.info_outline,
                  color: Color(0xFF2E7D32),
                  size: 22,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Text(
                  'حول التطبيق',
                  style: _quranStyle(
                    fontSize: 17,
                    color: const Color(0xFF1B5E20),
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Icon(
                Icons.arrow_forward_ios,
                size: 16,
                color: Colors.grey.shade400,
              ),
            ],
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
    final titleColor = enabled ? const Color(0xFF1B5E20) : Colors.grey.shade600;
    final accentColor =
        enabled ? const Color(0xFF2E7D32) : Colors.grey.shade500;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.05),
              blurRadius: 4,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: enabled
                    ? const Color(0xFF2E7D32).withValues(alpha: 0.10)
                    : Colors.grey.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(Icons.highlight, color: accentColor, size: 22),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                'التضليل',
                style: _quranStyle(
                  fontSize: 17,
                  color: titleColor,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.folder_open, size: 20),
              color: accentColor,
              onPressed: enabled
                  ? () {
                      Navigator.pop(ctx);
                      onShowIndex();
                    }
                  : null,
              tooltip: 'التضليلات المحفوظة',
            ),
            IconButton(
              icon: Icon(visible ? Icons.visibility : Icons.visibility_off,
                  size: 20),
              color: enabled
                  ? (visible ? const Color(0xFF2E7D32) : Colors.grey)
                  : Colors.grey.shade400,
              onPressed: enabled
                  ? () {
                      Navigator.pop(ctx);
                      onToggleVisibility();
                    }
                  : null,
              tooltip: enabled
                  ? (visible ? 'إخفاء التضليل' : 'إظهار التضليل')
                  : 'متوقف أثناء الاستماع',
            ),
            Icon(Icons.arrow_forward_ios,
                size: 16, color: Colors.grey.shade400),
          ],
        ),
      ),
    );
  }

  /// فهرس نطاقات تأشير الآيات المحفوظة
  void _showAyahHighlightsIndex(BuildContext context) {
    final entries = List<AyahRangeHighlight>.from(_ayahHighlights);
    if (entries.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'لا توجد تضليلات محفوظة حالياً',
            style: _quranStyle(
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

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFFE8F5E9),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: SafeArea(
          child: SizedBox(
            height: MediaQuery.of(ctx).size.height * 0.62,
            child: Column(
              children: [
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
                  child: Row(
                    children: [
                      IconButton(
                        icon: const Icon(Icons.arrow_back,
                            color: Color(0xFF1B5E20)),
                        onPressed: () => Navigator.pop(ctx),
                      ),
                      Expanded(
                        child: Text(
                          'التضليلات المحفوظة',
                          style: _quranStyle(
                            fontSize: 18,
                            color: const Color(0xFF1B5E20),
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: ListView.separated(
                    padding: const EdgeInsets.symmetric(
                        vertical: 12, horizontal: 12),
                    itemCount: entries.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (itemCtx, i) {
                      final e = entries[i];
                      final page = _ayahList
                          .where((a) =>
                              a.suraNo == e.sura && a.ayaNo == e.fromAyah)
                          .firstOrNull
                          ?.page;
                      final title = '${_suraNameFromNo(e.sura)}';
                      final rangeText = e.fromAyah == e.toAyah
                          ? 'آية ${_toNormalDigits(e.fromAyah)}'
                          : 'من ${_toNormalDigits(e.fromAyah)} إلى ${_toNormalDigits(e.toAyah)}';
                      return ListTile(
                        leading: CircleAvatar(
                          backgroundColor: e.color.withValues(alpha: 0.90),
                          child: const Icon(Icons.highlight,
                              color: Colors.white, size: 18),
                        ),
                        title: Text(
                          title,
                          style: _quranStyle(
                            fontSize: 16,
                            color: const Color(0xFF1B5E20),
                          ),
                        ),
                        subtitle: Text(
                          page == null
                              ? rangeText
                              : '$rangeText — ص ${_toNormalDigits(page)}',
                          style: _quranStyle(
                            fontSize: 12,
                            color: Colors.grey,
                            fontWeight: FontWeight.normal,
                          ),
                        ),
                        trailing: IconButton(
                          icon: const Icon(Icons.delete_outline,
                              color: Colors.red),
                          onPressed: () async {
                            final shouldDelete = await showDialog<bool>(
                                  context: itemCtx,
                                  builder: (dialogCtx) => Directionality(
                                    textDirection: TextDirection.rtl,
                                    child: AlertDialog(
                                      title: Text(
                                        'حذف التضليل',
                                        style: _quranStyle(
                                          fontSize: 18,
                                          color: const Color(0xFF1B5E20),
                                        ),
                                      ),
                                      content: Text(
                                        'هل تريد حذف هذا التضليل؟',
                                        style: _quranStyle(
                                          fontSize: 14,
                                          color: Colors.black87,
                                          fontWeight: FontWeight.normal,
                                        ),
                                      ),
                                      actions: [
                                        TextButton(
                                          onPressed: () =>
                                              Navigator.pop(dialogCtx, false),
                                          child: Text(
                                            'إلغاء',
                                            style: _quranStyle(
                                              fontSize: 14,
                                              color: Colors.grey,
                                            ),
                                          ),
                                        ),
                                        FilledButton(
                                          style: FilledButton.styleFrom(
                                              backgroundColor: Colors.red),
                                          onPressed: () =>
                                              Navigator.pop(dialogCtx, true),
                                          child: Text(
                                            'حذف',
                                            style: _quranStyle(
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
                            setState(() {
                              _ayahHighlights.removeWhere((h) =>
                                  h.sura == e.sura &&
                                  h.fromAyah == e.fromAyah &&
                                  h.toAyah == e.toAyah &&
                                  h.color.toARGB32() == e.color.toARGB32());
                            });
                            _syncAyahHighlightsStore();
                            await _saveBookmarks();
                            if (!context.mounted) return;
                            Navigator.pop(ctx);
                            _showAyahHighlightsIndex(context);
                          },
                        ),
                        onTap: () {
                          Navigator.pop(ctx);
                          if (page != null) {
                            _navigateToPage(page);
                          } else {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(
                                  'تعذّر تحديد صفحة البداية لهذا التضليل',
                                  style: _quranStyle(
                                    fontSize: 14,
                                    color: Colors.white,
                                  ),
                                ),
                                backgroundColor: const Color(0xFF2E7D32),
                              ),
                            );
                          }
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
    );
  }

  void _showSaveBookmarkSheet(BuildContext context, int currentIndex) {
    final currentPage = currentIndex + 1;
    final textStyle = _quranStyle(fontSize: 16, color: const Color(0xFF1B5E20));

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFFE8F5E9),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: SafeArea(
          child: SizedBox(
            height: MediaQuery.of(ctx).size.height * 0.5,
            child: Column(
              children: [
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
                  child: Row(
                    children: [
                      IconButton(
                        icon: const Icon(Icons.arrow_back,
                            color: Color(0xFF1B5E20)),
                        onPressed: () => Navigator.pop(ctx),
                      ),
                      Expanded(
                        child: Text('حفظ العلامة',
                            style: _quranStyle(
                                fontSize: 18,
                                color: const Color(0xFF1B5E20),
                                fontWeight: FontWeight.w700)),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
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
                              ? _mainBookmarkColor
                              : _mainBookmarkColor.withValues(alpha: 0.8),
                        ),
                        title: Text('العلامة الرئيسية', style: textStyle),
                        subtitle: Text(
                          _mainBookmarkPage != null
                              ? 'ص $_mainBookmarkPage'
                              : 'غير معينة — اضغط لتعيين الصفحة الحالية',
                          style: _quranStyle(
                              fontSize: 12,
                              color: Colors.grey,
                              fontWeight: FontWeight.normal),
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
                          style: _quranStyle(
                              fontSize: 12,
                              color: Colors.grey,
                              fontWeight: FontWeight.normal),
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
                      const Divider(),
                      Text('العلامات المحفوظة',
                          style: _quranStyle(
                              fontSize: 14,
                              color: const Color(0xFF2E7D32),
                              fontWeight: FontWeight.w600)),
                      ..._savedBookmarks.map(
                        (b) => ListTile(
                          leading: Icon(
                            Icons.bookmark,
                            color: b.color,
                            size: 26,
                          ),
                          title:
                              Text('${b.name} — ص ${b.page}', style: textStyle),
                          onTap: () {
                            Navigator.pop(ctx);
                            _navigateToPage(b.page);
                          },
                        ),
                      ),
                      const SizedBox(height: 8),
                      ListTile(
                        trailing: const Icon(Icons.add_circle_outline,
                            color: Color(0xFF2E7D32)),
                        title: Text('إضافة علامة جديدة', style: textStyle),
                        subtitle: Text(
                          'حفظ الصفحة الحالية (ص $currentPage) باسم',
                          style: _quranStyle(
                              fontSize: 12,
                              color: Colors.grey,
                              fontWeight: FontWeight.normal),
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
    );
  }

  void _showKhatmaSchedule(BuildContext context) {
    if (_khatmaPlan.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'لا توجد خطة ختمة محفوظة',
            style: _quranStyle(
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

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFFE8F5E9),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: SizedBox(
          height: MediaQuery.of(ctx).size.height * 0.85,
          child: Column(
            children: [
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
                child: Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.arrow_back,
                          color: Color(0xFF1B5E20)),
                      onPressed: () => Navigator.pop(ctx),
                    ),
                    Expanded(
                      child: Text('جدول الختمة',
                          style: _quranStyle(
                              fontSize: 18,
                              color: const Color(0xFF1B5E20),
                              fontWeight: FontWeight.bold)),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: ListView.separated(
                  padding: const EdgeInsets.all(8),
                  itemCount: daysMap.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (_, dayIdx) {
                    final day = daysMap.keys.toList()..sort();
                    final dayNumber = day[dayIdx];
                    final sessions = daysMap[dayNumber]!
                      ..sort(
                          (a, b) => a.sessionIndex.compareTo(b.sessionIndex));
                    final isAnyCompleted = sessions.any((s) => s.completed);
                    final allCompleted = sessions.every((s) => s.completed);

                    return ExpansionTile(
                      initiallyExpanded: dayIdx == 0,
                      backgroundColor: allCompleted
                          ? const Color(0xFFC8E6C9)
                          : isAnyCompleted
                              ? const Color(0xFFE8F5E9)
                              : Colors.white,
                      collapsedBackgroundColor: allCompleted
                          ? const Color(0xFFC8E6C9)
                          : isAnyCompleted
                              ? const Color(0xFFE8F5E9)
                              : Colors.white,
                      title: Row(
                        children: [
                          Text(
                            'اليوم ${dayNumber + 1}',
                            style: _quranStyle(
                                fontSize: 18,
                                color: const Color(0xFF1B5E20),
                                fontWeight: FontWeight.bold),
                          ),
                          const SizedBox(width: 8),
                          if (allCompleted)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 4),
                              decoration: BoxDecoration(
                                color: const Color(0xFF2E7D32),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Text(
                                'مكتمل',
                                style: _quranStyle(
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
                                      ? const Color(0xFF2E7D32)
                                      : Colors.grey.shade300,
                                  shape: BoxShape.circle,
                                ),
                                child: Center(
                                  child: session.completed
                                      ? const Icon(Icons.check,
                                          color: Colors.white, size: 20)
                                      : Text(
                                          '${session.sessionIndex + 1}',
                                          style: _quranStyle(
                                              fontSize: 14,
                                              color: Colors.black87,
                                              fontWeight: FontWeight.bold),
                                        ),
                                ),
                              ),
                              title: Text(
                                session.timeOfDay,
                                style: _quranStyle(
                                    fontSize: 16,
                                    color: const Color(0xFF1B5E20),
                                    fontWeight: FontWeight.w600),
                              ),
                              subtitle: Text(
                                'صفحات ${session.startPage} - ${session.endPage} '
                                '($len صفحة)',
                                style: _quranStyle(
                                    fontSize: 13,
                                    color: Colors.grey.shade700,
                                    fontWeight: FontWeight.normal),
                              ),
                              trailing: session.completed
                                  ? const Icon(Icons.check_circle,
                                      color: Color(0xFF2E7D32))
                                  : IconButton(
                                      icon: const Icon(
                                          Icons.radio_button_unchecked,
                                          color: Colors.grey),
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
                                              globalIndex: session.globalIndex,
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
                                              _khatmaBookmarkPage = totalPages;
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
                                      borderRadius: BorderRadius.circular(999),
                                      child: LinearProgressIndicator(
                                        minHeight: 4,
                                        value: progress.clamp(0.0, 1.0),
                                        backgroundColor: Colors.grey.shade300
                                            .withValues(alpha: 0.6),
                                        valueColor:
                                            AlwaysStoppedAnimation<Color>(
                                          session.completed
                                              ? const Color(0xFF2E7D32)
                                              : const Color(0xFF1E88E5),
                                        ),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  Text(
                                    '${_toNormalDigits((progress * 100).round().clamp(0, 100))}%',
                                    textDirection: TextDirection.ltr,
                                    style: _quranStyle(
                                      fontSize: 12,
                                      color: Colors.grey.shade700,
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
    );
  }

  void _showAddBookmarkDialog(BuildContext context, int currentPage) {
    final nameController = TextEditingController();
    Color selected = _mainBookmarkColor;
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
          return Directionality(
            textDirection: TextDirection.rtl,
            child: AlertDialog(
              title: Text('إضافة علامة جديدة',
                  style: _quranStyle(
                      fontSize: 18, color: const Color(0xFF1B5E20))),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: nameController,
                    decoration: const InputDecoration(
                      hintText: 'اسم العلامة (مثلاً: آخر قراءة)',
                      border: OutlineInputBorder(),
                    ),
                    autofocus: true,
                  ),
                  const SizedBox(height: 12),
                  Align(
                    alignment: Alignment.centerRight,
                    child: Text(
                      'لون العلامة',
                      style: _quranStyle(
                        fontSize: 14,
                        color: const Color(0xFF1B5E20),
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
                                color: selected == c
                                    ? const Color(0xFF1B5E20)
                                    : Colors.grey.shade300,
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
                      style: _quranStyle(fontSize: 14, color: Colors.grey)),
                ),
                FilledButton(
                  style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF2E7D32)),
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
                      style: _quranStyle(fontSize: 14, color: Colors.white)),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  void _showKhatmaSetupDialog(BuildContext context, int currentIndex) {
    final currentPage = currentIndex + 1;
    final daysController = TextEditingController(text: '30');
    final sessionsController = TextEditingController(text: '1');
    final sessionTimeControllers = <TextEditingController>[
      TextEditingController(text: 'الفجر'),
    ];

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => Directionality(
          textDirection: TextDirection.rtl,
          child: AlertDialog(
            titlePadding: EdgeInsets.zero,
            title: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
              child: Row(
                children: [
                  IconButton(
                    icon:
                        const Icon(Icons.arrow_back, color: Color(0xFF1B5E20)),
                    onPressed: () => Navigator.pop(dialogContext),
                  ),
                  Expanded(
                    child: Text('تقسيم ختمة',
                        style: _quranStyle(
                            fontSize: 18, color: const Color(0xFF1B5E20))),
                  ),
                ],
              ),
            ),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'سيتم تقسيم الختمة من الصفحة الأولى دائماً. حدد عدد الأيام وعدد القراءات في اليوم. '
                    'سيتم استخدام علامة الختمة لتتبع آخر صفحة وصلت إليها.',
                    style: _quranStyle(
                        fontSize: 12,
                        color: Colors.grey.shade800,
                        fontWeight: FontWeight.normal),
                  ),
                  const SizedBox(height: 12),
                  Text('عدد الأيام للختمة',
                      style: _quranStyle(
                          fontSize: 14,
                          color: const Color(0xFF1B5E20),
                          fontWeight: FontWeight.w600)),
                  const SizedBox(height: 4),
                  TextField(
                    controller: daysController,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                    ),
                    onChanged: (_) => setDialogState(() {}),
                  ),
                  const SizedBox(height: 8),
                  Text('عدد القراءات في اليوم',
                      style: _quranStyle(
                          fontSize: 14,
                          color: const Color(0xFF1B5E20),
                          fontWeight: FontWeight.w600)),
                  const SizedBox(height: 4),
                  TextField(
                    controller: sessionsController,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                    ),
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
                        style: _quranStyle(
                            fontSize: 14,
                            color: const Color(0xFF1B5E20),
                            fontWeight: FontWeight.w600)),
                    const SizedBox(height: 4),
                    ...List.generate(
                      int.tryParse(sessionsController.text) ?? 1,
                      (i) {
                        if (i >= sessionTimeControllers.length) {
                          sessionTimeControllers.add(
                              TextEditingController(text: 'القراءة ${i + 1}'));
                        }
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: TextField(
                            controller: sessionTimeControllers[i],
                            decoration: InputDecoration(
                              labelText: 'وقت القراءة ${i + 1}',
                              border: const OutlineInputBorder(),
                              hintText: 'مثال: الفجر، الظهر، العصر...',
                            ),
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
                    style: _quranStyle(fontSize: 14, color: Colors.grey)),
              ),
              FilledButton(
                style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF2E7D32)),
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
                          style: _quranStyle(
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
                    style: _quranStyle(fontSize: 14, color: Colors.white)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showGoToBookmarkSheet(BuildContext context, int currentIndex) {
    final textStyle = _quranStyle(fontSize: 16, color: const Color(0xFF1B5E20));

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFFE8F5E9),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: StatefulBuilder(
          builder: (modalCtx, setModalState) => SafeArea(
            child: SizedBox(
              height: MediaQuery.of(ctx).size.height * 0.6,
              child: Column(
                children: [
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
                    child: Row(
                      children: [
                        IconButton(
                          icon: const Icon(Icons.arrow_back,
                              color: Color(0xFF1B5E20)),
                          onPressed: () => Navigator.pop(ctx),
                        ),
                        Expanded(
                          child: Text('انتقال إلى علامة',
                              style: _quranStyle(
                                  fontSize: 18,
                                  color: const Color(0xFF1B5E20),
                                  fontWeight: FontWeight.w700)),
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 1),
                  Expanded(
                    child: ListView(
                      padding: const EdgeInsets.symmetric(
                          vertical: 16, horizontal: 12),
                      children: [
                        const SizedBox(height: 12),
                        if (_mainBookmarkPage != null)
                          ListTile(
                            trailing: Icon(Icons.bookmark,
                                color: _mainBookmarkColor, size: 22),
                            title: Text(
                                'العلامة الرئيسية — ص $_mainBookmarkPage',
                                style: textStyle),
                            onTap: () {
                              Navigator.pop(ctx);
                              _navigateToPage(_mainBookmarkPage!);
                            },
                          ),
                        if (_khatmaBookmarkPage != null)
                          ListTile(
                            trailing: const Icon(Icons.bookmark,
                                color: Color(0xFF1565C0), size: 22),
                            title: Text('علامة الختمة — ص $_khatmaBookmarkPage',
                                style: textStyle),
                            onTap: () {
                              Navigator.pop(ctx);
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
                                          style: _quranStyle(
                                              fontSize: 18,
                                              color: const Color(0xFF1B5E20))),
                                      content: Text(
                                          'هل متأكد من حذف علامة (${b.name})؟',
                                          style: _quranStyle(
                                              fontSize: 14,
                                              color: Colors.black87,
                                              fontWeight: FontWeight.normal)),
                                      actions: [
                                        TextButton(
                                          onPressed: () => Navigator.pop(
                                              dialogContext, false),
                                          child: Text('إلغاء',
                                              style: _quranStyle(
                                                  fontSize: 14,
                                                  color: Colors.grey)),
                                        ),
                                        FilledButton(
                                          style: FilledButton.styleFrom(
                                              backgroundColor:
                                                  const Color(0xFF2E7D32)),
                                          onPressed: () => Navigator.pop(
                                              dialogContext, true),
                                          child: Text('نعم',
                                              style: _quranStyle(
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
                                    if (index >= 0 && index < updated.length) {
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
                              Navigator.pop(ctx);
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
                              style: _quranStyle(
                                  fontSize: 14,
                                  color: Colors.grey,
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
    );
  }

  void _showSearchDialog(BuildContext context, int currentIndex) {
    final queryController = TextEditingController();
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

    showDialog(
      context: context,
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          contentPadding: EdgeInsets.zero,
          insetPadding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 24),
          titlePadding: EdgeInsets.zero,
          title: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
            child: Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.arrow_back, color: Color(0xFF1B5E20)),
                  onPressed: () => Navigator.pop(ctx),
                ),
                Expanded(
                  child: Text('بحث في الآيات',
                      style: _quranStyle(
                          fontSize: 20, color: const Color(0xFF1B5E20))),
                ),
              ],
            ),
          ),
          content: SizedBox(
            width: double.maxFinite,
            height: MediaQuery.of(context).size.height * 0.8,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: TextField(
                    controller: queryController,
                    style: _quranStyle(
                        fontSize: 18,
                        color: Colors.black87,
                        fontWeight: FontWeight.normal),
                    decoration: InputDecoration(
                      hintText: 'اكتب جزءاً من الآية...',
                      hintStyle: _quranStyle(
                          fontSize: 16,
                          color: Colors.grey,
                          fontWeight: FontWeight.normal),
                      border: const OutlineInputBorder(),
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 12),
                    ),
                    onChanged: runSearch,
                    autofocus: true,
                  ),
                ),
                const SizedBox(height: 12),
                Expanded(
                  child: ValueListenableBuilder<
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
                      if (list.isEmpty && queryController.text.trim().isEmpty) {
                        return Center(
                          child: Text('اكتب نص الآية للبحث في الملف',
                              style: _quranStyle(
                                  fontSize: 16,
                                  color: Colors.grey,
                                  fontWeight: FontWeight.normal)),
                        );
                      }
                      if (list.isEmpty) {
                        return Center(
                          child: Text('لا توجد نتائج',
                              style: _quranStyle(
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
                                style: _quranStyle(
                                    fontSize: 18,
                                    color: const Color(0xFF1B5E20),
                                    fontWeight: FontWeight.normal)),
                            subtitle: Padding(
                              padding: const EdgeInsets.only(top: 4),
                              child: Text(
                                  '${a.suraNameAr} — آية ${a.ayaNo} — ص ${a.page}',
                                  style: _quranStyle(
                                      fontSize: 15,
                                      color: const Color(0xFF2E7D32),
                                      fontWeight: FontWeight.w600)),
                            ),
                            onTap: () {
                              Navigator.pop(ctx);
                              _navigateToPage(a.page);
                            },
                          );
                        },
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text('إغلاق',
                  style: _quranStyle(fontSize: 14, color: Colors.grey)),
            ),
          ],
        ),
      ),
    );
  }

  void _showFihrist(BuildContext context, int currentIndex) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFFE8F5E9),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: DraggableScrollableSheet(
          initialChildSize: 0.6,
          maxChildSize: 0.9,
          minChildSize: 0.3,
          expand: false,
          builder: (_, scrollController) => Column(
            children: [
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
                child: Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.arrow_back,
                          color: Color(0xFF1B5E20)),
                      onPressed: () => Navigator.pop(ctx),
                    ),
                    Expanded(
                      child: Text('الفهرس',
                          style: _quranStyle(
                              fontSize: 20, color: const Color(0xFF1B5E20))),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: ListView.separated(
                  controller: scrollController,
                  itemCount: _suraList.length,
                  separatorBuilder: (_, __) => const Divider(
                    height: 0.5,
                    color: Color(0xFFBDBDBD),
                  ),
                  itemBuilder: (_, i) {
                    final s = _suraList[i];
                    final pageIndex = s.startPage - 1;
                    final suraNo = s.no;
                    final ayatCount = _suraAyahCount[suraNo] ?? 0;
                    final isMadani = _madaniSuras.contains(suraNo);
                    return InkWell(
                      onTap: () {
                        Navigator.pop(ctx);
                        _navigateToPage(pageIndex + 1);
                      },
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
                                  style: _quranStyle(
                                      fontSize: 16,
                                      color: const Color(0xFF00695C),
                                      fontWeight: FontWeight.w700),
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                s.nameAr,
                                style: _quranStyle(
                                    fontSize: 18,
                                    color: const Color(0xFF1B5E20),
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
                                  style: _quranStyle(
                                      fontSize: 14,
                                      color: Colors.grey.shade800,
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
                                        ? const Color.fromARGB(255, 50, 168, 56)
                                        : const Color.fromARGB(
                                            255, 23, 112, 153),
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  child: Text(
                                    isMadani ? 'مدنية' : 'مكية',
                                    style: _quranStyle(
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
                                  style: _quranStyle(
                                      fontSize: 15,
                                      color: const Color(0xFF2E7D32),
                                      fontWeight: FontWeight.w700),
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
            ],
          ),
        ),
      ),
    );
  }

  void _showAjza(BuildContext context, int currentIndex) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFFE8F5E9),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: DraggableScrollableSheet(
          initialChildSize: 0.6,
          maxChildSize: 0.9,
          minChildSize: 0.3,
          expand: false,
          builder: (_, scrollController) => Column(
            children: [
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
                child: Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.arrow_back,
                          color: Color(0xFF1B5E20)),
                      onPressed: () => Navigator.pop(ctx),
                    ),
                    Expanded(
                      child: Text('الأجزاء',
                          style: _quranStyle(
                              fontSize: 20, color: const Color(0xFF1B5E20))),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: ListView.separated(
                  controller: scrollController,
                  itemCount: 30,
                  separatorBuilder: (_, __) => const Divider(
                    height: 0.5,
                    color: Color(0xFFBDBDBD),
                  ),
                  itemBuilder: (_, i) {
                    final juz = i + 1;
                    final startPage = _juzStartPage[juz] ?? 1;
                    final pageIndex = startPage - 1;
                    return InkWell(
                      onTap: () {
                        Navigator.pop(ctx);
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
                                    color: const Color(0xFF00695C),
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text('الجزء ${_juzNames[i]}',
                                  style: _quranStyle(
                                      fontSize: 18,
                                      color: const Color(0xFF1B5E20),
                                      fontWeight: FontWeight.w600)),
                            ),
                            const SizedBox(width: 10),
                            Text('ص ${_toNormalDigits(startPage)}',
                                style: TextStyle(
                                    fontSize: 15,
                                    color: const Color(0xFF2E7D32),
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
    );
  }

  void _showPagesDialog(BuildContext context, int currentIndex) {
    final initialPage = (currentIndex + 1).clamp(1, totalPages);
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _PageNumberPickerSheet(
        initialPage: initialPage,
        toNormalDigits: _toNormalDigits,
        onApply: (page) {
          _navigateToPage(page);
        },
      ),
    );
  }
}

class _PageNumberPickerSheet extends StatefulWidget {
  const _PageNumberPickerSheet({
    required this.initialPage,
    required this.toNormalDigits,
    required this.onApply,
  });

  final int initialPage; // 1..604
  final String Function(int) toNormalDigits;
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
    // يجب ألا يكون الجذر Expanded: الأب هنا SizedBox وليس Row — وإلا تنهار العجلات (ارتفاع 0).
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          title,
          textAlign: TextAlign.center,
          style: const TextStyle(
            color: Color(0xFF2E7D32),
            fontFamily: 'QuranUthmani',
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 6),
        Expanded(
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: const Color(0xFFB7DDBD)),
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
                        fontFamily: 'QuranUthmani',
                        fontSize: selected ? 22 : 18,
                        fontWeight:
                            selected ? FontWeight.w700 : FontWeight.w500,
                        color: selected
                            ? const Color(0xFF1B5E20)
                            : Colors.grey.shade700,
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
    return SafeArea(
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
            color: const Color(0xFFE8F5E9),
            borderRadius: BorderRadius.circular(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  decoration: const BoxDecoration(
                    color: Color(0xFFE8F5E9),
                    borderRadius:
                        BorderRadius.vertical(top: Radius.circular(16)),
                  ),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
                  child: Row(
                    children: [
                      IconButton(
                        icon: const Icon(Icons.arrow_back,
                            color: Color(0xFF1B5E20)),
                        onPressed: () => Navigator.pop(context),
                      ),
                      const Expanded(
                        child: Text(
                          'انتقال إلى صفحة',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontFamily: 'QuranUthmani',
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFF1B5E20),
                          ),
                        ),
                      ),
                      const SizedBox(width: 48),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'الصفحة: ${widget.toNormalDigits(_page)}',
                        style: const TextStyle(
                          fontFamily: 'QuranUthmani',
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF1B5E20),
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
                                backgroundColor: Colors.white,
                                side:
                                    const BorderSide(color: Color(0xFF2E7D32)),
                              ),
                              child: const Text(
                                'إعادة',
                                style: TextStyle(
                                  fontFamily: 'QuranUthmani',
                                  fontWeight: FontWeight.w700,
                                  color: Color(0xFF1B5E20),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: FilledButton(
                              style: FilledButton.styleFrom(
                                backgroundColor: const Color(0xFF2E7D32),
                              ),
                              onPressed: () {
                                Navigator.pop(context);
                                widget.onApply(_page);
                              },
                              child: const Text(
                                'انتقال',
                                style: TextStyle(
                                  fontFamily: 'QuranUthmani',
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
    );
  }
}

class _AyahWheelPicker extends StatelessWidget {
  const _AyahWheelPicker({
    required this.title,
    required this.controller,
    required this.itemCount,
    required this.itemBuilder,
    required this.onSelectedItemChanged,
  });

  final String title;
  final FixedExtentScrollController controller;
  final int itemCount;
  final String Function(int index) itemBuilder;
  final ValueChanged<int> onSelectedItemChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          title,
          style: const TextStyle(
            fontFamily: 'QuranUthmani',
            fontSize: 14,
            color: Color(0xFF1B5E20),
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: Container(
            height: 120,
            color: const Color(0xFFEFF6F0),
            child: CupertinoPicker.builder(
              scrollController: controller,
              itemExtent: 38,
              magnification: 1.03,
              useMagnifier: true,
              selectionOverlay: Container(
                decoration: BoxDecoration(
                  border: Border.symmetric(
                    horizontal: BorderSide(
                      color: const Color(0xFF1B5E20).withValues(alpha: 0.18),
                    ),
                  ),
                ),
              ),
              onSelectedItemChanged: onSelectedItemChanged,
              childCount: itemCount,
              itemBuilder: (_, i) => Center(
                child: Text(
                  itemBuilder(i),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontFamily: 'QuranUthmani',
                    fontSize: 18,
                    color: Color(0xFF1B5E20),
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// عنصر في قائمة الضغط المطول على آية
class _AyahMenuItem extends StatelessWidget {
  const _AyahMenuItem({
    required this.icon,
    required this.label,
    this.subtitle,
    this.enabled = true,
    required this.onTap,
  });
  final IconData icon;
  final String label;
  final String? subtitle;
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
                      fontFamily: 'QuranUthmani',
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
                        fontFamily: 'QuranUthmani',
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

enum _AudioListenMode { surah, ayah }

class _AudioRangePickerSheet extends StatefulWidget {
  const _AudioRangePickerSheet({
    required this.initialRange,
    required this.currentSura,
    required this.currentAyah,
    required this.suraList,
    required this.suraAyahCount,
    required this.toNormalDigits,
    required this.onApply,
    required this.onClear,
  });

  final AyahPlaybackRange? initialRange;
  final int? currentSura;
  final int? currentAyah;
  final List<({int no, String nameAr, int startPage})> suraList;
  final Map<int, int> suraAyahCount;
  final String Function(int) toNormalDigits;
  final Future<void> Function(
      int fromSura, int fromAyah, int toSura, int toAyah) onApply;
  final Future<void> Function() onClear;

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
    return Expanded(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: selected ? const Color(0xFF2E7D32) : Colors.white,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: const Color(0xFF2E7D32)),
          ),
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontFamily: 'QuranUthmani',
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: selected ? Colors.white : const Color(0xFF1B5E20),
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
    return Expanded(
      child: Column(
        children: [
          Text(
            title,
            style: const TextStyle(
              color: Color(0xFF2E7D32),
              fontFamily: 'QuranUthmani',
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          Expanded(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: const Color(0xFFB7DDBD)),
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
                          fontFamily: 'QuranUthmani',
                          fontSize: 15,
                          fontWeight:
                              selected ? FontWeight.w700 : FontWeight.w500,
                          color: selected
                              ? const Color(0xFF1B5E20)
                              : Colors.grey.shade700,
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
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'تحديد نطاق التشغيل',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: 'QuranUthmani',
                fontSize: 18,
                color: Color(0xFF1B5E20),
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
                fontFamily: 'QuranUthmani',
                fontSize: 14,
                color: Colors.green.shade900,
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
                      side: const BorderSide(color: Color(0xFF2E7D32)),
                    ),
                    child: const Text(
                      'إلغاء المدى',
                      style: TextStyle(
                        fontFamily: 'QuranUthmani',
                        color: Color(0xFF1B5E20),
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
                      backgroundColor: const Color(0xFF2E7D32),
                    ),
                    child: const Text(
                      'تطبيق وتشغيل',
                      style: TextStyle(
                        fontFamily: 'QuranUthmani',
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

    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFFE8F5E9),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: _TafseerRangePickerSheet(
          sura: _sura,
          fromAyah: from,
          toAyah: to,
          suraList: widget.suraList,
          suraAyahCount: widget.suraAyahCount,
          toNormalDigits: widget.toNormalDigits,
          quranStyle: widget.quranStyle,
          maxAyat: _maxAyat,
          onChanged: (s, f, t) {
            setState(() {
              _sura = s;
              _fromAyah = f;
              _toAyah = t;
            });
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tafseerSaadi = _buildTafseerForRange(widget.tafseerSaadiBySuraAya);
    final tafseerMouaser =
        _buildTafseerForRange(widget.tafseerMouaserBySuraAya);
    final headerText = _fromAyah == _toAyah
        ? 'تفسير ${_suraName()} – الآية ${widget.toNormalDigits(_fromAyah)}'
        : 'تفسير ${_suraName()} – من ${widget.toNormalDigits(_fromAyah)} إلى ${widget.toNormalDigits(_toAyah)}';

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
              color: const Color(0xFFE8F5E9),
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
                        icon: const Icon(Icons.close, color: Color(0xFF1B5E20)),
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
                                color: const Color(0xFF1B5E20),
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
                  labelColor: const Color(0xFF2E7D32),
                  unselectedLabelColor: Colors.grey,
                  indicatorColor: const Color(0xFF2E7D32),
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
                        isLightTheme: true,
                      ),
                      _TafseerTabContent(
                        text: tafseerMouaser,
                        isEmpty: tafseerMouaser.isEmpty ||
                            tafseerMouaser.startsWith('لا يوجد') ||
                            tafseerMouaser.startsWith('لا يمكن'),
                        isLightTheme: true,
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
                        backgroundColor: const Color(0xFF2E7D32),
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
    required this.maxAyat,
    required this.onChanged,
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
  final int maxAyat;
  final void Function(int sura, int fromAyah, int toAyah) onChanged;
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
    const textColor = Color(0xFF1B5E20);
    const mutedColor = Color(0xFF2E7D32);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'اختر السورة ونطاق الآيات (حد أقصى ${widget.maxAyat} آيات)',
              style: widget.quranStyle(
                fontSize: 16,
                color: textColor,
                fontWeight: FontWeight.bold,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
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
                                      color: sel
                                          ? textColor
                                          : Colors.grey.shade700,
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
                                      color: sel
                                          ? textColor
                                          : Colors.grey.shade700,
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
                                      color: sel
                                          ? textColor
                                          : Colors.grey.shade700,
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
  });
  final String text;
  final bool isEmpty;
  final bool isLightTheme;

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
          fontFamily: 'QuranUthmani',
          fontSize: 19,
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
  final VoidCallback onClose;
  final String sheetTitle;

  const _AzkarSheetContent({
    required this.azkarList,
    required this.toNormalDigits,
    required this.quranStyle,
    required this.arabicRegex,
    required this.onClose,
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
    final title =
        rawTitle.isEmpty ? 'أذكار وأدعية' : rawTitle;
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
    final list = widget.azkarList;
    final indices = List.generate(list.length, (i) => i)
        .where((i) => _matchesSearch(i))
        .toList();
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  widget.sheetTitle,
                  style: widget.quranStyle(
                      fontSize: 20,
                      color: const Color(0xFF1B5E20),
                      fontWeight: FontWeight.bold),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close, color: Color(0xFF1B5E20)),
                onPressed: widget.onClose,
              )
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: TextField(
            controller: _searchController,
            onChanged: (v) => setState(() => _searchQuery = v),
            decoration: InputDecoration(
              hintText: 'بحث في العناوين أو الذكر...',
              prefixIcon: const Icon(Icons.search, color: Color(0xFF2E7D32)),
              filled: true,
              fillColor: Colors.white,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            ),
            style: widget.quranStyle(
                fontSize: 16,
                color: const Color(0xFF1B5E20),
                fontWeight: FontWeight.normal),
          ),
        ),
        const Divider(height: 1),
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
                    color: Colors.white,
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
                                  color: const Color(0xFF1B5E20),
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
                                    ? const Color(0xFF2E7D32)
                                    : Colors.grey.shade400,
                              ),
                            ),
                          ),
                          const Icon(
                            Icons.arrow_forward_ios,
                            size: 16,
                            color: Color(0xFF2E7D32),
                          ),
                        ],
                      ),
                      if (zikr.texts.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Text(
                          'عدد الأذكار: ${widget.toNormalDigits(zikr.texts.length)}',
                          style: widget.quranStyle(
                              fontSize: 14,
                              color: Colors.grey.shade700,
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
    final zikr = widget.azkarList[index];
    final arabicTitle =
        zikr.titleAr ?? 'مجموعة أذكار ${widget.toNormalDigits(index + 1)}';
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
          child: Row(
            children: [
              IconButton(
                icon: const Icon(Icons.arrow_back_ios_new,
                    color: Color(0xFF1B5E20), size: 22),
                onPressed: _back,
              ),
              Expanded(
                child: Text(
                  arabicTitle,
                  style: widget.quranStyle(
                      fontSize: 18,
                      color: const Color(0xFF1B5E20),
                      fontWeight: FontWeight.bold),
                ),
              ),
              IconButton(
                icon: Transform.rotate(
                  angle: 3.14159265359,
                  child: Icon(
                    (_playingGroupIndex == index && _audioPlaying)
                        ? Icons.pause_circle_filled_rounded
                        : Icons.play_circle_fill_rounded,
                    color: const Color(0xFF2E7D32),
                  ),
                ),
                tooltip: 'تشغيل صوت المجموعة',
                onPressed: _hasPlayableAudio(index)
                    ? () async {
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
                      }
                    : null,
              ),
              IconButton(
                icon: const Icon(Icons.close, color: Color(0xFF1B5E20)),
                onPressed: widget.onClose,
              )
            ],
          ),
        ),
        const Divider(height: 1),
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
                  color: Colors.white,
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
                          color: Colors.black87,
                          fontWeight: FontWeight.w500),
                      textAlign: TextAlign.right,
                    ),
                    const SizedBox(height: 12),
                    if (showLangAr) ...[
                      Text(
                        text.languageArabicTranslatedText!,
                        style: widget.quranStyle(
                            fontSize: 16,
                            color: const Color(0xFF2E7D32),
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
    required Future<void> Function()? onPressed,
    double iconSize = 24,
  }) {
    return IconButton(
      icon: iconWidget ?? Icon(icon, color: Colors.white),
      iconSize: iconSize,
      onPressed: onPressed == null
          ? null
          : () async {
              await onPressed();
            },
    );
  }
}
