import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';

import 'ayah_reciters_config.dart';
import 'ayah_reciters_prefs.dart';

/// عنصر في قائمة تشغيل متتالية (للوضع المتواصل).
class _QueueAyah {
  _QueueAyah(this.sura, this.ayah, this.url, this.segments, this.startOffsetMs);
  final int sura;
  final int ayah;
  final String url;
  final List<(int, int, int)> segments;
  final int startOffsetMs;
}

/// حالة مشغل تلاوة الآية.
enum AyahPlayerState {
  idle,
  loading,
  playing,
  paused,
  completed,
  error,
}

/// خدمة لتشغيل تلاوة الآية مع دعم القراء المتعددين.
class AyahAudioPlayer extends ChangeNotifier {
  AyahAudioPlayer._() {
    _player.playerStateStream.listen(_onPlayerStateChanged);
    _player.positionStream.listen(_onPositionChanged);
  }
  static final AyahAudioPlayer instance = AyahAudioPlayer._();

  final AudioPlayer _player = AudioPlayer();
  final Map<String, Map<String, dynamic>> _reciterMaps = {};

  String _currentReciterId = 'alnufais';
  int? _currentSura;
  int? _currentAyah;
  AyahPlayerState _state = AyahPlayerState.idle;
  String? _errorMessage;
  AyahPlaybackMode _playbackMode = AyahPlaybackMode.once;
  AyahPlaybackRange? _playbackRange;
  List<(int token, int startMs, int endMs)> _segments = const [];
  int _currentSegmentIndex = -1;
  bool _prefsLoaded = false;
  List<_QueueAyah> _queueAyahs = [];
  ConcatenatingAudioSource? _queueSource;
  StreamSubscription<int?>? _queueIndexSub;
  bool _usingQueue = false;
  bool _showAyahHighlight = false;
  Timer? _queueSyncTimer;
  bool _backgroundAudioReady = false;
  Future<void>? _backgroundAudioInitFuture;

  /// جلسة تشغيل أذكار (نفس [AudioPlayer] والإشعار، يحل محل التلاوة).
  bool _azkarSession = false;

  /// صوت البسملة (سورة 1 آية 1 - النفيس) يُشغّل قبل آية 1 عند الانتقال من سورة إلى سورة جديدة في الوضع المتواصل.
  static const String _basmallahTransitionUrl =
      'https://audio-cdn.tarteel.ai/quran/alnufais/001001.mp3';
  static const int _basmallahDurationMs = 3500;

  (int, int)? _pendingNextAfterBasmallah;

  static const String _appAlbum = 'ترتيل';

  String get _reciterNameAr {
    final r =
        kAyahReciters.where((e) => e.id == _currentReciterId).firstOrNull;
    return r?.nameAr ?? _appAlbum;
  }

  MediaItem _mediaItemForAyah(int sura, int ayah) => MediaItem(
        id: '$sura:$ayah',
        album: _appAlbum,
        title: 'سورة $sura آية $ayah — $_reciterNameAr',
      );

  MediaItem get _mediaItemBasmallah => const MediaItem(
        id: 'basmallah',
        album: _appAlbum,
        title: 'بسملة',
      );

  void _clearQueueState() {
    _queueSyncTimer?.cancel();
    _queueSyncTimer = null;
    _queueIndexSub?.cancel();
    _queueIndexSub = null;
    _queueSource = null;
    _queueAyahs = [];
    _usingQueue = false;
  }

  Future<void> _ensureBackgroundAudioInitialized() async {
    if (_backgroundAudioReady) return;
    _backgroundAudioInitFuture ??= JustAudioBackground.init(
      androidNotificationChannelId: 'com.ahmed.tartil.channel.audio',
      androidNotificationChannelName: 'التلاوة والأذكار',
      androidNotificationOngoing: true,
    );
    await _backgroundAudioInitFuture;
    _backgroundAudioReady = true;
  }

