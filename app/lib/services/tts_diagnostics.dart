/// TTS 自检
/// ================================================================
/// 把「系统里装了哪些 TTS 引擎 / 默认引擎是哪个 / en-US 有没有语音数据 /
/// 试念一句成不成」全跑一遍，写进 logs/tts/，同时回一份摘要给 UI 弹窗。
///
/// 这就是用来抓「手机念不出来、平板能念」这种设备差异的。
library;

import 'package:flutter_tts/flutter_tts.dart';

import 'tts_log.dart';

class TtsDiagnostics {
  /// 自检日志强制落盘（无视开关）：用户主动点的，就得有记录
  static Future<void> _log(String msg) =>
      TtsLog.write('diag', msg, force: true);

  static Future<String> run() async {
    final buf = StringBuffer();
    final tts = FlutterTts();
    void line(String s) => buf.writeln(s);

    try {
      final engines = await tts.getEngines;
      line('engines: $engines');
      await _log('engines=$engines');

      final def = await tts.getDefaultEngine;
      line('defaultEngine: $def');
      await _log('defaultEngine=$def');

      final langs = await tts.getLanguages;
      line('languages: ${langs is List ? '${langs.length} 种' : langs}');
      await _log('languages=$langs');

      final avail = await tts.isLanguageAvailable('en-US');
      line('isLanguageAvailable(en-US): $avail');
      await _log('en-US available=$avail');

      final lr = await tts.setLanguage('en-US');
      line('setLanguage(en-US): $lr');
      await _log('setLanguage -> $lr');

      await tts.setSpeechRate(0.48);
      await tts.setVolume(1.0);
      await tts.awaitSpeakCompletion(true);

      final sr = await tts.speak('Hello, this is a text to speech test.');
      line('speak: $sr');
      await _log('speak -> $sr');
      line('');
      line('没听到声音 = 引擎没绑上 / en-US 语音数据没下 / 被系统静音策略掐了。');
    } catch (e, st) {
      line('ERROR: $e');
      await _log('ERROR: $e\n$st');
    } finally {
      try {
        await tts.stop();
      } catch (_) {}
    }

    final report = buf.toString();
    await _log('--- report ---\n$report');
    return report;
  }
}
