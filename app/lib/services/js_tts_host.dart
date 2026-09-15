/// JS 插件宿主（TTS）
/// ================================================================
/// 用 flutter_js（Android 上是 QuickJS）跑「TTS Server」那套 JS 插件，
/// 宿主 API 全部由 Dart 喂：
///   ttsrv.userVars            配置项（如 cookie）
///   logger.i/d/e/w            日志
///   console.log               已由 flutter_js 自带
///   Websocket(url, headers)   .on('open'|'binary'|'text'|'close'|'error') / .send() / .cancel()
///                             —— 自定义请求头 / 二进制帧，浏览器 WebSocket 做不到，只有宿主能做
///   http.post/get             宿主未实现（v1 直接跳过并记日志）
///   fs.exists/readText/writeFile
///
/// 插件契约（同 TTS Server）：
///   PluginJS.getAudioV2({text, voice, rate, pitch}, callback)
///     callback.write(Uint8Array) / callback.close() / callback.error(msg)
///
/// 跨语言：二进制一律 base64；宿主 → JS 用 evaluate 推事件，JS → 宿主用 sendMessage。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_js/flutter_js.dart';

import 'tts_log.dart';

class _Session {
  final StreamController<List<int>> out = StreamController<List<int>>();
  _Session();
}

class JsTtsHost {
  final JavascriptRuntime _rt;
  final Directory? _fsDir;

  final Map<String, WebSocket> _sockets = {};
  final Map<String, _Session> _sessions = {};
  int _seq = 0;
  bool _scriptLoaded = false;
  String? _lastError;

  JsTtsHost._(this._rt, this._fsDir);

  String? get lastError => _lastError;

  static JsTtsHost create({Directory? fsDir}) {
    final rt = getJavascriptRuntime(xhr: false);
    final h = JsTtsHost._(rt, fsDir);
    h._installBridges();
    h._rt.evaluate(_prelude);
    return h;
  }

  /// 注入配置 + 载入插件脚本（只做一次）
  Future<bool> load(String script, Map<String, String> userVars) async {
    if (_scriptLoaded) return true;
    try {
      _rt.evaluate('globalThis.ttsrv = { userVars: ${jsonEncode(userVars)} };');
      _rt.evaluate('$script\n;globalThis.PluginJS = PluginJS;');
      _scriptLoaded = true;
      await TtsLog.write('plugin', '脚本已载入（${script.length} 字符）');
      return true;
    } catch (e, st) {
      _lastError = '$e';
      await TtsLog.write('plugin', 'ERROR 载入脚本: $e\n$st');
      return false;
    }
  }

  /// 合成一段文本，返回音频字节流
  ///
  /// [extra] 会被并进发给插件的 request 顶层，插件支持就吃、不支持就忽略。
  Stream<List<int>> synthesize({
    required String text,
    required String voice,
    double rate = 1.0,
    double pitch = 1.0,
    Map<String, String> extra = const {},
  }) {
    final id = 's${_seq++}';
    final s = _Session();
    _sessions[id] = s;
    // TTS Server 的 rate/pitch 是 0~100（50 = 正常）
    final req = <String, dynamic>{
      'text': text,
      'voice': voice,
      'rate': (rate * 50).round(),
      'pitch': (pitch * 50).round(),
      ...extra,
    };
    try {
      _rt.evaluate("__startTts('$id', ${jsonEncode(req)});");
    } catch (e) {
      _sessions.remove(id);
      s.out.addError('$e');
      s.out.close();
      TtsLog.write('plugin', 'ERROR startTts: $e');
    }
    return s.out.stream;
  }

