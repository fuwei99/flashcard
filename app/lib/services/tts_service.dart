/// TTS 服务：统一入口（在线 OpenAI 兼容 TTS 为主）+ 单词缓存 + 长句流式
/// ================================================================
///   Flashcard.tts(text, lang)
///        │
///   TtsService.speak(text, lang)
///        ├── 单个英文词  → 查 cache/tts/ 命中秒播；
///        │                未命中 POST /v1/audio/speech 拿全字节 → 存盘 → 播
///        └── 其它（长句）→ POST 的响应字节流**直接喂 StreamAudioSource**，
///                          边收边播（不缓存、不先攒完整包）
///
/// 兜底：在线没配置 / 合成失败时退回 flutter_tts（系统 TTS），绝不哑巴。
///
/// 缓存目录：<公共目录>/Flashcard/cache/tts/<sha1>.<fmt>
/// 缓存键：word + lang + model + voice + speed（换音色/换模型自动重建）
///
/// 约定：
///   · 持有 StudySettings 引用，读实时值——设置页改完即时生效，不用重启。
///   · 每次新朗读 _gen++，旧的顺序朗读发现代号变了立刻收手。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:http/http.dart' as http;
import 'package:just_audio/just_audio.dart';

import 'data_dir.dart';
import 'study_settings.dart';
import 'tts_log.dart';

class TtsService {
  final StudySettings settings;

  /// 兜底引擎（在线未配置/失败时用；不是主力）
  final FlutterTts _sysTts = FlutterTts();

  /// 主播放器：单词播缓存文件，长句播流式音频
  final AudioPlayer _player = AudioPlayer();

  final http.Client _client = http.Client();

  /// 打断代号：每次新朗读 +1；旧的顺序朗读发现代号变了立刻收手。
  int _gen = 0;

  TtsService({required this.settings});

  /// 初始化（兜底引擎先就位；在线引擎现连现用）
  Future<void> init() async {
    await TtsLog.write('init', 'TtsService init');
    try {
      final r1 = await _sysTts.setLanguage('en-US');
      final r2 = await _sysTts.setSpeechRate(0.48);
      final r3 = await _sysTts.setVolume(1.0);
      final r4 = await _sysTts.setPitch(1.0);
      final r5 = await _sysTts.awaitSpeakCompletion(true);
      await TtsLog.write('init',
          'fallback setLanguage=$r1 rate=$r2 vol=$r3 pitch=$r4 await=$r5');
    } catch (e, st) {
      await TtsLog.write('init', 'ERROR: $e\n$st');
    }
  }

  /// 在线引擎就绪？
  bool get _onlineReady =>
      settings.ttsOpenAiEnabled && settings.ttsOpenAiBaseUrl.trim().isNotEmpty;

  /// 是不是「单个英文词」（决定走缓存还是流式）
  static bool isSingleWord(String s) {
    final t = s.trim();
    if (t.isEmpty || t.length > 40) return false;
    return RegExp(r"^[A-Za-z][A-Za-z'\-]*$").hasMatch(t);
  }

  /// 朗读一段文本：单词走缓存，长句走流式；在线不可用时退系统 TTS
  Future<void> speak(String text, String lang) async {
    final t = text.trim();
    if (t.isEmpty) return;
    final myGen = ++_gen;
    await _stopAll();
    await _speakOne(t, lang, myGen);
  }

  /// 顺序朗读多条（单词 -> 例句）
  Future<void> speakSeq(List items) async {
    final myGen = ++_gen;
    await _stopAll();
    for (final it in items) {
      if (myGen != _gen) return;
      if (it is! Map) continue;
      final text = (it['text'] ?? '').toString().trim();
      final lang = (it['lang'] ?? 'en-US').toString();
      if (text.isEmpty) continue;
      await _speakOne(text, lang, myGen);
    }
  }

  Future<void> _speakOne(String text, String lang, int gen) async {
    if (gen != _gen) return;

    // 主力：在线引擎。单词走缓存，其余流式播放。
    if (_onlineReady) {
      if (isSingleWord(text)) {
        final ok = await _speakWordCached(text, lang, gen);
        if (ok) return;
      } else {
        final ok = await _speakStreamed(text, lang);
        if (ok) return;
      }
    }

    // 兜底：系统 TTS（在线没配置 / 合成失败）
    try {
      await _sysTts.setLanguage(lang);
      final r = await _sysTts.speak(text);
      await TtsLog.write(
          'sys', 'fallback lang=$lang speak=$r text="${_abbr(text)}"');
    } catch (e, st) {
      await TtsLog.write('sys', 'ERROR: $e\n$st');
    }
  }

  /// 单词：收全字节落盘，之后秒播
  Future<bool> _speakWordCached(String word, String lang, int gen) async {
    try {
      final file = await _cacheFile(word, lang);
      if (file == null) return false;

      if (!await file.exists()) {
        final bytes = await _synthesize(word);
        if (bytes == null || bytes.isEmpty) return false;
        await file.parent.create(recursive: true);
        await file.writeAsBytes(bytes, flush: true);
        await TtsLog.write('cache',
            'saved ${file.path} (${bytes.length}B) word="$word"');
      } else {
        await TtsLog.write('cache', 'hit word="$word"');
      }

      if (gen != _gen) return true; // 已被新朗读打断
      await _player.setFilePath(file.path);
      await _player.play(); // just_audio 的 play 会在播完时 complete
      return true;
    } catch (e, st) {
      await TtsLog.write('cache', 'ERROR: $e\n$st');
      return false;
    }
  }

