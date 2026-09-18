/// 全局错误捕获 · 崩溃日志
/// ================================================================
/// 落盘：`<公共目录>/Flashcard/logs/crash/crash-YYYYMMDD.log`
///      + 同目录 `last_crash.json`（机器可读，最近一次）
///
/// 以前整个壳**一个全局错误钩子都没有** —— 没有 FlutterError.onError、
/// 没有 PlatformDispatcher.onError、没有 runZonedGuarded、没有 ErrorWidget.builder。
/// 后果：build 里抛一个异常 = 用户看到一块红屏 + logcat 里一行没人看的输出，
/// 手机上的用户没法把 logcat 发过来，等于没有线索。
///
/// 三层各管一段，缺一层就有盲区：
///   1. [FlutterError.onError]        —— build / layout / paint 期间的框架错误
///   2. [PlatformDispatcher.onError]  —— 引擎层逃逸的异步异常（platform channel 回调等）
///   3. runZonedGuarded（在 main）    —— zone 内逃逸的同步/异步异常，兜底
///
/// 另有第四层在 WebView 那边：模板页里注入的 window.onerror /
/// unhandledrejection / console.error 钩子（见 TemplateEngine.buildPage），
/// 走 FCChannel 落到 logs/js/。那层管的是卡牌脚本，不归这里。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'data_dir.dart';

class CrashLog {
  CrashLog._();

  /// 不跟随「调试日志」开关 —— 崩溃日志量极小（还有去重），
  /// 关掉只会让真出事的时候一片空白。
  static bool enabled = true;

  /// 公共目录拿不到权限时的兜底目录（App 私有 documents）
  static Directory? _fallback;

  /// 版本信息，[init] 时填，进日志头
  static String appInfo = '';

  /// 最近几条（内存里留一份，调试页可以直接列出来）
  static final List<Map<String, dynamic>> recent = <Map<String, dynamic>>[];
  static const int _keepRecent = 50;

  /// 去重：同一签名在窗口期内只落一次盘。
  /// 一个 build 死循环能一秒刷几千条同样的异常，不去重的话
  /// 光是 fsync 就能把手机卡死 —— 比崩溃本身还严重。
  static final Map<String, DateTime> _seen = <String, DateTime>{};
  static const Duration _dedupeWindow = Duration(seconds: 10);
  static const int _dedupeMax = 400;

  /// 同一签名的重复次数（配合 recent 用）
  static final Map<String, int> _dupCount = <String, int>{};

  static String _two(int n) => n.toString().padLeft(2, '0');

  /// 解析兜底目录。main 里 fire-and-forget 调一次即可。
  static Future<void> init() async {
    try {
      _fallback = await getApplicationDocumentsDirectory();
    } catch (_) {}
    try {
      appInfo = '${Platform.operatingSystem} '
          '${Platform.operatingSystemVersion}';
    } catch (_) {}
  }

  /// 装全局钩子。必须在 runApp 之前调，且只调一次。
  static void install() {
    // ---- 1. 框架错误（build / layout / paint）----
    final prev = FlutterError.onError;
    FlutterError.onError = (FlutterErrorDetails details) {
      record(
        'flutter',
        details.exception,
        details.stack,
        ctx: details.context?.toString() ?? details.library,
      );
      // 原样转给上一个 handler（默认是 presentError，会往控制台打）
      try {
        prev?.call(details);
      } catch (_) {}
    };

    // ---- 2. 引擎层异步异常 ----
    // 返回 true = 已处理，别让它再往上炸一遍（也就不会再进 runZonedGuarded，
    // 所以不会重复落盘）。
    WidgetsBinding.instance.platformDispatcher.onError =
        (Object e, StackTrace s) {
      record('platform', e, s);
      return true;
    };

    // ---- 3. build 炸了别糊红屏 ----
    ErrorWidget.builder = (FlutterErrorDetails details) {
      record('widget', details.exception, details.stack);
      return _FriendlyError(details.exception);
    };
  }

  /// 记一条。同步落盘（崩溃路径上异步写很可能写不完进程就没了）。
  static void record(String where, Object error, StackTrace? stack,
      {String? ctx}) {
    if (!enabled) return;
    try {
      final sig = _signature(error, stack);
      final now = DateTime.now();

      final last = _seen[sig];
      if (last != null && now.difference(last) < _dedupeWindow) {
        _dupCount[sig] = (_dupCount[sig] ?? 1) + 1;
        _bumpRecentDup(sig);
        return;
      }
      _seen[sig] = now;
      if (_seen.length > _dedupeMax) {
        final oldest = _seen.keys.first;
        _seen.remove(oldest);
        _dupCount.remove(oldest);
      }
      _dupCount[sig] = 1;

      final entry = <String, dynamic>{
        'ts': now.toIso8601String(),
        'where': where,
        if (ctx != null && ctx.isNotEmpty) 'ctx': ctx,
        'error': _safe(error),
        'type': _safeType(error),
        'stack': _trimStack(stack),
        // 去重签名，只在内存里用；落盘前会剔掉
        '_sig': sig,
      };

      recent.add(entry);
      if (recent.length > _keepRecent) recent.removeAt(0);

      _writeSync(entry);
    } catch (_) {
      // 记日志本身绝不能把 APP 再搞崩一次
    }
  }

