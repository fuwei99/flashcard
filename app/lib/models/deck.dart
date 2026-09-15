/// 卡牌包 / 卡组 / 卡片 数据模型
library;

/// 单张卡片：字段字典 + 绑定的模板 id
class FlashCard {
  final String id;
  final Map<String, dynamic> fields;
  final String templateId;

  FlashCard({required this.id, required this.fields, required this.templateId});

  factory FlashCard.fromJson(Map<String, dynamic> j, String templateId) {
    final fields = Map<String, dynamic>.from(j);
    fields.remove('id');
    final id = (j['id'] ?? j['word'] ?? fields.values.firstOrNull ?? '').toString();
    return FlashCard(id: id, fields: fields, templateId: templateId);
  }

  String get word => (fields['word'] ?? id).toString();

  /// 完整释义（带括号里的常用短语 / 搭配）—— **只在词义页显示**
  String get meaningFull => (fields['meaning'] ?? '').toString().trim();

  /// 纯中文释义：去掉括号里的短语，用于选义 / 填词 / 语篇选词的提示。
  /// 否则「…(prevail over/against)」这种会把答案直接写在脸上。
  /// 优先用 json 里显式给的 `meaning_plain`，没有就现场剥括号兜底。
  String get meaningPlain {
    final v = (fields['meaning_plain'] ?? '').toString().trim();
    if (v.isNotEmpty) return v;
    return stripParenthetical(meaningFull);
  }

  /// 去掉 () （） 里的内容（一般是常用短语 / 搭配 / 近义标注）。
  /// 全剥没了就退回原串 —— 宁可留着，也别显示成空白。
  static String stripParenthetical(String s) {
    if (s.isEmpty) return s;
    var t = s.replaceAll(RegExp(r'[（(][^（()）]*[)）]'), '');
    t = t.replaceAll(RegExp(r'\s+'), ' ').trim();
    t = t.replaceAll(RegExp(r'[；;、,，]\s*$'), '').trim();
    return t.isEmpty ? s : t;
  }

  /// 序列化：id 单列，其余字段平铺
  Map<String, dynamic> toJson() => {'id': id, ...fields};
}

/// 一个卡组 = 若干卡片 + 绑定的模板 + 字段顺序
class Deck {
  final String deckId;
  final String name;
  final String version;
  final String templateId;
  final List<String> fieldsOrder;
  final List<FlashCard> cards;

  Deck({
    required this.deckId,
    required this.name,
    required this.version,
    required this.templateId,
    required this.fieldsOrder,
    required this.cards,
  });

  factory Deck.fromJson(Map<String, dynamic> j) {
    final tplId = (j['template'] ?? 'bubei_dark').toString();
    final order = (j['fields_order'] as List?)?.cast<String>() ??
        const <String>[];
    final cards = (j['cards'] as List? ?? [])
        .map((e) => FlashCard.fromJson(Map<String, dynamic>.from(e as Map), tplId))
        .toList();
    return Deck(
      deckId: (j['deck_id'] ?? 'deck').toString(),
      name: (j['name'] ?? '未命名卡组').toString(),
      version: (j['version'] ?? '1.0.0').toString(),
      templateId: tplId,
      fieldsOrder: order,
      cards: cards,
    );
  }
}

/// 模板包：manifest + 三段资源
class CardTemplate {
  final Map<String, dynamic> manifest;
  final String html;
  final String css;
  final String js;

  CardTemplate({
    required this.manifest,
    required this.html,
    required this.css,
    required this.js,
  });

  String get id => (manifest['id'] ?? 'unknown').toString();
  String get name => (manifest['name'] ?? id).toString();
  String get renderMode => (manifest['render_mode'] ?? 'placeholder').toString();

  /// 学习引擎：language（英语背诵）/ srs_basic（Anki 式）。
  /// 缺省 language —— 老模板没写 engine 也当英语书。
  String get engine => (manifest['engine'] ?? 'language').toString();
  List<String> get fields =>
      (manifest['fields'] as List?)?.cast<String>() ?? const [];
  Map<String, dynamic> get tts =>
      Map<String, dynamic>.from(manifest['tts'] as Map? ?? {});
}
