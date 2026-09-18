/// WebView 桥接层
/// ================================================================
/// 职责：
///   1. 把「书本字段 + 模板三段资源 + 会话上下文」组装成完整 HTML
///   2. 注入 glue JS（window.Flashcard）+ workflow.js（阶段 3）
///   3. 监听卡牌脚本发来的消息，转发给上层（屏幕）
///   4. 把 TTS 转给 flutter_tts
///   5. 双向 RPC（阶段 0）：Web 主动 call → 壳 handler → __resolve 回执
///
/// 注意：answer 消息不再在这里写 CardStore —— 交给 ReviewScreen
///       按「会话阶段」决定是毕业落盘，还是只记轮内结果。
library;

import 'dart:async';
import 'dart:convert';

import 'package:webview_flutter/webview_flutter.dart';

import '../models/book.dart';
import '../models/deck.dart';
import 'bridge_rpc.dart';
import 'card_source.dart';
import 'card_store.dart';
import 'js_log.dart';
import 'js_plugin_host.dart';
import 'plugin.dart';
import 'scheduler.dart';
import 'session_store.dart';
import 'template_engine.dart';
import 'template_fs.dart';
import 'tts_engine.dart';
import 'tts_log.dart';
import 'tts_service.dart';
import 'ui_prefs.dart';

class BridgeMessage {
  final String type;
  final Map<String, dynamic> data;
  BridgeMessage(this.type, this.data);
}

/// WebView 资源加载失败 → `logs/js/`。
///
/// 以前 NavigationDelegate 里只接了 onPageFinished，资源错误一个都没接：
/// 模板里的 `<img>` / 例句音频 / `fetch` 挂掉是**完全静默**的，
/// 用户看到的现象只是「卡上少了一块」，描述不出来、也没法查。
///
/// 注意这个是**所有**子资源都报（含非主框架），所以偶发噪声正常；
/// 排查时按 `code=` / `url=` grep 就行。
void logWebResourceError(WebResourceError e) {
  JsLog.write(
    'WEBRES',
    'code=${e.errorCode} type=${e.errorType} main=${e.isForMainFrame} '
    'url=${e.url ?? "-"} desc=${e.description}',
  );
}

class WebViewBridge {
  final CardStore store;
  final TtsService tts;

  /// 卡片内容源（阶段 2）：card.get / card.due / card.new 靠它。
  final CardSource cardSource;

  /// 双向 RPC 核心（阶段 0）。方法在 [_registerCore] 里注册。
  final BridgeRpc rpc = BridgeRpc();

  /// 会话断点（workflow.js 的 session.save 落这）。
  final SessionStore sessions = SessionStore();

  final _messages = StreamController<BridgeMessage>.broadcast();
  Stream<BridgeMessage> get messages => _messages.stream;

  String? _currentCardId;

  /// 最近一次 mount 的卡片数据快照（card.current 用）。
  Map<String, dynamic>? _lastCardJson;

  /// 会话计划（阶段 4）：Web 驱动模式下，workflow.js 用它自己排流程。
  /// 非 Web 驱动模式为 null。
  Map<String, dynamic>? _plan;

  /// 设置会话计划（由 ReviewScreen 在会话开始时调）。
  void setPlan(Map<String, dynamic>? plan) => _plan = plan;

  /// 原生顶部栏显隐回调 —— 模板调 `ui.setChrome` 时触发，屏幕据此 setState。
  void Function(bool top)? onChromeChanged;

  /// 宿主控制器 —— RPC 回执 / 事件推送要它 runJavaScript。
  WebViewController? _ctrl;

  WebViewBridge({
    required this.store,
    required this.tts,
    CardSource? cardSource,
  }) : cardSource = cardSource ?? BookCardSource() {
    sessions.init();
    _registerCore();
  }

  Future<void> initTts() => tts.init();

  /// 绑定控制器（必须在 load 之前调一次）。
  void attach(WebViewController c) => _ctrl = c;

