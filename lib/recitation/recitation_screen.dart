import 'dart:convert';
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:quran_app/quran/mushaf_page_layout.dart'
    show MushafPaperBackgroundScope, kMushafPaperBackgroundFallback;
import 'package:quran_app/quran/mushaf_stable_viewport.dart';
import 'package:quran_app/quran/renderers/qpc_v4_renderer.dart'
    show
        AyahRangeHighlight,
        kQpcPageNumberBottomGap,
        kQpcPageNumberRowHeight,
        kQpcPageNumberVerticalNudge,
        kQpcPageNumberVisualBoost,
        kQpcRaqumSvgScale,
        kQpcTopBarVerticalPadding;
import 'package:quran_app/quran/renderers/qpc_v4_black_renderer.dart'
    show QpcV4BlackPageView;
import 'package:quran_app/quran/ayah_highlight_persistence.dart';
import 'package:quran_app/quran/ayah_highlight_range_sheet.dart';
import 'package:quran_app/quran/ayah_highlights_main_menu_flow.dart';
import 'package:quran_app/quran/ayah_long_press_menu_dialog.dart';
import 'package:quran_app/quran/quran_menu_palette.dart';
import 'package:quran_app/quran/ayah_long_press_scope.dart';
import 'package:quran_app/recitation/arabic_normalizer.dart';
import 'package:quran_app/recitation/recitation_match_engine.dart';
import 'package:quran_app/recitation/recitation_logic.dart';
import 'package:quran_app/recitation/native_speech_service.dart';
import 'package:quran_app/recitation/recitation_db.dart';
import 'package:quran_app/recitation/recitation_review_screen.dart';
import 'package:quran_app/recitation/recitation_manual_start_sheet.dart';
import 'package:quran_app/audio/ayah_audio_player.dart';

enum _RecitationStage { detectingPosition, recitingMushaf }

/// رسالة عربية للمستخدم عند أخطاء التعرف الصوتي (بدون نص native تقني).
String _recitationSpeechErrorUserMessage(String? code) {
  switch (code) {
    case 'network':
    case 'network_timeout':
    case 'server':
    case 'server_disconnected':
      return 'تعذّر الاتصال بخدمة التعرف على الصوت. تحقق من الإنترنت وحاول مرة أخرى.';
    case 'permissions':
      return 'يحتاج التطبيق إلى صلاحية الميكروفون. فعّلها من إعدادات الجهاز ثم أعد المحاولة.';
    case 'speech_timeout':
    case 'no_match':
      return 'لم نسمع قراءة واضحة. قرّب الميكروفون وجرّب مرة أخرى.';
    default:
      return 'تعذّر بدء الاستماع. تأكد من صلاحية الميكروفون وحاول مرة أخرى.';
  }
}

class RecitationScreen extends StatefulWidget {
  const RecitationScreen({
    super.key,
    required this.initialSurahNumber,
    required this.initialAyahNumber,
    this.lockInitialAyahOnOpen = false,
  });

  final int initialSurahNumber;
  final int initialAyahNumber;

  /// يفتح التسميع مباشرةً على [initialSurahNumber]/[initialAyahNumber] دون مرحلة التموضع الصوتي
  /// (نفس مسار الاختيار اليدوي من العجلات).
  final bool lockInitialAyahOnOpen;

  static Future<void> open(
    BuildContext context, {
    required int initialSurahNumber,
    required int initialAyahNumber,
    bool lockInitialAyahOnOpen = false,
  }) {
    return Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => RecitationScreen(
          initialSurahNumber: initialSurahNumber,
          initialAyahNumber: initialAyahNumber,
          lockInitialAyahOnOpen: lockInitialAyahOnOpen,
        ),
      ),
    );
  }

  @override
  State<RecitationScreen> createState() => _RecitationScreenState();
}

