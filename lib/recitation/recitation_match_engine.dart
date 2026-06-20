// Pure transcript matching: alignment + tone map + pointer (no I/O, no UI).
import 'dart:math' as math;

import 'package:quran_app/recitation/arabic_normalizer.dart';
import 'package:quran_app/recitation/recitation_fuzzy_ayah.dart'
    show fuzzyRasmSimilarity;
import 'package:quran_app/recitation/recitation_logic.dart';

/// Snapshot for one matching pass. [window] is from [RecitationDb.getWordWindow].
class RecitationMatchInput {
  const RecitationMatchInput({
    required this.pointerBefore,
    required this.currentWordNumberAll,
    required this.allowedBacktrackFloorWordNumberAll,
    required this.ayahWordCount,
    required this.ayahFirstWordNumberAll,
    required this.ayahLastWordNumberAll,
    required this.recitationSessionStartWord,
    required this.revealedWordTones,
    required this.orderedSpokenWordIdsInAyah,
    required this.tokens,
    required this.window,
    required this.referenceTextByWordId,
    required this.isFinal,
  });

  /// [currentWordNumberAll] at the start of this pass (used for long-word relax).
  final int pointerBefore;

  final int currentWordNumberAll;
  final int allowedBacktrackFloorWordNumberAll;
  final int ayahWordCount;
  final int ayahFirstWordNumberAll;
  final int ayahLastWordNumberAll;
  final int? recitationSessionStartWord;
  final Map<int, RecitationWordTone> revealedWordTones;
  final List<int> orderedSpokenWordIdsInAyah;
  final List<String> tokens;
  final List<Map<String, Object?>> window;
  final Map<int, String> referenceTextByWordId;

  /// When false, consecutive-wrong handling does not freeze the read pointer or
  /// block ayah DB advance—wrong tones still apply so words stay visible in red.
  final bool isFinal;

  int get recitationToneFloor {
    final s = recitationSessionStartWord;
    if (s == null) {
      return 1;
    }
    return math.min(s, currentWordNumberAll);
  }
}

class RecitationMatchResult {
  const RecitationMatchResult({
    required this.revealedWordTones,
    required this.nextWordPointer,
    required this.bestMatchScore,
    required this.advanceDecision,
  });

  final Map<int, RecitationWordTone> revealedWordTones;
  final int nextWordPointer;
  final double bestMatchScore;
  final RecitationAdvanceDecision advanceDecision;
}

/// Per-token match strictness: [tolerant] maps to [RecitationWordTone.softCorrect]
/// in the UI (e.g. missing leading ال, near-token / one-edit ASR drift).
enum _TokenEquivalence { none, tolerant, strict }

class _AlignmentResult {
  const _AlignmentResult({
    required this.score,
    required this.matchedWordNumbers,
    required this.mismatchedWordNumbers,
    required this.firstMatchedWordNumberAll,
    required this.lastMatchedWordNumberAll,
    required this.wordEquivalence,
  });

  final int score;
  final Set<int> matchedWordNumbers;
  final Set<int> mismatchedWordNumbers;
  final int? firstMatchedWordNumberAll;
  final int? lastMatchedWordNumberAll;

  /// Strongest equivalence observed per mushaf word id for this hypothesis.
  final Map<int, _TokenEquivalence> wordEquivalence;
}

/// Alignment + tone updates for one ASR pass (partial or final).
class RecitationMatchEngine {
  RecitationMatchEngine._();

