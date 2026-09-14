/// 书 / 章 / 页 三级模型
/// ================================================================
/// 一本「书」= 一个卡组文件。书里可以带「章」，也可以不带。
/// 每张卡 = 书的一页，有自己的标题（单词卡就用单词当标题）。
///
///   书（Book）
///    ├── 章（Chapter）─ 页（FlashCard）
///    └── 章（Chapter）─ 页（FlashCard）
///
/// 或者没有章，直接：
///   书（Book）─ 页（FlashCard）× N
///
/// 语篇（Passage）挂在「章」上（无章时挂书上）：一章开头放一篇短文，
/// 尽量短，但包含本章所有目标词。通读辅助记忆 + 语篇选词都用它。
library;

import 'deck.dart';

/// 语篇里的一段：要么是普通文本，要么是一个目标词。
class PassageSegment {
  /// 普通文本（与 surface 二选一）
  final String? text;

  /// 目标词在文中的表面形式（下划线显示 / 填空答案）
  final String? surface;

  /// 目标词对应的卡片 word（查释义、对词库）
  final String? lemma;

  const PassageSegment.text(this.text)
      : surface = null,
        lemma = null;

  const PassageSegment.word(this.surface, this.lemma) : text = null;

  bool get isWord => surface != null;
}

/// 一章开头的一篇文章，尽量短，但包含本章所有目标词。
///
/// 标记语法（写在 [text] 里，牌组作者 / Agent 只需要维护这一个字段）：
///   [word]            目标词；填空答案 = word
///   [surface|lemma]   surface 是文中实际形式（如 prevailed），
///                     lemma 是卡片 word（如 prevail），用于查释义、对词库
///
/// 例：
///   "The [intensive] course kept him busy, and his notes were [obscure]."
class Passage {
  final String title;
  final String text;
  final String cn;
  final List<PassageSegment> segments;

  Passage({
    this.title = '',
    required this.text,
    this.cn = '',
    List<PassageSegment>? segments,
  }) : segments = segments ?? parse(text);

  bool get hasContent => text.trim().isNotEmpty;

  /// 文中的目标词（按出现顺序，可能重复）
  List<PassageSegment> get words => segments.where((s) => s.isWord).toList();

  static final RegExp _marker = RegExp(r'\[([^\]|]+)(?:\|([^\]]+))?\]');

  /// 解析 [word] / [surface|lemma] 标记
  static List<PassageSegment> parse(String raw) {
    final out = <PassageSegment>[];
    var last = 0;
    for (final m in _marker.allMatches(raw)) {
      if (m.start > last) {
        out.add(PassageSegment.text(raw.substring(last, m.start)));
      }
      final surface = m.group(1)!.trim();
      final lemma = (m.group(2) ?? m.group(1))!.trim();
      out.add(PassageSegment.word(surface, lemma));
      last = m.end;
    }
    if (last < raw.length) out.add(PassageSegment.text(raw.substring(last)));
    return out;
  }

  factory Passage.fromJson(Map<String, dynamic> j) {
    final text = (j['text'] ?? j['content'] ?? '').toString();
    return Passage(
      title: (j['title'] ?? '').toString(),
      text: text,
      cn: (j['cn'] ?? j['translation'] ?? '').toString(),
    );
  }

  Map<String, dynamic> toJson() => {
        if (title.isNotEmpty) 'title': title,
        'text': text,
        if (cn.isNotEmpty) 'cn': cn,
      };
}

/// 一章 = 一个文件夹
class Chapter {
  final String chapterId;
  final String title;
  final List<FlashCard> cards;

  /// 本章语篇（可空 —— 老卡组没写就跳过语篇两阶段）
  final Passage? passage;

  Chapter({
    required this.chapterId,
    required this.title,
    required this.cards,
    this.passage,
  });

  factory Chapter.fromJson(Map<String, dynamic> j, String templateId) {
    final cards = (j['cards'] as List? ?? [])
        .map((e) =>
            FlashCard.fromJson(Map<String, dynamic>.from(e as Map), templateId))
        .toList();
    return Chapter(
      chapterId: (j['chapter_id'] ?? j['title'] ?? 'ch').toString(),
      title: (j['title'] ?? '未命名章节').toString(),
      cards: cards,
      passage: _passageFrom(j['passage']),
    );
  }

  Map<String, dynamic> toJson() => {
        'chapter_id': chapterId,
        'title': title,
        if (passage != null) 'passage': passage!.toJson(),
        'cards': cards.map((c) => c.toJson()).toList(),
      };
}

/// 兼容三种写法：对象 {"text":...} / 纯字符串 / 空
Passage? _passageFrom(dynamic raw) {
  if (raw is Map) {
    final p = Passage.fromJson(Map<String, dynamic>.from(raw));
    return p.hasContent ? p : null;
  }
  if (raw is String && raw.trim().isNotEmpty) {
    final p = Passage.fromJson({'text': raw});
    return p.hasContent ? p : null;
  }
  return null;
}

/// 一本书
class Book {
  final String bookId;
  final String title;
  final String subtitle;
  final String templateId;
  final List<String> fieldsOrder;

  /// 有章节时用这个
  final List<Chapter> chapters;

  /// 没章节时，卡片直接挂书上
  final List<FlashCard> looseCards;

  /// 整本书兜底语篇（无章节时用；有章节时各章自己的优先）
  final Passage? passage;

  Book({
    required this.bookId,
    required this.title,
    this.subtitle = '',
    required this.templateId,
    required this.fieldsOrder,
    required this.chapters,
    required this.looseCards,
    this.passage,
  });

  bool get hasChapters => chapters.isNotEmpty;

  /// 全书的卡片（扁平）
  List<FlashCard> get allCards =>
      hasChapters ? chapters.expand((c) => c.cards).toList() : looseCards;

  int get totalPages => allCards.length;

  factory Book.fromJson(Map<String, dynamic> j) {
    final tplId = (j['template'] ?? 'bubei_dark').toString();
    final order =
        (j['fields_order'] as List?)?.cast<String>() ?? const <String>[];

    final chapters = (j['chapters'] as List? ?? [])
        .map((e) => Chapter.fromJson(Map<String, dynamic>.from(e as Map), tplId))
        .toList();

    // 兼容无章节的写法：顶层直接 cards
    final loose = (j['cards'] as List? ?? [])
        .map((e) =>
            FlashCard.fromJson(Map<String, dynamic>.from(e as Map), tplId))
        .toList();

    return Book(
      bookId: (j['book_id'] ?? j['deck_id'] ?? 'book').toString(),
      title: (j['title'] ?? j['name'] ?? '未命名书本').toString(),
      subtitle: (j['subtitle'] ?? '').toString(),
      templateId: tplId,
      fieldsOrder: order,
      chapters: chapters,
      looseCards: loose,
      passage: _passageFrom(j['passage']),
    );
  }

  Map<String, dynamic> toJson() => {
        'book_id': bookId,
        'title': title,
        'subtitle': subtitle,
        'template': templateId,
        'fields_order': fieldsOrder,
        if (passage != null) 'passage': passage!.toJson(),
        if (chapters.isNotEmpty)
          'chapters': chapters.map((c) => c.toJson()).toList(),
        if (looseCards.isNotEmpty)
          'cards': looseCards.map((c) => c.toJson()).toList(),
      };
}
