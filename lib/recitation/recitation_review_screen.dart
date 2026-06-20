import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:quran_app/recitation/recitation_db.dart';
import 'package:quran_app/recitation/recitation_screen.dart';

class RecitationReviewScreen extends StatefulWidget {
  const RecitationReviewScreen({
    super.key,
    this.initialSurahNumber,
  });

  final int? initialSurahNumber;

  static Future<void> open(
    BuildContext context, {
    int? initialSurahNumber,
  }) {
    return Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => RecitationReviewScreen(
          initialSurahNumber: initialSurahNumber,
        ),
      ),
    );
  }

  @override
  State<RecitationReviewScreen> createState() => _RecitationReviewScreenState();
}

class _RecitationReviewScreenState extends State<RecitationReviewScreen> {
  final RecitationDb _db = RecitationDb.instance;

  Widget _rtlBackButton(BuildContext context) {
    return IconButton(
      tooltip: MaterialLocalizations.of(context).backButtonTooltip,
      onPressed: () => Navigator.maybePop(context),
      icon: const Icon(Icons.arrow_back),
    );
  }

  PreferredSizeWidget _reviewAppBar(BuildContext context) {
    return AppBar(
      backgroundColor: const Color(0xFFE8F5E9),
      foregroundColor: const Color(0xFF1B5E20),
      elevation: 0,
      automaticallyImplyLeading: false,
      leading: _rtlBackButton(context),
      title: const Text('مراجعة التسميع'),
    );
  }

  bool _loading = true;
  String? _error;
  List<_SurahReviewSection> _sections = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      await _db.init();
      final surahs = await _db.getSurahs();
      if (surahs.isEmpty) throw StateError('لا توجد سور');
      final summaryBySurah = await _db.getSurahReviewSummaries();

      final sections = <_SurahReviewSection>[];

      for (final surah in surahs) {
        final surahNumber = (surah['id'] as int?) ?? 0;
        if (surahNumber <= 0) continue;
        final surahName = (surah['name_ar'] ?? '').toString();
        final ayahs = await _db.getAyahsForSurah(surahNumber);
        final ayahCount = ayahs.length;
        final summary = summaryBySurah[surahNumber] ?? const <String, int>{};
        final readCount = summary['read_ayahs'] ?? 0;
        final errAyahs = summary['error_ayahs'] ?? 0;
        final errWords = summary['error_words'] ?? 0;
        final statsRows = await _db.getReadAyahStatsRowsForSurah(surahNumber);
        final readAyahNumbers = <int>{};
        final errorAyahNumbers = <int>{};
        for (final row in statsRows) {
          final ayahNumber = (row['ayah_number'] as int?) ?? 0;
          if (ayahNumber <= 0) continue;
          readAyahNumbers.add(ayahNumber);
          final wrongWords = (row['wrong_words'] as int?) ?? 0;
          final rawErrorIds =
              (row['last_error_word_ids'] ?? '').toString().trim();
          var hasRealErrorIds = false;
          if (rawErrorIds.isNotEmpty) {
            try {
              final decoded = jsonDecode(rawErrorIds);
              if (decoded is List) {
                hasRealErrorIds = decoded.any((e) {
                  final v = int.tryParse(e.toString()) ?? 0;
                  return v > 0;
                });
              }
            } catch (_) {}
          }
          if (wrongWords > 0 || hasRealErrorIds) {
            errorAyahNumbers.add(ayahNumber);
          }
        }

        sections.add(
          _SurahReviewSection(
            surahNumber: surahNumber,
            surahName: surahName,
            ayahCount: ayahCount,
            readAyahCount: readCount,
            errorAyahCount: errAyahs,
            errorWordCount: errWords,
            readAyahNumbers: readAyahNumbers,
            errorAyahNumbers: errorAyahNumbers,
            entries: const [],
            detailsLoaded: false,
            isExpanded: false,
          ),
        );
      }

      if (!mounted) return;
      setState(() {
        _sections = sections;
        _loading = false;
        _error = null;
      });