  static RecitationMatchResult? match(RecitationMatchInput input) {
    if (input.tokens.isEmpty || input.window.isEmpty) {
      return null;
    }

    final bestMatch = _findBestAlignment(
      input.tokens,
      input.window,
      currentWordNumberAll: input.currentWordNumberAll,
      allowedBacktrackFloor: input.allowedBacktrackFloorWordNumberAll,
      ayahWordCount: input.ayahWordCount,
    );
    if (bestMatch == null) {
      return null;
    }

    if (input.orderedSpokenWordIdsInAyah.isEmpty) {
      return null;
    }

    final toneFloor = input.recitationToneFloor;
    final matchedNow =
        bestMatch.matchedWordNumbers.where((id) => id > 0).toSet();
    var matchedInRange = matchedNow.where((id) => id >= toneFloor).toSet();
    final eqByWord = bestMatch.wordEquivalence;
    var mismatched =
        bestMatch.mismatchedWordNumbers.where((id) => id > 0).toSet();
    final orderedWordIds = List<int>.from(input.orderedSpokenWordIdsInAyah)
      ..sort();
    final orderedWordIdsInRange =
        orderedWordIds.where((id) => id >= toneFloor).toList();
    final firstWordInAyah =
        orderedWordIdsInRange.isEmpty ? null : orderedWordIdsInRange.first;
    final hasAnyRevealedInAyah = orderedWordIdsInRange.any(
      input.revealedWordTones.containsKey,
    );
    final ayahHasStarted = firstWordInAyah != null &&
        (hasAnyRevealedInAyah || input.currentWordNumberAll > firstWordInAyah);

    // Cold-start guard: on a fresh ayah, ignore alignments that only matched
    // later words. This prevents one common token (e.g. "يخدعون") from jumping
    // deep into the next ayah and revealing a block before any actual recitation.
    if (firstWordInAyah != null &&
        !ayahHasStarted &&
        !matchedInRange.contains(firstWordInAyah) &&
        !mismatched.contains(firstWordInAyah)) {
      return null;
    }
    if (firstWordInAyah != null &&
        !ayahHasStarted &&
        !matchedInRange.contains(firstWordInAyah) &&
        mismatched.contains(firstWordInAyah)) {
      // The user started with a wrong first word: reveal that error only, but do
      // not let deep accidental matches advance/reveal later words yet.
      matchedInRange = <int>{};
      mismatched = <int>{firstWordInAyah};
    }

    final backtrackWindow = recitationBacktrackWindow(input.ayahWordCount);
    var nextPointer = input.currentWordNumberAll;
    final earliestMatchedInAyah =
        matchedInRange.isEmpty ? null : matchedInRange.reduce(math.min);
    final furthestMatchedInAyah =
        matchedInRange.isEmpty ? null : matchedInRange.reduce(math.max);
    final hasForwardProgress = furthestMatchedInAyah != null &&
        furthestMatchedInAyah >= input.currentWordNumberAll;
    final canBacktrackInAyah = earliestMatchedInAyah != null &&
        earliestMatchedInAyah < input.currentWordNumberAll &&
        input.currentWordNumberAll - earliestMatchedInAyah <= backtrackWindow &&
        !hasForwardProgress;
    if (earliestMatchedInAyah != null && canBacktrackInAyah) {
      nextPointer = earliestMatchedInAyah;
    } else if (furthestMatchedInAyah != null &&
        furthestMatchedInAyah >= input.currentWordNumberAll) {
      nextPointer = furthestMatchedInAyah + 1;
    }

    final nextTones =
        Map<int, RecitationWordTone>.from(input.revealedWordTones);
    final hadRevealedWordsBefore =
        input.revealedWordTones.keys.any((k) => k >= toneFloor);
    final orderedWindowWordIds = input.window
        .map((row) => (row['word_number_all'] as int?) ?? 0)
        .where((id) => id > 0)
        .toList(growable: false);

    bool isSuccessTone(RecitationWordTone? t) =>
        t == RecitationWordTone.correct || t == RecitationWordTone.softCorrect;

    if (hadRevealedWordsBefore &&
        furthestMatchedInAyah != null &&
        orderedWindowWordIds.isNotEmpty) {
      for (final id in orderedWindowWordIds) {
        if (id < toneFloor) {
          continue;
        }
        if (id < input.currentWordNumberAll) {
          continue;
        }
        if (id > furthestMatchedInAyah) {
          break;
        }
        if (matchedInRange.contains(id)) {
          continue;
        }
        if (!isSuccessTone(nextTones[id])) {
          nextTones[id] = RecitationWordTone.wrong;
        }
      }
    }
    for (final id in mismatched) {
      if (id < toneFloor) {
        continue;
      }
      if (!isSuccessTone(nextTones[id])) {
        nextTones[id] = RecitationWordTone.wrong;
      }
    }
    for (final id in matchedInRange) {
      final eq = eqByWord[id] ?? _TokenEquivalence.strict;
      nextTones[id] = eq == _TokenEquivalence.strict
          ? RecitationWordTone.correct
          : RecitationWordTone.softCorrect;
    }
    if (hadRevealedWordsBefore) {
      for (final id in orderedWindowWordIds) {
        if (id < toneFloor) {
          continue;
        }
        if (id < nextPointer && !nextTones.containsKey(id)) {
          nextTones[id] = RecitationWordTone.wrong;
        }
      }
    }
    nextTones.removeWhere((k, _) => k < toneFloor);

    final relaxId = input.pointerBefore;
    if (relaxId >= toneFloor &&
        nextTones[relaxId] == RecitationWordTone.wrong) {
      final refText = input.referenceTextByWordId[relaxId];
      if (refText != null &&
          recitationLongWordRelaxedAsrMatch(
            referenceWord: refText,
            sliceTokens: input.tokens,
          )) {
        nextTones[relaxId] = RecitationWordTone.softCorrect;
        nextPointer = math.max(nextPointer, relaxId + 1);
      }
    }

    final streakBlocksPointer = hasConsecutiveWrongStreak(
      tones: nextTones,
      orderedWordIds: orderedWordIdsInRange,
      threshold: 3,
    );
    final streakLocksNavigation = streakBlocksPointer && input.isFinal;
    if (streakLocksNavigation) {
      nextPointer = input.pointerBefore;
    }

    final tailWrongBump = recitationPointerBumpAfterAyahTailWrongOnly(
      orderedWordIdsInRange: orderedWordIdsInRange,
      tones: nextTones,
      nextPointer: nextPointer,
      blockedByWrongStreak: streakLocksNavigation,
    );
    if (tailWrongBump != null) {
      nextPointer = tailWrongBump;
    }

    final decision = computeAdvanceDecision(
      orderedWordIds: orderedWordIdsInRange,
      tones: nextTones,
      consecutiveWrongThreshold: input.isFinal ? 3 : 999,
    );

    return RecitationMatchResult(
      revealedWordTones: nextTones,
      nextWordPointer: nextPointer,
      bestMatchScore: bestMatch.score.toDouble(),
      advanceDecision: decision,
    );
  }

