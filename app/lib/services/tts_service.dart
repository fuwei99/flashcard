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

  /// 流式连续失败计数。单次偶发中断（Connection aborted）不惩罚，下次照试；
  /// 连续 [_kStreamFailLimit] 次才认定本机流式不可用，之后长句直接走
  /// 「收全→落盘→播」，省掉每次白炸（白炸 = 双倍合成 + 双倍延迟）。
  /// 任意一次成功即清零；不持久化，重启也重置。
  int _streamFails = 0;
  static const int _kStreamFailLimit = 3;

  /// 插件 id → 引擎（同插件复用；换插件才新建，JS 插件不必重载脚本）
  final Map<String, TtsEngine> _engines = {};

  /// 最近一次用过的引擎：_stopAll 时负责取消它在途的合成
  TtsEngine? _lastEngine;

  /// 最近一次流式播放的源：_stopAll 时释放，取消它对引擎流的订阅
  _EngineStreamSource? _lastSource;

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
      _lastEngine = engine; // 供 _stopAll 打断在途合成
      // 落盘三态：
      //   显式 true / "name" → 强制落盘
      //   显式 false        → 强制不落（流式）
      //   没传              → 单词看全局设置；长句不落（流式）
      final explicit = opts?.cache;
      final long = !isSingleWord(text);
      final shouldCache = explicit == true ||
          (explicit == null && !long && settings.ttsWordCacheEnabled);
      // 长句优先流式；偶发中断不惩罚，连续失败达阈值才认定本机不可用。
      final tryStream = !shouldCache && _streamFails < _kStreamFailLimit;
      final ok = shouldCache
          ? await _speakCached(engine, text, lang, gen, opts)
          : (tryStream ? await _speakStreamed(engine, text, gen, opts) : false);
      if (ok) {
        if (tryStream) _streamFails = 0; // 成功即清零，别让偶发失败累积成「不可用」
        return;
      }
      if (tryStream) _streamFails++;
      // 流式失败：把整段收下来落临时文件再播（词条同款路径），
      // 别直接跳系统 TTS —— 那样音色全变了。
      if (!shouldCache && gen == _gen) {
        if (await _speakCollected(engine, text, lang, gen, opts)) return;
      }
    }

    if (gen != _gen) return; // 已被新朗读打断，别再兜底出声
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
        if (gen != _gen) return true; // 被打断，别写半截缓存
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

  /// 长句：真·流式 —— 插件音频边收边播，不预收整段。
  ///
  /// just_audio 会对同一个 StreamAudioSource 反复调用 request()（探测 / 播放 /
  /// seek），每次都要求一条「全新」的流；直接返回引擎那条一次性流，第二次订阅
  /// 必炸 "Source error"（例句兜底系统 TTS 就是这么来的）。
  /// 这里隔一层可重放源：缓存已收字节，新订阅先补发缓存、再实时接后续增量。
  Future<bool> _speakStreamed(
      TtsEngine engine, String text, int gen, TtsOptions? opts) async {
    try {
      final source = _EngineStreamSource(
          engine.synthesize(text, opts: opts), engine.contentType);
      _lastSource = source;
      await _player.setAudioSource(source);
      if (gen != _gen) {
        await _player.stop();
        return true;
      }
      await _player.play();
      return true;
    } catch (e, st) {
      await TtsLog.write('stream', 'ERROR: $e\n$st');
      return false;
    }
  }

  /// 流式失败时的兜底：把整段收全 → 落临时文件 → 按文件播。
  /// 词条那条路（_speakCached）已证明「文件播放」稳；流式万一再出幺蛾子，
  /// 用这个兜住，音色还是原插件，别动不动退到系统 TTS 把音色换掉。
  Future<bool> _speakCollected(TtsEngine engine, String text, String lang,
      int gen, TtsOptions? opts) async {
    try {
      final bytes = await _collect(engine, text);
      if (bytes == null || bytes.isEmpty) return false;
      if (gen != _gen) return true;
      final dir = await DataDir.sub('cache/tts/.tmp');
      if (dir == null) return false;
      await dir.create(recursive: true);
      final hash = sha1
          .convert(utf8.encode('$text|$lang|${opts?.fingerprint ?? ''}'))
          .toString()
          .substring(0, 12);
      final ext = engine.contentType.contains('mpeg') ? 'mp3' : 'aac';
      final f = File('${dir.path}/s-$hash.$ext');
      await f.writeAsBytes(bytes, flush: true);
      if (gen != _gen) return true;
      await TtsLog.write(
          'stream', '流式失败→落临时文件播放 ${bytes.length}B "${_abbr(text)}"');
      await _player.setFilePath(f.path);
      await _player.play();
      return true;
    } catch (e, st) {
      await TtsLog.write('stream', 'collected ERROR: $e\n$st');
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
    // 释放上一个流式源：取消它对引擎流的订阅，别让旧数据继续灌进来
    try {
      await _lastSource?.dispose();
    } catch (_) {}
    _lastSource = null;
    // 关键：打断插件的在途合成（豆包那条 websocket）。否则上一条的音频
    // 会写进下一条的会话 —— 语篇选词「读成上一个词」就是这么来的。
    try {
      await _lastEngine?.stop();
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
      await _lastSource?.dispose();
    } catch (_) {}
    _lastSource = null;
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

/// 长句流式：把插件的音频字节流边收边喂 just_audio，且可被多次订阅。
///
/// just_audio 会对同一个 source 反复调用 request()（探测 / 播放 / seek），
/// 每次都要求一条新流。直接返回引擎那条一次性流，第二次订阅必炸
/// "Source error"。这里做一层可重放中间态：
///   · 已收到的字节全部进 _buffer
///   · 每次 request() 新建一个 controller，先补发 _buffer 里 start 之后的，
///     再把后续新到的字节实时转发给它
///   · 引擎结束 / 出错时，关闭所有在途订阅
/// 于是既是真流式（边收边播），又经得起任意次数重复订阅。
class _EngineStreamSource extends StreamAudioSource {
  final Stream<List<int>> _source;
  final String _contentType;
  final List<int> _buffer = <int>[];
  final List<StreamController<List<int>>> _sinks = [];
  StreamSubscription<List<int>>? _sub;
  bool _done = false;
  bool _started = false;
  Object? _error;
  StackTrace? _stack;

  _EngineStreamSource(this._source, this._contentType);

  void _ensureStarted() {
    if (_started) return;
    _started = true;
    _sub = _source.listen(
      (chunk) {
        _buffer.addAll(chunk);
        for (final c in _sinks) {
          if (!c.isClosed) c.add(chunk);
        }
      },
      onError: (Object e, StackTrace st) {
        _error = e;
        _stack = st;
        _done = true;
        for (final c in _sinks) {
          if (!c.isClosed) c.addError(e, st);
        }
        _closeSinks();
      },
      onDone: () {
        _done = true;
        _closeSinks();
      },
      cancelOnError: true,
    );
  }

  void _closeSinks() {
    for (final c in _sinks) {
      if (!c.isClosed) c.close();
    }
    _sinks.clear();
  }

  @override
  Future<StreamAudioResponse> request([int? start, int? end]) async {
    _ensureStarted();
    final ctrl = StreamController<List<int>>();
    // 不认 range（rangeRequestsSupported=false）：永远从 0 补发。
    // 若还按 start 切片却把 offset 报成 null，客户端会把这段当 0 起，音频错位。
    if (_buffer.isNotEmpty) ctrl.add(_buffer.sublist(0));
    if (_done) {
      if (_error != null) ctrl.addError(_error!, _stack);
      await ctrl.close();
    } else {
      _sinks.add(ctrl);
    }
    // just_audio 0.9.x 字段（实测 v0.9.46）：没有 isLive。
    return StreamAudioResponse(
      rangeRequestsSupported: false,
      sourceLength: null,
      contentLength: null,
      // ★ 必须 null —— 这是「例句必炸 Source error」的真凶 ★
      // just_audio 0.9.46 在本地代理 _ProxyHandler 里：
      //   if (rangeRequest != null && sourceResponse.offset != null) {
      //     _HttpRangeResponse(offset, offset + contentLength! - 1, sourceLength)
      //   }
      // ExoPlayer 一探测就带 Range 头 → 进该分支 → contentLength! 对 null 空断言崩，
      // 代理断连 → ExoPlayer 报 TYPE_SOURCE（即 "(0) Source error"）。
      // offset=null 会走 else：contentLength ?? -1 → chunked，正常流式。
      offset: null,
      contentType: _contentType,
      stream: ctrl.stream,
    );
  }

  /// 取消对引擎流的订阅并关闭所有在途订阅（新朗读 / 播放结束调用）
  Future<void> dispose() async {
    try {
      await _sub?.cancel();
    } catch (_) {}
    _sub = null;
    _closeSinks();
  }
}
