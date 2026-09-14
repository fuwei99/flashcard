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

  WebViewBridge({required this.store, FlutterTts? tts})
      : tts = tts ?? FlutterTts();

  Future<void> initTts() async {
    try {
      await tts.setLanguage('en-US');
      await tts.setSpeechRate(0.48);
      await tts.setVolume(1.0);
      await tts.setPitch(1.0);
      await tts.awaitSpeakCompletion(true);
    } catch (_) {}
  }

  /// 组装一张卡牌的完整 HTML 页面 —— SPA 骨架页，只在会话开始时 load 一次。
  ///
  /// [session] 会话上下文：{phase, mode, round}
  /// [choices] 干扰项：[{text, right}]
  ///
  /// 骨架页内不含真实卡片数据；每切一张卡由 [mountCard] 增量灌入。
  String buildCardPage({
    required Book book,
    required CardTemplate template,
    required FlashCard card,
    required int index,
    required int total,
    Map<String, dynamic> session = const {},
    List<Map<String, String>> choices = const [],
  }) {
    _currentCardId = card.id;

    final fields = <String, dynamic>{};
    for (final f in book.fieldsOrder) {
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

  /// SPA 增量挂卡：把一张卡的数据灌进已加载的骨架页，不重载页面。
  Future<void> mountCard(
    WebViewController ctrl, {
    required Book book,
    required CardTemplate template,
    required FlashCard card,
    required int index,
    required int total,
    Map<String, dynamic> session = const {},
    List<Map<String, String>> choices = const [],
  }) async {
    _currentCardId = card.id;

    final fields = <String, dynamic>{};
    for (final f in book.fieldsOrder) {
      fields[f] = card.fields[f] ?? '';
    }
    card.fields.forEach((k, v) => fields[k] = v);

    final cardJson = <String, dynamic>{
      'id': card.id,
      'fields': fields,
      'state': store.stateOf(card.id).toJson(),
      'index': index,
      'total': total,
      'session': session,
      'choices': choices,
    };

    final jsonStr = TemplateEngine.jsonForJs(cardJson);
    final js =
        "window.Flashcard.mountCard('$jsonStr');";
    await ctrl.runJavaScript(js);
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
          try {
            await tts.stop();
            await tts.setLanguage(lang);
            await tts.speak(text);
          } catch (_) {}
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
    _messages.close();
  }
}