  Future<void> _ensurePrefsLoaded() async {
    if (_prefsLoaded) return;
    _currentReciterId = await AyahRecitersPrefs.instance.getCurrentReciterId();
    _playbackMode = await AyahRecitersPrefs.instance.getPlaybackMode();
    _playbackRange = await AyahRecitersPrefs.instance.getPlaybackRange();
    _showAyahHighlight =
        await AyahRecitersPrefs.instance.getShowAyahHighlight();
    _prefsLoaded = true;
    notifyListeners();
  }

  String get currentReciterId => _currentReciterId;
  int? get currentSura => _currentSura;
  int? get currentAyah => _currentAyah;
  AyahPlayerState get state => _state;
  String? get errorMessage => _errorMessage;
  bool get isPlaying => _state == AyahPlayerState.playing;
  AyahPlaybackMode get playbackMode => _playbackMode;
  AyahPlaybackRange? get playbackRange => _playbackRange;
  int get currentSegmentIndex => _currentSegmentIndex;
  int? get currentSegmentToken =>
      (_currentSegmentIndex >= 0 && _currentSegmentIndex < _segments.length)
          ? _segments[_currentSegmentIndex].$1
          : null;
  bool get isActive =>
      _state == AyahPlayerState.playing ||
      _state == AyahPlayerState.paused ||
      _state == AyahPlayerState.loading;

  /// يكون true أثناء تشغيل صوت الأذكار عبر [playAzkarAudio] (نفس إشعار الوسائط).
  bool get isAzkarSession => _azkarSession;

  /// إظهار تأشير الآية كاملة أثناء التلاوة. إن false يبقى تأشير كلمة القراءة فقط.
  bool get showAyahHighlight => _showAyahHighlight;

  Future<void> setShowAyahHighlight(bool value) async {
    if (_showAyahHighlight == value) return;
    _showAyahHighlight = value;
    await AyahRecitersPrefs.instance.setShowAyahHighlight(value);
    notifyListeners();
  }

  Stream<Duration> get positionStream => _player.positionStream;
  Stream<Duration?> get durationStream => _player.durationStream;

  void _onPlayerStateChanged(PlayerState ps) async {
    final prev = _state;
    // الأذكار: لا نمرّ على منطق الآيات/المتواصل (نفس المشغّل والإشعار)
    if (_azkarSession) {
      if (ps.processingState == ProcessingState.completed) {
        _azkarSession = false;
        _state = AyahPlayerState.idle;
        if (prev != _state) notifyListeners();
        return;
      }
      if (ps.processingState == ProcessingState.loading ||
          ps.processingState == ProcessingState.buffering) {
        _state = AyahPlayerState.loading;
      } else if (ps.processingState == ProcessingState.ready) {
        _state = ps.playing ? AyahPlayerState.playing : AyahPlayerState.paused;
      } else if (ps.processingState == ProcessingState.idle) {
        _azkarSession = false;
        _state = AyahPlayerState.idle;
        if (!ps.playing) {
          _currentSura = null;
          _currentAyah = null;
        }
      } else {
        _state = AyahPlayerState.idle;
      }
      if (prev != _state) notifyListeners();
      return;
    }

    if (ps.processingState == ProcessingState.completed) {
      _state = AyahPlayerState.completed;
      if (_playbackMode == AyahPlaybackMode.once) {
        _currentSura = null;
        _currentAyah = null;
        _segments = const [];
        _currentSegmentIndex = -1;
        _state = AyahPlayerState.idle;
        notifyListeners();
        return;
      }
      if (_playbackMode == AyahPlaybackMode.repeat &&
          _currentSura != null &&
          _currentAyah != null) {
        await playAyah(_currentSura!, _currentAyah!);
        return;
      }
      if (_playbackMode == AyahPlaybackMode.continuous) {
        if (_pendingNextAfterBasmallah != null) {
          final pending = _pendingNextAfterBasmallah!;
          _pendingNextAfterBasmallah = null;
          await playAyah(pending.$1, pending.$2);
          return;
        }
        if (_usingQueue) {
          _clearQueueState();
        }
        if (_currentSura != null && _currentAyah != null) {
          final next = _nextAyahForContinuous();
          if (next != null) {
            final nextSura = next.$2;
            final nextAyah = next.$3;
            final prevSura = _currentSura!;
            final needBasmallah = nextAyah == 1 &&
                nextSura != prevSura &&
                nextSura > 1 &&
                !(prevSura == 8 && nextSura == 9);
            if (needBasmallah) {
              _pendingNextAfterBasmallah = (nextSura, nextAyah);
              try {
                await _player.setAudioSource(
                  AudioSource.uri(
                    Uri.parse(_basmallahTransitionUrl),
                    tag: _mediaItemBasmallah,
                  ),
                  preload: true,
                );
                _state = AyahPlayerState.playing;
                notifyListeners();
                await _player.play();
                return;
              } catch (_) {
                _pendingNextAfterBasmallah = null;
                await playAyah(nextSura, nextAyah);
                return;
              }
            }
            await playAyah(nextSura, nextAyah);
            return;
          }
        }
        _currentSura = null;
        _currentAyah = null;
        _segments = const [];
        _currentSegmentIndex = -1;
      }
      _state = AyahPlayerState.idle;
    } else if (ps.processingState == ProcessingState.loading ||
        ps.processingState == ProcessingState.buffering) {
      _state = AyahPlayerState.loading;
    } else if (ps.processingState == ProcessingState.ready) {
      _state = ps.playing ? AyahPlayerState.playing : AyahPlayerState.paused;
    } else if (ps.processingState == ProcessingState.idle) {
      _state = AyahPlayerState.idle;
      if (!ps.playing) {
        _currentSura = null;
        _currentAyah = null;
      }
    } else {
      _state = AyahPlayerState.idle;
    }
    if (prev != _state) notifyListeners();
  }

