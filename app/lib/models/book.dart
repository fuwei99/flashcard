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
library;

import 'deck.dart';

/// 一章 = 一个文件夹
class Chapter {
  final String chapterId;
  final String title;
  final List<FlashCard> cards;

  Chapter({
    required this.chapterId,
    required this.title,
    required this.cards,
  });

  factory Chapter.fromJson(Map<String, dynamic> j, String templateId) {
    final cards = (j['cards'] as List? ?? [])
        .map((e) => FlashCard.fromJson(Map<String, dynamic>.from(e as Map), templateId))
        .toList();
    return Chapter(
      chapterId: (j['chapter_id'] ?? j['title'] ?? 'ch').toString(),
      title: (j['title'] ?? '未命名章节').toString(),
      cards: cards,
    );
  }

  Map<String, dynamic> toJson() => {
        'chapter_id': chapterId,
        'title': title,
        'cards': cards.map((c) => c.toJson()).toList(),
      };
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

  Book({
    required this.bookId,
    required this.title,
    this.subtitle = '',
    required this.templateId,
    required this.fieldsOrder,
    required this.chapters,
    required this.looseCards,
  });

  bool get hasChapters => chapters.isNotEmpty;

  /// 全书的卡片（扁平）
  List<FlashCard> get allCards =>
      hasChapters ? chapters.expand((c) => c.cards).toList() : looseCards;

  int get totalPages => allCards.length;

  factory Book.fromJson(Map<String, dynamic> j) {
    final tplId = (j['template'] ?? 'bubei_dark').toString();
    final order = (j['fields_order'] as List?)?.cast<String>() ?? const <String>[];

    final chapters = (j['chapters'] as List? ?? [])
        .map((e) => Chapter.fromJson(Map<String, dynamic>.from(e as Map), tplId))
        .toList();

    // 兼容无章节的写法：顶层直接 cards
    final loose = (j['cards'] as List? ?? [])
        .map((e) => FlashCard.fromJson(Map<String, dynamic>.from(e as Map), tplId))
        .toList();

    return Book(
      bookId: (j['book_id'] ?? j['deck_id'] ?? 'book').toString(),
      title: (j['title'] ?? j['name'] ?? '未命名书本').toString(),
      subtitle: (j['subtitle'] ?? '').toString(),
      templateId: tplId,
      fieldsOrder: order,
      chapters: chapters,
      looseCards: loose,
    );
  }

  Map<String, dynamic> toJson() => {
        'book_id': bookId,
        'title': title,
        'subtitle': subtitle,
        'template': templateId,
        'fields_order': fieldsOrder,
        if (chapters.isNotEmpty)
          'chapters': chapters.map((c) => c.toJson()).toList(),
        if (looseCards.isNotEmpty)
          'cards': looseCards.map((c) => c.toJson()).toList(),
      };
}
