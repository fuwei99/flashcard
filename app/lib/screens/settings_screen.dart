/// 设置界面：每日背诵量
library;

import 'package:flutter/material.dart';

import '../services/data_dir.dart';
import '../services/reminder_service.dart';
import '../services/study_settings.dart';

class SettingsScreen extends StatefulWidget {
  final StudySettings settings;

  const SettingsScreen({super.key, required this.settings});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late int _wordLimit;
  late int _cardLimit;

  @override
  void initState() {
    super.initState();
    _wordLimit = widget.settings.wordDailyLimit;
    _cardLimit = widget.settings.cardDailyLimit;
  }

  Future<void> _saveWord() async {
    await widget.settings.setWordDailyLimit(_wordLimit);
    if (!mounted) return;
    setState(() {});
  }

  Future<void> _saveCard() async {
    await widget.settings.setCardDailyLimit(_cardLimit);
    if (!mounted) return;
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF141D1F),
      appBar: AppBar(
        backgroundColor: const Color(0xFF141D1F),
        elevation: 0,
        iconTheme: const IconThemeData(color: Color(0xFF8C9DA2)),
        title: const Text('设置',
            style: TextStyle(
                color: Color(0xFFF0F4F5),
                fontWeight: FontWeight.w700,
                fontSize: 18)),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _sectionLabel('每日单词背诵量'),
          const SizedBox(height: 10),
          _limitCard(
            value: _wordLimit,
            onChanged: (v) => setState(() => _wordLimit = v.round()),
            onSave: _saveWord,
            onPreset: (n) {
              setState(() => _wordLimit = n);
              _saveWord();
            },
          ),
          const SizedBox(height: 24),
          _sectionLabel('每日卡牌背诵量'),
          const SizedBox(height: 10),
          _limitCard(
            value: _cardLimit,
            onChanged: (v) => setState(() => _cardLimit = v.round()),
            onSave: _saveCard,
            onPreset: (n) {
              setState(() => _cardLimit = n);
              _saveCard();
            },
          ),
          const SizedBox(height: 24),
          _sectionLabel('卡片类型'),
          const SizedBox(height: 10),
          _modeCard(),
          const SizedBox(height: 24),
          _sectionLabel('背诵提醒'),
          const SizedBox(height: 10),
          _remindCard(),
          const SizedBox(height: 24),
          _sectionLabel('今日'),
          const SizedBox(height: 10),
          _todayCard(),
          const SizedBox(height: 24),
          _sectionLabel('数据目录'),
          const SizedBox(height: 10),
          _dataCard(),
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

  Widget _limitCard({
    required int value,
    required ValueChanged<double> onChanged,
    required VoidCallback onSave,
    required void Function(int) onPreset,
  }) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: const Color(0x0BFFFFFF),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0x14FFFFFF)),
      ),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              const Text('每天背多少个',
                  style: TextStyle(color: Color(0xFFF0F4F5), fontSize: 15)),
              Text('$value',
                  style: const TextStyle(
                      color: Color(0xFF00C08B),
                      fontSize: 30,
                      fontWeight: FontWeight.w700)),
            ],
          ),
          const SizedBox(height: 6),
          Slider(
            value: value.toDouble(),
            min: 5,
            max: 200,
            divisions: 39,
            activeColor: const Color(0xFF00C08B),
            inactiveColor: const Color(0x22FFFFFF),
            onChanged: onChanged,
            onChangeEnd: (_) => onSave(),
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            children: [10, 20, 30, 50, 80, 100]
                .map((n) => _presetChip(n, value, onPreset))
                .toList(),
          ),
        ],
      ),
    );
  }

  Widget _presetChip(int n, int cur, void Function(int) onPreset) {
    final sel = cur == n;
    return InkWell(
      borderRadius: BorderRadius.circular(999),
      onTap: () => onPreset(n),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          color: sel ? const Color(0x1F00C08B) : const Color(0x0BFFFFFF),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
              color: sel ? const Color(0xFF00C08B) : const Color(0x14FFFFFF)),
        ),
        child: Text('$n',
            style: TextStyle(
                color: sel ? const Color(0xFF00C08B) : const Color(0xFF8C9DA2),
                fontSize: 13,
                fontWeight: FontWeight.w600)),
      ),
    );
  }

  Widget _modeCard() {
    final s = widget.settings;
    Future<void> flip(Future<void> Function(bool) set, bool v) async {
      await set(v);
      if (mounted) setState(() {});
    }

    return Container(
      padding: const EdgeInsets.symmetric(vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0x0BFFFFFF),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0x14FFFFFF)),
      ),
      child: Column(
        children: [
          _modeSwitch(
            title: '语义选项',
            subtitle: '英→中，看单词选释义',
            value: s.modeChoice,
            onChanged: (v) => flip(s.setModeChoice, v),
          ),
          const Divider(height: 1, color: Color(0x0FFFFFFF)),
          _modeSwitch(
            title: '短句选词',
            subtitle: '真题例句挖空选词',
            value: s.modeSentenceCloze,
            onChanged: (v) => flip(s.setModeSentenceCloze, v),
          ),
          const Divider(height: 1, color: Color(0x0FFFFFFF)),
          _modeSwitch(
            title: '语篇选词',
            subtitle: '章首文章整篇填词（多邻国式）',
            value: s.modePassageCloze,
            onChanged: (v) => flip(s.setModePassageCloze, v),
          ),
        ],
      ),
    );
  }

  Widget _modeSwitch({
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

  Widget _remindCard() {
    final s = widget.settings;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0x0BFFFFFF),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0x14FFFFFF)),
      ),
      child: Column(
        children: [
          SwitchListTile(
            dense: true,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
            activeColor: const Color(0xFF00C08B),
            activeTrackColor: const Color(0x3300C08B),
            value: s.reminderEnabled,
            onChanged: (v) async {
              if (v) {
                final ok = await ReminderService.requestPermission();
                if (!ok && mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                    content: Text('通知权限被拒绝，可去系统设置里手动打开'),
                    backgroundColor: Color(0xFF1B2629),
                    behavior: SnackBarBehavior.floating,
                  ));
                }
                await ReminderService.scheduleDaily(
                    s.reminderHour, s.reminderMinute);
              } else {
                await ReminderService.cancel();
              }
              await s.setReminder(enabled: v);
              if (mounted) setState(() {});
            },
            title: const Text('每日提醒',
                style: TextStyle(
                    color: Color(0xFFF0F4F5),
                    fontSize: 15,
                    fontWeight: FontWeight.w600)),
            subtitle: const Text('到点提醒你来背单词',
                style: TextStyle(color: Color(0xFF54666C), fontSize: 12)),
          ),
          if (s.reminderEnabled) ...[
            const Divider(height: 1, color: Color(0x0FFFFFFF)),
            ListTile(
              dense: true,
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
              title: const Text('提醒时间',
                  style: TextStyle(
                      color: Color(0xFFF0F4F5),
                      fontSize: 15,
                      fontWeight: FontWeight.w600)),
              trailing: Text(s.reminderTimeLabel,
                  style: const TextStyle(
                      color: Color(0xFF00C08B),
                      fontSize: 16,
                      fontWeight: FontWeight.w700)),
              onTap: () async {
                final t = await showTimePicker(
                  context: context,
                  initialTime: TimeOfDay(
                      hour: s.reminderHour, minute: s.reminderMinute),
                );
                if (t == null) return;
                await s.setReminder(hour: t.hour, minute: t.minute);
                await ReminderService.scheduleDaily(t.hour, t.minute);
                if (mounted) setState(() {});
              },
            ),
          ],
        ],
      ),
    );
  }

  Widget _todayCard() {
    final s = widget.settings;
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: const Color(0x0BFFFFFF),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0x14FFFFFF)),
      ),
      child: Column(
        children: [
          _todayRow('单词', s.todayWordDone, s.wordDailyLimit, s.wordPassed),
          const SizedBox(height: 12),
          _todayRow('卡牌', s.todayCardDone, s.cardDailyLimit, s.cardPassed),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton(
              style: OutlinedButton.styleFrom(
                foregroundColor: const Color(0xFFFF5C5C),
                side: const BorderSide(color: Color(0x33FF5C5C)),
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
              onPressed: () async {
                await s.resetToday();
                if (!mounted) return;
                setState(() {});
              },
              child: const Text('重置今日进度'),
            ),
          ),
        ],
      ),
    );
  }

  /// 数据目录：所有数据都在公共文件夹，方便外部工具 / Agent 直接改
  Widget _dataCard() {
    final ok = widget.settings.fileBacked;
    final color = ok ? const Color(0xFF00C08B) : const Color(0xFFFF9F43);
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
          Row(
            children: [
              Icon(ok ? Icons.folder_open : Icons.folder_off,
                  size: 18, color: color),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                    ok ? '已写入公共文件夹' : '未拿到存储权限，暂存在 app 私有目录',
                    style: TextStyle(
                        color: color,
                        fontSize: 13,
                        fontWeight: FontWeight.w600)),
              ),
            ],
          ),
          const SizedBox(height: 10),
          const SelectableText(DataDir.publicPath,
              style: TextStyle(color: Color(0xFFF0F4F5), fontSize: 12)),
          const SizedBox(height: 10),
          const Text(
              'progress.json  每张卡的复习进度\n'
              'settings.json  设置 / 打卡 / 统计 / 提醒\n'
              'books/         导入的书（可直接放 json 进去）\n'
              'export/        手动导出的书',
              style: TextStyle(
                  color: Color(0xFF54666C), fontSize: 12, height: 1.7)),
        ],
      ),
    );
  }

  Widget _todayRow(String label, int done, int limit, bool passed) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Row(
          children: [
            Text('今日$label已背',
                style: const TextStyle(color: Color(0xFFF0F4F5), fontSize: 15)),
            if (passed) ...[
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: const Color(0x1F00C08B),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: const Text('已过关 😁',
                    style: TextStyle(
                        color: Color(0xFF00C08B),
                        fontSize: 11,
                        fontWeight: FontWeight.w700)),
              ),
            ],
          ],
        ),
        Text('$done / $limit',
            style: TextStyle(
                color:
                    passed ? const Color(0xFF00C08B) : const Color(0xFFF0F4F5),
                fontSize: 16,
                fontWeight: FontWeight.w600)),
      ],
    );
  }
}
