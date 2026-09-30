/// 诊断日志（落盘）
/// ================================================================
/// 两类分开写，互不掺和：
///   - TTS：  <公共目录>/Flashcard/logs/tts/tts-YYYYMMDD.log
///   - 切卡： <公共目录>/Flashcard/logs/switch/switch-YYYYMMDD.log
///
/// 以前 TTS 的每一步都包在 `catch (_) {}` 里 —— 出错一点痕迹不留，
/// 手机上念不出来完全无从下手。现在凡是 setLanguage / speak / stop
/// 的返回值和异常，全落到日志文件。
///
/// 开关：两类都由 StudySettings.ttsLogEnabled（我的-调试日志）同步；
/// 关掉后一律不写，只有 force=true（手动点「TTS 自检」）例外。
library;

import 'dart:async';
import 'dart:io';

import 'data_dir.dart';

/// 通用落盘器：写 <root>/logs/<sub>/<prefix>-YYYYMMDD.log
///
/// **诊断日志，绝不能反噬主流程。** 以前每写一条就
/// `dir.exists()` + `writeAsString(flush: true)` —— 一次 stat + 一次 fsync；
/// 而 WebView 每条消息（answer / tts / ttsSeq / log）都要 `await` 它。
/// 翻面那一击要连发 word + sentence 两条 TTS，主线程就被这几次 fsync 拖住，
/// Flutter 出不了帧 → 屏幕上就是「点了没反应」，而 WebView 里的 DOM 早翻面了
/// （2026-09-30 实机：点击「认识」卡 700ms，再点已进下一张卡）。
/// 多路并发 append 还会把行写串 —— 实机日志里能看到 `es=["choice"]` 这种半截行。
///
/// 现在：内存攒行 → 单飞队列批量落盘（不开 fsync，交给 page cache），
/// 目录只探测一次；攒够 [_maxPending] 行或 [_flushDelay] 到点才碰一次磁盘。
/// 任何失败都吞掉（记日志本身不能把 APP 搞崩）。
class FileLog {
  FileLog._();

  static final Map<String, StringBuffer> _buf = <String, StringBuffer>{};
  static final Map<String, String> _rel = <String, String>{};
  static final Set<String> _dirReady = <String>{};
  static Future<void> _chain = Future<void>.value();
  static Timer? _timer;
  static int _pending = 0;

  /// 攒这么多行立刻落盘（突发刷屏时别把内存撑爆）
  static const int _maxPending = 96;

  /// 平时最多滞后这么久落盘
  static const Duration _flushDelay = Duration(milliseconds: 400);

  static void _enqueue(
      String sub, String prefix, String tag, String msg) {
    final now = DateTime.now();
    final day = '${now.year}${_two(now.month)}${_two(now.day)}';
    final key = '$sub/$prefix-$day';
    (_buf[key] ??= StringBuffer())
        .writeln('${now.toIso8601String()} [$tag] $msg');
    _rel[key] = 'logs/$sub/$prefix-$day.log';
    _pending++;
    if (_pending >= _maxPending) {
      _timer?.cancel();
      _timer = null;
      _flushSoon();
    } else {
      _timer ??= Timer(_flushDelay, () {
        _timer = null;
        _flushSoon();
      });
    }
  }

  /// 排进单飞队列：同一时刻只有一次落盘在跑，行序天然不会串。
  static void _flushSoon() {
    _chain = _chain.then((_) => _flush()).catchError((_) {});
  }

  /// 立刻落下全部待写行（进后台 / 退出页面前调一次即可）
  static Future<void> flushNow() {
    _timer?.cancel();
    _timer = null;
    _flushSoon();
    return _chain;
  }

  static Future<void> _flush() async {
    if (_buf.isEmpty) return;
    if (_rel.isEmpty) return;
    final root = await DataDir.root();
    if (root == null) return;
    final keys = _buf.keys.toList();
    for (final k in keys) {
      final b = _buf[k];
      if (b == null) continue;
      final text = b.toString();
      b.clear();
      if (text.isEmpty) continue;
      final rel = _rel[k];
      if (rel == null) continue;
      try {
        final f = File('${root.path}/$rel');
        final dir = f.parent;
        if (!_dirReady.contains(dir.path)) {
          if (!dir.existsSync()) dir.createSync(recursive: true);
          _dirReady.add(dir.path);
        }
        // flush:false —— 诊断日志不值得每次 fsync；真要落盘由 OS 页缓存保证，
        // 只有整机掉电才可能丢最后几行。flushNow() 想立刻落就立刻落。
        f.writeAsStringSync(text, mode: FileMode.append, flush: false);
      } catch (_) {}
    }
    // 这一轮把所有 buffer 都排干了，计数器归零（只用来触发「攒够了立刻落盘」）。
    _pending = 0;
  }

  static String _two(int n) => n.toString().padLeft(2, '0');

  static Future<void> write({
    required bool enabled,
    required String sub,
    required String prefix,
    required String tag,
    required String msg,
    bool force = false,
  }) async {
    if (!enabled && !force) return;
    try {
      _enqueue(sub, prefix, tag, msg);
    } catch (_) {}
  }
}

/// TTS 诊断日志：合成 / 引擎 / 缓存 / 插件 / 系统 TTS
class TtsLog {
  static bool enabled = true;

  static Future<void> write(String tag, String msg, {bool force = false}) =>
      FileLog.write(
        enabled: enabled,
        sub: 'tts',
        prefix: 'tts',
        tag: tag,
        msg: msg,
        force: force,
      );
}

/// 切卡诊断日志：answer / mount 的时序（原 'switch'、'bridge' 两条埋点）
/// 单开一个目录，免得跟 TTS 的刷屏日志混一起看不清时序。
class SwitchLog {
  static bool enabled = true;

  static Future<void> write(String tag, String msg, {bool force = false}) =>
      FileLog.write(
        enabled: enabled,
        sub: 'switch',
        prefix: 'switch',
        tag: tag,
        msg: msg,
        force: force,
      );
}
