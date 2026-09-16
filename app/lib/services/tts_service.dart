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

  /// 后台落盘队列（统一接口的 play:false 分支）：串行跑，且让路给播放。
  /// 豆包是单会话宿主，并发合成会互相 cancel —— 后台只准一条一条来，
  /// 而且有朗读在途时整队停摆。
  final List<_CacheJob> _cacheQ = [];
  bool _cacheDraining = false;

  /// 朗读闸门：非 null = 有朗读在途，预取让路
  Completer<void>? _speakGate;

  void _openGate() => _speakGate ??= Completer<void>();

  void _closeGate() {
    final g = _speakGate;
    _speakGate = null;
    if (g != null && !g.isCompleted) g.complete();
  }

  /// 排一个后台落盘任务（去重：同一段音频不重复排队）
  void _enqueueCache(_CacheJob j) {
    if (_cacheQ.any((x) => x.key == j.key)) return;
    _cacheQ.add(j);
    unawaited(_drainCache());
  }

  Future<void> _drainCache() async {
    if (_cacheDraining) return;
    _cacheDraining = true;
    try {
      while (_cacheQ.isNotEmpty) {
        while (_speakGate != null) {
          await _speakGate!.future; // 播放优先，预取靠边
        }
        if (_cacheQ.isEmpty) break;
        final job = _cacheQ.removeAt(0);
        final engine = await _ensureEngine(job.opts?.pluginId);
        if (engine == null) continue;
        _lastEngine = engine;
        final ok = await _cacheOnly(engine, job.text, job.lang, job.opts);
        // 被播放打断（ws 被 cancel）→ 重排，别把任务丢了
        if (!ok && job.retry < 2) {
          job.retry++;
          _cacheQ.add(job);
        }
      }
    } finally {
      _cacheDraining = false;
    }
  }

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
    // 统一接口的 play:false 分支：只落盘、不出声 → 丢后台队列
    if (options?.shouldPlay == false) {
      _enqueueCache(_CacheJob(t, lang, options));
      return;
    }
    final myGen = ++_gen;
    _openGate();
    try {
      await _stopAll();
      await TtsLog.write('speak',
          'gen=$myGen lang=$lang ${options == null ? '' : 'opts=[${options.fingerprint}] '}"${_abbr(t)}"');
      await _speakOne(t, lang, myGen, options);
    } finally {
      _closeGate();
    }
  }

  /// 顺序朗读多条（单词 -> 例句）；每条可自带 plugin/voice/rate/pitch
  ///
  /// 关键优化：**本条一开口就去合成下一条**。
  /// 原来 `await _speakOne(...)` 要等 `_player.play()` 整条播完才轮到下一条，
  /// 于是「单词播 1.5s + 例句再等 1.2s TTFB」= 3s 才听到例句。
  /// 现在单词起播的瞬间就把例句合成挂上（此刻引擎空闲），
  /// 单词播完时例句字节已到手，落盘直接播，几乎无缝。
  Future<void> speakSeq(List items) async {
    final myGen = ++_gen;
    _openGate();
    try {
      await _stopAll();
      await TtsLog.write('speak', 'seq gen=$myGen ${items.length}条');

      // 先解析成结构化列表：要按下标「播第 i 条时预取第 i+1 条」
      final list = <_SeqItem>[];
      for (final it in items) {
        if (it is! Map) continue;
        final text = (it['text'] ?? '').toString().trim();
        if (text.isEmpty) continue;
        final lang = (it['lang'] ?? 'en-US').toString();
        final o = TtsOptions.parse(it);
        // play:false 的条目：丢后台落盘队列，不占本轮朗读
        if (o?.shouldPlay == false) {
          _enqueueCache(_CacheJob(text, lang, o));
          continue;
        }
        list.add(_SeqItem(text: text, lang: lang, opts: o));
      }

      _Prefetch? pre; // 在途预取

      for (var i = 0; i < list.length; i++) {
        if (myGen != _gen) return;
        final it = list[i];
        final p = pre;
        pre = null;

        // 本条起播回调：此刻引擎空闲 → 并行把下一条合成挂上
        void kick() {
          if (myGen != _gen) return;
          if (i + 1 >= list.length) return;
          final nx = list[i + 1];
          if (_willCache(nx)) return; // 下一条自己要走缓存，别跟它抢引擎
          pre = _startPrefetch(nx, myGen);
        }

        // ① 预取命中：字节已在手，落盘直接播，跳过整段合成等待
        if (p != null && p.key == it.key) {
          final bytes = await p.bytes;
          if (myGen != _gen) return;
          if (bytes != null && bytes.isNotEmpty) {
            final engine = await _ensureEngine(it.opts?.pluginId);
            if (engine != null && myGen == _gen) {
              if (await _playPrefetched(bytes, it, myGen, engine,
                  onStarted: kick)) {
                continue;
              }
            }
          }
          // 预取废了（合成失败 / 被打断）→ 退回正常路径
        }

        // ② 正常路径
        if (myGen != _gen) return;
        await _speakOne(it.text, it.lang, myGen, it.opts, onStarted: kick);
      }
    } finally {
      _closeGate();
    }
  }

  /// 这条会不会走「落盘缓存」——决定要不要预取（会走缓存的别抢引擎，
  /// 否则预取和它自己的合成会打架，白烧两次）
  bool _willCache(_SeqItem it) {
    final explicit = it.opts?.cache;
    final long = !isSingleWord(it.text);
    return explicit == true ||
        (explicit == null && !long && settings.ttsWordCacheEnabled);
  }

  /// 后台预合成：只收字节，不碰播放器
  _Prefetch _startPrefetch(_SeqItem it, int gen) {
    final fut = () async {
      final engine = await _ensureEngine(it.opts?.pluginId);
      if (engine == null || gen != _gen) return null;
      final b = await _collect(engine, it.text, opts: it.opts);
      await TtsLog.write('seq',
          '预取${b == null ? '失败' : '完成'} ${b?.length ?? 0}B "${_abbr(it.text)}"');
      return b;
    }();
    return _Prefetch(it.key, fut);
  }

  Future<void> _speakOne(
      String text, String lang, int gen, TtsOptions? opts,
      {void Function()? onStarted}) async {
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
      final wantCache = explicit == true ||
          (explicit == null && !long && settings.ttsWordCacheEnabled);
      final wantPlay = opts?.shouldPlay ?? true;

      // ① 本地已有 → 直接用。**不管 wantCache**：预取落盘的例句也要能被播放命中。
      final cached = await _cacheFile(text, lang, opts);
      if (cached != null && await cached.exists()) {
        await _touch(cached);
        if (!wantPlay) return; // 只要落盘 —— 已经在盘上了
        if (gen != _gen) return;
        await TtsLog.write('cache', 'hit(本地) "${_abbr(text)}"');
        await _playFile(cached, onStarted: onStarted);
        return;
      }

      // ② 不出声、只要落盘（预取兜底路径）
      if (!wantPlay) {
        await _cacheOnly(engine, text, lang, opts);
        return;
      }

      // ③ 出声：走缓存（合成+播）或流式
      // 长句优先流式；偶发中断不惩罚，连续失败达阈值才认定本机不可用。
      final tryStream = !wantCache && _streamFails < _kStreamFailLimit;
      final ok = wantCache
          ? await _speakCached(engine, text, lang, gen, opts,
              onStarted: onStarted)
          : (tryStream ? await _speakStreamed(engine, text, gen, opts) : false);
      if (ok) {
        if (tryStream) _streamFails = 0; // 成功即清零，别让偶发失败累积成「不可用」
        return;
      }
      if (tryStream) _streamFails++;
      // 流式失败：把整段收下来落临时文件再播（词条同款路径），
      // 别直接跳系统 TTS —— 那样音色全变了。
      if (!wantCache && gen == _gen) {
        if (await _speakCollected(engine, text, lang, gen, opts,
                onStarted: onStarted)) {
          return;
        }
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
      int gen, TtsOptions? opts, {void Function()? onStarted}) async {
    try {
      final file = await _cacheFile(text, lang, opts);
      if (file == null) return false;

      final hit = await file.exists();
      if (hit) {
        await TtsLog.write('cache', 'hit "${_abbr(text)}"');
      } else {
        final bytes = await _collect(engine, text, opts: opts);
        if (bytes == null || bytes.isEmpty) return false;
        if (gen != _gen) return true; // 被打断，别写半截缓存
        await file.parent.create(recursive: true);
        await file.writeAsBytes(bytes, flush: true);
        await _writeTtl(file, opts?.ttlDays);
        if (!isSingleWord(text)) {
          await _writeSidecar(file, text, lang, opts);
        }
        await TtsLog.write('cache',
            'saved ${file.path} (${bytes.length}B) "${_abbr(text)}"');
      }

      if (gen != _gen) return true; // 已被新朗读打断
      await _playFile(file, onStarted: onStarted);
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

  /// 收全一段合成的字节。
  /// [opts] 必须原样传下去 —— voice / rate / pitch 都在里面。
  /// 丢了就回落插件默认（例句被念成单词音色，就是这么来的）。
  Future<Uint8List?> _collect(TtsEngine engine, String text,
      {TtsOptions? opts}) async {
    try {
      final b = BytesBuilder();
      await for (final chunk in engine.synthesize(text, opts: opts)) {
        b.add(chunk);
      }
      return b.takeBytes();
    } catch (e, st) {
      await TtsLog.write('engine', 'ERROR: $e\n$st');
      return null;
    }
  }

  /// 播放一个本地文件（统一出口：起播瞬间回调 onStarted，供预取用）
  Future<void> _playFile(File f, {void Function()? onStarted}) async {
    await _player.setFilePath(f.path);
    final done = _player.play();
    onStarted?.call();
    await done;
  }

  /// 更新访问时间（清理策略按 mtime 走 LRU）
  Future<void> _touch(File f) async {
    try {
      await f.setLastModified(DateTime.now());
    } catch (_) {}
  }

  /// 写 TTL 标记：<audio>.ttl = {"expireAt": epochSec}；永久则清掉标记
  Future<void> _writeTtl(File audio, int? ttlDays) async {
    try {
      final t = File('${audio.path}.ttl');
      if (ttlDays == null) {
        if (await t.exists()) await t.delete();
        return;
      }
      final at = DateTime.now()
              .add(Duration(days: ttlDays))
              .millisecondsSinceEpoch ~/
          1000;
      await t.writeAsString('{"expireAt":$at,"ttlDays":$ttlDays}', flush: true);
    } catch (_) {}
  }

  /// 只要落盘、不出声：合成 → 写 cache/tts → 记 TTL。
  /// 已有同 key 文件则直接跳过，不重复合成。
  Future<bool> _cacheOnly(
      TtsEngine engine, String text, String lang, TtsOptions? opts) async {
    try {
      final f = await _cacheFile(text, lang, opts);
      if (f == null) return true; // 算不出来路径，别重排
      if (await f.exists()) return true;
      final bytes = await _collect(engine, text, opts: opts);
      if (bytes == null || bytes.isEmpty) return false;
      await f.parent.create(recursive: true);
      await f.writeAsBytes(bytes, flush: true);
      await _writeTtl(f, opts?.ttlDays);
      await TtsLog.write(
          'cache', 'prefetch ${bytes.length}B "${_abbr(text)}"');
      return true;
    } catch (e, st) {
      await TtsLog.write('cache', 'prefetch ERROR: $e\n$st');
      return false;
    }
  }

  /// 清理 TTS 缓存。
  ///   · 有 .ttl 标记的：按标记的过期时间删（永久的不删）
  ///   · 没有标记的：若给了 [olderThanDays]，按最后访问时间（mtime）删
  Future<Map<String, dynamic>> purgeCache({int? olderThanDays}) async {
    final dir = await DataDir.sub('cache/tts');
    if (dir == null || !await dir.exists()) {
      return {'removed': 0, 'freedBytes': 0};
    }
    final now = DateTime.now();
    final nowSec = now.millisecondsSinceEpoch ~/ 1000;
    var removed = 0;
    var freed = 0;
    await for (final e in dir.list()) {
      if (e is! File) continue;
      final p = e.path;
      if (p.endsWith('.txt') || p.endsWith('.ttl') || p.endsWith('.tmp')) {
        continue;
      }
      var dead = false;
      final t = File('$p.ttl');
      if (await t.exists()) {
        try {
          final m = jsonDecode(await t.readAsString());
          if (m is Map) {
            final at = (m['expireAt'] as num?)?.toInt();
            if (at != null && nowSec > at) dead = true;
          }
        } catch (_) {}
      } else if (olderThanDays != null && olderThanDays > 0) {
        final st = await e.stat();
        if (now.difference(st.modified).inDays >= olderThanDays) dead = true;
      }
      if (!dead) continue;
      try {
        freed += await e.length();
        await e.delete();
        removed++;
        for (final ext in ['.txt', '.ttl']) {
          final s = File('$p$ext');
          if (await s.exists()) await s.delete();
        }
      } catch (_) {}
    }
    await TtsLog.write('cache',
        'purge removed=$removed freed=${freed}B olderThan=$olderThanDays');
    return {'removed': removed, 'freedBytes': freed};
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

  /// 字节落 cache/tts/.tmp（同名覆盖），返回文件
  Future<File?> _writeTmp(Uint8List bytes, String text, String lang,
      TtsOptions? opts, TtsEngine engine) async {
    final dir = await DataDir.sub('cache/tts/.tmp');
    if (dir == null) return null;
    await dir.create(recursive: true);
    final hash = sha1
        .convert(utf8.encode('$text|$lang|${opts?.fingerprint ?? ''}'))
        .toString()
        .substring(0, 12);
    final ext = engine.contentType.contains('mpeg') ? 'mp3' : 'aac';
    final f = File('${dir.path}/s-$hash.$ext');
    await f.writeAsBytes(bytes, flush: true);
    return f;
  }

  /// 流式失败时的兜底：把整段收全 → 落临时文件 → 按文件播。
  /// 词条那条路（_speakCached）已证明「文件播放」稳；流式万一再出幺蛾子，
  /// 用这个兜住，音色还是原插件，别动不动退到系统 TTS 把音色换掉。
  Future<bool> _speakCollected(TtsEngine engine, String text, String lang,
      int gen, TtsOptions? opts, {void Function()? onStarted}) async {
    try {
      final bytes = await _collect(engine, text, opts: opts);
      if (bytes == null || bytes.isEmpty) return false;
      if (gen != _gen) return true;
      final f = await _writeTmp(bytes, text, lang, opts, engine);
      if (f == null) return false;
      if (gen != _gen) return true;
      await TtsLog.write(
          'stream', '流式失败→落临时文件播放 ${bytes.length}B "${_abbr(text)}"');
      await _playFile(f, onStarted: onStarted);
      return true;
    } catch (e, st) {
      await TtsLog.write('stream', 'collected ERROR: $e\n$st');
      return false;
    }
  }

  /// 预取命中：字节已在手，落 .tmp 直接播（跳过合成等待）
  Future<bool> _playPrefetched(Uint8List bytes, _SeqItem it, int gen,
      TtsEngine engine, {void Function()? onStarted}) async {
    try {
      final f = await _writeTmp(bytes, it.text, it.lang, it.opts, engine);
      if (f == null) return false;
      if (gen != _gen) return true;
      await TtsLog.write(
          'seq', '预取命中→直接播 ${bytes.length}B "${_abbr(it.text)}"');
      await _playFile(f, onStarted: onStarted);
      return true;
    } catch (e, st) {
      await TtsLog.write('seq', '预取播放 ERROR: $e\n$st');
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

/// speakSeq 的一条：文本 + 语言 + 覆盖参数
class _SeqItem {
  final String text;
  final String lang;
  final TtsOptions? opts;
  _SeqItem({required this.text, required this.lang, this.opts});

  /// 预取对账用的 key（口径和 _writeTmp 的 hash 一致）
  String get key => '$text|$lang|${opts?.fingerprint ?? ''}';
}

/// 在途预取：key 用来对账，bytes 是后台合成结果
class _Prefetch {
  final String key;
  final Future<Uint8List?> bytes;
  _Prefetch(this.key, this.bytes);
}

/// 后台落盘任务（统一接口的 play:false 分支）
class _CacheJob {
  final String text;
  final String lang;
  final TtsOptions? opts;
  int retry = 0;
  _CacheJob(this.text, this.lang, this.opts);

  /// 去重 / 对账口径，与 _writeTmp 的 hash 一致
  String get key => '$text|$lang|${opts?.fingerprint ?? ''}';
}