      final initial = widget.initialSurahNumber;
      if (initial != null) {
        final idx = _sections.indexWhere((s) => s.surahNumber == initial);
        if (idx >= 0) {
          await _toggleSection(idx);
        }
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        debugPrint('Recitation review load failed: $e');
        _error = 'تعذّر تحميل مراجعة التسميع. أعد المحاولة.';
      });
    }
  }

  Future<void> _toggleSection(int index) async {
    if (index < 0 || index >= _sections.length) return;
    final section = _sections[index];
    if (section.isExpanded) {
      setState(() {
        _sections = List<_SurahReviewSection>.from(_sections)
          ..[index] = _sections[index].copyWith(isExpanded: false);
      });
      return;
    }
    if (section.detailsLoaded || section.readAyahCount == 0) {
      setState(() {
        _sections = List<_SurahReviewSection>.from(_sections)
          ..[index] = _sections[index].copyWith(isExpanded: true);
      });
      return;
    }

    final rows = await _db.getReadAyahStatsRowsForSurah(section.surahNumber);
    final entries = <_AyahReviewEntry>[];
    for (final row in rows) {
      final ayahNumber = (row['ayah_number'] as int?) ?? 0;
      if (ayahNumber <= 0) continue;
      final words =
          await _db.getDisplayWordsForAyah(section.surahNumber, ayahNumber);
      final raw = (row['last_error_word_ids'] ?? '').toString();
      final wrong = <int>{};
      if (raw.trim().isNotEmpty) {
        try {
          final decoded = jsonDecode(raw);
          if (decoded is List) {
            for (final e in decoded) {
              final v = int.tryParse(e.toString()) ?? 0;
              if (v > 0) wrong.add(v);
            }
          }
        } catch (_) {}
      }
      entries.add(
        _AyahReviewEntry(
          surahNumber: section.surahNumber,
          ayahNumber: ayahNumber,
          words: words,
          wrongWordIds: wrong,
        ),
      );
    }
    if (!mounted) return;
    setState(() {
      _sections = List<_SurahReviewSection>.from(_sections)
        ..[index] = _sections[index].copyWith(
          isExpanded: true,
          detailsLoaded: true,
          entries: entries,
        );
    });
  }

  Future<void> _showAyahActions(_AyahReviewEntry entry) async {
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: ListTile(
            leading: const Icon(Icons.mic_rounded),
            title: Text(
              'ابدأ التسميع الذكي من السورة ${entry.surahNumber} - الآية ${entry.ayahNumber}',
            ),
            subtitle: const Text(
              'ستُحدّث أخطاء هذه الآية بناءً على محاولة التسميع الجديدة',
            ),
            onTap: () async {
              Navigator.of(ctx).pop();
              await RecitationScreen.open(
                context,
                initialSurahNumber: entry.surahNumber,
                initialAyahNumber: entry.ayahNumber,
              );
              if (!mounted) return;
              await _load();
            },
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Directionality(
        textDirection: TextDirection.rtl,
        child: Scaffold(
          appBar: _reviewAppBar(context),
          body: const Center(child: CircularProgressIndicator()),
        ),
      );
    }
    if (_error != null) {
      return Directionality(
        textDirection: TextDirection.rtl,
        child: Scaffold(
          appBar: _reviewAppBar(context),
          body: Center(child: Text(_error!)),
        ),
      );
    }

    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        backgroundColor: const Color(0xFFE8F5E9),
        appBar: _reviewAppBar(context),
        body: Column(
          children: [
            Expanded(
              child: ListView.separated(
                itemCount: _sections.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (context, i) {
                  final section = _sections[i];
                  final visibleEntries = section.entries;
                  return _SurahTile(
                    section: section,
                    visibleEntries: visibleEntries,
                    order: i + 1,
                    onToggle: () => _toggleSection(i),
                    onLongPressAyah: _showAyahActions,
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AyahReviewEntry {
  const _AyahReviewEntry({
    required this.surahNumber,
    required this.ayahNumber,
    required this.words,
    required this.wrongWordIds,
  });

  final int surahNumber;
  final int ayahNumber;
  final List<Map<String, Object?>> words;
  final Set<int> wrongWordIds;

  List<Widget> spans() {
    final out = <Widget>[];
    for (final w in words) {
      final isMarker = (w['is_ayah_marker'] as int? ?? 0) != 0;
      if (isMarker) continue;
      final id = (w['word_number_all'] as int?) ?? 0;
      final text = ((w['display_text'] ?? '').toString()).trim();
      if (text.isEmpty) continue;
      final wrong = wrongWordIds.contains(id);
      out.add(
        Text(
          text,
          style: TextStyle(
            color: wrong ? const Color(0xFFC63A2C) : const Color(0xFF1F9D49),
            fontSize: 20,
            fontFamily: 'QuranUthmani',
            fontWeight: FontWeight.w600,
          ),
        ),
      );
    }
    return out;
  }
}

class _SurahReviewSection {
  const _SurahReviewSection({
    required this.surahNumber,
    required this.surahName,
    required this.ayahCount,
    required this.readAyahCount,
    required this.errorAyahCount,
    required this.errorWordCount,
    required this.readAyahNumbers,
    required this.errorAyahNumbers,
    required this.entries,
    required this.detailsLoaded,
    required this.isExpanded,
  });

  final int surahNumber;
  final String surahName;
  final int ayahCount;
  final int readAyahCount;
  final int errorAyahCount;
  final int errorWordCount;
  final Set<int> readAyahNumbers;
  final Set<int> errorAyahNumbers;
  final List<_AyahReviewEntry> entries;
  final bool detailsLoaded;
  final bool isExpanded;

  _SurahReviewSection copyWith({
    bool? isExpanded,
    bool? detailsLoaded,
    List<_AyahReviewEntry>? entries,
  }) {
    return _SurahReviewSection(
      surahNumber: surahNumber,
      surahName: surahName,
      ayahCount: ayahCount,
      readAyahCount: readAyahCount,
      errorAyahCount: errorAyahCount,
      errorWordCount: errorWordCount,
      readAyahNumbers: readAyahNumbers,
      errorAyahNumbers: errorAyahNumbers,
      entries: entries ?? this.entries,
      detailsLoaded: detailsLoaded ?? this.detailsLoaded,
      isExpanded: isExpanded ?? this.isExpanded,
    );
  }
}

class _SurahTile extends StatelessWidget {
  const _SurahTile({
    required this.section,
    required this.visibleEntries,
    required this.order,
    required this.onToggle,
    required this.onLongPressAyah,
  });

  final _SurahReviewSection section;
  final List<_AyahReviewEntry> visibleEntries;
  final int order;
  final VoidCallback onToggle;
  final ValueChanged<_AyahReviewEntry> onLongPressAyah;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          onTap: onToggle,
          child: Container(
            margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
            decoration: BoxDecoration(
              color: const Color(0xFFFFFFFF),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFFE5E1EC)),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.04),
                  blurRadius: 4,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Icon(
                      section.isExpanded
                          ? Icons.keyboard_arrow_down_rounded
                          : Icons.keyboard_arrow_left_rounded,
                    ),
                    const SizedBox(width: 10),
                    Container(
                      width: 28,
                      height: 28,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: const Color(0xFFECE7F6),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        '$order',
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF4D4D4D),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        section.surahName.isEmpty
                            ? 'سورة ${section.surahNumber}'
                            : section.surahName,
                        style: const TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    Text(
                      'مقروءة ${section.readAyahCount}/${section.ayahCount} • أخطاء ${section.errorAyahCount}',
                      style: const TextStyle(
                        fontSize: 12,
                        color: Color(0xFF666666),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                _SurahProgressBar(
                  ayahCount: section.ayahCount,
                  readAyahs: section.readAyahNumbers,
                  errorAyahs: section.errorAyahNumbers,
                ),
              ],
            ),
          ),
        ),
        if (section.isExpanded)
          if (section.readAyahCount == 0)
            const Padding(
              padding: EdgeInsets.fromLTRB(18, 10, 18, 12),
              child: Text(
                'لم يتم قراءتها',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF666666),
                ),
              ),
            )
          else if (visibleEntries.isEmpty)
            const Padding(
              padding: EdgeInsets.fromLTRB(12, 10, 12, 12),
              child: Text(
                'لا توجد تفاصيل محفوظة لهذه السورة.',
                style: TextStyle(
                  fontSize: 13,
                  color: Color(0xFF666666),
                ),
              ),
            )
          else
            ...visibleEntries.map(
              (entry) => InkWell(
                onLongPress: () => onLongPressAyah(entry),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'الآية ${entry.ayahNumber}',
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF4D4D4D),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 3,
                        runSpacing: 6,
                        children: entry.spans(),
                      ),
                    ],
                  ),
                ),
              ),
            ),
      ],
    );
  }
}