  bool _isBeforeOrEqual(int s1, int a1, int s2, int a2) {
    return s1 < s2 || (s1 == s2 && a1 <= a2);
  }

  bool _isWithinRange(int sura, int ayah, AyahPlaybackRange range) {
    return _isBeforeOrEqual(range.fromSura, range.fromAyah, sura, ayah) &&
        _isBeforeOrEqual(sura, ayah, range.toSura, range.toAyah);
  }

  (bool, int, int)? _nextAyahForContinuous() {
    final s = _currentSura;
    final a = _currentAyah;
    if (s == null || a == null) return null;
    final range = _playbackRange;
    // نطبّق حدود النطاق فقط عندما تكون الآية الحالية داخل النطاق.
    // إن بدأ المستخدم التشغيل من سورة خارج النطاق المحفوظ، نتابع ترتيب المصحف
    // ولا نعيد القفز إلى بداية النطاق (كان يسبب: بعد آية 1 من سورة → بسملة → البقرة 1).
    if (range != null && _isWithinRange(s, a, range)) {
      if (s == range.toSura && a == range.toAyah) return null;
      final next = getNextAyah(s, a);
      if (next == null) return null;
      if (!_isWithinRange(next.$2, next.$3, range)) return null;
      return next;
    }
    return getNextAyah(s, a);
  }

  void _onPositionChanged(Duration position) {
    if (_segments.isEmpty || _currentSura == null || _currentAyah == null) {
      if (_currentSegmentIndex != -1) {
        _currentSegmentIndex = -1;
        notifyListeners();
      }
      return;
    }
    int ms = position.inMilliseconds;
    var idx = -1;
    for (int i = 0; i < _segments.length; i++) {
      final seg = _segments[i];
      if (ms >= seg.$2 && ms <= seg.$3) {
        idx = i;
        break;
      }
      if (ms >= seg.$2) idx = i;
    }
    if (_segments.isNotEmpty && idx >= 0) {
      final lastSeg = _segments.last;
      final nearEnd = ms >= (lastSeg.$3 - 400);
      if (nearEnd && idx == _segments.length - 1) {
        if (_currentSegmentIndex != idx) {
          _currentSegmentIndex = idx;
          notifyListeners();
        }
        return;
      }
    }
    if (idx != _currentSegmentIndex) {
      _currentSegmentIndex = idx;
      notifyListeners();
    }
  }