  /// 读最近一次崩溃（机器可读），给调试页 / Agent 看
  static Map<String, dynamic>? readLastCrash() {
    for (final dir in _candidates()) {
      try {
        final f = File('${dir.path}/last_crash.json');
        if (!f.existsSync()) continue;
        final j = json.decode(f.readAsStringSync());
        if (j is Map) return Map<String, dynamic>.from(j);
      } catch (_) {}
    }
    return null;
  }

  /// 崩溃日志目录（可能不存在）
  static Directory? logDir() {
    for (final d in _candidates()) {
      try {
        if (d.existsSync()) return d;
      } catch (_) {}
    }
    return null;
  }

  // ===============================================================
  // 内部
  // ===============================================================

  /// 候选落盘目录，按优先级：公共目录 → App 私有 → 系统临时目录
  static List<Directory> _candidates() {
    final out = <Directory>[];
    final pub = DataDir.cachedRoot;
    if (pub != null) out.add(Directory('${pub.path}/logs/crash'));
    final fb = _fallback;
    if (fb != null) out.add(Directory('${fb.path}/logs/crash'));
    try {
      out.add(Directory('${Directory.systemTemp.path}/flashcard-crash'));
    } catch (_) {}
    return out;
  }

  static void _writeSync(Map<String, dynamic> e) {
    // 剔掉内部字段再落盘
    final out = <String, dynamic>{};
    e.forEach((k, v) {
      if (k.startsWith('_')) return;
      out[k] = v;
    });
    for (final dir in _candidates()) {
      try {
        if (!dir.existsSync()) dir.createSync(recursive: true);
        final now = DateTime.now();
        final day = '${now.year}${_two(now.month)}${_two(now.day)}';
        final logFile = File('${dir.path}/crash-$day.log');
        // 新建当天文件时写一行头：不然后面拿到日志不知道是哪个版本崩的
        final head = logFile.existsSync()
            ? ''
            : '# flashcard 崩溃日志 · $day'
                '${appInfo.isEmpty ? '' : ' · $appInfo'}\n';
        logFile.writeAsStringSync(head + _format(out),
            mode: FileMode.append, flush: true);
        // 机器可读的「最近一次」，覆盖写 —— Agent 一眼就能读到
        File('${dir.path}/last_crash.json')
            .writeAsStringSync(json.encode(out), flush: true);
        return; // 写成功就收工，不往更低优先级的目录重复写
      } catch (_) {
        continue;
      }
    }
  }

  static String _format(Map<String, dynamic> e) {
    final b = StringBuffer()
      ..writeln('${e['ts']} [${e['where']}] ${e['error']}');
    final ctx = e['ctx'];
    if (ctx != null && ctx.toString().isNotEmpty) {
      b.writeln('  ctx: $ctx');
    }
    final st = e['stack'];
    if (st != null && st.toString().isNotEmpty) {
      for (final line in st.toString().split('\n')) {
        if (line.trim().isEmpty) continue;
        b.writeln('  $line');
      }
    }
    b.writeln('  ---');
    return b.toString();
  }

  static String _signature(Object error, StackTrace? stack) {
    final first = (stack?.toString() ?? '').split('\n').take(3).join('|');
    return '${_safeType(error)}|${_safe(error)}|$first';
  }

  static String _safe(Object? o) {
    try {
      return o.toString();
    } catch (_) {
      return '<toString() 抛了>';
    }
  }

  static String _safeType(Object? o) {
    try {
      return o.runtimeType.toString();
    } catch (_) {
      return 'unknown';
    }
  }

  static String _trimStack(StackTrace? s) {
    if (s == null) return '';
    try {
      final lines = s.toString().split('\n');
      const maxFrames = 24;
      const maxChars = 4000;
      var out = lines.take(maxFrames).join('\n');
      if (lines.length > maxFrames) out += '\n  …（省略 ${lines.length - maxFrames} 帧）';
      if (out.length > maxChars) out = '${out.substring(0, maxChars)}…（截断）';
      return out;
    } catch (_) {
      return '';
    }
  }

  static void _bumpRecentDup(String sig) {
    for (var i = recent.length - 1; i >= 0; i--) {
      final e = recent[i];
      if (e['_sig'] == sig) {
        e['dup'] = _dupCount[sig];
        return;
      }
    }
  }
}

/// 替掉红屏。必须极简 —— 这个 widget 自己再抛一次就是无限递归。
class _FriendlyError extends StatelessWidget {
  const _FriendlyError(this.error);

  final Object error;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF141D1F),
      alignment: Alignment.center,
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('这块卡牌炸了',
              style: TextStyle(color: Color(0xFFFF5C5C), fontSize: 14)),
          const SizedBox(height: 6),
          Text(
            CrashLog._safe(error),
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Color(0xFF54666C), fontSize: 11),
          ),
          const SizedBox(height: 6),
          const Text('堆栈已落盘：Documents/Flashcard/logs/crash/',
              style: TextStyle(color: Color(0xFF3E4E54), fontSize: 10)),
        ],
      ),
    );
  }
}
