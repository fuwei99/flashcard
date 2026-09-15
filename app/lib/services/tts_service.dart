/// TTS 服务：统一入口
/// ================================================================
///   Flashcard.tts(text, lang)
///        │
///   TtsService.speak(text, lang)
///        │
///   选中插件（PluginManager.active(tts)）
///        ├── 单个英文词 → cache/tts/ 命中秒播；未命中收全字节落盘再播
///        ├── 长句       → 音频流直接喂 StreamAudioSource，边收边播
///        └── 没插件/失败 → flutter_tts（系统 TTS）兜底
///
/// 插件怎么合成（HTTP / JS 脚本）由 tts_engine.dart 决定，这里只管调度 + 缓存 + 兜底。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:just_audio/just_audio.dart';

import 'data_dir.dart';
import 'plugin.dart';
import 'study_settings.dart';
import 'tts_engine.dart';
import 'tts_log.dart';

class TtsService {
  final StudySettings settings;

  /// 兜底引擎（没插件 / 插件失败时用；不是主力）
  final FlutterTts _sysTts = FlutterTts();

  /// 主播放器：单词播缓存文件，长句播流式音频
  final AudioPlayer _player = AudioPlayer();

  /// 打断代号：每次新朗读 +1；旧的顺序朗读发现代号变了立刻收手。
  int _gen = 0;

  TtsEngine? _engine;
  String _engineKey = '';

  TtsService({required this.settings});

  Future<void> init() async {
    await TtsLog.write('init', 'TtsService init');
    try {
      final r1 = await _sysTts.setLanguage('en-US');
      final r2 = await _sysTts.setSpeechRate(0.48);
      await _sysTts.setVolume(1.0);
      await _sysTts.setPitch(1.0);
      await _sysTts.awaitSpeakCompletion(true);
      await TtsLog.write('init', 'fallback setLanguage=$r1 rate=$r2');
    } catch (e, st) {
      await TtsLog.write('init', 'ERROR: $e\n$st');
    }
  }

  /// 当前插件 → 引擎（插件换了就重建）
  Future<TtsEngine?> _ensureEngine() async {
    final m = PluginManager.I.active(PluginType.tts);
    if (m == null) return null;
    final key = '${m.id}|${m.engine.wire}';
    if (_engine != null && _engineKey == key) return _engine;
    await _engine?.dispose();
    _engine = null;
    _engineKey = key;
    try {
      _engine = await buildTtsEngine(m, PluginManager.I.varsOf(m.id));
    } catch (e, st) {
      await TtsLog.write('plugin', 'ERROR 造引擎: $e\n$st');
      _engine = null;
    }
    return _engine;
  }

  /// 是不是「单个英文词」（决定走缓存还是流式）
  static bool isSingleWord(String s) {
    final t = s.trim();
    if (t.isEmpty || t.length > 40) return false;
    return RegExp(r"^[A-Za-z][A-Za-z'\-]*$").hasMatch(t);
  }

  /// 朗读一段文本：单词走缓存，长句走流式；没插件时退系统 TTS
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

    final engine = await _ensureEngine();
    if (engine != null) {
      if (isSingleWord(text)) {
        final ok = await _speakWordCached(engine, text, lang, gen);
        if (ok) return;
      } else {
        final ok = await _speakStreamed(engine, text, gen);
        if (ok) return;
      }
    }