class _SurahProgressBar extends StatelessWidget {
  const _SurahProgressBar({
    required this.ayahCount,
    required this.readAyahs,
    required this.errorAyahs,
  });

  final int ayahCount;
  final Set<int> readAyahs;
  final Set<int> errorAyahs;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: 12,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(999),
        child: CustomPaint(
          painter: _SurahProgressBarPainter(
            ayahCount: ayahCount,
            readAyahs: readAyahs,
            errorAyahs: errorAyahs,
          ),
        ),
      ),
    );
  }
}

class _SurahProgressBarPainter extends CustomPainter {
  _SurahProgressBarPainter({
    required this.ayahCount,
    required this.readAyahs,
    required this.errorAyahs,
  });

  final int ayahCount;
  final Set<int> readAyahs;
  final Set<int> errorAyahs;

  @override
  void paint(Canvas canvas, Size size) {
    final backgroundPaint = Paint()..color = const Color(0xFFCCCCCC);
    final correctPaint = Paint()..color = const Color(0xFF1FA74A);
    final errorPaint = Paint()..color = const Color(0xFFD92E2E);
    canvas.drawRect(Offset.zero & size, backgroundPaint);
    if (ayahCount <= 0 || size.width <= 0 || size.height <= 0) return;

    final cellWidth = size.width / ayahCount;

    for (var ayah = 1; ayah <= ayahCount; ayah++) {
      final isRead = readAyahs.contains(ayah);
      if (!isRead) continue;
      final hasError = errorAyahs.contains(ayah);
      final paint = hasError ? errorPaint : correctPaint;

      // Right-to-left layout: ayah 1 starts from far right.
      final left = size.width - (ayah * cellWidth);
      final right = size.width - ((ayah - 1) * cellWidth);
      canvas.drawRect(Rect.fromLTRB(left, 0, right, size.height), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _SurahProgressBarPainter oldDelegate) {
    return ayahCount != oldDelegate.ayahCount ||
        readAyahs.length != oldDelegate.readAyahs.length ||
        errorAyahs.length != oldDelegate.errorAyahs.length ||
        !setEquals(readAyahs, oldDelegate.readAyahs) ||
        !setEquals(errorAyahs, oldDelegate.errorAyahs);
  }
}