  // ================================================================
  // 双向 RPC：壳暴露给卡牌 / workflow 的原子能力
  // ================================================================
  void _registerCore() {
    rpc.register('ping', (p) async => {
          'pong': true,
          'ts': DateTime.now().toIso8601String(),
        });

    // 当前这张卡（最近一次 mount 的数据）
    rpc.register(
        'card.current', (p) async => _lastCardJson ?? <String, dynamic>{});

    // 卡级 KV（标熟 / 收藏…）
    rpc.register('state.kvGet', (p) async {
      final id = (p['id'] ?? '').toString();
      return id.isEmpty ? <String, dynamic>{} : store.kvOf(id);
    });
    rpc.register('state.kvPut', (p) async {
      final id = (p['id'] ?? '').toString();
      if (id.isNotEmpty) {
        store.putKv(id, (p['key'] ?? '').toString(), p['value']);
      }
      return {'ok': true};
    });

    // 原生顶部栏显隐：模板设置里实时切 + 落盘，下次启动直接读。
    // 走 UiPrefs（settings/ui.json），不依赖模板 fs 白名单。
    rpc.register('ui.setChrome', (p) async {
      final top = p['top'] != false;
      UiPrefs.setTopBar(top);
      onChromeChanged?.call(top);
      return {'ok': true, 'top': top};
    });
    rpc.register('ui.getChrome',
        (p) async => {'ok': true, 'top': UiPrefs.topBar});

    // ---- 原子能力（阶段 2）：卡片查询 + 评级提交 ----
    // 这四条是 workflow.js 自己开车的油：card.due / card.new 拿队列 ->
    // card.get 取内容 -> review.commit 交评级。壳只做「能力」，不做「流程」。

    // 单卡完整数据（形状与 mountCard 灌进模板的一致）
    rpc.register('card.get', (p) async {
      final id = (p['id'] ?? '').toString();
      final c = await cardSource.cardById(id);
      return {'card': c == null ? null : _cardJson(c)};
    });

    // 到期队列（已学 + 到期，不含新卡）。ids 按 due 升序，limit 截断。
    rpc.register('card.due', (p) async {
      final ids = await _queue(p, reviewOnly: true);
      return {'ids': ids, 'count': ids.length};
    });

    // 新卡队列（未学、未标熟）
    rpc.register('card.new', (p) async {
      final ids = await _queue(p, reviewOnly: false);
      return {'ids': ids, 'count': ids.length};
    });

    // 交评级：跑 FSRS + 落盘，回新状态。这是唯一会动调度数据的入口。
    //
    // 评分必须**显式且合法**。以前是 `catch (_) { rating = Rating.good }`，
    // 任何拼错的 / 老模板传的 / 消息串了的评分都被当成「记得」写进 FSRS ——
    // 这在调度系统里是最危险的一类兜底：它不报错，只是悄悄把这张卡的
    // 稳定性往上抬、把到期日往后推，而且不可逆。现在直接失败回传错误，
    // 让调用方（workflow.js）自己决定怎么提示。
    rpc.register('review.commit', (p) async {
      final id = (p['id'] ?? '').toString();
      if (id.isEmpty) return {'ok': false, 'error': 'missing id'};
      final key = (p['rating'] ?? '').toString();
      Rating rating;
      try {
        rating = Rating.fromKey(key);
      } catch (_) {
        return {
          'ok': false,
          'id': id,
          'error': '非法评分: "$key"（只接受 again/hard/good 或 忘记/模糊/记得）',
        };
      }
      final prev = store.stateOf(id);
      final st = review(prev, rating);
      store.putReview(id, prev, st, rating);
      return {'ok': true, 'id': id, 'rating': rating.key, 'state': st.toJson()};
    });

    // 会话计划（阶段 4）：workflow.js 拉它自己排流程；非 Web 驱动返回 null
    rpc.register('session.plan', (p) async => _plan);

    // 会话断点（workflow.js 用）
    rpc.register('session.save', (p) async {
      sessions.save((p['workflow'] ?? '').toString(), p['cursor'], p['session']);
      return {'ok': true};
    });
    rpc.register('session.load', (p) async => sessions.data);
    rpc.register('session.clear', (p) async {
      sessions.clear();
      return {'ok': true};
    });

    // 前端日志（JSlogs）—— 排查 JS 问题不用连电脑
    rpc.register('sys.log', (p) async {
      await JsLog.write(
        (p['tag'] ?? 'rpc').toString(),
        (p['msg'] ?? '').toString(),
      );
      return {'ok': true};
    });

    // TTS 缓存清理：删过期（.ttl 标记）/ 超期未用（mtime）的音频。
    // workflow.js 定期调一次即可，别放在卡牌热路径上。
    rpc.register('tts.purge', (p) async {
      final d = p['olderThanDays'];
      final n = d is num ? d.toInt() : int.tryParse('${d ?? ''}');
      return tts.purgeCache(olderThanDays: (n == null || n <= 0) ? null : n);
    });

    // ---- 通用插件系统 ----
    // 清单（发现 / 类型 / 配置）统一走 PluginManager，唯一真源。
    // 运行时按 engine 分派：js 的工具插件灌进 JsPluginHost；
    // TTS 的 js 插件仍走 JsTtsHost（它特殊，先不动）。
    rpc.register('plugin.list', (p) async {
      await PluginManager.I.load();
      await JsPluginHost.instance.ensureLoaded();
      final host = JsPluginHost.instance;
      return {
        'ok': true,
        'plugins': PluginManager.I.all
            .map((m) => {
                  'id': m.id,
                  'name': m.name,
                  'kind': m.type.wire,
                  'engine': m.engine.wire,
                  'version': m.version,
                  'builtin': m.builtin,
                  'api': m.api,
                  'methods': host.methodsOf(m.id),
                })
            .toList(),
      };
    });
    rpc.register('plugin.reload', (p) async {
      await PluginManager.I.load(force: true);
      final n = await JsPluginHost.instance.reload();
      return {'ok': true, 'count': n};
    });
    rpc.register('plugin.call', (p) async {
      final id = (p['id'] ?? '').toString();
      final method = (p['method'] ?? '').toString();
      final args = p['args'] is Map
          ? Map<String, dynamic>.from(p['args'] as Map)
          : <String, dynamic>{};
      if (id.isEmpty || method.isEmpty) {
        return {'ok': false, 'error': 'missing id/method'};
      }
      await JsPluginHost.instance.ensureLoaded();
      return JsPluginHost.instance.call(id, method, args);
    });

    // ---- 模板文件接口（fs.*）----
    // 让模板 / workflow.js 直接读写数据目录下的文件。默认白名单 books/，
    // 页面里能自己加笔记文件、删卡、把卡挪到别的目录，不用回 Dart 层改。
    // 边界：路径相对 Documents/Flashcard/，规范化后必须落在白名单内。
    TemplateFs().registerInto(rpc);

    // 书文件被模板改过之后（fs.write / fs.move / fs.delete），壳里那份
    // 书列表缓存还是旧的 —— 不显式失效，页面就还在按老书跑，白改。
    rpc.register('book.reload', (p) async {
      final src = cardSource;
      if (src is BookCardSource) src.invalidate();
      return {'ok': true};
    });
  }

