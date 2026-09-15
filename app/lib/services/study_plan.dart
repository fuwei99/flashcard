/// 学习计划编排
/// ================================================================
/// 入口是「一次开始，把今天所有到期词走完」，但会话内部**严格按
/// 书 → 章 的顺序、一个牌组一个牌组地推进**，每一章用它**自己的语篇**，
/// 所以「今天到期的词」一定落在它所属的那一篇里，语篇与词的对应关系不会乱：
///
///   复习段（按 书 → 章 顺序）
///     第 1 章有语篇 -> 语篇选词（只挖这 20 个到期词）+ 这 20 个到期词
///     第 1 章没语篇 -> 直接 20 个到期词
///     第 2 章 …（依次）
///   新学段（按 书 → 章 顺序）
///     每章 -> 语篇通读 + 语篇选词（挖全章目标词）+ 本章未学词
///
/// 顺序即「AB语篇 + AB词 + CD语篇 + CD词 + … + 新学语篇 + 新学词」。
library;

import '../models/book.dart';
import '../models/deck.dart';
import '../models/study_session.dart';
import 'card_store.dart';

/// 复习批大小：20 词一批
const int kReviewBatch = 20;

/// 一个分组 = 一章（或一本无章节的书）
class _Group {
  final Passage? passage;
  final List<FlashCard> cards;

  /// 展示用名字：章名，或（无章节时）书名
  final String title;

  const _Group(this.passage, this.cards, this.title);
}

class StudyPlanner {
  static List<_Group> _groups(Book b) {
    if (b.hasChapters) {
      return b.chapters
          .map((c) => _Group(c.passage, c.cards, c.title))
          .toList();
    }
    return [_Group(b.passage, b.looseCards, b.title)];
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

  /// 复习段：按 书 → 章，一章一章来，语篇只挖这批要复习的词
  static List<StudyUnit> reviewUnits(List<Book> books, CardStore store) {
    final out = <StudyUnit>[];
    for (final b in books) {
      for (final g in _groups(b)) {
        final cards = g.cards;
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
              ? lemmas.intersection(_passageLemmas(g.passage))
              : const <String>{};
          final withPassage = first && blanks.isNotEmpty;
          out.add(StudyUnit(
            passage: withPassage ? g.passage : null,
            cards: chunks[i],
            blankLemmas: withPassage ? blanks : null,
            readFirst: false,
            isReview: true,
            passageCards: cards,
            title: g.title,
          ));
        }
      }
    }
    return out;
  }

  /// 新学段：按 书 → 章，语篇通读 + 全挖 + 学新词
  static List<StudyUnit> newUnits(List<Book> books, CardStore store) {
    final out = <StudyUnit>[];
    for (final b in books) {
      for (final g in _groups(b)) {
        final fresh = g.cards.where((c) => !store.isLearned(c.id)).toList();
        if (fresh.isEmpty) continue;
        out.add(StudyUnit(
          passage: g.passage,
          cards: fresh,
          blankLemmas: null,
          readFirst: true,
          isReview: false,
          passageCards: g.cards,
          title: g.title,
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

  /// 单章 / 单本书的计划 —— 书内「顺序 / 乱序背诵」入口用
  static StudyUnit singleUnit({
    Passage? passage,
    required List<FlashCard> cards,
    List<FlashCard>? passageCards,
    bool readFirst = false,
    bool isReview = false,
    String title = '',
  }) {
    return StudyUnit(
      passage: passage,
      cards: cards,
      readFirst: readFirst,
      isReview: isReview,
      passageCards: passageCards,
      title: title,
    );
  }
}