  void _installBridges() {
    _rt.onMessage('ttsrv.log', (args) {
      try {
        final m = args as Map;
        TtsLog.write('plugin', '[${m['l'] ?? 'i'}] ${m['m'] ?? ''}');
      } catch (_) {}
      return '';
    });

    _rt.onMessage('ttsrv.fs', (args) {
      final dir = _fsDir;
      if (dir == null) return '';
      try {
        final m = args as Map;
        final op = '${m['op']}';
        final f = File('${dir.path}/${_safeName('${m['name'] ?? ''}')}');
        switch (op) {
          case 'exists':
            return '${f.existsSync()}';
          case 'readText':
            return f.existsSync() ? f.readAsStringSync() : '';
          case 'writeFile':
            if (!f.parent.existsSync()) f.parent.createSync(recursive: true);
            f.writeAsStringSync('${m['text'] ?? ''}');
            return 'true';
        }
      } catch (_) {}
      return '';
    });

    _rt.onMessage('ttsrv.ws.open', (args) {
      final m = args as Map;
      final headers = <String, String>{};
      if (m['headers'] is Map) {
        (m['headers'] as Map).forEach((k, v) => headers['$k'] = '$v');
      }
      _open('${m['id']}', '${m['url']}', headers);
      return 'true';
    });

    _rt.onMessage('ttsrv.ws.send', (args) {
      final m = args as Map;
      final ws = _sockets['${m['id']}'];
      if (ws == null) return 'false';
      try {
        final data = '${m['data'] ?? ''}';
        if (m['binary'] == true) {
          ws.add(base64.decode(data));
        } else {
          ws.add(data);
        }
        return 'true';
      } catch (_) {
        return 'false';
      }
    });

    _rt.onMessage('ttsrv.ws.close', (args) {
      final m = args as Map;
      _sockets.remove('${m['id']}')?.close();
      return 'true';
    });

    _rt.onMessage('ttsrv.audio.write', (args) {
      final m = args as Map;
      final s = _sessions['${m['id']}'];
      if (s == null) return '';
      try {
        s.out.add(base64.decode('${m['b64'] ?? ''}'));
      } catch (_) {}
      return '';
    });

    _rt.onMessage('ttsrv.audio.close', (args) {
      final m = args as Map;
      final s = _sessions.remove('${m['id']}');
      if (s != null && !s.out.isClosed) s.out.close();
      return '';
    });

    _rt.onMessage('ttsrv.audio.error', (args) {
      final m = args as Map;
      final s = _sessions.remove('${m['id']}');
      final msg = '${m['m'] ?? 'plugin error'}';
      _lastError = msg;
      TtsLog.write('plugin', 'audio error: $msg');
      if (s != null && !s.out.isClosed) {
        s.out.addError(msg);
        s.out.close();
      }
      return '';
    });
  }

  Future<void> _open(String id, String url, Map<String, String> headers) async {
    try {
      final ws = await WebSocket.connect(url, headers: headers)
          .timeout(const Duration(seconds: 15));
      _sockets[id] = ws;
      ws.listen(
        (data) {
          if (data is List<int>) {
            _emit(id, 'binary', base64.encode(data));
          } else {
            _emit(id, 'text', base64.encode(utf8.encode('$data')));
          }
        },
        onError: (e) => _emit(id, 'error', base64.encode(utf8.encode('$e'))),
        onDone: () => _emit(id, 'close', ''),
        cancelOnError: true,
      );
      _emit(id, 'open', '');
    } catch (e) {
      await TtsLog.write('plugin', 'ws open 失败: $e');
      _emit(id, 'error', base64.encode(utf8.encode('$e')));
      _emit(id, 'close', '');
    }
  }

  /// 把事件推进 JS（Dart → JS）
  void _emit(String id, String ev, String b64) {
    try {
      _rt.evaluate("__wsEmit('$id', '$ev', '$b64');");
    } catch (e) {
      TtsLog.write('plugin', 'ws emit 失败: $e');
    }
  }

  static String _safeName(String n) =>
      n.replaceAll('..', '_').replaceAll('/', '_').replaceAll('\\', '_');

  Future<void> dispose() async {
    for (final ws in _sockets.values) {
      try {
        await ws.close();
      } catch (_) {}
    }
    _sockets.clear();
    for (final s in _sessions.values) {
      if (!s.out.isClosed) s.out.close();
    }
    _sessions.clear();
    try {
      _rt.dispose();
    } catch (_) {}
  }