class _RecitationScreenState extends State<RecitationScreen>
    with SingleTickerProviderStateMixin {
  static const String _keyMenuFontScale = 'menu_font_scale';

  /// نفس مفتاح [QuranPageViewer] ليتطابق لون القائمة المنبثقة مع القائمة الرئيسية.
  static const String _kPrefsMenuDarkMode = 'menu_dark_mode';
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

  final RecitationDb _db = RecitationDb.instance;
  final NativeSpeechService _speech = NativeSpeechService.instance;

  late final AnimationController _visualizerController;
  StreamSubscription<NativeSpeechEvent>? _speechSub;
  Timer? _voiceDecayTimer;
  Timer? _listeningHealthTimer;

  /// Delays heavy transcript matching on partial ASR to avoid jank; finals flush immediately.
  static const Duration _kTranscriptProcessDebounce =
      Duration(milliseconds: 200);
  Timer? _transcriptProcessDebounce;

  /// Serializes async transcript processing (debounced partials + awaited finals).
  Future<void> _transcriptProcessChain = Future<void>.value();
  int _transcriptWorkVersion = 0;
  DateTime? _lastSpeechResultAt;
  DateTime? _lastAutoRestartAt;
  bool _autoRestartInFlight = false;

  bool _loading = true;
  bool _speechAvailable = false;
  bool _hasPermission = false;
  bool _isListening = false;
  bool _manualStopRequested = false;
  bool _startingListening = false;
  bool _autoLocking = false;

  String? _error;
  // ignore: unused_field
  String _statusText = 'جاهز';
  String _transcript = '';
  double _menuFontScale = 1.0;
  double _voiceLevel = 0.14;
  int _candidateSearchToken = 0;
  String _lastCandidateQuery = '';
  int _candidateOverflowCount = 0;
  _RecitationStage _stage = _RecitationStage.detectingPosition;
  int? _activeRecitationSessionId;

  int _surahNumber = 1;
  int _ayahNumber = 1;
  int _currentWordNumberAll = 1;
  int _allowedBacktrackFloorWordNumberAll = 1;
  String _lastNormalizedRecitationTranscript = '';
  String _lastMarkedReviewAyahKey = '';

  /// First [word_number_all] when the user locked the position (start of this
  /// recitation pass). Used with [_currentWordNumberAll] so "backtrack" only
  /// widens *matching*, not *red stains* for words before the reading line.
  int? _recitationSessionStartWord;
  final Map<int, int> _pageToHizb = <int, int>{};

  List<_AyahCandidate> _voiceCandidates = const [];
  Map<String, Object?>? _currentAyah;
  List<Map<String, Object?>> _currentAyahWords = const [];
  Map<int, RecitationWordTone> _revealedWordTones = <int, RecitationWordTone>{};

  /// On-page words from earlier ayat than the current one (from review DB).
  Map<int, Color> _resumePeerPageColors = const {};

  bool _resumeLastPositionInFlight = false;

  /// [DelayedLongPressDetector] على المصحف يفوز باختبار الضربات فيمنع
  /// [GestureDetector.onTap] الأب؛ نستخدم [Listener] مع مدة قصيرة أقل من
  /// ضغط المصحف الطويل (٤٠٠ ms) لاستدعاء الخيارات عند النقر على النص أيضاً.
  static const Duration _kRecitationQuickTapMaxDuration =
      Duration(milliseconds: 350);
  int? _recitationBodyPointerId;
  DateTime? _recitationBodyPointerDownUtc;

  // Long-session compaction:
  // keep a bounded matching baseline and prune far-away tone history.
  static const int _kBaselineKeepTailTokens = 84;
  static const int _kToneHistoryKeepBehindWords = 900;
  static const int _kToneHistoryKeepAheadWords = 180;
  static const int _kToneHistoryKeepBehindMaxWords = 4800;
  int _dynamicToneHistoryKeepBehindWords = _kToneHistoryKeepBehindWords;

  @override
  void initState() {
    super.initState();
    AyahAudioPlayer.instance.enterRecitationAyahSession();
    unawaited(_loadMenuFontScale());
    _visualizerController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat();
    _surahNumber = widget.initialSurahNumber;
    _ayahNumber = widget.initialAyahNumber;
    _bootstrap();
  }

  Future<void> _loadMenuFontScale() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final scale =
          (prefs.getDouble(_keyMenuFontScale) ?? 1.0).clamp(0.85, 1.4);
      if (!mounted) return;
      setState(() => _menuFontScale = scale);
    } catch (_) {}
  }

  Future<void> _bootstrap() async {
    try {
      await _db.init();
      _speechAvailable = await _speech.isAvailable();
      _hasPermission = await _speech.hasPermission();
      _subscribeToSpeechEvents();
      _startListeningHealthWatchdog();
      await _loadPageHizbMap();

      if (mounted && widget.lockInitialAyahOnOpen) {
        final ayahMeta = await _db.getAyah(
          widget.initialSurahNumber,
          widget.initialAyahNumber,
        );
        if (!mounted) return;
        if (ayahMeta == null) {
          setState(() {
            _error = 'تعذر تحميل الآية المختارة.';
          });
        } else {
          final candidate = _candidateFromAyahDbRow(ayahMeta);
          await _lockVoiceCandidate(candidate, transcript: '', isFinal: true);
        }
      }
    } catch (e) {
      debugPrint('Recitation init failed: $e');
      _error = 'تعذّر تهيئة شاشة التسميع. أعد المحاولة.';
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
    if (!_speechAvailable && mounted && _error == null) {
      setState(() {
        _error =
            'التعرف الصوتي العربي غير متاح على هذا الجهاز. أضف اللغة العربية من إعدادات الجهاز أو جرّب جهازاً آخر.';
      });
      return;
    }
    if (_speechAvailable && mounted && _error == null) {
      unawaited(_startListening());
    }
  }

  Future<void> _loadPageHizbMap() async {
    try {
      final raw = await rootBundle.loadString('assets/data/hafs_smart_v8.json');
      final list = jsonDecode(raw) as List<dynamic>;
      final pageToJuz = <int, int>{};
      for (final entry in list) {
        final map = Map<String, dynamic>.from(entry as Map);
        final page = (map['page'] as num?)?.toInt() ?? 0;
        final jozz = (map['jozz'] as num?)?.toInt() ?? 0;
        if (page >= 1 && page <= 604 && jozz >= 1 && jozz <= 30) {
          pageToJuz.putIfAbsent(page, () => jozz);
        }
      }
      final juzToPages = <int, List<int>>{};
      for (var page = 1; page <= 604; page++) {
        final juz = pageToJuz[page] ?? 1;
        juzToPages.putIfAbsent(juz, () => <int>[]).add(page);
      }
      _pageToHizb.clear();
      for (var juz = 1; juz <= 30; juz++) {
        final pages = (juzToPages[juz] ?? <int>[])..sort();
        final half = (pages.length / 2).ceil();
        for (var i = 0; i < pages.length; i++) {
          final hizb = (juz - 1) * 2 + (i < half ? 1 : 2);
          _pageToHizb[pages[i]] = hizb.clamp(1, 60);
        }
      }
    } catch (_) {
      // Keep fallback label if metadata file is unavailable.
    }
  }

  void _subscribeToSpeechEvents() {
    _speechSub?.cancel();
    _speechSub = _speech.events.listen(_handleSpeechEvent);
  }

  void _startListeningHealthWatchdog() {
    _listeningHealthTimer?.cancel();
    _listeningHealthTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!mounted) return;
      if (!_speechAvailable || !_isListening || _manualStopRequested) return;
      final last = _lastSpeechResultAt;
      if (last == null) return;
      final silence = DateTime.now().difference(last);
      // Long silence while "listening" usually means recognizer got stuck.
      if (silence >= const Duration(seconds: 25)) {
        unawaited(_attemptAutoRestart('watchdog_silence'));
      }
    });
  }

  Future<void> _attemptAutoRestart(String reason) async {
    if (!mounted || !_speechAvailable || _manualStopRequested) return;
    if (_autoRestartInFlight) return;
    final last = _lastAutoRestartAt;
    if (last != null &&
        DateTime.now().difference(last) < const Duration(seconds: 3)) {
      return;
    }
    _autoRestartInFlight = true;
    _lastAutoRestartAt = DateTime.now();
    setState(() {
      _isListening = false;
      _statusText = 'انقطع الاستماع، نحاول إعادة التشغيل...';
    });
    _setVoiceIdleFloor(active: false);
    try {
      await _speech.cancelListening();
    } catch (_) {}
    if (!mounted || _manualStopRequested) {
      _autoRestartInFlight = false;
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 850));
    if (!mounted || _manualStopRequested) {
      _autoRestartInFlight = false;
      return;
    }
    await _startListening();
    if (!mounted || _manualStopRequested) {
      _autoRestartInFlight = false;
      return;
    }
    if (!_isListening) {
      setState(() {
        _statusText = 'تعذر استرجاع الاستماع تلقائيًا ($reason)';
      });
    }
    _autoRestartInFlight = false;
  }

  Future<void> _loadAyah(
    int surahNumber,
    int ayahNumber, {
    required bool resetProgress,
    bool preservePointer = false,
    bool resetTranscriptBaseline = true,
    int? initialPointerWordNumberAll,
  }) async {
    final ayah = await _db.getAyah(surahNumber, ayahNumber);
    if (ayah == null) {
      if (mounted) {
        setState(() {
          _error = 'تعذر تحميل الآية المحددة.';
        });
      }
      return;
    }

    final words = await _db.getDisplayWordsForAyah(surahNumber, ayahNumber);
    if (words.isEmpty) {
      if (mounted) {
        setState(() {
          _error = 'لا توجد كلمات ظاهرة لهذه الآية.';
        });
      }
      return;
    }

    final firstSpokenWord = words.firstWhere(
      (word) => (word['is_ayah_marker'] as int? ?? 0) == 0,
      orElse: () => words.first,
    );
    final firstWordInAyah = (firstSpokenWord['word_number_all'] as int?) ?? 1;

    if (!mounted) return;

    // Keep already revealed words unless the flow explicitly reset them
    // (e.g. switching back to position-detection stage).
    final nextRevealTones =
        Map<int, RecitationWordTone>.from(_revealedWordTones);
    final ayahWordIds = words
        .where((word) => (word['is_ayah_marker'] as int? ?? 0) == 0)
        .map((word) => (word['word_number_all'] as int?) ?? 0)
        .where((id) => id > 0)
        .toList(growable: false);
    final lastSpokenInAyah =
        ayahWordIds.isEmpty ? firstWordInAyah : ayahWordIds.reduce(math.max);
    final int nextPointer;
    if (preservePointer) {
      nextPointer = _currentWordNumberAll;
    } else if (initialPointerWordNumberAll != null) {
      nextPointer =
          initialPointerWordNumberAll.clamp(firstWordInAyah, lastSpokenInAyah);
    } else {
      nextPointer = firstWordInAyah;
    }
    final backtrackWindow = recitationBacktrackWindow(ayahWordIds.length);
    final backtrackFloor = math.max(1, nextPointer - backtrackWindow);

    setState(() {
      _currentAyah = ayah;
      _currentAyahWords = words;
      _surahNumber = surahNumber;
      _ayahNumber = ayahNumber;
      _currentWordNumberAll = nextPointer;
      _allowedBacktrackFloorWordNumberAll = backtrackFloor;
      if (resetTranscriptBaseline) {
        _lastNormalizedRecitationTranscript = '';
      }
      if (!preservePointer) {
        _lastMarkedReviewAyahKey = '';
      }
      _transcript = '';
      _statusText = _isListening ? 'يستمع الآن...' : 'جاهز للبدء';
      _revealedWordTones = nextRevealTones;
      _compactRecitationStateInLongSession();
      _error = null;
    });
    if (_stage == _RecitationStage.recitingMushaf) {
      unawaited(_refreshResumePeerPageColors());
    }
  }

  Set<int> _wrongWordIdsFromStatsField(Object? raw) {
    final s = (raw ?? '').toString().trim();
    if (s.isEmpty) return const {};
    try {
      final decoded = jsonDecode(s);
      if (decoded is! List) return const {};
      return decoded
          .map((e) => int.tryParse(e.toString()) ?? 0)
          .where((e) => e > 0)
          .toSet();
    } catch (_) {
      return const {};
    }
  }

  Map<int, RecitationWordTone> _resumeTonesForAyahWordsUpToPointer({
    required List<Map<String, Object?>> words,
    required int pointerWordNumberAll,
    required Set<int> wrongWordIds,
  }) {
    final tones = <int, RecitationWordTone>{};
    for (final w in words) {
      if ((w['is_ayah_marker'] as int? ?? 0) != 0) continue;
      final id = (w['word_number_all'] as int?) ?? 0;
      if (id <= 0 || id > pointerWordNumberAll) continue;
      tones[id] = wrongWordIds.contains(id)
          ? RecitationWordTone.wrong
          : RecitationWordTone.correct;
    }
    return tones;
  }

  Future<Map<int, Color>> _fullAyahColorsFromStatsRow({
    required int surahNumber,
    required int ayahNumber,
    required Map<String, Object?> statsRow,
  }) async {
    final words = await _db.getDisplayWordsForAyah(surahNumber, ayahNumber);
    final wrongIds =
        _wrongWordIdsFromStatsField(statsRow['last_error_word_ids']);
    final out = <int, Color>{};
    for (final w in words) {
      if ((w['is_ayah_marker'] as int? ?? 0) != 0) continue;
      final id = (w['word_number_all'] as int?) ?? 0;
      if (id <= 0) continue;
      final tone = wrongIds.contains(id)
          ? RecitationWordTone.wrong
          : RecitationWordTone.correct;
      out[id] = _wordRevealColor(tone);
    }
    return out;
  }

  Future<void> _refreshResumePeerPageColors() async {
    if (_stage != _RecitationStage.recitingMushaf || _currentAyah == null) {
      return;
    }
    final page = (_currentAyah!['page_number'] as int?) ?? 0;
    final currentAyahId = (_currentAyah!['id'] as int?) ?? 0;
    if (page <= 0 || currentAyahId <= 0) return;

    final ayahsOnPage = await _db.getAyahsOnPageOrdered(page);
    final sessionStartWord = _recitationSessionStartWord;
    final merged = <int, Color>{};
    for (final row in ayahsOnPage) {
      final ayahId = (row['id'] as int?) ?? 0;
      if (ayahId <= 0 || ayahId >= currentAyahId) break;
      final ayahLastWord = (row['last_word_number_all'] as int?) ?? 0;
      if (sessionStartWord != null &&
          sessionStartWord > 0 &&
          ayahLastWord > 0 &&
          ayahLastWord < sessionStartWord) {
        // Ignore recitation stats from ayahs read in older sessions.
        continue;
      }
      final s = (row['surah_number'] as int?) ?? 0;
      final a = (row['ayah_number'] as int?) ?? 0;
      if (s <= 0 || a <= 0) continue;
      final stats = await _db.getAyahStatsRow(s, a);
      if (stats == null) continue;
      final tw = (stats['total_words'] as int?) ?? 0;
      final ta = (stats['total_attempts'] as int?) ?? 0;
      if (tw <= 0 && ta <= 0) continue;
      merged.addAll(await _fullAyahColorsFromStatsRow(
        surahNumber: s,
        ayahNumber: a,
        statsRow: stats,
      ));
    }
    if (!mounted) return;
    setState(() {
      _resumePeerPageColors = merged;
    });
  }

  Future<void> _resumeFromLastSavedRecitationPosition() async {
    if (_resumeLastPositionInFlight || _autoLocking) return;
    setState(() => _resumeLastPositionInFlight = true);
    try {
      final state = await _db.getRecitationState();
      final rs = (state?['last_surah'] as int?) ?? 0;
      final ra = (state?['last_ayah'] as int?) ?? 0;
      if (rs < 1 || ra < 1) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
                content: Text(
                    'لا يوجد موضع محفوظ بعد. ابدأ بتحديد الموضع أو القراءة.')),
          );
        }
        return;
      }

      final ayahRow = await _db.getAyah(rs, ra);
      if (ayahRow == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
                content: Text('تعذر قراءة الموضع المحفوظ من قاعدة البيانات.')),
          );
        }
        return;
      }

      final firstW = (ayahRow['first_word_number_all'] as int?) ?? 1;
      final lastW = (ayahRow['last_word_number_all'] as int?) ?? firstW;
      var pointer = (state?['last_word_number_all'] as int?) ?? firstW;
      if (pointer <= 0) pointer = firstW;
      pointer = pointer.clamp(firstW, lastW);

      final stats = await _db.getAyahStatsRow(rs, ra);
      final wrongIds =
          _wrongWordIdsFromStatsField(stats?['last_error_word_ids']);

      final words = await _db.getDisplayWordsForAyah(rs, ra);
      if (words.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('لا توجد كلمات لهذه الآية.')),
          );
        }
        return;
      }

      final resumeTones = _resumeTonesForAyahWordsUpToPointer(
        words: words,
        pointerWordNumberAll: pointer,
        wrongWordIds: wrongIds,
      );

      final sid = _activeRecitationSessionId;
      _activeRecitationSessionId = null;
      if (sid != null) {
        await _db.endRecitationSession(sid);
      }

      if (!mounted) return;
      setState(() {
        _resumePeerPageColors = const {};
        _stage = _RecitationStage.recitingMushaf;
        _voiceCandidates = const [];
        _candidateOverflowCount = 0;
        _transcript = '';
        _error = null;
        _revealedWordTones = resumeTones;
        _lastNormalizedRecitationTranscript = '';
        _lastMarkedReviewAyahKey = '';
        _statusText = _isListening ? 'يستمع الآن...' : 'جاهز للبدء';
      });

      await _loadAyah(
        rs,
        ra,
        resetProgress: true,
        preservePointer: false,
        resetTranscriptBaseline: true,
        initialPointerWordNumberAll: pointer,
      );

      if (!mounted || _currentAyah == null || _error != null) {
        return;
      }

      if (!mounted) return;
      setState(() {
        _recitationSessionStartWord = _firstSpokenWordNumberAllInAyah;
        _dynamicToneHistoryKeepBehindWords = _kToneHistoryKeepBehindWords;
      });

      _activeRecitationSessionId = await _db.startRecitationSession(
        startSurah: _surahNumber,
        startAyah: _ayahNumber,
        lastWordNumberAll: _currentWordNumberAll,
      );

      final ord = _orderedSpokenWordIdsInAyah;
      if (ord.isNotEmpty) {
        await _syncAyahReviewStatsRow(
          surahNumber: _surahNumber,
          ayahNumber: _ayahNumber,
          orderedSpokenWordIds: ord,
          tones: _revealedWordTones,
          lastScore: (stats?['last_score'] as num?)?.toDouble(),
          lastStatus: (stats?['last_status'] ?? 'in_progress').toString(),
          incrementAttempts: false,
        );
      }

      await _refreshResumePeerPageColors();
    } finally {
      if (mounted) {
        setState(() {
          _resumeLastPositionInFlight = false;
        });
      } else {
        _resumeLastPositionInFlight = false;
      }
    }
  }

  List<int> get _orderedSpokenWordIdsInAyah {
    final ids = _currentAyahWords
        .where((word) => (word['is_ayah_marker'] as int? ?? 0) == 0)
        .map((word) => (word['word_number_all'] as int?) ?? 0)
        .where((id) => id > 0)
        .toList()
      ..sort();
    return ids;
  }

  int? get _firstSpokenWordNumberAllInAyah {
    for (final w in _currentAyahWords) {
      if ((w['is_ayah_marker'] as int? ?? 0) != 0) continue;
      final n = (w['word_number_all'] as int?) ?? 0;
      if (n > 0) return n;
    }
    return null;
  }

  void _cancelTranscriptProcessDebounce() {
    _transcriptProcessDebounce?.cancel();
    _transcriptProcessDebounce = null;
  }

  void _appendTranscriptProcess(
    Future<void> Function() work,
  ) {
    _transcriptProcessChain =
        _transcriptProcessChain.catchError((Object? _) {}).then((_) => work());
  }

  String _compactBaseline(String normalized,
      {int keepTailTokens = _kBaselineKeepTailTokens}) {
    final tokens = normalized
        .split(' ')
        .map((t) => t.trim())
        .where((t) => t.isNotEmpty)
        .toList(growable: false);
    if (tokens.length <= keepTailTokens) return normalized;
    return tokens.sublist(tokens.length - keepTailTokens).join(' ');
  }

  void _compactRecitationStateInLongSession() {
    if (_revealedWordTones.isEmpty) return;
    final pointer = _currentWordNumberAll;
    final keepFrom = math.max(1, pointer - _dynamicToneHistoryKeepBehindWords);
    final keepTo = pointer + _kToneHistoryKeepAheadWords;
    _revealedWordTones.removeWhere((id, _) => id < keepFrom || id > keepTo);
  }

  void _adaptToneHistoryWindow({
    required int pointerBefore,
    required int pointerAfter,
  }) {
    if (pointerAfter < pointerBefore) {
      final backward = pointerBefore - pointerAfter;
      final desired = _kToneHistoryKeepBehindWords + backward + 900;
      _dynamicToneHistoryKeepBehindWords = math.min(
        _kToneHistoryKeepBehindMaxWords,
        math.max(_dynamicToneHistoryKeepBehindWords, desired),
      );
      return;
    }
    if (_dynamicToneHistoryKeepBehindWords > _kToneHistoryKeepBehindWords) {
      _dynamicToneHistoryKeepBehindWords = math.max(
        _kToneHistoryKeepBehindWords,
        _dynamicToneHistoryKeepBehindWords - 140,
      );
    }
  }

  List<int> _orderedSpokenWordIdsFromWords(List<Map<String, Object?>> words) {
    final ids = words
        .where((word) => (word['is_ayah_marker'] as int? ?? 0) == 0)
        .map((word) => (word['word_number_all'] as int?) ?? 0)
        .where((id) => id > 0)
        .toList()
      ..sort();
    return ids;
  }

  /// يحدّث صف [recitation_ayah_stats] ليتوافق مع [tones] (مراجعة التسميع).
  Future<({int correct, int wrong})> _syncAyahReviewStatsRow({
    required int surahNumber,
    required int ayahNumber,
    required List<int> orderedSpokenWordIds,
    required Map<int, RecitationWordTone> tones,
    required double? lastScore,
    required String lastStatus,
    required bool incrementAttempts,
  }) async {
    if (orderedSpokenWordIds.isEmpty) return (correct: 0, wrong: 0);
    var correct = 0;
    var wrong = 0;
    final wrongIds = <int>[];
    for (final id in orderedSpokenWordIds) {
      final t = tones[id];
      if (t == RecitationWordTone.correct ||
          t == RecitationWordTone.acceptable ||
          t == RecitationWordTone.softCorrect) {
        correct += 1;
      } else if (t == RecitationWordTone.wrong) {
        wrong += 1;
        wrongIds.add(id);
      }
    }
    await _db.upsertAyahRecitationStats(
      surahNumber: surahNumber,
      ayahNumber: ayahNumber,
      totalWords: orderedSpokenWordIds.length,
      correctWords: correct,
      wrongWords: wrong,
      lastScore: lastScore,
      lastStatus: lastStatus,
      lastErrorWordIdsJson: jsonEncode(wrongIds),
      incrementAttempts: incrementAttempts,
    );
    return (correct: correct, wrong: wrong);
  }

  Future<void> _persistRecitationSnapshot({
    required RecitationMatchResult match,
    required bool isFinal,
  }) async {
    await _db.upsertRecitationState(
      sessionId: _activeRecitationSessionId,
      surahNumber: _surahNumber,
      ayahNumber: _ayahNumber,
      lastWordNumberAll: _currentWordNumberAll,
    );

    final ordered = _orderedSpokenWordIdsInAyah;
    if (ordered.isEmpty) return;
    final tallies = await _syncAyahReviewStatsRow(
      surahNumber: _surahNumber,
      ayahNumber: _ayahNumber,
      orderedSpokenWordIds: ordered,
      tones: _revealedWordTones,
      lastScore: match.bestMatchScore,
      lastStatus: isFinal
          ? (match.advanceDecision.shouldAdvance ? 'review' : 'weak')
          : 'in_progress',
      incrementAttempts: isFinal,
    );
    if (!isFinal) return;

    final sid = _activeRecitationSessionId;
    if (sid != null) {
      await _db.updateSessionProgress(
        sessionId: sid,
        surahNumber: _surahNumber,
        ayahNumber: _ayahNumber,
        pointerWordNumberAll: _currentWordNumberAll,
        totalWordsDelta: ordered.length,
        correctWordsDelta: tallies.correct,
        wrongWordsDelta: tallies.wrong,
      );
    }
  }

  Future<void> _handleSpeechEvent(NativeSpeechEvent event) async {
    if (!mounted) return;
    switch (event.type) {
      case 'status':
        final status = event.status ?? '';
        switch (status) {
          case 'listening':
            _lastSpeechResultAt = DateTime.now();
            setState(() {
              _isListening = true;
              _statusText = _stage == _RecitationStage.detectingPosition
                  ? 'اقرأ من الموضع الذي تريد البدء منه'
                  : 'يستمع الآن...';
            });
            _setVoiceIdleFloor();
            break;
          case 'stopped':
            if (_manualStopRequested) {
              setState(() {
                _isListening = false;
                _statusText = 'توقف الاستماع';
              });
              _setVoiceIdleFloor(active: false);
            } else {
              unawaited(_attemptAutoRestart('native_stopped'));
            }
            break;
          default:
            break;
        }
        break;
      case 'result':
        final text = event.text?.trim() ?? '';
        if (text.isEmpty) return;
        final workVersion = ++_transcriptWorkVersion;
        setState(() {
          _transcript = text;
        });
        _lastSpeechResultAt = DateTime.now();
        _bumpVoiceLevel(_estimateVoiceLevel(text, event.confidence));
        if (event.isFinal) {
          _cancelTranscriptProcessDebounce();
          try {
            await _transcriptProcessChain;
          } catch (_) {
            // Prior step may have failed; still apply the final transcript.
          }
          if (!mounted) return;
          if (_stage == _RecitationStage.detectingPosition) {
            await _processPositionTranscript(text, isFinal: true);
          } else {
            await _processTranscript(text, isFinal: true);
          }
        } else {
          _cancelTranscriptProcessDebounce();
          _transcriptProcessDebounce = Timer(
            _kTranscriptProcessDebounce,
            () {
              _transcriptProcessDebounce = null;
              if (!mounted) return;
              _appendTranscriptProcess(() async {
                if (!mounted) return;
                if (workVersion != _transcriptWorkVersion) {
                  // Skip stale partial work; only latest transcript matters.
                  return;
                }
                final latest = _transcript.trim();
                if (latest.isEmpty) return;
                if (_stage == _RecitationStage.detectingPosition) {
                  await _processPositionTranscript(latest, isFinal: false);
                } else {
                  await _processTranscript(latest, isFinal: false);
                }
              });
            },
          );
        }
        break;
      case 'error':
        final transientCodes = <String>{
          'no_match',
          'speech_timeout',
          'client',
          'busy',
          // Google on-device / network speech can drop mid-session (long surah).
          'network',
          'network_timeout',
          'server',
          'server_disconnected',
        };
        if (_isListening &&
            !_manualStopRequested &&
            transientCodes.contains(event.code)) {
          // Keep UI steady for transient recognizer glitches and let the
          // watchdog / native layer recover without stop-start jitter.
          break;
        }
        setState(() {
          final code = event.code?.trim();
          debugPrint(
            'Speech recognition error: code=$code message=${event.message}',
          );
          _error = _recitationSpeechErrorUserMessage(code);
          _statusText = 'خطأ في الاستماع';
          _isListening = false;
        });
        _setVoiceIdleFloor(active: false);
        break;
      default:
        break;
    }
  }

  Future<void> _ensurePermission() async {
    if (_hasPermission) return;
    _hasPermission = await _speech.requestPermission();
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _startListening() async {
    if (_startingListening || _isListening) return;
    await _ensurePermission();
    if (!_hasPermission) {
      if (mounted) {
        setState(() {
          _error =
              'يحتاج التطبيق إلى صلاحية الميكروفون. فعّلها من إعدادات الجهاز ثم أعد المحاولة.';
          _statusText = 'الإذن مرفوض';
        });
      }
      return;
    }

    _startingListening = true;
    _manualStopRequested = false;
    if (mounted) {
      setState(() {
        _statusText = 'يفتح المايكروفون...';
      });
    }
    try {
      await _speech.startListening(
        locale: 'ar',
        partialResults: true,
        continuous: true,
      );
      if (mounted) {
        setState(() {
          _isListening = true;
          _statusText = _stage == _RecitationStage.detectingPosition
              ? 'اقرأ من الموضع الذي تريد البدء منه'
              : 'يستمع الآن...';
        });
      }
      _lastSpeechResultAt = DateTime.now();
      _setVoiceIdleFloor();
    } catch (e) {
      debugPrint('Start listening failed: $e');
      if (mounted) {
        final String startErrorMsg;
        if (e is PlatformException && e.code == 'not_available') {
          startErrorMsg =
              'التعرف الصوتي العربي غير متاح على هذا الجهاز. أضف اللغة العربية من إعدادات الجهاز أو جرّب جهازاً آخر.';
        } else if (e is PlatformException && e.code == 'missing_permission') {
          startErrorMsg =
              'يحتاج التطبيق إلى صلاحية الميكروفون والتعرف على الكلام. فعّل الصلاحيات من إعدادات الجهاز ثم أعد المحاولة.';
        } else {
          startErrorMsg =
              'تعذّر بدء الاستماع. تأكد من صلاحية الميكروفون وحاول مرة أخرى.';
        }
        setState(() {
          _error = startErrorMsg;
          _statusText = 'تعذر البدء';
        });
      }
    } finally {
      _startingListening = false;
    }
  }

  Future<void> _stopListening() async {
    _manualStopRequested = true;
    _transcriptWorkVersion += 1;
    final sid = _activeRecitationSessionId;
    _activeRecitationSessionId = null;
    if (sid != null) {
      await _db.endRecitationSession(sid);
    }
    try {
      await _speech.stopListening();
    } catch (_) {}
    if (mounted) {
      setState(() {
        _isListening = false;
        _statusText = 'متوقف';
      });
    }
    _setVoiceIdleFloor(active: false);
  }

  /// Unions main OR-token search with “short ayah read at start of clip” rows;
  /// on duplicate [ayah_id], keeps the row with higher [rank].
  List<Map<String, Object?>> _mergeAyahSearchRows(
    List<Map<String, Object?>> main,
    List<Map<String, Object?>> supplement,
  ) {
    final byId = <int, Map<String, Object?>>{};
    for (final r in main) {
      final id = (r['ayah_id'] as int?) ?? 0;
      if (id == 0) continue;
      byId[id] = r;
    }
    for (final r in supplement) {
      final id = (r['ayah_id'] as int?) ?? 0;
      if (id == 0) continue;
      final existing = byId[id];
      if (existing == null) {
        byId[id] = r;
        continue;
      }
      final rRank = (r['rank'] as num?)?.toDouble() ?? 0;
      final eRank = (existing['rank'] as num?)?.toDouble() ?? 0;
      if (rRank > eRank) {
        byId[id] = r;
      }
    }
    return byId.values.toList();
  }

  _AyahCandidate _candidateFromAyahDbRow(Map<String, Object?> row) {
    final m = Map<String, Object?>.from(row);
    m['ayah_id'] = row['id'];
    m['rank'] = 10000.0;
    return _AyahCandidate.fromMap(m);
  }

  _AyahCandidate _mapRowToRankedCandidate(
    Map<String, Object?> map,
    String query,
  ) {
    var c = _AyahCandidate.fromMap(map).withHeuristicScore(query);
    final fs = (map['fuzzy_score'] as num?)?.toDouble();
    if (fs != null && !c.passesOrderedThreshold && fs >= 0.38) {
      c = c.copyWith(
        passesOrderedThreshold: true,
        heuristicScore: math.max(c.heuristicScore, fs * 0.95),
        orderedCoverage: math.max(c.orderedCoverage, fs * 0.85),
      );
    }
    return c;
  }

  List<_AyahCandidate> _buildRankedAyahCandidateList(
    List<Map<String, Object?>> rows,
    String query,
  ) {
    return rows
        .map((m) => _mapRowToRankedCandidate(m, query))
        .where((candidate) => candidate.label.isNotEmpty)
        .where((candidate) => candidate.passesOrderedThreshold)
        .toList()
      ..sort((a, b) {
        final precise = (b.isPreciseMatch ? 1 : 0) - (a.isPreciseMatch ? 1 : 0);
        if (precise != 0) return precise;
        final lead = b.leadingConsecutiveAtAyahStart
            .compareTo(a.leadingConsecutiveAtAyahStart);
        if (lead != 0) return lead;
        final ordered = b.orderedCoverage.compareTo(a.orderedCoverage);
        if (ordered != 0) return ordered;
        final heuristic = b.heuristicScore.compareTo(a.heuristicScore);
        if (heuristic != 0) return heuristic;
        return b.rank.compareTo(a.rank);
      });
  }

  Future<void> _processPositionTranscript(
    String transcript, {
    required bool isFinal,
  }) async {
    final query = ArabicNormalizer.normalizeForSearch(transcript).trim();
    if (query.isEmpty || _autoLocking) return;
    final queryTokens = query
        .split(' ')
        .map((t) => t.trim())
        .where((t) => t.isNotEmpty)
        .toList();
    final tokenCount = queryTokens.length;
    final compact = query.replaceAll(' ', '');
    // موضعٌ مميّز قد يُعرف بكلمة واحدة (الم، الضحى، كهيعص، مدهامتان…).
    if (tokenCount == 1 && compact.length < 2) {
      setState(() {
        _voiceCandidates = const [];
        _candidateOverflowCount = 0;
        _statusText = 'نطق كلمة أطول قليلاً (حرفان على الأقل)';
      });
      return;
    }
    if (!isFinal && query == _lastCandidateQuery) return;

    _lastCandidateQuery = query;
    final currentSearchToken = ++_candidateSearchToken;
    final candidatesRows =
        await _db.searchAyahCandidates(transcript, limit: 120);
    final headRows = await _db.searchAyahCandidatesBySpokenHead(transcript);
    final mergedRows = _mergeAyahSearchRows(candidatesRows, headRows);

    if (!mounted ||
        _stage != _RecitationStage.detectingPosition ||
        currentSearchToken != _candidateSearchToken) {
      return;
    }

    var rankedCandidates = _buildRankedAyahCandidateList(mergedRows, query);

    if (rankedCandidates.isEmpty) {
      final fuzzyRows = await _db.searchAyahFuzzyByAsr(transcript, limit: 25);
      if (fuzzyRows.isNotEmpty) {
        rankedCandidates = _buildRankedAyahCandidateList(
          _mergeAyahSearchRows(mergedRows, fuzzyRows),
          query,
        );
      }
    }
    final totalCount = rankedCandidates.length;
    final preciseCandidates = rankedCandidates
        .where((candidate) => candidate.isPreciseMatch)
        .toList(growable: false);
    final visiblePool =
        preciseCandidates.isNotEmpty ? preciseCandidates : rankedCandidates;
    final candidates = visiblePool.take(5).toList(growable: false);
    final overflowCount = math.max(0, visiblePool.length - candidates.length);

    setState(() {
      _voiceCandidates = candidates;
      _candidateOverflowCount = overflowCount;
      if (_autoLocking) {
        _statusText = 'نفتح الصفحة الآن...';
      } else if (totalCount == 0) {
        _statusText = 'لا يوجد تطابق مرتب كافٍ بعد، أكمل القراءة';
      } else if (preciseCandidates.length == 1) {
        _statusText = 'تم العثور على موضع مطابق 100%';
      } else if (preciseCandidates.length > 1) {
        _statusText = 'أكثر من موضع مطابق 100%، اختر يدويًا';
      } else {
        _statusText =
            'أفضل النتائج مرتبة جزئيًا (${visiblePool.length})، اختر يدويًا أو أكمل القراءة';
      }
      _error = null;
    });

    if (_shouldAutoLockCandidate(
      candidates,
      preciseCandidates: preciseCandidates,
    )) {
      await _lockVoiceCandidate(
        preciseCandidates.first,
        transcript: transcript,
        isFinal: true,
      );
    }
  }

  bool _shouldAutoLockCandidate(
    List<_AyahCandidate> candidates, {
    required List<_AyahCandidate> preciseCandidates,
  }) {
    if (candidates.isEmpty || _autoLocking) return false;
    // New policy: auto-open only when there is exactly one precise (100%) match.
    if (preciseCandidates.length != 1) return false;
    return candidates.first.ayahId == preciseCandidates.first.ayahId;
  }

  Future<void> _processTranscript(
    String transcript, {
    required bool isFinal,
  }) async {
    if (_currentAyah == null) return;
    final pointerBefore = _currentWordNumberAll;
    final activeSurah = _surahNumber;
    final activeAyah = _ayahNumber;
    final normalizedTranscript =
        ArabicNormalizer.normalizeForSearch(transcript).trim();
    if (normalizedTranscript.isEmpty) return;

    final slice = sliceIncrementalTranscript(
      normalizedTranscript: normalizedTranscript,
      previousBaseline: _lastNormalizedRecitationTranscript,
      rewindTokens: 4,
      maxTokens: recitationTranscriptTokenWindow(_currentWordTotalCount),
    );
    _lastNormalizedRecitationTranscript = _compactBaseline(slice.nextBaseline);
    var tokens = slice.tokens;
    if (tokens.isEmpty) return;

    final transcriptTokenWindow =
        recitationTranscriptTokenWindow(_currentWordTotalCount);
    if (tokens.length > transcriptTokenWindow) {
      tokens = tokens.sublist(0, transcriptTokenWindow);
    }

    final backtrackWindow = recitationBacktrackWindow(_currentWordTotalCount);
    final forwardWindow =
        recitationForwardLookaheadWindow(_currentWordTotalCount, tokens.length);
    var from = math
        .max(
          1,
          math.min(_currentWordNumberAll - backtrackWindow,
              _allowedBacktrackFloorWordNumberAll),
        )
        .toInt();
    var to = (_currentWordNumberAll + forwardWindow).toInt();
    final ayahFirst = (_currentAyah!['first_word_number_all'] as int?) ?? 0;
    final ayahLast = (_currentAyah!['last_word_number_all'] as int?) ?? 0;
    if (ayahFirst > 0 && ayahLast >= ayahFirst) {
      from = math.max(from, ayahFirst);
      to = math.min(to, ayahLast);
    }
    if (from > to) {
      from = ayahFirst;
      to = ayahLast;
    }
    final window = await _db.getWordWindow(
      fromWordNumberAll: from,
      toWordNumberAll: to,
    );
    if (window.isEmpty) return;
    if (!mounted ||
        _currentAyah == null ||
        _surahNumber != activeSurah ||
        _ayahNumber != activeAyah) {
      return;
    }

    final refById = _referenceTextByWordIdForCurrentAyah();
    final match = RecitationMatchEngine.match(
      RecitationMatchInput(
        pointerBefore: pointerBefore,
        currentWordNumberAll: _currentWordNumberAll,
        allowedBacktrackFloorWordNumberAll: _allowedBacktrackFloorWordNumberAll,
        ayahWordCount: _currentWordTotalCount,
        ayahFirstWordNumberAll: ayahFirst,
        ayahLastWordNumberAll: ayahLast,
        recitationSessionStartWord: _recitationSessionStartWord,
        revealedWordTones: _revealedWordTones,
        orderedSpokenWordIdsInAyah: _orderedSpokenWordIdsInAyah,
        tokens: tokens,
        window: window,
        referenceTextByWordId: refById,
        isFinal: isFinal,
      ),
    );
    if (match == null) return;
    if (!mounted ||
        _currentAyah == null ||
        _surahNumber != activeSurah ||
        _ayahNumber != activeAyah) {
      return;
    }

    if (mounted) {
      setState(() {
        _currentWordNumberAll = match.nextWordPointer;
        _adaptToneHistoryWindow(
          pointerBefore: pointerBefore,
          pointerAfter: match.nextWordPointer,
        );
        _revealedWordTones = match.revealedWordTones;
        _compactRecitationStateInLongSession();
        if (isFinal && match.advanceDecision.hasBlockingStreak) {
          _statusText = 'توقف التقدم مؤقتًا: 3 كلمات متتالية غير صحيحة';
        } else if (_isListening) {
          _statusText = 'يستمع الآن...';
        }
      });
    }

    if (_surahNumber != activeSurah || _ayahNumber != activeAyah) {
      return;
    }

    await _persistRecitationSnapshot(match: match, isFinal: isFinal);

    if (match.advanceDecision.shouldAdvance) {
      final currentAyahKey = '$_surahNumber:$_ayahNumber';
      if (_lastMarkedReviewAyahKey != currentAyahKey) {
        await _db.updateAyahProgress(
          surahNumber: _surahNumber,
          ayahNumber: _ayahNumber,
          status: 'review',
          bestMatchScore: match.bestMatchScore,
          lastReviewedAt: DateTime.now(),
        );
        _lastMarkedReviewAyahKey = currentAyahKey;
      }
    }

    if (_surahNumber != activeSurah || _ayahNumber != activeAyah) {
      return;
    }

    await _syncAyahContextWithPointer();
  }

  Future<void> _syncAyahContextWithPointer() async {
    if (_currentAyah == null) return;
    final pointer = _currentWordNumberAll;
    final currentStart =
        (_currentAyah?['first_word_number_all'] as int?) ?? pointer;
    final currentEnd =
        (_currentAyah?['last_word_number_all'] as int?) ?? pointer;

    if (pointer > currentEnd) {
      var cursorAyah = await _db.getNextAyah(_surahNumber, _ayahNumber);
      while (cursorAyah != null) {
        final nextStart = (cursorAyah['first_word_number_all'] as int?) ?? 0;
        final nextEnd = (cursorAyah['last_word_number_all'] as int?) ?? 0;
        if (nextStart <= 0 || nextEnd < nextStart) break;
        if (pointer <= nextEnd) {
          await _loadAyah(
            (cursorAyah['surah_number'] as int?) ?? _surahNumber,
            (cursorAyah['ayah_number'] as int?) ?? _ayahNumber,
            resetProgress: false,
            preservePointer: true,
            // Crossing to another ayah with a stale baseline can hide most of
            // the new ayah until the user re-reads prior words.
            resetTranscriptBaseline: true,
          );
          break;
        }
        cursorAyah = await _db.getNextAyah(
          (cursorAyah['surah_number'] as int?) ?? _surahNumber,
          (cursorAyah['ayah_number'] as int?) ?? _ayahNumber,
        );
      }
      return;
    }

    if (pointer < currentStart) {
      var cursorAyah = await _db.getPreviousAyah(_surahNumber, _ayahNumber);
      while (cursorAyah != null) {
        final prevStart = (cursorAyah['first_word_number_all'] as int?) ?? 0;
        final prevEnd = (cursorAyah['last_word_number_all'] as int?) ?? 0;
        if (prevStart <= 0 || prevEnd < prevStart) break;
        if (pointer >= prevStart) {
          await _loadAyah(
            (cursorAyah['surah_number'] as int?) ?? _surahNumber,
            (cursorAyah['ayah_number'] as int?) ?? _ayahNumber,
            resetProgress: false,
            preservePointer: true,
            // Keep incremental slicing local to the newly loaded ayah context.
            resetTranscriptBaseline: true,
          );
          break;
        }
        cursorAyah = await _db.getPreviousAyah(
          (cursorAyah['surah_number'] as int?) ?? _surahNumber,
          (cursorAyah['ayah_number'] as int?) ?? _ayahNumber,
        );
      }
    }
  }

  Future<void> _lockVoiceCandidate(
    _AyahCandidate candidate, {
    required String transcript,
    required bool isFinal,
  }) async {
    if (_autoLocking) return;
    _autoLocking = true;
    setState(() {
      _statusText = 'نفتح الصفحة الآن...';
      _resumePeerPageColors = const {};
      _revealedWordTones = <int, RecitationWordTone>{};
      _lastNormalizedRecitationTranscript = '';
      _lastMarkedReviewAyahKey = '';
      _error = null;
    });

    await _loadAyah(
      candidate.surahNumber,
      candidate.ayahNumber,
      resetProgress: true,
    );
    if (!mounted || _currentAyah == null || _error != null) {
      _autoLocking = false;
      return;
    }

    setState(() {
      _stage = _RecitationStage.recitingMushaf;
      _voiceCandidates = const [];
      _candidateOverflowCount = 0;
      _statusText = _isListening ? 'يستمع الآن...' : 'جاهز للبدء';
      _transcript = '';
      _error = null;
      _recitationSessionStartWord = _currentWordNumberAll;
      _dynamicToneHistoryKeepBehindWords = _kToneHistoryKeepBehindWords;
    });

    _activeRecitationSessionId = await _db.startRecitationSession(
      startSurah: _surahNumber,
      startAyah: _ayahNumber,
      lastWordNumberAll: _currentWordNumberAll,
    );

    if (transcript.trim().isNotEmpty) {
      await _processTranscript(transcript, isFinal: isFinal);
    }
    unawaited(_refreshResumePeerPageColors());
    _autoLocking = false;
  }

  double _estimateVoiceLevel(String text, double? confidence) {
    final normalized = confidence?.clamp(0.0, 1.0) ?? 0.0;
    final density = text.length.clamp(1, 18) / 18;
    return (0.24 + (normalized * 0.46) + (density * 0.30)).clamp(0.14, 1.0);
  }

  void _setVoiceIdleFloor({bool active = true}) {
    final floor = active ? 0.14 : 0.05;
    _voiceDecayTimer?.cancel();
    if (!mounted) return;
    setState(() {
      _voiceLevel = floor;
    });
  }

  void _bumpVoiceLevel(double nextLevel) {
    final clamped = nextLevel.clamp(0.0, 1.0);
    _voiceDecayTimer?.cancel();
    if (mounted) {
      setState(() {
        _voiceLevel = math.max(_voiceLevel, clamped);
      });
    }
    _voiceDecayTimer =
        Timer.periodic(const Duration(milliseconds: 110), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      final floor = _isListening ? 0.14 : 0.05;
      final next = (_voiceLevel - 0.08).clamp(floor, 1.0);
      setState(() {
        _voiceLevel = next;
      });
      if ((next - floor).abs() < 0.01) {
        timer.cancel();
      }
    });
  }

  /// موضع افتراضي للعجلات: آخر قراءة محفوظة، وإلا الفاتحة (لا نربطها بأول آية
  /// صفحة المصحف — تلك قيم [widget.initial*] وتفسّر ظهور سورة/آية «غريبة»).
  Future<({int surah, int ayah})> _defaultSurahAyahForManualPicker() async {
    try {
      await _db.init();
      final st = await _db.getRecitationState();
      final ls = (st?['last_surah'] as int?) ?? 0;
      final la = (st?['last_ayah'] as int?) ?? 0;
      if (ls >= 1 && ls <= 114 && la >= 1) {
        final row = await _db.getAyah(ls, la);
        if (row != null) return (surah: ls, ayah: la);
      }
    } catch (_) {}
    return (surah: 1, ayah: 1);
  }

  Future<void> _openManualSurahAyahPicker() async {
    if (!mounted || _autoLocking || _resumeLastPositionInFlight) return;
    final def = await _defaultSurahAyahForManualPicker();
    if (!mounted) return;
    final picked = await showRecitationManualStartSheet(
      context,
      db: _db,
      initialSurahNumber: def.surah,
      initialAyahNumber: def.ayah,
    );
    if (!mounted || picked == null) return;
    final ayahMeta = await _db.getAyah(picked.surahNumber, picked.ayahNumber);
    if (!mounted) return;
    if (ayahMeta == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('تعذر تحميل الآية المختارة.')),
      );
      return;
    }
    final candidate = _candidateFromAyahDbRow(ayahMeta);
    await _lockVoiceCandidate(candidate, transcript: '', isFinal: true);
  }

  /// من لوحة «التضليلات المحفوظة» داخل التسميع: الانتقال لأول آية في النطاق المحفوظ.
  Future<void> _jumpRecitationToSavedHighlightStart(
    AyahRangeHighlight highlight,
  ) async {
    if (!mounted || _autoLocking || _resumeLastPositionInFlight) return;
    final ayahMeta = await _db.getAyah(highlight.sura, highlight.fromAyah);
    if (!mounted) return;
    if (ayahMeta == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('تعذر تحميل الآية المختارة.')),
      );
      return;
    }
    final candidate = _candidateFromAyahDbRow(ayahMeta);
    await _lockVoiceCandidate(candidate, transcript: '', isFinal: true);
  }

  Future<void> _showPositionDetection() async {
    if (!mounted) return;
    _transcriptWorkVersion += 1;
    final sid = _activeRecitationSessionId;
    _activeRecitationSessionId = null;
    if (sid != null) {
      await _db.endRecitationSession(sid);
    }
    setState(() {
      _resumePeerPageColors = const {};
      _stage = _RecitationStage.detectingPosition;
      _voiceCandidates = const [];
      _candidateOverflowCount = 0;
      _transcript = '';
      _currentAyah = null;
      _currentAyahWords = const [];
      _recitationSessionStartWord = null;
      _revealedWordTones = <int, RecitationWordTone>{};
      _lastNormalizedRecitationTranscript = '';
      _lastMarkedReviewAyahKey = '';
      _statusText = _isListening
          ? 'اقرأ من الموضع الذي تريد البدء منه'
          : 'يفتح المايكروفون...';
      _error = null;
    });
    _autoLocking = false;
    _lastCandidateQuery = '';
    _candidateSearchToken += 1;
    if (!_isListening && _speechAvailable) {
      await _startListening();
    }
  }

  Color _wordRevealColor(RecitationWordTone tone) {
    return switch (tone) {
      RecitationWordTone.correct => const Color.fromARGB(255, 31, 151, 57),
      RecitationWordTone.softCorrect => const Color.fromARGB(255, 22, 149, 113),
      RecitationWordTone.acceptable => const Color(0xFFC79B19),
      RecitationWordTone.wrong => const Color(0xFFC63A2C),
    };
  }

  /// Wrong reds still in [recitationWrongRedDisplayPolicy.suppressWrongRed] stay
  /// visible at reduced opacity so [hideUnrevealedWords] never hides them (no
  /// invisible→red flicker when tones oscillate).
  static final Color _wrongRedMuted =
      const Color(0xFFC63A2C).withValues(alpha: 0.42);

  /// Default mushaf ink for words the pointer has reached but the matcher has
  /// not colored yet (otherwise [hideUnrevealedWords] paints them as paper).
  static const Color _pendingRecitationInk = Color(0xFF000000);

  Color _colorForRecitationTone(
    int wordId,
    RecitationWordTone tone,
    RecitationWrongRedDisplayPolicy? policy,
  ) {
    if (tone != RecitationWordTone.wrong) {
      return _wordRevealColor(tone);
    }
    if (policy != null && policy.suppressWrongRed.contains(wordId)) {
      return _wrongRedMuted;
    }
    return _wordRevealColor(RecitationWordTone.wrong);
  }

  String? _referenceTextForWordRow(Map<String, Object?> word) {
    for (final key in ['normalized_text', 'search_key', 'display_text']) {
      final s = (word[key] ?? '').toString().trim();
      if (s.isNotEmpty) return s;
    }
    return null;
  }

  /// First non-empty reference field per spoken word id (for [RecitationMatchEngine]).
  Map<int, String> _referenceTextByWordIdForCurrentAyah() {
    final m = <int, String>{};
    for (final w in _currentAyahWords) {
      if ((w['is_ayah_marker'] as int? ?? 0) != 0) continue;
      final id = (w['word_number_all'] as int?) ?? 0;
      if (id <= 0) continue;
      final s = _referenceTextForWordRow(w);
      if (s != null) m[id] = s;
    }
    return m;
  }

  /// Words with [word_number_all] below this id never get recitation coloring:
  /// they stay hidden like the rest of the page until the user backs the
  /// pointer up (then the floor moves with [min]).
  int get _recitationToneFloor {
    final s = _recitationSessionStartWord;
    if (s == null) return 1;
    return math.min(s, _currentWordNumberAll);
  }

  Map<int, Color> get _visibleWordColors {
    final floor = _recitationToneFloor;
    final first = _firstSpokenWordNumberAllInAyah;
    RecitationWrongRedDisplayPolicy? policy;
    if (first != null && first > 0) {
      final ordered =
          _orderedSpokenWordIdsInAyah.where((id) => id >= floor).toList();
      policy = recitationWrongRedDisplayPolicy(
        orderedWordIdsInRange: ordered,
        tones: _revealedWordTones,
        firstSpokenWordIdInAyah: first,
      );
    }

    final result = <int, Color>{};
    final pointer = _currentWordNumberAll;
    final hasAnyRevealedInAyah = _orderedSpokenWordIdsInAyah.any(
      _revealedWordTones.containsKey,
    );
    final canShowPendingBeforeTone = first != null &&
        pointer > first &&
        _revealedWordTones.containsKey(first);
    final canShowPendingWords =
        hasAnyRevealedInAyah || canShowPendingBeforeTone;
    for (final id in _orderedSpokenWordIdsInAyah) {
      if (id < floor || id > pointer) continue;
      if (!canShowPendingWords) continue;
      if (!_revealedWordTones.containsKey(id)) {
        result[id] = _pendingRecitationInk;
      }
    }
    for (final entry in _revealedWordTones.entries) {
      if (entry.key >= floor) {
        result[entry.key] =
            _colorForRecitationTone(entry.key, entry.value, policy);
      }
    }
    return result;
  }

  Map<int, Color> get _mergedRecitationWordColors {
    final current = _visibleWordColors;
    if (_resumePeerPageColors.isEmpty) return current;
    return <int, Color>{..._resumePeerPageColors, ...current};
  }

  int get _currentWordTotalCount {
    final explicit = (_currentAyah?['word_count'] as int?);
    if (explicit != null && explicit > 0) return explicit;
    return _currentAyahWords
        .where((word) => (word['is_ayah_marker'] as int? ?? 0) == 0)
        .length;
  }

  @override
  void dispose() {
    final sid = _activeRecitationSessionId;
    if (sid != null) {
      unawaited(_db.endRecitationSession(sid));
    }
    _cancelTranscriptProcessDebounce();
    _speechSub?.cancel();
    _voiceDecayTimer?.cancel();
    _listeningHealthTimer?.cancel();
    _visualizerController.dispose();
    unawaited(_speech.cancelListening());
    unawaited(AyahAudioPlayer.instance.leaveRecitationAyahSession());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(child: CircularProgressIndicator()),
      );
    }

    final showDetectionAppBar = _stage == _RecitationStage.detectingPosition;

    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        backgroundColor: _stage == _RecitationStage.detectingPosition
            ? const Color(0xFFE8F5E9)
            : kMushafPaperBackgroundFallback,
        appBar: showDetectionAppBar
            ? AppBar(
                backgroundColor: const Color(0xFFE8F5E9),
                foregroundColor: const Color(0xFF1B5E20),
                elevation: 0,
                automaticallyImplyLeading: false,
                leading: IconButton(
                  tooltip: MaterialLocalizations.of(context).backButtonTooltip,
                  onPressed: () => Navigator.maybePop(context),
                  icon: const Icon(Icons.arrow_back),
                ),
                title: const Text('التسميع الذكي'),
                actions: [
                  if (_speechAvailable && !_isListening)
                    IconButton(
                      tooltip: 'إعادة تشغيل الاستماع',
                      onPressed: _startListening,
                      icon: const Icon(Icons.mic_rounded),
                    ),
                ],
              )
            : null,
        body: Stack(
          children: [
            _stage == _RecitationStage.recitingMushaf
                ? _buildRecitationBody(context)
                : SafeArea(child: _buildPositionDetectionBody(context)),
            if (_error != null)
              Positioned(
                top: 8,
                left: 12,
                right: 12,
                child: SafeArea(
                  bottom: false,
                  child: _InlineErrorBanner(
                    message: _error!,
                    onDismiss: () {
                      setState(() {
                        _error = null;
                      });
                    },
                  ),
                ),
              ),
          ],
        ),
      ),
    );
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

  Widget _buildRecitationTopBar({
    required int pageNumber,
    required int juzNumber,
    required String surahName,
  }) {
    final normalizedJuz = juzNumber.clamp(1, 30).toInt();
    final juzName = _juzNames[normalizedJuz - 1];
    final hizb = _pageToHizb[pageNumber];
    final rightLabel = hizb == null
        ? 'الجزء $juzName'
        : 'الجزء $juzName - الحزب: ${hizb.toString()}';
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: 12,
        vertical: kQpcTopBarVerticalPadding,
      ),
      child: Row(
        children: [
          Expanded(
            child: Align(
              alignment: Alignment.centerRight,
              child: Text(
                rightLabel,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Color(0xFF1B5E20),
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  fontFamily: 'QuranUthmani',
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          const SizedBox(width: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                surahName.isEmpty ? 'سورة غير معروفة' : surahName,
                textAlign: TextAlign.left,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Color(0xFF1B5E20),
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  fontFamily: 'SurahNameV4',
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRecitationPageNumberRow(int pageNumber) {
    return Padding(
      padding: const EdgeInsets.only(bottom: kQpcPageNumberBottomGap),
      child: Transform.translate(
        offset: const Offset(0, kQpcPageNumberVerticalNudge),
        child: SizedBox(
          height: kQpcPageNumberRowHeight,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final shift = constraints.maxWidth * 0.04;
              final pad = pageNumber.isOdd
                  ? EdgeInsets.fromLTRB(16, 0, 16 + shift, 0)
                  : EdgeInsets.fromLTRB(16 + shift, 0, 16, 0);
              return Align(
                alignment: pageNumber.isOdd
                    ? Alignment.centerRight
                    : Alignment.centerLeft,
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
                              _toArabicDigits(pageNumber),
                              style: const TextStyle(
                                fontSize: 18,
                                color: Colors.black,
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

  Widget _buildPositionDetectionBody(BuildContext context) {
    final baseTheme = Theme.of(context);
    final theme = baseTheme.copyWith(
      textTheme: baseTheme.textTheme.apply(fontSizeFactor: _menuFontScale),
    );
    return Directionality(
        textDirection: TextDirection.rtl,
        child: Theme(
          data: theme,
          child: DecoratedBox(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Color(0xFFEAF7EC),
                  Color(0xFFE2F2E5),
                  Color(0xFFDCEEDF),
                ],
              ),
            ),
            child: Column(
              children: [
                Expanded(
                  flex: 8,
                  child: LayoutBuilder(
                    builder: (context, constraints) => SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(24, 10, 24, 6),
                      child: ConstrainedBox(
                        constraints:
                            BoxConstraints(minHeight: constraints.maxHeight),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.start,
                          children: [
                            AnimatedBuilder(
                              animation: _visualizerController,
                              builder: (context, _) {
                                final normalizedLevel =
                                    _voiceLevel.clamp(0.0, 1.0);
                                final intensity = _isListening
                                    ? (0.06 + normalizedLevel * 1.75)
                                    : 0.015;
                                final outerAmplitude = 0.75 + (intensity * 6.0);
                                final waveOuterRadius = 85 + outerAmplitude + 4;
                                final waveCanvasSize =
                                    (waveOuterRadius * 2).clamp(136.0, 194.0);
                                return SizedBox(
                                  width: waveCanvasSize,
                                  height: waveCanvasSize,
                                  child: Stack(
                                    alignment: Alignment.center,
                                    children: [
                                      Positioned.fill(
                                        child: CustomPaint(
                                          painter: _SineWaveRingsPainter(
                                            level: _voiceLevel,
                                            active: _isListening,
                                          ),
                                        ),
                                      ),
                                      Container(
                                        width: 104,
                                        height: 104,
                                        decoration: BoxDecoration(
                                          shape: BoxShape.circle,
                                          gradient: LinearGradient(
                                            colors: [
                                              const Color(0xFF2E7D32)
                                                  .withValues(alpha: 0.95),
                                              const Color(0xFF1B5E20)
                                                  .withValues(alpha: 0.92),
                                            ],
                                            begin: Alignment.topLeft,
                                            end: Alignment.bottomRight,
                                          ),
                                          boxShadow: [
                                            BoxShadow(
                                              color: const Color(0xFF2E7D32)
                                                  .withValues(alpha: 0.24),
                                              blurRadius: 30,
                                              spreadRadius: 4,
                                            ),
                                          ],
                                        ),
                                        child: Stack(
                                          alignment: Alignment.center,
                                          children: [
                                            AnimatedContainer(
                                              duration: const Duration(
                                                  milliseconds: 260),
                                              width: _isListening ? 78 : 68,
                                              height: _isListening ? 78 : 68,
                                              decoration: BoxDecoration(
                                                shape: BoxShape.circle,
                                                color: Colors.white.withValues(
                                                  alpha: _isListening
                                                      ? 0.16
                                                      : 0.08,
                                                ),
                                              ),
                                            ),
                                            Container(
                                              width: 61,
                                              height: 61,
                                              decoration: BoxDecoration(
                                                shape: BoxShape.circle,
                                                gradient: LinearGradient(
                                                  begin: Alignment.topLeft,
                                                  end: Alignment.bottomRight,
                                                  colors: [
                                                    Colors.white.withValues(
                                                        alpha: 0.32),
                                                    Colors.white.withValues(
                                                        alpha: 0.10),
                                                  ],
                                                ),
                                                border: Border.all(
                                                  color: Colors.white
                                                      .withValues(alpha: 0.48),
                                                  width: 1.5,
                                                ),
                                              ),
                                              child: AnimatedOpacity(
                                                duration: const Duration(
                                                    milliseconds: 220),
                                                opacity: _isListening ? 1 : 0.9,
                                                child: Container(
                                                  width: 42,
                                                  height: 42,
                                                  decoration: BoxDecoration(
                                                    shape: BoxShape.circle,
                                                    color: Colors.white
                                                        .withValues(
                                                            alpha: 0.90),
                                                    border: Border.all(
                                                      color: Colors.white
                                                          .withValues(
                                                              alpha: 0.65),
                                                      width: 1.2,
                                                    ),
                                                  ),
                                                  child: Icon(
                                                    Icons
                                                        .record_voice_over_rounded,
                                                    color:
                                                        const Color(0xFF2E7D32)
                                                            .withValues(
                                                      alpha: _isListening
                                                          ? 0.98
                                                          : 0.86,
                                                    ),
                                                    size: 28,
                                                  ),
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
                            const SizedBox(height: 14),
                            _AutoMarqueeText(
                              _isListening
                                  ? 'اقرأ من الموضع الذي تريد البدء منه'
                                  : 'نجهز جلسة الاستماع...',
                              style: theme.textTheme.titleMedium?.copyWith(
                                color: const Color(0xFF1B5E20),
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 8),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                Expanded(
                  flex: 12,
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.fromLTRB(16, 20, 16, 18),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: const BorderRadius.vertical(
                        top: Radius.circular(28),
                      ),
                      border: Border.all(color: const Color(0xFFD2E6D6)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                'المواضع الأقرب الآن',
                                style: theme.textTheme.titleMedium?.copyWith(
                                  color: const Color(0xFF1B5E20),
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                            if (_autoLocking)
                              const SizedBox(
                                width: 22,
                                height: 22,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2.2),
                              ),
                          ],
                        ),
                        const SizedBox(height: 14),
                        Expanded(
                          child: _voiceCandidates.isEmpty
                              ? Center(
                                  child: Text(
                                    'انطق افتتاح آيتك: كلمة مميّزة كافٍ (مثلاً: الم، الضحى، كهيعص، مدهامتان) أو عدة كلمات، وستظهر اقتراحات الموضع.',
                                    textAlign: TextAlign.center,
                                    style: theme.textTheme.bodyMedium?.copyWith(
                                      color: const Color(0xFF4F6B54),
                                      height: 1.7,
                                    ),
                                  ),
                                )
                              : SingleChildScrollView(
                                  child: Wrap(
                                    spacing: 10,
                                    runSpacing: 10,
                                    alignment: WrapAlignment.start,
                                    textDirection: TextDirection.rtl,
                                    children: [
                                      for (var i = 0;
                                          i < _voiceCandidates.length;
                                          i++)
                                        _CandidatePill(
                                          label: _voiceCandidates[i].label,
                                          isPrimary: i == 0,
                                          isPrecise: _voiceCandidates[i]
                                              .isPreciseMatch,
                                          onTap: _autoLocking
                                              ? null
                                              : () {
                                                  unawaited(
                                                    _lockVoiceCandidate(
                                                      _voiceCandidates[i],
                                                      transcript: _transcript,
                                                      isFinal: true,
                                                    ),
                                                  );
                                                },
                                        ),
                                      if (_candidateOverflowCount > 0)
                                        _CandidatePill(
                                          label: '+$_candidateOverflowCount',
                                          isOverflow: true,
                                        ),
                                    ],
                                  ),
                                ),
                        ),
                        Container(
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: const Color(0xFFF4F8F4),
                            borderRadius: BorderRadius.circular(18),
                            border: Border.all(color: const Color(0xFFD8E6D8)),
                          ),
                          child: Text(
                            _transcript.isEmpty
                                ? 'النص الملتقط سيظهر هنا بمجرد أن يبدأ التطبيق بفهم القراءة.'
                                : _transcript,
                            textAlign: TextAlign.center,
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: const Color(0xFF2F4F34),
                              height: 1.6,
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            Expanded(
                              child: _buildPendingDetectionActionButton(
                                icon: Icons.my_location_outlined,
                                label: 'تحديد موضع البداية',
                                onPressed: _autoLocking ||
                                        _resumeLastPositionInFlight
                                    ? null
                                    : () {
                                        unawaited(_openManualSurahAyahPicker());
                                      },
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: _buildPendingDetectionActionButton(
                                icon: Icons.play_circle_outline_rounded,
                                label: 'متابعة آخر موضع',
                                onPressed: _resumeLastPositionInFlight
                                    ? null
                                    : () {
                                        unawaited(
                                            _resumeFromLastSavedRecitationPosition());
                                      },
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        _buildPendingDetectionActionButton(
                          icon: Icons.fact_check_outlined,
                          label: 'مراجعة التسميع',
                          onPressed: () async {
                            await RecitationReviewScreen.open(
                              context,
                              initialSurahNumber: _surahNumber,
                            );
                          },
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ));
  }

  Widget _buildPendingDetectionActionButton({
    required IconData icon,
    required String label,
    required VoidCallback? onPressed,
  }) {
    return FilledButton.icon(
      onPressed: onPressed,
      style: FilledButton.styleFrom(
        backgroundColor: const Color(0xFF2E7D32),
        foregroundColor: Colors.white,
        shape: const StadiumBorder(),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        minimumSize: const Size.fromHeight(44),
      ),
      icon: Icon(icon, size: 20),
      label: Text(
        label,
        style: const TextStyle(fontWeight: FontWeight.w700),
      ),
    );
  }

  /// العودة إلى الآية السابقة في واجهة التسميع مع مسح كشف الكلمات الحالي.
  Future<void> _retreatOneAyahInRecitation() async {
    if (!mounted || _stage != _RecitationStage.recitingMushaf) return;
    final fromS = _surahNumber;
    final fromA = _ayahNumber;
    final tonesBefore = Map<int, RecitationWordTone>.from(_revealedWordTones);
    final wordsBefore = List<Map<String, Object?>>.from(_currentAyahWords);
    final orderedBefore = _orderedSpokenWordIdsFromWords(wordsBefore);
    if (orderedBefore.isNotEmpty) {
      await _syncAyahReviewStatsRow(
        surahNumber: fromS,
        ayahNumber: fromA,
        orderedSpokenWordIds: orderedBefore,
        tones: tonesBefore,
        lastScore: null,
        lastStatus: 'in_progress',
        incrementAttempts: false,
      );
    }
    final prev = await _db.getPreviousAyah(_surahNumber, _ayahNumber);
    if (prev == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('لا توجد آية قبل هذه.')),
        );
      }
      return;
    }
    final ps = (prev['surah_number'] as int?) ?? _surahNumber;
    final pa = (prev['ayah_number'] as int?) ?? _ayahNumber;
    if (!mounted) return;
    setState(() {
      _revealedWordTones = <int, RecitationWordTone>{};
      _resumePeerPageColors = const {};
      _lastNormalizedRecitationTranscript = '';
      _lastMarkedReviewAyahKey = '';
      _transcript = '';
      _statusText = _isListening ? 'يستمع الآن...' : 'جاهز للبدء';
    });
    await _loadAyah(ps, pa, resetProgress: true);
    if (!mounted || _currentAyah == null || _error != null) return;
    setState(() {
      _recitationSessionStartWord = _firstSpokenWordNumberAllInAyah;
      _dynamicToneHistoryKeepBehindWords = _kToneHistoryKeepBehindWords;
    });
    await _db.upsertRecitationState(
      sessionId: _activeRecitationSessionId,
      surahNumber: _surahNumber,
      ayahNumber: _ayahNumber,
      lastWordNumberAll: _currentWordNumberAll,
    );
    unawaited(_refreshResumePeerPageColors());
  }

  Future<void> _showRecitationQuickActions() async {
    if (!mounted) return;
    final prefs = await SharedPreferences.getInstance();
    final pal = (prefs.getBool(_kPrefsMenuDarkMode) ?? false)
        ? _RecitationMainMenuPal.dark
        : _RecitationMainMenuPal.light;
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: pal.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) {
        final highlightDisabled = ayahHighlightingDisabledWhileAudioActive();
        return Directionality(
          textDirection: TextDirection.rtl,
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(4, 10, 4, 14),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _buildMainMenuStyleQuickActionTile(
                    pal: pal,
                    icon: Icons.skip_previous_rounded,
                    iconAngle: math.pi,
                    title: 'آية للخلف',
                    subtitle:
                        'العودة للآية السابقة وإخفاء كشف الآية الحالية لتسميعها من جديد',
                    onTap: () async {
                      Navigator.of(sheetContext).pop();
                      await _retreatOneAyahInRecitation();
                    },
                  ),
                  const SizedBox(height: 6),
                  _buildMainMenuStyleQuickActionTile(
                    pal: pal,
                    icon: Icons.my_location_rounded,
                    title: 'إعادة التموضع',
                    subtitle: 'العودة لواجهة كشف الموضع',
                    onTap: () async {
                      Navigator.of(sheetContext).pop();
                      await _showPositionDetection();
                    },
                  ),
                  const SizedBox(height: 6),
                  _buildMainMenuStyleQuickActionTile(
                    pal: pal,
                    icon: Icons.fact_check_outlined,
                    title: 'مراجعة التسميع',
                    subtitle: 'عرض السور والآيات المسموعة والأخطاء المحفوظة',
                    onTap: () async {
                      Navigator.of(sheetContext).pop();
                      await RecitationReviewScreen.open(
                        context,
                        initialSurahNumber: _surahNumber,
                      );
                    },
                  ),
                  const SizedBox(height: 6),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: _QuickSheetAyahHighlightRow(
                      sheetContext: sheetContext,
                      recitationContext: context,
                      menuDarkMode: prefs.getBool(_kPrefsMenuDarkMode) ?? false,
                      highlightDisabled: highlightDisabled,
                      menuQuranStyle: _menuQuranStyleRecitation,
                      toNormalDigits: _toNormalDigits,
                      suraNameFromNo: _suraNameForLongPressMenu,
                      onEditHighlightFromPanel: (c, e) =>
                          _openAyahHighlightSheetFromRecitation(c, editing: e),
                      onRecitationFromHighlightFromPanel: (c, e) =>
                          _jumpRecitationToSavedHighlightStart(e),
                    ),
                  ),
                  const SizedBox(height: 6),
                  _buildMainMenuStyleQuickActionTile(
                    pal: pal,
                    icon: Icons.stop_circle_rounded,
                    title: 'إيقاف التسميع',
                    subtitle: 'إغلاق وضع التسميع الحالي',
                    onTap: () async {
                      Navigator.of(sheetContext).pop();
                      await _stopListening();
                      if (!mounted) return;
                      Navigator.of(context).maybePop();
                    },
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// نفس تخطيط بطاقة «التسميع الذكي» في القائمة الرئيسية ([QuranPageViewer]).
  Widget _buildMainMenuStyleQuickActionTile({
    required _RecitationMainMenuPal pal,
    required IconData icon,
    double iconAngle = 0,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
    bool enabled = true,
  }) {
    final titleColor = enabled ? pal.title : pal.subtitle;
    final accentColor = enabled ? pal.accent : pal.trailingChevron;
    final chevronColor = pal.trailingChevron;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Material(
        color: pal.cardSurface,
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        elevation: 1,
        shadowColor: Colors.black.withValues(alpha: 0.06),
        child: InkWell(
          onTap: enabled ? onTap : null,
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
                  child: iconAngle == 0
                      ? Icon(icon, color: accentColor, size: 22)
                      : Transform.rotate(
                          angle: iconAngle,
                          alignment: Alignment.center,
                          child: Icon(icon, color: accentColor, size: 22),
                        ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        title,
                        style: TextStyle(
                          fontSize: 17,
                          color: titleColor,
                          fontWeight: FontWeight.w600,
                          fontFamily: 'Uthmani',
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          color: enabled ? pal.subtitle : pal.trailingChevron,
                          fontWeight: FontWeight.normal,
                          fontFamily: 'Uthmani',
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(
                  Icons.arrow_forward_ios,
                  size: 16,
                  color: chevronColor,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _onRecitationBodyPointerDown(PointerDownEvent e) {
    _recitationBodyPointerId = e.pointer;
    _recitationBodyPointerDownUtc = DateTime.now();
  }

  void _onRecitationBodyPointerUp(PointerUpEvent e) {
    if (e.pointer != _recitationBodyPointerId) return;
    final down = _recitationBodyPointerDownUtc;
    _recitationBodyPointerId = null;
    _recitationBodyPointerDownUtc = null;
    if (down == null) return;
    if (DateTime.now().difference(down) <= _kRecitationQuickTapMaxDuration) {
      _showRecitationQuickActions();
    }
  }

  void _onRecitationBodyPointerCancel(PointerCancelEvent e) {
    if (e.pointer == _recitationBodyPointerId) {
      _recitationBodyPointerId = null;
      _recitationBodyPointerDownUtc = null;
    }
  }

  String _toNormalDigits(int value) => value.toString();

  TextStyle _menuQuranStyleRecitation({
    required double fontSize,
    required Color color,
    FontWeight fontWeight = FontWeight.w600,
  }) {
    final scaled = (fontSize * _menuFontScale).clamp(10.0, 34.0);
    return TextStyle(
      fontFamily: 'QuranUthmani',
      fontSize: scaled,
      color: color,
      fontWeight: fontWeight,
    );
  }

  String _suraNameForLongPressMenu(int sura) {
    final row = _currentAyah;
    if (row != null && (row['surah_number'] as int? ?? 0) == sura) {
      final n = (row['surah_name_ar'] ?? '').toString().trim();
      if (n.isNotEmpty) return n;
    }
    return 'سورة $sura';
  }

  bool _recitationAyahIsCurrent(int sura, int ayah) =>
      sura == _surahNumber && ayah == _ayahNumber;

  /// للتمكين من «تجاوز الأخطاء»: بدء القراءة على هذه الآية (مؤشر أو كشف كلمات).
  bool _recitationAyahHasReadingProgress() {
    final first = _firstSpokenWordNumberAllInAyah;
    if (first == null) return false;
    if (_currentWordNumberAll > first) return true;
    for (final id in _orderedSpokenWordIdsInAyah) {
      if (_revealedWordTones.containsKey(id)) return true;
    }
    return false;
  }

  int _wrongToneCountInOrderedAyah() {
    var n = 0;
    for (final id in _orderedSpokenWordIdsInAyah) {
      if (_revealedWordTones[id] == RecitationWordTone.wrong) n++;
    }
    return n;
  }

  bool _canRecitationJumpToAyahStart(int sura, int ayah) {
    if (_stage != _RecitationStage.recitingMushaf) return false;
    if (!_recitationAyahIsCurrent(sura, ayah)) return true;
    final first = _firstSpokenWordNumberAllInAyah;
    if (first == null) return false;
    if (_currentWordNumberAll > first) return true;
    return _revealedWordTones.isNotEmpty;
  }

  Future<void> _applyRecitationAyahErrorOverride(
    int sura,
    int ayah, {
    int wrongWordsFallbackFromDb = 0,
  }) async {
    if (!mounted) return;
    final isCurrent = _recitationAyahIsCurrent(sura, ayah);
    final ordered = isCurrent
        ? _orderedSpokenWordIdsInAyah
        : _orderedSpokenWordIdsFromWords(
            await _db.getDisplayWordsForAyah(sura, ayah),
          );
    if (ordered.isEmpty) return;

    final stats = await _db.getAyahStatsRow(sura, ayah);
    var wrongFromTones = 0;
    if (isCurrent) {
      for (final id in ordered) {
        if (_revealedWordTones[id] == RecitationWordTone.wrong)
          wrongFromTones++;
      }
    }
    final wrongFromStats = (stats?['wrong_words'] as int?) ?? 0;
    final wDb = math
        .max(wrongWordsFallbackFromDb, wrongFromStats)
        .clamp(0, ordered.length);
    final sessionAdjust = math.max(wrongFromTones, wDb);
    if (sessionAdjust == 0) return;

    final nextTones = <int, RecitationWordTone>{
      for (final id in ordered) id: RecitationWordTone.correct,
    };
    if (isCurrent) {
      if (!mounted || !_recitationAyahIsCurrent(sura, ayah)) return;
      setState(() {
        for (final id in ordered) {
          _revealedWordTones[id] = RecitationWordTone.correct;
        }
      });
    }

    await _syncAyahReviewStatsRow(
      surahNumber: sura,
      ayahNumber: ayah,
      orderedSpokenWordIds: ordered,
      tones: nextTones,
      lastScore: (stats?['last_score'] as num?)?.toDouble(),
      lastStatus: 'review',
      incrementAttempts: false,
    );

    final sid = _activeRecitationSessionId;
    if (sid != null) {
      await _db.updateSessionProgress(
        sessionId: sid,
        surahNumber: _surahNumber,
        ayahNumber: _ayahNumber,
        pointerWordNumberAll: _currentWordNumberAll,
        totalWordsDelta: 0,
        correctWordsDelta: sessionAdjust,
        wrongWordsDelta: -sessionAdjust,
      );
    }
    await _refreshResumePeerPageColors();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('تم تجاوز أخطاء هذه الآية واحتسابها كاملة صحيحة'),
        backgroundColor: Color(0xFF2E7D32),
      ),
    );
  }

  Future<void> _confirmAndJumpRecitationToAyahStart(int sura, int ayah) async {
    if (!mounted || _autoLocking || _resumeLastPositionInFlight) return;
    await _performRecitationJumpToAyahStart(sura, ayah);
  }

  Future<void> _performRecitationJumpToAyahStart(int sura, int ayah) async {
    if (!mounted || _autoLocking) return;
    _autoLocking = true;
    try {
      final sid = _activeRecitationSessionId;
      if (sid != null) {
        await _db.endRecitationSession(sid);
      }
      if (!mounted) return;
      setState(() {
        _activeRecitationSessionId = null;
        _revealedWordTones = <int, RecitationWordTone>{};
        _lastNormalizedRecitationTranscript = '';
        _lastMarkedReviewAyahKey = '';
        _resumePeerPageColors = const {};
        _transcript = '';
      });

      await _loadAyah(sura, ayah, resetProgress: true);
      if (!mounted || _currentAyah == null || _error != null) return;

      final newSid = await _db.startRecitationSession(
        startSurah: sura,
        startAyah: ayah,
        lastWordNumberAll: _currentWordNumberAll,
      );
      await _db.upsertRecitationState(
        sessionId: newSid,
        surahNumber: sura,
        ayahNumber: ayah,
        lastWordNumberAll: _currentWordNumberAll,
      );

      if (!mounted) return;
      setState(() {
        _activeRecitationSessionId = newSid;
        // Jump flow should keep previously-completed ayahs visible on page;
        // only "following" progress is reset/rebuilt from the new position.
        _recitationSessionStartWord = null;
        _dynamicToneHistoryKeepBehindWords = _kToneHistoryKeepBehindWords;
      });

      await _refreshResumePeerPageColors();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'تم التموضع من سورة $sura آية $ayah',
            style: _menuQuranStyleRecitation(fontSize: 14, color: Colors.white),
          ),
          backgroundColor: const Color(0xFF2E7D32),
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _autoLocking = false);
      } else {
        _autoLocking = false;
      }
    }
  }

  void _onAyahLongPressInRecitation(
    BuildContext menuContext,
    int sura,
    int ayah,
    String ayahText,
    VoidCallback onClearSelection,
  ) {
    unawaited(_openRecitationAyahLongPressMenu(
      menuContext,
      sura: sura,
      ayah: ayah,
      ayahText: ayahText,
      onClearSelection: onClearSelection,
    ));
  }

  Future<void> _openAyahHighlightSheetFromRecitation(
    BuildContext menuContext, {
    int? sura,
    int? ayah,
    AyahRangeHighlight? editing,
  }) async {
    assert(
      editing != null || (sura != null && ayah != null),
      'تحرير أو تمرير سورة وآية',
    );
    final prefs = await SharedPreferences.getInstance();
    final menuDarkMode = prefs.getBool(_kPrefsMenuDarkMode) ?? false;
    final catalog = await loadSuraCatalogFromHafsJson();
    if (!menuContext.mounted) return;
    final initSura = editing?.sura ?? sura!;
    final initFrom = editing?.fromAyah ?? ayah!;
    final initTo = editing?.toAyah ?? ayah!;
    await showAyahHighlightRangeSheet(
      menuContext,
      initialSura: initSura,
      initialFromAyah: initFrom,
      initialToAyah: initTo,
      editing: editing,
      suraList: catalog.suraList,
      suraAyahCount: catalog.suraAyahCount,
      menuDarkMode: menuDarkMode,
      arabicUiFontFamily: 'QuranUthmani',
      menuQuranStyle: _menuQuranStyleRecitation,
      toNormalDigits: _toNormalDigits,
    );
  }

  Future<void> _openRecitationAyahLongPressMenu(
    BuildContext menuContext, {
    required int sura,
    required int ayah,
    required String ayahText,
    required VoidCallback onClearSelection,
  }) async {
    final isCurrentAyah = _recitationAyahIsCurrent(sura, ayah);
    final hasCurrentProgress =
        isCurrentAyah && _recitationAyahHasReadingProgress();
    final row = await _db.getAyahStatsRow(sura, ayah);
    var wrongDb = 0;
    if (row != null && (hasCurrentProgress || !isCurrentAyah)) {
      wrongDb = (row['wrong_words'] as int?) ?? 0;
    }
    if (!menuContext.mounted) return;

    final hasDbReadData = ((row?['total_words'] as int?) ?? 0) > 0 ||
        ((row?['total_attempts'] as int?) ?? 0) > 0;
    final canOverride = isCurrentAyah
        ? (hasCurrentProgress &&
            (_wrongToneCountInOrderedAyah() > 0 || wrongDb > 0))
        : (hasDbReadData && wrongDb > 0);
    final canJump = _canRecitationJumpToAyahStart(sura, ayah);

    await showAyahLongPressMenuDialog(
      parentContext: menuContext,
      sura: sura,
      ayah: ayah,
      ayahText: ayahText,
      onClearSelection: onClearSelection,
      suraName: _suraNameForLongPressMenu(sura),
      arabicUiFontFamily: 'QuranUthmani',
      menuQuranStyle: _menuQuranStyleRecitation,
      toNormalDigits: _toNormalDigits,
      rotateMenuForLandscape: false,
      isHighlightingDisabledByAudio: ayahHighlightingDisabledWhileAudioActive(),
      onTafseer: null,
      onHighlight: () {
        unawaited(_openAyahHighlightSheetFromRecitation(
          menuContext,
          sura: sura,
          ayah: ayah,
        ));
      },
      onRecitationOverrideAyahErrors: () => unawaited(
        _applyRecitationAyahErrorOverride(
          sura,
          ayah,
          wrongWordsFallbackFromDb: wrongDb,
        ),
      ),
      recitationOverrideAyahErrorsEnabled: canOverride,
      onRecitationJumpToAyahStart: () =>
          unawaited(_confirmAndJumpRecitationToAyahStart(sura, ayah)),
      recitationJumpToAyahStartEnabled: canJump,
    );
  }

  Widget _buildRecitationBody(BuildContext context) {
    if (_currentAyah == null) {
      return const Center(child: CircularProgressIndicator());
    }

    final currentAyah = _currentAyah!;
    final pageNumber = (currentAyah['page_number'] as int?) ?? 1;
    final juzNumber = (currentAyah['juz_number'] as int?) ?? 1;
    final surahName = (currentAyah['surah_name_ar'] ?? '').toString();

    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: _onRecitationBodyPointerDown,
      onPointerUp: _onRecitationBodyPointerUp,
      onPointerCancel: _onRecitationBodyPointerCancel,
      child: AyahLongPressScope(
        onAyahLongPress: _onAyahLongPressInRecitation,
        child: ColoredBox(
          color: kMushafPaperBackgroundFallback,
          child: Directionality(
            textDirection: TextDirection.rtl,
            child: Padding(
              padding: EdgeInsets.only(
                top: MediaQuery.viewPaddingOf(context).top,
                bottom: MediaQuery.viewPaddingOf(context).bottom,
              ),
              child: Column(
                children: [
                  _buildRecitationTopBar(
                    pageNumber: pageNumber,
                    juzNumber: juzNumber,
                    surahName: surahName,
                  ),
                  Expanded(
                    child: MushafPaperBackgroundScope(
                      color: kMushafPaperBackgroundFallback,
                      child: MushafStableViewport(
                        child: QpcV4BlackPageView(
                          page: pageNumber,
                          hideUnrevealedWords: true,
                          recitationWordColors: _mergedRecitationWordColors,
                          usePreciseRecitationOverlay: true,
                        ),
                      ),
                    ),
                  ),
                  _buildRecitationPageNumberRow(pageNumber),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// صف «التضليل» (إظهار/إخفاء + فتح التضليلات المحفوظة) كما في القائمة الرئيسية.
class _QuickSheetAyahHighlightRow extends StatefulWidget {
  const _QuickSheetAyahHighlightRow({
    required this.sheetContext,
    required this.recitationContext,
    required this.menuDarkMode,
    required this.highlightDisabled,
    required this.menuQuranStyle,
    required this.toNormalDigits,
    required this.suraNameFromNo,
    required this.onEditHighlightFromPanel,
    required this.onRecitationFromHighlightFromPanel,
  });

  final BuildContext sheetContext;
  final BuildContext recitationContext;
  final bool menuDarkMode;
  final bool highlightDisabled;
  final TextStyle Function({
    required double fontSize,
    required Color color,
    FontWeight fontWeight,
  }) menuQuranStyle;
  final String Function(int) toNormalDigits;
  final String Function(int) suraNameFromNo;
  final Future<void> Function(
    BuildContext context,
    AyahRangeHighlight editing,
  ) onEditHighlightFromPanel;
  final Future<void> Function(
    BuildContext context,
    AyahRangeHighlight highlight,
  ) onRecitationFromHighlightFromPanel;

  @override
  State<_QuickSheetAyahHighlightRow> createState() =>
      _QuickSheetAyahHighlightRowState();
}

class _QuickSheetAyahHighlightRowState
    extends State<_QuickSheetAyahHighlightRow> {
  bool? _visible;

  @override
  void initState() {
    super.initState();
    readAyahHighlightsVisible().then((v) {
      if (mounted) setState(() => _visible = v);
    });
  }

  @override
  Widget build(BuildContext context) {
    final pal = widget.menuDarkMode
        ? QuranMenuPaletteData.dark
        : QuranMenuPaletteData.light;
    if (_visible == null) {
      return SizedBox(
        height: 56,
        child: Center(
          child: SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: pal.accent,
            ),
          ),
        ),
      );
    }
    final vis = _visible!;
    return QuranMenuPalette(
      data: pal,
      child: AyahHighlightsMainMenuRow(
        menuPalette: pal,
        menuQuranStyle: widget.menuQuranStyle,
        visible: vis,
        enabled: !widget.highlightDisabled,
        onShowIndex: () async {
          Navigator.of(widget.sheetContext).pop();
          if (!widget.recitationContext.mounted) return;
          if (ayahHighlightingDisabledWhileAudioActive()) {
            ScaffoldMessenger.of(widget.recitationContext).showSnackBar(
              SnackBar(
                content: Text(
                  'التضليل متوقف أثناء الاستماع',
                  style: widget.menuQuranStyle(
                    fontSize: 14,
                    color: Colors.white,
                  ),
                ),
                backgroundColor: const Color(0xFF2E7D32),
              ),
            );
            return;
          }
          await showAyahHighlightsIndexPanel(
            widget.recitationContext,
            menuDarkMode: widget.menuDarkMode,
            horizontallyRotatedReading: false,
            menuQuranStyle: widget.menuQuranStyle,
            toNormalDigits: widget.toNormalDigits,
            suraNameFromNo: widget.suraNameFromNo,
            onDismissAllMenus: (dctx) =>
                Navigator.of(dctx).popUntil((route) => route.isFirst),
            onJumpToMushafPage: null,
            onEditHighlight: widget.onEditHighlightFromPanel,
            onRecitationFromHighlight:
                widget.onRecitationFromHighlightFromPanel,
            onHighlightsListMutated: null,
          );
        },
        onToggleVisibility: () async {
          final current = _visible!;
          final nv = !current;
          setState(() => _visible = nv);
          await writeAyahHighlightsVisible(nv);
          await syncAyahHighlightStoreFromPrefs();
        },
      ),
    );
  }
}

/// ألوان مطابقة لـ [_QuranMenuPaletteData] في `quran_page_viewer` (فاتح / داكن).
class _RecitationMainMenuPal {
  const _RecitationMainMenuPal({
    required this.surface,
    required this.cardSurface,
    required this.title,
    required this.subtitle,
    required this.accent,
    required this.trailingChevron,
  });

  final Color surface;
  final Color cardSurface;
  final Color title;
  final Color subtitle;
  final Color accent;
  final Color trailingChevron;

  static const _RecitationMainMenuPal light = _RecitationMainMenuPal(
    surface: Color(0xFFE8F5E9),
    cardSurface: Colors.white,
    title: Color(0xFF1B5E20),
    subtitle: Color(0xFF616161),
    accent: Color(0xFF2E7D32),
    trailingChevron: Color(0xFF9E9E9E),
  );

  static const _RecitationMainMenuPal dark = _RecitationMainMenuPal(
    surface: Color(0xFF051813),
    cardSurface: Color(0x14FFFFFF),
    title: Colors.white,
    subtitle: Color.fromARGB(255, 184, 201, 192),
    accent: Color(0xFF81C784),
    trailingChevron: Colors.white54,
  );
}

class _AyahCandidate {
  const _AyahCandidate({
    required this.ayahId,
    required this.surahNumber,
    required this.ayahNumber,
    required this.surahName,
    required this.rank,
    this.searchText = '',
    this.heuristicScore = 0,
    this.exactCoverage = 0,
    this.orderedCoverage = 0,
    this.matchedTokens = 0,
    this.spokenTokenCount = 0,
    this.passesOrderedThreshold = false,
    this.isPreciseMatch = false,
    this.leadingConsecutiveAtAyahStart = 0,
    this.pageNumber,
  });

  final int ayahId;
  final int surahNumber;
  final int ayahNumber;
  final String surahName;
  final double rank;
  final String searchText;
  final double heuristicScore;
  final double exactCoverage;
  final double orderedCoverage;
  final int matchedTokens;
  final int spokenTokenCount;
  final bool passesOrderedThreshold;
  final bool isPreciseMatch;

  /// How many of the *first* spoken tokens match the *first* words of this
  /// ayah in order. Used to prefer the surah/ayah the user *started* with when
  /// they read more than one ayah in one clip.
  final int leadingConsecutiveAtAyahStart;
  final int? pageNumber;

  String get label => '$surahName - $ayahNumber';
  String get matchSummary =>
      spokenTokenCount == 0 ? '0/0' : '$matchedTokens/$spokenTokenCount';

  factory _AyahCandidate.fromMap(Map<String, Object?> map) {
    return _AyahCandidate(
      ayahId: (map['ayah_id'] as int?) ?? 0,
      surahNumber: (map['surah_number'] as int?) ?? 0,
      ayahNumber: (map['ayah_number'] as int?) ?? 0,
      surahName: (map['surah_name_ar'] ?? '').toString(),
      rank: switch (map['rank']) {
        final double value => value,
        final int value => value.toDouble(),
        final String value => double.tryParse(value) ?? 0,
        _ => 0,
      },
      searchText: (map['search_text'] ?? '').toString(),
      pageNumber: (map['page_number'] as int?),
    );
  }

  _AyahCandidate withHeuristicScore(String query) {
    final queryTokens = ArabicNormalizer.normalizeForSearch(query)
        .split(' ')
        .map((token) => token.trim())
        .where((token) => token.isNotEmpty)
        .toList(growable: false);
    final targetTokens = ArabicNormalizer.normalizeForSearch(searchText)
        .split(' ')
        .map((token) => token.trim())
        .where((token) => token.isNotEmpty)
        .toList(growable: false);

    if (queryTokens.isEmpty || targetTokens.isEmpty) {
      return copyWith(
        heuristicScore: 0,
        exactCoverage: 0,
        isPreciseMatch: false,
        leadingConsecutiveAtAyahStart: 0,
      );
    }

    var leadingConsecutive = 0;
    for (var i = 0; i < queryTokens.length && i < targetTokens.length; i++) {
      if (queryTokens[i] == targetTokens[i]) {
        leadingConsecutive++;
        continue;
      }
      if (_nearCandidateToken(targetTokens[i], queryTokens[i])) {
        leadingConsecutive++;
        continue;
      }
      break;
    }

    var lastIndex = -1;
    var exactHits = 0;
    var nearHits = 0;
    for (final token in queryTokens) {
      int? foundIndex;
      var matchedNear = false;
      for (var i = lastIndex + 1; i < targetTokens.length; i++) {
        if (targetTokens[i] == token) {
          foundIndex = i;
          break;
        }
      }
      if (foundIndex == null) {
        for (var i = lastIndex + 1; i < targetTokens.length; i++) {
          if (_nearCandidateToken(targetTokens[i], token)) {
            foundIndex = i;
            matchedNear = true;
            break;
          }
        }
      }
      if (foundIndex == null) continue;
      if (matchedNear) {
        nearHits += 1;
      } else {
        exactHits += 1;
      }
      lastIndex = foundIndex;
    }

    final matchedTokens = exactHits + nearHits;
    final coverage =
        queryTokens.isEmpty ? 0 : matchedTokens / queryTokens.length;
    final exactCoverage =
        queryTokens.isEmpty ? 0.0 : exactHits / queryTokens.length;
    final minOrderedMatches = _minimumOrderedMatches(queryTokens.length);
    // Entire target ayah (all of its words) matches the *start* of the query,
    // then the user kept reading: global coverage of the long clip is low but
    // this ayah is a valid “first position” (e.g. الضحى 1 + next surah).
    final fullAyahReadAtStart =
        targetTokens.isNotEmpty && leadingConsecutive >= targetTokens.length;
    final passesOrderedThreshold =
        (matchedTokens >= minOrderedMatches && coverage >= 0.60) ||
            fullAyahReadAtStart;
    final prefixBoost = targetTokens.take(queryTokens.length).toList();
    var orderHits = 0;
    for (var i = 0; i < math.min(prefixBoost.length, queryTokens.length); i++) {
      if (prefixBoost[i] == queryTokens[i]) {
        orderHits += 1;
      }
    }
    final orderScore = queryTokens.isEmpty ? 0 : orderHits / queryTokens.length;
    final finalScore = (coverage * 0.72) + (orderScore * 0.28);
    final exactContiguous = _containsExactContiguousSequence(
      targetTokens: targetTokens,
      queryTokens: queryTokens,
    );
    final isPreciseMatch = exactCoverage == 1.0 &&
        exactContiguous &&
        nearHits == 0 &&
        matchedTokens == queryTokens.length;
    return copyWith(
      heuristicScore: finalScore.clamp(0.0, 1.0),
      exactCoverage: exactCoverage.clamp(0.0, 1.0),
      orderedCoverage: coverage.clamp(0.0, 1.0).toDouble(),
      matchedTokens: matchedTokens,
      spokenTokenCount: queryTokens.length,
      passesOrderedThreshold: passesOrderedThreshold,
      isPreciseMatch: isPreciseMatch,
      leadingConsecutiveAtAyahStart: leadingConsecutive,
    );
  }

  _AyahCandidate copyWith({
    double? heuristicScore,
    double? exactCoverage,
    double? orderedCoverage,
    int? matchedTokens,
    int? spokenTokenCount,
    bool? passesOrderedThreshold,
    bool? isPreciseMatch,
    int? leadingConsecutiveAtAyahStart,
  }) {
    return _AyahCandidate(
      ayahId: ayahId,
      surahNumber: surahNumber,
      ayahNumber: ayahNumber,
      surahName: surahName,
      rank: rank,
      searchText: searchText,
      heuristicScore: heuristicScore ?? this.heuristicScore,
      exactCoverage: exactCoverage ?? this.exactCoverage,
      orderedCoverage: orderedCoverage ?? this.orderedCoverage,
      matchedTokens: matchedTokens ?? this.matchedTokens,
      spokenTokenCount: spokenTokenCount ?? this.spokenTokenCount,
      passesOrderedThreshold:
          passesOrderedThreshold ?? this.passesOrderedThreshold,
      isPreciseMatch: isPreciseMatch ?? this.isPreciseMatch,
      leadingConsecutiveAtAyahStart:
          leadingConsecutiveAtAyahStart ?? this.leadingConsecutiveAtAyahStart,
      pageNumber: pageNumber,
    );
  }
}

class _InlineErrorBanner extends StatelessWidget {
  const _InlineErrorBanner({
    required this.message,
    required this.onDismiss,
  });

  final String message;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: const Color(0xFF3F1313).withValues(alpha: 0.96),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: const Color(0xFF913737)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.only(top: 2),
              child: Icon(Icons.error_outline, color: Colors.white),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                message,
                style: const TextStyle(
                  color: Colors.white,
                  height: 1.5,
                ),
              ),
            ),
            IconButton(
              onPressed: onDismiss,
              icon: const Icon(Icons.close, color: Colors.white),
              visualDensity: VisualDensity.compact,
            ),
          ],
        ),
      ),
    );
  }
}

class _CandidatePill extends StatelessWidget {
  const _CandidatePill({
    required this.label,
    this.isPrimary = false,
    this.isOverflow = false,
    this.isPrecise = false,
    this.onTap,
  });

  final String label;
  final bool isPrimary;
  final bool isOverflow;
  final bool isPrecise;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final background = isOverflow
        ? const Color(0xFFE8ECE8)
        : isPrimary
            ? const Color(0xFFDDEFE1)
            : const Color(0xFFF3F8F3);
    final border = isOverflow
        ? const Color(0xFFC7D1C9)
        : isPrimary
            ? const Color(0xFF8BC39A)
            : const Color(0xFFD0E0D3);
    final badgeText = isPrecise && !isOverflow ? '100%' : null;
    final pill = AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: TextStyle(
              color: const Color(0xFF1B5E20),
              fontWeight: isPrimary ? FontWeight.w700 : FontWeight.w600,
            ),
          ),
          if (badgeText != null) ...[
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: const Color(0xFF2E7D32),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                badgeText,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ],
      ),
    );
    if (onTap == null || isOverflow) return pill;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: pill,
      ),
    );
  }
}

class _SineWaveRingsPainter extends CustomPainter {
  _SineWaveRingsPainter({
    required this.level,
    required this.active,
  });

  final double level;
  final bool active;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final normalizedLevel = level.clamp(0.0, 1.0);
    // Keep rings almost flat in silence, and boost strongly while speaking.
    final intensity = active ? (0.06 + normalizedLevel * 1.75) : 0.015;

    // Dense neon wave rings around the avatar.
    _drawNeonWaveRing(
      canvas,
      center: center,
      baseRadius: 73,
      amplitude: 0.35 + (intensity * 4.7),
      frequency: 18,
      color: const Color.fromARGB(255, 185, 225, 153),
      alpha: active ? 0.70 : 0.20,
      strokeWidth: 2.2,
    );
    _drawNeonWaveRing(
      canvas,
      center: center,
      baseRadius: 79,
      amplitude: 0.55 + (intensity * 5.3),
      frequency: 16,
      color: const Color.fromARGB(255, 4, 86, 10),
      alpha: active ? 0.62 : 0.18,
      strokeWidth: 2.0,
    );
    _drawNeonWaveRing(
      canvas,
      center: center,
      baseRadius: 85,
      amplitude: 0.75 + (intensity * 6.0),
      frequency: 14,
      color: const Color.fromARGB(255, 123, 218, 194),
      alpha: active ? 0.56 : 0.15,
      strokeWidth: 1.8,
    );
  }

  void _drawNeonWaveRing(
    Canvas canvas, {
    required Offset center,
    required double baseRadius,
    required Color color,
    required double amplitude,
    required int frequency,
    required double alpha,
    required double strokeWidth,
  }) {
    // Soft glow behind each wave.
    final glow = Paint()
      ..color = color.withValues(alpha: (alpha * 0.26).clamp(0.0, 1.0))
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth + 3.2
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2.2);

    final paint = Paint()
      ..color = color.withValues(alpha: alpha)
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;

    final path = Path();
    const samples = 240;
    for (var i = 0; i <= samples; i++) {
      final t = (i / samples) * math.pi * 2;
      // Keep the waveform spatially fixed; only amplitude changes with voice level.
      final wobble = math.sin(t * frequency);
      final micro = math.sin(t * (frequency ~/ 2));
      final radius =
          baseRadius + (wobble * amplitude) + (micro * amplitude * 0.35);
      final x = center.dx + math.cos(t) * radius;
      final y = center.dy + math.sin(t) * radius;
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    path.close();
    canvas.drawPath(path, glow);
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _SineWaveRingsPainter oldDelegate) {
    return level != oldDelegate.level || active != oldDelegate.active;
  }
}

class _AutoMarqueeText extends StatelessWidget {
  const _AutoMarqueeText(
    this.text, {
    this.style,
  });

  final String text;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final effectiveStyle = style ?? DefaultTextStyle.of(context).style;
        final painter = TextPainter(
          text: TextSpan(text: text, style: effectiveStyle),
          textDirection: TextDirection.rtl,
          maxLines: 1,
        )..layout(maxWidth: constraints.maxWidth);
        final isOverflowing = painter.width > constraints.maxWidth;
        if (!isOverflowing) {
          return Text(
            text,
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: effectiveStyle,
          );
        }
        return _BouncingMarqueeText(
          text: text,
          style: effectiveStyle,
          maxWidth: constraints.maxWidth,
        );
      },
    );
  }
}

class _BouncingMarqueeText extends StatefulWidget {
  const _BouncingMarqueeText({
    required this.text,
    required this.style,
    required this.maxWidth,
  });

  final String text;
  final TextStyle style;
  final double maxWidth;

  @override
  State<_BouncingMarqueeText> createState() => _BouncingMarqueeTextState();
}

class _BouncingMarqueeTextState extends State<_BouncingMarqueeText>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _progress;
  double _distance = 0;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 3400),
    );
    _progress = CurvedAnimation(parent: _controller, curve: Curves.easeInOut);
    _controller.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(covariant _BouncingMarqueeText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text ||
        oldWidget.maxWidth != widget.maxWidth) {
      _distance = 0;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final painter = TextPainter(
      text: TextSpan(text: widget.text, style: widget.style),
      textDirection: TextDirection.rtl,
      maxLines: 1,
    )..layout();
    _distance = math.max(0, painter.width - widget.maxWidth + 14);

    return ClipRect(
      child: AnimatedBuilder(
        animation: _progress,
        builder: (context, _) {
          final dx = _distance * _progress.value;
          return Transform.translate(
            offset: Offset(dx, 0),
            child: Align(
              alignment: Alignment.centerRight,
              child: Text(
                widget.text,
                maxLines: 1,
                softWrap: false,
                style: widget.style,
              ),
            ),
          );
        },
      ),
    );
  }
}

bool _containsExactContiguousSequence({
  required List<String> targetTokens,
  required List<String> queryTokens,
}) {
  if (targetTokens.isEmpty || queryTokens.isEmpty) return false;
  if (queryTokens.length > targetTokens.length) return false;
  final window = queryTokens.length;
  for (var start = 0; start <= targetTokens.length - window; start++) {
    var allMatch = true;
    for (var i = 0; i < window; i++) {
      if (targetTokens[start + i] != queryTokens[i]) {
        allMatch = false;
        break;
      }
    }
    if (allMatch) return true;
  }
  return false;
}

int _minimumOrderedMatches(int tokenCount) {
  if (tokenCount <= 2) return tokenCount;
  if (tokenCount <= 4) return tokenCount - 1;
  return (tokenCount * 0.60).ceil();
}

bool _nearCandidateToken(String expected, String spoken) {
  if (expected == spoken) return true;
  if ((expected.length - spoken.length).abs() > 1) return false;
  if (math.min(expected.length, spoken.length) < 3) return false;
  if (expected.codeUnitAt(0) != spoken.codeUnitAt(0)) return false;
  return _levenshteinDistanceLoose(expected, spoken) <= 1;
}

int _levenshteinDistanceLoose(String a, String b) {
  final n = a.length;
  final m = b.length;
  if (n == 0) return m;
  if (m == 0) return n;

  var previous = List<int>.generate(m + 1, (i) => i);
  var current = List<int>.filled(m + 1, 0);

  for (var i = 1; i <= n; i++) {
    current[0] = i;
    for (var j = 1; j <= m; j++) {
      final cost = a.codeUnitAt(i - 1) == b.codeUnitAt(j - 1) ? 0 : 1;
      current[j] = math.min(
        math.min(current[j - 1] + 1, previous[j] + 1),
        previous[j - 1] + cost,
      );
    }
    final tmp = previous;
    previous = current;
    current = tmp;
  }

  return previous[m];
}
