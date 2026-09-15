/// TTS 引擎抽象 + 实现
/// ================================================================
/// 插件系统里「TTS 插件」的实际执行体：
///   · OpenAiTtsEngine —— engine = openai-tts，纯 HTTP，声明式
///   · JsTtsEngine     —— engine = js，跑在内置 JS 宿主上（豆包那类）
///
/// 统一出口：synthesize(text) → 音频字节流（可以边收边播）。
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'data_dir.dart';
import 'js_tts_host.dart';
import 'plugin.dart';
import 'tts_log.dart';

/// 一次朗读的覆盖参数 —— 模板可以逐条指定用哪个插件、什么音色/语速/音调。
///
/// 全部可空，null = 「用插件配置里的值」：
///   plugin  指定 TTS 插件 id（缺省 = 当前选中的那个）
///   voice   音色 / speaker
///   rate    语速倍率（1.0 = 正常）
///   pitch   音调倍率（1.0 = 正常）
///   extra   透传给 JS 插件的附件参数（并进 getAudioV2 的 request）
class TtsOptions {
  final String? pluginId;
  final String? voice;
  final double? rate;
  final double? pitch;

  /// 是否落盘缓存：null = 跟随全局设置（单词）/ 不落盘（长句）
  /// true = 强制落盘；由 parse 从 cache 字段归一化而来
  final bool? cache;

  /// 自定义缓存文件名前缀（cache 为字符串时）
  final String? cacheName;

  /// 透传给 JS 插件的附件参数（并进 getAudioV2 的 request）
  final Map<String, String> extra;

  const TtsOptions({
    this.pluginId,
    this.voice,
    this.rate,
    this.pitch,
    this.cache,
    this.cacheName,
    this.extra = const {},
  });

  /// 走系统 TTS（flutter_tts）：plugin: "system"
  bool get system => pluginId == 'system';

  bool get isEmpty =>
      pluginId == null &&
      voice == null &&
      rate == null &&
      pitch == null &&
      cache == null &&
      cacheName == null &&
      extra.isEmpty;

  /// 从 bridge 收到的 JSON map 解析
  ///   plugin/voice/rate/pitch/extra + cache(true|"name"|{name})
  static TtsOptions? parse(Object? j) {
    if (j is! Map) return null;
    String? s(String k) {
      final v = '${j[k] ?? ''}'.trim();
      return v.isEmpty ? null : v;
    }

    double? d(String k) {
      final v = j[k];
      return v == null ? null : double.tryParse('$v');
    }

    bool? cache;
    String? cacheName;
    final cv = j['cache'];
    if (cv is bool) {
      cache = cv;
    } else if (cv is String) {
      final n = cv.trim();
      cache = true;
      cacheName = n.isEmpty ? null : n;
    } else if (cv is Map) {
      final n = '${cv['name'] ?? ''}'.trim();
      cache = true;
      cacheName = n.isEmpty ? null : n;
    }

    final extra = <String, String>{};
    final e = j['extra'];
    if (e is Map) e.forEach((k, v) => extra['$k'] = '$v');
    final o = TtsOptions(
      pluginId: s('plugin'),
      voice: s('voice'),
      rate: d('rate'),
      pitch: d('pitch'),
      cache: cache,
      cacheName: cacheName,
      extra: extra,
    );
    return o.isEmpty ? null : o;
  }

  /// 音频身份串（不含 cache —— 存不存不影响音频内容），用于引擎/缓存去重
  String get fingerprint =>
      '${pluginId ?? ''}|${voice ?? ''}|${rate ?? ''}|${pitch ?? ''}|${extraKey(extra)}';

  static String extraKey(Map<String, String> m) {
    final keys = m.keys.toList()..sort();
    return keys.map((k) => '$k=$m[k]').join(',');
  }
}

/// 一个 TTS 后端
abstract class TtsEngine {
  /// 音频 MIME（喂 just_audio 用）
  String get contentType;

  /// 合成；返回的流可以边收边播。[opts] 是模板级覆盖参数，可空。
  Stream<List<int>> synthesize(String text, {TtsOptions? opts});

  Future<void> stop() async {}

  Future<void> dispose() async {}
}

/// OpenAI 兼容 HTTP TTS（声明式插件：/audio/speech）
class OpenAiTtsEngine extends TtsEngine {
  final String baseUrl;
  final String apiKey;
  final String model;
  final String voice;
  final String format;
  final double speed;
  final http.Client _client = http.Client();

  OpenAiTtsEngine({
    required this.baseUrl,
    required this.apiKey,
    required this.model,
    required this.voice,
    required this.format,
    required this.speed,
  });

