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

import 'dart:io';

import 'data_dir.dart';

/// 通用落盘器：写 <root>/logs/<sub>/<prefix>-YYYYMMDD.log
/// 任何失败都吞掉（记日志本身不能把 APP 搞崩）。
class _FileLog {
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
      final root = await DataDir.root();
      if (root == null) return;
      final dir = Directory('${root.path}/logs/$sub');
      if (!await dir.exists()) await dir.create(recursive: true);
      final now = DateTime.now();
      final day = '${now.year}${_two(now.month)}${_two(now.day)}';
      final f = File('${dir.path}/$prefix-$day.log');
      final ts = now.toIso8601String();
      await f.writeAsString('$ts [$tag] $msg\n',
          mode: FileMode.append, flush: true);
    } catch (_) {}
  }

  static String _two(int n) => n.toString().padLeft(2, '0');
}

/// TTS 诊断日志：合成 / 引擎 / 缓存 / 插件 / 系统 TTS
class TtsLog {
  static bool enabled = true;

  static Future<void> write(String tag, String msg, {bool force = false}) =>
      _FileLog.write(
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
      _FileLog.write(
        enabled: enabled,
        sub: 'switch',
        prefix: 'switch',
        tag: tag,
        msg: msg,
        force: force,
      );
}
