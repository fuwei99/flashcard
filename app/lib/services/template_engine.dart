/// flashcard 模板引擎 · Dart 版
/// ================================================================
/// 模板占位符渲染（唯一实现，生产路径）：
///   {{field}}               直接替换
///   {{#field}}...{{/field}} 字段真值/非空时保留
///   {{^field}}...{{/field}} 字段为空时保留
/// 列表字段（phrases）不在此展开，交给模板自带 script.js 生成 DOM。
library;

import 'dart:convert';

class TemplateEngine {
  static bool _truthy(dynamic v) {
    if (v == null) return false;
    if (v is String) return v.trim().isNotEmpty;
    if (v is List) return v.isNotEmpty;
    if (v is Map) return v.isNotEmpty;
    return v == true;
  }

  /// 渲染模板
  static String render(
    String template,
    Map<String, dynamic> fields, {
    Map<String, dynamic>? extra,
  }) {
    final data = <String, dynamic>{...fields, ...?extra};

    // section: {{#name}}...{{/name}} / {{^name}}...{{/name}}
    final secRe = RegExp(r'\{\{([#^])(\w+)\}\}([\s\S]*?)\{\{/\2\}\}');
    var out = template;
    String prev;
    do {
      prev = out;
      out = out.replaceAllMapped(secRe, (m) {
        final sign = m.group(1)!;
        final name = m.group(2)!;
        final body = m.group(3)!;
        final t = _truthy(data[name]);
        if (sign == '#') return t ? body : '';
        return t ? '' : body;
      });
    } while (out != prev);

    // 变量替换
    final varRe = RegExp(r'\{\{(\w+)\}\}');
    out = out.replaceAllMapped(varRe, (m) {
      final v = data[m.group(1)!];
      if (v == null || v is List || v is Map) return '';
      return v.toString();
    });

    return out;
  }

  /// 把模板 + 数据组装成一个完整 HTML 页面，塞进 WebView
  static String buildPage({
    required String templateHtml,
    required String css,
    required String js,
    required Map<String, dynamic> fields,
    required Map<String, dynamic> cardJson,
    Map<String, dynamic>? kv,
    Map<String, dynamic>? extra,
    String workflowJs = '',
  }) {
    final html = render(templateHtml, fields, extra: extra);
    final cardJsonStr = _jsonEncode(cardJson);
    final kvJsonStr = _jsonEncode(kv ?? {});

    return '''<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no,viewport-fit=cover">
<style>$css</style>
</head>
<body>
$html
<script>
window.__FLASHCARD_CARD__ = $cardJsonStr;
window.__FLASHCARD_KV__ = $kvJsonStr;
</script>
<script>
// ---- 原生壳注入的 API 契约（模板 script.js 直接用它）----
(function () {
  var ch = (typeof FCChannel !== "undefined") ? FCChannel : null;
  function post(obj){ if (ch) ch.postMessage(JSON.stringify(obj)); }

  // ---- 双向 RPC（阶段 0）：请求/响应 + 事件 ----
  var seq = 0;
  var pending = {};   // id -> {resolve, reject}
  var listeners = {}; // event -> [fn]
  function call(method, params) {
    return new Promise(function (resolve, reject) {
      if (!ch) { reject(new Error("no channel")); return; }
      var id = ++seq;
      pending[id] = { resolve: resolve, reject: reject };
      post({ type: "rpc", id: id, method: method, params: params || {} });
    });
  }
  function on(evt, fn) { (listeners[evt] = listeners[evt] || []).push(fn); }

  window.Flashcard = {
    getCard: function () { return window.__FLASHCARD_CARD__; },
    answer:  function (r) { post({type:"answer", rating:r}); },
    tts:     function (t, o) {
      // 第二参：字符串/缺省 = 老写法（lang）；对象 = 指定插件/音色/语速/音调
      if (o == null || typeof o === "string") {
        post({type:"tts", text:t, lang:o||"en-US"});
      } else {
        post(Object.assign({type:"tts", text:t}, o));
      }
    },
    ttsSeq:  function (list) { post({type:"ttsSeq", items:list||[]}); },
    ttsStop: function () { post({type:"ttsStop"}); },
    getState:function (k) { return (window.__FLASHCARD_KV__||{})[k]; },
    setState:function (k, v) { window.__FLASHCARD_KV__[k]=v; post({type:"setState", key:k, value:v}); },
    // ---- JS 日志（JSlogs）：模板层诊断输出，落 logs/js/ ----
    log:     function (tag, msg) {
      post({type:"log", tag: String(tag == null ? "js" : tag),
            msg: String(msg == null ? "" : msg)});
    },
    // ---- 通用消息（阶段 4）：workflow.js 主动给壳发指令 ----
    post:    function (type, data) {
      var o = {type: type};
      if (data) { for (var k in data) { if (Object.prototype.hasOwnProperty.call(data, k)) o[k] = data[k]; } }
      post(o);
    },
    undo:    function () { post({type:"undo"}); },
    // ---- 拼写轮（一轮走完触发，循环在模板里跑）----
    spellDone:     function () { post({type:"spellDone"}); },
    spellProgress: function (d, t) { post({type:"spellProgress", done:d, total:t}); },
    next:    function () { post({type:"next"}); },
    prev:    function () { post({type:"prev"}); },
    ready:   function () { post({type:"ready"}); },
    // ---- SPA：原生侧切卡调用，一次全页重载改成 DOM 增量替换 ----
    mountCard: function (jsonStr) {
      window.__FLASHCARD_CARD__ = JSON.parse(jsonStr);
      if (window.__FLASHCARD_ONMOUNT__) window.__FLASHCARD_ONMOUNT__();
    },
    onMount: function (fn) {
      window.__FLASHCARD_ONMOUNT__ = fn;
    },

    // ---- 双向 RPC（阶段 0）----
    call: call,
    on: on,
    // 壳 -> Web：RPC 回执
    __resolve: function (jsonStr) {
      var m;
      try { m = JSON.parse(jsonStr); } catch (e) { return; }
      var p = pending[m.id];
      if (!p) return;
      delete pending[m.id];
      if (m.ok) p.resolve(m.result);
      else p.reject(new Error((m.result && m.result.error) || "rpc error"));
    },
    // 壳 -> Web：事件推送
    __emit: function (evt, jsonStr) {
      var ls = listeners[evt];
      if (!ls) return;
      var data = {};
      if (jsonStr) { try { data = JSON.parse(jsonStr); } catch (e) {} }
      for (var i = 0; i < ls.length; i++) {
        try { ls[i](data); } catch (e) {}
      }
    }
  };
})();
</script>
<script>$js</script>
${workflowJs.isEmpty ? '' : '<script>$workflowJs</script>'}
</body>
</html>''';
  }