  void _setSegmentsFromAyahData(Map<String, dynamic> data) {
    final raw = data['segments'];
    if (raw is! List) {
      _segments = const [];
      _currentSegmentIndex = -1;
      return;
    }
    _segments = _parseSegments(raw);
    _currentSegmentIndex = -1;
  }

  List<(int token, int startMs, int endMs)> _parseSegments(dynamic raw) {
    if (raw is! List) return const [];
    final segments = <(int token, int startMs, int endMs)>[];
    for (int i = 0; i < raw.length; i++) {
      final item = raw[i];
      if (item is! List || item.length < 3) continue;
      final token = int.tryParse(item[0].toString()) ?? (i + 1);
      final start = int.tryParse(item[1].toString()) ?? 0;
      final end = int.tryParse(item[2].toString()) ?? 0;
      if (end > start) segments.add((token, start, end));
    }
    return segments;
  }

  (bool, int, int)? _nextAyahForContinuousFrom(int sura, int ayah) {
    final range = _playbackRange;
    if (range != null && _isWithinRange(sura, ayah, range)) {
      if (sura == range.toSura && ayah == range.toAyah) return null;
      final next = getNextAyah(sura, ayah);
      if (next == null) return null;
      if (!_isWithinRange(next.$2, next.$3, range)) return null;
      return next;
    }
    return getNextAyah(sura, ayah);
  }

  Future<Map<String, dynamic>?> _getReciterMap(String reciterId) async {
    if (_reciterMaps.containsKey(reciterId)) {
      return _reciterMaps[reciterId];
    }
    final reciter = kAyahReciters.where((r) => r.id == reciterId).firstOrNull;
    if (reciter == null) return null;
    try {
      final jsonStr = await rootBundle.loadString(reciter.assetPath);
      final map = json.decode(jsonStr) as Map<String, dynamic>;
      _reciterMaps[reciterId] = map;
      return map;
    } catch (_) {
      return null;
    }
  }

  int _getAyahDurationMs(Map<String, dynamic> data) {
    final segs = _parseSegments(data['segments']);
    if (segs.isNotEmpty) return segs.last.$3;
    final d = data['duration'];
    if (d != null) {
      final sec =
          (d is num) ? d.toDouble() : (double.tryParse(d.toString()) ?? 0);
      return (sec * 1000).round();
    }
    return 0;
  }

  /// يُرجع true إذا كانت البسملة مطلوبة قبل (sura, 1) عند الانتقال من سورة سابقة.
  /// [prevSura] السورة السابقة في التسلسل (للتمييز بين بداية مباشرة من آية 1 والانتقال التلقائي).
  bool _needsBasmallahBefore(int sura, {int? prevSura}) {
    if (sura <= 1) return false;
    if (sura == 9) return false; // لا بسملة بين الأنفال والتوبة
    if (prevSura == null) return false; // بداية مباشرة (ضغط المستخدم) — لا بسملة
    return prevSura != sura;
  }

  List<_QueueAyah> _buildQueueFromMap(
    Map<String, dynamic> map,
    int startSura,
    int startAyah,
    int count, {
    int initialOffsetMs = 0,
    int? prevSura,
  }) {
    final list = <_QueueAyah>[];
    int offsetMs = initialOffsetMs;
    int s = startSura, a = startAyah;
    for (int i = 0; i < count; i++) {
      if (a == 1 && _needsBasmallahBefore(s, prevSura: prevSura)) {
        list.add(_QueueAyah(
          0,
          0,
          _basmallahTransitionUrl,
          const [],
          offsetMs,
        ));
        offsetMs += _basmallahDurationMs;
      }
      final key = '$s:$a';
      final data = map[key];
      if (data == null || data is! Map<String, dynamic>) break;
      final url = data['audio_url'] as String?;
      if (url == null || url.isEmpty) break;
      final segments = _parseSegments(data['segments']);
      list.add(_QueueAyah(s, a, url, segments, offsetMs));
      offsetMs += _getAyahDurationMs(data);
      final next = _nextAyahForContinuousFrom(s, a);
      if (next == null) break;
      prevSura = s;
      s = next.$2;
      a = next.$3;
    }
    return list;
  }

