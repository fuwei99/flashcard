/// 学习计划编排
/// ================================================================
/// 复习是**连续**的：从今天的第一个到期词一路背到最后一个，中间只按
/// 每 20 个词停一下（暂停点在 UI 层，不在计划层）。
///
/// 但「语篇 ↔ 词」的对应不能乱，所以计划仍然**严格按 书 → 章 顺序**
/// 一个牌组一个牌组地排，每一章挂它**自己的**语篇：
///
///   复习段（书 → 章）
///     第 1 章（有语篇）→ [语篇选词(只挖该章今天到期的词)] + [该章全部到期词]
///     第 2 章（没语篇）→ [该章全部到期词]
///     第 3 章 …（依次，一路连续背下去）
///   新学段（书 → 章）
///     每章 → [语篇通读] + [语篇选词(挖全章目标词)] + [本章未学词]
///
/// 即「AB语篇 + AB词 + CD语篇 + CD词 + … + 新学语篇 + 新学词」。
library;

import '../models/book.dart';
import '../models/deck.dart';
import '../models/study_session.dart';
import 'card_store.dart';

/// 一组 = 背多少个词停一下（只影响 UI 暂停节奏，不影响编排）
const int kGroupSize = 20;

/// 一个分组 = 一章（或一本没有章节的书）
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

  /// 复习段：书 → 章，一章一个单元，语篇只挖该章今天到期的词。
  /// 一章的到期词**不拆批**，全在这个单元里连续背。
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

        // 语篇只挖「该章今天到期、且语篇里确实出现」的词
        final blanks =
            due.map(_lemmaOf).toSet().intersection(_passageLemmas(g.passage));
        // 一个都没命中就不挂语篇，避免出现 0 空格的空页面
        final withPassage = blanks.isNotEmpty;

        out.add(StudyUnit(
          passage: withPassage ? g.passage : null,
          cards: due,
          blankLemmas: withPassage ? blanks : null,
          readFirst: false,
          isReview: true,
          passageCards: cards,
          title: g.title,
        ));
      }
    }
    return out;
  }

  /// 新学段：书 → 章，语篇通读 + 全挖 + 学本章新词
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
