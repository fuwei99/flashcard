/// 书 / 章 / 页 三级模型
/// ================================================================
/// 一本「书」= 一个卡组。书里可以带「章」，也可以不带。
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
///
/// ## 分片存储（v0.7.0）
/// 大书不再塞进一个 json，而是一章一个文件：
///
///   books/<book_id>/index.json      书元信息 + 章节目录（标题 / 卡片数 / 卡片 id / 语篇）
///   books/<book_id>/ch_0001.json    第 1 章：**只有卡片**
///   books/<book_id>/ch_0002.json    ...
///
/// 好处：
///   1. 启动只读 index.json —— 首页要的「今天到期多少 / 新词多少」靠
///      [Chapter.cardIds] + [Book.allCardIds] 就能算，**一张卡都不用载入**；
///   2. 真要开背了，才按章读 ch_*.json（一章几十~几百 KB，毫秒级）；
///   3. Agent 改第 3 章就开 ch_0003.json，diff 干净，不会误伤别的章。
///
/// 语篇只写在 index.json 里（单一真源，避免两处不一致）；
/// 单文件的老格式仍然支持，读取时自动兼容。
library;

import 'dart:convert';
import 'dart:io';

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

/// 从分片文件里同步读出一章的卡片（首次访问 [Chapter.cards] 时调用）
List<FlashCard> _readChapterCards(String path, String templateId) {
  try {
    final f = File(path);
    if (!f.existsSync()) return const <FlashCard>[];
    final m = json.decode(f.readAsStringSync());
    if (m is! Map) return const <FlashCard>[];
    return [
      for (final e in (m['cards'] as List? ?? []))
        FlashCard.fromJson(Map<String, dynamic>.from(e as Map), templateId),
    ];
  } catch (_) {
    return const <FlashCard>[];
  }
}

/// 一章 = 一个文件
class Chapter {
  final String chapterId;
  final String title;

  /// 本章语篇（可空 —— 老卡组没写就跳过语篇两阶段）
  final Passage? passage;

  /// 索引里声明的卡片数（分片存储时用；不载入卡片就能算总数）
  final int cardCount;

  /// 索引里声明的卡片 id 列表（不载入卡片就能算到期 / 新卡）
  final List<String> cardIds;

  /// 分片文件名（相对书目录）；null / 空 = 卡片已内联在书文件里
  final String? file;

  List<FlashCard>? _cards;
  final List<FlashCard> Function()? _loader;

  Chapter({
    required this.chapterId,
    required this.title,
    List<FlashCard>? cards,
    this.passage,
    this.cardCount = 0,
    this.cardIds = const <String>[],
    this.file,
    List<FlashCard> Function()? loader,
  })  : _cards = cards,
        _loader = loader;

  /// 卡片。分片存储时**首次访问才真正读盘**（同步；单章文件很小，毫秒级）。
  List<FlashCard> get cards => _cards ??= (_loader?.call() ?? <FlashCard>[]);

  /// 已经载入内存了？
  bool get loaded => _cards != null;

  /// 主动载入（不关心返回值时用）
  void ensureLoaded() => cards;

  /// **不触发载入**的卡片数
  int get count {
    final c = _cards;
    if (c != null) return c.length;
    if (cardCount > 0) return cardCount;
    return cardIds.length;
  }

  /// **不触发载入**的卡片 id 列表
  List<String> get ids {
    final c = _cards;
    if (c != null) return [for (final x in c) x.id];
    return cardIds;
  }

  /// 老格式：卡片内联在书文件里
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

  /// 新格式：只读 index.json 里的章节元信息（不含卡片）
  factory Chapter.meta(Map<String, dynamic> j) {
    return Chapter(
      chapterId: (j['chapter_id'] ?? j['title'] ?? 'ch').toString(),
      title: (j['title'] ?? '未命名章节').toString(),
      passage: _passageFrom(j['passage']),
      cardCount: (j['card_count'] as num?)?.toInt() ?? 0,
      cardIds: (j['card_ids'] as List? ?? [])
          .map((e) => e.toString())
          .toList(),
      file: j['file']?.toString(),
    );
  }