  void _onQueueIndexChanged(int? index) {
    if (index == null || index < 0 || index >= _queueAyahs.length) return;
    _queueSyncTimer?.cancel();
    _queueSyncTimer = null;
    final q = _queueAyahs[index];
    // أثناء البسملة (0,0) نُبقي عرض الآية السابقة
    if (q.sura != 0 || q.ayah != 0) {
      _currentSura = q.sura;
      _currentAyah = q.ayah;
      _segments = q.segments.map((s) => (s.$1, s.$2, s.$3)).toList();
    }
    _currentSegmentIndex = -1;
    notifyListeners();
    // مزامنة فورية ثم مؤجلة — تجنب اختفاء تأشير الكلمات بسبب تأخر positionStream أو تحميل الصفحة من الكاش
    _onPositionChanged(_player.position);
    Future.microtask(() => _onPositionChanged(_player.position));
    _queueSyncTimer = Timer(const Duration(milliseconds: 150), () {
      if (_usingQueue && _queueAyahs.isNotEmpty && index < _queueAyahs.length) {
        final qNow = _queueAyahs[index];
        if (_currentSura == qNow.sura && _currentAyah == qNow.ayah) {
          _onPositionChanged(_player.position);
        }
      }
      _queueSyncTimer = null;
    });
    _ensureQueueHasMore(index);
  }

  Future<void> _ensureQueueHasMore(int currentIndex) async {
    if (currentIndex < _queueAyahs.length - 2) return;
    final src = _queueSource;
    final map = await _getReciterMap(_currentReciterId);
    if (src == null || map == null) return;
    final last = _queueAyahs.isNotEmpty ? _queueAyahs.last : null;
    if (last == null) return;
    final next = _nextAyahForContinuousFrom(last.sura, last.ayah);
    if (next == null) return;
    final s = next.$2;
    final a = next.$3;
    final startOffset = _queueAyahs.isEmpty
        ? 0
        : _queueAyahs.last.startOffsetMs +
            (last.sura == 0 && last.ayah == 0
                ? _basmallahDurationMs
                : _getAyahDurationMs(
                    map['${last.sura}:${last.ayah}'] as Map<String, dynamic>? ??
                        {}));
    final toAdd = _buildQueueFromMap(
      map,
      s,
      a,
      2,
      initialOffsetMs: startOffset,
      prevSura: last.sura == 0 ? null : last.sura,
    );
    if (toAdd.isEmpty) return;
    int runningOffset = startOffset;
    for (final q in toAdd) {
      _queueAyahs
          .add(_QueueAyah(q.sura, q.ayah, q.url, q.segments, runningOffset));
      await src.add(AudioSource.uri(
        Uri.parse(q.url),
        tag: q.sura == 0 && q.ayah == 0
            ? _mediaItemBasmallah
            : _mediaItemForAyah(q.sura, q.ayah),
      ));
      runningOffset += (q.sura == 0 && q.ayah == 0)
          ? _basmallahDurationMs
          : _getAyahDurationMs(
              map['${q.sura}:${q.ayah}'] as Map<String, dynamic>? ?? {});
    }
  }

