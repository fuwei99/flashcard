/// 通用 JS 插件宿主
/// ================================================================
/// 壳**只提供原语**，业务逻辑（签名 / 解析 / 缓存 / 密钥）全在插件 JS 里 ——
/// 往 `Flashcard/plugins/` 丢一个 .js 就是一个新插件，不用改壳、不用重编。
///
/// 为什么用 JS 宿主而不是纯声明式：
///   有道要 sha256 动态签名，声明式配置表达不了；塞回壳又违背「壳不认识业务」。
///   QuickJS 里能跑任意逻辑，壳只当代发 HTTP 的手。
///
/// 为什么要宿主代发 HTTP：
///   WebView 里 fetch 会被 CORS 拦；插件里也绝不能出现 appSecret 明文落页面。
///   插件跑在壳内 QuickJS，HTTP 由 Dart 发，两个问题一起解决。
///
/// 宿主原语（注入每个插件的作用域）：
///   logger.i/w/e(msg)                        日志 → JsLog（[v1] 标签）
///   http.post(url, {headers, body}, cb)      真 HTTP；cb(err, {status, text, json()})
///   http.get(url, {headers}, cb)
///   kv.get(key) → String                     插件私有 KV（落 plugins/<id>/kv.json）
///   kv.set(key, value)
///   registerPlugin({id, name, methods})
///
/// 壳 RPC（模板用）：
///   plugin.list                      → [{id, name, methods:[...]}]
///   plugin.call {id, method, args}   → {ok, data} | {ok:false, error}
///   plugin.reload                    → 重扫插件目录
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_js/flutter_js.dart';
import 'package:http/http.dart' as http;

import 'data_dir.dart';
import 'js_log.dart';
import 'plugin.dart';

class JsPluginHost {
  final JavascriptRuntime _rt;
  final Map<String, Completer<Map<String, dynamic>>> _pending = {};
  final Map<String, String> _name = {};           // id -> 显示名
  final Map<String, List<String>> _methods = {};  // id -> 方法表
  int _seq = 0;
  bool _loaded = false;

  /// 首次调用前扫一遍插件目录（幂等）
  Future<void> ensureLoaded() async {
    if (_loaded) return;
    _loaded = true;
    await reload();
  }

  JsPluginHost._(this._rt) {
    _installBridges();
    _rt.evaluate(_prelude);
  }

  static JsPluginHost create() =>
      JsPluginHost._(getJavascriptRuntime(xhr: false));

  /// 全局单例：壳里所有 plugin.* RPC 共用一个 QuickJS 运行时
  static JsPluginHost? _instance;
  static JsPluginHost get instance => _instance ??= create();

  /// 某插件注册的方法表
  List<String> methodsOf(String id) => _methods[id] ?? const [];

  /// 插件清单
  List<Map<String, dynamic>> list() => _methods.keys
      .map((id) => {'id': id, 'name': _name[id] ?? id, 'methods': _methods[id]})
      .toList();

  /// 重新加载所有「tool + js」插件。
  ///
  /// 发现工作交给 PluginManager（唯一真源），这里只负责把它们的脚本
  /// 灌进 QuickJS 运行时。TTS 的 js 插件走 JsTtsHost，不归这管。
  Future<int> reload() async {
    _loaded = true;
    await PluginManager.I.load();
    final list = PluginManager.I.all
        .where((p) => p.type == PluginType.tool && p.engine == PluginEngine.js)
        .toList();

    _methods.clear();
    _name.clear();
    try {
      _rt.evaluate('globalThis.__plugins = {};');
    } catch (_) {}

    var n = 0;
    for (final p in list) {
      try {
        final code = await p.loadScript();
        if (code == null) continue;
        _rt.evaluate('__loadPlugin(${jsonEncode(p.id)}, ${jsonEncode(code)});');
        n++;
      } catch (e) {
        await JsLog.write('v1', '插件加载失败 ${p.id}: $e');
      }
    }
    await JsLog.write(
        'v1', '工具插件重载：$n 个 · ${list.map((e) => e.id).join(",")}');
    return n;
  }

  /// 调插件方法；永远 resolve（失败也是 {ok:false}），绝不把异常抛给模板
  Future<Map<String, dynamic>> call(
      String id, String method, Map<String, dynamic> args) {
    final callId = 'c${_seq++}';
    final c = Completer<Map<String, dynamic>>();
    _pending[callId] = c;
    try {
      _rt.evaluate('__pluginCall(${jsonEncode(callId)}, ${jsonEncode(id)}, '
          '${jsonEncode(method)}, ${jsonEncode(jsonEncode(args))});');
    } catch (e) {
      _pending.remove(callId);
      return Future.value({'ok': false, 'error': '$e'});
    }
    return c.future.timeout(const Duration(seconds: 15), onTimeout: () {
      _pending.remove(callId);
      return {'ok': false, 'error': 'timeout'};
    });
  }