  static _AlignmentResult? _findBestAlignment(
    List<String> tokens,
    List<Map<String, Object?>> window, {
    required int currentWordNumberAll,
    required int allowedBacktrackFloor,
    required int ayahWordCount,
  }) {
    if (tokens.isEmpty || window.isEmpty) {
      return null;
    }
    final candidateStarts = <int>[];
    final backtrackWindow = recitationBacktrackWindow(ayahWordCount);
    final forwardWindow =
        recitationForwardLookaheadWindow(ayahWordCount, tokens.length);
    final minWord = math.min(
      allowedBacktrackFloor,
      currentWordNumberAll - backtrackWindow,
    );
    final maxWord = currentWordNumberAll + forwardWindow;
    for (var i = 0; i < window.length; i++) {
      final wordNumberAll = (window[i]['word_number_all'] as int?) ?? 0;
      if (wordNumberAll >= minWord && wordNumberAll <= maxWord) {
        candidateStarts.add(i);
      }
    }
    if (candidateStarts.isEmpty) {
      candidateStarts.add(0);
    }

    _AlignmentResult? best;
    for (final startIndex in candidateStarts) {
      var expectedIndex = startIndex;
      final matched = <int>{};
      final mismatched = <int>{};
      final strengthByWord = <int, _TokenEquivalence>{};
      int? firstMatched;
      int? lastMatched;

      var ti = 0;
      while (ti < tokens.length) {
        final join = _findTokenMatchWithJoin(
          window,
          expectedIndex,
          tokens,
          ti,
        );
        final foundIndex = join.found;
        if (foundIndex == null) {
          if (expectedIndex < window.length) {
            mismatched.add(
              (window[expectedIndex]['word_number_all'] as int?) ?? 0,
            );
          }
          ti += 1;
          continue;
        }

        for (var skipped = expectedIndex; skipped < foundIndex; skipped++) {
          mismatched.add((window[skipped]['word_number_all'] as int?) ?? 0);
        }

        final matchedWordNumber =
            (window[foundIndex]['word_number_all'] as int?) ?? 0;
        matched.add(matchedWordNumber);
        strengthByWord[matchedWordNumber] =
            _maxEquiv(strengthByWord[matchedWordNumber], join.strength);
        firstMatched ??= matchedWordNumber;
        lastMatched = matchedWordNumber;
        expectedIndex = foundIndex + 1;
        ti += join.tokensConsumed;
      }

      final backwardPenalty =
          firstMatched != null && firstMatched < currentWordNumberAll ? 2 : 0;
      final distancePenalty = firstMatched == null
          ? 0
          : (firstMatched - currentWordNumberAll).abs();
      final score = matched.length * 3 -
          mismatched.length -
          backwardPenalty -
          distancePenalty;
      final result = _AlignmentResult(
        score: score,
        matchedWordNumbers: matched,
        mismatchedWordNumbers: mismatched,
        firstMatchedWordNumberAll: firstMatched,
        lastMatchedWordNumberAll: lastMatched,
        wordEquivalence: strengthByWord,
      );

      if (best == null) {
        best = result;
      } else if (result.score > best.score) {
        best = result;
      }
    }

    return best;
  }

