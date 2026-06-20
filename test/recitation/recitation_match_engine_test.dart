import 'package:flutter_test/flutter_test.dart';
import 'package:quran_app/recitation/recitation_logic.dart';
import 'package:quran_app/recitation/recitation_match_engine.dart';

Map<String, Object?> _wordRow(int id, String text) {
  return <String, Object?>{
    'word_number_all': id,
    'search_key': text,
    'display_text': text,
    'normalized_text': text,
  };
}

void main() {
  group('RecitationMatchEngine cold ayah start guard', () {
    test('marks first-word wrong only, without deep jump/reveal', () {
      final match = RecitationMatchEngine.match(
        RecitationMatchInput(
          pointerBefore: 100,
          currentWordNumberAll: 100,
          allowedBacktrackFloorWordNumberAll: 100,
          ayahWordCount: 6,
          ayahFirstWordNumberAll: 100,
          ayahLastWordNumberAll: 105,
          recitationSessionStartWord: null,
          revealedWordTones: const <int, RecitationWordTone>{},
          orderedSpokenWordIdsInAyah: const <int>[100, 101, 102, 103, 104, 105],
          tokens: const <String>['يخدعون'],
          window: <Map<String, Object?>>[
            _wordRow(100, 'الذين'),
            _wordRow(101, 'يقولون'),
            _wordRow(102, 'امنا'),
            _wordRow(103, 'بالله'),
            _wordRow(104, 'وما'),
            _wordRow(105, 'يخدعون'),
          ],
          referenceTextByWordId: const <int, String>{
            100: 'الذين',
            101: 'يقولون',
            102: 'امنا',
            103: 'بالله',
            104: 'وما',
            105: 'يخدعون',
          },
          isFinal: false,
        ),
      );

      expect(match, isNotNull);
      expect(match!.nextWordPointer, 100);
      expect(match.revealedWordTones[100], RecitationWordTone.wrong);
      expect(match.revealedWordTones.containsKey(105), isFalse);
    });

    test('accepts progress when first ayah word is actually matched', () {
      final match = RecitationMatchEngine.match(
        RecitationMatchInput(
          pointerBefore: 100,
          currentWordNumberAll: 100,
          allowedBacktrackFloorWordNumberAll: 100,
          ayahWordCount: 4,
          ayahFirstWordNumberAll: 100,
          ayahLastWordNumberAll: 103,
          recitationSessionStartWord: null,
          revealedWordTones: const <int, RecitationWordTone>{},
          orderedSpokenWordIdsInAyah: const <int>[100, 101, 102, 103],
          tokens: const <String>['الذين'],
          window: <Map<String, Object?>>[
            _wordRow(100, 'الذين'),
            _wordRow(101, 'يؤمنون'),
            _wordRow(102, 'بالغيب'),
            _wordRow(103, 'ويقيمون'),
          ],
          referenceTextByWordId: const <int, String>{
            100: 'الذين',
            101: 'يؤمنون',
            102: 'بالغيب',
            103: 'ويقيمون',
          },
          isFinal: false,
        ),
      );

      expect(match, isNotNull);
      expect(match!.nextWordPointer, 101);
      expect(match.revealedWordTones[100], isNotNull);
    });
  });
}
