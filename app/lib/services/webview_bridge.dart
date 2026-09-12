/// WebView 桥接层
/// ================================================================
/// 职责：
///   1. 把「书本字段 + 模板三段资源」组装成完整 HTML 页面
///   2. 把页面塞进 WebView 之前，注入 glue JS（window.Flashcard）
///   3. 监听卡牌脚本通过 FCChannel 发来的消息
///   4. 把评分转给 scheduler，把 TTS 转给 flutter_tts
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_tts/flutter_tts.dart';

import '../models/book.dart';
import '../models/deck.dart';
import 'card_store.dart';
import 'scheduler.dart';
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
    await tts.setLanguage('en-US');
    await tts.setSpeechRate(0.48);
    await tts.setPitch(1.0);
  }

  /// 组装一张卡牌的完整 HTML 页面
  String buildCardPage({
    required Book book,
    required CardTemplate template,
    required FlashCard card,
    required int index,
    required int total,
  }) {
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
    };

    return TemplateEngine.buildPage(
      templateHtml: template.html,
      css: template.css,
      js: template.js,
      fields: fields,
      cardJson: cardJson,
      kv: store.kvOf(card.id),
      extra: {'__index': index + 1, '__total': total},
    );
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
    _messages.add(BridgeMessage(type, data));

    switch (type) {
      case 'answer':
        final rating = Rating.fromKey((data['rating'] ?? 'good').toString());
        final id = _currentCardId;
        if (id != null) {
          final st = store.stateOf(id);
          final updated = review(st, rating);
          store.putState(id, updated);
        }
        break;

      case 'tts':
        final text = (data['text'] ?? '').toString();
        final lang = (data['lang'] ?? 'en-US').toString();
        if (text.isNotEmpty) {
          await tts.stop();
          await tts.setLanguage(lang);
          await tts.speak(text);
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
        break;
    }
  }

  void dispose() {
    _messages.close();
  }
}
