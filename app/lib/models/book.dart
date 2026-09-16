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
/// ## 分片存储（v0.8.4）
/// 大书不再塞进一个 json，而是一章一个文件：
///
///   books/<book_id>/index.json      书元信息（书级字段，**不含章节列表**）
///   books/<book_id>/ch_0001.json    第 1 章：标题 / 语篇 / 卡片
///   books/<book_id>/ch_0002.json    ...
///
/// 章节的**唯一真源是目录里的 ch_*.json**：
///   1. 加一章 = 丢一个 ch_xxxx.json 进去，不用改 index.json；
///   2. 删一章 = 删文件；
///   3. Agent 改第 3 章只动 ch_0003.json，diff 干净。
///
/// index.json 里的老 `chapters` 数组仍会被读，但**只当缓存种子**（省一次读盘），
/// 目录里的文件列表优先。单文件的老格式仍然支持，读取时自动兼容。
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

/// 从 ch_xxxx.json 解析出的一章内容（标题 / 语篇 / 卡片都在这一个文件里）
class ChapterContent {
  final String title;
  final Passage? passage;
  final List<FlashCard> cards;

  const ChapterContent({
    this.title = '',
    this.passage,
    this.cards = const <FlashCard>[],
  });
}

/// 同步读一个 ch 分片文件（首次访问时才调用；单章几十~几百 KB，毫秒级）
ChapterContent _readChapterFile(String path, String templateId) {
  try {
    final f = File(path);
    if (!f.existsSync()) return const ChapterContent();
    final m = json.decode(f.readAsStringSync());
    if (m is! Map) return const ChapterContent();
    return ChapterContent(
      title: (m['title'] ?? '').toString(),
      passage: _passageFrom(m['passage']),
      cards: [
        for (final e in (m['cards'] as List? ?? []))
          FlashCard.fromJson(Map<String, dynamic>.from(e as Map), templateId),
      ],
    );
  } catch (_) {
    return const ChapterContent();
  }
}

/// ch_xxxx.json 的文件名规则（自然排序用文件名里的数字）
final RegExp _chFileRe = RegExp(r'^ch_(\d+)\.json$');

int _chFileNo(String name) {
  final m = _chFileRe.firstMatch(name);
  return m == null ? 0 : (int.tryParse(m.group(1)!) ?? 0);
}

/// 扫出目录里所有 ch_*.json，按编号排序 —— 章节的**唯一真源是文件本身**，
/// 加一章只要丢一个 ch_xxxx.json 进来，不用动 index.json。
List<String> _chapterFiles(String dir) {
  final names = <String>[];
  try {
    final d = Directory(dir);
    if (!d.existsSync()) return names;
    for (final e in d.listSync()) {
      if (e is! File) continue;
      final n = e.uri.pathSegments.last;
      if (_chFileRe.hasMatch(n)) names.add(n);
    }
  } catch (_) {}
  names.sort((a, b) => _chFileNo(a).compareTo(_chFileNo(b)));
  return names;
}

/// 一章 = 一个 ch_xxxx.json（老格式的章也可能内联在书文件里）
class Chapter {
  final String chapterId;

  /// 分片文件名（相对书目录）；null / 空 = 卡片内联
  final String? file;

  // ---- 老格式（index.json 里带 chapters）的「种子」 ----
  // 有种子就不用读盘；新格式没有种子，title / passage / cards 全懒加载自 ch 文件。
  final String _seedTitle;
  final Passage? _seedPassage;
  final int _seedCount;
  final List<String> _seedIds;
  final List<FlashCard>? _inlineCards;

  final ChapterContent Function()? _loader;
  ChapterContent? _loaded;

  Chapter({
    required this.chapterId,
    this.file,
    String seedTitle = '',
    Passage? seedPassage,
    int seedCount = 0,
    List<String> seedIds = const <String>[],
    List<FlashCard>? inlineCards,
    ChapterContent Function()? loader,
  })  : _seedTitle = seedTitle,
        _seedPassage = seedPassage,
        _seedCount = seedCount,
        _seedIds = seedIds,
        _inlineCards = inlineCards,
        _loader = loader;

  ChapterContent get _content => _loaded ??= (_loader != null
      ? _loader!()
      : ChapterContent(
          title: _seedTitle,
          passage: _seedPassage,
          cards: _inlineCards ?? const <FlashCard>[],
        ));

  /// 内容已经载入内存了？（内联章永远算已载入）
  bool get loaded => _loaded != null || _loader == null;