  static ({
    int? found,
    int tokensConsumed,
    _TokenEquivalence strength,
  }) _findTokenMatchWithJoin(
    List<Map<String, Object?>> window,
    int expectedIndex,
    List<String> tokens,
    int ti,
  ) {
    ({
      int index,
      _TokenEquivalence strength,
    })? tryToken(String t) {
      if (t.isEmpty) {
        return null;
      }
      return _findTokenRowMatch(window, expectedIndex, t);
    }

    var pair = tryToken(tokens[ti]);
    if (pair != null) {
      return (
        found: pair.index,
        tokensConsumed: 1,
        strength: pair.strength,
      );
    }
    if (ti + 1 < tokens.length) {
      final j2 = (tokens[ti] + tokens[ti + 1]).replaceAll(RegExp(r'\s+'), '');
      pair = tryToken(j2);
      if (pair != null) {
        return (
          found: pair.index,
          tokensConsumed: 2,
          strength: pair.strength,
        );
      }
    }
    if (ti + 2 < tokens.length) {
      final j3 = (tokens[ti] + tokens[ti + 1] + tokens[ti + 2])
          .replaceAll(RegExp(r'\s+'), '');
      pair = tryToken(j3);
      if (pair != null) {
        return (
          found: pair.index,
          tokensConsumed: 3,
          strength: pair.strength,
        );
      }
    }
    return (
      found: null,
      tokensConsumed: 1,
      strength: _TokenEquivalence.none,
    );
  }

  /// First mushaf token row matching [spoken]; null if none in the small lookahead.
  static ({int index, _TokenEquivalence strength})? _findTokenRowMatch(
    List<Map<String, Object?>> words,
    int fromIndex,
    String spoken,
  ) {
    final maxIndex = math.min(words.length - 1, fromIndex + 2);
    for (var index = fromIndex; index <= maxIndex; index++) {
      final e = _equivAcrossExpectedFields(words[index], spoken);
      if (e != _TokenEquivalence.none) {
        return (index: index, strength: e);
      }
    }
    return null;
  }

  static _TokenEquivalence _equivAcrossExpectedFields(
    Map<String, Object?> row,
    String spoken,
  ) {
    const keys = ['search_key', 'display_text', 'normalized_text'];
    var best = _TokenEquivalence.none;
    for (final key in keys) {
      final expected = (row[key] ?? '').toString();
      if (expected.isEmpty) continue;
      final e = _tokenEquivalenceStrength(expected, spoken);
      if (e == _TokenEquivalence.strict) return _TokenEquivalence.strict;
      if (e == _TokenEquivalence.tolerant) best = _TokenEquivalence.tolerant;
    }
    return best;
  }