    // 兜底：系统 TTS
    try {
      await _sysTts.setLanguage(lang);
      final r = await _sysTts.speak(text);
      await TtsLog.write(
          'sys', 'fallback lang=$lang speak=$r text="${_abbr(text)}"');
    } catch (e, st) {
      await TtsLog.write('sys', 'ERROR: $e\n$st');
    }
  }

  /// 单词：收全字节落盘，之后秒播（受 ttsWordCacheEnabled 控制）
  Future<bool> _speakWordCached(
      TtsEngine engine, String word, String lang, int gen) async {
    try {
      final file = await _cacheFile(word, lang);
      if (file == null) return false;

      final useCache = settings.ttsWordCacheEnabled;
      final hit = useCache && await file.exists();
      if (hit) {
        await TtsLog.write('cache', 'hit word="$word"');
      } else {
        final bytes = await _collect(engine, word);
        if (bytes == null || bytes.isEmpty) return false;
        await file.parent.create(recursive: true);
        await file.writeAsBytes(bytes, flush: true);
        await TtsLog.write(
            'cache',
            '${useCache ? "saved" : "refresh"} ${file.path} '
                '(${bytes.length}B) word="$word"');
      }

      if (gen != _gen) return true; // 已被新朗读打断
      await _player.setFilePath(file.path);
      await _player.play();
      return true;
    } catch (e, st) {
      await TtsLog.write('cache', 'ERROR: $e\n$st');
      return false;
    }
  }

  Future<Uint8List?> _collect(TtsEngine engine, String text) async {
    try {
      final b = BytesBuilder();
      await for (final chunk in engine.synthesize(text)) {
        b.add(chunk);
      }
      return b.takeBytes();
    } catch (e, st) {
      await TtsLog.write('engine', 'ERROR: $e\n$st');
      return null;
    }
  }

  /// 长句：音频流直接喂播放器，边收边播
  Future<bool> _speakStreamed(TtsEngine engine, String text, int gen) async {
    try {
      await _player.setAudioSource(
          _EngineStreamSource(engine.synthesize(text), engine.contentType));
      if (gen != _gen) return true;
      await _player.play();
      return true;
    } catch (e, st) {
      await TtsLog.write('stream', 'ERROR: $e\n$st');
      return false;
    }
  }

  /// 缓存文件路径：<单词>-<speaker>-<sha1前12位>.<ext>
  /// 文件名带单词，肉眼能认；后面那截 sha1 兜底，保证「同词不同音色 / 不同插件」
  /// 不会互相覆盖。换音色/插件后旧文件不会被命中，会自动重建。
  Future<File?> _cacheFile(String word, String lang) async {
    final dir = await DataDir.sub('cache/tts');
    if (dir == null) return null;
    final m = PluginManager.I.active(PluginType.tts);
    final pid = m?.id ?? 'sys';
    final voice = m == null ? '' : PluginManager.I.varOf(m.id, 'voice');
    final key = '$pid|${word.toLowerCase()}|$lang|$voice';
    final hash = sha1.convert(utf8.encode(key)).toString().substring(0, 12);
    final w = _fileSafe(word.toLowerCase(), 40);
    final sp = _fileSafe(voice.isEmpty ? 'default' : voice, 24);
    return File('${dir.path}/$w-$sp-$hash.${_extOf(m)}');
  }

  /// 文件名安全：只留 [A-Za-z0-9_-]，其余并成下划线，两端去下划线，截断到 max
  static String _fileSafe(String s, int max) {
    var t = s.trim().replaceAll(RegExp(r'[^A-Za-z0-9_-]+'), '_');
    t = t.replaceAll(RegExp(r'^_+|_+$'), '');
    if (t.isEmpty) t = 'x';
    if (t.length > max) t = t.substring(0, max);
    return t;
  }

  String _extOf(PluginManifest? m) {
    if (m == null) return 'mp3';
    if (m.engine == PluginEngine.openaiTts) {
      final f = PluginManager.I.varOf(m.id, 'format').trim();
      return f.isEmpty ? 'mp3' : f;
    }
    final f = '${m.defaults['audio_format'] ?? 'aac'}'.trim();
    return f.isEmpty ? 'aac' : f;
  }

  /// 设置页「测试发音」用：走一遍合成，返回是否拿到音频
  Future<bool> testSynthesize(String text) async {
    final engine = await _ensureEngine();
    if (engine == null) return false;
    final bytes = await _collect(engine, text.trim());
    return bytes != null && bytes.isNotEmpty;
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
    try {
      await _engine?.dispose();
    } catch (_) {}
    _engine = null;
  }

  static String _abbr(String s) =>
      s.length <= 48 ? s : '${s.substring(0, 48)}…';
}

/// 长句流式：把插件的音频字节流实时喂给 just_audio
class _EngineStreamSource extends StreamAudioSource {
  final Stream<List<int>> _stream;
  final String _contentType;
  _EngineStreamSource(this._stream, this._contentType);

  @override
  Future<StreamAudioResponse> request([int? start, int? end]) async {
    // just_audio 0.9.x 字段（实测 v0.9.46）：没有 isLive。
    // 一次性字节流，不能重放、不支持 Range。
    return StreamAudioResponse(
      rangeRequestsSupported: false,
      sourceLength: null,
      contentLength: null,
      offset: 0,
      contentType: _contentType,
      stream: _stream,
    );
  }
}