  /// 长句：把 POST 的字节流直接喂给播放器，边收边播
  Future<bool> _speakStreamed(String text, String lang) async {
    try {
      await _player.setAudioSource(_TtsStreamSource(this, text, lang));
      await _player.play();
      return true;
    } catch (e, st) {
      await TtsLog.write('stream', 'ERROR: $e\n$st');
      return false;
    }
  }

  /// 发一次 POST，返回未读完的响应（body 留给调用方流式消费）
  Future<http.StreamedResponse> _postStream(String text, String lang) async {
    final base =
        settings.ttsOpenAiBaseUrl.trim().replaceAll(RegExp(r'/+$'), '');
    final req = http.Request('POST', Uri.parse('$base/audio/speech'))
      ..headers['Content-Type'] = 'application/json'
      ..headers['Accept'] = 'audio/*';
    final key = settings.ttsOpenAiApiKey.trim();
    if (key.isNotEmpty) req.headers['Authorization'] = 'Bearer $key';
    req.body = json.encode({
      'model': settings.ttsOpenAiModel,
      'input': text,
      'voice': settings.ttsOpenAiVoice,
      'response_format': settings.ttsOpenAiFormat,
      'speed': settings.ttsOpenAiSpeed,
    });
    final resp = await _client.send(req).timeout(const Duration(seconds: 20));
    if (resp.statusCode != 200) {
      final body = await resp.stream
          .bytesToString()
          .timeout(const Duration(seconds: 5));
      await TtsLog.write('stream',
          'HTTP ${resp.statusCode}: ${body.length > 300 ? body.substring(0, 300) : body}');
      throw TtsHttpException(resp.statusCode, body);
    }
    return resp;
  }

  /// 单词用：收全字节（用于落盘缓存）
  Future<Uint8List?> _synthesize(String word) async {
    try {
      final resp = await _postStream(word, 'en-US');
      final bytes = await resp.toBytes().timeout(const Duration(seconds: 30));
      if (bytes.isEmpty) return null;
      return bytes;
    } catch (e, st) {
      await TtsLog.write('openai', 'ERROR: $e\n$st');
      return null;
    }
  }

  /// 缓存文件路径（按 词+lang+模型+音色+语速 取 sha1）
  Future<File?> _cacheFile(String word, String lang) async {
    final dir = await DataDir.sub('cache/tts');
    if (dir == null) return null;
    final key = [
      word.toLowerCase(),
      lang,
      settings.ttsOpenAiModel,
      settings.ttsOpenAiVoice,
      settings.ttsOpenAiSpeed.toString(),
    ].join('|');
    final hash = sha1.convert(utf8.encode(key)).toString();
    final fmt = settings.ttsOpenAiFormat.trim().isEmpty
        ? 'mp3'
        : settings.ttsOpenAiFormat.trim();
    return File('${dir.path}/$hash.$fmt');
  }

  /// 设置页「测试发音」用：强制走在线合成，返回是否成功
  Future<bool> testOpenAi(String text) async {
    final bytes = await _synthesize(text.trim());
    return bytes != null && bytes.isNotEmpty;
  }

  /// 预热一批单词（可选：导入新词后批量拉音频，之后全走缓存）
  Future<void> precacheWords(Iterable<String> words, String lang) async {
    if (!_onlineReady) return;
    for (final w in words) {
      final t = w.trim();
      if (!isSingleWord(t)) continue;
      try {
        final f = await _cacheFile(t, lang);
        if (f == null || await f.exists()) continue;
        final bytes = await _synthesize(t);
        if (bytes == null || bytes.isEmpty) continue;
        await f.parent.create(recursive: true);
        await f.writeAsBytes(bytes, flush: true);
      } catch (_) {}
    }
  }

  Future<void> _stopAll() async {
    try {
      await _player.stop();
    } catch (_) {}
    try {
      await _sysTts.stop();
    } catch (_) {}
  }

  /// 打断当前朗读
  Future<void> stop() async {
    _gen++;
    await _stopAll();
  }

  Future<void> dispose() async {
    _gen++;
    try {
      await _player.dispose();
    } catch (_) {}
    try {
      await _sysTts.stop();
    } catch (_) {}
    _client.close();
  }

  static String _abbr(String s) =>
      s.length <= 48 ? s : '${s.substring(0, 48)}…';
}

/// 长句流式：把在线 TTS 的响应字节流实时喂给 just_audio
class _TtsStreamSource extends StreamAudioSource {
  final TtsService owner;
  final String text;
  final String lang;
  _TtsStreamSource(this.owner, this.text, this.lang);

  @override
  Future<StreamAudioResponse> request([int? start, int? end]) async {
    final resp = await owner._postStream(text, lang);
    return StreamAudioResponse(
      contentType: resp.headers['content-type'] ?? 'audio/mpeg',
      // 不知道总长 → 非 seekable，按实时流处理，边收边放
      contentLength: null,
      stream: resp.stream,
      isLive: true,
    );
  }
}

/// 在线接口报错（非 200）
class TtsHttpException implements Exception {
  final int code;
  final String body;
  TtsHttpException(this.code, this.body);
  @override
  String toString() =>
      'TTS HTTP $code: ${body.length > 200 ? body.substring(0, 200) : body}';
}