  /// JS 侧宿主环境（原样字符串，别做 Dart 插值）
  static const _prelude = r'''
var __B64C = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
function __b64enc(input) {
  var bytes;
  if (typeof input === 'string') { bytes = __utf8enc(input); }
  else if (input instanceof Uint8Array) { bytes = input; }
  else if (input && input.buffer) { bytes = new Uint8Array(input.buffer); }
  else if (input && typeof input.length === 'number') { bytes = input; }
  else { bytes = []; }
  var out = '';
  for (var i = 0; i < bytes.length; i += 3) {
    var b1 = bytes[i] & 0xff;
    var b2 = i + 1 < bytes.length ? bytes[i + 1] & 0xff : NaN;
    var b3 = i + 2 < bytes.length ? bytes[i + 2] & 0xff : NaN;
    var e1 = b1 >> 2;
    var e2 = ((b1 & 3) << 4) | (isNaN(b2) ? 0 : (b2 >> 4));
    var e3 = isNaN(b2) ? 64 : (((b2 & 15) << 2) | (isNaN(b3) ? 0 : (b3 >> 6)));
    var e4 = isNaN(b3) ? 64 : (b3 & 63);
    out += __B64C.charAt(e1) + __B64C.charAt(e2)
      + (e3 === 64 ? '=' : __B64C.charAt(e3))
      + (e4 === 64 ? '=' : __B64C.charAt(e4));
  }
  return out;
}
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
function __utf8enc(str) {
  var out = [];
  for (var i = 0; i < str.length; i++) {
    var c = str.charCodeAt(i);
    if (c < 0x80) { out.push(c); }
    else if (c < 0x800) { out.push(0xC0 | (c >> 6)); out.push(0x80 | (c & 0x3F)); }
    else if (c >= 0xD800 && c <= 0xDBFF && i + 1 < str.length) {
      var n = str.charCodeAt(i + 1);
      var cp = 0x10000 + ((c - 0xD800) << 10) + (n - 0xDC00);
      out.push(0xF0 | (cp >> 18)); out.push(0x80 | ((cp >> 12) & 0x3F));
      out.push(0x80 | ((cp >> 6) & 0x3F)); out.push(0x80 | (cp & 0x3F));
      i++;
    } else {
      out.push(0xE0 | (c >> 12)); out.push(0x80 | ((c >> 6) & 0x3F)); out.push(0x80 | (c & 0x3F));
    }
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
function __hostRaw(ch, obj) { return sendMessage(ch, JSON.stringify(obj)); }

var ttsrv = { userVars: {} };

var logger = {
  i: function (m) { __hostRaw('ttsrv.log', { l: 'i', m: String(m) }); },
  d: function (m) { __hostRaw('ttsrv.log', { l: 'd', m: String(m) }); },
  w: function (m) { __hostRaw('ttsrv.log', { l: 'w', m: String(m) }); },
  e: function (m) { __hostRaw('ttsrv.log', { l: 'e', m: String(m) }); }
};

var fs = {
  exists: function (n) { return __hostRaw('ttsrv.fs', { op: 'exists', name: String(n) }) === 'true'; },
  readText: function (n) { return __hostRaw('ttsrv.fs', { op: 'readText', name: String(n) }); },
  writeFile: function (n, t) { __hostRaw('ttsrv.fs', { op: 'writeFile', name: String(n), text: String(t) }); }
};

var http = {
  post: function (url) {
    __hostRaw('ttsrv.log', { l: 'w', m: 'http.post 宿主未实现，已跳过：' + url });
    return { text: function () { return ''; }, json: function () { return {}; } };
  },
  get: function (url) {
    __hostRaw('ttsrv.log', { l: 'w', m: 'http.get 宿主未实现，已跳过：' + url });
    return { text: function () { return ''; } };
  }
};

var __wsMap = {};
var __wsSeq = 0;
function Websocket(url, headers) {
  var self = this;
  __wsSeq += 1;
  var id = 'w' + __wsSeq;
  __wsMap[id] = self;
  self._id = id;
  self._h = {};
  self._q = [];
  self.on = function (ev, cb) {
    self._h[ev] = cb;
    for (var i = 0; i < self._q.length; i++) {
      if (self._q[i][0] === ev) {
        try { cb.apply(null, self._q[i][1]); } catch (e) {}
      }
    }
    self._q = self._q.filter(function (x) { return x[0] !== ev; });
  };
  self.send = function (data) {
    var binary = (typeof data !== 'string');
    var payload = __b64enc(binary ? data : String(data));
    return __hostRaw('ttsrv.ws.send', { id: id, data: payload, binary: binary }) === 'true';
  };
  self.cancel = function () { __hostRaw('ttsrv.ws.close', { id: id }); };
  __hostRaw('ttsrv.ws.open', { id: id, url: String(url), headers: headers || {} });
  return self;
}
function __wsEmit(id, ev, b64) {
  var ws = __wsMap[id];
  if (!ws) return;
  var args;
  if (ev === 'binary') { args = [__b64dec(b64)]; }
  else if (ev === 'text') { args = [__b64str(b64)]; }
  else if (ev === 'open') { args = []; }
  else if (ev === 'close') { args = [1000, '']; __wsMap[id] = null; }
  else if (ev === 'error') { args = [__b64str(b64), null]; __wsMap[id] = null; }
  else { args = []; }
  var h = ws._h[ev];
  if (h) {
    try { h.apply(null, args); } catch (e) { __hostRaw('ttsrv.log', { l: 'e', m: 'ws ' + ev + ': ' + e }); }
  } else {
    ws._q.push([ev, args]);
  }
}
function __startTts(id, req) {
  var cb = {
    write: function (u8) { __hostRaw('ttsrv.audio.write', { id: id, b64: __b64enc(u8) }); },
    close: function () { __hostRaw('ttsrv.audio.close', { id: id }); },
    error: function (e) { __hostRaw('ttsrv.audio.error', { id: id, m: String(e) }); }
  };
  try {
    if (typeof PluginJS === 'undefined' || !PluginJS.getAudioV2) {
      cb.error('插件没实现 PluginJS.getAudioV2');
      return;
    }
    PluginJS.getAudioV2(req, cb);
  } catch (e) {
    cb.error('插件异常: ' + e);
  }
}
''';
}
