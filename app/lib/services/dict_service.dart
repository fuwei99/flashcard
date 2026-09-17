/// 有道词典（有道智云 · 查词 v3）
/// ================================================================
/// 为什么在壳侧：WebView 里直接 fetch 有道会被 CORS 拦，而且签名要 appSecret，
/// 绝不能塞进模板 JS。所以模板只发 `dict.lookup`，壳侧做签名 + HTTP。
///
/// 配置落盘：`Flashcard/settings/dict.json`
///   { "appKey": "xxx", "appSecret": "yyy" }
/// 模板设置页可写（RPC dict.setConfig），也可用文件管理器 / Agent 直接改。
///
/// 签名（v3）：
///   input = q 长度 <= 20 ? q : q[:10] + len(q) + q[-10:]
///   sign  = sha256(appKey + input + salt + curtime + appSecret)
///   表单：q, from=en, to=zh-CHS, appKey, salt, sign, signType=v3, curtime
library;

import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import 'data_dir.dart';

class DictService {
  static const _endpoint = 'https://openapi.youdao.com/api';
  static const _cfgFile = 'settings/dict.json';

  static String _appKey = '';
  static String _appSecret = '';
  static bool _loaded = false;

  /// 进程内缓存：同一个词不重复打接口
  static final Map<String, Map<String, dynamic>?> _cache = {};

  static bool get loaded => _loaded;

  /// 首次用到时读一次盘
  static Future<void> ensureLoaded() async {
    if (_loaded) return;
    await DataDir.root();
    final d = DataDir.readJsonSync(_cfgFile);
    _appKey = (d?['appKey'] ?? '').toString().trim();
    _appSecret = (d?['appSecret'] ?? '').toString().trim();
    _loaded = true;
  }

  static Map<String, dynamic> config() => {
        'appKey': _appKey,
        'hasSecret': _appSecret.isNotEmpty,
        'configured': _appKey.isNotEmpty && _appSecret.isNotEmpty,
      };

  /// 写配置并清缓存（换 key 后立刻生效）
  static Future<Map<String, dynamic>> setConfig(
      String appKey, String appSecret) async {
    await DataDir.root();
    _appKey = appKey.trim();
    _appSecret = appSecret.trim();
    _cache.clear();
    _loaded = true;
    await DataDir.writeJson(
        _cfgFile, {'appKey': _appKey, 'appSecret': _appSecret});
    return config();
  }

  static String _sign(String q, String salt, String curtime) {
    final len = q.length;
    final input =
        len <= 20 ? q : '${q.substring(0, 10)}$len${q.substring(len - 10)}';
    final raw = '$_appKey$input$salt$curtime$_appSecret';
    return sha256.convert(utf8.encode(raw)).toString();
  }

  /// 查词。未配置 / 网络错 / 未收录 → null
  static Future<Map<String, dynamic>?> lookup(String word) async {
    await ensureLoaded();
    final q = word.trim();
    if (q.isEmpty) return null;
    final key = q.toLowerCase();
    if (_cache.containsKey(key)) return _cache[key];
    if (_appKey.isEmpty || _appSecret.isEmpty) return null;

    final salt = _uuid();
    final curtime = (DateTime.now().millisecondsSinceEpoch ~/ 1000).toString();
    final sign = _sign(q, salt, curtime);

    try {
      final resp = await http.post(
        Uri.parse(_endpoint),
        body: {
          'q': q,
          'from': 'en',
          'to': 'zh-CHS',
          'appKey': _appKey,
          'salt': salt,
          'sign': sign,
          'signType': 'v3',
          'curtime': curtime,
        },
      ).timeout(const Duration(seconds: 8));

      if (resp.statusCode != 200) return null;
      final j = json.decode(utf8.decode(resp.bodyBytes));
      if (j is! Map) return null;
      if ('${j['errorCode']}' != '0') return null;

      final entry = _normalize(q, j);
      _cache[key] = entry;
      return entry;
    } catch (_) {
      return null;
    }
  }

  /// 拍成模板要的 dictEntry 形状：
  /// { word, phonetic, level, senses:[{pos,cn}], collocations, examples, fromApi }
  static Map<String, dynamic> _normalize(String q, Map j) {
    String phonetic = '';
    final senses = <Map<String, dynamic>>[];

    final basic = j['basic'];
    if (basic is Map) {
      phonetic =
          (basic['us-phonetic'] ?? basic['phonetic'] ?? '').toString().trim();
      final explains = basic['explains'];
      if (explains is List) {
        for (final e in explains) {
          final s = e.toString().trim();
          if (s.isEmpty) continue;
          // "adj. 好的；令人满意的" → pos="adj." cn="好的；令人满意的"
          final m = RegExp(r'^([a-zA-Z]+\.)\s*(.+)$').firstMatch(s);
          if (m != null) {
            senses.add({'pos': m.group(1), 'cn': m.group(2)});
          } else {
            senses.add({'pos': '', 'cn': s});
          }
        }
      }
    }
    // basic 没有就退到 translation
    if (senses.isEmpty && j['translation'] is List) {
      for (final t in j['translation']) {
        final s = t.toString().trim();
        if (s.isNotEmpty) senses.add({'pos': '', 'cn': s});
      }
    }

    // web 网络释义 → 当例句用
    final examples = <Map<String, dynamic>>[];
    final web = j['web'];
    if (web is List) {
      for (final w in web) {
        if (w is! Map) continue;
        final k = (w['key'] ?? '').toString().trim();
        final v = w['value'];
        final cn = v is List && v.isNotEmpty ? v.first.toString() : '';
        if (k.isEmpty || cn.isEmpty) continue;
        examples.add({'en': k, 'cn': cn, 'src': '网络释义'});
        if (examples.length >= 3) break;
      }
    }

    return {
      'word': (j['query'] ?? q).toString(),
      'phonetic': phonetic,
      'level': '',
      'senses': senses,
      'collocations': <Map<String, dynamic>>[],
      'examples': examples,
      'fromApi': true,
      'source': 'youdao',
    };
  }

  static String _uuid() {
    final r = Random();
    final b = List.generate(16, (_) => r.nextInt(256));
    return b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  }
}