  static _TokenEquivalence _maxEquiv(
    _TokenEquivalence? prev,
    _TokenEquivalence incoming,
  ) {
    if (prev == null || prev == _TokenEquivalence.none) return incoming;
    if (incoming == _TokenEquivalence.strict ||
        prev == _TokenEquivalence.strict) {
      return _TokenEquivalence.strict;
    }
    return _TokenEquivalence.tolerant;
  }

  static _TokenEquivalence _tokenEquivalenceStrength(
    String expected,
    String spoken,
  ) {
    if (expected.isEmpty || spoken.isEmpty) {
      return _TokenEquivalence.none;
    }
    if (expected == spoken) {
      return _TokenEquivalence.strict;
    }

    final strictExpected = _strictTokenForms(expected);
    final strictSpoken = _strictTokenForms(spoken);
    for (final form in strictExpected) {
      if (strictSpoken.contains(form)) {
        return _TokenEquivalence.strict;
      }
    }

    final expectedForms = ArabicNormalizer.tokenMatchForms(expected);
    final spokenForms = ArabicNormalizer.tokenMatchForms(spoken);

    if (expectedForms.isEmpty || spokenForms.isEmpty) {
      return _TokenEquivalence.none;
    }

    // Anything matched only through broader token forms (weak-letter drops,
    // ASR drifts, etc.) is tolerant, not strict.
    for (final form in expectedForms) {
      if (spokenForms.contains(form)) {
        return _TokenEquivalence.tolerant;
      }
    }

    final expectedWithoutAl = expectedForms
        .map(_stripLeadingAl)
        .where((value) => value.isNotEmpty)
        .toSet();
    final spokenWithoutAl = spokenForms
        .map(_stripLeadingAl)
        .where((value) => value.isNotEmpty)
        .toSet();

    for (final form in expectedWithoutAl) {
      if (spokenWithoutAl.contains(form)) {
        return _TokenEquivalence.tolerant;
      }
    }

    for (final expectedForm in expectedWithoutAl) {
      for (final spokenForm in spokenWithoutAl) {
        if (_isNearTokenMatch(expectedForm, spokenForm)) {
          return _TokenEquivalence.tolerant;
        }
      }
    }

    return _TokenEquivalence.none;
  }

  static Set<String> _strictTokenForms(String token) {
    final forms = <String>{};
    void add(String value) {
      final compact = value.replaceAll(RegExp(r'\s+'), '').trim();
      if (compact.isNotEmpty) {
        forms.add(compact);
      }
    }

    add(token);
    add(ArabicNormalizer.normalizeBasic(token));
    add(ArabicNormalizer.normalizeForSearch(token));
    return forms;
  }

  static String _stripLeadingAl(String token) {
    if (token.startsWith('ال') && token.length > 2) {
      return token.substring(2);
    }
    return token;
  }

  static bool _isNearTokenMatch(String expected, String spoken) {
    if (expected == spoken) {
      return true;
    }
    final minL = math.min(expected.length, spoken.length);
    if (minL < 3) {
      return false;
    }
    final long = minL >= 7;
    final maxLenDiff = long ? 2 : 1;
    if ((expected.length - spoken.length).abs() > maxLenDiff) {
      return false;
    }
    if (!long) {
      if (expected.codeUnitAt(0) != spoken.codeUnitAt(0)) {
        return false;
      }
      return _levenshteinDistance(expected, spoken) <= 1;
    }
    if (expected.codeUnitAt(0) == spoken.codeUnitAt(0) &&
        _levenshteinDistance(expected, spoken) <= 2) {
      return true;
    }
    final a = ArabicNormalizer.normalizeForSearch(expected);
    final b = ArabicNormalizer.normalizeForSearch(spoken);
    if (a.isEmpty || b.isEmpty) {
      return false;
    }
    return fuzzyRasmSimilarity(a, b) >= 0.62;
  }

  static int _levenshteinDistance(String a, String b) {
    final n = a.length;
    final m = b.length;
    if (n == 0) {
      return m;
    }
    if (m == 0) {
      return n;
    }

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
}
