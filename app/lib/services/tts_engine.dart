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

/// 一个 TTS 后端
abstract class TtsEngine {
  /// 音频 MIME（喂 just_audio 用）
  String get contentType;

  /// 合成；返回的流可以边收边播
  Stream<List<int>> synthesize(String text);

  Future<void> stop() async {}

  Future<void> dispose() async {}
}

/// OpenAI 兼容 HTTP TTS（声明式插件：/audio/speech）
class OpenAiTtsEngine implements TtsEngine {
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
  Stream<List<int>> synthesize(String text) async* {
    final base = baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
    if (base.isEmpty) throw '未配置 Base URL';
    final req = http.Request('POST', Uri.parse('$base/audio/speech'))
      ..headers['Content-Type'] = 'application/json'
      ..headers['Accept'] = 'audio/*';
    final key = apiKey.trim();
    if (key.isNotEmpty) req.headers['Authorization'] = 'Bearer $key';
    req.body = json.encode({
      'model': model,
      'input': text,
      'voice': voice,
      'response_format': format,
      'speed': speed,
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
class JsTtsEngine implements TtsEngine {
  final JsTtsHost host;
  final String voice;
  final double rate;
  final String _contentType;

  JsTtsEngine(
    this.host, {
    required this.voice,
    this.rate = 1.0,
    String contentType = 'audio/aac',
  }) : _contentType = contentType;

  @override
  String get contentType => _contentType;

  @override
  Stream<List<int>> synthesize(String text) =>
      host.synthesize(text: text, voice: voice, rate: rate);

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
