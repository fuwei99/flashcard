/// 卡牌包 / 卡组 / 卡片 数据模型
library;

/// 把可能是 List 的释义压成字符串。
/// Dart 的 `List.toString()` 会吐 `[税, 负担]`（带方括号和空格），
/// theme_vocab 这类书的 cn 就是数组，直接 toString 会把方括号漏到界面上。
/// 凡是可能为 List 的释义字段，一律走这里。
String cnToString(dynamic v) {
  if (v == null) return '';
  if (v is List) {
    return v
        .map((e) => e == null ? '' : e.toString().trim())
        .where((e) => e.isNotEmpty)
        .join('；');
  }
  return v.toString().trim();
}

/// 一个义项：词性 + 释义（+ 多音词的音标）。
/// 一词多义 / 一词多性就靠它拆开，
/// 不再用「一个 pos 字符串 + 一个 meaning 字符串」硬凑。
class Sense {
  final String pos;
  final String cn;        // 完整释义（可带括号里的短语）
  final String phonetic;  // 多音词才有（record n./v. 读音不同）

  const Sense({this.pos = '', this.cn = '', this.phonetic = ''});

  bool get isEmpty => cn.trim().isEmpty;

  factory Sense.fromJson(Map<dynamic, dynamic> j) {
    var cn = cnToString(j['cn']);
    if (cn.isEmpty) cn = cnToString(j['meaning']);
    return Sense(
      pos: (j['pos'] ?? '').toString().trim(),
      cn: cn,
      phonetic: (j['phonetic_us'] ?? j['phonetic'] ?? '').toString().trim(),
    );
  }

  Map<String, dynamic> toJson() => {
        if (pos.isNotEmpty) 'pos': pos,
        'cn': cn,
        if (phonetic.isNotEmpty) 'phonetic_us': phonetic,
      };
}

/// 一个「关联词」条目 —— 派生词 / 近义词 / 反义词共用。
///
/// 形状 = 词 + 义项列表（**词性+释义绑定**），所以多词性照样表达得了：
///   {"word":"intensively","senses":[{"pos":"adv.","cn":"密集地，集中地"}]}
///
/// 宽容读取（写盘一律规范形）：
///   {"word":"intensively","pos":"adv.","cn":"密集地"}   ← 平铺简写
///   "intensively"                                       ← 只有词，没释义也显示
class RelatedWord {
  final String word;
  final List<Sense> senses;

  const RelatedWord({this.word = '', this.senses = const []});

  bool get isEmpty => word.trim().isEmpty && senses.isEmpty;

  factory RelatedWord.fromJson(dynamic j) {
    if (j is String) return RelatedWord(word: j.trim());
    if (j is! Map) return const RelatedWord();

    final w = (j['word'] ?? j['en'] ?? j['k'] ?? '').toString().trim();
    final out = <Sense>[];

    final raw = j['senses'] ?? j['meanings'];
    if (raw is List) {
      for (final e in raw) {
        if (e is Map) {
          final s = Sense.fromJson(e);
          if (!s.isEmpty) out.add(s);
        } else if (e is String && e.trim().isNotEmpty) {
          out.add(Sense(cn: e.trim()));
        }
      }
    }
    // 平铺简写兜底：pos + cn 直接挂在条目上
    if (out.isEmpty) {
      final cn = cnToString(j['cn'] ?? j['meaning'] ?? j['v']);
      if (cn.isNotEmpty) {
        out.add(Sense(pos: (j['pos'] ?? '').toString().trim(), cn: cn));
      }
    }
    return RelatedWord(word: w, senses: out);
  }

  /// 纯中文释义（剥括号），用于紧凑展示
  String get plain => senses
      .map((s) => FlashCard.stripParenthetical(s.cn))
      .where((s) => s.isNotEmpty)
      .join('；');

  Map<String, dynamic> toJson() => {
        'word': word,
        if (senses.isNotEmpty)
          'senses': senses.map((s) => s.toJson()).toList(),
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
    final cn = cnToString(fields['meaning']);
    if (cn.isEmpty) return const [];
    return [Sense(pos: (fields['pos'] ?? '').toString().trim(), cn: cn)];
  }

  /// 词性标签：多词性用 / 连（adj./vt.）。
  /// 选义选项的「词性前缀」用它 —— 老数据的 pos 已经在 senses 里兜底了，
  /// 所以新 schema 删掉 pos 字段后这里不会再变空。
  String get posLabel {
    final set = <String>{};
    for (final s in senses) {
      if (s.pos.isNotEmpty) set.add(s.pos);
    }
    return set.join('/');
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
    final explicit = cnToString(fields['meaning_plain']);
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

  /// 是否有例句。
  /// **没有例句就不出「选词填空」** —— 空挖不出来，整题无从谈起，
  /// 会话编排里会直接把 cloze 这个考法对这张卡跳过。
  bool get hasSentence =>
      (fields['sentence_en'] ?? '').toString().trim().isNotEmpty;

  /// 预备「易混项」：卡里显式给几个长得像 / 意思近的词当干扰项，
  /// 出题时**优先**用它们（顺序照样打乱），没有才回落到整本书随机抽词。
  ///
  ///   "confusions": [
  ///     {"word":"accident","senses":[{"pos":"n.","cn":["事故；意外"]}]},
  ///     {"word":"occasion","senses":[{"pos":"n.","cn":["场合；时机"]}]}
  ///   ]
  /// 宽容读取简写：{"word":"accident","pos":"n.","cn":"事故；意外"}
  List<Map<String, dynamic>> get confusions {
    final raw = fields['confusions'];
    if (raw is! List) return const [];
    return [
      for (final e in raw)
        if (e is Map) Map<String, dynamic>.from(e),
    ];
  }

  /// 关联词通用读取（派生词 / 近义词 / 反义词形状一致，共用一套解析）
  List<RelatedWord> _related(String key) {
    final raw = fields[key];
    if (raw is! List) return const [];
    final out = <RelatedWord>[];
    for (final e in raw) {
      final r = RelatedWord.fromJson(e);
      if (!r.isEmpty) out.add(r);
    }
    return out;
  }

  /// 派生词（固定卡片）。没有就整张卡不显示。
  List<RelatedWord> get derivatives => _related('derivatives');

  /// 近义词（和反义词**同一张卡**）
  List<RelatedWord> get synonyms => _related('synonyms');

  /// 反义词
  List<RelatedWord> get antonyms => _related('antonyms');

  bool get hasThesaurus => synonyms.isNotEmpty || antonyms.isNotEmpty;

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

  /// 按 id 判等（同一张卡从不同 Book 实例读出来、或从不同代码路径拿到，
  /// 也必须是同一张）。
  ///
  /// 以前没有这个，全靠对象同一性 —— 目前没出事纯属侥幸：
  /// `StudySession._retestPool.remove(card)` 依赖「传进来的和放进去的是
  /// 同一批实例」。但 Chapter 是首次访问才解析的，只要 refresh 造出新的
  /// Book，同一张卡就是两个对象，那时 remove / contains / Set 去重会
  /// **静默失效**（不报错，只是删不掉）。按 id 判等堵死这个陷阱。
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is FlashCard && id == other.id && templateId == other.templateId);

  @override
  int get hashCode => Object.hash(id, templateId);

  @override
  String toString() => 'FlashCard($id)';
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

  /// Web-first workflow（阶段 3）：卡牌包自定义学习流程的裸 JS。
  /// 空字符串 = 没有，壳走老路径。
  final String workflow;

  CardTemplate({
    required this.manifest,
    required this.html,
    required this.css,
    required this.js,
    this.workflow = '',
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
