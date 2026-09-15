/// WebView 桥接层
/// ================================================================
/// 职责：
///   1. 把「书本字段 + 模板三段资源 + 会话上下文」组装成完整 HTML
///   2. 注入 glue JS（window.Flashcard）
///   3. 监听卡牌脚本发来的消息，转发给上层（屏幕）
///   4. 把 TTS 转给 flutter_tts
///
/// 注意：answer 消息不再在这里写 CardStore —— 交给 ReviewScreen
///       按「会话阶段」决定是毕业落盘，还是只记轮内结果。
library;

import 'dart:async';
import 'dart:convert';

import 'package:webview_flutter/webview_flutter.dart';

import '../models/book.dart';
import '../models/deck.dart';
import 'card_store.dart';
import 'template_engine.dart';
import 'tts_engine.dart';
import 'tts_log.dart';
import 'tts_service.dart';

class BridgeMessage {
  final String type;
  final Map<String, dynamic> data;
  BridgeMessage(this.type, this.data);
}

class WebViewBridge {
  final CardStore store;
  final TtsService tts;

  final _messages = StreamController<BridgeMessage>.broadcast();
  Stream<BridgeMessage> get messages => _messages.stream;

  String? _currentCardId;

  WebViewBridge({required this.store, required this.tts});

  Future<void> initTts() => tts.init();

  /// 组装一张卡牌的完整 HTML 页面 —— SPA 骨架页，只在会话开始时 load 一次。
  ///
  /// 骨架页内不含真实卡片数据；每切一张卡由 [mountCard] 增量灌入。
  /// 语篇两阶段没有具体卡片，card 传 null。
  String buildCardPage({
    required List<String> fieldsOrder,
    required CardTemplate template,
    FlashCard? card,
    required int index,
    required int total,
    Map<String, dynamic> session = const {},
    List<Map<String, String>> choices = const [],
  }) {
    _currentCardId = card?.id;

    final fields = <String, dynamic>{};
    for (final f in fieldsOrder) {
      fields[f] = '';
    }

    final cardJson = <String, dynamic>{
      'id': '',
      'fields': fields,
      'state': <String, dynamic>{},
      'index': index,
      'total': total,
      'session': session,
      'choices': choices,
    };

    return TemplateEngine.buildPage(
      templateHtml: template.html,
      css: template.css,
      js: template.js,
      fields: fields,
      cardJson: cardJson,
      kv: const <String, dynamic>{},
      extra: {'__index': index + 1, '__total': total},
    );
  }

  /// SPA 增量挂卡：把一张卡（或一章语篇）的数据灌进已加载的骨架页，不重载页面。
  Future<void> mountCard(
    WebViewController ctrl, {
    required List<String> fieldsOrder,
    required CardTemplate template,
    FlashCard? card,
    Passage? passage,
    List<FlashCard> passageCards = const [],
    Set<String>? blankLemmas,
    required int index,
    required int total,
    Map<String, dynamic> session = const {},
    List<Map<String, String>> choices = const [],
  }) async {
    _currentCardId = card?.id;

    final fields = <String, dynamic>{};
    for (final f in fieldsOrder) {
      fields[f] = '';
    }
    card?.fields.forEach((k, v) => fields[k] = v);

    final cardJson = <String, dynamic>{
      'id': card?.id ?? '',
      'fields': fields,
      'state':
          card == null ? <String, dynamic>{} : store.stateOf(card.id).toJson(),
      'index': index,
      'total': total,
      'session': session,
      'choices': choices,
      if (passage != null && passage.hasContent)
        'passage': passageJson(passage, passageCards, blankLemmas),
    };

    final jsonStr = TemplateEngine.jsonForJs(cardJson);
    final js = "window.Flashcard.mountCard('$jsonStr');";
    await ctrl.runJavaScript(js);
  }

  /// 把语篇解析成模板友好的 segments，并把每个目标词关联到本章卡片（词性/释义）。
  /// 模板拿到的是现成结构，不需要自己解析 [word] / [surface|lemma]。
  /// [blankLemmas] 为 null 时挖全部标记词；否则只挖命中的 lemma。
  Map<String, dynamic> passageJson(Passage p, List<FlashCard> cards,
      [Set<String>? blankLemmas]) {
    final byWord = <String, FlashCard>{};
    for (final c in cards) {
      byWord[c.word.toLowerCase()] = c;
      final w = (c.fields['word'] ?? '').toString().toLowerCase();
      if (w.isNotEmpty) byWord[w] = c;
    }

    final segs = <Map<String, dynamic>>[];
    for (final s in p.segments) {
      if (s.isWord) {
        final lemma = (s.lemma ?? '').toLowerCase();
        final c = byWord[lemma];
        segs.add({
          'w': s.surface,
          'lemma': s.lemma,
          // 多词性用 / 连（adj./vt.），释义取全部义项
          'pos': c == null
              ? ''
              : {for (final e in c.senses) if (e.pos.isNotEmpty) e.pos}.join('/'),
          'meaning': c?.meaningFull ?? '',
          // 纯中文释义：语篇选词的「当前空」提示用它，避免短语泄题
          'plain': c?.meaningPlain ?? '',
          'blank': blankLemmas == null || blankLemmas.contains(lemma),
        });
      } else {
        segs.add({'t': s.text});
      }
    }

    return {
      'title': p.title,
      'cn': p.cn,
      'segments': segs,
    };
  }

  /// 处理卡牌脚本发来的一条消息
  Future<void> handleMessage(String raw) async {
    Map<String, dynamic> data;
    try {
      data = json.decode(raw) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    final type = (data['type'] ?? '').toString();

    // answer 只转发，不落盘 —— 由 ReviewScreen 决定
    _messages.add(BridgeMessage(type, data));

    // 时序埋点：把 JS 发过来的每条消息按到达顺序记下，
    // 排查「点击没反应 / TTS 串页」时能看清 answer 和 tts 的先后。
    if (type == 'answer' || type == 'tts' || type == 'ttsSeq' || type == 'ttsStop') {
      await SwitchLog.write('bridge',
          '$type ${type == 'answer' ? (data['rating'] ?? '') : (data['text'] ?? (data['items'] is List ? '${(data['items'] as List).length}条' : ''))}');
    }

    switch (type) {
      case 'tts':
        // 卡牌字段常带 <u>/<b> 高亮标签，直接喂 TTS 会念出尖括号
        final text = _plainText((data['text'] ?? '').toString());
        final lang = (data['lang'] ?? 'en-US').toString();
        if (text.isNotEmpty) {
          // 模板可带 plugin/voice/rate/pitch/extra 覆盖当前插件配置
          await tts.speak(text, lang, options: TtsOptions.parse(data));
        }
        break;

      case 'ttsStop':
        await tts.stop();
        break;

      case 'ttsSeq':
        // 顺序朗读：念完一条再念下一条（进词义页 = 单词 -> 例句）
        final items = data['items'];
        if (items is List) {
          await tts.speakSeq(items);
        }
        break;

      case 'setState':
        final id = _currentCardId;
        if (id != null) {
          store.putKv(id, (data['key'] ?? '').toString(), data['value']);
        }
        break;

      case 'ready':
      case 'undo':
      case 'next':
      case 'prev':
      case 'answer':
        break;
    }
  }

  /// 去掉 HTML 标签 + 压缩空白，只留能念的纯文本
  static String _plainText(String s) => s
      .replaceAll(RegExp(r'<[^>]*>'), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  void dispose() {
    tts.dispose();
    _messages.close();
  }
}
