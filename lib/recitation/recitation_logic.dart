import 'dart:math' as math;

import 'package:quran_app/recitation/arabic_normalizer.dart';

enum RecitationWordTone { correct, acceptable, softCorrect, wrong }

class RecitationAdvanceDecision {
  const RecitationAdvanceDecision({
    required this.shouldAdvance,
    required this.reason,
    required this.unresolvedWords,
    required this.hasBlockingStreak,
  });

  final bool shouldAdvance;
  final String reason;
  final int unresolvedWords;
  final bool hasBlockingStreak;
}

class IncrementalTranscriptSlice {
  const IncrementalTranscriptSlice({
    required this.tokens,
    required this.nextBaseline,
  });

  final List<String> tokens;
  final String nextBaseline;
}

int recitationTranscriptTokenWindow(int ayahWordCount) {
  return math.max(ayahWordCount + 8, 18);
}

int recitationBacktrackWindow(int ayahWordCount) {
  // Dynamic backtrack: short ayahs keep a modest window, longer ayahs allow
  // wider re-reading so users can restart from the beginning mid-ayah.
  // Keep an upper cap to avoid overly large search spans.
  final dynamicWindow = ayahWordCount + 6;
  return math.max(15, math.min(dynamicWindow, 48));
}

int recitationForwardLookaheadWindow(int ayahWordCount, int tokenCount) {
  return math.max(tokenCount + 12, ayahWordCount + 6);
}

/// After prefix alignment, [sliceIncrementalTranscript] may start at a large
/// [start] (stable ASR + change only at the end). Then `sublist(start)` **drops
/// the beginning of the current utterance**, and the user cannot re-fix the
/// first words without resetting baseline (e.g. by navigating). When [start] is
/// large, we **always include** a short head of the full [normalizedTranscript]
/// so the matcher can still see early ayah words.
const int kIncrementalSliceAnchorTokenHead = 12;

IncrementalTranscriptSlice sliceIncrementalTranscript({
  required String normalizedTranscript,
  required String previousBaseline,
  int rewindTokens = 4,
  int maxTokens = 32,
}) {
  List<String> splitTokens(String text) => text
      .split(' ')
      .map((token) => token.trim())
      .where((token) => token.isNotEmpty)
      .toList(growable: false);

  final currentTokens = splitTokens(normalizedTranscript);
  final previousTokens = splitTokens(previousBaseline);
  if (currentTokens.isEmpty) {
    return const IncrementalTranscriptSlice(tokens: [], nextBaseline: '');
  }

  var prefix = 0;
  final prefixLimit = math.min(currentTokens.length, previousTokens.length);
  while (
      prefix < prefixLimit && currentTokens[prefix] == previousTokens[prefix]) {
    prefix += 1;
  }

  var start = math.max(0, prefix - rewindTokens);
  if (start >= currentTokens.length) {
    start = math.max(0, currentTokens.length - rewindTokens);
  }

  // Keep tail segment from [start] unless we need to re-attach a head
  // (divergence far into the line — original head must stay visible to ASR).
  var tokens = start > kIncrementalSliceAnchorTokenHead
      ? <String>[
          ...currentTokens.sublist(0, kIncrementalSliceAnchorTokenHead),
          ...currentTokens.sublist(start),
        ]
      : currentTokens.sublist(start);

  if (tokens.length > maxTokens) {
    tokens = tokens.sublist(0, maxTokens);
  }
  return IncrementalTranscriptSlice(
    tokens: tokens,
    nextBaseline: normalizedTranscript,
  );
}

/// Maximal runs of consecutive [RecitationWordTone.wrong] along [orderedWordIds].
List<List<int>> recitationMaximalWrongRuns({
  required List<int> orderedWordIds,
  required Map<int, RecitationWordTone> tones,
}) {
  final runs = <List<int>>[];
  List<int>? cur;
  for (final id in orderedWordIds) {
    if (tones[id] == RecitationWordTone.wrong) {
      cur ??= <int>[];
      cur.add(id);
    } else {
      if (cur != null) {
        runs.add(cur);
        cur = null;
      }
    }
  }
  if (cur != null) {
    runs.add(cur);
  }
  return runs;
}

/// Rules for when [RecitationWordTone.wrong] should paint red in the mushaf:
/// - Any run longer than 3: only the first 3 wrongs in that run may show red.
/// - [ayahStartStaggerOrder]: first 3 ids when the run starts at the ayah’s first
///   word and has length ≥3; host shows those reds only after stagger timers.
class RecitationWrongRedDisplayPolicy {
  const RecitationWrongRedDisplayPolicy({
    required this.suppressWrongRed,
    required this.ayahStartStaggerOrder,
  });

  final Set<int> suppressWrongRed;
  final List<int> ayahStartStaggerOrder;
}

RecitationWrongRedDisplayPolicy recitationWrongRedDisplayPolicy({
  required List<int> orderedWordIdsInRange,
  required Map<int, RecitationWordTone> tones,
  required int firstSpokenWordIdInAyah,
}) {
  final runs = recitationMaximalWrongRuns(
    orderedWordIds: orderedWordIdsInRange,
    tones: tones,
  );
  final suppress = <int>{};
  var staggerOrder = const <int>[];

  for (final run in runs) {
    if (run.length > 3) {
      suppress.addAll(run.sublist(3));
    }
    if (run.isEmpty) continue;
    if (run.first == firstSpokenWordIdInAyah) {
      if (run.length >= 3 && staggerOrder.isEmpty) {
        staggerOrder = run.sublist(0, 3);
      }
    }
  }

  return RecitationWrongRedDisplayPolicy(
    suppressWrongRed: suppress,
    ayahStartStaggerOrder: staggerOrder,
  );
}

