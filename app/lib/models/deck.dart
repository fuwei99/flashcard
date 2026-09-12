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
  List<String> get fields =>
      (manifest['fields'] as List?)?.cast<String>() ?? const [];
  Map<String, dynamic> get tts =>
      Map<String, dynamic>.from(manifest['tts'] as Map? ?? {});
}