  @override
  String get contentType => switch (format.toLowerCase()) {
        'wav' => 'audio/wav',
        'aac' => 'audio/aac',
        'opus' => 'audio/opus',
        'flac' => 'audio/flac',
        'pcm' => 'audio/pcm',
        _ => 'audio/mpeg',
      };

  @override
  Stream<List<int>> synthesize(String text, {TtsOptions? opts}) async* {
    final base = baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
    if (base.isEmpty) throw '未配置 Base URL';
    final req = http.Request('POST', Uri.parse('$base/audio/speech'))
      ..headers['Content-Type'] = 'application/json'
      ..headers['Accept'] = 'audio/*';
    final key = apiKey.trim();
    if (key.isNotEmpty) req.headers['Authorization'] = 'Bearer $key';
    final v = (opts?.voice ?? voice).trim();
    final sp = opts?.rate ?? speed;
    req.body = json.encode({
      'model': model,
      'input': text,
      'voice': v.isEmpty ? 'alloy' : v,
      'response_format': format,
      'speed': sp,
    });
    final resp = await _client.send(req).timeout(const Duration(seconds: 20));
    if (resp.statusCode != 200) {
      final body = await resp.stream
          .bytesToString()
          .timeout(const Duration(seconds: 5));
      await TtsLog.write('openai', 'HTTP ${resp.statusCode}: ${_abbr(body)}');
      throw TtsHttpException(resp.statusCode, body);
    }
    yield* resp.stream;
  }

  @override
  Future<void> dispose() async => _client.close();
}

/// JS 脚本插件（豆包那类，跑在内置 QuickJS 宿主上）
class JsTtsEngine extends TtsEngine {
  final JsTtsHost host;
  final String voice;
  final double rate;
  final double pitch;
  final String _contentType;

  JsTtsEngine(
    this.host, {
    required this.voice,
    this.rate = 1.0,
    this.pitch = 1.0,
    String contentType = 'audio/aac',
  }) : _contentType = contentType;

  @override
  String get contentType => _contentType;

  @override
  Stream<List<int>> synthesize(String text, {TtsOptions? opts}) => host.synthesize(
        text: text,
        voice: opts?.voice ?? voice,
        rate: opts?.rate ?? rate,
        pitch: opts?.pitch ?? pitch,
        extra: opts?.extra ?? const {},
      );

  @override
  Future<void> stop() async => host.cancelCurrent();

  @override
  Future<void> dispose() => host.dispose();
}

/// 按插件清单造引擎
Future<TtsEngine?> buildTtsEngine(
    PluginManifest m, Map<String, String> vars) async {
  switch (m.engine) {
    case PluginEngine.openaiTts:
      return OpenAiTtsEngine(
        baseUrl: vars['base_url'] ?? '',
        apiKey: vars['api_key'] ?? '',
        model: (vars['model'] ?? '').isEmpty ? 'gpt-4o-mini-tts' : vars['model']!,
        voice: (vars['voice'] ?? '').isEmpty ? 'alloy' : vars['voice']!,
        format: (vars['format'] ?? '').isEmpty ? 'mp3' : vars['format']!,
        speed: double.tryParse(vars['speed'] ?? '1.0') ?? 1.0,
      );
    case PluginEngine.js:
      final script = await m.loadScript();
      if (script == null) {
        await TtsLog.write('plugin', '插件 ${m.id} 找不到脚本 ${m.entry}');
        return null;
      }
      final cacheDir = await DataDir.sub('plugins/.cache');
      final host = JsTtsHost.create(fsDir: cacheDir);
      final ok = await host.load(script, vars);
      if (!ok) {
        await host.dispose();
        return null;
      }
      final fmt = '${m.defaults['audio_format'] ?? 'aac'}'.toLowerCase();
      return JsTtsEngine(
        host,
        voice: vars['voice'] ?? '',
        rate: double.tryParse(vars['rate'] ?? '1.0') ?? 1.0,
        pitch: double.tryParse(vars['pitch'] ?? '1.0') ?? 1.0,
        contentType: fmt == 'mp3' ? 'audio/mpeg' : 'audio/aac',
      );
    case PluginEngine.openaiChat:
      return null;
  }
}

String _abbr(String s) => s.length <= 200 ? s : '${s.substring(0, 200)}…';

class TtsHttpException implements Exception {
  final int code;
  final String body;
  TtsHttpException(this.code, this.body);
  @override
  String toString() => 'TTS HTTP $code: ${_abbr(body)}';
}
