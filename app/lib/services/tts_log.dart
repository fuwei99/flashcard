/// TTS 诊断日志
/// ================================================================
/// 落盘：<公共目录>/Flashcard/logs/tts/tts-YYYYMMDD.log
/// （即 /storage/emulated/0/Documents/Flashcard/logs/tts/tts-20260915.log）
///
/// 以前 TTS 的每一步都包在 `catch (_) {}` 里 —— 出错一点痕迹不留，
/// 手机上念不出来完全无从下手。现在凡是 setLanguage / speak / stop
/// 的返回值和异常，全落到这个文件。
library;

import 'dart:io';

import 'data_dir.dart';

class TtsLog {
  /// 追加一行日志；任何失败都吞掉（记日志本身不能把 APP 搞崩）
  static Future<void> write(String tag, String msg) async {
    try {
      final root = await DataDir.root();
      if (root == null) return;
      final dir = Directory('${root.path}/logs/tts');
      if (!await dir.exists()) await dir.create(recursive: true);
      final now = DateTime.now();
      final day =
          '${now.year}${_two(now.month)}${_two(now.day)}';
      final f = File('${dir.path}/tts-$day.log');
      final ts = now.toIso8601String();
      await f.writeAsString('$ts [$tag] $msg\n',
          mode: FileMode.append, flush: true);
    } catch (_) {}
  }

  static String _two(int n) => n.toString().padLeft(2, '0');
}