  /// تشغيل تلاوة آية محددة.
  Future<bool> playAyah(int sura, int ayah, {String? reciterId}) async {
    _azkarSession = false;
    try {
      await _ensureBackgroundAudioInitialized();
    } catch (e) {
      // لا نمنع تشغيل الآية إذا تعذر تهيئة إشعارات الخلفية.
      debugPrint('Background audio init failed: $e');
    }
    await _ensurePrefsLoaded();
    _errorMessage = null;
    final rid = reciterId ?? _currentReciterId;
    _currentReciterId = rid;

    final map = await _getReciterMap(rid);
    if (map == null) {
      _errorMessage = 'تعذر تحميل بيانات القارئ';
      _state = AyahPlayerState.error;
      notifyListeners();
      return false;
    }

    final key = '$sura:$ayah';
    final data = map[key];
    if (data == null || data is! Map<String, dynamic>) {
      return false;
    }
    _setSegmentsFromAyahData(data);
    final url = data['audio_url'] as String?;
    if (url == null || url.isEmpty) return false;

    _currentSura = sura;
    _currentAyah = ayah;
    _state = AyahPlayerState.loading;
    _playbackMode = await AyahRecitersPrefs.instance.getPlaybackMode();
    notifyListeners();

    try {
      if (_playbackMode == AyahPlaybackMode.continuous) {
        _clearQueueState();
        _queueAyahs = _buildQueueFromMap(map, sura, ayah, 4);
        if (_queueAyahs.isEmpty) return false;
        _queueSource = ConcatenatingAudioSource(
          children: _queueAyahs
              .map((q) => AudioSource.uri(
                    Uri.parse(q.url),
                    tag: q.sura == 0 && q.ayah == 0
                        ? _mediaItemBasmallah
                        : _mediaItemForAyah(q.sura, q.ayah),
                  ))
              .toList(),
          useLazyPreparation: false,
        );
        await _player.setAudioSource(_queueSource!);
        _usingQueue = true;
        _queueIndexSub =
            _player.currentIndexStream.listen(_onQueueIndexChanged);
        _onQueueIndexChanged(0);
        await _player.play();
        return true;
      }
      if (_usingQueue || _queueIndexSub != null || _queueSource != null) {
        _clearQueueState();
      }
      await _player.setAudioSource(
        AudioSource.uri(
          Uri.parse(url),
          tag: _mediaItemForAyah(sura, ayah),
        ),
        preload: true,
      );
      await _player.play();
      return true;
    } catch (e) {
      _errorMessage = 'تعذر تشغيل التلاوة';
      _state = AyahPlayerState.error;
      notifyListeners();
      return false;
    }
  }

  /// الآية السابقة وتشغيلها.
  Future<bool> playPrev() async {
    final s = _currentSura;
    final a = _currentAyah;
    if (s == null || a == null) return false;
    final prev = getPrevAyah(s, a);
    if (prev == null) return false;
    return playAyah(prev.$2, prev.$3);
  }

  /// الآية التالية وتشغيلها.
  Future<bool> playNext() async {
    final s = _currentSura;
    final a = _currentAyah;
    if (s == null || a == null) return false;
    final next = getNextAyah(s, a);
    if (next == null) return false;
    return playAyah(next.$2, next.$3);
  }

  bool get hasPrev {
    final s = _currentSura;
    final a = _currentAyah;
    if (s == null || a == null) return false;
    return getPrevAyah(s, a) != null;
  }

  bool get hasNext {
    final s = _currentSura;
    final a = _currentAyah;
    if (s == null || a == null) return false;
    return getNextAyah(s, a) != null;
  }

  Future<void> pause() async {
    await _player.pause();
  }

  Future<void> resume() async {
    await _player.play();
  }

  Future<void> stop() async {
    _azkarSession = false;
    _clearQueueState();
    _pendingNextAfterBasmallah = null;
    await _player.stop();
    _currentSura = null;
    _currentAyah = null;
    _segments = const [];
    _currentSegmentIndex = -1;
    _state = AyahPlayerState.idle;
    _errorMessage = null;
    notifyListeners();
  }

