import 'package:flutter_test/flutter_test.dart';
import 'package:quran_app/recitation/recitation_logic.dart';

void main() {
  group('recitationBacktrackWindow', () {
    test('keeps a minimum for short ayahs', () {
      expect(recitationBacktrackWindow(4), 15);
    });

    test('expands for longer ayahs', () {
      expect(recitationBacktrackWindow(24), 30);
    });

    test('caps very large ayahs to avoid huge window', () {
      expect(recitationBacktrackWindow(80), 48);
    });
  });

  group('sliceIncrementalTranscript', () {
    test('returns new tail with rewind tokens', () {
      final slice = sliceIncrementalTranscript(
        normalizedTranscript: 'الذين يؤمنون بالغيب ويقيمون الصلاة',
        previousBaseline: 'الذين يؤمنون بالغيب',
        rewindTokens: 2,
        maxTokens: 12,
      );

      expect(slice.tokens, ['يؤمنون', 'بالغيب', 'ويقيمون', 'الصلاة']);
      expect(slice.nextBaseline, 'الذين يؤمنون بالغيب ويقيمون الصلاة');
    });

    test('handles baseline reset correctly', () {
      final slice = sliceIncrementalTranscript(
        normalizedTranscript: 'بما انزل اليك',
        previousBaseline: 'الذين يؤمنون بالغيب',
      );

      expect(slice.tokens, ['بما', 'انزل', 'اليك']);
    });

    test('keeps the beginning of the slice when capping with maxTokens', () {
      final long = List.generate(40, (i) => 'w$i').join(' ');
      final slice = sliceIncrementalTranscript(
        normalizedTranscript: long,
        previousBaseline: '',
        maxTokens: 10,
      );
      expect(slice.tokens.length, 10);
      expect(slice.tokens.first, 'w0');
    });

    test(
      're-attaches ayah head tokens when stable prefix is long (far divergence)',
      () {
        final prev = List.generate(20, (i) => 'w$i').join(' ');
        final next =
            '${List.generate(20, (i) => 'w$i').join(' ')} w20 w21 extra';
        final slice = sliceIncrementalTranscript(
          normalizedTranscript: next,
          previousBaseline: prev,
          rewindTokens: 4,
          maxTokens: 50,
        );
        expect(slice.tokens.contains('w0'), isTrue);
        expect(slice.tokens.contains('w19'), isTrue);
        expect(slice.tokens.contains('w20'), isTrue);
      },
    );
  });

  group('recitationPointerBumpAfterAyahTailWrongOnly', () {
    test('bumps past ayah when only the last word in range is wrong', () {
      final bumped = recitationPointerBumpAfterAyahTailWrongOnly(
        orderedWordIdsInRange: const [10, 11, 12, 13],
        tones: const {
          10: RecitationWordTone.correct,
          11: RecitationWordTone.correct,
          12: RecitationWordTone.acceptable,
          13: RecitationWordTone.wrong,
        },
        nextPointer: 13,
        blockedByWrongStreak: false,
      );
      expect(bumped, 14);
    });

    test('no bump when an earlier word is also wrong', () {
      final bumped = recitationPointerBumpAfterAyahTailWrongOnly(
        orderedWordIdsInRange: const [10, 11, 12],
        tones: const {
          10: RecitationWordTone.correct,
          11: RecitationWordTone.wrong,
          12: RecitationWordTone.wrong,
        },
        nextPointer: 12,
        blockedByWrongStreak: false,
      );
      expect(bumped, isNull);
    });

    test('no bump when blocked by wrong streak', () {
      final bumped = recitationPointerBumpAfterAyahTailWrongOnly(
        orderedWordIdsInRange: const [1, 2, 3],
        tones: const {
          1: RecitationWordTone.correct,
          2: RecitationWordTone.correct,
          3: RecitationWordTone.wrong,
        },
        nextPointer: 3,
        blockedByWrongStreak: true,
      );
      expect(bumped, isNull);
    });
  });

  group('computeAdvanceDecision', () {
    test('blocks advance when unresolved words remain', () {
      final decision = computeAdvanceDecision(
        orderedWordIds: const [1, 2, 3, 4],
        tones: const {
          1: RecitationWordTone.correct,
          2: RecitationWordTone.acceptable,
          3: RecitationWordTone.wrong,
        },
        consecutiveWrongThreshold: 3,
      );

      expect(decision.shouldAdvance, isFalse);
      expect(decision.reason, 'unresolved_words');
      expect(decision.unresolvedWords, 1);
    });

    test('blocks advance on three consecutive wrong words', () {
      final decision = computeAdvanceDecision(
        orderedWordIds: const [10, 11, 12, 13, 14],
        tones: const {
          10: RecitationWordTone.correct,
          11: RecitationWordTone.wrong,
          12: RecitationWordTone.wrong,
          13: RecitationWordTone.wrong,
          14: RecitationWordTone.acceptable,
        },
        consecutiveWrongThreshold: 3,
      );

      expect(decision.shouldAdvance, isFalse);
      expect(decision.reason, 'blocked_3_wrong');
      expect(decision.hasBlockingStreak, isTrue);
    });

    test('wrong streak does not span unrevealed (null) words', () {
      final decision = computeAdvanceDecision(
        orderedWordIds: const [1, 2, 3, 4, 5],
        tones: const {
          1: RecitationWordTone.wrong,
          3: RecitationWordTone.wrong,
          5: RecitationWordTone.wrong,
        },
        consecutiveWrongThreshold: 3,
      );

      expect(decision.hasBlockingStreak, isFalse);
      expect(decision.reason, 'unresolved_words');
    });

    test('allows advance when all words are resolved and no blocking streak',
        () {
      final decision = computeAdvanceDecision(
        orderedWordIds: const [21, 22, 23],
        tones: const {
          21: RecitationWordTone.correct,
          22: RecitationWordTone.acceptable,
          23: RecitationWordTone.wrong,
        },
        consecutiveWrongThreshold: 3,
      );

      expect(decision.shouldAdvance, isTrue);
      expect(decision.reason, 'ready');
      expect(decision.unresolvedWords, 0);
    });

    test('softCorrect breaks wrong streak like correct', () {
      final decision = computeAdvanceDecision(
        orderedWordIds: const [1, 2, 3, 4],
        tones: const {
          1: RecitationWordTone.wrong,
          2: RecitationWordTone.softCorrect,
          3: RecitationWordTone.wrong,
          4: RecitationWordTone.correct,
        },
        consecutiveWrongThreshold: 3,
      );

      expect(decision.hasBlockingStreak, isFalse);
    });
  });

  group('recitationWrongRedDisplayPolicy', () {
    const first = 100;
    test('shows first ayah word red immediately; still staggers at three', () {
      final p1 = recitationWrongRedDisplayPolicy(
        orderedWordIdsInRange: const [100, 101, 102],
        tones: const {100: RecitationWordTone.wrong},
        firstSpokenWordIdInAyah: first,
      );
      expect(p1.suppressWrongRed, isNot(contains(100)));
      expect(p1.ayahStartStaggerOrder, isEmpty);

      final p2 = recitationWrongRedDisplayPolicy(
        orderedWordIdsInRange: const [100, 101, 102],
        tones: const {
          100: RecitationWordTone.wrong,
          101: RecitationWordTone.wrong,
        },
        firstSpokenWordIdInAyah: first,
      );
      expect(p2.suppressWrongRed, isNot(contains(100)));
      expect(p2.ayahStartStaggerOrder, isEmpty);

      final p3 = recitationWrongRedDisplayPolicy(
        orderedWordIdsInRange: const [100, 101, 102, 103],
        tones: const {
          100: RecitationWordTone.wrong,
          101: RecitationWordTone.wrong,
          102: RecitationWordTone.wrong,
        },
        firstSpokenWordIdInAyah: first,
      );
      expect(p3.suppressWrongRed, isNot(contains(100)));
      expect(p3.ayahStartStaggerOrder, [100, 101, 102]);
    });

    test('only first three wrongs in a long run may show red', () {
      final p = recitationWrongRedDisplayPolicy(
        orderedWordIdsInRange: const [1, 2, 3, 4, 5],
        tones: const {
          1: RecitationWordTone.wrong,
          2: RecitationWordTone.wrong,
          3: RecitationWordTone.wrong,
          4: RecitationWordTone.wrong,
          5: RecitationWordTone.wrong,
        },
        firstSpokenWordIdInAyah: 10,
      );
      expect(p.suppressWrongRed, {4, 5});
      expect(p.ayahStartStaggerOrder, isEmpty);
    });

    test(
        'run starting at first word and length 4: stagger head + tail suppressed',
        () {
      final p = recitationWrongRedDisplayPolicy(
        orderedWordIdsInRange: const [100, 101, 102, 103],
        tones: const {
          100: RecitationWordTone.wrong,
          101: RecitationWordTone.wrong,
          102: RecitationWordTone.wrong,
          103: RecitationWordTone.wrong,
        },
        firstSpokenWordIdInAyah: first,
      );
      expect(p.suppressWrongRed, contains(103));
      expect(p.ayahStartStaggerOrder, [100, 101, 102]);
    });
  });

  group('recitationLongWordRelaxedAsrMatch', () {
    test('matches one or two tokens as ordered subsequence (مدهامتان)', () {
      // Two ASR parts must still contain every letter of the ref in order;
      // «مد»+«همتان» is missing the alif after ه (م د ه م ≠ م د ه ا م).
      expect(
        recitationLongWordRelaxedAsrMatch(
          referenceWord: 'مدهامتان',
          sliceTokens: const ['مده', 'امتان'],
        ),
        isTrue,
      );
      expect(
        recitationLongWordRelaxedAsrMatch(
          referenceWord: 'مدهامتان',
          sliceTokens: const ['مدهاميتان'],
        ),
        isTrue,
      );
    });

    test('rejects short reference', () {
      expect(
        recitationLongWordRelaxedAsrMatch(
          referenceWord: 'الذين',
          sliceTokens: const ['الذينا'],
        ),
        isFalse,
      );
    });

    test('rejects wrong letter order', () {
      expect(
        recitationLongWordRelaxedAsrMatch(
          referenceWord: 'مدهامتان',
          sliceTokens: const ['متدهامان'],
        ),
        isFalse,
      );
    });
  });
}