  /// 卡片。分片章**首次访问才真正读盘**（同步；单章文件很小，毫秒级）。
  List<FlashCard> get cards => _content.cards;

  /// 主动载入（不关心返回值时用）
  void ensureLoaded() => cards;

  String get title =>
      _seedTitle.isNotEmpty ? _seedTitle : (_content.title.isNotEmpty ? _content.title : '未命名章节');

  Passage? get passage => _seedPassage ?? _content.passage;

  /// 卡片数 —— 有种子 / 内联就不读盘
  int get count {
    if (_inlineCards != null) return _inlineCards!.length;
    if (_seedCount > 0) return _seedCount;
    if (_loaded != null) return _loaded!.cards.length;
    return _content.cards.length;
  }

  /// 卡片 id 列表 —— 有种子 / 内联就不读盘
  List<String> get ids {
    if (_inlineCards != null) return [for (final x in _inlineCards!) x.id];
    if (_seedIds.isNotEmpty) return _seedIds;
    return [for (final x in _content.cards) x.id];
  }

  /// 老格式：卡片内联在书文件里
  factory Chapter.fromJson(Map<String, dynamic> j, String templateId) {
    final cards = (j['cards'] as List? ?? [])
        .map((e) =>
            FlashCard.fromJson(Map<String, dynamic>.from(e as Map), templateId))
        .toList();
    return Chapter(
      chapterId: (j['chapter_id'] ?? j['title'] ?? 'ch').toString(),
      seedTitle: (j['title'] ?? '未命名章节').toString(),
      seedPassage: _passageFrom(j['passage']),
      inlineCards: cards,
    );
  }

  /// 老格式：index.json 里的章节条目 —— **只当种子**（省一次读盘），
  /// 目录里的 ch 文件列表才是真源。
  factory Chapter.meta(Map<String, dynamic> j) {
    return Chapter(
      chapterId: (j['chapter_id'] ?? j['title'] ?? 'ch').toString(),
      file: j['file']?.toString(),
      seedTitle: (j['title'] ?? '').toString(),
      seedPassage: _passageFrom(j['passage']),
      seedCount: (j['card_count'] as num?)?.toInt() ?? 0,
      seedIds: (j['card_ids'] as List? ?? [])
          .map((e) => e.toString())
          .toList(),
    );
  }

  /// ch_xxxx.json 的内容（标题 / 语篇 / 卡片全在这，单一真源）
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

  /// 新格式：只读 index.json 的**书级**元信息；章节从目录里的 ch_*.json 发现。
  /// 加一章 = 丢一个 ch_xxxx.json，不用动 index.json。
  factory Book.fromIndex(Map<String, dynamic> j, String dir) {
    final tplId = (j['template'] ?? 'bubei_dark').toString();
    final order =
        (j['fields_order'] as List?)?.cast<String>() ?? const <String>[];

    // 老 index.json 里的 chapters 只当「种子」（有 title/passage/card_ids，
    // 省一次读盘）；目录里的 ch_*.json 列表才是唯一真源。
    final seeds = <String, Chapter>{};
    for (final e in (j['chapters'] as List? ?? [])) {
      final m = Chapter.meta(Map<String, dynamic>.from(e as Map));
      final f = m.file;
      if (f != null && f.isNotEmpty) seeds[f] = m;
    }

    final chapters = <Chapter>[];
    for (final fname in _chapterFiles(dir)) {
      final seed = seeds[fname];
      chapters.add(Chapter(
        chapterId: seed?.chapterId ?? 'ch_${_chFileNo(fname)}',
        file: fname,
        seedTitle: seed?.title ?? '',
        seedPassage: seed?.passage,
        seedCount: seed?.count ?? 0,
        seedIds: seed?.ids ?? const <String>[],
        loader: () => _readChapterFile('$dir/$fname', tplId),
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

  /// 新格式：index.json —— **只有书级元信息**，章节列表不写在这
  /// （章节由目录里的 ch_*.json 决定，加章不用改 index）
  Map<String, dynamic> toIndexJson() {
    final m = <String, dynamic>{
      'format': 'flashcard.book.v3',
      'book_id': bookId,
      'title': title,
      'subtitle': subtitle,
      'template': templateId,
      'fields_order': fieldsOrder,
    };
    if (passage != null) m['passage'] = passage!.toJson();
    if (!hasChapters) {
      m['loose_count'] = looseCards.isNotEmpty ? looseCards.length : looseCount;
      m['loose_ids'] = looseCards.isNotEmpty
          ? [for (final c in looseCards) c.id]
          : looseIds;
    }
    return m;
  }
}
