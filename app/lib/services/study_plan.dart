/// 学习计划编排（跨牌组）
/// ================================================================
/// 单词复习不再一个牌组一个牌组地来 —— 所有单词书合到一起排：
///
///   复习段（按章遍历，章内有到期词就成组）
///     该章有语篇 -> 语篇选词（只挖这 20 个到期词）+ 这 20 个到期词
///     该章没语篇 -> 直接 20 个到期词
///     一章到期词 > 20 -> 拆批；只有第一批挂语篇
///   新学段（按章遍历）
///     该章有语篇 -> 语篇通读 + 语篇选词（挖全章目标词）+ 本章未学词
///     该章没语篇 -> 直接本章未学词
///
/// 顺序即「AB语篇 + AB词 + CD语篇 + CD词 + … + 新学语篇 + 新学词」。
library;

import '../models/book.dart';
import '../models/deck.dart';
import '../models/study_session.dart';
import 'card_store.dart';

/// 复习批大小：20 词一批
const int kReviewBatch = 20;

class StudyPlanner {
  /// 一章（或一本无章节的书）= 一个分组
  static List<MapEntry<Passage?, List<FlashCard>>> _groups(Book b) {
    if (b.hasChapters) {
      return b.chapters.map((c) => MapEntry(c.passage, c.cards)).toList();
    }
    return [MapEntry(b.passage, b.looseCards)];
  }

  static List<List<T>> _chunk<T>(List<T> src, int size) {
    final out = <List<T>>[];
    if (size <= 0) {
      out.add(src);
      return out;
    }
    for (var i = 0; i < src.length; i += size) {
      final end = (i + size) > src.length ? src.length : (i + size);
      out.add(src.sublist(i, end));
    }
    return out;
  }

  static String _lemmaOf(FlashCard c) =>
      (c.fields['word'] ?? c.word).toString().trim().toLowerCase();

  /// 语篇里出现的目标词 lemma（小写）
  static Set<String> _passageLemmas(Passage? p) {
    if (p == null) return const <String>{};
    return p.segments
        .where((s) => s.isWord)
        .map((s) => (s.lemma ?? '').trim().toLowerCase())
        .where((s) => s.isNotEmpty)
        .toSet();
  }

  /// 复习段：跨牌组，按章成组，语篇只挖这批要复习的词
  static List<StudyUnit> reviewUnits(List<Book> books, CardStore store) {
    final out = <StudyUnit>[];
    for (final b in books) {
      for (final g in _groups(b)) {
        final cards = g.value;
        if (cards.isEmpty) continue;
        final ids = cards.map((c) => c.id).toList();
        final dueIds = store.reviewDue(ids).toSet();
        if (dueIds.isEmpty) continue;

        final due = cards.where((c) => dueIds.contains(c.id)).toList()
          ..sort((a, b2) {
            final da = store.stateOf(a.id).due;
            final db = store.stateOf(b2.id).due;
            if (da == null && db == null) return 0;
            if (da == null) return -1;
            if (db == null) return 1;
            return da.compareTo(db);
          });

        final chunks = _chunk(due, kReviewBatch);
        for (var i = 0; i < chunks.length; i++) {
          final first = i == 0;
          final lemmas = chunks[i].map(_lemmaOf).toSet();
          // 语篇里只挖「这批要复习、且语篇里确实出现」的词
          final blanks = first
              ? lemmas.intersection(_passageLemmas(g.key))
              : const <String>{};
          final withPassage = first && blanks.isNotEmpty;
          out.add(StudyUnit(
            passage: withPassage ? g.key : null,
            cards: chunks[i],
            blankLemmas: withPassage ? blanks : null,
            readFirst: false,
            isReview: true,
            passageCards: cards,
          ));
        }
      }
    }
    return out;
  }

  /// 新学段：按章，语篇通读 + 全挖 + 学新词
  static List<StudyUnit> newUnits(List<Book> books, CardStore store) {
    final out = <StudyUnit>[];
    for (final b in books) {
      for (final g in _groups(b)) {
        final fresh = g.value.where((c) => !store.isLearned(c.id)).toList();
        if (fresh.isEmpty) continue;
        out.add(StudyUnit(
          passage: g.key,
          cards: fresh,
          blankLemmas: null,
          readFirst: true,
          isReview: false,
          passageCards: g.value,
        ));
      }
    }
    return out;
  }

  /// 单词总计划：复习段 + 新学段
  static List<StudyUnit> wordPlan({
    required List<Book> books,
    required CardStore store,
    required bool withReview,
    required bool withNew,
  }) {
    return [
      if (withReview) ...reviewUnits(books, store),
      if (withNew) ...newUnits(books, store),
    ];
  }

  /// 某本书（或某一章）的单单元计划 —— 书内「顺序/乱序背诵」入口用
  static StudyUnit singleUnit({
    Passage? passage,
    required List<FlashCard> cards,
    List<FlashCard>? passageCards,
    bool readFirst = false,
    bool isReview = false,
  }) {
    return StudyUnit(
      passage: passage,
      cards: cards,
      readFirst: readFirst,
      isReview: isReview,
      passageCards: passageCards,
    );
  }
}
