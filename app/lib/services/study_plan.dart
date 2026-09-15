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
/// ## 懒加载（v0.7.0）
/// 判断「这一章有没有今天到期 / 有没有新词」只用 [Chapter.ids]（来自
/// index.json），**不读章节文件**。只有真有到期/新词的那几章，才会把
/// ch_xxxx.json 读进来。所以 6500 词的书，开背时也只载入当天要用的那几章。
library;

import '../models/book.dart';
import '../models/deck.dart';
import '../models/study_session.dart';
import 'card_store.dart';

/// 一组 = 背多少个词停一下（只影响 UI 暂停节奏，不影响编排）
const int kGroupSize = 20;

/// 一个分组 = 一章（或一本没有章节的书）
class _Group {
  final Chapter? chapter;
  final Passage? passage;
  final List<FlashCard> inlineCards;
  final String title;

  const _Group(this.chapter, this.passage, this.inlineCards, this.title);

  /// **不触发载入**的卡片 id
  List<String> get ids =>
      chapter != null ? chapter!.ids : [for (final c in inlineCards) c.id];

  /// 真正要卡片时才读盘
  List<FlashCard> get cards =>
      chapter != null ? chapter!.cards : inlineCards;
}

/// 全局排序用的「到期引用」：一张到期卡 + 它属于哪个分组
class _DueRef {
  final DateTime? due;
  final _Group group;
  final String cardId;
  const _DueRef(this.due, this.group, this.cardId);
}

class StudyPlanner {
  static List<_Group> _groups(Book b) {
    if (b.hasChapters) {
      return [
        for (final c in b.chapters) _Group(c, c.passage, const [], c.title),
      ];
    }
    return [_Group(null, b.passage, b.looseCards, b.title)];
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

  /// 一批卡里「出现在语篇中的」lemma —— 语篇填空只挖这些空。
  ///
  /// 关键：传进来的 [cards] 决定挖哪些空。已经背过的词不要传进来，
  /// 这样它们在语篇里只作划线词展示（blank=false），不挖空、不进词库；
  /// 语篇通读页本来就不看 blank，照样整篇划线。
  static Set<String> blankLemmasFor(List<FlashCard> cards, Passage? p) =>
      cards.map(_lemmaOf).toSet().intersection(_passageLemmas(p));

  /// 复习段：书 → 章，一章一个单元，语篇只挖该章今天到期的词。
  ///
  /// [limit] = 今日复习上限（null/<=0 = 不限）。**全局**排序后截断：
  /// 先按到期时间升序把所有到期词排一遍，取前 limit 个，再按书→章原顺序
  /// 重新分组。没被取到的卡 due 不变，明天照旧在队列里 —— 天然顺延。
  static List<StudyUnit> reviewUnits(List<Book> books, CardStore store,
      {int? limit}) {
    // 一次生成、全程复用同一批 _Group 实例（下面拿它当 Map key，靠 identity）
    final groups = <_Group>[];
    for (final b in books) {
      groups.addAll(_groups(b));
    }

    // ① 先只用 id 问「这章有到期的吗」—— 不读章节文件
    final refs = <_DueRef>[];
    for (final g in groups) {
      final ids = g.ids;
      if (ids.isEmpty) continue;
      for (final id in store.reviewDue(ids)) {
        refs.add(_DueRef(store.stateOf(id).due, g, id));
      }
    }
    if (refs.isEmpty) return const [];

    // ② 全局按到期时间升序：最该复习的排前面
    refs.sort((a, b) {
      final da = a.due;
      final db = b.due;
      if (da == null && db == null) return 0;
      if (da == null) return -1;
      if (db == null) return 1;
      return da.compareTo(db);
    });

    // ③ 全局截断：超出的今天不背，明天还在队列里
    final chosen =
        (limit == null || limit <= 0) ? refs : refs.take(limit).toList();

    // ④ 按书→章原顺序重新分组（同一章的词仍然连续背）
    final byGroup = <_Group, List<String>>{};
    for (final r in chosen) {
      (byGroup[r.group] ??= <String>[]).add(r.cardId);
    }

    final out = <StudyUnit>[];
    for (final g in groups) {
      final picked = byGroup[g];
      if (picked == null || picked.isEmpty) continue;

      // 到这一步才真读盘
      final cards = g.cards;
      if (cards.isEmpty) continue;

      final idSet = picked.toSet();
      final due = cards.where((c) => idSet.contains(c.id)).toList()
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
    return out;
  }

  /// 新学段：书 → 章，语篇通读 + 全挖 + 学本章新词
  static List<StudyUnit> newUnits(List<Book> books, CardStore store) {
    final out = <StudyUnit>[];
    for (final b in books) {
      for (final g in _groups(b)) {
        // 同样先只用 id 判断，没新词就不读盘。
        // 学过的、以及手动标熟的，都不再进新学队列。
        final freshIds = g.ids
            .where((id) => !store.isLearned(id) && !store.isKnown(id))
            .toSet();
        if (freshIds.isEmpty) continue;

        final fresh = g.cards.where((c) => freshIds.contains(c.id)).toList();
        if (fresh.isEmpty) continue;

        // 语篇只挖「本章还没背过的词」：背过的只划线展示、不挖空。
        // 否则背到一半退出去再进来，已经背过的词又得重填一遍。
        final hasPassage = g.passage != null && g.passage!.hasContent;
        final blanks = blankLemmasFor(fresh, g.passage);

        out.add(StudyUnit(
          passage: hasPassage ? g.passage : null,
          cards: fresh,
          blankLemmas: hasPassage ? blanks : null,
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
  /// [reviewLimit] 只作用于复习段（每日复习上限，null/<=0 = 不限）
  static List<StudyUnit> wordPlan({
    required List<Book> books,
    required CardStore store,
    required bool withReview,
    required bool withNew,
    int? reviewLimit,
  }) {
    return [
      if (withReview) ...reviewUnits(books, store, limit: reviewLimit),
      if (withNew) ...newUnits(books, store),
    ];
  }

  /// 单章 / 单本书的计划 —— 书内「顺序 / 乱序背诵」入口用
  static StudyUnit singleUnit({
    Passage? passage,
    required List<FlashCard> cards,
    List<FlashCard>? passageCards,
    Set<String>? blankLemmas,
    bool readFirst = false,
    bool isReview = false,
    String title = '',
  }) {
    return StudyUnit(
      passage: passage,
      cards: cards,
      blankLemmas: blankLemmas,
      readFirst: readFirst,
      isReview: isReview,
      passageCards: passageCards,
      title: title,
    );
  }
}