  void _installBridges() {
    _rt.onMessage('plugin.log', (args) {
      try {
        final m = args as Map;
        JsLog.write('v1', '[plugin/${m['l'] ?? 'i'}] ${m['m'] ?? ''}');
      } catch (_) {}
      return '';
    });

    _rt.onMessage('plugin.reg', (args) {
      try {
        final m = args as Map;
        final id = '${m['id']}';
        _name[id] = '${m['name'] ?? id}';
        final ms = m['methods'];
        _methods[id] =
            ms is List ? ms.map((e) => '$e').toList() : <String>[];
        JsLog.write('v1', '插件注册 $id → ${_methods[id]}');
      } catch (_) {}
      return 'true';
    });

    // 插件私有 KV（同步返回，走 onMessage 的返回值通道）
    _rt.onMessage('plugin.kv', (args) {
      try {
        final m = args as Map;
        final pid = '${m['pid']}';
        final op = '${m['op']}';
        final k = '${m['k']}';
        if (op == 'get') return _kvGet(pid, k);
        if (op == 'set') {
          _kvSet(pid, k, '${m['v'] ?? ''}');
          return 'true';
        }
      } catch (_) {}
      return '';
    });

    // HTTP：立即返回，真正结果由 _doHttp 异步 evaluate 回推
    _rt.onMessage('plugin.http', (args) {
      try {
        _doHttp(args as Map);
      } catch (_) {}
      return 'true';
    });

    _rt.onMessage('plugin.result', (args) {
      try {
        final m = args as Map;
        final c = _pending.remove('${m['id']}');
        if (c == null || c.isCompleted) return '';
        if (m['ok'] == true) {
          dynamic data;
          try {
            data = jsonDecode('${m['data'] ?? 'null'}');
          } catch (_) {
            data = null;
          }
          c.complete({'ok': true, 'data': data});
        } else {
          c.complete({'ok': false, 'error': '${m['err'] ?? 'plugin error'}'});
        }
      } catch (_) {}
      return '';
    });
  }

  Future<void> _doHttp(Map m) async {
    final id = '${m['id']}';
    final method = '${m['method'] ?? 'GET'}'.toUpperCase();
    final url = '${m['url']}';
    final headers = <String, String>{};
    if (m['headers'] is Map) {
      (m['headers'] as Map).forEach((k, v) => headers['$k'] = '$v');
    }
    final body = '${m['body'] ?? ''}';
    final ct = '${m['contentType'] ?? ''}';
    try {
      final req = http.Request(method, Uri.parse(url));
      req.headers.addAll(headers);
      if (ct.isNotEmpty) req.headers['Content-Type'] = ct;
      if (body.isNotEmpty) req.body = body;
      final resp =
          await http.Client().send(req).timeout(const Duration(seconds: 10));
      final bytes = await resp.stream.toBytes();
      _emitHttp(id, resp.statusCode, base64.encode(bytes));
    } catch (e) {
      await JsLog.write('v1', 'plugin http 失败: $e');
      _emitHttp(id, 0, '');
    }
  }

  void _emitHttp(String id, int status, String b64) {
    try {
      _rt.evaluate("__httpDone('$id', $status, '$b64');");
    } catch (_) {}
  }

  // ---- 插件私有 KV：Flashcard/plugins/<id>/kv.json ----
  String _kvGet(String pid, String k) {
    final d = DataDir.readJsonSync('plugins/$pid/kv.json');
    final v = d?[k];
    return v == null ? '' : (v is String ? v : jsonEncode(v));
  }

  void _kvSet(String pid, String k, String v) {
    final d = DataDir.readJsonSync('plugins/$pid/kv.json') ?? <String, dynamic>{};
    d[k] = v;
    DataDir.writeJsonSync('plugins/$pid/kv.json', d);
  }

  void dispose() {
    for (final c in _pending.values) {
      if (!c.isCompleted) c.complete({'ok': false, 'error': 'disposed'});
    }
    _pending.clear();
    try {
      _rt.dispose();
    } catch (_) {}
  }