  // ---- RPC 辅助 ----

  /// 一张卡的完整数据（与 mountCard 灌进模板的形状一致）
  Map<String, dynamic> _cardJson(FlashCard c) => {
        'id': c.id,
        'fields': c.fields,
        'state': store.stateOf(c.id).toJson(),
        'kv': store.kvOf(c.id),
      };

  /// 到期 / 新卡队列。
  /// 只用 [Book.allCardIds]（来自 index.json，**不读章节文件**）判队列，
  /// 所以列 6500 词的到期也不会把书读进内存。
  Future<List<String>> _queue(
    Map<String, dynamic> p, {
    required bool reviewOnly,
  }) async {
    final limit = (p['limit'] as num?)?.toInt() ?? 0;
    final bookId = (p['bookId'] ?? '').toString();
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);

    final dueRefs = <MapEntry<String, DateTime?>>[];
    final newIds = <String>[];

    for (final b in await cardSource.books()) {
      if (bookId.isNotEmpty && b.bookId != bookId) continue;
      for (final id in b.allCardIds) {
        if (store.isKnown(id)) continue; // 标熟 = 永久出队
        final st = store.stateOf(id);
        if (st.isNew) {
          if (!reviewOnly) newIds.add(id);
        } else if (st.due == null || !st.due!.isAfter(today)) {
          dueRefs.add(MapEntry(id, st.due));
        }
      }
    }

