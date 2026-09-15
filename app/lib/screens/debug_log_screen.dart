/// 调试日志
/// ================================================================
/// 各路日志分开管，一路一个开关。现在只有 TTS 一路；
/// 以后要加网络 / 调度 / WebView 日志，往 _logSwitch 列表里追加即可，
/// 开关本体存在 settings.json 的 *_log_enabled 字段里。
library;

import 'package:flutter/material.dart';

import '../services/data_dir.dart';
import '../services/study_settings.dart';

class DebugLogScreen extends StatefulWidget {
  final StudySettings settings;

  const DebugLogScreen({super.key, required this.settings});

  @override
  State<DebugLogScreen> createState() => _DebugLogScreenState();
}

class _DebugLogScreenState extends State<DebugLogScreen> {
  Future<void> _flip(Future<void> Function(bool) set, bool v) async {
    await set(v);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.settings;
    return Scaffold(
      backgroundColor: const Color(0xFF141D1F),
      appBar: AppBar(
        backgroundColor: const Color(0xFF141D1F),
        elevation: 0,
        iconTheme: const IconThemeData(color: Color(0xFF8C9DA2)),
        title: const Text('调试日志',
            style: TextStyle(
                color: Color(0xFFF0F4F5),
                fontWeight: FontWeight.w700,
                fontSize: 18)),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _sectionLabel('日志开关'),
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.symmetric(vertical: 4),
            decoration: BoxDecoration(
              color: const Color(0x0BFFFFFF),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: const Color(0x14FFFFFF)),
            ),
            child: Column(
              children: [
                _logSwitch(
                  title: 'TTS 日志',
                  subtitle: '记录语音合成每一步的返回值与异常',
                  value: s.ttsLogEnabled,
                  onChanged: (v) => _flip(s.setTtsLogEnabled, v),
                ),
                // 以后加别的日志：这里往下追加
                // const Divider(height: 1, color: Color(0x0FFFFFFF)),
                // _logSwitch(...),
              ],
            ),
          ),
          const SizedBox(height: 24),
          _sectionLabel('落盘位置'),
          const SizedBox(height: 10),
          _pathCard(),
        ],
      ),
    );
  }

  Widget _sectionLabel(String t) => Text(t,
      style: const TextStyle(
          color: Color(0xFF8C9DA2),
          fontSize: 13,
          fontWeight: FontWeight.w600,
          letterSpacing: .5));

  Widget _logSwitch({
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return SwitchListTile(
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
      activeColor: const Color(0xFF00C08B),
      activeTrackColor: const Color(0x3300C08B),
      value: value,
      onChanged: onChanged,
      title: Text(title,
          style: const TextStyle(
              color: Color(0xFFF0F4F5),
              fontSize: 15,
              fontWeight: FontWeight.w600)),
      subtitle: Text(subtitle,
          style: const TextStyle(color: Color(0xFF54666C), fontSize: 12)),
    );
  }

  Widget _pathCard() {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: const Color(0x0BFFFFFF),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0x14FFFFFF)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('TTS',
              style: TextStyle(
                  color: Color(0xFFF0F4F5),
                  fontSize: 13,
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          const SelectableText('Documents/Flashcard/logs/tts/',
              style: TextStyle(color: Color(0xFFB7C4C8), fontSize: 12)),
          const SizedBox(height: 10),
          const Text('每路日志一个子目录，按天分文件：tts-YYYYMMDD.log',
              style: TextStyle(
                  color: Color(0xFF54666C), fontSize: 12, height: 1.6)),
          const SizedBox(height: 4),
          Text(DataDir.publicPath,
              style: const TextStyle(color: Color(0xFF3C4A50), fontSize: 11)),
        ],
      ),
    );
  }
}