  /// JS 侧宿主环境（原样字符串，别做 Dart 插值）
  static const _prelude = r'''
function __hostRaw(ch, obj) { return sendMessage(ch, JSON.stringify(obj)); }

var logger = {
  i: function (m) { __hostRaw('plugin.log', { l: 'i', m: String(m) }); },
  w: function (m) { __hostRaw('plugin.log', { l: 'w', m: String(m) }); },
  e: function (m) { __hostRaw('plugin.log', { l: 'e', m: String(m) }); }
};

// ---- base64 / utf8（Dart ↔ JS 二进制通道）----
var __B64C = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
function __b64dec(str) {
  var out = [], buf = 0, bits = 0;
  for (var i = 0; i < str.length; i++) {
    var c = str.charAt(i);
    if (c === '=') break;
    var v = __B64C.indexOf(c);
    if (v < 0) continue;
    buf = (buf << 6) | v; bits += 6;
    if (bits >= 8) { bits -= 8; out.push((buf >> bits) & 0xff); }
  }
  return new Uint8Array(out);
}
function __utf8dec(bytes) {
  var out = '', i = 0;
  while (i < bytes.length) {
    var c = bytes[i++];
    if (c < 0x80) { out += String.fromCharCode(c); }
    else if (c < 0xE0) { out += String.fromCharCode(((c & 0x1F) << 6) | (bytes[i++] & 0x3F)); }
    else if (c < 0xF0) { out += String.fromCharCode(((c & 0x0F) << 12) | ((bytes[i++] & 0x3F) << 6) | (bytes[i++] & 0x3F)); }
    else {
      var cp = ((c & 0x07) << 18) | ((bytes[i++] & 0x3F) << 12) | ((bytes[i++] & 0x3F) << 6) | (bytes[i++] & 0x3F);
      cp -= 0x10000;
      out += String.fromCharCode(0xD800 + (cp >> 10), 0xDC00 + (cp & 0x3FF));
    }
  }
  return out;
}
function __b64str(s) { return __utf8dec(__b64dec(s)); }

// ---- HTTP（真请求由 Dart 代发，绕开 WebView CORS）----
var __httpPending = {};
var __httpSeq = 0;
var http = {
  request: function (method, url, opts, cb) {
    if (typeof opts === 'function') { cb = opts; opts = {}; }
    opts = opts || {};
    var id = 'h' + (++__httpSeq);
    __httpPending[id] = cb;
    var body = opts.body == null ? '' : String(opts.body);
    __hostRaw('plugin.http', {
      id: id, method: String(method), url: String(url),
      headers: opts.headers || {}, body: body, contentType: opts.contentType || ''
    });
  },
  get: function (url, opts, cb) { http.request('GET', url, opts, cb); },
  post: function (url, opts, cb) { http.request('POST', url, opts, cb); }
};
function __httpDone(id, status, b64) {
  var cb = __httpPending[id];
  if (!cb) return;
  delete __httpPending[id];
  var text = __b64str(b64);
  try {
    cb(null, {
      status: status, text: text,
      json: function () { try { return JSON.parse(text); } catch (e) { return null; } }
    });
  } catch (e) { __hostRaw('plugin.log', { l: 'e', m: 'http 回调抛错: ' + e }); }
}

// ---- 插件注册表 ----
var __plugins = {};
function __loadPlugin(pid, code) {
  var myKv = {
    get: function (k) { return __hostRaw('plugin.kv', { pid: pid, op: 'get', k: String(k) }); },
    set: function (k, v) {
      __hostRaw('plugin.kv', { pid: pid, op: 'set', k: String(k),
        v: (typeof v === 'string' ? v : JSON.stringify(v)) });
    }
  };
  var reg = function (def) {
    if (!def || !def.id) return;
    __plugins[def.id] = def;
    var ms = [];
    if (def.methods) { for (var k in def.methods) { if (def.methods.hasOwnProperty(k)) ms.push(k); } }
    __hostRaw('plugin.reg', { id: def.id, name: def.name || def.id, methods: ms });
  };
  try {
    var fn = new Function('kv', 'logger', 'http', 'registerPlugin', code);
    fn(myKv, logger, http, reg);
  } catch (e) {
    __hostRaw('plugin.log', { l: 'e', m: '插件 ' + pid + ' 执行失败: ' + e });
  }
}
function __pluginCall(callId, pluginId, method, argsJson) {
  var p = __plugins[pluginId];
  if (!p) { __hostRaw('plugin.result', { id: callId, ok: false, err: '没有插件: ' + pluginId }); return; }
  var fn = p.methods ? p.methods[method] : null;
  if (typeof fn !== 'function') { __hostRaw('plugin.result', { id: callId, ok: false, err: '没有方法: ' + method }); return; }
  var args = {};
  try { args = JSON.parse(argsJson || '{}'); } catch (e) {}
  var done = false;
  var cb = function (err, res) {
    if (done) return;
    done = true;
    if (err) { __hostRaw('plugin.result', { id: callId, ok: false, err: String(err) }); }
    else { __hostRaw('plugin.result', { id: callId, ok: true, data: JSON.stringify(res == null ? null : res) }); }
  };
  try { fn(args, cb); } catch (e) { cb(e); }
}
''';
}