  /// index.json 里的章节条目（含语篇，不含卡片）
  Map<String, dynamic> toMetaJson() => {
        'chapter_id': chapterId,
        'title': title,
        if (passage != null) 'passage': passage!.toJson(),
        'file': file ?? '',
        'card_count': count,
        'card_ids': ids,
      };

  /// ch_xxxx.json 的内容（只有卡片；语篇在 index 里）
  Map<String, dynamic> toJson() => {
        'chapter_id': chapterId,
        'title': title,
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

  /// 无章节 + 分片存储时，索引里声明的卡片数 / id
  final int looseCount;
  final List<String> looseIds;

  /// 整本书兜底语篇（无章节时用；有章节时各章自己的优先）
  final Passage? passage;

  /// 分片目录（null = 单文件 / 内置 asset）
  final String? dir;

  Book({
    required this.bookId,
    required this.title,
    this.subtitle = '',
    required this.templateId,
    required this.fieldsOrder,
    required this.chapters,
    required this.looseCards,
    this.looseCount = 0,
    this.looseIds = const <String>[],
    this.passage,
    this.dir,
  });

  bool get hasChapters => chapters.isNotEmpty;

  /// 卡片总数 —— **不触发载入**
  int get totalCards {
    if (hasChapters) return chapters.fold(0, (n, c) => n + c.count);
    if (looseCards.isNotEmpty) return looseCards.length;
    if (looseCount > 0) return looseCount;
    return looseIds.length;
  }

  int get totalPages => totalCards;

  /// 全书卡片 id —— **不触发载入**（首页算到期 / 新词用这个）
  List<String> get allCardIds {
    if (hasChapters) return [for (final c in chapters) ...c.ids];
    if (looseCards.isNotEmpty) return [for (final c in looseCards) c.id];
    return looseIds;
  }

  /// 全书的卡片（会把所有章节读进内存；只在真要背的时候用）
  List<FlashCard> get allCards =>
      hasChapters ? chapters.expand((c) => c.cards).toList() : looseCards;

  /// 老格式：卡片内联
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

  /// 新格式：只读 index.json，章节卡片按需载入
  factory Book.fromIndex(Map<String, dynamic> j, String dir) {
    final tplId = (j['template'] ?? 'bubei_dark').toString();
    final order =
        (j['fields_order'] as List?)?.cast<String>() ?? const <String>[];

    final chapters = <Chapter>[];
    for (final e in (j['chapters'] as List? ?? [])) {
      final meta = Chapter.meta(Map<String, dynamic>.from(e as Map));
      final fname = meta.file;
      chapters.add(Chapter(
        chapterId: meta.chapterId,
        title: meta.title,
        passage: meta.passage,
        cardCount: meta.cardCount,
        cardIds: meta.cardIds,
        file: fname,
        loader: (fname == null || fname.isEmpty)
            ? null
            : () => _readChapterCards('$dir/$fname', tplId),
      ));
    }

    return Book(
      bookId: (j['book_id'] ?? j['deck_id'] ?? 'book').toString(),
      title: (j['title'] ?? j['name'] ?? '未命名书本').toString(),
      subtitle: (j['subtitle'] ?? '').toString(),
      templateId: tplId,
      fieldsOrder: order,
      chapters: chapters,
      looseCards: const <FlashCard>[],
      looseCount: (j['loose_count'] as num?)?.toInt() ?? 0,
      looseIds: (j['loose_ids'] as List? ?? []).map((e) => e.toString()).toList(),
      passage: _passageFrom(j['passage']),
      dir: dir,
    );
  }

  /// 老格式序列化（单文件）
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

  /// 新格式：index.json（不含卡片）
  Map<String, dynamic> toIndexJson() {
    final m = <String, dynamic>{
      'format': 'flashcard.book.v2',
      'book_id': bookId,
      'title': title,
      'subtitle': subtitle,
      'template': templateId,
      'fields_order': fieldsOrder,
    };
    if (passage != null) m['passage'] = passage!.toJson();
    if (hasChapters) {
      m['chapters'] = [for (final c in chapters) c.toMetaJson()];
    } else {
      m['loose_count'] = looseCards.isNotEmpty ? looseCards.length : looseCount;
      m['loose_ids'] = looseCards.isNotEmpty
          ? [for (final c in looseCards) c.id]
          : looseIds;
    }
    return m;
  }
}