  /// 转成可直接嵌进 JS 单引号字符串的 JSON 文本
  ///
  /// json.encode 输出的是合法 JSON（内部控制符已转义为 \\n \\" 等）。
  /// 这里只补 JS 单引号字符串语境下必要的两层转义：反斜杠、单引号。
  /// 其他字符原样透传 —— 多加任何转义都会在 JSON.parse 后被二次反转，
  /// 把 \\n 变成真换行、把 \\" 变成裸引号，直接炸掉 JSON 结构。
  static String jsonForJs(Object? o) {
    final s = json.encode(o);
    final buf = StringBuffer();
    for (final c in s.runes) {
      final ch = String.fromCharCode(c);
      if (ch == r"'") {
        buf.write(r"\'");
      } else if (ch == r'\') {
        buf.write(r'\\');
      } else {
        buf.write(ch);
      }
    }
    return buf.toString();
  }

  static String _jsonEncode(Object? o) {
    final sb = StringBuffer();
    void enc(Object? v) {
      if (v == null) {
        sb.write('null');
      } else if (v is num || v is bool) {
        sb.write(v.toString());
      } else if (v is String) {
        sb.write('"');
        for (final c in v.runes) {
          final ch = String.fromCharCode(c);
          switch (ch) {
            case '"': sb.write(r'\"'); break;
            case r'\': sb.write(r'\\'); break;
            case '\n': sb.write(r'\n'); break;
            case '\r': sb.write(r'\r'); break;
            case '\t': sb.write(r'\t'); break;
            case '<': sb.write(r'\u003c'); break;
            case '>': sb.write(r'\u003e'); break;
            case '&': sb.write(r'\u0026'); break;
            default:
              if (c < 0x20) {
                sb.write('\\u${c.toRadixString(16).padLeft(4, '0')}');
              } else {
                sb.write(ch);
              }
          }
        }
        sb.write('"');
      } else if (v is List) {
        sb.write('[');
        for (var i = 0; i < v.length; i++) {
          if (i > 0) sb.write(',');
          enc(v[i]);
        }
        sb.write(']');
      } else if (v is Map) {
        sb.write('{');
        var first = true;
        v.forEach((k, val) {
          if (!first) sb.write(',');
          first = false;
          enc(k.toString());
          sb.write(':');
          enc(val);
        });
        sb.write('}');
      } else {
        enc(v.toString());
      }
    }
    enc(o);
    return sb.toString();
  }
}
