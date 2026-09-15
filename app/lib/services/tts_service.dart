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

  /// 插件 id → 引擎（同插件复用；换插件才新建，JS 插件不必重载脚本）
  final Map<String, TtsEngine> _engines = {};

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

  /// 取引擎：pluginId 为 null 时用当前选中插件；否则用指定插件
  Future<TtsEngine?> _ensureEngine(String? pluginId) async {
    final m = pluginId == null
        ? PluginManager.I.active(PluginType.tts)
        : PluginManager.I.byId(pluginId);
    if (m == null || m.type != PluginType.tts) {
      if (pluginId != null) {
        await TtsLog.write('plugin', '指定的插件不存在或不是 TTS：$pluginId');
      }
      return null;
    }
    final key = '${m.id}|${m.engine.wire}';
    final hit = _engines[key];
    if (hit != null) return hit;
    try {
      final e = await buildTtsEngine(m, PluginManager.I.varsOf(m.id));
      if (e != null) _engines[key] = e;
      return e;
    } catch (e, st) {
      await TtsLog.write('plugin', 'ERROR 造引擎 ${m.id}: $e\n$st');
      return null;
    }
  }

  /// 是不是「单个英文词」（决定走缓存还是流式）
  static bool isSingleWord(String s) {
    final t = s.trim();
    if (t.isEmpty || t.length > 40) return false;
    return RegExp(r"^[A-Za-z][A-Za-z'\-]*$").hasMatch(t);
  }

  /// 朗读一段文本：单词走缓存，长句走流式；没插件时退系统 TTS
  ///
  /// [options] 是模板级覆盖：指定插件 / 音色 / 语速 / 音调 / 附件参数。
  Future<void> speak(String text, String lang, {TtsOptions? options}) async {
    final t = text.trim();
    if (t.isEmpty) return;
    final myGen = ++_gen;
    await _stopAll();
    await TtsLog.write('speak',
        'gen=$myGen lang=$lang ${options == null ? '' : 'opts=[${options.fingerprint}] '}"${_abbr(t)}"');
    await _speakOne(t, lang, myGen, options);
  }

  /// 顺序朗读多条（单词 -> 例句）；每条可自带 plugin/voice/rate/pitch
  Future<void> speakSeq(List items) async {
    final myGen = ++_gen;
    await _stopAll();
    await TtsLog.write('speak', 'seq gen=$myGen ${items.length}条');
    for (final it in items) {
      if (myGen != _gen) return;
      if (it is! Map) continue;
      final text = (it['text'] ?? '').toString().trim();
      final lang = (it['lang'] ?? 'en-US').toString();
      if (text.isEmpty) continue;
      await _speakOne(text, lang, myGen, TtsOptions.parse(it));
    }
  }

  Future<void> _speakOne(
      String text, String lang, int gen, TtsOptions? opts) async {
    if (gen != _gen) return;

    // 模板点名走系统 TTS：plugin:"system"
    if (opts?.system == true) {
      await _speakSystem(text, lang, opts);
      return;
    }

    final engine = await _ensureEngine(opts?.pluginId);
    if (engine != null) {
      // 落盘三态：
      //   显式 true / "name" → 强制落盘
      //   显式 false        → 强制不落（流式）
      //   没传              → 单词看全局设置；长句不落（流式）
      final explicit = opts?.cache;
      final long = !isSingleWord(text);
      final shouldCache = explicit == true ||
          (explicit == null && !long && settings.ttsWordCacheEnabled);
      final ok = shouldCache
          ? await _speakCached(engine, text, lang, gen, opts)
          : await _speakStreamed(engine, text, gen, opts);
      if (ok) return;
    }

    await _speakSystem(text, lang, opts);
  }

  /// 系统 TTS（flutter_tts）兜底 / plugin:"system" 直连
  Future<void> _speakSystem(String text, String lang, TtsOptions? opts) async {
    try {
      await _sysTts.setLanguage(lang);
      if (opts?.rate != null) {
        await _sysTts.setSpeechRate((0.48 * opts!.rate!).clamp(0.1, 1.0));
      }
      if (opts?.pitch != null) {
        await _sysTts.setPitch(opts!.pitch!.clamp(0.5, 2.0));
      }
      final r = await _sysTts.speak(text);
      await TtsLog.write('sys', 'lang=$lang speak=$r text="${_abbr(text)}"');
    } catch (e, st) {
      await TtsLog.write('sys', 'ERROR: $e\n$st');
    }
  }

  /// 落盘缓存：命中直接播；未命中收全字节落盘再播。
  /// 长句额外旁挂一个 .txt 存全文 + 参数，文件名只留前 20 字也认得出。
  Future<bool> _speakCached(TtsEngine engine, String text, String lang,
      int gen, TtsOptions? opts) async {
    try {
      final file = await _cacheFile(text, lang, opts);
      if (file == null) return false;

      final hit = await file.exists();
      if (hit) {
        await TtsLog.write('cache', 'hit "${_abbr(text)}"');
      } else {
        final bytes = await _collect(engine, text);
        if (bytes == null || bytes.isEmpty) return false;
        await file.parent.create(recursive: true);
        await file.writeAsBytes(bytes, flush: true);
        if (!isSingleWord(text)) {
          await _writeSidecar(file, text, lang, opts);
        }
        await TtsLog.write('cache',
            'saved ${file.path} (${bytes.length}B) "${_abbr(text)}"');
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

  /// 长句旁挂 .txt：和音频同主干，写全文 + 合成参数
  Future<void> _writeSidecar(
      File audio, String text, String lang, TtsOptions? opts) async {
    try {
      final txt =
          File(audio.path.replaceAll(RegExp(r'\.[A-Za-z0-9]+$'), '.txt'));
      await txt.writeAsString(
        jsonEncode({
          'text': text,
          'lang': lang,
          'plugin': opts?.pluginId ?? PluginManager.I.activeId(PluginType.tts),
          'voice': opts?.voice,
          'rate': opts?.rate,
          'pitch': opts?.pitch,
          'extra': opts?.extra ?? const {},
        }),
        flush: true,
      );
    } catch (_) {}
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
  Future<bool> _speakStreamed(
      TtsEngine engine, String text, int gen, TtsOptions? opts) async {
    try {
      await _player.setAudioSource(_EngineStreamSource(
          engine.synthesize(text, opts: opts), engine.contentType));
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
  /// 缓存文件路径：<stem>-<speaker>-<sha1前12位>.<ext>
  ///   stem = 自定义 cacheName > 文本本身；长文本只取前 20 字
  ///   hash = plugin|text|lang|voice|rate|pitch|extra —— 判定复用只看它
  Future<File?> _cacheFile(String text, String lang, TtsOptions? opts) async {
    final dir = await DataDir.sub('cache/tts');
    if (dir == null) return null;
    final pid = opts?.pluginId;
    final m = (pid != null && pid != 'system')
        ? PluginManager.I.byId(pid)
        : PluginManager.I.active(PluginType.tts);
    final mid = m?.id ?? 'sys';
    final voice =
        opts?.voice ?? (m == null ? '' : PluginManager.I.varOf(m.id, 'voice'));
    final key = '$mid|${text.toLowerCase()}|$lang|$voice'
        '|${opts?.rate ?? ''}|${opts?.pitch ?? ''}'
        '|${TtsOptions.extraKey(opts?.extra ?? const {})}';
    final hash = sha1.convert(utf8.encode(key)).toString().substring(0, 12);
    final stem = _cacheStem(text, opts);
    final sp = _fileSafe(voice.isEmpty ? 'default' : voice, 24);
    return File('${dir.path}/$stem-$sp-$hash.${_extOf(m)}');
  }

  /// 文件名主干：优先自定义名；否则用文本，长文本截前 20 字
  static String _cacheStem(String text, TtsOptions? opts) {
    final custom = (opts?.cacheName ?? '').trim();
    final t = custom.isNotEmpty ? custom : text.trim();
    final cut = t.length <= 40 ? t : t.substring(0, 20);
    return _fileSafe(cut, 40);
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
    final engine = await _ensureEngine(null);
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
    await TtsLog.write('speak', 'stop → gen=$_gen');
  }

  Future<void> dispose() async {
    _gen++;
    try {
      await _player.dispose();
    } catch (_) {}
    try {
      await _sysTts.stop();
    } catch (_) {}
    for (final e in _engines.values) {
      try {
        await e.dispose();
      } catch (_) {}
    }
    _engines.clear();
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