    if (!reviewOnly) {
      return limit > 0 ? newIds.take(limit).toList() : newIds;
    }

    // 最该复习的排前面：按到期时间升序
    dueRefs.sort((a, b) {
      final da = a.value;
      final db = b.value;
      if (da == null && db == null) return 0;
      if (da == null) return -1;
      if (db == null) return 1;
      return da.compareTo(db);
    });
    final ids = [for (final e in dueRefs) e.key];
    return limit > 0 ? ids.take(limit).toList() : ids;
  }

  /// 壳 → Web 事件推送
  Future<void> emit(String event, [dynamic data]) async {
    final c = _ctrl;
    if (c == null) return;
    await c.runJavaScript(BridgeRpc.emitScript(event, data));
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
    List<Map<String, dynamic>> choices = const [],
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
      workflowJs: template.workflow,
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
    List<Map<String, dynamic>> choices = const [],
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
      // 卡牌私有 KV（标熟 / 收藏…）—— 模板顶栏读它渲染按钮状态。
      // 不传这个，模板就不知道这张卡是不是已经标过熟，按钮永远是灰的。
      'kv': card == null ? <String, dynamic>{} : store.kvOf(card.id),
      'index': index,
      'total': total,
      'session': session,
      'choices': choices,
      if (passage != null && passage.hasContent)
        'passage': passageJson(passage, passageCards, blankLemmas),
    };

    _lastCardJson = cardJson;

    final jsonStr = TemplateEngine.jsonForJs(cardJson);
    final js = "window.Flashcard.mountCard('$jsonStr');";
    await ctrl.runJavaScript(js);
  }

  /// 拼写轮：把整轮要拼的条目一次性灌给模板，循环由模板自己跑。
  ///
  /// 阶段 3 起，拼写轮的循环归 workflow.js 所有；这里保留为兼容入口。
  Future<void> startSpellRound(
      WebViewController ctrl, List<Map<String, dynamic>> items) async {
    final jsonStr = TemplateEngine.jsonForJs({'items': items});
    await ctrl.runJavaScript(
        "if(window.Flashcard&&window.Flashcard.startSpellRound)"
        "{window.Flashcard.startSpellRound('$jsonStr');}");
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

    // 双向 RPC（阶段 0）：不走 messages 流，直接查表执行 + 回执。
    if (type == 'rpc') {
      final id = (data['id'] as num?)?.toInt() ?? 0;
      final method = (data['method'] ?? '').toString();
      final params = data['params'] is Map
          ? Map<String, dynamic>.from(data['params'] as Map)
          : <String, dynamic>{};
      final script = await rpc.dispatch(id, method, params);
      final c = _ctrl;
      if (c != null) await c.runJavaScript(script);
      return;
    }

    // JS 日志（JSlogs）：写独立文件，不进 messages 流、不掺切卡时序
    if (type == 'log') {
      await JsLog.write(
        (data['tag'] ?? 'js').toString(),
        (data['msg'] ?? '').toString(),
      );
      return;
    }

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