bool hasConsecutiveWrongStreak({
  required Map<int, RecitationWordTone> tones,
  required List<int> orderedWordIds,
  required int threshold,
}) {
  if (threshold <= 1 || orderedWordIds.isEmpty) return false;
  var streak = 0;
  for (final id in orderedWordIds) {
    final tone = tones[id];
    if (tone == RecitationWordTone.wrong) {
      streak += 1;
      if (streak >= threshold) {
        return true;
      }
    } else if (tone == RecitationWordTone.correct ||
        tone == RecitationWordTone.acceptable ||
        tone == RecitationWordTone.softCorrect) {
      streak = 0;
    } else {
      // No tone yet: do not let a wrong streak span "gaps" of unevaluated
      // words (common at the start of an ayah — one red, rest unrevealed).
      streak = 0;
    }
  }
  return false;
}

/// When the matcher never adds the ayah's last word to the matched set (it may
/// only appear as mismatched), the furthest match stays before the tail and the
/// read pointer may never cross the ayah end. If every word in range already has
/// a tone and only the final word is [wrong], return `lastId + 1` so the host
/// can sync to the next ayah.
int? recitationPointerBumpAfterAyahTailWrongOnly({
  required List<int> orderedWordIdsInRange,
  required Map<int, RecitationWordTone> tones,
  required int nextPointer,
  required bool blockedByWrongStreak,
}) {
  if (blockedByWrongStreak || orderedWordIdsInRange.isEmpty) return null;
  final lastId = orderedWordIdsInRange.last;
  if (nextPointer > lastId) return null;
  if (tones[lastId] != RecitationWordTone.wrong) return null;
  for (final id in orderedWordIdsInRange) {
    if (id >= lastId) break;
    final t = tones[id];
    if (t != RecitationWordTone.correct &&
        t != RecitationWordTone.acceptable &&
        t != RecitationWordTone.softCorrect) {
      return null;
    }
  }
  return lastId + 1;
}

RecitationAdvanceDecision computeAdvanceDecision({
  required List<int> orderedWordIds,
  required Map<int, RecitationWordTone> tones,
  required int consecutiveWrongThreshold,
}) {
  if (orderedWordIds.isEmpty) {
    return const RecitationAdvanceDecision(
      shouldAdvance: false,
      reason: 'no_words',
      unresolvedWords: 0,
      hasBlockingStreak: false,
    );
  }

  bool isUnresolvedForAdvance(int id) {
    final tone = tones[id];
    if (tone == null) return true;
    return false;
  }

  final unresolvedWords =
      orderedWordIds.where((id) => isUnresolvedForAdvance(id)).length;
  final blocking = hasConsecutiveWrongStreak(
    tones: tones,
    orderedWordIds: orderedWordIds,
    threshold: consecutiveWrongThreshold,
  );

  if (blocking) {
    return RecitationAdvanceDecision(
      shouldAdvance: false,
      reason: 'blocked_3_wrong',
      unresolvedWords: unresolvedWords,
      hasBlockingStreak: true,
    );
  }
  if (unresolvedWords > 0) {
    return RecitationAdvanceDecision(
      shouldAdvance: false,
      reason: 'unresolved_words',
      unresolvedWords: unresolvedWords,
      hasBlockingStreak: false,
    );
  }

  return const RecitationAdvanceDecision(
    shouldAdvance: true,
    reason: 'ready',
    unresolvedWords: 0,
    hasBlockingStreak: false,
  );
}

/// [compactRef] runes must appear in order within [compactCandidate]; extra
/// runes in the candidate are ignored (ASR splits / insertions).
bool recitationOrderedSubsequenceMatch(
  String compactRef,
  String compactCandidate,
) {
  if (compactRef.isEmpty || compactCandidate.isEmpty) return false;
  final refR = compactRef.runes.toList();
  final candR = compactCandidate.runes.toList();
  if (refR.length < 7) return false;
  var ri = 0;
  for (final c in candR) {
    if (ri < refR.length && c == refR[ri]) {
      ri++;
    }
  }
  return ri == refR.length;
}

bool _relaxedCandidateLengthOk(String compactRef, String compactCandidate) {
  final rl = compactRef.runes.length;
  final cl = compactCandidate.runes.length;
  if (cl < rl) return false;
  return cl <= rl * 2 + 6;
}

/// Long mushaf words (≥7 letters after normalization): if strict alignment
/// fails, accept ASR that matches the reference as an ordered subsequence
/// using **one** slice token or **two adjacent** tokens concatenated.
bool recitationLongWordRelaxedAsrMatch({
  required String referenceWord,
  required List<String> sliceTokens,
}) {
  final ref = ArabicNormalizer.normalizeForSearch(referenceWord)
      .replaceAll(RegExp(r'\s+'), '');
  if (ref.runes.length < 7) return false;

  for (var i = 0; i < sliceTokens.length; i++) {
    final t1 = ArabicNormalizer.normalizeForSearch(sliceTokens[i])
        .replaceAll(RegExp(r'\s+'), '');
    if (t1.isEmpty) continue;
    if (_relaxedCandidateLengthOk(ref, t1) &&
        recitationOrderedSubsequenceMatch(ref, t1)) {
      return true;
    }
    if (i + 1 < sliceTokens.length) {
      final t2 = ArabicNormalizer.normalizeForSearch(sliceTokens[i + 1])
          .replaceAll(RegExp(r'\s+'), '');
      final merged = t1 + t2;
      if (merged.isNotEmpty &&
          _relaxedCandidateLengthOk(ref, merged) &&
          recitationOrderedSubsequenceMatch(ref, merged)) {
        return true;
      }
    }
  }
  return false;
}
