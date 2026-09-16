/// 公共目录变更检测 —— App 从后台回来时自动热重载
/// ================================================================
/// AI 往 books/ 丢一章、改 templates/ 里的 CSS，用户切回 App 时不该
/// 还得手动点「重载模板」。这里用「文件数 + 最大 mtime」当指纹：
/// 内容原地修改也会更新 mtime，所以改一个 ch 文件也能测到。
///
/// 只 walk templates/ 和 books/ 两层下的文件（量级：几十个），
/// 每次回前台算一次，开销可忽略。
library;

import 'dart:io';

import 'data_dir.dart';

class HotReload {
  HotReload._();

  static int? _lastSig;

  /// 书 + 模板目录的变更指纹：最大 mtime 与文件数混合，降低碰撞。
  static Future<int> currentSignature() async {
    final root = await DataDir.root();
    if (root == null) return 0;
    var maxMs = 0;
    var count = 0;
    for (final sub in const ['templates', 'books']) {
      final d = Directory('${root.path}/$sub');
      if (!await d.exists()) continue;
      try {
        await for (final e in d.list(recursive: true, followLinks: false)) {
          if (e is! File) continue;
          count++;
          try {
            final ms = e.statSync().modified.millisecondsSinceEpoch;
            if (ms > maxMs) maxMs = ms;
          } catch (_) {}
        }
      } catch (_) {}
    }
    return maxMs * 1000003 + count;
  }

  /// 首次调用只建立基线并返回 false；之后指纹变了才返回 true。
  static Future<bool> changed() async {
    final sig = await currentSignature();
    if (_lastSig == null) {
      _lastSig = sig;
      return false;
    }
    if (sig == _lastSig) return false;
    _lastSig = sig;
    return true;
  }

  /// 手动重建基线（重载完成后调用，避免下一次误判为“又变了”）。
  static Future<void> resync() async {
    _lastSig = await currentSignature();
  }
}
