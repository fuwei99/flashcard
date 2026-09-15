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

import 'package:flutter_tts/flutter_tts.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../models/book.dart';
import '../models/deck.dart';
import 'card_store.dart';
import 'template_engine.dart';
import 'tts_log.dart';

class BridgeMessage {
  final String type;
  final Map<String, dynamic> data;
  BridgeMessage(this.type, this.data);
}

class WebViewBridge {
  final CardStore store;
  final FlutterTts tts;

  final _messages = StreamController<BridgeMessage>.broadcast();
  Stream<BridgeMessage> get messages => _messages.stream;

  String? _currentCardId;

  /// TTS 顺序朗读的「代」计数：每来一条新的朗读就 +1，
  /// 正在跑的 ttsSeq 循环发现代号变了就立刻收手，避免和新卡片抢话。
  int _ttsGen = 0;

  WebViewBridge({required this.store, FlutterTts? tts})
      : tts = tts ?? FlutterTts();

  Future<void> initTts() async {
    await TtsLog.write('init', 'initTts start');
    try {
      final r1 = await tts.setLanguage('en-US');
      final r2 = await tts.setSpeechRate(0.48);
      final r3 = await tts.setVolume(1.0);
      final r4 = await tts.setPitch(1.0);
      final r5 = await tts.awaitSpeakCompletion(true);
      await TtsLog.write('init',
          'setLanguage=$r1 rate=$r2 vol=$r3 pitch=$r4 awaitCompletion=$r5');
      final avail = await tts.isLanguageAvailable('en-US');
      await TtsLog.write('init', 'isLanguageAvailable(en-US)=$avail');
      final def = await tts.getDefaultEngine;
      await TtsLog.write('init', 'defaultEngine=$def');
      final engines = await tts.getEngines;
      await TtsLog.write('init', 'engines=$engines');
    } catch (e, st) {
      await TtsLog.write('init', 'ERROR: $e\n$st');
    }
  }

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

    switch (type) {
      case 'tts':
        // 卡牌字段常带 <u>/<b> 高亮标签，直接喂 TTS 会念出尖括号
        final text = _plainText((data['text'] ?? '').toString());
        final lang = (data['lang'] ?? 'en-US').toString();
        if (text.isNotEmpty) {
          _ttsGen++; // 打断可能正在进行的顺序朗读
          try {
            await tts.stop();
            final lr = await tts.setLanguage(lang);
            final sr = await tts.speak(text);
            await TtsLog.write('speak',
                'lang=$lang setLanguage->$lr speak->$sr text="${_abbr(text)}"');
          } catch (e, st) {
            await TtsLog.write('speak', 'ERROR: $e\n$st');
          }
        }
        break;

      case 'ttsStop':
        _ttsGen++; // 打断可能正在进行的顺序朗读
        try {
          await tts.stop();
          await TtsLog.write('stop', 'stop ok');
        } catch (e) {
          await TtsLog.write('stop', 'ERROR: $e');
        }
        break;

      case 'ttsSeq':
        // 顺序朗读：念完一条再念下一条（进词义页 = 单词 -> 例句）
        final items = data['items'];
        if (items is List) {
          final myGen = ++_ttsGen;
          try {
            await tts.stop();
            for (final it in items) {
              if (myGen != _ttsGen) break; // 被新朗读打断，立即收手
              if (it is! Map) continue;
              final text = _plainText((it['text'] ?? '').toString());
              final lang = (it['lang'] ?? 'en-US').toString();
              if (text.isEmpty) continue;
              final lr = await tts.setLanguage(lang);
              final sr = await tts.speak(text);
              await TtsLog.write('seq',
                  'lang=$lang setLanguage->$lr speak->$sr text="${_abbr(text)}"');
            }
          } catch (e, st) {
            await TtsLog.write('seq', 'ERROR: $e\n$st');
          }
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

  /// 日志里别塞整段语篇，掐个头
  static String _abbr(String s) =>
      s.length <= 48 ? s : '${s.substring(0, 48)}…';

  void dispose() {
    _messages.close();
  }
}
