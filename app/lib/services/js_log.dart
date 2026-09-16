/// JS 日志 · JSlogs（模板层诊断输出）
/// ================================================================
/// script.js / workflow.js 里 `FC.log(tag, msg)` 的输出落这：
///   <公共目录>/Flashcard/logs/js/js-YYYYMMDD.log
///
/// 单开一个目录，**不掺进 tts/ 和 switch/** —— 调流程 / 调拼写时
/// 一眼能看清 JS 那边到底走了哪一步、传了什么参数。
///
/// 开关跟随 StudySettings.ttsLogEnabled（我的 - 调试日志）。
library;

import 'tts_log.dart';

class JsLog {
  static bool enabled = true;

  /// [tag] 建议 [WF]（workflow.js）/ [SC]（script.js）之类，方便 grep。
  static Future<void> write(String tag, String msg, {bool force = false}) =>
      FileLog.write(
        enabled: enabled,
        sub: 'js',
        prefix: 'js',
        tag: tag,
        msg: msg,
        force: force,
      );
}