  /// تشغيل صوت مجموعة أذكار في **نفس** مشغّل التلاوة وإشعار الوسائط (يحل محل الآية الحالية).
  Future<bool> playAzkarAudio(String url, {required String title}) async {
    try {
      await _ensureBackgroundAudioInitialized();
    } catch (e) {
      debugPrint('Background audio init failed: $e');
    }
    _errorMessage = null;
    _azkarSession = true;
    _clearQueueState();
    _pendingNextAfterBasmallah = null;
    _currentSura = null;
    _currentAyah = null;
    _segments = const [];
    _currentSegmentIndex = -1;
    _state = AyahPlayerState.loading;
    notifyListeners();
    final displayTitle =
        title.trim().isEmpty ? 'أذكار وأدعية' : title.trim();
    final safeTitle = displayTitle.length > 120
        ? '${displayTitle.substring(0, 117)}...'
        : displayTitle;
    try {
      await _player
          .setAudioSource(
            AudioSource.uri(
              Uri.parse(url),
              tag: MediaItem(
                id: 'azkar:${url.hashCode}',
                album: _appAlbum,
                title: safeTitle,
              ),
            ),
            preload: true,
          )
          .timeout(const Duration(seconds: 25));
      await _player.play();
      return true;
    } catch (e) {
      _azkarSession = false;
      _state = AyahPlayerState.error;
      _errorMessage = 'تعذر تشغيل صوت الأذكار';
      notifyListeners();
      return false;
    }
  }

  Future<void> cyclePlaybackMode() async {
    final wasPlaying = _state == AyahPlayerState.playing;
    final wasPaused = _state == AyahPlayerState.paused;
    final currentSura = _currentSura;
    final currentAyah = _currentAyah;
    final previousMode = _playbackMode;

    _playbackMode = AyahPlaybackMode
        .values[(_playbackMode.index + 1) % AyahPlaybackMode.values.length];
    await AyahRecitersPrefs.instance.setPlaybackMode(_playbackMode);

    // عند التحويل من "متابعة" إلى "مرة واحدة/تكرار":
    // queue المتتابعة تكون محمّلة مسبقاً، لذا نعيد ربط نفس الآية الحالية
    // بمصدر مفرد فوراً حتى يطبق الوضع الجديد مباشرة على الآية المشغلة الآن.
    if (previousMode == AyahPlaybackMode.continuous &&
        _playbackMode != AyahPlaybackMode.continuous &&
        currentSura != null &&
        currentAyah != null &&
        (wasPlaying || wasPaused)) {
      final ok = await playAyah(
        currentSura,
        currentAyah,
        reciterId: _currentReciterId,
      );
      if (ok && wasPaused) {
        await pause();
      }
      return;
    }
    notifyListeners();
  }

  Future<void> setReciter(String id) async {
    await _ensurePrefsLoaded();
    _currentReciterId = id;
    await AyahRecitersPrefs.instance.setCurrentReciterId(id);
    notifyListeners();
  }

  Future<void> setPlaybackRange(int sura, int fromAyah, int toAyah) async {
    await setPlaybackRangeSpan(sura, fromAyah, sura, toAyah);
  }

  Future<void> setPlaybackRangeSpan(
    int fromSura,
    int fromAyah,
    int toSura,
    int toAyah,
  ) async {
    await _ensurePrefsLoaded();
    var s1 = fromSura;
    var a1 = fromAyah;
    var s2 = toSura;
    var a2 = toAyah;
    if (s2 < s1 || (s2 == s1 && a2 < a1)) {
      final ts = s1;
      final ta = a1;
      s1 = s2;
      a1 = a2;
      s2 = ts;
      a2 = ta;
    }
    _playbackRange = AyahPlaybackRange(
      fromSura: s1,
      fromAyah: a1,
      toSura: s2,
      toAyah: a2,
    );
    await AyahRecitersPrefs.instance.setPlaybackRange(_playbackRange!);
    notifyListeners();
  }

  Future<void> clearPlaybackRange() async {
    _playbackRange = null;
    await AyahRecitersPrefs.instance.clearPlaybackRange();
    notifyListeners();
  }

  Future<bool> playRangeStart() async {
    await _ensurePrefsLoaded();
    final range = _playbackRange;
    if (range == null) return false;
    return playAyah(range.fromSura, range.fromAyah);
  }

  void dismissError() {
    _errorMessage = null;
    if (_state == AyahPlayerState.error) {
      _state = AyahPlayerState.idle;
      _currentSura = null;
      _currentAyah = null;
    }
    notifyListeners();
  }
}
