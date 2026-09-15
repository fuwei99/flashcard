/// 卡牌包 / 卡组 / 卡片 数据模型
library;

/// 一个义项：词性 + 释义（+ 多音词的音标）。
/// 一词多义 / 一词多性就靠它拆开，
/// 不再用「一个 pos 字符串 + 一个 meaning 字符串」硬凑。
class Sense {
  final String pos;
  final String cn;        // 完整释义（可带括号里的短语）
  final String phonetic;  // 多音词才有（record n./v. 读音不同）

  const Sense({this.pos = '', this.cn = '', this.phonetic = ''});

  bool get isEmpty => cn.trim().isEmpty;

  factory Sense.fromJson(Map<dynamic, dynamic> j) => Sense(
        pos: (j['pos'] ?? '').toString().trim(),
        cn: (j['cn'] ?? j['meaning'] ?? '').toString().trim(),
        phonetic: (j['phonetic_us'] ?? j['phonetic'] ?? '').toString().trim(),
      );

  Map<String, dynamic> toJson() => {
        if (pos.isNotEmpty) 'pos': pos,
        'cn': cn,
        if (phonetic.isNotEmpty) 'phonetic_us': phonetic,
      };
}

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

  /// 义项列表。
  /// 新格式直接读 `senses`；老格式（`pos` + `meaning` 两个字符串）
  /// 在这里被折成一条 —— 所以用户手里的老书不用改 json 也能出选项、能渲染。
  List<Sense> get senses {
    final raw = fields['senses'];
    if (raw is List && raw.isNotEmpty) {
      final out = <Sense>[];
      for (final e in raw) {
        if (e is Map) {
          final s = Sense.fromJson(e);
          if (!s.isEmpty) out.add(s);
        } else if (e is String && e.trim().isNotEmpty) {
          out.add(Sense(cn: e.trim()));
        }
      }
      if (out.isNotEmpty) return out;
    }
    final cn = (fields['meaning'] ?? '').toString().trim();
    if (cn.isEmpty) return const [];
    return [Sense(pos: (fields['pos'] ?? '').toString().trim(), cn: cn)];
  }

  /// 完整释义（词义页 / 语篇浮层用）：多义项用「；」连起来
  String get meaningFull => senses
      .map((s) => ((s.pos.isNotEmpty ? '${s.pos} ' : '') + s.cn).trim())
      .where((s) => s.isNotEmpty)
      .join('；');

  /// 纯中文释义：剥掉括号里的短语，用于选义 / 填词 / 语篇选词的提示。
  /// 否则「…(prevail over/against)」这种会把答案直接写在脸上。
  /// 优先用 json 里显式给的 `meaning_plain`，没有就从 senses 现场派生。
  String get meaningPlain {
    final explicit = (fields['meaning_plain'] ?? '').toString().trim();
    if (explicit.isNotEmpty) return explicit;
    final parts = senses
        .map((s) => stripParenthetical(s.cn))
        .where((s) => s.isNotEmpty)
        .toList();
    return parts.join('；');
  }

  /// 展示块（词义页的扩展卡片）。
  /// 模板**不认识业务字段**，只按 block 的 `type` 渲染 ——
  /// 以后加「近义词 / 反义词 / 词形变化」只要往 json 里塞一个 block，
  /// 不用改模板、更不用重编 APK。
  List<Map<String, dynamic>> get blocks {
    final raw = fields['blocks'];
    if (raw is! List) return const [];
    return [
      for (final e in raw)
        if (e is Map) Map<String, dynamic>.from(e),
    ];
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
